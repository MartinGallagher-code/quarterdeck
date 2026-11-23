# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Martin J. Gallagher
"""Further rounds until an optimum: `qd doe optimize STUDY -c RESPONSE
--budget N` (QD-072, step 7 of a tuning study).

qd decides the rounds and runs them; doe decides the points.  From the
study's central composite or Box-Behnken follow-up, on its host and target:

- while doe's surface puts the best point on the region's **edge**, qd
  walks doe's steepest path (`doe optimize --steepest`) a step at a time
  until a step is no better than the one before, then lays a new design of
  the same kind and size around the best point measured (doe generate);
- once the optimum is **inside** the region, `doe next-batch` adds points
  near it (refine; model_guided for a response to minimise, since doe's
  refine centres on the largest value), and qd runs **confirmation runs**
  at doe's best point inside the region.

It stops on the owner's rule: the confirmation runs agree with doe's
prediction (their mean within twice doe's cross-validated error of it:
doe gives no prediction interval) and the last round improved the best
measured response by under 2%; or when the run budget is spent, never past
it; or when it cannot go on (doe fits no surface, the host answers
nothing, doe proposes nothing new), and says which.  Then a recommendation:
the settings, the command line that runs them, the predicted and measured
response with their spread, the starting settings for comparison, and
whether it is only the best of the region searched or the best the study
has measured anywhere.

Every round is a design of the study, filed as `qd doe run` files one: a
path, a region, a confirmation (`metadata.qd_round`), each point a run, so
`qd compare --study` and qd web show them.  A refinement adds points to
the design it refines (filed again, its points so far kept).  Everything
the loop decides is decided again from the store, so an interrupted
optimize run again carries on where it stopped, and the budget counts every
run it made before.
"""

import hashlib
import json
import math

from .common import PROG, die, plural
from . import doe as doemod, filing, stats, study as studymod

GAIN = 2.0          # the owner's stop: the last round gained under 2%
CONFIRM_RUNS = 3    # runs at the predicted optimum
BATCH = 4           # points doe next-batch adds a round
STRATEGIES = ("refine", "model_guided", "bayesian")
MAX_STEPS = 200     # a loop that decides this often has stopped deciding
KINDS = ("path", "region", "confirm")
SKIP_META = ("name", "description", "qd_note", "qd_like", "qd_optimize",
             "qd_round", "qd_refines", "qd_follows")


class Stop(Exception):
    """Why the loop stopped: reason converged, budget or stalled."""

    def __init__(self, reason, text):
        Exception.__init__(self, text)
        self.reason, self.text = reason, text


# ---------------------------------------------------------------------------
# What a factor can take
# ---------------------------------------------------------------------------

def _bound(v):
    try:
        v = float(v)
    except (TypeError, ValueError):
        return None
    return v if v == v and abs(v) != float("inf") else None


def limits(factor):
    """(low, high, whole) a numeric factor may be set to, or None for a
    categorical one.  The config's own qd_min and qd_max where it gives
    them; else a count (whole-number levels, 1 or more) no lower than 1,
    any other factor whose levels are not negative no lower than 0, and no
    upper bound."""
    if not doemod.numeric(factor):
        return None
    lv = [float(x) for x in factor["levels"]]
    whole = all(v.is_integer() for v in lv)
    lo, hi = _bound(factor.get("qd_min")), _bound(factor.get("qd_max"))
    if lo is None:
        if whole and min(lv) >= 1:
            lo = 1.0
        elif min(lv) >= 0:
            lo = 0.0
    return lo, hi, whole


def settle(lim, v):
    """v as the command can take it: a whole number for a count, inside the
    factor's limits."""
    lo, hi, whole = lim
    if whole:
        v = float(math.floor(v + 0.5))
        lo = None if lo is None else float(math.ceil(lo))
        hi = None if hi is None else float(math.floor(hi))
    if lo is not None and v < lo:
        v = lo
    if hi is not None and v > hi:
        v = hi
    return v


def show(v, whole):
    return str(int(v)) if whole else "%.6g" % v


def recentre(lim, centre, half):
    """A factor's two levels for a region of the same size around centre,
    moved (not shrunk) to stay inside its limits; a count's two levels sum
    to an even number, so the design's middle is a whole number too."""
    lo_b, hi_b, whole = lim
    if whole:
        lo_b = None if lo_b is None else float(math.ceil(lo_b))
        hi_b = None if hi_b is None else float(math.floor(hi_b))
    lo, hi = centre - half, centre + half
    if whole:
        lo, hi = math.floor(lo + 0.5), math.floor(hi + 0.5)
    if lo_b is not None and lo < lo_b:
        lo, hi = lo_b, hi + (lo_b - lo)
    if hi_b is not None and hi > hi_b:
        lo, hi = lo - (hi - hi_b), hi_b
        if lo_b is not None and lo < lo_b:
            lo = lo_b
    if whole and (lo + hi) % 2:
        # the middle a whole number: one wider where the limits allow
        if hi_b is None or hi + 1 <= hi_b:
            hi += 1
        elif lo_b is None or lo - 1 >= lo_b:
            lo -= 1
        else:
            hi -= 1
    if hi <= lo:
        hi = lo + (2 if whole else max(abs(lo) * 0.1, 1e-6))
    return float(lo), float(hi)


def pct(before, after, direction):
    """How much better after is than before, in percent (direction
    maximize or minimize); None when before is 0 or not there."""
    if before is None or after is None or before == 0:
        return None
    d = (after - before) if direction != "minimize" else (before - after)
    return d / abs(before) * 100.0


def reached(e):
    """Whether a run reached a host (one answered, failed or timed out);
    one every host of which was not run -- interrupted by Ctrl-C, or
    stopped before it started -- measured nothing and tried nothing."""
    h = e.meta.get("hosts") or {}
    return (h.get("total") or 0) > (h.get("not-run") or 0)


def _mean(xs):
    return sum(xs) / float(len(xs)) if xs else None


def _seed(text):
    return int(hashlib.sha1(text.encode("utf-8")).hexdigest()[:8], 16) \
        % 1000003


# ---------------------------------------------------------------------------
# The loop
# ---------------------------------------------------------------------------

class Optimizer(object):
    """One optimize: a study's response from its start design.  run_point
    (design, run_id, [(factor, level)]) runs one point on the study's
    hosts and files it; say(text) tells the person watching."""

    def __init__(self, st, prov, start, column, agg="median", budget=0,
                 confirm=CONFIRM_RUNS, batch=BATCH, strategy="refine",
                 gain=GAIN, run_point=None, say=None, sel=None, cost=1):
        self.st, self.prov, self.start = st, prov, start
        self.agg, self.budget = agg, budget
        # QD-073: the drive group optimised (drives.Selection; None, every
        # row as one), and the runs a point makes (one a drive slot, when
        # a host's drives are measured one at a time)
        self.sel, self.cost = sel, max(1, int(cost or 1))
        self.gkey = sel.meta() if sel is not None else None
        self.confirm, self.batch = confirm, batch
        self.strategy, self.gain = strategy, gain
        self.run_point = run_point
        self.say = say or (lambda text: None)
        row, cfg, matrix = doemod.load(st, start)
        self.rname, self.column, self.direction = \
            doemod.surface_spec(cfg, column)
        self.template = row.get("command") or doemod.command_of(cfg)
        self.fixed = doemod.fixed_of(cfg)
        self.factors = list(matrix.get("factor_names") or [])
        self.study = doemod.study_of(cfg, start)
        self.tried = set()
        self.said = set()
        self.surfaces = {}
        self.ran = 0
        self.stopped = None
        self.refresh()

    # -- what the store holds --------------------------------------------

    def refresh(self):
        self.st.reset()
        self.designs = {}
        self.runs = {}
        for e in self.st.entries():
            g, p = e.meta.get("group"), str(e.meta.get("part", ""))
            if g and p.isdigit():
                self.runs.setdefault(g, {}).setdefault(int(p), []).append(e)
        self.rounds = []
        for name in studymod.members(self.st, self.study):
            r = self.load(name)
            meta = r[1].get("metadata") or {}
            rd = meta.get("qd_round") if isinstance(meta, dict) else None
            if isinstance(rd, dict) and rd.get("start") == self.start and \
                    rd.get("response") == self.rname and \
                    rd.get("group") == self.gkey:
                self.rounds.append(name)
        self.vals = {}

    def load(self, name):
        if name not in self.designs:
            self.designs[name] = doemod.load(self.st, name)
        return self.designs[name]

    def meta(self, name):
        m = self.load(name)[1].get("metadata") or {}
        return m if isinstance(m, dict) else {}

    def round_of(self, name):
        rd = self.meta(name).get("qd_round")
        return rd if isinstance(rd, dict) else {}

    def kind(self, name):
        return "start" if name == self.start else self.round_of(name).get(
            "kind", "")

    def marker(self):
        m = self.meta(self.start).get("qd_optimize")
        return m if isinstance(m, dict) else None

    def points(self, name):
        return doemod.points(self.load(name)[2])

    def values(self, name):
        """{run_id: the point's response, or None}."""
        if name not in self.vals:
            self.vals[name] = dict(
                (rid, v) for rid, v, _ in
                doemod.responses(self.st, name, self.column, self.agg,
                                 self.sel))
        return self.vals[name]

    def answered(self, name, rid):
        return doemod.answered(self.runs.get(name, {}).get(rid, []),
                               self.sel)

    def spent(self):
        """Every run this optimize made: each of its rounds' runs, and the
        start design's runs since it began."""
        n = sum(len(rs) for name in self.rounds
                for rs in self.runs.get(name, {}).values())
        m = self.marker() or {}
        before = int(m.get("runs_before") or 0)
        if self.gkey is not None:
            before = int((m.get("groups") or {}).get(self.glabel(), before))
        mine = sum(len(rs) for rs in self.runs.get(self.start, {}).values())
        return n + max(0, mine - before)

    def working(self):
        """The design the loop works on: the latest region, else the start."""
        regions = [n for n in self.rounds if self.kind(n) == "region"]
        return regions[-1] if regions else self.start

    def follows(self, name):
        return [n for n in self.rounds
                if self.round_of(n).get("follows") == name]

    def path_of(self, w):
        ps = [n for n in self.follows(w) if self.kind(n) == "path"]
        return ps[-1] if ps else None

    def confirms_of(self, w):
        return [n for n in self.follows(w) if self.kind(n) == "confirm"]

    def refines(self, w):
        rs = self.meta(w).get("qd_refines")
        return [r for r in rs if isinstance(r, dict)] \
            if isinstance(rs, list) else []

    def better(self, a, b):
        return a > b if self.direction != "minimize" else a < b

    def best(self, pts):
        """The best of [(value, ...)] for this response; None for none."""
        pts = [p for p in pts if p[0] is not None]
        if not pts:
            return None
        top = pts[0]
        for p in pts[1:]:
            if self.better(p[0], top[0]):
                top = p
        return top

    def lims(self, name):
        cfg = self.load(name)[1]
        out = {}
        for f in cfg.get("factors") or []:
            if isinstance(f, dict) and f.get("name") in self.factors:
                out[f["name"]] = limits(f)
        return out

    def centre(self, name):
        """{factor: level} at the middle of the design's numeric factors."""
        out = {}
        for f, lim in self.lims(name).items():
            if lim is None:
                continue
            lv = [float(x) for x in self.factor(name, f)["levels"]]
            out[f] = show((lv[0] + lv[1]) / 2.0, lim[2])
        return out

    def factor(self, name, f):
        for d in self.load(name)[1].get("factors") or []:
            if isinstance(d, dict) and d.get("name") == f:
                return d
        return {}

    def region(self, name):
        """The design's numeric factors' levels, to tell regions apart."""
        out = []
        for f in self.factors:
            d = self.factor(name, f)
            if doemod.numeric(d):
                out.append((f, tuple(sorted(float(x) for x in d["levels"]))))
        return tuple(out)

    def all_points(self, names=None):
        """[(value, design, run_id, {factor: level})] for every point of
        this optimize (the start, every round), measured or not."""
        out = []
        for name in names or ([self.start] + self.rounds):
            vals = self.values(name)
            for rid, _, lv in self.points(name):
                out.append((vals.get(rid), name, rid, dict(lv)))
        return out

    def note(self, text):
        """Say text once in this run."""
        if text not in self.said:
            self.said.add(text)
            self.say(text)

    # -- spending ----------------------------------------------------------

    def glabel(self):
        """The group's key in the start design's qd_optimize marker."""
        g = self.gkey or {}
        return "%s=%s%s" % (g.get("per", ""), g.get("group", ""),
                            ("/" + g["block"]) if g.get("block") else "")

    def need(self, n, what):
        # n points; a point is self.cost runs when a host's drives are
        # measured one at a time
        n *= self.cost
        left = self.budget - self.spent()
        if left >= n:
            return
        if left <= 0:
            raise Stop("budget", "the budget of %s is spent" %
                       plural(self.budget, "run"))
        raise Stop("budget", "%s needs %s, and %d of the budget of %s %s "
                   "left" % (what, plural(n, "run"), left,
                             plural(self.budget, "run"),
                             "is" if left == 1 else "are"))

    def run(self, name, rid, levels):
        self.tried.add((name, rid))
        self.run_point(name, rid, levels)
        self.ran += self.cost
        self.refresh()
        return self.answered(name, rid)

    def measure(self, name, what):
        """Run every point of a design not measured yet (once in this run:
        a point that fails is not run again until optimize is run again)."""
        for rid, _, lv in self.points(name):
            if self.answered(name, rid) or (name, rid) in self.tried:
                continue
            self.need(1, what)
            self.run(name, rid, lv)

    # -- filing a round ------------------------------------------------------

    def file(self, name, cfg, matrix, seed=None, row=None):
        doemod.file_design(self.st, self.prov, name, self.template,
                           seed, (row or {}).get("blocks_by") or "",
                           cfg, matrix)
        self.refresh()

    def begin(self):
        """Mark the start design with the optimize it starts (so the budget
        counts only the runs made since), once."""
        m = self.marker()
        now = sum(len(rs) for rs in self.runs.get(self.start, {}).values())
        if m is not None:
            if m.get("response") != self.rname:
                die("%s is optimised for %s already: one optimize a design "
                    "(qd doe next %s -c %s writes another follow-up to "
                    "start from)" % (self.start, m.get("response"),
                                     self.study, self.rname))
            if self.gkey is None or \
                    self.glabel() in (m.get("groups") or {}):
                return
            # another drive group's optimize from the same design: its own
            # count of the runs made before it began
            m = json.loads(json.dumps(m))
            m.setdefault("groups", {})[self.glabel()] = now
        else:
            m = {"response": self.rname, "column": self.column,
                 "optimize": self.direction, "runs_before": now}
            if self.gkey is not None:
                m["groups"] = {self.glabel(): now}
        row, cfg, matrix = self.load(self.start)
        cfg = json.loads(json.dumps(cfg))
        cfg.setdefault("metadata", {})["qd_optimize"] = m
        self.file(self.start, cfg, matrix, row.get("seed") or None, row)

    def round_name(self, kind):
        n = 1 + sum(1 for r in self.rounds if self.kind(r) == kind)
        known = set(doemod.names(self.st))
        while True:
            name = filing.dataset_name("%s-%s-%s%s%d" % (
                self.study, self.rname.replace("_", "-"),
                (doemod.safe_part(self.sel.group).lower().replace("_", "-")
                 + "-") if self.sel is not None and self.sel.group else "",
                kind, n))
            if name not in known:
                return name, n
            n += 1

    def round_cfg(self, base, name, kind, n, follows, operation, extra,
                  factors=None):
        cfg = json.loads(json.dumps(self.load(base)[1]))
        meta = dict((k, v) for k, v in (cfg.get("metadata") or {}).items()
                    if k not in SKIP_META)
        rd = {"kind": kind, "n": n, "start": self.start,
              "response": self.rname, "follows": follows}
        if self.gkey is not None:
            rd["group"] = self.gkey
        rd.update(extra)
        meta.update({
            "name": name,
            "description": "QD-072: qd doe optimize's %s %d for %s, from %s"
                           % (kind, n, self.rname, follows),
            "qd_command": self.template,
            "qd_study": self.study,
            "qd_follows": {"design": follows, "response": self.rname,
                           "column": self.column,
                           "optimize": self.direction},
            "qd_round": rd})
        if self.gkey is not None:
            meta["qd_group"] = self.gkey
        cfg["metadata"] = meta
        cfg["settings"] = dict(cfg.get("settings") or {}, operation=operation,
                               block_count=1)
        if factors is not None:
            cfg["factors"] = factors
        return cfg

    def surface(self, w):
        key = (w, tuple(sorted(self.values(w).items())))
        if key not in self.surfaces:
            self.surfaces[key] = doemod.surface(self.st, w, self.column,
                                                self.agg, grid=False,
                                                sel=self.sel)
        return self.surfaces[key]

    # -- the rounds ------------------------------------------------------------

    def loop(self):
        """Round after round until a Stop; returns the Stop."""
        self.begin()
        try:
            for _ in range(MAX_STEPS):
                self.step()
            raise Stop("stalled", "the loop decided %d times without "
                       "stopping" % MAX_STEPS)
        except Stop as s:
            self.stopped = s
        self.refresh()
        return self.stopped

    def step(self):
        w = self.working()
        self.measure(w, "measuring %s" % w)
        k = len(self.factors)
        want = 2 + 2 * k + k * (k - 1) // 2   # a quadratic's terms, and one
        got = sum(1 for v in self.values(w).values() if v is not None)
        if got < want:
            raise Stop("stalled", "%d of %s's %s measured %s: a quadratic "
                       "surface over %s needs %d" % (
                           got, w, plural(len(self.points(w)), "point"),
                           self.rname, plural(k, "factor"), want))
        s = self.surface(w)
        if s["fit"]["model"] != "quadratic" or not s["model"]["terms"]:
            raise Stop("stalled", "doe fitted no quadratic surface to %s "
                       "(%d points measured)" % (w, got))
        p = self.path_of(w)
        if p is None and s["verdict"]["where"] == "edge":
            if self.new_path(w, s):
                return
        if p is not None:
            self.walk(p, w)
            if self.new_region(w, p):
                return
        self.inside(w, s)

    def new_path(self, w, s):
        """File doe's steepest path from w, rounded and kept inside the
        factors' limits, a point a step; None when it goes nowhere."""
        if (w, "nopath") in self.said:
            return None
        table, _ = doemod.steepest(self.st, w, self.column, self.agg,
                                   self.sel)
        lims = self.lims(w)
        prev = dict(self.centre(w))
        steps = []
        for step, sets, pred in table:
            if step == 0:
                continue
            pt = {}
            for f in self.factors:
                v = sets.get(f, "")
                lim = lims.get(f)
                if lim is not None:
                    try:
                        v = show(settle(lim, float(v)), lim[2])
                    except ValueError:
                        pass
                pt[f] = v
            if all(pt.get(f) == prev.get(f) for f in pt):
                continue
            steps.append((step, pt, pred))
            prev = pt
        if not steps:
            self.said.add((w, "nopath"))
            self.note("  doe's steepest path from %s goes nowhere the factors "
                      "can be set (every step rounds to the last, or is past "
                      "a limit): the region stays" % w)
            return None
        self.need(1, "the first step of the path")
        name, n = self.round_name("path")
        op = "steepest_ascent" if self.direction != "minimize" else \
            "steepest_descent"
        edge = ", ".join("%s at its %s level" % (f, e)
                         for f, e in (s["optimum"] or {}).get("edge") or [])
        cfg = self.round_cfg(w, name, "path", n, w, op, {
            "w_points": max([rid for rid, _, _ in self.points(w)] or [0]),
            "steps": [st for st, _, _ in steps],
            "predicted": [pr for _, _, pr in steps]})
        matrix = {"factor_names": self.factors, "operation": op,
                  "metadata": {"qd_round": "path"},
                  "runs": [{"run_id": i + 1, "block_id": 1,
                            "factor_values": pt, "whole_plot_id": 0}
                           for i, (_, pt, _) in enumerate(steps)]}
        self.file(name, cfg, matrix)
        self.say("%s doe optimize -- the best point inside %s is on its edge "
                 "(%s): doe's steepest %s from its centre, %s, walked until "
                 "a step is no better (%s)" % (
                     PROG, w, edge or "doe's verdict",
                     "ascent" if self.direction != "minimize" else "descent",
                     plural(len(steps), "step"), name))
        return name

    def centre_value(self, w, upto=None):
        c = self.centre(w)
        vals = self.values(w)
        xs = [vals.get(rid) for rid, _, lv in self.points(w)
              if (upto is None or rid <= upto) and
              all(dict(lv).get(f) == v for f, v in c.items())]
        return _mean([x for x in xs if x is not None])

    def walk(self, p, w):
        """Measure the path a step at a time, until a step is no better
        than the best before it (the design's centre, at first), fails,
        or is the last."""
        rd = self.round_of(p)
        best = self.centre_value(w, rd.get("w_points"))
        preds = rd.get("predicted") or []
        for i, (rid, _, lv) in enumerate(self.points(p)):
            ran = False
            if not self.answered(p, rid):
                # a step that failed ends the path; one interrupted before
                # it reached the host is run again
                if (p, rid) in self.tried or any(
                        reached(e) for e in self.runs.get(p, {}).get(rid, [])):
                    return
                self.need(1, "the next step of the path")
                ran = True
                if not self.run(p, rid, lv):
                    self.say("  step %d failed: no host measured it, so the "
                             "path ends here" % rid)
                    return
            v = self.values(p).get(rid)
            if v is None:
                return
            ok = best is None or self.better(v, best)
            if ran:
                pr = preds[i] if i < len(preds) else None
                self.say("  step %d: %s = %s%s, %s" % (
                    rid, self.rname, stats.fmt_num(v),
                    (" (doe's line said %s)" % stats.fmt_num(pr))
                    if pr is not None else "",
                    "better: on" if ok else
                    "no better than %s: the path ends here" %
                    stats.fmt_num(best)))
            if not ok:
                return
            best = v

    def new_region(self, w, p):
        """File a design like w around the best point measured on the path
        (or in w, as it was when the path began); None when that is w's
        own centre or a region searched already."""
        rd = self.round_of(p)
        upto = rd.get("w_points")
        cands = [x for x in self.all_points([w, p])
                 if x[1] == p or upto is None or x[2] <= upto]
        top = self.best(cands)
        if top is None:
            return None
        lims = self.lims(w)
        sets = top[3]
        centre = self.centre(w)
        if top[1] == w and all(sets.get(f) == v for f, v in centre.items()):
            self.note("  nothing on the path or in %s beats its centre: the "
                      "region stays" % w)
            return None
        factors, levels = [], {}
        for f in self.load(w)[1].get("factors") or []:
            f = json.loads(json.dumps(f))
            lim = lims.get(f.get("name"))
            if lim is not None:
                lv = [float(x) for x in f["levels"]]
                half = abs(lv[1] - lv[0]) / 2.0
                try:
                    c = float(sets.get(f["name"]))
                except (TypeError, ValueError):
                    c = (lv[0] + lv[1]) / 2.0
                lo, hi = recentre(lim, c, half)
                f["levels"] = [show(lo, lim[2]), show(hi, lim[2])]
                levels[f["name"]] = (lo, hi)
            factors.append(f)
        here = tuple((f, levels[f]) for f in self.factors if f in levels)
        seen = [self.region(n) for n in [self.start] + self.rounds
                if self.kind(n) in ("start", "region")]
        if here in seen:
            self.note("  a region around the best point (%s) is one searched "
                      "already: the region stays" % " ".join(
                          "%s=%s" % (f, sets.get(f)) for f in self.factors))
            return None
        name, n = self.round_name("region")
        op = self.load(w)[2].get("operation") or \
            (self.load(w)[1].get("settings") or {}).get("operation")
        cfg = self.round_cfg(w, name, "region", n, p, op, {
            "centre": dict((f, sets.get(f)) for f in self.factors),
            "best": top[0], "from": "%s point %d" % (top[1], top[2])},
            factors)
        seed = doemod.seed_of(cfg)
        matrix = doemod.generate(cfg, seed)
        npts = len(doemod.points(matrix))
        self.need(npts, "the next region, a %s of %s around %s," % (
            op.replace("_", " "), plural(npts, "point"),
            " ".join("%s=%s" % (f, sets.get(f)) for f in self.factors)))
        self.file(name, cfg, matrix, seed)
        self.say("%s doe optimize -- a %s around the best point measured, "
                 "%s (%s = %s, %s point %d): %s, %s" % (
                     PROG, op.replace("_", " "),
                     " ".join("%s=%s" % (f, sets.get(f))
                              for f in self.factors),
                     self.rname, stats.fmt_num(top[0]), top[1], top[2],
                     name, " ".join("%s %s..%s" % (
                         f, show(levels[f][0], lims[f][2]),
                         show(levels[f][1], lims[f][2]))
                         for f in self.factors if f in levels)))
        return name

    def inside(self, w, s):
        cs = self.confirms_of(w)
        r = len(self.refines(w))
        if cs and r == len(cs):
            c = cs[-1]
            self.measure(c, "the confirmation runs")
            if not any(v is not None for v in self.values(c).values()):
                raise Stop("stalled", "no confirmation run in %s measured "
                           "%s: the host answered none" % (c, self.rname))
            j = self.judge(c)
            if j["converged"]:
                raise Stop("converged", j["text"])
            self.say("  %s; another round" % j["text"])
        if r <= len(cs):
            self.need(self.batch + self.confirm,
                      "another round (%d points to refine, %d to confirm)"
                      % (self.batch, self.confirm))
            self.refine(w, len(cs) + 1, s)
            return
        self.new_confirm(w, len(cs) + 1, s)

    def refine(self, w, k, s):
        strategy = self.strategy
        if strategy == "refine" and self.direction == "minimize":
            strategy = "model_guided"
            self.note("  doe's refine centres on the largest value seen, so "
                      "for %s, to minimise, its model_guided strategy is "
                      "used" % self.rname)
        new, _ = doemod.next_batch(self.st, w, self.column, self.agg,
                                   strategy, self.batch,
                                   _seed("%s/%d" % (w, k)), self.sel)
        lims = self.lims(w)
        pts = []
        for fv in new:
            pt = {}
            for f in self.factors:
                v, lim = fv.get(f, ""), lims.get(f)
                if lim is not None:
                    try:
                        v = show(settle(lim, float(v)), lim[2])
                    except ValueError:
                        pass
                pt[f] = v
            pts.append(pt)
        if not pts:
            raise Stop("stalled", "doe next-batch (%s) proposed no new "
                       "points for %s" % (strategy, w))
        row, cfg, matrix = self.load(w)
        cfg = json.loads(json.dumps(cfg))
        matrix = json.loads(json.dumps(matrix))
        first = 1 + max([int(x["run_id"]) for x in matrix.get("runs") or []]
                        or [0])
        for i, pt in enumerate(pts):
            matrix.setdefault("runs", []).append({
                "run_id": first + i, "block_id": 1, "factor_values": pt,
                "whole_plot_id": 0})
        meta = cfg.setdefault("metadata", {})
        meta["qd_refines"] = self.refines(w) + [{
            "n": k, "first": first, "points": len(pts),
            "strategy": strategy}]
        self.file(w, cfg, matrix, row.get("seed") or None, row)
        want = doemod.WANTED.get(self.direction, "optimum")
        self.say("%s doe optimize -- %s: doe next-batch (%s) adds %s near "
                 "it, points %d to %d" % (
                     PROG, ("the %s is inside %s" % (want, w))
                     if s["verdict"]["where"] == "inside" else
                     ("the region stays at %s, its %s not clearly inside "
                      "it" % (w, want)),
                     strategy, plural(len(pts), "point"), first,
                     first + len(pts) - 1))

    def refine_points(self, w, k):
        for r in self.refines(w):
            if r.get("n") == k:
                return set(range(int(r["first"]),
                                 int(r["first"]) + int(r["points"])))
        return set()

    def new_confirm(self, w, k, s):
        best = s["optimum"]
        if not best or not best.get("settings"):
            raise Stop("stalled", "doe optimize found no best point inside "
                       "%s to confirm" % w)
        lims = self.lims(w)
        pt = {}
        for f in self.factors:
            v, lim = best["settings"].get(f, ""), lims.get(f)
            if lim is not None:
                try:
                    v = show(settle(lim, float(v)), lim[2])
                except ValueError:
                    pass
            pt[f] = v
        code = doemod.coding(self.load(w)[1], self.factors)
        coded = dict((f, doemod.to_coded(code, f, pt[f]))
                     for f in self.factors)
        terms = [(t, b) for t, b in s["model"]["terms"]]
        pred = doemod.predict(terms, self.factors, coded) \
            if terms and all(c is not None for c in coded.values()) \
            else best.get("predicted")
        rmse = s["fit"].get("rmse_cv")
        half = 2.0 * rmse if rmse is not None else None
        mine = self.refine_points(w, k)
        top = self.best([x for x in self.all_points()
                         if not (x[1] == w and x[2] in mine)])
        self.need(self.confirm, "the confirmation runs")
        name, n = self.round_name("confirm")
        cfg = self.round_cfg(w, name, "confirm", n, w, "confirmation", {
            "refine": k, "settings": pt, "predicted": pred,
            "interval": half, "rmse_cv": rmse,
            "model": s["model"]["kind"],
            "before": top[0] if top else None})
        matrix = {"factor_names": self.factors, "operation": "confirmation",
                  "metadata": {"qd_round": "confirm"},
                  "runs": [{"run_id": i + 1, "block_id": 1,
                            "factor_values": dict(pt), "whole_plot_id": 0}
                           for i in range(self.confirm)]}
        self.file(name, cfg, matrix)
        self.say("%s doe optimize -- confirmation: %s at %s, where doe "
                 "predicts %s = %s%s (%s)" % (
                     PROG, plural(self.confirm, "run"),
                     " ".join("%s=%s" % (f, pt[f]) for f in self.factors),
                     self.rname, stats.fmt_num(pred),
                     (" +/- %s" % stats.fmt_num(half)) if half is not None
                     else "", name))

    def judge(self, c):
        """Whether a confirmation meets the owner's rule, and the words."""
        rd = self.round_of(c)
        vals = [v for v in self.values(c).values() if v is not None]
        mean = _mean(vals)
        pred, half = rd.get("predicted"), rd.get("interval")
        within = None if pred is None or half is None or mean is None \
            else abs(mean - pred) <= half
        top = self.best(self.all_points())
        gain = pct(rd.get("before"), top[0] if top else None, self.direction)
        ok = bool(within) and gain is not None and gain < self.gain
        words = []
        if mean is not None:
            words.append("the confirmation runs measured %s = %s (mean of %d)"
                         % (self.rname, stats.fmt_num(mean), len(vals)))
        if within is None:
            words.append("doe gave no error to judge them by")
        else:
            words.append("%s doe's prediction %s +/- %s" % (
                "inside" if within else "outside", stats.fmt_num(pred),
                stats.fmt_num(half)))
        if gain is not None:
            words.append("and the round improved the best measured by %.1f%% "
                         "(%s %g%%)" % (gain, "under" if gain < self.gain
                                        else "not under", self.gain))
        return {"converged": ok, "within": within, "gain": gain,
                "mean": mean, "values": vals, "predicted": pred,
                "interval": half, "text": ", ".join(words)}

    # -- the recommendation ------------------------------------------------

    def report(self):
        """What the loop found, as figures: the stop, every round, the
        recommended settings and command, the start for comparison, the
        region searched, and whether it is the best the study has seen."""
        stop = self.stopped
        pts = self.all_points()
        out = {"study": self.study, "start": self.start,
               "response": self.rname, "column": self.column,
               "optimize": self.direction, "agg": self.agg,
               "budget": self.budget, "spent": self.spent(),
               "ran": self.ran, "factors": self.factors,
               "group": self.gkey, "runs_per_point": self.cost,
               "held": [[k, v] for k, v in self.fixed],
               "stop": {"reason": stop.reason, "text": stop.text}
               if stop else None,
               "rounds": self.round_rows()}
        # the start: the start design's centre
        sc = self.centre(self.start)
        start_v = self.centre_value(self.start)
        out["starting"] = {"settings": sc, "measured": start_v,
                           "design": self.start}
        rec = self.recommend(pts)
        out["recommended"] = rec
        if rec:
            out["change"] = pct(start_v, rec["measured"]["mean"],
                                self.direction)
        else:
            out["change"] = None
        out["region"] = self.searched(pts)
        out["overall"] = self.overall(rec)
        return out

    def recommend(self, pts):
        w = self.working()
        cs = self.confirms_of(w)
        groups = {}
        order = []
        for v, name, rid, lv in pts:
            if v is None:
                continue
            key = tuple(lv.get(f, "") for f in self.factors)
            if key not in groups:
                groups[key] = []
                order.append(key)
            groups[key].append((v, name, rid))
        if not groups:
            return None
        chosen = None
        if self.stopped and self.stopped.reason == "converged" and cs:
            rd = self.round_of(cs[-1])
            chosen = tuple(rd["settings"].get(f, "") for f in self.factors)
            source = "confirmed"
        if chosen not in groups:
            chosen = self.best([(_mean([x[0] for x in groups[k]]), k)
                                for k in order])[1]
            source = "measured"
        sets = dict(zip(self.factors, chosen))
        vals = [x[0] for x in groups[chosen]]
        where = sorted(set(x[1] for x in groups[chosen]))
        pred = half = None
        for c in cs + [n for n in self.rounds if self.kind(n) == "confirm"]:
            rd = self.round_of(c)
            if tuple(rd.get("settings", {}).get(f, "")
                     for f in self.factors) == chosen:
                pred, half = rd.get("predicted"), rd.get("interval")
                if source == "measured" and c in where:
                    source = "confirmation"
                break
        if pred is None:
            pred, half = self.predict_at(w, sets)
        sd = None
        if len(vals) > 1:
            m = _mean(vals)
            sd = (sum((x - m) ** 2 for x in vals) / (len(vals) - 1)) ** 0.5
        held = [(k, v) for k, v in self.fixed]
        return {"settings": sets, "source": source, "designs": where,
                "predicted": pred, "interval": half,
                "measured": {"mean": _mean(vals), "min": min(vals),
                             "max": max(vals), "n": len(vals), "sd": sd,
                             "values": vals},
                "command": doemod.substitute(
                    self.template, [(f, sets[f]) for f in self.factors],
                    held)}

    def predict_at(self, w, sets):
        """doe's model of w at sets, and twice its cross-validated error,
        where sets lies inside w's region; (None, None) elsewhere."""
        vals = self.values(w)
        if sum(1 for v in vals.values() if v is not None) < 2:
            return None, None
        try:
            s = self.surface(w)
        except Exception:   # a figure for the report, never a failure
            return None, None
        terms = [(t, b) for t, b in (s.get("model") or {}).get("terms") or []]
        if not terms:
            return None, None
        code = doemod.coding(self.load(w)[1], self.factors)
        coded = dict((f, doemod.to_coded(code, f, sets.get(f)))
                     for f in self.factors)
        if any(c is None or abs(c) > 1 + 1e-9 for c in coded.values()):
            return None, None
        rmse = s["fit"].get("rmse_cv")
        return doemod.predict(terms, self.factors, coded), \
            (2.0 * rmse if rmse is not None else None)

    def searched(self, pts):
        """{factor: [lowest, highest]} over every point measured."""
        out = {}
        for v, name, _, lv in pts:
            if v is None:
                continue
            for f in self.factors:
                try:
                    x = float(lv.get(f))
                except (TypeError, ValueError):
                    continue
                lo, hi = out.get(f, (x, x))
                out[f] = (min(lo, x), max(hi, x))
        return dict((f, [lo, hi]) for f, (lo, hi) in out.items())

    def overall(self, rec):
        """Whether any design of the study measured better than the
        recommendation, by more than its spread: [] when none did."""
        if not rec:
            return {"best": False, "better": [], "points": 0}
        tol = rec["interval"] or 0.0
        mean = rec["measured"]["mean"]
        better, n = [], 0
        for name in studymod.members(self.st, self.study):
            vals = self.values(name)
            for rid, _, lv in self.points(name):
                v = vals.get(rid)
                if v is None:
                    continue
                n += 1
                if self.better(v, mean) and abs(v - mean) > tol:
                    better.append({"design": name, "point": rid, "value": v,
                                   "levels": dict(lv)})
        better.sort(key=lambda b: -b["value"] if self.direction != "minimize"
                    else b["value"])
        return {"best": not better, "better": better[:3], "points": n}

    def round_rows(self):
        """Every round in the order it was filed: [{round, design, kind,
        points, measured, runs, best, note}]."""
        rows = []
        done = {}

        def add(design, kind, rids, note):
            vals = self.values(design)
            got = [vals.get(r) for r in rids]
            top = self.best([(v,) for v in got])
            rows.append({"round": len(rows), "design": design, "kind": kind,
                         "points": len(rids),
                         "measured": sum(1 for v in got if v is not None),
                         "runs": sum(len(self.runs.get(design, {}).get(r, []))
                                     for r in rids),
                         "best": top[0] if top else None, "note": note})

        def base(design):
            ids = set()
            for r in self.refines(design):
                ids |= set(range(int(r["first"]),
                                 int(r["first"]) + int(r["points"])))
            return [rid for rid, _, _ in self.points(design)
                    if rid not in ids]

        def refine_row(design, r):
            done.setdefault(design, set()).add(r.get("n"))
            add(design, "refine", sorted(self.refine_points(design,
                                                            r.get("n"))),
                "doe next-batch (%s)" % r.get("strategy", ""))

        for name in [self.start] + self.rounds:
            kind = self.kind(name)
            rd = self.round_of(name)
            if kind == "confirm":
                w = rd.get("follows")
                for r in self.refines(w):
                    if r.get("n") == rd.get("refine") and \
                            r.get("n") not in done.get(w, set()):
                        refine_row(w, r)
                pr, hf = rd.get("predicted"), rd.get("interval")
                add(name, kind, [rid for rid, _, _ in self.points(name)],
                    "doe predicts %s%s" % (
                        stats.fmt_num(pr) if pr is not None else "?",
                        (" +/- %s" % stats.fmt_num(hf)) if hf is not None
                        else ""))
            elif kind == "path":
                add(name, kind, [rid for rid, _, _ in self.points(name)],
                    "doe's steepest path from %s" % rd.get("follows"))
            else:
                op = (self.load(name)[2].get("operation") or "")
                add(name, kind, base(name),
                    op.replace("_", " ") + ("" if kind == "start" else
                                            " around %s" % " ".join(
                                                "%s=%s" % kv for kv in sorted(
                                                    (rd.get("centre") or
                                                     {}).items()))))
        for name in [self.start] + self.rounds:
            for r in self.refines(name):
                if r.get("n") not in done.get(name, set()):
                    refine_row(name, r)
        return rows
