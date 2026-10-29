# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Martin J. Gallagher
"""Designed experiments on a fleet: doe designs and analyses, qd measures.

    qd doe plan CONFIG.json                  the design doe makes of it
    qd doe run CONFIG.json -s hosts.txt -- 'iperf3 -c peer -P {streams}'
    qd doe status NAME                       which points are measured
    qd doe analyze NAME -c COLUMN            doe's effects, ANOVA, power

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
`doe analyze` (and `doe optimize` with --optimize).  doe needs Python 3.9
and numpy; qd runs it as a command, so qd itself keeps its 3.6 floor.
"""

import json
import os
import re
import shutil
import subprocess
import tempfile

from .common import die, read_text, write_text
from . import filing, store as storemod, tools

DESIGNS = "qd.designs"
COLUMNS = ("design", "created", "command", "seed", "blocks_by", "config",
           "matrix")
FACTOR_RE = re.compile(r"\{([A-Za-z_][A-Za-z0-9_.-]*)\}")


def doe_argv():
    argv = tools.find_tool("doe")
    if not argv:
        die("designs come from design_of_experiments' doe, which is not "
            "installed here: pip install doehelper (it needs Python 3.9+)")
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
            nums = t.numbers(column)
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


def analyze(st, name, column, agg="median", optimize=False, extra=()):
    """Write the responses as doe reads them and run doe analyze (and
    optimize); returns (doe's text, the per-point responses)."""
    row, cfg, matrix = load(st, name)
    resp = responses(st, name, column, agg)
    got = [r for r in resp if r[1] is not None]
    if len(got) < 2:
        die("only %d of the design's %d points have a %s to analyse: "
            "`qd doe status %s` says which are measured" % (
                len(got), len(resp), column, name))
    work = tempfile.mkdtemp(prefix="qd-doe-")
    try:
        out_dir = os.path.join(work, "results")
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
        conf = os.path.join(work, "config.json")
        write_text(conf, json.dumps(cfg, indent=2))
        args = ["analyze", "--config", conf, "--results-dir", out_dir,
                "--no-plots", "--no-report", "--partial"] + list(extra)
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
