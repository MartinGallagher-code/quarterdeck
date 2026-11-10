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
    # the server running after the case.  18100 to 18119 are this suite's
    # (test_xstore.sh says why).  Extra arguments go to qd web.
    "$PY" "$QD_DIR/qd" web -n -q --port 18100 "$@" > web.out 2> web.err &
    echo $! > web.pid
    LINK=""
    for _ in $(seq 1 50); do
        LINK="$(sed -n 's/^qd web: \(https\{0,1\}:[^ ]*\).*/\1/p' web.err | tail -1)"
        [ -n "$LINK" ] && break
        sleep 0.1
    done
    [ -n "$LINK" ] || { cat web.err; fail "the server did not start"; }
    # URL is the server's address; LINK is what was printed, which carries
    # ?token= when the server made its own token
    URL="${LINK%%\?*}"
    TOKEN=""
    case "$LINK" in *"?token="*) TOKEN="${LINK#*\?token=}" ;; esac
    export URL LINK TOKEN
}

stop_web() {
    kill "$(cat web.pid)" 2> /dev/null
    wait "$(cat web.pid)" 2> /dev/null || true
}

# req PATH [HEADER:VALUE...]: the status, the Location and Set-Cookie
# headers when there are any, then the body, from $URL (0.0.0.0 reached as
# 127.0.0.1), never following a redirect.  https is verified against
# $QD_TEST_CA.
req() {
    "$PY" "$QD_DIR/tests/web_req.py" "$URL" "$@"
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

t_entries_carry_the_operator() {
    install_fake_ssh
    fake_host a
    echo 0.5 > "$FAKE_ROOT/a/load"
    QD_OPERATOR=ann qdf run -s a -q -- cat load > /dev/null
    start_web
    out="$(get /api/entries)"
    assert_contains "$out" '"operator": "ann@'
    assert_contains "$(get '/api/entry?e=latest')" "by        ann@"
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

# a qualified baseline and peer groups: the page gets the terminal's figures
t_compare_against_a_qualified_baseline() {
    imp() {
        printf 'host,sku,v\na,x,%s\nb,x,%s\nc,y,200\nd,y,200\n' "$1" "$1" \
            > q.csv
        qd import q.csv --name q > /dev/null
    }
    qd peers define sku --by sku > /dev/null
    for v in 100.0 100.2 99.9 100.1 99.8; do imp "$v"; done
    QD_OPERATOR=tester qd baseline set good q --last 5 --peers sku -c v \
        > /dev/null
    for v in 97.0 97.2 96.9 97.1 96.8; do imp "$v"; done
    start_web
    out="$(get '/api/compare?e=latest&last=5&baseline=good&c=v')"
    assert_contains "$out" '"name": "good"'
    assert_contains "$out" '"operator": "tester"'
    assert_contains "$out" '"verdict": "significant"'
    assert_contains "$out" '"p_text": "0.0079"'
    assert_contains "$out" '"p_holm_text": "0.016"'
    assert_contains "$out" '"effect_text": "-1.00"'
    assert_contains "$out" '"verdict": "not significant"'
    # the same figures the terminal prints
    term="$(qd compare q --last 5 --baseline good -c v --format csv)" || true
    assert_contains "$term" "v,x,5,100,0.1,5,97,-3.0,-1.00,0.0079,0.016,significant"
    # run against run, with each peer group's median per run
    out="$(get '/api/compare?e=latest&last=2&c=v&peers=sku')"
    assert_contains "$out" '"peer_groups": ["sku"]'
    assert_contains "$out" '"baselines": ["good"]'
    assert_contains "$out" '"peer": "x", "medians": [97.1, 96.8]'
    out="$(get '/api/compare?e=latest&last=2&c=v&peers=nosuch')"
    assert_contains "$out" "400"
    assert_contains "$out" "no peer group"
}

t_join_is_the_terminal_s() {
    seed
    # telemetry for the latest run's hosts, inside each one's window, kept
    # in the store as qd import --telemetry keeps it
    qd show ds:qd.hosts --format csv > hosts.csv
    "$PY" - <<'PYEOF'
import csv
rows = [r for r in csv.DictReader(open("hosts.csv"))]
last = rows[-1]["run"]
out = ["_time,host,metric,value"]
for r in rows:
    if r["run"] == last:
        t, d = float(r["ts"]), float(r["duration_s"])
        out.append("%.3f,%s,temp_c,%d" % (t + d / 2, r["host"],
                                          40 + ord(r["host"]) - ord("a")))
open("tel.csv", "w").write("\n".join(out) + "\n")
PYEOF
    qd import tel.csv --telemetry > /dev/null
    start_web
    out="$(get '/api/join?e=latest~1&tel=latest&agg=max,count')"
    assert_contains "$out" "200"
    assert_contains "$out" '"with": 5'
    assert_contains "$out" '"figures": ["window_from", "window_to", "telemetry_host", "temp_c_max", "temp_c_count"]'
    assert_contains "$out" '["e", "r2", "ok"'
    # the same figures the terminal prints
    qd join latest~1 latest --agg max,count --format csv > cli.csv
    assert_contains "$(grep '^e,' cli.csv)" ",e,44,1"
    assert_contains "$out" '"e", "44", "1"'
    # where= reads the telemetry's columns: the hot one alone
    out="$(get '/api/join?e=latest~1&tel=latest&where=temp_c_max>43')"
    assert_contains "$out" '"matched": 1'
    out="$(get '/api/join?e=latest~1')"
    assert_contains "$out" "400"
    assert_contains "$out" "tel=REF names the telemetry"
    # a file beside the server is never read as telemetry: a name is a
    # run's (tel.csv is the import's) or nothing
    cp tel.csv other.csv
    out="$(get '/api/join?e=latest~1&tel=other.csv')"
    assert_contains "$out" "400"
    assert_contains "$out" "no run or dataset"
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

# the store picker: the named stores, and any of them read by name --
# never by path
t_the_store_picker_reads_named_stores() {
    seed
    qd store new lab > /dev/null
    printf 'host,mbps\nx,9400\n' > lab.csv
    qd import lab.csv --name in_lab --store lab > /dev/null 2>&1
    start_web
    out="$(get /api/stores)"
    assert_contains "$out" '"name": "lab"'
    assert_contains "$out" '"runs": 1'
    assert_contains "$out" '"here": null'
    out="$(get '/api/entries?store=lab')"
    assert_contains "$out" '"name": "in_lab"'
    assert_not_contains "$out" "cat load"
    assert_contains "$(get '/api/rows?e=latest&store=lab')" '"x"'
    # the server's own store when none is named
    assert_contains "$(get /api/entries)" "cat load"
    out="$(get "/api/entries?store=$TEST_TMPDIR/store")"
    assert_contains "$out" "400"
    assert_contains "$out" "no store named"
    assert_contains "$(get '/api/entries?store=nope')" "400"
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

# beyond loopback: a token is made and printed once, every request needs
# it, the link's ?token= becomes a cookie, and nothing writes
t_exposed_needs_its_token() {
    seed
    start_web --host 0.0.0.0
    [ -n "$TOKEN" ] || fail "no token in the link: $LINK"
    assert_contains "$(cat web.err)" "WARNING: no TLS"
    assert_contains "$(cat web.err)" "read-only"
    out="$(req /api/entries)"
    assert_contains "$out" "401"
    assert_not_contains "$out" "cat load"
    assert_contains "$(req /)" "401"
    assert_contains "$(req /app.js)" "401"
    assert_contains "$(req /floor/files/x)" "401"
    assert_contains "$(req /api/entries "Authorization:Bearer wrong-token-0123456789")" "401"
    assert_contains "$(req "/api/entries?token=x$TOKEN")" "401"
    out="$(req /api/entries "Authorization:Bearer $TOKEN")"
    assert_contains "$out" "200"
    assert_contains "$out" "cat load"
    assert_contains "$(req /api/entries "Cookie:other=1; qd_web_token=$TOKEN")" "200"
    # the printed link: a cookie, and the token out of the address bar
    out="$(req "/?token=$TOKEN")"
    assert_contains "$out" "303"
    assert_contains "$out" "Location: /"$'\n'
    assert_contains "$out" "qd_web_token=$TOKEN; Path=/; HttpOnly; SameSite=Strict"
    assert_not_contains "$out" "Secure"
    out="$(req "/api/rows?e=latest&token=$TOKEN&limit=1")"
    assert_contains "$out" "200"
    assert_contains "$out" '"matched"'
    # another parameter is kept; a path naming another host is not followed
    assert_contains "$(req "/x/?a=1&token=$TOKEN")" "Location: /x/?a=1"
    assert_contains "$(req "//evil.example/?token=$TOKEN")" "Location: /evil.example/"
    # read-only beyond this machine
    out="$(req '/api/overlay?e=latest' "Authorization:Bearer $TOKEN")"
    assert_contains "$out" "403"
    assert_contains "$out" "--allow-writes"
    assert_no_file "$XDG_CACHE_HOME/quarterdeck/floor"
    # the Host check is loopback's: a network reaches it by any name
    assert_contains "$(req /api/entries "Authorization:Bearer $TOKEN" "Host:wr01.example:18100")" "200"
    stop_web
    # a logged request never carries the token: it is printed once, at start
    "$PY" "$QD_DIR/qd" web -n --host 0.0.0.0 --port 18101 > /dev/null 2> log.err &
    echo $! > web.pid
    for _ in $(seq 1 50); do grep -q "token=" log.err && break; sleep 0.1; done
    t2="$(sed -n 's/^qd web: http[^ ]*?token=\([^ ]*\).*/\1/p' log.err)"
    [ -n "$t2" ] || fail "no token printed: $(cat log.err)"
    URL="$(sed -n 's/^qd web: \(http:[^ ?]*\).*/\1/p' log.err)"
    req "/api/entries?token=$t2" > /dev/null
    req "/?a=1&token=$t2" > /dev/null
    req "/api/entries" "Authorization:Bearer $t2" > /dev/null
    sleep 0.3
    stop_web
    assert_eq "$(grep -c -- "$t2" log.err)" "1"
    assert_contains "$(cat log.err)" "token=-"
}

t_allow_writes_and_a_given_token() {
    seed
    printf '%s\n' "given-token-0123456789" > tok
    start_web --host 0.0.0.0 --token-file tok --allow-writes
    # a token given is never printed
    assert_eq "$TOKEN" ""
    assert_not_contains "$(cat web.err)" "given-token"
    assert_contains "$(cat web.err)" "writes allowed"
    assert_contains "$(req /api/entries)" "401"
    out="$(req '/api/overlay?e=latest' "Authorization:Bearer given-token-0123456789")"
    assert_contains "$out" "200"
    assert_contains "$out" '"samples"'
    stop_web
    # QD_WEB_TOKEN on loopback: required there too (a login node's
    # 127.0.0.1 is every user's), and writes stay allowed there
    QD_WEB_TOKEN="env-token-0123456789ab" start_web
    assert_contains "$(req /api/entries)" "401"
    assert_contains "$(req /api/entries "Authorization:Bearer env-token-0123456789ab")" "200"
    assert_contains "$(req '/api/overlay?e=latest' "Authorization:Bearer env-token-0123456789ab")" "200"
    assert_not_contains "$(cat web.err)" "env-token"
    assert_contains "$(cat web.err)" "the token is required"
}

t_bad_tokens_and_tls_files_are_refused() {
    seed
    QD_WEB_TOKEN=short qd_rc web -n 2> err
    assert_status "$QD_RC" 2
    assert_contains "$(cat err)" "at least 16"
    QD_WEB_TOKEN="has a space in it 0123" qd_rc web -n 2> err
    assert_status "$QD_RC" 2
    assert_contains "$(cat err)" "no spaces"
    : > empty
    qd_rc web -n --token-file empty 2> err
    assert_status "$QD_RC" 2
    assert_contains "$(cat err)" "is empty"
    qd_rc web -n --token-file nosuch 2> err
    assert_status "$QD_RC" 2
    assert_contains "$(cat err)" "cannot read the token file nosuch"
    qd_rc web -n --tls-cert nosuch.pem 2> err
    assert_status "$QD_RC" 2
    assert_contains "$(cat err)" "no such file: nosuch.pem"
    qd_rc web -n --tls-key k.pem 2> err
    assert_status "$QD_RC" 2
    assert_contains "$(cat err)" "--tls-key needs --tls-cert"
    echo "not a certificate" > bad.pem
    qd_rc web -n --tls-cert bad.pem 2> err
    assert_status "$QD_RC" 2
    assert_contains "$(cat err)" "cannot use bad.pem for TLS"
}

t_tls_serves_https() {
    if ! command -v openssl > /dev/null 2>&1; then
        echo "  (openssl not installed: TLS case skipped)"
        return 0
    fi
    seed
    openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj /CN=localhost \
        -keyout key.pem -out cert.pem > /dev/null 2>&1 || fail "openssl req"
    export QD_TEST_CA="$PWD/cert.pem"
    start_web --host 0.0.0.0 --tls-cert cert.pem --tls-key key.pem
    assert_contains "$URL" "https://"
    assert_not_contains "$(cat web.err)" "WARNING: no TLS"
    assert_contains "$(req /api/entries)" "401"
    out="$(req /api/entries "Authorization:Bearer $TOKEN")"
    assert_contains "$out" "200"
    assert_contains "$out" "cat load"
    assert_contains "$(req "/?token=$TOKEN")" "SameSite=Strict; Secure"
    # plain http to the https port gets no answer, and the server carries on
    plain="http://127.0.0.1:${URL##*:}"
    "$PY" -c 'import sys, urllib.request
try:
    urllib.request.urlopen(sys.argv[1] + "api/entries", timeout=5)
    print("answered")
except Exception:
    print("refused")' "$plain" > plain.out
    assert_eq "$(cat plain.out)" "refused"
    assert_contains "$(req /api/entries "Authorization:Bearer $TOKEN")" "200"
    stop_web
    # the key inside the cert file; on loopback, no token, as before
    cat key.pem cert.pem > both.pem
    start_web --tls-cert both.pem
    assert_eq "$TOKEN" ""
    assert_contains "$(req /api/entries)" "200"
}

run_test "entries, rows, --where, a bad filter"     t_entries_rows_and_filters
run_test "entries carry the operator"              t_entries_carry_the_operator
run_test "column figures match the CLI's"           t_column_figures_match_the_cli
run_test "a column's unit is its figures' scale"    t_column_unit_is_the_figures_scale
run_test "group, pivot, trend"                      t_group_pivot_trend
run_test "diff defaults to the last same run"       t_diff_defaults_to_the_last_same_run
run_test "compare: the terminal's verdict"           t_compare_is_the_terminal_s
run_test "compare: a qualified baseline, peer groups" t_compare_against_a_qualified_baseline
run_test "campaigns and designs, and their runs"     t_campaigns_and_designs_are_listed
run_test "telemetry joined as the terminal joins it" t_join_is_the_terminal_s
run_test "raw answers, export, overlay"             t_raw_export_and_overlay
run_test "static page; nothing escapes its root"    t_static_page_and_no_escape
run_test "references are never paths"              t_refs_are_never_paths
run_test "the store picker reads named stores"      t_the_store_picker_reads_named_stores
run_test "app.js parses"                            t_app_js_parses
run_test "floor: overlay written, viewer named"       t_floor_writes_the_overlay_and_names_the_viewer
run_test "no store yet: refused"                    t_empty_store_is_refused
run_test "beyond loopback: the token, read-only"    t_exposed_needs_its_token
run_test "--allow-writes; a token given"            t_allow_writes_and_a_given_token
run_test "bad tokens and TLS files refused"         t_bad_tokens_and_tls_files_are_refused
run_test "TLS: https, and plain http refused"       t_tls_serves_https
finish
