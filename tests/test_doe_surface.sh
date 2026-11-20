#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Martin J. Gallagher

# qd doe surface (QD-071): doe's response surface for a central composite
# or Box-Behnken design -- its model and fit, the stationary point and its
# kind, the best point inside the design region, and whether that is
# inside the region or on its edge -- and the contours qd web draws of it.
# fio is the helper's stand_in_fio with FIO_PEAK, whose read IOPS is a
# known hill and read latency a known bowl; doe is the helper's
# stand_in_doe (which fits the quadratic as doe does), and the real one
# too where it is installed.

set -u
source "$(dirname "${BASH_SOURCE[0]}")/test_helper.bash"

# what qd said, its lines joined: wrapping does not split a phrase
flat() { tr '\n' ' ' < "$1" | tr -s ' '; }

# a figure of the surface, from `qd doe surface --json` (what qd web serves)
api() {
    qd doe surface ccd -c "$1" --json > api.json
    "$PY" -c 'import json, sys; s = json.load(open("api.json")); print(json.dumps(eval(sys.argv[1]), sort_keys=True))' "$2"
}

# a planted hill: its top found within tolerance and called a maximum,
# inside the region; the bowl of the other response a minimum
found_the_optimum() {
    surface_design "iodepth=24,numjobs=6"
    qd doe surface ccd > out
    assert_contains "$(flat out)" "ccd: read_iops (jobs.0.read.iops, maximise), 16 of 16 points measured"
    assert_contains "$(flat out)" "a maximum, inside the design region"
    assert_contains "$(flat out)" "the maximum is inside the design region: confirm it"
    assert_contains "$(flat out)" "lack of fit"
    assert_contains "$(flat out)" "R2 1.0000"
    "$PY" - out <<'PYEOF'
import re, sys
t = open(sys.argv[1]).read()
row = lambda f: re.search(r"^\s+%s\s+(\S+)\s+(\S+)" % f, t, re.M).groups()
d, j = float(row("iodepth")[0]), float(row("numjobs")[0])
assert abs(d - 24) < 1 and abs(j - 6) < 0.5, (d, j)
PYEOF
    qd doe surface ccd -c read_lat_mean > out
    assert_contains "$(flat out)" "read_lat_mean (jobs.0.read.clat_ns.mean, minimise)"
    assert_contains "$(flat out)" "a minimum, inside the design region"
    assert_contains "$(flat out)" "the minimum is inside the design region"
}

# a hill whose top is beyond iodepth's high level: on the edge, said
found_the_edge() {
    surface_design "iodepth=60,numjobs=6"
    qd doe surface ccd -c read_iops > out
    assert_contains "$(flat out)" "outside the design region"
    assert_contains "$(flat out)" "on its edge (iodepth at its high level)"
    assert_contains "$(flat out)" "another round is needed"
    assert_eq "$(api read_iops 's["verdict"]["where"]')" '"edge"'
    assert_eq "$(api read_iops 's["optimum"]["edge"]')" '[["iodepth", "high"]]'
}

# a point fio failed at is not measured: left out of doe's fit, never
# handed over as 0, and drawn as not measured
t_a_failed_point_is_left_out() {
    stand_in_doe
    FIO_FAIL="--iodepth=36 --numjobs=9" surface_design "iodepth=24,numjobs=6"
    qd doe surface ccd > out
    assert_contains "$(flat out)" "15 of 16 points measured"
    assert_contains "$(flat out)" "a maximum, inside the design region"
    assert_eq "$(grep -c '^read_iops ' "$FAKE_BIN/doe-values")" "15"
    assert_eq "$(grep -cE ' (0|0\.0)$' "$FAKE_BIN/doe-values")" "0"
    assert_eq "$(api read_iops '[p["values"] for p in s["pairs"][0]["design"] if (p["a"], p["b"]) == (36, 9)]')" "[[null]]"
}

# --report keeps doe's report, its surface plots among the plots, where
# qd web links it; the contours qd web draws are doe's model on a grid
t_report_and_the_contours() {
    stand_in_doe
    surface_design "iodepth=24,numjobs=6"
    qd doe surface ccd --report > out
    assert_contains "$(flat out)" "doe's report: $XDG_CACHE_HOME/quarterdeck/doe/"
    assert_contains "$(flat out)" "rsm_read_iops_iodepth_vs_numjobs.png"
    assert_contains "$(flat out)" "qd web links it from the design's page (column jobs.0.read.iops)"
    qd doe surface ccd -c read_iops --json > s.json
    "$PY" - <<'PYEOF'
import json
s = json.load(open("s.json"))
assert s["response"] == "read_iops" and s["optimize"] == "maximize", s
assert s["stationary"]["kind"] == "maximum" and s["stationary"]["inside"]
assert s["verdict"]["where"] == "inside", s["verdict"]
assert s["model"]["kind"] == "quadratic", s["model"]
(p,) = s["pairs"]
assert (p["a"], p["b"]) == ("iodepth", "numjobs"), p
assert len(p["x"]) == len(p["y"]) == 25 and len(p["z"]) == 25
assert (p["x"][0], p["x"][-1], p["y"][0], p["y"][-1]) == (4, 36, 1, 9)
# the grid's centre is doe's intercept; its top is near the planted 90000
b = dict(s["model"]["terms"])
assert abs(p["z"][12][12] - b["intercept"]) < 1e-6, (p["z"][12][12], b)
top = max(v for r in p["z"] for v in r)
assert 89800 < top < 90200, top
# levels inside the grid's range; every band is one of them; lines on it
assert all(p["min"] < v < p["max"] for v in p["levels"]), p["levels"]
assert all(0 <= v <= len(p["levels"]) for r in p["bands"] for v in r)
for ln in p["lines"]:
    for x1, y1, x2, y2 in ln["segments"]:
        assert 4 <= x1 <= 36 and 4 <= x2 <= 36 and 1 <= y1 <= 9 and 1 <= y2 <= 9
assert sum(len(ln["segments"]) for ln in p["lines"]) > 20
# the face-centred design's nine places, its centre run eight times
assert len(p["design"]) == 9, p["design"]
assert [len(d["points"]) for d in p["design"] if (d["a"], d["b"]) == (20, 5)] == [8]
assert abs(p["marks"]["stationary"]["a"] - 24) < 1, p["marks"]
assert p["held"] == [], p["held"]
PYEOF
}

# a design doe fits no quadratic to (two levels a factor) has no
# stationary point, and qd says what would; what it cannot do is refused
t_no_surface_and_refusals() {
    stand_in_doe
    surface_design "iodepth=24,numjobs=6"
    "$PY" - <<'PYEOF'
import json
c = json.load(open("ccd.json"))
c["metadata"] = {"name": "two", "qd_command": c["metadata"]["qd_command"]}
c["settings"]["operation"] = "full_factorial"
json.dump(c, open("two.json", "w"))
PYEOF
    FIO_PEAK="iodepth=24,numjobs=6" qdf doe run two.json -s hosts.txt -q > /dev/null
    qd_rc doe surface two -c read_iops > out
    assert_status "$QD_RC" 0
    assert_contains "$(flat out)" "doe fitted no quadratic surface here (4 points measured)"
    assert_contains "$(flat out)" "qd doe next two"
    # no -c, and two responses with no follow-up's to choose: which?
    qd_rc doe surface two 2> err
    assert_status "$QD_RC" 2
    assert_contains "$(cat err)" "a surface of which response? -c one of: read_iops, read_lat_mean"
    qd_rc doe surface ccd -c read_iops,read_lat_mean 2> err
    assert_status "$QD_RC" 2
    assert_contains "$(cat err)" "a surface is of one response"
    qd_rc doe surface nothing 2> err
    assert_status "$QD_RC" 2
    assert_contains "$(cat err)" "no design 'nothing'"
}

t_finds_the_known_optimum() { stand_in_doe; found_the_optimum; }
t_an_optimum_outside_is_on_the_edge() { stand_in_doe; found_the_edge; }

t_with_the_real_doe() {
    if ! command -v doe > /dev/null 2>&1; then
        echo "  (doe is not installed here: pip install doehelper)"
        return 0
    fi
    unset QD_DOE
    found_the_optimum
    qd doe surface ccd --report > out
    assert_contains "$(flat out)" "rsm_read_iops_iodepth_vs_numjobs.png"
    rm -rf "$QD_STORE"
    found_the_edge
}

run_test "a known optimum, found and classified"        t_finds_the_known_optimum
run_test "an optimum outside the region is on the edge" t_an_optimum_outside_is_on_the_edge
run_test "a failed point is left out, not 0"           t_a_failed_point_is_left_out
run_test "--report, and the contours qd web draws"      t_report_and_the_contours
run_test "no surface to fit, and refusals"              t_no_surface_and_refusals
run_test "with the real doe, where installed"           t_with_the_real_doe
finish
