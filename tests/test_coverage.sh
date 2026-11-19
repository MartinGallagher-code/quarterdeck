#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Martin J. Gallagher

# qd coverage (QD-053): which hosts each named test has run on, its
# latest status and run, a host never asked counted as never, the hosts
# that owe a test written as a host list `qd run -s` reads back, --since,
# and the exit status: 1 when anything is owed, 0 when nothing is, 2 for
# usage (an empty store with no NAME among it).

set -u
source "$(dirname "${BASH_SOURCE[0]}")/test_helper.bash"

# Five hosts in the list, n1..n4 reachable and n5 not; n6 is a host the
# runs saw that the list no longer holds.  Three named runs over
# overlapping hosts:
#   facts  n1..n4, then again on n2 n3 (n2 fails the second time)
#   iperf  n1 n2 n5 n6 (n5 unreachable, n6 off the list)
#   burnin n3 n4 (n4 fails)
seed() {
    install_fake_ssh
    for h in n1 n2 n3 n4 n6; do fake_host "$h"; done
    fake_host_unreachable n5
    for h in n1 n2 n3 n4 n6; do touch "$FAKE_ROOT/$h/pass"; done
    printf '%s\n' 'n1 rack=r1' 'n2 rack=r1' 'n3 rack=r2' 'n4 rack=r2' \
        'n5 rack=r3' > hosts.txt
    qdf_rc run -S n1,n2,n3,n4 --name facts -- test -e pass > /dev/null 2>&1
    rm "$FAKE_ROOT/n2/pass"
    qdf_rc run -S n2,n3 --name facts -- test -e pass > /dev/null 2>&1
    touch "$FAKE_ROOT/n2/pass"
    qdf_rc run -S n1,n2,n5,n6 --name iperf --timeout 5 -- test -e pass \
        > /dev/null 2>&1
    rm "$FAKE_ROOT/n4/pass"
    qdf_rc run -S n3,n4 --name burnin -- test -e pass > /dev/null 2>&1
}

# the CSV's rows as host:name:counted words, in its order
cells() {
    qd_rc coverage -s hosts.txt "$@" --format csv > cov.csv
    tail -n +2 cov.csv | awk -F, '{ printf "%s:%s:%s ", $1, $2, $4 }'
}

t_grid_counts_and_exit() {
    seed
    qd_rc coverage facts iperf burnin -s hosts.txt > out
    assert_status "$QD_RC" 1
    out="$(cat out)"
    assert_contains "$out" "qd coverage -- 5 hosts against 3 names"
    # the head: per name, ok, failed, unreachable, never
    assert_contains "$out" "facts   3 ok, 1 failed, 0 unreachable, 1 never   (2 owed)"
    assert_contains "$out" "iperf   2 ok, 0 failed, 1 unreachable, 2 never   (3 owed)"
    assert_contains "$out" "burnin  1 ok, 1 failed, 0 unreachable, 3 never   (4 owed)"
    # the latest of facts' two runs on n2 counts: the failure
    assert_eq "$(qd log | grep -c facts)" "2"
    assert_contains "$(grep '^  n2 ' out)" "failed "
    assert_contains "$(grep '^  n5 ' out)" "never"
    assert_contains "$(grep '^  n5 ' out)" "unreachable "
    # a host the runs saw that the list does not hold: apart, uncounted
    assert_contains "$out" "not in the host list, and not counted: n6 (iperf ok)"
    assert_eq "$(grep -c '^  n6 ' out)" "0"
    # the tidy table behind it: a row per host and name, list order
    assert_eq "$(cells facts iperf burnin)" "n1:facts:ok n1:iperf:ok n1:burnin:never n2:facts:failed n2:iperf:ok n2:burnin:never n3:facts:ok n3:iperf:never n3:burnin:ok n4:facts:ok n4:iperf:never n4:burnin:failed n5:facts:never n5:iperf:unreachable n5:burnin:never n6:iperf:ok "
    assert_status "$QD_RC" 1
    assert_eq "$(head -n 1 cov.csv)" "host,name,status,counted,owed,run,when,listed"
    assert_contains "$(grep '^n6,' cov.csv)" ",no"
    # each cell names the run it came from
    rid="$(grep '^n2,facts,' cov.csv | cut -d, -f6)"
    assert_eq "$rid" "$(qd log | awk '$1 ~ /facts/ { r = $1 } END { print r }')"
    # JSON: the same rows
    qd_rc coverage facts -s hosts.txt --format json > cov.json
    assert_status "$QD_RC" 1
    assert_eq "$("$PY" -c 'import json,sys; d=json.load(open("cov.json")); print(len(d), sorted(set(r["counted"] for r in d)))')" \
        "5 ['failed', 'never', 'ok']"
    # a list owing nothing: exit 0
    printf 'n1\nn3\n' > two.txt
    qd_rc coverage facts -s two.txt > out
    assert_status "$QD_RC" 0
    assert_contains "$(cat out)" "facts  2 ok, 0 failed, 0 unreachable, 0 never   (none owed)"
    # n2 and n4 are runs' hosts the list left out
    assert_contains "$(cat out)" "not counted: n2 (facts failed); n4 (facts ok)"
    # no NAME: every name, the newest first
    qd_rc coverage -s hosts.txt > out
    assert_status "$QD_RC" 1
    assert_contains "$(cat out)" "against 3 names"
    assert_contains "$(grep '^  host ' out)" "burnin"
    head="$(grep '^  host ' out | tr -s ' ')"
    assert_eq "$head" " host burnin iperf facts"
}

# the owed hosts, written and run: then nothing is owed for that name
t_owed_list_round_trips() {
    seed
    # --since, first: an older run is never
    # n1's facts ok is from the first facts run, older than the second
    second="$(qd log | awk '$1 ~ /facts/ { r = $1 } END { print r }')"
    assert_eq "$(cells facts --since "$second" | tr ' ' '\n' | grep '^n1:')" "n1:facts:never"
    assert_eq "$(cells facts --since "$second" | tr ' ' '\n' | grep '^n3:')" "n3:facts:ok"
    # a date: one long ago changes nothing, one to come makes all never
    assert_eq "$(cells facts --since 2000-01-01 | tr ' ' '\n' | grep '^n1:')" "n1:facts:ok"
    qd_rc coverage facts -s hosts.txt --since 2999-01-01 > out
    assert_status "$QD_RC" 1
    assert_contains "$(cat out)" "0 ok, 0 failed, 0 unreachable, 5 never"
    assert_contains "$(cat out)" "since 2999-01-01T00:00:00Z"
    qd_rc coverage facts -s hosts.txt --since 2026-13-45 2> err
    assert_status "$QD_RC" 2
    assert_contains "$(cat err)" "not a date"
    # the owed lists
    qd_rc coverage facts burnin -s hosts.txt --owed owed > out
    assert_status "$QD_RC" 1
    assert_file_exists owed/facts.txt
    assert_file_exists owed/burnin.txt
    # never, or not ok, with the attributes the list gave them
    assert_eq "$(grep -v '^#' owed/facts.txt)" "$(printf 'n2 rack=r1\nn5 rack=r3')"
    assert_contains "$(head -n 1 owed/facts.txt)" "# facts: 2 host(s) -- never, or not ok"
    assert_contains "$(cat out)" "qd run -s owed/facts.txt --name facts -- ..."
    # the gap closed: n5 is back
    rm "$FAKE_ROOT/n5/.unreachable"
    touch "$FAKE_ROOT/n5/pass"
    qdf_rc run -s owed/facts.txt --name facts -- test -e pass > /dev/null 2>&1
    assert_status "$QD_RC" 0
    # the attributes rode along into the new run
    assert_contains "$(qd show facts:hosts --format csv)" "n5,r3,ok"
    qd_rc coverage facts -s hosts.txt > out
    assert_status "$QD_RC" 0
    assert_contains "$(cat out)" "facts  5 ok, 0 failed, 0 unreachable, 0 never   (none owed)"
    # a name with nothing owed still gets its file, with no hosts in it,
    # so a list from an earlier time is never left standing
    qd_rc coverage facts -s hosts.txt --owed owed > /dev/null
    assert_status "$QD_RC" 0
    assert_eq "$(grep -cv '^#' owed/facts.txt)" "0"
}

# a name the store lacks: every host never, said, exit 1; an empty store
# with no NAME: exit 2 with a reason
t_unknown_name_and_empty_store() {
    printf 'n1\nn2\n' > hosts.txt
    qd_rc coverage -s hosts.txt > out 2> err
    assert_status "$QD_RC" 2
    assert_contains "$(cat err)" "no runs on the fleet in the store"
    qd_rc coverage burnin -s hosts.txt > out 2> err
    assert_status "$QD_RC" 1
    assert_contains "$(cat err)" "no run named burnin in the store"
    assert_contains "$(cat out)" "burnin  0 ok, 0 failed, 0 unreachable, 2 never"
    # no host list at all (and no hosts.txt here): a usage error, never
    # this machine
    mkdir elsewhere
    (cd elsewhere && qd_rc coverage burnin > ../out 2> ../err &&
        echo "$QD_RC" > ../rc)
    assert_status "$(cat rc)" 2
    assert_contains "$(cat err)" "no hosts given"
    # a name whose runs are not on the fleet
    printf 'host,load\nn1,0.5\n' > load.csv
    qd import load.csv --name load > /dev/null
    qd_rc coverage load -s hosts.txt 2> err
    assert_status "$QD_RC" 2
    assert_contains "$(cat err)" "none on the fleet"
    # two probes asked together file a run each, under its own name
    install_fake_ssh
    fake_host n1
    qdf_rc probe os numa -S n1 -q > /dev/null 2>&1
    qd_rc coverage os numa -s hosts.txt --owed owed > out
    assert_status "$QD_RC" 1
    assert_contains "$(cat out)" "os    1 ok, 0 failed, 0 unreachable, 1 never"
    assert_contains "$(cat out)" "numa  1 ok, 0 failed, 0 unreachable, 1 never"
    assert_contains "$(cat out)" "qd probe os -s owed/os.txt"
}

run_test "coverage: grid, counts, exit status, and no NAME" t_grid_counts_and_exit
run_test "coverage: --since, and the owed list round-trips through qd run -s" t_owed_list_round_trips
run_test "coverage: an unknown name, an empty store" t_unknown_name_and_empty_store
finish
