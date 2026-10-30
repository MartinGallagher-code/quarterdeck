#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Martin J. Gallagher

# qd compare: N stored runs side by side -- the per-run summary, host by
# host, the drift rule, status flips, baselines, groups, CSV.

set -u
source "$(dirname "${BASH_SOURCE[0]}")/test_helper.bash"

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
    seed
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
    seed
    qd_rc compare latest~2 latest~1 -c A > out
    assert_status "$QD_RC" 0
    assert_contains "$(cat out)" "0 of 4 keys changed"
}

t_drift_threshold_and_baseline() {
    seed
    qd_rc compare load --last 3 -c A --drift 30 > out
    assert_status "$QD_RC" 0
    # against the last run instead: the first two moved the other way
    qd_rc compare load --last 3 -c A --baseline latest > out
    assert_contains "$(cat out)" "baseline R3"
    assert_contains "$(cat out)" "R1 drift -20.0%"
}

t_status_flip_is_a_change() {
    seed
    rm -rf "$FAKE_ROOT/d"
    qdf run -q -s hosts.txt --name load -- cat v > /dev/null || true
    qd_rc compare load --last 2 -c A > out
    assert_contains "$(cat out)" "R2 ok->unreachable"
    assert_contains "$(cat out)" "hosts_ok"
    assert_contains "$(cat out)" "3/4"
}

t_no_column_compares_every_median() {
    seed
    out="$(qd compare load --last 3)" || true
    assert_contains "$out" "medians"
    assert_contains "$out" "A "
}

t_csv_is_the_wide_table() {
    seed
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

run_test "a wordy --agg is refused"                 t_a_wordy_agg_is_refused
run_test "a multi-line command is one line"           t_a_multi_line_command_is_one_line
run_test "--last N, one column: summary and drift"    t_last_n_runs_one_column
run_test "identical runs exit 0"                      t_identical_runs_exit_zero
run_test "--drift threshold, --baseline"              t_drift_threshold_and_baseline
run_test "ok -> unreachable is a change"              t_status_flip_is_a_change
run_test "no column: every numeric median"            t_no_column_compares_every_median
run_test "--format csv: host by run"                  t_csv_is_the_wide_table
run_test "one run alone is refused"                   t_one_run_alone_is_refused
finish
