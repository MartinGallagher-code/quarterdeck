#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Martin J. Gallagher

# qd doe init fio: QD-067's Plackett-Burman screen of fio's parameters on
# one drive of one host.  fio is played by the helper's stand_in_fio, whose
# JSON answer is a known function of its options (the factors it was
# built to depend on are listed above it in test_helper.bash), so the
# screen's ranking must name exactly those.  doe is the helper's
# stand_in_doe, and the real one too where it is installed; provost is the
# real one, which parses fio's JSON into the columns the responses read.

set -u
source "$(dirname "${BASH_SOURCE[0]}")/test_helper.bash"

# the screen's starting config, its fio file on a scratch directory
screen() {
    stand_in_fio
    install_fake_ssh
    fake_host a
    echo a > hosts.txt
    qd doe init fio > init.out
    sed -i.bak "s#/mnt/DRIVE/qd-fio.dat#${1:-/srv/scratch/qd-fio.dat}#" fio-screen.json
}

# the line of the ranking that starts with a response, and the one after
ranking() { sed -n "/^  $1 /{N;p;}" "${2:-an.out}"; }

t_init_writes_the_screen() {
    stand_in_doe
    qd doe init fio > out
    assert_file_exists fio-screen.json
    assert_contains "$(cat out)" "wrote fio-screen.json: plackett-burman, 7 factors"
    assert_contains "$(cat out)" "iodepth    1 / 32"
    assert_contains "$(cat out)" "filename   /mnt/DRIVE/qd-fio.dat  held fixed"
    assert_contains "$(cat out)" "qd doe run fio-screen.json -s hosts.txt"
    # every factor carries its reason; every response the column it is read from
    "$PY" - <<'EOF'
import json
c = json.load(open("fio-screen.json"))
assert c["settings"]["operation"] == "plackett_burman", c["settings"]
names = [f["name"] for f in c["factors"]]
assert names == ["bs", "iodepth", "numjobs", "rwmixread", "rw", "ioengine",
                 "direct"], names
for f in c["factors"]:
    assert len(f["levels"]) == 2 and len(f["description"]) > 40, f
assert set(c["fixed_factors"]) == {"filename", "size", "runtime", "ramp_time"}
for r in c["responses"]:
    assert r["column"].startswith("jobs.0.") and r["optimize"], r
assert "{bs}k" in c["metadata"]["qd_command"]
EOF
    # the plan says run needs no command: the config has one
    out="$(qd doe plan fio-screen.json)"
    assert_contains "$out" "fio-screen: 8 points of 7 factors"
    assert_contains "$out" "qd doe run fio-screen.json -s hosts.txt "
    assert_not_contains "$out" "COMMAND"
    # an edited config is never written over
    qd_rc doe init fio 2> err
    assert_status "$QD_RC" 2
    assert_contains "$(cat err)" "fio-screen.json is there already"
    qd_rc doe init iperf 2> err
    assert_status "$QD_RC" 2
    assert_contains "$(cat err)" "no starting config 'iperf': fio"
}

t_the_screen_files_every_point_with_fio_columns() {
    stand_in_doe
    screen
    qdf_rc doe run fio-screen.json -s hosts.txt -q > out
    assert_status "$QD_RC" 0
    assert_contains "$(cat out)" "8 of 8 points measured"
    assert_contains "$(cat out)" "next: qd doe analyze fio-screen"
    assert_eq "$(grep -c '1/1 ok' out)" "8"
    # the command was the config's, its fixed factors and levels put in
    grep -q 'fio --name=qd-screen --filename=/srv/scratch/qd-fio.dat --size=8G --time_based --runtime=60 --ramp_time=10 --group_reporting --output-format=json --rw=' "$FAKE_SSH_LOG" ||
        fail "the command run was not the config's: $(tail -1 "$FAKE_SSH_LOG")"
    # a point's row: its factor levels, and fio's JSON as provost parses it
    csv="$(qd show latest --cols host,bs,iodepth,numjobs,rwmixread,rw,ioengine,direct,jobs.0.read.iops,jobs.0.write.clat_ns.percentile.99.000000 --format csv)"
    assert_contains "$csv" "host,bs,iodepth,numjobs,rwmixread,rw,ioengine,direct,jobs.0.read.iops,jobs.0.write.clat_ns.percentile.99.000000"
    assert_eq "$(printf '%s\n' "$csv" | sed -n 2p | cut -d, -f1)" "a"
    for c in jobs.0.read.iops jobs.0.write.iops jobs.0.read.bw_bytes \
             jobs.0.read.clat_ns.mean; do
        [ -n "$(qd show latest --cols "$c" --format csv | sed -n 2p)" ] ||
            fail "no $c in the point's row"
    done
}

t_the_analysis_ranks_the_planted_factors_per_response() {
    stand_in_doe
    screen
    qdf doe run fio-screen.json -s hosts.txt -q > /dev/null
    qd doe analyze fio-screen > an.out
    assert_contains "$(cat an.out)" "8 responses per point"
    assert_contains "$(cat an.out)" "read_lat_p99=jobs.0.read.clat_ns.percentile.99.000000"
    # each response's big factors are the ones stand_in_fio depends on, in
    # the order of their effects, with the level that is better for it
    assert_contains "$(ranking read_iops)" "big: iodepth 67% (max 32), bs 33% (max 4)"
    assert_contains "$(ranking write_iops)" "big: numjobs 71% (max 8), rwmixread 29% (max 30)"
    assert_contains "$(ranking read_lat_mean)" "big: iodepth 80% (min 1)"
    assert_contains "$(ranking read_lat_mean)" "then: numjobs 20%"
    assert_contains "$(ranking read_lat_p99)" "big: rw 71% (min rw), ioengine 29% (min io_uring)"
    assert_contains "$(ranking write_lat_mean)" "big: numjobs 100% (min 1)"
    assert_contains "$(ranking write_lat_p99)" "big: direct 74% (min 1), rw 26% (min rw)"
    # and they differ where the stand-in makes them differ
    assert_not_contains "$(ranking read_iops)" "numjobs 71%"
    assert_not_contains "$(ranking write_iops | head -1)" "iodepth"
    # all of them went to doe in one go, each with its main effects
    for r in read_iops write_iops read_bw write_bw read_lat_mean \
             read_lat_p99 write_lat_mean write_lat_p99; do
        assert_contains "$(cat an.out)" "=== Main Effects: $r ==="
    done
    assert_eq "$(grep -c '^read_iops ' "$FAKE_BIN/doe-values")" "8"
}

# -c picks responses: a column, or a response of the config by name
t_c_picks_the_responses() {
    stand_in_doe
    screen
    qdf doe run fio-screen.json -s hosts.txt -q > /dev/null
    out="$(qd doe analyze fio-screen -c jobs.0.read.iops)"
    assert_contains "$out" "jobs.0.read.iops per point (median over the hosts"
    assert_contains "$out" "big: iodepth 67% (max 32), bs 33% (max 4)"
    assert_not_contains "$out" "write_iops"
    out="$(qd doe analyze fio-screen -c read_iops,write_lat_p99)"
    assert_contains "$out" "2 responses per point"
    assert_contains "$out" "=== Main Effects: write_lat_p99 ==="
    assert_not_contains "$out" "=== Main Effects: read_bw ==="
    # a column no point has is said, not analysed as zeros
    qd_rc doe analyze fio-screen -c jobs.0.nothing 2> err
    assert_status "$QD_RC" 2
    assert_contains "$(cat err)" "only 0 of the design's 8 points have a jobs.0.nothing"
}

# a point where fio failed: fio still prints its JSON, every figure 0,
# and none of those zeros reaches doe -- the point is blank, left out
t_a_failed_point_is_left_out_not_zero() {
    stand_in_doe
    screen
    # one point of the stand-in's design, and only one, has all three
    FIO_FAIL="--bs=128k --iodepth=32 --numjobs=8" \
        qdf_rc doe run fio-screen.json -s hosts.txt -q > out
    assert_status "$QD_RC" 1
    assert_contains "$(cat out)" "0/1 ok"
    assert_contains "$(cat out)" "7 of 8 points measured"
    # the zeros were filed, as fio printed them, beside a status that is not ok
    run="$(grep '0/1 ok' out | sed 's/.*(\(.*\))$/\1/')"
    row="$(qd show "$run" --cols status,jobs.0.error,jobs.0.read.iops --format csv | sed -n 2p)"
    case "$row" in
        ok,*) fail "the failed point's row is ok: $row" ;;
        *,22,0 | *,22,0.0) ;;
        *) fail "the failed point's row: $row" ;;
    esac
    qd doe analyze fio-screen > an.out
    point="$(qd doe status fio-screen | awk '/0\/1$/ {print $1}')"
    [ -n "$point" ] || fail "no failed point in qd doe status"
    # its row of responses is blank, and doe was handed 7 points, no zeros
    assert_eq "$(grep -cE "^ +$point\$" an.out)" "1"
    assert_contains "$(cat an.out)" "Partial mode: analyzing 7/8 completed runs"
    assert_eq "$(grep -c '^read_iops ' "$FAKE_BIN/doe-values")" "7"
    assert_eq "$(grep -c " $point " "$FAKE_BIN/doe-values")" "0"
    assert_eq "$(grep -cE ' (0|0\.0)$' "$FAKE_BIN/doe-values")" "0"
    assert_contains "$(ranking read_iops)" "big: iodepth"
    # run again, the failed point (and only it) is measured again
    qdf_rc doe run fio-screen.json -s hosts.txt -q > out
    assert_status "$QD_RC" 0
    assert_eq "$(grep -c '1/1 ok' out)" "1"
    assert_contains "$(cat out)" "8 of 8 points measured"
}

# fio writing a device destroys what is on it: refused without --yes,
# before any point runs; reading one, or writing a file, is not
t_a_raw_device_write_needs_yes() {
    stand_in_doe
    screen /dev/nvme0n1
    qdf_rc doe run fio-screen.json -s hosts.txt -q 2> err
    assert_status "$QD_RC" 2
    assert_contains "$(cat err)" "it looks like fio writing a raw device"
    assert_contains "$(cat err)" "qd doe run --yes"
    assert_eq "$(ssh_calls)" "0"
    qd_rc doe status fio-screen 2> err
    assert_contains "$(cat err)" "no design"
    qdf_rc doe run fio-screen.json -s hosts.txt -q --yes > out
    assert_status "$QD_RC" 0
    assert_contains "$(cat out)" "8 of 8 points measured"
    # a read of the device is no write
    qdf_rc run -s hosts.txt -q -- fio --filename=/dev/nvme0n1 --rw=randread --output-format=json > /dev/null
    assert_status "$QD_RC" 0
    qdf_rc run -s hosts.txt -q -- fio --rw=randwrite --filename=/dev/sdb 2> err
    assert_status "$QD_RC" 2
    assert_contains "$(cat err)" "fio writing a raw device"
}

# what a design holds fixed is part of it: another file is another design
t_another_fixed_factor_is_another_design() {
    stand_in_doe
    screen
    qdf doe run fio-screen.json -s hosts.txt -q > /dev/null
    sed -i.bak 's#"size": "8G"#"size": "16G"#' fio-screen.json
    qdf_rc doe run fio-screen.json -s hosts.txt -q 2> err
    assert_status "$QD_RC" 2
    assert_contains "$(cat err)" "was run with other fixed factors (filename=/srv/scratch/qd-fio.dat ramp_time=10 runtime=60 size=8G)"
    qdf_rc doe run fio-screen.json -s hosts.txt -q --name fio-16g > out
    assert_status "$QD_RC" 0
    grep -q -- '--size=16G' "$FAKE_SSH_LOG" || fail "the new design did not use size 16G"
    # and a {name} that is neither factor nor held fixed is still refused
    qdf_rc doe run fio-screen.json -s hosts.txt --name typo -- 'fio --bs={bs}k --size={sise}' 2> err
    assert_status "$QD_RC" 2
    assert_contains "$(cat err)" "{sise}, which is not a factor of the design"
    assert_contains "$(cat err)" "held fixed: filename, ramp_time, runtime, size"
}

t_with_the_real_doe() {
    if ! command -v doe > /dev/null 2>&1; then
        echo "  (doe is not installed here: pip install doehelper)"
        return 0
    fi
    unset QD_DOE
    screen
    qdf doe run fio-screen.json -s hosts.txt -q > out
    assert_contains "$(cat out)" "8 of 8 points measured"
    qd doe analyze fio-screen > an.out
    assert_contains "$(cat an.out)" "=== Alias Structure: Plackett Burman ==="
    assert_contains "$(ranking read_iops)" "big: iodepth 67% (max 32), bs 33% (max 4)"
    assert_contains "$(ranking write_iops)" "big: numjobs 71% (max 8), rwmixread 29% (max 30)"
    assert_contains "$(ranking read_lat_p99)" "big: rw 71% (min rw), ioengine 29% (min io_uring)"
    assert_contains "$(ranking write_lat_p99)" "big: direct 74% (min 1), rw 26% (min rw)"
}

run_test "init fio writes the screen's config"         t_init_writes_the_screen
run_test "the screen files every point, fio's columns" t_the_screen_files_every_point_with_fio_columns
run_test "the planted factors rank first, per response" t_the_analysis_ranks_the_planted_factors_per_response
run_test "-c picks the responses"                       t_c_picks_the_responses
run_test "a failed point is left out, not zero"         t_a_failed_point_is_left_out_not_zero
run_test "fio writing a raw device needs --yes"         t_a_raw_device_write_needs_yes
run_test "another fixed factor, another design"         t_another_fixed_factor_is_another_design
run_test "with the real doe, where installed"           t_with_the_real_doe
finish
