#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Martin J. Gallagher

# qd survey (QD-060): qd probe facts inventory, then one screen of the
# values most hosts share, who differs, who is far from the median and
# who did not answer -- on the fake fleet, with a real provost.

set -u
source "$(dirname "${BASH_SOURCE[0]}")/test_helper.bash"

# A uname that answers -r from the fake host's ./kernel when it has one,
# and a binnacle whose why-slow --facts answers from the host's
# ./facts.json: one odd kernel, and one odd reading, wherever wanted.
stand_ins() {
    mkdir -p "$TEST_TMPDIR/unamebin" "$TEST_TMPDIR/py/binnacle"
    cat > "$TEST_TMPDIR/unamebin/uname" <<SH
#!/bin/sh
if [ "\$1" = -r ] && [ -f ./kernel ]; then exec cat ./kernel; fi
exec $(command -v uname) "\$@"
SH
    chmod +x "$TEST_TMPDIR/unamebin/uname"
    : > "$TEST_TMPDIR/py/binnacle/__init__.py"
    cat > "$TEST_TMPDIR/py/binnacle/why_slow.py" <<'PY'
import sys
with open("facts.json") as f:
    sys.stdout.write(f.read())
PY
}

# facts HOST MEM_AVAILABLE_PCT: why-slow's readings, as the demo's
facts() {
    printf '{"cpu.busy_pct": 40.0, "cpu.count": 64, "mem.available_pct": %s, "mem.total_kb": 527958076, "sys.kernel": "x"}\n' \
        "$2" > "$FAKE_ROOT/$1/facts.json"
}

# fleet N: hosts h01..hN, rack r1, every one alike
fleet() {
    local i h
    install_fake_ssh
    stand_ins
    : > hosts.txt
    for i in $(seq 1 "$1"); do
        h="$(printf 'h%02d' "$i")"
        fake_host "$h"
        facts "$h" "7$((i % 3))"
        printf '%s rack=r1\n' "$h" >> hosts.txt
    done
}

# the fake ssh by QD_SSH, not --ssh: the probe command the survey prints
# under WHAT TO DO NEXT is its own command line
survey() {
    PATH="$TEST_TMPDIR/unamebin:$PATH" PYTHONPATH="$TEST_TMPDIR/py" \
        QD_SSH="$FAKE_BIN/ssh" QD_SCP="$FAKE_BIN/scp" qd_rc survey "$@"
}

# the commands under WHAT TO DO NEXT, one a line
next_cmds() {
    sed -n '/WHAT TO DO NEXT/,$p' "$1" | sed -n 's/^    \* \(qd .*\)$/\1/p' |
        sed 's/   *[^ ].*$//; s/  .*//'
}

t_the_odd_ones_are_named() {
    fleet 5
    printf '6.5.0-41-generic\n' > "$FAKE_ROOT/h05/kernel"
    facts h04 12
    rm -rf "$FAKE_ROOT/h03"; fake_host_unreachable h03
    survey -s hosts.txt > out 2> err
    assert_status "$QD_RC" 1
    out="$(cat out)"
    assert_contains "$out" "qd survey -- 5 hosts asked facts and inventory (8 probes)"
    assert_contains "$out" "WHAT MOST HOSTS SAY"
    # the odd kernel, against what the rest of its rack runs
    assert_contains "$out" "h05              kernel 6.5.0-41-generic (most in rack r1: "
    # the numeric outlier, by median and MAD
    assert_contains "$out" "h04              mem.available_pct 12 (median 7"
    # the host that did not answer, and why
    assert_contains "$out" "DID NOT ANSWER"
    assert_contains "$out" "h03              unreachable: "
    # which step found what
    assert_contains "$out" "FOUND  1 host did not answer (qd probe)
         1 host differs (qd outliers --categorical)
         1 value far from the median (qd outliers)"
    assert_contains "$out" "* qd show os --where 'status!=ok'"
    assert_not_contains "$out" "skipped"
    # blank is not measured: h03 is counted in no "of N"
    assert_contains "$out" "of 4"
    assert_not_contains "$out" "of 5"
}

# what it files is what qd probe facts inventory files: the same runs, by
# the same names, of the same hosts and columns
t_it_files_what_probe_files() {
    fleet 3
    survey -s hosts.txt > out
    assert_status "$QD_RC" 0
    assert_contains "$(cat out)" "FOUND  nothing: every host answered, and none stands out"
    PATH="$TEST_TMPDIR/unamebin:$PATH" PYTHONPATH="$TEST_TMPDIR/py" \
        qdf_rc probe facts inventory -s hosts.txt --store "$TEST_TMPDIR/plain" -q > /dev/null
    assert_status "$QD_RC" 0
    for p in facts os firmware disks mounts numa gpu packages; do
        a="$(qd show "$p" --cols host,status --format csv)"
        b="$(qd show "$p" --cols host,status --format csv --store "$TEST_TMPDIR/plain")"
        assert_eq "$a" "$b"
        assert_eq "$(qd show "$p" --format csv | head -1)" \
            "$(qd show "$p" --format csv --store "$TEST_TMPDIR/plain" | head -1)"
    done
    assert_eq "$(qd log | grep -c 'probe')" "$(qd log --store "$TEST_TMPDIR/plain" | grep -c 'probe')"
}

# binnacle not installed here: facts is skipped and said, the rest runs
t_binnacle_missing_is_a_skip() {
    fleet 3
    # a binnacle without why-slow ahead of any real one: not installed
    mkdir -p nobin/binnacle
    : > nobin/binnacle/__init__.py
    PATH="$TEST_TMPDIR/unamebin:$PATH" PYTHONPATH="$PWD/nobin" \
        QD_SSH="$FAKE_BIN/ssh" QD_SCP="$FAKE_BIN/scp" \
        qd_rc survey -s hosts.txt > out 2> err
    assert_status "$QD_RC" 0
    out="$(cat out)"
    assert_contains "$out" "qd survey -- 3 hosts asked inventory (7 probes)"
    assert_contains "$out" "skipped  facts: not installed here ("
    assert_contains "$out" "pip install binnacle"
    assert_not_contains "$out" "mem.available_pct"
    assert_contains "$out" "* qd probe inventory -s hosts.txt"
    qd_rc show facts > /dev/null 2>&1
    assert_status "$QD_RC" 2
    assert_contains "$(qd show os --cols host,status --format csv)" "h03,ok"
}

# no hosts named: this machine, and nothing to compare it against
t_no_hosts_is_this_machine() {
    qd_rc survey > out 2> err
    assert_status "$QD_RC" 0
    out="$(cat out)"
    assert_contains "$out" "qd survey -- 1 host asked"
    assert_contains "$out" "ONE HOST  nothing to compare it against"
    assert_contains "$out" "qd demo"
    assert_not_contains "$out" "WHO DIFFERS"
    assert_contains "$(cat err)" "no hosts named, so the fleet is this machine"
    # facts too where binnacle is installed (CI), and it ran here
    assert_contains "$out" "* qd probe "
    assert_contains "$out" "inventory  "
    assert_contains "$(qd show os --cols host,status --format csv)" ",ok"
}

# every command under WHAT TO DO NEXT parses, and the read ones run
t_every_next_step_parses_and_runs() {
    fleet 4
    printf '6.5.0-41-generic\n' > "$FAKE_ROOT/h02/kernel"
    facts h01 5
    survey -s hosts.txt > out
    assert_status "$QD_RC" 1
    next_cmds out > cmds
    assert_eq "$(wc -l < cmds | tr -d ' ')" "4"
    assert_contains "$(cat cmds)" "qd probe facts inventory -s hosts.txt"
    assert_contains "$(cat cmds)" "qd freq os kernel"
    assert_contains "$(cat cmds)" "qd outliers os os,kernel --categorical"
    assert_contains "$(cat cmds)" "qd outliers facts mem.available_pct"
    "$PY" - "$QD_DIR" cmds <<'PY'
import shlex, sys
sys.path.insert(0, sys.argv[1])
from quarterdeck import cli
parser, _ = cli.build_parser()
for line in open(sys.argv[2]):
    parser.parse_args(shlex.split(line)[1:])
PY
    while IFS= read -r c; do
        case "$c" in "qd probe "*) continue ;; esac
        eval "qd_rc ${c#qd }" > ran 2>&1
        [ "$QD_RC" -le 1 ] || fail "$c: exit $QD_RC: $(cat ran)"
    done < cmds
    # what the summary named, the plain commands name too
    assert_contains "$(qd outliers facts mem.available_pct)" "h01"
    assert_contains "$(qd freq os kernel)" "h02"
    # --store is carried into them
    survey -s hosts.txt --store "$TEST_TMPDIR/other" > out
    next_cmds out > cmds
    assert_contains "$(cat cmds)" "qd freq os kernel --store $TEST_TMPDIR/other"
}

# any fleet: one screen, each section naming a few and counting the rest
t_one_screen_for_any_fleet() {
    fleet 16
    for h in h01 h02 h03 h04; do
        printf '5.%s.0-odd\n' "${h#h}" > "$FAKE_ROOT/$h/kernel"
    done
    for h in h05 h06 h07 h08; do facts "$h" 3; done
    for h in h09 h10 h11 h12; do rm -rf "${FAKE_ROOT:?}/$h"; fake_host_unreachable "$h"; done
    survey -s hosts.txt > out
    assert_status "$QD_RC" 1
    n="$(wc -l < out | tr -d ' ')"
    [ "$n" -le 40 ] || fail "$n lines: $(cat out)"
    # four of each, three named: differs, outliers, did not answer
    assert_eq "$(grep -c '^    \.\.\. and 1 more' out)" "3"
    assert_eq "$(grep -c '^    \.\.\. and 1 more host$' out)" "2"
    # the summary, before the commands (which are as long as typed)
    sed '/WHAT TO DO NEXT/,$d' out | awk 'length > 100 { exit 1 }' ||
        fail "a line past 100 columns: $(cat out)"
}

t_usage_errors_exit_2() {
    qd_rc survey --every 5 -S a 2> err
    assert_status "$QD_RC" 2
    assert_contains "$(cat err)" "qd survey asks once"
    qd_rc survey --nosuch 2> err
    assert_status "$QD_RC" 2
    qd_rc survey nosuch-host 2> err
    assert_status "$QD_RC" 2
    # --dry-run: what would run, and no summary
    install_fake_ssh
    fake_host a
    qdf_rc survey -S a --dry-run > out 2>&1
    assert_status "$QD_RC" 0
    assert_not_contains "$(cat out)" "WHAT MOST HOSTS SAY"
}

t_the_card_and_hints_name_it() {
    assert_contains "$(qd --help)" "qd survey [HOSTS]"
    assert_contains "$(qd)" "qd survey "
    assert_contains "$(qd hints)" "qd survey -s hosts.txt"
    assert_contains "$(qd help survey)" "usage: qd survey"
}

run_test "the odd kernel, outlier and silent host"     t_the_odd_ones_are_named
run_test "it files what qd probe facts inventory does" t_it_files_what_probe_files
run_test "binnacle missing: facts skipped, said"       t_binnacle_missing_is_a_skip
run_test "no hosts named: this machine, qd demo"       t_no_hosts_is_this_machine
run_test "every next step parses, and the reads run"   t_every_next_step_parses_and_runs
run_test "one screen for any fleet"                    t_one_screen_for_any_fleet
run_test "usage errors exit 2"                         t_usage_errors_exit_2
run_test "qd --help, hints and help name it"           t_the_card_and_hints_name_it
finish
