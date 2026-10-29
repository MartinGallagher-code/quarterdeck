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

t_a_fleet_tool_is_run_here_and_read_back() {
    seed
    # dcprobe, played by a stand-in that writes what its scan writes
    cat > "$FAKE_BIN/dcprobe" <<'EOF'
#!/bin/sh
out=""; servers=""
while [ $# -gt 0 ]; do
  case "$1" in -o) out="$2"; shift 2;; --servers) servers="$2"; shift 2;; *) shift;; esac
done
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
}

t_binnacle_scripts_run_on_the_hosts() {
    seed
    if "$PY" -c 'import binnacle.why_slow' 2>/dev/null; then
        qdf_rc probe facts -s hosts.txt -q --remote-dir rd > out
        assert_status "$QD_RC" 0
        # why-slow's readings, a column each
        assert_contains "$(qd show facts --cols host,cpu.count --format csv)" "a,"
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
run_test "a fleet tool: run here, read back"         t_a_fleet_tool_is_run_here_and_read_back
run_test "binnacle's scripts run on the hosts"       t_binnacle_scripts_run_on_the_hosts
finish
