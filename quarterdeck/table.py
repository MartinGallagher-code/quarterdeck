# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Martin J. Gallagher
"""Tables: what every dataset is, and every format they arrive in.

A table is named columns over rows of strings.  A blank cell is "not
measured" and stays blank all the way through -- it is never read as 0,
because averaging a gap as a zero is the one mistake that makes every
number look better than it is.

The formats read here are the ones the toolchain writes:

  CSV / TSV          iperf_results.csv, mx and netmesh reports, every
                     binnacle --csv, agree --merge-csv, anything else
  wide tables        `Timestamp  host  rtt (us)  loss %` -- what
                     monitoring writes and the floor-plan viewer reads
  results            the viewer's `test target value [k=v ...]`, with its
                     `!test` lines: mx export, iperf export-overlay,
                     reckon --overlay, dcprobe, dcimport
  NDJSON / JSON      the same results as objects, agree --json, reckon
                     --json, or any list of objects
  grids              `src\\dst` matrices: mx matrix.csv and --grid,
                     netmesh grids, iperf gen --grid
"""

import csv
import io
import json
import math
import re

from .common import die, read_text

VERDICTS = ("PASS", "WARN", "FAIL")


def to_num(text):
    """A cell as a number, or None.  `37%` reads as 37 (df's Use%, the
    viewer's `loss %`); nan and inf are not measurements."""
    if text is None:
        return None
    s = text.strip()
    if not s:
        return None
    if s.endswith("%"):
        s = s[:-1].rstrip()
    try:
        v = float(s)
    except ValueError:
        return None
    if math.isnan(v) or math.isinf(v):
        return None
    return v


def slug(name):
    return re.sub(r"[^0-9a-z]+", "_", name.lower()).strip("_")


class Table(object):
    """Columns, rows of strings, and where they came from.

    `tests` carries the results format's `!test` display metadata so a
    round trip through the logbook paints the same on the floor plan;
    `notes` carries the comment header a tool wrote above its data (mx and
    iperf say there what the run was and what they left out).
    """

    def __init__(self, columns, rows, name="data", source="", tests=None,
                 notes=None):
        self.columns = list(columns)
        width = len(self.columns)
        fixed = []
        for r in rows:
            r = list(r)
            if len(r) < width:
                r = r + [""] * (width - len(r))
            elif len(r) > width:
                r = r[:width]
            fixed.append(r)
        self.rows = fixed
        self.name = name
        self.source = source
        self.tests = tests if tests is not None else {}
        self.notes = notes if notes is not None else []
        self._num = {}

    def __len__(self):
        return len(self.rows)

    def derive(self, rows=None, columns=None, name=None):
        """A table over some of these rows or columns, keeping provenance."""
        if columns is None:
            columns = self.columns
            data = self.rows if rows is None else rows
        else:
            idx = [self.index(c) for c in columns]
            columns = [self.columns[i] for i in idx]
            data = [[r[i] for i in idx]
                    for r in (self.rows if rows is None else rows)]
        t = Table(columns, data, name or self.name, self.source, self.tests,
                  self.notes)
        if getattr(self, "entry", None) is not None:
            t.entry = self.entry
        return t

    # -- columns ------------------------------------------------------------

    def has(self, name):
        return self.find(name) is not None

    def find(self, name):
        """The column index for a name, or None.  Exact, then
        case-insensitive, then as a slug (`rtt (us)` is `rtt_us`), then a
        unique prefix of one."""
        if name in self.columns:
            return self.columns.index(name)
        low = name.lower()
        for i, c in enumerate(self.columns):
            if c.lower() == low:
                return i
        s = slug(name)
        for i, c in enumerate(self.columns):
            if slug(c) == s:
                return i
        if s:
            hits = [i for i, c in enumerate(self.columns)
                    if slug(c).startswith(s)]
            if len(hits) == 1:
                return hits[0]
        return None

    def index(self, name):
        i = self.find(name)
        if i is not None:
            return i
        s = slug(name)
        hits = [c for c in self.columns if s and slug(c).startswith(s)]
        if len(hits) > 1:
            die("column %r is ambiguous: %s" % (name, ", ".join(hits)))
        die("no column %r in %s (columns: %s)"
            % (name, self.name, ", ".join(self.columns) or "none"))

    def colname(self, name):
        return self.columns[self.index(name)]

    def values(self, name):
        i = self.index(name)
        return [r[i] for r in self.rows]

    def numbers(self, name):
        i = self.index(name)
        if i not in self._num:
            self._num[i] = [to_num(r[i]) for r in self.rows]
        return self._num[i]

    def kind(self, name):
        """num: every filled cell is a number.  mixed: some are.  text:
        none are.  empty: nothing was measured at all."""
        i = self.index(name)
        filled = numeric = 0
        nums = self.numbers(name)
        for r, v in zip(self.rows, nums):
            if r[i].strip():
                filled += 1
                if v is not None:
                    numeric += 1
        if not filled:
            return "empty"
        if numeric == filled:
            return "num"
        return "mixed" if numeric else "text"

    def is_results(self):
        return self.columns[:3] == ["test", "target", "value"]


# ---------------------------------------------------------------------------
# Splitting fields
# ---------------------------------------------------------------------------

def split_results_fields(line):
    """The results format's field rule: tabs, commas or runs of spaces
    separate, except inside quotes, and the quotes are not kept."""
    out, cur, quote, have = [], [], None, False
    for ch in line:
        if quote:
            if ch == quote:
                quote = None
            else:
                cur.append(ch)
            continue
        if ch in "\"'" and (not cur or cur[-1] == "="):
            quote = ch
            have = True
            continue
        if ch in "\t, ":
            if cur or have:
                out.append("".join(cur))
                cur, have = [], False
            continue
        cur.append(ch)
    if cur or have:
        out.append("".join(cur))
    return out


def _is_header(fields):
    return all(f.strip() and to_num(f) is None for f in fields)


def _dedupe(names):
    out, seen = [], {}
    for i, n in enumerate(names):
        n = n.strip() or "col_%d" % (i + 1)
        if n in seen:
            seen[n] += 1
            n = "%s_%d" % (n, seen[n])
        else:
            seen[n] = 1
        out.append(n)
    return out


def letters(n):
    """A, B, ... Z, AA, AB: what a header-less table's columns are called,
    as the floor-plan viewer calls them."""
    out = []
    for i in range(n):
        s, k = "", i
        while True:
            s = chr(ord("A") + k % 26) + s
            k = k // 26 - 1
            if k < 0:
                break
        out.append(s)
    return out


# ---------------------------------------------------------------------------
# Readers
# ---------------------------------------------------------------------------

def _split_comments(lines):
    notes, body = [], []
    started = False
    for ln in lines:
        if not started and (ln.startswith("#") or not ln.strip()):
            if ln.strip():
                notes.append(ln[1:].strip())
            continue
        started = True
        body.append(ln)
    return notes, body


def parse_delimited(text, name="data", source=""):
    """CSV, TSV or a whitespace-aligned table, with or without a header."""
    lines = text.splitlines()
    notes, body = _split_comments(lines)
    body = [ln for ln in body if ln.strip() and not ln.startswith("#")]
    if not body:
        return Table([], [], name, source, notes=notes)
    first = body[0]
    if "\t" in first:
        delim = "\t"
    elif "," in first:
        delim = ","
    else:
        delim = None

    def split(ln, maxfields=None):
        if delim is None:
            if maxfields:
                return ln.split(None, maxfields - 1)
            return ln.split()
        return next(csv.reader([ln], delimiter=delim))

    if delim is not None:
        rows = list(csv.reader(io.StringIO("\n".join(body) + "\n"),
                               delimiter=delim))
    else:
        rows = None
    head = split(first)
    if _is_header(head):
        columns = _dedupe(head)
        start = 1
    else:
        columns = None
        # A header may be commented out so the file stays a table to awk:
        # `# Timestamp<TAB>host<TAB>...`.
        if notes:
            cand = split(lines_last_comment(lines))
            if len(cand) == len(head) and _is_header(cand):
                columns = _dedupe(cand)
                notes = notes[:-1]
        if columns is None:
            columns = letters(len(head))
        start = 0
    width = len(columns)
    data, long_rows = [], 0
    if rows is None:
        source_rows = [split(ln, width) for ln in body[start:]]
    else:
        source_rows = rows[start:]
    for r in source_rows:
        if not r or not any(c.strip() for c in r):
            continue
        r = [c.strip() for c in r]
        if r == columns:
            continue                    # a header repeated mid-stream
        if len(r) > width:
            long_rows += 1
        data.append(r)
    t = Table(columns, data, name, source, notes=notes)
    if long_rows:
        t.notes.append("%d row(s) had more fields than the header; the "
                       "extra fields were dropped" % long_rows)
    return t


def lines_last_comment(lines):
    last = ""
    for ln in lines:
        if ln.startswith("#"):
            last = ln.lstrip("#").strip()
        elif ln.strip():
            break
    return last


def _meta_pairs(fields):
    out = []
    for f in fields:
        k, eq, v = f.partition("=")
        if eq and k:
            out.append((k, v))
    return out


def parse_results(text, name="data", source=""):
    """The viewer's results format: `test target value [key=value ...]`."""
    tests, notes, samples = {}, [], []
    meta_cols = []
    for ln in text.splitlines():
        s = ln.strip()
        if not s:
            continue
        if s.startswith("#"):
            notes.append(s[1:].strip())
            continue
        f = split_results_fields(s)
        if not f:
            continue
        if f[0] == "!test":
            if len(f) >= 2:
                tests[f[1]] = _meta_pairs(f[2:])
            continue
        if len(f) < 3:
            continue
        meta = _meta_pairs(f[3:])
        for k, _ in meta:
            if k not in meta_cols:
                meta_cols.append(k)
        samples.append((f[0], f[1], f[2], dict(meta)))
    return _results_table(samples, meta_cols, tests, notes, name, source)


def _results_table(samples, meta_cols, tests, notes, name, source):
    reserved = {"test", "target", "value"}
    cols = ["test", "target", "value"] + [
        m if m not in reserved else "meta_" + m for m in meta_cols]
    rows = [[t, g, v] + [meta.get(m, "") for m in meta_cols]
            for t, g, v, meta in samples]
    return Table(cols, rows, name, source, tests=tests, notes=notes)


def _flatten(obj, prefix=""):
    out = []
    if isinstance(obj, dict):
        for k, v in obj.items():
            key = "%s.%s" % (prefix, k) if prefix else str(k)
            if isinstance(v, dict):
                out.extend(_flatten(v, key))
            else:
                out.append((key, _cell(v)))
    else:
        out.append((prefix or "value", _cell(obj)))
    return out


def _cell(v):
    if v is None:
        return ""
    if isinstance(v, bool):
        return "true" if v else "false"
    if isinstance(v, float):
        return repr(v) if v != int(v) or abs(v) >= 1e16 else str(int(v))
    if isinstance(v, (list, tuple)):
        if all(not isinstance(x, (dict, list)) for x in v):
            return " ".join(_cell(x) for x in v)
        return json.dumps(v, sort_keys=True)
    return str(v)


def objects_table(objs, name="data", source="", notes=None):
    cols, rows = [], []
    for o in objs:
        flat = _flatten(o)
        for k, _ in flat:
            if k not in cols:
                cols.append(k)
        rows.append(dict(flat))
    return Table(cols, [[r.get(c, "") for c in cols] for r in rows], name,
                 source, notes=notes or [])


def _is_sample(o):
    return isinstance(o, dict) and "test" in o and "target" in o \
        and "value" in o


def _samples_table(objs, tests, notes, name, source):
    meta_cols, samples = [], []
    for o in objs:
        if "!test" in o:
            tests[str(o["!test"])] = [(k, _cell(v)) for k, v in o.items()
                                      if k != "!test"]
            continue
        if not _is_sample(o):
            continue
        meta = dict((str(k), _cell(v)) for k, v in
                    (o.get("meta") or {}).items())
        for k in meta:
            if k not in meta_cols:
                meta_cols.append(k)
        samples.append((_cell(o["test"]), _cell(o["target"]),
                        _cell(o["value"]), meta))
    return _results_table(samples, meta_cols, tests, notes, name, source)


def parse_json(text, name="data", source=""):
    """NDJSON or one JSON document -> one or more tables."""
    lines = [ln for ln in text.splitlines() if ln.strip()]
    notes = [ln.strip()[1:].strip() for ln in lines
             if ln.strip().startswith("#")]
    body = [ln for ln in lines if not ln.strip().startswith("#")]
    doc = None
    try:
        doc = json.loads("\n".join(body))
    except ValueError:
        objs = []
        for n, ln in enumerate(body, 1):
            try:
                objs.append(json.loads(ln))
            except ValueError as exc:
                die("%s: line %d is not JSON: %s" % (source or name, n, exc))
        doc = objs
        ndjson = True
    else:
        ndjson = False
    if ndjson or isinstance(doc, list):
        objs = doc if isinstance(doc, list) else [doc]
        if any(isinstance(o, dict) and ("!test" in o or _is_sample(o))
               for o in objs):
            return [_samples_table(objs, {}, notes, name, source)]
        return [objects_table([o for o in objs if o is not None], name,
                              source, notes)]
    if isinstance(doc, dict):
        if "samples" in doc and isinstance(doc["samples"], list):
            tests = {}
            for k, v in (doc.get("tests") or {}).items():
                tests[k] = [(mk, _cell(mv)) for mk, mv in v.items()]
            return [_samples_table(doc["samples"], tests, notes, name,
                                   source)]
        if "!test" in doc or _is_sample(doc):
            return [_samples_table([doc], {}, notes, name, source)]
        tables = []
        scalars = []
        for k, v in doc.items():
            if isinstance(v, list) and v and all(isinstance(o, dict)
                                                 for o in v):
                tables.append(objects_table(v, "%s" % k, source))
            elif isinstance(v, dict) and k == "meta":
                scalars.extend("%s=%s" % kv for kv in _flatten(v))
            elif not isinstance(v, (list, dict)):
                scalars.append("%s=%s" % (k, _cell(v)))
        if tables:
            for t in tables:
                t.notes = notes + scalars
            return tables
        return [objects_table([doc], name, source, notes)]
    return [Table(["value"], [[_cell(doc)]], name, source, notes=notes)]


def parse_grid(text, name="data", source=""):
    """A `src\\dst` matrix -> one row per (src, dst) cell that has a value.

    Rows send and columns receive in every grid this toolchain writes, so
    the long form keeps that reading: a sick sender is every row with one
    `src`, a sick receiver every row with one `dst`.  Blank cells are
    pairs that were not measured (or not in the matrix) and are left out
    rather than written as zeros.
    """
    notes, body = _split_comments(text.splitlines())
    body = [ln for ln in body if ln.strip()]
    delim = "\t" if "\t" in body[0] else ","
    rows = list(csv.reader(io.StringIO("\n".join(body) + "\n"),
                           delimiter=delim))
    head = [c.strip() for c in rows[0]]
    dsts = head[1:]
    out = []
    for r in rows[1:]:
        if not r:
            continue
        src = r[0].strip()
        for d, cell in zip(dsts, r[1:]):
            cell = cell.strip()
            if cell:
                out.append([src, d, cell])
    return Table(["src", "dst", "value"], out, name, source, notes=notes)


def parse_lines_table(text, name="data", source=""):
    rows = [[str(i), ln] for i, ln in enumerate(text.splitlines(), 1)]
    return Table(["line_no", "line"], rows, name, source)


def detect(text):
    """Which reader a text wants, from what is inside it, never its name."""
    body = []
    for ln in text.splitlines():
        s = ln.strip()
        if s and not s.startswith("#"):
            body.append(s)
        if len(body) >= 6:
            break
    if not body:
        return "empty"
    if body[0][0] in "{[":
        return "json"
    if any(b.startswith("!test") for b in body):
        return "results"
    first = body[0]
    if first.split(",")[0].split("\t")[0].strip().lower() in (
            "src\\dst", "src/dst", "source\\target"):
        return "grid"
    # A results file written --no-meta has no !test line: three fields or
    # more, the third a number or a verdict, every later one key=value.
    f = split_results_fields(first)
    if len(f) >= 3 and (to_num(f[2]) is not None or f[2] in VERDICTS) \
            and all("=" in x for x in f[3:]) and not _is_header(f) \
            and to_num(f[0]) is None and to_num(f[1]) is None:
        return "results"
    if ("," in first or "\t" in first) and len(body) > 1:
        return "table"
    # Words separated by spaces are a table only when they look like one:
    # a header of names, and rows that split the same way under it.
    # `hello world` is a line; `df -P` is a table.
    words = first.split()
    if len(words) > 1 and len(body) > 1 and _is_header(words):
        fits = sum(1 for b in body[1:] if len(b.split()) >= len(words) - 1)
        if fits >= 0.8 * (len(body) - 1):
            return "table"
    return "lines"


READERS = {
    "results": lambda text, name, src: [parse_results(text, name, src)],
    "json": parse_json,
    "grid": lambda text, name, src: [parse_grid(text, name, src)],
    "table": lambda text, name, src: [parse_delimited(text, name, src)],
    "csv": lambda text, name, src: [parse_delimited(text, name, src)],
    "lines": lambda text, name, src: [parse_lines_table(text, name, src)],
}


def parse_text(text, name="data", source="", fmt=None):
    fmt = fmt or detect(text)
    if fmt == "empty":
        return [Table([], [], name, source)]
    if fmt not in READERS:
        die("unknown format %r (want %s)" % (fmt, ", ".join(sorted(READERS))))
    return READERS[fmt](text, name, source)


def load_file(path, name=None, fmt=None):
    import os
    base = os.path.basename(path.rstrip("/")) or path
    stem = name or re.sub(r"\.(csv|tsv|txt|json|ndjson|log|dat)$", "", base)
    return parse_text(read_text(path), stem, path, fmt)


# ---------------------------------------------------------------------------
# Writers
# ---------------------------------------------------------------------------

def to_csv(t, delim=","):
    buf = io.StringIO()
    w = csv.writer(buf, delimiter=delim, lineterminator="\n")
    w.writerow(t.columns)
    for r in t.rows:
        w.writerow(r)
    return buf.getvalue()


def to_tsv(t):
    return to_csv(t, "\t")


def _json_value(t, col, v):
    if v == "":
        return None
    if t.kind(col) == "num":
        n = to_num(v)
        if n is not None and not v.strip().endswith("%"):
            return int(n) if n == int(n) and "." not in v and "e" not in \
                v.lower() else n
    return v


def to_ndjson(t):
    out = []
    if t.is_results():
        for test, meta in sorted(t.tests.items()):
            o = {"!test": test}
            o.update(dict(meta))
            out.append(json.dumps(o, sort_keys=True))
        for r in t.rows:
            o = {"test": r[0], "target": r[1],
                 "value": _json_value(t, "value", r[2])}
            meta = dict((c, v) for c, v in zip(t.columns[3:], r[3:]) if v)
            if meta:
                o["meta"] = meta
            out.append(json.dumps(o, sort_keys=True))
        return "\n".join(out) + ("\n" if out else "")
    for r in t.rows:
        o = {}
        for c, v in zip(t.columns, r):
            jv = _json_value(t, c, v)
            if jv is not None:
                o[c] = jv
        out.append(json.dumps(o, sort_keys=True))
    return "\n".join(out) + ("\n" if out else "")


def to_json(t):
    rows = []
    for r in t.rows:
        rows.append(dict((c, _json_value(t, c, v))
                         for c, v in zip(t.columns, r)))
    return json.dumps(rows, indent=2, sort_keys=True) + "\n"


def _quote_meta(v):
    if not v or not re.search(r"[\s,'\"]", v):
        return v
    q = '"' if '"' not in v else "'"
    if q in v:
        die("cannot write %r into a results file: it holds both kinds of "
            "quote, and the format has no escape" % v)
    return q + v + q


def to_results(t):
    """A results-format table back out as the viewer reads it."""
    out = []
    for n in t.notes:
        out.append("# " + n)
    for test, meta in sorted(t.tests.items()):
        out.append("\t".join(["!test", test] + [
            "%s=%s" % (k, _quote_meta(v)) for k, v in meta]))
    for r in t.rows:
        fields = [r[0], r[1], r[2]] + [
            "%s=%s" % (c[5:] if c.startswith("meta_") else c, _quote_meta(v))
            for c, v in zip(t.columns[3:], r[3:]) if v]
        out.append("\t".join(fields))
    return "\n".join(out) + "\n"


def to_markdown(t):
    def esc(s):
        return s.replace("|", "\\|").replace("\n", " ")
    out = ["| " + " | ".join(esc(c) for c in t.columns) + " |",
           "|" + "|".join("---:" if t.kind(c) == "num" else "---"
                          for c in t.columns) + "|"]
    for r in t.rows:
        out.append("| " + " | ".join(esc(v) for v in r) + " |")
    return "\n".join(out) + "\n"


WRITERS = {"csv": to_csv, "tsv": to_tsv, "ndjson": to_ndjson,
           "json": to_json, "md": to_markdown, "results": to_results}


def format_for(path, default="csv"):
    ext = path.rsplit(".", 1)[-1].lower() if "." in path else ""
    return {"csv": "csv", "tsv": "tsv", "txt": "tsv", "ndjson": "ndjson",
            "jsonl": "ndjson", "json": "json", "md": "md"}.get(ext, default)
