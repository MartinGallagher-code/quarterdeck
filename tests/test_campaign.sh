#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Martin J. Gallagher

# qd campaign: a system run in parts, progress kept by binnacle's muster
# (the real one: these cases need binnacle), every part a run in provost.

set -u
source "$(dirname "${BASH_SOURCE[0]}")/test_helper.bash"

have_muster() {
    command -v muster > /dev/null 2>&1 || "$PY" -c 'import binnacle.muster' 2>/dev/null
}

seed() {
    install_fake_ssh
    for h in a b c d; do fake_host "$h"; echo 1 > "$FAKE_ROOT/$h/v"; done
    printf 'a rack=r1\nb rack=r1\nc rack=r2\nd rack=r2\n' > hosts.txt
    qd campaign new burn -s hosts.txt --by rack -- cat v > out
}

t_without_muster_it_says_so() {
    if have_muster; then
        echo "  (muster is installed: nothing to refuse)"
        return 0
    fi
    install_fake_ssh
    fake_host a
    qd_rc campaign new x -S a --into 1 -- true 2> err
    assert_status "$QD_RC" 2
    assert_contains "$(cat err)" "pip install binnacle"
}

t_parts_are_handed_out_once() {
    have_muster || { echo "  (no muster here: pip install binnacle)"; return 0; }
    seed
    assert_contains "$(cat out)" "burn: 2 parts, 4 hosts, by rack"
    assert_contains "$(qd campaign status burn)" "0 of 2 parts done"
    qdf campaign run burn --parts 1 > out
    assert_contains "$(cat out)" "part rack-r1: 2/2 ok"
    assert_contains "$(cat out)" "1 of 2 parts done"
    qdf campaign run burn > out
    assert_contains "$(cat out)" "part rack-r2: 2/2 ok"
    qdf campaign run burn > out
    assert_contains "$(cat out)" "nothing was left to take"
    # every part is a run in provost, its part on every row
    assert_contains "$(qd log)" "burn"
    st="$(qd campaign status burn)"
    assert_contains "$st" "2 of 2 parts done"
    assert_contains "$st" "rack-r2"
    assert_contains "$(qd campaign ls)" "2/2"
}

t_failed_parts_come_back_on_retry() {
    have_muster || { echo "  (no muster here: pip install binnacle)"; return 0; }
    seed
    fake_host_unreachable d
    qdf_rc campaign run burn > out
    assert_status "$QD_RC" 1
    assert_contains "$(qd campaign status burn)" "hosts failed"
    rm -f "$FAKE_ROOT/d/.unreachable"
    out="$(qd campaign retry burn)"
    assert_contains "$out" "1 part back in the pool: rack-r2"
    qdf campaign run burn > out
    assert_contains "$(cat out)" "part rack-r2: 2/2 ok"
    assert_not_contains "$(cat out)" "rack-r1"
}

t_two_workers_never_share_a_part() {
    have_muster || { echo "  (no muster here: pip install binnacle)"; return 0; }
    seed
    qdf campaign run burn > w1 2>&1 &
    p=$!
    qdf campaign run burn > w2 2>&1 || true
    wait "$p" || true
    n="$(cat w1 w2 | grep -c 'part rack-')"
    assert_eq "$n" "2"
    assert_eq "$(qd log | grep -c burn)" "2"
}

t_the_parts_compare_as_wholes() {
    have_muster || { echo "  (no muster here: pip install binnacle)"; return 0; }
    seed
    echo 2 > "$FAKE_ROOT/c/v"; echo 2 > "$FAKE_ROOT/d/v"
    qdf campaign run burn > /dev/null
    out="$(qd compare --group burn -c A)" || true
    assert_contains "$out" "the runs share no host: compared as wholes"
    assert_contains "$out" "part rack-r2"
}

t_names_are_checked() {
    have_muster || { echo "  (no muster here: pip install binnacle)"; return 0; }
    seed
    qd_rc campaign new burn -s hosts.txt --by rack -- cat v 2> err
    assert_status "$QD_RC" 2
    assert_contains "$(cat err)" "there is a campaign burn already"
    qd_rc campaign status nosuch 2> err
    assert_contains "$(cat err)" "no campaign 'nosuch'"
}

run_test "without muster: refused, and why"          t_without_muster_it_says_so
run_test "parts are handed out once, progress kept"  t_parts_are_handed_out_once
run_test "failed parts come back on retry"           t_failed_parts_come_back_on_retry
run_test "two workers never share a part"            t_two_workers_never_share_a_part
run_test "a campaign's parts compare as wholes"      t_the_parts_compare_as_wholes
run_test "names are checked"                         t_names_are_checked
finish
