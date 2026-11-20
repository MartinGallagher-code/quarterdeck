# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Martin J. Gallagher
"""Designed experiments on a fleet: doe designs and analyses, qd measures.

    qd doe init fio                          a starting config: fio's screen
    qd doe plan CONFIG.json                  the design doe makes of it
    qd doe run CONFIG.json -s hosts.txt -- 'iperf3 -c peer -P {streams}'
    qd doe status NAME                       which points are measured
    qd doe analyze NAME -c COLUMN[,COL...]   doe's effects, ANOVA, power
    qd doe analyze NAME -c COLUMN --report   and doe's plots and HTML report
    qd doe next NAME -c RESPONSE             a CCD/Box-Behnken follow-up
    qd doe run FOLLOWUP.json --like NAME     where NAME ran, as it held
    qd doe surface NAME -c RESPONSE          doe's response surface
    qd doe optimize STUDY -c RESPONSE --budget N   rounds until an optimum

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

`qd doe analyze` reduces each point's runs to one response per column (the
median of COLUMN over the hosts, or --agg), writes them the way doe reads
results -- run_<id>.json beside the design's design_matrix.json, one key per
response, and no key at all for a response a point did not measure -- and
hands them to `doe analyze` (and `doe optimize` with --optimize).  Several
responses go to doe in one go, and doe's main effects (its --csv tables)
are ranked per response, the big factors being those inside doe's own 80%
Pareto line.  doe needs Python 3.10 and numpy; qd runs it as a command, so
qd itself keeps its 3.6 floor.

A config may carry what qd needs beyond doe's own keys, which doe ignores:
`metadata.qd_command`, the command a point runs (so `qd doe run CONFIG`
needs no command after --), `metadata.qd_timeout`, the seconds one point
needs (qd doe run's --timeout is at least that), and a `column` on each response, the column of
the filed run it is read from.  doe's `fixed_factors` -- what the design
holds still -- are put into the command by {name} like the factors.
`qd doe init fio` writes such a config: QD-067's Plackett-Burman screen of
fio's parameters on one drive of one host.

`qd doe next` (QD-069) takes a screen's ranked effects for one response
and writes a follow-up config: the big numeric factors varied, the rest
held at their better level, the design doe suggest's response-surface
choice, the study the screen's (metadata.qd_study).  `qd doe run --like`
runs it on the hosts the screen ran on, holding what the screen held.
The screen and its follow-ups are a study; quarterdeck/study.py lines up
every run of it (`qd compare --study`, qd web's study view, QD-070).

`qd doe optimize` (QD-072, quarterdeck/optimize.py) runs further rounds
until an optimum is found, with doe's steepest path and next batch (the
last section here) choosing the points.

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


def fixed_of(cfg):
    """doe's fixed_factors: what the design holds still, {name: value}."""
    fx = cfg.get("fixed_factors") or {}
    if not isinstance(fx, dict):
        return []
    return [(str(k), str(v)) for k, v in sorted(fx.items())]


def command_of(cfg):
    """The command the config names for its points (metadata.qd_command),
    or ""."""
    meta = cfg.get("metadata") or {}
    cmd = meta.get("qd_command") if isinstance(meta, dict) else None
    return cmd.strip() if isinstance(cmd, str) else ""


def timeout_of(cfg):
    """The seconds one point needs (metadata.qd_timeout), or None.  qd doe
    run uses at least this as its per-host --timeout, so a point that runs
    longer than qd's 60 s default is not stopped part-way."""
    meta = cfg.get("metadata") or {}
    v = meta.get("qd_timeout") if isinstance(meta, dict) else None
    try:
        v = float(v)
    except (TypeError, ValueError):
        return None
    return v if v > 0 else None


def substitute(template, levels, fixed=()):
    """{factor} replaced by its level, {name} of a fixed factor by its
    value; a {name} that is neither is an error, not a silent literal."""
    d = dict(fixed)
    d.update(dict(levels))

    def one(m):
        if m.group(1) not in d:
            die("the command names {%s}, which is not a factor of the "
                "design (factors: %s%s)" % (
                    m.group(1), ", ".join(k for k, _ in levels),
                    ("; held fixed: %s" % ", ".join(k for k, _ in fixed))
                    if fixed else ""))
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


def answered(runs):
    """Whether any of a point's runs had a host answer ok: a point every
    run of which failed everywhere has measured nothing, and `qd doe run`
    runs it again."""
    return any(((e.meta.get("hosts") or {}).get("ok") or 0) > 0
               for e in runs)


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
    have been measured: a host answered ok)."""
    row, _, matrix = load(st, name)
    runs = point_runs(st, name)
    rows, done = [], 0
    for rid, blk, lv in points(matrix):
        rs = runs.get(rid, [])
        done += 1 if answered(rs) else 0
        last = rs[-1] if rs else None
        h = (last.meta.get("hosts") or {}) if last else {}
        rows.append([str(rid), str(blk), " ".join("%s=%s" % kv for kv in lv),
                     str(len(rs)), last.id if last else "",
                     ("%d/%d" % (h.get("ok", 0), h.get("total", 0))) if h
                     else ""])
    return row, rows, done


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


def response_name(column):
    """A response's name as doe keeps it: the column, made a word."""
    return re.sub(r"[^A-Za-z0-9_]+", "_", column).strip("_") or "response"


def specs(cfg, columns=None):
    """[(response name, column, optimize)]: the -c columns given (each a
    column, or a response of the config by name), else every response of
    the config that names its column; [] when neither says."""
    rs = [r for r in cfg.get("responses") or [] if isinstance(r, dict)]
    by_name = dict((r.get("name"), r) for r in rs)
    by_col = dict((r.get("column"), r) for r in rs if r.get("column"))
    out = []
    if columns:
        for c in columns:
            r = by_col.get(c) or by_name.get(c) or \
                by_name.get(response_name(c)) or {}
            col = r.get("column") or c
            out.append((r.get("name") if r.get("column") else
                        response_name(col), col,
                        r.get("optimize", "maximize")))
    else:
        out = [(r["name"], r["column"], r.get("optimize", "maximize"))
               for r in rs if r.get("name") and r.get("column")]
    seen = set()
    for n, _, _ in out:
        if n in seen:
            die("two responses are both named %s: -c each column once" % n)
        seen.add(n)
    return out


PARETO = 80.0   # doe's pareto_threshold: its Pareto chart's line


def big_factors(effects):
    """The first of doe's ranked effects whose contributions reach its 80%
    Pareto line: the few that matter, the rest being the trivial many."""
    out, total = [], 0.0
    for f, _, pct in effects:
        if total >= PARETO or not pct:
            break
        out.append(f)
        total += pct
    return out


def level_key(x):
    """doe's order of a factor's levels: numbers by value, then the rest
    by name.  A positive main effect is the second level's mean over the
    first's."""
    try:
        return (0, float(x), "")
    except ValueError:
        return (1, 0.0, x)


def best_levels(matrix, effects, optimize):
    """{factor: the level doe's effect says is better for this response}."""
    lv = {}
    for _, _, levels in points(matrix):
        for f, v in levels:
            lv.setdefault(f, set()).add(v)
    out = {}
    for f, eff, _ in effects:
        ls = sorted(lv.get(f, ()), key=level_key)
        if len(ls) != 2 or not eff:
            continue
        higher = ls[1] if eff > 0 else ls[0]
        lower = ls[0] if eff > 0 else ls[1]
        out[f] = higher if optimize != "minimize" else lower
    return out


def read_effects(path):
    """doe's main_effects_<response>.csv: [(factor, effect, % contribution)]
    in doe's order, largest first; [] when doe wrote none."""
    import csv
    if not os.path.isfile(path):
        return []
    out = []
    with open(path) as f:
        for r in csv.DictReader(f):
            try:
                out.append((r["factor_name"], float(r["main_effect"]),
                            float(r["pct_contribution"])))
            except (KeyError, TypeError, ValueError):
                continue
    return out


def read_tables(csv_dir, rname):
    """doe's other --csv tables for one response, as rows of text:
    {"model_adequacy": [[metric, value]], "stationary_point": ...,
    "cross_validation": ...}; a table doe did not write is not there."""
    import csv
    safe = rname.replace("/", "_").replace(" ", "_")
    out = {}
    for t in ("model_adequacy", "stationary_point", "cross_validation"):
        path = os.path.join(csv_dir, "%s_%s.csv" % (t, safe))
        if os.path.isfile(path):
            with open(path) as f:
                out[t] = [r for r in csv.reader(f)][1:]
    return out


def analyze(st, name, columns=None, agg="median", optimize=False, extra=(),
            report=None, detail=None):
    """Write the responses as doe reads them and run doe analyze (and
    optimize) on all of them at once.  Returns (doe's text, the responses
    [(name, column, optimize, [(run_id, value or None, n)])], doe's ranked
    effects {name: [(factor, effect, pct)]}, the design's matrix).  With
    report (a directory, from report_dir), doe's plots and HTML report are
    kept there, with the results and config that made them.  With detail
    (a dict), doe's own texts and the rest of its --csv tables are put in
    it: "analyze", "optimize" and "csv" {response: {table: rows}}."""
    row, cfg, matrix = load(st, name)
    sp = specs(cfg, columns)
    if not sp:
        die("analyze what? -c COLUMN[,COLUMN...]: the responses, as qd show "
            "names them (or a config whose responses name their column)")
    allr = [(n, c, o, responses(st, name, c, agg)) for n, c, o in sp]
    usable = [r for r in allr if sum(1 for x in r[3] if x[1] is not None) >= 2]
    if not usable:
        n = max(sum(1 for x in r[3] if x[1] is not None) for r in allr)
        die("only %d of the design's %d points have a %s to analyse: "
            "`qd doe status %s` says which are measured" % (
                n, len(allr[0][3]), " or ".join(c for _, c, _, _ in allr),
                name))
    work = tempfile.mkdtemp(prefix="qd-doe-")
    try:
        out_dir = os.path.join(report or work, "results")
        csv_dir = os.path.join(work, "effects")
        os.makedirs(out_dir)
        write_text(os.path.join(out_dir, "design_matrix.json"),
                   json.dumps(matrix, indent=2))
        # one run_<id>.json a point, a key per response it measured: a
        # response not measured is no key -- blank, never 0 -- and doe
        # leaves that point out of that response's analysis
        per = {}
        for rname, _, _, resp in usable:
            for rid, v, _ in resp:
                if v is not None:
                    per.setdefault(rid, {})[rname] = v
        for rid, vals in sorted(per.items()):
            write_text(os.path.join(out_dir, "run_%d.json" % rid),
                       json.dumps(vals, sort_keys=True))
        cfg = json.loads(json.dumps(cfg))
        cfg["responses"] = [{"name": rname, "optimize": o}
                            for rname, _, o, _ in usable]
        settings = cfg.setdefault("settings", {})
        settings["out_directory"] = out_dir
        settings.setdefault("test_script", "true")
        if report:
            settings["processed_directory"] = report
        conf = os.path.join(report or work, "config.json")
        write_text(conf, json.dumps(cfg, indent=2))
        args = ["analyze", "--config", conf, "--results-dir", out_dir] + \
            ([] if report else ["--no-plots", "--no-report"]) + \
            ["--partial", "--csv", csv_dir] + list(extra)
        rc, text = run_doe(args, cwd=work)
        if rc != 0:
            die("doe analyze failed (exit %d):\n%s" % (rc, text[-2000:]))
        effects = {}
        for rname, _, _, _ in usable:
            safe = rname.replace("/", "_").replace(" ", "_")
            effects[rname] = read_effects(
                os.path.join(csv_dir, "main_effects_%s.csv" % safe))
        if detail is not None:
            detail["analyze"] = text
            detail["csv"] = dict((r[0], read_tables(csv_dir, r[0]))
                                 for r in usable)
        if optimize:
            rc, more = run_doe(["optimize", "--config", conf, "--results-dir",
                                out_dir, "--partial"], cwd=work)
            text += "\n" + more
            if detail is not None:
                detail["optimize"] = more
        return clean(text), allr, effects, matrix
    finally:
        shutil.rmtree(work, ignore_errors=True)


def ranking_lines(allr, effects, matrix, width=80, indent="  "):
    """Lines a response: its big factors, each with its share of the
    effect and the level that is better for that response, then the rest
    in doe's order."""
    import textwrap
    lines = []
    head = max([len(r[0]) for r in allr] + [8]) + 2
    pad = indent + " " * head
    wrap = max(40, (width or 80))

    def put(first, text):
        lines.extend(textwrap.wrap(text, wrap, initial_indent=first,
                                   subsequent_indent=pad,
                                   break_on_hyphens=False) or [first])

    for rname, _, o, resp in allr:
        first = indent + rname.ljust(head)
        eff = effects.get(rname)
        if eff is None:
            n = sum(1 for x in resp if x[1] is not None)
            put(first, "not analysed: %d point%s measured it" % (
                n, "" if n == 1 else "s"))
            continue
        if not eff:
            put(first, "doe gave no main effects")
            continue
        big = big_factors(eff)
        best = best_levels(matrix, eff, o)
        put(first, "big: " + ", ".join(
            "%s %.0f%%%s" % (f, p, (" (%s %s)" % (
                "max" if o != "minimize" else "min", best[f]))
                if f in best else "")
            for f, _, p in eff if f in big))
        rest = ["%s %.0f%%" % (f, p) for f, _, p in eff if f not in big]
        if rest:
            put(pad, "then: " + ", ".join(rest))
    return lines


# ---------------------------------------------------------------------------
# The follow-up: `qd doe next SCREEN -c RESPONSE` (QD-069)
# ---------------------------------------------------------------------------

SURFACES = ("central_composite", "box_behnken")
MAX_FACTORS = 4     # a surface over more is rarely worth its runs
MIN_FACTORS = 2     # and one over fewer has no shape to show
BUDGET = 30         # doe suggest's room: a CCD on 2, a Box-Behnken on 3 or 4


def study_of(cfg, name):
    """The study a design belongs to: its metadata.qd_study, else its own
    name (a screen starts one)."""
    meta = cfg.get("metadata") or {}
    s = meta.get("qd_study") if isinstance(meta, dict) else None
    return s if isinstance(s, str) and s.strip() else name


def numeric(factor):
    """Whether a factor can be a surface's axis: not categorical, and two
    levels that are numbers."""
    if not isinstance(factor, dict) or factor.get("type") == "categorical":
        return False
    lv = factor.get("levels") or []
    if len(lv) != 2:
        return False
    try:
        float(lv[0])
        float(lv[1])
    except (TypeError, ValueError):
        return False
    return True


def suggest(n, budget):
    """doe suggest --goal response_surface for n numeric factors:
    (operation, doe's estimate of its runs, doe's reasons, doe's text)."""
    rc, text = run_doe(["suggest", "--factors", str(n), "--budget",
                        str(budget), "--goal", "response_surface"])
    m = re.search(r"operation\s*:\s*(\S+)", text)
    if rc != 0 or not m:
        die("doe suggest gave no design (exit %d):\n%s"
            % (rc, text.strip()[-1500:]))
    est = re.search(r"estimated runs\s*:\s*(\d+)", text)
    why = [ln.strip()[2:] for ln in text.splitlines()
           if ln.strip().startswith("- ")]
    return m.group(1), int(est.group(1)) if est else None, why, text


def choose(cfg, effects, best, picked=None):
    """Which of the screen's factors the follow-up varies.  Returns
    (varied [factor dicts], held [(name, level, why)], said [lines]).

    By default the big factors (inside doe's Pareto line) that are numeric,
    at most MAX_FACTORS, topped up to MIN_FACTORS from the next numeric
    factors that moved the response at all; with `picked`, those.  A
    categorical factor is never varied: it is held at its better level,
    and said.  Every factor not varied is held: at its better level for
    this response, or, where the screen saw no effect, at its first."""
    facs = [f for f in cfg.get("factors") or [] if isinstance(f, dict)]
    by = dict((f.get("name"), f) for f in facs)
    pct = dict((f, p) for f, _, p in effects)
    order = [f for f, _, _ in effects if f in by] + \
        [f.get("name") for f in facs if f.get("name") not in pct]
    said = []
    if picked:
        bad = [p for p in picked if p not in by]
        if bad:
            die("--factors: %s %s not a factor of the screen (its factors: "
                "%s)" % (", ".join(bad), "is" if len(bad) == 1 else "are",
                         ", ".join(f.get("name") for f in facs)))
        want = list(picked)
    else:
        big = big_factors(effects)
        want = [f for f in big if numeric(by[f])][:MAX_FACTORS]
        dropped = [f for f in big if numeric(by[f])][MAX_FACTORS:]
        if dropped:
            said.append("%s also inside the Pareto line: a surface over "
                        "more than %d factors is rarely worth its runs "
                        "(--factors to choose)" % (", ".join(dropped),
                                                   MAX_FACTORS))
        if len(want) < MIN_FACTORS:
            more = [f for f in order if f not in want and numeric(by[f])
                    and pct.get(f)][:MIN_FACTORS - len(want)]
            if more:
                said.append("%s added: the next largest numeric effect%s, "
                            "so the surface has two dimensions" % (
                                ", ".join(more),
                                "" if len(more) == 1 else "s"))
            want += more
    varied, held = [], []
    for name in order:
        f = by[name]
        if name in want and numeric(f):
            varied.append(f)
            continue
        level = best.get(name)
        if name in want or (not picked and name in big_factors(effects)):
            kind = "categorical" if f.get("type") == "categorical" else \
                "not numeric"
            said.append("%s is %s: a central composite or Box-Behnken "
                        "varies a number between two levels, so it is "
                        "held at %s%s" % (
                            name, kind, level or (f.get("levels") or [""])[0],
                            ", its better level" if level else
                            ", its first level"))
        if level is not None:
            held.append((name, level, "better"))
        else:
            held.append((name, str((f.get("levels") or [""])[0]), "first"))
    return varied, held, said


def follow_up(screen, row, cfg, rname, column, optimize, varied, held,
              operation):
    """The follow-up's doe config: the varied factors at the screen's
    levels, the rest and the screen's own fixed factors held, the
    screen's command and responses, and the study it belongs to."""
    meta = dict((k, v) for k, v in (cfg.get("metadata") or {}).items()
                if k not in ("name", "description", "qd_note", "qd_like"))
    name = filing.dataset_name("%s-%s-%s" % (
        screen, rname.replace("_", "-"),
        "ccd" if operation == "central_composite" else
        "bbd" if operation == "box_behnken" else operation))
    fixed = dict(fixed_of(cfg))
    for n, v, _ in held:
        fixed[n] = v
    meta.update({
        "name": name,
        "description": "%s on %s of %s's factors, for %s (QD-069): %s "
                       "held." % (operation.replace("_", " "),
                                  " and ".join(f["name"] for f in varied),
                                  screen, rname,
                                  ", ".join("%s=%s" % (n, v)
                                            for n, v, _ in held) or
                                  "nothing else"),
        "qd_command": row.get("command") or command_of(cfg),
        "qd_study": study_of(cfg, screen),
        "qd_follows": {"design": screen, "response": rname,
                       "column": column, "optimize": optimize},
    })
    factors = []
    for f in varied:
        f = json.loads(json.dumps(f))
        f["type"] = "continuous"
        factors.append(f)
    out = {"metadata": meta, "factors": factors, "fixed_factors": fixed,
           "responses": json.loads(json.dumps(cfg.get("responses") or [])),
           "settings": {"operation": operation, "block_count": 1}}
    return name, out


def between(matrix, varied):
    """[(factor, level)]: a level the design lays out between a factor's
    two whole-number levels that is not a whole number itself (Box-Behnken
    puts 1..32's middle at 16.5), which a tool counting jobs or I/Os
    cannot take."""
    out = []
    for f in varied:
        try:
            whole = all(float(x).is_integer() for x in f["levels"])
        except (TypeError, ValueError):
            continue
        if not whole:
            continue
        seen = set()
        for _, _, levels in points(matrix):
            for n, v in levels:
                if n != f["name"] or v in seen:
                    continue
                seen.add(v)
                try:
                    if not float(v).is_integer():
                        out.append((n, v))
                except ValueError:
                    pass
    return out


def screen_hosts(st, name):
    """The hosts a design's points ran on, in the order they first ran:
    [(host row of its latest point run there, via)].  A host is there
    whether it answered or not."""
    runs = point_runs(st, name)
    seen, out = {}, []
    for rid in sorted(runs):
        for e in runs[rid]:
            for h in e.store.host_rows(e.id):
                n = h.get("host", "")
                if not n:
                    continue
                if n not in seen:
                    out.append(n)
                seen[n] = (h, e.meta.get("via") or "ssh")
    return [seen[n] for n in out]


def clean(text):
    """doe's report, less the warning about the stand-in test script qd
    gives it (qd ran the tests; doe only reads their results)."""
    return "\n".join(ln for ln in text.splitlines()
                     if "test_script" not in ln).strip("\n")


# ---------------------------------------------------------------------------
# Starting configs: `qd doe init NAME`
# ---------------------------------------------------------------------------

# QD-067: a Plackett-Burman screen of fio's parameters on one drive of one
# host.  The factors, levels and the reason for each are the proposal the
# owner approves (or changes) before the first real run; the manual says
# the same at more length,
# docs/larger-jobs.md: "A screen of fio's parameters: qd doe init fio"
FIO_COMMAND = (
    "fio --name=qd-screen --filename={filename} --size={size} --time_based "
    "--runtime={runtime} --ramp_time={ramp_time} --group_reporting "
    "--output-format=json --rw={rw} --rwmixread={rwmixread} --bs={bs}k "
    "--iodepth={iodepth} --numjobs={numjobs} --ioengine={ioengine} "
    "--direct={direct}")

FIO_SCREEN = {
    "metadata": {
        "name": "fio-screen",
        "description": "Plackett-Burman screen of fio's parameters on one "
                       "drive of one host (QD-067): which of them move "
                       "IOPS, bandwidth and latency most.",
        "qd_command": FIO_COMMAND,
        # one point is the 10 s ramp and the 60 s run, plus fio's start
        # and the file's laying out: past qd's 60 s default --timeout
        "qd_timeout": 180,
        "qd_note": "Set fixed_factors.filename to a file on the drive under "
                   "test before the first run. A /dev path writes the raw "
                   "device and destroys what is on it: qd doe run refuses "
                   "it without --yes.",
    },
    "factors": [
        {"name": "bs", "label": "block size",
         "levels": ["4", "128"], "type": "continuous",
         "unit": "KiB",
         "description": "Block size: 4k is the small random I/O that "
                        "IOPS is quoted for, 128k the large I/O streaming "
                        "work issues. It trades IOPS for bandwidth more "
                        "than any other setting."},
        {"name": "iodepth", "label": "I/Os in flight per job",
         "levels": ["1", "32"], "type": "continuous",
         "description": "I/Os each job keeps in flight: 1 is latency-bound, "
                        "one at a time; 32 fills a SATA/SAS queue and goes "
                        "a long way towards an NVMe drive's."},
        {"name": "numjobs", "label": "jobs submitting at once",
         "levels": ["1", "8"], "type": "continuous",
         "description": "Jobs (processes) submitting at once: parallelism "
                        "on the host side, which iodepth alone does not "
                        "give an NVMe drive's many queues. 8 stays under "
                        "a server's core count."},
        {"name": "rwmixread", "label": "share of reads",
         "levels": ["30", "70"], "type": "continuous",
         "unit": "% reads", "qd_min": 1, "qd_max": 99,
         "description": "Share of reads. Kept off 0 and 100 so every point "
                        "does reads and writes, and every response is "
                        "measured at every point: fio reports 0 for a "
                        "direction that did no I/O, which would read as a "
                        "measurement. qd_min and qd_max keep qd doe "
                        "optimize's later rounds inside 1 to 99."},
        {"name": "rw", "label": "sequential or random",
         "levels": ["rw", "randrw"], "type": "categorical",
         "description": "Access pattern, sequential (rw) or random "
                        "(randrw), both mixed so rwmixread applies at every "
                        "point. Categorical: a central composite or "
                        "Box-Behnken follow-up holds it at its better "
                        "level."},
        {"name": "ioengine", "label": "how fio submits I/O",
         "levels": ["libaio", "io_uring"],
         "type": "categorical",
         "description": "How fio submits I/O: both asynchronous, so iodepth "
                        "means the same at both levels (a synchronous "
                        "engine such as psync ignores iodepth). io_uring "
                        "needs Linux 5.1+ and a fio built with it (fio "
                        "--enghelp lists it)."},
        {"name": "direct", "label": "page cache or O_DIRECT",
         "levels": ["0", "1"], "type": "categorical",
         "description": "1 bypasses the page cache (O_DIRECT) and measures "
                        "the drive; 0 goes through it, and measures what "
                        "applications that do not use O_DIRECT get. libaio "
                        "is only asynchronous with direct=1, an interaction "
                        "a screen cannot separate from the main effects."},
    ],
    "fixed_factors": {
        "filename": "/mnt/DRIVE/qd-fio.dat",
        "size": "8G",
        "runtime": "60",
        "ramp_time": "10",
    },
    "responses": [
        {"name": "read_iops", "column": "jobs.0.read.iops",
         "optimize": "maximize", "unit": "IO/s"},
        {"name": "write_iops", "column": "jobs.0.write.iops",
         "optimize": "maximize", "unit": "IO/s"},
        {"name": "read_bw", "column": "jobs.0.read.bw_bytes",
         "optimize": "maximize", "unit": "B/s"},
        {"name": "write_bw", "column": "jobs.0.write.bw_bytes",
         "optimize": "maximize", "unit": "B/s"},
        {"name": "read_lat_mean", "column": "jobs.0.read.clat_ns.mean",
         "optimize": "minimize", "unit": "ns"},
        {"name": "read_lat_p99",
         "column": "jobs.0.read.clat_ns.percentile.99.000000",
         "optimize": "minimize", "unit": "ns"},
        {"name": "write_lat_mean", "column": "jobs.0.write.clat_ns.mean",
         "optimize": "minimize", "unit": "ns"},
        {"name": "write_lat_p99",
         "column": "jobs.0.write.clat_ns.percentile.99.000000",
         "optimize": "minimize", "unit": "ns"},
    ],
    "settings": {"operation": "plackett_burman", "block_count": 1},
}

EXAMPLES = {"fio": ("fio-screen.json", FIO_SCREEN)}


def init(kind, path=None):
    """Write the starting config `kind` (EXAMPLES) to path (its own name in
    this directory by default); returns (path, config)."""
    if kind not in EXAMPLES:
        die("no starting config %r: %s" % (kind, ", ".join(sorted(EXAMPLES))))
    default, cfg = EXAMPLES[kind]
    path = path or default
    if os.path.exists(path):
        die("%s is there already: move it, or edit it" % path)
    write_text(path, json.dumps(cfg, indent=2) + "\n")
    return path, cfg


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


def report_key(cfg, columns=None):
    """What a report is kept under: the one response's column, or the
    columns joined when one analysis covers several (qd web links the
    one-column reports from a design's page); None when -c names none."""
    sp = specs(cfg, columns)
    if not sp:
        return None
    return ",".join(c for _, c, _ in sp)


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


# ---------------------------------------------------------------------------
# The response surface: `qd doe surface NAME -c RESPONSE` (QD-071)
# ---------------------------------------------------------------------------
#
# doe fits the surface and finds its optima: `doe analyze` the quadratic
# model's adequacy and its stationary point (what kind, where, the response
# there; its --csv tables), `doe optimize` the model's coefficients and the
# best point inside the design region (L-BFGS-B).  qd reads those back and
# says what they mean for the study, and for qd web evaluates doe's own
# fitted polynomial, in doe's coding, on a grid of each pair of factors.

EDGE = 0.98      # a coded setting this near -1 or +1 is on the region's edge
GRID = 25        # points along each axis of qd web's contours
WANTED = {"maximize": "maximum", "minimize": "minimum"}


def _num(text):
    try:
        v = float(text)
    except (TypeError, ValueError):
        return None
    return v if v == v and v not in (float("inf"), float("-inf")) else None


def metrics(rows):
    """doe's metric,value table as {metric: value text}."""
    return dict((r[0], r[1]) for r in rows or [] if len(r) >= 2)


def lack_of_fit(text, rname):
    """doe's Lack of Fit row of the response's ANOVA (df, F, p), or None:
    doe prints one when the design repeats points (pure error)."""
    sec = text.split("=== ANOVA Table: %s ===" % rname, 1)
    if len(sec) < 2:
        return None
    body = sec[1].split("\n=== ", 1)[0]
    m = re.search(r"^Lack of Fit\s+(\d+)\s+\S+\s+\S+(?:[ \t]+(\S+))?"
                  r"(?:[ \t]+(\S+))?[ \t]*$", body, re.M)
    if not m:
        return None
    return {"df": int(m.group(1)), "f": _num(m.group(2)),
            "p": _num(m.group(3))}


def optimize_text(text, rname):
    """What doe optimize printed for one response: its models
    {"linear"/"quadratic": {"r_squared", "adj_r_squared", "terms"
    [(term, coefficient)]}}, and its surface optimum (the model it used,
    {factor: setting}, the predicted response) -- None where doe printed
    none."""
    sec = text.split("=== Optimization: %s ===" % rname, 1)
    out = {"models": {}, "optimum": None}
    if len(sec) < 2:
        return out
    body = sec[1].split("\n=== ", 1)[0]
    cur = None
    for ln in body.splitlines():
        m = re.match(r"\s*RSM Model \((\w+), R\S* = (\S+), Adj R\S* = "
                     r"([^)\s]+)\):", ln)
        if m:
            cur = out["models"][m.group(1)] = {
                "r_squared": _num(m.group(2)),
                "adj_r_squared": _num(m.group(3)), "terms": []}
            continue
        if cur is None:
            continue
        m = re.match(r"\s{4}(\S+)\s+([-+]?\S+)\s*$", ln)
        if m and _num(m.group(2)) is not None:
            cur["terms"].append((m.group(1), float(m.group(2))))
        elif ln.strip() and ln.strip() != "Coefficients:":
            cur = None
        elif not ln.strip() and cur["terms"]:
            cur = None
    m = re.search(r"Surface optimum \(via [^,]+, (\w+) model\):\n"
                  r"((?:[ \t]+.*\n?)+)", body)
    if m:
        sets, pv = {}, None
        for ln in m.group(2).splitlines():
            ln = ln.strip()
            if ln.startswith("Predicted value:"):
                pv = _num(ln.split(":", 1)[1])
            elif " = " in ln:
                k, v = ln.split(" = ", 1)
                sets[k.strip()] = v.strip()
        out["optimum"] = {"model": m.group(1), "settings": sets,
                          "predicted": pv}
    return out


def coding(cfg, factors):
    """{factor: (centre, half range, levels)} in doe's coding: a numeric
    factor's -1..+1 over its levels' lowest to highest; a categorical one's
    two levels, sorted, as -1 and +1 (rsm._encode_factor_value)."""
    decl = dict((f.get("name"), f) for f in cfg.get("factors") or []
                if isinstance(f, dict))
    out = {}
    for f in factors:
        d = decl.get(f) or {}
        lv = [str(x) for x in d.get("levels") or []]
        nums = [_num(x) for x in lv]
        if lv and d.get("type") != "categorical" and \
                all(v is not None for v in nums):
            lo, hi = min(nums), max(nums)
            out[f] = ((lo + hi) / 2.0, (hi - lo) / 2.0, None)
        else:
            out[f] = (0.0, 1.0, sorted(lv))
    return out


def to_coded(code, f, value):
    centre, half, cats = code[f]
    if cats is not None:
        return -1.0 if cats and str(value) == cats[0] else 1.0
    v = _num(value)
    if v is None:
        return None
    return (v - centre) / half if half else 0.0


def to_natural(code, f, c):
    centre, half, cats = code[f]
    return centre + c * half if cats is None else c


def predict(terms, factors, x):
    """doe's fitted polynomial (its own terms: intercept, A, A*B, A^2) at
    coded settings x {factor: value} -- rsm.optimize_surface's sum."""
    v = 0.0
    for term, b in terms:
        if term == "intercept":
            v += b
        elif term.endswith("^2"):
            v += b * x.get(term[:-2], 0.0) ** 2
        elif "*" in term:
            p, q = term.split("*", 1)
            v += b * x.get(p, 0.0) * x.get(q, 0.0)
        else:
            v += b * x.get(term, 0.0)
    return v


def nice_levels(lo, hi, n=6):
    """About n round contour levels strictly inside lo..hi."""
    import math
    if hi <= lo:
        return []
    raw = (hi - lo) / float(n)
    mag = 10 ** math.floor(math.log10(raw))
    step = next(m * mag for m in (1, 2, 2.5, 5, 10) if m * mag >= raw)
    v = math.floor(lo / step) * step + step
    out = []
    while v < hi - step * 1e-9:
        if v > lo + step * 1e-9:
            out.append(round(v, 12))
        v += step
    return out


def contour_segments(xs, ys, z, level):
    """Marching squares: the line segments of z == level over the grid
    (z[j][i] at xs[i], ys[j]), as [x1, y1, x2, y2]."""
    segs = []

    def cut(p, q, zp, zq):
        t = (level - zp) / (zq - zp) if zq != zp else 0.5
        return (p[0] + t * (q[0] - p[0]), p[1] + t * (q[1] - p[1]))

    for j in range(len(ys) - 1):
        for i in range(len(xs) - 1):
            c = [((xs[i], ys[j]), z[j][i]), ((xs[i + 1], ys[j]), z[j][i + 1]),
                 ((xs[i + 1], ys[j + 1]), z[j + 1][i + 1]),
                 ((xs[i], ys[j + 1]), z[j + 1][i])]
            pts = []
            for k in range(4):
                (p, zp), (q, zq) = c[k], c[(k + 1) % 4]
                if (zp < level) != (zq < level):
                    pts.append(cut(p, q, zp, zq))
            if len(pts) == 2:
                segs.append([pts[0][0], pts[0][1], pts[1][0], pts[1][1]])
            elif len(pts) == 4:
                segs.append([pts[0][0], pts[0][1], pts[1][0], pts[1][1]])
                segs.append([pts[2][0], pts[2][1], pts[3][0], pts[3][1]])
    return segs


def surface_spec(cfg, column=None):
    """(response name, column, optimize) the surface is fitted to: the one
    asked for, else the response a follow-up was made for
    (metadata.qd_follows), else the config's only one."""
    sp = specs(cfg, [column] if column else None)
    if not column:
        meta = cfg.get("metadata") or {}
        fol = meta.get("qd_follows") if isinstance(meta, dict) else None
        if isinstance(fol, dict) and fol.get("response"):
            sp = [s for s in sp if s[0] == fol["response"]] or sp
    if not sp:
        die("a surface of what? -c COLUMN: the response, as qd show names "
            "it (or a config whose responses name their column)")
    if len(sp) > 1:
        die("a surface of which response? -c one of: %s"
            % ", ".join(s[0] for s in sp))
    return sp[0]


def surface(st, name, column=None, agg="median", report=None, grid=True):
    """doe's response surface for one response of a design, and what it
    means: the fitted model and its fit, the stationary point and its kind,
    the best point inside the design region and whether it is on the
    region's edge (another round is needed) or inside it; with grid, each
    pair of numeric factors' contours of doe's model, the other factors
    held at doe's optimum.  Every statistic is doe's."""
    row, cfg, matrix = load(st, name)
    rname, col, optimize = surface_spec(cfg, column)
    detail = {}
    text, allr, _, matrix = analyze(st, name, [col], agg, True,
                                    report=report, detail=detail)
    resp = allr[0][3]
    factors = list(matrix.get("factor_names") or [])
    code = coding(cfg, factors)
    numeric_f = [f for f in factors if code[f][2] is None]
    tables = detail.get("csv", {}).get(rname, {})
    ad = metrics(tables.get("model_adequacy"))
    spt = metrics(tables.get("stationary_point"))
    cv = dict((r[0], r[3]) for r in tables.get("cross_validation") or []
              if len(r) > 3)
    opt = optimize_text(detail.get("optimize", ""), rname)
    out = {"design": name, "response": rname, "column": col,
           "optimize": optimize, "agg": agg,
           "operation": (cfg.get("settings") or {}).get("operation") or
           matrix.get("operation"),
           "measured": sum(1 for _, v, _ in resp if v is not None),
           "total": len(resp), "factors": factors, "numeric": numeric_f,
           "levels": dict((f, [to_natural(code, f, -1.0),
                               to_natural(code, f, 1.0)])
                          for f in numeric_f)}
    out["fit"] = {
        "model": ad.get("model_type") or None,
        "observations": _num(ad.get("n_observations")),
        "parameters": _num(ad.get("n_parameters")),
        "r_squared": _num(ad.get("r_squared")),
        "adj_r_squared": _num(ad.get("adj_r_squared")),
        "predicted_r_squared": _num(ad.get("predicted_r_squared")),
        "rmse_cv": _num(cv.get("rmse_cv")),
        "lack_of_fit": lack_of_fit(detail.get("analyze", ""), rname)}
    sp = None
    if spt.get("nature"):
        sp = {"kind": spt["nature"],
              "predicted": _num(spt.get("predicted_value")),
              "inside": spt.get("inside_design_region") == "True",
              "coded": dict((f, _num(spt.get("coded[%s]" % f)))
                            for f in factors),
              "settings": dict((f, spt.get("natural[%s]" % f, ""))
                               for f in factors),
              "eigenvalues": [_num(v) for v in
                              (spt.get("eigenvalues") or "").split(";")
                              if _num(v) is not None]}
    out["stationary"] = sp
    model = None
    best = opt["optimum"]
    if best and best["model"] in opt["models"]:
        model = best["model"]
    elif opt["models"]:
        model = "quadratic" if "quadratic" in opt["models"] else \
            sorted(opt["models"])[0]
    terms = opt["models"][model]["terms"] if model else []
    out["model"] = {"kind": model, "terms": [[t, b] for t, b in terms],
                    "coding": dict((f, {"centre": code[f][0],
                                        "half_range": code[f][1]})
                                   for f in numeric_f)}
    if best:
        coded = dict((f, to_coded(code, f, best["settings"].get(f)))
                     for f in factors if f in best["settings"])
        edges = [[f, "high" if c > 0 else "low"] for f, c in
                 sorted(coded.items(), key=lambda kv: factors.index(kv[0]))
                 if c is not None and code[f][2] is None and abs(c) >= EDGE]
        out["optimum"] = {"settings": best["settings"], "coded": coded,
                          "predicted": best["predicted"], "edge": edges}
    else:
        out["optimum"] = None
    out["verdict"] = verdict(out)
    if report:
        out["report"] = report
    if grid and terms and len(numeric_f) >= 2:
        out["pairs"] = surface_grids(out, code, terms, matrix, resp)
    else:
        out["pairs"] = []
    return out


def verdict(s):
    """{"where": "inside" | "edge" | "none", "text": the words}: where the
    optimum is, and what to do next."""
    want = WANTED.get(s["optimize"], "maximum")
    sp, best = s["stationary"], s["optimum"]
    if s["fit"]["model"] != "quadratic" or sp is None:
        return {"where": "none", "text": (
            "doe fitted no quadratic surface here (%d points measured), so "
            "there is no stationary point: a central composite or "
            "Box-Behnken follow-up has the points a surface needs (qd doe "
            "next %s)" % (s["measured"], s["design"]))}
    if sp["kind"] == want and sp["inside"]:
        return {"where": "inside", "text": (
            "the %s is inside the design region: confirm it with a run at "
            "these settings" % want)}
    if best and best["edge"]:
        return {"where": "edge", "text": (
            "the best point inside the design region is on its edge (%s): "
            "the %s lies beyond it, so another round is needed, moved that "
            "way" % (", ".join("%s at its %s level" % (f, e)
                               for f, e in best["edge"]), want))}
    why = "outside the design region" if not sp["inside"] else \
        "a %s, not a %s" % (sp["kind"].replace("_", " "), want)
    return {"where": "edge" if not sp["inside"] else "none", "text": (
        "the stationary point is %s, and the best point inside the region "
        "is not on its edge: there is no clear %s here, and another round, "
        "nearer doe's optimum, is needed" % (why, want))}


def surface_grids(s, code, terms, matrix, resp):
    """Each pair of numeric factors: doe's model on a GRID x GRID grid of
    the pair (natural units), the other factors held at doe's optimum (or
    the centre), with round contour levels, their lines, the band each
    cell falls in, and where the design's points and the optimum are."""
    import itertools
    numeric_f = s["numeric"]
    held = dict((f, 0.0) for f in s["factors"])
    if s["optimum"]:
        for f, c in s["optimum"]["coded"].items():
            if c is not None:
                held[f] = c
    settings = s["optimum"]["settings"] if s["optimum"] else {}
    vals = dict((rid, v) for rid, v, _ in resp)
    pts = points(matrix)
    span = {}
    for f in numeric_f:
        cs = [to_coded(code, f, dict(lv)[f]) for _, _, lv in pts]
        cs = [c for c in cs if c is not None]
        span[f] = (min([-1.0] + cs), max([1.0] + cs))
    out = []
    for a, b in itertools.combinations(numeric_f, 2):
        ca = [span[a][0] + (span[a][1] - span[a][0]) * i / (GRID - 1.0)
              for i in range(GRID)]
        cb = [span[b][0] + (span[b][1] - span[b][0]) * j / (GRID - 1.0)
              for j in range(GRID)]
        z = []
        for yb in cb:
            rowz = []
            for xa in ca:
                x = dict(held)
                x[a], x[b] = xa, yb
                rowz.append(predict(terms, s["factors"], x))
            z.append(rowz)
        xs = [to_natural(code, a, c) for c in ca]
        ys = [to_natural(code, b, c) for c in cb]
        flat = [v for r in z for v in r]
        levels = nice_levels(min(flat), max(flat))
        lines = [{"level": lv, "segments": contour_segments(xs, ys, z, lv)}
                 for lv in levels]
        bands = [[sum(1 for lv in levels if v >= lv) for v in r] for r in z]
        here = {}
        for rid, _, lv in pts:
            d = dict(lv)
            k = (d[a], d[b])
            p = here.setdefault(k, {"a": _num(d[a]), "b": _num(d[b]),
                                    "points": [], "values": []})
            p["points"].append(rid)
            p["values"].append(vals.get(rid))
        mark = {}
        for key, src in (("stationary", s["stationary"]),
                         ("optimum", s["optimum"])):
            c = (src or {}).get("coded") or {}
            if c.get(a) is not None and c.get(b) is not None:
                mark[key] = {"a": to_natural(code, a, c[a]),
                             "b": to_natural(code, b, c[b]),
                             "inside": span[a][0] <= c[a] <= span[a][1] and
                             span[b][0] <= c[b] <= span[b][1]}
        out.append({"a": a, "b": b, "x": xs, "y": ys, "z": z,
                    "min": min(flat), "max": max(flat),
                    "levels": levels, "lines": lines, "bands": bands,
                    "held": [[f, settings.get(f) or
                              "%.6g" % to_natural(code, f, held[f])]
                             for f in s["factors"] if f not in (a, b)],
                    "design": sorted(here.values(),
                                     key=lambda p: (p["a"], p["b"])),
                    "marks": mark})
    return out


# ---------------------------------------------------------------------------
# Further rounds: doe's steepest path and next batch (QD-072)
# ---------------------------------------------------------------------------
#
# `qd doe optimize` (quarterdeck/optimize.py) decides the rounds and runs
# them; doe decides the points.  These hand one design's responses to doe
# the way analyze() does and read back the points doe proposes: the steps
# of `doe optimize --steepest` (its linear model's path, half a coded unit
# a step for the factor that moves most) and the runs `doe next-batch`
# appends to the design.

def one_response(st, name, column, agg, work):
    """The design's points and one response, as doe reads them, in work:
    (config path, results directory, the response [(run_id, value or
    None, n)], (name, column, optimize)).  A point not measured is no
    run_<id>.json at all: blank, never 0."""
    _, cfg, matrix = load(st, name)
    rname, col, optimize = surface_spec(cfg, column)
    resp = responses(st, name, col, agg)
    out_dir = os.path.join(work, "results")
    os.makedirs(out_dir)
    write_text(os.path.join(out_dir, "design_matrix.json"),
               json.dumps(matrix, indent=2))
    for rid, v, _ in resp:
        if v is not None:
            write_text(os.path.join(out_dir, "run_%d.json" % rid),
                       json.dumps({rname: v}))
    cfg = json.loads(json.dumps(cfg))
    cfg["responses"] = [{"name": rname, "optimize": optimize}]
    settings = cfg.setdefault("settings", {})
    settings["out_directory"] = out_dir
    settings.setdefault("test_script", "true")
    conf = os.path.join(work, "config.json")
    write_text(conf, json.dumps(cfg, indent=2))
    return conf, out_dir, resp, (rname, col, optimize)


def steepest_table(text, rname, factors):
    """doe optimize --steepest's table for one response: [(step,
    {factor: setting}, predicted or None)], step 0 the design's centre;
    [] when doe printed none (no gradient: every main effect 0)."""
    m = re.search(r"=== Steepest (?:Ascent|Descent): %s ===\n" %
                  re.escape(rname), text)
    if not m:
        return []
    out = []
    for ln in text[m.end():].splitlines():
        if not ln.strip():
            if out:
                break
            continue
        if ln.startswith("==="):
            break
        cells = ln.split()
        if not cells[0].isdigit() or len(cells) != len(factors) + 2:
            continue
        out.append((int(cells[0]), dict(zip(factors, cells[1:-1])),
                    _num(cells[-1])))
    return out


def steepest(st, name, column=None, agg="median"):
    """doe's steepest ascent (or, for a response to minimise, descent) from
    a design's points: [(step, {factor: setting}, predicted)], and doe's
    text.  The path is doe's linear model's, so its predictions past the
    region are a straight line's: qd measures each step to see."""
    work = tempfile.mkdtemp(prefix="qd-doe-")
    try:
        conf, out_dir, _, (rname, _, _) = one_response(st, name, column,
                                                         agg, work)
        rc, text = run_doe(["optimize", "--config", conf, "--results-dir",
                            out_dir, "--partial", "--steepest"], cwd=work)
        if rc != 0:
            die("doe optimize --steepest failed (exit %d):\n%s"
                % (rc, text[-2000:]))
        _, _, matrix = load(st, name)
        return steepest_table(text, rname,
                              matrix.get("factor_names") or []), clean(text)
    finally:
        shutil.rmtree(work, ignore_errors=True)


def next_batch(st, name, column=None, agg="median", strategy="refine",
               size=4, seed=None):
    """doe next-batch on a design's points: the runs doe appends to its
    matrix, [{factor: setting}] in doe's order, and doe's text.  qd files
    them as more points of the same design, so a point measured already
    is not run again."""
    work = tempfile.mkdtemp(prefix="qd-doe-")
    try:
        conf, out_dir, _, _ = one_response(st, name, column, agg, work)
        _, _, matrix = load(st, name)
        known = set(int(r["run_id"]) for r in matrix.get("runs") or [])
        args = ["next-batch", "--config", conf, "--results-dir", out_dir,
                "--strategy", strategy, "--batch-size", str(size),
                "--output", os.path.join(work, "next.sh"), "--partial"]
        if seed is not None:
            args += ["--seed", str(seed)]
        rc, text = run_doe(args, cwd=work)
        path = os.path.join(out_dir, "design_matrix.json")
        if rc != 0 or not os.path.isfile(path):
            die("doe next-batch failed (exit %d):\n%s"
                % (rc, text.strip()[-2000:]))
        grown = json.loads(read_text(path))
        new = [dict((k, str(v)) for k, v in
                    (r.get("factor_values") or {}).items())
               for r in grown.get("runs") or []
               if int(r["run_id"]) not in known]
        return new, clean(text)
    finally:
        shutil.rmtree(work, ignore_errors=True)
