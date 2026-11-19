# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Martin J. Gallagher
"""A study: the screen, its follow-up and every later round, as one.

A design belongs to a study by its config's `metadata.qd_study` -- what
`qd doe next` writes into a follow-up, and `qd doe run --like` sets --
and a design that names none is a study of its own name (a screen starts
one).  So the grouping is already filed with each design in `qd.designs`,
and a store written before studies existed reads as one study per design:
nothing new is filed, and `provost store check` has nothing new to see.

`qd compare --study STUDY` and qd web's study view line up every run of
every design of a study (QD-070): a row per run and host, the run's
responses (each one number from that host's rows: the median, or --agg),
and every factor as a column -- the level the point set where the design
varied it, the level the design held where it did not.  A factor every
design held at one level is said once, above the table, not repeated on
every row.  Blank is not measured: a host that failed a point has no
response there, and a factor a design neither varied nor held is blank.

The designs differ in their factors and points, which is the point of a
study; what joins them is the factor's name.  The chart of a response
against a factor is worked out here too, each design a series, with the
response's median at each level, so the page draws and never computes.
"""

from .common import die
from . import doe as doemod, stats, table as tablemod

LEAD = ["design", "point", "host"]
TAIL = ["status", "run"]
NOT_AGGS = ("distinct", "first", "last", "top", "worst", "auto", "count")


def studies(st):
    """[(study, [design, ...])], in the order their first design was
    filed; a design is in the study its config names, else its own."""
    order, by = [], {}
    for name in doemod.names(st):
        _, cfg, _ = doemod.load(st, name)
        s = doemod.study_of(cfg, name)
        if s not in by:
            by[s] = []
            order.append(s)
        by[s].append(name)
    return [(s, by[s]) for s in order]


def members(st, study):
    """The designs of a study, in the order they were filed; [] when no
    design is in it."""
    for s, names in studies(st):
        if s == study:
            return names
    return []


def study_or_die(st, study):
    names = members(st, study)
    if names:
        return names
    all_ = studies(st)
    for s, ns in all_:
        if study in ns:
            die("%s is a design of the study %s: name the study (its "
                "designs: %s)" % (study, s, ", ".join(ns)))
    die("no study %r in the store %s%s" % (
        study, st.shown(), (" (studies: %s)" % ", ".join(s for s, _ in all_))
        if all_ else " -- a study is a screen and the designs `qd doe "
        "next` makes from it"))


class Design(object):
    def __init__(self, st, name):
        self.name = name
        self.row, self.cfg, self.matrix = doemod.load(st, name)
        self.points = doemod.points(self.matrix)
        self.varied = list(self.matrix.get("factor_names") or [])
        self.held = doemod.fixed_of(self.cfg)
        self.operation = self.matrix.get("operation") or \
            (self.cfg.get("settings") or {}).get("operation") or ""
        meta = self.cfg.get("metadata") or {}
        fol = meta.get("qd_follows") if isinstance(meta, dict) else None
        self.follows = fol if isinstance(fol, dict) else {}
        self.runs = doemod.point_runs(st, name)
        self.measured = sum(1 for rid, _, _ in self.points
                            if doemod.answered(self.runs.get(rid, [])))

    def json(self):
        return {"name": self.name, "operation": self.operation,
                "varied": self.varied,
                "held": [[k, v] for k, v in self.held],
                "follows": self.follows.get("design") or "",
                "for": self.follows.get("response") or "",
                "points": len(self.points), "measured": self.measured,
                "runs": sum(len(rs) for rs in self.runs.values()),
                "command": self.row.get("command", "")}


class Study(object):
    def __init__(self):
        self.name = ""
        self.designs = []       # [Design]
        self.factors = []       # factor columns, in the table
        self.constant = []      # [(factor, level)]: every design held it so
        self.responses = []     # [(response name, column)]
        self.agg = "median"
        self.table = None       # a tablemod.Table: every run and host
        self.notes = []

    def json(self):
        return {"study": self.name, "agg": self.agg,
                "designs": [d.json() for d in self.designs],
                "factors": self.factors,
                "constant": [[k, v] for k, v in self.constant],
                "responses": [[n, c] for n, c in self.responses],
                "notes": self.notes}


def response_specs(designs, columns, required=True):
    """[(name, column)]: the -c columns (each a column, or a response by
    name of any design's config), else every response a design's config
    names a column for, in the order they first appear."""
    out, seen = [], {}
    for d in designs:
        for n, col, _ in doemod.specs(d.cfg, columns):
            if n in seen:
                if seen[n] != col and not columns:
                    die("the designs of the study read the response %s from "
                        "different columns (%s, %s): -c the one to compare"
                        % (n, seen[n], col))
                continue
            seen[n] = col
            out.append((n, col))
    if not out and required:
        die("which response? -c COLUMN (the configs of this study name "
            "none)")
    return out


def build(st, study, columns=None, agg="median", required=True):
    """Every run of every design of a study, as a Study (with no response
    columns, when not required and the configs name none)."""
    if agg in NOT_AGGS or agg not in stats.AGGS:
        die("a study reduces each host's rows to one number: --agg median, "
            "mean, min, max, sum, stdev, range or p05..p99 (not %s)" % agg)
    s = Study()
    s.name, s.agg = study, agg
    s.designs = [Design(st, n) for n in study_or_die(st, study)]
    s.responses = response_specs(s.designs, columns, required)
    # every factor any design varied or held, varied ones first
    names = []
    for d in s.designs:
        for f in d.varied:
            if f not in names:
                names.append(f)
    for d in s.designs:
        for f, _ in d.held:
            if f not in names:
                names.append(f)
    for f in names:
        levels = set()
        varied = False
        for d in s.designs:
            if f in d.varied:
                varied = True
                break
            levels.add(dict(d.held).get(f))
        if not varied and len(levels) == 1 and None not in levels:
            s.constant.append((f, levels.pop()))
        else:
            s.factors.append(f)
    rnames = [n for n, _ in s.responses]
    clash = [c for c in rnames + s.factors if c in LEAD + TAIL]
    clash += [n for n in rnames if n in s.factors]
    if clash:
        die("a study's table names its columns design, point, host, status, "
            "run, each factor and each response: %s is two of them"
            % clash[0])
    rows = []
    for d in s.designs:
        held = dict(d.held)
        for rid, _, levels in d.points:
            lv = dict(levels)
            fcells = [lv[f] if f in lv else held.get(f, "")
                      for f in s.factors]
            for e in d.runs.get(rid, []):
                for host, status, vals in run_cells(e, s.responses, agg):
                    rows.append([d.name, str(rid), host] +
                                [stats.fmt_num(v, 8) if v is not None
                                 else "" for v in vals] + fcells +
                                [status, e.id])
    s.table = tablemod.Table(LEAD + rnames + s.factors + TAIL, rows,
                             name=study, source="study %s" % study)
    unknown = [d.name for d in s.designs
               if any(f not in d.varied and f not in dict(d.held)
                      for f in s.factors)]
    if unknown:
        s.notes.append("blank factor cells: %s neither varied nor held "
                       "those factors" % ", ".join(unknown))
    return s


def run_cells(e, responses, agg):
    """[(host, its status, [one value per response or None])] for a run:
    every host the run had, each response the agg of that host's numbers
    on rows that are ok (on its family's base scale, as `qd doe analyze`
    reads them)."""
    t = e.load("data")
    hi = t.index("host") if t.has("host") else None
    si = t.index("status") if t.has("status") else None
    hosts = [(h.get("host", ""), h.get("status", ""))
             for h in e.store.host_rows(e.id) if h.get("host")]
    if not hosts:
        seen = []
        for r in t.rows:
            k = r[hi] if hi is not None else ""
            if k not in seen:
                seen.append(k)
        hosts = [(k, "") for k in seen]
    out = []
    for host, status in hosts:
        rows = [r for r in t.rows if hi is None or r[hi] == host]
        if not status and si is not None and rows:
            status = rows[0][si]
        vals = []
        for _, col in responses:
            cells = []
            if t.has(col):
                ci = t.index(col)
                for r in rows:
                    if si is not None and r[si] != "ok":
                        continue
                    v = tablemod.to_base(r[ci])[0]
                    if v is not None:
                        cells.append(repr(v))
            v = stats.AGGS[agg](cells) if cells else None
            vals.append(float(v) if v is not None else None)
        out.append((host, status, vals))
    return out


def chart(s, t, factor, response):
    """A response against a factor, each design a series: its points
    [x, level, value, run, point, host] (value None: not measured), and
    the response's median at each level [x, level, median, n].  x is the
    level where every level is a number, else its place in the levels'
    natural order (x_labels)."""
    if factor not in t.columns or factor not in s.factors:
        die("no factor %r in the study %s (its factors: %s)" % (
            factor, s.name, ", ".join(s.factors) or "none varied"))
    names = [n for n, _ in s.responses]
    if response not in names:
        die("no response %r in the study %s (its responses: %s)" % (
            response, s.name, ", ".join(names)))
    fi, vi = t.index(factor), t.index(response)
    di, pi, hi, ri = (t.index(c) for c in ("design", "point", "host", "run"))
    levels = [r[fi] for r in t.rows if r[fi].strip()]
    numeric = all(tablemod.to_num(v) is not None for v in levels)
    labels = None
    if not numeric:
        labels = stats.natural_sorted(sorted(set(levels)))
        pos = dict((v, i) for i, v in enumerate(labels))
    series, order = {}, []
    for r in t.rows:
        if not r[fi].strip():
            continue
        x = tablemod.to_num(r[fi]) if numeric else float(pos[r[fi]])
        y = tablemod.to_num(r[vi]) if r[vi].strip() else None
        if r[di] not in series:
            series[r[di]] = []
            order.append(r[di])
        series[r[di]].append([x, r[fi], y, r[ri], r[pi], r[hi]])
    out = []
    for name in order:
        pts = sorted(series[name], key=lambda p: p[0])
        at = {}
        for p in pts:
            at.setdefault(p[0], (p[1], []))[1].append(p[2])
        meds = []
        for x in sorted(at):
            lv, ys = at[x]
            ys = sorted(y for y in ys if y is not None)
            meds.append([x, lv, stats.quantile(ys, .5) if ys else None,
                         len(ys)])
        out.append({"group": name, "points": pts, "levels": meds})
    return {"factor": factor, "response": response, "series": out,
            "numeric_x": numeric, "x_labels": labels,
            "unmeasured": sum(1 for r in t.rows if not r[vi].strip())}
