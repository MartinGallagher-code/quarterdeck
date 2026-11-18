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

A limit can be relative to a baseline (QD-033): `baseline`, `baseline-5%`,
`baseline+2`, `baseline-2ms`, held against an earlier run or a qualified
baseline given with `qd check --baseline RUN|NAME`.  Under `each` every
host is held to its own value in the baseline; a host the baseline lacks
is not measured.  Against a qualified baseline of three runs or more, and
three values or more for a host in the run, the Mann-Whitney U test with
Holm's adjustment (as `qd compare --baseline NAME` makes it) must also
find the difference significant before a crossed limit fails.

`cv`, `skew`, `kurtosis` and `zmax` (QD-050) are unitless figures of the
rows' spread and shape (stats.shape); zmax is qd outliers' robust z.  A
limit on one takes no unit, and one that cannot be had is not measured.
"""

import datetime
import re

from . import query, stats
from .common import QdError, die
from .table import load_file, slug, split_unit, to_base, unit_family

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
# spread and shape (QD-050): unitless, so a limit on them takes no unit
SHAPE_AGGS = ("cv", "skew", "kurtosis", "zmax")
NUMERIC_AGGS = ("mean", "median", "min", "max", "sum", "stdev", "range",
                "p05", "p25", "p75", "p95", "p99") + SHAPE_AGGS
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


REL_RE = re.compile(r"^baseline\s*(?:([+-])\s*(.*))?$", re.I)
REL_TEXT = "baseline, baseline+N, baseline-N or baseline-N%"


def parse_relative(text):
    """A limit relative to the baseline: (sign, amount, is_percent, unit)
    for `baseline-5%`, `baseline+2ms`, `baseline` (no offset); None when
    the text is not relative at all; a string saying why when it starts
    `baseline` but cannot be read."""
    m = REL_RE.match((text or "").strip())
    if not m:
        return None
    if not m.group(1):
        return (1, 0.0, False, "")
    part = _tol_part(m.group(2).replace(" ", ""))
    if part is None:
        return "a limit relative to the baseline is %s, not %r" % (REL_TEXT,
                                                                   text)
    return (1 if m.group(1) == "+" else -1,) + part


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
        # a limit relative to the baseline (QD-033): limit, and limit2 of
        # a between; never for the words of in, == and !=
        self.rel = self.rel2 = None
        if op in ("<", "<=", ">", ">=", "between", "within"):
            r = parse_relative(limit)
            self.rel = r if isinstance(r, tuple) else None
        if op == "between":
            r = parse_relative(limit2)
            self.rel2 = r if isinstance(r, tuple) else None
        self.relative = self.rel is not None or self.rel2 is not None
        if op == "within" and self.rel is not None:
            t = parse_tolerance(limit2)
            self.tol_shown = t[2] if t else ""
        elif op == "within":
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
        rel = {}
        for k in ("limit", "limit2"):
            rel[k] = parse_relative(d.get(k, "")) if op in (
                "<", "<=", ">", ">=", "between", "within") else None
            if isinstance(rel[k], str) and (k == "limit" or
                                            op == "between"):
                die("%s: %s" % (where, rel[k]), 2)
        if op == "within" and rel["limit"] is not None:
            if parse_tolerance(d.get("limit2", "")) is None:
                die("%s: within needs a tolerance in limit2 (+-10%%, "
                    "-5%%,+10%% or +-3), not %r" % (where,
                                                     d.get("limit2", "")), 2)
        elif op == "within":
            b = _within_bounds(d["limit"], d.get("limit2", ""),
                               d.get("unit", ""))
            if isinstance(b, str):
                die("%s: %s" % (where, b), 2)
        if op == "between":
            if not d.get("limit2"):
                die("%s: between needs limit2" % where, 2)
            for k in ("limit", "limit2"):
                if rel[k] is None and split_unit(d[k])[0] is None:
                    die("%s: between needs numbers, not %r" % (where, d[k]),
                        2)
        elif op in ("<", "<=", ">", ">=") and rel["limit"] is None and \
                split_unit(d["limit"])[0] is None:
            die("%s: %s needs a number or %s, not %r" % (
                where, op, REL_TEXT, d["limit"]), 2)
        if agg != "each" and op in ("in",):
            die("%s: %s over hosts gives a number; `in` wants words"
                % (where, agg), 2)
        if agg in SHAPE_AGGS:
            unit = _unit_on_shape(d, op, rel)
            if unit:
                die("%s: %s is unitless, so its limit takes no unit (%s)"
                    % (where, agg, unit), 2)
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


def _unit_on_shape(d, op, rel):
    """What gives a unit to a limit on cv, skew, kurtosis or zmax, or "".
    A percentage of the baseline, or a within tolerance in percent, is
    not a unit: it is a share of the figure."""
    if d.get("unit"):
        return "unit %s" % d["unit"]
    for k in ("limit", "limit2"):
        text = d.get(k, "")
        if k == "limit2" and op != "between":
            if op == "within":
                tol = parse_tolerance(text) or ()
                if any(part[2] for part in tol[:2]):
                    return "limit2 %s" % text
            continue
        r = rel.get(k)
        if isinstance(r, tuple):
            if r[3]:
                return "%s %s" % (k, text)
        elif split_unit(text)[1]:
            return "%s %s" % (k, text)
    return ""


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


def run_check(table, chk, ref=None):
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
    if chk.relative:
        return run_relative(table, chk, rows, ref)
    if chk.agg in SHAPE_AGGS:
        return run_shape(table, chk, rows)
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
    elif getattr(res, "margins", None) is not None:
        shown = _closest(per, res.margins)
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


def _closest(per, margins):
    """The row nearest its own limit, for an all-pass relative `each`."""
    pairs = [(m, p[1]) for m, p in zip(margins, per) if m is not None]
    if not pairs:
        return per[0][1] if per else ""
    return min(pairs, key=lambda x: x[0])[1]


# ---------------------------------------------------------------------------
# Spread and shape over the rows (QD-050)
# ---------------------------------------------------------------------------

class _Plain(object):
    """The footing of a unitless figure: numbers as they are, an offset
    from the baseline in no unit at all."""
    own = ""

    def amount(self, amount, unit):
        return None if unit else amount

    def show(self, v):
        return stats.fmt_num(v)


def _shape_of(sub, col, agg):
    """(figure, why not, a note, {row index: robust z}) over the table
    `sub`.  zmax is taken by qd outliers' own reading: outliers() with
    its default per (each host's median when hosts repeat), so the two
    agree on the worst host and its score."""
    nums = sub.numbers(col)
    if agg != "zmax":
        fig, why = stats.shape(agg, [v for v in nums if v is not None])
        return fig, why, "", {}
    per = stats.default_per(sub, col)
    hits, info = stats.outliers(sub, col, per, z=0.0)
    need = dict(stats.SHAPE_MIN)["zmax"]
    who = "hosts" if per else "values"
    if info["n"] < need:
        return None, "zmax wants %d %s or more, and has %d" % (
            need, who, info["n"]), "", {}
    if not info["mad"]:
        return None, "the MAD is 0 (most %s are the same), so there is no " \
            "robust z; qd outliers lists every one that differs" % who, \
            "", {}
    med, mad = info["median"], info["mad"]
    by = {}
    if per:
        ki = sub.index(per)
        for r, v in zip(sub.rows, nums):
            if v is not None:
                by.setdefault(r[ki], []).append(v)
        by = dict((k, stats.quantile(sorted(xs), .5)) for k, xs in
                  by.items())
    zs = {}
    for i, (r, v) in enumerate(zip(sub.rows, nums)):
        if v is None:
            continue
        x = by[r[sub.index(per)]] if per else v
        zs[i] = stats.robust_z(x, med, mad)
    if not hits:
        return 0.0, "", "no value off the median %s" % stats.fmt_num(med), zs
    key, _, _, _, score, _ = hits[0]
    note = "worst |z|: %s (robust z %s; median %s, MAD %s%s)" % (
        key, stats.outlier_cells([hits[0]])[0][3], stats.fmt_num(med),
        stats.fmt_num(mad), ", per %s" % per if per else "")
    return abs(score), "", note, zs


def _plain_limits(chk):
    num = lambda t: split_unit(t)[0]
    if chk.op == "between":
        return num(chk.limit), num(chk.limit2)
    if chk.op == "within":
        return num(chk.lo), num(chk.hi)
    return num(chk.limit), None


def run_shape(table, chk, rows, ref=None, side=None):
    """A cv, skew, kurtosis or zmax check.  They are unitless: the cells
    are read on one scale, as qd outliers reads them, and the figure is
    shown as it is.  With ref and side (the run's numbers on the
    baseline's footing, the baseline's column, rows and key), the limit
    is relative to the same figure over the baseline's rows of the same
    hosts."""
    from .compare import pct
    sub = table.derive(rows=list(rows))
    col = sub.colname(chk.column)
    nums = sub.numbers(col)
    pos = dict((id(r), n) for n, r in enumerate(table.rows, 1))
    labels = [_label(table, r, pos[id(r)]) for r in rows]
    cells = [r[table.index(chk.column)].strip() for r in rows]
    measured = sum(1 for v in nums if v is not None)
    blank = [lb for lb, v in zip(labels, nums) if v is None]
    fig, why, worst, zs = _shape_of(sub, col, chk.agg)
    foot = _Plain()
    notes, extra = [], {}
    lims = None
    if fig is not None and chk.relative:
        bnums, bcol, brows, kc = side
        # zmax over hosts that repeat is over each host's median, on
        # both sides, as qd outliers takes it
        bvals, notes, missing = _baseline_values(
            table, chk, rows, bnums, ref, bcol, brows, kc,
            chk.agg == "zmax" and stats.default_per(sub, col) is not None)
        bfig = None
        if missing:
            why = missing
        elif not bvals:
            why = "%s measured no %s" % (ref.describe(), chk.column)
        else:
            bfig, bwhy = stats.shape(chk.agg, bvals)
            if bfig is None:
                why = "in %s: %s" % (ref.describe(), bwhy)
        if bfig is not None:
            lims = resolve(chk, bfig, foot)
            if lims is None:
                why = "the limit's unit does not fit %s" % chk.agg
            else:
                extra = dict(base_shown=foot.show(bfig),
                             drift=_pct_text(pct(bfig, fig)),
                             limit_shown=_resolved_text(chk, lims, foot))
        if ref.bl is None:
            notes.append(_how(ref, 0, 0))
        if why:
            fig = None
    elif fig is not None:
        lims = _plain_limits(chk)

    def obs_of(i):
        if chk.agg == "zmax" and i in zs and fig is not None:
            return stats.fmt_num(zs[i])
        return cells[i]

    if fig is None:
        per = [(lb, obs_of(i), UNMEASURED) for i, lb in enumerate(labels)]
        note = why + ("; not measured: %s" % ", ".join(blank[:5])
                      if blank else "")
        res = Result(chk, "", UNMEASURED, measured, len(per), "",
                     "; ".join(x for x in [note] + notes if x), per)
        for k, v in extra.items():
            setattr(res, k, v)
        return res
    ok = compare(chk.op, fig, lims[0], lims[1])
    per = []
    for i, (lb, v) in enumerate(zip(labels, nums)):
        if v is None:
            per.append((lb, cells[i], UNMEASURED))
        elif chk.agg == "zmax":
            per.append((lb, obs_of(i), PASS if compare(
                chk.op, abs(zs[i]), lims[0], lims[1]) else FAIL))
        else:
            per.append((lb, cells[i], PASS if ok else FAIL))
    if measured < len(per):
        res = Result(chk, foot.show(fig), UNMEASURED, measured, len(per), "",
                     "%s over %d of %d (%s would %s); not measured: %s" % (
                         chk.agg, measured, len(per), chk.agg,
                         "pass" if ok else "fail", ", ".join(blank[:5])),
                     per)
    else:
        res = Result(chk, foot.show(fig), PASS if ok else FAIL, measured,
                     len(per), "", "", per)
        res.src = list(rows)
    res.note = "; ".join(x for x in [res.note, worst] + notes if x)
    for k, v in extra.items():
        setattr(res, k, v)
    return res


def run(table, checks, waivers=None, today=None, ref=None):
    """Every check's Result.  ref (a Reference) is what limits relative to
    the baseline are held to; without one they are not measured."""
    out = [run_check(table, c, ref) for c in checks]
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


# ---------------------------------------------------------------------------
# Limits relative to a baseline (QD-033)
# ---------------------------------------------------------------------------

ALPHA = 0.05


class Reference(object):
    """What a relative limit is held to: an earlier run's table (narrowed
    by the command's own --where, as the run is) or a qualified baseline
    from `qd baseline set`, whose every key holds one value per run."""

    def __init__(self, label, table=None, bl=None):
        self.label = label
        self.table = table
        self.bl = bl

    def runs(self):
        return len(self.bl.runs) if self.bl is not None else 1

    def describe(self):
        if self.bl is not None:
            return "baseline %s (%d run%s)" % (
                self.label, self.runs(), "" if self.runs() == 1 else "s")
        return "run %s" % self.label


def _written_unit(cells):
    """The commonest unit written in a column's cells, or ""."""
    count = {}
    for c in cells:
        u = split_unit(c)[1]
        if u:
            count[u] = count.get(u, 0) + 1
    if not count:
        return ""
    return sorted(count, key=lambda u: (-count[u], u))[0]


class _Footing(object):
    """How a relative check reads its numbers: both sides as qd's
    baselines keep them (sizes in bytes, times in seconds, anything else
    as written), and an offset or a figure shown in the check's own
    unit."""

    def __init__(self, chk, cells, common):
        self.based = common in ("B", "s")
        self.family = {"B": "size", "s": "time"}.get(common)
        # the check's unit, else its offset's, else the cells' commonest
        given = [r[3] for r in (chk.rel, chk.rel2) if r and r[3] and (
            not self.based or unit_family(r[3]) == self.family)]
        self.own = chk.unit or (given[0] if given else "") or \
            _written_unit(cells)
        self.problem = ""

    def amount(self, amount, unit):
        """An offset or a bound as a number on this footing; None when its
        unit does not fit the column's."""
        u = unit or self.own
        if self.based:
            if unit_family(u) == self.family:
                return to_base("%r%s" % (amount, u))[0]
            if u:
                return None
            return amount
        if not unit or _units_match(unit, self.own):
            return amount
        if self.own and unit_family(unit) and \
                unit_family(unit) == unit_family(self.own):
            return to_base("%r%s" % (amount, unit))[0] / \
                to_base("1" + self.own)[0]
        return None

    def show(self, v):
        if v is None:
            return ""
        if self.based and unit_family(self.own):
            f = to_base("1" + self.own)[0]
            if f:
                v = v / f
        return stats.fmt_num(v)


def _bound(rel, ref, foot):
    sign, amount, pct, unit = rel
    if pct:
        return ref + sign * abs(ref) * amount / 100.0
    d = foot.amount(amount, unit)
    return None if d is None else ref + sign * d


def resolve(chk, ref, foot):
    """(limit, limit2) as numbers, given the baseline's value; None when
    a unit does not fit."""
    if chk.op == "within" and chk.rel is not None:
        tol = parse_tolerance(chk.limit2)
        out = []
        for sign, (amount, pct, unit) in ((-1, tol[0]), (1, tol[1])):
            if pct:
                d = abs(ref) * amount / 100.0
            else:
                d = foot.amount(amount, unit)
                if d is None:
                    return None
            out.append(ref + sign * d)
        return out[0], out[1]
    sides = []
    for i, (rel, text) in enumerate(((chk.rel, chk.limit),
                                     (chk.rel2, chk.limit2))):
        if i == 1 and chk.op != "between":
            sides.append(None)
            continue
        if rel is not None:
            v = _bound(rel, ref, foot)
        else:
            n, u = split_unit(text)
            v = None if n is None else foot.amount(n, u or chk.unit)
        if v is None:
            return None
        sides.append(v)
    return sides[0], sides[1]


def _margin(op, v, lim, lim2):
    if op in ("<", "<="):
        return lim - v
    if op in (">", ">="):
        return v - lim
    return min(v - lim, lim2 - v)


def _key_columns(table, ref):
    """The columns a run's rows are matched to the baseline's on, or a
    string saying why they cannot be."""
    from .diff import SECONDARY
    if ref.bl is not None:
        miss = [k for k in ref.bl.key if not table.has(k)]
        if miss:
            return "the baseline %s matches rows on %s, and this has no %s" \
                % (ref.label, ",".join(ref.bl.key), ", ".join(miss))
        return [table.colname(k) for k in ref.bl.key]
    b = ref.table
    if table.is_results() and b.is_results():
        from .diff import auto_key
        return auto_key(table, b)
    for primary in ("host", "ssh_host", "target", "name", "src"):
        if table.has(primary, prefix=False) and b.has(primary, prefix=False):
            return [primary] + [c for c in SECONDARY if c != primary and
                                table.has(c, prefix=False) and
                                b.has(c, prefix=False)]
    return "no host column the run and %s share to match rows on" % (
        ref.describe())


def _keyed(table, rows, kc, nums):
    """[(key, [rows], [numbers])] in first-seen order; a row with every
    key cell blank is nobody's."""
    ki = [table.index(k) for k in kc]
    order, by = [], {}
    for r, v in zip(rows, nums):
        k = tuple(r[i].strip() for i in ki)
        if not any(k):
            continue
        if k not in by:
            by[k] = ([], [])
            order.append(k)
        by[k][0].append(r)
        if v is not None:
            by[k][1].append(v)
    return [(k, by[k][0], by[k][1]) for k in order]


def _ref_side(chk, ref, run_unit):
    """(column in the baseline, its numbers' unit, its rows or None, a
    problem)."""
    from . import baseline as blmod
    if ref.bl is not None:
        bl = ref.bl
        name = None
        for c in bl.columns:
            if c == chk.column or slug(c) == slug(chk.column):
                name = c
        if name is None:
            return None, "", None, "the baseline %s holds %s, not %s" % (
                ref.label, ", ".join(bl.columns), chk.column)
        u = bl.units.get(name, "")
        return name, u, None, ""
    b = ref.table
    if not b.has(chk.column):
        return None, "", None, "%s has no column %s" % (ref.describe(),
                                                         chk.column)
    rows = b.rows
    if chk.where:
        try:
            rows = query.where(b, [chk.where])
        except QdError as exc:
            return None, "", None, "where %s in %s: %s" % (
                chk.where, ref.describe(), exc)
    nums, u = blmod.base_numbers(b.values(chk.column))
    pos = dict((id(r), n) for n, r in enumerate(b.rows))
    return b.colname(chk.column), u, [(r, nums[pos[id(r)]]) for r in rows], \
        ""


def run_relative(table, chk, rows, ref):
    """A check whose limit is relative to the baseline."""
    from . import baseline as blmod
    from .compare import pct
    if ref is None:
        return Result(chk, total=len(rows), note="the limit is relative to "
                      "a baseline: give one with --baseline RUN|NAME")
    allnums, unit = blmod.base_numbers(table.values(chk.column))
    pos = dict((id(r), n) for n, r in enumerate(table.rows))
    nums = [allnums[pos[id(r)]] for r in rows]
    foot = _Footing(chk, table.values(chk.column), unit)
    col, bunit, brows, problem = _ref_side(chk, ref, unit)
    if not problem and unit and bunit and unit != bunit:
        problem = "%s is in %s here and in %s in %s" % (
            chk.column, unit, bunit, ref.describe())
    if problem:
        return Result(chk, total=len(rows), note=problem)
    kc = _key_columns(table, ref)
    if isinstance(kc, str) and (chk.agg == "each" or ref.bl is not None):
        return Result(chk, total=len(rows), note=kc)
    if chk.agg == "each":
        return _relative_each(table, chk, rows, nums, ref, col, brows, kc,
                              foot, pct)
    if chk.agg in SHAPE_AGGS:
        return run_shape(table, chk, rows, ref, (nums, col, brows, kc))
    return _relative_agg(table, chk, rows, nums, ref, col, brows, kc, foot,
                         pct)


def _ref_by_key(ref, col, brows, kc):
    """{key: [the baseline's values]}: a run's rows of a key reduced to
    their median, as compare reduces them; a qualified baseline's one
    value per run."""
    from . import baseline as blmod
    if ref.bl is not None:
        return dict((k, xs) for (c, k), xs in ref.bl.keys.items()
                    if c == col and xs)
    b = ref.table
    got = _keyed(b, [r for r, _ in brows], kc, [v for _, v in brows])
    return dict((k, [blmod.reduce(xs, "median")]) for k, _, xs in got
                if xs)


def _relative_each(table, chk, rows, nums, ref, col, brows, kc, foot, pct):
    from . import baseline as blmod
    base = _ref_by_key(ref, col, brows, kc)
    keyed = _keyed(table, rows, kc, nums)
    per, src, margins, extra, tests = [], [], [], [], []
    unknown, problem = [], ""
    for k, krows, xs in keyed:
        label = ",".join(x for x in k if x) or _label(table, krows[0], 0)
        src.append(krows[0])
        if not xs:
            per.append((label, "", UNMEASURED))
            margins.append(None)
            extra.append(("", "", ""))
            continue
        v = blmod.reduce(xs, "median")
        refs = base.get(k)
        if not refs:
            unknown.append(label)
            per.append((label, foot.show(v), UNMEASURED))
            margins.append(None)
            extra.append(("not in the baseline", "", ""))
            continue
        bmed = blmod.median(refs)
        lims = resolve(chk, bmed, foot)
        if lims is None:
            problem = "the limit's unit does not fit %s's" % chk.column
            break
        ok = compare(chk.op, v, lims[0], lims[1])
        per.append((label, foot.show(v), PASS if ok else FAIL))
        margins.append(_margin(chk.op, v, lims[0], lims[1]))
        d = pct(bmed, v)
        extra.append((_resolved_text(chk, lims, foot), foot.show(bmed),
                      _pct_text(d)))
        if ref.bl is not None and len(refs) >= blmod.MIN_RUNS and \
                len(xs) >= blmod.MIN_RUNS:
            from .stats import mann_whitney
            tests.append((len(per) - 1, mann_whitney(xs, refs)["p"]))
    if problem:
        return Result(chk, total=len(keyed), note=problem)
    notes = []
    if tests:
        from .stats import holm
        adj = holm([p for _, p in tests])
        kept = []
        for (i, _), p in zip(tests, adj):
            if per[i][2] == FAIL and p >= ALPHA:
                per[i] = (per[i][0], per[i][1], PASS)
                kept.append(per[i][0])
                margins[i] = 0.0
        if kept:
            notes.append("past the limit but not significant (Holm-adjusted "
                         "p %s or more): %s" % (stats.fmt_num(ALPHA),
                                                _names([(x,) for x in kept])))
    if unknown:
        notes.append("%d not in %s: %s" % (len(unknown), ref.describe(),
                                            _names([(x,) for x in unknown])))
    notes.append(_how(ref, len(tests), len(keyed)))
    measured = sum(1 for _, _, v in per if v != UNMEASURED)
    res = Result(chk, "", PASS, measured, len(per), foot.own, "", per)
    res.src = src
    res.margins = margins
    res.row_extra = extra
    _each_verdict(res)
    res.note = "; ".join(x for x in [res.note] + notes if x)
    res.base_note = "; ".join(notes)
    return res


def _baseline_values(table, chk, rows, nums, ref, col, brows, kc,
                     per_host=False):
    """(the baseline's values a figure over the run's rows is held to,
    notes, why not): the baseline's rows of the same hosts (each host's
    median of them, with per_host), or each host's median over a
    qualified baseline's runs.  `why not` is set when the baseline lacks
    some of the hosts."""
    from . import baseline as blmod
    notes = []
    if isinstance(kc, str):
        bvals = [v for _, v in brows if v is not None]
        notes.append("the baseline's rows are not matched host by host: "
                     + kc)
        return bvals, notes, ""
    keys = set(k for k, _, _ in _keyed(table, rows, kc, nums))
    base = _ref_by_key(ref, col, brows, kc)
    missing = sorted(",".join(k) for k in keys if k not in base)
    if missing:
        return [], notes, "%d not in %s, so the %s would be over other " \
            "hosts: %s" % (len(missing), ref.describe(), chk.agg,
                           _names([(x,) for x in missing]))
    if ref.bl is not None:
        bvals = [blmod.median(base[k]) for k in keys]
        notes.append("the %s of each host's median over the baseline's "
                     "runs; no rank test for a figure over hosts" % chk.agg)
    elif per_host:
        bvals = [base[k][0] for k in keys]
    else:
        bki = [ref.table.index(k) for k in kc]
        bvals = [v for r, v in brows if v is not None and
                 tuple(r[i].strip() for i in bki) in keys]
    return bvals, notes, ""


def _relative_agg(table, chk, rows, nums, ref, col, brows, kc, foot, pct):
    # each row's verdict is against the limit the aggregate is held to,
    # once that is known; until then none is measured
    per = [(_label(table, r, n), foot.show(v) if v is not None else "",
            UNMEASURED) for n, (r, v) in enumerate(zip(rows, nums), 1)]
    vals = [v for v in nums if v is not None]
    if not vals:
        return Result(chk, "", UNMEASURED, 0, len(per), foot.own,
                      "nothing numeric to take the %s of" % chk.agg, per)
    agg = stats.AGGS[chk.agg]([repr(v) for v in vals])
    bvals, notes, missing = _baseline_values(table, chk, rows, nums, ref,
                                             col, brows, kc)
    if missing:
        return Result(chk, foot.show(agg), UNMEASURED, len(vals), len(per),
                      foot.own, missing, per)
    if not bvals:
        return Result(chk, foot.show(agg), UNMEASURED, len(vals), len(per),
                      foot.own, "%s measured no %s" % (ref.describe(),
                                                       chk.column), per)
    bagg = stats.AGGS[chk.agg]([repr(v) for v in bvals])
    lims = resolve(chk, bagg, foot)
    if lims is None:
        return Result(chk, total=len(per), note="the limit's unit does not "
                      "fit %s's" % chk.column)
    ok = compare(chk.op, agg, lims[0], lims[1])
    per = [(p[0], p[1], p[2] if v is None else
            PASS if compare(chk.op, v, lims[0], lims[1]) else FAIL)
           for p, v in zip(per, nums)]
    measured = len(vals)
    if ref.bl is None:
        notes.append(_how(ref, 0, 0))
    if measured < len(per):
        blank = [p[0] for p in per if p[2] == UNMEASURED]
        res = Result(chk, foot.show(agg), UNMEASURED, measured, len(per),
                     foot.own, "%s over %d of %d (%s would %s); not "
                     "measured: %s" % (chk.agg, measured, len(per), chk.agg,
                                       "pass" if ok else "fail",
                                       ", ".join(blank[:5])), per)
    else:
        res = Result(chk, foot.show(agg), PASS if ok else FAIL, measured,
                     len(per), foot.own, "", per)
        res.src = list(rows)
    res.note = "; ".join(x for x in [res.note] + notes if x)
    res.base_shown = foot.show(bagg)
    res.drift = _pct_text(pct(bagg, agg))
    res.limit_shown = _resolved_text(chk, lims, foot)
    return res


def _how(ref, tested, keys):
    if ref.bl is None:
        return "against one run (%s): decided on medians, no rank test" % (
            ref.label)
    if tested == keys:
        return "against %s: the rank test decided each host" % (
            ref.describe())
    if tested:
        return "against %s: the rank test decided %d of %d hosts, medians " \
            "the rest (3 values a side wanted)" % (ref.describe(), tested,
                                                   keys)
    return "against %s: decided on medians (the rank test wants 3 values " \
        "a side, and the run has fewer per host)" % ref.describe()


def _resolved_text(chk, lims, foot):
    if chk.op in ("between", "within"):
        return "between %s and %s" % (foot.show(lims[0]),
                                      foot.show(lims[1]))
    return "%s %s" % (chk.op, foot.show(lims[0]))


def _pct_text(d):
    if d is None:
        return ""
    if d in (float("inf"), float("-inf")):
        return "from 0"
    return "%.1f" % d


SUMMARY_COLUMNS = ["req", "column", "agg", "where", "observed", "limit",
                   "unit", "measured", "verdict", "note"]
EACH_COLUMNS = ["req", "row", "column", "observed", "limit", "unit",
                "verdict"]
SEVERITY_COLUMNS = ["severity"]
WAIVER_COLUMNS = ["justification", "expires", "granted_by"]
BASELINE_COLUMNS = ["baseline", "drift_pct"]


def columns(base, checks, waivers, ref=None):
    """A verdict table's header: the columns of old, then severity when
    the thresholds file has one, then the waiver's when there are
    waivers, then the baseline's value and the drift from it when there
    is a baseline.  With none of them it is what it always was."""
    out = list(base)
    if any(c.severity for c in checks):
        out += SEVERITY_COLUMNS
    if waivers is not None:
        out += WAIVER_COLUMNS
    if ref is not None:
        out += BASELINE_COLUMNS
    return out


def _waiver_cells(ws, today=None):
    if not ws:
        return ["", "", ""]
    return ["; ".join(w.justification for w in ws),
            "; ".join(w.expires_text(today) for w in ws),
            "; ".join(w.granted_by for w in ws if w.granted_by)]


def _extra(r, cols, ws, today=None, base=("", "")):
    out = []
    if "severity" in cols:
        out.append(r.chk.severity)
    if "justification" in cols:
        out += _waiver_cells(ws, today)
    if "baseline" in cols:
        out += list(base)
    return out


def _summary_base(r):
    return (getattr(r, "base_shown", ""), getattr(r, "drift", ""))


def summary_rows(results, cols=None, today=None):
    cols = cols or SUMMARY_COLUMNS
    out = []
    for r in results:
        c = r.chk
        lim = c.limit_text()
        if getattr(r, "limit_shown", ""):
            lim += " (%s)" % r.limit_shown
        out.append([c.req, c.column, c.agg, c.where, r.observed,
                    lim, r.unit,
                    "%d/%d" % (r.measured, r.total), r.verdict,
                    "; ".join(x for x in (r.note, c.note) if x)] +
                   _extra(r, cols, r.waivers or r.expired, today,
                          _summary_base(r)))
    return out


def each_rows(results, cols=None, today=None):
    cols = cols or EACH_COLUMNS
    out = []
    for r in results:
        c = r.chk
        if not r.rows:
            out.append([c.req, "", c.column, "", c.limit_text(), r.unit,
                        r.verdict] + _extra(r, cols, r.waivers or r.expired,
                                            today, _summary_base(r)))
        whole = r.verdict in (WAIVED, UNEXPECTED) and c.agg != "each"
        rx = getattr(r, "row_extra", None)
        for i, (label, obs, v) in enumerate(r.rows):
            w = r.row_waiver.get(i)
            if c.agg == "each" and r.verdict == UNEXPECTED:
                ws = r.waivers
            elif whole:
                ws = r.waivers
            else:
                ws = [w] if w else []
            lim, base = c.limit_text(), ("", "")
            if rx is not None:
                if rx[i][0]:
                    lim = "%s (%s)" % (lim, rx[i][0])
                base = (rx[i][1], rx[i][2])
            elif c.agg != "each" and c.relative:
                base = _summary_base(r)
                if getattr(r, "limit_shown", ""):
                    lim = "%s (%s)" % (lim, r.limit_shown)
            out.append([c.req, label, c.column, obs, lim, r.unit,
                        v] + _extra(r, cols, ws, today, base))
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
