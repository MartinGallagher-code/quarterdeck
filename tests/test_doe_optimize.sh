#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Martin J. Gallagher

# qd doe optimize (QD-072): further rounds, run by qd until an optimum is
# found -- doe's steepest path while the best point is on the region's
# edge, a design around the best point measured, doe next-batch inside the
# region, confirmation runs at doe's predicted optimum -- then the
# recommended settings and the command line that runs them.  fio is the
# helper's stand_in_fio with FIO_PEAK, whose read IOPS is a known hill and
# read latency a known bowl, both with their top (bottom) at iodepth 60 and
# 6 jobs: outside the central composite surface_design lays out (iodepth 4
# to 36).  doe is the helper's stand_in_doe, and the real one too where it
# is installed.

set -u
source "$(dirname "${BASH_SOURCE[0]}")/test_helper.bash"

# what qd said, its lines joined: wrapping does not split a phrase
flat() { tr '\n' ' ' < "$1" | tr -s ' '; }

# how many times fio has run, in all (stand_in_fio counts them with FIO_PEAK)
calls() { wc -c < "$FAKE_BIN/fio-calls" | tr -d ' '; }

PEAK="iodepth=60,numjobs=6"

# the central composite on host a, its best point on its edge; optimize
# runs against the same hill
start() {
    surface_design "$PEAK"
    export FIO_PEAK="$PEAK"
}

# the report as JSON: every round's point run once (but for $EXTRA runs
# more, interrupted), the budget kept, the spend the runs of the rounds --
# and what a check in $1 says on top
report_holds() {
    qdf_rc doe optimize ccd -c "${2:-read_iops}" --budget "${3:-60}" --json > rep.json
    "$PY" - rep.json "$1" <<'PYEOF'
import json, os, sys
r = json.load(open(sys.argv[1]))
assert r["spent"] <= r["budget"], (r["spent"], r["budget"])
# every point of every round run once: nothing measured twice, nothing
# left out (a round the loop ran is measured whole, but for a path that
# stopped where it got no better)
extra = int(os.environ.get("EXTRA", "0"))
assert all(x["runs"] >= x["measured"] for x in r["rounds"]), r["rounds"]
assert sum(x["runs"] - x["measured"] for x in r["rounds"]) == extra, r["rounds"]
assert r["spent"] == sum(x["runs"] for x in r["rounds"][1:]), r
exec(sys.argv[2])
PYEOF
}

walked_to_the_optimum() {
    start
    qdf_rc doe optimize ccd -c read_iops --budget 60 -q > out 2> err
    assert_status "$QD_RC" 0
    f="$(flat out)"
    assert_contains "$f" "qd doe optimize -- ccd: read_iops (jobs.0.read.iops, maximise) from ccd, on a; 0 of a budget of 60 runs spent"
    assert_contains "$f" "the best point inside ccd is on its edge (iodepth at its high level): doe's steepest ascent from its centre"
    assert_contains "$f" "no better than"
    assert_contains "$f" "the path ends here"
    assert_contains "$f" "a central composite around the best point measured"
    assert_contains "$f" "doe next-batch (refine) adds 4 points near it"
    assert_contains "$f" "confirmation: 3 runs at"
    assert_contains "$f" "qd doe optimize -- ccd: read_iops, an optimum found"
    assert_contains "$f" "inside doe's prediction"
    assert_contains "$f" "the settings confirmed at doe's predicted maximum"
    assert_contains "$f" "a local maximum, the best of the region searched (iodepth 4 to"
    assert_contains "$f" "and the best the study has measured anywhere ("
    n="$(calls)"
    # run again: nothing is left to run, and it says the same
    report_holds '
assert r["stop"]["reason"] == "converged", r["stop"]
assert r["ran"] == 0, r["ran"]
kinds = [x["kind"] for x in r["rounds"]]
assert kinds[:3] == ["start", "path", "region"], kinds
assert kinds[-2:] == ["refine", "confirm"], kinds
rec = r["recommended"]
s = rec["settings"]
assert abs(int(s["iodepth"]) - 60) <= 4 and abs(int(s["numjobs"]) - 6) <= 1, s
assert rec["source"] == "confirmed" and rec["measured"]["n"] == 3, rec
assert abs(rec["measured"]["mean"] - rec["predicted"]) <= rec["interval"], rec
assert r["starting"]["settings"] == {"iodepth": "20", "numjobs": "5"}, r["starting"]
assert r["starting"]["measured"] < 10000 and r["change"] > 900, r
assert r["overall"]["best"] and r["overall"]["points"] > 40, r["overall"]
assert r["region"]["iodepth"][0] == 4 and r["region"]["iodepth"][1] > 60, r["region"]
cmd = rec["command"]
assert "--iodepth=%s --numjobs=%s " % (s["iodepth"], s["numjobs"]) in cmd, cmd
assert "--filename=/srv/scratch/qd-fio.dat" in cmd, cmd
open("cmd", "w").write(cmd)
open("mean", "w").write(repr(rec["measured"]["mean"]))
'
    assert_status "$QD_RC" 0
    assert_eq "$(calls)" "$n"
    # the command recommended, run through the stand-in, gives what was
    # measured (give or take the stand-in's noise, 40 a run)
    sh -c "$(cat cmd)" > fio.json
    "$PY" - fio.json "$(cat mean)" <<'PYEOF'
import json, sys
v = json.load(open(sys.argv[1]))["jobs"][0]["read"]["iops"]
assert abs(v - float(sys.argv[2])) <= 80, (v, sys.argv[2])
PYEOF
    # every round is a design of the study, as compare and status show
    out="$(qd compare --study ccd -c read_iops --format csv)"
    assert_contains "$out" "ccd-read-iops-path1"
    assert_contains "$out" "ccd-read-iops-region1"
    assert_contains "$out" "ccd-read-iops-confirm1"
    out="$(qd doe status ccd)"
    assert_contains "$out" "ccd-read-iops-region1"
    assert_contains "$out" "steepest-ascent"
}

t_walks_to_an_optimum_outside() { stand_in_doe; walked_to_the_optimum; }

# a response to minimise: doe's steepest descent, its model_guided
# strategy (its refine centres on the largest value), and the bowl's bottom
t_a_response_to_minimise() {
    stand_in_doe
    start
    qdf_rc doe optimize ccd -c read_lat_mean --budget 80 -q > out 2> err
    assert_status "$QD_RC" 0
    f="$(flat out)"
    assert_contains "$f" "read_lat_mean (jobs.0.read.clat_ns.mean, minimise)"
    assert_contains "$f" "doe's steepest descent from its centre"
    assert_contains "$f" "for read_lat_mean, to minimise, its model_guided strategy is used"
    assert_contains "$f" "the settings confirmed at doe's predicted minimum"
    report_holds '
assert r["stop"]["reason"] == "converged", r["stop"]
s = r["recommended"]["settings"]
assert abs(int(s["iodepth"]) - 60) <= 4 and abs(int(s["numjobs"]) - 6) <= 1, s
assert r["recommended"]["measured"]["mean"] < r["starting"]["measured"], r
assert r["change"] > 0, r["change"]
' read_lat_mean 80
    # one optimize a design: the other response is refused, not mixed in
    qd_rc doe optimize ccd -c read_iops --budget 60 2> err
    assert_status "$QD_RC" 2
    assert_contains "$(cat err)" "ccd is optimised for read_lat_mean already"
}

# the budget is never passed: a run stops when it is spent, a round it
# cannot finish is not begun, and a larger budget carries on from there
t_the_budget_exactly_and_carrying_on() {
    stand_in_doe
    start
    # what optimize refuses, before it runs anything
    "$PY" - <<'PYEOF'
import json
c = json.load(open("ccd.json"))
c["metadata"] = {"name": "two", "qd_command": c["metadata"]["qd_command"]}
c["settings"]["operation"] = "full_factorial"
json.dump(c, open("two.json", "w"))
PYEOF
    qdf doe run two.json -s hosts.txt -q > /dev/null
    base="$(calls)"
    qd_rc doe optimize ccd -c read_iops 2> err
    assert_status "$QD_RC" 2
    assert_contains "$(cat err)" "how many runs may it make? --budget N"
    qd_rc doe optimize ccd --budget 0 2> err
    assert_contains "$(cat err)" "--budget wants a number of runs above 0"
    qd_rc doe optimize ccd -c read_iops,read_lat_mean --budget 9 2> err
    assert_contains "$(cat err)" "optimize is for one response"
    qd_rc doe optimize ccd --budget 9 --blocks-by rack 2> err
    assert_contains "$(cat err)" "it takes no --blocks-by"
    qd_rc doe optimize ccd --budget 9 -s hosts.txt 2> err
    assert_contains "$(cat err)" "so it takes no -s"
    qd_rc doe optimize two --budget 9 2> err
    assert_contains "$(cat err)" "two is a full factorial: optimize starts from a central composite or Box-Behnken"
    qd_rc doe optimize nothing --budget 9 2> err
    assert_contains "$(cat err)" "no study 'nothing'"
    assert_eq "$(calls)" "$base"
    # four runs: the first four steps of the path, and not one more
    qdf_rc doe optimize ccd -c read_iops --budget 4 -q > out
    assert_status "$QD_RC" 1
    f="$(flat out)"
    assert_contains "$f" "ccd: read_iops, stopped: the budget"
    assert_contains "$f" "the budget of 4 runs is spent"
    assert_contains "$f" "4 of 4 runs made (4 in this run)"
    assert_contains "$f" "the best settings measured (not confirmed)"
    assert_contains "$f" "qd doe optimize ccd -c read_iops --budget 14"
    assert_eq "$(calls)" "$((base + 4))"
    # 21: the path's last two steps, and then the next region would need
    # 16 runs where 15 are left, so it is not begun
    qdf_rc doe optimize ccd -c read_iops --budget 21 -q > out
    assert_status "$QD_RC" 1
    f="$(flat out)"
    assert_contains "$f" "the next region, a central composite of 16 points around iodepth=60 numjobs=7, needs 16 runs, and 15 of the budget of 21 runs are left"
    assert_contains "$f" "6 of 21 runs made (2 in this run)"
    assert_eq "$(calls)" "$((base + 6))"
    # and a budget that is enough finds the optimum, nothing run twice;
    # with --json, what it runs is said on stderr and stdout is the report
    report_holds '
assert r["stop"]["reason"] == "converged", r["stop"]
assert r["ran"] > 10, r["ran"]
open("spent", "w").write(str(r["spent"]))
'
    assert_status "$QD_RC" 0
    assert_eq "$(calls)" "$((base + $(cat spent)))"
}

# Ctrl-C part way through a path: the step being measured is lost, and
# optimize run again carries on from there, every round run once
t_an_interrupted_optimize_carries_on() {
    stand_in_doe
    start
    # fio's 19th call is the third step of the path; job control on, so
    # the run in the background takes SIGINT as Ctrl-C (a script's
    # background jobs ignore it otherwise)
    set -m
    FIO_INTERRUPT="19:$PWD/pid" "$PY" "$QD_DIR/qd" doe optimize ccd \
        --ssh "$FAKE_BIN/ssh" --scp "$FAKE_BIN/scp" -c read_iops \
        --budget 60 -q > out 2> err &
    echo "$!" > pid
    rc=0
    wait "$!" || rc=$?
    set +m
    assert_eq "$rc" "130"
    assert_contains "$(cat err)" "interrupted (Ctrl-C) at ccd-read-iops-path1 point 3, which is kept as not measured"
    assert_eq "$(calls)" "19"
    assert_contains "$(qd doe status ccd-read-iops-path1)" "2 of 10 points measured"
    qdf_rc doe optimize ccd -c read_iops --budget 60 -q > out 2> err
    assert_status "$QD_RC" 0
    assert_contains "$(flat out)" "3 of a budget of 60 runs spent"
    EXTRA=1 report_holds '
assert r["stop"]["reason"] == "converged", r["stop"]
assert [x["kind"] for x in r["rounds"]][:3] == ["start", "path", "region"], r["rounds"]
open("spent", "w").write(str(r["spent"]))
'
    # the interrupted step was run once more, and counted; nothing else was
    assert_eq "$(calls)" "$((16 + $(cat spent)))"
}

# fio fails at every point: the path ends at its first step, the region
# around the best point measures nothing, and optimize says it cannot go
# on, with the best it measured
t_it_says_when_it_cannot_go_on() {
    stand_in_doe
    start
    FIO_FAIL="--iodepth" qdf_rc doe optimize ccd -c read_iops --budget 60 -q > out 2> err
    assert_status "$QD_RC" 1
    f="$(flat out)"
    assert_contains "$f" "step 1 failed: no host measured it, so the path ends here"
    assert_contains "$f" "ccd: read_iops, stopped: it cannot go on"
    assert_contains "$f" "0 of ccd-read-iops-region1's 16 points measured read_iops: a quadratic surface over 2 factors needs 7"
    assert_contains "$f" "not a confirmed maximum: the best measured in the region searched (iodepth 4 to 36, numjobs 1 to 9)"
    assert_contains "$f" "the best settings measured (not confirmed)"
    assert_contains "$f" "17 of 60 runs made (17 in this run)"
}

# what a factor can be set to: a count stays a whole number from 1 up, a
# config's qd_min and qd_max hold, and a region keeps its size, moved
# inside the limits, its middle a whole number
t_limits_and_regions() {
    "$PY" - "$QD_DIR" <<'PYEOF'
import sys
sys.path.insert(0, sys.argv[1])
from quarterdeck import optimize as o
f = {"name": "iodepth", "levels": ["4", "36"], "type": "continuous"}
assert o.limits(f) == (1.0, None, True), o.limits(f)
assert o.limits({"name": "x", "levels": ["0.5", "2"]}) == (0.0, None, False)
assert o.limits({"name": "x", "levels": ["-1", "1"]}) == (None, None, True)
assert o.limits({"name": "rw", "levels": ["rw", "randrw"],
                 "type": "categorical"}) is None
mix = {"name": "rwmixread", "levels": ["30", "70"], "qd_min": 1, "qd_max": 99}
lim = o.limits(mix)
assert lim == (1.0, 99.0, True), lim
assert o.settle(lim, 120.4) == 99 and o.settle(lim, -3) == 1
assert o.settle(lim, 24.5) == 25 and o.settle(lim, 24.4) == 24
assert o.settle((0.0, None, False), 2.345) == 2.345
whole = (1.0, None, True)
assert o.recentre(whole, 60, 16) == (44.0, 76.0)
assert o.recentre(whole, 3, 16) == (1.0, 33.0)          # moved up, not cut
assert o.recentre(whole, 28, 15.5) == (13.0, 45.0)      # middle 29, whole
assert o.recentre(lim, 95, 20) == (59.0, 99.0)          # moved down to 99
assert o.pct(100.0, 102.0, "maximize") == 2.0
assert o.pct(100.0, 98.0, "minimize") == 2.0
assert o.pct(0.0, 1.0, "maximize") is None
PYEOF
}

t_with_the_real_doe() {
    if ! command -v doe > /dev/null 2>&1; then
        echo "  (doe is not installed here: pip install doehelper)"
        return 0
    fi
    unset QD_DOE
    walked_to_the_optimum
}

run_test "walks to an optimum outside the first region"   t_walks_to_an_optimum_outside
run_test "a response to minimise"                          t_a_response_to_minimise
run_test "the budget, exactly, and carrying on"            t_the_budget_exactly_and_carrying_on
run_test "an interrupted optimize carries on"              t_an_interrupted_optimize_carries_on
run_test "it says when it cannot go on"                    t_it_says_when_it_cannot_go_on
run_test "limits and regions"                              t_limits_and_regions
run_test "with the real doe, where installed"              t_with_the_real_doe
finish
