#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Martin J. Gallagher

# test_saved.sh -- the user's own probes (QD-054): `qd probe add NAME --
# COMMAND`, `qd probe rm NAME`, and `qd probe NAME`, which runs it as
# `qd run --name NAME -- COMMAND` would.  Kept in probes.json beside qd's
# config.json, never in a store; and never a way around --allow,
# --read-only or the mutation guard, which see its command, not its name.
# fio is the README's worked example: its JSON, from a fixture, filed by
# the real provost.

set -u
source "$(dirname "${BASH_SOURCE[0]}")/test_helper.bash"

FIO_JSON="$QD_DIR/tests/corpus/fio/randread.json"
# the README's fio probe, word for word
FIO_CMD="fio --name=randread --rw=randread --bs=4k --size=256M --runtime=30 --time_based --directory=/var/tmp --direct=1 --ioengine=libaio --iodepth=4 --output-format=json"

seed() {
    install_fake_ssh
    for h in a b; do fake_host "$h"; done
    printf 'a rack=r1\nb rack=r2\n' > hosts.txt
    # a fio on every fake host's PATH: the fixture, with FIO_IOPS (when
    # set) for its read IOPS, so two runs can differ
    cat > "$FAKE_BIN/fio" <<EOF
#!/bin/sh
if [ -n "\${FIO_IOPS:-}" ]; then
    sed "s/\"iops\" : 28952.931569/\"iops\" : \$FIO_IOPS/" "$FIO_JSON"
else
    cat "$FIO_JSON"
fi
EOF
    chmod +x "$FAKE_BIN/fio"
    export PATH="$FAKE_BIN:$PATH"
}

# no run of that name in the case's store
no_run_named() {
    qd_rc show "$1" --format csv > /dev/null 2>&1
    [ "$QD_RC" -ne 0 ] || fail "a run named $1 was filed"
}

t_add_list_run_replace_rm_in_a_temporary_home() {
    seed
    # the config where a user's is: $HOME/.config, not the harness's own
    unset XDG_CONFIG_HOME
    export HOME="$TEST_TMPDIR/home"
    mkdir -p "$HOME"
    qd probe add mykernel --note "the running kernel" -- uname -r > out
    assert_contains "$(cat out)" "qd probe mykernel: saved: uname -r"
    assert_file_exists "$HOME/.config/quarterdeck/probes.json"
    assert_contains "$(cat "$HOME/.config/quarterdeck/probes.json")" '"command": "uname -r"'
    # listed beside qd's own, marked as the user's, its command shown whole
    out="$(qd probe)"
    assert_contains "$out" "facts"
    assert_contains "$out" "mykernel"
    assert_contains "$out" "yours"
    assert_contains "$out" "the running kernel"
    # where it is kept, said with a tilde, not the whole of $HOME
    assert_contains "$out" "from ~"
    assert_contains "$out" "/.config/quarterdeck/probes.json"
    assert_contains "$(printf '%s\n' "$out" | grep -E '^ +mykernel +uname -r$')" "uname -r"
    # run: a run of its own name, every host
    qdf_rc probe mykernel -s hosts.txt -q > out
    assert_status "$QD_RC" 0
    assert_contains "$(cat out)" "qd probe mykernel"
    csv="$(qd show mykernel --format csv)"
    assert_contains "$csv" "host,rack,status"
    assert_eq "$(printf '%s\n' "$csv" | tail -n +2 | wc -l | tr -d ' ')" "2"
    # over an existing name only with --replace
    qd_rc probe add mykernel -- uname -a 2> err
    assert_status "$QD_RC" 2
    assert_contains "$(cat err)" "--replace"
    assert_contains "$(cat "$HOME/.config/quarterdeck/probes.json")" '"command": "uname -r"'
    qd probe add mykernel --replace -- uname -s > out
    assert_contains "$(cat out)" "replaced, now uname -s"
    assert_contains "$(qd probe)" "uname -s"
    assert_not_contains "$(qd probe)" "the running kernel"
    qdf probe mykernel -s hosts.txt -q > /dev/null
    assert_contains "$(qd log mykernel)" "uname -s"
    # rm: gone from the list, and asking for it is a refusal
    qd probe rm mykernel > out
    assert_contains "$(cat out)" "removed (it ran: uname -s)"
    assert_not_contains "$(qd probe)" "mykernel"
    qdf_rc probe mykernel -s hosts.txt -q 2> err
    assert_status "$QD_RC" 2
    assert_contains "$(cat err)" "no probe 'mykernel'"
    qd_rc probe rm mykernel 2> err
    assert_status "$QD_RC" 2
    assert_contains "$(cat err)" "you have no probe 'mykernel'"
}

t_a_run_is_filed_under_its_name_and_compared() {
    seed
    qd probe add fio-randread -- "$FIO_CMD" > /dev/null
    qdf probe fio-randread -s hosts.txt -q > /dev/null
    FIO_IOPS=21500.25 qdf probe fio-randread -s hosts.txt -q > /dev/null
    # filed as `qd run --name fio-randread -- COMMAND` files it: a run,
    # its command whole, no tool
    log="$(qd log fio-randread)"
    assert_contains "$log" "kind      run"
    assert_contains "$log" "command   $FIO_CMD"
    assert_contains "$log" "your probe fio-randread"
    assert_not_contains "$log" "tool "
    # compare exits 1 on a change, and this is one
    qd_rc compare fio-randread -c jobs.0.read.iops --last 5 > cmp.txt
    assert_status "$QD_RC" 1
    out="$(cat cmp.txt)"
    assert_contains "$out" "2 runs"
    assert_contains "$out" "R1"
    assert_contains "$out" "R2"
    assert_contains "$out" "28953"
    assert_contains "$out" "21500"
    # beside qd's own probes in one command, each still its own run
    qdf_rc probe os fio-randread packages -s hosts.txt -q > out
    assert_status "$QD_RC" 0
    assert_contains "$(cat out)" "qd probe os"
    assert_contains "$(cat out)" "qd probe fio-randread"
    assert_contains "$(cat out)" "qd probe packages"
    qd_rc compare fio-randread -c jobs.0.read.iops --last 5 > cmp.txt
    assert_contains "$(cat cmp.txt)" "3 runs"
}

t_clashes_bad_names_and_existing_names_are_exit_2() {
    seed
    qd probe add mine -- uptime > /dev/null
    before="$(cat "$XDG_CONFIG_HOME/quarterdeck/probes.json")"
    for name in facts os health inventory settings; do
        qd_rc probe add "$name" -- uptime 2> err
        assert_status "$QD_RC" 2
        assert_contains "$(cat err)" "is a probe qd ships"
    done
    for name in add rm latest; do
        qd_rc probe add "$name" -- uptime 2> err
        assert_status "$QD_RC" 2
        assert_contains "$(cat err)" "a word qd probe takes itself"
    done
    for name in 'a b' 'fio-' '.hidden' 'qd.runs' 'unsorted' 'a..b' 'a/b' \
            'x@y' 'latest~1' "$(printf 'n%.0s' $(seq 1 65))"; do
        qd_rc probe add "$name" -- uptime 2> err
        assert_status "$QD_RC" 2
        assert_contains "$(cat err)" "is not one"
    done
    qd_rc probe add mine -- uname -r 2> err
    assert_status "$QD_RC" 2
    assert_contains "$(cat err)" "you have a probe 'mine' already (uptime)"
    # nothing to save, and the words that belong to add alone
    qd_rc probe add other 2> err
    assert_status "$QD_RC" 2
    assert_contains "$(cat err)" "nothing to save"
    qd_rc probe add 2> err
    assert_status "$QD_RC" 2
    qd_rc probe os --note x 2> err
    assert_status "$QD_RC" 2
    qd_rc probe os -- uptime 2> err
    assert_status "$QD_RC" 2
    assert_contains "$(cat err)" "a command after -- is for"
    qd_rc probe rm os 2> err
    assert_status "$QD_RC" 2
    assert_contains "$(cat err)" "not one of yours"
    # none of it touched the saved probes
    assert_eq "$(cat "$XDG_CONFIG_HOME/quarterdeck/probes.json")" "$before"
    # a file that is not qd's is said, not run
    printf '{"probes": {"x": {"note": "no command"}}}\n' \
        > "$XDG_CONFIG_HOME/quarterdeck/probes.json"
    qd_rc probe x -s hosts.txt 2> err
    assert_status "$QD_RC" 2
    assert_contains "$(cat err)" "fix or remove it"
}

# the one thing that must not go wrong: a saved probe is never a way
# around a policy
t_read_only_and_allow_see_a_saved_probes_command() {
    seed
    qd probe add fio-randread -- "$FIO_CMD" > /dev/null
    # read-only with no allow-list: refused, nothing filed, on record
    qdf_rc probe fio-randread -s hosts.txt -q --read-only 2> err
    assert_status "$QD_RC" 2
    assert_contains "$(cat err)" "read-only allows only the probes qd ships"
    no_run_named fio-randread
    assert_contains "$(cat "$XDG_CACHE_HOME/quarterdeck/policy.log")" "$FIO_CMD"
    QD_READ_ONLY=1 qdf_rc probe fio-randread -s hosts.txt -q 2> err
    assert_status "$QD_RC" 2
    # ... while qd's own probes still run
    qdf_rc probe os -s hosts.txt -q --read-only > out 2>&1
    assert_status "$QD_RC" 0
    assert_contains "$(qd log os)" "policy: read-only"
    # asked beside qd's own, it is refused before any of them runs
    qd rm os --yes > /dev/null
    qdf_rc probe os fio-randread -s hosts.txt -q --read-only 2> err
    assert_status "$QD_RC" 2
    no_run_named os
    # an allow-list that names its name, or another command, does not
    # allow it; a pattern that matches its command does
    printf 'fio-randread\nfio --name=seqwrite *\n' > names.txt
    qdf_rc probe fio-randread -s hosts.txt -q --read-only --allow names.txt 2> err
    assert_status "$QD_RC" 2
    assert_contains "$(cat err)" "is not on the allow-list names.txt"
    no_run_named fio-randread
    printf 'fio --name=randread * --output-format=json\n' > allow.txt
    qdf_rc probe fio-randread -s hosts.txt -q --read-only --allow allow.txt > out 2>&1
    assert_status "$QD_RC" 0
    log="$(qd log fio-randread)"
    assert_contains "$log" "policy: read-only"
    assert_contains "$log" "policy: allow-list allow.txt"
    # --allow alone: outside it needs --confirm, as `qd run` does
    qdf_rc probe fio-randread -s hosts.txt -q --allow names.txt < /dev/null 2> err
    assert_status "$QD_RC" 2
    assert_contains "$(cat err)" "--confirm"
}

t_the_mutation_guard_catches_a_saved_rm_rf() {
    seed
    mkdir -p "$FAKE_ROOT/a/scratch" "$FAKE_ROOT/b/scratch"
    qd probe add tidy -- rm -rf scratch > out 2> err
    assert_contains "$(cat err)" "every run of it needs --yes"
    qdf_rc probe tidy -s hosts.txt -q < /dev/null 2> err
    assert_status "$QD_RC" 2
    assert_contains "$(cat err)" "it looks like rm -rf"
    assert_contains "$(cat err)" "qd probe tidy --yes"
    assert_dir_exists "$FAKE_ROOT/a/scratch"
    no_run_named tidy
    # an allow-list that names it does not let it past without --yes
    printf 'rm *\n' > rm.txt
    qdf_rc probe tidy -s hosts.txt -q --allow rm.txt < /dev/null 2> err
    assert_status "$QD_RC" 2
    assert_contains "$(cat err)" "rm -rf"
    assert_dir_exists "$FAKE_ROOT/a/scratch"
    # --yes, as for `qd run`
    qdf_rc probe tidy -s hosts.txt -q --yes > out 2>&1
    assert_status "$QD_RC" 0
    assert_no_file "$FAKE_ROOT/a/scratch"
}

t_a_store_brings_no_commands() {
    seed
    qd probe add mykernel -- uname -r > /dev/null
    qdf probe mykernel -s hosts.txt -q > /dev/null
    # the definition is in the config, and nowhere in the store
    assert_file_exists "$XDG_CONFIG_HOME/quarterdeck/probes.json"
    assert_eq "$(find "$QD_STORE" -name 'probes.json' | wc -l | tr -d ' ')" "0"
    # another machine (another config) with this store: the runs are
    # there to read, the probe is not there to run
    export XDG_CONFIG_HOME="$TEST_TMPDIR/elsewhere"
    assert_contains "$(qd show mykernel --format csv)" "host,rack,status"
    assert_not_contains "$(qd probe)" "mykernel"
    qdf_rc probe mykernel -s hosts.txt -q 2> err
    assert_status "$QD_RC" 2
    assert_contains "$(cat err)" "no probe 'mykernel'"
}

# The README's fio example, filed by the provost under test.  If this
# provost does not file these columns from fio's JSON, the README's
# example is wrong for it: change the example to what does parse.
t_fio_json_files_the_readme_columns() {
    seed
    qd probe add fio-randread --note "4k random reads, 30 s, in /var/tmp" \
        -- "$FIO_CMD" > /dev/null
    qdf_rc probe fio-randread -s hosts.txt -q > out 2>&1
    assert_status "$QD_RC" 0
    cols="host,jobs.0.read.iops,jobs.0.read.bw,jobs.0.read.clat_ns.percentile.99.000000,jobs.0.read.lat_ns.mean,disk_util.0.util"
    csv="$(qd show fio-randread --cols "$cols" --format csv)"
    if [ "$(printf '%s\n' "$csv" | head -1)" != "$cols" ]; then
        fail "$QD_PROVOST did not file the README's fio columns from fio's JSON (got: $(printf '%s\n' "$csv" | head -1)): change README's fio example to what it does file"
    fi
    assert_contains "$csv" "a,28952.931569,115811,272384,138073.53,99.512"
    assert_contains "$csv" "b,28952.931569,115811,272384,138073.53,99.512"
    # every column named here is the README's, and so is the command
    for c in jobs.0.read.iops jobs.0.read.bw jobs.0.read.clat_ns.percentile.99.000000 \
            jobs.0.read.lat_ns.mean disk_util.0.util; do
        assert_contains "$(cat "$QD_DIR/README.md")" "$c"
    done
    assert_contains "$(cat "$QD_DIR/README.md")" "$FIO_CMD"
    # the README's limits: IOPS passes, a p99 over 250 us fails
    printf 'req\tcolumn\top\tlimit\tagg\tunit\n' > fio-limits.tsv
    printf 'STO-1\tjobs.0.read.iops\t>=\t20000\tmin\t\n' >> fio-limits.tsv
    printf 'STO-2\tjobs.0.read.clat_ns.percentile.99.000000\t<=\t250000\tmax\tns\n' >> fio-limits.tsv
    qd_rc check fio-randread --against fio-limits.tsv > out
    assert_status "$QD_RC" 1
    assert_contains "$(grep STO-1 out)" "pass"
    assert_contains "$(grep STO-2 out)" "fail"
    assert_contains "$(cat out)" "1 pass, 1 fail, 0 not measured"
}

run_test "add, list, run, replace, rm (a temp HOME)"  t_add_list_run_replace_rm_in_a_temporary_home
run_test "filed under its name; compare reads it"   t_a_run_is_filed_under_its_name_and_compared
run_test "clash, bad name, no --replace: exit 2"    t_clashes_bad_names_and_existing_names_are_exit_2
run_test "read-only and --allow see its command"    t_read_only_and_allow_see_a_saved_probes_command
run_test "the mutation guard catches a saved rm -rf" t_the_mutation_guard_catches_a_saved_rm_rf
run_test "a store brings no commands to run"        t_a_store_brings_no_commands
run_test "fio's JSON: the README's columns"         t_fio_json_files_the_readme_columns
finish
