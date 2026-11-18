#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Martin J. Gallagher

# The help qd gives, checked against qd itself: `qd --help` has a usage
# line for every verb the parser registers (QD-043), every command `qd
# hints` suggests still parses (QD-045), and every README pointer in qd's
# code names a section the README has (QD-046,
# tests/check_readme_pointers.py, which tests/check.sh also runs).  Each
# check is also run on a broken copy, to show it can fail.
# tests/help_unit.py does the reading for the first two.

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

t_hints_prints_every_hint() {
    qd hints > hints.txt
    unit hints-count
    assert_status "$RC" 0
    # a title, a blank line, then one line a hint
    assert_eq "$(wc -l < hints.txt | tr -d ' ')" "$((OUT + 2))"
    assert_contains "$(head -n 1 hints.txt)" "hints -- what you want to know"
    assert_contains "$(cat hints.txt)" "qd outliers latest COLUMN"
}

t_hints_every_command_parses() {
    unit hints
    assert_status "$RC" 0
    assert_eq "$OUT" "ok"
}

t_hints_check_fails_on_a_bad_flag_or_verb() {
    unit hints flag
    assert_status "$RC" 1
    assert_contains "$OUT" "Is my host list even real?: qd run --srevers hosts.txt"
    assert_contains "$OUT" "unrecognized arguments: --srevers"
    unit hints verb
    assert_status "$RC" 1
    assert_contains "$OUT" "Who is far from the rest?: qd outlyers latest COLUMN"
    assert_contains "$OUT" "invalid choice: 'outlyers'"
}

# pointers [ROOT]: tests/check_readme_pointers.py, with OUT and RC kept
pointers() {
    set +e
    OUT="$("$PY" "$QD_DIR/tests/check_readme_pointers.py" "$@")"
    RC=$?
    set -e
}

# a copy of the code and the README to break, in tree/
copy_tree() {
    mkdir -p tree/quarterdeck
    cp "$QD_DIR"/quarterdeck/*.py tree/quarterdeck/
    cp "$QD_DIR/README.md" tree/
}

# edit FILE SED-SCRIPT: sed FILE in place, as BSD and GNU sed both can
edit() { sed "$2" "$1" > "$1.new" && mv "$1.new" "$1"; }

t_readme_pointers_all_land() {
    pointers
    assert_status "$RC" 0
    assert_contains "$OUT" "every one names a section of README.md"
    # the one that had gone stale, as it is now
    assert_contains "$(cat "$QD_DIR/quarterdeck/exporters.py")" \
        '(README: "Into Splunk, Prometheus or a notebook")'
}

t_readme_pointer_check_fails_where_one_does_not_land() {
    copy_tree
    pointers tree
    assert_status "$RC" 0
    # the section's name before it was renamed
    edit tree/quarterdeck/exporters.py \
        's/README: "Into Splunk, Prometheus or a notebook"/README: "Sending a run to Splunk or Prometheus"/'
    pointers tree
    assert_status "$RC" 1
    assert_eq "$OUT" 'quarterdeck/exporters.py:8: README has no section "Sending a run to Splunk or Prometheus"'
    # a heading renamed under a pointer
    copy_tree
    edit tree/README.md 's/^### Allow-lists and read-only$/### Allow-lists/'
    pointers tree
    assert_status "$RC" 1
    assert_contains "$OUT" 'quarterdeck/policy.py:'
    assert_contains "$OUT" 'README has no section "Allow-lists and read-only"'
    # a `# comment` in an example is not a section
    copy_tree
    edit tree/quarterdeck/policy.py 's/README: "Allow-lists and read-only"/README: "cloudvision.map"/'
    grep -q '^# cloudvision.map$' tree/README.md || fail "the README's example lost its comment"
    pointers tree
    assert_status "$RC" 1
    assert_contains "$OUT" 'README has no section "cloudvision.map"'
}

t_readme_pointer_check_refuses_a_pointer_it_cannot_read() {
    copy_tree
    # the old style, and a pointer cut over two lines
    edit tree/quarterdeck/exporters.py \
        's/(README: "Into Splunk, Prometheus or a notebook")/(README, "Into Splunk, Prometheus or a notebook")/'
    printf '# see the README: "Telemetry\n# exports"\n' >> tree/quarterdeck/policy.py
    pointers tree
    assert_status "$RC" 1
    assert_contains "$OUT" "quarterdeck/exporters.py:8: a README mention this check cannot read"
    assert_contains "$OUT" "quarterdeck/policy.py:"
    assert_eq "$(printf '%s\n' "$OUT" | wc -l | tr -d ' ')" "2"
    # README.md, the file's name, is not a pointer
    copy_tree
    printf '# README.md ships in the sdist\n' >> tree/quarterdeck/policy.py
    pointers tree
    assert_status "$RC" 0
    # no manual at all
    mkdir empty
    pointers empty
    assert_status "$RC" 2
}

run_test "qd --help lists every verb"                  t_card_lists_every_verb
run_test "the card check names a verb with no line"    t_card_check_names_a_verb_with_no_line
run_test "qd hints prints every hint"                  t_hints_prints_every_hint
run_test "every command qd hints suggests parses"      t_hints_every_command_parses
run_test "the hints check fails on a bad flag or verb" t_hints_check_fails_on_a_bad_flag_or_verb
run_test "every README pointer in the code lands"      t_readme_pointers_all_land
run_test "the pointer check fails where one does not land" \
    t_readme_pointer_check_fails_where_one_does_not_land
run_test "the pointer check refuses what it cannot read" \
    t_readme_pointer_check_refuses_a_pointer_it_cannot_read
finish
