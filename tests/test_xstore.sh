#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Martin J. Gallagher

# REF@STORE: a run read from any registered store, wherever a reading
# command takes one -- so two labs' or two machines' runs are set side by
# side without exporting one store into the other.

set -u
source "$(dirname "${BASH_SOURCE[0]}")/test_helper.bash"

# two named stores, wr01 and wr02, each with runs named kernel; and the
# case's own store (QD_STORE) with one of its own
seed() {
    qd store new wr01 > /dev/null
    qd store new wr02 > /dev/null
    # one file, imported again and again: the same thing run each time,
    # as previous_like and --last read it
    printf 'host,mbps\nh1,100\nh2,200\n' > k.csv
    qd import k.csv --name kernel --store wr01 > /dev/null 2>&1
    printf 'host,mbps\nh1,999\nh2,999\n' > k.csv
    qd import k.csv --name kernel > /dev/null 2>&1
    printf 'host,mbps\nh1,150\nh2,200\n' > k.csv
    qd import k.csv --name kernel --store wr01 > /dev/null 2>&1
    printf 'host,mbps\nh1,110\nh3,300\n' > k.csv
    qd import k.csv --name kernel --store wr02 > /dev/null 2>&1
}

ids_in() { qd log --store "$1" 2>/dev/null | tail -n +2 | awk '{print $1}'; }

t_show_and_diff_across_two_stores() {
    seed
    out="$(qd show kernel@wr02 --format csv)"
    assert_contains "$out" "h3,300"
    assert_not_contains "$out" "999"
    # without @STORE a reference means what it did: the command's own store
    assert_contains "$(qd show kernel --format csv)" "h1,999"
    qd_rc diff kernel@wr01 kernel@wr02 > out
    assert_status "$QD_RC" 1
    assert_contains "$(cat out)" "kernel@wr01 (2 rows) -> B"
    assert_contains "$(cat out)" "kernel@wr02 (2 rows)"
    assert_contains "$(cat out)" "h1  mbps 150 -> 110"
    # the other commands that read a run take it too
    assert_contains "$(qd stats kernel@wr02 mbps)" "kernel@wr02"
    assert_contains "$(qd export kernel@wr02)" "h3,300"
    assert_contains "$(qd log kernel@wr02)" "kernel@wr02  kernel"
    assert_contains "$(qd log kernel@wr02)" "store     "
    # --store names the command's own store: a run in it shows no @
    out="$(qd diff kernel@wr01 latest~1 --store wr01 || true)"
    assert_not_contains "$out" "@wr01"
}

t_a_table_of_a_run_in_another_store() {
    seed
    mkdir two
    printf 'host,mbps\nh1,5\n' > two/net.csv
    printf 'host,disk\nh1,7\n' > two/disk.csv
    qd import two --name pair --store wr02 > /dev/null 2>&1
    tables="$(qd log pair@wr02 | sed -n '/tables/,$p')"
    assert_contains "$tables" "net"
    assert_contains "$(qd show latest:net@wr02 --format csv)" "h1,5"
    assert_contains "$(qd show latest:disk@wr02 --format csv)" "h1,7"
    # a report header names it as it is typed back
    assert_contains "$(qd stats latest:disk@wr02 disk)" ":disk@wr02"
}

t_an_unknown_store_is_refused_listing_the_stores() {
    seed
    qd_rc show kernel@nope 2> err
    assert_status "$QD_RC" 2
    assert_contains "$(cat err)" "no store named 'nope'"
    assert_contains "$(cat err)" "the stores are wr01, wr02"
    # never the command's own store instead
    qd_rc diff kernel kernel@nope 2> err
    assert_status "$QD_RC" 2
    assert_contains "$(cat err)" "no store named 'nope'"
    # a directory is --store's job, not an @
    mkdir -p elsewhere
    qd_rc show kernel@elsewhere 2> err
    assert_status "$QD_RC" 2
    assert_contains "$(cat err)" "no store named 'elsewhere'"
}

t_a_file_named_with_an_at_is_still_a_file() {
    seed
    printf 'host,mbps\nf1,42\n' > 'me@wr01.csv'
    assert_contains "$(qd show me@wr01.csv --format csv)" "f1,42"
    mkdir 'dir@wr02'
    printf 'host,mbps\nf2,43\n' > 'dir@wr02/x.csv'
    assert_contains "$(qd show 'dir@wr02' --format csv)" "f2,43"
    qd_rc diff me@wr01.csv kernel@wr01 > out
    assert_status "$QD_RC" 1
    assert_contains "$(cat out)" "me@wr01.csv"
}

t_previous_like_stays_in_its_own_store() {
    seed
    # one reference: the run before it in wr01, not the case's own store's
    qd_rc diff kernel@wr01 > out
    assert_status "$QD_RC" 1
    assert_contains "$(cat out)" "h1  mbps 100 -> 150"
    assert_not_contains "$(cat out)" "999"
    # wr02 has one kernel run: nothing earlier there, whatever is elsewhere
    qd_rc diff kernel@wr02 2> err
    assert_status "$QD_RC" 2
    assert_contains "$(cat err)" "nothing earlier in"
    assert_contains "$(cat err)" "kernel@wr02"
}

t_compare_across_three_stores_with_labels() {
    seed
    qd_rc compare kernel@wr01 kernel kernel@wr02 -c mbps > out
    assert_status "$QD_RC" 1
    assert_contains "$(cat out)" "3 runs, mbps by host"
    w1="$(ids_in wr01 | tail -1)"
    w2="$(ids_in wr02 | tail -1)"
    assert_contains "$(cat out)" "R1   $w1@wr01"
    assert_contains "$(cat out)" "R3   $w2@wr02"
    # the run from the command's own store carries no @
    assert_contains "$(cat out)" "R2   $(qd log | tail -1 | awk '{print $1}')  "
    out="$(qd compare kernel@wr01 kernel kernel@wr02 -c mbps --format csv \
        || true)"
    # h3 is wr02's alone: blank (not measured) on the others, never zero
    assert_contains "$out" "h3,,,300"
    # h2 was not measured in wr02
    assert_contains "$out" "h2,200,999,,"
    # a baseline from another store
    out="$(qd compare kernel@wr01 kernel@wr02 -c mbps --baseline \
        kernel@wr02 || true)"
    assert_contains "$out" "baseline R2"
}

t_compare_last_n_at_a_store() {
    seed
    out="$(qd compare kernel --last 2@wr01 -c mbps || true)"
    assert_contains "$out" "2 runs"
    assert_contains "$out" "@wr01"
    assert_not_contains "$out" "999"
    qd_rc compare kernel --last x@wr01 2> err
    assert_status "$QD_RC" 2
    assert_contains "$(cat err)" "--last wants a count"
    qd_rc compare kernel --last 2@nope 2> err
    assert_status "$QD_RC" 2
    assert_contains "$(cat err)" "no store named 'nope'"
}

t_writing_commands_take_no_at() {
    seed
    qd_rc rm kernel@wr01 --yes 2> err
    assert_status "$QD_RC" 2
    assert_contains "$(cat err)" "rm deletes from --store"
    assert_eq "$(ids_in wr01 | wc -l | tr -d ' ')" "2"
}

# one side read from a remote store's copy, fetched over the fake ssh;
# a command reading two runs from it fetches it once
t_a_remote_store_on_one_side() {
    seed
    install_fake_ssh
    fake_host lab
    export QD_SSH="$FAKE_BIN/ssh"
    printf 'host,mbps\nh1,120\nh2,210\n' > lab.csv
    QD_STORE="$FAKE_ROOT/lab/store" qd import lab.csv --name kernel \
        > /dev/null 2>&1
    QD_STORE="$FAKE_ROOT/lab/store" qd import lab.csv --name kernel \
        > /dev/null 2>&1
    qd store new lab --remote lab:store > /dev/null
    n="$(ssh_calls)"
    qd_rc diff kernel@wr01 kernel@lab > out
    assert_status "$QD_RC" 1
    assert_contains "$(cat out)" "kernel@lab (2 rows)"
    assert_contains "$(cat out)" "h1  mbps 150 -> 120"
    # copies younger than QD_REMOTE_REFRESH are not fetched again
    assert_eq "$(ssh_calls)" "$n"
    n="$(ssh_calls)"
    QD_REMOTE_REFRESH=0 qd compare latest~1@lab latest@lab kernel@wr02 \
        -c mbps > out 2>&1 || true
    assert_contains "$(cat out)" "3 runs"
    # one store opened once: one fetch for two references to it
    assert_eq "$(ssh_calls)" "$((n + 1))"
}

# qd web takes the port asked for or one of the 19 above it, and checks it
# is free before it binds: each suite that starts a server has a range of
# its own (web 18100, this 18120, remote 18140, check 18160), so suites
# run side by side never race for one port.
start_web() {
    "$PY" "$QD_DIR/qd" web -n -q --port 18120 > web.out 2> web.err &
    echo $! > web.pid
    for _ in $(seq 1 50); do
        URL="$(sed -n 's/^qd web: \(http:[^ ]*\).*/\1/p' web.err | tail -1)"
        [ -n "$URL" ] && break
        sleep 0.1
    done
    [ -n "$URL" ] || { cat web.err; fail "the server did not start"; }
    export URL
}

get() {
    "$PY" - "$URL" "$1" <<'EOF'
import json, sys, urllib.request, urllib.error
base, path = sys.argv[1], sys.argv[2]
try:
    with urllib.request.urlopen(base.rstrip("/") + path) as r:
        status, body = r.status, r.read()
except urllib.error.HTTPError as e:
    status, body = e.code, e.read()
sys.stdout.buffer.write(b"%d\n" % status + body + b"\n")
EOF
}

t_the_web_api_diffs_and_compares_across_stores() {
    seed
    start_web
    # B here (the case's own store), A from wr02
    out="$(get '/api/diff?b=kernel&a=kernel&a_store=wr02')"
    assert_contains "$out" "200"
    assert_contains "$out" '"a_store": "wr02"'
    assert_contains "$out" '"b_store": ""'
    assert_contains "$out" '"kernel@wr02"'
    assert_contains "$out" '"only_a": [["h3"]]'
    # the same with the @ in the reference, and with the request's store
    out="$(get '/api/diff?store=wr01&b=kernel&a=kernel@wr02')"
    assert_contains "$out" '"b_store": ""'
    assert_contains "$out" '"a_store": "wr02"'
    # B alone: the run before it in B's own store
    out="$(get '/api/diff?b=kernel@wr01')"
    assert_contains "$out" "200"
    assert_contains "$out" '"a_store": "wr01"'
    assert_not_contains "$out" "999"
    # compare: the runs here and one from each of the others
    out="$(get '/api/compare?e=kernel&c=mbps&also=kernel@wr01&also=kernel@wr02&changed=0')"
    assert_contains "$out" "200"
    assert_contains "$out" '"store": "wr01"'
    assert_contains "$out" '"store": "wr02"'
    assert_contains "$out" '"key": ["h3"], "values": [null, null, 300.0]'
    # a store that is not registered, or a path: refused
    assert_contains "$(get '/api/diff?b=kernel&a=kernel@nope')" "400"
    out="$(get "/api/diff?b=kernel&a_store=$TEST_TMPDIR/store&a=kernel")"
    assert_contains "$out" "400"
}

run_test "show and diff across two stores"           t_show_and_diff_across_two_stores
run_test "RUN:TABLE@STORE"                           t_a_table_of_a_run_in_another_store
run_test "an unknown store: refused, stores listed"  t_an_unknown_store_is_refused_listing_the_stores
run_test "a file named with @ is still a file"       t_a_file_named_with_an_at_is_still_a_file
run_test "previous_like stays in its own store"      t_previous_like_stays_in_its_own_store
run_test "compare across three stores, labelled"     t_compare_across_three_stores_with_labels
run_test "compare --last N@STORE"                    t_compare_last_n_at_a_store
run_test "writing commands take no @STORE"           t_writing_commands_take_no_at
run_test "a remote store on one side"                t_a_remote_store_on_one_side
run_test "the web API across stores"                 t_the_web_api_diffs_and_compares_across_stores
finish
