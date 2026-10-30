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
    # the page's counts and shares are the engine's, not worked out there
    out="$(get '/api/column?e=latest&c=status')"
    assert_contains "$out" '"agree": 5'
    assert_contains "$out" '"disagree": 0'
    assert_contains "$out" '"e"], 5, 100.0]'
    out="$(get '/api/trend?e=latest&c=A&over=')"
    assert_contains "$out" '"summary": {"n": 1, "first": 9.0, "last": 9.0, "min": 9.0, "max": 9.0}'
    assert_contains "$(get '/api/diff?b=latest')" '"both": 5'
}

# the unit is the scale the figures are on: 512M beside 2G are bytes
t_column_unit_is_the_figures_scale() {
    printf 'host,mem,lat\na,512M,900ms\nb,2G,1.2s\n' > u.csv
    qd import u.csv > /dev/null
    start_web
    out="$(get '/api/column?e=latest&c=mem')"
    assert_contains "$out" '"unit": "B"'
    assert_contains "$out" '"max": 2147483648'
    assert_contains "$(get '/api/column?e=latest&c=lat')" '"unit": "s"'
    assert_contains "$(qd stats latest mem)" "max 2147483648  (B)"
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

t_compare_is_the_terminal_s() {
    seed
    start_web
    # host a moved 0.5 -> 0.6 between the two runs: past 5%, a change
    out="$(get '/api/compare?e=latest&c=A')"
    assert_contains "$out" '"label": "R2"'
    assert_contains "$out" '"changed": 1'
    assert_contains "$out" '"keys_total": 5'
    assert_contains "$out" "R2 drift +20.0%"
    assert_contains "$(qd compare latest -c A)" "R2 drift +20.0%"
    # every key on request, the runs' own figures beside them
    out="$(get '/api/compare?e=latest&c=A&changed=0')"
    assert_contains "$out" '"key": ["e"]'
    assert_contains "$out" '"median": 0.5'
    # no column: the medians of every numeric column the runs share
    out="$(get '/api/compare?e=latest')"
    assert_contains "$out" '"numeric": ["A"]'
    assert_contains "$out" '"column": "A", "medians"'
    out="$(get '/api/compare?e=latest&c=nosuch')"
    assert_contains "$out" "400"
}

t_campaigns_and_designs_are_listed() {
    install_fake_ssh
    for h in a b c d; do fake_host "$h"; done
    printf 'a rack=r1\nb rack=r1\nc rack=r2\nd rack=r2\n' > hosts.txt
    stand_in_doe
    cat > bench.json <<'EOF'
{"metadata": {"name": "Stream test"},
 "factors": [{"name": "streams", "levels": ["1", "4"], "type": "continuous"}],
 "responses": [{"name": "mbps", "optimize": "maximize"}],
 "settings": {"operation": "full_factorial", "block_count": 1}}
EOF
    # shellcheck disable=SC2016  # expanded on the far side, not here
    qdf doe run bench.json -s hosts.txt -q -- \
        'echo "mbps: $(( 900 + 100 * {streams} ))"' > /dev/null
    start_web
    out="$(get /api/groups)"
    assert_contains "$out" '"kind": "design"'
    assert_contains "$out" '"name": "stream-test"'
    assert_contains "$out" "2 of 2 points measured"
    # the design's points compared: its factors on each run
    out="$(get '/api/compare?group=stream-test&c=mbps')"
    assert_contains "$out" '"factors": "streams=4"'
    assert_contains "$out" "R2 drift"
    # a factor is what the point was, not what it measured
    out="$(get '/api/compare?group=stream-test')"
    assert_contains "$out" '"numeric": ["mbps"]'
    out="$(get /api/entries)"
    assert_contains "$out" '"group": "stream-test"'
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

# a reference is a run or a provost dataset, never a path: no file on the
# machine is read through e=, and a page that points its own name at the
# server (DNS rebinding) is turned away
t_refs_are_never_paths() {
    seed
    mkdir -p outside && printf 'k\tv\nsecret\t42\n' > outside/secret.tsv
    start_web
    out="$(get "/api/rows?e=$PWD/outside/secret")"
    assert_contains "$out" "400"
    assert_not_contains "$out" "42"
    out="$(get '/api/rows?e=ds:../../outside/secret')"
    assert_contains "$out" "400"
    assert_not_contains "$out" "42"
    out="$(get '/api/export?e=ds:../../outside/secret&format=csv')"
    assert_not_contains "$out" "42"
    out="$("$PY" - "$URL" <<'EOF'
import sys, urllib.request, urllib.error
req = urllib.request.Request(sys.argv[1] + "api/entries",
                             headers={"Host": "evil.example:18100"})
try:
    urllib.request.urlopen(req)
    print("200")
except urllib.error.HTTPError as e:
    print(e.code)
EOF
)"
    assert_eq "$out" "403"
    assert_contains "$(get /api/entries)" "200"
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
run_test "a column's unit is its figures' scale"    t_column_unit_is_the_figures_scale
run_test "group, pivot, trend"                      t_group_pivot_trend
run_test "diff defaults to the last same run"       t_diff_defaults_to_the_last_same_run
run_test "compare: the terminal's verdict"           t_compare_is_the_terminal_s
run_test "campaigns and designs, and their runs"     t_campaigns_and_designs_are_listed
run_test "raw answers, export, overlay"             t_raw_export_and_overlay
run_test "static page; nothing escapes its root"    t_static_page_and_no_escape
run_test "references are never paths"              t_refs_are_never_paths
run_test "app.js parses"                            t_app_js_parses
run_test "floor: overlay written, viewer named"       t_floor_writes_the_overlay_and_names_the_viewer
run_test "no store yet: refused"                    t_empty_store_is_refused
finish
