# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Martin J. Gallagher
"""How long a campaign will take, before it starts (QD-035).

    qd campaign estimate NAME [--workers N] [--assume SECONDS] [--start T]

Each host's expected duration comes from what the store already holds:
the median of its own earlier runs of the campaign's command, else the
median over every host that ran it, else --assume.  A part none of
those covers is unknown, never zero.  The parts are then put through the
scheduler a real `campaign run` uses -- pacing.Gate, with the campaign's
caps, power budget and ramp, `--jobs` hosts at a time per worker, each
worker its own caps as in a real run -- and through its windows, which
gate the start of a part, as `campaign run` does: a part started inside
a window runs to its end.  So the estimate and the run cannot pace
differently.

The result: wall time (and the spread, from each host's p10 and p90),
how many windows it takes and when each closes, and the most hosts (and
watts) running at once per capped attribute.
"""

import datetime
import heapq

from . import pacing
from .stats import quantile

SAME, FLEET, ASSUMED, UNKNOWN = "same hosts", "fleet", "assumed", "unknown"


def _median(xs):
    return quantile(sorted(xs), .5) if xs else None


def _q(xs, q):
    return quantile(sorted(xs), q) if xs else None


def history(st, c):
    """{host: [seconds per earlier run]}, and how many runs they came
    from: every run in the store of the campaign's command, or of its
    name (its own parts, a probe of that name), each ok host's
    duration_s."""
    from .common import QdError
    per, runs = {}, 0
    for e in st.entries():
        m = e.meta
        if m.get("command") != c.command and c.name not in (
                m.get("group"), m.get("name")):
            continue
        try:
            t = e.load()
        except QdError:
            continue
        if not (t.has("host") and t.has("duration_s")):
            continue
        hi, di = t.index("host"), t.index("duration_s")
        si = t.index("status") if t.has("status") else None
        got = False
        for r in t.rows:
            if si is not None and r[si].strip() not in ("ok", ""):
                continue        # a failed or timed-out host says little
            try:
                d = float(r[di])
            except ValueError:
                continue
            if d < 0:
                continue
            per.setdefault(r[hi], []).append(d)
            got = True
        runs += 1 if got else 0
    return per, runs


class PartTimes(object):
    def __init__(self, part):
        self.part = part
        self.source = UNKNOWN
        self.n = 0              # the values the durations rest on
        self.runs = 0
        self.mid = {}           # host name -> median seconds
        self.lo = {}            # p10
        self.hi = {}            # p90


def part_times(c, hist, runs, assume=None):
    """[PartTimes] per part: each host's own median where it has history,
    the fleet's where it has none, --assume where nothing has."""
    fleet = [d for ds in hist.values() for d in ds]
    out = []
    for part, hosts in c.parts:
        pt = PartTimes(part)
        pt.runs = runs
        sources = set()
        for h in hosts:
            own = hist.get(h.name)
            if own:
                xs, src = own, SAME
            elif fleet:
                xs, src = fleet, FLEET
            elif assume is not None:
                xs, src = [float(assume)], ASSUMED
            else:
                xs, src = [], UNKNOWN
            sources.add(src)
            if xs:
                pt.mid[h.name] = _median(xs)
                pt.lo[h.name] = _q(xs, .1)
                pt.hi[h.name] = _q(xs, .9)
                pt.n += len(xs) if src != FLEET else 0
        if UNKNOWN in sources:
            pt.source = UNKNOWN
        elif ASSUMED in sources:
            pt.source = ASSUMED
        elif FLEET in sources:
            pt.source = FLEET if sources == {FLEET} else "same hosts and fleet"
            pt.n = len(fleet)
        else:
            pt.source = SAME
        out.append(pt)
    return out


class Sim(object):
    def __init__(self):
        self.wall = None            # seconds, None when unknown
        self.end = None             # datetime
        self.windows = []           # [(opens, closes)] each window used
        self.overruns = []          # [(part, seconds past its window)]
        self.parts = []             # [(part, worker, start dt, end dt)]
        self.intervals = []         # [(start s, end s, host)]


def fan_out(hosts, dur, jobs, gate, t0):
    """One part through the scheduler: the end time, in seconds, and each
    host's (start, end).  Gate.pick decides as in gated_fan_out; time
    moves to the next start the ramp allows or the next host's end,
    whichever comes first, and nothing sleeps."""
    waiting = list(range(len(hosts)))
    running = []                    # heap of (end, index)
    t = t0
    spans = []
    workers = max(1, min(jobs, len(hosts)))
    while waiting or running:
        if waiting and len(running) < workers:
            i, wait = gate.pick([hosts[j] for j in waiting], t)
            if i is not None:
                j = waiting.pop(i)
                gate.start(hosts[j], t)
                heapq.heappush(running, (t + dur[j], j))
                spans.append((t, t + dur[j], hosts[j]))
                continue
            nxt = running[0][0] if running else None
            if wait is not None and (nxt is None or t + wait < nxt):
                t += wait
                continue
        end, j = heapq.heappop(running)
        t = max(t, end)
        gate.end(hosts[j])
    return t, spans


def simulate(c, times, which, jobs, workers, caps, power, draw, spacing,
             windows, start):
    """The campaign's parts, in order, over `workers` workers, each with
    a Gate of its own (caps are per worker, as in a real run).  `which`:
    "mid", "lo" or "hi" -- the durations to use."""
    res = Sim()
    if any(pt.source == UNKNOWN for pt in times):
        return res
    free = [(0.0, w) for w in range(workers)]
    heapq.heapify(free)
    used = {}

    def at(s):
        return start + datetime.timedelta(seconds=s)
    last = 0.0
    for (part, hosts), pt in zip(c.parts, times):
        t, w = heapq.heappop(free)
        if windows:
            now = at(t)
            if not pacing.in_window(windows, now):
                nxt = pacing.next_open(windows, now)
                if nxt is None:
                    return Sim()
                t = (nxt - start).total_seconds()
            closes = pacing.window_closes(windows, at(t))
            span = (pacing.window_opened(windows, at(t)), closes)
            used.setdefault(span, True)
        d = getattr(pt, which)
        gate = pacing.Gate(caps, spacing, power, draw)
        end, spans = fan_out(hosts, [d[h.name] for h in hosts], jobs, gate,
                             t)
        res.intervals.extend(spans)
        res.parts.append((part, w, at(t), at(end)))
        if windows and at(end) > closes:
            res.overruns.append((part, (at(end) - closes).total_seconds()))
        last = max(last, end)
        heapq.heappush(free, (end, w))
    res.wall = last
    res.end = at(last)
    res.windows = sorted(used)
    return res


def peaks(intervals, caps, power, draw=None):
    """The most hosts running at once per capped attribute (its busiest
    value), and the most watts per power budget: [(what, value, peak,
    limit)]."""
    out = []
    events = []
    for s, e, h in intervals:
        events.append((s, 1, h))
        events.append((e, -1, h))
    # ends before starts at one instant: a host that ends as the next
    # starts did not overlap it
    events.sort(key=lambda x: (x[0], x[1]))
    for attr, n in caps:
        cur, best = {}, {}
        for _, d, h in events:
            v = dict(h.attrs or ()).get(attr, "")
            cur[v] = cur.get(v, 0) + d
            best[v] = max(best.get(v, 0), cur[v])
        if best:
            v = sorted(best, key=lambda k: (-best[k], k))[0]
            out.append(("hosts per %s" % attr, v, best[v], n))
    for attr, limit in power:
        cur, best = {}, {}
        for _, d, h in events:
            v = dict(h.attrs or ()).get(attr, "") if attr else ""
            cur[v] = cur.get(v, 0.0) + d * (pacing.host_watts(h, draw) or 0.0)
            best[v] = max(best.get(v, 0.0), cur[v])
        if best:
            v = sorted(best, key=lambda k: (-best[k], k))[0]
            out.append(("watts per %s" % attr if attr else "watts", v,
                        best[v], limit))
    return out
