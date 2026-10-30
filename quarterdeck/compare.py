# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Martin J. Gallagher
"""Comparing runs: any number of them, side by side.

`qd diff` says what changed between two tables.  This lines up N runs from
the store -- the last N of one name, a campaign's parts, a design's points,
or any list of refs -- and says, for each run, how it went (how many hosts
answered) and where a column sat (median, spread, extremes), and how far
that moved from the baseline: the first run, or the one named.  Then, key
by key (host, or host and record), every run's value side by side, flagged
where it drifted past the threshold from the baseline or its status went
from ok to anything else.

The drift rule is a median per key, compared run against baseline, past a
percentage (5 by default): one noisy sample is not a change, and a host
that went from ok to failed is a change whatever the numbers say.  Blank
is not measured, never zero, here as everywhere: a key a run did not
measure has no value and no delta, and is said to be missing.
"""

from .common import die
from .diff import VOLATILE, auto_key
from .stats import AGGS, summary
from .table import Table, column_numbers

FLIP_OK = ("ok", "pass", "passed", "")
STAT_COLS = ("n", "median", "mean", "stdev", "min", "p95", "max")


class Compared(object):
    def __init__(self):
        self.runs = []          # [{label, entry, table, stats, delta_pct, ...}]
        self.column = None
        self.unit = ""
        self.key = []
        self.keys = []          # [(key tuple, [value or None per run], flags)]
        self.status = {}        # key -> [status per run]
        self.notes = []
        self.baseline = 0
        self.columns = []       # with no column: [(col, [median per run])]


def labels(n):
    return ["R%d" % (i + 1) for i in range(n)]


def settings(tables):
    """What the runs were, not what they measured: a design's factors and
    the hosts' attributes, which differ between runs by intent."""
    out = set()
    for t in tables:
        e = getattr(t, "entry", None)
        if e is not None and hasattr(e, "setting_columns"):
            out |= e.setting_columns()
    return out


def common_numeric(tables):
    """The numeric data columns every table has, in the first one's order,
    bookkeeping and the runs' settings left out."""
    from .stats import BOOKKEEPING
    first = tables[0]
    skip = settings(tables)
    out = []
    for c in first.columns:
        if c in VOLATILE or c in BOOKKEEPING or c in ("status", "error") or \
                c in skip:
            continue
        if all(t.has(c) and t.kind(c) in ("num", "mixed") for t in tables):
            out.append(c)
    return out


def _key_for(tables, key):
    if key:
        for t in tables:
            for k in key:
                t.index(k)
        return key
    k = auto_key(tables[0], tables[-1])
    return [c for c in k if all(t.has(c) for t in tables)] or k


def compare(tables, column=None, key=None, drift=5.0, agg="median",
            baseline=0):
    """tables: one per run, in time order (each with .entry where it came
    from the store).  Returns a Compared."""
    if len(tables) < 2:
        die("compare wants two runs or more (found %d)" % len(tables))
    if agg in ("distinct", "first", "last", "top", "worst", "auto"):
        die("compare reduces a key's repeated rows to one number: --agg "
            "median, mean, min, max, sum, stdev, range, p05..p99 or count "
            "(not %s)" % agg)
    if agg not in AGGS:
        die("unknown --agg %r (want %s)" % (agg, ", ".join(sorted(AGGS))))
    if not 0 <= baseline < len(tables):
        die("the baseline is not one of the runs compared")
    res = Compared()
    res.baseline = baseline
    labs = labels(len(tables))
    for lab, t in zip(labs, tables):
        e = getattr(t, "entry", None)
        h = (e.meta.get("hosts") or {}) if e is not None else {}
        res.runs.append({"label": lab, "table": t, "entry": e,
                         "id": e.id if e is not None else t.source or t.name,
                         "created": e.meta.get("created", "") if e is not None
                         else "", "hosts": h, "rows": len(t.rows)})
    if column is None:
        cols = common_numeric(tables)
        for c in cols:
            meds = []
            for t in tables:
                s = summary(t.numbers(c))
                meds.append(s.get("median"))
            res.columns.append((c, meds))
        if not cols:
            res.notes.append("no numeric column all the runs share: name "
                             "one, or compare their statuses")
    else:
        for t in tables:
            t.index(column)
        res.column = tables[0].colname(column)
        res.unit = tables[0].unit(res.column)
        units = set(t.unit(t.colname(column)) for t in tables)
        if len(units) > 1:
            res.notes.append("the runs report %s in different units (%s): "
                             "compare with care" % (res.column,
                                                    ", ".join(sorted(units))))
        for r, t in zip(res.runs, tables):
            r["stats"] = summary(t.numbers(column))
        base = res.runs[baseline]["stats"].get("median")
        for r in res.runs:
            m = r["stats"].get("median")
            r["delta_pct"] = pct(base, m)
    res.key = _key_for(tables, key)
    _per_key(res, tables, column, agg, drift)
    return res


def pick(st, refs=(), group=None, last=None):
    """The runs to compare, oldest first: those named; a group's (a
    campaign's parts or a design's points); or the last N runs like the
    one named (5 by default)."""
    if group:
        es = [e for e in st.entries() if e.meta.get("group") == group]
        if not es:
            die("no runs in group %r (a campaign or a design's name)"
                % group)
        return es[-last:] if last else es
    refs = list(refs) or ["latest"]
    if len(refs) == 1 or last:
        e = st.resolve(refs[-1])
        if not hasattr(e, "captures"):
            die("%s is a whole dataset, not a run: compare runs of it "
                "(qd compare NAME --last N)" % e.id)
        like = [x for x in st.entries() if (x.meta.get("kind"),
                x.meta.get("command"), x.meta.get("name")) ==
                (e.meta.get("kind"), e.meta.get("command"),
                 e.meta.get("name"))]
        ids = [x.id for x in like]
        es = like[:ids.index(e.id) + 1][-(last or 5):]
        if len(es) < 2:
            die("%s is the only run of %r: compare needs another (or name "
                "the runs to compare)" % (e.id, e.meta.get("name") or
                                          e.meta.get("command")))
        return es
    return [st.resolve(r) for r in refs]


def with_baseline(st, entries, ref):
    """(entries, the baseline's index): the run named, where it is among
    them, or put in front when it is not."""
    if not ref:
        return entries, 0
    b = st.resolve(ref)
    ids = [e.id for e in entries]
    if b.id in ids:
        return entries, ids.index(b.id)
    return [b] + entries, 0


def last_change(res, vals):
    """The latest run against the baseline (the first run when the
    baseline is the latest), in percent."""
    last = vals[-1] if res.baseline != len(vals) - 1 else vals[0]
    return pct(vals[res.baseline], last)


def column_changes(res):
    """With no column: [(column, [median per run], change)]."""
    return [(c, meds, last_change(res, meds)) for c, meds in res.columns]


def pct(a, b):
    if a is None or b is None:
        return None
    if a == 0:
        return None if b == 0 else float("inf") if b > 0 else float("-inf")
    return (b - a) / abs(a) * 100.0


def _per_key(res, tables, column, agg, drift):
    order, vals, stat = [], {}, {}
    for i, t in enumerate(tables):
        ki = [t.index(k) for k in res.key]
        ci = t.index(column) if column else None
        si = t.index("status") if t.has("status") else None
        nums = column_numbers([r[ci] for r in t.rows])[0] if ci is not None \
            else None
        groups = {}
        for n, r in enumerate(t.rows):
            k = tuple(r[j] for j in ki)
            if k not in vals:
                vals[k] = [None] * len(tables)
                stat[k] = [None] * len(tables)
                order.append(k)
            if si is not None:
                s = r[si]
                # the worst status a key reached in this run
                if stat[k][i] is None or (stat[k][i] in FLIP_OK and
                                          s not in FLIP_OK):
                    stat[k][i] = s
            if nums is not None and nums[n] is not None:
                groups.setdefault(k, []).append(nums[n])
        for k, xs in groups.items():
            if len(xs) == 1:
                vals[k][i] = xs[0]
            else:
                v = AGGS[agg]([repr(x) for x in xs])
                vals[k][i] = v if isinstance(v, float) else (
                    float(v) if v not in (None, "") else None)
    b = res.baseline
    # runs over different hosts (a campaign's parts, a design's blocks)
    # share no key: there is nothing to match, so they compare as wholes
    shared = column is not None and any(
        vals[k][b] is not None and any(v is not None for i, v in
                                       enumerate(vals[k]) if i != b)
        for k in order)
    if column is not None and not shared:
        res.notes.append("the runs share no %s: compared as wholes, not key "
                         "by key" % ",".join(res.key))
    for k in order:
        flags = []
        row = vals[k]
        if column is not None and shared:
            if row[b] is None:
                flags.append("no baseline")
            for i, v in enumerate(row):
                if i == b:
                    continue
                d = pct(row[b], v)
                if v is None and row[b] is not None:
                    flags.append("%s missing" % res.runs[i]["label"])
                elif d is not None and abs(d) > drift:
                    flags.append("%s drift %+.1f%%" % (res.runs[i]["label"], d)
                                 if d not in (float("inf"), float("-inf"))
                                 else "%s from 0" % res.runs[i]["label"])
        st = stat[k]
        if any(s is not None for s in st):
            bs = st[b] if st[b] is not None else ""
            for i, s in enumerate(st):
                if i != b and s is not None and s != bs and \
                        not (s in FLIP_OK and bs in FLIP_OK):
                    flags.append("%s %s->%s" % (res.runs[i]["label"],
                                                bs or "absent", s))
        res.keys.append((k, row, flags))
        res.status[k] = st
    res.drift = drift


def wide_table(res):
    """The per-key comparison as a table: the key, each run's value, the
    last run against the baseline, and the flags."""
    labs = [r["label"] for r in res.runs]
    cols = list(res.key) + labs + ["change_pct", "flags"]
    rows = []
    for k, vals, flags in res.keys:
        d = last_change(res, vals)
        rows.append(list(k) + [num(v) for v in vals] +
                    [("%.1f" % d) if d not in (None, float("inf"),
                                               float("-inf")) else "",
                     "; ".join(flags)])
    return Table(cols, rows, "compare")


def summary_table(res):
    """One row per run: what it was and, with a column, where it sat."""
    cols = ["run", "id", "created", "hosts_ok", "rows"]
    if res.column:
        cols += list(STAT_COLS) + ["change_pct"]
    rows = []
    for r in res.runs:
        h = r["hosts"]
        ok = ("%d/%d" % (h.get("ok", 0), h.get("total", 0))) if h else ""
        row = [r["label"], r["id"], r["created"], ok, str(r["rows"])]
        if res.column:
            s = r.get("stats") or {}
            row += [num(s.get(c)) for c in STAT_COLS]
            d = r.get("delta_pct")
            row.append(("%.1f" % d) if d not in (None, float("inf"),
                                                 float("-inf")) else "")
        rows.append(row)
    return Table(cols, rows, "runs")


def num(v):
    from .stats import fmt_num
    if v is None:
        return ""
    if isinstance(v, int):
        return str(v)
    return fmt_num(v)
