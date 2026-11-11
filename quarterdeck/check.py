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

`within` holds a value to `limit` give or take `limit2` (`+-10%`,
`-5%,+10%`, `+-3`).  A `severity` column (critical, high, medium, low,
info) lets `--fail-level` leave lesser failures reported but not failing
the run.  A waivers file (QD-028) excuses a measured failure of a named
requirement with a justification, until an expiry date: the check is then
waived, never passed, and a waiver that expects a failure flags a pass as
an unexpected pass.  Not measured is never waived.
"""

import datetime
import re

from . import query, stats
from .common import QdError, die
from .table import load_file, split_unit, to_base, unit_family

PASS, FAIL, UNMEASURED = "pass", "fail", "not measured"
WAIVED, UNEXPECTED = "waived", "unexpected pass"
VERDICTS = (PASS, FAIL, UNMEASURED, WAIVED, UNEXPECTED)
OPS = ("<", "<=", ">", ">=", "==", "!=", "in", "between", "within")
REQUIRED = ("req", "column", "op", "limit")
OPTIONAL = ("limit2", "where", "agg", "unit", "note", "severity")
# InSpec's words, least to most; its impact numbers map onto them
SEVERITIES = ("info", "low", "medium", "high", "critical")
WAIVER_REQUIRED = ("req", "justification")
WAIVER_OPTIONAL = ("expires", "where", "expect", "granted_by")
NUMERIC_AGGS = ("mean", "median", "min", "max", "sum", "stdev", "range",
                "p05", "p25", "p75", "p95", "p99")
AGGS = ("each",) + NUMERIC_AGGS


def severity_of(text):
    """A severity word from a thresholds cell: one of SEVERITIES, `none`
    for info, or an InSpec impact 0.0-1.0; "" when blank, None when it is
    none of those."""
    t = (text or "").strip().lower()
    if not t:
        return ""
    if t == "none":
        return "info"
    if t in SEVERITIES:
        return t
    try:
        v = float(t)
    except ValueError:
        return None
    if not 0.0 <= v <= 1.0:
        return None
    if v < 0.01:
        return "info"
    if v < 0.4:
        return "low"
    if v < 0.7:
        return "medium"
    if v < 0.9:
        return "high"
    return "critical"


def _tol_part(text):
    """(amount, is_percent, unit) for one side of a tolerance, as written
    without its sign; None when it is not one."""
    v, u = split_unit(text)
    if v is None or v < 0:
        return None
    if u == "%":
        return v, True, ""
    return v, False, u or ""


def parse_tolerance(text):
    """(lower, upper, shown) from `limit2` of a `within` check: each side
    (amount, is_percent, unit).  `+-10%`, `\u00b110%`, `+/-3`, or two
    signed sides `-5%,+10%` (`;` also separates them).  None when it
    cannot be read."""
    t = (text or "").strip().replace(" ", "")
    for sym in (u"\u00b1", "+/-", "+-"):
        if t.startswith(sym):
            part = _tol_part(t[len(sym):])
            if part is None:
                return None
            w = t[len(sym):]
            return part, part, "-%s, +%s" % (w, w)
    bits = [b for b in re.split(r"[,;]", t)]
    if len(bits) != 2:
        return None
    lo = hi = None
    for b in bits:
        if b.startswith("-") and lo is None:
            lo = (_tol_part(b[1:]), b[1:])
        elif b.startswith("+") and hi is None:
            hi = (_tol_part(b[1:]), b[1:])
        else:
            return None
    if lo is None or hi is None or lo[0] is None or hi[0] is None:
        return None
    return lo[0], hi[0], "-%s, +%s" % (lo[1], hi[1])


def _within_bounds(limit, limit2, unit):
    """(lo text, hi text, shown) for a `within` check, in the limit's own
    unit; or a string saying why it cannot be read."""
    tol = parse_tolerance(limit2)
    if tol is None:
        return "within needs a tolerance in limit2 (+-10%%, -5%%,+10%% " \
            "or +-3), not %r" % limit2
    ref, ref_unit = split_unit(limit)
    if ref is None:
        return "within needs a number in limit, not %r" % limit
    own = ref_unit or unit or ""
    bounds = []
    for sign, (amount, pct, tunit) in ((-1, tol[0]), (1, tol[1])):
        if pct:
            d = abs(ref) * amount / 100.0
        elif not tunit or (own and tunit.lower() == own.lower()):
            d = amount
        elif own and unit_family(tunit) and \
                unit_family(tunit) == unit_family(own):
            d = to_base("%r%s" % (amount, tunit))[0] / \
                to_base("1" + own)[0]
        else:
            return "within: the tolerance %r is not in the limit's unit " \
                "(%s)" % (limit2, own or "none")
        bounds.append("%r%s" % (ref + sign * d, ref_unit or ""))
    return bounds[0], bounds[1], tol[2]


class Check(object):
    def __init__(self, line, req, column, op, limit, limit2="", where="",
                 agg="", unit="", note="", severity=""):
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
        self.severity = severity
        self.lo = self.hi = self.tol_shown = ""
        if op == "within":
            b = _within_bounds(limit, limit2, unit)
            if not isinstance(b, str):
                self.lo, self.hi, self.tol_shown = b

    def limit_text(self):
        if self.op == "between":
            return "between %s and %s" % (self.limit, self.limit2)
        if self.op == "within":
            return "within %s (%s)" % (self.limit, self.tol_shown)
        return "%s %s" % (self.op, self.limit)

    def range_op(self):
        return self.op in ("between", "within")


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
        sev = severity_of(d.get("severity"))
        if sev is None:
            die("%s: unknown severity %r (want %s, or an impact 0.0-1.0)"
                % (where, d["severity"], ", ".join(SEVERITIES)), 2)
        if op == "within":
            b = _within_bounds(d["limit"], d.get("limit2", ""),
                               d.get("unit", ""))
            if isinstance(b, str):
                die("%s: %s" % (where, b), 2)
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
                         d.get("unit", ""), d.get("note", ""), sev))
    if not out:
        die("%s holds no checks" % path, 2)
    return out


class Waiver(object):
    def __init__(self, line, req, justification, expires="", where="",
                 expect="", granted_by=""):
        self.line = line
        self.req = req
        self.justification = justification
        self.expires = expires
        self.where = where
        self.expect = expect
        self.granted_by = granted_by

    def expired(self, today=None):
        if not self.expires:
            return False
        today = today or datetime.date.today()
        return _date(self.expires) < today

    def expires_text(self, today=None):
        if not self.expires:
            return ""
        return self.expires + (" (expired)" if self.expired(today) else "")


def _date(text):
    try:
        return datetime.datetime.strptime(text, "%Y-%m-%d").date()
    except ValueError:
        return None


def read_waivers(path, checks):
    """The waivers in a waivers file, keyed by nothing: a list in file
    order.  Exit 2 naming the line that is wrong, and for a waiver whose
    req no check has, so a typo cannot quietly excuse nothing."""
    import os
    if not os.path.isfile(path):
        die("no such waivers file: %s" % path, 2)
    try:
        t = load_file(path, fmt="table")[0]
    except (IOError, OSError, UnicodeDecodeError) as exc:
        die("cannot read %s: %s" % (path, exc), 2)
    cols = [c.strip().lower() for c in t.columns]
    missing = [c for c in WAIVER_REQUIRED if c not in cols]
    if missing:
        die("%s: the header needs %s (it has %s)" % (
            path, ", ".join(missing), ", ".join(t.columns) or "nothing"), 2)
    extra = [c for c in cols if c not in WAIVER_REQUIRED + WAIVER_OPTIONAL]
    if extra:
        die("%s: unknown column %s (want %s)" % (
            path, ", ".join(extra),
            ", ".join(WAIVER_REQUIRED + WAIVER_OPTIONAL)), 2)
    reqs = set(c.req for c in checks)
    out = []
    for n, r in enumerate(t.rows, 1):
        d = dict((c, v.strip()) for c, v in zip(cols, r))
        if not any(d.values()):
            continue
        where = "%s, waiver %d (%s)" % (path, n, d.get("req") or "no req")
        for c in WAIVER_REQUIRED:
            if not d.get(c):
                die("%s: %s is blank" % (where, c), 2)
        if d["req"] not in reqs:
            die("%s: no check has req %s, so it would waive nothing" % (
                where, d["req"]), 2)
        if d.get("expires") and _date(d["expires"]) is None:
            die("%s: expires %r is not a date (YYYY-MM-DD)" % (
                where, d["expires"]), 2)
        expect = (d.get("expect") or "").lower()
        if expect not in ("", "fail"):
            die("%s: expect %r: the only expectation is fail" % (
                where, d["expect"]), 2)
        if d.get("where"):
            try:
                query.parse(d["where"])
            except QdError as exc:
                die("%s: where %r: %s" % (where, d["where"], exc), 2)
        out.append(Waiver(n, d["req"], d["justification"],
                          d.get("expires", ""), d.get("where", ""), expect,
                          d.get("granted_by", "")))
    if not out:
        die("%s holds no waivers" % path, 2)
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
    if op in ("between", "within"):
        return lim <= v <= lim2
    raise ValueError(op)


def limits(scale, chk):
    """(limit, limit2) as numbers on the scale the cells are read on."""
    if chk.op == "between":
        return scale.limit(chk.limit, chk), scale.limit(chk.limit2, chk)
    if chk.op == "within":
        return scale.limit(chk.lo, chk), scale.limit(chk.hi, chk)
    return scale.limit(chk.limit, chk), None


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
    numeric_op = chk.op in ("<", "<=", ">", ">=", "between", "within") or (
        chk.op in ("==", "!=") and split_unit(chk.limit)[0] is not None)
    if numeric_op:
        if num is None:
            if chk.op in ("==", "!="):
                ok = _text_ok(chk.op, cell, chk)
                return cell.strip(), PASS if ok else FAIL
            return cell.strip(), UNMEASURED
        lim, lim2 = limits(scale, chk)
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
        self.src = []              # the table rows self.rows are of
        self.waivers = []          # the waivers that excused something
        self.expired = []          # expired waivers that would have
        self.row_waiver = {}       # index in self.rows -> its Waiver


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
        res = Result(chk, "", PASS, measured, len(per), unit, chk_note, per)
        res.src = list(rows)
        res.nums = nums
        res.scale = scale
        return _each_verdict(res)
    vals = [n for n in nums if n is not None]
    if not vals:
        return Result(chk, "", UNMEASURED, 0, len(per), unit,
                      "nothing numeric to take the %s of" % chk.agg, per)
    agg = stats.AGGS[chk.agg]([repr(v) for v in vals])
    lim, lim2 = limits(scale, chk)
    ok = compare(chk.op, agg, lim, lim2)
    if measured < len(per):
        blank = [p[0] for p in per if p[2] == UNMEASURED]
        return Result(chk, scale.show(agg), UNMEASURED, measured,
                      len(per), unit, "%s over %d of %d (%s would %s); not "
                      "measured: %s" % (chk.agg, measured, len(per), chk.agg,
                                        "pass" if ok else "fail",
                                        ", ".join(blank[:5])) +
                      ("; " + chk_note if chk_note else ""), per)
    res = Result(chk, scale.show(agg), PASS if ok else FAIL, measured,
                 len(per), unit, chk_note, per)
    res.src = list(rows)
    return res


def _names(rows):
    return ", ".join(p[0] for p in rows[:5]) + (", ..." if len(rows) > 5
                                               else "")


def _each_verdict(res):
    """The verdict, the value shown and the note of an `each` check, from
    its rows' verdicts (some of which a waiver may have made waived)."""
    chk, per = res.chk, res.rows
    chk_note = res.note
    measured = res.measured
    fails = [p for p in per if p[2] == FAIL]
    waived = [p for p in per if p[2] == WAIVED]
    if fails:
        verdict = FAIL
    elif measured < len(per):
        verdict = UNMEASURED
    elif waived:
        verdict = WAIVED
    else:
        verdict = PASS
    # the worst row is the one shown: a failure, else a blank, else a
    # waived failure, else the one nearest the limit
    if fails:
        shown = fails[0][1]
        note = "%d of %d failed: %s" % (len(fails), len(per),
                                        _names(fails))
        if measured < len(per):
            note += "; %d not measured" % (len(per) - measured)
    elif measured < len(per):
        shown = ""
        blank = [p for p in per if p[2] == UNMEASURED]
        note = "%d of %d not measured: %s" % (
            len(blank), len(per), _names(blank))
    elif waived:
        shown = waived[0][1]
        note = ""
    else:
        shown = _nearest(chk, per, res.nums, res.scale)
        note = ""
    if waived:
        note = "; ".join(x for x in (note, "%d of %d failed under a "
                                     "waiver: %s" % (
                                         len(waived), len(per),
                                         _names(waived))) if x)
    res.observed = shown
    res.verdict = verdict
    res.note = "; ".join(x for x in (note, chk_note) if x)
    return res


def _nearest(chk, per, nums, scale):
    """The measured value closest to failing, for an all-pass `each`."""
    pairs = [(n, p[1]) for n, p in zip(nums, per) if n is not None]
    if not pairs:
        return per[0][1] if per else ""
    if chk.op in ("<", "<="):
        return max(pairs, key=lambda x: x[0])[1]
    if chk.op in (">", ">="):
        return min(pairs, key=lambda x: x[0])[1]
    if chk.range_op():
        lo, hi = limits(scale, chk)
        return min(pairs, key=lambda x: min(x[0] - lo, hi - x[0]))[1]
    return pairs[0][1]


def run(table, checks, waivers=None, today=None):
    out = [run_check(table, c) for c in checks]
    if waivers:
        for r in out:
            mine = [w for w in waivers if w.req == r.chk.req]
            if mine:
                apply_waivers(table, r, mine, today)
    return out


def _covered(table, w, rows):
    """The ids of `rows` a waiver's where picks (every one, with no
    where); None when its where cannot be read against this table."""
    if not w.where:
        return set(id(r) for r in rows)
    try:
        return set(id(r) for r in query.where(table, [w.where]))
    except QdError:
        return None


def apply_waivers(table, res, waivers, today=None):
    """Excuse a measured failure of res under its active waivers.  Not
    measured is never waived; an expired waiver does nothing but is
    named; `expect fail` with nothing to excuse is an unexpected pass."""
    live = [w for w in waivers if not w.expired(today)]
    dead = [w for w in waivers if w.expired(today)]
    notes = []
    if res.verdict == UNMEASURED or not res.src:
        if live and res.verdict == UNMEASURED:
            notes.append("not measured: a waiver excuses only a measured "
                         "failure")
        res.note = "; ".join(x for x in [res.note] + notes if x)
        return res
    cover = []
    for w in live:
        c = _covered(table, w, res.src)
        if c is None:
            notes.append("waiver %d: where %s cannot be read here" % (
                w.line, w.where))
            continue
        cover.append((w, c))
    if res.chk.agg == "each":
        used = []
        per = list(res.rows)
        for i, (p, r) in enumerate(zip(per, res.src)):
            if p[2] != FAIL:
                continue
            for w, c in cover:
                if id(r) in c:
                    per[i] = (p[0], p[1], WAIVED)
                    res.row_waiver[i] = w
                    if w not in used:
                        used.append(w)
                    break
        if used:
            res.rows = per
            res.waivers = used
            # the note is rebuilt from the rows, without the parts the
            # rows gave it before
            res.note = _keep_unit_note(res.note)
            _each_verdict(res)
    else:
        whole = set(id(r) for r in res.src)
        if res.verdict == FAIL:
            for w, c in cover:
                if whole <= c:
                    res.verdict = WAIVED
                    res.waivers = [w]
                    notes.append("failed under a waiver")
                    break
            else:
                if cover:
                    notes.append("a waiver's where does not cover every "
                                 "row of this %s: not waived" % res.chk.agg)
    if res.verdict == PASS:
        for w, c in cover:
            if w.expect == "fail" and (res.chk.agg == "each" or
                                       set(id(r) for r in res.src) <= c):
                res.verdict = UNEXPECTED
                res.waivers = [w]
                notes.append("expected to fail under a waiver, and passed")
                break
    if dead and res.verdict in (FAIL, PASS):
        failed_rows = [i for i, p in enumerate(res.rows) if p[2] == FAIL]
        hit = []
        for w in dead:
            c = _covered(table, w, res.src) or set()
            if res.chk.agg == "each":
                if any(id(res.src[i]) in c for i in failed_rows):
                    hit.append(w)
            elif res.verdict == FAIL:
                hit.append(w)
        for w in hit:
            notes.append("waiver expired %s: not applied" % w.expires)
        res.expired = hit
        if res.chk.agg == "each":
            for i in failed_rows:
                for w in hit:
                    c = _covered(table, w, res.src) or set()
                    if id(res.src[i]) in c:
                        res.row_waiver[i] = w
                        break
    res.note = "; ".join(x for x in [res.note] + notes if x)
    return res


def _keep_unit_note(note):
    """The part of an `each` note that is not about its rows: the unit
    remark, which _each_verdict keeps."""
    for part in note.split("; "):
        if part.startswith("the column carries no unit"):
            return part
    return ""


SUMMARY_COLUMNS = ["req", "column", "agg", "where", "observed", "limit",
                   "unit", "measured", "verdict", "note"]
EACH_COLUMNS = ["req", "row", "column", "observed", "limit", "unit",
                "verdict"]
SEVERITY_COLUMNS = ["severity"]
WAIVER_COLUMNS = ["justification", "expires", "granted_by"]


def columns(base, checks, waivers):
    """A verdict table's header: the columns of old, then severity when
    the thresholds file has one, then the waiver's when there are
    waivers.  With neither it is what it always was."""
    out = list(base)
    if any(c.severity for c in checks):
        out += SEVERITY_COLUMNS
    if waivers is not None:
        out += WAIVER_COLUMNS
    return out


def _waiver_cells(ws, today=None):
    if not ws:
        return ["", "", ""]
    return ["; ".join(w.justification for w in ws),
            "; ".join(w.expires_text(today) for w in ws),
            "; ".join(w.granted_by for w in ws if w.granted_by)]


def _extra(r, cols, ws, today=None):
    out = []
    if "severity" in cols:
        out.append(r.chk.severity)
    if "justification" in cols:
        out += _waiver_cells(ws, today)
    return out


def summary_rows(results, cols=None, today=None):
    cols = cols or SUMMARY_COLUMNS
    out = []
    for r in results:
        c = r.chk
        out.append([c.req, c.column, c.agg, c.where, r.observed,
                    c.limit_text(), r.unit,
                    "%d/%d" % (r.measured, r.total), r.verdict,
                    "; ".join(x for x in (r.note, c.note) if x)] +
                   _extra(r, cols, r.waivers or r.expired, today))
    return out


def each_rows(results, cols=None, today=None):
    cols = cols or EACH_COLUMNS
    out = []
    for r in results:
        c = r.chk
        if not r.rows:
            out.append([c.req, "", c.column, "", c.limit_text(), r.unit,
                        r.verdict] + _extra(r, cols, r.waivers or r.expired,
                                            today))
        whole = r.verdict in (WAIVED, UNEXPECTED) and c.agg != "each"
        for i, (label, obs, v) in enumerate(r.rows):
            w = r.row_waiver.get(i)
            if c.agg == "each" and r.verdict == UNEXPECTED:
                ws = r.waivers
            elif whole:
                ws = r.waivers
            else:
                ws = [w] if w else []
            out.append([c.req, label, c.column, obs, c.limit_text(), r.unit,
                        v] + _extra(r, cols, ws, today))
    return out


def counts(results):
    out = dict((v, 0) for v in VERDICTS)
    for r in results:
        out[r.verdict] += 1
    return out


def counts_text(n, waivers=False):
    """`3 pass, 1 fail, 0 not measured`, and the waived and unexpected
    passes when there are waivers to give them."""
    text = "%d pass, %d fail, %d not measured" % (
        n.get(PASS, 0), n.get(FAIL, 0), n.get(UNMEASURED, 0))
    if waivers or n.get(WAIVED):
        text += ", %d waived" % n.get(WAIVED, 0)
    if n.get(UNEXPECTED):
        text += ", %d unexpected pass" % n[UNEXPECTED]
    return text


def rank(severity):
    """Where a severity stands; blank stands above them all, so a check
    with no severity is never let off by --fail-level."""
    if not severity:
        return len(SEVERITIES)
    return SEVERITIES.index(severity)


def failing(results, level="info"):
    """(the results that fail the run, the failures let off by the fail
    level).  Not measured always fails it: --fail-level is about
    failures, and blank is never a pass."""
    hard, soft = [], []
    for r in results:
        if r.verdict == UNMEASURED:
            hard.append(r)
        elif r.verdict in (FAIL, UNEXPECTED):
            (hard if rank(r.chk.severity) >= rank(level) else soft).append(r)
    return hard, soft
