#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Martin J. Gallagher

# What a host's login shell prints before the command (QD-038).  sshd runs
# a command through the user's login shell, which reads ~/.bashrc (or
# /etc/bash.bashrc, ~/.zshenv, conda's init) first; a greeting or a
# setlocale warning from there came back as part of the answer, so a table
# was filed as lines and the error column held the warning.  qd now sends
# a start line ahead of the command and cuts what came before it: kept in
# qd.hosts' preamble column, never filed as the answer.  FAKE_SSH_RC is the
# fake host's ~/.bashrc.  The launchers are in test_via.sh, the probes in
# test_probe.sh, and a real sshd and bash in test_ssh.sh.

set -u
source "$(dirname "${BASH_SOURCE[0]}")/test_helper.bash"

# n02's login shell greets, and warns on stderr; n01's says nothing
chatty_rc() {
    cat > rc <<'EOF'
[ "$FAKE_HOST" = n02 ] || return 0
echo "Welcome to n02 -- scheduled maintenance Friday"
echo "bash: warning: setlocale: LC_ALL: cannot change locale (en_US.UTF-8)" >&2
EOF
    export FAKE_SSH_RC="$PWD/rc"
}

seed() {
    install_fake_ssh
    fake_host n01
    fake_host n02
    chatty_rc
}

# a column of one host's row in a run's qd.hosts
host_cell() {
    qd show "$1:hosts" --where "host=$2" --cols "$3" --format csv |
        tail -n +2
}

# fleet.Runner on one fake host, for what the CLI cannot show: every byte
# of an answer.  argv: PKGDIR; CASE_CMD is the command, with @START@ and
# @MARK@ standing for this run's start and group lines; prints the Result
# as JSON.
write_driver() {
    cat > "$TEST_TMPDIR/drive.py" <<'EOF'
import json, os, sys
sys.path.insert(0, sys.argv[1])
from quarterdeck import fleet
from quarterdeck.hosts import Host

r = fleet.Runner(ssh=os.environ.get("CASE_SSH", os.environ["FAKE_BIN"] + "/ssh"),
                 scp=os.environ["FAKE_BIN"] + "/scp",
                 timeout=float(os.environ.get("CASE_TIMEOUT", "30")),
                 max_output=int(os.environ.get("CASE_MAX", "4194304")),
                 keep_preamble=os.environ.get("CASE_KEEP") == "1")
cmd = os.environ["CASE_CMD"].replace("@START@", r.start).replace(
    "@MARK@", r.mark)
x = r.run_one(Host("n01", "n01"), cmd)
# each run's id is its own: RUNID, so two runs' answers can be compared
print(json.dumps(dict((k, v.replace(r.run_id, "RUNID") if k != "rc" else v)
                      for k, v in (("outcome", x.outcome), ("rc", int(x.rc)),
                                   ("out", x.stdout), ("err", x.stderr),
                                   ("pre", x.preamble))), sort_keys=True))
EOF
}

drive() { "$PY" "$TEST_TMPDIR/drive.py" "$QD_DIR"; }

# one field of drive's JSON, as it is
field() { "$PY" -c 'import json, sys; sys.stdout.write(json.load(open(sys.argv[1]))[sys.argv[2]])' "$1" "$2"; }

setup_driver() {
    install_fake_ssh
    fake_host n01
    write_driver
}

# -- the run: the answer, the error, the column, the note ----------------------

t_a_greeting_is_cut_from_a_table_and_json() {
    seed
    qdf run -S n01,n02 -- "printf 'cpus\tmhz\n64\t2400\n'" > out 2> err
    # both hosts' answers read as the table they are, not as lines
    assert_contains "$(cat out)" "[provost: printf: cpus, mhz]"
    assert_eq "$(qd show latest --cols host,cpus,mhz --format csv)" \
        "$(printf 'host,cpus,mhz\nn01,64,2400\nn02,64,2400')"
    assert_contains "$(host_cell latest n02 preamble)" "Welcome to n02"
    assert_contains "$(host_cell latest n02 preamble)" "setlocale"
    assert_not_contains "$(host_cell latest n01 preamble)" "Welcome"
    # why-slow --facts' shape: JSON, read as JSON
    qdf run -S n01,n02 -q -- \
        "printf '{\"cpu\": {\"count\": 8}, \"load\": 0.5}\n'" > /dev/null
    assert_eq "$(qd show latest --cols host,cpu.count,load --format csv)" \
        "$(printf 'host,cpu.count,load\nn01,8,0.5\nn02,8,0.5')"
}

t_the_error_column_is_the_commands_own() {
    seed
    qdf_rc run -S n01,n02 -q -- 'ls /nonexistent-dir' > /dev/null 2>&1
    assert_status "$QD_RC" 1
    err="$(host_cell latest n02 error)"
    assert_contains "$err" "ls: cannot access"
    assert_not_contains "$err" "setlocale"
    assert_not_contains "$(host_cell latest n02 stderr)" "setlocale"
    assert_contains "$(host_cell latest n02 preamble)" "setlocale"
    # the run's summary names the same error
    qdf_rc run -S n02 -- 'ls /nonexistent-dir' > out 2> /dev/null
    assert_contains "$(cat out)" "ls: cannot access"
    assert_not_contains "$(cat out)" "setlocale"
}

t_the_run_says_once_where_it_is() {
    seed
    qdf run -S n01,n02 --count 2 --every 0.1 -q -- true > /dev/null 2> err
    assert_eq "$(grep -c 'login shell printed' err)" "1"
    id="$(qd log latest | sed -n '1s/ .*//p')"
    assert_contains "$(cat err)" "on 1 host (n02): cut from the answers, kept in the preamble column (qd show $id:hosts)"
    # every pass's row has it
    assert_eq "$(qd show latest:hosts --cols host,pass --where 'preamble~Welcome' --format csv | tail -n +2)" \
        "$(printf 'n02,1\nn02,2')"
    # a run where no shell printed says nothing new, and its hosts table
    # has no preamble column
    unset FAKE_SSH_RC
    qdf run -S n01,n02 -q -- true > /dev/null 2> err
    assert_eq "$(cat err)" ""
    assert_not_contains "$(qd show latest:hosts --format csv | head -n 1)" "preamble"
}

# A quiet host: the same answer, row and exit status as with
# --keep-preamble, which sends no start line (0.22.0's way)
t_a_quiet_host_is_as_it_was() {
    install_fake_ssh
    fake_host n01
    for opt in "" --keep-preamble; do
        # shellcheck disable=SC2086  # an option or none
        qdf_rc run -S n01 -q $opt -- \
            "printf 'a\tb\n1\t2\n'; printf 'oops\n' >&2; exit 3" > /dev/null
        echo "$QD_RC" > "rc$opt.txt"
        qd show latest:hosts --cols host,status,rc,bytes,error,stderr \
            --format csv > "rows$opt.csv"
        qd show latest --cols host,status,a,b --format csv > "data$opt.csv"
        # the answer as provost keeps it, every byte, less qd's prologue
        cap="$(qd show latest --cols capture --format csv | tail -n 1)"
        grep -v '^#%' "$QD_STORE/captures/$cap/output.txt" > "capture$opt.txt"
    done
    cmp "capture.txt" "capture--keep-preamble.txt" ||
        fail "the captures differ: $(cat capture.txt)"
    assert_contains "$(cat capture.txt)" "$(printf 'a\tb')"
    assert_eq "$(cat rc.txt)" "$(cat rc--keep-preamble.txt)"
    assert_eq "$(cat rows.csv)" "$(cat rows--keep-preamble.csv)"
    assert_eq "$(cat data.csv)" "$(cat data--keep-preamble.csv)"
    assert_contains "$(cat rows.csv)" "n01,failed,3,8,oops,"
}

t_keep_preamble_keeps_it_in() {
    seed
    qdf run -S n01,n02 --keep-preamble -- "printf 'cpus\tmhz\n64\t2400\n'" \
        > out 2> err
    # as before 0.23.0: n02's answer is filed greeting and all, and is not
    # read as the table (how it is read instead is provost's own: 2.1.0
    # and 2.24.0 differ)
    cap="$(qd show latest --cols host,capture --format csv |
        awk -F, '$1 == "n02" { print $2; exit }')"
    assert_contains "$(cat "$QD_STORE/captures/$cap/output.txt")" \
        "Welcome to n02"
    assert_not_contains "$(qd show latest --cols host,cpus --format csv)" \
        "n02,64"
    assert_not_contains "$(cat err)" "login shell"
    assert_eq "$(host_cell latest n02 preamble)" ""
    QD_KEEP_PREAMBLE=1 qdf_rc run -S n02 -q -- 'ls /nonexistent-dir' \
        > /dev/null 2> err
    assert_contains "$(host_cell latest n02 error)" "setlocale"
    assert_not_contains "$(cat err)" "login shell"
}

t_dry_run_and_no_store() {
    seed
    out="$(qdf run -S n01,n02 --dry-run -- uptime)"
    assert_not_contains "$out" ".start"
    assert_not_contains "$out" ".pgid"
    assert_contains "$out" " n02 uptime"
    qdf run -S n01,n02 --no-store -- "printf 'cpus\n8\n'" > out 2> err
    assert_contains "$(cat err)" "on 1 host (n02): cut from the answers, not kept (--no-store)"
    assert_not_contains "$(cat out)" "Welcome"
}

# -- the same through every way a run reaches a host --------------------------

t_a_pushed_script_and_a_failed_push() {
    seed
    printf '#!/bin/sh\nprintf "cpus\\tmhz\\n64\\t2400\\n"\n' > probe.sh
    qdf run -S n01,n02 --script probe.sh --remote-dir rd -q > /dev/null
    assert_eq "$(qd show latest --cols host,cpus --format csv)" \
        "$(printf 'host,cpus\nn01,64\nn02,64')"
    assert_contains "$(host_cell latest n02 preamble)" "Welcome"
    # cleaned up, through the same start line
    assert_eq "$(ls -A "$FAKE_ROOT/n02/rd")" ""
    # a push that fails: the error is mkdir's own, not the greeting
    printf 'a file\n' > "$FAKE_ROOT/n02/afile"
    qdf_rc run -S n02 --script probe.sh --remote-dir afile -q > /dev/null 2>&1
    assert_status "$QD_RC" 1
    assert_eq "$(host_cell latest n02 status)" "push-failed"
    err="$(host_cell latest n02 error)"
    assert_contains "$err" "mkdir"
    assert_not_contains "$err" "setlocale"
    assert_contains "$(host_cell latest n02 preamble)" "Welcome"
}

t_sudo_reuse_retries_and_passes() {
    seed
    cat > "$FAKE_BIN/sudo" <<'EOF'
#!/bin/sh
# sudo -n sh -c CMD, as the fake host's user; it says so on stderr
echo "sudo: a stand-in" >&2
shift
exec "$@"
EOF
    chmod +x "$FAKE_BIN/sudo"
    export PATH="$FAKE_BIN:$PATH"
    table="printf 'cpus\tmhz\n8\t1\n'"
    qdf run -S n01,n02 --sudo -q -- "$table" > /dev/null
    assert_eq "$(qd show latest --cols host,cpus --format csv)" \
        "$(printf 'host,cpus\nn01,8\nn02,8')"
    # what sudo says comes after the start line: it is the command's
    assert_contains "$(host_cell latest n02 stderr)" "sudo: a stand-in"
    assert_not_contains "$(host_cell latest n02 preamble)" "sudo"
    export TMPDIR="$TEST_TMPDIR/t"
    mkdir -p "$TMPDIR"
    qdf run -S n01,n02 --reuse -q -- "$table" > /dev/null
    assert_eq "$(qd show latest --cols host,cpus --format csv)" \
        "$(printf 'host,cpus\nn01,8\nn02,8')"
    fake_host_unreachable n09
    qdf_rc run -S n02,n09 --retries 1 -q -- "$table" > /dev/null 2>&1
    assert_contains "$(qd show latest --cols host,cpus --format csv)" "n02,8"
    assert_contains "$(qd show latest:hosts --cols host,attempt,status --format csv)" "n09,2,unreachable"
    qdf run -S n02 --count 2 --every 0.1 -q -- "$table" > /dev/null
    assert_eq "$(qd show latest --cols host,pass,cpus --format csv)" \
        "$(printf 'host,pass,cpus\nn02,1,8\nn02,2,8')"
}

# QD-026's stop still finds the command's group, from the start line
t_a_timeout_is_still_stopped_on_the_host() {
    seed
    export FAKE_SSH_DETACH=1
    qdf_rc run -S n02 --timeout 1 -q -- 'sleep 3; touch MARK' > out 2>&1
    assert_status "$QD_RC" 1
    assert_contains "$(host_cell latest n02 error)" "qd stopped it on the host"
    assert_contains "$(host_cell latest n02 preamble)" "Welcome"
    sleep 3.5
    assert_no_file "$FAKE_ROOT/n02/MARK"
}

# -- every byte of an answer ----------------------------------------------------

# Whatever a command prints is kept whole: text like this run's own start
# and group lines, a first line of `#%`, nothing at all, bytes that are not
# UTF-8, a last line with no newline, pieces with pauses between them.
# Each comes back the same as with --keep-preamble, and none of it is cut.
t_the_commands_own_output_is_never_cut() {
    setup_driver
    for c in \
        "printf 'a\\tb\\n1\\t2\\n'" \
        "true" \
        "printf 'no newline'" \
        "printf '#%% run: x\\nv\\n'" \
        "printf '\\377\\376 not utf-8\\n'; printf '\\377 err\\n' >&2" \
        "printf '\\n@START@\\n'; printf '\\n@MARK@ 1 1\\n' >&2; echo after" \
        "echo @START@; echo @MARK@ 7 7 >&2" \
        "printf a; sleep 0.3; printf 'b\\n'; sleep 0.3; printf c >&2; sleep 0.2; printf d"; do
        CASE_CMD="$c" drive > cut.json
        CASE_CMD="$c" CASE_KEEP=1 drive > kept.json
        assert_eq "$(cat cut.json)" "$(cat kept.json)"
        assert_eq "$(field cut.json pre)" ""
    done
    CASE_CMD="echo @START@; echo @MARK@ 7 7 >&2" drive > cut.json
    assert_contains "$(field cut.json out)" ".start"
    assert_contains "$(field cut.json err)" ".pgid 7 7"
    CASE_CMD="printf 'no newline'" drive > cut.json
    assert_eq "$(field cut.json out)" "no newline"
}

t_a_preamble_is_cut_exactly() {
    setup_driver
    # a greeting with no newline at its end, on both streams
    printf '%s\n' "printf 'Welcome'" "printf 'warned' >&2" > rc
    export FAKE_SSH_RC="$PWD/rc"
    CASE_CMD="printf 'cpus\\tmhz\\n64\\t2400\\n'; printf 'own\\n' >&2" drive > r.json
    assert_eq "$(field r.json out)" "$(printf 'cpus\tmhz\n64\t2400')"
    assert_eq "$(field r.json err)" "own"
    assert_eq "$(field r.json pre)" "$(printf 'Welcome\nwarned')"
    # blank lines are the shell's too, and an answer that starts blank
    # keeps its blank line
    printf '%s\n' "echo" "echo hi" "echo" > rc
    CASE_CMD="printf '\\nx\\n'" drive > r.json
    "$PY" -c 'import json, sys; d = json.load(open(sys.argv[1])); assert d["out"] == "\nx\n", d; assert d["pre"] == "\nhi\n\n", d' r.json
    # with --keep-preamble, as before: all of it in the answer
    printf '%s\n' "echo Welcome" > rc
    CASE_KEEP=1 CASE_CMD="echo answer" drive > r.json
    assert_eq "$(field r.json out)" "$(printf 'Welcome\nanswer')"
    assert_eq "$(field r.json pre)" ""
}

# No start line, no cut: a startup file that exec's something else, or
# exits, never lets the command start; everything it said is kept
t_no_start_line_no_cut() {
    setup_driver
    export FAKE_SSH_RC="$PWD/rc"
    printf '%s\n' 'echo greeting' 'exec echo hijacked' > rc
    CASE_CMD="echo answer" drive > r.json
    assert_eq "$(field r.json outcome)" "ok"
    assert_eq "$(field r.json out)" "$(printf 'greeting\nhijacked')"
    assert_eq "$(field r.json pre)" ""
    printf '%s\n' 'echo bye' 'echo going >&2' 'exit 3' > rc
    CASE_CMD="echo answer" drive > r.json
    assert_eq "$(field r.json outcome)" "failed"
    assert_eq "$(field r.json out)" "bye"
    assert_eq "$(field r.json err)" "going"
    assert_eq "$(field r.json pre)" ""
}

# Past 64 KiB before the start line: nothing is cut, and the stream is as
# it came, less the line itself -- stdout the same as --keep-preamble's
# (whose own late group line, 0.22.0's, stays in its stderr)
t_past_64k_nothing_is_cut() {
    setup_driver
    export FAKE_SSH_RC="$PWD/rc"
    # shellcheck disable=SC2016  # for the fake host's shell
    printf '%s\n' 'head -c 70000 /dev/zero | tr "\0" x; echo' \
        'head -c 70000 /dev/zero | tr "\0" y >&2; echo >&2' > rc
    CASE_CMD="echo answer; echo own >&2" drive > cut.json
    CASE_KEEP=1 CASE_CMD="echo answer; echo own >&2" drive > kept.json
    assert_eq "$(field cut.json out)" "$(field kept.json out)"
    assert_eq "$(field cut.json pre)" ""
    out="$(field cut.json out)"
    assert_eq "${#out}" "$((70000 + 1 + 6))"
    assert_not_contains "$out" "RUNID"
    err="$(field cut.json err)"
    assert_eq "${#err}" "$((70000 + 1 + 3))"
    assert_not_contains "$err" "RUNID"
}

# The preamble is held outside --max-output: a long greeting does not
# make a short answer too much
t_the_preamble_is_not_counted_as_output() {
    setup_driver
    export FAKE_SSH_RC="$PWD/rc"
    printf '%s\n' 'head -c 1000 /dev/zero | tr "\0" x; echo' > rc
    CASE_MAX=200 CASE_CMD="echo answer" drive > r.json
    assert_eq "$(field r.json outcome)" "ok"
    assert_eq "$(field r.json out)" "answer"
    pre="$(field r.json pre)"
    assert_eq "${#pre}" "1000"
    # past it, the answer is too much, as ever, and still stopped
    CASE_MAX=200 CASE_CMD="head -c 1000 /dev/zero" drive > r.json
    assert_contains "$(field r.json err)" "output exceeded --max-output"
}

# An ssh that hands each stream on a byte at a time: the start line comes
# across many reads, and is still found
t_a_start_line_across_many_reads() {
    setup_driver
    cat > "$FAKE_BIN/slowssh" <<'EOF'
#!/usr/bin/env python3
import os, subprocess, sys, threading, time
p = subprocess.Popen([os.environ["FAKE_BIN"] + "/ssh"] + sys.argv[1:],
                     stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                     stdin=subprocess.DEVNULL)
def relay(src, fd):
    while True:
        b = src.read(1)
        if not b:
            break
        os.write(fd, b)
        time.sleep(0.002)
ts = [threading.Thread(target=relay, args=(p.stdout, 1)),
      threading.Thread(target=relay, args=(p.stderr, 2))]
for t in ts:
    t.start()
for t in ts:
    t.join()
sys.exit(p.wait())
EOF
    chmod +x "$FAKE_BIN/slowssh"
    printf '%s\n' 'echo Welcome' 'echo warned >&2' > rc
    export FAKE_SSH_RC="$PWD/rc"
    CASE_SSH="$FAKE_BIN/slowssh" CASE_CMD="printf 'cpus\\n8\\n'; echo own >&2" \
        drive > r.json
    assert_eq "$(field r.json out)" "$(printf 'cpus\n8')"
    assert_eq "$(field r.json err)" "own"
    assert_eq "$(field r.json pre)" "$(printf 'Welcome\nwarned')"
}

run_test "a greeting is cut from a table and from JSON"   t_a_greeting_is_cut_from_a_table_and_json
run_test "the error column is the command's own"          t_the_error_column_is_the_commands_own
run_test "the run says it once, and where it is"          t_the_run_says_once_where_it_is
run_test "a quiet host is as it was"                      t_a_quiet_host_is_as_it_was
run_test "--keep-preamble keeps it in"                    t_keep_preamble_keeps_it_in
run_test "--dry-run shows no marks; --no-store"           t_dry_run_and_no_store
run_test "--script, and a failed push's own error"        t_a_pushed_script_and_a_failed_push
run_test "--sudo, --reuse, --retries, passes"             t_sudo_reuse_retries_and_passes
run_test "a timeout is still stopped on the host"         t_a_timeout_is_still_stopped_on_the_host
run_test "the command's own output is never cut"          t_the_commands_own_output_is_never_cut
run_test "a preamble is cut exactly"                      t_a_preamble_is_cut_exactly
run_test "no start line, no cut"                          t_no_start_line_no_cut
run_test "past 64 KiB, nothing is cut"                    t_past_64k_nothing_is_cut
run_test "the preamble is not counted as output"          t_the_preamble_is_not_counted_as_output
run_test "a start line across many reads"                 t_a_start_line_across_many_reads

finish
