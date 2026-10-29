#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Martin J. Gallagher

# qd doe: designs from design_of_experiments' doe, measured on the fleet,
# analysed by doe.  doe is played by a stand-in that writes what the real
# one writes (design_matrix.json; run_<id>.json read back) -- the real one
# needs Python 3.9 and numpy -- and the real one is used too where it is
# installed.

set -u
source "$(dirname "${BASH_SOURCE[0]}")/test_helper.bash"

stand_in_doe() {
    cat > "$FAKE_BIN/doe" <<'EOF'
#!/usr/bin/env python3
# doe, for the suite: full factorial designs, block_count copies of them,
# and two-level main effects -- the files and headings the real one has.
import itertools, json, os, sys
a = sys.argv[1:]
def opt(n):
    return a[a.index(n) + 1] if n in a else None
cfg = json.load(open(opt("--config")))
out = cfg["settings"]["out_directory"]
if a[0] == "generate":
    names = [f["name"] for f in cfg["factors"]]
    base = list(itertools.product(*[f["levels"] for f in cfg["factors"]]))
    runs = []
    for b in range(int(cfg["settings"].get("block_count", 1))):
        for combo in base:
            runs.append({"run_id": len(runs) + 1, "block_id": b + 1,
                         "factor_values": dict(zip(names, combo)),
                         "whole_plot_id": 0})
    if not os.path.isdir(out):
        os.makedirs(out)
    json.dump({"factor_names": names, "operation": "full_factorial",
               "metadata": {}, "runs": runs},
              open(os.path.join(out, "design_matrix.json"), "w"))
    open(opt("--output"), "w").write("#!/bin/sh\n")
    print("Generated %d runs" % len(runs))
elif a[0] == "analyze":
    d = opt("--results-dir")
    m = json.load(open(os.path.join(d, "design_matrix.json")))
    resp = cfg["responses"][0]["name"]
    vals = {}
    for r in m["runs"]:
        p = os.path.join(d, "run_%d.json" % r["run_id"])
        if os.path.exists(p):
            vals[r["run_id"]] = json.load(open(p))[resp]
    print("=== Main Effects: %s ===" % resp)
    for f in m["factor_names"]:
        lv = sorted(set(r["factor_values"][f] for r in m["runs"]), key=float)
        mean = []
        for l in lv:
            xs = [vals[r["run_id"]] for r in m["runs"]
                  if r["factor_values"][f] == l and r["run_id"] in vals]
            mean.append(sum(xs) / len(xs))
        print("%-20s %10.4f" % (f, mean[-1] - mean[0]))
EOF
    chmod +x "$FAKE_BIN/doe"
    export QD_DOE="$FAKE_BIN/doe"
}

config() {
    cat > bench.json <<EOF
{"metadata": {"name": "Stream test"},
 "factors": [{"name": "streams", "levels": ["1", "4"], "type": "continuous"},
             {"name": "window", "levels": ["64", "1024"], "type": "continuous"}],
 "responses": [{"name": "mbps", "optimize": "maximize"}],
 "settings": {"operation": "full_factorial", "block_count": ${1:-1}}}
EOF
}

seed() {
    install_fake_ssh
    for h in a b c d; do fake_host "$h"; done
    printf 'a rack=r1\nb rack=r1\nc rack=r2\nd rack=r2\n' > hosts.txt
}

# a "benchmark" whose answer is known: 300 more with 4 streams, window/8
# shellcheck disable=SC2016  # expanded on the far side, not here
BENCH='echo "mbps: $(( 900 + 300 * ({streams} > 1) + {window} / 8 ))"'

t_plan_shows_the_design() {
    stand_in_doe
    config
    out="$(qd doe plan bench.json)"
    assert_contains "$out" "stream-test: 4 points of 2 factors"
    assert_contains "$out" "streams"
    assert_contains "$out" "{streams} {window}"
}

t_run_measures_every_point_once() {
    stand_in_doe
    seed
    config
    qdf_rc doe run bench.json -s hosts.txt -q -- "$BENCH" > out
    assert_status "$QD_RC" 0
    assert_contains "$(cat out)" "point 4/4"
    assert_contains "$(cat out)" "4 of 4 points measured"
    # the factors are columns of the point's rows, and provost's
    csv="$(qd show latest --format csv)"
    assert_contains "$csv" "host,rack,streams,window,status"
    assert_contains "$(qd doe status stream-test)" "4 of 4 points measured"
    # measured points are not measured again
    qdf_rc doe run bench.json -s hosts.txt -q -- "$BENCH" > out
    assert_contains "$(cat out)" "nothing left to run"
    assert_eq "$(qd log | grep -c stream_test)" "4"
}

t_analyze_hands_doe_the_responses() {
    stand_in_doe
    seed
    config
    qdf doe run bench.json -s hosts.txt -q -- "$BENCH" > /dev/null
    out="$(qd doe analyze stream-test -c mbps)"
    assert_contains "$out" "mbps per point"
    assert_contains "$out" "=== Main Effects: mbps ==="
    assert_contains "$out" "streams                300.0000"
    assert_contains "$out" "window                 120.0000"
    out="$(qd compare --group stream-test -c mbps)" || true
    assert_contains "$out" "factors streams=4"
}

t_blocks_run_on_host_groups() {
    stand_in_doe
    seed
    config 2
    qdf doe run bench.json -s hosts.txt --blocks-by rack -q -- "$BENCH" > out
    assert_contains "$(cat out)" "point 8/8"
    # block 1 on rack r1, block 2 on rack r2
    st="$(qd doe status stream-test)"
    assert_contains "$st" "8 of 8 points measured"
    assert_contains "$(qd show latest --cols host --format csv)" "c"
    assert_not_contains "$(qd show latest --cols host --format csv)" "a"
}

t_a_factor_that_is_not_there_is_refused() {
    stand_in_doe
    seed
    config
    qdf_rc doe run bench.json -s hosts.txt -- 'iperf3 -P {stream}' 2> err
    assert_status "$QD_RC" 2
    assert_contains "$(cat err)" "{stream}, which is not a factor"
    assert_eq "$(ssh_calls)" "0"
}

t_no_doe_says_how_to_get_it() {
    config
    QD_DOE=/nonexistent/doe PATH="/usr/bin:/bin" qd_rc doe plan bench.json 2> err
    assert_status "$QD_RC" 2
    assert_contains "$(cat err)" "pip install doehelper"
}

t_with_the_real_doe() {
    if ! command -v doe > /dev/null 2>&1; then
        echo "  (doe is not installed here: pip install doehelper)"
        return 0
    fi
    unset QD_DOE
    seed
    config
    qdf doe run bench.json -s hosts.txt -q -- "$BENCH" > /dev/null
    out="$(qd doe analyze stream-test -c mbps)"
    assert_contains "$out" "=== ANOVA Table: mbps ==="
    assert_contains "$out" "streams                300.0000"
}

run_test "plan shows doe's design"                   t_plan_shows_the_design
run_test "run measures every point, once"            t_run_measures_every_point_once
run_test "analyze hands doe the responses"           t_analyze_hands_doe_the_responses
run_test "--blocks-by: a block per host group"       t_blocks_run_on_host_groups
run_test "a {name} that is no factor: refused"       t_a_factor_that_is_not_there_is_refused
run_test "no doe: how to get it"                     t_no_doe_says_how_to_get_it
run_test "with the real doe, where installed"        t_with_the_real_doe
finish
