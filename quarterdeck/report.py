# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Martin J. Gallagher
"""qd report: an evidence package for a run or a campaign.

    qd report RUN|campaign:NAME [--out DIR] [--check FILE] [--baseline RUN]
              [--drift PCT] [--z Z] [--zip]

writes a directory an evaluator can read, check and attach without qd:

    data/RUN/TABLE.csv, TABLE.json         each table, as `qd export` writes it
    data/RUN/TABLE.stats.csv, .json        `qd stats` on it
    data/RUN/outliers.csv, .json           `qd outliers` on every numeric column
    data/RUN/check.csv, .json              `qd check` against --check, or the
                                           verdicts `qd check --keep` filed
    data/RUN/captures/cNNNN.txt            every answer as provost keeps it
                                           (`provost source cNNNN`)
    data/baseline.csv, .json               medians against --baseline
    data/baseline-hosts.csv, .json         `qd compare BASELINE RUN --format csv`
    data/parts.csv, .json                  a campaign: its parts, and their
                                           medians side by side
    inputs/FILE                            the --check file, as given
    verify.txt                             `provost verify` on the captures
    manifest.json                          run records (with the operator),
                                           the captures' #% keys, versions,
                                           the store's head commit, verify
    summary.md, summary.html               what an evaluator reads first
    SHA256SUMS                             every other file: sha256sum -c

Every figure in the summaries is computed here by the functions the
commands themselves use -- describe, outliers, check, compare -- and each
section names the command that prints the same figures.  The HTML is
static: no script, no request for anything, every dataset string escaped,
and a Content-Security-Policy that would refuse a script if one got in.

A section whose feature has nothing to say is left out and named at the
end, with why: no thresholds given or kept, no baseline, a provost without
`verify` (PV-026), captures with no #% keys of their own (PV-020).  As the
features arrive the sections fill in.

The package is written beside its destination and moved into place whole,
so a report that failed half way leaves nothing behind.  It is never
written inside the store: provost commits everything there.
"""

import hashlib
import html
import json
import os
import platform
import re
import shlex
import shutil
import subprocess
import tempfile
import time
import zipfile

from . import VERSION
from . import check as checkmod, compare as comparemod, filing, stats
from . import store as storemod, table as tablemod, whoran
from .common import PROG, QdError, die, plural, read_text
from .store import shown_id
from .table import Table

KIND = "qd-report"
REPORT_VERSION = 1

# rows of one table in a summary; the rest are in its file under data/
ROW_LIMIT = 60
OUTLIER_ROWS = 15
OUTLIER_COLUMNS = 40
CELL_LIMIT = 160

# columns a summary's figures leave out: bookkeeping and who-it-was
NOT_FIGURES = set(stats.BOOKKEEPING) | {"host", "addr", "error", "stderr",
                                        "capture"}
# '#%' keys that are qd's own, said elsewhere in the report
QD_KEYS = ("run", "host", "pass")
VERDICT_ORDER = (checkmod.FAIL, checkmod.UNMEASURED, checkmod.PASS)

SAFE_ARG = re.compile(r"^[A-Za-z0-9_@%+=:,./-]+$")
KEY_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_.-]*$")
ANSI_RE = re.compile(r"\x1b\[[0-9;]*m")


# ---------------------------------------------------------------------------
# Small pieces
# ---------------------------------------------------------------------------

def safe(name, default):
    """A file name from a run id or a table name: letters, digits, '.',
    '_' and '-', no '..', never empty."""
    s = re.sub(r"[^A-Za-z0-9._-]+", "_", name or "")
    s = re.sub(r"\.{2,}", ".", s).strip("._-")
    return s or default


def sh(word):
    """A word as typed at a shell."""
    return word if SAFE_ARG.match(word) else shlex.quote(word)


def store_arg(st):
    """--store's value for a store, as typed: ~/... where that needs no
    quotes (the shell expands it), else the whole path quoted."""
    where = st.shown()
    if re.match(r"^[A-Za-z0-9_~@%+=:,./-]+$", where):
        return where
    return shlex.quote(st.root)


def clip(text, n=CELL_LIMIT):
    text = text or ""
    return text if len(text) <= n else text[:n - 3] + "..."


def sha256_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def prologue_pairs(text):
    """[(key, value)] of a capture's '#%' lines, read as provost reads a
    run manifest (PV-020): key=value words, a value in double quotes may
    hold spaces (with \\" and \\\\ inside), anything else is skipped."""
    out = []
    for ln in (text or "").splitlines():
        if not ln.startswith("#%"):
            continue
        line = ln[2:]
        while True:
            line = line.lstrip(" \t")
            if not line:
                break
            m = re.match(r'([A-Za-z_][A-Za-z0-9_.-]*)="', line)
            if m:
                rest, val, i, closed = line[m.end():], [], 0, False
                while i < len(rest):
                    c = rest[i]
                    if c == "\\" and i + 1 < len(rest):
                        val.append(rest[i + 1])
                        i += 2
                        continue
                    if c == '"':
                        closed = True
                        i += 1
                        break
                    val.append(c)
                    i += 1
                after = rest[i:]
                if closed and (after == "" or after[0] in " \t"):
                    out.append((m.group(1), "".join(val).replace("\t", " ")))
                    line = after
                    continue
            word = re.match(r"[^ \t]+", line).group(0)
            line = line[len(word):]
            k, sep, v = word.partition("=")
            if sep and KEY_RE.match(k):
                out.append((k, v))
    return out


def git_head(root):
    """The store's head commit, or blank: git's, and only the store's own
    (a store with no .git of its own is not read through a parent's)."""
    if not os.path.exists(os.path.join(root, ".git")):
        return ""
    try:
        p = subprocess.Popen(["git", "-C", root, "rev-parse", "HEAD"],
                             stdout=subprocess.PIPE,
                             stderr=subprocess.DEVNULL,
                             stdin=subprocess.DEVNULL)
        out, _ = p.communicate(timeout=30)
    except (OSError, subprocess.SubprocessError):
        return ""
    return out.decode("utf-8", "replace").strip() if p.returncode == 0 \
        else ""


# ---------------------------------------------------------------------------
# The summary: sections of blocks, rendered as Markdown and as HTML
# ---------------------------------------------------------------------------

class Section(object):
    """A heading and its blocks: ("p", text), ("facts", [(k, v)]),
    ("table", Table, numeric columns), ("items", [text]), ("files",
    [path]), ("code", [command]) and ("pre", [line of output]).  All of it
    plain text: escaping is the renderers' job, and theirs alone."""

    def __init__(self, title, level=2):
        self.title = title
        self.level = level
        self.blocks = []

    def text(self, s):
        self.blocks.append(("p", s))

    def facts(self, pairs):
        pairs = [(k, "%s" % v) for k, v in pairs if v not in (None, "")]
        if pairs:
            self.blocks.append(("facts", pairs))

    def table(self, t, numeric=(), rest=None, limit=ROW_LIMIT):
        shown = t if len(t.rows) <= limit else t.derive(rows=t.rows[:limit])
        self.blocks.append(("table", shown, set(numeric)))
        if len(t.rows) > limit:
            self.text("... %d more row(s)%s" % (
                len(t.rows) - limit, (" in " + rest) if rest else ""))

    def items(self, lines):
        lines = list(lines)
        if lines:
            self.blocks.append(("items", lines))

    def files(self, paths):
        if paths:
            self.blocks.append(("files", list(paths)))

    def code(self, lines):
        if lines:
            self.blocks.append(("code", list(lines)))

    def pre(self, lines):
        if lines:
            self.blocks.append(("pre", list(lines)))


# Markdown's punctuation, escaped wherever it could be read as markup or
# HTML; an underscore inside a word (of_median) cannot be, and is left be
MD_SPECIAL = re.compile(r"[\\`*\[\]<>|&]|(?<![A-Za-z0-9])_|_(?![A-Za-z0-9])")


def md(s):
    """Text for a Markdown cell or value: shown as it is, never read as
    markup or HTML, on one line."""
    s = (s or "").replace("\r", " ").replace("\n", " ")
    return MD_SPECIAL.sub(lambda m: "\\" + m.group(0), s)


def md_line(s):
    """md() for text that starts a line, where #, -, + and 1. start a
    heading or a list."""
    s = md(s)
    if s[:1] in ("#", "+", "-", "="):
        return "\\" + s
    return re.sub(r"^(\d+)([.)])", r"\1\\\2", s)


def md_fence(lines):
    longest = max([len(r) for ln in lines for r in re.findall(r"`+", ln)] +
                  [2])
    return "`" * (longest + 1)


def render_md(title, sections):
    out = ["# " + md(title), ""]
    for sec in sections:
        out.append("#" * sec.level + " " + md(sec.title))
        out.append("")
        for b in sec.blocks:
            kind = b[0]
            if kind == "p":
                out.append(md_line(b[1]))
            elif kind == "facts":
                out.extend("- **%s**: %s" % (md(k), md(clip(v)))
                           for k, v in b[1])
            elif kind == "items":
                out.extend("- " + md_line(clip(x, 400)) for x in b[1])
            elif kind == "files":
                out.extend("- [%s](%s)" % (md(p), p) for p in b[1])
            elif kind in ("code", "pre"):
                fence = md_fence(b[1])
                out.append(fence + ("sh" if kind == "code" else "text"))
                out.extend(b[1])
                out.append(fence)
            elif kind == "table":
                t, numeric = b[1], b[2]
                out.append("| " + " | ".join(md(c) or " " for c in t.columns)
                           + " |")
                out.append("|" + "|".join("---:" if c in numeric else "---"
                                          for c in t.columns) + "|")
                for r in t.rows:
                    out.append("| " + " | ".join(md(clip(v)) or " " for v in r)
                               + " |")
            out.append("")
    return "\n".join(out).rstrip("\n") + "\n"


CSS = """
:root { color-scheme: light dark; }
body { font: 15px/1.45 system-ui, -apple-system, "Segoe UI", sans-serif;
       max-width: 72rem; margin: 2rem auto; padding: 0 1rem; }
h1 { font-size: 1.6rem; } h2 { margin-top: 2rem; border-bottom: 1px solid
#8884; } h3 { margin-top: 1.5rem; }
table { border-collapse: collapse; margin: .5rem 0 1rem; font-size: 13px; }
th, td { border: 1px solid #8885; padding: .2rem .5rem; text-align: left;
         vertical-align: top; white-space: pre-wrap; overflow-wrap: anywhere; }
th { background: #8882; } td.n { text-align: right;
     font-variant-numeric: tabular-nums; }
table.facts th { width: 11rem; }
pre { background: #8881; padding: .6rem .8rem; overflow-x: auto; }
code, pre { font: 13px/1.4 ui-monospace, Menlo, Consolas, monospace; }
@media print { pre, table { break-inside: avoid; } }
"""


def esc(s):
    return html.escape(s or "", quote=True)


def esc_cell(s):
    return esc(clip(s)).replace("\n", "<br>")


def render_html(title, sections):
    out = ["<!doctype html>", '<html lang="en">', "<head>",
           '<meta charset="utf-8">',
           # nothing may run and nothing is fetched: a page safe to attach
           '<meta http-equiv="Content-Security-Policy" content="default-src '
           "'none'; style-src 'unsafe-inline'; img-src 'none'; "
           "form-action 'none'; base-uri 'none'\">",
           '<meta name="viewport" content="width=device-width, '
           'initial-scale=1">',
           '<meta name="generator" content="%s %s">' % (PROG, VERSION),
           "<title>%s</title>" % esc(title),
           "<style>%s</style>" % CSS, "</head>", "<body>",
           "<h1>%s</h1>" % esc(title)]
    for sec in sections:
        out.append("<section>")
        out.append("<h%d>%s</h%d>" % (sec.level, esc(sec.title), sec.level))
        for b in sec.blocks:
            kind = b[0]
            if kind == "p":
                out.append("<p>%s</p>" % esc(b[1]))
            elif kind == "facts":
                out.append('<table class="facts">')
                out.extend("<tr><th>%s</th><td>%s</td></tr>"
                           % (esc(k), esc_cell(v)) for k, v in b[1])
                out.append("</table>")
            elif kind == "items":
                out.append("<ul>")
                out.extend("<li>%s</li>" % esc(clip(x, 400)) for x in b[1])
                out.append("</ul>")
            elif kind == "files":
                out.append("<ul>")
                out.extend('<li><a href="%s">%s</a></li>' % (esc(p), esc(p))
                           for p in b[1])
                out.append("</ul>")
            elif kind == "code":
                out.append("<pre><code>%s</code></pre>"
                           % esc("\n".join(b[1])))
            elif kind == "pre":
                out.append('<pre class="out">%s</pre>' % esc("\n".join(b[1])))
            elif kind == "table":
                t, numeric = b[1], b[2]
                out.append("<table><thead><tr>%s</tr></thead><tbody>" % "".join(
                    "<th>%s</th>" % esc(c) for c in t.columns))
                for r in t.rows:
                    out.append("<tr>%s</tr>" % "".join(
                        '<td class="n">%s</td>' % esc_cell(v)
                        if c in numeric else "<td>%s</td>" % esc_cell(v)
                        for c, v in zip(t.columns, r)))
                out.append("</tbody></table>")
        out.append("</section>")
    out.extend(["</body>", "</html>"])
    return "\n".join(out) + "\n"


# ---------------------------------------------------------------------------
# The package on disk
# ---------------------------------------------------------------------------

class Package(object):
    """The report's files, written into a scratch directory beside where
    they are going, and moved there whole when every one is written."""

    def __init__(self, parent):
        self.tmp = tempfile.mkdtemp(prefix=".qd-report.", dir=parent)
        self.paths = []

    def _path(self, rel):
        if rel in self.paths:
            raise ValueError("written twice: %s" % rel)
        p = os.path.join(self.tmp, *rel.split("/"))
        d = os.path.dirname(p)
        if not os.path.isdir(d):
            os.makedirs(d)
        self.paths.append(rel)
        return p

    def write(self, rel, text):
        data = text if isinstance(text, bytes) else text.encode("utf-8")
        with open(self._path(rel), "wb") as fh:
            fh.write(data)
        return rel

    def copy(self, rel, src):
        shutil.copyfile(src, self._path(rel))
        return rel

    def full(self, rel):
        return os.path.join(self.tmp, *rel.split("/"))

    def table(self, base, t):
        """base.csv and base.json: what `qd export --format csv|json`
        writes for the same table."""
        return [self.write(base + ".csv", tablemod.to_csv(t)),
                self.write(base + ".json", tablemod.to_json(t))]

    def sums(self):
        """SHA256SUMS over every file, in `sha256sum -c`'s format."""
        lines = ["%s  %s" % (sha256_file(self.full(p)), p)
                 for p in sorted(self.paths)]
        return self.write("SHA256SUMS", "\n".join(lines) + "\n")

    def size(self):
        return sum(os.path.getsize(self.full(p)) for p in self.paths)

    def zip_to(self, dest, top):
        fd, tmp = tempfile.mkstemp(prefix=".qd-report.", suffix=".zip",
                                   dir=os.path.dirname(dest) or ".")
        os.close(fd)
        try:
            stamp = time.localtime()[:6]
            with zipfile.ZipFile(tmp, "w", zipfile.ZIP_DEFLATED) as z:
                for rel in sorted(self.paths):
                    info = zipfile.ZipInfo(top + "/" + rel, stamp)
                    info.compress_type = zipfile.ZIP_DEFLATED
                    info.external_attr = 0o644 << 16
                    with open(self.full(rel), "rb") as fh:
                        z.writestr(info, fh.read())
            os.replace(tmp, dest)
        finally:
            if os.path.exists(tmp):
                os.unlink(tmp)

    def discard(self):
        shutil.rmtree(self.tmp, ignore_errors=True)


# ---------------------------------------------------------------------------
# What is reported on
# ---------------------------------------------------------------------------

class Subject(object):
    """A run, or a campaign (or a design: any group of runs) and its
    parts."""

    def __init__(self, st, kind, name, runs, latest, parts=(), campaign=None,
                 not_run=()):
        self.st = st
        self.kind = kind              # run, campaign or design
        self.name = name
        self.runs = runs              # every run in it, oldest first
        self.latest = latest          # [(part, run)]: what it found
        self.parts = list(parts)
        self.campaign = campaign
        self.not_run = list(not_run)


def resolve(st, ref):
    if ref.startswith("campaign:"):
        return group_subject(st, ref[len("campaign:"):])
    if os.path.exists(ref):
        die("qd report reads what the store holds, and %s is a file: `qd "
            "import %s` files it, then report on that run" % (ref, sh(ref)))
    r, tname = storemod.split_ref(ref)
    if tname:
        die("a report covers every table of a run: name the run (%s), not "
            "one of its tables" % r)
    e = st.resolve(r)
    if not isinstance(e, storemod.Run):
        die("%s is a whole dataset, not a run: report on a run of it (qd log "
            "lists them)" % e.id)
    return Subject(st, "run", e.id, [e], [("", e)])


def group_subject(st, name):
    from . import campaign as camp
    if not name:
        die("which campaign? %s report campaign:NAME" % PROG)
    c = camp.load_all(st).get(name)
    runs = [e for e in st.entries() if e.meta.get("group") == name]
    if c is None and not runs:
        die("no campaign or design %r in the store %s (qd campaign ls, qd "
            "log)" % (name, st.shown()))
    by = {}
    order = []
    for e in runs:
        p = e.meta.get("part") or ""
        if p not in by:
            by[p] = []
            order.append(p)
        by[p].append(e)
    parts = [p for p, _ in c.parts] if c is not None else order
    parts += [p for p in order if p not in parts]
    latest = [(p, by[p][-1]) for p in parts if p in by]
    # in the order they ran, as `qd compare --group` lines them up
    pos = dict((id(e), i) for i, e in enumerate(runs))
    latest.sort(key=lambda pe: pos[id(pe[1])])
    return Subject(st, "campaign" if c is not None else "design", name,
                   runs, latest, parts, c,
                   [p for p in parts if p not in by])


# ---------------------------------------------------------------------------
# The report
# ---------------------------------------------------------------------------

class Report(object):
    def __init__(self, args, subject, pkg):
        self.args = args
        self.subject = subject
        self.pkg = pkg
        self.st = subject.st
        self.sections = []
        self.findings = []
        self.left_out = []
        self.commands = []
        self.runs = {}            # run id -> its manifest entry
        self.tables = {}          # run id -> [(info, Table, describe, base)]
        self.manifest = {}

    # -- commands that print the same figures ----------------------------

    def ref(self, e, table=None):
        return sh(shown_id(e, table))

    def qd(self, words, entries=()):
        """`qd WORDS` as typed to read these runs: --store for those in
        the command's own store (a REF@STORE names its own)."""
        entries = list(entries) or [None]
        own = [e for e in entries if e is None or
               getattr(e.store, "via", None) is None]
        st = own[0].store if own and own[0] is not None else self.st
        tail = (" --store " + store_arg(st)) if own else ""
        return "%s %s%s" % (PROG, words, tail)

    def say(self, sec, what, cmds):
        sec.code(cmds)
        for c in cmds:
            self.commands.append({"for": what, "command": c})

    def leave_out(self, what, why):
        self.left_out.append({"section": what, "why": why})

    def section(self, title, level=2):
        s = Section(title, level)
        self.sections.append(s)
        return s

    # -- a run's files ----------------------------------------------------

    def add_run(self, e):
        st = e.store
        d = "data/" + safe(e.id, "run")
        entry = {"id": e.id, "dir": d, "record": record(e), "tables": [],
                 "captures": []}
        if e.meta.get("part"):
            entry["part"] = e.meta["part"]
        taken = set()
        loaded = []
        for info in e.tables:
            name = safe(info["name"], "table")
            k = 2
            while name in taken or name + ".stats" in taken or \
                    name in ("outliers", "check", "captures"):
                name = "%s-%d" % (safe(info["name"], "table"), k)
                k += 1
            taken.update((name, name + ".stats"))
            t = e.load_info(info)
            base = "%s/%s" % (d, name)
            files = self.pkg.table(base, t)
            desc = stats.describe(t)
            files += self.pkg.table(base + ".stats", desc)
            entry["tables"].append({"name": info["name"], "rows": len(t.rows),
                                    "columns": len(t.columns),
                                    "files": files})
            loaded.append((info, t, desc, base))
        for cid in e.captures():
            src = st.path("captures", cid, "output.txt")
            if not os.path.isfile(src):
                self.findings.append("capture %s of %s is not in the store "
                                     "any more" % (cid, e.id))
                continue
            rel = self.pkg.copy("%s/captures/%s.txt" % (d, cid), src)
            meta = st.meta(cid)
            ctx = st.context(cid)
            got = sha256_file(self.pkg.full(rel))
            rec = meta.get("output_sha256", "")
            c = {"id": cid, "file": rel, "bytes": os.path.getsize(
                self.pkg.full(rel)), "sha256": got,
                 "datasets": [n for n in meta.get("dataset", "").split(",")
                              if n]}
            for k in ("host", "pass"):
                if ctx.get(k):
                    c[k] = ctx[k]
            if meta.get("input_sha256"):
                c["input_sha256"] = meta["input_sha256"]
            if rec:
                c["recorded_sha256"] = rec
                c["matches_record"] = got == rec
                if got != rec:
                    self.findings.append(
                        "capture %s of %s does not hash to the sha256 provost "
                        "recorded for it" % (cid, e.id))
            n = storemod.first_row(meta)
            if n is not None:
                # a row number: what every provost's `source` takes
                c["source"] = st.provost("source %d" % n)
            entry["captures"].append(c)
        entry["manifest_keys"], entry["annotations"] = manifest_keys(st, e)
        self.runs[e.id] = entry
        self.tables[e.id] = loaded
        return entry

    def data_tables(self, e):
        """The tables a run measured: all of a `qd do`'s, a fan-out's data
        (its hosts table is the Hosts section)."""
        out = self.tables.get(e.id, [])
        if e.meta.get("kind") == "run":
            out = [x for x in out if x[0]["name"] == "data"]
        return out


def record(e):
    """The run's qd.runs row: every column it has a value for."""
    out = dict((k, e.row[k]) for k in storemod.RUN_COLUMNS
               if e.row.get(k, "") != "")
    if e.row.get("_capture"):
        out["capture"] = e.row["_capture"]
    return out


def manifest_keys(st, e):
    """({key: {value: captures}}, {key: {value: captures}}): the '#%' keys
    of a run's captures, and the ones `provost annotate` added later."""
    keys, notes = {}, {}
    for cid in e.captures():
        for k, v in prologue_pairs(st.context_text(cid)):
            if k in QD_KEYS:
                continue
            keys.setdefault(k, {})
            keys[k][v] = keys[k].get(v, 0) + 1
        p = st.path("captures", cid, "annotations.txt")
        if os.path.isfile(p):
            for k, v in prologue_pairs(read_text(p)):
                notes.setdefault(k, {})
                notes[k][v] = notes[k].get(v, 0) + 1
    return keys, notes


def keys_table(keys, ncap, when):
    rows = []
    for k in sorted(keys):
        vals = keys[k]
        n = sum(vals.values())
        if len(vals) == 1:
            shown = list(vals)[0]
        else:
            top = sorted(vals.items(), key=lambda kv: (-kv[1], kv[0]))
            shown = "%d values: %s" % (len(vals), ", ".join(
                "%s (%d)" % kv for kv in top[:6]) + (", ..." if len(top) > 6
                                                     else ""))
        rows.append([k, shown, "%d of %d" % (n, ncap), when])
    return rows


# ---------------------------------------------------------------------------
# Sections
# ---------------------------------------------------------------------------

def run_facts(e):
    m, row = e.meta, e.row
    via = [("as " + m["ssh_user"]) if m.get("ssh_user") else "",
           ("key " + m["ssh_key"]) if m.get("ssh_key") else "",
           {"yes": "under sudo", "no": "no sudo"}.get(m.get("sudo", ""), "")]
    tools = ", ".join(v for _, v in sorted((m.get("tools") or {}).items()))
    return [("run", shown_id(e)), ("name", m.get("name")),
            ("kind", m.get("kind")), ("command", m.get("command")),
            ("created", m.get("created")), ("finished", row.get("finished")),
            ("took", ("%ss" % stats.fmt_num(m["duration_s"]))
             if isinstance(m.get("duration_s"), float) else
             m.get("duration_s")),
            ("passes", ("%d every %ss" % (m["passes"], m.get("every")))
             if (m.get("passes") or 1) > 1 else ""),
            ("exit", m.get("rc")),
            ("by", storemod.operator_shown(m)),
            ("ssh", ", ".join(v for v in via if v)),
            ("campaign or design", m.get("group")), ("part", m.get("part")),
            ("factors", storemod.shown_attrs(m.get("factors"))
             if m.get("factors") else ""),
            ("tool", tools), ("cwd", m.get("cwd")),
            ("qd that ran it", row.get("qd")),
            ("notes", "; ".join(m.get("notes") or [])),
            ("filed as", e.row.get("_capture") and "qd.runs row in capture %s"
             % e.row["_capture"])]


def last_pass_rows(e):
    """The run's qd.hosts rows of its last pass: what its counts count."""
    rows = e.store.host_rows(e.id)
    last = str(e.meta.get("passes") or 1)
    return [h for h in rows if (h.get("pass") or "1") == last]


def hosts_counts(e):
    h = e.meta.get("hosts") or {}
    total = h.get("total", 0)
    return total, h.get("ok", 0), [(k, h[k]) for k in storemod.OUTCOMES
                                   if k != "ok" and h.get(k)]


def hosts_text(total, ok, bad):
    words = "%s asked: %d ok" % (plural(total, "host"), ok)
    if total - ok:
        words += ", %d did not answer (%s)" % (
            total - ok, ", ".join("%d %s" % (n, k) for k, n in bad))
    return words


def bad_hosts(e, part=None):
    rows = []
    for h in last_pass_rows(e):
        if h.get("status") == "ok":
            continue
        rows.append(([part] if part is not None else []) + [
            h.get("host", ""), h.get("status", ""), h.get("rc", ""),
            h.get("error", "") or clip(h.get("stderr", ""), 120)])
    return rows


def hosts_section(rep, sec, e):
    total, ok, bad = hosts_counts(e)
    sec.text(hosts_text(total, ok, bad) + ".")
    if total - ok:
        rep.findings.append("%s: %d of %s did not answer" % (
            shown_id(e), total - ok, plural(total, "host")))
    rows = bad_hosts(e)
    if rows:
        t = Table(["host", "status", "rc", "error"], rows, "hosts")
        sec.table(t, rest=rep.runs[e.id]["dir"] + "/hosts.csv")
    rep.say(sec, "hosts", [
        rep.qd("log %s" % rep.ref(e), [e]),
        rep.qd("show %s --where %s" % (rep.ref(e, "hosts"),
                                      sh("status!=ok")), [e])])


FIGURE_COLUMNS = ["column", "kind", "n", "blank", "distinct", "mean",
                  "median", "min", "p95", "max", "top"]


def table_ref(e, info):
    """A table as a reference names it: the run alone for its first
    table (what every reading command reads by default), RUN:TABLE for
    the others."""
    return None if e.tables and info is e.tables[0] else info["name"]


def figures_section(rep, sec, e):
    tables = rep.data_tables(e)
    for info, t, desc, base in tables:
        keep = [r for r in desc.rows if r[0] not in NOT_FIGURES and
                r[1] != "empty"]
        idx = [desc.columns.index(c) for c in FIGURE_COLUMNS]
        sub = Table(FIGURE_COLUMNS, [[r[i] for i in idx] for r in keep],
                    "figures")
        sec.text("%s%s, %s." % (
            ("Table %s: " % info["name"]) if len(tables) > 1 else "",
            plural(len(t.rows), "row"), plural(len(t.columns), "column")))
        if sub.rows:
            sec.table(sub, numeric=FIGURE_COLUMNS[2:10],
                      rest=base + ".stats.csv")
        for n in t.notes[:8]:
            sec.text("Note from the table: " + n)
        rep.say(sec, "figures", [rep.qd("stats %s" % rep.ref(
            e, table_ref(e, info)), [e])])
    if not tables:
        sec.text("The run holds no tables: nothing it filed is in the store "
                 "any more.")


def outliers_section(rep, sec, e, z):
    out_rows = []
    hits, quiet = [], []
    for info, t, _, base in rep.data_tables(e):
        tname = table_ref(e, info)
        for col in comparemod.common_numeric([t]):
            if t.is_results() and col == "value" and \
                    len(set(t.values("test"))) > 1:
                continue
            per = stats.default_per(t, col)
            rows, inf = stats.outliers(t, col, per, z)
            if not inf["n"]:
                continue
            who = per or ("host" if t.has("host") else "row")
            cells = stats.outlier_cells(rows)
            for c in cells:
                out_rows.append([info["name"], col, who] + c)
            if cells:
                hits.append((tname, col, who, inf, cells))
            else:
                quiet.append((tname, col))
    d = rep.runs[e.id]["dir"]
    ot = Table(["table", "column", "per", "key"] + stats.OUTLIER_SHOWN,
               out_rows, "outliers")
    files = rep.pkg.table(d + "/outliers", ot)
    rep.runs[e.id]["outliers"] = {"files": files, "z": z,
                                  "rows": len(out_rows)}
    if not hits and not quiet:
        sec.text("No numeric column to look for outliers in.")
        return
    sec.text("Robust z-score past %s, by the median and the MAD (qd "
             "outliers): %s with outliers, %s without." % (
                 stats.fmt_num(z), plural(len(hits), "column"),
                 plural(len(quiet), "column")))
    cmds = []
    for tname, col, who, inf, cells in hits[:OUTLIER_COLUMNS]:
        sec.text("%s%s: median %s, MAD %s over %d %ss; %d far from the "
                 "rest%s." % (
                     col, (" in " + tname) if tname else "",
                     stats.fmt_num(inf["median"]), stats.fmt_num(inf["mad"]),
                     inf["n"], who, len(cells),
                     "; most agree exactly, so every value that differs is "
                     "listed" if not inf["mad"] else ""))
        sec.table(Table([who] + stats.OUTLIER_SHOWN, cells, "outliers"),
                  numeric=("value", "of_median", "robust_z"),
                  rest=files[0], limit=OUTLIER_ROWS)
        cmds.append(rep.qd("outliers %s %s%s" % (
            rep.ref(e, tname), sh(col),
            (" --z %s" % stats.fmt_num(z)) if z != 3.5 else ""), [e]))
    if len(hits) > OUTLIER_COLUMNS:
        sec.text("... %d more column(s) with outliers in %s"
                 % (len(hits) - OUTLIER_COLUMNS, files[0]))
    if quiet:
        sec.text("None in: %s%s." % (", ".join(c for _, c in quiet[:30]),
                                     ", ..." if len(quiet) > 30 else ""))
    if not cmds:
        # nothing far out: the first column looked at, to see it is so
        tname, col = quiet[0]
        cmds.append(rep.qd("outliers %s %s%s" % (
            rep.ref(e, tname), sh(col),
            (" --z %s" % stats.fmt_num(z)) if z != 3.5 else ""), [e]))
    rep.say(sec, "outliers", cmds)


def kept_check(st, e):
    """The verdicts `qd check RUN --keep` filed for a run, latest first,
    or None."""
    name = "check-" + shown_id(e)
    kept = [x for x in st.entries() if x.meta.get("kind") == "check" and
            x.meta.get("name") == name]
    return kept[-1] if kept else None


def check_tables(rep, e, checks, against):
    """(verdict table, counts, how) for a run: against --check, or the
    verdicts kept for it; None when there is neither."""
    if checks is not None:
        t = e.load()
        results = checkmod.run(t, checks)
        vt = Table(checkmod.SUMMARY_COLUMNS, checkmod.summary_rows(results),
                   "check")
        cmd = rep.qd("check %s --against %s" % (rep.ref(e), sh(against)),
                     [e])
        return vt, checkmod.counts(results), cmd, None
    k = kept_check(rep.st, e)
    if k is None:
        return None
    vt = k.load()
    n = {checkmod.PASS: 0, checkmod.FAIL: 0, checkmod.UNMEASURED: 0}
    if vt.has("verdict"):
        for v in vt.values("verdict"):
            if v in n:
                n[v] += 1
    return vt, n, rep.qd("show %s" % rep.ref(k), [k]), k


def counts_text(n):
    return "%d pass, %d fail, %d not measured" % (
        n[checkmod.PASS], n[checkmod.FAIL], n[checkmod.UNMEASURED])


def write_check(rep, e, vt, n, kept):
    d = rep.runs[e.id]["dir"]
    files = rep.pkg.table(d + "/check", vt)
    rep.runs[e.id]["check"] = {
        "files": files, "pass": n[checkmod.PASS], "fail": n[checkmod.FAIL],
        "not_measured": n[checkmod.UNMEASURED],
        "from": ("kept: %s" % kept.id) if kept is not None else "--check"}
    if n[checkmod.FAIL] or n[checkmod.UNMEASURED]:
        rep.findings.append("%s: checks %s" % (shown_id(e), counts_text(n)))
    return files


# ---------------------------------------------------------------------------
# Building it
# ---------------------------------------------------------------------------

def tool_exit(rep, e):
    if e.meta.get("kind") == "do" and e.meta.get("rc") not in (None, 0):
        rep.findings.append("%s: the tool exited %s" % (shown_id(e),
                                                         e.meta["rc"]))


def checks_section(rep, sec, e, checks, against):
    """A run's verdicts, against --check or as `qd check --keep` filed
    them; False when there are none to show."""
    ct = check_tables(rep, e, checks, against)
    if ct is None:
        return False
    vt, n, cmd, kept = ct
    files = write_check(rep, e, vt, n, kept)
    if kept is not None:
        sec.text("The verdicts qd check --keep filed for this run as %s "
                 "(%s): %s." % (kept.id, kept.meta.get("created", ""),
                                counts_text(n)))
        for note in vt.notes[:2]:
            sec.text("They came from: " + note)
    else:
        sec.text("Against %s: %s." % (against, counts_text(n)))
    sec.table(vt, numeric=("observed",), rest=files[0])
    rep.say(sec, "checks", [cmd])
    return True


def run_sections(rep, e, checks, against):
    """The sections about one run: what it was, its hosts, its figures,
    its checks, its outliers."""
    rep.section("Run %s" % shown_id(e)).facts(run_facts(e))
    tool_exit(rep, e)
    if e.meta.get("kind") == "run":
        hosts_section(rep, rep.section("Hosts"), e)
    figures_section(rep, rep.section("Figures"), e)
    sec = Section("Checks")
    if checks_section(rep, sec, e, checks, against):
        rep.sections.append(sec)


def baseline_section(rep, base, runs, labels):
    """Medians of every numeric column, the baseline's and each run's,
    and the hosts whose status changed: `qd compare BASELINE RUN...`."""
    tables = [base.load()] + [e.load() for e in runs]
    res = comparemod.compare(tables, None, None, rep.args.drift, "median", 0)
    drift = rep.args.drift
    heads = ["column", "baseline"] + labels + ["moved"]
    rows, moved = [], 0
    for c, meds in res.columns:
        flags = []
        for lab, m in zip(labels, meds[1:]):
            d = comparemod.pct(meds[0], m)
            if d is None:
                continue
            if d in (float("inf"), float("-inf")):
                flags.append("%s from 0" % lab)
            elif abs(d) > drift:
                flags.append("%s %+.1f%%" % (lab, d))
        moved += 1 if flags else 0
        rows.append([c] + [comparemod.num(m) for m in meds] +
                    ["; ".join(flags)])
    mt = Table(heads, rows, "baseline")
    files = rep.pkg.table("data/baseline", mt)
    wide = comparemod.wide_table(res)
    files += rep.pkg.table("data/baseline-hosts", wide)
    changed = [r for r in wide.rows if r[-1]]
    sec = rep.section("Against the baseline")
    sec.facts([("baseline", shown_id(base)),
               ("its command", base.meta.get("command")),
               ("its date", base.meta.get("created")),
               ("drift", "a median moving more than %s%%"
                % stats.fmt_num(drift))])
    for n in res.notes:
        sec.text("Note: " + n)
    sec.text("%s compared by median: %d moved past %s%%; %s changed "
             "status." % (plural(len(rows), "column"), moved,
                          stats.fmt_num(drift), plural(len(changed), "key")))
    if rows:
        sec.table(mt, numeric=heads[1:-1], rest=files[0])
    if changed:
        sec.table(wide.derive(rows=changed), rest=files[2])
    rep.manifest["baseline"] = {
        "run": shown_id(base), "drift_pct": drift, "columns": len(rows),
        "moved": moved, "status_changed": len(changed), "files": files}
    if moved or changed:
        rep.findings.append("against %s: %s" % (shown_id(base), "; ".join(
            x for x in (
                moved and "%s moved more than %s%%" % (
                    plural(moved, "column"), stats.fmt_num(drift)),
                changed and "%s changed status" % plural(len(changed), "key"))
            if x)))
    rep.say(sec, "baseline", [rep.qd("compare %s %s%s" % (
        rep.ref(base), " ".join(rep.ref(e) for e in runs),
        (" --drift %s" % stats.fmt_num(drift)) if drift != 5.0 else ""),
        [base] + list(runs))])


def campaign_sections(rep, checks, against):
    from . import campaign as camp
    s = rep.subject
    c = s.campaign
    sec = rep.section("Campaign %s" % s.name if c is not None
                      else "Design %s" % s.name)
    total_hosts = sum(len(hs) for _, hs in c.parts) if c is not None else 0
    commands = sorted(set(e.meta.get("command", "") for e in s.runs))
    sec.facts([("name", s.name),
               ("command", c.command if c is not None else
                "; ".join(commands)),
               ("split", c.split if c is not None else ""),
               ("parts", "%d (%d run, %d not yet)" % (
                   len(s.parts), len(s.latest), len(s.not_run))),
               ("hosts", total_hosts or ""),
               ("runs", "%d (%d earlier runs of a part, superseded by a "
                "later one)" % (len(s.runs), len(s.runs) - len(s.latest))
                if len(s.runs) > len(s.latest) else len(s.runs)),
               ("pool", c.pool if c is not None else ""),
               ("at most", c.max_per if c is not None else ""),
               ("ramp", c.ramp if c is not None else ""),
               ("windows", c.window if c is not None else "")])
    if c is not None:
        try:
            _, rows = camp.describe(rep.st, c, quiet=True)
        except QdError as exc:
            sec.text("The pool could not be read (%s): its states are "
                     "left out." % exc)
            rows = [r[:2] + ["?"] + r[3:] for r in
                    _describe_without_pool(rep.st, c)]
        pt = Table(camp.STATUS_COLUMNS, rows, "parts")
        how = rep.qd("campaign status %s" % sh(s.name))
    else:
        rows = []
        latest = dict(s.latest)
        for p in s.parts:
            rs = [e for e in s.runs if (e.meta.get("part") or "") == p]
            last = latest.get(p)
            total, ok, _ = hosts_counts(last) if last else (0, 0, [])
            rows.append([p, str(len(rs)), last.id if last else "",
                         ("%d/%d" % (ok, total)) if total else "",
                         ("ok" if ok == total else "hosts failed")
                         if total else ""])
        pt = Table(["part", "runs", "last_run", "ok", "verdict"], rows,
                   "parts")
        how = rep.qd("doe status %s" % sh(s.name))
    files = rep.pkg.table("data/parts", pt)
    sec.table(pt, numeric=("hosts", "runs"), rest=files[0])
    if s.not_run:
        rep.findings.append("%s of %s not run yet: %s" % (
            plural(len(s.not_run), "part"), plural(len(s.parts), "part"),
            ", ".join(s.not_run[:10]) + (", ..." if len(s.not_run) > 10
                                         else "")))
    rep.say(sec, "parts", [how])

    # every part's hosts, as one count
    sec = rep.section("Hosts")
    total = ok = 0
    bad_by = {}
    rows = []
    for p, e in s.latest:
        if e.meta.get("kind") != "run":
            continue
        t, o, bad = hosts_counts(e)
        total, ok = total + t, ok + o
        for k, n in bad:
            bad_by[k] = bad_by.get(k, 0) + n
        rows.extend(bad_hosts(e, p))
    sec.text("Over the last run of each part: " + hosts_text(
        total, ok, [(k, bad_by[k]) for k in storemod.OUTCOMES
                    if bad_by.get(k)]) + ".")
    if total - ok:
        rep.findings.append("%d of %s did not answer in the parts' last "
                            "runs" % (total - ok, plural(total, "host")))
    if rows:
        sec.table(Table(["part", "host", "status", "rc", "error"], rows,
                        "hosts"))
    rep.say(sec, "hosts", [rep.qd("show %s --where %s" % (
        rep.ref(e, "hosts"), sh("status!=ok")), [e])
        for _, e in s.latest if e.meta.get("kind") == "run"])

    # the parts' medians side by side
    if len(s.latest) > 1:
        runs = [e for _, e in s.latest]
        res = comparemod.compare([e.load() for e in runs], None, None,
                                 rep.args.drift, "median", 0)
        labels = [p or e.id for p, e in s.latest]
        mt = Table(["column"] + labels, [
            [c] + [comparemod.num(m) for m in meds]
            for c, meds in res.columns], "medians")
        files = rep.pkg.table("data/parts-medians", mt)
        sec = rep.section("Medians by part")
        sec.text("Every numeric column the parts share, by its median in "
                 "each part's last run.")
        for n in res.notes:
            sec.text("Note: " + n)
        if mt.rows:
            sec.table(mt, numeric=labels, rest=files[0])
        same = [e.id for e in s.runs] == [e.id for e in runs]
        rep.say(sec, "medians by part", [rep.qd(
            "compare --group %s" % sh(s.name)) if same else rep.qd(
                "compare %s" % " ".join(rep.ref(e) for e in runs), runs)])

    # each requirement against each part's last run
    if checks is not None:
        mat = {}
        for p, e in s.latest:
            ct = check_tables(rep, e, checks, against)
            vt, n, _, kept = ct
            write_check(rep, e, vt, n, kept)
            for r in vt.rows:
                mat.setdefault(r[0], {})[p or e.id] = "%s%s" % (
                    r[vt.columns.index("verdict")],
                    (" (%s)" % r[vt.columns.index("observed")])
                    if r[vt.columns.index("observed")] else "")
        labels = [p or e.id for p, e in s.latest]
        rows = [[req] + [mat.get(req, {}).get(p, "") for p in labels]
                for req in [ck.req for ck in checks]]
        ct_t = Table(["req"] + labels, rows, "checks")
        files = rep.pkg.table("data/checks-by-part", ct_t)
        sec = rep.section("Checks by part")
        sec.text("Each requirement against each part's last run (%s); the "
                 "observed value in brackets." % against)
        sec.table(ct_t, rest=files[0])
        rep.say(sec, "checks", [rep.qd("check %s --against %s" % (
            rep.ref(e), sh(against)), [e]) for _, e in s.latest])
    else:
        kept = [p for p, e in s.latest if kept_check(rep.st, e) is not None]
        if not kept:
            rep.leave_out("checks", "no --check FILE given, and no verdicts "
                          "kept for any part's last run (qd check RUN "
                          "--against FILE --keep)")

def part_sections(rep, e, part):
    """One part's last run, after the campaign's own sections."""
    sec = rep.section("Part %s: run %s" % (part, shown_id(e)))
    sec.facts(run_facts(e))
    tool_exit(rep, e)
    if e.meta.get("kind") == "run":
        total, ok, bad = hosts_counts(e)
        sec.text(hosts_text(total, ok, bad) + ".")
    figures_section(rep, rep.section("Figures", 3), e)
    if rep.runs[e.id].get("check") is None:
        # no --check: the verdicts kept for this part, if any
        sec = Section("Checks", 3)
        if checks_section(rep, sec, e, None, None):
            rep.sections.append(sec)
    outliers_section(rep, rep.section("Outliers", 3), e, rep.args.z)


def _describe_without_pool(st, c):
    from . import campaign as camp
    runs = camp.part_runs(st, c.name)
    rows = []
    for part, hs in c.parts:
        rs = runs.get(part, [])
        last = rs[-1] if rs else None
        h = (last.meta.get("hosts") or {}) if last else {}
        ok = ("%d/%d" % (h.get("ok", 0), h.get("total", 0))) if h else ""
        verdict = ""
        if last is not None:
            verdict = "ok" if h.get("ok", 0) == h.get("total", 0) \
                else "hosts failed"
        rows.append([part, str(len(hs)), "", str(len(rs)),
                     last.id if last else "", ok, verdict,
                     last.meta.get("finished", "") if last else ""])
    return rows


def keys_section(rep):
    """The '#%' keys of every capture reported on (PV-020's run manifest),
    and the post-run ones `provost annotate` added."""
    keys, notes, ncap, first = {}, {}, 0, None
    for e in rep.subject.runs:
        ent = rep.runs[e.id]
        ncap += len(ent["captures"])
        if first is None and ent["captures"]:
            first = ent["captures"][0]
        for src, dst in ((ent["manifest_keys"], keys),
                         (ent["annotations"], notes)):
            for k, vals in src.items():
                for v, n in vals.items():
                    dst.setdefault(k, {})
                    dst[k][v] = dst[k].get(v, 0) + n
    rep.manifest["manifest_keys"] = {"captures": ncap, "run": keys,
                                     "post_run": notes}
    if not keys and not notes:
        rep.leave_out("run manifest", "the captures carry no #% keys beyond "
                      "qd's own run, host and pass (provost's run-manifest "
                      "keys, PV-020, go in a capture's prologue)")
        return
    sec = rep.section("Run manifest")
    sec.text("The #%% keys of the %s, as provost reads them (PV-020), with "
             "how many carry each; qd's own run, host and pass are left out. "
             "Post-run keys are the ones provost annotate added after the "
             "run." % plural(ncap, "capture"))
    rows = keys_table(keys, ncap, "run") + keys_table(notes, ncap, "post-run")
    sec.table(Table(["key", "value", "captures", "when"], rows, "manifest"))
    if first:
        # by capture id where there are annotations (only a provost that
        # has them shows them so), else by row, as every provost takes it
        how = first["id"] if notes or "source" not in first else None
        rep.say(sec, "run manifest", [
            rep.st.provost("source %s" % how) if how else first["source"]])


def verify_section(rep):
    """`provost verify` on every capture the report's runs filed (PV-026):
    its output kept as verify.txt, its findings counted."""
    st = rep.st
    caps = set()
    for e in rep.subject.runs:
        caps.update(st.all_run_captures(e))
    caps = sorted(caps, key=lambda c: storemod.cnum(c) or 0)
    prov = filing.Provost(st)
    if not prov.argv:
        rep.leave_out("store integrity", "provost is not installed here, so "
                      "provost verify could not run")
        return
    rc, out, _ = prov.call(["verify", "--help"])
    if rc != 0 or "usage: provost verify" not in out:
        rep.leave_out("store integrity", "this provost (%s) has no verify "
                      "(PV-026, in provost after 2.3.0)"
                      % " ".join(prov.argv))
        return
    args = ["verify"]
    for k in range(0, len(caps), filing.RM_CHUNK):
        args += ["--capture", ",".join(caps[k:k + filing.RM_CHUNK])]
    rc, out, err = prov.call(args)
    text = ANSI_RE.sub("", out + err)
    rep.pkg.write("verify.txt", text)
    found = len([ln for ln in text.splitlines()
                 if ln.lstrip().startswith("FAIL")])
    m = re.search(r"^\s*(\S+) at ([0-9a-f]{7,64})\s*$", text, re.M)
    if len(caps) <= 40:
        cmd = st.provost(" ".join(sh(a) for a in args))
    else:
        rep.pkg.write("verify-captures.txt", "\n".join(caps) + "\n")
        cmd = st.provost('verify --capture "$(paste -sd , '
                         'verify-captures.txt)"')
    rep.manifest["verify"] = {
        "command": st.provost(" ".join(sh(a) for a in args)),
        "exit": rc, "findings": found, "captures": len(caps),
        "head": m.group(2) if m else "", "output": "verify.txt"}
    sec = rep.section("Store integrity")
    sec.facts([("verdict", "no findings" if rc == 0 else
                "%s (exit %d)" % (plural(found, "finding"), rc)),
               ("checked", "the %s this report's runs filed; git fsck and "
                "the id sequence cover the whole store"
                % plural(len(caps), "capture")),
               ("head", ("%s at %s" % (m.group(1), m.group(2))) if m else "")])
    sec.text("provost verify shows the store is internally consistent: "
             "nothing in it was edited, lost or dropped without rewriting "
             "its history to match. It does not prove the history was never "
             "rewritten; record the head commit above outside the store to "
             "anchor it.")
    lines = text.rstrip("\n").splitlines()
    sec.pre(lines[:60] + (["... %d more line(s) in verify.txt"
                            % (len(lines) - 60)] if len(lines) > 60 else []))
    if rc != 0:
        rep.findings.append("provost verify: %s (verify.txt)"
                            % plural(found or 1, "finding"))
    rep.say(sec, "store integrity", [cmd])


def files_section(rep):
    sec = rep.section("Files")
    sec.text("Everything below is listed, with its sha256, in SHA256SUMS; "
             "manifest.json says what each run's files are.")
    for e in rep.subject.runs:
        ent = rep.runs[e.id]
        paths = [p for t in ent["tables"] for p in t["files"]]
        for k in ("outliers", "check"):
            paths += (ent.get(k) or {}).get("files", [])
        sec.text("Run %s%s: %s, and %s in %s/captures/ (each host's answer "
                 "exactly as provost keeps it)." % (
                     e.id, (" (part %s)" % ent["part"]) if ent.get("part")
                     else "", plural(len(ent["tables"]), "table"),
                     plural(len(ent["captures"]), "capture"), ent["dir"]))
        sec.files(paths)
    top = [p for p in sorted(rep.pkg.paths) if not p.startswith("data/")
           or p.count("/") == 1]
    sec.text("And:")
    sec.files(top + ["manifest.json", "summary.md", "summary.html",
                     "SHA256SUMS"])


def about_section(rep, argv):
    st = rep.st
    m = rep.manifest
    sec = rep.section("About this report")
    sec.facts([("made", m["generated"]),
               ("by", storemod.operator_shown(m["generated_by"])),
               ("with", "%s %s" % (PROG, " ".join(sh(a) for a in argv))),
               ("qd", m["versions"]["qd"]),
               ("provost", m["versions"]["provost"]),
               ("python", m["versions"]["python"]),
               ("store", st.root),
               ("store head", m["store"]["head"]),
               ("store format", m["store"]["format"])])


def intro_sections(rep):
    """What goes first, made last: how to check the package, and what it
    found."""
    s1 = Section("This package")
    s1.text("Each table is in data/ as CSV and JSON, with the statistics, "
            "outliers and checks computed from it and every answer as "
            "provost keeps it. Every figure here is the one the command "
            "under it prints. To check that no file has changed since the "
            "report was made, in this directory:")
    s1.code(["sha256sum -c SHA256SUMS            # or: shasum -a 256 -c "
             "SHA256SUMS"])
    s2 = Section("Findings")
    if rep.findings:
        s2.items(rep.findings)
    else:
        s2.text("None: every host answered, and nothing checked, compared "
                "or verified here failed.")
    return [s1, s2]


def left_out_section(rep):
    if not rep.left_out:
        return None
    sec = Section("Not in this report")
    sec.items("%s: %s" % (x["section"], x["why"]) for x in rep.left_out)
    return sec


# ---------------------------------------------------------------------------
# The whole of it
# ---------------------------------------------------------------------------

def default_out(subject):
    if subject.kind == "run":
        return "qd-report-" + safe(subject.name, "run")
    return "qd-report-%s-%s" % (subject.kind, safe(subject.name, "group"))


def preflight(st, out, want_zip):
    """Where the package goes, refused before anything is read: a
    directory that is new or empty, never inside the store."""
    out = os.path.abspath(os.path.expanduser(out))
    parent = os.path.dirname(out)
    if not os.path.isdir(parent):
        die("no such directory to write the report in: %s" % parent)
    if os.path.exists(out) and (not os.path.isdir(out) or os.listdir(out)):
        die("%s is there already%s: a report goes into a new directory "
            "(--out DIR)" % (out, "" if not os.path.isdir(out) else
                             " and is not empty"))
    root = os.path.realpath(st.root)
    if (os.path.realpath(out) + os.sep).startswith(root + os.sep):
        die("%s is inside the store %s, which provost commits whole: put "
            "the report somewhere else (--out DIR)" % (out, st.shown()))
    zpath = out + ".zip" if want_zip else None
    if zpath and os.path.exists(zpath):
        die("%s is there already: --zip writes a new one" % zpath)
    return out, parent, zpath


def make(args, where, argv=()):
    """Write the package.  -> (Report, its directory, its zip or None)"""
    from . import stores
    st, ref = where(args.ref or "latest")
    subject = resolve(st, ref)
    checks = against = None
    if args.check:
        checks = checkmod.read_thresholds(args.check)
        against = "inputs/" + safe(os.path.basename(args.check),
                                   "thresholds.tsv")
    base = None
    if args.baseline:
        bst, bref = where(args.baseline)
        base = bst.resolve(storemod.split_ref(bref)[0])
        if not isinstance(base, storemod.Run):
            die("the baseline %s is a whole dataset, not a run" % base.id)
        if any(comparemod.ident(base) == comparemod.ident(e)
               for _, e in subject.latest):
            die("the baseline %s is the run being reported on: name an "
                "earlier one" % shown_id(base))
    out, parent, zpath = preflight(st, args.out or default_out(subject),
                                   args.zip)
    try:
        pkg = Package(parent)
    except OSError as exc:
        die("cannot write the report in %s: %s" % (
            parent, exc.strerror or exc))
    try:
        rep = Report(args, subject, pkg)
        rep.manifest.update({
            "kind": KIND, "report_version": REPORT_VERSION,
            "generated": storemod.now_iso(), "generated_by": whoran.local(),
            "subject": {"kind": subject.kind, "name": subject.name,
                        "ref": args.ref or "latest"},
            "versions": {"qd": VERSION, "provost": stores.provost_version(),
                         "python": platform.python_version()},
            "store": {"path": st.root, "name": st.via or "",
                      "head": git_head(st.root),
                      "format": stores.store_format(st.root)}})
        if checks is not None:
            pkg.copy(against, args.check)
            rep.manifest["checks"] = {"thresholds": against,
                                      "given_as": args.check,
                                      "checks": len(checks)}
        for e in subject.runs:
            rep.add_run(e)
        if subject.kind == "run":
            e = subject.runs[0]
            run_sections(rep, e, checks, against)
            if checks is None and kept_check(st, e) is None:
                rep.leave_out("checks", "no --check FILE given, and no "
                              "verdicts kept for this run (qd check RUN "
                              "--against FILE --keep)")
        else:
            campaign_sections(rep, checks, against)
        if base is not None:
            labels = [p or e.id for p, e in subject.latest] \
                if subject.kind != "run" else ["run"]
            baseline_section(rep, base, [e for _, e in subject.latest],
                             labels)
        else:
            rep.leave_out("against a baseline", "no --baseline RUN given "
                          "(a run: qd baseline's named baselines are not "
                          "read here yet)")
        if subject.kind == "run":
            outliers_section(rep, rep.section("Outliers"), subject.runs[0],
                             args.z)
        else:
            for p, e in subject.latest:
                part_sections(rep, e, p or e.id)
        keys_section(rep)
        verify_section(rep)
        if subject.kind != "run":
            rep.manifest["campaign"] = {
                "name": subject.name, "kind": subject.kind,
                "parts": subject.parts, "not_run": subject.not_run,
                "last_runs": dict((p, e.id) for p, e in subject.latest)}
        files_section(rep)
        about_section(rep, argv)
        rep.manifest.update({
            "runs": [rep.runs[e.id] for e in subject.runs],
            "findings": rep.findings, "left_out": rep.left_out,
            "commands": rep.commands,
            "files": sorted(pkg.paths + ["manifest.json", "summary.md",
                                         "summary.html", "SHA256SUMS"])})
        pkg.write("manifest.json", json.dumps(rep.manifest, indent=1,
                                              sort_keys=True) + "\n")
        title = "%s report: %s %s" % (PROG, subject.kind, subject.name)
        rest = left_out_section(rep)
        sections = intro_sections(rep) + rep.sections + (
            [rest] if rest else [])
        pkg.write("summary.md", render_md(title, sections))
        pkg.write("summary.html", render_html(title, sections))
        pkg.sums()
        if os.path.isdir(out):
            os.rmdir(out)
        os.rename(pkg.tmp, out)
        pkg.tmp = out
    except OSError as exc:
        pkg.discard()
        die("cannot write the report: %s%s" % (
            exc.strerror or exc, (" (%s)" % exc.filename) if getattr(
                exc, "filename", None) else ""))
    except BaseException:
        pkg.discard()
        raise
    if zpath:
        try:
            pkg.zip_to(zpath, os.path.basename(out))
        except OSError as exc:
            die("the report is in %s, but its zip could not be written: %s"
                % (out, exc.strerror or exc))
    return rep, out, zpath
