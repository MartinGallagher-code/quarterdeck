#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Martin J. Gallagher

# qd doe next and qd doe run --like (QD-069): from QD-067's fio screen, a
# central composite or Box-Behnken follow-up on the factors that matter,
# the rest held at their better level, run on the host and target the
# screen ran on.  fio is the helper's stand_in_fio, whose answer depends on
# known factors (listed above it in test_helper.bash); doe is the helper's
# stand_in_doe, and the real one too where it is installed.

set -u
source "$(dirname "${BASH_SOURCE[0]}")/test_helper.bash"

# the screen, run and filed: on host a (or the hosts given)
screen() {
    stand_in_fio
    install_fake_ssh
    printf '' > hosts.txt
    for h in "${@:-a}"; do
        fake_host "$h"
        echo "$h" >> hosts.txt
    done
    qd doe init fio > /dev/null
    sed -i.bak "s#/mnt/DRIVE/qd-fio.dat#/srv/scratch/qd-fio.dat#" fio-screen.json
    qdf doe run fio-screen.json -s hosts.txt -q > /dev/null
}

# a key of the follow-up config, as JSON
cfg() { "$PY" -c 'import json,sys; c = json.load(open(sys.argv[1])); exec("print(json.dumps(" + sys.argv[2] + ", sort_keys=True))")' "$1" "$2"; }

t_next_keeps_the_big_factors() {
    stand_in_doe
    screen
    qd doe next fio-screen -c read_iops > out
    f=fio-screen-read-iops-ccd.json
    assert_file_exists "$f"
    assert_contains "$(cat out)" "wrote $f: central-composite on 2 factors, 16 points"
    assert_contains "$(cat out)" "read_iops (jobs.0.read.iops, maximise), as the screen fio-screen"
    # the planted factors, with their shares; what the screen did not see
    # move read IOPS is held at its first level, and said so
    row() { grep -E "^  $1 " out | tr -s ' '; }
    assert_eq "$(row iodepth)" " iodepth 1 / 32 67% varied: the screen's range"
    assert_eq "$(row bs)" " bs 4 / 128 33% varied: the screen's range"
    assert_eq "$(row numjobs)" " numjobs 1 0% held: no effect seen, its first level"
    assert_eq "$(row filename)" " filename /srv/scratch/qd-fio.dat held, as in the screen"
    assert_contains "$(cat out)" "central composite, doe suggest's choice (Central composite on 2"
    assert_contains "$(cat out)" "doe generate lays out 16 points"
    assert_contains "$(cat out)" "study     fio-screen, the screen's own"
    assert_contains "$(cat out)" "the screen's own range for each varied factor, not re-centred"
    assert_contains "$(cat out)" "qd doe run $f --like fio-screen"
    assert_eq "$(cfg $f 'c["settings"]["operation"]')" '"central_composite"'
    assert_eq "$(cfg $f '[x["name"] for x in c["factors"]]')" '["iodepth", "bs"]'
    assert_eq "$(cfg $f '[x["levels"] for x in c["factors"]]')" '[["1", "32"], ["4", "128"]]'
    assert_eq "$(cfg $f 'c["fixed_factors"]')" '{"direct": "0", "filename": "/srv/scratch/qd-fio.dat", "ioengine": "libaio", "numjobs": "1", "ramp_time": "10", "runtime": "60", "rw": "rw", "rwmixread": "30", "size": "8G"}'
    # the screen's command and responses; the study is the screen's
    assert_eq "$(cfg $f 'c["metadata"]["qd_command"]')" "$(cfg fio-screen.json 'c["metadata"]["qd_command"]')"
    assert_eq "$(cfg $f 'len(c["responses"])')" "8"
    assert_eq "$(cfg $f 'c["metadata"]["qd_study"]')" '"fio-screen"'
    assert_eq "$(cfg $f 'c["metadata"]["qd_follows"]')" '{"column": "jobs.0.read.iops", "design": "fio-screen", "optimize": "maximize", "response": "read_iops"}'
    # doe lays out what it said: 16 points of the two factors
    out="$(qd doe plan "$f")"
    assert_contains "$out" "fio-screen-read-iops-ccd: 16 points of 2 factors, central_composite"
    # a written config is never written over
    qd_rc doe next fio-screen -c read_iops 2> err
    assert_status "$QD_RC" 2
    assert_contains "$(cat err)" "$f is there already: move it, or -o another file"
}

# the held factors are at the level the screen found better for the
# response, and the follow-up's command carries them
t_held_factors_at_their_better_level() {
    stand_in_doe
    screen
    qd doe next fio-screen -c read_lat_p99 --factors iodepth,bs,numjobs -o bbd.json > out
    assert_contains "$(cat out)" "wrote bbd.json: box-behnken on 3 factors, 15 points"
    assert_contains "$(cat out)" "read_lat_p99 (jobs.0.read.clat_ns.percentile.99.000000, minimise)"
    row() { grep -E "^  $1 " out | tr -s ' '; }
    assert_eq "$(row rw)" " rw rw 71% held: its better level"
    assert_eq "$(row ioengine)" " ioengine io_uring 29% held: its better level"
    # Box-Behnken's middle of 1..32 is 16.5: said, with what to do
    assert_contains "$(cat out)" "iodepth's middle level is 16.5, and a count takes whole"
    assert_contains "$(cat out)" "numjobs's middle level is 4.5"
    assert_not_contains "$(cat out)" "warning   bs's middle"
    assert_eq "$(cfg bbd.json 'c["settings"]["operation"]')" '"box_behnken"'
    assert_eq "$(cfg bbd.json '[c["fixed_factors"][k] for k in ("rw", "ioengine", "direct", "rwmixread")]')" '["rw", "io_uring", "0", "30"]'
    qdf_rc doe run bbd.json --like fio-screen -q > out
    assert_status "$QD_RC" 0
    assert_contains "$(cat out)" "15 of 15 points measured"
    # every point of the follow-up ran with the held levels
    n="$(grep -c -- '--rw=rw .*--ioengine=io_uring --direct=0' "$FAKE_SSH_LOG")"
    [ "$n" -ge 15 ] || fail "the held levels were not in the follow-up's commands ($n)"
    assert_eq "$(grep -c -- '--rwmixread=30 --bs=' "$FAKE_SSH_LOG")" "$((15 + 4))"
}

# a categorical factor is never varied: held at its better level, and said
t_a_categorical_factor_is_held() {
    stand_in_doe
    screen
    qd doe next fio-screen -c read_lat_p99 --factors iodepth,rw,ioengine,bs > out
    assert_contains "$(cat out)" "note      rw is categorical: a central composite or Box-Behnken varies a"
    assert_contains "$(cat out)" "number between two levels, so it is held at rw, its better level"
    assert_contains "$(cat out)" "ioengine is categorical"
    assert_contains "$(cat out)" "central-composite on 2 factors"
    f=fio-screen-read-lat-p99-ccd.json
    assert_eq "$(cfg $f '[x["name"] for x in c["factors"]]')" '["bs", "iodepth"]'
    assert_eq "$(cfg $f '[c["fixed_factors"][k] for k in ("rw", "ioengine")]')" '["rw", "io_uring"]'
    # by default the big factors are taken: for read p99 both categorical,
    # and nothing numeric moved it, so there is nothing to fit a surface over
    qd_rc doe next fio-screen -c read_lat_p99 -o p99.json 2> err
    assert_status "$QD_RC" 2
    assert_contains "$(cat err)" "nothing to fit a surface over"
    assert_contains "$(cat err)" "rw is categorical"
    assert_contains "$(cat err)" "ioengine is categorical"
    assert_no_file p99.json
    # one big numeric factor is topped up with the next that moved it
    qd doe next fio-screen -c read_lat_mean > out
    assert_contains "$(tr -s ' \n' ' ' < out)" "numjobs added: the next largest numeric effect, so the surface has two dimensions"
    assert_eq "$(cfg fio-screen-read-lat-mean-ccd.json '[x["name"] for x in c["factors"]]')" '["iodepth", "numjobs"]'
}

t_next_refuses_what_it_cannot_do() {
    stand_in_doe
    screen
    qd_rc doe next fio-screen 2> err
    assert_status "$QD_RC" 2
    assert_contains "$(cat err)" "a follow-up is for one response: -c NAME, one of read_iops, write_iops"
    qd_rc doe next fio-screen -c read_iops,write_iops 2> err
    assert_status "$QD_RC" 2
    qd_rc doe next fio-screen -c read_iops --factors iodepth,blocksize 2> err
    assert_status "$QD_RC" 2
    assert_contains "$(cat err)" "--factors: blocksize is not a factor of the screen"
    # doe suggest's own choice when the budget is too small: said, not written
    qd_rc doe next fio-screen -c read_iops --budget 10 2> err
    assert_status "$QD_RC" 2
    assert_contains "$(cat err)" "doe suggest, for 2 numeric factors with a budget of 10 runs, chose full_factorial"
    assert_contains "$(cat err)" "a larger --budget"
    assert_no_file fio-screen-read-iops-ccd.json
    qd_rc doe next nothing -c read_iops 2> err
    assert_status "$QD_RC" 2
    assert_contains "$(cat err)" "no design 'nothing'"
}

# --like: exactly the hosts and the target the screen ran on, said; a host
# that has gone is reported, never skipped in silence
t_like_runs_where_the_screen_ran() {
    stand_in_doe
    screen a b
    qd doe next fio-screen -c write_iops > /dev/null
    f=fio-screen-write-iops-ccd.json
    # a hosts.txt here names other hosts: --like does not read it
    fake_host c
    echo c > hosts.txt
    : > "$FAKE_SSH_LOG"
    qdf_rc doe run "$f" --like fio-screen -q > out
    assert_status "$QD_RC" 0
    assert_contains "$(cat out)" "like fio-screen: on its 2 hosts a, b, with its command, holding what it held (filename=/srv/scratch/qd-fio.dat ramp_time=10 runtime=60 size=8G)"
    assert_contains "$(cat out)" "16 of 16 points measured"
    assert_eq "$(grep -c '2/2 ok' out)" "16"
    grep -q -- '--filename=/srv/scratch/qd-fio.dat --size=8G' "$FAKE_SSH_LOG" ||
        fail "the follow-up did not write the screen's file"
    assert_eq "$(qd show latest --cols host --format csv | sed 1d | sort | tr '\n' ' ')" "a b "
    # the design is filed as part of the screen's study
    out="$(qd doe status fio-screen-write-iops-ccd)"
    assert_contains "$out" "study    fio-screen (follows fio-screen: write_iops; like fio-screen)"
    # and doe analyses it as it does any design
    qd doe analyze fio-screen-write-iops-ccd -c write_iops > an.out
    assert_contains "$(cat an.out)" "=== Main Effects: write_iops ==="
    # -s and --like are two host lists
    qdf_rc doe run "$f" --like fio-screen -s hosts.txt 2> err
    assert_status "$QD_RC" 2
    assert_contains "$(cat err)" "--like is the host list -- the hosts fio-screen ran on -- so it takes no -s"
    # another target than the screen's is refused
    sed 's#/srv/scratch/qd-fio.dat#/srv/other.dat#' "$f" > other.json
    qdf_rc doe run other.json --like fio-screen --name other 2> err
    assert_status "$QD_RC" 2
    assert_contains "$(cat err)" "fio-screen ran with filename=/srv/scratch/qd-fio.dat, and other.json has filename=/srv/other.dat"
    # b has gone: its points there are not measured, and that is said
    fake_host_unreachable b
    qd doe next fio-screen -c write_iops -o again.json > /dev/null
    qdf_rc doe run again.json --like fio-screen --name again -q > out 2> err
    assert_status "$QD_RC" 1
    assert_contains "$(cat out)" "like fio-screen: on its 2 hosts a, b"
    assert_eq "$(grep -c '1/2 ok' out)" "16"
    assert_contains "$(cat err)" "b answered at none of the 16 points run here (b unreachable) -- fio-screen ran there; has it gone?"
}

t_with_the_real_doe() {
    if ! command -v doe > /dev/null 2>&1; then
        echo "  (doe is not installed here: pip install doehelper)"
        return 0
    fi
    unset QD_DOE
    screen
    qd doe next fio-screen -c read_iops > out
    assert_contains "$(cat out)" "central-composite on 2 factors, 16 points"
    assert_eq "$(cfg fio-screen-read-iops-ccd.json '[x["name"] for x in c["factors"]]')" '["iodepth", "bs"]'
    qd doe next fio-screen -c read_lat_p99 --factors iodepth,bs,numjobs -o bbd.json > out
    assert_contains "$(cat out)" "box-behnken on 3 factors, 15 points"
    assert_contains "$(cat out)" "iodepth's middle level is 16.5"
    qdf_rc doe run fio-screen-read-iops-ccd.json --like fio-screen -q > out
    assert_status "$QD_RC" 0
    assert_contains "$(cat out)" "16 of 16 points measured"
    qd doe analyze fio-screen-read-iops-ccd -c read_iops > an.out
    assert_contains "$(cat an.out)" "read_iops"
}

run_test "next keeps the big factors, doe's design"     t_next_keeps_the_big_factors
run_test "held factors at their better level"           t_held_factors_at_their_better_level
run_test "a categorical factor is held, and said"       t_a_categorical_factor_is_held
run_test "next refuses what it cannot do"               t_next_refuses_what_it_cannot_do
run_test "--like runs where the screen ran"             t_like_runs_where_the_screen_ran
run_test "with the real doe, where installed"           t_with_the_real_doe
finish
