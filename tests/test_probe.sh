#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Martin J. Gallagher

# qd probe: the catalogue -- shell commands run by qd's own fan-out,
# binnacle's tools pushed and run on each host, and fleet tools (dcprobe)
# run here and read back.

set -u
source "$(dirname "${BASH_SOURCE[0]}")/test_helper.bash"

seed() {
    install_fake_ssh
    for h in a b; do fake_host "$h"; done
    printf 'a rack=r1\nb rack=r2\n' > hosts.txt
}

t_the_catalogue_lists_itself() {
    out="$(qd probe)"
    assert_contains "$out" "facts"
    assert_contains "$out" "health"
    assert_contains "$out" "sysctl"
    assert_contains "$out" "groups: inventory ="
    qd_rc probe nosuch -s a 2> err
    assert_status "$QD_RC" 2
    assert_contains "$(cat err)" "no probe 'nosuch'"
}

t_command_probes_file_a_run_each() {
    seed
    qdf_rc probe os packages -s hosts.txt -q > out
    assert_status "$QD_RC" 0
    assert_contains "$(cat out)" "qd probe os -- distribution, kernel"
    assert_contains "$(cat out)" "qd probe packages"
    # each is a run of its own name, with named columns
    csv="$(qd show os --format csv)"
    assert_contains "$csv" "host,rack,status"
    assert_contains "$csv" "kernel"
    assert_contains "$(qd show packages --cols host,manager --format csv)" "a,"
    assert_contains "$(qd log)" "packages"
}

t_a_group_expands() {
    seed
    qdf_rc probe settings -s hosts.txt -q > out
    assert_contains "$(cat out)" "qd probe sysctl"
    assert_contains "$(cat out)" "qd probe numa"
    # sysctl's key: value lines are columns, one row per host
    assert_contains "$(qd show sysctl --cols host,vm.swappiness --format csv)" "a,"
}

# A host without the tool a probe asks: it says so in a column, and what it
# could not read is left out -- never 0, never "unknown". On real hosts,
# Alpine answered `listening: 0` with sshd listening (no ss), and Debian
# without systemd `failed_units: 0`.
t_a_missing_tool_is_said_not_zeroed() {
    seed
    nop="$(path_without ss netstat systemctl systemd-detect-virt \
        dpkg-query rpm apk pacman)"
    PATH="$nop" qdf_rc probe listen services os -s hosts.txt -q > out
    assert_status "$QD_RC" 0
    assert_contains "$(qd show listen --format csv)" "none (no ss, no netstat)"
    assert_not_contains "$(qd show listen --format csv | head -1)" "listening"
    out="$(qd show services --format csv)"
    assert_contains "$out" "no systemd"
    assert_not_contains "$(printf '%s\n' "$out" | head -1)" "failed_units"
    assert_not_contains "$(qd show os --format csv | head -1)" "virt"
    assert_not_contains "$(qd show os --format csv)" "unknown"
    # the package manager a host has is the one counted: Alpine's apk
    mkdir -p apkbin
    printf '#!/bin/sh\nprintf "musl\\nbusybox\\nopenssh\\n"\n' > apkbin/apk
    chmod +x apkbin/apk
    PATH="$PWD/apkbin:$nop" qdf probe packages -s hosts.txt -q > out
    assert_contains "$(qd show packages --cols host,manager,packages --format csv)" \
        "a,apk,3"
    assert_not_contains "$(qd show packages --format csv | head -1)" "reboot"
}

# a tool that is there but fails is said too: not a count of nothing
t_a_failing_tool_is_said_not_zeroed() {
    seed
    mkdir -p failbin
    printf '#!/bin/sh\necho "permission denied" >&2\nexit 1\n' > failbin/ss
    cp failbin/ss failbin/docker
    chmod +x failbin/ss failbin/docker
    PATH="$PWD/failbin:$(path_without netstat podman)" qdf probe listen containers -s hosts.txt -q > out
    assert_contains "$(qd show listen --format csv)" "ss failed"
    assert_not_contains "$(qd show listen --format csv | head -1)" "listening"
    out="$(qd show containers --format csv)"
    assert_contains "$out" "ps refused"
    assert_not_contains "$(printf '%s\n' "$out" | head -1)" "docker_running"
    # a package tool that fails has counted nothing; nvidia-smi that cannot
    # reach its driver has measured nothing, and [N/A] is no reading
    printf '#!/bin/sh\necho "rpmdb: open failed" >&2\nexit 1\n' > failbin/rpm
    printf '#!/bin/sh\necho "NVIDIA-SMI has failed because it could not communicate with the NVIDIA driver."\nexit 9\n' > failbin/nvidia-smi
    chmod +x failbin/rpm failbin/nvidia-smi
    PATH="$PWD/failbin:$(path_without dpkg-query apk pacman)" qdf_rc probe packages gpu -s hosts.txt -q > out
    out="$(qd show packages --format csv)"
    assert_contains "$out" "rpm failed"
    assert_not_contains "$(printf '%s\n' "$out" | head -1)" "packages,"
    assert_contains "$(qd show gpu --cols host,status --format csv)" "a,failed"
    printf '#!/bin/sh\necho "0, H100, 40, 10, 100, 80000, [N/A], 0"\n' > failbin/nvidia-smi
    PATH="$PWD/failbin:$PATH" qdf probe gpu -s hosts.txt -q > out
    assert_contains "$(qd show gpu --cols host,name,temp_c --format csv)" "a,H100,40"
    assert_not_contains "$(qd show gpu --format csv)" "N/A"
}

# reachable's CSV goes where --csv says; its -o is the annotated host list
t_reach_reads_reachables_csv() {
    seed
    cat > "$FAKE_BIN/reachable" <<'EOF'
#!/bin/sh
hosts="$1"; csv=""; shift
while [ $# -gt 0 ]; do
  case "$1" in --csv) csv="$2"; shift 2;; *) shift;; esac
done
case "$csv" in ""|-*) echo "reachable: --csv wants a path here" >&2; exit 2;; esac
{ echo "host,addr,ping,ssh,usable,outcome,detail,duration_s"
  while read -r h _; do echo "$h,$h,yes,yes,yes,ok,,0.1"; done < "$hosts"
} > "$csv"
cat "$hosts"
EOF
    chmod +x "$FAKE_BIN/reachable"
    QD_REACHABLE="$FAKE_BIN/reachable" qd_rc probe reach -s hosts.txt > out 2>&1
    assert_status "$QD_RC" 0
    assert_contains "$(qd show latest --cols host,usable,outcome --format csv)" \
        "b,yes,ok"
}

t_a_fleet_tool_is_run_here_and_read_back() {
    seed
    # dcprobe, played by a stand-in that writes what its scan writes
    cat > "$FAKE_BIN/dcprobe" <<'EOF'
#!/bin/sh
out=""; servers=""
while [ $# -gt 0 ]; do
  case "$1" in -o) out="$2"; shift 2;; --servers) servers="$2"; shift 2;; *) shift;; esac
done
cp "$servers" given.txt
{ printf '!test\thost_load1\tunit=load higher=bad\n'
  while read -r h _; do printf 'host_load1\t%s\t0.5\tat=2026-10-29T00:00:00Z\n' "$h"; done < "$servers"
} > "$out"
EOF
    chmod +x "$FAKE_BIN/dcprobe"
    QD_DCPROBE="$FAKE_BIN/dcprobe" qd_rc probe health -s hosts.txt > out 2>&1
    assert_status "$QD_RC" 0
    csv="$(qd show latest --format csv)"
    assert_contains "$csv" "test,target,value"
    assert_contains "$csv" "host_load1,b,0.5"
    assert_contains "$(qd log latest)" "health"
    # dcprobe judges a NIC by the gbps= and mtu= on its host line: they
    # are handed on, not stripped
    printf 'a gbps=25 mtu=9000\n' > nics.txt
    QD_DCPROBE="$FAKE_BIN/dcprobe" qd_rc probe health -s nics.txt > out 2>&1
    assert_contains "$(cat given.txt)" "a gbps=25 mtu=9000"
}

t_binnacle_scripts_run_on_the_hosts() {
    seed
    if "$PY" -c 'import binnacle.why_slow' 2>/dev/null; then
        qdf_rc probe facts -s hosts.txt -q --remote-dir rd > out
        assert_status "$QD_RC" 0
        # why-slow's readings, a column each, and one row per host: a list
        # in them (the top processes) is a cell of JSON, not rows
        assert_contains "$(qd show facts --cols host,cpu.count --format csv)" "a,"
        assert_eq "$(qd show facts --cols host --format csv | tail -n +2 | wc -l | tr -d ' ')" "2"
    else
        qdf_rc probe facts -s hosts.txt 2> err
        assert_status "$QD_RC" 2
        assert_contains "$(cat err)" "pip install binnacle"
        assert_eq "$(ssh_calls)" "0"
    fi
}

run_test "the catalogue lists itself"                t_the_catalogue_lists_itself
run_test "command probes: a run each, named"         t_command_probes_file_a_run_each
run_test "a group expands to its probes"             t_a_group_expands
run_test "a missing tool is said, never zeroed"     t_a_missing_tool_is_said_not_zeroed
run_test "a failing tool is said, never zeroed"     t_a_failing_tool_is_said_not_zeroed
run_test "reach reads reachable's CSV"              t_reach_reads_reachables_csv
run_test "a fleet tool: run here, read back"         t_a_fleet_tool_is_run_here_and_read_back
run_test "binnacle's scripts run on the hosts"       t_binnacle_scripts_run_on_the_hosts
finish
