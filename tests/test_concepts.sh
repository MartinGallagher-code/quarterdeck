#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Martin J. Gallagher

# docs/concepts.md (QD-042), the words and run references every qd command
# assumes, checked against qd itself: every qd command on the page parses,
# every way of naming a run the resolver takes is on the page (and nothing
# it does not take), its links land and the README, the walkthrough and
# `qd --help` point at it.  tests/concepts_unit.py does the reading; each
# check is also run on a broken copy, to show it can fail.  The page's
# examples are run against the demo store in tests/test_demo.sh, which
# files one.

# shellcheck disable=SC2016  # the backticks in sed scripts are Markdown's
set -u
source "$(dirname "${BASH_SOURCE[0]}")/test_helper.bash"

PAGE="$QD_DIR/docs/concepts.md"

# unit ROOT CASE ARGS...: tests/concepts_unit.py, with OUT and RC kept
unit() {
    set +e
    OUT="$("$PY" "$QD_DIR/tests/concepts_unit.py" "$@")"
    RC=$?
    set -e
}

# a copy of the code, the README and the docs to break, in tree/
copy_tree() {
    rm -rf tree
    mkdir -p tree
    cp -R "$QD_DIR/quarterdeck" "$QD_DIR/docs" "$QD_DIR/README.md" tree/
}

# edit FILE SED-SCRIPT: sed FILE in place, as BSD and GNU sed both can
edit() { sed "$2" "$1" > "$1.new" && mv "$1.new" "$1"; }

# a provost clone's tree, where QD_PROVOST is one: its docs are checked too
provost_tree() {
    local p
    p="$(dirname "$(printf '%s' "$PROVOST_CMD" | awk '{print $NF}')")"
    [ -f "$p/docs/store-format.md" ] && echo "$p"
    return 0
}

t_every_command_parses() {
    unit "$QD_DIR" examples
    assert_status "$RC" 0
    assert_contains "$OUT" "every one parses"
}

t_examples_check_fails_on_a_bad_flag_or_verb() {
    copy_tree
    edit tree/docs/concepts.md 's/qd show latest~1/qd show latest~1 --colls host/'
    unit tree examples
    assert_status "$RC" 1
    assert_contains "$OUT" "qd show latest~1 --colls host"
    assert_contains "$OUT" "unrecognized arguments: --colls"
    copy_tree
    edit tree/docs/concepts.md 's/`qd peers define sku --by sku`/`qd peer define sku --by sku`/'
    unit tree examples
    assert_status "$RC" 1
    assert_contains "$OUT" "invalid choice: 'peer'"
    # a verb named in a sentence must still be one
    copy_tree
    edit tree/docs/concepts.md 's/which `qd check` gives/which `qd chek` gives/'
    unit tree examples
    assert_status "$RC" 1
    assert_contains "$OUT" "invalid choice: 'chek'"
}

t_every_form_is_on_the_page() {
    unit "$QD_DIR" forms
    assert_status "$RC" 0
    for f in latest latest~N prev ds:NAME RUN:TABLE RUN@STORE ID PART NAME FILE; do
        assert_contains "$OUT" " $f"
    done
}

t_forms_check_fails_when_page_and_code_part() {
    # a form gone from the page
    copy_tree
    edit tree/docs/concepts.md '/^| `prev`, `prev~N` |/d'
    unit tree forms
    assert_status "$RC" 1
    assert_eq "$OUT" "docs/concepts.md: the resolver takes prev, which the page does not name"
    # a word the resolver gains
    copy_tree
    edit tree/quarterdeck/store.py 's/(latest|last|prev)?/(latest|last|prev|newest)?/'
    unit tree forms
    assert_status "$RC" 1
    assert_eq "$OUT" "docs/concepts.md: the resolver takes newest, which the page does not name"
    # a prefix renamed
    copy_tree
    edit tree/quarterdeck/store.py 's/ref.startswith("ds:")/ref.startswith("dataset:")/'
    unit tree forms
    assert_status "$RC" 1
    assert_contains "$OUT" "the resolver takes dataset:NAME"
    assert_contains "$OUT" "ds:NAME is no form the resolver takes"
    # a store split on another character
    copy_tree
    edit tree/quarterdeck/store.py 's/a, _, b = ref.rpartition("@")/a, _, b = ref.rpartition("+")/'
    unit tree forms
    assert_status "$RC" 1
    assert_contains "$OUT" "the resolver takes RUN+STORE"
    # a way of resolving this check does not know
    copy_tree
    edit tree/quarterdeck/store.py 's/^\( *\)return named\[-1\]$/\1return named[0]/'
    unit tree forms
    assert_status "$RC" 1
    assert_contains "$OUT" "resolve() returns named[0], a form this check does not know"
    # a form the page names that the resolver does not take, and a row
    # with no example
    copy_tree
    edit tree/docs/concepts.md 's/^| `latest`, `last` | the newest run | `qd show latest` |$/| `latest`, `newest` | the newest run | qd show latest |/'
    unit tree forms
    assert_status "$RC" 1
    assert_contains "$OUT" "newest is no form the resolver takes"
    assert_contains "$OUT" "the resolver takes last, which the page does not name"
    assert_contains "$OUT" "latest/newest has no example"
}

t_links_land() {
    local pt
    pt="$(provost_tree)"
    unit "$QD_DIR" links ${pt:+"$pt"}
    assert_status "$RC" 0
    assert_contains "$OUT" "every one lands"
}

t_links_check_fails_where_one_does_not_land() {
    copy_tree
    edit tree/docs/concepts.md 's/(..\/README.md#waivers)/(..\/README.md#waiver)/'
    unit tree links
    assert_status "$RC" 1
    assert_contains "$OUT" "docs/concepts.md:"
    assert_contains "$OUT" "../README.md#waiver: no heading #waiver there"
    # a link to the page, to a heading it does not have
    copy_tree
    edit tree/README.md 's/(docs\/concepts.md#naming-a-run)/(docs\/concepts.md#run-references)/'
    unit tree links
    assert_status "$RC" 1
    assert_contains "$OUT" "README.md:"
    assert_contains "$OUT" "no heading #run-references there"
    # a file of this repository on GitHub that it does not have
    copy_tree
    printf '\n[x](https://github.com/MartinGallagher-code/quarterdeck/blob/main/docs/nowhere.md)\n' \
        >> tree/docs/concepts.md
    unit tree links
    assert_status "$RC" 1
    assert_contains "$OUT" "docs/nowhere.md: no such file"
    # the walkthrough no longer pointing at it
    copy_tree
    edit tree/docs/getting-started.md 's/\[Concepts\](concepts.md[^)]*)/Concepts/g'
    unit tree links
    assert_status "$RC" 1
    assert_eq "$OUT" "docs/getting-started.md: no link to docs/concepts.md"
}

# What points at the page, and what moved to it: qd --help's RUN paragraph
# ends with it, the README's first `qd freq latest A` says what A is, and
# "Named stores" links to the table rather than keeping a copy.  The page
# stays short, its picture fits 60 columns, and the sdist ships it.
t_pointers_and_the_page() {
    local para readme
    para="$(qd --help | sed -n '/^RUN[: ]/,/^$/p')"
    [ -n "$para" ] || fail "qd --help has no RUN paragraph"
    assert_contains "$(printf '%s\n' "$para" | grep . | tail -n 1)" "docs/concepts.md"
    readme="$QD_DIR/README.md"
    assert_contains "$(head -n 40 "$readme")" "(docs/concepts.md)"
    assert_contains "$(sed -n '/^qd freq latest A /,/^---/p' "$readme")" \
        "(docs/concepts.md#the-objects)"
    assert_contains "$(sed -n '/^qd freq latest A /,/^---/p' "$readme")" \
        "provost names a field it found no"
    assert_not_contains "$(cat "$readme")" "| Reference | Means |"
    assert_contains "$(sed -n '/^### Named stores/,/^## Running/p' "$readme")" \
        "(docs/concepts.md#naming-a-run)"
    [ "$(wc -l < "$PAGE")" -le 150 ] || fail "the page is over 150 lines"
    awk '/^```text/{f=1; next} /^```/{f=0} f && length($0) > 60 {
        print "too wide: " $0; bad=1 } END { exit bad }' "$PAGE" ||
        fail "the page's picture is wider than 60 columns"
    assert_contains "$(cat "$QD_DIR/MANIFEST.in")" "docs/concepts.md"
}

run_test "every qd command on the page parses"              t_every_command_parses
run_test "the examples check fails on a bad flag or verb"   t_examples_check_fails_on_a_bad_flag_or_verb
run_test "every form the resolver takes is on the page"     t_every_form_is_on_the_page
run_test "the forms check fails when page and code part"    t_forms_check_fails_when_page_and_code_part
run_test "the page's links, and the links to it, land"      t_links_land
run_test "the links check fails where one does not land"    t_links_check_fails_where_one_does_not_land
run_test "--help, the README and the walkthrough point at it" t_pointers_and_the_page
finish
