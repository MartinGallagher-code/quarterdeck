# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Martin J. Gallagher
"""Coverage: which hosts each named test has run on, and which still owe it.

    qd coverage facts iperf burnin -s hosts.txt --owed owed/

A test here is a run's name -- `--name`, a probe's name, a campaign's --
and a host's state in it is its latest answer in any run of that name:
ok, failed (a non-zero exit, a timeout, a push that failed), unreachable,
or never.  Everything is read from qd.hosts, the table every run on the
fleet files a row per host and pass into; no answer is read.

The rules (docs/larger-jobs.md: "Which hosts have had it: qd coverage"):

  - latest is by when the run started (qd.runs `created`, then the order
    the store filed them in), never by id;
  - within a run a host's last pass and its last try count, as --rerun
    reads them;
  - a not-run row (a run stopped before it reached the host) is not an
    answer: the host keeps whatever it had before, or never;
  - with --since, a run that started before it is not read, so an old ok
    is never.
"""

import calendar
import re
import time

from .common import die
from .store import now_iso

OK, FAILED, UNREACHABLE, NEVER = "ok", "failed", "unreachable", "never"
COUNTED = (OK, FAILED, UNREACHABLE, NEVER)
NOT_RUN = "not-run"

# With no NAME, the newest this many names; --all for every one.
DEFAULT_NAMES = 8

DATE_RE = re.compile(r"^(\d{4})-(\d{2})-(\d{2})"
                     r"(?:[T ](\d{2}):(\d{2})(?::(\d{2}))?Z?)?$")


def counted_as(status):
    """The column a host's status is counted in."""
    if status == OK:
        return OK
    if status == UNREACHABLE:
        return UNREACHABLE
    return FAILED       # failed, timeout, push-failed, anything newer


def epoch(created):
    """qd.runs' `created` (2026-11-18T10:15:00Z) -> seconds, or None."""
    try:
        return calendar.timegm(time.strptime(created or "",
                                             "%Y-%m-%dT%H:%M:%SZ"))
    except ValueError:
        return None


def start_key(e):
    """A run's place in time: when it started, then the order filed."""
    t = epoch(e.meta.get("created"))
    return (t if t is not None else 0, int(e.row.get("_rowid") or 0))


def fleet_runs(st):
    """The runs that file a row per host: qd run, qd probe on the hosts,
    a campaign's parts, a design's points."""
    return [e for e in st.entries() if e.meta.get("kind") == "run"]


def names_newest_first(runs):
    """Every run name, the one run most recently first."""
    last = {}
    for e in runs:
        if e.name:
            k = start_key(e)
            if e.name not in last or k > last[e.name]:
                last[e.name] = k
    return sorted(last, key=lambda n: last[n], reverse=True)


def parse_since(st, text, resolve):
    """--since: a date (YYYY-MM-DD, UTC midnight; or YYYY-MM-DDTHH:MM[:SS],
    UTC) or a run reference.  -> (key, what it is, shown).  A run's key is
    its own: that run counts, the ones that started before it do not."""
    m = DATE_RE.match(text.strip())
    if m:
        y, mo, d, hh, mm, ss = [int(g) if g else 0 for g in m.groups()]
        try:
            t = calendar.timegm((y, mo, d, hh, mm, ss, 0, 0, 0))
            time.strptime("%04d-%02d-%02d" % (y, mo, d), "%Y-%m-%d")
        except (ValueError, OverflowError):
            die("--since %s is not a date (YYYY-MM-DD, or "
                "YYYY-MM-DDTHH:MM, UTC)" % text)
        if not (0 <= hh < 24 and 0 <= mm < 60 and 0 <= ss < 62):
            die("--since %s is not a time of day" % text)
        return (t, -1), now_iso(t)
    e = resolve(text)
    if getattr(e, "meta", {}).get("kind") != "run":
        die("--since %s: give a date (YYYY-MM-DD) or a run on the fleet; "
            "%s is neither" % (text, getattr(e, "id", text)))
    return start_key(e), "%s (%s)" % (e.id, e.meta.get("created") or "?")


def final_rows(rows):
    """{host: its last answer in one run}: the last pass, then the last
    try, a not-run row passed over."""
    out = {}
    for h in rows:
        if h.get("status") == NOT_RUN or not h.get("host"):
            continue
        k = (_int(h.get("pass")), _int(h.get("attempt")))
        name = h["host"]
        if name not in out or k >= out[name][0]:
            out[name] = (k, h)
    return dict((n, h) for n, (_, h) in out.items())


def _int(v):
    try:
        return int(v or 1)
    except ValueError:
        return 1


def latest(st, runs, names, since=None):
    """{name: {host: cell}}, a cell the host's latest answer in a run of
    that name: status as filed, counted (ok, failed, unreachable), the run,
    and when (the host's own start, else the run's).  A run before `since`
    is not read."""
    want = set(names)
    chosen = sorted([e for e in runs if e.name in want and
                     (since is None or start_key(e) >= since)],
                    key=start_key)
    grid = dict((n, {}) for n in names)
    for e in chosen:
        for host, h in final_rows(st.host_rows(e.id)).items():
            when = ""
            try:
                when = now_iso(float(h.get("ts") or ""))
            except ValueError:
                when = e.meta.get("created") or ""
            status = h.get("status") or ""
            grid[e.name][host] = {"status": status,
                                  "counted": counted_as(status),
                                  "run": e.id, "when": when}
    return grid


def owed(cell):
    return cell is None or cell["counted"] != OK
