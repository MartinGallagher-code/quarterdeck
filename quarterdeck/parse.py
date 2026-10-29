# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Martin J. Gallagher
"""Turning what a command printed into columns.

    auto     the first of json, number, kv, csv that fits every host's
             answer, else text -- and the report says which it chose
    text     the whole answer in one `stdout` column
    lines    one row per line: line_no, line
    number   the first number in the answer, as `value`
    kv       `key=value` and `key: value` lines, one column per key;
             `MemTotal: 16384 kB` becomes memtotal_kb = 16384
    csv      a CSV (or TSV) with a header, one row per row, stacked by
             column name across hosts as agree --merge-csv does
    json     an object is a row (nested keys dotted), a list of them rows
    table    a whitespace-aligned table with a header: df -P, ps, ss
    extract  --extract NAME=REGEX: group 1 (or the match) of the first
             match; a regex with (?P<name>...) groups makes those columns

A host whose answer does not fit gets a `parse_error` saying why, never a
silent blank -- and every host's raw answer is kept beside the dataset.
"""

import csv
import io
import json
import re

from .common import die
from .table import _cell, _flatten, slug, to_num

MODES = ("auto", "text", "lines", "number", "kv", "csv", "json", "table",
         "extract")

NUMBER_RE = re.compile(r"[-+]?(?:\d+\.\d*|\.\d+|\d+)(?:[eE][-+]?\d+)?")
# A colon separates only when whitespace follows it, so `MemTotal: 16 kB`
# and `Model name:  Xeon` are pairs while a time (17:05:56), a URL or
# `host:port` is not; keys are short, which `date` output never is.
KV_RE = re.compile(r"^\s*([A-Za-z_][\w .\-/()\[\]]{0,47}?)\s*"
                   r"(?:=|:(?=\s|$))\s*(.*?)\s*$")
UNIT_RE = re.compile(r"^([-+]?(?:\d+\.\d*|\.\d+|\d+)(?:[eE][-+]?\d+)?)\s*"
                     r"([A-Za-z%/]{1,6})$")


def compile_extracts(specs):
    """NAME=REGEX, or a bare REGEX whose named groups name its columns."""
    out = []
    for spec in specs or []:
        name, eq, rx = spec.partition("=")
        if not (eq and re.match(r"^[A-Za-z_][\w.-]*$", name) and rx):
            name, rx = None, spec
        try:
            pat = re.compile(rx, re.M)
        except re.error as exc:
            die("--extract %s: bad regular expression: %s" % (spec, exc))
        if name is None and not pat.groupindex:
            die("--extract wants NAME=REGEX, or a regex with (?P<name>...) "
                "groups; got %r" % spec)
        out.append((slug(name) if name else None, pat))
    return out


def p_text(out):
    return [{"stdout": out.rstrip("\n")}], None


def p_lines(out):
    lines = out.rstrip("\n").split("\n") if out.strip() else []
    if not lines:
        return [{}], None
    return [{"line_no": str(i), "line": ln} for i, ln in
            enumerate(lines, 1)], None


def p_number(out):
    m = NUMBER_RE.search(out)
    if not m:
        return [{}], "no number in the output"
    return [{"value": m.group(0)}], None


def p_kv(out):
    row = {}
    for ln in out.splitlines():
        m = KV_RE.match(ln) if ln.strip() else None
        if not m:
            continue
        key, val = slug(m.group(1)), m.group(2)
        if not key:
            continue
        u = UNIT_RE.match(val)
        if u:
            key, val = "%s_%s" % (key, slug(u.group(2)) or "pct"), u.group(1)
        row[key] = val
    if not row:
        return [{}], "no key=value or key: value lines"
    return [row], None


def _sniff(first):
    return "\t" if "\t" in first else ","


def p_csv(out):
    text = out.strip("\n")
    if not text.strip():
        return [{}], "no output"
    first = text.splitlines()[0]
    rdr = csv.reader(io.StringIO(text + "\n"), delimiter=_sniff(first))
    rows = list(rdr)
    head = [h.strip() for h in rows[0]]
    if len(head) < 2:
        return [{}], "not a CSV with a header"
    out_rows = []
    for r in rows[1:]:
        if not r or [c.strip() for c in r] == head:
            continue
        out_rows.append(dict(zip(head, [c.strip() for c in r])))
    return out_rows or [{}], None


def p_json(out):
    try:
        doc = json.loads(out)
    except ValueError as exc:
        return [{}], "not JSON: %s" % exc
    if isinstance(doc, list):
        rows = []
        for o in doc:
            rows.append(dict(_flatten(o)) if isinstance(o, dict)
                        else {"value": _cell(o)})
        return rows or [{}], None
    if isinstance(doc, dict):
        return [dict(_flatten(doc))], None
    return [{"value": _cell(doc)}], None


def p_table(out):
    lines = [ln for ln in out.splitlines() if ln.strip()]
    if len(lines) < 1:
        return [{}], "no output"
    head = [slug(h) or "col_%d" % (i + 1)
            for i, h in enumerate(lines[0].split())]
    # `Mounted on` is one heading in two words: when every row has fewer
    # fields than the header splits into, fold the header's tail.
    widths = [len(ln.split()) for ln in lines[1:]]
    if widths and max(widths) < len(head):
        n = max(widths)
        head = head[:n - 1] + ["_".join(head[n - 1:])]
    rows = []
    for ln in lines[1:]:
        f = ln.split(None, len(head) - 1)
        rows.append(dict(zip(head, f)))
    return rows or [{}], None


def make_extract(pats):
    def p_extract(out):
        row, missed = {}, []
        for name, pat in pats:
            m = pat.search(out)
            if not m:
                missed.append(name or pat.pattern)
                continue
            named = m.groupdict()
            if named:
                for k, v in named.items():
                    if v is not None:
                        row[slug(k) or k] = v.strip()
            else:
                row[name] = (m.group(1) if pat.groups else m.group(0)).strip()
        return [row], ("no match for %s" % ", ".join(missed)
                       if missed else None)
    return p_extract


PARSERS = {"text": p_text, "lines": p_lines, "number": p_number,
           "kv": p_kv, "csv": p_csv, "json": p_json, "table": p_table}


def _fits(mode, out):
    s = out.strip()
    if mode == "json":
        if not s or s[0] not in "{[":
            return False
        try:
            json.loads(s)
            return True
        except ValueError:
            return False
    if mode == "number":
        return to_num(s) is not None and "\n" not in s
    if mode == "kv":
        lines = [ln for ln in s.splitlines() if ln.strip()]
        return bool(lines) and all(KV_RE.match(ln) for ln in lines)
    if mode == "csv":
        lines = s.splitlines()
        if len(lines) < 2:
            return False
        d = _sniff(lines[0])
        head = next(csv.reader([lines[0]], delimiter=d))
        if len(head) < 2 or any(to_num(h) is not None or not h.strip()
                                for h in head):
            return False
        return all(len(next(csv.reader([ln], delimiter=d))) == len(head)
                   for ln in lines[1:] if ln.strip())
    return False


def choose(outputs):
    """The mode `auto` settles on for this set of answers."""
    filled = [o for o in outputs if o.strip()]
    if not filled:
        return "text"
    for mode in ("json", "number", "kv", "csv"):
        if all(_fits(mode, o) for o in filled):
            return mode
    return "text"


def parse_all(results, mode="auto", extracts=None):
    """Each result's answer as rows of {column: value}.

    -> (mode used, [(result, [row dict], error or None)], [parsed columns])
    """
    if extracts:
        if mode not in ("auto", "extract"):
            die("--extract chooses its own columns; it cannot be combined "
                "with --parse %s" % mode)
        fn = make_extract(compile_extracts(extracts))
        mode = "extract"
    else:
        if mode == "extract":
            die("--parse extract needs at least one --extract NAME=REGEX")
        if mode == "auto":
            mode = choose([r.stdout for r in results if r.outcome == "ok"])
        if mode not in PARSERS:
            die("unknown --parse %r (want %s)" % (mode, ", ".join(MODES)))
        fn = PARSERS[mode]
    parsed, cols = [], []
    for r in results:
        if r.outcome != "ok":
            parsed.append((r, [{}], None))
            continue
        rows, err = fn(r.stdout)
        for row in rows:
            for k in row:
                if k not in cols:
                    cols.append(k)
        parsed.append((r, rows, err))
    return mode, parsed, cols
