#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Martin J. Gallagher

# Reading a dataset: --where, --sort, stats, freq, hist, outliers, pivot,
# trend.  Blank is "not measured" in every one of them.

set -u
source "$(dirname "${BASH_SOURCE[0]}")/test_helper.bash"

fleet() {
    {
        echo "host,rack,status,mbps,loss_pct,kernel"
        echo "h01,r1,ok,9400,0.0,6.1.0-18"
        echo "h02,r1,ok,9410,0.1,6.1.0-18"
        echo "h03,r1,ok,9390,0.0,6.1.0-18"
        echo "h04,r2,ok,9405,,6.1.0-18"
        echo "h05,r2,ok,4700,2.5,6.1.0-13"
        echo "h06,r2,ok,9395,0.0,6.1.0-18"
        echo "h07,r3,unreachable,,,"
        echo "h08,r3,ok,9402,0.0,6.1.0-18"
    } > fleet.csv
}

t_where_numbers_text_regex_blank() {
    fleet
    out="$(qd show fleet.csv --where 'mbps<9000' --cols host --format csv)"
    assert_eq "$out" "$(printf 'host\nh05')"
    out="$(qd show fleet.csv --where 'status=OK' --where 'rack=r2' --cols host --format csv)"
    assert_eq "$out" "$(printf 'host\nh04\nh05\nh06')"
    out="$(qd show fleet.csv --where 'host~^h0[78]' --cols host --format csv)"
    assert_eq "$out" "$(printf 'host\nh07\nh08')"
    out="$(qd show fleet.csv --where 'loss_pct=' --cols host --format csv)"
    assert_eq "$out" "$(printf 'host\nh04\nh07')"
    out="$(qd show fleet.csv --where 'not (rack=r1 or status!=ok) and loss_pct!=' --cols host --format csv)"
    assert_eq "$out" "$(printf 'host\nh05\nh06\nh08')"
    # blank is never less than a number
    out="$(qd show fleet.csv --where 'loss_pct<1' --cols host --format csv)"
    assert_not_contains "$out" "h04"
    qd_rc show fleet.csv --where 'nosuch>1' 2> err
    assert_status "$QD_RC" 2
    assert_contains "$(cat err)" "no column 'nosuch'"
    qd_rc show fleet.csv --where 'mbps>(' 2> err
    assert_status "$QD_RC" 2
}

t_sort_numeric_blank_last_both_ways() {
    fleet
    out="$(qd show fleet.csv --sort mbps --cols host --format csv | tr '\n' ' ')"
    assert_eq "$out" "host h05 h03 h06 h01 h08 h04 h02 h07 "
    out="$(qd show fleet.csv --sort -mbps --cols host --format csv | tr '\n' ' ')"
    assert_eq "$out" "host h02 h04 h08 h01 h06 h03 h05 h07 "
    out="$(qd show fleet.csv --sort rack,-mbps --cols host --format csv | tr '\n' ' ')"
    assert_eq "$out" "host h02 h01 h03 h04 h06 h05 h08 h07 "
}

t_stats_describe_and_one_column() {
    fleet
    out="$(qd stats fleet.csv)"
    assert_contains "$out" "6 columns"
    assert_contains "$out" "mbps"
    out="$(qd stats fleet.csv loss_pct)"
    assert_contains "$out" "measured  6   blank 2"
    assert_contains "$out" "median 0"
    out="$(qd stats fleet.csv --format csv)"
    assert_contains "$out" "column,kind,n,blank,distinct,mean"
    assert_contains "$out" "mbps,num,7,1,7"
}

t_stats_group_by_and_aggs() {
    fleet
    out="$(qd stats fleet.csv mbps --by rack --format csv)"
    assert_contains "$out" "rack,n,mbps_mean,mbps_median,mbps_min,mbps_max"
    assert_contains "$out" "r2,3,7833,9395,4700,9405"
    assert_contains "$out" "r3,2,9402,9402,9402,9402"
    out="$(qd stats fleet.csv status --by rack --agg worst --format csv)"
    assert_contains "$out" "r3,2,unreachable"
    out="$(qd stats fleet.csv kernel --by rack --format csv)"
    assert_contains "$out" "r2,3,6.1.0-18 (2/3)"
    qd_rc stats fleet.csv --by rack --agg nonsense
    assert_status "$QD_RC" 2
}

t_freq_is_consensus_with_holders() {
    fleet
    out="$(qd freq fleet.csv kernel)"
    assert_contains "$out" "3 distinct values"
    assert_contains "$out" "6 agree on the most common; 2 do not"
    assert_contains "$out" "h05"
    out="$(qd freq fleet.csv kernel --format csv)"
    assert_contains "$out" "6.1.0-13,1,12.5,h05"
}

t_freq_multiline_values_show_a_diff() {
    {
        echo 'host,stdout'
        printf 'a,"x=1\ny=2\nz=3"\n'
        printf 'b,"x=1\ny=2\nz=3"\n'
        printf 'c,"x=1\ny=9\nz=3"\n'
    } > m.csv
    out="$(qd freq m.csv stdout)"
    assert_contains "$out" "GROUP 1  2"
    assert_contains "$out" "| y=2"
    assert_contains "$out" "-y=2"
    assert_contains "$out" "+y=9"
    out="$(qd freq m.csv stdout --loose)"
    assert_contains "$out" "1 distinct value"
}

t_hist_bins_and_exact_integers() {
    fleet
    out="$(qd hist fleet.csv mbps --bins 4)"
    assert_contains "$out" "7 measured, 1 blank"
    assert_contains "$out" "4700 - 5878"
    printf 'host,rc\na,0\nb,0\nc,1\nd,255\n' > rc.csv
    out="$(qd hist rc.csv rc --format csv)"
    assert_contains "$out" "0,0,2"
    assert_contains "$out" "255,255,1"
    qd_rc hist fleet.csv kernel
    assert_status "$QD_RC" 1
}

t_outliers_by_median_and_mad() {
    fleet
    out="$(qd outliers fleet.csv mbps)"
    assert_contains "$out" "h05"
    assert_contains "$out" "low"
    assert_contains "$out" "1 of 7 hosts"
    assert_not_contains "$out" "h01  "
    # most of the fleet agrees exactly: every one that differs is named
    printf 'host,somaxconn\na,4096\nb,4096\nc,4096\nd,128\ne,4096\n' > s.csv
    out="$(qd outliers s.csv somaxconn)"
    assert_contains "$out" "most of them agree exactly"
    assert_contains "$out" "d "
}

t_outliers_reduce_per_host_first() {
    {
        echo "host,ts,load1"
        for t in 1 2 3; do
            for h in a b c d e; do echo "$h,$t,1.0$t"; done
            echo "f,$t,9.0"
        done
    } > series.csv
    out="$(qd outliers series.csv load1)"
    assert_contains "$out" "median per host"
    assert_contains "$out" "6 hosts"
    assert_contains "$out" "f "
}

t_pivot_results_defaults_and_counts() {
    printf '%s\n' 'mx_pps	h1	100' 'mx_pps	h2	110' 'mx_loss	h1	0.5' \
        'state	h1	PASS' 'state	h1	FAIL' 'state	h2	PASS' > r.tsv
    out="$(qd pivot r.tsv --format csv)"
    assert_contains "$out" "target,mx_loss,mx_pps,state"
    assert_contains "$out" "h1,0.5,100,FAIL"
    assert_contains "$out" "h2,,110,PASS"
    fleet
    out="$(qd pivot fleet.csv --rows rack --cols status --format csv)"
    assert_contains "$out" "rack,ok,unreachable"
    assert_contains "$out" "r3,1,1"
}

t_trend_sparklines_on_one_scale() {
    {
        echo "host,ts,v"
        for t in 1 2 3 4; do echo "a,$t,$t"; echo "b,$t,$((5 - t))"; done
    } > t.csv
    out="$(QD_ASCII=1 qd trend t.csv v)"
    assert_contains "$out" "by host over ts"
    assert_contains "$out" "one scale for all, 1 .. 4"
    out="$(qd trend t.csv v --format csv)"
    assert_contains "$out" "a,4,1,4,1,4"
    assert_contains "$out" "b,4,4,1,1,4"
}

t_results_value_mixing_tests_is_refused_for_outliers() {
    printf '%s\n' 'mx_pps	h1	100' 'mx_loss	h1	0.5' 'mx_pps	h2	90' > r.tsv
    qd_rc outliers r.tsv value 2> err
    assert_status "$QD_RC" 2
    assert_contains "$(cat err)" "--where test="
    out="$(qd outliers r.tsv value --where test=mx_pps)"
    assert_contains "$out" "per target"
}

# a column in mixed units is read on one scale everywhere, not cell by
# cell: --where with a unit, sorting, a group's mean, times, export
t_mixed_units_are_one_scale() {
    printf 'host,rack,used,lat\na,r1,512M,900ms\nb,r1,2G,1.2s\nc,r2,1G,800ms\nd,r2,980M,1.1s\n' > u.csv
    out="$(qd show u.csv --where 'used>600M' --cols host --format csv | tr '\n' ' ')"
    assert_eq "$out" "host b c d "
    out="$(qd show u.csv --sort -used --cols host --format csv | tr '\n' ' ')"
    assert_eq "$out" "host b c d a "
    # r1's mean of 512M and 2G is 1.25 GiB, in bytes -- not (512+2)/2
    assert_contains "$(qd stats u.csv used --by rack)" "1342177280"
    # 900ms beside 1.2s: seconds, every cell measured
    assert_contains "$(qd stats u.csv lat)" "measured  4"
    # a number with a unit is exported as written
    assert_contains "$(qd export u.csv --format json)" '"used": "512M"'
}

run_test "mixed units are one scale"                t_mixed_units_are_one_scale
run_test "--where: numbers, text, regex, blank, logic"  t_where_numbers_text_regex_blank
run_test "--sort: numeric, blanks last, both ways"      t_sort_numeric_blank_last_both_ways
run_test "stats: describe and one column"               t_stats_describe_and_one_column
run_test "stats --by and --agg"                         t_stats_group_by_and_aggs
run_test "freq: consensus with holders"                 t_freq_is_consensus_with_holders
run_test "freq: multi-line values diffed"               t_freq_multiline_values_show_a_diff
run_test "hist: bins, exact integers"                   t_hist_bins_and_exact_integers
run_test "outliers: median and MAD, MAD 0"              t_outliers_by_median_and_mad
run_test "outliers: one value per host first"           t_outliers_reduce_per_host_first
run_test "pivot: results defaults, worst verdict"       t_pivot_results_defaults_and_counts
run_test "trend: sparklines on one scale"               t_trend_sparklines_on_one_scale
run_test "outliers refuse a value of mixed tests"       t_results_value_mixing_tests_is_refused_for_outliers
finish
