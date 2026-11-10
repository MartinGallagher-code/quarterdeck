# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Martin J. Gallagher
"""Qualified baselines: what good looked like, blessed and kept.

    qd baseline set gold load --last 5 --peers sku -c mbps
    qd baseline ls | show NAME | rm NAME --yes
    qd compare load --last 5 --baseline gold

A baseline is set from one or more runs someone vouches for, and kept in
the store as qd's own table, qd.baselines: who set it and when, the runs,
and for each column, peer group and key (host) the value every run gave,
with their median, spread (MAD) and count.  It is never "the first run in
the list": compare --baseline NAME holds later runs against it.

Each run is reduced the way compare reduces one: a key's rows to one
number (--agg, the median), a peer group to the median of its keys.  So
a peer group has one value per run, and the runs are the replicates: the
spread between them is the run-to-run noise a real change has to stand
out from.  With at least three runs on each side, compare tests the
difference with the Mann-Whitney U test (stats.mann_whitney), adjusts the
p values for the number of tests made (Holm), and gives the effect size
beside the drift.  A difference that is significant is a change even
inside the drift threshold -- the point of a baseline, to see a slide
before a fixed limit is crossed -- and a drift past the threshold is
still a change whatever the test says.  Fewer runs: the drift alone, said
to be so.

Blank is not measured, never zero: a run that did not measure a key gives
it no value, and a baseline's count is of the runs that measured it.
"""

import json
import re

from .common import die, plural
from . import filing, store as storemod, table as tablemod
from .stats import AGGS, fmt_num, holm, mann_whitney, quantile, smallest_p

BASELINES = "qd.baselines"
COLUMNS = ("baseline", "created", "operator", "note", "name", "runs",
           "table", "key_cols", "agg", "peers", "by", "column", "unit",
           "peer", "key", "n_runs", "median", "mad", "values")
NAME_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]*$")
MIN_RUNS = 3
ALL = ""                # the peer group of a baseline set without --peers

GROUP_COLUMNS = ["column", "peers", "base_runs", "base_median", "base_mad",
                 "runs", "median", "drift_pct", "effect", "p", "p_holm",
                 "verdict", "flags"]


def shown_peer(p):
    return "(all)" if p == ALL else p


def median(xs):
    return quantile(sorted(xs), .5) if xs else None


def mad(xs):
    m = median(xs)
    return median([abs(x - m) for x in xs]) if xs else None


def pct(a, b):
    if a is None or b is None:
        return None
    if a == 0:
        return None if b == 0 else float("inf") if b > 0 else float("-inf")
    return (b - a) / abs(a) * 100.0


def pct_text(d):
    if d is None:
        return ""
    if d in (float("inf"), float("-inf")):
        return "from 0"
    return "%+.1f%%" % d


def p_text(p):
    if p is None:
        return ""
    return "%.2g" % p if p >= 0.0001 else "<0.0001"


# -- one run, reduced -----------------------------------------------------

def base_numbers(cells):
    """A column's cells as numbers on one scale across runs -- sizes in
    bytes, times in seconds, anything else as written -- and the unit.  A
    cell in a unit other than the column's commonest is left out, as
    compare leaves it; a bare number beside a unit is read as that unit."""
    pairs, units = [], {}
    for c in cells:
        v, fam = tablemod.to_base(c)
        if v is None:
            pairs.append((None, None))
            continue
        u = "B" if fam == "size" else "s" if fam == "time" else (fam or "")
        pairs.append((v, u))
        if u:
            units[u] = units.get(u, 0) + 1
    if not units:
        return [v for v, _ in pairs], ""
    common = sorted(units, key=lambda u: (-units[u], u))[0]
    return [v if u in (common, "") else None for v, u in pairs], common


def reduce(xs, agg):
    if len(xs) == 1:
        return xs[0]
    v = AGGS[agg]([repr(x) for x in xs])
    if v is None or v == "":
        return None
    return float(v)


def measure(table, columns, key, agg, group_of):
    """One run: ({column: {key: value}}, {key: peer or None}, {column:
    unit}).  A key's rows reduce to one number by agg, blanks left out; a
    key with nothing measured in a column has no value there."""
    ki = [table.index(k) for k in key]
    at = group_of(table)
    peer_of = {}
    for r in table.rows:
        k = tuple(r[i] for i in ki)
        if not any(x.strip() for x in k):
            continue                    # no host: nobody's measurement
        if peer_of.get(k) is None:
            peer_of[k] = at(r, k)
    vals, units = {}, {}
    for c in columns:
        if not table.has(c):
            vals[c] = {}
            continue
        nums, units[c] = base_numbers(table.values(c))
        per = {}
        for r, v in zip(table.rows, nums):
            k = tuple(r[i] for i in ki)
            if v is not None and k in peer_of:
                per.setdefault(k, []).append(v)
        vals[c] = dict((k, reduce(xs, agg)) for k, xs in per.items())
        vals[c] = dict((k, v) for k, v in vals[c].items() if v is not None)
    return vals, peer_of, units


def group_medians(vals, peer_of):
    """{(column, peer): the median of the peer group's keys} for one run;
    a group none of whose keys measured the column has no value."""
    out = {}
    for c, per in vals.items():
        by = {}
        for k, v in per.items():
            p = peer_of.get(k)
            if p is not None:
                by.setdefault(p, []).append(v)
        for p, xs in by.items():
            out[(c, p)] = median(xs)
    return out


def grouping(peers):
    """table -> (row, key) -> peer: by a peer group's definition, or
    every key in one group when there is none."""
    if peers is None:
        return lambda table: (lambda row, key: ALL)

    def make(table):
        at = peers.assigner(table)
        return lambda row, key: at(row)
    return make


# -- the baseline itself --------------------------------------------------

class Baseline(object):
    def __init__(self):
        self.name = ""
        self.created = ""
        self.operator = ""
        self.note = ""
        self.like = ""                  # the runs' name: what they ran
        self.runs = []                  # their ids
        self.table = "data"
        self.key = []
        self.agg = "median"
        self.peers = ""                 # the peer group's name, or ""
        self.by = []                    # its columns, for a `by` rule
        self.columns = []
        self.units = {}
        self.groups = {}                # (column, peer) -> [value per run]
        self.keys = {}                  # (column, key) -> [value per run]
        self.key_peer = {}              # key -> peer

    def peer_names(self, column=None):
        from .stats import natural_sorted
        return natural_sorted(sorted(set(
            p for (c, p) in self.groups if column in (None, c))))

    def summary(self):
        return "%s, %s, %s%s" % (
            plural(len(self.runs), "run"), plural(len(self.columns),
                                                  "column"),
            "peer group %s" % self.peers if self.peers else "no peer group",
            (" (%s)" % ", ".join(shown_peer(p) for p in self.peer_names()))
            if self.peers else "")


def check_name(st, name):
    if not NAME_RE.match(name or "") or ".." in name:
        die("a baseline's name is letters, digits, '.', '_' and '-', "
            "starting with a letter or digit: %r" % name)
    clash = [e for e in st.entries() if name in (e.id, e.name)]
    if clash:
        die("%s is a run's name in this store, and compare --baseline %s "
            "would not say which you meant: pick another name" % (name,
                                                                  name))
    return name


def build(name, entries, tables, columns, key, agg, peers, note=""):
    """A Baseline from runs (entries, and their tables, oldest first)."""
    bl = Baseline()
    bl.name, bl.note, bl.agg, bl.key = name, note, agg, list(key)
    bl.runs = [e.id for e in entries]
    bl.like = entries[-1].meta.get("name", "") if entries else ""
    bl.table = tables[0].name if tables else "data"
    bl.columns = list(columns)
    bl.peers = peers.name if peers is not None else ""
    bl.by = list(peers.by) if peers is not None and \
        peers.members is None else []
    group_of = grouping(peers)
    units = {}
    for t in tables:
        vals, peer_of, u = measure(t, columns, key, agg, group_of)
        for c, unit in u.items():
            units.setdefault(c, set()).add(unit)
        for k, p in peer_of.items():
            if p is not None and bl.key_peer.get(k) is None:
                bl.key_peer[k] = p
        for c, per in vals.items():
            for k, v in per.items():
                if peer_of.get(k) is not None:
                    bl.keys.setdefault((c, k), []).append(v)
        for ck, v in group_medians(vals, peer_of).items():
            bl.groups.setdefault(ck, []).append(v)
    for c in columns:
        us = sorted(u for u in units.get(c, ()) if u)
        if len(us) > 1:
            die("the runs give %s in different units (%s): a baseline holds "
                "one" % (c, ", ".join(us)))
        bl.units[c] = us[0] if us else ""
    if not bl.groups:
        die("nothing to keep: no run measured %s%s" % (
            ", ".join(columns), (" in any host of peer group %s" % bl.peers)
            if bl.peers else ""))
    return bl


def rows_of(bl):
    head = [bl.name, bl.created, bl.operator, bl.note, bl.like,
            ";".join(bl.runs), bl.table, ",".join(bl.key), bl.agg, bl.peers,
            ",".join(bl.by)]
    out = []
    for c in bl.columns:
        for p in bl.peer_names(c):
            xs = bl.groups[(c, p)]
            out.append(head + [c, bl.units.get(c, ""), p, ""] + _figs(xs))
        keys = sorted((k for (cc, k) in bl.keys if cc == c),
                      key=lambda k: (bl.key_peer.get(k) or "", k))
        for k in keys:
            xs = bl.keys[(c, k)]
            out.append(head + [c, bl.units.get(c, ""),
                               bl.key_peer.get(k) or "",
                               key_text(k)] + _figs(xs))
    return out


def key_text(k):
    """A key as kept: a host as it is, a key of several columns as a JSON
    list (key_cols says which).  Blank is the peer group's own row."""
    return k[0] if len(k) == 1 else json.dumps(list(k),
                                               separators=(",", ":"))


def key_of(text, ncols):
    if ncols == 1:
        return (text,)
    return tuple(json.loads(text))


def _figs(xs):
    return [str(len(xs)), "%.15g" % median(xs), "%.15g" % mad(xs),
            ";".join("%.15g" % x for x in xs)]


def file_baseline(st, prov, bl):
    from .whoran import operator
    bl.created = storemod.now_iso()
    bl.operator = operator()
    _file(prov, rows_of(bl))
    st.reset()
    got = _latest(_rows(st), bl.name)
    if not got or got[0].get("created") != bl.created:
        die("provost did not file baseline %s where qd reads it (%s): "
            "`provost ls` there says where it went" % (bl.name, BASELINES))
    return bl


def _file(prov, rows):
    prov.require("keep the baseline")
    b = filing.Batch()
    try:
        b.add_own(BASELINES, filing.own_tsv(COLUMNS, rows, spaces=True))
        notes = filing.notes_of(prov, b, "baseline")
    finally:
        b.cleanup()
    if notes:
        die(notes[0])


# -- reading it back ------------------------------------------------------

def _rows(st):
    return st._read_own(BASELINES)


def _latest(rows, name):
    mine = [r for r in rows if r.get("baseline") == name]
    if not mine:
        return []
    last = mine[-1].get("_capture")
    return [r for r in mine if r.get("_capture") == last]


def _gone(rows):
    return any(r.get("note") == "-removed-" and not r.get("column")
               for r in rows)


def names(st):
    rows = _rows(st)
    out = []
    for r in rows:
        n = r.get("baseline")
        if n and n not in out:
            out.append(n)
    return [n for n in out if not _gone(_latest(rows, n))]


def exists(st, name):
    rows = _latest(_rows(st), name)
    return bool(rows) and not _gone(rows)


def _nums(text):
    out = []
    for w in (text or "").replace(";", " ").split():
        try:
            out.append(float(w))
        except ValueError:
            pass
    return out


def load(st, name):
    rows = _latest(_rows(st), name)
    if not rows or _gone(rows):
        known = names(st)
        die("no baseline %r in the store %s%s" % (
            name, st.shown(), (" (baselines: %s; qd baseline ls)"
                               % ", ".join(known)) if known else
            " -- qd baseline set %s RUN... makes one" % name))
    h = rows[0]
    bl = Baseline()
    bl.name = name
    for f in ("created", "operator", "note", "table", "agg", "peers"):
        setattr(bl, f, h.get(f, "") or getattr(bl, f))
    bl.like = h.get("name", "")
    bl.runs = (h.get("runs") or "").replace(";", " ").split()
    bl.key = [k for k in (h.get("key_cols") or "").split(",") if k]
    bl.by = [b for b in (h.get("by") or "").split(",") if b]
    for r in rows:
        c = r.get("column", "")
        if not c:
            continue
        if c not in bl.columns:
            bl.columns.append(c)
            bl.units[c] = r.get("unit", "")
        xs = _nums(r.get("values"))
        if r.get("key"):
            try:
                k = key_of(r["key"], len(bl.key))
            except (ValueError, TypeError):
                die("the baseline %s in the store is damaged (a key that is "
                    "not JSON)" % name)
            bl.keys[(c, k)] = xs
            if r.get("peer") and bl.key_peer.get(k) is None:
                bl.key_peer[k] = r["peer"]
        else:
            bl.groups[(c, r.get("peer", ""))] = xs
    return bl


def remove(st, prov, name):
    """A tombstone filed over it: the store is git, and what a baseline
    said stays in its history."""
    bl = load(st, name)
    from .whoran import operator
    _file(prov, [[name, storemod.now_iso(), operator(), "-removed-"] +
                 [""] * (len(COLUMNS) - 4)])
    st.reset()
    if exists(st, name):
        die("provost did not file the removal of %s where qd reads it (%s)"
            % (name, BASELINES))
    return bl


# -- holding runs against it ----------------------------------------------

class Against(object):
    def __init__(self):
        self.baseline = None
        self.columns = []
        self.runs = []                  # [{label, id, entry, ...}]
        self.groups = []                # [dict] one per column and peer
        self.keys = []                  # [dict] one per column and key
        self.notes = []
        self.drift = 5.0
        self.alpha = 0.05
        self.min_drift = 1.0


def candidate_grouping(bl, peers_now):
    """How later runs' keys are put in the baseline's peer groups: by the
    same columns, for a `by` rule; for a list, by the key's group in the
    baseline, else the peer group's definition now (a host added since)."""
    if not bl.peers:
        return lambda table: (lambda row, key: ALL)
    if bl.by:
        from .peers import Peers
        return grouping(Peers(bl.peers, bl.by))
    now = peers_now.assigner if peers_now is not None and \
        peers_now.members is not None else None

    def make(table):
        at = now(table) if now else None

        def one(row, key):
            p = bl.key_peer.get(key)
            if p is None and at is not None:
                p = at(row)
            return p
        return one
    return make


def against(bl, entries, tables, column=None, drift=5.0, alpha=0.05,
            peers_now=None, min_drift=1.0):
    """Later runs held against a baseline: per column and peer group the
    drift, effect, p and verdict; per key the drift.

    A significant difference is a change when it is at least min_drift
    percent: runs with no noise at all make any difference a sure one, and
    0.03% is not a slide anyone acts on."""
    res = Against()
    res.baseline, res.drift, res.alpha = bl, drift, alpha
    res.min_drift = min_drift
    if column:
        name = None
        for c in bl.columns:
            if c == column or tablemod.slug(c) == tablemod.slug(column):
                name = c
        if name is None:
            die("the baseline %s holds %s, not %s" % (
                bl.name, ", ".join(bl.columns), column))
        res.columns = [name]
    else:
        res.columns = list(bl.columns)
    from .compare import labels
    for lab, e, t in zip(labels(len(tables)), entries, tables):
        h = (e.meta.get("hosts") or {}) if e is not None else {}
        res.runs.append({"label": lab, "entry": e, "table": t,
                         "id": storemod.shown_id(e) if e is not None
                         else t.source or t.name,
                         "created": e.meta.get("created", "")
                         if e is not None else "", "hosts": h,
                         "rows": len(t.rows)})
    group_of = candidate_grouping(bl, peers_now)
    per_run, key_order, ungrouped = [], [], set()
    for t in tables:
        for k in bl.key:
            t.index(k)
        vals, peer_of, units = measure(t, res.columns, bl.key, bl.agg,
                                       group_of)
        for c, u in units.items():
            if u and bl.units.get(c) and u != bl.units[c]:
                res.notes.append("%s is in %s in %s and in %s in the "
                                 "baseline: left as it is, compare with care"
                                 % (c, u, t.name, bl.units[c]))
        for k, p in peer_of.items():
            if p is None:
                ungrouped.add(k)
            elif k not in key_order:
                key_order.append(k)
        per_run.append((vals, peer_of, group_medians(vals, peer_of)))
    ungrouped -= set(key_order)
    if ungrouped:
        res.notes.append("%s in no peer group of %s: left out" % (
            plural(len(ungrouped), "key"), bl.peers))
    tests = []
    for c in res.columns:
        peers_seen = set(p for (cc, p) in bl.groups if cc == c)
        for _, _, gm in per_run:
            peers_seen |= set(p for (cc, p) in gm if cc == c)
        from .stats import natural_sorted
        for p in natural_sorted(sorted(peers_seen)):
            base = bl.groups.get((c, p), [])
            vals = [gm.get((c, p)) for _, _, gm in per_run]
            got = [v for v in vals if v is not None]
            g = {"column": c, "peer": p, "base_n": len(base),
                 "base_median": median(base), "base_mad": mad(base),
                 "values": vals, "n": len(got), "median": median(got),
                 "drift_pct": pct(median(base), median(got)),
                 "effect": None, "p": None, "p_holm": None, "test": None,
                 "flags": []}
            if not got:
                g["verdict"] = "not measured"
            elif not base:
                g["verdict"] = "not in the baseline"
            elif len(base) < MIN_RUNS or len(got) < MIN_RUNS:
                g["verdict"] = "too few runs"
            else:
                mw = mann_whitney(got, base)
                g.update(effect=mw["effect"], p=mw["p"], test=mw["method"],
                         smallest_p=smallest_p(len(got), len(base)))
                tests.append(g)
            res.groups.append(g)
    for g, adj in zip(tests, holm([g["p"] for g in tests])):
        g["p_holm"] = adj
        g["verdict"] = "significant" if adj < alpha else "not significant"
        d = g["drift_pct"]
        if adj < alpha:
            if d is None or abs(d) >= min_drift:
                g["flags"].append("significant")
            else:
                g["verdict"] = "significant (under %s%%)" % fmt_num(min_drift)
    for g in res.groups:
        d = g["drift_pct"]
        if d is not None and g["base_n"] and abs(d) > drift:
            g["flags"].append("past %s%%" % fmt_num(drift))
    if tests and all(g["smallest_p"] >= alpha for g in tests):
        n = min(min(g["n"], g["base_n"]) for g in tests)
        res.notes.append("with %d runs a side the rank test cannot get "
                         "below p %s, so nothing can be significant at %s: "
                         "more runs (4 a side reach 0.029)" % (
                             n, p_text(min(g["smallest_p"] for g in tests)),
                             fmt_num(alpha)))
    for c in res.columns:
        keys = [k for (cc, k) in bl.keys if cc == c]
        keys += [k for k in key_order if k not in keys and
                 any(k in vals.get(c, {}) for vals, _, _ in per_run)]
        for k in keys:
            base = bl.keys.get((c, k), [])
            vals = [v.get(c, {}).get(k) for v, _, _ in per_run]
            got = [v for v in vals if v is not None]
            d = pct(median(base), median(got))
            flags = []
            if base and got and d is not None and abs(d) > drift:
                flags.append("drift %s" % pct_text(d))
            elif got and not base:
                flags.append("not in the baseline")
            peer = bl.key_peer.get(k)
            if peer is None:
                for _, po, _ in per_run:
                    if po.get(k) is not None:
                        peer = po[k]
                        break
            res.keys.append({"column": c, "peer": peer, "key": k,
                             "base_n": len(base), "base_median": median(base),
                             "values": vals, "median": median(got),
                             "drift_pct": d, "flags": flags})
    return res


def table_of(e, bl, asked=None):
    """The table of run e to hold against the baseline: the one asked
    for, else the one of the baseline's table name, else a run's only
    table (an import's table is named after its file)."""
    if asked:
        return e.load(asked)
    names = e.table_names()
    if bl.table in names or len(names) != 1:
        return e.load(bl.table)
    return e.load(names[0])


def flagged(res):
    return any(g["flags"] for g in res.groups) or \
        any(k["flags"] for k in res.keys)


def group_table(res):
    """The per column and peer group comparison as a table."""
    rows = []
    for g in res.groups:
        rows.append([g["column"], shown_peer(g["peer"]), str(g["base_n"]),
                     num(g["base_median"]), num(g["base_mad"]), str(g["n"]),
                     num(g["median"]), pct_num(g["drift_pct"]),
                     "" if g["effect"] is None else "%+.2f" % g["effect"],
                     p_text(g["p"]), p_text(g["p_holm"]), g["verdict"],
                     "; ".join(g["flags"])])
    return tablemod.Table(GROUP_COLUMNS, rows, "baseline")


def key_table(res, only_flagged=False):
    cols = ["column"] + (["peers"] if res.baseline.peers else []) + \
        list(res.baseline.key) + ["baseline"] + \
        [r["label"] for r in res.runs] + ["drift_pct", "flags"]
    rows = []
    for k in res.keys:
        if only_flagged and not k["flags"]:
            continue
        rows.append([k["column"]] +
                    ([shown_peer(k["peer"]) if k["peer"] is not None
                      else ""] if res.baseline.peers else []) +
                    list(k["key"]) + [num(k["base_median"])] +
                    [num(v) for v in k["values"]] +
                    [pct_num(k["drift_pct"]), "; ".join(k["flags"])])
    return tablemod.Table(cols, rows, "keys")


def show_table(bl):
    """What a baseline holds, one row per column and peer group."""
    rows = []
    for c in bl.columns:
        for p in bl.peer_names(c):
            xs = bl.groups[(c, p)]
            nkeys = sum(1 for (cc, k) in bl.keys if cc == c and
                        (bl.key_peer.get(k) or ALL) == p)
            rows.append([c, shown_peer(p), str(nkeys), str(len(xs)),
                         num(median(xs)), num(mad(xs)),
                         " ".join(num(x) for x in xs)])
    return tablemod.Table(["column", "peers", "keys", "runs", "median", "mad",
                           "values"], rows, "baseline")


def num(v):
    return "" if v is None else fmt_num(v)


def pct_num(d):
    if d is None or d in (float("inf"), float("-inf")):
        return ""
    return "%.1f" % d
