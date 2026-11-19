# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Martin J. Gallagher
"""Designed experiments on a fleet: doe designs and analyses, qd measures.

    qd doe plan CONFIG.json                  the design doe makes of it
    qd doe run CONFIG.json -s hosts.txt -- 'iperf3 -c peer -P {streams}'
    qd doe status NAME                       which points are measured
    qd doe analyze NAME -c COLUMN            doe's effects, ANOVA, power
    qd doe analyze NAME -c COLUMN --report   and doe's plots and HTML report

The design is design_of_experiments' (`doe`, pip install doehelper): its
config file (factors, levels, the design to use -- full or fractional
factorial, Plackett-Burman, Latin hypercube, central composite, ...), its
generator, its analysis.  qd adds the part doe leaves to a test script:
running each point of the design on the fleet, with every {factor} in the
command replaced by that point's level, and keeping what came back.

Each point is a qd run filed in provost like any other -- named after the
design, with the design, the point and its factor levels on every row --
so it can be shown, compared (`qd compare --group NAME -c mbps`) and
re-measured.  With --blocks-by ATTR the design's blocks run on different
host groups (one rack a block, say), which is what blocking is for.  A
point already measured is not run again unless asked (--redo), so an
interrupted design carries on where it stopped.

`qd doe analyze` reduces each point's runs to one response (the median of
COLUMN over the hosts, or --agg), writes them the way doe reads results --
run_<id>.json beside the design's design_matrix.json -- and hands them to
`doe analyze` (and `doe optimize` with --optimize).  doe needs Python 3.10
and numpy; qd runs it as a command, so qd itself keeps its 3.6 floor.
With --report doe's plots and HTML report are kept (in qd's cache unless a
directory is named), where qd web links them.  qd web's charts of a design
-- main effects, interactions, a Pareto of effect sizes -- are effects()'s
plain means of the points measured; the statistics stay doe's.
"""

import hashlib
import json
import os
import re
import shutil
import subprocess
import tempfile

from .common import die, read_text, write_text
from . import filing, store as storemod, table as tablemod, tools

DESIGNS = "qd.designs"
COLUMNS = ("design", "created", "command", "seed", "blocks_by", "config",
           "matrix")
FACTOR_RE = re.compile(r"\{([A-Za-z_][A-Za-z0-9_.-]*)\}")


def doe_argv():
    argv = tools.find_tool("doe")
    if not argv:
        die("designs come from design_of_experiments' doe, which is not "
            "installed here: pip install doehelper (it needs Python 3.10+)")
    return argv


def run_doe(args, cwd=None):
    try:
        p = subprocess.Popen(doe_argv() + list(args), stdout=subprocess.PIPE,
                             stderr=subprocess.STDOUT,
                             stdin=subprocess.DEVNULL, cwd=cwd)
        out, _ = p.communicate()
    except OSError as exc:
        die("cannot run doe: %s" % exc)
    return p.returncode, out.decode("utf-8", "replace")


def read_config(path):
    if not os.path.isfile(path):
        die("no such design config: %s" % path)
    try:
        cfg = json.loads(read_text(path))
    except ValueError as exc:
        die("%s is not JSON: %s" % (path, exc))
    if not isinstance(cfg, dict) or not cfg.get("factors"):
        die("%s has no factors: a doe config names its factors and their "
            "levels (see `doe init --list`)" % path)
    return cfg


def design_name(cfg, path, name=None):
    if name:
        return filing.dataset_name(name)
    meta = cfg.get("metadata") or {}
    base = meta.get("name") or os.path.splitext(os.path.basename(path))[0]
    return filing.dataset_name(re.sub(r"\s+", "-", base.strip()).lower())


def seed_of(cfg, seed=None):
    """doe's run-order seed: the one given, else one drawn from the config
    itself, so `qd doe plan` shows the order `qd doe run` will use."""
    if seed is not None:
        return seed
    text = json.dumps(cfg, sort_keys=True).encode("utf-8")
    return int(hashlib.sha1(text).hexdigest()[:8], 16) % 1000003


def generate(cfg, seed=None):
    """The design doe makes of cfg: its design_matrix.json, parsed."""
    work = tempfile.mkdtemp(prefix="qd-doe-")
    try:
        cfg = json.loads(json.dumps(cfg))
        settings = cfg.setdefault("settings", {})
        settings["out_directory"] = os.path.join(work, "out")
        settings.setdefault("test_script", "true")
        conf = os.path.join(work, "config.json")
        write_text(conf, json.dumps(cfg, indent=2))
        args = ["generate", "--config", conf, "--output",
                os.path.join(work, "runner.sh")]
        if seed is not None:
            args += ["--seed", str(seed)]
        rc, out = run_doe(args, cwd=work)
        path = os.path.join(work, "out", "design_matrix.json")
        if rc != 0 or not os.path.isfile(path):
            die("doe generate made no design (exit %d):\n%s"
                % (rc, out.strip()[-1500:]))
        return json.loads(read_text(path))
    finally:
        shutil.rmtree(work, ignore_errors=True)


def points(matrix):
    """[(run_id, block_id, [(factor, level)])] in the design's run order."""
    names = matrix.get("factor_names") or []
    out = []
    for r in matrix.get("runs") or []:
        fv = r.get("factor_values") or {}
        out.append((int(r["run_id"]), int(r.get("block_id") or 1),
                    [(n, str(fv.get(n, ""))) for n in names]))
    return out


def substitute(template, levels):
    """{factor} replaced by its level; a {name} that is no factor is an
    error, not a silent literal."""
    d = dict(levels)

    def one(m):
        if m.group(1) not in d:
            die("the command names {%s}, which is not a factor of the "
                "design (factors: %s)" % (m.group(1), ", ".join(d)))
        return d[m.group(1)]
    return FACTOR_RE.sub(one, template)


def unused(template, levels):
    named = set(FACTOR_RE.findall(template))
    return [k for k, _ in levels if k not in named]


def file_design(st, prov, name, command, seed, blocks_by, cfg, matrix):
    b = filing.Batch()
    b.add_own(DESIGNS, filing.own_tsv(COLUMNS, [[
        name, storemod.now_iso(), command, "" if seed is None else str(seed),
        blocks_by or "", storemod.escape(json.dumps(cfg, sort_keys=True)),
        storemod.escape(json.dumps(matrix, sort_keys=True))]]))
    try:
        filing.notes_of(prov, b, "design")
    finally:
        b.cleanup()


def exists(st, name):
    return any(r.get("design") == name for r in st._read_own(DESIGNS))


def load(st, name):
    """The latest design filed under name: (row, cfg, matrix)."""
    rows = [r for r in st._read_own(DESIGNS) if r.get("design") == name]
    if not rows:
        known = sorted(set(r.get("design") for r in st._read_own(DESIGNS)))
        die("no design %r in the store %s%s" % (
            name, st.shown(), (" (designs: %s)" % ", ".join(known))
            if known else ""))
    row = rows[-1]
    try:
        cfg = json.loads(storemod.unescape(row.get("config", "")))
        matrix = json.loads(storemod.unescape(row.get("matrix", "")))
    except ValueError:
        die("the design %s in the store is damaged (its config or matrix "
            "is not JSON)" % name)
    return row, cfg, matrix


def point_runs(st, name):
    """{run_id: [qd runs of that point, oldest first]}."""
    out = {}
    for e in st.entries():
        if e.meta.get("group") == name and \
                str(e.meta.get("part", "")).isdigit():
            out.setdefault(int(e.meta["part"]), []).append(e)
    return out


def names(st):
    """Every design in the store, in the order they were first filed."""
    out = []
    for r in st._read_own(DESIGNS):
        if r.get("design") and r["design"] not in out:
            out.append(r["design"])
    return out


STATUS_COLUMNS = ["point", "block", "factors", "runs", "last_run", "ok"]


def status_rows(st, name):
    """(the design's row, a STATUS_COLUMNS row per point, how many points
    have been measured)."""
    row, _, matrix = load(st, name)
    runs = point_runs(st, name)
    rows = []
    for rid, blk, lv in points(matrix):
        rs = runs.get(rid, [])
        last = rs[-1] if rs else None
        h = (last.meta.get("hosts") or {}) if last else {}
        rows.append([str(rid), str(blk), " ".join("%s=%s" % kv for kv in lv),
                     str(len(rs)), last.id if last else "",
                     ("%d/%d" % (h.get("ok", 0), h.get("total", 0))) if h
                     else ""])
    return row, rows, sum(1 for r in rows if r[3] != "0")


def responses(st, name, column, agg="median"):
    """[(run_id, value or None, n)]: each point's response, one number
    from all its runs' rows (hosts that answered)."""
    from .stats import AGGS
    if agg not in AGGS:
        die("unknown --agg %r" % agg)
    _, _, matrix = load(st, name)
    runs = point_runs(st, name)
    out = []
    for rid, _, _ in points(matrix):
        cells = []
        for e in runs.get(rid, []):
            t = e.load("data")
            if not t.has(column):
                continue
            si = t.index("status") if t.has("status") else None
            # each cell on its family's base scale (bytes, seconds): one
            # point's 900M and another's 1.2G are one scale across runs
            nums = [tablemod.to_base(c)[0] for c in t.values(column)]
            for r, v in zip(t.rows, nums):
                if (si is None or r[si] == "ok") and v is not None:
                    cells.append(repr(v))
        v = AGGS[agg](cells) if cells else None
        if v is not None and not isinstance(v, float):
            try:
                v = float(v)
            except (TypeError, ValueError):
                v = None
        out.append((rid, v, len(cells)))
    return out


def analyze(st, name, column, agg="median", optimize=False, extra=(),
            report=None):
    """Write the responses as doe reads them and run doe analyze (and
    optimize); returns (doe's text, the per-point responses).  With report
    (a directory, from report_dir), doe's plots and HTML report are kept
    there, with the results and config that made them."""
    row, cfg, matrix = load(st, name)
    resp = responses(st, name, column, agg)
    got = [r for r in resp if r[1] is not None]
    if len(got) < 2:
        die("only %d of the design's %d points have a %s to analyse: "
            "`qd doe status %s` says which are measured" % (
                len(got), len(resp), column, name))
    work = tempfile.mkdtemp(prefix="qd-doe-")
    try:
        out_dir = os.path.join(report or work, "results")
        os.makedirs(out_dir)
        write_text(os.path.join(out_dir, "design_matrix.json"),
                   json.dumps(matrix, indent=2))
        rname = re.sub(r"[^A-Za-z0-9_]+", "_", column).strip("_") or "response"
        for rid, v, _ in got:
            write_text(os.path.join(out_dir, "run_%d.json" % rid),
                       json.dumps({rname: v}))
        cfg = json.loads(json.dumps(cfg))
        old = dict((r.get("name"), r) for r in cfg.get("responses") or [])
        keep = old.get(rname) or old.get(column) or {}
        cfg["responses"] = [{"name": rname,
                             "optimize": keep.get("optimize", "maximize")}]
        settings = cfg.setdefault("settings", {})
        settings["out_directory"] = out_dir
        settings.setdefault("test_script", "true")
        if report:
            settings["processed_directory"] = report
        conf = os.path.join(report or work, "config.json")
        write_text(conf, json.dumps(cfg, indent=2))
        args = ["analyze", "--config", conf, "--results-dir", out_dir] + \
            ([] if report else ["--no-plots", "--no-report"]) + \
            ["--partial"] + list(extra)
        rc, text = run_doe(args, cwd=work)
        if rc != 0:
            die("doe analyze failed (exit %d):\n%s" % (rc, text[-2000:]))
        if optimize:
            rc, more = run_doe(["optimize", "--config", conf, "--results-dir",
                                out_dir, "--partial"], cwd=work)
            text += "\n" + more
        return clean(text), resp
    finally:
        shutil.rmtree(work, ignore_errors=True)


def clean(text):
    """doe's report, less the warning about the stand-in test script qd
    gives it (qd ran the tests; doe only reads their results)."""
    return "\n".join(ln for ln in text.splitlines()
                     if "test_script" not in ln).strip("\n")


# ---------------------------------------------------------------------------
# doe's report kept, and the figures qd web draws (QD-068)
# ---------------------------------------------------------------------------

REPORT_MARK = ".qd-doe-report"


def report_root():
    """Where qd keeps doe's reports when no directory is named: its cache
    (never the store, which provost commits whole), what qd web serves at
    /doe/."""
    return os.path.join(storemod.cache_root(), "doe")


def safe_part(text):
    return re.sub(r"[^A-Za-z0-9_.@-]+", "_", text).strip("._") or "_"


def store_key(st):
    return hashlib.sha1(st.root.encode("utf-8")).hexdigest()[:12]


def report_rel(st, name, column):
    """The report's place under report_root(): the store, the design, the
    column -- so two stores' designs of one name never share one."""
    return "/".join([store_key(st), safe_part(name), safe_part(column)])


def report_path(st, name, column):
    """The cache's place for a design's report on one column."""
    return os.path.join(report_root(),
                        *report_rel(st, name, column).split("/"))


def report_dir(st, name, column, where=None):
    """The directory doe's report goes in, made ready: the one asked for,
    else the cache's.  A directory qd made before is emptied first (so no
    plot from an earlier analysis is left beside a new report); one that
    holds anything else is refused, never emptied."""
    path = os.path.abspath(os.path.expanduser(where)) if where else \
        report_path(st, name, column)
    if os.path.exists(path) and not os.path.isdir(path):
        die("--report %s is a file, not a directory" % path)
    if os.path.isdir(path) and os.listdir(path):
        if not os.path.isfile(os.path.join(path, REPORT_MARK)):
            die("--report %s holds files qd did not put there: name a new "
                "or empty directory" % path)
        for f in os.listdir(path):
            p = os.path.join(path, f)
            if os.path.isdir(p) and not os.path.islink(p):
                shutil.rmtree(p)
            else:
                os.remove(p)
    try:
        if not os.path.isdir(path):
            os.makedirs(path)
        write_text(os.path.join(path, REPORT_MARK),
                   "doe's report for design %s, column %s, made by qd doe "
                   "analyze --report; qd empties this directory when it "
                   "makes the report again\n" % (name, column))
    except (IOError, OSError) as exc:
        die("cannot make the report directory %s: %s"
            % (path, getattr(exc, "strerror", None) or exc))
    return path


def report_files(path):
    """What doe left in a report directory: (the HTML report or None, its
    plots), names relative to path."""
    if not os.path.isdir(path):
        return None, []
    names_ = sorted(os.listdir(path))
    html = "report.html" if "report.html" in names_ else None
    return html, [f for f in names_ if f.lower().endswith(".png")]


def response_columns(st, name):
    """The numeric columns of the design's runs, less its factors, the
    hosts' attributes and qd's bookkeeping (compare's rule): what a
    response can be, in the order first seen."""
    from .compare import VOLATILE
    from .stats import BOOKKEEPING
    _, _, matrix = load(st, name)
    factors = set(matrix.get("factor_names") or [])
    out = []
    for _, es in sorted(point_runs(st, name).items()):
        for e in es:
            t = e.load("data")
            skip = factors | set(BOOKKEEPING) | set(VOLATILE) | \
                set(("status", "error"))
            if hasattr(e, "setting_columns"):
                skip |= e.setting_columns()
            for c in t.columns:
                if c in out or c in skip:
                    continue
                if t.kind(c) == "num":
                    out.append(c)
    return out


def level_order(levels, declared):
    """A factor's levels in the order a chart's axis wants them: by value
    when every one is a number, else as the config lists them."""
    try:
        return sorted(levels, key=float)
    except ValueError:
        pass
    known = [str(v) for v in declared or []]
    return sorted(levels, key=lambda v: (known.index(v) if v in known
                                         else len(known), levels.index(v)))


def _mean(xs):
    return sum(xs) / float(len(xs)) if xs else None


def effects(st, name, column, agg="median"):
    """The figures qd web charts for one response: each point's value (as
    `qd doe analyze` reduces it), each factor's level means (main effects),
    each pair's cell means (interactions) and a Pareto of effect sizes.
    Plain means of the points measured -- a point with no value is left
    out of every mean, never counted as zero; significance, ANOVA and the
    rest are doe's (qd doe analyze, and its report)."""
    _, cfg, matrix = load(st, name)
    pts = points(matrix)
    factors = matrix.get("factor_names") or []
    declared = dict((f.get("name"), f.get("levels"))
                    for f in cfg.get("factors") or [] if isinstance(f, dict))
    resp = dict((rid, (v, n)) for rid, v, n in
                responses(st, name, column, agg))
    levels = {}
    for f in factors:
        seen = []
        for _, _, lv in pts:
            v = dict(lv)[f]
            if v not in seen:
                seen.append(v)
        levels[f] = level_order(seen, declared.get(f))
    point_rows = []
    for rid, blk, lv in pts:
        v, n = resp.get(rid, (None, 0))
        point_rows.append({"point": rid, "block": blk,
                           "levels": dict(lv), "value": v, "samples": n})
    measured = [p for p in point_rows if p["value"] is not None]

    def cell(conds):
        xs = [p["value"] for p in measured
              if all(p["levels"][f] == v for f, v in conds)]
        return {"mean": _mean(xs), "n": len(xs)}

    main = []
    for f in factors:
        cells = [dict(cell([(f, v)]), level=v) for v in levels[f]]
        means = [c["mean"] for c in cells if c["mean"] is not None]
        first = cells[0]["mean"] if cells else None
        last = cells[-1]["mean"] if cells else None
        main.append({
            "factor": f, "levels": cells,
            # the last level's mean less the first's (high less low)
            "effect": last - first if first is not None and
            last is not None and len(cells) > 1 else None,
            # the spread of the level means: what the Pareto ranks
            "size": max(means) - min(means) if len(means) > 1 else None})
    inter = []
    for i, a in enumerate(factors):
        for b in factors[i + 1:]:
            grid = [[cell([(a, va), (b, vb)]) for va in levels[a]]
                    for vb in levels[b]]
            eff = None
            if len(levels[a]) == 2 and len(levels[b]) == 2 and \
                    all(c["mean"] is not None for r in grid for c in r):
                # two-level factors: half the difference between a's
                # effect at b's high level and at b's low one
                eff = ((grid[1][1]["mean"] - grid[1][0]["mean"]) -
                       (grid[0][1]["mean"] - grid[0][0]["mean"])) / 2.0
            inter.append({"a": a, "b": b, "a_levels": levels[a],
                          "b_levels": levels[b], "cells": grid,
                          "effect": eff,
                          "size": abs(eff) if eff is not None else None})
    pareto = [{"term": m["factor"], "kind": "main", "effect": m["effect"],
               "size": m["size"]} for m in main if m["size"] is not None]
    pareto += [{"term": "%s x %s" % (x["a"], x["b"]), "kind": "interaction",
                "effect": x["effect"], "size": x["size"]}
               for x in inter if x["size"] is not None]
    pareto.sort(key=lambda r: -r["size"])
    return {"design": name, "column": column, "agg": agg,
            "factors": factors, "levels": levels,
            "points": point_rows, "measured": len(measured),
            "total": len(point_rows), "main": main,
            "interactions": inter, "pareto": pareto}
