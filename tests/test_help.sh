#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Martin J. Gallagher

# The help qd gives, checked against qd itself: `qd --help` has a usage
# line for every verb the parser registers (QD-043), under the goal
# headings, in at most 50 lines of 80 columns with six examples at most
# (QD-040), every command `qd hints` suggests still parses (QD-045), its
# headings are the card's (QD-040), and every README pointer in qd's
# code names a section the README has (QD-046,
# tests/check_readme_pointers.py, which tests/check.sh also runs), and `qd
# help VERB` prints what `qd VERB --help` does (QD-044).  Bare `qd`, `qd
# start` and `qd help basics` print the start card, at most 25 lines of
# 80 columns, every command on it a registered verb that parses, while
# `qd --help` and `qd -h` keep the full card (QD-058).  Each check is
# also run on a broken copy, to show it can fail.
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

# unit_count: how many verbs build_parser() registers
unit_count() {
    "$PY" -c 'import sys; sys.path.insert(0, sys.argv[1])
from quarterdeck import cli; print(len(cli.build_parser()[1].choices))' "$QD_DIR"
}

t_card_lists_every_verb() {
    qd --help > card.txt
    unit card card.txt
    assert_status "$RC" 0
    assert_eq "$OUT" "ok"
    # the store's commands, which every "no store" message names
    assert_contains "$(cat card.txt)" "qd store new|ls|use|rename|rm|clear|export|import"
    # what the card keeps besides the commands (QD-040)
    for want in "RUN: latest" "QD_STORE" "Exit status" "qd demo" \
        "docs/getting-started.md" "Full manual: " "qd hints | doctor"; do
        assert_contains "$(cat card.txt)" "$want"
    done
}

t_card_fits_a_screen() {
    qd --help > card.txt
    lines="$(wc -l < card.txt | tr -d ' ')"
    [ "$lines" -le 50 ] || fail "qd --help is $lines lines, over 50"
    assert_eq "$(awk 'length > 80' card.txt)" ""
    # the core loop's examples: six at most
    n="$(sed -n '/^The core loop:/,/^$/p' card.txt | grep -c '^  qd ')"
    [ "$n" -ge 1 ] && [ "$n" -le 6 ] || fail "$n example lines"
    assert_eq "$(grep -c '^Examples' card.txt)" "0"
}

t_card_check_names_a_verb_with_no_line() {
    qd --help > card.txt
    grep -v '^ *qd store ' card.txt > no-store.txt
    unit card no-store.txt
    assert_status "$RC" 1
    assert_eq "$OUT" "store"
    # one of the run-together verbs
    sed 's/|outliers RUN/ RUN/' card.txt > no-outliers.txt
    unit card no-outliers.txt
    assert_status "$RC" 1
    assert_eq "$OUT" "outliers"
    # one of the verbs after a spaced |
    sed 's/| doctor \[HOST\] //' card.txt > no-doctor.txt
    unit card no-doctor.txt
    assert_status "$RC" 1
    assert_eq "$OUT" "doctor"
    # run's own line gone: campaign's and doe's `run` sub-commands, and
    # the core loop's example, do not stand in for it
    grep -v '^  qd run \[HOSTS\]' card.txt > no-run.txt
    unit card no-run.txt
    assert_status "$RC" 1
    assert_eq "$OUT" "run"
    # a verb on two lines
    sed 's/^  qd diff /  qd diff|web /' card.txt > twice.txt
    unit card twice.txt
    assert_status "$RC" 1
    assert_eq "$OUT" "twice: web"
    # the headings out of order, or one renamed
    awk '$0 == "Over time" { $0 = "Later" } { print }' card.txt > renamed.txt
    unit card renamed.txt
    assert_status "$RC" 1
    assert_contains "$OUT" "headings: Run, Read it back, Judge and report,"
    # an example that no longer parses
    sed 's/^  qd freq latest A /  qd freq latest A --srevers/' card.txt > bad-example.txt
    unit card bad-example.txt
    assert_status "$RC" 1
    assert_contains "$OUT" "example: qd freq latest A --srevers"
}

t_hints_prints_every_hint() {
    qd hints > hints.txt
    unit hints-count
    assert_status "$RC" 0
    # one line a hint, under the card's headings, in the card's order
    assert_eq "$(grep -c '^  ' hints.txt)" "$OUT"
    assert_contains "$(head -n 1 hints.txt)" "hints -- what you want to know"
    assert_contains "$(cat hints.txt)" "qd outliers latest COLUMN"
    unit groups
    assert_eq "$(sed -n '2,$p' hints.txt | grep -v '^  ' | grep -v '^$')" "$OUT"
    # and those are the card's own
    qd --help > card.txt
    assert_eq "$(grep -Fx -f <(printf '%s\n' "$OUT") card.txt)" "$OUT"
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

t_help_verb_is_the_verbs_help() {
    # every verb, through main(), both ways
    unit verb-help
    assert_status "$RC" 0
    assert_eq "$OUT" "ok $(unit_count)"
    unit verb-help cut
    assert_status "$RC" 1
    assert_contains "$OUT" "run: qd help run and qd run --help differ"
    # and through qd itself: run, and the two whose lists main() cuts at --
    for v in run campaign doe; do
        qd "$v" --help > want.txt
        qd help "$v" > got.txt
        assert_eq "$(cat got.txt)" "$(cat want.txt)"
        assert_contains "$(head -n 1 got.txt)" "usage: qd $v "
    done
    # a global option before VERB does not break the parse
    qd help --store elsewhere run > got.txt
    qd run --help > want.txt
    assert_eq "$(cat got.txt)" "$(cat want.txt)"
    # bare qd help is still everything, and the card names qd help VERB
    out="$(qd help)"
    assert_contains "$out" "usage: qd run "
    assert_contains "$out" "usage: qd web "
    assert_contains "$(qd --help)" "| demo | help [VERB]"
}

t_help_unknown_verb_names_the_closest() {
    qd_rc help stat 2> err.txt > out.txt
    assert_status "$QD_RC" 2
    assert_eq "$(cat err.txt)" \
        "qd: no verb 'stat'; the closest: stats, start; qd --help lists them all"
    assert_eq "$(cat out.txt)" ""
    # nothing close: the three nearest all the same
    qd_rc help nosuch 2> err.txt
    assert_status "$QD_RC" 2
    assert_contains "$(cat err.txt)" "qd: no verb 'nosuch'; the closest: "
    assert_contains "$(cat err.txt)" "; qd --help lists them all"
    assert_eq "$(tr -cd ',' < err.txt)" ",,"
}

t_bare_qd_prints_the_start_card() {
    qd > start.txt
    head -n 1 start.txt > title.txt
    assert_contains "$(cat title.txt)" "qd -- run a command on many machines"
    lines="$(wc -l < start.txt | tr -d ' ')"
    [ "$lines" -le 25 ] || fail "bare qd is $lines lines, over 25"
    assert_eq "$(awk 'length > 80' start.txt)" ""
    for want in "Getting started" "qd demo " "qd odd " "qd log " \
        "qd show latest " "qd web " "qd --help" "qd help VERB" "qd hints"; do
        assert_contains "$(cat start.txt)" "$want"
    done
    # not the full card
    assert_eq "$(grep -c '^Exit status' start.txt)" "0"
    # the same card three ways, each exit 0
    for how in "start" "help basics"; do
        # shellcheck disable=SC2086
        qd_rc $how > other.txt
        assert_status "$QD_RC" 0
        assert_eq "$(cat other.txt)" "$(cat start.txt)"
    done
}

t_help_flag_keeps_the_full_card() {
    qd --help > card.txt
    qd -h > h.txt
    assert_eq "$(cat h.txt)" "$(cat card.txt)"
    for want in "Exit status" "Full manual: " "The core loop:"; do
        assert_contains "$(cat card.txt)" "$want"
    done
    qd > start.txt
    [ "$(cat card.txt)" != "$(cat start.txt)" ] || fail "qd --help is the start card"
    # and qd start has its line on it, under Help
    assert_contains "$(cat card.txt)" "qd hints | doctor [HOST] | start | demo"
}

t_start_card_names_only_verbs_that_parse() {
    qd > start.txt
    unit start start.txt
    assert_status "$RC" 0
    assert_eq "$OUT" "ok 9"
    # a command named that is not a verb
    awk '{ print } /^Getting started$/ { print "  qd poll -- uname -r          ask every host" }' \
        start.txt > ask.txt
    unit start ask.txt
    assert_status "$RC" 1
    assert_eq "$OUT" "not a verb: poll: qd poll -- uname -r"
    # a command that no longer parses, in the footer
    sed 's/Ideas: qd hints/Ideas: qd hints --srevers/' start.txt > flag.txt
    unit start flag.txt
    assert_status "$RC" 1
    assert_contains "$OUT" "qd hints --srevers: "
    assert_contains "$OUT" "unrecognized arguments: --srevers"
    # no command at all
    head -n 1 start.txt > none.txt
    unit start none.txt
    assert_status "$RC" 1
    assert_eq "$OUT" "no qd command on the card"
}

run_test "bare qd prints the start card"               t_bare_qd_prints_the_start_card
run_test "qd --help and -h keep the full card"         t_help_flag_keeps_the_full_card
run_test "the start card names only verbs that parse"  t_start_card_names_only_verbs_that_parse
run_test "qd --help lists every verb"                  t_card_lists_every_verb
run_test "qd --help fits a screen"                     t_card_fits_a_screen
run_test "the card check names a verb with no line"    t_card_check_names_a_verb_with_no_line
run_test "qd help VERB prints qd VERB --help"         t_help_verb_is_the_verbs_help
run_test "qd help NOSUCH names the closest verbs"     t_help_unknown_verb_names_the_closest
run_test "qd hints prints every hint"                  t_hints_prints_every_hint
run_test "every command qd hints suggests parses"      t_hints_every_command_parses
run_test "the hints check fails on a bad flag or verb" t_hints_check_fails_on_a_bad_flag_or_verb
run_test "every README pointer in the code lands"      t_readme_pointers_all_land
run_test "the pointer check fails where one does not land" \
    t_readme_pointer_check_fails_where_one_does_not_land
run_test "the pointer check refuses what it cannot read" \
    t_readme_pointer_check_refuses_a_pointer_it_cannot_read
finish
