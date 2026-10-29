# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Martin J. Gallagher
"""The store: provost's, read straight from its files.

qd keeps nothing of its own.  What it brings back is filed by provost
(filing.py) and read back here from provost's store, which is plain files:

    datasets/NAME.tsv            '#', 'capture', context columns, 'n', data
    captures/cNNNN/meta.tsv      what a capture was: dataset, row_ids, ...
    captures/cNNNN/output.txt    the input exactly as provost was given it
    captures/cNNNN/context.txt   its '#%' prologue
    provenance.tsv               '#' -> dataset, capture

A qd run is three things in there:

    qd.runs    a row per run: what ran, where, when, how it went
    qd.hosts   a row per host and pass: how it answered (status, rc,
               duration, stderr) -- whether or not it printed anything
    NAME       what the hosts printed: a capture per host, opening with
               '#% run=RUN host=HOST [pass=N] [attr=value ...]'

and this module puts them back together: each host's status beside the
rows provost parsed out of its answer, and a row of blanks for a host that
printed nothing, because a host that did not answer is a finding, not a
gap.  `qd do` and `qd import` file their tables the same way, each capture
opening with '#% run=RUN' and a 'qd-table' line that names the table.
Any other provost dataset reads too: `ds:NAME`, or a bare NAME no run has.

Which store: --store, QD_STORE, or provost's own rule -- PROVOST_WORKSPACE,
the nearest controlled directory above this one, PROVOST_HOME, ~/.provost
-- so `provost ls` lists what qd filed and `provost source cNNNN` shows a
host's answer.
"""

import binascii
import json
import os
import re
import time

from .common import die, env, read_text
from .table import Table

RUNS, HOSTS = "qd.runs", "qd.hosts"

RUN_COLUMNS = ("run", "kind", "name", "command", "created", "finished",
               "duration_s", "hosts", "ok", "failed", "timeout",
               "unreachable", "push_failed", "passes", "every", "rc",
               "captures", "tool", "ran", "version", "cwd", "qd", "notes",
               "group", "part", "factors")
HOST_COLUMNS = ("run", "host", "addr", "pass", "ts", "status", "rc",
                "duration_s", "bytes", "error", "attrs", "stderr")
OUTCOMES = ("ok", "failed", "timeout", "unreachable", "push-failed")

# Free text is escaped in qd's own tables: provost's TSV reader drops
# double quotes, and a tab or a newline would end the cell.
TEXT_COLUMNS = ("command", "ran", "version", "cwd", "notes", "error",
                "stderr", "attrs", "factors")

KEY_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_.-]*$")

# How far before a run's own row its captures are looked for, beyond the
# number it filed: other captures filed at the same moment can sit between.
SCAN_SLACK = 5000

_ESC = {"\\": "\\\\", "\t": "\\t", "\n": "\\n", "\r": "\\r", '"': "\\x22"}
_ESC_RE = re.compile(r'[\\\t\n\r"]')
_UNESC = {"\\\\": "\\", "\\t": "\t", "\\n": "\n", "\\r": "\r",
          "\\x22": '"'}
_UNESC_RE = re.compile(r"\\(?:\\|t|n|r|x22)")


def escape(text):
    return _ESC_RE.sub(lambda m: _ESC[m.group(0)], text or "")


def unescape(text):
    return _UNESC_RE.sub(lambda m: _UNESC[m.group(0)], text or "")


def now_iso(t=None):
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(t or time.time()))


def cnum(cid):
    """c0042 -> 42; anything else -> None."""
    m = re.match(r"^c(\d+)$", cid or "")
    return int(m.group(1)) if m else None


def cname(n):
    return "c%04d" % n


def parse_context(text):
    """The key=value words of a '#%' prologue, as provost reads them for
    --context-columns: the last value of a repeated key wins."""
    out = {}
    for ln in text.splitlines():
        if not ln.startswith("#%"):
            continue
        for w in ln[2:].split():
            k, sep, v = w.partition("=")
            if sep and KEY_RE.match(k):
                out[k] = v
    return out


def table_line(info):
    """The '#%' line that says which of an entry's tables a capture is.
    Hex, so no word of it is a key=value for provost to make a column of."""
    blob = json.dumps(info, sort_keys=True, separators=(",", ":"))
    return "#% qd-table " + binascii.hexlify(blob.encode("utf-8")).decode()


def read_table_line(text):
    for ln in text.splitlines():
        if ln.startswith("#% qd-table "):
            try:
                return json.loads(binascii.unhexlify(
                    ln.split(None, 2)[2].strip()).decode("utf-8"))
            except (ValueError, TypeError, binascii.Error, IndexError):
                return {}
    return {}


def split_attrs(text):
    out = []
    for w in (text or "").split():
        k, sep, v = w.partition("=")
        if sep and k:
            out.append((k, v))
    return out


def row_count(meta):
    m = re.match(r"^(\d+)-(\d+)$", meta.get("row_ids", ""))
    return int(m.group(2)) - int(m.group(1)) + 1 if m else 0


def first_row(meta):
    """The first row number a capture filed, or None: what `provost source
    N` takes in every provost (a capture id only in newer ones)."""
    m = re.match(r"^(\d+)-\d+$", meta.get("row_ids", ""))
    return int(m.group(1)) if m else None


def context_columns(meta):
    """The dataset columns a capture's context became (provost records
    them as context_columns key=column,...)."""
    out = set()
    for pair in (meta.get("context_columns") or "").split(","):
        k, sep, c = pair.partition("=")
        if sep and c:
            out.add(c)
    return out


LONG_KV = (("field", "value"), ("key", "value"), ("name", "value"))


def widen(records):
    """One host's answer filed long -- a `field, value` row per setting,
    which is how provost reads `key: value` lines it judges a list -- as
    the one row it describes: each field a column.  None when the rows
    are not that shape (a real table stays a table)."""
    if not records:
        return None
    cols = [c for c, _ in records[0] if c != "n"]
    if tuple(cols) not in LONG_KV:
        return None
    out, seen = [], set()
    for rec in records:
        d = dict(rec)
        f = d.get(cols[0], "")
        if not f or f in seen:
            return None              # a repeated field: a list, not a record
        seen.add(f)
        out.append((f, d.get("value", "")))
    return out


def read_dataset(path, name):
    """A provost dataset: a header and rows, tab-separated, nothing quoted
    (a '#' header is a header here, not a comment)."""
    lines = read_text(path).split("\n")
    lines = [ln[:-1] if ln.endswith("\r") else ln for ln in lines if ln]
    if not lines:
        return Table([], [], name, path)
    return Table(lines[0].split("\t"), [ln.split("\t") for ln in lines[1:]],
                 name, path)


def default_root():
    for v in (env("STORE"), os.environ.get("PROVOST_WORKSPACE")):
        if v:
            return os.path.abspath(os.path.expanduser(v))
    d = os.getcwd()
    while True:
        if os.path.isfile(os.path.join(d, ".provost", "CONTROLLED")):
            return os.path.join(d, ".provost")
        up = os.path.dirname(d)
        if up == d:
            break
        d = up
    return os.path.abspath(os.path.expanduser(
        os.environ.get("PROVOST_HOME") or "~/.provost"))


def cache_root():
    """Where qd writes what it makes from a store (floor-plan overlays):
    never the store itself, which provost commits whole."""
    v = env("CACHE")
    if v:
        return os.path.abspath(os.path.expanduser(v))
    base = os.environ.get("XDG_CACHE_HOME") or os.path.expanduser("~/.cache")
    return os.path.join(base, "quarterdeck")


class Store(object):
    def __init__(self, root=None):
        self.root = os.path.abspath(os.path.expanduser(root)) if root \
            else default_root()
        self.reset()

    def reset(self):
        self._tables = {}
        self._index = {}
        self._meta = {}
        self._ctx = {}
        self._ctx_text = {}
        self._prov = None
        self._runs = None
        self._hosts = None
        self._stamp = self.stamp()

    def stamp(self):
        """What moves whenever provost files something."""
        out = []
        for p in ("datasets", os.path.join(".git", "index"),
                  os.path.join(".git", "HEAD")):
            try:
                out.append(os.path.getmtime(os.path.join(self.root, p)))
            except OSError:
                out.append(0)
        return tuple(out)

    def refresh(self):
        """Forget what was read, if provost has filed something since."""
        if self.stamp() != self._stamp:
            self.reset()

    def exists(self):
        return os.path.isdir(os.path.join(self.root, "datasets"))

    def path(self, *parts):
        return os.path.join(self.root, *parts)

    def shown(self):
        root, home = self.root, os.path.expanduser("~")
        if home not in ("", "/") and (root + "/").startswith(home + "/"):
            root = "~" + root[len(home):]
        return root

    # -- datasets -----------------------------------------------------------

    def dataset_names(self):
        try:
            names = os.listdir(self.path("datasets"))
        except OSError:
            return []
        return sorted(n[:-4] for n in names if n.endswith(".tsv"))

    def has_dataset(self, name):
        return os.path.isfile(self.path("datasets", name + ".tsv"))

    def dataset(self, name):
        if name not in self._tables:
            if not self.has_dataset(name):
                die("no dataset %r in %s (provost ls lists them)"
                    % (name, self.shown()))
            self._tables[name] = read_dataset(
                self.path("datasets", name + ".tsv"), name)
        return self._tables[name]

    def family(self, name):
        """NAME and the variants provost files another shape into
        (NAME.v2, NAME.v3, ...)."""
        pat = re.compile(r"^%s(\.v\d+)?$" % re.escape(name))
        return [n for n in self.dataset_names() if pat.match(n)]

    def row_index(self, name):
        if name not in self._index:
            t = self.dataset(name)
            idx = {}
            if "#" in t.columns:
                i = t.columns.index("#")
                for r in t.rows:
                    if r[i].isdigit():
                        idx[int(r[i])] = r
            self._index[name] = idx
        return self._index[name]

    def provenance(self):
        """'#' -> capture, for a store older than the capture column."""
        if self._prov is None:
            self._prov = {}
            p = self.path("provenance.tsv")
            if os.path.isfile(p):
                for ln in read_text(p).splitlines()[1:]:
                    f = ln.split("\t")
                    if len(f) >= 3 and f[0].isdigit():
                        self._prov[int(f[0])] = f[2]
        return self._prov

    def row_capture(self, t, row):
        if "capture" in t.columns:
            return row[t.columns.index("capture")]
        if "#" in t.columns and row[t.columns.index("#")].isdigit():
            return self.provenance().get(int(row[t.columns.index("#")]), "")
        return ""

    # -- captures -----------------------------------------------------------

    def meta(self, cid):
        if cid not in self._meta:
            m = {}
            p = self.path("captures", cid, "meta.tsv")
            if os.path.isfile(p):
                for ln in read_text(p).splitlines():
                    k, sep, v = ln.partition("\t")
                    if sep:
                        m[k] = v
            self._meta[cid] = m
        return self._meta[cid]

    def context_text(self, cid):
        if cid not in self._ctx_text:
            p = self.path("captures", cid, "context.txt")
            self._ctx_text[cid] = read_text(p) if os.path.isfile(p) else ""
        return self._ctx_text[cid]

    def context(self, cid):
        if cid not in self._ctx:
            self._ctx[cid] = parse_context(self.context_text(cid))
        return self._ctx[cid]

    def output(self, cid):
        """A capture's input as provost was given it, less its prologue."""
        if not re.match(r"^c\d+$", cid or ""):
            return None
        p = self.path("captures", cid, "output.txt")
        if not os.path.isfile(p):
            return None
        lines = read_text(p).split("\n")
        i = 0
        while i < len(lines) and lines[i].startswith("#%"):
            i += 1
        return "\n".join(lines[i:])

    def capture_rows(self, cid):
        """[(dataset, Table)]: the rows a capture filed, dataset by dataset
        (one, unless provost split the input into several)."""
        m = self.meta(cid)
        rng = re.match(r"^(\d+)-(\d+)$", m.get("row_ids", ""))
        out = []
        for name in [n for n in m.get("dataset", "").split(",") if n]:
            if not self.has_dataset(name):
                continue                    # removed since (provost rm)
            t = self.dataset(name)
            rows = []
            if rng:
                idx = self.row_index(name)
                rows = [idx[n] for n in range(int(rng.group(1)),
                                              int(rng.group(2)) + 1)
                        if n in idx]
            out.append((name, t.derive(rows=rows)))
        return out

    # -- qd's own tables ------------------------------------------------------

    def _read_own(self, name):
        out = []
        for ds in self.family(name):
            t = self.dataset(ds)
            for r in t.rows:
                d = dict(zip(t.columns, r))
                for c in TEXT_COLUMNS:
                    if c in d:
                        d[c] = unescape(d[c])
                d["_rowid"] = int(d["#"]) if d.get("#", "").isdigit() else 0
                d["_capture"] = d.get("capture") or \
                    self.provenance().get(d["_rowid"], "")
                out.append(d)
        out.sort(key=lambda d: d["_rowid"])
        return out

    def run_rows(self):
        if self._runs is None:
            self._runs = [r for r in self._read_own(RUNS) if r.get("run")]
        return self._runs

    def host_rows(self, run_id):
        if self._hosts is None:
            by = {}
            for d in self._read_own(HOSTS):
                by.setdefault(d.get("run", ""), []).append(d)
            self._hosts = by
        return self._hosts.get(run_id, [])

    def run_captures(self, row):
        """The captures filed with '#% run=RUN', oldest first.  qd files a
        run's own row last, so they come just before it: walk back from
        there until there are as many as the run says it filed."""
        want = int(row.get("captures") or 0)
        start = cnum(row.get("_capture"))
        if not want or start is None:
            return []
        found = []
        n, floor = start - 1, max(1, start - 1 - want - SCAN_SLACK)
        while n >= floor and len(found) < want:
            cid = cname(n)
            if self.context(cid).get("run") == row["run"]:
                found.append(cid)
            n -= 1
        found.reverse()
        return found

    # -- entries --------------------------------------------------------------

    def entries(self):
        return [Run(self, r) for r in self.run_rows()]

    def run_ids(self):
        return set(r["run"] for r in self.run_rows())

    def resolve(self, ref):
        """latest, latest~N, a run id or a unique part of one, a run's
        --name (its latest), ds:NAME or a dataset no run is named."""
        if ref.startswith("ds:"):
            return Dataset(self, ref[3:])
        entries = self.entries()
        m = re.match(r"^(latest|last|prev)?(?:~(\d+))?$", ref)
        if m and (m.group(1) or m.group(2)):
            if not entries:
                die("no runs in the store %s yet -- `qd run`, `qd do` or "
                    "`qd import` files one (or point --store at another)"
                    % self.shown())
            back = int(m.group(2) or 0) + (1 if m.group(1) == "prev" else 0)
            if back >= len(entries):
                die("%s goes back further than the %d runs in %s"
                    % (ref, len(entries), self.shown()))
            return entries[-1 - back]
        for e in entries:
            if e.id == ref:
                return e
        named = [e for e in entries if e.name == ref]
        if named:
            return named[-1]
        if self.has_dataset(ref):
            return Dataset(self, ref)
        pre = [e for e in entries if e.id.startswith(ref)]
        if len(pre) == 1:
            return pre[0]
        sub = [e for e in entries if ref in e.id]
        if len(sub) == 1:
            return sub[0]
        if len(pre) > 1 or len(sub) > 1:
            many = pre if len(pre) > 1 else sub
            die("%r matches %d runs: %s" % (
                ref, len(many), ", ".join(e.id for e in many[-6:])))
        die("no run or dataset %r in %s (try `qd log`, or `provost ls`)"
            % (ref, self.shown()))

    def previous_like(self, entry):
        """The last run before this one that ran the same thing -- what
        `qd diff latest` compares against when given one reference."""
        if not isinstance(entry, Run):
            return None
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


def _pick(tables, name, eid):
    if name is None:
        return tables[0]
    hits = [t for t in tables if t["name"] == name] or \
        [t for t in tables if t["name"].startswith(name)]
    if len(hits) != 1:
        die("%s has no single table %r (tables: %s)"
            % (eid, name, ", ".join(t["name"] for t in tables)))
    return hits[0]


class Run(object):
    """A qd run, `qd do` or `qd import`, put back together from the store."""

    def __init__(self, store, row):
        self.store = store
        self.row = row
        self.id = row["run"]
        m = dict((k, v) for k, v in row.items()
                 if k in RUN_COLUMNS and v != "")
        m["id"] = self.id
        m["capture"] = row.get("_capture", "")
        for k in ("duration_s", "every"):
            if k in m:
                try:
                    m[k] = float(m[k])
                except ValueError:
                    pass
        for k in ("passes", "rc", "captures"):
            if k in m and re.match(r"^-?\d+$", m[k]):
                m[k] = int(m[k])
        if m.get("kind") == "run":
            h = {"total": int(row.get("hosts") or 0)}
            for k in OUTCOMES:
                v = row.get(k.replace("-", "_"), "")
                if v.isdigit() and int(v):
                    h[k] = int(v)
            m["hosts"] = h
        else:
            m.pop("hosts", None)
        if m.get("tool") and m.get("version"):
            m["tools"] = {m["tool"]: m.pop("version")}
        notes = m.pop("notes", "")
        if notes:
            m["notes"] = notes.split("\n")
        self.meta = m
        self._caps = None
        self._tables = None

    @property
    def name(self):
        return self.meta.get("name") or ""

    def captures(self):
        if self._caps is None:
            self._caps = self.store.run_captures(self.row)
        return self._caps

    @property
    def tables(self):
        if self._tables is None:
            self._tables = self._list()
        return self._tables

    def table_names(self):
        return [t["name"] for t in self.tables]

    def table_count(self):
        """How many tables, without reading them: what `qd log` shows."""
        if self.meta.get("kind") == "run":
            return 2
        return int(self.meta.get("captures") or 0)

    def _list(self):
        caps = self.captures()
        if self.meta.get("kind") == "run":
            hosts = self.store.host_rows(self.id)
            per = {}
            for cid in caps:
                ctx = self.store.context(cid)
                per[(ctx.get("host", ""), ctx.get("pass") or "1")] = \
                    row_count(self.store.meta(cid))
            rows = sum(max(1, per.get((h.get("host", ""),
                                       h.get("pass") or "1"), 0))
                       for h in hosts)
            names = sorted(set(n for cid in caps for n in
                               self.store.meta(cid).get("dataset", "")
                               .split(",") if n))
            return [{"name": "data", "rows": rows, "from": "ssh",
                     "datasets": names},
                    {"name": "hosts", "rows": len(hosts), "from": "ssh",
                     "datasets": [HOSTS]}]
        out = []
        for cid in caps:
            info = read_table_line(self.store.context_text(cid))
            m = self.store.meta(cid)
            out.append({"name": info.get("name") or cid,
                        "index": info.get("index", len(out)),
                        "rows": row_count(m), "from": info.get("from", ""),
                        "capture": cid, "notes": info.get("notes") or [],
                        "datasets": [n for n in m.get("dataset", "")
                                     .split(",") if n]})
        # in the order qd read them, whatever order provost filed them in
        out.sort(key=lambda t: t["index"])
        return out

    def load(self, name=None):
        tabs = self.tables
        if not tabs:
            die("%s holds no tables: nothing it filed is in the store any "
                "more (provost rm, or a store restored to before it)"
                % self.id)
        info = _pick(tabs, name, self.id)
        if self.meta.get("kind") == "run":
            t = self._data() if info["name"] == "data" else self._hosts()
        else:
            t = self._filed(info)
        t.entry = self
        return t

    def _host_lead(self, hosts):
        """host, addr, its attributes, the run's design factors, pass."""
        attrs = []
        for h in hosts:
            for k, _ in split_attrs(h.get("attrs")):
                if k not in attrs:
                    attrs.append(k)
        factors = split_attrs(self.meta.get("factors"))
        fnames = [k for k, _ in factors if k not in attrs]
        show_addr = any(h.get("addr") for h in hosts)
        multi = int(self.meta.get("passes") or 1) > 1
        cols = ["host"] + (["addr"] if show_addr else []) + attrs + \
            fnames + (["pass", "ts"] if multi else [])
        fvals = dict(factors)

        def cells(h):
            ad = dict(split_attrs(h.get("attrs")))
            return [h.get("host", "")] + ([h.get("addr", "")]
                                          if show_addr else []) + \
                [ad.get(a, "") for a in attrs] + \
                [fvals.get(f, "") for f in fnames] + (
                    [h.get("pass") or "1", h.get("ts", "")] if multi else [])
        return cols, cells

    def _hosts(self):
        hosts = self.store.host_rows(self.id)
        cols, cells = self._host_lead(hosts)
        caps = self._by_host()
        tail = ["status", "rc", "duration_s", "bytes", "error", "stderr",
                "capture"]
        rows = [cells(h) + [h.get(c, "") for c in tail[:-1]] +
                [caps.get((h.get("host", ""), h.get("pass") or "1"), "")]
                for h in hosts]
        return Table(cols + tail, rows, "hosts", self.store.root)

    def _by_host(self):
        out = {}
        for cid in self.captures():
            ctx = self.store.context(cid)
            out[(ctx.get("host", ""), ctx.get("pass") or "1")] = cid
        return out

    def _data(self):
        """Every host's status beside the rows provost parsed out of its
        answer; a host that printed nothing still has its row."""
        hosts = self.store.host_rows(self.id)
        lead, cells = self._host_lead(hosts)
        lead = lead + ["status", "rc", "duration_s", "error", "capture"]
        caps = self._by_host()
        parts, datasets, many = [], [], False
        for h in hosts:
            cid = caps.get((h.get("host", ""), h.get("pass") or "1"), "")
            recs = []
            if cid:
                drop = context_columns(self.store.meta(cid))
                for ds, t in self.store.capture_rows(cid):
                    if ds not in datasets:
                        datasets.append(ds)
                    if ds == "unsorted":
                        recs.append((ds, []))   # held: its text is raw
                        continue
                    keep = [i for i, c in enumerate(t.columns)
                            if c not in ("#", "capture") and c not in drop]
                    pairs = [[(t.columns[i], r[i]) for i in keep]
                             for r in t.rows]
                    wide = widen(pairs)
                    recs.extend((ds, p) for p in
                                ([wide] if wide is not None else pairs))
                many = many or len(recs) > 1
            parts.append((h, cid, recs))
        # Data columns in the order they first appear, less any blank on
        # every row of this run: provost unions a dataset's columns across
        # captures, and another run's shape is not this run's measurement.
        order, filled = [], set()
        for _, _, recs in parts:
            for _, pairs in recs:
                for c, v in pairs:
                    if c == "n" and not many:
                        continue
                    if c not in order:
                        order.append(c)
                    if v.strip():
                        filled.add(c)
        datacols = [c for c in order if c in filled or c == "n"]
        names, taken = {}, set(lead) | {"dataset"}
        for c in datacols:
            m = c
            while m in taken:
                m = "_" + m
            taken.add(m)
            names[c] = m
        show_ds = len(datasets) > 1
        cols = lead + (["dataset"] if show_ds else []) + \
            [names[c] for c in datacols]
        rows = []
        for h, cid, recs in parts:
            base = cells(h) + [h.get("status", ""), h.get("rc", ""),
                               h.get("duration_s", ""), h.get("error", ""),
                               cid]
            for ds, pairs in recs or [("", [])]:
                d = dict(pairs)
                rows.append(base + ([ds] if show_ds else []) +
                            [d.get(c, "") for c in datacols])
        t = Table(cols, rows, "data", self.store.root)
        if len(datasets) > 1:
            t.notes.append("filed by provost into %s" % ", ".join(datasets))
        return t

    def _filed(self, info):
        cid = info.get("capture", "")
        meta = self.store.meta(cid)
        drop = context_columns(meta)
        extra = read_table_line(self.store.context_text(cid))
        cols, rows = [], []
        for ds, t in self.store.capture_rows(cid):
            keep = [c for c in t.columns
                    if c not in ("#", "capture", "n") and c not in drop]
            for c in keep:
                if c not in cols:
                    cols.append(c)
            for r in t.rows:
                d = dict(zip(t.columns, r))
                rows.append(d)
        t = Table(cols, [[d.get(c, "") for c in cols] for d in rows],
                  info["name"], info.get("from") or self.store.root,
                  tests=extra.get("tests") or {},
                  notes=list(extra.get("notes") or []))
        return t

    def summary(self):
        h = self.meta.get("hosts") or {}
        if h:
            return "%d/%d ok" % (h.get("ok", 0), h.get("total", 0))
        return "%d rows" % sum(t.get("rows", 0) for t in self.tables)

    def raw(self, host=None, pas=None, capture=None):
        """[(label, text)]: the answer a row came from, and its stderr."""
        out = []
        if not capture and host is not None:
            capture = self._by_host().get((host, pas or "1"), "")
        if capture:
            text = self.store.output(capture)
            if text is not None:
                out.append((source_label(self.store, capture), text))
        if host is not None and self.meta.get("kind") == "run":
            for h in self.store.host_rows(self.id):
                if h.get("host") == host and \
                        (h.get("pass") or "1") == (pas or "1") and \
                        h.get("stderr"):
                    out.append(("stderr", h["stderr"]))
        return out


class Dataset(object):
    """A provost dataset read whole: everything every capture filed in it,
    run by qd or not (`provost run df -h` makes one)."""

    def __init__(self, store, name):
        if not store.has_dataset(name):
            die("no dataset %r in %s (provost ls lists them)"
                % (name, store.shown()))
        self.store = store
        self.name = name
        self.id = "ds:" + name
        self.meta = {"id": self.id, "kind": "dataset", "name": name,
                     "command": ""}

    @property
    def tables(self):
        t = self.store.dataset(self.name)
        return [{"name": self.name, "rows": len(t.rows), "from": "provost"}]

    def table_names(self):
        return [self.name]

    def table_count(self):
        return 1

    def load(self, name=None):
        if name not in (None, self.name):
            die("%s has one table, %s" % (self.id, self.name))
        t = self.store.dataset(self.name)
        cols = [c for c in t.columns if c != "#"]
        if "capture" in t.columns:
            out = t.derive(columns=cols)
        else:
            out = Table(["capture"] + cols,
                        [[self.store.row_capture(t, r)] +
                         [r[t.columns.index(c)] for c in cols]
                         for r in t.rows], self.name, t.source)
        out.entry = self
        return out

    def summary(self):
        return "%d rows" % len(self.store.dataset(self.name).rows)

    def raw(self, host=None, pas=None, capture=None):
        if capture:
            text = self.store.output(capture)
            if text is not None:
                return [(source_label(self.store, capture), text)]
        return []


def source_label(store, cid):
    n = first_row(store.meta(cid))
    return "raw answer: capture %s%s" % (
        cid, (", provost source %d" % n) if n is not None else "")


def split_ref(ref):
    """`ENTRY:TABLE` -> (ENTRY, TABLE); a bare ref has no table (and
    ds:NAME is a dataset, not a table of an entry called ds)."""
    if ":" in ref and not os.path.exists(ref):
        a, _, b = ref.rpartition(":")
        if a and b and "/" not in b and a != "ds":
            return a, b
    return ref, None


def load_ref(store, ref, fmt=None):
    """A table from a store reference or straight from a file/directory.

    Files and directories are read through the importers, so anything
    `qd import` would take can be looked at without filing it first.
    """
    from . import importers
    ref_, tname = split_ref(ref)
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
    return store.resolve(ref_).load(tname)


def describe_entry(e):
    """What `qd log ENTRY` prints."""
    m = e.meta
    out = ["%s  %s" % (e.id, m.get("name") or "")]
    out.append("  kind      %s" % m.get("kind", "?"))
    if m.get("created"):
        out.append("  created   %s" % m["created"])
    if m.get("command"):
        out.append("  command   %s" % m["command"])
    if m.get("cwd"):
        out.append("  cwd       %s" % m["cwd"])
    h = m.get("hosts")
    if h:
        parts = ["%d hosts" % h.get("total", 0)] + [
            "%d %s" % (h[k], k) for k in OUTCOMES if h.get(k)]
        out.append("  hosts     %s" % ", ".join(parts))
    if (m.get("passes") or 1) > 1:
        out.append("  passes    %d every %ss" % (m["passes"], m.get("every")))
    if m.get("duration_s") is not None:
        out.append("  took      %ss" % m["duration_s"])
    if m.get("rc") is not None:
        out.append("  exit      %s" % m["rc"])
    for k, v in sorted((m.get("tools") or {}).items()):
        out.append("  tool      %s" % v)
    caps = e.captures() if hasattr(e, "captures") else []
    if caps:
        lo, hi = min(caps, key=cnum), max(caps, key=cnum)
        out.append("  filed     %s, %s%s" % (
            "%d capture%s" % (len(caps), "" if len(caps) == 1 else "s"),
            lo, (".." + hi) if len(caps) > 1 else ""))
        n = first_row(e.store.meta(caps[0]))
        if n is not None:
            out.append("  answers   provost source %d  (one per row: qd show "
                       "%s --cols host,capture)" % (n, e.id))
    out.append("  store     %s" % e.store.shown())
    out.append("  tables")
    for t in e.tables:
        out.append("    %-18s %6d rows  %s%s" % (
            t["name"], t.get("rows", 0), ", ".join(t.get("datasets") or []),
            ("  <- %s" % t["from"]) if t.get("from") not in
            (None, "", "ssh", "provost") else ""))
        for n in (t.get("notes") or [])[:6]:
            out.append("      # %s" % n)
    for n in m.get("notes", []):
        out.append("  note      %s" % n)
    return out
