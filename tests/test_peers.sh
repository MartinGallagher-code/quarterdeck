#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Martin J. Gallagher

# Peer groups and qualified baselines: qd peers, qd baseline, and --peers
# and --baseline NAME on stats, outliers and compare -- the rank test
# against scipy's figures, a small real shift found in quiet runs and not
# in noisy ones, and blank never counted as zero.

set -u
source "$(dirname "${BASH_SOURCE[0]}")/test_helper.bash"

# imp NAME A B C D: one run of NAME, hosts a b (sku x) and c d (sku y)
# measuring v; an empty word is a blank cell
imp() {
    local name=$1
    shift
    printf 'host,sku,v\na,x,%s\nb,x,%s\nc,y,%s\nd,y,%s\n' "$@" > "$name.csv"
    qd import "$name.csv" --name "$name" > /dev/null
}

# the statistics, against figures scipy 1.18.1's mannwhitneyu(x, y) gave
# for the same samples (scipy is not a dependency: these are constants)
t_rank_test_matches_scipy() {
    "$PY" - "$QD_DIR" <<'EOF' || fail "the rank test disagrees with scipy"
import sys
sys.path.insert(0, sys.argv[1])
from quarterdeck.stats import mann_whitney, smallest_p
cases = [
    # x, y, scipy's U, scipy's p, the method scipy's auto picks
    ([1.0, 2.0, 3.0, 4.0, 5.0], [6.0, 7.0, 8.0, 9.0, 10.0],
     0.0, 0.007936507936507936, "exact"),
    ([10.2, 10.5, 10.1, 10.4], [10.0, 9.9, 10.3, 9.8, 10.05],
     18.0, 0.06349206349206349, "exact"),
    ([1, 2, 2, 3, 3, 3, 4, 5, 5, 6], [3, 4, 4, 5, 6, 6, 7, 7, 8, 9],
     15.5, 0.00949585610483713, "normal"),
    ([12.1, 11.8, 12.6, 13.0, 12.2, 11.9, 12.4, 12.8, 13.1, 12.0],
     [11.2, 11.5, 11.9, 11.1, 12.05, 11.4, 11.7, 11.3, 11.6, 12.3, 11.0,
      11.45], 110.5, 0.0009743386937058591, "normal"),
    ([100.0, 101.0, 99.5], [97.0, 96.5, 97.2], 9.0, 0.1, "exact"),
]
for x, y, u, p, how in cases:
    r = mann_whitney(x, y)
    assert abs(r["u"] - u) < 1e-9, (x, y, r, u)
    assert abs(r["p"] - p) < 1e-12, (x, y, r, p)
    assert r["method"] == how, (x, y, r, how)
# all tied: scipy says nan; no evidence of a difference is p 1
assert mann_whitney([3.0] * 3, [3.0] * 3)["p"] == 1.0
# the effect: +1 every x above every y, -1 below
assert mann_whitney([6, 7, 8], [1, 2, 3])["effect"] == 1.0
assert mann_whitney([1, 2, 3], [6, 7, 8])["effect"] == -1.0
assert mann_whitney([], [1.0]) is None
assert abs(smallest_p(3, 3) - 0.1) < 1e-12
assert abs(smallest_p(4, 4) - 2 / 70.0) < 1e-12
EOF
}

t_holm_adjustment() {
    "$PY" - "$QD_DIR" <<'EOF' || fail "holm is wrong"
import sys
sys.path.insert(0, sys.argv[1])
from quarterdeck.stats import holm
# by hand: sorted .005 .01 .03 .04 -> x4 x3 x2 x1, kept monotone
got = holm([0.01, 0.04, 0.03, None, 0.005])
want = [0.03, 0.06, 0.06, None, 0.02]
assert all((g is None and w is None) or abs(g - w) < 1e-12
           for g, w in zip(got, want)), got
assert holm([0.9, 0.8]) == [1.0, 1.0]
assert holm([]) == []
EOF
}

t_define_by_ls_show_and_stats() {
    imp load 100 102 200 204
    out="$(qd peers define sku --by sku --note 'one SKU, one group')"
    assert_contains "$out" "defined sku: by sku"
    out="$(qd peers ls)"
    assert_contains "$out" "sku"
    assert_contains "$out" "one SKU, one group"
    out="$(qd peers show sku latest)"
    assert_contains "$out" "2 groups"
    assert_contains "$out" "a b"
    out="$(qd stats latest v --peers sku --format csv)"
    assert_contains "$out" "sku,n,v_mean,v_median,v_min,v_max"
    assert_contains "$out" "x,2,101,101,100,102"
    assert_contains "$out" "y,2,202,202,200,204"
    # a second definition of the name is refused without --replace
    qd_rc peers define sku --by host 2> err
    assert_status "$QD_RC" 2
    assert_contains "$(cat err)" "--replace"
    qd peers define sku --by host --replace > /dev/null
    assert_contains "$(qd peers ls)" "by host"
    # kept in the store, as qd's own table
    assert_contains "$(qd show ds:qd.peers --format csv)" "peers,"
}

t_blank_rows_are_in_no_group() {
    printf 'host,sku,v\na,x,1\nb,,2\nc,y,3\n' > m.csv
    qd import m.csv --name m > /dev/null
    qd peers define sku --by sku > /dev/null
    out="$(qd stats latest v --peers sku)"
    assert_contains "$out" "1 row in no peer group of sku: left out"
    assert_not_contains "$(qd stats latest v --peers sku --format csv)" ",,"
}

t_outliers_against_peers() {
    # d is ordinary beside the y hosts and far from its own x peers
    printf 'host,sku,v\n' > m.csv
    for h in a:x:100 b:x:101 c:x:99 d:x:150 e:y:150 f:y:151 g:y:149 \
             i:y:152 j:y:148; do
        IFS=: read -r n s v <<< "$h"
        printf '%s,%s,%s\n' "$n" "$s" "$v" >> m.csv
    done
    qd import m.csv --name m > /dev/null
    qd peers define sku --by sku > /dev/null
    out="$(qd outliers latest v --peers sku)"
    assert_contains "$out" "each against its own group"
    assert_contains "$out" "1 of 9 hosts sit far from their peers"
    assert_contains "$(qd outliers latest v --peers sku --format csv)" \
        "x,d,150"
    # against the whole fleet it is the x hosts that stand out instead
    assert_not_contains "$(qd outliers latest v --format csv)" "d,150"
    # Tukey's fences: the same finding by the quartiles
    out="$(qd outliers latest v --peers sku --method iqr --format csv)"
    assert_contains "$out" "peers,host,value,of_median,iqrs_out,side"
    assert_contains "$out" "x,d,150"
    out="$(qd outliers latest v --method iqr)"
    assert_contains "$out" "Tukey's fences"
}

t_define_from_a_file_and_from_facts() {
    imp load 1 2 3 4
    printf 'host\tgroup\na\tpod1\nb\tpod1\nc\tpod2\n' > pods.tsv
    out="$(qd peers define pods --from pods.tsv)"
    assert_contains "$out" "2 groups of 3 hosts"
    out="$(qd stats latest v --peers pods)"
    assert_contains "$out" "1 row in no peer group of pods"
    # what the hosts are, from a facts run, frozen; a blank is no group
    for h in a b c d; do :; done
    printf 'host,kernel,bios\na,5.15,1.2\nb,5.15,1.2\nc,6.1,1.2\nd,,1.3\n' \
        > facts.csv
    qd import facts.csv --name facts > /dev/null
    out="$(qd peers define hw --facts kernel,bios)"
    assert_contains "$out" "kernel,bios in"
    assert_contains "$out" "2 groups of 3 hosts"
    assert_contains "$out" "1 host with kernel,bios blank, in no group: d"
    out="$(qd peers show hw)"
    assert_contains "$out" "5.15,1.2"
    assert_contains "$out" "6.1,1.2"
    # frozen: a later facts run does not move anyone until defined again
    printf 'host,kernel,bios\na,6.1,1.2\nb,5.15,1.2\nc,6.1,1.2\n' > facts.csv
    qd import facts.csv --name facts > /dev/null
    assert_contains "$(qd stats load v --peers hw --format csv)" \
        '"5.15,1.2",2,1.5'
    qd_rc peers define x --by a --from pods.tsv 2> err
    assert_status "$QD_RC" 2
    assert_contains "$(cat err)" "define it one way"
}

t_baseline_kept_with_who_and_when() {
    imp load 100 101 200 201
    imp load 102 103 202 203
    imp load 101 102 201 202
    qd peers define sku --by sku > /dev/null
    out="$(QD_OPERATOR=tester qd baseline set gold load --last 3 --peers sku \
        -c v --note 'after firmware 2.1, 3 4')"
    assert_contains "$out" "set gold"
    assert_contains "$out" "set by tester at 20"
    assert_contains "$out" "after firmware 2.1, 3 4"
    # read back from the store: a note of words and numbers is one cell
    assert_contains "$(qd baseline show gold)" "; after firmware 2.1, 3 4"
    out="$(qd baseline show gold --format csv)"
    assert_contains "$out" "column,peers,keys,runs,median,mad,values"
    # x: a run's group value is the median of a and b
    assert_contains "$out" "v,x,2,3,101.5,1,100.5 102.5 101.5"
    assert_contains "$out" "v,y,2,3,201.5,1,200.5 202.5 201.5"
    out="$(qd baseline ls)"
    assert_contains "$out" "gold"
    assert_contains "$out" "tester"
    assert_contains "$(qd show ds:qd.baselines --format csv)" "gold"
    qd_rc baseline set gold load 2> err
    assert_status "$QD_RC" 2
    assert_contains "$(cat err)" "set already (by tester"
    qd_rc baseline set load latest 2> err
    assert_status "$QD_RC" 2
    assert_contains "$(cat err)" "is a run's name"
    qd baseline set gold load --replace > /dev/null
    assert_contains "$(qd baseline show gold)" "1 run"
}

# the point of it: a 3% slide in quiet runs is a change before the 5%
# threshold, and the same slide in noisy runs is not
t_a_small_shift_in_quiet_runs_is_significant() {
    qd peers define sku --by sku > /dev/null
    imp quiet 100.0 100.0 200.0 200.0
    imp quiet 100.2 100.2 200.2 200.2
    imp quiet 99.9 99.9 199.9 199.9
    imp quiet 100.1 100.1 200.1 200.1
    imp quiet 99.8 99.8 199.8 199.8
    qd baseline set good quiet --last 5 --peers sku -c v > /dev/null
    imp quiet 97.0 97.0 200.1 200.1
    imp quiet 97.2 97.2 199.9 199.9
    imp quiet 96.9 96.9 200.0 200.0
    imp quiet 97.1 97.1 200.2 200.2
    imp quiet 96.8 96.8 199.8 199.8
    qd_rc compare quiet --last 5 --baseline good -c v > out
    assert_status "$QD_RC" 1
    out="$(cat out)"
    assert_contains "$out" "5 runs against baseline good"
    assert_contains "$out" "1 of 2 peer groups changed"
    qd_rc compare quiet --last 5 --baseline good -c v --format csv > out
    out="$(cat out)"
    assert_contains "$out" \
        "column,peers,base_runs,base_median,base_mad,runs,median,drift_pct,effect,p,p_holm,verdict,flags"
    # x moved 3%: inside the 5% threshold, and every run below every
    # baseline run (exact p 0.0079, Holm over two tests 0.016)
    assert_contains "$out" "v,x,5,100,0.1,5,97,-3.0,-1.00,0.0079,0.016,significant,significant"
    assert_contains "$out" "v,y,5,200,0.1,5,200,0.0,"
    assert_contains "$out" "not significant,"

    imp noisy 100 100 200 200
    imp noisy 92 92 200 200
    imp noisy 108 108 200 200
    imp noisy 95 95 200 200
    imp noisy 105 105 200 200
    qd baseline set rough noisy --last 5 --peers sku -c v > /dev/null
    imp noisy 97 97 200 200
    imp noisy 89 89 200 200
    imp noisy 105 105 200 200
    imp noisy 93 93 200 200
    imp noisy 103 103 200 200
    qd_rc compare noisy --last 5 --baseline rough -c v --format csv > out
    assert_status "$QD_RC" 0
    out="$(cat out)"
    assert_contains "$out" "v,x,5,100,5,5,97,-3.0,"
    assert_contains "$out" "not significant,"
    assert_not_contains "$out" ",significant,"
}

# runs with no noise at all make any difference a sure one: 0.1% is
# significant, and not a change until --min-drift says it is
t_a_sure_but_tiny_difference_is_not_a_change() {
    for _ in 1 2 3 4; do imp flat 100 100 100 100; done
    qd baseline set level flat --last 4 -c v > /dev/null
    for _ in 1 2 3 4; do imp flat 99.9 99.9 99.9 99.9; done
    qd_rc compare flat --last 4 --baseline level -c v --format csv > out
    assert_status "$QD_RC" 0
    assert_contains "$(cat out)" ",significant (under 1%),"
    qd_rc compare flat --last 4 --baseline level -c v --min-drift 0 \
        --format csv > out
    assert_status "$QD_RC" 1
    assert_contains "$(cat out)" "-0.1,-1.00,0.013,0.013,significant,significant"
}

t_too_few_runs_falls_back_to_the_drift() {
    qd peers define sku --by sku > /dev/null
    imp few 100 100 200 200
    imp few 101 101 201 201
    qd baseline set two few --last 2 --peers sku > /dev/null 2> err
    imp few 90 90 200 200
    qd_rc compare few --baseline two -c v > out
    assert_status "$QD_RC" 1
    out="$(cat out)"
    assert_contains "$out" "too few runs"
    assert_contains "$(qd compare few --baseline two -c v --format csv)" \
        "too few runs,past 5%"
    # a run the baseline was set from is not held against it
    out="$(qd compare few --last 3 --baseline two -c v)" || true
    assert_contains "$out" "2 runs the baseline was set from: left out"
    qd_rc compare latest~2 latest~1 --baseline two -c v 2> err
    assert_status "$QD_RC" 2
    assert_contains "$(cat err)" "every run picked is one the baseline"
    # an import's table is named after its file: a run of one table is
    # read whatever the file was called
    printf 'host,sku,v\na,x,100\nb,x,100\nc,y,200\nd,y,200\n' > other.csv
    qd import other.csv --name few > /dev/null
    out="$(qd compare few --baseline two -c v)" || true
    assert_contains "$out" "1 run against baseline two"
}

# blank is not measured: never a zero in a median, a count or a test
t_blank_is_never_zero() {
    qd peers define sku --by sku > /dev/null
    imp b 100 100 200 200
    imp b 100 "" 200 200
    imp b 100 100 200 200
    qd baseline set base b --last 3 --peers sku -c v > /dev/null
    out="$(qd show ds:qd.baselines --format csv --cols baseline,peer,key,n_runs,median,values)"
    # host b measured in two runs of three; the group is untouched by it
    assert_contains "$out" "base,x,b,2,100,100;100"
    assert_contains "$out" "base,x,,3,100,100;100;100"
    imp b 100 "" 200 200
    out="$(qd compare b --baseline base -c v --format csv)"
    assert_contains "$out" "v,x,3,100,0,1,100,0.0,"
    assert_not_contains "$out" "past 5%"
}

t_compare_peers_run_against_run() {
    qd peers define sku --by sku > /dev/null
    imp r 100 100 200 200
    imp r 100 100 180 180
    qd_rc compare r --last 2 -c v --peers sku > out
    assert_status "$QD_RC" 1
    out="$(cat out)"
    assert_contains "$out" "by peer group sku (by sku)"
    assert_contains "$out" "1 of 2 groups changed"
    out="$(qd compare r --last 2 -c v --peers sku --format csv)" || true
    assert_contains "$out" "sku,R1,R2,change_pct,flags"
    assert_contains "$out" "y,200,180,-10.0,R2 drift -10.0%"
    qd_rc compare r --last 2 --peers sku 2> err
    assert_status "$QD_RC" 2
    assert_contains "$(cat err)" "name it with -c"
}

t_rm_needs_yes_and_leaves_history() {
    imp r 1 2 3 4
    qd peers define sku --by sku > /dev/null
    qd baseline set b1 r > /dev/null 2>&1
    qd_rc peers rm sku 2> err
    assert_status "$QD_RC" 2
    assert_contains "$(cat err)" "add --yes"
    qd peers rm sku --yes > /dev/null
    assert_contains "$(qd peers ls)" "no peer groups"
    qd_rc stats latest v --peers sku 2> err
    assert_status "$QD_RC" 2
    assert_contains "$(cat err)" "no peer group 'sku'"
    qd baseline rm b1 --yes > /dev/null
    assert_contains "$(qd baseline ls)" "no baselines"
    # qd's own records are not deleted whole
    qd_rc rm ds:qd.baselines --yes 2> err
    assert_status "$QD_RC" 2
    assert_contains "$(cat err)" "qd's own record"
    # and the names are free again
    qd peers define sku --by sku > /dev/null
    qd baseline set b1 r > /dev/null 2>&1
    assert_contains "$(qd baseline ls)" "b1"
}

run_test "the rank test matches scipy's figures"        t_rank_test_matches_scipy
run_test "Holm's adjustment"                            t_holm_adjustment
run_test "peers: define --by, ls, show, stats --peers"  t_define_by_ls_show_and_stats
run_test "a blank in a by column is no group"           t_blank_rows_are_in_no_group
run_test "outliers --peers, --method iqr"               t_outliers_against_peers
run_test "peers: --from FILE, --facts COLS (frozen)"    t_define_from_a_file_and_from_facts
run_test "baseline set, show, ls: who and when kept"    t_baseline_kept_with_who_and_when
run_test "a 3% shift: quiet significant, noisy not"     t_a_small_shift_in_quiet_runs_is_significant
run_test "a sure but tiny difference: --min-drift"      t_a_sure_but_tiny_difference_is_not_a_change
run_test "too few runs: the drift alone"                t_too_few_runs_falls_back_to_the_drift
run_test "blank is never zero"                          t_blank_is_never_zero
run_test "compare --peers, run against run"             t_compare_peers_run_against_run
run_test "rm needs --yes; own records stay"             t_rm_needs_yes_and_leaves_history
finish
