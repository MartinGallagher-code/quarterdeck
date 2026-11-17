#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Martin J. Gallagher

# The help qd gives, checked against qd itself: `qd --help` has a usage
# line for every verb the parser registers (QD-043).  Each check is also
# run on a broken copy, to show it can fail.  tests/help_unit.py does the
# reading.

set -u
source "$(dirname "${BASH_SOURCE[0]}")/test_helper.bash"

# unit CASE ARGS...: tests/help_unit.py, with OUT and RC kept
unit() {
    set +e
    OUT="$("$PY" "$QD_DIR/tests/help_unit.py" "$QD_DIR" "$@")"
    RC=$?
    set -e
}

t_card_lists_every_verb() {
    qd --help > card.txt
    unit card card.txt
    assert_status "$RC" 0
    assert_eq "$OUT" "ok"
    # the store's commands, which every "no store" message names
    assert_contains "$(cat card.txt)" "qd store new|ls|use|rename|rm|clear|export|import"
}

t_card_check_names_a_verb_with_no_line() {
    qd --help > card.txt
    grep -v '^ *qd store ' card.txt > no-store.txt
    unit card no-store.txt
    assert_status "$RC" 1
    assert_eq "$OUT" "store"
    # one of the run-together verbs
    sed 's/|outliers|/|/' card.txt > no-outliers.txt
    unit card no-outliers.txt
    assert_status "$RC" 1
    assert_eq "$OUT" "outliers"
    # one of the verbs after a spaced |
    sed 's/| hints |/|/' card.txt > no-hints.txt
    unit card no-hints.txt
    assert_status "$RC" 1
    assert_eq "$OUT" "hints"
    # run's own line gone: campaign's and doe's `run` sub-commands do not
    # stand in for it
    sed 's/^Usage: qd run .*/Usage:/' card.txt > no-run.txt
    unit card no-run.txt
    assert_status "$RC" 1
    assert_eq "$OUT" "run"
}

run_test "qd --help lists every verb"                  t_card_lists_every_verb
run_test "the card check names a verb with no line"    t_card_check_names_a_verb_with_no_line
finish
