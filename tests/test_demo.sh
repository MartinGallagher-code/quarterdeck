#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Martin J. Gallagher

# qd demo, and the walkthrough that reads it (QD-039): a made-up fleet's
# week, filed through provost as any run is, with no ssh, network or host
# list; docs/getting-started.md, every command of which runs here and must
# print what the page shows; and the examples of docs/concepts.md's
# "Naming a run", which read the demo (QD-042).
#
# Filing the demo is a few hundred provost captures, the slow part, so
# only two cases file it: the walkthrough (the page's own `qd demo`) and
# --rebuild.  They are the suite's first two cases, so `--shard` (PARTS
# in run_tests.sh) puts them on different runners.

set -u
source "$(dirname "${BASH_SOURCE[0]}")/test_helper.bash"

GUIDE="$QD_DIR/docs/getting-started.md"

# A machine that has never run qd: an empty home, where stores, config
# and cache all live, no QD_STORE, no PROVOST_HOME (so ~/.provost is
# provost's default, which nothing here may make), no ssh or scp on PATH,
# and `qd` on it as the clone's.  Output in UTF-8 whatever the Python
# (3.6 under LANG=C writes ASCII otherwise).
fresh_machine() {
    export HOME="$TEST_TMPDIR/home"
    mkdir -p "$HOME" "$TEST_TMPDIR/qdbin"
    unset QD_STORE PROVOST_HOME XDG_CONFIG_HOME XDG_DATA_HOME XDG_CACHE_HOME
    export PYTHONIOENCODING=utf-8
    export WT_PY="$PY" WT_QD="$QD_DIR/qd"
    # shellcheck disable=SC2016  # expanded when the stand-in runs
    printf '%s\n' '#!/bin/sh' 'exec "$WT_PY" "$WT_QD" "$@"' > "$TEST_TMPDIR/qdbin/qd"
    chmod +x "$TEST_TMPDIR/qdbin/qd"
    PATH="$TEST_TMPDIR/qdbin:$(path_without ssh scp)"
    export PATH
    if command -v ssh > /dev/null || command -v scp > /dev/null; then
        fail "ssh or scp is still on PATH"
    fi
}

demo_root() { echo "$HOME/.local/share/quarterdeck/stores/demo"; }
runs_in() { qd log --all --store "$1" | tail -n +2 | grep -c .; }
active_store() {
    "$PY" -c 'import json, sys; print(json.load(open(sys.argv[1])).get("active"))' \
        "$HOME/.config/quarterdeck/config.json"
}

# -- the walkthrough -----------------------------------------------------------

# Every ```console block of the page, run in order on a fresh machine, the
# page's own `qd demo` first; then the findings the demo was built for,
# asked again here so a page rewritten by --update cannot lose them.  The
# shell's fleet settings are set, wrongly for a demo, to show the demo
# ignores them: none of them is anything to it.
t_walkthrough() {
    fresh_machine
    export QD_VIA=pdsh QD_MAX_FAIL=0 QD_RETRIES=2 QD_RATE=1/s QD_READ_ONLY=1 \
        QD_JOBS=1 QD_SERVERS="$TEST_TMPDIR/nowhere.txt"
    local update=()
    [ -n "${QD_WALKTHROUGH_UPDATE:-}" ] && update=(--update)
    "$PY" "$QD_DIR/tests/walkthrough.py" "$GUIDE" "$PWD" "${update[@]}"
    unset QD_VIA QD_MAX_FAIL QD_RETRIES QD_RATE QD_READ_ONLY QD_JOBS QD_SERVERS

    # every example of docs/concepts.md's "Naming a run", against the demo
    # the page says they read, each exiting 0 as it says (QD-042)
    assert_eq "$(active_store)" "demo"
    set +e
    out="$("$PY" "$QD_DIR/tests/concepts_unit.py" "$QD_DIR" run qd)"
    rc=$?
    set -e
    assert_status "$rc" 0
    assert_contains "$out" "every one exits 0"

    # nothing filed or made where it should not be
    assert_no_file "$HOME/.provost"
    assert_eq "$(runs_in demo)" "7"
    assert_eq "$(qd show demo-kernel:hosts --cols host --format csv | tail -n +2 | grep -c .)" "24"
    assert_contains "$(qd log demo-iperf)" "via       demo"
    # who runs which kernel: one host on another, one not answering
    out="$(qd freq demo-kernel A)"
    assert_contains "$out" "22 agree on the most common; 2 do not"
    assert_contains "$out" "6.8.0-31-generic"
    assert_contains "$(qd freq demo-kernel A --format csv)" "demo-r2n05"
    out="$(qd show demo-kernel --where status!=ok --cols host,status --format csv)"
    assert_eq "$out" "$(printf 'host,status\ndemo-r1n09,unreachable')"
    # who is far from the rest: the slow host, and only it
    out="$(qd outliers demo-iperf mbps)"
    assert_contains "$out" "demo-r2n03"
    assert_contains "$out" "1 of 24 hosts sit far from the rest"
    # did it get worse: the sliding host, and only it, both ways of asking
    qd_rc compare demo-facts -c mem.available_pct --last 5 > out
    assert_status "$QD_RC" 1
    assert_contains "$(cat out)" "1 of 24 keys changed"
    assert_contains "$(cat out)" "demo-r2n07  62.8  51.3  39.6  27.9  15.4"
    qd_rc changes demo-facts -c mem.available_pct > out
    assert_status "$QD_RC" 1
    assert_contains "$(cat out)" "1 of 24 keys changed"
    assert_contains "$(cat out)" "demo-r2n07  fell"
    # does it meet spec: the planted requirement fails, and nothing else
    qd_rc check demo-iperf --against limits.csv --format csv > out
    assert_status "$QD_RC" 1
    assert_eq "$(grep -c ',fail,' out)" "1"
    assert_contains "$(grep ',fail,' out)" "NET-001"
    assert_eq "$(grep -c ',pass,' out)" "2"
}

# -- filing it again ---------------------------------------------------------------

# A store named demo that holds nothing (a demo stopped before it filed
# anything) is the demo's to replace; a second qd demo leaves a whole one
# as it is; --rebuild files it afresh, never a second week on the first;
# the store in use is never touched; and qd store rm removes it.
t_again_and_rebuild() {
    local batch=1
    has_batch || batch=0        # before fresh_machine, which unsets QD_STORE
    fresh_machine
    printf 'host,v\na,1\n' > t.csv
    qd store new mine > /dev/null
    qd store use mine > /dev/null
    qd import t.csv --name mine-t > /dev/null
    before="$(qd log --store mine)"
    mkdir -p "$(demo_root)"
    qd store new demo > /dev/null
    qd_rc demo 2> err
    assert_status "$QD_RC" 2
    assert_contains "$(cat err)" "registered, but holds no demo"
    out="$(qd demo --rebuild)"
    assert_contains "$out" "qd demo -- filed the store demo: a made-up fleet's week, 7 runs of 24 hosts"
    assert_eq "$(runs_in demo)" "7"
    assert_eq "$(active_store)" "mine"
    assert_eq "$(qd log --store mine)" "$before"
    assert_no_file "$HOME/.provost"
    out="$(qd demo)"
    assert_contains "$out" "the store demo is there already"
    assert_contains "$out" "qd demo --rebuild files it again"
    assert_eq "$(runs_in demo)" "7"
    if [ "$batch" = 1 ]; then
        # a whole demo replaced: the slow path, one capture at a time,
        # files it once only, for time; filing is the same code on both
        qd demo --rebuild > /dev/null
        assert_eq "$(runs_in demo)" "7"
        assert_eq "$(qd show demo-kernel:hosts --store demo --cols host --format csv | tail -n +2 | grep -c .)" "24"
        assert_eq "$(active_store)" "mine"
    fi
    out="$(qd store rm demo --delete)"
    assert_contains "$out" "demo deleted"
    assert_no_file "$(demo_root)"
    assert_eq "$(active_store)" "mine"
}

# -- what qd demo will not do --------------------------------------------------------

# Somebody's own store called demo is never the demo's to replace, nor a
# directory where the demo would go.
t_leaves_a_store_that_is_not_the_demo_alone() {
    fresh_machine
    printf 'host,v\na,1\n' > t.csv
    qd store new demo > /dev/null
    qd import t.csv --store demo --name mine > /dev/null
    for flag in "" --rebuild; do
        # shellcheck disable=SC2086  # an empty flag is no word
        qd_rc demo $flag 2> err
        assert_status "$QD_RC" 2
        assert_contains "$(cat err)" "there is a store named demo that is not qd's demo"
    done
    assert_eq "$(runs_in demo)" "1"
    qd store rm demo > /dev/null
    qd_rc demo 2> err
    assert_status "$QD_RC" 2
    assert_contains "$(cat err)" "holds files that are not qd's demo: nothing deleted"
    assert_eq "$(runs_in "$(demo_root)")" "1"
}

# Stopped part-way, a demo leaves nothing behind: no half a week to read
# back as if it were the whole.  With no provost, nothing is begun.
t_a_demo_that_fails_leaves_nothing() {
    local real="$QD_PROVOST" ok=1
    has_batch || ok=26      # a call a capture: the first run's, then no more
    fresh_machine
    cat > "$TEST_TMPDIR/flaky-provost" <<EOF
#!/usr/bin/env bash
# provost, until it has filed $ok times
case "\$*" in *--help*) exec $real "\$@" ;; esac
n=\$((\$(cat "$TEST_TMPDIR/calls" 2>/dev/null || echo 0) + 1))
echo "\$n" > "$TEST_TMPDIR/calls"
[ "\$n" -le $ok ] || { echo "provost: no space left on device" >&2; exit 1; }
exec $real "\$@"
EOF
    chmod +x "$TEST_TMPDIR/flaky-provost"
    QD_PROVOST="$TEST_TMPDIR/flaky-provost" qd_rc demo > out 2> err
    assert_status "$QD_RC" 2
    assert_contains "$(cat err)" "provost"
    assert_no_file "$(demo_root)"
    assert_not_contains "$(qd store ls)" "demo"
    QD_PROVOST="$TEST_TMPDIR/no-such-provost" PATH="$(path_without provost)" \
        qd_rc demo 2> err
    assert_status "$QD_RC" 2
    assert_contains "$(cat err)" "provost, which is not installed here"
    assert_no_file "$(demo_root)"
    assert_not_contains "$(qd store ls)" "demo"
}

# The stand-in that answers for the demo's hosts is no launcher a run can
# ask for: not --via, not QD_VIA, not a word of qd run's help.
t_the_stand_in_is_out_of_reach() {
    fresh_machine
    qd_rc run --via demo -S demo-r1n01 -- true 2> err
    assert_status "$QD_RC" 2
    assert_contains "$(cat err)" "--via demo (QD_VIA): not a launcher qd knows"
    QD_VIA=demo qd_rc run -S demo-r1n01 -- true 2> err
    assert_status "$QD_RC" 2
    assert_contains "$(cat err)" "not a launcher qd knows"
    qd_rc doctor --via demo 2> err
    assert_status "$QD_RC" 2
    assert_contains "$(cat err)" "--via demo (QD_VIA): not a launcher qd knows"
    assert_not_contains "$(qd run --help)" "demo"
    "$PY" -c 'import sys; sys.path.insert(0, sys.argv[1])
from quarterdeck import launch
assert "demo" not in launch.VIAS, launch.VIAS' "$QD_DIR"
    # and qd demo takes no fleet: no hosts, no launcher
    qd_rc demo -s hosts.txt 2> err
    assert_status "$QD_RC" 2
    qd_rc demo --via ssh 2> err
    assert_status "$QD_RC" 2
}

# -- where qd says it ------------------------------------------------------------

t_limits_help_hints_and_doctor() {
    fresh_machine
    out="$(qd demo --limits)"
    assert_eq "$out" "$(cat "$QD_DIR/quarterdeck/demo/limits.csv")"
    assert_contains "$out" "req,column,op,limit"
    qd_rc demo --store elsewhere 2> err
    assert_status "$QD_RC" 2
    assert_contains "$(cat err)" "files into the store named demo, and no other"
    for out in "$(qd --help)" "$(qd hints)"; do
        assert_contains "$out" "qd demo"
        assert_contains "$out" "docs/getting-started.md"
    done
    # nothing in the store: the demo is something to learn on
    out="$(qd doctor --store "$TEST_TMPDIR/empty" 2>&1 || true)"
    assert_contains "$out" "* qd demo"
    # and qd setup the way onto your own fleet (QD-065)
    assert_contains "$out" "* qd setup "
    printf 'host,v\na,1\n' > t.csv
    qd import t.csv --store "$TEST_TMPDIR/full" > /dev/null
    out="$(qd doctor --store "$TEST_TMPDIR/full" 2>&1 || true)"
    assert_not_contains "$out" "qd demo"
    assert_not_contains "$out" "qd setup"
}

# The page's map names every command qd has, the README points at the page
# from its top and from "Thirty seconds", and no output on the page lost a
# column to the width it was checked at.
t_the_page_the_map_and_the_readme() {
    local verbs v readme
    verbs="$("$PY" -c 'import sys; sys.path.insert(0, sys.argv[1])
from quarterdeck.cli import build_parser
print("\n".join(build_parser()[1].choices))' "$QD_DIR")"
    map="$(sed -n '/^## Every command, by what it is for/,$p' "$GUIDE")"
    [ -n "$map" ] || fail "the page has no map"
    for v in $verbs; do
        assert_contains "$map" "\`qd $v\`"
    done
    assert_not_contains "$(cat "$GUIDE")" "not shown: "
    readme="$(cat "$QD_DIR/README.md")"
    assert_contains "$(head -n 40 "$QD_DIR/README.md")" "docs/getting-started.md"
    assert_contains "$(sed -n '/^## Thirty seconds/,/^---/p' "$QD_DIR/README.md")" "qd demo"
    assert_contains "$readme" "(docs/getting-started.md)"
}

# The demo's answers are package data: the plan names only files that are
# there, every answers file answers for every host in the demo's hosts.txt
# and no other, and the wheel and the sdist take the directory.
t_the_answers_are_package_data() {
    "$PY" - "$QD_DIR" <<'EOF'
import os, sys
sys.path.insert(0, sys.argv[1])
from quarterdeck import demo, hosts
hs = [h.name for h in hosts.collect_hosts(servers=[demo.data("hosts.txt")])]
assert len(hs) == 24 and all(h.startswith("demo-") for h in hs), hs
plan = demo.read_plan()
assert len(plan) == 7, plan
for at, name, answers, command in plan:
    assert name.startswith("demo-"), name
    got = demo.read_answers(answers)
    assert sorted(got) == sorted(hs), (answers, sorted(set(got) ^ set(hs)))
    for h, a in got.items():
        assert a.status == "ok" and a.text or a.status != "ok", (answers, h)
EOF
    assert_contains "$(cat "$QD_DIR/pyproject.toml")" '"demo/*"'
    assert_contains "$(cat "$QD_DIR/MANIFEST.in")" "quarterdeck/demo"
}

# the two that file the demo first: different runners under --shard
run_test "the walkthrough: every command prints what the page shows" t_walkthrough
run_test "again: left alone; --rebuild files it afresh; store rm" t_again_and_rebuild
run_test "a store called demo that is not the demo: left alone" t_leaves_a_store_that_is_not_the_demo_alone
run_test "a demo that fails part-way leaves nothing"              t_a_demo_that_fails_leaves_nothing
run_test "the stand-in launcher is out of a run's reach"           t_the_stand_in_is_out_of_reach
run_test "--limits, --help, hints and doctor name the demo"        t_limits_help_hints_and_doctor
run_test "the page's map, its width, and the README's links"       t_the_page_the_map_and_the_readme
run_test "the answers are package data, one for every host"        t_the_answers_are_package_data
finish
