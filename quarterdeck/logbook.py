# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Martin J. Gallagher
"""The logbook: one directory per dataset, in a directory you named.

    logbook/
      20261029-142233-uptime/
        entry.json        what ran, where, when, and what came back
        data.csv          the dataset itself; more tables beside it
        raw/<host>.out    every host's answer exactly as it arrived
        raw/<host>.err

Nothing is kept anywhere else: no dotdir, no database, no `latest`
pointer to go stale.  Entries sort by their id, which starts with the
time they were made, so `latest` is simply the last one and `latest~1`
the one before.  A results table (the floor-plan viewer's format) is
stored in that format, so `dcviz serve -d logbook` can open it as is.
"""

import json
import os
import re
import time

from . import VERSION
from .common import die, env, read_text, write_text
from .table import parse_text, slug, to_csv, to_results

DEFAULT_DIR = "logbook"


def now_iso(t=None):
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(t or time.time()))


class Entry(object):
    def __init__(self, path, meta=None):
        self.path = path
        self.id = os.path.basename(path.rstrip("/"))
        self.meta = meta if meta is not None else self._read()

    def _read(self):
        f = os.path.join(self.path, "entry.json")
        if not os.path.isfile(f):
            return {"id": self.id, "tables": [], "broken": True}
        try:
            return json.loads(read_text(f))
        except ValueError:
            return {"id": self.id, "tables": [], "broken": True}

    @property
    def name(self):
        return self.meta.get("name") or ""

    @property
    def tables(self):
        return self.meta.get("tables") or []

    def table_names(self):
        return [t["name"] for t in self.tables]

    def save(self):
        self.meta["id"] = self.id
        body = json.dumps(self.meta, indent=2, sort_keys=True) + "\n"
        tmp = os.path.join(self.path, ".entry.json.tmp")
        write_text(tmp, body)
        os.replace(tmp, os.path.join(self.path, "entry.json"))

    def add_table(self, table, origin=""):
        """Write a table into the entry and list it; names stay unique."""
        name = slug(table.name) or "data"
        taken = set(self.table_names())
        base, k = name, 2
        while name in taken:
            name = "%s_%d" % (base, k)
            k += 1
        if table.is_results():
            fname, fmt, text = name + ".tsv", "results", to_results(table)
        else:
            fname, fmt, text = name + ".csv", "csv", to_csv(table)
        write_text(os.path.join(self.path, fname), text)
        info = {"name": name, "file": fname, "format": fmt,
                "rows": len(table.rows), "columns": list(table.columns)}
        if origin:
            info["from"] = origin
        if table.notes and fmt == "csv":
            info["notes"] = list(table.notes)
        self.meta.setdefault("tables", []).append(info)
        self.save()
        return name

    def load(self, name=None):
        tabs = self.tables
        if not tabs:
            die("entry %s holds no tables%s" % (
                self.id, " (entry.json is missing or unreadable)"
                if self.meta.get("broken") else ""))
        if name is None:
            info = tabs[0]
        else:
            hits = [t for t in tabs if t["name"] == name] or \
                [t for t in tabs if t["name"].startswith(name)]
            if len(hits) != 1:
                die("entry %s has no single table %r (tables: %s)"
                    % (self.id, name, ", ".join(self.table_names())))
            info = hits[0]
        f = os.path.join(self.path, info["file"])
        fmt = "results" if info.get("format") == "results" else "csv"
        t = parse_text(read_text(f), info["name"], f, fmt)[0]
        t.name = info["name"]
        if info.get("notes"):
            t.notes = list(info["notes"]) + t.notes
        t.entry = self
        return t

    def summary(self):
        h = self.meta.get("hosts") or {}
        if h:
            return "%d/%d ok" % (h.get("ok", 0), h.get("total", 0))
        rows = sum(t.get("rows", 0) for t in self.tables)
        return "%d rows" % rows


class Logbook(object):
    def __init__(self, root=None):
        self.root = root or env("LOGBOOK") or DEFAULT_DIR

    def exists(self):
        return os.path.isdir(self.root)

    def entries(self):
        if not self.exists():
            return []
        out = []
        for d in sorted(os.listdir(self.root)):
            p = os.path.join(self.root, d)
            if os.path.isdir(p) and not d.startswith(".") and \
                    os.path.isfile(os.path.join(p, "entry.json")):
                out.append(Entry(p))
        # Ids sort by the second they were made in; two made in the same
        # second are ordered by the moment, which entry.json keeps.
        out.sort(key=lambda e: (e.id[:15], e.meta.get("created_ts") or 0,
                                e.id))
        return out

    def create(self, kind, name, command="", argv=None):
        stamp = time.strftime("%Y%m%d-%H%M%S")
        label = slug(name or "")[:32].strip("_") or kind
        try:
            if not os.path.isdir(self.root):
                os.makedirs(self.root)
        except OSError as exc:
            die("cannot make the logbook %s: %s" % (self.root, exc))
        base = "%s-%s" % (stamp, label)
        eid, k = base, 2
        while os.path.exists(os.path.join(self.root, eid)):
            eid = "%s-%d" % (base, k)
            k += 1
        path = os.path.join(self.root, eid)
        try:
            os.makedirs(path)
        except OSError as exc:
            die("cannot make %s: %s" % (path, exc))
        meta = {"id": eid, "name": name or "", "kind": kind,
                "created": now_iso(), "created_ts": time.time(),
                "qd": VERSION, "cwd": os.getcwd(),
                "command": command, "argv": list(argv or []), "tables": []}
        e = Entry(path, meta)
        e.save()
        return e

    def resolve(self, ref):
        """latest, latest~N, an id or a unique prefix of one, or a name."""
        entries = self.entries()
        if not entries:
            die("no logbook entries in %s -- `qd run`, `qd do` or `qd "
                "import` makes one (or point --logbook at another)"
                % self.root)
        m = re.match(r"^(latest|last|prev)?(?:~(\d+))?$", ref)
        if m and (m.group(1) or m.group(2)):
            back = int(m.group(2) or 0) + (1 if m.group(1) == "prev" else 0)
            if back >= len(entries):
                die("%s goes back further than the %d entries in %s"
                    % (ref, len(entries), self.root))
            return entries[-1 - back]
        for e in entries:
            if e.id == ref:
                return e
        named = [e for e in entries if e.name == ref]
        if named:
            return named[-1]
        pre = [e for e in entries if e.id.startswith(ref)]
        if len(pre) == 1:
            return pre[0]
        sub = [e for e in entries if ref in e.id]
        if len(sub) == 1:
            return sub[0]
        if len(pre) > 1 or len(sub) > 1:
            many = pre if len(pre) > 1 else sub
            die("%r matches %d entries: %s" % (
                ref, len(many), ", ".join(e.id for e in many[-6:])))
        die("no logbook entry %r in %s (try `qd log`)" % (ref, self.root))

    def previous_like(self, entry):
        """The last entry before this one that ran the same thing -- what
        `qd diff latest` compares against when given one reference."""
        entries = self.entries()
        key = (entry.meta.get("kind"), entry.meta.get("command"),
               entry.meta.get("name"))
        ids = [e.id for e in entries]
        earlier = entries[:ids.index(entry.id)] if entry.id in ids else []
        for e in reversed(earlier):
            if (e.meta.get("kind"), e.meta.get("command"),
                    e.meta.get("name")) == key:
                return e
        return None


def split_ref(ref):
    """`ENTRY:TABLE` -> (ENTRY, TABLE); a bare ref has no table."""
    if ":" in ref and not os.path.exists(ref):
        a, _, b = ref.rpartition(":")
        if a and b and "/" not in b:
            return a, b
    return ref, None


def load_ref(book, ref, fmt=None):
    """A table from a logbook reference or straight from a file/directory.

    Files and directories are read through the importers, so anything
    `qd import` would take can be looked at without importing it first.
    """
    from . import importers
    ref_, tname = split_ref(ref)
    if os.path.isfile(os.path.join(ref_, "entry.json")):
        return Entry(os.path.abspath(ref_)).load(tname)
    if os.path.exists(ref_):
        tables = importers.read_path(ref_, fmt)
        if not tables:
            die("nothing readable in %s" % ref_)
        if tname:
            hits = [t for t in tables if t.name == tname]
            if not hits:
                die("%s has no table %r (tables: %s)" % (
                    ref_, tname, ", ".join(t.name for t in tables)))
            return hits[0]
        return tables[0]
    return book.resolve(ref_).load(tname)


def describe_entry(e):
    """What `qd log ENTRY` prints."""
    m = e.meta
    out = ["%s  %s" % (e.id, m.get("name") or "")]
    out.append("  kind      %s" % m.get("kind", "?"))
    out.append("  created   %s" % m.get("created", "?"))
    if m.get("command"):
        out.append("  command   %s" % m["command"])
    if m.get("cwd"):
        out.append("  cwd       %s" % m["cwd"])
    h = m.get("hosts")
    if h:
        parts = ["%d hosts" % h.get("total", 0)] + [
            "%d %s" % (h[k], k) for k in ("ok", "failed", "timeout",
                                          "unreachable", "push-failed")
            if h.get(k)]
        out.append("  hosts     %s" % ", ".join(parts))
    if m.get("parse"):
        out.append("  parsed    as %s" % m["parse"])
    if m.get("passes", 1) and m.get("passes", 1) > 1:
        out.append("  passes    %d every %ss" % (m["passes"], m.get("every")))
    if m.get("duration_s") is not None:
        out.append("  took      %ss" % m["duration_s"])
    if m.get("rc") is not None:
        out.append("  exit      %s" % m["rc"])
    for k, v in sorted((m.get("tools") or {}).items()):
        out.append("  tool      %s" % v)
    out.append("  tables")
    for t in e.tables:
        out.append("    %-18s %6d rows  %s%s" % (
            t["name"], t.get("rows", 0), t["file"],
            ("  <- %s" % t["from"]) if t.get("from") else ""))
        for n in t.get("notes", [])[:6]:
            out.append("      # %s" % n)
    for n in m.get("notes", []):
        out.append("  note      %s" % n)
    return out
