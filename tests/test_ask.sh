#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Martin J. Gallagher

# qd ask (QD-059): qd run, then qd freq latest A, in one step.  Against the
# fake fleet: every host agreeing, two answers, a host unreachable, an
# answer of several columns, the hosts that printed nothing, this machine
# when no hosts are named; its run is qd run's, through qd log; every
# command under WHAT TO DO NEXT parses; the exit status says which step
# found something.

set -u
source "$(dirname "${BASH_SOURCE[0]}")/test_helper.bash"

seed() {
    install_fake_ssh
    for h in node01 node02 node03; do fake_host "$h"; done
    echo "6.1.0-18" > "$FAKE_ROOT/node01/kernel"
    echo "6.1.0-18" > "$FAKE_ROOT/node02/kernel"
    echo "6.1.0-13" > "$FAKE_ROOT/node03/kernel"
    fake_host_unreachable node09
    printf 'node01 rack=r1\nnode02 rack=r1\nnode03 rack=r2\nnode09 rack=r2\n' \
        > hosts.txt
}

ask() { qdf_rc ask "$@"; }

# every "* qd ..." line under WHAT TO DO NEXT in FILE parses, as qd would
# parse it; prints each that does not, and "ok N" when all N do
next_steps_parse() {
    "$PY" - "$QD_DIR" "$1" <<'EOF'
import contextlib, io, re, shlex, sys
sys.path.insert(0, sys.argv[1])
from quarterdeck import cli
text = open(sys.argv[2]).read().split("WHAT TO DO NEXT", 1)[1]
cmds = [m.group(1) for m in re.finditer(r"^    \* (qd .*?)(?:  |$)", text,
                                        re.M)]
bad = []
for c in cmds:
    parser, _ = cli.build_parser()
    try:
        with contextlib.redirect_stderr(io.StringIO()):
            parser.parse_args(shlex.split(c)[1:])
    except SystemExit:
        bad.append(c)
print("\n".join(bad) if bad else "ok %d" % len(cmds))
EOF
}

t_every_host_agrees() {
    seed
    ask -S node01,node02 -- cat kernel > out
    assert_status "$QD_RC" 0
    out="$(cat out)"
    assert_contains "$out" "qd ask -- cat kernel: 2 hosts, 2 ok"
    assert_contains "$out" "ANSWERS  one answer from 2 hosts (column A)"
    assert_contains "$out" "2  6.1.0-18"
    assert_contains "$out" "node01 node02"
    assert_contains "$out" "ALIKE  all 2 hosts said the same"
    assert_not_contains "$out" "DID NOT ANSWER"
    assert_not_contains "$out" "NOT ALIKE"
    assert_contains "$out" "qd freq latest A"
    assert_contains "$out" "qd show latest "
    assert_contains "$out" "qd view latest"
    # qd odd for its three columns, and qd again, where qd run would
    # suggest them (QD-065)
    assert_eq "$(next_steps_parse out)" "ok 4"
    assert_contains "$out" "* qd odd latest"
    assert_contains "$out" "* qd again latest"
}

t_two_answers_most_common_first() {
    seed
    ask -S node01,node02,node03 -- cat kernel > out
    assert_status "$QD_RC" 1
    out="$(cat out)"
    assert_contains "$out" "ANSWERS  2 different answers from 3 hosts (column A)"
    # the most common first, each with its count and its hosts
    assert_eq "$(grep -n '6.1.0-18' out | cut -d: -f1)" \
        "$(($(grep -n '6.1.0-13' out | cut -d: -f1) - 2))"
    assert_contains "$out" "$(printf '    2  6.1.0-18\n       node01 node02\n    1  6.1.0-13\n       node03')"
    # which step found it
    assert_contains "$out" "NOT ALIKE  2 different answers (the count)"
    assert_not_contains "$out" "(the run)"
    # qd odd for its three columns, and qd again, where qd run would
    # suggest them (QD-065)
    assert_eq "$(next_steps_parse out)" "ok 4"
    assert_contains "$out" "* qd odd latest"
    assert_contains "$out" "* qd again latest"
}

t_a_host_unreachable() {
    seed
    echo "6.1.0-18" > "$FAKE_ROOT/node03/kernel"
    ask -s hosts.txt -- cat kernel > out
    assert_status "$QD_RC" 1
    out="$(cat out)"
    assert_contains "$out" "4 hosts, 3 ok, 1 unreachable"
    assert_contains "$out" "ANSWERS  one answer from 3 hosts"
    assert_contains "$out" "DID NOT ANSWER"
    assert_contains "$out" "node09  unreachable      ssh: connect to host node09 port 22: Connection timed out"
    assert_contains "$out" "NOT ALIKE  1 host did not answer (the run)"
    assert_not_contains "$out" "(the count)"
    assert_contains "$out" "qd show latest --where status!=ok"
    assert_contains "$out" "qd run --rerun latest -- ..."
    assert_eq "$(next_steps_parse out)" "ok 5"
    # a failed command is a host that did not answer, with its exit
    ask -S node01,node02 -- cat no-such-file > out
    assert_status "$QD_RC" 1
    assert_contains "$(cat out)" "failed (exit 1)"
    assert_contains "$(cat out)" "2 hosts did not answer (the run)"
}

t_both_steps_found_something() {
    seed
    ask -s hosts.txt -- cat kernel > out
    assert_status "$QD_RC" 1
    assert_contains "$(cat out)" \
        "NOT ALIKE  1 host did not answer (the run); 2 different answers (the count)"
}

t_several_columns_fall_back_to_the_run_summary() {
    seed
    for h in node01 node02; do printf 'a b c\n1 2 3\n' > "$FAKE_ROOT/$h/wide"; done
    ask -S node01,node02 -- cat wide > out
    assert_status "$QD_RC" 0
    out="$(cat out)"
    assert_contains "$out" "qd ask: the answer is 3 columns (a, b, c), not one value to count: qd run's summary instead"
    # qd run's summary: its preview table and its next steps
    assert_contains "$out" "qd ask -- cat wide: 2 hosts, 2 ok"
    assert_contains "$out" "node01  1  2  3"
    assert_not_contains "$out" "ANSWERS"
    # qd odd for its three columns, and qd again, where qd run would
    # suggest them (QD-065)
    assert_eq "$(next_steps_parse out)" "ok 4"
    assert_contains "$out" "* qd odd latest"
    assert_contains "$out" "* qd again latest"
    # still 1 when a host did not answer
    printf 'node01\nnode09\n' > two.txt
    ask -s two.txt -- cat wide > out
    assert_status "$QD_RC" 1
    assert_contains "$(cat out)" "DID NOT ANSWER"
}

t_printed_nothing_is_not_an_answer() {
    seed
    : > "$FAKE_ROOT/node02/kernel"
    ask -S node01,node02 -- cat kernel > out
    assert_status "$QD_RC" 1
    out="$(cat out)"
    assert_contains "$out" "ANSWERS  one answer from 2 hosts (column A)"
    assert_contains "$out" "$(printf '    1  6.1.0-18\n       node01\n    1  (printed nothing)\n       node02')"
    assert_contains "$out" "NOT ALIKE  1 host answered with nothing (the count)"
    # every host printing nothing is every host alike
    ask -S node01,node02,node03 -- true > out
    assert_status "$QD_RC" 0
    assert_contains "$(cat out)" "ANSWERS  3 hosts answered, and printed nothing"
    assert_contains "$(cat out)" "ALIKE  all 3 hosts answered, printing nothing"
    assert_eq "$(next_steps_parse out)" "ok 2"
}

t_a_long_host_list_is_cut_short() {
    install_fake_ssh
    for i in 01 02 03 04 05 06 07 08 09 10 11; do
        fake_host "n$i"
        echo same > "$FAKE_ROOT/n$i/v"
    done
    echo other > "$FAKE_ROOT/n11/v"
    ask -S 'n[01-11]' -- cat v > out
    assert_status "$QD_RC" 1
    out="$(cat out)"
    assert_contains "$out" "10  same"
    assert_contains "$out" "n01 n02 n03 n04 n05 n06 n07 n08 (+2 more)"
    assert_contains "$out" " 1  other"
    assert_contains "$out" "qd freq latest A --all-labels  the count above, as qd freq gives it, every host named"
    # qd odd for its three columns, and qd again, where qd run would
    # suggest them (QD-065)
    assert_eq "$(next_steps_parse out)" "ok 4"
    assert_contains "$out" "* qd odd latest"
    assert_contains "$out" "* qd again latest"
}

# the run qd ask files is the run qd run files: compared through qd log,
# the run's rows and its qd.runs row, ids, times and paths aside
t_its_run_is_qd_runs() {
    seed
    QD_STORE="$TEST_TMPDIR/by-run" qdf_rc run -s hosts.txt -- cat kernel > /dev/null
    assert_status "$QD_RC" 1
    QD_STORE="$TEST_TMPDIR/by-ask" ask -s hosts.txt -- cat kernel > /dev/null
    assert_status "$QD_RC" 1
    for s in by-run by-ask; do
        QD_STORE="$TEST_TMPDIR/$s" qd log latest |
            sed -e "s#$TEST_TMPDIR/$s#STORE#g" \
                -e 's/[0-9]\{8\}-[0-9]\{6\}/ID/g' \
                -e 's/[0-9-]*T[0-9:]*Z/TIME/g' |
            grep -v '^  took ' > "$s.log"
        QD_STORE="$TEST_TMPDIR/$s" qd show latest --format csv \
            --cols host,rack,status,rc,error,capture,A > "$s.rows"
        QD_STORE="$TEST_TMPDIR/$s" qd show ds:qd.runs --format csv \
            --cols kind,name,command,hosts,ok,failed,timeout,unreachable,captures,via,ssh_user,sudo,not_run,cwd \
            > "$s.runs"
        QD_STORE="$TEST_TMPDIR/$s" qd show latest:hosts --format csv \
            --cols host,rack,status,rc,bytes,error,stderr,capture > "$s.hosts"
    done
    assert_eq "$(cat by-ask.log)" "$(cat by-run.log)"
    assert_eq "$(cat by-ask.rows)" "$(cat by-run.rows)"
    assert_eq "$(cat by-ask.runs)" "$(cat by-run.runs)"
    assert_eq "$(cat by-ask.hosts)" "$(cat by-run.hosts)"
    assert_contains "$(cat by-ask.log)" "command   cat kernel"
    # one run each, and the same datasets in provost
    assert_eq "$(QD_STORE="$TEST_TMPDIR/by-ask" qd log | wc -l | tr -d ' ')" "2"
    assert_eq "$(QD_STORE="$TEST_TMPDIR/by-ask" qd show ds:cat --format csv --cols A)" \
        "$(QD_STORE="$TEST_TMPDIR/by-run" qd show ds:cat --format csv --cols A)"
}

t_no_hosts_is_this_machine() {
    install_fake_ssh
    me="$("$PY" -c 'import sys
sys.path.insert(0, sys.argv[1])
from quarterdeck.hosts import local_name
print(local_name())' "$QD_DIR")"
    qdf_rc ask -- echo hi > out 2> err
    assert_status "$QD_RC" 0
    assert_contains "$(cat out)" "qd ask -- echo hi: 1 host, 1 ok"
    assert_contains "$(cat out)" "$(printf '    1  hi\n       %s' "$me")"
    assert_contains "$(cat out)" "ALIKE  the one host answered"
    assert_contains "$(cat err)" "no hosts named, so the fleet is this machine, $me"
    assert_eq "$(qd show ds:qd.runs --cols via,hosts,ok --format csv | tail -n +2)" "local,1,1"
    # no ssh was started
    assert_eq "$(cat "$FAKE_SSH_ARGV")" ""
}

t_it_takes_run_s_host_options() {
    seed
    # --first, --name, and the safety options
    ask -s hosts.txt --first 2 --name kern -- cat kernel > out
    assert_status "$QD_RC" 0
    assert_contains "$(cat out)" "2 hosts, 2 ok"
    assert_contains "$(qd log latest)" "kern"
    : > "$FAKE_SSH_LOG"
    ask -s hosts.txt --dry-run -- cat kernel > out
    assert_status "$QD_RC" 0
    assert_eq "$(ssh_calls)" "0"
    ask -s hosts.txt --limit 2 -- cat kernel 2> err
    assert_status "$QD_RC" 2
    assert_contains "$(cat err)" "refusing to run on 4 hosts: --limit is 2"
    # --rerun: the host that did not answer in the last run, now back
    ask -s hosts.txt -- cat kernel > /dev/null
    rm "$FAKE_ROOT/node09/.unreachable"
    echo "6.1.0-18" > "$FAKE_ROOT/node09/kernel"
    ask --rerun latest -- cat kernel > out
    assert_status "$QD_RC" 0
    assert_contains "$(cat out)" "1 host, 1 ok"
    assert_contains "$(cat out)" "node09"
    # --retries and --max-fail, as qd run reads them
    ask -s hosts.txt --retries 1 --max-fail 5 --jobs 2 --timeout 30 -- cat kernel > out
    assert_status "$QD_RC" 1
    # --sudo and --via
    ask -S node01 --sudo --dry-run -- cat kernel > out
    assert_status "$QD_RC" 0
    assert_contains "$(cat out)" "sudo -n"
}

t_usage_errors_are_two() {
    seed
    ask -s hosts.txt 2> err
    assert_status "$QD_RC" 2
    assert_contains "$(cat err)" "qd ask --servers hosts.txt -- uptime"
    ask -s hosts.txt --bogus -- cat kernel 2> err
    assert_status "$QD_RC" 2
    ask -s hosts.txt --script no-such.sh 2> err
    assert_status "$QD_RC" 2
    assert_contains "$(cat err)" "no such script"
    # nothing was filed
    assert_contains "$(qd log 2>&1)" "no runs in the store"
}

t_on_the_card_and_in_the_hints() {
    assert_contains "$(qd --help)" "qd ask [HOSTS] [OPTIONS] -- COMMAND"
    assert_contains "$(qd hints)" "qd ask --servers hosts.txt -- uname -r"
    assert_contains "$(qd help ask)" "qd run, then qd freq latest A"
}

run_test "every host agrees: 0"                         t_every_host_agrees
run_test "two answers, most common first: 1"            t_two_answers_most_common_first
run_test "a host unreachable: listed, with why: 1"      t_a_host_unreachable
run_test "both steps found something: both named"       t_both_steps_found_something
run_test "several columns: qd run's summary, said so"   t_several_columns_fall_back_to_the_run_summary
run_test "printed nothing is not an answer"             t_printed_nothing_is_not_an_answer
run_test "a long host list is cut short"                t_a_long_host_list_is_cut_short
run_test "its run is qd run's, through qd log"          t_its_run_is_qd_runs
run_test "no hosts named: this machine"                 t_no_hosts_is_this_machine
run_test "it takes qd run's host options"               t_it_takes_run_s_host_options
run_test "usage errors exit 2"                          t_usage_errors_are_two
run_test "on qd --help and in qd hints"                 t_on_the_card_and_in_the_hints
finish
