#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Martin J. Gallagher
#
# test_pacing.sh -- a campaign's pacing: --max-per caps per power domain,
# --ramp, --window (QD-020).  The scheduler is driven with a fake clock;
# the campaign cases run real (short) commands and read when each host
# started and ended.

set -u
source "$(dirname "${BASH_SOURCE[0]}")/test_helper.bash"

have_muster() {
    command -v muster > /dev/null 2>&1 || "$PY" -c 'import binnacle.muster' 2>/dev/null
}

py() { (cd "$QD_DIR" && "$PY" -c "$1"); }

t_the_gate_with_a_fake_clock() {
    out="$(py '
from quarterdeck.pacing import Gate
class H(object):
    def __init__(s, n, pdu): s.name, s.attrs = n, [("pdu", pdu)]
hs = [H("a", "p1"), H("b", "p1"), H("c", "p1"), H("d", "p2"), H("e", "")]
g = Gate([("pdu", 2)], spacing=10.0)
t, order, running, waiting = 0.0, [], [], list(hs)
while waiting:
    i, w = g.pick(waiting, t)
    if i is not None:
        h = waiting.pop(i)
        g.start(h, t)
        running.append(h)
        order.append("%s@%g" % (h.name, t))
    elif w is None:         # nothing fits until a host ends: the oldest
        g.end(running.pop(0))
    else:
        t += w              # the fake clock moves; nothing sleeps
print(" ".join(order))
')"
    # a and b take p1's two places, so c waits and d (p2) and e (no pdu)
    # go past it; the ramp spaces every start by 10 s of the fake clock
    assert_eq "$out" "a@0 b@10 d@20 e@30 c@40"
}

t_windows() {
    out="$(py '
import datetime as D
from quarterdeck.pacing import parse_windows, in_window, next_open, window_closes
w = parse_windows(["Mon-Fri 18:00-06:00"])
t = lambda s: D.datetime.strptime(s, "%Y-%m-%d %H:%M")
# 2026-11-09 is a Monday
for s in ("2026-11-09 17:59", "2026-11-09 18:00", "2026-11-10 05:59",
          "2026-11-10 06:00", "2026-11-14 03:00", "2026-11-14 18:00",
          "2026-11-15 12:00"):
    print(s, in_window(w, t(s)))
print("next", next_open(w, t("2026-11-14 18:00")))
print("closes", window_closes(w, t("2026-11-09 23:00")))
w2 = parse_windows(["Sat,Sun 00:00-24:00; 22:00-04:00"])
print("w2", in_window(w2, t("2026-11-15 12:00")), in_window(w2, t("2026-11-11 23:30")),
      in_window(w2, t("2026-11-11 12:00")))
')"
    assert_contains "$out" "2026-11-09 17:59 False"
    assert_contains "$out" "2026-11-09 18:00 True"
    assert_contains "$out" "2026-11-10 05:59 True"
    assert_contains "$out" "2026-11-10 06:00 False"
    # Friday night's window runs into Saturday morning
    assert_contains "$out" "2026-11-14 03:00 True"
    assert_contains "$out" "2026-11-14 18:00 False"
    assert_contains "$out" "2026-11-15 12:00 False"
    assert_contains "$out" "next 2026-11-16 18:00:00"
    assert_contains "$out" "closes 2026-11-10 06:00:00"
    assert_contains "$out" "w2 True True False"
}

seed() {
    install_fake_ssh
    : > "$TEST_TMPDIR/times"
    : > hosts.txt
    for h in a b c d e f; do fake_host "$h"; done
    printf 'a pdu=p1\nb pdu=p1\nc pdu=p1\nd pdu=p1\ne pdu=p2\nf pdu=p2\n' > hosts.txt
    # each host notes when it started and ended, and holds on for a moment
    cat > "$TEST_TMPDIR/work.sh" <<'SH'
t() { "$PY" -c 'import time; print("%.3f" % time.time())'; }
echo "start $(t) $FAKE_HOST" >> "$TIMES"
sleep 0.4
echo "end $(t) $FAKE_HOST" >> "$TIMES"
echo ok: 1
SH
    export TIMES="$TEST_TMPDIR/times" PY
}

# the most hosts of one pdu running at once, from the start/end log
max_overlap() {
    "$PY" - "$TEST_TMPDIR/times" "$1" <<'PYEOF'
import sys
pdu = {"a": "p1", "b": "p1", "c": "p1", "d": "p1", "e": "p2", "f": "p2"}
ev = []
for ln in open(sys.argv[1]):
    kind, t, h = ln.split()
    if sys.argv[2] in ("all", pdu[h]):
        ev.append((float(t), 0 if kind == "end" else 1))
run = best = 0
for _, k in sorted(ev):
    run += 1 if k else -1
    best = max(best, run)
print(best)
PYEOF
}

t_max_per_holds_and_is_kept() {
    have_muster || { echo "  (no muster here: pip install binnacle)"; return 0; }
    seed
    qd campaign new burn -s hosts.txt --into 1 --max-per pdu=2 \
        -- bash "$TEST_TMPDIR/work.sh" > out
    assert_contains "$(cat out)" "at most  2 per pdu running at once"
    assert_contains "$(qd campaign status burn)" "2 per pdu"
    # run takes the cap from the campaign: no flag given here
    qdf_rc campaign run burn --jobs 6 > out 2>&1
    assert_status "$QD_RC" 0
    assert_eq "$(grep -c '^start' "$TEST_TMPDIR/times")" "6"
    assert_eq "$(max_overlap p1)" "2"
    assert_eq "$(max_overlap p2)" "2"
    # the caps are per value: p2's hosts ran beside p1's
    [ "$(max_overlap all)" -ge 3 ] || fail "only $(max_overlap all) ran at once"
}

t_a_ramp_spaces_the_starts() {
    have_muster || { echo "  (no muster here: pip install binnacle)"; return 0; }
    seed
    qd campaign new r -s hosts.txt --into 1 --ramp 4/s \
        -- bash "$TEST_TMPDIR/work.sh" > out
    qdf_rc campaign run r --jobs 6 > out 2>&1
    assert_status "$QD_RC" 0
    gap="$("$PY" - "$TEST_TMPDIR/times" <<'PYEOF'
import sys
ts = sorted(float(l.split()[1]) for l in open(sys.argv[1]) if l.startswith("start"))
# 4 a second: the six starts span at least 1.25 s, and no second holds
# more than 4 of them, give or take one for process start-up jitter (a
# stamp is taken inside the host's command, after ssh and bash started)
busiest = max(sum(1 for u in ts if t <= u < t + 1.0) for t in ts)
print(ts[-1] - ts[0] >= 1.1 and busiest <= 5, len(ts))
PYEOF
)"
    assert_eq "$gap" "True 6"
}

t_windows_hold_back_parts() {
    have_muster || { echo "  (no muster here: pip install binnacle)"; return 0; }
    seed
    qd campaign new w -s hosts.txt --into 2 --window "Mon-Fri 18:00-06:00" \
        -- bash "$TEST_TMPDIR/work.sh" > out
    # Monday noon: closed, nothing taken, the next window named
    QD_NOW=2026-11-09T12:00 qdf_rc campaign run w > out 2>&1
    assert_status "$QD_RC" 0
    assert_contains "$(cat out)" "outside its windows"
    assert_contains "$(cat out)" "the next opens Mon 2026-11-09 18:00"
    assert_eq "$(grep -c '^start' "$TEST_TMPDIR/times")" "0"
    assert_contains "$(QD_NOW=2026-11-09T12:00 qd campaign status w)" \
        "closed; the next opens Mon 2026-11-09 18:00"
    assert_contains "$(qd campaign status w)" "0 of 2 parts done"
    # Monday night: open, and every part runs
    QD_NOW=2026-11-09T23:00 qdf_rc campaign run w > out 2>&1
    assert_status "$QD_RC" 0
    assert_contains "$(qd campaign status w)" "2 of 2 parts done"
    assert_contains "$(QD_NOW=2026-11-09T23:00 qd campaign status w)" \
        "open now, until Tue 06:00"
}

t_bad_pacing_is_refused() {
    have_muster || { echo "  (no muster here: pip install binnacle)"; return 0; }
    install_fake_ssh
    fake_host a
    for bad in "--max-per pdu" "--max-per pdu=0" "--max-per pdu=2,pdu=3" \
               "--ramp fast" "--ramp 0/min" "--window Funday 10:00-11:00" \
               "--window 25:00-26:00" "--window Mon"; do
        # shellcheck disable=SC2086
        qd_rc campaign new x -S a --into 1 $bad -- true > out 2>&1
        assert_status "$QD_RC" 2
    done
    assert_contains "$(qd campaign ls)" "no campaigns"
}

t_rate_spaces_new_connections() {
    install_fake_ssh
    : > hosts.txt
    for i in $(seq -w 1 50); do fake_host "n$i"; echo "n$i" >> hosts.txt; done
    cat > "$TEST_TMPDIR/stamp.sh" <<'SH'
"$PY" -c 'import time; print("%.3f" % time.time())' >> "$TIMES"
SH
    export TIMES="$TEST_TMPDIR/times" PY
    : > "$TIMES"
    t0="$("$PY" -c 'import time; print(time.time())')"
    qdf_rc run -s hosts.txt -q --no-store --rate 10/s -- bash "$TEST_TMPDIR/stamp.sh" > out 2>&1
    assert_status "$QD_RC" 0
    "$PY" - "$TIMES" "$t0" > got <<'PYEOF'
import sys
ts = sorted(float(l) for l in open(sys.argv[1]))
# 50 connections at 10 a second: the last starts about 4.9 s in, and no
# second holds more than 10 starts, give or take one for process jitter
busiest = max(sum(1 for u in ts if t <= u < t + 1.0) for t in ts)
print(len(ts), ts[-1] - float(sys.argv[2]) >= 4.8, busiest <= 11)
PYEOF
    assert_eq "$(cat got)" "50 True True"
    qd_rc run -s hosts.txt -q --no-store --rate fast -- true > out 2>&1
    assert_status "$QD_RC" 2
    assert_contains "$(cat out)" "--rate wants"
}

t_the_open_file_limit_is_respected() {
    install_fake_ssh
    : > hosts.txt
    for i in $(seq 1 60); do fake_host "h$i"; echo "h$i" >> hosts.txt; done
    # a hard limit of 64: 32 at once would run out of pipes, and every ssh
    # that could not start would read as a host that did not answer
    (ulimit -n 64; "$PY" "$QD_DIR/qd" run --ssh "$FAKE_BIN/ssh" -s hosts.txt \
        -q --no-store -j 32 -- 'sleep 0.1; echo v: 1' > out 2> err)
    assert_contains "$(cat out)" "60 hosts, 60 ok"
    assert_contains "$(cat err)" "so 4 run at once instead"
    # a low soft limit under a high hard one is simply raised, unsaid
    (ulimit -Sn 64; ulimit -Hn 4096 2> /dev/null || true; "$PY" "$QD_DIR/qd" run \
        --ssh "$FAKE_BIN/ssh" -s hosts.txt -q --no-store -j 32 \
        -- 'echo v: 1' > out 2> err)
    assert_contains "$(cat out)" "60 hosts, 60 ok"
    assert_not_contains "$(cat err)" "run at once instead"
    out="$(py '
from quarterdeck.fleet import fit_jobs
class R(object):
    RLIMIT_NOFILE, RLIM_INFINITY = 7, -1
    def __init__(s, soft, hard, settable=True):
        s.lim, s.settable = [soft, hard], settable
    def getrlimit(s, k): return tuple(s.lim)
    def setrlimit(s, k, v):
        if not s.settable: raise ValueError("no")
        s.lim = list(v)
print(fit_jobs(32, R(1024, 1024)))
print(fit_jobs(32, R(64, 4096)))
print(fit_jobs(32, R(64, 64))[0])
print(fit_jobs(32, R(64, -1, settable=False))[0])
print(fit_jobs(500, R(256, 256))[0])
')"
    assert_eq "$out" "$(printf "(32, '')\n(32, '')\n4\n4\n43")"
}

# QD-035: a campaign's duration and windows, estimated before it starts

# a fleet of 40 hosts, h01..h40, ten to a rack, and NAME's history: each
# took SECONDS (an import named after the campaign, as a probe's run is)
forty() {
    : > hosts.txt
    printf 'host,status,duration_s\n' > hist.csv
    for i in $(seq -w 1 40); do
        r=$(( (10#$i - 1) / 10 + 1 ))
        echo "h$i rack=r$r ${3:-}" >> hosts.txt
        echo "h$i,ok,$2" >> hist.csv
    done
    qd import hist.csv --name "$1" > /dev/null
}

t_estimate_by_hand() {
    have_muster || { echo "  (no muster here: pip install binnacle)"; return 0; }
    forty est 300
    # one part of 40 hosts, 2 per rack at once: 8 at a time, so 5 passes
    # of 5 minutes, 25 minutes, inside one 2-hour window
    qd campaign new est -s hosts.txt --into 1 --max-per rack=2 \
        --window "18:00-20:00" -- work > /dev/null
    qd_rc campaign estimate est --start 2026-11-09T18:00 > out
    assert_status "$QD_RC" 0
    out="$(cat out)"
    assert_contains "$out" "wall time  25m 00s (p10-p90 25m 00s - 25m 00s), from Mon 2026-11-09 18:00 to Mon 2026-11-09 18:25"
    assert_contains "$out" "windows    1 window: Mon 11-09 18:00 until Mon 11-09 20:00"
    assert_contains "$out" "2 hosts per rack at most (r1), of 2 allowed"
    assert_contains "$out" "same hosts"
    json="$(qd campaign estimate est --start 2026-11-09T18:00 --json)"
    assert_contains "$json" '"wall_s": 1500.0'
    assert_contains "$json" '"source": "same hosts"'
    # a part a rack, an hour's window: 18:00, 18:25 and 18:50 start in
    # the first (the third runs on to 19:15), the fourth waits a day
    qd campaign new est2 -s hosts.txt --by rack --max-per rack=2 \
        --window "18:00-19:00" -- work > /dev/null
    printf 'host,status,duration_s\n' > h2.csv
    for i in $(seq -w 1 40); do echo "h$i,ok,300" >> h2.csv; done
    qd import h2.csv --name est2 > /dev/null
    out="$(qd campaign estimate est2 --start 2026-11-09T18:00)"
    assert_contains "$out" "2 windows: Mon 11-09 18:00 until Mon 11-09 19:00; Tue 11-10 18:00 until Tue 11-10 19:00"
    assert_contains "$out" "to Tue 2026-11-10 18:25"
    assert_contains "$out" "part rack-r3 runs 15m 00s past its window's close"
    # two workers, each with caps of its own: two parts at once
    out="$(qd campaign estimate est2 --start 2026-11-09T18:00 --workers 2)"
    assert_contains "$out" "to Mon 2026-11-09 18:50"
    assert_contains "$out" "2 hosts per rack at most"
}

t_estimate_unknown_and_assumed() {
    have_muster || { echo "  (no muster here: pip install binnacle)"; return 0; }
    printf 'a rack=r1\nb rack=r1\n' > hosts.txt
    qd campaign new fresh -s hosts.txt --into 1 -- never-run-before > /dev/null
    qd_rc campaign estimate fresh --start 2026-11-09T18:00 > out
    assert_status "$QD_RC" 1
    assert_contains "$(cat out)" "wall time  unknown: no history of this command for 1 part"
    assert_contains "$(cat out)" "unknown"
    assert_not_contains "$(cat out)" "0s"
    qd_rc campaign estimate fresh --start 2026-11-09T18:00 --assume 300 --jobs 1 > out
    assert_status "$QD_RC" 0
    assert_contains "$(cat out)" "wall time  10m 00s"
    assert_contains "$(cat out)" "assumed"
    # the fleet's history covers a host with none of its own
    printf 'host,status,duration_s\nother,ok,60\nb,failed,999\n' > h.csv
    qd import h.csv --name fresh > /dev/null
    out="$(qd campaign estimate fresh --start 2026-11-09T18:00 --jobs 1)"
    assert_contains "$out" "wall time  2m 00s"
    assert_contains "$out" "fleet"
}

t_power_budget() {
    have_muster || { echo "  (no muster here: pip install binnacle)"; return 0; }
    forty pw 300
    # 400 W a host, 1000 W a rack: two at once a rack, as --max-per 2
    qd campaign new pw -s hosts.txt --into 1 --max-watts rack=1000 \
        --watts 400 -- work > out
    assert_contains "$(cat out)" "power    at most 1000W per rack drawn at once (a host's draw: its watts attribute, else 400W)"
    out="$(qd campaign estimate pw --start 2026-11-09T18:00)"
    assert_contains "$out" "wall time  25m 00s"
    assert_contains "$out" "800 watts per rack at most (r1), of 1000 allowed"
    # a budget over all hosts, with each host's own draw
    forty pw2 300 watts=250
    qd campaign new pw2 -s hosts.txt --into 1 --max-watts 2.5kW -- work > /dev/null
    out="$(qd campaign estimate pw2 --start 2026-11-09T18:00)"
    # ten at a time: 4 passes, 20 minutes, 2500 W
    assert_contains "$out" "wall time  20m 00s"
    assert_contains "$out" "2500 watts at most, of 2500 allowed"
    # an unknown draw is not zero, and a host bigger than its budget
    # could never start: both refused before anything is kept
    printf 'a rack=r1\nb rack=r1 watts=900\n' > small.txt
    qd_rc campaign new x -s small.txt --into 1 --max-watts rack=800 -- work 2> err
    assert_status "$QD_RC" 2
    assert_contains "$(cat err)" "a has no watts attribute"
    qd_rc campaign new x -s small.txt --into 1 --max-watts rack=800 --watts 100 -- work 2> err
    assert_status "$QD_RC" 2
    assert_contains "$(cat err)" "b draws 900W, more than the 800W budget per rack"
    for bad in "--max-watts rack=lots" "--max-watts 0" "--watts 5 " "--max-watts r=1,r=2"; do
        # shellcheck disable=SC2086
        qd_rc campaign new x -s small.txt --into 1 $bad -- work > out 2>&1
        assert_status "$QD_RC" 2
    done
    assert_not_contains "$(qd campaign ls)" " x "
}

t_power_budget_holds_in_a_run() {
    have_muster || { echo "  (no muster here: pip install binnacle)"; return 0; }
    seed
    # 500 W each, 1000 W a pdu: p1's four hosts two at a time
    qd campaign new hot -s hosts.txt --into 1 --max-watts pdu=1000 \
        --watts 500 -- bash "$TEST_TMPDIR/work.sh" > /dev/null
    qdf_rc campaign run hot --jobs 6 > out 2>&1
    assert_status "$QD_RC" 0
    assert_eq "$(grep -c '^start' "$TEST_TMPDIR/times")" "6"
    assert_eq "$(max_overlap p1)" "2"
    [ "$(max_overlap all)" -ge 3 ] || fail "only $(max_overlap all) ran at once"
}

t_estimate_against_a_real_run() {
    have_muster || { echo "  (no muster here: pip install binnacle)"; return 0; }
    seed
    # one run first, so the store holds each host's duration
    qd campaign new first -s hosts.txt --into 1 --max-per pdu=2 \
        -- bash "$TEST_TMPDIR/work.sh" > /dev/null
    qdf_rc campaign run first --jobs 6 > /dev/null 2>&1
    qd campaign new second -s hosts.txt --into 1 --max-per pdu=2 \
        -- bash "$TEST_TMPDIR/work.sh" > /dev/null
    est="$(qd campaign estimate second --jobs 6 --json | "$PY" -c 'import json,sys; print(json.load(sys.stdin)["wall_s"])')"
    : > "$TEST_TMPDIR/times"
    qdf_rc campaign run second --jobs 6 > /dev/null 2>&1
    # the real wall time, first start to last end, within 50% (and a
    # second) of the estimate: the hosts sleep 0.4 s, ssh's start-up is
    # what varies
    "$PY" - "$TEST_TMPDIR/times" "$est" <<'PYEOF' || fail "estimate $est s is not near the real run"
import sys
ts = [float(l.split()[1]) for l in open(sys.argv[1])]
real, est = max(ts) - min(ts), float(sys.argv[2])
print("real %.2f est %.2f" % (real, est))
sys.exit(0 if abs(real - est) <= 0.5 * est + 1.0 else 1)
PYEOF
}

t_dry_run_says_how_long() {
    have_muster || { echo "  (no muster here: pip install binnacle)"; return 0; }
    forty dry 300
    qd campaign new dry -s hosts.txt --into 1 --max-per rack=2 -- work > /dev/null
    install_fake_ssh
    QD_NOW=2026-11-09T18:00 qdf_rc campaign run dry --dry-run > out 2>&1
    assert_contains "$(head -3 out)" "# qd campaign estimate -- dry"
    assert_contains "$(cat out)" "# wall time  25m 00s"
}

run_test "the gate, with a fake clock"           t_the_gate_with_a_fake_clock
run_test "windows: open, closed, overnight, next" t_windows
run_test "--max-per holds, and the campaign keeps it" t_max_per_holds_and_is_kept
run_test "--ramp spaces the starts"              t_a_ramp_spaces_the_starts
run_test "--window holds parts back"             t_windows_hold_back_parts
run_test "bad pacing is refused"                 t_bad_pacing_is_refused
run_test "--rate spaces new connections"         t_rate_spaces_new_connections
run_test "the open-file limit: raised, or fewer at once" t_the_open_file_limit_is_respected
run_test "estimate: by hand, windows, workers"   t_estimate_by_hand
run_test "estimate: unknown, assumed, the fleet's" t_estimate_unknown_and_assumed
run_test "a power budget, and its estimate"      t_power_budget
run_test "a power budget holds in a run"         t_power_budget_holds_in_a_run
run_test "estimate against a real run"           t_estimate_against_a_real_run
run_test "a dry run says how long"               t_dry_run_says_how_long
finish
