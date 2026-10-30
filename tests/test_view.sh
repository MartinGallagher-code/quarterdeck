#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Martin J. Gallagher

# qd view, driven without a terminal: QD_TEST_KEYS is a script of keys and
# the last screen is printed.  rig in binnacle tests its form the same way.

set -u
source "$(dirname "${BASH_SOURCE[0]}")/test_helper.bash"

seed() {
    {
        echo "host,rack,status,mbps,kernel"
        echo "h01,r1,ok,9400,6.1.0-18"
        echo "h02,r1,ok,9410,6.1.0-18"
        echo "h03,r2,ok,4700,6.1.0-13"
        echo "h04,r2,unreachable,,"
    } > f.csv
    qd import f.csv --name fleet > /dev/null
}

view() { QD_TEST_SCREEN="${SCREEN:-100x14}" QD_TEST_KEYS="$1" qd view "${2:-latest}"; }

t_first_screen_and_column_strip() {
    seed
    out="$(view '')"
    assert_contains "$out" "qd view"
    assert_contains "$out" "h04"
    assert_contains "$out" "row 1/4"
    out="$(view '<right><right><right>')"
    assert_contains "$out" "mbps  num   n 3   blank 1"
    assert_contains "$out" "median 9400"
}

# a filter nothing matches leaves an empty list to move in: it is said,
# not a crash
t_an_empty_list_can_be_moved_in() {
    seed
    out="$(view 'fmbps>99999<enter><right><right>cjG <enter>')"
    assert_contains "$out" "0 distinct values over 0 rows"
    assert_contains "$out" "0 of 0"
}

# r in a grouped view would put the raw rows under the grouped title
t_r_in_a_derived_view_is_said() {
    seed
    out="$(view '<right>gr')"
    assert_contains "$out" "q back to that, and r there"
    assert_contains "$out" "mbps_mean"
    assert_not_contains "$out" "h01"
    assert_contains "$(view 'r')" "reloaded: 4 rows"
}

t_filter_sort_and_undo() {
    seed
    out="$(view 'fmbps<9405<enter>')"
    assert_contains "$out" "2 rows where mbps<9405"
    out="$(view 'fmbps<9405<enter><right><right><right>S')"
    assert_contains "$out" "sorted by mbps descending"
    out="$(view 'fmbps<9405<enter>u')"
    assert_contains "$out" "dropped filter mbps<9405"
    out="$(view 'fnosuch>1<enter>')"
    assert_contains "$out" "no column 'nosuch'"
}

t_quick_filter_on_a_cell() {
    seed
    out="$(view '<right>=')"
    assert_contains "$out" "2 rows where rack=r1"
    out="$(view '<right><right>!')"
    assert_contains "$out" "1 row where status!=ok"
    out="$(view '<down><down><down><right><right>!')"
    assert_contains "$out" "3 rows where status!=unreachable"
}

t_describe_counts_and_drill_down() {
    seed
    SCREEN=100x24 out="$(SCREEN=100x24 view '<right><right><right>d')"
    assert_contains "$out" "mbps in depth"
    assert_contains "$out" "measured  3   blank 1"
    out="$(view '<right><right><right><right>c')"
    assert_contains "$out" "counts of kernel"
    assert_contains "$out" "2 agree on the most common, 2 do not"
    out="$(view '<right><right><right><right>c<enter>')"
    assert_contains "$out" "2 rows where kernel=6.1.0-18"
}

t_group_and_back() {
    seed
    out="$(view '<right>g')"
    assert_contains "$out" "grouped by rack"
    assert_contains "$out" "r2"
    out="$(view '<right>g<down><enter>')"
    assert_contains "$out" "rack=r2"
    out="$(view '<right>gq')"
    assert_contains "$out" "row 1/4"
}

t_detail_help_and_quit() {
    seed
    out="$(SCREEN=100x20 view '<down><enter>')"
    assert_contains "$out" "row 2 of"
    assert_contains "$out" "h02"
    out="$(SCREEN=100x40 view '?')"
    assert_contains "$out" "keep rows with this cell's value"
    # q from the table: back to the store's contents; Q quits
    assert_contains "$(view 'q')" "1 run, "
    assert_eq "$(view 'Q')" ""
    assert_eq "$(view 'qq')" ""
}

# two more runs and a dataset no run filed: everything there is to page
seed_more() {
    seed
    printf 'host,load\nh01,0.5\nh02,0.7\n' > load.csv
    qd import load.csv --name load > /dev/null
    printf 'disk,used\nsda,40\n' > disks.csv
    qd import disks.csv --name disks > /dev/null
    printf 'a=1, b=2\n' | pv --name loose > /dev/null 2>&1
}

viewall() { QD_TEST_SCREEN="${SCREEN:-100x14}" QD_TEST_KEYS="$1" qd view; }

t_no_run_opens_everything() {
    seed_more
    out="$(SCREEN=100x20 viewall '')"
    assert_contains "$out" "3 runs, "
    assert_contains "$out" "runs newest first, then datasets"
    assert_contains "$out" "disks"
    assert_contains "$out" "ds:loose"
    assert_contains "$out" "1 row"
    # the newest is first, and Enter opens it
    out="$(viewall '<enter>')"
    assert_contains "$out" "sda"
    assert_contains "$out" "(1 of "
}

t_paging_through_the_store() {
    seed_more
    # ] from the newest: the next one down the contents, an older run
    out="$(viewall '<enter>]')"
    assert_contains "$out" "2 of "
    assert_contains "$out" "h02"
    assert_contains "$out" "0.7"
    out="$(viewall '<enter>]]')"
    assert_contains "$out" "9400"
    out="$(viewall '<enter>]][')"
    assert_contains "$out" "0.7"
    assert_contains "$(viewall '<enter>[')" "that is the first thing in the store"
    # past the runs: the datasets, one by one, to the last
    out="$(SCREEN=100x14 viewall '<enter>}}}]]]]]]]]]]]]]]]]')"
    assert_contains "$out" "that is the last thing in the store"
    out="$(viewall '<enter>}}}')"
    assert_contains "$out" "4 of "
    assert_contains "$out" "in the store: ds:"
    # a run's tables come one after the other: a qd import has one each,
    # a dataset one; } skips the rest of a run, so the two agree here
    assert_eq "$(viewall '<enter>}}' | head -3)" "$(viewall '<enter>]]' | head -3)"
}

t_back_to_the_contents() {
    seed_more
    # q: the contents, on what was being looked at, ready for the next
    out="$(viewall '<enter>]]q')"
    assert_contains "$out" "3 of "
    out="$(viewall '<enter>]]q<down><enter>')"
    assert_contains "$out" "(4 of "
    # L from deep in a table's views: the contents
    out="$(viewall '<enter><right>gdL')"
    assert_contains "$out" "runs newest first"
    # paging from a report pages its table
    out="$(viewall '<enter><right>d]')"
    assert_contains "$out" "2 of "
    # a RUN named: that, with the contents under it
    out="$(view '' latest~2)"
    assert_contains "$out" "(3 of "
    assert_contains "$(view 'q' latest~2)" "3 of "
    # a file is not in the store: said, and L still lists the store
    assert_contains "$(view ']' f.csv)" "page from a table in the store"
    assert_contains "$(view 'L' f.csv)" "runs newest first"
}

t_needs_a_terminal_without_a_script() {
    seed
    qd_rc view latest < /dev/null > out 2> err
    assert_status "$QD_RC" 2
    assert_contains "$(cat err)" "needs a terminal"
}

run_test "an empty list can be moved in"             t_an_empty_list_can_be_moved_in
run_test "r in a derived view: said"               t_r_in_a_derived_view_is_said
run_test "first screen and the column strip"     t_first_screen_and_column_strip
run_test "filter, sort, undo, a bad filter"      t_filter_sort_and_undo
run_test "= and ! filter on the cell"            t_quick_filter_on_a_cell
run_test "describe, counts, drill down"          t_describe_counts_and_drill_down
run_test "group by, and back"                    t_group_and_back
run_test "row detail, help, quit"                t_detail_help_and_quit
run_test "no terminal, no script: refused"       t_needs_a_terminal_without_a_script
run_test "no RUN: everything in the store"        t_no_run_opens_everything
run_test "] [ } { page through the store"        t_paging_through_the_store
run_test "back to the contents, and files"       t_back_to_the_contents
finish
