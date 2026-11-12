#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Martin J. Gallagher

# The runner itself (QD-024): run_tests.sh --list, --shard K/N dealing
# every suite to exactly one share (or its parts, QD_TEST_PART, each to a
# different one), a failing suite failing its own share with its output
# whole, and the exit statuses as they were.  Most cases run a copy of the
# runner beside a few stand-in suites in the case's temp dir, so they take
# no time; tests/check_shards.sh is run here too, on the real suites and on
# a broken runner and workflow.

set -u
source "$(dirname "${BASH_SOURCE[0]}")/test_helper.bash"

TESTS="$QD_DIR/tests"

# fake_tree NAME[:STATUS]...: a copy of the runner in t/ beside stand-in
# suites, each printing three lines and exiting STATUS (0 if not given).
# TIMES and PARTS in the copy become FAKE_TIMES and FAKE_PARTS (none).
fake_tree() {
    local s name rc
    # the copy's suites run the real helper with a fake provost, which has
    # no `store check`: QD_STORE_CHECK=require would fail every case
    unset QD_TEST_ONLY QD_TEST_JOBS QD_STORE_CHECK
    mkdir -p t
    sed -e "s/^TIMES=.*/TIMES=\"${FAKE_TIMES:-}\"/" \
        -e "s/^PARTS=.*/PARTS=\"${FAKE_PARTS:-}\"/" \
        "$TESTS/run_tests.sh" > t/run_tests.sh
    grep -q "^PARTS=\"${FAKE_PARTS:-}\"$" t/run_tests.sh || fail "no PARTS line in the runner"
    cp "$TESTS/check_shards.sh" t/check_shards.sh
    for s in "$@"; do
        name="${s%%:*}"
        rc=0
        [ "$name" = "$s" ] || rc="${s#*:}"
        cat > "t/test_$name.sh" <<EOF
echo "  $name: first line"
echo "  $name: only=\${QD_TEST_ONLY:-}"
echo "  $name: last line"
exit $rc
EOF
    done
    # a provost the runner takes, without batch; no stand-in files anything
    printf '#!/bin/sh\nexit 1\n' > "$FAKE_BIN/provost"
    chmod +x "$FAKE_BIN/provost"
}

# runner ARGS...: the copy, with RC and OUT (stdout and stderr) kept
runner() {
    set +e
    OUT="$(QD_PROVOST="$FAKE_BIN/provost" bash t/run_tests.sh "$@" 2>&1)"
    RC=$?
    set -e
}

# the suites in the real tree, one a line, sorted
real_suites() {
    local f
    for f in "$TESTS"/test_*.sh; do
        f="${f##*/test_}"
        echo "${f%.sh}"
    done | LC_ALL=C sort
}

t_list_names_every_suite_once_and_needs_no_provost() {
    local out
    out="$(QD_PROVOST="" PATH="$(path_without provost)" \
        bash "$TESTS/run_tests.sh" --list)"
    assert_eq "$(echo "$out" | LC_ALL=C sort)" "$(real_suites)"
    assert_eq "$(echo "$out" | LC_ALL=C sort | uniq -d)" ""
    # every suite has a measured time: none counts as UNLISTED
    local name times
    times="$(sed -n 's/^TIMES="\(.*\)"$/ \1 /p' "$TESTS/run_tests.sh")"
    for name in $out; do
        case "$times" in
            *" $name:"*) ;;
            *) fail "$name is not in run_tests.sh's TIMES" ;;
        esac
    done
}

t_every_share_count_covers_every_suite_once() {
    local n k got
    for n in 1 2 3 4 5 7 24 30; do
        got="$(k=1; while [ "$k" -le "$n" ]; do
            bash "$TESTS/run_tests.sh" --list --shard "$k/$n"
            k=$((k + 1))
        done | LC_ALL=C sort)"
        # no unit twice, and every suite there, whole or in parts
        assert_eq "$(echo "$got" | uniq -d)" ""
        assert_eq "$(echo "$got" | sed 's/:.*//' | LC_ALL=C sort -u)" "$(real_suites)"
    done
    # one share: every suite whole, as without --shard
    assert_eq "$(bash "$TESTS/run_tests.sh" --list --shard 1/1 | LC_ALL=C sort)" \
        "$(real_suites)"
    # and what CI's workflow runs, parts and all
    local out
    out="$(bash "$TESTS/check_shards.sh")"
    assert_contains "$out" "each in exactly one share"
}

# a stand-in suite of seven cases on the real helper
helper_suite() {
    {
        echo "source \"$TESTS/test_helper.bash\""
        local c
        for c in 1 2 3 4 5 6 7; do
            echo "t_$c() { echo case $c > /dev/null; }"
            echo "run_test \"case $c\" t_$c"
        done
        echo "finish"
    } > "t/test_$1.sh"
}

t_a_split_suite_runs_each_case_once() {
    FAKE_TIMES="big:90 a:10 b:10" FAKE_PARTS="big:3" fake_tree a b
    helper_suite big
    # QD_TEST_PART: each part its share of the cases, all of them once
    local whole parts i
    whole="$(bash t/test_big.sh | grep '^  ok' | LC_ALL=C sort)"
    assert_eq "$(echo "$whole" | wc -l | tr -d ' ')" "7"
    parts="$(for i in 1 2 3; do QD_TEST_PART="$i/3" bash t/test_big.sh; done |
        grep '^  ok' | LC_ALL=C sort)"
    assert_eq "$parts" "$whole"
    assert_eq "$(QD_TEST_PART=2/3 bash t/test_big.sh | grep -c '^  ok')" "2"
    # with QD_TEST_ONLY too: the same cases are in the same part
    assert_eq "$(QD_TEST_PART=1/3 QD_TEST_ONLY='case 4' bash t/test_big.sh |
        grep '^  ok')" "  ok   case 4"
    set +e
    QD_TEST_PART=4/3 bash t/test_big.sh > out 2>&1
    RC=$?
    set -e
    assert_status "$RC" 2
    assert_contains "$(cat out)" "QD_TEST_PART is I/P"
    # the runner: three parts, each in a share of its own
    for i in 1 2 3; do
        runner --list --shard "$i/3"
        assert_eq "$(echo "$OUT" | grep -c '^big:')" "1"
    done
    runner -j 2 --shard 1/3
    assert_status "$RC" 0
    assert_contains "$OUT" "big:1/3
  ok   case 1
  ok   case 4
  ok   case 7"
    # a part's seconds say which part they are
    assert_contains "$(echo "$OUT" | grep '^seconds:')" " big:1/3:"
    # fewer shares than parts: as many parts as shares; one share: whole
    runner --list --shard 2/2
    assert_contains "$OUT" "big:2/2"
    runner --list --shard 1/1
    assert_eq "$(echo "$OUT" | tr '\n' ' ')" "a b big "
    # without --shard, whole
    runner -j 1 big
    assert_contains "$OUT" "big
  ok   case 1
  ok   case 2"
}

t_the_deal_is_longest_first_to_the_lightest_share() {
    # sorted: a 50, b 40, c 30, z 30 (not listed: UNLISTED), d 20, e 10
    # a->1 (50), b->2 (40), c->2 (70), z->1 (80), d->2 (90), e->1 (90)
    FAKE_TIMES="a:50 b:40 c:30 d:20 e:10" fake_tree a b c d e z
    runner --list --shard 1/2
    assert_status "$RC" 0
    assert_eq "$(echo "$OUT" | tr '\n' ' ')" "a e z "
    runner --list --shard 2/2
    assert_eq "$(echo "$OUT" | tr '\n' ' ')" "b c d "
    # named suites are dealt among themselves, and listed as named:
    # a 50 -> 1, z 30 -> 2, e 10 -> 2
    runner --list --shard 2/2 e z a
    assert_eq "$(echo "$OUT" | tr '\n' ' ')" "e z "
    runner -j 2
    assert_status "$RC" 0
    assert_contains "$OUT" "suites: 6, 2 at a time"
    assert_contains "$OUT" "seconds: "
}

t_a_bad_shard_is_refused_with_2() {
    fake_tree a b
    local v
    for v in "" 0/3 4/3 3 3/ /3 1/0 a/3 1/b 1/3/3 -1/3 01/3 1/03 " 1/3" \
            99999/99999; do
        runner --shard "$v"
        assert_status "$RC" 2
        assert_contains "$OUT" "--shard wants K/N"
        assert_not_contains "$OUT" "a: first line"
    done
    runner --shard
    assert_status "$RC" 2
    assert_contains "$OUT" "--shard wants K/N"
    runner --shard=2/2
    assert_status "$RC" 0
}

t_a_failing_suite_fails_its_share_and_shows_whole() {
    # bad lands in share 1 of 2 with good1; good2 and good3 in share 2
    FAKE_TIMES="bad:50 good1:10 good2:40 good3:20" \
        fake_tree bad:1 good1 good2 good3
    local j
    for j in 1 2; do
        runner -j "$j" --shard 1/2
        assert_status "$RC" 1
        assert_contains "$OUT" "shard 1/2: bad good1"
        assert_contains "$OUT" "1 suite(s) failed"
        # its three lines, together and in order
        assert_contains "$OUT" "  bad: first line
  bad: only=
  bad: last line"
        runner -j "$j" --shard 2/2
        assert_status "$RC" 0
        assert_contains "$OUT" "shard 2/2: good2 good3"
        assert_contains "$OUT" "all suites passed"
        assert_not_contains "$OUT" "bad:"
    done
}

t_more_shares_than_suites_runs_nothing_and_passes() {
    fake_tree a b
    runner --shard 3/3
    assert_status "$RC" 0
    assert_contains "$OUT" "shard 3/3: no suites"
    runner --list --shard 3/3
    assert_status "$RC" 0
    assert_eq "$OUT" ""
}

t_the_runner_otherwise_runs_as_before() {
    fake_tree one two three:1
    # -j 1: the serial run
    runner -j 1 one two
    assert_status "$RC" 0
    assert_contains "$OUT" "one
  one: first line"
    assert_contains "$OUT" "all suites passed"
    assert_not_contains "$OUT" "three:"
    # -j N: every suite, output whole, the time and every suite's seconds
    runner -j 3
    assert_status "$RC" 1
    assert_contains "$OUT" "suites: 3, 3 at a time"
    assert_contains "$OUT" "1 suite(s) failed"
    assert_contains "$OUT" "time: "
    assert_contains "$OUT" "seconds: "
    # QD_TEST_ONLY reaches the suites
    export QD_TEST_ONLY=xyz
    runner -j 2 one two
    unset QD_TEST_ONLY
    assert_status "$RC" 0
    assert_contains "$OUT" "one: only=xyz"
    # usage and missing things: 2
    runner nosuch
    assert_status "$RC" 2
    assert_contains "$OUT" "no such suite: test_nosuch.sh"
    runner -j 0
    assert_status "$RC" 2
    runner --nosuch
    assert_status "$RC" 2
    set +e
    OUT="$(QD_PROVOST="" PATH="$(path_without provost)" bash t/run_tests.sh one 2>&1)"
    RC=$?
    set -e
    assert_status "$RC" 2
    assert_contains "$OUT" "no provost"
    runner --help
    assert_status "$RC" 0
    assert_contains "$OUT" "--shard K/N"
    assert_contains "$OUT" "Exit status: 0"
}

t_check_shards_fails_a_gap_or_a_suite_in_two() {
    fake_tree a b c d e
    cat > wf.yml <<'EOF'
jobs:
  good:
    strategy:
      matrix:
        python-version: ["3.12"]
        shard: [1, 2, 3]
    steps:
      # run_tests.sh --shard K/N in a comment is not a job's
      - run: bash tests/run_tests.sh --shard ${{ matrix.shard }}/3
EOF
    bash t/check_shards.sh wf.yml > out 2>&1 || fail "$(cat out)"
    assert_contains "$(cat out)" "each in exactly one share"
    # a matrix that leaves a share out
    sed 's/shard: \[1, 2, 3\]/shard: [1, 2]/' wf.yml > gap.yml
    set +e
    bash t/check_shards.sh gap.yml > out 2>&1
    RC=$?
    set -e
    assert_status "$RC" 1
    assert_contains "$(cat out)" "good: runs shares of 3 but its matrix lists shard: [1,2], not [1,2,3]"
    # a --shard that is not the matrix's
    sed 's|\${{ matrix.shard }}/3|1/3|' wf.yml > fixed.yml
    set +e
    bash t/check_shards.sh fixed.yml > out 2>&1
    RC=$?
    set -e
    assert_status "$RC" 1
    assert_contains "$(cat out)" "good: --shard is not"
    # mutation: a runner that keeps every suite in share 1 as well
    # shellcheck disable=SC2016  # a sed script and a pattern, not expansions
    sed 's/\[ "\$best" -eq \$((k - 1)) \] && keep\[i\]=1/{ [ "$best" -eq $((k - 1)) ] || [ "$k" -eq 1 ]; } \&\& keep[i]=1/' \
        t/run_tests.sh > t/r && mv t/r t/run_tests.sh
    # shellcheck disable=SC2016  # a sed script and a pattern, not expansions
    grep -q '\[ "\$k" -eq 1 \]' t/run_tests.sh || fail "the mutation did not apply"
    set +e
    bash t/check_shards.sh wf.yml > out 2>&1
    RC=$?
    set -e
    assert_status "$RC" 1
    assert_contains "$(cat out)" "in two or more:"
    # mutation: a runner that drops the last suite it deals
    fake_tree a b c d e
    # shellcheck disable=SC2016  # a sed script and a pattern, not expansions
    sed 's/^    for i in \$(by_time); do$/    for i in $(by_time | sed "$ d"); do/' \
        t/run_tests.sh > t/r && mv t/r t/run_tests.sh
    grep -q 'by_time | sed' t/run_tests.sh || fail "the mutation did not apply"
    set +e
    bash t/check_shards.sh wf.yml > out 2>&1
    RC=$?
    set -e
    assert_status "$RC" 1
    assert_contains "$(cat out)" "in none:"
    # mutation: a runner that lets two parts of a suite share a runner
    FAKE_TIMES="big:90 a:80 b:80" FAKE_PARTS="big:2" fake_tree a b
    helper_suite big
    bash t/check_shards.sh wf.yml > out 2>&1 || fail "$(cat out)"
    sed 's/\*" \${files\[\$i\]} "\*) ;;/*" no such suite "*) ;;/' \
        t/run_tests.sh > t/r && mv t/r t/run_tests.sh
    grep -q 'no such suite "' t/run_tests.sh || fail "the mutation did not apply"
    set +e
    bash t/check_shards.sh wf.yml > out 2>&1
    RC=$?
    set -e
    assert_status "$RC" 1
    assert_contains "$(cat out)" "two parts in one share: big"
}

run_test "--list: every suite once, no provost needed"   t_list_names_every_suite_once_and_needs_no_provost
run_test "every share count covers every suite once"     t_every_share_count_covers_every_suite_once
run_test "the deal: longest first, to the lightest"      t_the_deal_is_longest_first_to_the_lightest_share
run_test "a bad --shard is refused with 2"              t_a_bad_shard_is_refused_with_2
run_test "a split suite runs each case once"           t_a_split_suite_runs_each_case_once
run_test "a failing suite fails its share, whole"       t_a_failing_suite_fails_its_share_and_shows_whole
run_test "more shares than suites: nothing, and 0"      t_more_shares_than_suites_runs_nothing_and_passes
run_test "the runner otherwise runs as before"          t_the_runner_otherwise_runs_as_before
run_test "check_shards fails a gap or a suite in two"   t_check_shards_fails_a_gap_or_a_suite_in_two
finish
