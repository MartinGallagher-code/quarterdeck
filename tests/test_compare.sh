#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Martin J. Gallagher

# qd compare: N stored runs side by side -- the per-run summary, host by
# host, the drift rule, status flips, baselines, groups, CSV.

set -u
source "$(dirname "${BASH_SOURCE[0]}")/test_helper.bash"
# seed's runs are filed once and copied into each case that starts from them
use_fixtures

seed() {
    install_fake_ssh
    for h in a b c d; do fake_host "$h"; done
    printf 'a rack=r1\nb rack=r1\nc rack=r2\nd rack=r2\n' > hosts.txt
    put 10 20 30 40
    qdf run -q -s hosts.txt --name load -- cat v > /dev/null
    put 10 20 30 40
    qdf run -q -s hosts.txt --name load -- cat v > /dev/null
    put 10 25 30 40
    qdf run -q -s hosts.txt --name load -- cat v > /dev/null
}

put() {
    echo "$1" > "$FAKE_ROOT/a/v"; echo "$2" > "$FAKE_ROOT/b/v"
    echo "$3" > "$FAKE_ROOT/c/v"; echo "$4" > "$FAKE_ROOT/d/v"
}

t_last_n_runs_one_column() {
    fixture seed seed
    qd_rc compare load --last 3 -c A > out
    out="$(cat out)"
    # a change is a finding, as in diff
    assert_status "$QD_RC" 1
    assert_contains "$out" "3 runs, A by host"
    assert_contains "$out" "R1"
    assert_contains "$out" "R3"
    assert_contains "$out" "1 of 4 keys changed"
    assert_contains "$out" "R3 drift +25.0%"
    assert_not_contains "$out" "R2 drift"
}

t_identical_runs_exit_zero() {
    fixture seed seed
    qd_rc compare latest~2 latest~1 -c A > out
    assert_status "$QD_RC" 0
    assert_contains "$(cat out)" "0 of 4 keys changed"
}

t_drift_threshold_and_baseline() {
    fixture seed seed
    qd_rc compare load --last 3 -c A --drift 30 > out
    assert_status "$QD_RC" 0
    # against the last run instead: the first two moved the other way
    qd_rc compare load --last 3 -c A --baseline latest > out
    assert_contains "$(cat out)" "baseline R3"
    assert_contains "$(cat out)" "R1 drift -20.0%"
}

t_status_flip_is_a_change() {
    fixture seed seed
    rm -rf "$FAKE_ROOT/d"
    qdf run -q -s hosts.txt --name load -- cat v > /dev/null || true
    qd_rc compare load --last 2 -c A > out
    assert_contains "$(cat out)" "R2 ok->unreachable"
    assert_contains "$(cat out)" "hosts_ok"
    assert_contains "$(cat out)" "3/4"
}

t_no_column_compares_every_median() {
    fixture seed seed
    out="$(qd compare load --last 3)" || true
    assert_contains "$out" "medians"
    assert_contains "$out" "A "
}

t_csv_is_the_wide_table() {
    fixture seed seed
    out="$(qd compare load --last 3 -c A --format csv)" || true
    assert_contains "$out" "host,R1,R2,R3,change_pct,flags"
    assert_contains "$out" "b,20,20,25,25.0,R3 drift +25.0%"
}

t_one_run_alone_is_refused() {
    install_fake_ssh
    fake_host a
    echo 1 > "$FAKE_ROOT/a/v"
    qdf run -q -S a --name once -- cat v > /dev/null
    qd_rc compare once 2> err
    assert_status "$QD_RC" 2
    assert_contains "$(cat err)" "only run"
}

# a command of several lines (a probe's) is its first line in the report
t_a_multi_line_command_is_one_line() {
    install_fake_ssh
    for h in a b; do fake_host "$h"; done
    printf 'a\nb\n' > hosts.txt
    cmd="$(printf 'echo n: 1\ntrue second_line_of_the_script')"
    qdf run -s hosts.txt -q --name ml -- "$cmd" > /dev/null
    qdf run -s hosts.txt -q --name ml -- "$cmd" > /dev/null
    out="$(qd compare ml --last 2)" || true
    assert_contains "$out" "echo n: 1"
    assert_not_contains "$out" "second_line_of_the_script"
}

# repeated keys reduce to a number: an --agg that gives words is refused
t_a_wordy_agg_is_refused() {
    install_fake_ssh
    for h in a b; do fake_host "$h"; echo "x: 1" > "$FAKE_ROOT/$h/f"; done
    printf 'a\nb\n' > hosts.txt
    qdf run -s hosts.txt -q --name w -- cat f > /dev/null
    qdf run -s hosts.txt -q --name w -- cat f > /dev/null
    qd_rc compare w --last 2 -c x --agg top 2> err
    assert_status "$QD_RC" 2
    assert_contains "$(cat err)" "one number"
}

# QD-036: two whole campaigns side by side
have_muster_c() {
    command -v muster > /dev/null 2>&1 || "$PY" -c 'import binnacle.muster' 2>/dev/null
}

# two campaigns over a..d (a part a rack); each host answers its
# ./m file, set per campaign: camp NAME a b c d [extra host's value]
camp() {
    local name=$1 h i=0
    shift
    for h in a b c d; do
        i=$((i + 1))
        fake_host "$h"
        printf 'mbps: %s\nrtt: %s\n' "${!i}" "$((100 + i))" > "$FAKE_ROOT/$h/m"
    done
    qd campaign new "$name" -s hosts.txt --by rack -- cat m > /dev/null
    qdf campaign run "$name" > /dev/null 2>&1
}

t_campaigns_side_by_side() {
    have_muster_c || { echo "  (no muster here: pip install binnacle)"; return 0; }
    install_fake_ssh
    printf 'a rack=r1\nb rack=r1\nc rack=r2\nd rack=r2\n' > hosts.txt
    camp before 1000 1000 1000 1000
    # c's bandwidth drops 10%
    camp after 1000 1000 900 1000
    qd_rc compare --campaigns before after --drift 5 --format csv > out
    assert_status "$QD_RC" 1
    out="$(cat out)"
    assert_contains "$out" "host,column,A,B,change_pct,flags"
    assert_contains "$out" "c,mbps,1000,900,-10.0,drift -10.0%"
    assert_contains "$out" "a,mbps,1000,1000,0.0,"
    assert_contains "$out" "c,rtt,103,103,0.0,"
    qd_rc compare --campaigns before after --drift 15 > out
    assert_status "$QD_RC" 0
    assert_contains "$(cat out)" "0 of 8 values moved past 15%, across 2 columns"
    assert_contains "$(cat out)" "A  before: 2 runs, 4 rows, 4 host"
    qd_rc compare --campaigns before after -c mbps > out
    assert_status "$QD_RC" 1
    assert_contains "$(cat out)" "1 of 4 values moved past 5%, across 1 column"
    # the same campaign against itself: nothing moved, exit 0
    qd_rc compare --campaigns after after > out
    assert_status "$QD_RC" 0
    assert_contains "$(cat out)" "0 of 8 values moved"
    # json too, the formats compare offers
    assert_contains "$(qd compare --campaigns before after --format json || true)" '"flags": "drift -10.0%"'
}

t_campaigns_only_in_one() {
    have_muster_c || { echo "  (no muster here: pip install binnacle)"; return 0; }
    install_fake_ssh
    printf 'a rack=r1\nb rack=r1\nc rack=r2\nd rack=r2\n' > hosts.txt
    camp one 1000 1000 1000 1000
    # B ran on e as well, and a part run again (retry) counts once
    fake_host e
    printf 'mbps: 1000\nrtt: 101\n' > "$FAKE_ROOT/e/m"
    printf 'a rack=r1\nb rack=r1\nc rack=r2\nd rack=r2\ne rack=r3\n' > hosts.txt
    qd campaign new two -s hosts.txt --by rack -- cat m > /dev/null
    qdf campaign run two > /dev/null 2>&1
    qd campaign retry two rack-r1 > /dev/null
    qdf campaign run two > /dev/null 2>&1
    qd_rc compare --campaigns one two --format csv > out
    assert_status "$QD_RC" 1
    assert_contains "$(cat out)" "e,mbps,,1000,,only in B"
    qd_rc compare --campaigns one two > out
    assert_contains "$(cat out)" "only in B: 1 host e"
    assert_contains "$(cat out)" "B  two: 3 runs, 5 rows"
    qd_rc compare --campaigns one nosuch 2> err
    assert_status "$QD_RC" 2
    assert_contains "$(cat err)" "no runs in campaign 'nosuch'"
    qd_rc compare --campaigns one two --baseline one 2> err
    assert_status "$QD_RC" 2
}

run_test "a wordy --agg is refused"                 t_a_wordy_agg_is_refused
run_test "a multi-line command is one line"           t_a_multi_line_command_is_one_line
run_test "--last N, one column: summary and drift"    t_last_n_runs_one_column
run_test "identical runs exit 0"                      t_identical_runs_exit_zero
run_test "--drift threshold, --baseline"              t_drift_threshold_and_baseline
run_test "ok -> unreachable is a change"              t_status_flip_is_a_change
run_test "no column: every numeric median"            t_no_column_compares_every_median
run_test "--format csv: host by run"                  t_csv_is_the_wide_table
run_test "one run alone is refused"                   t_one_run_alone_is_refused
run_test "campaigns: side by side"              t_campaigns_side_by_side
run_test "campaigns: only in one, retried parts" t_campaigns_only_in_one
finish
