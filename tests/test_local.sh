#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Martin J. Gallagher

# A command given no hosts runs on this machine, as one host named after
# it, reached without ssh: `--via local` (QD-037).  Everything that names
# hosts still wins; `qd split` and `qd campaign new` still refuse; --sudo
# is refused on the host nobody named.  The fake ssh is on hand in every
# case, so a case can show it was never started.

set -u
source "$(dirname "${BASH_SOURCE[0]}")/test_helper.bash"

# this machine's name, as a row gives it
local_name() {
    "$PY" -c 'import sys
sys.path.insert(0, sys.argv[1])
from quarterdeck.hosts import local_name
print(local_name())' "$QD_DIR"
}

no_ssh_started() {
    assert_eq "$(cat "$FAKE_SSH_ARGV")" ""
    assert_eq "$(cat "$FAKE_SSH_LOG")" ""
}

notices() { grep -c "no hosts named" "$1" || true; }

# SIG (INT or TERM) to qd alone once FILE exists, with SIGINT back to its
# default (a suite run in the background starts with it ignored):
# test_run.sh's interrupt_when, for either signal
signal_when() {
    local sig="$1" file="$2"; shift 2
    set +e
    "$PY" -c 'import os, signal, subprocess, sys, time
p = subprocess.Popen(sys.argv[3:], preexec_fn=lambda: signal.signal(
    signal.SIGINT, signal.SIG_DFL))
end = time.time() + 60
while not os.path.exists(sys.argv[2]) and time.time() < end \
        and p.poll() is None:
    time.sleep(0.05)
time.sleep(0.3)
if p.poll() is None:
    p.send_signal(getattr(signal, "SIG" + sys.argv[1]))
sys.exit(p.wait())' "$sig" "$file" "$@"
    QD_RC=$?
    set -e
}

# PID has ended, within 3 s: no longer there, or a zombie its parent's
# end left for init to reap
gone() {
    local i=0
    while kill -0 "$1" 2>/dev/null; do
        case "$(ps -o stat= -p "$1" 2>/dev/null)" in *Z*) return 0 ;; esac
        [ "$i" -lt 30 ] || return 1
        sleep 0.1
        i=$((i + 1))
    done
}

# -- the default ------------------------------------------------------------

t_a_bare_run_is_this_machine() {
    install_fake_ssh
    me="$(local_name)"
    qdf_rc run -- echo hi 2> err
    assert_status "$QD_RC" 0
    assert_eq "$(qd show latest --cols host,addr,status,rc,A --format csv | tail -n +2)" \
        "$me,127.0.0.1,ok,0,hi"
    assert_eq "$(qd show ds:qd.runs --cols via,hosts,ok,ssh_user --format csv | tail -n +2)" \
        "local,1,1,"
    assert_contains "$(qd log latest)" "via       local"
    # no ssh, no scp: not even an ssh -G for the run's record
    no_ssh_started
    assert_eq "$(notices err)" "1"
    assert_contains "$(cat err)" "the fleet is this machine, $me, reached without ssh (--via local)"
    assert_contains "$(cat err)" "name hosts with -s FILE, -S a,b,c, QD_SERVERS or a hosts.txt here"
}

t_the_notice_comes_once_and_only_for_the_default() {
    install_fake_ssh
    fake_host localhost
    # two probes are two runs from one host list: one notice
    qd_rc probe os mounts -q > out 2> err
    assert_status "$QD_RC" 0
    assert_eq "$(notices err)" "1"
    assert_eq "$(qd show ds:qd.runs --cols via --format csv | tail -n +2 | tr '\n' ' ')" \
        "local local "
    # hosts named: nothing said
    qdf_rc run -S localhost -- echo hi 2> err
    assert_status "$QD_RC" 0
    assert_eq "$(notices err)" "0"
    # --via local names this machine
    qd_rc run --via local -- echo hi 2> err
    assert_status "$QD_RC" 0
    assert_eq "$(notices err)" "0"
    # a launcher given: this machine, by that launcher, and it says so
    qdf_rc run --via ssh --dry-run -- uptime > out 2> err
    assert_contains "$(cat err)" "reached by --via ssh at 127.0.0.1"
    assert_contains "$(cat out)" "127.0.0.1 uptime"
}

t_every_way_of_naming_hosts_wins() {
    install_fake_ssh
    for h in n01 n02 n03; do fake_host "$h"; done
    echo n01 > hosts.txt
    qdf run -q -- echo hi > /dev/null 2> err
    assert_eq "$(qd show latest --cols host --format csv | tail -n +2)" "n01"
    assert_eq "$(notices err)" "0"
    rm hosts.txt
    echo n02 > servers.txt
    qdf run -q -- echo hi > /dev/null
    assert_eq "$(qd show latest --cols host --format csv | tail -n +2)" "n02"
    rm servers.txt
    QD_SERVERS=n03 qdf run -q -- echo hi > /dev/null
    assert_eq "$(qd show latest --cols host --format csv | tail -n +2)" "n03"
    echo n01 > list.txt
    qdf run -q -s list.txt -- echo hi > /dev/null
    assert_eq "$(qd show latest --cols host --format csv | tail -n +2)" "n01"
    qdf run -q -S n02 -- echo hi > /dev/null
    assert_eq "$(qd show latest --cols host --format csv | tail -n +2)" "n02"
    assert_eq "$(qd show ds:qd.runs --cols via --format csv | tail -n +2 | sort -u)" "ssh"
    # an empty host list names hosts too: it is not this machine
    : > hosts.txt
    qdf_rc run -q -- echo hi 2> err
    assert_status "$QD_RC" 2
    assert_contains "$(cat err)" "no hosts given"
    rm hosts.txt
    # --layout: binnacle's manifest, played by a stand-in
    printf 'dc A\n' > floor.dc
    printf '%s\n' '#!/bin/sh' 'echo "name,path,kind,role,room,row,rack,slot"' \
        'echo "n03,A/r1/u1,node,server,A,A,r1,u1"' > "$FAKE_BIN/manifest"
    chmod +x "$FAKE_BIN/manifest"
    QD_MANIFEST="$FAKE_BIN/manifest" qdf run -q --layout floor.dc -- echo hi > /dev/null
    assert_eq "$(qd show latest --cols host --format csv | tail -n +2)" "n03"
    # --rerun: the hosts that were not ok
    fake_host_unreachable n04
    qdf_rc run -q -S n01,n04 -- echo hi > /dev/null
    qdf_rc run -q --rerun latest -- echo hi > /dev/null
    assert_eq "$(qd show latest --cols host,status --format csv | tail -n +2)" "n04,unreachable"
    # --via srun: the allocation's nodes, as before
    install_fake_launchers
    in_allocation 4242 'n0[1-2]'
    qd_rc run --via srun -q -- echo hi > /dev/null 2> err
    assert_status "$QD_RC" 0
    assert_eq "$(qd show latest --cols host --format csv | tail -n +2 | tr '\n' ' ')" "n01 n02 "
    assert_eq "$(notices err)" "0"
}

t_a_rerun_of_a_local_run_stays_local() {
    install_fake_ssh
    me="$(local_name)"
    qdf_rc run -q -- 'exit 3' > /dev/null 2>&1
    assert_status "$QD_RC" 1
    assert_eq "$(qd show latest --cols host,status,rc --format csv | tail -n +2)" "$me,failed,3"
    qdf_rc run -q --rerun latest -- echo again > /dev/null 2> err
    assert_status "$QD_RC" 0
    assert_eq "$(qd show latest --cols host,addr,status,A --format csv | tail -n +2)" \
        "$me,127.0.0.1,ok,again"
    assert_eq "$(qd show ds:qd.runs --cols via --format csv | tail -n +2 | tr '\n' ' ')" \
        "local local "
    assert_eq "$(notices err)" "0"
    no_ssh_started
}

t_hosts_prints_this_machine() {
    me="$(local_name)"
    out="$(qd hosts 2> err)"
    assert_eq "$out" "$me=127.0.0.1"
    assert_eq "$(notices err)" "1"
    assert_eq "$(qd hosts --plain 2> /dev/null)" "$me=127.0.0.1"
    assert_contains "$(qd hosts --csv 2> /dev/null)" "$me,127.0.0.1,"
}

t_split_and_campaign_new_still_refuse() {
    qd_rc split --into 2 2> err
    assert_status "$QD_RC" 2
    assert_contains "$(cat err)" "no hosts given (use --servers FILE"
    assert_eq "$(notices err)" "0"
    qd_rc campaign new c1 --into 2 -- uptime 2> err
    assert_status "$QD_RC" 2
    assert_contains "$(cat err)" "no hosts given (use --servers FILE"
    # and with hosts, they split as before
    printf 'a\nb\n' > hosts.txt
    qd_rc split --into 2 > out 2> err
    assert_status "$QD_RC" 0
    assert_contains "$(cat out)" "2 hosts"
}

t_doe_run_gets_the_default() {
    stand_in_doe
    cat > bench.json <<EOF
{"metadata": {"name": "Stream test"},
 "factors": [{"name": "streams", "levels": ["1", "4"], "type": "continuous"}],
 "responses": [{"name": "mbps", "optimize": "maximize"}],
 "settings": {"operation": "full_factorial", "block_count": 1}}
EOF
    install_fake_ssh
    # shellcheck disable=SC2016  # expanded by the command, not here
    qdf_rc doe run bench.json -q -- 'echo "mbps: $(( 900 * {streams} ))"' > out 2> err
    assert_status "$QD_RC" 0
    assert_contains "$(cat out)" "2 of 2 points measured"
    assert_eq "$(notices err)" "1"
    assert_eq "$(qd show ds:qd.runs --cols via --format csv | tail -n +2 | sort -u)" "local"
    no_ssh_started
}

# -- --sudo, --user ------------------------------------------------------------

t_sudo_on_the_unnamed_host_is_refused() {
    install_fake_ssh
    me="$(local_name)"
    qdf_rc run --sudo -- 'touch RAN' 2> err
    assert_status "$QD_RC" 2
    assert_contains "$(cat err)" "--sudo with no hosts named would run the command as root on this machine, $me"
    assert_contains "$(cat err)" "-S localhost, or --via local"
    assert_no_file RAN
    QD_VIA=ssh qdf_rc run --sudo -- 'touch RAN' 2> err
    assert_status "$QD_RC" 2
    assert_contains "$(cat err)" "would run the command as root"
    # named, it is meant
    qd_rc run --via local --sudo --dry-run -- id > out 2> err
    assert_status "$QD_RC" 0
    assert_eq "$(cat out)" "sh -c 'sudo -n sh -c id'"
    qdf_rc run -S localhost --sudo --dry-run -- id > out 2> err
    assert_status "$QD_RC" 0
    assert_contains "$(cat out)" "localhost 'sudo -n sh -c id'"
    no_ssh_started
}

t_user_is_warned_and_ignored() {
    install_fake_ssh
    qdf_rc run -u bob -q -- echo hi > /dev/null 2> err
    assert_status "$QD_RC" 0
    assert_contains "$(cat err)" "--user (QD_SSH_USER) is not used with --via local: the command runs here, as you"
    assert_eq "$(qd show ds:qd.runs --cols via,ssh_user --format csv | tail -n +2)" "local,"
    no_ssh_started
}

# -- --via local --------------------------------------------------------------

t_via_local_refuses_other_hosts() {
    install_fake_ssh
    me="$(local_name)"
    qdf_rc run --via local -S otherhost -- 'touch RAN' 2> err
    assert_status "$QD_RC" 2
    assert_contains "$(cat err)" "otherhost is not this machine: --via local runs here only"
    qdf_rc run --via local -S 'web=10.9.9.9' -- 'touch RAN' 2> err
    assert_status "$QD_RC" 2
    assert_contains "$(cat err)" "web (10.9.9.9) is not this machine"
    QD_VIA=local qdf_rc run -S localhost:2222 -- 'touch RAN' 2> err
    assert_status "$QD_RC" 2
    assert_contains "$(cat err)" "localhost has a port (2222)"
    qdf_rc run --via local -S localhost,127.0.0.1 -- 'touch RAN' 2> err
    assert_status "$QD_RC" 2
    assert_contains "$(cat err)" "localhost, 127.0.0.1 are all this machine: --via local runs on it once"
    assert_no_file RAN
    no_ssh_started
    # this machine, by any of its names
    for h in localhost 127.0.0.1 ::1 "$me" "box=127.0.0.2"; do
        qdf_rc run --via local -S "$h" -q -- echo hi > /dev/null 2>&1
        assert_status "$QD_RC" 0
    done
    no_ssh_started
}

t_a_named_localhost_is_reached_by_ssh() {
    install_fake_ssh
    fake_host localhost
    qdf_rc run -S localhost -q -- echo hi > /dev/null
    assert_status "$QD_RC" 0
    assert_contains "$(cat "$FAKE_SSH_LOG")" "ssh localhost"
    assert_eq "$(qd show ds:qd.runs --cols via --format csv | tail -n +2)" "ssh"
}

# shellcheck disable=SC2016  # expanded by the command, not here
t_via_local_pushes_runs_and_cleans_up() {
    install_fake_ssh
    printf '#!/bin/sh\necho "args: $*"\necho "in: $(pwd)"\n' > probe.sh
    printf 'data\n' > extra.txt
    rd="$TEST_TMPDIR/rd"
    qdf_rc run --script probe.sh --push extra.txt --remote-dir "$rd" -q -- 'hello there' > /dev/null
    assert_status "$QD_RC" 0
    assert_contains "$(pv source 1)" "args: hello there"
    assert_contains "$(pv source 1)" "in: $rd/qd."
    # made, used, removed -- rd too, since qd made it
    assert_no_file "$rd"
    # --keep-remote keeps the run's own directory, sentinel and all
    mkdir -p "$rd"
    qdf_rc run --push extra.txt --remote-dir "$rd" --keep-remote -q -- cat extra.txt > /dev/null 2> err
    assert_status "$QD_RC" 0
    assert_contains "$(cat err)" "left on each host in $rd/qd."
    kept="$(ls "$rd")"
    assert_file_exists "$rd/$kept/extra.txt"
    assert_file_exists "$rd/$kept/.qd-owned"
    [ -x "$rd/$kept/extra.txt" ] || fail "the pushed file is not executable"
    # cleanup removes only the run's own directory: rd and what else is
    # in it stay
    rm -rf "${rd:?}/$kept"
    touch "$rd/someone-elses"
    qdf_rc run --push extra.txt --remote-dir "$rd" -q -- cat extra.txt > /dev/null
    assert_status "$QD_RC" 0
    assert_eq "$(ls -A "$rd")" "someone-elses"
    no_ssh_started
}

t_via_local_a_push_that_fails_is_push_failed() {
    install_fake_ssh
    printf 'x\n' > f.txt
    mkdir ro
    chmod 500 ro
    if touch ro/probe 2>/dev/null; then
        # root writes anywhere: nothing to show here
        return 0
    fi
    qdf_rc run --push f.txt --remote-dir "$TEST_TMPDIR/ro/sub" -q -- cat f.txt > /dev/null 2>&1
    chmod 700 ro
    assert_status "$QD_RC" 1
    assert_contains "$(qd show latest --cols status --format csv)" "push-failed"
}

t_via_local_feeds_stdin() {
    write_driver
    printf 'import sys\nprint("read: " + sys.stdin.read().strip())\n' > s.py
    printf 'print("from stdin")\n' > in.py
    out="$(drive "python3 s.py" in.py)"
    assert_contains "$out" '"outcome": "ok"'
    assert_contains "$out" 'read: print(\"from stdin\")'
    # a script probe, sent to `python3 -` on stdin, as the probes send it
    out="$(drive "python3 -" in.py)"
    assert_contains "$out" '"out": "from stdin\n"'
}

t_via_local_a_timeout_stops_the_whole_group() {
    install_fake_ssh
    # shellcheck disable=SC2016  # expanded by the command, not here
    qdf_rc run --no-store --timeout 1 -- \
        'sleep 600 & echo $! > child; (sleep 3; touch LATE) & wait' > out 2>&1
    assert_status "$QD_RC" 1
    assert_contains "$(cat out)" "timed out after 1.0s; qd stopped it on the host"
    assert_file_exists child
    gone "$(cat child)" || fail "sleep 600 is still running: $(cat child)"
    sleep 2.5
    assert_no_file LATE
    no_ssh_started
}

t_via_local_max_output_stops_a_flood() {
    install_fake_ssh
    # shellcheck disable=SC2016  # expanded by the command, not here
    qdf_rc run --max-output 2000 -- 'echo $$ > shell; while :; do echo flood; done' > out 2>&1
    assert_status "$QD_RC" 1
    csv="$(qd show latest --cols status,rc,error --format csv)"
    assert_contains "$csv" "failed,125,output exceeded --max-output (2000 bytes); qd stopped it on the host"
    gone "$(cat shell)" || fail "the flooding shell is still running"
}

t_via_local_ctrl_c_stops_the_command() {
    install_fake_ssh
    # shellcheck disable=SC2016  # expanded by the command, not here
    signal_when INT started "$PY" "$QD_DIR/qd" run --timeout 120 -- \
        'sleep 120 & echo $! > child; touch started; wait' > out 2>&1
    assert_status "$QD_RC" 1
    assert_contains "$(cat out)" "interrupted (Ctrl-C)"
    assert_contains "$(qd show latest --cols status,error --format csv)" \
        "not-run,qd: interrupted (Ctrl-C) before it answered"
    gone "$(cat child)" || fail "the command's sleep outlived qd: $(cat child)"
    # a TERM ends qd at once, as ever, and the command with it
    rm started child
    # shellcheck disable=SC2016  # expanded by the command, not here
    signal_when TERM started "$PY" "$QD_DIR/qd" run --no-store --timeout 120 -- \
        'sleep 120 & echo $! > child; touch started; wait' > out 2>&1
    assert_status "$QD_RC" 143
    gone "$(cat child)" || fail "TERM to qd left the command's sleep: $(cat child)"
}

t_via_local_policy_every_and_retries() {
    install_fake_ssh
    # the allow-list, before anything runs
    printf 'uptime\n' > allow.txt
    qdf_rc run --allow allow.txt -- 'touch RAN' 2> err
    assert_status "$QD_RC" 2
    assert_no_file RAN
    qdf_rc run --read-only --push allow.txt -- cat allow.txt 2> err
    assert_status "$QD_RC" 2
    # --every and --count: a pass each
    qdf_rc run --every 0.2 --count 2 -q -- echo tick > /dev/null
    assert_status "$QD_RC" 0
    assert_eq "$(qd show latest --cols pass --format csv | tail -n +2 | tr '\n' ' ')" "1 2 "
    # --retries --retry-failed: every try a row
    qdf_rc run --retries 1 --retry-failed -q -- 'exit 4' > /dev/null
    assert_status "$QD_RC" 1
    assert_eq "$(qd show latest --cols attempt,rc --format csv | tail -n +2 | tr '\n' ' ')" "1,4 2,4 "
    no_ssh_started
}

t_doctor_says_where_the_hosts_come_from() {
    me="$(local_name)"
    out="$(qd doctor --via local 2>&1 || true)"
    assert_contains "$out" "launcher  local: this machine only, without ssh"
    assert_contains "$out" "hosts     none named here, so a command runs on this machine, $me, without ssh (--via local)"
    out="$(qd doctor 2>&1 || true)"
    assert_contains "$out" "srun, pdsh, clush or local"
    out="$(QD_VIA=ssh qd doctor 2>&1 || true)"
    assert_contains "$out" "by --via ssh at 127.0.0.1"
    echo n01 > hosts.txt
    assert_contains "$(qd doctor 2>&1 || true)" "hosts     hosts.txt in this directory"
    assert_contains "$(QD_SERVERS='n[1-2]' qd doctor 2>&1 || true)" "hosts     QD_SERVERS (n[1-2])"
}

# fleet's runner through launch.LocalRunner, for what the CLI has no flag
# for: a file on the command's stdin.  argv: PKGDIR COMMAND STDIN
write_driver() {
    cat > "$TEST_TMPDIR/drive.py" <<'EOF'
import json, sys
sys.path.insert(0, sys.argv[1])
from quarterdeck import launch
from quarterdeck.hosts import local_host

r = launch.make("local", timeout=20)
x = r.run_one(local_host(), sys.argv[2], stdin=sys.argv[3])
print(json.dumps({"outcome": x.outcome, "rc": int(x.rc), "out": x.stdout,
                  "err": x.stderr}))
EOF
}

drive() { "$PY" "$TEST_TMPDIR/drive.py" "$QD_DIR" "$@"; }

run_test "a bare run is this machine, with no ssh"    t_a_bare_run_is_this_machine
run_test "the notice: once, and only for the default" t_the_notice_comes_once_and_only_for_the_default
run_test "every way of naming hosts wins"             t_every_way_of_naming_hosts_wins
run_test "a rerun of a local run stays local"         t_a_rerun_of_a_local_run_stays_local
run_test "qd hosts prints this machine"               t_hosts_prints_this_machine
run_test "split and campaign new still refuse"        t_split_and_campaign_new_still_refuse
run_test "doe run gets the default"                   t_doe_run_gets_the_default
run_test "--sudo on the unnamed host is refused"      t_sudo_on_the_unnamed_host_is_refused
run_test "--user is warned about and ignored"         t_user_is_warned_and_ignored
run_test "--via local refuses other hosts"            t_via_local_refuses_other_hosts
run_test "a named localhost is reached by ssh"        t_a_named_localhost_is_reached_by_ssh
run_test "--via local: pushes, runs, cleans up"       t_via_local_pushes_runs_and_cleans_up
run_test "--via local: a failed push is push-failed"  t_via_local_a_push_that_fails_is_push_failed
run_test "--via local: stdin"                         t_via_local_feeds_stdin
run_test "--via local: --timeout stops the group"     t_via_local_a_timeout_stops_the_whole_group
run_test "--via local: --max-output stops a flood"    t_via_local_max_output_stops_a_flood
run_test "--via local: Ctrl-C or TERM stops it"       t_via_local_ctrl_c_stops_the_command
run_test "--via local: policy, --every, --retries"    t_via_local_policy_every_and_retries
run_test "doctor: the launcher, and where hosts come from" t_doctor_says_where_the_hosts_come_from
finish
