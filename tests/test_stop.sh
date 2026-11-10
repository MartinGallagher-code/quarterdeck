#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Martin J. Gallagher

# A command qd gives up on -- past --timeout or --max-output -- is stopped
# on the host, not only its local ssh killed (QD-026).  Real OpenSSH runs
# the command apart from the client, so killing ssh leaves it running;
# FAKE_SSH_DETACH=1 makes the fake ssh do the same, and every case here
# runs that way.  Each command would leave a mark (MARK, CHILD) a few
# seconds on; a stopped one never does.  The first case shows the fake
# keeps a command running when nothing stops it, so the others prove
# something.

set -u
source "$(dirname "${BASH_SOURCE[0]}")/test_helper.bash"

later() { sleep 3.5; }

# fleet.Runner on one fake host, for what the CLI has no flag for (a
# script on stdin, as the probes send) and for byte-for-byte answers.
# argv: PKGDIR CASE; prints what came back as JSON.
write_driver() {
    cat > "$TEST_TMPDIR/drive.py" <<'EOF'
import json, os, sys
sys.path.insert(0, sys.argv[1])
from quarterdeck import fleet
from quarterdeck.hosts import Host

case = sys.argv[2]
r = fleet.Runner(ssh=os.environ["FAKE_BIN"] + "/ssh",
                 scp=os.environ["FAKE_BIN"] + "/scp", timeout=1,
                 max_output=int(os.environ.get("CASE_MAX", 4194304)))
if case == "nostop":
    r.stop = lambda host, group: ""
h = Host("n01", "n01")
stdin = None
if case == "stdin":
    open("probe.py", "w").write(
        "import time\ntime.sleep(3)\nopen('MARK', 'w').write('x')\n")
    stdin, command = "probe.py", "python3 -"
else:
    command = os.environ["CASE_CMD"]
x = r.run_one(h, command, stdin=stdin)
print(json.dumps({"outcome": x.outcome, "rc": int(x.rc), "out": x.stdout,
                  "err": x.stderr, "left": getattr(x, "left_running", None)}))
EOF
}

drive() { "$PY" "$TEST_TMPDIR/drive.py" "$QD_DIR" "$@"; }

setup_detached() {
    install_fake_ssh
    fake_host n01
    export FAKE_SSH_DETACH=1
}

t_the_fake_keeps_an_unstopped_command_running() {
    setup_detached
    write_driver
    CASE_CMD='sleep 2; touch MARK' drive nostop > out
    assert_contains "$(cat out)" '"outcome": "timeout"'
    later
    assert_file_exists "$FAKE_ROOT/n01/MARK"
}

t_a_timed_out_command_is_stopped_with_its_children() {
    setup_detached
    qdf_rc run --no-store -S n01 --timeout 1 -- \
        '(sleep 3; touch CHILD) & sleep 3; touch MARK' > out 2>&1
    assert_status "$QD_RC" 1
    assert_contains "$(cat out)" "timed out after 1.0s; qd stopped it on the host"
    assert_not_contains "$(cat out)" "NOT STOPPED"
    later
    assert_no_file "$FAKE_ROOT/n01/MARK"
    assert_no_file "$FAKE_ROOT/n01/CHILD"
}

t_a_flooding_command_is_stopped() {
    setup_detached
    # silent once past the cap, so no broken pipe ends it
    qdf_rc run --no-store -S n01 --max-output 1000 -- \
        'head -c 5000 /dev/zero; sleep 3; touch MARK' > out 2>&1
    assert_contains "$(cat out)" "output exceeded --max-output (1000 bytes); qd stopped it on the host"
    later
    assert_no_file "$FAKE_ROOT/n01/MARK"
}

t_a_script_is_stopped_before_its_directory_goes() {
    setup_detached
    # shellcheck disable=SC2016  # a script for the far side to expand
    printf '#!/bin/sh\nsleep 3\ntouch "$1"\n' > slow.sh
    qdf_rc run --no-store -S n01 --timeout 1 --remote-dir rd \
        --script slow.sh -- "$FAKE_ROOT/n01/MARK" > out 2>&1
    assert_contains "$(cat out)" "qd stopped it on the host"
    assert_not_contains "$(cat out)" "could not remove"
    assert_eq "$(ls "$FAKE_ROOT/n01/rd" 2>/dev/null)" ""
    later
    assert_no_file "$FAKE_ROOT/n01/MARK"
}

t_a_probe_on_stdin_is_stopped() {
    setup_detached
    write_driver
    drive stdin > out
    assert_contains "$(cat out)" '"outcome": "timeout"'
    assert_contains "$(cat out)" '"left": false'
    later
    assert_no_file "$FAKE_ROOT/n01/MARK"
}

# the host cannot be reached again to stop it: the row and the summary
# say it may still be running, and a pushed directory is left with it
t_a_stop_that_cannot_be_confirmed_is_said() {
    setup_detached
    printf '#!/bin/sh\ntouch ../../.unreachable\nsleep 3\n' > cut.sh
    qdf_rc run --no-store -S n01 --timeout 1 --remote-dir rd \
        --script cut.sh > out 2>&1
    assert_contains "$(cat out)" "NOT STOPPED  the command may still be running on 1 host, where qd could not stop it: n01"
    assert_contains "$(cat out)" "timed out after 1.0s, and may still be running on the host: qd could not stop it"
    assert_dir_exists "$FAKE_ROOT/n01/$(cd "$FAKE_ROOT/n01" && ls -d rd/qd.*)"
    rm -f "$FAKE_ROOT/n01/.unreachable"
    # --quiet still says it
    qdf_rc run --no-store -q -S n01 --timeout 1 -- \
        'touch .unreachable; sleep 3' > out 2>&1
    assert_contains "$(cat out)" "NOT STOPPED"
    rm -f "$FAKE_ROOT/n01/.unreachable"
    # and a kept run carries it as a note
    qdf_rc run -q -S n01 --timeout 1 -- 'touch .unreachable; sleep 3' \
        > /dev/null 2>&1
    rm -f "$FAKE_ROOT/n01/.unreachable"
    assert_contains "$(qd log latest)" "note      may still be running on 1 host, where qd could not stop it: n01"
    assert_contains "$(qd show latest --cols error --format csv)" "may still be running on the host"
    later
}

# what finishes in time comes back exactly as before: no terminal, no
# CRLF, stderr apart, and the line naming the group taken off again
t_an_answer_in_time_is_unchanged() {
    for detach in "" 1; do
        install_fake_ssh
        fake_host n01
        export FAKE_SSH_DETACH="$detach"
        write_driver
        # shellcheck disable=SC2016  # for the far side
        CASE_CMD='printf "a\tb\n\nc"; printf "e1\ne2\n" >&2; [ -t 0 ] || [ -t 1 ] && echo tty; exit 3' \
            drive plain > out
        assert_eq "$(cat out)" '{"outcome": "failed", "rc": 3, "out": "a\tb\n\nc", "err": "e1\ne2\n", "left": false}'
        # stderr of exactly --max-output bytes is not past it
        CASE_MAX=10 CASE_CMD='printf 0123456789 >&2' drive plain > out
        assert_eq "$(cat out)" '{"outcome": "ok", "rc": 0, "out": "", "err": "0123456789", "left": false}'
        CASE_MAX=10 CASE_CMD='printf 0123456789x >&2' drive plain > out
        assert_contains "$(cat out)" '"rc": 125'
    done
}

run_test "the fake keeps an unstopped command running" t_the_fake_keeps_an_unstopped_command_running
run_test "a timed-out command is stopped, children too" t_a_timed_out_command_is_stopped_with_its_children
run_test "a flooding command is stopped"               t_a_flooding_command_is_stopped
run_test "a script stops before its directory goes"    t_a_script_is_stopped_before_its_directory_goes
run_test "a probe on stdin is stopped"                 t_a_probe_on_stdin_is_stopped
run_test "a stop not confirmed is said"                t_a_stop_that_cannot_be_confirmed_is_said
run_test "an answer in time is unchanged"              t_an_answer_in_time_is_unchanged
finish
