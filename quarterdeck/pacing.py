# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Martin J. Gallagher
"""Pacing a campaign: caps per power domain, a ramp, maintenance windows.

    --max-per pdu=4     no more than 4 hosts sharing a pdu value at once
    --ramp 6/min        no more than 6 host starts a minute, evenly spaced
    --window "Mon-Fri 18:00-06:00"   start parts only inside these hours

A burn-in that loads every node on one PDU at once can trip its breaker,
so the caps are about safety, not speed.  They hold within one worker
(one `qd campaign run`): two workers on one campaign each keep their own
count, and muster gives them different parts.

The scheduler takes its clock as an argument, so it is tested without
sleeping (tests/test_pacing.sh drives it with a fake one).
"""

import datetime
import re
import threading
import time

from .common import die

DAYS = ("mon", "tue", "wed", "thu", "fri", "sat", "sun")


# ---------------------------------------------------------------------------
# Caps and ramp
# ---------------------------------------------------------------------------

def parse_caps(specs):
    """[(attr, n)] from ["pdu=4", "rack=8"] (or "pdu=4,rack=8")."""
    out = []
    for spec in specs or []:
        for part in spec.split(","):
            part = part.strip()
            if not part:
                continue
            k, sep, v = part.partition("=")
            if not sep or not re.match(r"^[A-Za-z_][\w.-]*$", k.strip()) \
                    or not v.strip().isdigit() or int(v) < 1:
                die("--max-per wants ATTR=N with N 1 or more, e.g. "
                    "pdu=4; got %r" % part)
            out.append((k.strip(), int(v)))
    names = [k for k, _ in out]
    if len(set(names)) != len(names):
        die("--max-per names %s twice" % ", ".join(
            sorted(set(k for k in names if names.count(k) > 1))))
    return out


def parse_ramp(text):
    """Seconds between host starts from "6/min", "1/s", "120/h" or "6"
    (a minute's worth); None for none."""
    if not text:
        return None
    m = re.match(r"^\s*(\d+(?:\.\d+)?)\s*(?:/\s*(s|sec|m|min|h|hour))?\s*$",
                 text)
    if not m or float(m.group(1)) <= 0:
        die("--ramp wants a rate such as 6/min, 1/s or 120/h; got %r"
            % text)
    per = {"s": 1, "sec": 1, "m": 60, "min": 60, "h": 3600,
           "hour": 3600}[m.group(2) or "min"]
    return per / float(m.group(1))


def caps_text(caps):
    return ",".join("%s=%d" % c for c in caps)


class Gate(object):
    """Which waiting host may start now.  `pick` is pure: given what is
    running and the time, it says which host goes next, or how long to
    wait -- the fan-out supplies the clock and does the waiting."""

    def __init__(self, caps=(), spacing=None):
        self.caps = list(caps)
        self.spacing = spacing
        self.running = {}           # (attr, value) -> count
        self.last_start = None

    def _keys(self, host):
        attrs = dict(getattr(host, "attrs", ()) or ())
        # a host without the attribute shares one count with the others
        # that lack it: unlabelled is not unlimited
        return [(a, attrs.get(a, "")) for a, _ in self.caps]

    def fits(self, host):
        for (a, n), key in zip(self.caps, self._keys(host)):
            if self.running.get(key, 0) >= n:
                return False
        return True

    def pick(self, waiting, now):
        """(index into waiting, 0) for the host to start, or (None, s):
        wait s seconds (None: until a running host ends)."""
        if self.spacing and self.last_start is not None:
            due = self.last_start + self.spacing
            if now < due:
                return None, due - now
        for i, h in enumerate(waiting):
            if self.fits(h):
                return i, 0
        return None, None

    def start(self, host, now):
        for key in self._keys(host):
            self.running[key] = self.running.get(key, 0) + 1
        self.last_start = now

    def end(self, host):
        for key in self._keys(host):
            self.running[key] -= 1

    def active(self):
        return bool(self.caps or self.spacing)


def gated_fan_out(hosts, fn, jobs, gate, clock=time.monotonic,
                  on_start=None, label="", progress=None):
    """fn(host) for every host, at most `jobs` at once and as `gate`
    allows, results in host-list order.  `clock` is the time source the
    gate is asked with; waiting is done on a condition variable, so a
    host that ends wakes the scheduler at once."""
    from concurrent.futures import ThreadPoolExecutor
    n = len(hosts)
    results = [None] * n
    waiting = list(range(n))
    cond = threading.Condition()
    state = {"inflight": 0, "error": None}
    workers = max(1, min(jobs, n))

    done = [0]

    def run(i):
        try:
            results[i] = fn(hosts[i])
        except BaseException as exc:     # noqa: kept for the caller
            state["error"] = exc
        finally:
            with cond:
                gate.end(hosts[i])
                state["inflight"] -= 1
                done[0] += 1
                if progress:
                    progress("%s%d/%d done" % (label, done[0], n))
                cond.notify_all()

    with ThreadPoolExecutor(max_workers=workers) as pool:
        with cond:
            while waiting or state["inflight"]:
                if state["error"] is not None:
                    break
                if waiting and state["inflight"] < workers:
                    i, wait = gate.pick([hosts[j] for j in waiting], clock())
                    if i is not None:
                        j = waiting.pop(i)
                        gate.start(hosts[j], clock())
                        state["inflight"] += 1
                        if on_start:
                            on_start(hosts[j])
                        pool.submit(run, j)
                        continue
                    cond.wait(wait if wait is not None else 1.0)
                else:
                    cond.wait(1.0)
            while state["inflight"]:
                cond.wait(1.0)
    if state["error"] is not None:
        raise state["error"]
    return results


# ---------------------------------------------------------------------------
# Maintenance windows
# ---------------------------------------------------------------------------

class Window(object):
    def __init__(self, days, start, minutes, text):
        self.days = days            # set of weekday numbers, Monday 0
        self.start = start          # minutes after midnight
        self.minutes = minutes      # how long it is open
        self.text = text

    def spans(self, t):
        """[(open, close)] datetimes of this window that could hold t."""
        out = []
        for back in (0, 1, 2):
            d = (t - datetime.timedelta(days=back)).date()
            if d.weekday() in self.days:
                o = datetime.datetime(d.year, d.month, d.day) + \
                    datetime.timedelta(minutes=self.start)
                out.append((o, o + datetime.timedelta(minutes=self.minutes)))
        return out

    def opens_after(self, t):
        for ahead in range(0, 9):
            d = (t + datetime.timedelta(days=ahead)).date()
            if d.weekday() in self.days:
                o = datetime.datetime(d.year, d.month, d.day) + \
                    datetime.timedelta(minutes=self.start)
                if o > t:
                    return o
        return None


def _hhmm(text, whole):
    m = re.match(r"^(\d{1,2}):(\d\d)$", text)
    if not m or int(m.group(1)) > 24 or int(m.group(2)) > 59 or (
            int(m.group(1)) == 24 and int(m.group(2))):
        die("--window: %r is not a time (HH:MM) in %r" % (text, whole))
    return int(m.group(1)) * 60 + int(m.group(2))


FULL = ("monday", "tuesday", "wednesday", "thursday", "friday",
        "saturday", "sunday")


def _day(d, whole):
    d = d.strip().lower()
    for i, (short, full) in enumerate(zip(DAYS, FULL)):
        if d in (short, full):
            return i
    die("--window: %r is not a day (Mon..Sun) in %r" % (d, whole))


def _days(text, whole):
    out = set()
    for part in text.split(","):
        a, sep, b = part.partition("-")
        i = _day(a, whole)
        j = _day(b, whole) if sep else i
        while True:
            out.add(i)
            if i == j:
                break
            i = (i + 1) % 7
    return out


def parse_windows(specs):
    """Windows from ["Mon-Fri 18:00-06:00", "Sat,Sun 00:00-24:00",
    "22:00-04:00"]; several in one string are split on ';'."""
    out = []
    for spec in specs or []:
        for one in spec.split(";"):
            one = one.strip()
            if not one:
                continue
            words = one.split()
            if len(words) == 1:
                days, span = set(range(7)), words[0]
            elif len(words) == 2:
                days, span = _days(words[0], one), words[1]
            else:
                die("--window wants [DAYS] HH:MM-HH:MM, e.g. "
                    "\"Mon-Fri 18:00-06:00\"; got %r" % one)
            a, sep, b = span.partition("-")
            if not sep:
                die("--window: %r is not a span HH:MM-HH:MM" % span)
            s, e = _hhmm(a, one), _hhmm(b, one)
            minutes = (e - s) % 1440 or 1440
            out.append(Window(days, s, minutes, one))
    return out


def in_window(windows, t):
    if not windows:
        return True
    return any(o <= t < c for w in windows for o, c in w.spans(t))


def next_open(windows, t):
    """When the next window opens after t (None: no windows)."""
    times = [x for x in (w.opens_after(t) for w in windows) if x]
    return min(times) if times else None


def window_closes(windows, t):
    """When the window holding t closes (the latest, where they overlap)."""
    ends = [c for w in windows for o, c in w.spans(t) if o <= t < c]
    return max(ends) if ends else None


def windows_text(windows):
    return "; ".join(w.text for w in windows)
