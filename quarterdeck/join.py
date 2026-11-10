# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Martin J. Gallagher
"""qd join: a run's rows beside another system's telemetry, by host and time.

Every row of a run was measured on a host, over a window of time.  The
telemetry another system kept -- temperatures, power, link counters, from
Splunk, CloudVision, a gNMI or Prometheus collector, exported to a file --
says what that host was doing then.  This puts the two side by side: for
each row, each metric's samples from its host inside its window, reduced
to a few figures (mean, max, p99, delta ...).

The windows, the first that applies:

  --time COL[,COL]   the rows' own times: an instant (with --window +-N
                     around it), or a start and an end
  a fan-out          each host's own, from qd.hosts: when qd started it
                     (ts) and how long it took (duration_s), per pass.
                     ts is to the millisecond from 0.10.0; a run filed
                     before kept the whole second, and its windows run a
                     second longer to cover what was cut off
  qd do              the run's own start and finish, for every row

--window +-N widens each by N seconds either side: for telemetry sampled
every N seconds, and for clocks that disagree.  The windows are this
machine's clock and the samples the hosts' (or their collectors'), so the
latest `qd probe skew` in the store -- binnacle's skew, run on each host --
is read, and a host whose clock was further out than the window allows is
named.

A sample is in a window when its time is at or after the start and at or
before the end: both edges count.  Hosts are matched by name: the alias
map's first (NAME ALIAS ...), then the name exactly, then without case,
then without a :port (Prometheus's instance), then the short name --
node01 for node01.dc1.example.com -- when only one host of the run has
it.  A fan-out's addresses count as its hosts' names.

A row whose host has no sample in its window gets blanks, never zeros:
nothing was measured there.  An export bigger than memory is fine: it is
read a line at a time, and only the samples of the run's hosts inside its
windows are kept.
"""

import bisect
import fnmatch
import re

from .common import die, plural
from . import importers, stats
from .exporters import TARGET_COLS
from .importers import epoch_of, iso_ms
from .table import Table

AGGS = ("mean", "max", "min", "median", "p05", "p25", "p75", "p95", "p99",
        "stdev", "count", "first", "last", "delta", "rate")
DEFAULT_AGGS = ("mean", "max")
QUANTILES = {"median": .5, "p05": .05, "p25": .25, "p75": .75, "p95": .95,
             "p99": .99}
# the columns a join adds before the figures: the window each row was
# given, and what the telemetry called its host
WINDOW_COLUMNS = ("window_from", "window_to", "telemetry_host")

_IP_RE = re.compile(r"^\d{1,3}(\.\d{1,3}){3}$")
# `±` as typed, and as a Python 3.6 under LANG=C hands it over (its UTF-8
# bytes, surrogate-escaped)
_PLUS_MINUS = (u"±", u"\udcc2\udcb1", "+-", "+/-")


# ---------------------------------------------------------------------------
# What was asked for
# ---------------------------------------------------------------------------

def parse_window(text):
    """--window: `run` (each row's window as it is), or how far to widen
    it either side -- +-30, 30, 30s, 2m, 500ms, run+-30s.  -> seconds."""
    s = (text or "run").strip().replace(" ", "")
    if s.lower().startswith("run"):
        s = s[3:]
    for p in _PLUS_MINUS:
        if s.startswith(p):
            s = s[len(p):]
            break
    if not s:
        return 0.0
    m = re.match(r"^(\d+(?:\.\d*)?|\.\d+)(ms|s|m|min|h)?$", s.lower())
    if not m:
        die("--window wants run, or how far to widen each window either "
            "side: +-30, 30s, 2m, 500ms (not %r)" % text)
    return float(m.group(1)) * {"ms": 0.001, "s": 1.0, "m": 60.0,
                                "min": 60.0, "h": 3600.0}.get(m.group(2),
                                                              1.0)


def parse_aggs(text):
    """--agg: figures from each window's samples, comma-separated."""
    if not text:
        return list(DEFAULT_AGGS)
    out = []
    for a in (w.strip().lower() for w in text.split(",")):
        if not a:
            continue
        if a not in AGGS:
            die("unknown --agg %r (want %s)" % (a, ", ".join(AGGS)))
        if a not in out:
            out.append(a)
    return out or list(DEFAULT_AGGS)


def split_list(text):
    return [w.strip() for w in (text or "").split(",") if w.strip()]


def window_text(margin):
    if not margin:
        return "run"
    return "run +-%ss" % stats.fmt_num(margin)


# ---------------------------------------------------------------------------
# Figures
# ---------------------------------------------------------------------------

def reduce(agg, ts, vs):
    """One figure from a window's samples (times and values, in time
    order), or None when there is nothing to make it from."""
    n = len(vs)
    if not n:
        return None
    if agg == "count":
        return n
    if agg == "first":
        return vs[0]
    if agg == "last":
        return vs[-1]
    if agg in ("delta", "rate"):
        if n < 2:
            return None
        d = vs[-1] - vs[0]
        if agg == "delta":
            return d
        dt = ts[-1] - ts[0]
        return d / dt if dt > 0 else None
    if agg == "mean":
        return stats.mean(vs)
    if agg == "stdev":
        return stats.stdev(vs)
    s = sorted(vs)
    if agg == "min":
        return s[0]
    if agg == "max":
        return s[-1]
    return stats.quantile(s, QUANTILES[agg])


# ---------------------------------------------------------------------------
# Hosts: telemetry's names for them -> the run's
# ---------------------------------------------------------------------------

def strip_port(name):
    """node01:9100 -> node01, [fd00::1]:9100 -> fd00::1; a bare IPv6
    address is left as it is."""
    m = re.match(r"^\[([^\]]+)\](?::\d+)?$", name)
    if m:
        return m.group(1)
    if name.count(":") == 1:
        h, _, p = name.partition(":")
        if p.isdigit():
            return h
    return name


def short_name(name):
    """The first label of a DNS name, lower case; an address has none."""
    n = strip_port(name).lower()
    if _IP_RE.match(n) or ":" in n:
        return None
    return n.split(".", 1)[0] or None


class Matcher(object):
    """Telemetry's name for a host -> the run's name for it, or None."""

    def __init__(self, names, aliases=None, addrs=None):
        self.names = set(names)
        self.aliases = aliases or {}
        self.exact = dict((n, n) for n in names)
        for a, n in (addrs or {}).items():
            self.exact.setdefault(a, n)
            self.exact.setdefault(strip_port(a), n)
        self.lower, self.short = {}, {}
        for a, n in list(self.exact.items()):
            self._add(self.lower, a.lower(), n)
        for n in names:
            s = short_name(n)
            if s:
                self._add(self.short, s, n)
        self.cache = {}
        self.missed = {}         # telemetry names matched to no host: rows
        self.ambiguous = set()

    @staticmethod
    def _add(d, k, n):
        if d.get(k, n) != n:
            d[k] = None          # two hosts: no match by this name
        else:
            d[k] = n

    def match(self, name):
        if name in self.cache:
            n = self.cache[name]
            if n is None:
                self.missed[name] = self.missed.get(name, 0) + 1
            return n
        n = self._match(name)
        self.cache[name] = n
        if n is None:
            self.missed[name] = 1
        return n

    def _match(self, name):
        if name in self.aliases:
            a = self.aliases[name]
            return a if a in self.names else None
        for cand in (name, strip_port(name)):
            if cand in self.exact:
                return self.exact[cand]
            n = self.lower.get(cand.lower(), False)
            if n:
                return n
            if n is None:
                self.ambiguous.add(name)
                return None
        s = short_name(name)
        if s is not None and s in self.short:
            if self.short[s] is None:
                self.ambiguous.add(name)
            return self.short[s]
        return None


class Keeper(object):
    """What the join will use of an export, asked before a line's time is
    even read: a host of the run, inside the span of its windows."""

    def __init__(self, matcher, spans):
        self.matcher = matcher
        self.spans = spans

    def host(self, name):
        n = self.matcher.match(name)
        return n if n in self.spans else None

    def time(self, key, t):
        lo, hi = self.spans[key]
        return lo <= t <= hi


# ---------------------------------------------------------------------------
# Windows: when each row was measured
# ---------------------------------------------------------------------------

def host_column(table, host_col=None):
    if host_col:
        return table.index(host_col)
    for c in TARGET_COLS:
        i = importers._find(table.columns, c, loose=False)
        if i is not None:
            return i
    die("which column of %s names each row's host? None is called %s: "
        "--host-col COL" % (table.name, ", ".join(TARGET_COLS)))


def row_windows(table, entry, time_cols=None, margin=0.0, host_col=None):
    """(host per row, (start, end) or None per row, how the windows were
    found, notes, {address: host}) -- the start and end in UTC epoch
    seconds, widened by `margin` either side."""
    hi = host_column(table, host_col)
    hosts = [r[hi].strip() for r in table.rows]
    wins, notes, addrs = [], [], {}
    kind = (getattr(entry, "meta", None) or {}).get("kind")
    what = getattr(entry, "id", None) or table.source or table.name
    if time_cols:
        if len(time_cols) > 2:
            die("--time wants one column (an instant) or two (a start and "
                "an end), not %d" % len(time_cols))
        if len(time_cols) == 1 and not margin:
            die("--time %s is an instant, and a window of no width holds "
                "nothing: give how far either side to look, --window +-30s"
                % time_cols[0])
        idx = [table.index(c) for c in time_cols]
        bad = 0
        for r in table.rows:
            ts = [epoch_of(r[i]) for i in idx]
            if any(t is None for t in ts) or ts[-1] < ts[0]:
                wins.append(None)
                bad += any(r[i].strip() for i in idx)
                continue
            wins.append((ts[0] - margin, ts[-1] + margin))
        how = "the rows' own times: %s" % (
            "%s, +-%ss" % (table.columns[idx[0]], stats.fmt_num(margin))
            if len(idx) == 1 else "%s to %s" % (
                table.columns[idx[0]], table.columns[idx[1]]))
        if bad:
            notes.append("%s whose time could not be read (or ends before "
                         "it starts): no window, so blank"
                         % plural(bad, "row"))
        return hosts, wins, how, notes, addrs
    if kind == "run":
        per, whole = {}, 0
        for h in entry.store.host_rows(entry.id):
            try:
                t0 = float(h.get("ts") or "")
                dur = float(h.get("duration_s") or 0)
            except ValueError:
                continue
            # a whole second (before 0.10.0): the start was cut, not rounded
            cut = "." not in (h.get("ts") or "")
            whole += cut
            per[(h.get("host", ""), h.get("pass") or "1")] = (
                t0 - margin, t0 + dur + (1.0 if cut else 0.0) + margin)
            if h.get("addr"):
                addrs[h["addr"]] = h.get("host", "")
        pi = importers._find(table.columns, "pass", loose=False)
        for r, h in zip(table.rows, hosts):
            p = (r[pi].strip() if pi is not None else "") or "1"
            wins.append(per.get((h, p)))
        how = "each host's own, from qd.hosts: when qd started it and how " \
              "long it took"
        if whole:
            notes.append("%s filed before 0.10.0 keep their start to the "
                         "second: those windows run a second longer, to "
                         "cover what was cut off"
                         % plural(whole, "host window"))
        return hosts, wins, how, notes, addrs
    if kind == "do":
        t0 = epoch_of(entry.meta.get("created", ""))
        t1 = epoch_of(entry.meta.get("finished", ""))
        if t0 is None or t1 is None:
            die("%s does not say when it ran: --time COL gives the rows' "
                "own times" % what)
        # both kept to the second, the start cut and the finish too
        w = (t0 - margin, t1 + 1.0 + margin)
        return hosts, [w] * len(hosts), \
            "the run's own start and finish, for every row", notes, addrs
    die("%s says nothing of when its rows were measured -- %s.  Give "
        "--time COL, a column of their own times (or two, a start and an "
        "end)" % (what, "an import keeps when it was imported, not when it "
                  "was measured" if kind == "import" else
                  "only a fan-out or a `qd do` keeps that"))


# ---------------------------------------------------------------------------
# Clocks: binnacle's skew, as `qd probe skew` filed it
# ---------------------------------------------------------------------------

_SKEW_RE = re.compile(
    r"^\s*(?:(\d+(?:\.\d+)?)(us|ms|s)|(\d+)(d|h|m)\s+(\d+)(h|m|s))\s+"
    r"(fast|slow)\b")
_UNIT = {"us": 1e-6, "ms": 1e-3, "s": 1.0, "m": 60.0, "h": 3600.0,
         "d": 86400.0}


def parse_offset(detail):
    """skew's CLOCK_OFFSET finding -- `2.5s fast the 1 source that
    answered`, `3m 05s slow ...` -- as seconds the host's clock is ahead
    (negative: behind), or None."""
    m = _SKEW_RE.match(detail or "")
    if not m:
        return None
    if m.group(1):
        v = float(m.group(1)) * _UNIT[m.group(2)]
    else:
        v = int(m.group(3)) * _UNIT[m.group(4)] + \
            int(m.group(5)) * _UNIT[m.group(6)]
    return v if m.group(7) == "fast" else -v


def skew_offsets(store, ref=None):
    """(the skew run, {host: seconds its clock was ahead}, the hosts it
    checked) from the latest `qd probe skew` in the store, or the run
    `ref` names; None when there is none.  skew reports an offset only
    past its warning (a second, by default): a host it checked and did
    not report was closer than that."""
    if ref:
        e = store.resolve(ref)
    else:
        e = None
        for x in reversed(store.entries()):
            if x.meta.get("name") == "skew" and \
                    x.meta.get("tool") == "probe":
                e = x
                break
        if e is None:
            return None
    t = e.load()
    hi = importers._find(t.columns, "host", loose=False)
    ri = importers._find(t.columns, "rule_id", loose=False)
    di = importers._find(t.columns, "detail", loose=False)
    if hi is None or ri is None:
        if ref:
            die("%s is not binnacle skew's findings (no host and rule_id "
                "columns): `qd probe skew` files them" % e.id)
        return None
    offsets, checked = {}, set()
    for r in t.rows:
        h, rule = r[hi].strip(), r[ri].strip()
        if not h or not rule:
            continue
        checked.add(h)
        if rule == "CLOCK_OFFSET" and di is not None:
            v = parse_offset(r[di])
            if v is not None:
                offsets[h] = v
    return e, offsets, checked


def skew_notes(found, hosts, margin, shown):
    """What skew says about the joined hosts' clocks, against how far the
    window reaches either side.  found: skew_offsets' answer, None when
    the store has no skew run, False when none was to be read."""
    if found is False:
        return []
    if found is None:
        return ["clocks: nothing in this store says how far each host's "
                "clock is from this machine's (`qd probe skew` measures "
                "it, with binnacle's skew); the windows are this "
                "machine's time, the samples the hosts'"]
    e, offsets, checked = found
    out = []
    late = sorted((h for h in set(hosts) if h in offsets
                   and abs(offsets[h]) > margin),
                  key=lambda h: -abs(offsets[h]))
    if late:
        def said(h):
            v = offsets[h]
            return "%s %ss %s" % (h, stats.fmt_num(abs(v)),
                                  "fast" if v > 0 else "slow")
        need = max(abs(offsets[h]) for h in late)
        out.append("clocks: %s, when %s checked (%s) -- further out than "
                   "the window's +-%ss, so their samples can sit outside "
                   "their windows: --window +-%ss covers it, or correct "
                   "the clocks" % (", ".join(said(h) for h in late[:6]) + (
                       " ..." if len(late) > 6 else ""), shown(e),
                       e.meta.get("created", "?"), stats.fmt_num(margin),
                       stats.fmt_num(int(need) + 1)))
    unchecked = sorted(set(h for h in hosts if h) - checked)
    if unchecked:
        out.append("clocks: %s checked no clock of %s" % (
            shown(e), ", ".join(unchecked[:6]) +
            (" ..." if len(unchecked) > 6 else "")))
    return out


# ---------------------------------------------------------------------------
# The join
# ---------------------------------------------------------------------------

class Joined(object):
    """A join's table, and what it found."""

    def __init__(self, table, notes, metrics, rows_with, rows_without,
                 kept, read, how):
        self.table = table
        self.notes = notes
        self.metrics = metrics
        self.rows_with = rows_with          # rows with samples in window
        self.rows_without = rows_without    # [host] of rows with none
        self.kept = kept                    # samples inside the windows
        self.read = read                    # export rows read
        self.how = how


def wanted(metric, patterns):
    return not patterns or any(fnmatch.fnmatchcase(metric, p) or
                               metric == p for p in patterns)


def join(table, entry, source, cmap=None, aliases=None, margin=0.0,
         aggs=None, metrics=None, time_cols=None, host_col=None,
         skew=None, shown=None):
    """`table`'s rows, each with its window and, per metric, `aggs` of its
    host's samples in that window.  `source`: an importers
    TelemetrySource.  `skew`: what skew_offsets found (None: nothing in
    the store; False: not looked for).  `shown(entry)` names a run in the
    notes."""
    aggs = list(aggs or DEFAULT_AGGS)
    shown = shown or (lambda e: e.id)
    hosts, wins, how, notes, addrs = row_windows(table, entry, time_cols,
                                                 margin, host_col)
    names = []
    for h in hosts:
        if h and h not in names:
            names.append(h)
    spans = {}
    for h, w in zip(hosts, wins):
        if h and w is not None:
            lo, hi = spans.get(h, w)
            spans[h] = (min(lo, w[0]), max(hi, w[1]))
    matcher = Matcher(names, aliases, addrs)
    shape = importers.Shape(source.columns, cmap, source.origin)
    tally = {}
    data, order, unwanted = {}, [], set()
    for t, tel, metric, v, _ in importers.samples(
            source, shape, cmap, None, Keeper(matcher, spans), tally):
        if not wanted(metric, metrics):
            unwanted.add(metric)
            continue
        key = (matcher.match(tel), metric)
        if key not in data:
            data[key] = []
            if metric not in order:
                order.append(metric)
        data[key].append((t, v, tel))
    times = {}
    for key, lst in data.items():
        lst.sort(key=lambda s: s[0])
        times[key] = [s[0] for s in lst]
    # the figures' columns: METRIC_AGG, kept apart from the run's own
    taken = set(table.columns) | set(WINDOW_COLUMNS)
    cols = []
    for m in order:
        for a in aggs:
            c = "%s_%s" % (re.sub(r"\s+", "_", m), a)
            while c in taken:
                c = "tel_" + c
            taken.add(c)
            cols.append((m, a, c))
    rows, with_, without, kept = [], 0, [], 0
    for r, h, w in zip(table.rows, hosts, wins):
        if w is None or not h:
            rows.append(list(r) + [""] * (len(WINDOW_COLUMNS) + len(cols)))
            without.append(h or "(no host)")
            continue
        lo, hi = w
        tel_names, cells, any_ = set(), [], False
        per = {}
        for m in order:
            key = (h, m)
            lst = data.get(key)
            if not lst:
                per[m] = ([], [])
                continue
            ts = times[key]
            a, b = bisect.bisect_left(ts, lo), bisect.bisect_right(ts, hi)
            part = lst[a:b]
            if part:
                any_ = True
                kept += len(part)
                tel_names.update(s[2] for s in part)
            per[m] = ([s[0] for s in part], [s[1] for s in part])
        for m, a, _ in cols:
            ts, vs = per[m]
            cells.append(stats.cell(reduce(a, ts, vs)))
        if any_:
            with_ += 1
        else:
            without.append(h)
        rows.append(list(r) + [iso_ms(lo), iso_ms(hi),
                               ",".join(sorted(tel_names))] + cells)
    out = Table(list(table.columns) + list(WINDOW_COLUMNS) +
                [c for _, _, c in cols], rows, "join", table.source)
    # -- what it found, in words ---------------------------------------------
    lines = ["windows: %s%s" % (how, (", widened %ss either side"
                                      % stats.fmt_num(margin))
                                if margin and "+-" not in how else "")]
    lines.extend(notes)
    lines.append("telemetry: %s kept for the run's hosts and windows, of "
                 "%s read from %s as %s" % (
                     plural(sum(len(x) for x in data.values()), "sample"),
                     plural(tally.get("rows", 0), "row"), source.origin,
                     shape.describe()))
    if metrics:
        none = [p for p in metrics if not any(
            fnmatch.fnmatchcase(m, p) or m == p
            for m in order + sorted(unwanted))]
        if none:
            lines.append("--metrics: nothing in the windows is called %s"
                         % ", ".join(none))
    if not order:
        lines.append("no samples at all for this run's hosts in its "
                     "windows -- %s" % (
                         "is the host named differently there? (an alias "
                         "file, --alias, says which is which)"
                         if matcher.missed else
                         "were they exported for when it ran? (and in "
                         "which zone: a column map's tz)"))
    silent = [h for h in names if h in spans and
              not any((h, m) in data for m in order)]
    if silent and order:
        lines.append("no samples at all for %s" % ", ".join(silent[:8]) + (
            " ..." if len(silent) > 8 else ""))
    if matcher.missed and (silent or not order):
        top = sorted(matcher.missed.items(), key=lambda kv: (-kv[1], kv[0]))
        lines.append("names in the telemetry that matched no host of the "
                     "run: %s -- an alias file (--alias) maps them" %
                     ", ".join("%s (%d)" % kv for kv in top[:6]) +
                     (" ..." if len(top) > 6 else ""))
    if matcher.ambiguous:
        lines.append("names that fit more than one host, so match none: %s"
                     % ", ".join(sorted(matcher.ambiguous)[:6]))
    if without:
        lines.append("%s with nothing in the window (blank, not 0): %s" % (
            plural(len(without), "row"), ", ".join(sorted(set(without))[:8])
            + (" ..." if len(set(without)) > 8 else "")))
    lines.extend(skew_notes(skew, [h for h in names if h in spans], margin,
                            shown))
    lines.extend(source.notes)
    lines.extend(importers.tally_notes(tally, source))
    out.notes = lines
    return Joined(out, lines, order, with_, without, kept,
                  tally.get("rows", 0), how)
