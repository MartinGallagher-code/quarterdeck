#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Martin J. Gallagher

# qd run and qd hosts: host lists, fan-out, failure classes, parsing,
# repeated passes, the logbook entry, and the safety guards.

set -u
source "$(dirname "${BASH_SOURCE[0]}")/test_helper.bash"

seed() {
    install_fake_ssh
    for h in node01 node02 node03; do fake_host "$h"; done
    echo "6.1.0-18" > "$FAKE_ROOT/node01/kernel"
    echo "6.1.0-18" > "$FAKE_ROOT/node02/kernel"
    echo "6.1.0-13" > "$FAKE_ROOT/node03/kernel"
    fake_host_unreachable node09
    printf 'node01 rack=r1\nnode02 rack=r1\nnode03 rack=r2\nnode09 rack=r2\n' \
        > hosts.txt
}

run_qd() { qdf_rc run -s hosts.txt "$@"; }

t_version_and_help() {
    out="$(qd --version)"
    assert_contains "$out" "qd 0."
    assert_contains "$out" "GPL-3.0-or-later"
    out="$(qd)"
    assert_contains "$out" "Full manual:"
    out="$(qd help)"
    assert_contains "$out" "qd web"
    assert_contains "$out" "--extract"
}

t_hosts_ranges_attrs_and_order() {
    out="$(qd hosts -S 'node[01-03]')"
    assert_eq "$out" "$(printf 'node01\nnode02\nnode03')"
    printf '# fleet\nweb=10.0.0.5:2222 rack=r9\nnode02 node01\nnode02\n' > h.txt
    out="$(qd hosts -s h.txt)"
    assert_eq "$out" "$(printf 'web=10.0.0.5:2222 rack=r9\nnode02\nnode01')"
    out="$(qd hosts -s h.txt --csv)"
    assert_contains "$out" "host,addr,port,rack"
    assert_contains "$out" "web,10.0.0.5,2222,r9"
    qd_rc hosts -S '[fe80::1::2]'
    assert_status "$QD_RC" 2
    out="$(qd hosts -s h.txt --plain)"
    assert_eq "$out" "$(printf 'web=10.0.0.5:2222\nnode02\nnode01')"
}

t_hosts_warn_when_an_attribute_looks_like_a_host() {
    printf 'a=10.0.0.1 b=10.0.0.2\n' > h.txt
    out="$(qd hosts -s h.txt 2>&1)"
    assert_contains "$out" "read as an attribute, not a host"
    printf 'a=10.0.0.1 gbps=25\n' > h.txt
    out="$(qd hosts -s h.txt 2>&1)"
    assert_not_contains "$out" "attribute"
}

t_hosts_layout_asks_manifest() {
    printf 'dc A\n' > floor.dc
    # binnacle's manifest, played by a stand-in that answers its --csv
    printf '%s\n' '#!/bin/sh' \
        'echo "name,path,kind,role,room,row,rack,slot"' \
        'echo "wr01r01u01,A/wr01/A/r01/u01,node,server,wr01,A,r01,u01"' \
        > "$FAKE_BIN/manifest-ok"
    printf '#!/bin/sh\necho "usage: manifest [an unrelated tool]"\n' \
        > "$FAKE_BIN/manifest-other"
    printf '#!/bin/sh\necho "manifest: nothing matched" >&2\nexit 1\n' \
        > "$FAKE_BIN/manifest-none"
    chmod +x "$FAKE_BIN"/manifest-*
    out="$(QD_MANIFEST="$FAKE_BIN/manifest-ok" qd hosts --layout floor.dc 'rack[1]')"
    assert_eq "$out" "wr01r01u01 room=wr01 row=A rack=r01 slot=u01 role=server path=A/wr01/A/r01/u01"
    # something else called manifest: refused by name, not read as no hosts
    QD_MANIFEST="$FAKE_BIN/manifest-other" qd_rc hosts --layout floor.dc x 2> err
    assert_status "$QD_RC" 2
    assert_contains "$(cat err)" "binnacle's manifest"
    QD_MANIFEST="$FAKE_BIN/manifest-none" qd_rc hosts --layout floor.dc x 2> err
    assert_status "$QD_RC" 1
    assert_contains "$(cat err)" "matched no servers"
    qd_rc hosts --select 'rack[1]' 2> err
    assert_contains "$(cat err)" "--select needs --layout"
}

t_run_keeps_every_answer_and_says_who_failed() {
    seed
    run_qd -- cat kernel > out
    assert_status "$QD_RC" 1
    out="$(cat out)"
    assert_contains "$out" "4 hosts, 3 ok, 1 unreachable"
    assert_contains "$out" "DID NOT ANSWER"
    assert_contains "$out" "node09"
    assert_contains "$out" "qd freq latest stdout"
    e="$(ls logbook)"
    assert_file_exists "logbook/$e/entry.json"
    assert_file_exists "logbook/$e/raw/node03.out"
    assert_eq "$(cat "logbook/$e/raw/node03.out")" "6.1.0-13"
    csv="$(cat "logbook/$e/data.csv")"
    assert_contains "$csv" "host,rack,status,rc,duration_s,error,stdout"
    assert_contains "$csv" "node09,r2,unreachable,255"
    assert_contains "$csv" "node03,r2,ok,0"
}

t_run_all_ok_exits_zero() {
    seed
    rm -rf "$FAKE_ROOT/node09"
    printf 'node01\nnode02\n' > hosts.txt
    run_qd -q -- true > /dev/null
    assert_status "$QD_RC" 0
}

t_failed_command_is_failed_not_unreachable() {
    seed
    run_qd -q -- cat no-such-file > /dev/null
    out="$(qd show latest --cols host,status,rc --format csv)"
    assert_contains "$out" "node01,failed,1"
    assert_contains "$out" "node09,unreachable,255"
}

t_parse_auto_kv_with_units() {
    seed
    for h in node01 node02 node03; do
        printf 'MemTotal:  16384 kB\nvm.swappiness = 60\n' > "$FAKE_ROOT/$h/m"
    done
    run_qd -- cat m > out
    assert_contains "$(cat out)" "parsed as kv: memtotal_kb, vm_swappiness"
    out="$(qd show latest --cols host,memtotal_kb --format csv)"
    assert_contains "$out" "node01,16384"
}

t_parse_auto_json_number_csv() {
    seed
    for h in node01 node02 node03; do
        echo '{"a": 1, "b": {"c": "x"}}' > "$FAKE_ROOT/$h/j"
        echo '42.5' > "$FAKE_ROOT/$h/n"
        printf 'dev,mb\nsda,10\nsdb,20\n' > "$FAKE_ROOT/$h/c"
    done
    run_qd -- cat j > out
    assert_contains "$(cat out)" "parsed as json: a, b.c"
    run_qd -- cat n > out
    assert_contains "$(cat out)" "parsed as number: value"
    run_qd -- cat c > out
    assert_contains "$(cat out)" "parsed as csv: dev, mb"
    # one row per CSV row, the host repeated on each
    out="$(qd show latest --where status=ok --cols host,dev,mb --format csv)"
    assert_contains "$out" "node02,sdb,20"
}

t_extract_named_and_numbered_groups() {
    seed
    for h in node01 node02 node03; do
        echo "0.52 0.40 0.31 1/234 5678" > "$FAKE_ROOT/$h/loadavg"
    done
    run_qd --extract 'load1=^(\S+)' --extract '(?P<l5>\S+) (?P<l15>\S+) \d+/' \
        -- cat loadavg > out
    assert_contains "$(cat out)" "parsed as extract: load1, l5, l15"
    out="$(qd show latest --where status=ok --cols host,load1,l5,l15 --format csv)"
    assert_contains "$out" "node01,0.52,0.40,0.31"
    qdf_rc run -s hosts.txt --parse kv --extract 'a=(x)' -- true 2> err
    assert_status "$QD_RC" 2
    assert_contains "$(cat err)" "cannot be combined"
}

t_parse_error_is_a_column_not_a_silence() {
    seed
    echo "no digits here" > "$FAKE_ROOT/node01/n"
    echo "7" > "$FAKE_ROOT/node02/n"
    echo "8" > "$FAKE_ROOT/node03/n"
    run_qd --parse number -- cat n > /dev/null
    out="$(qd show latest --cols host,parse_error,value --format csv)"
    assert_contains "$out" "node01,no number in the output,"
    assert_contains "$out" "node02,,7"
}

t_parse_table_folds_a_two_word_heading() {
    seed
    for h in node01 node02 node03; do
        printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\n/dev/sda1 100 37 63 37%% /\n' \
            > "$FAKE_ROOT/$h/df"
    done
    run_qd --parse table -- cat df > /dev/null
    out="$(qd show latest --where status=ok --cols host,capacity,mounted_on --format csv)"
    assert_contains "$out" "node01,37%,/"
    out="$(qd stats latest capacity --where status=ok)"
    assert_contains "$out" "mean      37"
}

t_repeated_passes_make_a_time_series() {
    seed
    # shellcheck disable=SC2016  # expanded on the far side, not here
    run_qd --every 0.2 --count 3 --parse number -- 'echo $RANDOM' > out
    assert_contains "$(cat out)" "3 passes"
    out="$(qd show latest --cols host,pass --format csv)"
    assert_contains "$out" "node01,3"
    out="$(qd trend latest value)"
    assert_contains "$out" "by host over ts"
    e="$(ls logbook)"
    assert_file_exists "logbook/$e/raw/node02.3.out"
}

t_dry_run_and_sudo_contact_nothing() {
    seed
    out="$(qdf run -s hosts.txt --dry-run --sudo -- 'uptime | cut -c1-5')"
    assert_contains "$out" "sudo -n sh -c"
    assert_eq "$(ssh_calls)" "0"
    assert_no_file logbook
}

t_script_is_pushed_run_and_cleaned_up() {
    seed
    # shellcheck disable=SC2016  # a script for the far side to expand
    printf '#!/bin/sh\necho "args:$1:$FAKE_HOST"\n' > probe.sh
    run_qd --script probe.sh --remote-dir rd -- hello > /dev/null
    out="$(qd show latest --where status=ok --cols host,stdout --format csv)"
    assert_contains "$out" "node02,args:hello:node02"
    assert_no_file "$FAKE_ROOT/node02/rd"
    run_qd --script probe.sh --remote-dir rd --keep-remote -- x > /dev/null
    assert_file_exists "$FAKE_ROOT/node02/rd/probe.sh"
}

t_mutation_guard_and_limit() {
    seed
    run_qd -- rm -rf /var/log 2> err
    assert_status "$QD_RC" 2
    assert_contains "$(cat err)" "looks like rm -rf"
    assert_eq "$(ssh_calls)" "0"
    run_qd --limit 2 -- true 2> err
    assert_status "$QD_RC" 2
    assert_contains "$(cat err)" "--limit is 2"
    qdf_rc run -s hosts.txt --first 0 -- true 2> err
    assert_status "$QD_RC" 2
}

t_no_log_keeps_nothing() {
    seed
    run_qd --no-log -- cat kernel > out
    assert_contains "$(cat out)" "6.1.0-13"
    assert_no_file logbook
}

t_names_and_refs_resolve() {
    seed
    run_qd -q --name first -- cat kernel > /dev/null
    run_qd -q --name second -- cat kernel > /dev/null
    out="$(qd log)"
    assert_contains "$out" "first"
    assert_contains "$out" "second"
    assert_contains "$(qd log latest)" "second"
    assert_contains "$(qd log latest~1)" "first"
    assert_contains "$(qd log first)" "first"
    qd_rc log latest~5 2> err
    assert_status "$QD_RC" 2
    assert_contains "$(cat err)" "goes back further"
}

t_lang_c_and_utf8_output_survive() {
    seed
    printf 'caf\xc3\xa9\n' > "$FAKE_ROOT/node01/name"
    printf 'tea\n' > "$FAKE_ROOT/node02/name"
    printf 'tea\n' > "$FAKE_ROOT/node03/name"
    out="$(LC_ALL=C PYTHONIOENCODING='' PYTHONUTF8=0 PYTHONCOERCECLOCALE=0 \
        "$PY" "$QD_DIR/qd" run --ssh "$FAKE_BIN/ssh" -s hosts.txt -- cat name)" || true
    assert_contains "$out" "caf"
}

run_test "version, --help and help"                 t_version_and_help
run_test "hosts: ranges, attributes, order"           t_hosts_ranges_attrs_and_order
run_test "hosts: warn on an attribute that is a host" t_hosts_warn_when_an_attribute_looks_like_a_host
run_test "hosts: --layout asks manifest"              t_hosts_layout_asks_manifest
run_test "run keeps every answer, names failures"     t_run_keeps_every_answer_and_says_who_failed
run_test "run exits 0 when every host answers"        t_run_all_ok_exits_zero
run_test "a failed command is not unreachable"        t_failed_command_is_failed_not_unreachable
run_test "parse auto: kv, units into the name"        t_parse_auto_kv_with_units
run_test "parse auto: json, number, csv"              t_parse_auto_json_number_csv
run_test "extract: numbered and named groups"         t_extract_named_and_numbered_groups
run_test "a parse failure is a column"                t_parse_error_is_a_column_not_a_silence
run_test "parse table: df's two-word heading"         t_parse_table_folds_a_two_word_heading
run_test "--every/--count: a time series"             t_repeated_passes_make_a_time_series
run_test "--dry-run and --sudo contact nothing"       t_dry_run_and_sudo_contact_nothing
run_test "--script: pushed, run, cleaned up"          t_script_is_pushed_run_and_cleaned_up
run_test "mutation guard, --limit, --first 0"         t_mutation_guard_and_limit
run_test "--no-log keeps nothing"                     t_no_log_keeps_nothing
run_test "latest, latest~N and names resolve"         t_names_and_refs_resolve
run_test "LANG=C survives non-ASCII answers"          t_lang_c_and_utf8_output_survive
finish
