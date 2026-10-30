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
    assert_contains "$out" "--store"
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

# a host line is split on spaces, here and by every tool of the suite: a
# value with a space in it, written as it is, would read back as a host
t_a_host_line_reads_back_as_its_host() {
    printf 'dc A\n' > floor.dc
    printf '%s\n' '#!/bin/sh' \
        'echo "name,path,kind,role,room,row,rack,slot"' \
        'echo "wr01r01u01,A/wr01/A/r01/u01,node,gpu server,wr01,A,r01,u01"' \
        > "$FAKE_BIN/manifest-ok"
    chmod +x "$FAKE_BIN/manifest-ok"
    QD_MANIFEST="$FAKE_BIN/manifest-ok" qd hosts --layout floor.dc 'rack[1]' > hosts.txt
    assert_contains "$(cat hosts.txt)" "role=gpu_server"
    assert_eq "$(qd hosts -s hosts.txt --plain)" "wr01r01u01"
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
    assert_contains "$out" "qd freq latest A"
    assert_contains "$out" "captures c0001..c0003"
    # what came back is provost's: a capture per host, the answer verbatim
    cap="$(qd show latest --where host=node03 --cols capture --format csv | tail -1)"
    assert_contains "$(cat "$QD_STORE/captures/$cap/output.txt")" "6.1.0-13"
    assert_contains "$(qd log latest)" "provost source"
    assert_contains "$(pv ls)" "qd.runs"
    csv="$(qd show latest --format csv)"
    assert_contains "$csv" "host,rack,status,rc,duration_s,error,capture,A"
    assert_contains "$csv" "node09,r2,unreachable,255"
    assert_contains "$csv" "node03,r2,ok,0"
    assert_contains "$csv" "$cap,6.1.0-13"
    assert_contains "$(qd log latest)" "3 captures, c0001..c0003"
}

t_provost_rows_name_their_host() {
    seed
    run_qd -q -- cat kernel > /dev/null
    if has_batch; then
        # one commit for the whole fleet, and every row says whose it is
        assert_contains "$(git -C "$QD_STORE" log -1 --format=%s)" "batch:"
        assert_contains "$(pv show cat | tr -s ' \t' ' ')" "node03 r2"
    else
        echo "  (this provost has no batch: host columns not checked)"
    fi
    assert_contains "$(qd show ds:cat --format csv)" "6.1.0-13"
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
    out="$(qd show latest:hosts --cols host,stderr --format csv)"
    assert_contains "$out" "No such file"
}

t_key_value_answers_with_units() {
    seed
    for h in node01 node02 node03; do
        printf 'MemTotal:  16384 kB\nMemFree:   2048 kB\n' > "$FAKE_ROOT/$h/m"
    done
    printf 'MemTotal:  32768 kB\nMemFree:   4096 kB\n' > "$FAKE_ROOT/node03/m"
    run_qd -- cat m > out
    assert_contains "$(cat out)" "MemTotal, MemFree"
    out="$(qd show latest --cols host,MemTotal --format csv)"
    assert_contains "$out" "node03,32768 kB"
    out="$(qd stats latest MemTotal --where status=ok)"
    assert_contains "$out" "max 32768"
}

t_a_blank_value_stays_blank() {
    seed
    # a setting a host could not read: `key:` and nothing, which provost
    # reads as a section header over the lines after it
    for h in node01 node02 node03; do
        printf 'vm.swappiness: 60\nnet.core.rmem_max: \nvm.dirty_ratio: 20\nfs.file-max: 9\n' \
            > "$FAKE_ROOT/$h/s"
    done
    run_qd -- cat s > out
    out="$(qd show latest --cols host,vm.swappiness,vm.dirty_ratio --format csv)"
    assert_contains "$out" "node02,60,20"
    assert_not_contains "$(qd show latest --format csv | head -1)" "group"
    # and qd log counts the rows qd show has, not provost's long ones
    n="$(qd show latest --format csv | tail -n +2 | wc -l | tr -d ' ')"
    qd log latest | grep -qE "data +$n rows" || fail "qd log does not say $n rows"
}

t_json_number_and_csv_answers() {
    seed
    for h in node01 node02 node03; do
        echo '{"a": 1, "b": "x"}' > "$FAKE_ROOT/$h/j"
        echo '42.5' > "$FAKE_ROOT/$h/n"
        printf 'dev,mb\nsda,10\nsdb,20\n' > "$FAKE_ROOT/$h/c"
    done
    run_qd -- cat j > out
    # wide (a, b) or long (field, value): provost's choice -- 2.1.0 reads
    # it long without jq -- and either way the key and its value come back
    # on the host's rows
    out="$(qd show latest --where host=node02 --format csv)"
    assert_contains "$out" "b"
    assert_contains "$out" ",x"
    run_qd -- cat n > out
    assert_contains "$(qd show latest --cols host,A --format csv)" "node02,42.5"
    run_qd -- cat c > out
    # one row per CSV row, the host repeated on each, n numbering them
    out="$(qd show latest --where status=ok --cols host,n,dev,mb --format csv)"
    assert_contains "$out" "node02,2,sdb,20"
}

# What a provost with `batch` reads as written and PyPI's 2.1.0 did not:
# quotes inside TSV cells, nested JSON with no jq, JSON Lines under `#`
# comments, and the floor-plan viewer's results format.
t_answers_a_newer_provost_reads() {
    if ! pv batch --help > /dev/null 2>&1; then
        echo "  (this provost predates batch, and these readers)"
        return 0
    fi
    seed
    for h in node01 node02 node03; do
        printf 'dev\tnote\nsda\tsaid "hi"\n' > "$FAKE_ROOT/$h/t"
        echo '{"host": "x", "cpu": {"count": 64, "model": "EPYC"}}' \
            > "$FAKE_ROOT/$h/j"
        printf '# scan of 2 records\n{"k": 1}\n{"k": 2}\n' > "$FAKE_ROOT/$h/l"
        printf '!test\tmbps\tunit=Mbit/s\nmbps\tpeer1\t940\tnote=fine\n' \
            > "$FAKE_ROOT/$h/r"
    done
    run_qd -- cat t > out
    assert_contains "$(qd show latest --cols host,note --format json)" \
        'said \"hi\"'
    PATH="$(nojq_path)" run_qd -- cat j > out
    assert_contains "$(qd show latest --cols host,cpu.count,cpu.model --format csv)" \
        "node02,64,EPYC"
    run_qd -- cat l > out
    assert_contains "$(qd show latest --cols host,k --format csv)" "node02,2"
    assert_not_contains "$(qd show latest --format csv | head -1)" "scan"
    run_qd -- cat r > out
    assert_contains "$(qd show latest --cols host,test,value,unit,note --format csv)" \
        "node02,mbps,940,Mbit/s,fine"
}

t_a_host_that_printed_nothing_keeps_its_row() {
    seed
    : > "$FAKE_ROOT/node01/n"
    echo "7" > "$FAKE_ROOT/node02/n"
    echo "8" > "$FAKE_ROOT/node03/n"
    run_qd -- cat n > /dev/null
    out="$(qd show latest --cols host,status,capture,A --format csv)"
    assert_contains "$out" "node01,ok,,"
    # (which capture is whose follows host order only where provost batches)
    assert_contains "$(qd show latest --cols host,A --format csv)" "node02,7"
    cap2="$(qd show latest --where host=node02 --cols capture --format csv | tail -1)"
    [ -n "$cap2" ] || fail "node02 answered but has no capture"
    assert_contains "$(qd log latest)" "2 captures"
}

t_df_table_is_one_row_per_filesystem() {
    seed
    for h in node01 node02 node03; do
        printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\n/dev/sda1 100 37 63 37%% /\n' \
            > "$FAKE_ROOT/$h/df"
    done
    run_qd -- cat df > /dev/null
    out="$(qd show latest --where status=ok --cols host,Capacity,Mounted_on --format csv)"
    assert_contains "$out" "node01,37%,/"
    out="$(qd stats latest Capacity --where status=ok)"
    assert_contains "$out" "mean      37"
}

t_repeated_passes_make_a_time_series() {
    seed
    # shellcheck disable=SC2016  # expanded on the far side, not here
    run_qd --every 0.2 --count 3 -- 'echo $RANDOM' > out
    assert_contains "$(cat out)" "3 passes"
    out="$(qd show latest --cols host,pass --format csv)"
    assert_contains "$out" "node01,3"
    out="$(qd trend latest A)"
    assert_contains "$out" "by host over ts"
    assert_contains "$(qd log latest)" "9 captures"
}

t_dry_run_and_sudo_contact_nothing() {
    seed
    out="$(qdf run -s hosts.txt --dry-run --sudo -- 'uptime | cut -c1-5')"
    assert_contains "$out" "sudo -n sh -c"
    assert_eq "$(ssh_calls)" "0"
    assert_no_file "$QD_STORE"
}

t_script_is_pushed_run_and_cleaned_up() {
    seed
    # shellcheck disable=SC2016  # a script for the far side to expand
    printf '#!/bin/sh\necho "args:$1:$FAKE_HOST"\n' > probe.sh
    run_qd --script probe.sh --remote-dir rd -- hello > /dev/null
    out="$(qd show latest --where status=ok --cols host,A --format csv)"
    assert_contains "$out" "node02,args:hello:node02"
    assert_no_file "$FAKE_ROOT/node02/rd"
    run_qd --script probe.sh --remote-dir rd --keep-remote -- x > /dev/null 2> err
    assert_contains "$(cat err)" "left on each host in rd/qd."
    kept="$(sed -n 's/.*left on each host in \(rd\/qd\.[0-9a-f]*\).*/\1/p' err)"
    assert_file_exists "$FAKE_ROOT/node02/$kept/probe.sh"
}

# --remote-dir is where the run makes a directory of its own: what was
# there before stays, and two runs at once never clean up each other's
t_the_remote_dir_is_never_removed() {
    seed
    mkdir -p "$FAKE_ROOT/node02/bin"
    echo mine > "$FAKE_ROOT/node02/bin/mytool"
    echo hello > payload.txt
    run_qd --push payload.txt --remote-dir bin -- cat payload.txt > /dev/null
    assert_contains "$(qd show latest --cols host,A --format csv)" "node02,hello"
    assert_eq "$(cat "$FAKE_ROOT/node02/bin/mytool")" "mine"
    assert_eq "$(ls "$FAKE_ROOT/node02/bin")" "mytool"
    # a slow run and a quick one, side by side, on the same hosts
    run_qd --push payload.txt --remote-dir rd -- 'sleep 2; cat payload.txt' \
        > /dev/null &
    sleep 0.7
    echo other > other.txt
    run_qd --push other.txt --remote-dir rd -- true > /dev/null
    wait
    slow="$(qd log | grep -- '-sleep ' | cut -d' ' -f1)"
    assert_contains "$(qd show "$slow" --cols host,A --format csv)" "node02,hello"
    assert_no_file "$FAKE_ROOT/node02/rd"
}

# a command on the host that exits 124 itself (timeout N check) answered:
# failed, not a qd timeout
t_an_exit_of_124_is_the_host_s() {
    seed
    run_qd -- 'echo checked; exit 124' > /dev/null
    out="$(qd show latest --cols host,status,rc --format csv)"
    assert_contains "$out" "node02,failed,124"
    assert_not_contains "$out" "timeout"
}

# A pushed file is beside the command, by its own name, wherever
# --remote-dir puts it
t_push_runs_beside_the_files() {
    seed
    echo hello > payload.txt
    run_qd --push payload.txt --remote-dir rd -- cat payload.txt > /dev/null
    assert_contains "$(qd show latest --cols host,A --format csv)" "node02,hello"
    assert_no_file "$FAKE_ROOT/node02/rd"
}

# 127 is the remote shell's "command not found": the host answered, so it
# failed rather than being unreachable (sudo missing, on real hosts)
t_command_not_found_is_failed_not_unreachable() {
    seed
    run_qd -- nosuchcommand > /dev/null
    out="$(qd show latest --cols host,status,rc --format csv)"
    assert_contains "$out" "node02,failed,127"
    assert_contains "$out" "node09,unreachable"
}

# A store provost would not find on its own (QD_STORE, --store): the tip
# to read an answer with provost names it, so it works as printed
t_provost_tips_name_the_store() {
    seed
    run_qd -- cat kernel > out
    assert_contains "$(cat out)" "PROVOST_WORKSPACE=$QD_STORE provost source"
    n="$(sed -n 's/.*PROVOST_WORKSPACE=[^ ]* provost source \([0-9]*\).*/\1/p' out | head -1)"
    # shellcheck disable=SC2086  # QD_PROVOST may be a command line
    assert_contains "$(env PROVOST_WORKSPACE="$QD_STORE" $PROVOST_CMD source "$n")" "6.1.0"
    # where provost finds the store itself, the tip is plain
    out="$(PROVOST_WORKSPACE="$QD_STORE" qd log latest)"
    assert_contains "$out" "answers   provost source"
    assert_not_contains "$out" "PROVOST_WORKSPACE="
}

# A big run is filed a few hundred inputs at a time, each a commit, so
# provost's lock is never held for the whole fleet; nothing is lost
t_a_big_run_is_filed_in_chunks() {
    has_batch || { echo "  (this provost files one capture at a time)"; return 0; }
    seed
    QD_FILE_CHUNK=2 run_qd -- cat kernel > out
    assert_status "$QD_RC" 1
    assert_eq "$(git -C "$QD_STORE" log --oneline | grep -c ' batch: ')" "3"
    out="$(qd show latest --cols host,status,A --format csv)"
    assert_contains "$out" "node03,ok,6.1.0-13"
    assert_contains "$out" "node09,unreachable"
    assert_contains "$(qd log latest)" "3 captures"
}

# --dry-run prints what will run: with pushed files, from beside them
t_dry_run_shows_where_pushed_files_run() {
    seed
    echo hello > payload.txt
    out="$(qdf run -s hosts.txt --dry-run --push payload.txt --remote-dir rd -- cat payload.txt)"
    assert_contains "$out" "cd rd/qd."
    assert_contains "$out" " && cat payload.txt"
    assert_eq "$(ssh_calls)" "0"
}

# an ssh that will not start is refused before any host, not filed as a
# fleet of failures
t_an_ssh_that_will_not_start_is_refused() {
    seed
    qd_rc run -s hosts.txt --ssh /nonexistent/ssh -- true 2> err
    assert_status "$QD_RC" 2
    assert_contains "$(cat err)" "cannot run /nonexistent/ssh"
    assert_eq "$(qd log 2>&1 | grep -c ' run ')" "0"
}

# a chunk of a big run provost fails on is said input by input, and the
# rest -- the run's own row with them -- are still filed
t_a_failed_chunk_still_files_the_run() {
    has_batch || { echo "  (this provost files one capture at a time)"; return 0; }
    seed
    cat > flaky-provost <<EOF
#!/bin/sh
if [ "\$1" = batch ]; then
  n=\$(cat "$PWD/calls" 2>/dev/null || echo 0); n=\$((n + 1)); echo \$n > "$PWD/calls"
  [ \$n -eq 2 ] && exit 1
fi
exec $PROVOST_CMD "\$@"
EOF
    chmod +x flaky-provost
    QD_FILE_CHUNK=2 QD_PROVOST="$PWD/flaky-provost" run_qd -- cat kernel > out 2> err
    assert_contains "$(cat out err)" "provost batch failed (exit 1)"
    assert_contains "$(qd log latest)" "cat kernel"
    assert_contains "$(qd show latest --cols host,status --format csv)" "node09,unreachable"
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

t_no_store_keeps_nothing() {
    seed
    run_qd --no-store -- cat kernel > out
    assert_contains "$(cat out)" "6.1.0-13"
    assert_no_file "$QD_STORE"
}

t_no_provost_is_refused_before_any_host() {
    seed
    QD_PROVOST=/nonexistent/provost qdf_rc run -s hosts.txt -- cat kernel 2> err
    assert_status "$QD_RC" 2
    assert_contains "$(cat err)" "pip install provost"
    assert_eq "$(ssh_calls)" "0"
}

t_store_follows_provost_rules() {
    seed
    # no --store and no QD_STORE: PROVOST_WORKSPACE, as provost itself
    unset QD_STORE
    PROVOST_WORKSPACE="$TEST_TMPDIR/elsewhere" qdf_rc run -q -s hosts.txt -- cat kernel > /dev/null
    assert_file_exists "$TEST_TMPDIR/elsewhere/qd.runs.tsv" 2>/dev/null ||         assert_file_exists "$TEST_TMPDIR/elsewhere/datasets/qd.runs.tsv"
    out="$(qd log --store "$TEST_TMPDIR/elsewhere")"
    assert_contains "$out" "cat kernel"
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

run_test "--remote-dir itself is never removed"     t_the_remote_dir_is_never_removed
run_test "exit 124 on the host is the host's"       t_an_exit_of_124_is_the_host_s
run_test "a host line reads back as its host"        t_a_host_line_reads_back_as_its_host
run_test "version, --help and help"                 t_version_and_help
run_test "hosts: ranges, attributes, order"           t_hosts_ranges_attrs_and_order
run_test "hosts: warn on an attribute that is a host" t_hosts_warn_when_an_attribute_looks_like_a_host
run_test "hosts: --layout asks manifest"              t_hosts_layout_asks_manifest
run_test "run keeps every answer, names failures"     t_run_keeps_every_answer_and_says_who_failed
run_test "provost's rows name their host"            t_provost_rows_name_their_host
run_test "run exits 0 when every host answers"        t_run_all_ok_exits_zero
run_test "a failed command is not unreachable"        t_failed_command_is_failed_not_unreachable
run_test "key: value answers, numbers with units"     t_key_value_answers_with_units
run_test "a key: with no value stays blank"           t_a_blank_value_stays_blank
run_test "json, number and csv answers"               t_json_number_and_csv_answers
run_test "answers a provost with batch reads"        t_answers_a_newer_provost_reads
run_test "a host that printed nothing keeps its row"  t_a_host_that_printed_nothing_keeps_its_row
run_test "df: one row per filesystem"                 t_df_table_is_one_row_per_filesystem
run_test "--every/--count: a time series"             t_repeated_passes_make_a_time_series
run_test "--dry-run and --sudo contact nothing"       t_dry_run_and_sudo_contact_nothing
run_test "--script: pushed, run, cleaned up"          t_script_is_pushed_run_and_cleaned_up
run_test "--push: the command runs beside its files"  t_push_runs_beside_the_files
run_test "command not found is failed, not unreachable" t_command_not_found_is_failed_not_unreachable
run_test "provost tips name a store it cannot find"   t_provost_tips_name_the_store
run_test "a big run is filed in chunks"               t_a_big_run_is_filed_in_chunks
run_test "--dry-run shows where pushed files run"     t_dry_run_shows_where_pushed_files_run
run_test "an ssh that will not start is refused"      t_an_ssh_that_will_not_start_is_refused
run_test "a failed chunk still files the run"         t_a_failed_chunk_still_files_the_run
run_test "mutation guard, --limit, --first 0"         t_mutation_guard_and_limit
run_test "--no-store keeps nothing"                   t_no_store_keeps_nothing
run_test "no provost: refused before any host"        t_no_provost_is_refused_before_any_host
run_test "the store follows provost's rules"          t_store_follows_provost_rules
run_test "latest, latest~N and names resolve"         t_names_and_refs_resolve
run_test "LANG=C survives non-ASCII answers"          t_lang_c_and_utf8_output_survive
finish
