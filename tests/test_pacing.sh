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

run_test "the gate, with a fake clock"           t_the_gate_with_a_fake_clock
run_test "windows: open, closed, overnight, next" t_windows
run_test "--max-per holds, and the campaign keeps it" t_max_per_holds_and_is_kept
run_test "--ramp spaces the starts"              t_a_ramp_spaces_the_starts
run_test "--window holds parts back"             t_windows_hold_back_parts
run_test "bad pacing is refused"                 t_bad_pacing_is_refused
run_test "--rate spaces new connections"         t_rate_spaces_new_connections
run_test "the open-file limit: raised, or fewer at once" t_the_open_file_limit_is_respected
finish
