#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Martin J. Gallagher

# qd web: the JSON API the page is drawn from, against a real server on
# loopback.  The page itself does no arithmetic, so checking the API checks
# every figure it shows; app.js is syntax-checked when node is here.

set -u
source "$(dirname "${BASH_SOURCE[0]}")/test_helper.bash"

start_web() {
    # The interpreter itself goes in the background, not the qd function:
    # $! of a backgrounded function is a subshell, and killing that leaves
    # the server running after the case.
    "$PY" "$QD_DIR/qd" web -n -q --port 18100 > web.out 2> web.err &
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
# bytes, not text: under LANG=C a 3.6 stdout is ASCII, and the page has
# characters that are not
sys.stdout.buffer.write(b"%d\n" % status + body + b"\n")
EOF
}

seed() {
    install_fake_ssh
    for h in a b c d e; do fake_host "$h"; done
    for h in a b c d; do echo "0.5" > "$FAKE_ROOT/$h/load"; done
    echo "9.0" > "$FAKE_ROOT/e/load"
    printf 'a rack=r1\nb rack=r1\nc rack=r2\nd rack=r2\ne rack=r2\n' > hosts.txt
    qdf run -s hosts.txt -q -- cat load > /dev/null || true
    echo "0.6" > "$FAKE_ROOT/a/load"
    qdf run -s hosts.txt -q -- cat load > /dev/null || true
}

t_entries_rows_and_filters() {
    seed
    start_web
    out="$(get /api/entries)"
    assert_contains "$out" "200"
    assert_contains "$out" '"kind": "run"'
    out="$(get '/api/rows?e=latest&where=A>1&sort=-A')"
    assert_contains "$out" '"matched": 1'
    assert_contains "$out" '"e"'
    out="$(get '/api/rows?e=latest&where=nosuch>1')"
    assert_contains "$out" "400"
    assert_contains "$out" "no column"
}

t_column_figures_match_the_cli() {
    seed
    start_web
    out="$(get '/api/column?e=latest&c=A')"
    assert_contains "$out" '"median": 0.5'
    assert_contains "$out" '"outliers"'
    assert_contains "$out" '"e", 9.0'
    cli="$(qd stats latest A)"
    assert_contains "$cli" "median 0.5"
}

t_group_pivot_trend() {
    seed
    start_web
    out="$(get '/api/group?e=latest&by=rack')"
    assert_contains "$out" '"A_mean"'
    assert_contains "$out" '"r2", "3"'
    out="$(get '/api/pivot?e=latest&rows=rack&cols=status')"
    assert_contains "$out" '"rack", "ok"'
    out="$(get '/api/trend?e=latest&c=A&over=')"
    assert_contains "$out" '"over": null'
    assert_contains "$out" '"group": "e"'
}

t_diff_defaults_to_the_last_same_run() {
    seed
    start_web
    out="$(get '/api/diff?b=latest')"
    assert_contains "$out" '"changed_total": 1'
    assert_contains "$out" '"key": ["a"]'
    out="$(get '/api/diff?b=latest~1')"
    assert_contains "$out" "400"
    assert_contains "$out" "nothing earlier"
}

t_raw_export_and_overlay() {
    seed
    start_web
    out="$(get '/api/raw?e=latest&host=e')"
    assert_contains "$out" '"out": "9.0\n"'
    # which capture it is, and the row provost source takes in any provost
    assert_contains "$out" '"label": "raw answer: capture c00'
    assert_contains "$out" "provost source "
    out="$(get '/api/export?e=latest&format=csv&where=rack=r1')"
    assert_contains "$out" "host,rack,status"
    assert_not_contains "$out" "r2"
    out="$(get '/api/overlay?e=latest')"
    assert_contains "$out" '"samples"'
    e="$(qd log latest | head -1 | cut -d' ' -f1)"
    # written to qd's cache, never into the store provost commits
    assert_file_exists "$XDG_CACHE_HOME/quarterdeck/floor/$e/overlay.tsv"
    assert_contains "$(cat "$XDG_CACHE_HOME/quarterdeck/floor/$e/overlay.tsv")" "qd_a	e	9.0"
    assert_eq "$(git -C "$QD_STORE" status --porcelain)" ""
}

t_static_page_and_no_escape() {
    seed
    start_web
    out="$(get /)"
    assert_contains "$out" "<title>quarterdeck</title>"
    out="$(get /app.js)"
    assert_contains "$out" "textContent"
    out="$(get '/../../../../etc/passwd')"
    assert_contains "$out" "404"
    out="$(get '/floor/files/../../../etc/passwd')"
    assert_not_contains "$out" "root:"
    out="$(get '/api/raw?e=latest&host=../../../etc/passwd')"
    assert_not_contains "$out" "root:"
    out="$(get '/api/raw?e=latest&capture=../../etc/passwd')"
    assert_not_contains "$out" "root:"
    out="$(get /api/nope)"
    assert_contains "$out" "404"
    assert_contains "$(cat web.err)" "127.0.0.1"
}

t_app_js_parses() {
    if ! command -v node > /dev/null 2>&1; then
        echo "  (node not installed: syntax check skipped)"
        return 0
    fi
    node --check "$QD_DIR/quarterdeck/web/app.js"
}

t_floor_writes_the_overlay_and_names_the_viewer() {
    seed
    printf 'dc A\n' > floor.dc
    # without the viewer: the overlay is written and the way to open it said
    # --dry-run either way: where dcviz is installed it would otherwise start
    # serving and never return
    PATH="/usr/bin:/bin" QD_DCVIZ="" qd floor latest --layout floor.dc \
        --dry-run > out 2> err || true
    e="$(qd log latest | head -1 | cut -d' ' -f1)"
    assert_file_exists "$XDG_CACHE_HOME/quarterdeck/floor/$e/overlay.tsv"
    assert_contains "$(cat err)" "10 samples"
    # with one: the command it would run
    printf '#!/bin/sh\necho dcviz "$@"\n' > "$FAKE_BIN/dcviz"
    chmod +x "$FAKE_BIN/dcviz"
    out="$(QD_DCVIZ="$FAKE_BIN/dcviz" qd floor latest --layout floor.dc --dry-run 2>/dev/null)"
    assert_contains "$out" "serve -d"
    assert_contains "$out" "--results files/overlay.tsv"
    assert_contains "$out" "--layout files/floor.dc"
    assert_file_exists "$XDG_CACHE_HOME/quarterdeck/floor/$e/floor.dc"
}

t_empty_store_is_refused() {
    qd_rc web -n 2> err
    assert_status "$QD_RC" 2
    assert_contains "$(cat err)" "no store at"
}

run_test "entries, rows, --where, a bad filter"     t_entries_rows_and_filters
run_test "column figures match the CLI's"           t_column_figures_match_the_cli
run_test "group, pivot, trend"                      t_group_pivot_trend
run_test "diff defaults to the last same run"       t_diff_defaults_to_the_last_same_run
run_test "raw answers, export, overlay"             t_raw_export_and_overlay
run_test "static page; nothing escapes its root"    t_static_page_and_no_escape
run_test "app.js parses"                            t_app_js_parses
run_test "floor: overlay written, viewer named"       t_floor_writes_the_overlay_and_names_the_viewer
run_test "no store yet: refused"                    t_empty_store_is_refused
finish
