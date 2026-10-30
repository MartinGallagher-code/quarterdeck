# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Martin J. Gallagher
"""qd web: the store in a browser.

A small server, standard library only, on 127.0.0.1 unless told otherwise:
one static page (quarterdeck/web/) and a JSON API over provost's store.  The
page does no arithmetic of its own -- every figure, filter, group, diff,
comparison and outlier comes back from the same functions `qd stats`,
`qd diff`, `qd compare` and the rest print, so the browser and the terminal
cannot disagree about a number.  Campaigns and designs are listed as
`qd campaign status` and `qd doe status` list them.

When datacenter_visualization is installed its viewer is served beside it at
/floor/, with qd's overlays at /floor/files/, so "Floor plan" on any dataset
paints it on the layout without a second server.

Read-only, apart from one thing: a floor-plan overlay is written into qd's
cache (never the store, which provost commits whole), as `qd floor` does.
Requests are answered one at a time, and the store is re-read whenever
provost has filed something since the last one.
"""

import json
import os
import posixpath
import re
import socket
import socketserver
import sys
import threading
import webbrowser
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import parse_qs, quote, unquote, urlparse

from . import VERSION
from . import campaign as camp, compare as comparemod, diff as diffmod, \
    doe as doemod, query, stats, table as tablemod, tools
from .common import PROG, QdError, die, env_float, write_text
from .store import cache_root, describe_entry, shown_attrs, split_ref

STATIC = os.path.join(os.path.dirname(os.path.abspath(__file__)), "web")

TYPES = {".html": "text/html; charset=utf-8",
         ".js": "text/javascript; charset=utf-8",
         ".mjs": "text/javascript; charset=utf-8",
         ".css": "text/css; charset=utf-8", ".json": "application/json",
         ".svg": "image/svg+xml", ".dc": "text/plain; charset=utf-8",
         ".tsv": "text/plain; charset=utf-8",
         ".csv": "text/plain; charset=utf-8",
         ".ndjson": "application/x-ndjson", ".md": "text/plain",
         ".txt": "text/plain; charset=utf-8", ".png": "image/png",
         ".ico": "image/x-icon"}

PAGE_ROWS = 200


class ThreadingServer(socketserver.ThreadingMixIn, HTTPServer):
    """http.server's ThreadingHTTPServer, which 3.6 does not have yet."""
    daemon_threads = True


class Cache(object):
    """The last few tables read, keyed by file and mtime: a page asks for
    the same table once per click, and a 100k-row CSV takes a moment."""

    def __init__(self, size=8):
        self.size = size
        self.items = []
        self.lock = threading.Lock()

    def get(self, key, make):
        with self.lock:
            for k, v in self.items:
                if k == key:
                    return v
        v = make()
        with self.lock:
            self.items = [(key, v)] + [kv for kv in self.items
                                       if kv[0] != key][:self.size - 1]
        return v


class Api(object):
    def __init__(self, book, layout=None):
        self.book = book
        self.layout = layout
        self.cache = Cache()
        self.lock = threading.Lock()

    # -- loading -------------------------------------------------------------

    def entry(self, ref):
        return self.book.resolve(ref or "latest")

    def table(self, ref, tname=None):
        ref, inline = split_ref(ref or "latest")
        e = self.entry(ref)
        tname = tname or inline
        info = None
        for t in e.tables:
            if tname is None or t["name"] == tname:
                info = t
                break
        if info is None:
            die("%s has no table %r" % (e.id, tname))
        return self.cache.get((e.id, info["name"], self.book.stamp()),
                              lambda: e.load(info["name"]))

    def subset(self, q, t=None):
        t = t or self.table(one(q, "e"), one(q, "t"))
        wh = [w for w in q.get("where", []) if w.strip()]
        rows = query.where(t, wh)
        sort = one(q, "sort")
        if sort:
            rows = query.sort_rows(t, rows, sort)
        return t, t.derive(rows=rows)

    # -- endpoints -----------------------------------------------------------

    def entries(self, q):
        out = []
        for e in reversed(self.book.entries()):
            m = e.meta
            out.append({"id": e.id, "name": m.get("name", ""),
                        "kind": m.get("kind", ""),
                        "created": m.get("created", ""),
                        "command": m.get("command", ""),
                        "summary": e.summary(), "hosts": m.get("hosts"),
                        "rc": m.get("rc"), "group": m.get("group", ""),
                        "part": m.get("part", ""),
                        "factors": shown_attrs(m.get("factors")),
                        "tables": [{"name": t["name"],
                                    "rows": t.get("rows", 0),
                                    "from": t.get("from", "")}
                                   for t in e.tables]})
        return {"root": self.book.shown(), "entries": out,
                "version": VERSION, "floor": self.floor_available(),
                "layout": os.path.basename(self.layout) if self.layout
                else None}

    def entry_info(self, q):
        e = self.entry(one(q, "e"))
        prev = self.book.previous_like(e)
        return {"id": e.id, "meta": e.meta, "describe": describe_entry(e),
                "previous": prev.id if prev else None}

    def rows(self, q):
        t, s = self.subset(q)
        off = int(one(q, "offset") or 0)
        lim = int(one(q, "limit") or PAGE_ROWS)
        kinds = dict((c, t.kind(c)) for c in t.columns)
        e = getattr(t, "entry", None)
        return {"name": t.name, "entry": e.id if e else None,
                "columns": t.columns, "kinds": kinds,
                "total": len(t.rows), "matched": len(s.rows),
                "offset": off, "rows": s.rows[off:off + lim],
                "results": t.is_results(),
                "tests": dict((k, dict(v)) for k, v in t.tests.items()),
                "notes": t.notes, "raw": self.has_raw(t)}

    def has_raw(self, t):
        e = getattr(t, "entry", None)
        return bool(e is not None and ("capture" in t.columns or (
            e.meta.get("kind") == "run" and "host" in t.columns)))

    def column(self, q):
        t, s = self.subset(q)
        c = s.colname(one(q, "c"))
        kind = s.kind(c)
        vals = s.values(c)
        filled = [v for v in vals if v.strip()]
        out = {"name": c, "kind": kind, "n": len(filled),
               "blank": len(vals) - len(filled),
               "distinct": len(set(filled)),
               "unit": (dict(t.tests.get(c, [])).get("unit")
                        if t.tests else None) or tools.guess_unit(c)}
        if kind in ("num", "mixed"):
            sm = stats.summary(s.numbers(c))
            out["summary"] = dict((k, v) for k, v in sm.items())
            out["hist"] = [[lo, hi, n] for lo, hi, n in
                           stats.histogram(s.numbers(c))]
            per = None
            if not (s.is_results() and c == "value" and
                    len(set(s.values("test"))) > 1):
                per = stats.default_per(s, c)
                rows, info = stats.outliers(s, c, per)
                out["outliers"] = {
                    "per": per or ("host" if s.has("host") else "row"),
                    "median": info.get("median"), "mad": info.get("mad"),
                    "n": info["n"], "z": info["z"],
                    "rows": [[k, v, rel, None if abs(z) == float("inf")
                              else z, side] for k, v, _, rel, z, side
                             in rows[:50]]}
        fr = stats.freq(s, c)
        out["top"] = [[v, n, labels[:12], len(labels)]
                      for v, n, labels in fr[:30]]
        out["more_values"] = max(0, len(fr) - 30)
        out["over"] = stats.default_over(s)
        return out

    def group(self, q):
        t, s = self.subset(q)
        by = [b.strip() for b in (one(q, "by") or "").split(",")
              if b.strip()]
        if not by:
            die("group by what? pick a column")
        cols = [c.strip() for c in (one(q, "cols") or "").split(",")
                if c.strip()] or None
        aggs = [a.strip() for a in (one(q, "agg") or "").split(",")
                if a.strip()] or None
        g = stats.group_by(s, by, cols, aggs)
        return table_json(g)

    def pivot(self, q):
        t, s = self.subset(q)
        r, c = one(q, "rows"), one(q, "cols")
        v = one(q, "values") or None
        if s.is_results():
            r, c, v = r or "target", c or "test", v or "value"
        if not r or not c:
            die("pivot wants rows and cols")
        p = stats.pivot(s, r, c, v, one(q, "agg") or "auto")
        return table_json(p)

    def trend(self, q):
        t, s = self.subset(q)
        c = s.colname(one(q, "c"))
        by = one(q, "by")
        if by is None:
            if s.has("host") and s.colname("host") != c:
                by = "host"
            elif s.is_results():
                by = "target"
        by = by or None
        # An empty `over` is a choice -- row order -- not a missing one.
        over = q.get("over")
        over = stats.default_over(s) if over is None else (over[0] or None)
        s = tablemod.normalize_units([s], [c])[0]
        vi = s.index(c)
        oi = s.index(over) if over else None
        bi = s.index(by) if by else None
        numeric = oi is None or all(
            tablemod.to_num(r[oi]) is not None for r in s.rows
            if r[oi].strip())
        labels = None
        if not numeric:
            # Stamps that are not numbers (ISO dates, pass labels) are
            # placed by their order; ISO sorts as text in time order.
            labels = stats.natural_sorted(sorted(set(
                r[oi] for r in s.rows if r[oi].strip())))
            pos = dict((v, i) for i, v in enumerate(labels))
        groups, order = {}, []
        for n, r in enumerate(s.rows):
            y = tablemod.to_num(r[vi])
            if oi is None:
                x, xs = float(n), str(n + 1)
            elif numeric:
                x, xs = tablemod.to_num(r[oi]), r[oi]
            else:
                x, xs = (float(pos[r[oi]]) if r[oi] in pos else None), r[oi]
            if x is None:
                continue
            g = r[bi] if bi is not None else "(all)"
            if g not in groups:
                groups[g] = []
                order.append(g)
            groups[g].append([x, xs, y])
        series = []
        for g in stats.natural_sorted(order):
            pts = sorted(groups[g], key=lambda p: p[0])
            series.append({"group": g, "points": pts})
        return {"column": c, "by": by, "over": over, "series": series,
                "numeric_x": numeric and oi is not None,
                "x_labels": labels}

    def diff(self, q):
        b_ref = one(q, "b") or "latest"
        a_ref = one(q, "a")
        b_ref_, b_t = split_ref(b_ref)
        be = self.entry(b_ref_)
        if not a_ref:
            prev = self.book.previous_like(be)
            if prev is None:
                die("nothing earlier ran what %s ran; pick an entry to "
                    "compare against" % be.id)
            a_ref = prev.id + ((":" + b_t) if b_t else "")
        a_ref_, a_t = split_ref(a_ref)
        a = self.table(a_ref_, a_t)
        b = self.table(b_ref_, b_t)
        wh = [w for w in q.get("where", []) if w.strip()]
        if wh:
            a = a.derive(rows=query.where(a, wh))
            b = b.derive(rows=query.where(b, wh))
        key = [k.strip() for k in (one(q, "key") or "").split(",")
               if k.strip()] or None
        cols = [c.strip() for c in (one(q, "cols") or "").split(",")
                if c.strip()] or None
        tol = float(one(q, "tolerance") or 0)
        res = diffmod.diff_tables(a, b, key, cols, tol)
        changed = []
        for k, chs in res.changed[:500]:
            items = []
            for ch in chs:
                d = {"col": ch.col, "a": ch.a, "b": ch.b, "kind": ch.kind,
                     "delta": ch.delta, "pct": ch.pct}
                if "\n" in ch.a or "\n" in ch.b:
                    d["text_diff"] = diffmod.text_diff(ch.a, ch.b, 60)
                items.append(d)
            changed.append({"key": list(k), "changes": items})
        return {"a": a_ref, "b": b_ref, "a_rows": len(a.rows),
                "b_rows": len(b.rows), "key": res.key, "cols": res.cols,
                "ignored": res.ignored, "notes": res.notes,
                "only_a": [list(k) for k in res.only_a],
                "only_b": [list(k) for k in res.only_b],
                "same": res.same, "changed": changed,
                "changed_total": len(res.changed),
                "col_summary": res.col_summary}

    def compare(self, q):
        """N runs side by side: `qd compare`'s engine, its run picking
        and baseline rule included."""
        group = one(q, "group") or None
        last = int(one(q, "last") or 0) or None
        es, base = comparemod.with_baseline(
            self.book, comparemod.pick(self.book, [one(q, "e") or "latest"],
                                       group, last), one(q, "baseline"))
        tables = [self.table(e.id, one(q, "t")) for e in es]
        wh = [w for w in q.get("where", []) if w.strip()]
        if wh:
            tables = [t.derive(rows=query.where(t, wh)) for t in tables]
        key = [k.strip() for k in (one(q, "key") or "").split(",")
               if k.strip()] or None
        drift = float(one(q, "drift") or env_float("DRIFT", 5.0))
        agg = one(q, "agg") or "median"
        res = comparemod.compare(tables, one(q, "c") or None, key, drift,
                                 agg, base)
        runs = []
        for r in res.runs:
            m = r["entry"].meta if r["entry"] is not None else {}
            h = r["hosts"]
            runs.append({"label": r["label"], "id": r["id"],
                         "created": r["created"], "rows": r["rows"],
                         "part": m.get("part", ""),
                         "factors": shown_attrs(m.get("factors")),
                         "command": m.get("command", ""),
                         "hosts_ok": ("%d/%d" % (h.get("ok", 0),
                                                 h.get("total", 0)))
                         if h else "",
                         "stats": r.get("stats"),
                         "change_pct": r.get("delta_pct")})
        only = one(q, "changed") != "0"
        keys, changed = [], 0
        for k, vals, flags in res.keys:
            changed += bool(flags)
            if (flags or not only) and len(keys) < 500:
                keys.append({"key": list(k), "values": vals,
                             "change_pct": comparemod.last_change(res, vals),
                             "flags": flags,
                             "status": res.status.get(k)})
        return {"runs": runs, "baseline": base, "column": res.column,
                "unit": res.unit, "key": res.key, "drift": res.drift,
                "agg": agg, "group": group, "notes": res.notes,
                "numeric": comparemod.common_numeric(tables),
                "columns": [{"column": c, "medians": meds, "change_pct": d}
                            for c, meds, d in
                            comparemod.column_changes(res)],
                "keys": keys, "keys_total": len(res.keys),
                "changed": changed, "only_changed": only}

    def groups(self, q):
        """The campaigns and designs in the store, how far each has got,
        and its parts or points: what `qd campaign status` and `qd doe
        status` print."""
        out = []
        for name, c in sorted(camp.load_all(self.book).items()):
            summ, rows = camp.describe(self.book, c, quiet=True)
            out.append({"kind": "campaign", "name": name,
                        "command": c.command, "split": c.split,
                        "progress": camp.progress(c, summ),
                        "done": summ.get("done"),
                        "total": summ.get("total", str(len(c.parts))),
                        "columns": camp.STATUS_COLUMNS, "rows": rows})
        for name in doemod.names(self.book):
            row, rows, done = doemod.status_rows(self.book, name)
            out.append({"kind": "design", "name": name,
                        "command": row.get("command", ""),
                        "progress": "%d of %d points measured"
                        % (done, len(rows)),
                        "done": str(done), "total": str(len(rows)),
                        "columns": doemod.STATUS_COLUMNS, "rows": rows})
        return {"groups": out}

    def raw(self, q):
        t = self.table(one(q, "e"), one(q, "t"))
        e = getattr(t, "entry", None)
        host = one(q, "host") or None
        cap = one(q, "capture") or None
        if e is None or not (host or cap):
            die("no raw answers for this")
        if cap and not re.match(r"^c\d+$", cap):
            die("no capture %r" % cap)
        out = {}
        for label, text in e.raw(host=host, pas=one(q, "pass"), capture=cap):
            if label == "stderr":
                out["err"] = text[:1 << 20]
            elif "out" not in out:
                out["out"], out["label"] = text[:1 << 20], label
        return out

    def export(self, q):
        t, s = self.subset(q)
        fmt = one(q, "format") or "csv"
        if fmt == "overlay":
            e = getattr(t, "entry", None)
            o = tools.to_overlay(s, e.id if e else None)
            return "%s-%s.tsv" % (e.id if e else "qd", t.name), \
                tablemod.to_results(o)
        if fmt not in tablemod.WRITERS:
            die("unknown format %r" % fmt)
        e = getattr(t, "entry", None)
        ext = {"md": "md", "ndjson": "ndjson", "json": "json",
               "tsv": "tsv"}.get(fmt, "csv")
        return "%s-%s.%s" % (e.id if e else "qd", t.name, ext), \
            tablemod.WRITERS[fmt](s)

    def overlay(self, q):
        t, s = self.subset(q)
        e = getattr(t, "entry", None)
        if e is None:
            die("only a run in the store can be put on the floor plan")
        o = tools.to_overlay(s, e.id)
        name = "overlay.tsv" if t.name == "data" else \
            "overlay-%s.tsv" % re.sub(r"[^\w@-]+", "_", t.name)
        sub = re.sub(r"[^\w@-]+", "_", e.id)
        path = os.path.join(floor_root(), sub, name)
        write_text(path, tablemod.to_results(o))
        url = None
        if self.floor_available():
            url = "/floor/?results=%s" % quote("files/%s/%s" % (sub, name))
            if self.layout:
                url += "&layout=%s" % quote(
                    "files/_layout/" + os.path.basename(self.layout))
            else:
                url += "&build=1"
        return {"file": path, "url": url,
                "samples": len(o.rows),
                "overlays": sorted(set(o.values("test")))}

    # -- the floor-plan viewer ------------------------------------------------

    def floor_root(self):
        try:
            from dcviz.serve import static_root
        except ImportError:
            return None
        try:
            return str(static_root())
        except SystemExit:
            return None

    def floor_available(self):
        return self.floor_root() is not None


def floor_root():
    """qd's overlays, one directory per run: what /floor/files/ serves."""
    return os.path.join(cache_root(), "floor")


def one(q, k):
    v = q.get(k)
    return v[0] if v else None


def table_json(t):
    return {"columns": t.columns, "rows": t.rows,
            "kinds": dict((c, t.kind(c)) for c in t.columns)}


def safe_join(root, rel):
    """http.server's rule: normalise, then drop every . and .. outright, so
    a path can never climb out of the directory it is served from."""
    rest = posixpath.normpath(unquote(rel))
    words = [w for w in rest.split("/") if w and w not in (".", "..")]
    return os.path.join(root, *words)


ROUTES = {"/api/entries": "entries", "/api/entry": "entry_info",
          "/api/rows": "rows", "/api/column": "column",
          "/api/group": "group", "/api/pivot": "pivot",
          "/api/trend": "trend", "/api/diff": "diff", "/api/raw": "raw",
          "/api/overlay": "overlay", "/api/compare": "compare",
          "/api/groups": "groups"}


LOOPBACK = ("127.0.0.1", "localhost", "::1")


class Handler(BaseHTTPRequestHandler):
    api = None
    quiet = False
    loopback = True
    server_version = "quarterdeck/" + VERSION

    def host_ok(self):
        """Bound to this machine, the server answers only requests made to
        a loopback name: a page elsewhere that points its own name at
        127.0.0.1 (DNS rebinding) is turned away."""
        if not self.loopback:
            return True
        host = (self.headers.get("Host") or "").strip().lower()
        if host.startswith("["):
            host = host[1:].split("]", 1)[0]
        else:
            host = host.rsplit(":", 1)[0] if host.count(":") == 1 else host
        return host in LOOPBACK

    def log_message(self, fmt, *args):
        if not self.quiet:
            sys.stderr.write("%s web: %s\n" % (PROG, fmt % args))

    def send(self, code, body, ctype, extra=None):
        if isinstance(body, str):
            body = body.encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-cache")
        self.send_header("X-Content-Type-Options", "nosniff")
        for k, v in (extra or {}).items():
            self.send_header(k, v)
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def send_json(self, code, obj):
        self.send(code, json.dumps(_clean(obj), default=str,
                                   allow_nan=False), "application/json")

    def do_HEAD(self):
        self.do_GET()

    def do_GET(self):
        if not self.host_ok():
            self.send_json(403, {"error": "this server answers requests "
                                 "to 127.0.0.1 or localhost only"})
            return
        url = urlparse(self.path)
        path = url.path
        q = parse_qs(url.query, keep_blank_values=True)
        try:
            if path in ROUTES:
                with self.api.lock:
                    self.api.book.refresh()
                    obj = getattr(self.api, ROUTES[path])(q)
                self.send_json(200, obj)
            elif path == "/api/export":
                with self.api.lock:
                    self.api.book.refresh()
                    name, text = self.api.export(q)
                self.send(200, text, "text/plain; charset=utf-8", {
                    "Content-Disposition": 'attachment; filename="%s"'
                    % re.sub(r'[^\w.@-]', "_", name)})
            elif path == "/floor" or path.startswith("/floor/"):
                self.floor(path[len("/floor"):] or "/")
            elif path.startswith("/api/"):
                self.send_json(404, {"error": "no such endpoint: %s" % path})
            else:
                self.static(STATIC, path)
        except QdError as exc:
            self.send_json(400, {"error": str(exc)})
        except (ValueError, KeyError) as exc:
            self.send_json(400, {"error": "bad request: %s" % exc})
        except (BrokenPipeError, ConnectionResetError):
            pass

    def static(self, root, path):
        if path.endswith("/"):
            path += "index.html"
        f = safe_join(root, path)
        if not os.path.isfile(f):
            self.send(404, "not found\n", "text/plain")
            return
        ext = os.path.splitext(f)[1].lower()
        with open(f, "rb") as fh:
            body = fh.read()
        self.send(200, body, TYPES.get(ext, "application/octet-stream"))

    def floor(self, rest):
        root = self.api.floor_root()
        if rest == "/files" or rest.startswith("/files/"):
            sub = rest[len("/files"):]
            lay = self.api.layout
            if lay and sub.startswith("/_layout/"):
                if os.path.basename(sub) == os.path.basename(lay):
                    self.static(os.path.dirname(os.path.abspath(lay)),
                                "/" + os.path.basename(lay))
                    return
                self.send(404, "not found\n", "text/plain")
                return
            self.static(floor_root(), sub)
            return
        if root is None:
            self.send(404, "the floor-plan viewer is not installed here: "
                      "pip install datacenter-layout-viewer\n", "text/plain")
            return
        if rest == "/":
            rest = "/index.html"
        self.static(root, rest)


def _clean(obj):
    """inf and nan are not JSON; a robust z of infinity goes out as null."""
    if isinstance(obj, float) and (obj != obj or obj in (float("inf"),
                                                         float("-inf"))):
        return None
    if isinstance(obj, dict):
        return dict((k, _clean(v)) for k, v in obj.items())
    if isinstance(obj, (list, tuple)):
        return [_clean(v) for v in obj]
    return obj


def free_port(host, port):
    """The port asked for, or the next one free above it -- dcviz's rule."""
    for candidate in range(port, port + 20):
        s = socket.socket(socket.AF_INET6 if ":" in host else socket.AF_INET)
        try:
            s.bind((host, candidate))
        except OSError:
            continue
        finally:
            s.close()
        return candidate
    die("no free port in %d..%d" % (port, port + 19))


def serve(book, host="127.0.0.1", port=8100, layout=None, open_browser=True,
          quiet=False, ready=None):
    if not os.path.isfile(os.path.join(STATIC, "index.html")):
        die("this install is missing its web page (%s)" % STATIC)
    if layout and not os.path.isfile(layout):
        die("no such layout: %s" % layout)
    api = Api(book, layout)

    class Bound(Handler):
        pass

    Bound.api = api
    Bound.quiet = quiet
    Bound.loopback = host in LOOPBACK
    port = free_port(host, port)
    httpd = ThreadingServer((host, port), Bound)
    shown = "[%s]" % host if ":" in host else host
    url = "http://%s:%d/" % (shown, port)
    sys.stderr.write("%s web: the store in %s\n" % (PROG, book.shown()))
    if api.floor_available():
        sys.stderr.write("%s web: the floor-plan viewer is at %sfloor/\n"
                         % (PROG, url))
    sys.stderr.write("%s web: %s   (Ctrl+C to stop)\n" % (PROG, url))
    if host not in LOOPBACK:
        sys.stderr.write("%s web: listening beyond this machine: anyone who "
                         "can reach %s:%d can read the store\n"
                         % (PROG, host, port))
    if ready is not None:
        ready(url)
    if open_browser:
        threading.Timer(0.3, webbrowser.open, (url,)).start()
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        sys.stderr.write("\n")
    finally:
        httpd.server_close()
    return 0
