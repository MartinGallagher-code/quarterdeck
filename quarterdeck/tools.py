# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Martin J. Gallagher
"""The toolchain quarterdeck drives, and what each one leaves behind.

Each tool is found on PATH, as an importable module, or wherever its
QD_<NAME> variable points (QD_MX="python3 ~/src/matrix_orchestrator/mx").
`qd do` runs one and then reads back what it wrote, by the rules below --
which are knowledge of where these tools put their output, not guesses:

  mx run|summarize        reports/ (--reports, MX_REPORTS), and then
                          `mx export --no-collect --json`: no ssh, the
                          overlay numbers mx computes by its own rules
  mx export               -o FILE, or what it printed
  iperf-orchestrator      results/<run>/ after run, all, summarize,
                          process, parse-csv, export-overlay
  agree                   --json/--csv/--merge-csv files; with none, qd
                          adds --csv (and --merge-csv for `script`) into
                          the entry and says so
  dcprobe                 -o FILE (host_status.tsv after scan and watch,
                          preflight.tsv after preflight) and --history
  reckon                  --overlay/--csv/--json FILE
  netmesh                 --reports DIR, --grid DIR
  any --csv PATH          that file; a bare --csv prints to stdout
  anything else           stdout, when it is a table
"""

import os
import re
import shlex
import shutil
import subprocess
import sys

from .common import env
from .table import Table, slug

BINNACLE = ("binnacle", "why-slow", "agree", "logtriage", "netmesh",
            "reachable", "resolve", "during", "skew", "muster", "manifest",
            "dredge", "rig", "reckon", "plumb")

# name -> (executables to look for, python module to fall back on, use)
TOOLS = [
    ("mx", ("mx", "matrix-orchestrator"), "matrix_orchestrator",
     "request/response pps across a fleet"),
    ("iperf-orchestrator", ("iperf-orchestrator", "iperf_orchestrator.sh"),
     "iperf_orchestrator", "full-mesh TCP bandwidth"),
] + [
    (b, (b,), "binnacle.%s" % b.replace("-", "_"),
     "binnacle: " + {
         "binnacle": "which instruments are installed",
         "why-slow": "why is this box slow", "agree": "who disagrees",
         "logtriage": "which log lines matter", "netmesh": "idle network",
         "reachable": "prune a host list", "resolve": "DNS",
         "during": "what limited a run", "skew": "clock", "muster":
         "leases on a pool", "manifest": "hosts from a layout", "dredge":
         "bring files back", "rig": "settings in a file", "reckon":
         "grade a run against the hardware", "plumb": "page cache vs disk",
     }[b]) for b in BINNACLE
] + [
    ("provost", ("provost",), "provost_data",
     "the store: every answer filed, parsed and kept in git"),
    # no module fallback: doe has no __main__, and PyPI's doehelper wants
    # Python 3.10+
    ("doe", ("doe",), None, "design of experiments: designs and their "
     "analysis (qd doe)"),
    ("dcviz", ("dcviz",), "dcviz", "floor-plan viewer: dcviz serve"),
    ("dcprobe", ("dcprobe",), "dcviz.dcprobe", "how every host is doing"),
    ("dcadd", ("dcadd",), "dcviz.dcadd", "append to a results file"),
    ("dcimport", ("dcimport",), "dcviz.dcimport", "netmesh into overlays"),
]

TOOL_NAMES = [t[0] for t in TOOLS]


def _module_ok(mod):
    try:
        import importlib.util
        return importlib.util.find_spec(mod) is not None
    except (ImportError, ValueError, AttributeError):
        return False


def find_tool(name):
    """argv that runs `name`, or None."""
    over = env(name.upper().replace("-", "_"))
    if over:
        # no shell reads it, so ~ is expanded here, as the shell would
        argv = [os.path.expanduser(a) for a in shlex.split(over)]
        # an override naming nothing that exists is "not installed", said
        # as such, rather than an OSError at the first use
        if argv and (shutil.which(argv[0]) or os.path.isfile(argv[0])):
            return argv
        return None
    for t in TOOLS:
        if t[0] == name:
            exes, mod = t[1], t[2]
            break
    else:
        exes, mod = (name,), None
    for exe in exes:
        p = shutil.which(exe)
        if p:
            return [p]
    if mod and _module_ok(mod):
        return [sys.executable, "-m", mod]
    return None


def tool_version(argv, timeout=10):
    try:
        p = subprocess.Popen(list(argv) + ["--version"],
                             stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                             stdin=subprocess.DEVNULL)
        out, _ = p.communicate(timeout=timeout)
    except (OSError, subprocess.TimeoutExpired):
        return ""
    lines = out.decode("utf-8", "replace").strip().splitlines()
    return lines[0].strip() if lines else ""


def doctor_rows():
    rows = []
    for name in ("ssh", "scp"):
        p = shutil.which(name)
        rows.append([name, "ok" if p else "MISSING", p or "", "",
                     "every fan-out"])
    for name, _, _, use in TOOLS:
        argv = find_tool(name)
        if argv:
            ver = tool_version(argv)
            rows.append([name, "ok", " ".join(argv), ver, use])
        else:
            rows.append([name, "-", "", "", use])
    if _module_ok("curses"):
        rows.append(["curses", "ok", "", "", "qd view"])
    else:
        rows.append(["curses", "MISSING", "", "", "qd view (the "
                     "non-interactive verbs still work)"])
    return rows


INSTALL = {
    "provost": "pip install provost (qd keeps everything in its store)",
    "doe": "pip install doehelper (Python 3.10+)",
    "mx": "pip install matrix-orchestrator",
    "iperf-orchestrator": "pip install iperf-orchestrator",
    "dcviz": "pip install datacenter-layout-viewer",
    "dcprobe": "pip install datacenter-layout-viewer",
    "dcadd": "pip install datacenter-layout-viewer",
    "dcimport": "pip install datacenter-layout-viewer",
}


def install_hint(name):
    return INSTALL.get(name, "pip install binnacle" if name in BINNACLE
                       else "")


# ---------------------------------------------------------------------------
# qd do: what a tool run leaves behind
# ---------------------------------------------------------------------------

def opt(argv, names):
    """The last value given to any of these options, or None.  Nothing
    after `--` is the tool's: `agree -- why-slow --csv x` is why-slow's
    --csv, written on the far side."""
    if "--" in argv:
        argv = argv[:argv.index("--")]
    val = None
    for i, a in enumerate(argv):
        for n in names:
            if a == n and i + 1 < len(argv):
                val = argv[i + 1]
            elif n.startswith("--") and a.startswith(n + "="):
                val = a[len(n) + 1:]
    return val


def opt_path(argv, names):
    """An option whose path is optional (`--csv [PATH]`): the path if one
    was given, else None."""
    v = opt(argv, names)
    if v is None or v.startswith("-") or v == "":
        return None
    return v


def tool_of(argv):
    """Which tool an argv runs: `mx run`, `python3 ./mx run`, `./mx.py`."""
    if not argv:
        return "", []
    i = 0
    if os.path.basename(argv[0]).startswith("python") and len(argv) > 1:
        i = 1
        if argv[1] == "-m" and len(argv) > 2:
            mod = argv[2]
            name = {"matrix_orchestrator": "mx",
                    "iperf_orchestrator": "iperf-orchestrator"}.get(
                mod, mod.split(".")[-1].replace("_", "-"))
            return name, argv[3:]
    base = os.path.basename(argv[i])
    for ext in (".py", ".sh"):
        if base.endswith(ext):
            base = base[:-len(ext)]
    base = base.replace("_", "-")
    alias = {"matrix-orchestrator": "mx",
             "iperf-orchestrator.sh": "iperf-orchestrator"}
    return alias.get(base, base), argv[i + 1:]


class Plan(object):
    """What to run, and what to read back afterwards."""

    def __init__(self, argv):
        self.argv = list(argv)
        self.imports = []          # (path, table name or None)
        self.after = []            # (argv, output path, table name)
        self.notes = []
        self.tool = ""


# Tools whose host files take `key=value` after a host: dcprobe judges a
# NIC by its gbps=, mtu= and nic=.  The rest (reachable, agree, mx) read
# every word as a host, and are given names only.
READS_ATTRIBUTES = ("dcprobe",)

DCPROBE_OUT = {"scan": "host_status.tsv", "watch": "host_status.tsv",
               "preflight": "preflight.tsv"}
IPERF_VERBS = ("run", "all", "summarize", "process", "parse-csv",
               "parse-cpu", "export-overlay", "results-summary")


def plan(argv, entry_dir):
    p = Plan(argv)
    tool, rest = tool_of(argv)
    p.tool = tool
    verb = rest[0] if rest and not rest[0].startswith("-") else ""
    if tool == "mx":
        reports = opt(rest, ["--reports"]) or os.environ.get(
            "MX_REPORTS") or "reports"
        if verb in ("run", "summarize"):
            p.imports.append((reports, "reports"))
            out = os.path.join(entry_dir, "mx_export.ndjson")
            exp = list(argv[:len(argv) - len(rest)]) + [
                "export", "--no-collect", "--json", "-o", out]
            for flag in ("--reports", "--matrix", "--window", "--nic-gbps",
                         "--names", "--target-prefix"):
                v = opt(rest, [flag])
                if v is not None:
                    exp += [flag, v]
            p.after.append((exp, out, "mx_export"))
        elif verb == "export":
            o = opt(rest, ["-o", "--output"])
            if o and o != "-":
                p.imports.append((o, "mx_export"))
    elif tool == "iperf-orchestrator":
        if any(v in rest for v in IPERF_VERBS):
            base = opt(rest, ["-o", "--output"]) or os.environ.get(
                "RESULTS_BASE") or "results"
            run = opt(rest, ["--run-id"]) or os.environ.get(
                "IPERF_RUN_ID") or "latest"
            p.imports.append((os.path.join(base, run), None))
        o = opt_path(rest, ["--overlay-out"])
        if o:
            p.imports.append((o, "iperf_overlay"))
    elif tool == "agree":
        given = [(opt(rest, ["--json"]), "agree"),
                 (opt(rest, ["--csv"]), "agree_hosts"),
                 (opt(rest, ["--merge-csv"]), "merged")]
        given = [(v, n) for v, n in given if v and not v.startswith("-")]
        if given:
            p.imports.extend(given)
        elif verb in ("", "run", "script"):
            # before the command, or at the end when there is none
            # (`agree script why-slow -f hosts` takes no `--`)
            cut = argv.index("--") if "--" in argv else len(argv)
            add = ["--csv", os.path.join(entry_dir, "agree.csv")]
            if verb == "script":
                add += ["--merge-csv", os.path.join(entry_dir, "merged.csv")]
            p.argv = argv[:cut] + add + argv[cut:]
            p.imports.append((add[1], "agree_hosts"))
            if verb == "script":
                p.imports.append((add[3], "merged"))
            p.notes.append("added %s so the groups are filed with the run"
                           % " ".join(add[::2]))
    elif tool == "dcprobe":
        # where dcprobe writes when not told: scan and watch the
        # host_status.tsv the viewer opens, preflight its own file
        default = DCPROBE_OUT.get(verb)
        for names, tname, dflt in ((["-o", "--output"], None, default),
                                   (["--history"], "history", None)):
            v = opt(rest, names) or dflt
            if v and v != "-":
                p.imports.append((v, tname))
    elif tool == "reckon":
        for names, tname in ((["--overlay"], "reckon_overlay"),
                             (["--csv"], "reckon_findings"),
                             (["--json"], "reckon")):
            v = opt_path(rest, names)
            if v:
                p.imports.append((v, tname))
    elif tool == "netmesh":
        for names, tname in ((["--reports"], "reports"),
                             (["--grid"], "grid")):
            v = opt_path(rest, names)
            if v:
                p.imports.append((v, tname))
    else:
        v = opt_path(rest, ["--csv"])
        if v:
            p.imports.append((v, tool or None))
    return p


# ---------------------------------------------------------------------------
# Overlays for the floor-plan viewer
# ---------------------------------------------------------------------------

TARGET_COLS = ("host", "target", "ssh_host", "name", "src", "source")
PEER_COLS = ("peer", "dst")
SKIP = ("addr", "rc", "duration_s", "pass", "ts", "timestamp", "time",
        "line_no", "error", "parse_error", "stdout", "stderr", "line",
        "run", "at", "test_start", "filename", "digest", "is_baseline",
        "group_id", "slot", "path", "room", "row", "rack", "role")
STATUS_VERDICT = {"ok": "PASS", "failed": "FAIL", "timeout": "FAIL",
                  "unreachable": "FAIL", "push-failed": "FAIL"}
UNITS = (("_pct", "%"), ("_percent", "%"), ("_us", "us"), ("_ms", "ms"),
         ("_s", "s"), ("_mbps", "Mb/s"), ("_gbps", "Gb/s"), ("_pps", "pps"),
         ("_kb", "kB"), ("_mb", "MB"), ("_gb", "GB"), ("_bytes", "B"),
         ("_c", "C"))


PLAIN_NUMBER = re.compile(r"^[-+]?(\d+\.?\d*|\.\d+)([eE][-+]?\d+)?$")


def guess_unit(col):
    s = slug(col)
    for suffix, unit in UNITS:
        if s.endswith(suffix):
            return unit
    if col.endswith("%"):
        return "%"
    return None


def column_unit(t, s, name):
    """The unit a column's figures are in, for the terminal and the page
    alike: what its cells were put on (B where sizes were mixed, s where
    times were, ms where every cell said ms), else what the !test lines
    say, else what its name implies (rtt_us); None when nothing does.
    `t` is the table, `s` the rows asked about."""
    u = s.unit(name)
    if u:
        return u
    meta = t.tests or {}
    if s.is_results() and name == "value" and s.rows:
        tests = set(s.values("test"))
        if len(tests) != 1:
            return None
        u = dict(meta.get(tests.pop(), [])).get("unit")
    else:
        u = dict(meta.get(name, [])).get("unit")
    return u or guess_unit(name)


def to_overlay(table, run_label=None, prefix="qd_", target=None):
    """A dataset as the viewer's results: one sample per host per number.

    Numbers become overlays named prefix+column, the `status` of a run
    becomes a PASS/FAIL overlay so an unreachable host paints red rather
    than disappearing, and free text (stdout, errors) stays out.  A table
    that already is results passes through untouched.
    """
    if table.is_results():
        return table
    tcol = target
    if not tcol:
        for c in TARGET_COLS:
            if table.has(c):
                tcol = table.colname(c)
                break
    if not tcol:
        from .common import die
        die("no column names the hosts (want one of %s, or --target COL)"
            % ", ".join(TARGET_COLS))
    tcol = table.colname(tcol)
    pcol = None
    for c in PEER_COLS:
        if table.has(c) and table.colname(c) != tcol:
            pcol = table.colname(c)
            break
    ti = table.index(tcol)
    pi = table.index(pcol) if pcol else None
    plan_cols = []
    tests = {}
    for c in table.columns:
        if c in (tcol, pcol) or slug(c) in SKIP or c.lower() in SKIP:
            continue
        kind = table.kind(c)
        name = prefix + (slug(c) or "value")
        if c == "status" or slug(c) == "status":
            plan_cols.append((table.index(c), name, "status", None))
            tests[name] = [("short", "STAT"),
                           ("label", "Answered (%s)" % c)]
        elif kind == "num":
            # the viewer reads a sample as a number: 512M and 2G go over
            # as bytes, 900ms and 1.2s as seconds, and the unit is said
            plan_cols.append((table.index(c), name, "num", table.numbers(c)))
            meta = []
            u = table.unit(c) or guess_unit(c)
            if u:
                meta.append(("unit", u))
            meta.append(("label", c))
            tests[name] = meta
        elif kind == "text" and set(v.strip().upper() for v in
                                    table.values(c) if v.strip()) <= \
                set(("PASS", "WARN", "FAIL")):
            plan_cols.append((table.index(c), name, "verdict", None))
            tests[name] = [("label", c)]
    rows = []
    meta_cols = (["peer"] if pcol else []) + (["run"] if run_label else [])
    for n, r in enumerate(table.rows):
        tgt = r[ti].strip()
        if not tgt:
            continue
        for i, name, kind, nums in plan_cols:
            v = r[i].strip()
            if not v:
                continue
            if kind == "status":
                verdict = STATUS_VERDICT.get(v.lower(), "WARN")
                v = verdict
            elif kind == "num":
                if nums[n] is None:
                    continue
                plain = v.rstrip("%").strip()
                # as written where it is a number already (9.0, a counter
                # past 2**53); put on the column's scale where it is not
                v = plain if PLAIN_NUMBER.match(plain) else "%.15g" % nums[n]
            row = [name, tgt, v]
            if pcol:
                row.append(r[pi])
            if run_label:
                row.append(run_label)
            rows.append(row)
    t = Table(["test", "target", "value"] + meta_cols, rows, "overlay",
              table.source, tests=tests)
    t.notes = ["quarterdeck overlay of %s%s" % (
        table.name, (" (%s)" % run_label) if run_label else "")]
    return t
