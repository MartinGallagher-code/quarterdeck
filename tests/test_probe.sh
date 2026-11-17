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

# several probes at once: every host asked every probe in one pool, and
# every run filed by one provost call (one commit) -- each its own run
t_probes_run_together() {
    seed
    qdf probe os -s hosts.txt -q > /dev/null
    : > "$FAKE_SSH_LOG"
    before="$(git -C "$QD_STORE" rev-list --count HEAD)"
    qdf_rc probe os mounts numa -s hosts.txt -q > out
    assert_status "$QD_RC" 0
    for p in os mounts numa; do
        assert_contains "$(cat out)" "qd probe $p"
        assert_contains "$(qd log)" "-$p"
    done
    assert_eq "$(ssh_calls)" "6"
    if has_batch; then
        after="$(git -C "$QD_STORE" rev-list --count HEAD)"
        assert_eq "$((after - before))" "1"
    fi
    # each is still its own run, compared with its own last run
    qdf probe os mounts -s hosts.txt -q > /dev/null
    assert_contains "$(qd diff os 2>&1)" "matched on host"
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
        # sent on stdin, as why-slow --ssh sends itself: one ssh per host,
        # no copy, nothing left on the host
        assert_eq "$(ssh_calls)" "2"
        assert_eq "$(grep -c '^scp ' "$FAKE_SSH_LOG")" "0"
        assert_no_file "$FAKE_ROOT/a/rd"
    else
        qdf_rc probe facts -s hosts.txt 2> err
        assert_status "$QD_RC" 2
        assert_contains "$(cat err)" "pip install binnacle"
        assert_eq "$(ssh_calls)" "0"
    fi
}

# QD-027: --max-fail and --retries are the fan-out's, so a probe has them,
# and probes run together share one stop
t_probes_stop_and_retry_like_a_run() {
    seed
    fake_host_unreachable c
    printf 'a rack=r1\nb rack=r2\nc rack=r2\nd rack=r2\n' > hosts.txt
    fake_host d
    qdf_rc probe os packages -s hosts.txt -j 1 --max-fail 0 -q > out
    assert_status "$QD_RC" 1
    assert_contains "$(qd show os --cols host,status --format csv)" "d,not-run"
    assert_contains "$(qd show packages --cols host,status --format csv)" "a,not-run"
    qdf_rc probe os -s hosts.txt --retries 1 -q > /dev/null
    out="$(qd show os --cols host,attempt,status --format csv)"
    assert_contains "$out" "c,1,unreachable"
    assert_contains "$out" "c,2,unreachable"
    assert_contains "$(qdf probe os -s hosts.txt --max-fail 1 --dry-run 2>&1)" "plan: --max-fail 1"
}

# QD-034: the firmware probe, read from a fake host's own /sys, /proc and
# ethtool (QD_PROBE_ROOT=. points the probe at the host's sandbox), and
# the categorical odd one out

CORPUS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/corpus/firmware"

# fw_host HOST BIOS NIC_KIND [MTU]: a host whose /sys and ethtool answer as
# the corpus's NIC_KIND (mlx5 or virtio) does, with BIOS as its version
fw_host() {
    local h=$1 bios=$2 kind=$3 mtu=${4:-1500} d
    fake_host "$h"
    d="$FAKE_ROOT/$h"
    mkdir -p "$d/sys/class/dmi/id" "$d/proc" "$d/sys/class/net/eth0/device" \
        "$d/sys/class/net/lo" "$d/ethtool"
    cp "$CORPUS/dmi/"* "$d/sys/class/dmi/id/"
    printf '%s\n' "$bios" > "$d/sys/class/dmi/id/bios_version"
    cp "$CORPUS/cpuinfo" "$d/proc/cpuinfo"
    printf '%s\n' "$mtu" > "$d/sys/class/net/eth0/mtu"
    printf '65536\n' > "$d/sys/class/net/lo/mtu"
    for f in i k g c a; do
        [ -f "$CORPUS/$kind.$f" ] && cp "$CORPUS/$kind.$f" "$d/ethtool/eth0.$f"
    done
    return 0
}

# an ethtool that answers from the fake host's ./ethtool/IFACE.FLAG, as the
# real one does: what it cannot do is "Operation not supported", exit 1
fake_ethtool() {
    mkdir -p "$TEST_TMPDIR/ethbin"
    cat > "$TEST_TMPDIR/ethbin/ethtool" <<'SH'
#!/bin/sh
f="ethtool/$2.${1#-}"
[ -f "$f" ] && exec cat "$f"
echo "Cannot get device settings: Operation not supported" >&2
exit 1
SH
    chmod +x "$TEST_TMPDIR/ethbin/ethtool"
}

t_firmware_reads_dmi_cpuinfo_and_ethtool() {
    install_fake_ssh
    fake_ethtool
    fw_host a 2.19.1 mlx5 9000
    fw_host b 2.19.1 virtio
    printf 'a rack=r1\nb rack=r1\n' > hosts.txt
    QD_PROBE_ROOT=. PATH="$TEST_TMPDIR/ethbin:$PATH" \
        qdf_rc probe firmware -s hosts.txt -q > out
    assert_status "$QD_RC" 0
    assert_contains "$(cat out)" "qd probe firmware -- BIOS, board"
    csv="$(qd show firmware --cols host,nic,bios_version,bios_vendor,product_name,microcode,mtu,driver,firmware_version --format csv)"
    assert_contains "$csv" "a,eth0,2.19.1,Dell Inc.,PowerEdge R650,0xd0003d1,9000,mlx5_core,22.36.1010 (MT_0000000359)"
    # virtio has no firmware version: blank, not measured, never a word
    assert_contains "$csv" "b,eth0,2.19.1,Dell Inc.,PowerEdge R650,0xd0003d1,1500,virtio_net,"
    # lo has no device: not a NIC, not a row
    assert_not_contains "$csv" ",lo,"
    out="$(qd show firmware --cols host,offload.tx-checksum-ipv4,offload.large-receive-offload,ring.rx,ring_max.rx,coalesce.rx-usecs,coalesce.adaptive-rx,pause.rx,pause.autonegotiate --format csv)"
    assert_contains "$out" "a,off,off,1024,8192,8,on,on,off"
    # what virtio's ethtool cannot say (coalescing, pause) is left out
    assert_contains "$out" "b,,off,256,256,,,,"
    # serials and the like are never read
    assert_not_contains "$(qd show firmware --format csv | head -1)" "serial"
    assert_contains "$(qd probe)" "firmware"
    assert_contains "$(qd probe)" "inventory = os firmware disks"
}

t_firmware_says_what_it_could_not_read() {
    install_fake_ssh
    fw_host a 2.19.1 mlx5
    fw_host b 2.19.1 mlx5
    # no dmi at all on b (a VM without it)
    rm -rf "$FAKE_ROOT/b/sys/class/dmi"
    printf 'a\nb\n' > hosts.txt
    nop="$(path_without ethtool)"
    QD_PROBE_ROOT=. PATH="$nop" qdf_rc probe firmware -s hosts.txt -q > out
    assert_status "$QD_RC" 0
    csv="$(qd show firmware --cols host,nic,bios_version,dmi,ethtool,mtu --format csv)"
    # the DMI rows are filed, and ethtool's absence is said, not blank
    assert_contains "$csv" "a,eth0,2.19.1,,not installed,1500"
    assert_contains "$csv" "b,eth0,,absent,not installed,1500"
    assert_not_contains "$(qd show firmware --format csv | head -1)" "driver"
    if [ "$(id -u)" != 0 ]; then
        # a file only root can read says so (root reads it: not testable as root)
        chmod 000 "$FAKE_ROOT/a/sys/class/dmi/id/bios_version"
        QD_PROBE_ROOT=. PATH="$nop" qdf_rc probe firmware -s hosts.txt -q > out
        assert_contains "$(qd show firmware --cols host,bios_version --format csv)" "a,needs root"
        chmod 644 "$FAKE_ROOT/a/sys/class/dmi/id/bios_version"
    fi
}

t_firmware_finds_the_odd_host_in_a_rack() {
    install_fake_ssh
    fake_ethtool
    for h in a b c; do fw_host "$h" 2.19.1 mlx5 9000; done
    fw_host d 2.17.0 mlx5 9000
    fw_host e 2.19.1 mlx5 1500
    printf 'a rack=r1\nb rack=r1\nc rack=r1\nd rack=r1\ne rack=r2\n' > hosts.txt
    QD_PROBE_ROOT=. PATH="$TEST_TMPDIR/ethbin:$PATH" \
        qdf_rc probe firmware -s hosts.txt -q > /dev/null
    qd_rc outliers firmware --categorical --format csv > out
    assert_status "$QD_RC" 1
    out="$(cat out)"
    # one NIC a host: no match column
    assert_contains "$out" "rack,column,host,value,majority,agree,measured,verdict"
    # d's BIOS against r1's 2.19.1; e is alone in r2, so nothing to say
    assert_contains "$out" "r1,bios_version,d,2.17.0,2.19.1,3,4,differs"
    assert_eq "$(printf '%s\n' "$out" | tail -n +2 | wc -l | tr -d ' ')" "1"
}

run_test "the catalogue lists itself"                t_the_catalogue_lists_itself
run_test "command probes: a run each, named"         t_command_probes_file_a_run_each
run_test "a group expands to its probes"             t_a_group_expands
run_test "a missing tool is said, never zeroed"     t_a_missing_tool_is_said_not_zeroed
run_test "a failing tool is said, never zeroed"     t_a_failing_tool_is_said_not_zeroed
run_test "reach reads reachable's CSV"              t_reach_reads_reachables_csv
run_test "a fleet tool: run here, read back"         t_a_fleet_tool_is_run_here_and_read_back
run_test "several probes run together"             t_probes_run_together
run_test "binnacle's scripts run on the hosts"       t_binnacle_scripts_run_on_the_hosts
run_test "probes stop and retry like a run"         t_probes_stop_and_retry_like_a_run
run_test "firmware: dmi, cpuinfo and ethtool"       t_firmware_reads_dmi_cpuinfo_and_ethtool
run_test "firmware: what it could not read"         t_firmware_says_what_it_could_not_read
run_test "firmware: the odd host in a rack"         t_firmware_finds_the_odd_host_in_a_rack
finish
