# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Martin J. Gallagher
"""qd check: a dataset against fixed limits keyed by requirement.

A thresholds file is TSV (or CSV) with a header:

    req      column  op       limit  limit2  where    agg     unit
    SYS-101  mbps    >=       900                     each    Mbps
    SYS-102  rtt_us  <=       250           rack=r2  p99     us
    SYS-103  status  in       ok
    SYS-104  temp_c  between  20     45               max

`req`, `column`, `op` and `limit` are required; the rest may be left out
or blank.  Each check gives one verdict: pass, fail, or not measured.
Blank is never a pass: a blank cell, a missing column, or no rows left by
`where` is not measured, and under `each` (the default) one unmeasured
row makes the whole check not measured unless another row failed it.
"""

from . import query, stats
from .common import QdError, die
from .table import load_file, split_unit, to_base, unit_family

PASS, FAIL, UNMEASURED = "pass", "fail", "not measured"
OPS = ("<", "<=", ">", ">=", "==", "!=", "in", "between")
REQUIRED = ("req", "column", "op", "limit")
OPTIONAL = ("limit2", "where", "agg", "unit", "note")
NUMERIC_AGGS = ("mean", "median", "min", "max", "sum", "stdev", "range",
                "p05", "p25", "p75", "p95", "p99")
AGGS = ("each",) + NUMERIC_AGGS


class Check(object):
    def __init__(self, line, req, column, op, limit, limit2="", where="",
                 agg="", unit="", note=""):
        self.line = line
        self.req = req
        self.column = column
        self.op = op
        self.limit = limit
        self.limit2 = limit2
        self.where = where
        self.agg = agg or "each"
        self.unit = unit
        self.note = note

    def limit_text(self):
        if self.op == "between":
            return "between %s and %s" % (self.limit, self.limit2)
        return "%s %s" % (self.op, self.limit)


def read_thresholds(path):
    """The checks in a thresholds file, or exit 2 naming the line that is
    wrong."""
    import os
    if not os.path.isfile(path):
        die("no such thresholds file: %s" % path, 2)
    try:
        t = load_file(path, fmt="table")[0]
    except (IOError, OSError, UnicodeDecodeError) as exc:
        die("cannot read %s: %s" % (path, exc), 2)
    cols = [c.strip().lower() for c in t.columns]
    missing = [c for c in REQUIRED if c not in cols]
    if missing:
        die("%s: the header needs %s (it has %s)" % (
            path, ", ".join(missing), ", ".join(t.columns) or "nothing"), 2)
    extra = [c for c in cols if c not in REQUIRED + OPTIONAL]
    if extra:
        die("%s: unknown column %s (want %s)" % (
            path, ", ".join(extra), ", ".join(REQUIRED + OPTIONAL)), 2)
    out, seen = [], {}
    for n, r in enumerate(t.rows, 1):
        d = dict((c, v.strip()) for c, v in zip(cols, r))
        if not any(d.values()):
            continue
        where = "%s, check %d (%s)" % (path, n, r[0].strip() or "no req")
        for c in REQUIRED:
            if not d.get(c):
                die("%s: %s is blank" % (where, c), 2)
        op = d["op"].lower()
        if op not in OPS:
            die("%s: unknown op %r (want %s)" % (where, d["op"],
                                                  ", ".join(OPS)), 2)
        agg = (d.get("agg") or "each").lower()
        if agg not in AGGS:
            die("%s: unknown agg %r (want %s)" % (where, d["agg"],
                                                   ", ".join(AGGS)), 2)
        if op == "between":
            if not d.get("limit2"):
                die("%s: between needs limit2" % where, 2)
            for k in ("limit", "limit2"):
                if split_unit(d[k])[0] is None:
                    die("%s: between needs numbers, not %r" % (where, d[k]),
                        2)
        elif op in ("<", "<=", ">", ">=") and split_unit(d["limit"])[0] \
                is None:
            die("%s: %s needs a number, not %r" % (where, op, d["limit"]), 2)
        if agg != "each" and op in ("in",):
            die("%s: %s over hosts gives a number; `in` wants words"
                % (where, agg), 2)
        if d.get("where"):
            try:
                query.parse(d["where"])
            except QdError as exc:
                die("%s: where %r: %s" % (where, d["where"], exc), 2)
        if (d["req"], d["column"], d.get("where", ""), agg) in seen:
            die("%s: the same check as check %d" % (
                where, seen[(d["req"], d["column"], d.get("where", ""),
                             agg)]), 2)
        seen[(d["req"], d["column"], d.get("where", ""), agg)] = n
        out.append(Check(n, d["req"], d["column"], op, d["limit"],
                         d.get("limit2", ""), d.get("where", ""), agg,
                         d.get("unit", ""), d.get("note", "")))
    if not out:
        die("%s holds no checks" % path, 2)
    return out


# ---------------------------------------------------------------------------
# Comparing
# ---------------------------------------------------------------------------

def _units_match(a, b):
    return (a or "").lower() == (b or "").lower()


class Scale(object):
    """How a column's cells and a check's limits are put on one footing:
    as written, or both on a base scale (bytes, seconds) when their units
    are of one family.  `problem` says why they cannot be compared."""

    def __init__(self, table, chk):
        self.base = False
        self.problem = ""
        self.declared = self.col_unit = ""
        col_unit = table.unit(chk.column)
        lim_unit = split_unit(chk.limit)[1] or ""
        declared = chk.unit or lim_unit
        if chk.unit and lim_unit and not _units_match(chk.unit, lim_unit):
            if not (unit_family(chk.unit) and unit_family(chk.unit) ==
                    unit_family(lim_unit)):
                self.problem = "limit %s is not in unit %s" % (chk.limit,
                                                                chk.unit)
                return
        self.unit = col_unit or declared
        self.declared = declared
        self.col_unit = col_unit
        if not declared or not col_unit or _units_match(declared, col_unit):
            if unit_family(lim_unit) and unit_family(col_unit) == \
                    unit_family(lim_unit) and not _units_match(lim_unit,
                                                               col_unit):
                self.base = True
            return
        if unit_family(declared) and unit_family(declared) == \
                unit_family(col_unit):
            self.base = True
            return
        self.problem = "column is in %s, the limit in %s" % (col_unit,
                                                              declared)

    def shown_unit(self):
        """The unit a check's figures are given in: the limit's, so the
        observed value reads beside the limit it is held to."""
        return self.declared or self.col_unit or ""

    def show(self, num):
        if num is None:
            return ""
        if self.base:
            f = to_base("1" + self.shown_unit())[0]
            if f:
                num = num / f
        return stats.fmt_num(num)

    def limit(self, text, chk):
        if self.base:
            v, u = split_unit(text)
            if v is not None and not u and chk.unit:
                text = text + chk.unit
            return to_base(text)[0]
        return split_unit(text)[0]


def _num_cells(table, chk, scale, rows):
    i = table.index(chk.column)
    if scale.base:
        return [to_base(r[i])[0] for r in rows]
    nums = table.numbers(chk.column)
    pos = dict((id(r), n) for n, r in enumerate(table.rows))
    return [nums[pos[id(r)]] for r in rows]


def compare(op, v, lim, lim2=None):
    if op == "<":
        return v < lim
    if op == "<=":
        return v <= lim
    if op == ">":
        return v > lim
    if op == ">=":
        return v >= lim
    if op == "==":
        return v == lim
    if op == "!=":
        return v != lim
    if op == "between":
        return lim <= v <= lim2
    raise ValueError(op)


def _text_ok(op, cell, chk):
    words = [w.strip().lower() for w in chk.limit.split(",") if w.strip()]
    c = cell.strip().lower()
    if op == "in":
        return c in words
    if op == "==":
        return c == chk.limit.strip().lower()
    if op == "!=":
        return c != chk.limit.strip().lower()
    return None


def _row_verdict(table, chk, scale, row, num):
    """(observed, verdict) for one row."""
    cell = row[table.index(chk.column)]
    if not cell.strip():
        return "", UNMEASURED
    numeric_op = chk.op in ("<", "<=", ">", ">=", "between") or (
        chk.op in ("==", "!=") and split_unit(chk.limit)[0] is not None)
    if numeric_op:
        if num is None:
            if chk.op in ("==", "!="):
                ok = _text_ok(chk.op, cell, chk)
                return cell.strip(), PASS if ok else FAIL
            return cell.strip(), UNMEASURED
        lim = scale.limit(chk.limit, chk)
        lim2 = scale.limit(chk.limit2, chk) if chk.op == "between" else None
        return scale.show(num) if scale.base else cell.strip(), \
            PASS if compare(chk.op, num, lim, lim2) else FAIL
    ok = _text_ok(chk.op, cell, chk)
    return cell.strip(), PASS if ok else FAIL


class Result(object):
    def __init__(self, chk, observed="", verdict=UNMEASURED, measured=0,
                 total=0, unit="", note="", rows=None):
        self.chk = chk
        self.observed = observed
        self.verdict = verdict
        self.measured = measured
        self.total = total
        self.unit = unit
        self.note = note
        self.rows = rows or []     # [(label, observed, verdict)]


def _label(table, row, n):
    for c in ("host", "target", "name", "src"):
        if table.has(c):
            v = row[table.index(c)].strip()
            if v:
                return v
    return "row %d" % n


def run_check(table, chk):
    if not table.has(chk.column):
        return Result(chk, note="no column %s" % chk.column)
    rows = table.rows
    if chk.where:
        try:
            rows = query.where(table, [chk.where])
        except QdError as exc:
            return Result(chk, note="where %s: %s" % (chk.where, exc))
    if not rows:
        return Result(chk, note="no rows where %s" % chk.where)
    scale = Scale(table, chk)
    if scale.problem:
        return Result(chk, total=len(rows), note="unit mismatch: " +
                      scale.problem)
    nums = _num_cells(table, chk, scale, rows) if scale.base or \
        table.kind(chk.column) in ("num", "mixed") else [None] * len(rows)
    pos = dict((id(r), n) for n, r in enumerate(table.rows, 1))
    per = []
    for r, num in zip(rows, nums):
        obs, v = _row_verdict(table, chk, scale, r, num)
        per.append((_label(table, r, pos[id(r)]), obs, v))
    measured = sum(1 for _, _, v in per if v != UNMEASURED)
    unit = scale.shown_unit()
    if scale.declared and not scale.col_unit and \
            table.kind(chk.column) == "num":
        chk_note = "the column carries no unit: read as %s" % scale.declared
    else:
        chk_note = ""
    if chk.agg == "each":
        fails = [p for p in per if p[2] == FAIL]
        if fails:
            verdict = FAIL
        elif measured < len(per):
            verdict = UNMEASURED
        else:
            verdict = PASS
        # the worst row is the one shown: a failure, else a blank, else
        # the one nearest the limit
        if fails:
            shown = fails[0][1]
            note = "%d of %d failed: %s" % (len(fails), len(per), ", ".join(
                p[0] for p in fails[:5]) + (", ..." if len(fails) > 5
                                             else ""))
            if measured < len(per):
                note += "; %d not measured" % (len(per) - measured)
        elif measured < len(per):
            shown = ""
            blank = [p[0] for p in per if p[2] == UNMEASURED]
            note = "%d of %d not measured: %s" % (
                len(blank), len(per), ", ".join(blank[:5]) +
                (", ..." if len(blank) > 5 else ""))
        else:
            shown = _nearest(chk, per, nums, scale)
            note = ""
        return Result(chk, shown, verdict, measured, len(per), unit,
                      "; ".join(x for x in (note, chk_note) if x), per)
    vals = [n for n in nums if n is not None]
    if not vals:
        return Result(chk, "", UNMEASURED, 0, len(per), unit,
                      "nothing numeric to take the %s of" % chk.agg, per)
    agg = stats.AGGS[chk.agg]([repr(v) for v in vals])
    lim = scale.limit(chk.limit, chk)
    lim2 = scale.limit(chk.limit2, chk) if chk.op == "between" else None
    ok = compare(chk.op, agg, lim, lim2)
    if measured < len(per):
        blank = [p[0] for p in per if p[2] == UNMEASURED]
        return Result(chk, scale.show(agg), UNMEASURED, measured,
                      len(per), unit, "%s over %d of %d (%s would %s); not "
                      "measured: %s" % (chk.agg, measured, len(per), chk.agg,
                                        "pass" if ok else "fail",
                                        ", ".join(blank[:5])) +
                      ("; " + chk_note if chk_note else ""), per)
    return Result(chk, scale.show(agg), PASS if ok else FAIL, measured,
                  len(per), unit, chk_note, per)


def _nearest(chk, per, nums, scale):
    """The measured value closest to failing, for an all-pass `each`."""
    pairs = [(n, p[1]) for n, p in zip(nums, per) if n is not None]
    if not pairs:
        return per[0][1] if per else ""
    if chk.op in ("<", "<="):
        return max(pairs, key=lambda x: x[0])[1]
    if chk.op in (">", ">="):
        return min(pairs, key=lambda x: x[0])[1]
    if chk.op == "between":
        lo = scale.limit(chk.limit, chk)
        hi = scale.limit(chk.limit2, chk)
        return min(pairs, key=lambda x: min(x[0] - lo, hi - x[0]))[1]
    return pairs[0][1]


def run(table, checks):
    return [run_check(table, c) for c in checks]


SUMMARY_COLUMNS = ["req", "column", "agg", "where", "observed", "limit",
                   "unit", "measured", "verdict", "note"]
EACH_COLUMNS = ["req", "row", "column", "observed", "limit", "unit",
                "verdict"]


def summary_rows(results):
    out = []
    for r in results:
        c = r.chk
        out.append([c.req, c.column, c.agg, c.where, r.observed,
                    c.limit_text(), r.unit,
                    "%d/%d" % (r.measured, r.total), r.verdict,
                    "; ".join(x for x in (r.note, c.note) if x)])
    return out


def each_rows(results):
    out = []
    for r in results:
        c = r.chk
        if not r.rows:
            out.append([c.req, "", c.column, "", c.limit_text(), r.unit,
                        r.verdict])
        for label, obs, v in r.rows:
            out.append([c.req, label, c.column, obs, c.limit_text(), r.unit,
                        v])
    return out


def counts(results):
    out = {PASS: 0, FAIL: 0, UNMEASURED: 0}
    for r in results:
        out[r.verdict] += 1
    return out

