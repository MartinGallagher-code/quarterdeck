#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Martin J. Gallagher

# A study (QD-070): a screen and the designs that follow it, grouped by the
# study their configs name, every run of every design lined up by qd
# compare --study and by qd web's /api/study.  The two designs here have
# different factors, so the table has to say which level each design held;
# the "benchmark" is an echo whose answer is known, and host b fails every
# point with window=2048, which must stay blank, never 0.

set -u
source "$(dirname "${BASH_SOURCE[0]}")/test_helper.bash"
# the two designs are run once and copied into each case that starts from them
use_fixtures

# shellcheck disable=SC2016  # expanded on the far side, not here
BENCH='[ ! -e skip{window} ] && echo "mbps: $(( 900 + 300 * ({streams} > 1) + {window} / 8 + {burst} ))"'
# shellcheck disable=SC2016
SCREEN='[ ! -e skip{window} ] && echo "mbps: $(( 900 + 300 * ({streams} > 1) + {window} / 8 ))" # {proto}'

# the screen on a and b; the follow-up, which varies window and burst and
# holds streams at 4, run --like the screen: 2 designs x 4 points x 2 hosts
study() {
    stand_in_doe
    install_fake_ssh
    fake_host a
    fake_host b
    touch "$FAKE_ROOT/b/skip2048"
    printf 'a\nb\n' > hosts.txt
    "$PY" - "$SCREEN" "$BENCH" <<'EOF'
import json, sys
screen = {"metadata": {"name": "screen", "qd_command": sys.argv[1]},
          "factors": [{"name": "streams", "levels": ["1", "4"]},
                      {"name": "window", "levels": ["64", "1024"]}],
          "fixed_factors": {"proto": "tcp"},
          "responses": [{"name": "mbps", "column": "mbps",
                         "optimize": "maximize"}],
          "settings": {"operation": "full_factorial", "block_count": 1}}
follow = json.loads(json.dumps(screen))
follow["metadata"] = {"name": "follow", "qd_command": sys.argv[2],
                      "qd_follows": {"design": "screen",
                                     "response": "mbps"}}
follow["factors"] = [{"name": "window", "levels": ["512", "2048"]},
                     {"name": "burst", "levels": ["0", "2"]}]
follow["fixed_factors"] = {"streams": "4"}
json.dump(screen, open("screen.json", "w"))
json.dump(follow, open("follow.json", "w"))
EOF
    qdf doe run screen.json -s hosts.txt -q > /dev/null
    if [ "${1:-}" != "screen" ]; then
        qdf_rc doe run follow.json --like screen -q > /dev/null
        assert_status "$QD_RC" 1    # b failed two points
    fi
}

# the csv's row for DESIGN HOST and factor levels as they appear
row() { grep -E "^$1,[0-9]+,$2,[^,]*$3" study.csv; }

t_compare_lines_up_every_run() {
    study screen
    # a screen alone is a study of one design: status shows no study
    assert_not_contains "$(qd doe status screen)" "the study"
    qdf_rc doe run follow.json --like screen -q > /dev/null
    qd compare --study screen --format csv > study.csv
    assert_eq "$(head -1 study.csv)" "design,point,host,mbps,streams,window,burst,status,run"
    # every run once, a row per host: 8 runs on 2 hosts
    assert_eq "$(sed 1d study.csv | wc -l | tr -d ' ')" "16"
    assert_eq "$(sed 1d study.csv | cut -d, -f3,9 | sort -u | wc -l | tr -d ' ')" "16"
    assert_eq "$(sed 1d study.csv | cut -d, -f9 | sort -u | wc -l | tr -d ' ')" "8"
    assert_eq "$(qd log | grep -c 'screen\|follow')" "8"
    # the screen varied streams and window; burst it never knew: blank
    assert_eq "$(row screen a ',1,64,,' | cut -d, -f4)" "908"
    assert_eq "$(row screen b ',4,1024,,' | cut -d, -f4)" "1328"
    # the follow-up held streams at 4, and varied window and burst
    assert_eq "$(row follow a ',4,512,2,' | cut -d, -f4)" "1266"
    assert_eq "$(row follow a ',4,2048,0,' | cut -d, -f4)" "1456"
    # b failed at window 2048: no mbps -- blank, not 0 -- and not ok
    for r in $(row follow b ',4,2048,' | cut -d, -f4,8); do
        case "$r" in
            ,ok | 0,* | ,) fail "b's failed point: $r" ;;
            ,*) ;;
            *) fail "b's failed point: $r" ;;
        esac
    done
    assert_eq "$(row follow b ',4,2048,' | wc -l | tr -d ' ')" "2"
    # what every design held is said once, not a column
    out="$(qd compare --study screen --width 120)"
    assert_contains "$out" "2 designs, 16 rows (a run on one host each)"
    assert_contains "$out" "screen: full factorial, 4 of 4 points measured; varies streams window"
    assert_contains "$out" "follow: full factorial, following screen for mbps, 4 of 4 points measured; varies window burst; holds streams=4"
    assert_contains "$out" "held by every design: proto=tcp"
    assert_contains "$out" "note: blank factor cells: screen neither varied nor held those factors"
    # filtered and sorted as qd show does
    qd compare --study screen --where 'window>=1024' --sort -mbps --format csv > s.csv
    assert_eq "$(sed -n 2p s.csv | cut -d, -f1,3,4)" "follow,a,1458"
    assert_eq "$(sed 1d s.csv | wc -l | tr -d ' ')" "8"
    out="$(qd compare --study screen --where 'window>=1024')"
    assert_contains "$out" "16 rows (a run on one host each), 8 shown"
    # -c names the response: a column, or a config's response by name
    assert_eq "$(qd compare --study screen -c mbps --format csv | head -1)" "design,point,host,mbps,streams,window,burst,status,run"
}

t_compare_refuses_what_it_cannot_do() {
    fixture study study
    qd_rc compare --study nothing 2> err
    assert_status "$QD_RC" 2
    assert_contains "$(cat err)" "no study 'nothing'"
    assert_contains "$(cat err)" "(studies: screen)"
    qd_rc compare --study follow 2> err
    assert_status "$QD_RC" 2
    assert_contains "$(cat err)" "follow is a design of the study screen: name the study (its designs: screen, follow)"
    qd_rc compare --study screen --group screen 2> err
    assert_status "$QD_RC" 2
    assert_contains "$(cat err)" "leave --group out"
    qd_rc compare --study screen --agg top 2> err
    assert_status "$QD_RC" 2
    assert_contains "$(cat err)" "not top"
    qd_rc compare --group screen --sort mbps 2> err
    assert_status "$QD_RC" 2
    assert_contains "$(cat err)" "--sort orders a study's runs"
}

t_doe_status_lists_the_study() {
    fixture study study
    out="$(qd doe status screen)"
    assert_contains "$out" "qd doe -- screen: 4 of 4 points measured"
    assert_contains "$out" "the study screen: 2 designs, 8 of 8 points measured"
    assert_contains "$(echo "$out" | tr -s ' ')" " follow full-factorial 4/4 4 screen (mbps) window burst"
    assert_contains "$out" "qd compare --study screen"
    out="$(qd doe status follow)"
    assert_contains "$out" "study    screen (follows screen: mbps; like screen)"
    assert_contains "$out" "qd doe status screen"
    # a study named for no design: the designs that name it
    "$PY" - <<'EOF'
import json
c = json.load(open("screen.json"))
c["metadata"] = {"name": "solo", "qd_study": "tuning",
                 "qd_command": c["metadata"]["qd_command"]}
c["factors"] = c["factors"][:1]
c["fixed_factors"]["window"] = "64"
c["responses"] = [{"name": "mbps"}]      # no column named
json.dump(c, open("solo.json", "w"))
EOF
    qdf doe run solo.json -S a -q > /dev/null
    out="$(qd doe status tuning)"
    assert_contains "$out" "the study tuning: 1 design, 2 of 2 points measured"
    assert_contains "$out" "solo"
    # its config names no response's column: -c names it
    qd_rc compare --study tuning 2> err
    assert_status "$QD_RC" 2
    assert_contains "$(cat err)" "which response? -c COLUMN"
    qd compare --study tuning -c mbps --format csv > t.csv
    assert_eq "$(head -1 t.csv)" "design,point,host,mbps,streams,status,run"
    # the web's study still gives the runs, and no chart until one is named
    out="$("$PY" -c 'import json, sys; sys.path.insert(0, sys.argv[1])
from quarterdeck import store, web
d = web.Api(store.Store(sys.argv[2])).study({"study": ["tuning"]})
print(json.dumps([d["responses"], d["chart"], d["columns"], d["total"]]))' "$QD_DIR" "$QD_STORE")"
    assert_eq "$out" '[[], null, ["design", "point", "host", "streams", "status", "run"], 2]'
}

# qd web's study: the same rows from the engine, filtered and sorted
# there, and the chart's points and medians worked out there too
start_web() {
    "$PY" "$QD_DIR/qd" web -n -q --port 18180 > web.out 2> web.err &
    echo $! > web.pid
    for _ in $(seq 1 50); do
        URL="$(sed -n 's/^qd web: \(http:[^ ]*\).*/\1/p' web.err | tail -1)"
        [ -n "$URL" ] && break
        sleep 0.1
    done
    [ -n "$URL" ] || { cat web.err; fail "the server did not start"; }
    export URL
}

# a key of the JSON at PATH, as JSON
api() {
    "$PY" - "$URL" "$1" "$2" <<'EOF'
import json, sys, urllib.request, urllib.error
base, path, expr = sys.argv[1:4]
try:
    with urllib.request.urlopen(base.rstrip("/") + path) as r:
        d = json.loads(r.read().decode("utf-8"))
except urllib.error.HTTPError as e:
    d = dict(json.loads(e.read().decode("utf-8")), status=e.code)
print(json.dumps(eval(expr, {"d": d}), sort_keys=True))
EOF
}

t_web_study() {
    fixture study study
    start_web
    assert_eq "$(api /api/groups 'd["studies"]')" '[{"designs": ["screen", "follow"], "name": "screen", "progress": "2 designs, 8 of 8 points measured"}]'
    p='/api/study?study=screen'
    assert_eq "$(api "$p" 'd["columns"]')" '["design", "point", "host", "mbps", "streams", "window", "burst", "status", "run"]'
    assert_eq "$(api "$p" '[d["total"], d["matched"], len(d["rows"])]')" '[16, 16, 16]'
    assert_eq "$(api "$p" 'd["constant"]')" '[["proto", "tcp"]]'
    assert_eq "$(api "$p" '[(x["name"], x["varied"], x["held"], x["follows"], x["measured"]) for x in d["designs"]]')" '[["screen", ["streams", "window"], [["proto", "tcp"]], "", 4], ["follow", ["window", "burst"], [["proto", "tcp"], ["streams", "4"]], "screen", 4]]'
    # the same rows as the terminal's, in the same order
    qd compare --study screen --format csv | sed 1d > cli.csv
    api "$p" '"\n".join(",".join(r) for r in d["rows"])' | "$PY" -c 'import json,sys; print(json.loads(sys.stdin.read()))' > web.csv
    assert_eq "$(cat web.csv)" "$(cat cli.csv)"
    # filtered and sorted by the server
    q="$p&where=window%3E%3D1024&sort=-mbps"
    assert_eq "$(api "$q" '[d["total"], d["matched"], d["rows"][0][:4]]')" '[16, 8, ["follow", "'"$(grep '^follow,[0-9]*,a,1458' cli.csv | cut -d, -f2)"'", "a", "1458"]]'
    # the chart: by default the factor the latest design varied first,
    # each design a series; b's failed points are not measured (None), and
    # the median at each level is the engine's
    assert_eq "$(api "$p" '[d["chart"]["factor"], d["chart"]["response"], d["chart"]["numeric_x"], d["chart"]["unmeasured"]]')" '["window", "mbps", true, 2]'
    assert_eq "$(api "$p" '[s["group"] for s in d["chart"]["series"]]')" '["screen", "follow"]'
    assert_eq "$(api "$p" '[[m[1], m[2], m[3]] for m in d["chart"]["series"][1]["levels"]]')" '[["512", 1265.0, 4], ["2048", 1457.0, 2]]'
    assert_eq "$(api "$p" '[p[2] for p in d["chart"]["series"][1]["points"] if p[5] == "b" and p[1] == "2048"]')" '[null, null]'
    assert_eq "$(api "$p" '[[m[1], m[2]] for m in d["chart"]["series"][0]["levels"]]')" '[["64", 1058.0], ["1024", 1178.0]]'
    # another factor and a factor held: the follow-up's streams is its level
    assert_eq "$(api "$p&factor=streams" '[[m[1], m[2], m[3]] for m in d["chart"]["series"][1]["levels"]]')" '[["4", 1266.0, 6]]'
    # what is not there is said, as the terminal says it
    assert_eq "$(api "$p&factor=nothing" '[d["status"], d["error"]]')" '[400, "no factor '"'"'nothing'"'"' in the study screen (its factors: streams, window, burst)"]'
    assert_eq "$(api '/api/study?study=follow' 'd["status"]')" '400'
    assert_eq "$(api "$p&c=nothing" '[r[3] for r in d["rows"]]')" "$(printf '[%s""]' "$(printf '"", %.0s' $(seq 15))")"
}

run_test "compare --study lines up every run once"  t_compare_lines_up_every_run
run_test "compare --study refuses what it cannot"   t_compare_refuses_what_it_cannot_do
run_test "doe status lists the study's designs"     t_doe_status_lists_the_study
run_test "qd web's study: rows, filter, chart"      t_web_study
finish
