#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Martin J. Gallagher

# qd diff: keys found on their own, volatile columns left out and named,
# repeated keys reduced first, gone and new kept apart, exit status.

set -u
source "$(dirname "${BASH_SOURCE[0]}")/test_helper.bash"

t_host_keyed_changes_gone_and_new() {
    printf 'host,ts,mbps,status\na,1,9400,ok\nb,1,9300,ok\nc,1,9000,ok\n' > old.csv
    printf 'host,ts,mbps,status\na,2,9400,ok\nb,2,4700,ok\nd,2,9100,ok\n' > new.csv
    qd_rc diff old.csv new.csv > out
    assert_status "$QD_RC" 1
    out="$(cat out)"
    assert_contains "$out" "matched on host"
    assert_contains "$out" "ignored   ts"
    assert_contains "$out" "2 keys in both: 1 changed, 1 the same; 1 only in A (gone), 1 only in B (new)"
    assert_contains "$out" "b  mbps 9300 -> 4700 (-49.5%)"
    assert_contains "$out" "ONLY IN A (gone)"
    out="$(qd diff old.csv new.csv --format csv)" || true
    assert_contains "$out" "host,change,column,a,b,delta,pct"
    assert_contains "$out" "b,changed,mbps,9300,4700,-4600,-49.46"
    assert_contains "$out" "c,gone"
    assert_contains "$out" "d,new"
}

t_identical_exits_zero_and_tolerance() {
    printf 'host,v\na,100\nb,200\n' > x.csv
    printf 'host,v\na,101\nb,200\n' > y.csv
    qd_rc diff x.csv x.csv > out
    assert_status "$QD_RC" 0
    assert_contains "$(cat out)" "no differences"
    qd_rc diff x.csv y.csv --tolerance 2 > out
    assert_status "$QD_RC" 0
    qd_rc diff x.csv y.csv > out
    assert_status "$QD_RC" 1
}

t_worse_status_ranks_first_and_blank_is_named() {
    printf 'host,status,v\na,ok,1\nb,ok,1\nc,ok,5\n' > x.csv
    printf 'host,status,v\na,ok,9\nb,unreachable,\nc,ok,5\n' > y.csv
    out="$(qd diff x.csv y.csv)" || true
    first="$(printf '%s\n' "$out" | grep -A1 CHANGED | tail -1)"
    assert_contains "$first" "b  status ok -> unreachable"
    assert_contains "$out" "v went blank (1)"
}

t_repeated_keys_are_reduced_and_said() {
    printf 'ts,host,dir,peer,pps\n1,a,tx,b,100\n2,a,tx,b,110\n1,b,tx,a,90\n2,b,tx,a,90\n' > r1.csv
    printf 'ts,host,dir,peer,pps\n1,a,tx,b,50\n2,a,tx,b,60\n1,b,tx,a,90\n2,b,tx,a,90\n' > r2.csv
    out="$(qd diff r1.csv r2.csv)" || true
    assert_contains "$out" "matched on host,dir,peer"
    assert_contains "$out" "keys repeat, so each was reduced"
    assert_contains "$out" "pps 105 -> 55"
}

t_results_keyed_on_test_and_target() {
    printf 'mx_pps\th1\t100\trun=a\nmx_pps\th2\t100\trun=a\n' > a.tsv
    printf 'mx_pps\th1\t100\trun=b\nmx_pps\th2\t80\trun=b\n' > b.tsv
    out="$(qd diff a.tsv b.tsv)" || true
    assert_contains "$out" "matched on test,target"
    assert_contains "$out" "ignored   run"
    assert_contains "$out" "mx_pps h2  value 100 -> 80 (-20.0%)"
}

t_one_ref_compares_with_the_last_run_of_the_same_thing() {
    install_fake_ssh
    fake_host a; fake_host b
    echo one > "$FAKE_ROOT/a/f"; echo one > "$FAKE_ROOT/b/f"
    qdf run -S a,b -q -- cat f > /dev/null
    qdf run -S a,b -q -- uptime > /dev/null || true
    echo two > "$FAKE_ROOT/b/f"
    qdf run -S a,b -q -- cat f > /dev/null
    out="$(qd diff latest)" || true
    assert_contains "$out" "b  A one -> two"
    # what is compared is what the hosts said; the capture id is bookkeeping
    assert_contains "$out" "ignored   duration_s, capture"
    qd_rc diff latest~1 2> err
    assert_status "$QD_RC" 2
    assert_contains "$(cat err)" "nothing earlier"
}

t_multiline_text_gets_a_unified_diff() {
    {
        echo 'host,stdout'
        printf 'a,"l1\nl2\nl3"\n'
    } > x.csv
    {
        echo 'host,stdout'
        printf 'a,"l1\nL2\nl3"\n'
    } > y.csv
    out="$(qd diff x.csv y.csv)" || true
    assert_contains "$out" "stdout: text changed"
    assert_contains "$out" "-l2"
    assert_contains "$out" "+L2"
}

# a key reduced from repeated rows is not rounded against one that is not
t_a_reduced_key_is_not_rounded() {
    printf 'host,lat\na,940.25\nb,12.3456\n' > b.csv
    printf 'host,lat\na,940.2\na,940.3\nb,12.3456\nb,12.3456\n' > a.csv
    qd_rc diff a.csv b.csv > out
    assert_status "$QD_RC" 0
}

# 980M then 1.1G is a rise, not a fall to 1.1 of something
t_a_change_of_unit_is_not_a_change() {
    printf 'host,used\na,512M\nd,980M\n' > a.csv
    printf 'host,used\na,512M\nd,1.1G\n' > b.csv
    out="$(qd diff a.csv b.csv)" || true
    assert_contains "$out" "+14.9%"
    assert_not_contains "$out" "-99"
}

run_test "a change of unit is not a change"         t_a_change_of_unit_is_not_a_change
run_test "a reduced key is not rounded"             t_a_reduced_key_is_not_rounded
run_test "host keys: changed, gone, new, CSV"           t_host_keyed_changes_gone_and_new
run_test "identical exits 0; --tolerance"               t_identical_exits_zero_and_tolerance
run_test "worse status first; went blank named"         t_worse_status_ranks_first_and_blank_is_named
run_test "repeated keys reduced, and said"              t_repeated_keys_are_reduced_and_said
run_test "results keyed on test+target, run ignored"    t_results_keyed_on_test_and_target
run_test "one ref: against the last same run"           t_one_ref_compares_with_the_last_run_of_the_same_thing
run_test "multi-line text: a unified diff"              t_multiline_text_gets_a_unified_diff
finish
