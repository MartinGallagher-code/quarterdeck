#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Martin J. Gallagher

# Every drive on every host (QD-073): host lines name their drives
# (drives=FILE,FILE drive_model=MODEL), {drive} in a design's command is
# each one's file, and every point runs on every drive -- one at a time on
# each host, or all of a host's at once with --drives-together -- filed
# with drive and drive_model columns.  The analysis, the follow-up, the
# surface and optimize read the rows per drive, model, host or the fleet.
#
# fio is drive_fio below, whose drives differ: on a PM9A3 (a file under
# /srv/nvme*) read IOPS is moved by iodepth alone, on an ST4000 (under
# /srv/sata*) by numjobs alone, and host h2 reads 100 IO/s more than h1
# everywhere.  FIO_PEAK_NVME / FIO_PEAK_SATA=iodepth=D,numjobs=J make
# that model's read IOPS a hill with its top at (D, J) instead.  Every
# call is logged (host, file, start, end), so the suite can tell whether
# a host's drives ran one at a time or at once.  doe is the helper's
# stand_in_doe, and the real one too where it is installed.

set -u
source "$(dirname "${BASH_SOURCE[0]}")/test_helper.bash"
use_fixtures

flat() { tr '\n' ' ' < "$1" | tr -s ' '; }

drive_fio() {
    cat > "$FAKE_BIN/fio" <<'EOF'
#!/usr/bin/env python3
import json, os, sys, time
o = {}
for x in sys.argv[1:]:
    if x.startswith("--"):
        k, _, v = x[2:].partition("=")
        o[k] = v
def num(k, d):
    return float(o.get(k, d).lower().rstrip("kib"))
bs, depth, jobs = num("bs", "4k"), num("iodepth", "1"), num("numjobs", "1")
f, host = o.get("filename", ""), os.environ.get("FAKE_HOST", "")
here = os.path.dirname(os.path.abspath(sys.argv[0]))
t0 = time.time()
time.sleep(float(os.environ.get("FIO_SLEEP", "0")))
calls = os.path.join(here, "fio-calls")
k = len(open(calls).read()) if os.path.exists(calls) else 0
open(calls, "a").write(".")
model = "NVME" if "/nvme" in f else "SATA"
if model == "NVME":
    r = 20000 + 30000 * (depth >= 32)
else:
    r = 5000 + 4000 * (jobs >= 8)
peak = os.environ.get("FIO_PEAK_" + model, "")
if peak:
    p = dict(kv.split("=") for kv in peak.split(","))
    dd, jj = depth - float(p["iodepth"]), jobs - float(p["numjobs"])
    r = 90000 - 50 * dd ** 2 - 1500 * jj ** 2 + 20 * (k % 5 - 2)
r += 100 * (host == "h2")
err = 1 if os.environ.get("FIO_FAIL_FILE") and \
    os.environ["FIO_FAIL_FILE"] in f else 0
if err:
    r = 0
def side(iops, mean_us):
    st = lambda us: {"min": int(us * 500), "max": int(us * 3000),
                     "mean": us * 1000.0, "stddev": us * 100.0, "N": 100}
    clat = st(mean_us)
    clat["percentile"] = {"50.000000": int(mean_us * 1000),
                          "99.000000": int(mean_us * 3000)}
    bw = iops * bs
    return {"io_bytes": int(bw * 1024 * 30), "bw_bytes": int(bw * 1024),
            "bw": int(bw), "iops": float(iops), "runtime": 30000,
            "total_ios": int(iops * 30), "clat_ns": clat,
            "lat_ns": st(mean_us + 2)}
job = {"jobname": o.get("name", "fio"), "groupid": 0, "error": err,
       "elapsed": 31, "read": side(r, 100 + depth),
       "write": side(8000, 80 + jobs), "usr_cpu": 5.0, "sys_cpu": 20.0}
print(json.dumps({"fio version": "fio-3.36", "timestamp": 1751880000,
                  "jobs": [job]}, indent=2))
open(os.path.join(here, "fio-log"), "a").write(
    "%s %s %.4f %.4f\n" % (host, f, t0, time.time()))
sys.exit(err)
EOF
    chmod +x "$FAKE_BIN/fio"
    export PATH="$FAKE_BIN:$PATH"
}

# two hosts, each with a PM9A3 and an ST4000
fleet() {
    drive_fio
    install_fake_ssh
    fake_host h1
    fake_host h2
    cat > hosts.txt <<'EOF'
h1 drives=/srv/nvme0/qd-fio.dat,/srv/sata0/qd-fio.dat drive_model=PM9A3,ST4000 rack=r1
h2 drives=/srv/nvme0/qd-fio.dat,/srv/sata0/qd-fio.dat drive_model=PM9A3,ST4000 rack=r1
EOF
}

# the screen: qd doe init fio-drives, run with the flags given
screen() {
    fleet
    qd doe init fio-drives > init.out
    qdf doe run fio-drives-screen.json -s hosts.txt -q "$@" > run.out 2> run.err
}

# the screen with the stand-in doe, each call a fifth of a second (so the
# timing tells one at a time from at once): made once a suite, a copy for
# each case that asks (QD-074)
screened() {
    stand_in_doe
    FIO_SLEEP=0.2 screen
}

# the line of the ranking that starts with a response, and the one after,
# of the analysis in $2 that follows the heading matching $3
ranking() { sed -n "/$3/,/doe analyze:/p" "$2" | sed -n "/^  $1 /{N;p;}"; }

# whether, per host, the calls' [start, end] in fio-log overlap: prints
# "together" or "apart" for each host, then "hosts-overlap" or
# "hosts-apart" for the first calls of the two hosts
overlaps() {
    "$PY" - "$FAKE_BIN/fio-log" <<'PYEOF'
import sys
calls = [ln.split() for ln in open(sys.argv[1]) if ln.strip()]
by = {}
for h, f, a, b in calls:
    by.setdefault(h, []).append((float(a), float(b)))
for h in sorted(by):
    xs = sorted(by[h])
    hit = any(xs[i + 1][0] < xs[i][1] for i in range(len(xs) - 1))
    print("%s %s" % (h, "together" if hit else "apart"))
a, b = sorted(by["h1"]), sorted(by["h2"])
both = any(x[0] < y[1] and y[0] < x[1] for x in a for y in b)
print("hosts-overlap" if both else "hosts-apart")
PYEOF
}

t_init_writes_the_drives_screen() {
    stand_in_doe
    qd doe init fio-drives > out
    assert_file_exists fio-drives-screen.json
    assert_contains "$(cat out)" "wrote fio-drives-screen.json: plackett-burman, 7 factors"
    assert_contains "$(flat out)" "drives=/srv/nvme0/qd-fio.dat,/srv/nvme1/qd-fio.dat drive_model=PM9A3"
    "$PY" - <<'EOF'
import json
c = json.load(open("fio-drives-screen.json"))
assert "--filename={drive}" in c["metadata"]["qd_command"], c["metadata"]
assert "filename" not in c["fixed_factors"], c["fixed_factors"]
assert c["metadata"]["name"] == "fio-drives-screen"
EOF
}

t_every_drive_of_every_host_one_at_a_time() {
    fixture screened screened
    assert_contains "$(cat run.out)" "8 of 8 points measured"
    # a run per drive slot: the first drive of each host, then the second
    assert_eq "$(grep -c ', drive 1 of 2: 2/2 ok' run.out)" "8"
    assert_eq "$(grep -c ', drive 2 of 2: 2/2 ok' run.out)" "8"
    # every host x drive x point: 2 x 2 x 8 calls, each with its own file
    assert_eq "$(wc -l < "$FAKE_BIN/fio-log" | tr -d ' ')" "32"
    for h in h1 h2; do
        for d in nvme0 sata0; do
            assert_eq "$(grep -c "^$h /srv/$d/qd-fio.dat " "$FAKE_BIN/fio-log")" "8"
        done
    done
    # one drive at a time on each host, the hosts side by side
    assert_eq "$(overlaps)" "h1 apart
h2 apart
hosts-overlap"
    # the rows: host, drive and its model, the host's other attributes
    csv="$(qd show latest --cols host,drive,drive_model,rack,iodepth,jobs.0.read.iops --format csv)"
    assert_contains "$csv" "host,drive,drive_model,rack,iodepth,jobs.0.read.iops"
    assert_contains "$csv" "h1,/srv/sata0/qd-fio.dat,ST4000,r1,"
    assert_contains "$csv" "h2,/srv/sata0/qd-fio.dat,ST4000,r1,"
    assert_not_contains "$csv" "drives="
    # status counts drives: every point 4/4
    qd doe status fio-drives-screen > st.out
    assert_contains "$(cat st.out)" "drives   4 drives, one at a time on each host"
    assert_eq "$(grep -c ' 4/4$' st.out)" "8"
    # run again: nothing is left to run
    qdf doe run fio-drives-screen.json -s hosts.txt -q > again.out
    assert_contains "$(cat again.out)" "nothing left to run"
    assert_eq "$(wc -l < "$FAKE_BIN/fio-log" | tr -d ' ')" "32"
}

t_each_model_has_its_own_effects() {
    fixture screened screened
    # the default: per drive model, each with its own big factor
    qd doe analyze fio-drives-screen -c read_iops > an.out
    assert_contains "$(flat an.out)" "fio-drives-screen, model PM9A3 (h1:/srv/nvme0/qd-fio.dat, h2:/srv/nvme0/qd-fio.dat): jobs.0.read.iops per point"
    assert_contains "$(flat an.out)" "fio-drives-screen, model ST4000 (h1:/srv/sata0/qd-fio.dat, h2:/srv/sata0/qd-fio.dat)"
    assert_contains "$(ranking read_iops an.out 'model PM9A3')" "big: iodepth 100% (max 32)"
    assert_contains "$(ranking read_iops an.out 'model ST4000')" "big: numjobs 100% (max 8)"
    # per drive: four groups, each drive's planted factor
    qd doe analyze fio-drives-screen -c read_iops --per drive > drv.out
    assert_eq "$(grep -c '^qd doe -- fio-drives-screen, drive ' drv.out)" "4"
    assert_contains "$(ranking read_iops drv.out 'drive h2:.srv.sata0')" "big: numjobs 100% (max 8)"
    assert_contains "$(ranking read_iops drv.out 'drive h1:.srv.nvme0')" "big: iodepth 100% (max 32)"
    # one group by name; per host, both models on each host; the fleet
    # as one, both factors
    out="$(qd doe analyze fio-drives-screen -c read_iops --group ST4000)"
    assert_contains "$out" "model ST4000"
    assert_not_contains "$out" "PM9A3"
    qd doe analyze fio-drives-screen -c read_iops --per host > host.out
    assert_eq "$(grep -c '^qd doe -- fio-drives-screen, host h' host.out)" "2"
    qd doe analyze fio-drives-screen -c read_iops --per fleet > fl.out
    assert_contains "$(cat fl.out)" "qd doe -- fio-drives-screen: jobs.0.read.iops per point (median over the hosts that answered)"
    assert_contains "$(ranking read_iops fl.out 'fio-drives-screen:')" "iodepth"
    assert_contains "$(ranking read_iops fl.out 'fio-drives-screen:')" "numjobs"
    # --block drive: each drive of the model an observation, in a block
    : > "$FAKE_BIN/doe-values"
    qd doe analyze fio-drives-screen -c read_iops --group PM9A3 --block drive > blk.out
    assert_contains "$(flat blk.out)" "model PM9A3, each drive a block"
    assert_contains "$(flat blk.out)" "each drive's value at a point is an observation, in a block of its own"
    assert_contains "$(ranking read_iops blk.out 'model PM9A3')" "big: iodepth 100% (max 32)"
    # doe was given a run a point and drive: 16 of them
    assert_eq "$(grep -c '^read_iops ' "$FAKE_BIN/doe-values")" "16"
}

t_drives_together_a_host_at_once() {
    stand_in_doe
    FIO_SLEEP=0.3 screen --drives-together --jobs 1
    assert_contains "$(cat run.out)" "8 of 8 points measured"
    assert_eq "$(grep -c ', 4 drives at once: 4/4 ok' run.out)" "8"
    assert_eq "$(wc -l < "$FAKE_BIN/fio-log" | tr -d ' ')" "32"
    # a host's drives at once; --jobs 1 counts hosts, so the hosts one
    # after the other
    assert_eq "$(overlaps)" "h1 together
h2 together
hosts-apart"
    qd doe status fio-drives-screen > st.out
    assert_contains "$(cat st.out)" "drives   4 drives, all of a host's at once"
    assert_eq "$(grep -c ' 4/4$' st.out)" "8"
    # a design keeps the way it was run: again without the flag, it is
    # still measured together, and nothing is left to run
    qdf doe run fio-drives-screen.json -s hosts.txt -q > again.out
    assert_contains "$(cat again.out)" "nothing left to run"
}

t_a_design_keeps_how_it_ran_its_drives() {
    fixture screened screened
    qdf_rc doe run fio-drives-screen.json -s hosts.txt -q --drives-together 2> err
    assert_status "$QD_RC" 2
    assert_contains "$(cat err)" "the design fio-drives-screen measured its drives one at a time"
}

t_a_failed_slot_runs_again() {
    stand_in_doe
    fleet
    qd doe init fio-drives > /dev/null
    FIO_FAIL_FILE=sata0 qdf_rc doe run fio-drives-screen.json -s hosts.txt -q > out 2> err
    assert_eq "$(grep -c ', drive 2 of 2: 0/2 ok' out)" "8"
    qd doe status fio-drives-screen > st.out
    assert_eq "$(grep -c ' 2/4$' st.out)" "8"
    # the failed drives are blank, never zero, in the ST4000's analysis
    qd_rc doe analyze fio-drives-screen -c read_iops --group ST4000 2> err
    assert_status "$QD_RC" 2
    assert_contains "$(cat err)" "only 0 of the design's 8 points have a jobs.0.read.iops to analyse for model ST4000"
    # run again: the slot that measured nothing runs again, and only it
    qdf doe run fio-drives-screen.json -s hosts.txt -q > again.out
    assert_eq "$(grep -c ', drive 2 of 2: 2/2 ok' again.out)" "8"
    assert_not_contains "$(cat again.out)" "drive 1 of 2"
    qd doe status fio-drives-screen > st.out
    assert_eq "$(grep -c ' 4/4$' st.out)" "8"
    qd doe analyze fio-drives-screen -c read_iops --group ST4000 > an.out
    assert_contains "$(ranking read_iops an.out 'model ST4000')" "big: numjobs 100% (max 8)"
}

t_like_reuses_every_host_and_drive() {
    fixture screened screened
    # a follow-up is for one group
    qd_rc doe next fio-drives-screen -c read_iops 2> err
    assert_status "$QD_RC" 2
    assert_contains "$(flat err)" "a follow-up is for one group, and fio-drives-screen has 2 models under --per model: --group NAME, one of PM9A3, ST4000"
    qd doe next fio-drives-screen -c write_iops --group ST4000 --factors numjobs,iodepth > next.out
    f="fio-drives-screen-write-iops-st4000-ccd"
    assert_file_exists "$f.json"
    assert_contains "$(flat next.out)" "as the screen fio-drives-screen ranked it for model ST4000"
    assert_contains "$(flat next.out)" "measure them on the drives of model ST4000 that fio-drives-screen ran on"
    "$PY" - "$f.json" <<'PYEOF'
import json, sys
c = json.load(open(sys.argv[1]))
assert c["metadata"]["qd_group"] == {"per": "model", "group": "ST4000"}, c["metadata"]
assert c["metadata"]["qd_drives"] == "each", c["metadata"]
PYEOF
    : > "$FAKE_BIN/fio-log"
    qdf doe run "$f.json" --like fio-drives-screen -q > like.out
    assert_contains "$(flat like.out)" "like fio-drives-screen: on its 2 hosts h1, h2, 2 drives (model ST4000), with its command"
    # only the ST4000s ran, every one of them
    assert_eq "$(grep -c '/srv/nvme0' "$FAKE_BIN/fio-log")" "0"
    assert_eq "$(grep -c '^h1 /srv/sata0' "$FAKE_BIN/fio-log")" "$(grep -c '^h2 /srv/sata0' "$FAKE_BIN/fio-log")"
    [ "$(grep -c '^h1 /srv/sata0' "$FAKE_BIN/fio-log")" -gt 0 ] || fail "no ST4000 runs"
    # its analysis reads its own group by default
    qd doe analyze "$f" -c write_iops > an.out
    assert_contains "$(flat an.out)" "$f, model ST4000"
    # --per fleet: one follow-up for every drive, run on all four
    qd doe next fio-drives-screen -c read_iops --per fleet --factors iodepth,numjobs -o fleet.json > /dev/null
    : > "$FAKE_BIN/fio-log"
    qdf doe run fleet.json --like fio-drives-screen -q > fl.out
    assert_contains "$(flat fl.out)" "on its 2 hosts h1, h2, 4 drives, with its command"
    for d in h1\ /srv/nvme0 h1\ /srv/sata0 h2\ /srv/nvme0 h2\ /srv/sata0; do
        [ "$(grep -c "^$d" "$FAKE_BIN/fio-log")" -gt 0 ] || fail "no runs on $d"
    done
}

t_refusals() {
    stand_in_doe
    fleet
    qd doe init fio-drives > /dev/null
    # {drive} with no drives named
    echo h1 > plain.txt
    qdf_rc doe run fio-drives-screen.json -s plain.txt -q 2> err
    assert_status "$QD_RC" 2
    assert_contains "$(flat err)" "the command names {drive}, but no host names its drives: add drives=FILE[,FILE...]"
    # some hosts naming drives, others none
    printf 'h1 drives=/srv/nvme0/a\nh2\n' > some.txt
    qdf_rc doe run fio-drives-screen.json -s some.txt -q 2> err
    assert_contains "$(flat err)" "h2 names no drives: every host needs drives=FILE[,FILE...]"
    # drives named and no {drive} to put them in: said, and each host
    # runs it once, as before drives
    qd doe init fio > /dev/null
    qdf_rc doe run fio-screen.json -s hosts.txt -q > out 2> err
    assert_status "$QD_RC" 0
    assert_contains "$(flat err)" "h1, h2 name drives (drives=), but the command has no {drive}: each host runs it once"
    assert_eq "$(grep -c ': 2/2 ok' out)" "8"
    assert_eq "$(wc -l < "$FAKE_BIN/fio-log" | tr -d ' ')" "16"
    rm "$FAKE_BIN/fio-log"
    # the models do not match the drives; a file the shell would split
    printf 'h1 drives=/srv/a,/srv/b drive_model=X,Y,Z\n' > bad.txt
    qdf_rc doe run fio-drives-screen.json -s bad.txt -q 2> err
    assert_contains "$(flat err)" "h1 names 2 drives and 3 drive models"
    printf 'h1 drives=/srv/a;rm\n' > bad.txt
    qdf_rc doe run fio-drives-screen.json -s bad.txt -q 2> err
    assert_contains "$(flat err)" "the drive file /srv/a;rm has characters a command cannot take"
    # a raw device is refused without --yes, before any point runs
    printf 'h1 drives=/dev/nvme0n1\n' > raw.txt
    qdf_rc doe run fio-drives-screen.json -s raw.txt -q 2> err
    assert_status "$QD_RC" 2
    assert_contains "$(flat err)" "fio writing a raw device"
    assert_no_file "$FAKE_BIN/fio-log"
    qd_rc doe status fio-drives-screen 2> err
    assert_contains "$(cat err)" "no design 'fio-drives-screen'"
    # the flags where they mean nothing
    qdf_rc doe run fio-drives-screen.json -s hosts.txt --per model 2> err
    assert_contains "$(cat err)" "--per chooses the drives an analysis reads"
    qdf_rc doe run fio-screen.json -s plain.txt --drives-together 2> err
    assert_contains "$(flat err)" "--drives-together runs a host's drives at once: the hosts name no drives"
    qdf doe run fio-drives-screen.json -s hosts.txt -q > /dev/null
    qd_rc doe analyze fio-drives-screen -c read_iops --group NOPE 2> err
    assert_contains "$(flat err)" "fio-drives-screen has no model 'NOPE': its models are PM9A3, ST4000"
    qd_rc doe analyze fio-drives-screen -c read_iops --per host --block host 2> err
    assert_contains "$(cat err)" "--block host with --per host"
    qd_rc doe analyze fio-drives-screen -c read_iops --per fleet --group PM9A3 2> err
    assert_contains "$(cat err)" "the fleet is one group"
    qd_rc doe analyze fio-drives-screen -c read_iops --report 2> err
    assert_contains "$(cat err)" "--report keeps one analysis: --group NAME, one of PM9A3, ST4000"
    qd_rc doe surface fio-drives-screen -c read_iops --json 2> err
    assert_contains "$(flat err)" "--json is for one group"
}

# the central composite on every drive: the PM9A3's hill tops out beyond
# the region (iodepth 60), the ST4000's inside it (iodepth 20, 5 jobs)
surface_on_drives() {
    fleet
    cat > ccd.json <<'JSON'
{
  "metadata": {
    "name": "dccd",
    "qd_command": "fio --name=qd --filename={drive} --size=1G --time_based --runtime=5 --group_reporting --output-format=json --rw=randrw --rwmixread=50 --bs=4k --iodepth={iodepth} --numjobs={numjobs} --ioengine=libaio --direct=1"
  },
  "factors": [
    {"name": "iodepth", "levels": ["4", "36"], "type": "continuous"},
    {"name": "numjobs", "levels": ["1", "9"], "type": "continuous"}
  ],
  "responses": [
    {"name": "read_iops", "column": "jobs.0.read.iops", "optimize": "maximize"}
  ],
  "settings": {"operation": "central_composite", "block_count": 1}
}
JSON
    export FIO_PEAK_NVME="iodepth=60,numjobs=6" FIO_PEAK_SATA="iodepth=20,numjobs=5"
    qdf doe run ccd.json -s hosts.txt -q > run.out
}

t_the_surface_and_optimize_per_model() {
    stand_in_doe
    surface_on_drives
    qd doe surface dccd -c read_iops > s.out
    f="$(flat s.out)"
    assert_contains "$f" "qd doe surface -- dccd, model PM9A3 (h1:/srv/nvme0/qd-fio.dat, h2:/srv/nvme0/qd-fio.dat): read_iops"
    assert_contains "$f" "qd doe surface -- dccd, model ST4000 (h1:/srv/sata0/qd-fio.dat, h2:/srv/sata0/qd-fio.dat): read_iops"
    # each model's own verdict
    sed -n '/model PM9A3/,/model ST4000/p' s.out > nvme.out
    sed -n '/model ST4000/,$p' s.out > sata.out
    assert_contains "$(flat nvme.out)" "on its edge"
    assert_contains "$(flat sata.out)" "the maximum is inside the design region"
    qd doe surface dccd -c read_iops --group ST4000 --json > s.json
    "$PY" - s.json <<'PYEOF'
import json, sys
s = json.load(open(sys.argv[1]))
assert s["group"] == {"per": "model", "group": "ST4000"}, s["group"]
assert s["verdict"]["where"] == "inside", s["verdict"]
opt = s["optimum"]["settings"]
assert 15 < float(opt["iodepth"]) < 25 and 4 < float(opt["numjobs"]) < 6, opt
PYEOF
    # optimize is for one group, and runs on its drives alone
    qdf_rc doe optimize dccd -c read_iops --budget 20 -q 2> err
    assert_status "$QD_RC" 2
    assert_contains "$(flat err)" "optimize is for one group"
    : > "$FAKE_BIN/fio-log"
    qdf_rc doe optimize dccd -c read_iops --group ST4000 --budget 20 -q > opt.out 2> opt.err
    f="$(flat opt.out)"
    assert_contains "$f" "qd doe optimize -- dccd: read_iops (jobs.0.read.iops, maximise) from dccd, on h1, h2, 2 drives (model ST4000)"
    assert_contains "$f" "qd doe optimize -- dccd (model ST4000): read_iops"
    assert_contains "$f" "each drive of model ST4000: h1:/srv/sata0/qd-fio.dat, h2:/srv/sata0/qd-fio.dat, {drive} being each one's file"
    assert_contains "$f" "--filename={drive}"
    assert_eq "$(grep -c '/srv/nvme0' "$FAKE_BIN/fio-log")" "0"
    [ "$(wc -l < "$FAKE_BIN/fio-log" | tr -d ' ')" -gt 0 ] || fail "optimize ran nothing"
    # its rounds are the group's, named for it, and read it by default
    qd doe status dccd > st.out
    round="$(grep -o 'dccd-read-iops-st4000-[a-z]*1' opt.out | head -1)"
    [ -n "$round" ] || fail "no round named for the group: $(cat opt.out)"
    qd doe analyze "$round" -c read_iops > ran.out
    assert_contains "$(flat ran.out)" "$round, model ST4000"
    # the budget counts every drive's run
    qdf_rc doe optimize dccd -c read_iops --group ST4000 --budget 20 --json > rep.json
    "$PY" - rep.json <<'PYEOF'
import json, sys
r = json.load(open(sys.argv[1]))
assert r["spent"] <= r["budget"], (r["spent"], r["budget"])
assert r["group"] == {"per": "model", "group": "ST4000"}, r["group"]
assert r["drives"] == ["h1:/srv/sata0/qd-fio.dat", "h2:/srv/sata0/qd-fio.dat"], r["drives"]
s = r["recommended"]["settings"]
assert 14 <= float(s["iodepth"]) <= 26, s
PYEOF
}

# one drive at a time, a point is a run per drive slot: optimize's budget
# counts each, and never goes past it
t_optimize_counts_each_drive_slot() {
    stand_in_doe
    fleet
    cat > hosts.txt <<'EOF'
h1 drives=/srv/sata0/qd-fio.dat,/srv/sata1/qd-fio.dat drive_model=ST4000
EOF
    cat > ccd.json <<'JSON'
{
  "metadata": {
    "name": "two",
    "qd_command": "fio --name=qd --filename={drive} --size=1G --output-format=json --bs=4k --iodepth={iodepth} --numjobs={numjobs}"
  },
  "factors": [
    {"name": "iodepth", "levels": ["4", "36"], "type": "continuous"},
    {"name": "numjobs", "levels": ["1", "9"], "type": "continuous"}
  ],
  "responses": [
    {"name": "read_iops", "column": "jobs.0.read.iops", "optimize": "maximize"}
  ],
  "settings": {"operation": "central_composite", "block_count": 1}
}
JSON
    export FIO_PEAK_SATA="iodepth=20,numjobs=5"
    qdf doe run ccd.json -s hosts.txt -q > /dev/null
    : > "$FAKE_BIN/fio-log"
    qdf_rc doe optimize two -c read_iops --budget 9 -q > opt.out 2> opt.err
    assert_contains "$(flat opt.out)" "a point is 2 runs, a drive at a time"
    n="$(wc -l < "$FAKE_BIN/fio-log" | tr -d ' ')"
    [ "$n" -le 9 ] || fail "optimize made $n runs on a budget of 9"
    assert_eq "$((n % 2))" "0"
}

t_with_the_real_doe() {
    if ! command -v doe > /dev/null 2>&1; then
        echo "  (doe is not installed here: pip install doehelper)"
        return 0
    fi
    unset QD_DOE
    screen
    qd doe analyze fio-drives-screen -c read_iops > an.out
    assert_contains "$(ranking read_iops an.out 'model PM9A3')" "big: iodepth 100% (max 32)"
    assert_contains "$(ranking read_iops an.out 'model ST4000')" "big: numjobs 100% (max 8)"
    # the host as a block: h2's 100 IO/s more is doe's Block row
    qd doe analyze fio-drives-screen -c read_iops --group ST4000 --block host > blk.out
    assert_contains "$(cat blk.out)" "Block"
    assert_contains "$(ranking read_iops blk.out 'model ST4000')" "big: numjobs 100% (max 8)"
}

run_test "init fio-drives writes the screen, {drive} in it" t_init_writes_the_drives_screen
run_test "every drive of every host, one at a time"      t_every_drive_of_every_host_one_at_a_time
run_test "each model has its own effects"                t_each_model_has_its_own_effects
run_test "--drives-together: a host's drives at once"    t_drives_together_a_host_at_once
run_test "a design keeps how it ran its drives"          t_a_design_keeps_how_it_ran_its_drives
run_test "a drive slot that failed runs again"           t_a_failed_slot_runs_again
run_test "--like reuses every host and drive"            t_like_reuses_every_host_and_drive
run_test "refusals"                                      t_refusals
run_test "the surface and optimize, per model"           t_the_surface_and_optimize_per_model
run_test "optimize counts each drive slot's run"         t_optimize_counts_each_drive_slot
run_test "with the real doe, where installed"            t_with_the_real_doe
finish
