#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Martin J. Gallagher

# qd rm and qd store clear: what goes is said first, and nothing goes
# without --yes; then provost deletes it, in one commit.  Deleting one run
# needs `provost rm --capture` (newer than provost 2.2.0); a provost
# without it is refused with a reason, and the store is left as it was.

set -u
source "$(dirname "${BASH_SOURCE[0]}")/test_helper.bash"

seed() {
    install_fake_ssh
    for h in node01 node02; do fake_host "$h"; done
    echo "6.1.0-18" > "$FAKE_ROOT/node01/kernel"
    echo "6.1.0-13" > "$FAKE_ROOT/node02/kernel"
    printf 'node01 rack=r1\nnode02 rack=r2\n' > hosts.txt
    qdf_rc run -s hosts.txt --name kern -- cat kernel > /dev/null
    echo "6.1.0-20" > "$FAKE_ROOT/node02/kernel"
    qdf_rc run -s hosts.txt --name kern -- cat kernel > /dev/null
    printf 'host,load\nnode01,0.5\n' > load.csv
    qd import load.csv --name load > /dev/null
}

# this provost deletes captures: `provost rm --capture`
can_rm() { pv rm --help 2> /dev/null | grep -q -- '--capture'; }

runs() { qd log 2>/dev/null | tail -n +2 | awk '{print $1}' | tr '\n' ' '; }
commits() { git -C "$QD_STORE" rev-list --count HEAD; }

t_rm_says_what_goes_and_waits_for_yes() {
    seed
    before="$(runs)"; n="$(commits)"
    qd_rc rm latest~1 > out 2> err
    assert_status "$QD_RC" 2
    assert_contains "$(cat out)" "1 run, from"
    assert_contains "$(cat out)" "kern"
    assert_contains "$(cat out)" "2/2 ok"
    assert_contains "$(cat err)" "nothing deleted: add --yes"
    assert_eq "$(runs)" "$before"
    assert_eq "$(commits)" "$n"
}

t_rm_deletes_one_run_of_a_fleet() {
    seed
    if ! can_rm; then
        qd_rc rm latest~2 --yes 2> err
        assert_status "$QD_RC" 2
        assert_contains "$(cat err)" "needs \`provost rm --capture\`"
        assert_contains "$(qd log)" "kern"
        return 0
    fi
    # oldest first: the two kern runs, then the import
    first="$(runs | awk '{print $1}')"; second="$(runs | awk '{print $2}')"
    n="$(commits)"
    qd_rc rm latest~2 --yes > out
    assert_status "$QD_RC" 0
    assert_contains "$(cat out)" "deleted 1 run ("
    # one commit, and the other runs whole
    assert_eq "$(commits)" "$((n + 1))"
    assert_not_contains "$(runs)" "$first"
    assert_contains "$(runs)" "$second"
    out="$(qd show "$second" --format csv)"
    assert_contains "$out" "node02"
    assert_contains "$out" "6.1.0-20"
    assert_not_contains "$out" "6.1.0-13"
    assert_contains "$(qd show "$second":hosts --format csv)" "node01"
    # nothing of the deleted run is left in any dataset
    assert_eq "$(grep -l "$first" "$QD_STORE"/datasets/*.tsv)" ""
    # and the store is clean: provost's commit, nothing left over
    assert_eq "$(git -C "$QD_STORE" status --porcelain)" ""
}

t_rm_several_and_a_dataset() {
    seed
    printf 'a=1, b=2\n' | pv --name loose > /dev/null 2>&1
    if ! can_rm; then
        # a whole dataset needs no new provost
        qd_rc rm ds:loose --yes > out
        assert_status "$QD_RC" 0
        assert_no_file "$QD_STORE/datasets/loose.tsv"
        return 0
    fi
    qd_rc rm kern latest~2 ds:loose --yes > out
    assert_status "$QD_RC" 0
    assert_contains "$(cat out)" "deleted 2 runs ("
    assert_contains "$(cat out)" "and 1 dataset"
    assert_no_file "$QD_STORE/datasets/loose.tsv"
    # the newest kern run, the first one, and the import is left
    assert_eq "$(runs | wc -w | tr -d ' ')" "1"
    assert_contains "$(qd log)" "load.csv"
}

t_rm_refuses_what_is_not_one_runs() {
    seed
    qd_rc rm ds:qd.runs --yes 2> err
    assert_status "$QD_RC" 2
    assert_contains "$(cat err)" "qd's own record"
    qd_rc rm ds:qd.hosts.v2 --yes 2> err
    assert_status "$QD_RC" 2
    qd_rc rm nosuch --yes 2> err
    assert_status "$QD_RC" 2
    assert_contains "$(cat err)" "no run or dataset 'nosuch'"
    assert_eq "$(runs | wc -w | tr -d ' ')" "3"
}

t_store_clear() {
    seed
    unset QD_STORE
    qd store new lab > /dev/null
    qd import load.csv --store lab --name load > /dev/null
    qd_rc store clear lab > out 2> err
    assert_status "$QD_RC" 2
    assert_contains "$(cat out)" "holds 1 run"
    assert_contains "$(cat err)" "add --yes to clear it"
    assert_contains "$(qd log --store lab)" "load.csv"
    qd store clear lab --yes > out
    assert_contains "$(cat out)" "lab ("
    assert_contains "$(cat out)" "is empty"
    assert_contains "$(qd log --store lab 2>&1)" "no runs in the store"
    assert_eq "$(ls "$XDG_DATA_HOME/quarterdeck/stores/lab/captures")" ""
    # still registered, its history kept, and empty is said
    assert_contains "$(qd store ls)" "lab"
    assert_contains "$(git -C "$XDG_DATA_HOME/quarterdeck/stores/lab" log -1 --format=%s)" "rm: deleted"
    assert_contains "$(qd store clear lab)" "is empty already"
    # and it files again as a store
    qd import load.csv --store lab > /dev/null
    assert_contains "$(qd log --store lab)" "load.csv"
}

# a campaign's part: said, with what runs it again
t_rm_a_campaign_part_says_how_to_redo_it() {
    command -v muster > /dev/null 2>&1 || "$PY" -c 'import binnacle.muster' \
        2> /dev/null || { echo "  (no muster here: pip install binnacle)"; return 0; }
    can_rm || { echo "  (this provost has no rm --capture)"; return 0; }
    install_fake_ssh
    for h in a b; do fake_host "$h"; echo 1 > "$FAKE_ROOT/$h/v"; done
    printf 'a rack=r1\nb rack=r2\n' > hosts.txt
    qd campaign new burn -s hosts.txt --by rack -- cat v > /dev/null
    qdf campaign run burn --parts 1 > /dev/null
    qd_rc rm latest --yes > out
    assert_status "$QD_RC" 0
    assert_contains "$(cat out)" "of campaign burn: qd campaign retry burn"
}

run_test "rm says what goes, and waits for --yes"   t_rm_says_what_goes_and_waits_for_yes
run_test "rm deletes one run of a fleet"            t_rm_deletes_one_run_of_a_fleet
run_test "rm several runs and a dataset"            t_rm_several_and_a_dataset
run_test "rm refuses what is not one run's"         t_rm_refuses_what_is_not_one_runs
run_test "rm a campaign's part: how to redo it"    t_rm_a_campaign_part_says_how_to_redo_it
run_test "store clear"                              t_store_clear
finish
