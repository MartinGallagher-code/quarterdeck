#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Martin J. Gallagher

# qd changes: change points in each host's series of runs -- the statistic
# against the reference's own pinned values (tests/changes_unit.py), then
# over real runs in a store: a step at run k, a host too seldom measured,
# an outlier, a run a host missed, a peer group, CSV and JSON.

set -u
source "$(dirname "${BASH_SOURCE[0]}")/test_helper.bash"

unit() {
    local out
    out="$("$PY" "$QD_DIR/tests/changes_unit.py" "$QD_DIR" "$1")"
    assert_contains "$out" "ok"
}

t_unit_pinned() { unit pinned; }
t_unit_brute() { unit brute; }
t_unit_step() { unit step; }
t_unit_false_positives() { unit false_positives; }
t_unit_outlier() { unit outlier; }
t_unit_slide() { unit slide; }
t_unit_blanks() { unit blanks; }
t_unit_deterministic() { unit deterministic; }
t_unit_timing() { unit timing; }

# twelve runs of `load`: a steps from 100 to 80 at run 7; b holds at 50;
# c answers in three runs only; d holds at 70 but for one run of 140 (run
# 5) and one it did not answer (run 9)
A=(100 101 99 100 102 98 80 81 79 80 82 78)
B=(50 51 49 50 51 49 50 51 49 50 51 49)
D=(70 71 69 70 140 71 69 70 - 71 69 70)

seed() {
    install_fake_ssh
    for h in a b c d; do fake_host "$h"; done
    printf 'a sku=x\nb sku=x\nc sku=y\nd sku=y\n' > hosts.txt
    : > ids
    local i
    for i in 0 1 2 3 4 5 6 7 8 9 10 11; do
        echo "${A[$i]}" > "$FAKE_ROOT/a/v"
        echo "${B[$i]}" > "$FAKE_ROOT/b/v"
        case "$i" in
            0 | 5 | 11) echo 60 > "$FAKE_ROOT/c/v" ;;
            *) rm -f "$FAKE_ROOT/c/v" ;;
        esac
        if [ "${D[$i]}" = "-" ]; then
            rm -f "$FAKE_ROOT/d/v"
        else
            echo "${D[$i]}" > "$FAKE_ROOT/d/v"
        fi
        qdf run -q -s hosts.txt --name load -- cat v > /dev/null || true
        qd log latest | sed -n '1s/ .*//p' >> ids
    done
}

run_id() { sed -n "${1}p" ids; }

t_a_step_at_run_k() {
    seed
    qd_rc changes load -c A > out
    out="$(cat out)"
    # a change is a finding, as in compare
    assert_status "$QD_RC" 1
    assert_contains "$out" "12 runs"
    assert_contains "$out" "1 of 4 keys changed"
    # between the 6th run and the 7th, -20 %
    assert_contains "$out" "a     fell    $(run_id 6)"
    assert_contains "$out" "$(run_id 7)"
    assert_contains "$out" "-20.0%"
    assert_contains "$out" "no change: b, d"
    assert_contains "$out" "too few runs (under 5 measured): c (3)"
    assert_contains "$out" "not measured, left out of the series:"
    assert_contains "$out" "d in $(run_id 9)"
    assert_contains "$out" "qd diff $(run_id 6) $(run_id 7)"
}

t_csv_stretches() {
    out="$(qd changes load -c A --format csv)" || true
    assert_contains "$out" "host,status,stretch,first_run,last_run,runs,median,mad,change_pct,change_mads,change,reported,best_to_latest_pct,outliers,missing"
    assert_contains "$out" "a,changed,1,$(run_id 1),$(run_id 6),6,100,"
    assert_contains "$out" "a,changed,2,$(run_id 7),$(run_id 12),6,80,1,-20.0,"
    assert_contains "$out" ",fell,yes,-20.0,,"
    assert_contains "$out" "c,too few runs,,,,3,"
    # blank is not measured: d's series leaves run 9 out, and says so
    assert_contains "$out" "d,no change,1,$(run_id 1),$(run_id 12),11,70,"
    assert_contains "$out" ",$(run_id 9)"
    assert_not_contains "$out" "d,changed"
}

t_json_and_direction() {
    out="$(qd changes load -c A --format json --higher-is-better)" || true
    assert_contains "$out" '"change": "regression"'
    qd_rc changes load -c A --lower-is-better > out
    # with a direction, only a regression (or a slide) is a finding
    assert_status "$QD_RC" 0
    assert_contains "$(cat out)" "improvement"
}

t_last_n_and_too_few() {
    seed
    # the last four runs: too few for any host
    qd_rc changes load -c A --last 4 > out
    assert_status "$QD_RC" 0
    assert_contains "$(cat out)" "4 runs"
    assert_contains "$(cat out)" "0 of 4 keys changed"
    assert_contains "$(cat out)" "too few runs (under 5 measured): a (4), b (4)"
}

t_peer_groups() {
    qd peers define sku --by sku > /dev/null
    qd_rc changes load -c A --peers sku > out
    out="$(cat out)"
    assert_contains "$out" "each peer group of sku"
    assert_contains "$out" "1 of 2 peer groups changed"
    # x is a and b: its median falls from 75 to 65 at run 7
    assert_contains "$out" "x    fell    $(run_id 6)"
    assert_contains "$out" "-13.3%"
    out="$(qd changes load -c A --peers sku --format csv)" || true
    assert_contains "$out" "sku,status,stretch"
}

t_floor_and_usage() {
    # a 20 % step under a 25 % floor: listed, not reported
    qd_rc changes load -c A --min-change 25 > out
    assert_status "$QD_RC" 0
    assert_contains "$(cat out)" "0 of 4 keys changed"
    out="$(qd changes load -c A --min-change 25 --format csv)" || true
    assert_contains "$out" ",fell,no,"
    qd_rc changes load 2> err
    assert_status "$QD_RC" 2
    assert_contains "$(cat err)" "-c COL"
    qd_rc changes load -c A --p 2 2> err
    assert_status "$QD_RC" 2
    assert_contains "$(cat err)" "probability"
}

run_test "unit: the reference's pinned values"            t_unit_pinned
run_test "unit: t against every ordered pair"             t_unit_brute
run_test "unit: a known step is found at its run"         t_unit_step
run_test "unit: no step, false positives near p"          t_unit_false_positives
run_test "unit: one outlier run is not a change"          t_unit_outlier
run_test "unit: small steps add up to a slide"            t_unit_slide
run_test "unit: blanks left out, too few runs said"       t_unit_blanks
run_test "unit: the same answer every time"               t_unit_deterministic
run_test "unit: 100 runs under a second"                  t_unit_timing
# twelve runs take a while to file: each store is seeded once and read
# several ways
t_one_store() {
    t_a_step_at_run_k
    t_csv_stretches
    t_json_and_direction
    t_floor_and_usage
}

t_another_store() {
    t_last_n_and_too_few
    t_peer_groups
}

run_test "a step at run k; csv, json, direction, floor"   t_one_store
run_test "--last N, too few runs, --peers"                t_another_store
finish
