# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Martin J. Gallagher
"""What changed between two datasets.

Rows are matched on key columns -- `host` for a fleet run, `test,target`
for viewer results, `src,dst` for a grid, `source,target` for iperf --
and every other column they share is compared.  A key that repeats (a
report row per interval, a probe per pass) is reduced first, numbers by
their mean and words by the worst or most common, and the report says so:
comparing one arbitrary interval against another turns ordinary variance
into a change.

Columns that differ on every run by construction -- timestamps, run
labels, durations -- are left out and named, the same way agree's
--fleet-csv masks host and ts: masking applies to what is compared,
never to what is kept.
"""

import difflib

from .common import die
from .stats import AGGS, SEVERITY, cell, check_aggs, mean, quantile
from .table import Table, to_num

VOLATILE = ("ts", "timestamp", "time", "date", "at", "run", "duration_s",
            "test_start", "started", "finished", "filename", "pass",
            "meta_run", "source_file", "capture", "#", "bytes")

# `n` is provost's record number within a capture: a host that answered
# with three rows is matched row by row.
SECONDARY = ("dir", "peer", "layer", "rule_id", "line_no", "test", "probe",
             "flow", "column", "group", "n")


def auto_key(a, b):
    def both(c):
        return a.has(c) and b.has(c)
    if a.is_results() and b.is_results():
        return ["test", "target"] + [c for c in ("peer", "dir", "layer")
                                     if both(c)]
    for pair in (("src", "dst"), ("source", "target")):
        if both(pair[0]) and both(pair[1]):
            return list(pair) + [c for c in ("dir", "peer", "layer")
                                 if both(c)]
    for primary in ("host", "ssh_host", "target", "name", "column"):
        if both(primary):
            return [primary] + [c for c in SECONDARY
                                if c != primary and both(c)]
    common = [c for c in a.columns if b.has(c)]
    if not common:
        die("the two tables share no column to match rows on")
    return common[:1]


class Change(object):
    __slots__ = ("col", "a", "b", "delta", "pct", "kind")

    def __init__(self, col, a, b, delta=None, pct=None, kind="changed"):
        self.col, self.a, self.b = col, a, b
        self.delta, self.pct, self.kind = delta, pct, kind


class DiffResult(object):
    def __init__(self):
        self.key = []
        self.cols = []
        self.ignored = []
        self.only_a = []
        self.only_b = []
        self.changed = []           # [(key tuple, [Change])]
        self.same = 0
        self.notes = []
        self.col_summary = []       # per numeric column

    @property
    def differs(self):
        return bool(self.only_a or self.only_b or self.changed)


def _reduce(table, key_idx, cols, agg, side, notes):
    order, groups = [], {}
    for r in table.rows:
        k = tuple(r[i].strip() for i in key_idx)
        if k not in groups:
            groups[k] = []
            order.append(k)
        groups[k].append(r)
    multi = sum(1 for k in order if len(groups[k]) > 1)
    out = {}
    for k in order:
        rows = groups[k]
        vals = {}
        for c, i in cols:
            cells = [r[i] for r in rows]
            if len(cells) == 1:
                vals[c] = cells[0].strip()
            else:
                v = AGGS[agg](cells)
                # full precision: a single row on the other side is not
                # rounded, so neither is this
                vals[c] = ("%.15g" % v) if isinstance(v, float) else cell(v)
        out[k] = vals
    if multi:
        notes.append("%s: %d rows over %d keys -- %d keys repeat, so each "
                     "was reduced to its %s before comparing"
                     % (side, len(table.rows), len(order), multi,
                        "numbers' mean and words' worst or most common"
                        if agg == "auto" else agg))
    return order, out


def _severity(v):
    return SEVERITY.get(v.strip().lower(), None)


def diff_tables(a, b, key=None, cols=None, tolerance=0.0, agg="auto"):
    res = DiffResult()
    check_aggs([agg])
    key = key or auto_key(a, b)
    res.key = [a.colname(k) for k in key]
    for k in key:
        b.index(k)
    if cols:
        res.cols = [a.colname(c) for c in cols]
        for c in cols:
            b.index(c)
    else:
        for c in a.columns:
            if c in res.key or not b.has(c):
                continue
            if c.lower() in VOLATILE:
                res.ignored.append(c)
                continue
            res.cols.append(c)
    a_cols = [(c, a.index(c)) for c in res.cols]
    b_cols = [(c, b.index(c)) for c in res.cols]
    a_order, a_vals = _reduce(a, [a.index(k) for k in res.key], a_cols, agg,
                              "A", res.notes)
    b_order, b_vals = _reduce(b, [b.index(k) for k in res.key], b_cols, agg,
                              "B", res.notes)
    only_a_cols = [c for c in a.columns if not b.has(c)]
    only_b_cols = [c for c in b.columns if not a.has(c)]
    if only_a_cols:
        res.notes.append("only A has column(s): %s" % ", ".join(only_a_cols))
    if only_b_cols:
        res.notes.append("only B has column(s): %s" % ", ".join(only_b_cols))
    res.only_a = [k for k in a_order if k not in b_vals]
    res.only_b = [k for k in b_order if k not in a_vals]
    pairs = {c: [] for c in res.cols}
    for k in a_order:
        if k not in b_vals:
            continue
        changes = []
        for c in res.cols:
            va, vb = a_vals[k][c], b_vals[k][c]
            na, nb = to_num(va), to_num(vb)
            if na is not None and nb is not None:
                pairs[c].append((na, nb))
            if va == vb:
                continue
            if not va:
                changes.append(Change(c, va, vb, kind="appeared"))
            elif not vb:
                changes.append(Change(c, va, vb, kind="went blank"))
            elif na is not None and nb is not None:
                d = nb - na
                pct = 100.0 * d / abs(na) if na else None
                if d == 0:
                    continue
                if tolerance and pct is not None and abs(pct) <= tolerance:
                    continue
                changes.append(Change(c, va, vb, d, pct))
            else:
                changes.append(Change(c, va, vb))
        if changes:
            res.changed.append((k, changes))
        else:
            res.same += 1

    def rank(item):
        key, changes = item
        worse = any((_severity(ch.b) or 0) > (_severity(ch.a) or 0)
                    for ch in changes)
        blanked = any(ch.kind == "went blank" for ch in changes)
        pcts = [abs(ch.pct) for ch in changes if ch.pct is not None]
        return (0 if worse else 1, 0 if blanked else 1,
                -(max(pcts) if pcts else 0), key)
    res.changed.sort(key=rank)
    for c in res.cols:
        p = pairs[c]
        if not p or len(p) < 1:
            continue
        rose = sum(1 for x, y in p if y > x)
        fell = sum(1 for x, y in p if y < x)
        ma, mb = mean([x for x, _ in p]), mean([y for _, y in p])
        deltas = sorted(y - x for x, y in p)
        res.col_summary.append({
            "column": c, "n": len(p), "mean_a": ma, "mean_b": mb,
            "mean_pct": (100.0 * (mb - ma) / abs(ma)) if ma else None,
            "median_delta": quantile(deltas, .5),
            "rose": rose, "fell": fell, "same": len(p) - rose - fell})
    return res


def text_diff(a, b, limit=12):
    """A unified diff of two multi-line cells, cut at `limit` lines."""
    lines = list(difflib.unified_diff(a.splitlines(), b.splitlines(),
                                      "A", "B", lineterm="", n=1))[2:]
    if len(lines) > limit:
        more = len(lines) - limit
        lines = lines[:limit] + ["... %d more diff line(s)" % more]
    return lines


DIFF_COLS = ["change", "column", "a", "b", "delta", "pct"]


def as_table(res):
    """The diff as tidy rows: one per changed cell, gone or new key."""
    cols = list(res.key) + DIFF_COLS
    rows = []
    for k in res.only_a:
        rows.append(list(k) + ["gone", "", "", "", "", ""])
    for k in res.only_b:
        rows.append(list(k) + ["new", "", "", "", "", ""])
    for k, changes in res.changed:
        for ch in changes:
            rows.append(list(k) + [ch.kind, ch.col, ch.a, ch.b,
                                   cell(ch.delta), cell(ch.pct)])
    return Table(cols, rows, "diff")
