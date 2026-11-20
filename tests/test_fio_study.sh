#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Martin J. Gallagher

# A fio tuning study, start to finish (QD-066): the seven steps of
# docs/fio-study.md run one after another on one drive of one host, each
# from what the step before it left in the store -- the Plackett-Burman
# screen (QD-067), its effects in qd web (QD-068), the follow-up qd doe
# next writes and qd doe run --like measures (QD-069), the study compared
# (QD-070), the response surface (QD-071) and qd doe optimize's rounds to
# the settings to use (QD-072).  Each step has its own suite; this one
# checks that they join up.  fio is the helper's stand_in_fio with
# FIO_PEAK: read IOPS a hill whose top is at iodepth 60 and 6 jobs,
# outside the screen's range (iodepth 1 to 32), flattened (scale=0.2) so
# that it stays above 0 over the whole screen, as a drive's does.  doe is
# the helper's stand_in_doe, and the real one too where it is installed.

set -u
source "$(dirname "${BASH_SOURCE[0]}")/test_helper.bash"

# what qd said, its lines joined: wrapping does not split a phrase
flat() { tr '\n' ' ' < "$1" | tr -s ' '; }

# how many times fio has run, in all (stand_in_fio counts them with FIO_PEAK)
calls() { wc -c < "$FAKE_BIN/fio-calls" | tr -d ' '; }

# a key of a config, as JSON
cfg() { "$PY" -c 'import json,sys; c = json.load(open(sys.argv[1])); exec("print(json.dumps(" + sys.argv[2] + ", sort_keys=True))")' "$1" "$2"; }

FU=fio-screen-read-iops-ccd

# steps 1 to 7, in order, on host a; with $1=web, qd web's views of each
# step as well.  With $1=real, the real doe: whether it prints its best
# point inside a region (doe optimize's "Surface optimum") turns on
# scipy's L-BFGS-B saying it converged, which differs from one machine to
# the next for the same fit (doe 0.5.0, on CI's runners and not here), so
# steps 6 and 7 check only what does not turn on it.
the_study() {
    stand_in_fio
    install_fake_ssh
    fake_host a
    echo a > host.txt
    export FIO_PEAK="iodepth=60,numjobs=6,scale=0.2"

    # 1. the screen: eight points of seven fio settings, ranked
    qd doe init fio > /dev/null
    sed -i.bak "s#/mnt/DRIVE/qd-fio.dat#/srv/scratch/qd-fio.dat#" fio-screen.json
    qdf_rc doe run fio-screen.json -s host.txt -q > out 2> err
    assert_status "$QD_RC" 0
    assert_contains "$(cat out)" "8 of 8 points measured"
    qd doe analyze fio-screen -c read_iops > an.out
    assert_contains "$(flat an.out)" "read_iops big: iodepth"
    assert_contains "$(flat an.out)" "(max 32)"

    # 3. the follow-up on the big numeric factors, the rest held
    qd doe next fio-screen -c read_iops > next.out
    assert_contains "$(flat next.out)" "wrote $FU.json: central-composite on 2 factors, 16 points"
    assert_eq "$(cfg $FU.json '[x["name"] for x in c["factors"]]')" '["iodepth", "numjobs"]'
    assert_eq "$(cfg $FU.json '[c["fixed_factors"][k] for k in ("filename", "rw", "ioengine", "bs")]')" \
        '["/srv/scratch/qd-fio.dat", "randrw", "libaio", "4"]'
    assert_eq "$(cfg $FU.json 'c["metadata"]["qd_study"]')" '"fio-screen"'

    # 4. measured where the screen was, holding what it held
    qdf_rc doe run $FU.json --like fio-screen -q > out 2> err
    assert_status "$QD_RC" 0
    assert_contains "$(flat out)" "like fio-screen: on its host a"
    assert_contains "$(cat out)" "16 of 16 points measured"

    # 5. the study, every run of both designs
    qd compare --study fio-screen -c read_iops > cmp.out
    assert_contains "$(flat cmp.out)" "2 designs, 24 rows"

    # 6. the surface: a maximum beyond the region, so another round
    qd doe surface $FU > surf.out
    assert_contains "$(flat surf.out)" "a maximum, outside the design region"
    if [ "${1:-}" = real ]; then
        real_optimize
        return 0
    fi
    assert_contains "$(flat surf.out)" "on its edge (iodepth at its high level)"

    # 7. qd runs the rounds itself, to the settings to use
    qdf_rc doe optimize fio-screen -c read_iops --budget 80 -q > opt.out 2> err
    assert_status "$QD_RC" 0
    f="$(flat opt.out)"
    assert_contains "$f" "from $FU, on a; 0 of a budget of 80 runs spent"
    assert_contains "$f" "doe's steepest ascent from its centre"
    assert_contains "$f" "qd doe optimize -- fio-screen: read_iops, an optimum found"
    assert_contains "$f" "the settings confirmed at doe's predicted maximum"
    assert_contains "$f" "iodepth 16 60"
    assert_contains "$f" "numjobs 4 6"
    # the command: the screen's own, with the screen's held settings, the
    # follow-up's held levels and the recommended ones
    cmd="$(sed -n '/^  command/,$p' opt.out | sed '/^$/,$d' | sed 's/^  command//' | tr -s ' \n' '  ')"
    for x in --filename=/srv/scratch/qd-fio.dat --size=8G --runtime=60 \
             --rw=randrw --bs=4k --ioengine=libaio --iodepth=60 --numjobs=6; do
        assert_contains "$cmd" " $x "
    done
    case "$cmd" in *"{"*) fail "a placeholder left in the command: $cmd" ;; esac
    # every round is a design of the study: the screen, the follow-up, the
    # path, the region (and its refinement), the confirmation
    qd doe status fio-screen > st.out
    for d in fio-screen $FU fio-screen-read-iops-path1 fio-screen-read-iops-region1 \
             fio-screen-read-iops-confirm1; do
        assert_contains "$(cat st.out)" "$d "
    done
    qd compare --study fio-screen -c read_iops --format csv > all.csv
    rows="$(($(wc -l < all.csv) - 1))"
    assert_eq "$rows" "$(calls)"
    # done: the same command again runs nothing more
    n="$(calls)"
    qdf_rc doe optimize fio-screen -c read_iops --budget 80 --json > rep.json
    assert_status "$QD_RC" 0
    assert_eq "$(calls)" "$n"
    assert_eq "$(cfg rep.json '[c["stop"]["reason"], c["ran"], c["recommended"]["settings"]["iodepth"], c["recommended"]["settings"]["numjobs"]]')" \
        '["converged", 0, "60", "6"]'

    [ "${1:-}" = web ] || return 0
    # 2, 5 and 6 in qd web: the screen's effects, the study's every run,
    # the region's surface -- each figure the engine's
    "$PY" "$QD_DIR/qd" web -n -q --port 18200 > web.out 2> web.err &
    echo $! > web.pid
    URL=""
    for _ in $(seq 1 50); do
        URL="$(sed -n 's/^qd web: \(http:[^ ]*\).*/\1/p' web.err | tail -1)"
        [ -n "$URL" ] && break
        sleep 0.1
    done
    [ -n "$URL" ] || { cat web.err; fail "the server did not start"; }
    assert_eq "$(api '/api/design?name=fio-screen&c=jobs.0.read.iops' '[d["measured"], d["total"], d["pareto"][0]["term"], len(d["main"])]')" \
        '[8, 8, "iodepth", 7]'
    assert_eq "$(api '/api/groups' '[(s["name"], len(s["designs"])) for s in d["studies"]]')" '[["fio-screen", 5]]'
    assert_eq "$(api '/api/study?study=fio-screen&c=read_iops' 'd["total"]')" "$rows"
    assert_eq "$(api "/api/surface?name=fio-screen-read-iops-region1" '[d["stationary"]["kind"], d["verdict"]["where"]]')" \
        '["maximum", "inside"]'
    kill "$(cat web.pid)" 2> /dev/null || true
}

# a key of the JSON qd web answers at PATH, as JSON
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

# step 7 with the real doe: within its budget, every round filed in the
# study, and the settings it recommends (confirmed, or the best measured
# where doe gave no best point to confirm) at the hill's top
real_optimize() {
    qdf_rc doe optimize fio-screen -c read_iops --budget 80 -q > opt.out 2> err
    case "$QD_RC" in 0|1) ;; *) cat opt.out err; fail "qd doe optimize exited $QD_RC" ;; esac
    qdf_rc doe optimize fio-screen -c read_iops --budget 80 --json > rep.json
    "$PY" - rep.json <<'PYEOF'
import json, sys
r = json.load(open(sys.argv[1]))
assert r["spent"] <= r["budget"] == 80, (r["spent"], r["budget"])
assert r["stop"]["reason"] in ("converged", "stalled"), r["stop"]
kinds = [x["kind"] for x in r["rounds"]]
assert kinds[:2] == ["start", "path"], kinds
s = r["recommended"]["settings"]
assert 50 <= float(s["iodepth"]) <= 70 and 5 <= float(s["numjobs"]) <= 7, s
assert "--iodepth=%s " % s["iodepth"] in r["recommended"]["command"] + " ", r["recommended"]
PYEOF
    qd compare --study fio-screen -c read_iops --format csv > all.csv
    assert_eq "$(($(wc -l < all.csv) - 1))" "$(calls)"
}

t_the_whole_study() {
    stand_in_doe
    the_study web
}

t_with_the_real_doe() {
    if ! command -v doe > /dev/null 2>&1; then
        echo "  (doe is not installed here: pip install doehelper)"
        return 0
    fi
    unset QD_DOE
    the_study real
    # doe's own report, with the screen's plots, kept for qd web
    qd doe analyze fio-screen -c read_iops --report rep > /dev/null
    assert_file_exists rep/report.html
}

run_test "the whole study, from the screen to the settings to use"  t_the_whole_study
run_test "with the real doe, where installed"                        t_with_the_real_doe
finish
