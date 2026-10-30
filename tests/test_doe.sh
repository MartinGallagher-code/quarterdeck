#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Martin J. Gallagher

# qd doe: designs from design_of_experiments' doe, measured on the fleet,
# analysed by doe.  doe is played by the helper's stand_in_doe, which writes
# what the real one writes (design_matrix.json; run_<id>.json read back) --
# the real one needs Python 3.10 and numpy -- and the real one is used too
# where it is installed.

set -u
source "$(dirname "${BASH_SOURCE[0]}")/test_helper.bash"

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
    # every numeric column: the response, not the factors that set it
    out="$(qd compare --group stream-test | sed -n '/medians/,/keys changed/p')" || true
    assert_contains "$out" "mbps"
    assert_not_contains "$out" "window"
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

# the typo guard checks every point before any runs, and names the verb
t_a_refused_point_runs_nothing() {
    stand_in_doe
    seed
    config
    qdf_rc doe run bench.json -s hosts.txt -- 'echo {streams}; [ {window} = 1024 ] && rm -rf /tmp/qd-nothing' 2> err
    assert_status "$QD_RC" 2
    assert_contains "$(cat err)" "qd doe run --yes"
    assert_eq "$(ssh_calls)" "0"
}

# a refused first run files no design: the command fixed, it runs
t_a_refused_first_run_files_no_design() {
    stand_in_doe
    seed
    config
    qdf_rc doe run bench.json -s hosts.txt -- 'echo {streams} {window}; rm -rf /tmp/qd-x' 2> err
    assert_status "$QD_RC" 2
    qd_rc doe status stream-test 2> err
    assert_contains "$(cat err)" "no design"
    qdf_rc doe run bench.json -s hosts.txt -q -- "$BENCH" > out
    assert_status "$QD_RC" 0
    assert_contains "$(cat out)" "4 of 4 points measured"
}

# plan shows the order run measures in: the same seed, from the config
t_plan_is_the_order_run_measures() {
    stand_in_doe
    seed
    config
    plan="$(qd doe plan bench.json | sed -n 's/^ *\([0-9]\) *1 *\([0-9]*\) *\([0-9]*\)$/\1 \2 \3/p')"
    qdf doe run bench.json -s hosts.txt -q -- "$BENCH" > /dev/null
    status="$(qd doe status stream-test | sed -n 's/^ *\([0-9]\) *1 *streams=\([0-9]*\) window=\([0-9]*\).*/\1 \2 \3/p')"
    [ -n "$plan" ] || fail "no points read from plan"
    assert_eq "$status" "$plan"
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

# more host groups than blocks: the ones left out are said
t_unblocked_groups_are_said() {
    stand_in_doe
    seed
    config
    printf 'a rack=r1\nb rack=r2\nc rack=r3\n' > hosts.txt
    qdf doe run bench.json -s hosts.txt --blocks-by rack -q -- "$BENCH" > out 2> err
    assert_contains "$(cat err)" "rack-r2, rack-r3 will not be measured"
    qdf_rc doe run bench.json -s hosts.txt -q -- "$BENCH" 2> err
    assert_status "$QD_RC" 2
    assert_contains "$(cat err)" "was run --blocks-by rack"
}

# a level with a space in it is read back whole: `-w 1M`, not `-w`
t_a_level_with_a_space() {
    stand_in_doe
    seed
    cat > win.json <<'EOF'
{"metadata": {"name": "Window"},
 "factors": [{"name": "args", "levels": ["-w 64K", "-w 1M"], "type": "categorical"}],
 "responses": [{"name": "mbps", "optimize": "maximize"}],
 "settings": {"operation": "full_factorial", "block_count": 1}}
EOF
    qdf doe run win.json -s hosts.txt -q -- 'echo "mbps: 1"; echo {args} > /dev/null' > /dev/null
    out="$(qd compare --group window -c mbps)" || true
    assert_contains "$out" "factors args=-w 1M"
    assert_contains "$(qd show latest --cols host,args --format csv)" "a,-w "
}

run_test "a level with a space"                      t_a_level_with_a_space
run_test "more groups than blocks: said"            t_unblocked_groups_are_said
run_test "plan shows doe's design"                   t_plan_shows_the_design
run_test "run measures every point, once"            t_run_measures_every_point_once
run_test "analyze hands doe the responses"           t_analyze_hands_doe_the_responses
run_test "--blocks-by: a block per host group"       t_blocks_run_on_host_groups
run_test "a {name} that is no factor: refused"       t_a_factor_that_is_not_there_is_refused
run_test "a refused point: nothing runs"              t_a_refused_point_runs_nothing
run_test "a refused first run files no design"       t_a_refused_first_run_files_no_design
run_test "plan is the order run measures"           t_plan_is_the_order_run_measures
run_test "no doe: how to get it"                     t_no_doe_says_how_to_get_it
run_test "with the real doe, where installed"        t_with_the_real_doe
finish
