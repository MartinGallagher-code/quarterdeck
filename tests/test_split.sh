#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Martin J. Gallagher

# qd split: one host list into several -- by attribute, shards, waves,
# random and stratified, A/B, canary, pairs, reachable, by answer.

set -u
source "$(dirname "${BASH_SOURCE[0]}")/test_helper.bash"

fleet() {
    printf '%s\n' 'n1 rack=r1' 'n2 rack=r1' 'n3 rack=r1' 'n4 rack=r2' \
        'n5 rack=r2' 'n6 rack=r2' > hosts.txt
}

groups_of() {   # the CSV, as "group:host" words
    qd split -s hosts.txt "$@" --format csv | tail -n +2 | cut -d, -f1,2 \
        | tr ',' ':' | tr '\n' ' '
}

t_by_attribute_and_files() {
    fleet
    out="$(qd split -s hosts.txt --by rack --out lists)"
    assert_contains "$out" "6 hosts into 2 lists, by rack"
    assert_file_exists lists/rack-r1.txt
    assert_contains "$(cat lists/rack-r2.txt)" "n5 rack=r2"
    # a list is a host file the suite reads: qd itself, for one
    assert_eq "$(qd hosts -s lists/rack-r1.txt --plain)" "$(printf 'n1\nn2\nn3')"
    qd_rc split -s hosts.txt --by role 2> err
    assert_contains "$(cat err)" "no host has a 'role' attribute"
    # names only, for agree, which reads rack=r1 as a host
    qd split -s hosts.txt --by rack --out plain --plain > /dev/null
    assert_eq "$(grep -v '^#' plain/rack-r2.txt)" "$(printf 'n4\nn5\nn6')"
}

# two values that clean to one name are two lists, never one file
# written twice
t_values_that_clean_alike_are_two_lists() {
    printf '%s\n' 'n1 room=a/b' 'n2 room=a:b' 'n3 room=A_B' > hosts.txt
    out="$(qd split -s hosts.txt --by room --out lists)"
    assert_contains "$out" "3 hosts into 3 lists"
    assert_contains "$out" "room-a_b-2"
    assert_eq "$(ls lists | wc -l | tr -d ' ')" "3"
    assert_eq "$(cat lists/*.txt | grep -v '^#' | cut -d' ' -f1 | sort | tr '\n' ' ')" "n1 n2 n3 "
}

# row is where a server sits, from a host file as from a layout
t_by_row_from_a_host_file() {
    printf '%s\n' 'n1 row=A rack=r1' 'n2 row=B rack=r1' > hosts.txt
    out="$(groups_of --by row)"
    assert_eq "$out" "row-A:n1 row-B:n2 "
}

t_shards_deals_and_waves() {
    fleet
    assert_eq "$(groups_of --into 4)" "shard-1:n1 shard-1:n2 shard-2:n3 shard-2:n4 shard-3:n5 shard-4:n6 "
    assert_eq "$(groups_of --deal 2)" "shard-1:n1 shard-1:n3 shard-1:n5 shard-2:n2 shard-2:n4 shard-2:n6 "
    assert_eq "$(groups_of --size 4)" "wave-1:n1 wave-1:n2 wave-1:n3 wave-1:n4 wave-2:n5 wave-2:n6 "
}

t_random_is_seeded_and_stratified() {
    fleet
    a="$(groups_of --random 3 --seed 7)"
    b="$(groups_of --random 3 --seed 7)"
    assert_eq "$a" "$b"
    # stratified: every group gets one host of each rack
    out="$(qd split -s hosts.txt --random 3 --seed 7 --stratify rack --format csv)"
    for g in group-1 group-2 group-3; do
        assert_eq "$(printf '%s\n' "$out" | grep -c "^$g,.*,r1$")" "1"
        assert_eq "$(printf '%s\n' "$out" | grep -c "^$g,.*,r2$")" "1"
    done
}

t_ab_canary_and_pairs() {
    fleet
    out="$(qd split -s hosts.txt --ab --seed 1 --format csv)"
    assert_eq "$(printf '%s\n' "$out" | grep -c '^a,')" "3"
    assert_eq "$(printf '%s\n' "$out" | grep -c '^b,')" "3"
    # stratified by rack: each half has some of each (3 of r1 go 2 and 1)
    for half in a b; do
        for rack in r1 r2; do
            n="$(printf '%s\n' "$out" | grep -c "^$half,.*,$rack\$")"
            [ "$n" -ge 1 ] || fail "half $half has no host of $rack"
        done
    done
    assert_eq "$(groups_of --canary 1 | cut -d' ' -f1-2)" "canary:n1 rest:n2"
    assert_contains "$(groups_of --pairs)" "pair-3:n5 pair-3:n6"
    assert_contains "$(groups_of --pairs --ring)" "pair-6:n6 pair-6:n1"
}

t_reachable_decides_up_and_down() {
    fleet
    # binnacle's reachable, played by a stand-in that answers its --csv
    cat > "$FAKE_BIN/reachable" <<'EOF'
#!/bin/sh
echo "host,addr,ping,ssh,usable,outcome,detail,duration_s"
while read -r h _; do
  case "$h" in n4|n6) echo "$h,$h,no,no,no,timeout,,1.0";; *) echo "$h,$h,yes,yes,yes,ok,,0.1";; esac
done < "$1"
EOF
    chmod +x "$FAKE_BIN/reachable"
    out="$(QD_REACHABLE="$FAKE_BIN/reachable" qd split -s hosts.txt --reachable --format csv)"
    assert_contains "$out" "down,n4"
    assert_contains "$out" "down,n6"
    assert_contains "$out" "up,n5"
}

t_by_answer_in_a_stored_run() {
    install_fake_ssh
    for h in n1 n2 n3; do fake_host "$h"; echo same > "$FAKE_ROOT/$h/f"; done
    echo other > "$FAKE_ROOT/n3/f"
    fake_host_unreachable n4
    printf 'n1\nn2\nn3\nn4\n' > hosts.txt
    qdf run -q -s hosts.txt -- cat f > /dev/null || true
    rm hosts.txt
    out="$(qd split --answers latest --format csv)"
    assert_contains "$out" "answer-1,n1"
    assert_contains "$out" "answer-1,n2"
    assert_contains "$out" "answer-2,n3"
    assert_contains "$out" "unreachable,n4"
}

t_one_way_at_a_time() {
    fleet
    qd_rc split -s hosts.txt 2> err
    assert_status "$QD_RC" 2
    assert_contains "$(cat err)" "say how to split"
    qd_rc split -s hosts.txt --by rack --into 2 2> err
    assert_contains "$(cat err)" "got --by, --into"
}

# a run of several passes: each host once, by its last answer
t_answers_of_a_multi_pass_run() {
    install_fake_ssh
    for h in n1 n2; do fake_host "$h"; echo same > "$FAKE_ROOT/$h/f"; done
    printf 'n1\nn2\n' > hosts.txt
    qdf run -q -s hosts.txt --every 0.1 --count 3 -- cat f > /dev/null
    rm hosts.txt
    out="$(qd split --answers latest --format csv)"
    assert_eq "$(printf '%s\n' "$out" | grep -c '^answer-1,')" "2"
}

run_test "--answers: a multi-pass run"              t_answers_of_a_multi_pass_run
run_test "--by ATTR, and the lists as files"          t_by_attribute_and_files
run_test "values that clean alike: two lists"         t_values_that_clean_alike_are_two_lists
run_test "--by row, from a host file"                 t_by_row_from_a_host_file
run_test "--into, --deal, --size"                     t_shards_deals_and_waves
run_test "--random: seeded, --stratify"               t_random_is_seeded_and_stratified
run_test "--ab, --canary, --pairs, --ring"            t_ab_canary_and_pairs
run_test "--reachable: binnacle decides"              t_reachable_decides_up_and_down
run_test "--answers: grouped by what hosts said"      t_by_answer_in_a_stored_run
run_test "one way of splitting at a time"             t_one_way_at_a_time
finish
