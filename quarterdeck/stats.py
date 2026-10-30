# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Martin J. Gallagher
"""Statistics over tables: describe, group, count, bin, flag, pivot, trend.

Every function here skips blanks rather than counting them as zero, and
says how many it skipped.  Quantiles interpolate linearly between the
closest ranks (the common "type 7" definition), so a p95 of 20 values is
a number between two of them rather than one of them.
"""

import math
import re
from collections import Counter

from .common import die
from .table import Table, normalize_units, to_num

# How bad a word is, for the `worst` aggregation and for verdict cells in
# a pivot: the worst wins, so a failure under a collapsed group stays
# visible -- the rule the floor-plan viewer applies to verdict metrics.
SEVERITY = {"pass": 0, "ok": 0, "tested": 0, "reporting": 0,
            "warn": 1, "skipped": 1, "silent": 2,
            "fail": 3, "failed": 3, "timeout": 3, "push-failed": 3,
            "no-data": 3, "unreachable": 4}

BOOKKEEPING = ("rc", "duration_s", "pass", "ts", "line_no", "n", "#",
               "capture", "bytes")

TIME_COLUMNS = ("ts", "timestamp", "time", "pass", "at", "test_start",
                "started", "date")


def quantile(s, q):
    """q in [0,1] over an already-sorted list; linear between ranks."""
    if not s:
        return None
    if len(s) == 1:
        return s[0]
    pos = (len(s) - 1) * q
    lo = int(math.floor(pos))
    hi = min(lo + 1, len(s) - 1)
    return s[lo] + (s[hi] - s[lo]) * (pos - lo)


def mean(xs):
    return sum(xs) / len(xs) if xs else None


def stdev(xs):
    """Sample standard deviation; None below two values, where it is not
    a measurement of anything."""
    if len(xs) < 2:
        return None
    m = mean(xs)
    return math.sqrt(sum((x - m) ** 2 for x in xs) / (len(xs) - 1))


def summary(nums):
    xs = sorted(x for x in nums if x is not None)
    out = {"n": len(xs)}
    if not xs:
        return out
    out.update(mean=mean(xs), stdev=stdev(xs), min=xs[0], max=xs[-1],
               sum=sum(xs), p05=quantile(xs, .05), p25=quantile(xs, .25),
               median=quantile(xs, .5), p75=quantile(xs, .75),
               p95=quantile(xs, .95), p99=quantile(xs, .99))
    return out


# ---------------------------------------------------------------------------
# Aggregations: a list of cells in, one cell out
# ---------------------------------------------------------------------------

def _nums(cells):
    return [n for n in (to_num(c) for c in cells) if n is not None]


def _filled(cells):
    return [c for c in cells if c.strip()]


def _num_agg(fn):
    def agg(cells):
        xs = sorted(_nums(cells))
        return fn(xs) if xs else None
    return agg


def is_verdictish(cells):
    vals = set(c.strip().lower() for c in _filled(cells))
    return bool(vals) and vals <= set(SEVERITY)


def _worst(cells):
    vals = _filled(cells)
    if not vals:
        return None
    return max(vals, key=lambda v: (SEVERITY.get(v.strip().lower(), -1), v))


def _top(cells):
    vals = _filled(cells)
    if not vals:
        return None
    c = Counter(vals)
    best = sorted(c.items(), key=lambda kv: (-kv[1], kv[0]))[0]
    if best[1] == len(vals):
        return best[0]
    return "%s (%d/%d)" % (best[0], best[1], len(vals))


def _auto(cells):
    """Numbers average; verdicts take the worst; other words the most
    common, with its share when not unanimous."""
    filled = _filled(cells)
    if not filled:
        return None
    if len(_nums(filled)) == len(filled):
        return AGGS["mean"](filled)
    if is_verdictish(filled):
        return _worst(filled)
    return _top(filled)


AGGS = {
    "mean": _num_agg(mean),
    "median": _num_agg(lambda s: quantile(s, .5)),
    "min": _num_agg(lambda s: s[0]),
    "max": _num_agg(lambda s: s[-1]),
    "sum": _num_agg(sum),
    "stdev": _num_agg(stdev),
    "range": _num_agg(lambda s: s[-1] - s[0]),
    "p05": _num_agg(lambda s: quantile(s, .05)),
    "p25": _num_agg(lambda s: quantile(s, .25)),
    "p75": _num_agg(lambda s: quantile(s, .75)),
    "p95": _num_agg(lambda s: quantile(s, .95)),
    "p99": _num_agg(lambda s: quantile(s, .99)),
    "count": lambda cells: len(_filled(cells)),
    "distinct": lambda cells: len(set(_filled(cells))),
    "first": lambda cells: (_filled(cells) or [None])[0],
    "last": lambda cells: (_filled(cells) or [None])[-1],
    "top": _top,
    "worst": _worst,
    "auto": _auto,
}


def check_aggs(names):
    for a in names:
        if a not in AGGS:
            die("unknown aggregation %r (want %s)"
                % (a, ", ".join(sorted(AGGS))))
    return names


def cell(v):
    """An aggregate back as a table cell, in the four-significant-digit
    fixed notation the toolchain writes, so 1.163e+06 never appears."""
    if v is None:
        return ""
    if isinstance(v, str):
        return v
    return fmt_num(v)


def fmt_num(v, sig=4):
    if v is None:
        return ""
    if isinstance(v, int):
        return str(v)
    if v == int(v) and abs(v) < 1e15:
        return str(int(v))
    if v == 0:
        return "0"
    mag = int(math.floor(math.log10(abs(v))))
    dec = max(0, min(6, sig - 1 - mag))
    s = "%.*f" % (dec, v)
    if "." in s:
        s = s.rstrip("0").rstrip(".")
    return "0" if s in ("-0", "") else s


# ---------------------------------------------------------------------------
# describe
# ---------------------------------------------------------------------------

DESCRIBE_COLS = ["column", "kind", "n", "blank", "distinct", "mean",
                 "stdev", "min", "p05", "median", "p95", "max", "top"]


def describe(table, cols=None):
    """One row per column: what is in it, and how it is spread."""
    out = []
    for c in (cols or table.columns):
        name = table.colname(c)
        vals = table.values(name)
        kind = table.kind(name)
        filled = _filled(vals)
        s = summary(table.numbers(name)) if kind in ("num", "mixed") else {}
        row = [name, kind, str(len(filled)), str(len(vals) - len(filled)),
               str(len(set(filled)))]
        for k in ("mean", "stdev", "min", "p05", "median", "p95", "max"):
            row.append(cell(s.get(k)))
        top = ""
        if kind in ("text", "mixed") or (kind == "num" and len(set(filled))
                                          <= 3 and len(filled) > 3):
            top = _top(filled) or ""
        row.append(top)
        out.append(row)
    return Table(DESCRIBE_COLS, out, "describe", table.source)


# ---------------------------------------------------------------------------
# group
# ---------------------------------------------------------------------------

def _key_sort(keys):
    def k(key):
        out = []
        for part in key:
            n = to_num(part)
            out.append((0, n, "") if n is not None else
                       (1 if part else 2, 0, part.lower()))
        return out
    return sorted(keys, key=k)


def groups(table, by):
    idx = [table.index(b) for b in by]
    order, members = [], {}
    for r in table.rows:
        key = tuple(r[i] for i in idx)
        if key not in members:
            members[key] = []
            order.append(key)
        members[key].append(r)
    return [(k, members[k]) for k in _key_sort(order)]


def group_by(table, by, cols=None, aggs=None):
    """One row per distinct value of the --by columns.

    With one value column the default is its centre and spread (mean,
    median, min, max); with several, each one's mean -- or what --agg
    asks for -- and every figure's name says which it is (mbps_mean).  A
    word column gets `auto`: verdicts take the worst, other words the
    most common.
    """
    table = normalize_units([table])[0]     # 512M beside 2G: one scale
    by = [table.colname(b) for b in by]
    if cols:
        cols = [table.colname(c) for c in cols]
    else:
        cols = [c for c in table.columns if c not in by
                and table.kind(c) == "num"]
        # How a run went (exit code, seconds, pass number) is bookkeeping,
        # not a measurement: left out when there is anything else.
        measured = [c for c in cols if c not in BOOKKEEPING]
        cols = measured or cols
    if aggs:
        check_aggs(aggs)
    out_cols = list(by) + ["n"]
    plan = []
    for c in cols:
        kind = table.kind(c)
        if aggs:
            mine = aggs
        elif kind in ("num",) and len(cols) == 1:
            mine = ["mean", "median", "min", "max"]
        elif kind == "num":
            mine = ["mean"]
        else:
            mine = ["auto"]
        for a in mine:
            out_cols.append(c if a == "auto" else "%s_%s" % (c, a))
            plan.append((table.index(c), a))
    rows = []
    for key, members in groups(table, by):
        row = list(key) + [str(len(members))]
        for i, a in plan:
            row.append(cell(AGGS[a]([m[i] for m in members])))
        rows.append(row)
    return Table(out_cols, rows, "groups", table.source)


# ---------------------------------------------------------------------------
# freq: value counts, which is consensus by another name
# ---------------------------------------------------------------------------

DIGITS_RE = re.compile(r"\d+(?:\.\d+)?")


def normalize(value, loose):
    if not loose:
        return value
    v = re.sub(r"[ \t]+", " ", value.strip())
    v = "\n".join(ln.rstrip() for ln in v.splitlines())
    return DIGITS_RE.sub("#", v)


def freq(table, col, loose=False, label_col=None):
    """[(value, count, labels)] most common first.

    `labels` are the hosts (or whatever --label names) holding each value,
    in table order, so "47 agree, 3 don't" comes with who the 3 are.
    """
    i = table.index(col)
    li = None
    if label_col:
        li = table.index(label_col)
    elif table.has("host") and table.colname("host") != table.columns[i]:
        li = table.index("host")
    counts, labels, first = Counter(), {}, {}
    for r in table.rows:
        key = normalize(r[i], loose)
        counts[key] += 1
        first.setdefault(key, r[i])
        if li is not None:
            labels.setdefault(key, [])
            if r[li] not in labels[key]:
                labels[key].append(r[li])
    out = []
    for key, n in sorted(counts.items(), key=lambda kv: (-kv[1], kv[0])):
        out.append((key if loose else first[key], n, labels.get(key, [])))
    return out


# ---------------------------------------------------------------------------
# hist
# ---------------------------------------------------------------------------

def histogram(nums, bins=None):
    """[(lo, hi, count)] over equal-width bins.

    A column of a few distinct whole numbers (exit codes, core counts,
    MTUs) gets one bin per value instead, because a bin from 1499.5 to
    3000 is not a reading of anything.
    """
    xs = sorted(x for x in nums if x is not None)
    if not xs:
        return []
    distinct = sorted(set(xs))
    if all(x == int(x) for x in distinct) and len(distinct) <= (bins or 20):
        c = Counter(xs)
        return [(v, v, c[v]) for v in distinct]
    lo, hi = xs[0], xs[-1]
    if lo == hi:
        return [(lo, hi, len(xs))]
    if not bins:
        bins = max(5, min(30, int(math.ceil(math.log(len(xs), 2))) + 1))
    width = (hi - lo) / float(bins)
    counts = [0] * bins
    for x in xs:
        k = min(bins - 1, int((x - lo) / width))
        counts[k] += 1
    return [(lo + k * width, lo + (k + 1) * width, counts[k])
            for k in range(bins)]


# ---------------------------------------------------------------------------
# outliers
# ---------------------------------------------------------------------------

OUTLIER_COLS = ["key", "value", "median", "rel_median_pct", "robust_z",
                "side"]


def default_per(table, col):
    """Reduce per host when hosts repeat (a time series, a mesh), so one
    host's hundred rows count as one opinion -- per target, in a results
    table."""
    name = table.colname(col)
    if table.is_results() and name == "value":
        return "target"
    if table.has("host") and table.colname("host") != name:
        hosts = table.values("host")
        if len(set(hosts)) < len(hosts):
            return table.colname("host")
    return None


def outliers(table, col, per=None, z=3.5):
    """Who sits far from everybody else, by the median and the MAD.

    The robust z-score is 0.6745 (x - median) / MAD (Iglewicz and
    Hoaglin); past 3.5 is an outlier.  The median and MAD rather than the
    mean and stdev because the outlier is the thing being looked for: one
    host at a tenth of the speed drags a mean and inflates a stdev until
    it hides inside both.  When most of the fleet agrees exactly (MAD 0)
    every value that differs is reported, since agreement is the norm.
    Returns (rows, info).
    """
    name = table.colname(col)
    vals = table.numbers(name)
    if per:
        ki = table.index(per)
        by = {}
        order = []
        for r, v in zip(table.rows, vals):
            if v is None:
                continue
            if r[ki] not in by:
                by[r[ki]] = []
                order.append(r[ki])
            by[r[ki]].append(v)
        items = [(k, quantile(sorted(by[k]), .5)) for k in order]
    else:
        li = table.index("host") if table.has("host") and \
            table.colname("host") != name else None
        items = []
        for n, (r, v) in enumerate(zip(table.rows, vals), 1):
            if v is not None:
                items.append((r[li] if li is not None else "row %d" % n, v))
    xs = sorted(v for _, v in items)
    info = {"n": len(xs), "column": name, "per": per, "z": z}
    if not xs:
        return [], info
    med = quantile(xs, .5)
    mad = quantile(sorted(abs(x - med) for x in xs), .5)
    info.update(median=med, mad=mad)
    rows = []
    for key, v in items:
        if mad:
            rz = 0.6745 * (v - med) / mad
            hit = abs(rz) > z
        else:
            rz = float("inf") if v > med else float("-inf") if v < med \
                else 0.0
            hit = v != med
        if not hit:
            continue
        rel = 100.0 * v / med if med else None
        rows.append((key, v, med, rel, rz, "high" if v > med else "low"))
    rows.sort(key=lambda r: (-abs(r[4]), str(r[0])))
    return rows, info


# ---------------------------------------------------------------------------
# pivot
# ---------------------------------------------------------------------------

def natural_sorted(vals):
    def k(v):
        n = to_num(v)
        return (0, n, "") if n is not None else (1, 0, v.lower())
    return sorted(vals, key=k)


def pivot(table, rows, cols, values=None, agg="auto"):
    """Long to wide: one row per --rows value, one column per --cols value.

    With no --values each cell is a count.  `auto` decides per cell:
    numbers average, verdicts take the worst, other words the most common.
    """
    table = normalize_units([table])[0]
    ri, ci = table.index(rows), table.index(cols)
    vi = table.index(values) if values else None
    check_aggs([agg])
    rkeys, ckeys, cells = [], [], {}
    for r in table.rows:
        rk, ck = r[ri], r[ci]
        if rk not in cells:
            cells[rk] = {}
            rkeys.append(rk)
        if ck not in ckeys:
            ckeys.append(ck)
        cells[rk].setdefault(ck, []).append(r[vi] if vi is not None else "x")
    ckeys = natural_sorted(ckeys)
    out = []
    for rk in natural_sorted(rkeys):
        row = [rk]
        for ck in ckeys:
            got = cells[rk].get(ck)
            if got is None:
                row.append("")
            elif vi is None:
                row.append(str(len(got)))
            else:
                row.append(cell(AGGS[agg](got)))
        out.append(row)
    t = Table([table.colname(rows)] + ckeys, out, "pivot", table.source)
    if table.is_results():
        t.tests = table.tests
    return t


# ---------------------------------------------------------------------------
# trend
# ---------------------------------------------------------------------------

def default_over(table):
    for c in TIME_COLUMNS:
        if table.has(c) and table.colname(c).lower() == c:
            return table.colname(c)
    return None


def trend(table, col, by=None, over=None):
    """[(group, [value or None, ...])] each in --over order."""
    table = normalize_units([table], [col])[0]
    vi = table.index(col)
    oi = table.index(over) if over else None
    rows = list(table.rows)
    if oi is not None:
        def k(r):
            n = to_num(r[oi])
            return (0, n, "") if n is not None else (1, 0, r[oi])
        rows.sort(key=k)
    if by:
        bi = table.index(by)
        order, series = [], {}
        for r in rows:
            g = r[bi]
            if g not in series:
                series[g] = []
                order.append(g)
            series[g].append(to_num(r[vi]))
        return [(g, series[g]) for g in natural_sorted(order)]
    return [("(all)", [to_num(r[vi]) for r in rows])]


def resample(series, width):
    """A series squeezed to at most `width` points by bucket means; a
    bucket with nothing measured stays None, a gap rather than a zero."""
    if len(series) <= width:
        return list(series)
    out = []
    step = len(series) / float(width)
    for k in range(width):
        part = [v for v in series[int(k * step):int((k + 1) * step)]
                if v is not None]
        out.append(mean(part) if part else None)
    return out
