# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Martin J. Gallagher
"""Reading what the toolchain left on disk, by what it is, not its name.

    a file                      whichever format is inside it (see table.py)
    an iperf run directory      iperf_results.csv, cpu_summary.csv and the
                                overlay if there is one, as three tables
    an iperf results/ base      its `latest` run
    a directory of reports      mx's reports/, netmesh's --reports, a
                                folder of monitoring tables: files that
                                share a header stack into one table
    a directory of grids        netmesh's --grid: one row per pair, a
                                column per grid (rtt_p50, loss, mtu)
    a telemetry export          another system's samples (Splunk, a gNMI
                                collector, CloudVision, Prometheus): read
                                a line at a time as (time, host, metric,
                                value), by a column map -- `qd import
                                --telemetry` keeps it, `qd join` lines it
                                up against a run
"""

import calendar
import csv
import datetime
import io
import json
import os
import re
import time

from .common import die, plural, read_text
from .table import Table, _flatten, load_file, to_num

DATA_EXT = (".csv", ".tsv", ".ndjson", ".jsonl", ".json", ".txt", ".dat",
            ".log")
IPERF_FILES = (("iperf_results.csv", "iperf_results"),
               ("cpu_summary.csv", "cpu_summary"),
               ("iperf_overlay.tsv", "iperf_overlay"),
               ("iperf_overlay.ndjson", "iperf_overlay"))


def is_iperf_run(d):
    return any(os.path.isfile(os.path.join(d, f)) for f, _ in
               IPERF_FILES[:2])


def read_iperf_run(d):
    tables = []
    for f, name in IPERF_FILES:
        p = os.path.join(d, f)
        if os.path.isfile(p):
            for t in load_file(p, name):
                tables.append(t)
    mode = os.path.join(d, ".run_mode")
    if os.path.isfile(mode):
        try:
            with open(mode) as fh:
                m = fh.read().strip()
        except OSError:
            m = ""
        if m:
            for t in tables:
                t.notes.append("iperf run %s, mode %s"
                               % (os.path.basename(os.path.realpath(d)), m))
    return tables


def join_grids(members, name, source):
    """Grids side by side: one row per (src, dst), the value of each grid
    in a column named for its file (rtt_p50_grid.csv is rtt_p50).  They
    share the long form's header, but stacked, rtt and loss and mtu would
    be one column; a pair one grid does not have stays blank there."""
    names = []
    for f, _ in members:
        n = re.sub(r"[-_.]?grid$", "", os.path.splitext(f)[0]) or "value"
        names.append(n if n not in names else os.path.splitext(f)[0])
    cells, order = {}, []
    for col, (f, t) in zip(names, members):
        for src, dst, v in t.rows:
            if (src, dst) not in cells:
                cells[(src, dst)] = {}
                order.append((src, dst))
            cells[(src, dst)][col] = v
    rows = [[s, d] + [cells[(s, d)].get(c, "") for c in names]
            for s, d in order]
    notes = []
    for f, t in members:
        notes.extend("%s: %s" % (f, n) for n in t.notes[:3])
    t = Table(["src", "dst"] + names, rows, name, source, notes=notes)
    t.notes.insert(0, "%d grids side by side: %s" % (
        len(members), " ".join(f for f, _ in members)))
    return t


def read_dir(d, fmt=None):
    """Every data file directly in `d`; files sharing a header are one
    table, the way a folder of tables is one dashboard in the viewer."""
    latest = os.path.join(d, "latest")
    if is_iperf_run(d):
        return read_iperf_run(d)
    if os.path.isdir(latest) and is_iperf_run(latest):
        return read_iperf_run(latest)
    files = sorted(f for f in os.listdir(d)
                   if f.lower().endswith(DATA_EXT) and not f.startswith(".")
                   and os.path.isfile(os.path.join(d, f)))
    if not files:
        die("no data files in %s (looked for %s)"
            % (d, " ".join("*" + e for e in DATA_EXT)))
    groups, order = {}, []
    for f in files:
        for t in load_file(os.path.join(d, f), fmt=fmt):
            if not t.columns:
                continue
            key = (tuple(t.columns), t.is_results())
            if key not in groups:
                groups[key] = []
                order.append(key)
            groups[key].append((f, t))
    out = []
    base = os.path.basename(os.path.abspath(d)) or "data"
    for key in order:
        members = groups[key]
        if len(members) == 1:
            out.append(members[0][1])
            continue
        first = members[0][1]
        name = base if len(order) == 1 else "%s_%s" % (base, "grids")
        if all(getattr(t, "grid", False) for _, t in members):
            out.append(join_grids(members, name, d))
            continue
        tag = not (first.has("host") or first.has("target"))
        cols = list(first.columns) + (["source_file"] if tag else [])
        rows = []
        notes, tests = [], {}
        for f, t in members:
            for r in t.rows:
                rows.append(r + [f] if tag else r)
            tests.update(t.tests)
            notes.extend("%s: %s" % (f, n) for n in t.notes[:3])
        names = [t.name for _, t in members]
        stem = os.path.commonprefix(names)
        if any(n != stem for n in names):
            # cut back to a whole word: room-wr01 and room-wr02 are "room"
            stem = re.split(r"[-_.]", stem)[0] if re.search(r"[-_.]", stem) \
                else stem
        stem = stem.strip("-_.") or first.name
        name = base if len(order) == 1 else "%s_%s" % (base, stem)
        t = Table(cols, rows, name, d, tests=tests, notes=notes)
        t.notes.insert(0, "%d files stacked: %s" % (
            len(members), " ".join(f for f, _ in members[:12]) +
            (" ..." if len(members) > 12 else "")))
        out.append(t)
    return out


def read_path(path, fmt=None):
    if os.path.isdir(path):
        return read_dir(path, fmt)
    if not os.path.exists(path):
        die("no such file or directory: %s" % path)
    return load_file(path, fmt=fmt)


# ---------------------------------------------------------------------------
# Telemetry: another system's samples, as (time, host, metric, value)
# ---------------------------------------------------------------------------
#
# Splunk, CloudVision, a gNMI or Prometheus collector: each can write what
# it holds to a file, and that file is all qd reads -- no API client, no
# credentials, no network.  A column map says which column is which part
# of a sample, for an export whose names qd does not already know.

# The four parts of a sample, as `qd import --telemetry` keeps them.
TELEMETRY = ("time", "host", "metric", "value")

# What each part is called in the exports qd knows, best first: Splunk's
# CSV (_time, host), Prometheus samples (timestamp, instance, __name__),
# Telegraf's JSON (timestamp, tags.host -- tags.source from its gnmi
# input -- and a field a metric), a device and path, and qd's own.
ROLE_NAMES = (
    ("time", ("_time", "time", "timestamp", "ts", "@timestamp", "datetime")),
    ("host", ("host", "hostname", "device", "node", "instance", "target",
              "server", "tags.host", "tags.source")),
    ("metric", ("metric", "metric_name", "__name__", "name", "path", "key",
                "field")),
    ("value", ("value", "_value", "val", "reading")),
)

# A wide export (a column per metric) that names no metrics: every column
# is one except these -- Splunk's own fields, which ride along on every
# event it exports (and anything starting `_` or `date_`).
WIDE_SKIP = ("linecount", "punct", "splunk_server", "splunk_server_group",
             "index", "source", "sourcetype", "eventtype", "timestartpos",
             "timeendpos", "tag", "tag::eventtype")

MAP_KEYS = ("time", "host", "metric", "value", "metrics", "time_format",
            "tz")

_TIME_RE = re.compile(
    r"^(\d{4})-(\d\d)-(\d\d)[T ](\d\d):(\d\d)(?::(\d\d)(\.\d+)?)?"
    r"\s*(Z|z|UTC|GMT|[+-]\d\d(?::?\d\d)?)?$")


def epoch_of(text, fmt=None, tz=0.0):
    """Seconds since the epoch, UTC, for a time as an export writes it, or
    None when it is not one: an epoch number in seconds, milliseconds,
    microseconds or nanoseconds (told apart by size), or ISO 8601.  A time
    that names no zone is `tz` seconds east of UTC (0: it is UTC).  `fmt`
    reads it with that strptime format instead."""
    s = (text or "").strip()
    if not s:
        return None
    if fmt:
        try:
            d = datetime.datetime.strptime(s, fmt)
        except ValueError:
            return None
        t = calendar.timegm(d.replace(tzinfo=None).timetuple()) + \
            d.microsecond / 1e6
        off = d.utcoffset()
        return t - (off.total_seconds() if off is not None else tz)
    try:
        v = float(s)
    except ValueError:
        v = None
    if v is not None:
        if v != v or v in (float("inf"), float("-inf")) or v < 0:
            return None
        # 1e11 s is the year 5138: anything that large is a finer unit
        if v > 1e17:
            return v / 1e9
        if v > 1e14:
            return v / 1e6
        if v > 1e11:
            return v / 1e3
        return v
    m = _TIME_RE.match(s)
    if not m:
        return None
    y, mo, d, h, mi = (int(m.group(i)) for i in range(1, 6))
    sec = int(m.group(6) or 0)
    if not (1 <= mo <= 12 and 1 <= d <= 31 and h < 24 and mi < 60
            and sec < 61):
        return None
    try:
        t = calendar.timegm((y, mo, d, h, mi, sec, 0, 0, 0))
    except (ValueError, OverflowError):
        return None
    t += float(m.group(7)) if m.group(7) else 0.0
    zone = m.group(8)
    if zone is None:
        return t - tz
    if zone in ("Z", "z", "UTC", "GMT"):
        return t
    return t - offset_seconds(zone)


def offset_seconds(text):
    """+01:00, +0100, +01, -05:30 -> seconds east of UTC; None otherwise."""
    m = re.match(r"^([+-])(\d\d):?(\d\d)?$", text.strip())
    if not m:
        return None
    s = int(m.group(2)) * 3600 + int(m.group(3) or 0) * 60
    return -s if m.group(1) == "-" else s


def iso_ms(t):
    """An epoch time as UTC ISO 8601, to the millisecond."""
    whole = int(t)
    ms = int(round((t - whole) * 1000))
    if ms >= 1000:
        whole, ms = whole + 1, ms - 1000
    return "%s.%03dZ" % (time.strftime("%Y-%m-%dT%H:%M:%S",
                                       time.gmtime(whole)), ms)


class ColumnMap(object):
    """Which column of an export is which part of a sample (roles: time,
    host, metric, value), or which columns are metrics in an export with
    one per metric; how its times are written, and in which zone when
    they do not say.  Anything it leaves out, qd finds by name."""

    def __init__(self, roles=None, metrics=None, time_format=None, tz=0.0,
                 origin=""):
        self.roles = dict(roles or {})
        self.metrics = metrics
        self.time_format = time_format
        self.tz = tz
        self.origin = origin


def read_map(path):
    """A column map file: one `KEY VALUE` a line (or KEY=VALUE, KEY:
    VALUE), `#` for comments.

        time         _time            the column holding each sample's time
        host         device           the one naming the host
        metric       name             long form: which metric a row is ...
        value        value            ... and its reading
        metrics      temp_c power_w   wide form: a column per metric
                                      (* for every other column)
        time_format  %d/%m/%Y %H:%M:%S   strptime, for times that are
                                      neither epoch numbers nor ISO 8601
        tz           +01:00           the zone of times that name none
                                      (default UTC)
    """
    if not os.path.isfile(path):
        die("no such column map: %s" % path)
    cm = ColumnMap(origin=path)
    seen = set()
    for n, ln in enumerate(read_text(path).splitlines(), 1):
        s = ln.strip()
        if not s or s.startswith("#"):
            continue
        m = re.match(r"^([A-Za-z_]+)\s*[:=]?\s*(.*)$", s)
        key = m.group(1).lower() if m else ""
        val = m.group(2).strip() if m else ""
        if key not in MAP_KEYS:
            die("%s line %d: %r is not a column map key (want %s)"
                % (path, n, key or s, ", ".join(MAP_KEYS)))
        if key in seen:
            die("%s line %d: %s is given twice" % (path, n, key))
        seen.add(key)
        if not val:
            die("%s line %d: %s names nothing" % (path, n, key))
        if key == "metrics":
            cm.metrics = [w for w in re.split(r"[,\s]+", val) if w]
        elif key == "time_format":
            cm.time_format = val
        elif key == "tz":
            if val.upper() in ("UTC", "GMT", "Z"):
                cm.tz = 0.0
            else:
                off = offset_seconds(val)
                if off is None:
                    die("%s line %d: tz wants UTC or an offset such as "
                        "+01:00, not %r (a zone name would need Python "
                        "3.9's zoneinfo, and a fixed offset is what an "
                        "export's times are in anyway)" % (path, n, val))
                cm.tz = float(off)
        else:
            cm.roles[key] = val
    if cm.metrics and ("metric" in cm.roles or "value" in cm.roles):
        die("%s: metrics (a column per metric) and metric/value (a row per "
            "sample) are two shapes of export; give one" % path)
    return cm


def read_aliases(path):
    """{name another system uses: the name the run uses} from a file of
    lines `NAME ALIAS [ALIAS ...]` -- the run's name first, then what
    telemetry calls the same machine (its FQDN, its BMC, its switch
    port's device name).  `#` for comments, commas or spaces between."""
    if not os.path.isfile(path):
        die("no such alias file: %s" % path)
    out = {}
    for n, ln in enumerate(read_text(path).splitlines(), 1):
        words = [w for w in re.split(r"[,\s]+", ln.split("#", 1)[0]) if w]
        if not words:
            continue
        name = words[0]
        for a in words:
            if out.get(a, name) != name:
                die("%s line %d: %s is an alias of %s and of %s"
                    % (path, n, a, out[a], name))
            out[a] = name
    return out


class TelemetrySource(object):
    """An export's columns, and its rows read one at a time (`rows` is an
    iterator over lists of cells): what `samples` reads."""

    def __init__(self, columns, rows, origin, notes=None):
        self.columns = list(columns)
        self.rows = rows
        self.origin = origin
        self.notes = notes or []
        self.bad = 0                 # lines that were not a row at all


def table_source(t, origin=None):
    """A table already read (a stored telemetry dataset) as a source."""
    return TelemetrySource(t.columns, iter(t.rows), origin or t.name)


def telemetry_source(path):
    """A telemetry export on disk, read a line at a time: CSV or TSV (any
    comment lines above the header skipped), NDJSON, or a JSON list of
    objects -- which is read whole, there being no streaming JSON reader
    in the standard library."""
    if os.path.isdir(path):
        die("%s is a directory: a telemetry export is one file" % path)
    try:
        fh = io.open(path, encoding="utf-8-sig", errors="replace",
                     newline="")
    except OSError as exc:
        die("cannot read %s: %s" % (path, exc.strerror or exc))
    first = None
    for ln in fh:
        s = ln.strip()
        if s and not s.startswith("#"):
            first = ln
            break
    if first is None:
        fh.close()
        die("nothing in %s" % path)
    head = first.strip()
    if head.startswith("["):
        try:
            doc = json.loads(first + fh.read())
        except ValueError as exc:
            die("%s is not JSON: %s" % (path, exc))
        finally:
            fh.close()
        objs = [o for o in (doc if isinstance(doc, list) else [doc])
                if isinstance(o, dict)]
        cols = []
        flat = []
        for o in objs:
            f = dict(_flatten(o))
            for k in f:
                if k not in cols:
                    cols.append(k)
            flat.append(f)
        return TelemetrySource(
            cols, iter([[f.get(c, "") for c in cols] for f in flat]), path,
            ["%s is one JSON document, read whole: NDJSON or CSV is read a "
             "line at a time" % os.path.basename(path)])
    if head.startswith("{"):
        fh.close()
        return ndjson_source(path)
    delim = "\t" if "\t" in first else ";" if (
        ";" in first and "," not in first) else ","
    reader = csv.reader(_chain([first], fh), delimiter=delim)
    header = [c.strip() for c in next(reader)]

    def delimited():
        try:
            for r in reader:
                if r and any(c.strip() for c in r):
                    yield r
        finally:
            fh.close()
    return TelemetrySource(header, delimited(), path)


def ndjson_source(path):
    """NDJSON, an object a line, read twice: once for the union of every
    line's keys -- a collector writes different fields on different
    lines, and the first line's alone would drop the rest -- and once for
    the rows.  Neither pass holds more than a line and the key names."""
    def objects(count=False):
        with io.open(path, encoding="utf-8-sig", errors="replace") as fh:
            for ln in fh:
                s = ln.strip()
                if not s or s.startswith("#"):
                    continue
                try:
                    yield dict(_flatten(json.loads(s)))
                except ValueError:
                    if count:
                        src.bad += 1
    cols, seen = [], set()
    for f in objects():
        for k in f:
            if k not in seen:
                seen.add(k)
                cols.append(k)
    src = TelemetrySource(cols, None, path)
    src.rows = ([f.get(c, "") for c in cols] for f in objects(True))
    return src


def _chain(head, rest):
    for x in head:
        yield x
    for x in rest:
        yield x


def _find(columns, name, loose=True):
    """A column's index by name: exact, then any case, then (loose) as a
    slug -- never a prefix, which would read `time` as `timeout`."""
    if name in columns:
        return columns.index(name)
    low = name.lower()
    for i, c in enumerate(columns):
        if c.lower() == low:
            return i
    if loose:
        s = re.sub(r"[^0-9a-z]+", "_", low).strip("_")
        for i, c in enumerate(columns):
            if s and re.sub(r"[^0-9a-z]+", "_", c.lower()).strip("_") == s:
                return i
    return None


class Shape(object):
    """Where each part of a sample is in an export's columns: `time` and
    `host` indexes, then either `long` -- (metric, value) indexes, a row
    per sample -- or `wide`, [(index, metric)], a column per metric."""

    def __init__(self, columns, cmap=None, origin=""):
        cm = cmap or ColumnMap()
        where = origin or "the telemetry"
        found = {}
        for role, names in ROLE_NAMES:
            given = cm.roles.get(role)
            if given:
                i = _find(columns, given)
                if i is None:
                    die("the column map %sgives %s as %r, which %s does not "
                        "have (its columns: %s)" % (
                            (cm.origin + " ") if cm.origin else "", role,
                            given, where, ", ".join(columns[:20]) or "none"))
                found[role] = i
                continue
            for n in names:
                i = _find(columns, n, loose=False)
                if i is not None and i not in found.values():
                    found[role] = i
                    break
        for role in ("time", "host"):
            if role not in found:
                die("which column of %s is each sample's %s? None is called "
                    "%s: give a column map (--map FILE) with a line "
                    "`%s COLUMN` (its columns: %s)" % (
                        where, role, ", ".join(dict(ROLE_NAMES)[role]),
                        role, ", ".join(columns[:20]) or "none"))
        self.columns = list(columns)
        self.time, self.host = found["time"], found["host"]
        self.long, self.wide = None, []
        if cm.metrics:
            rest = self._others(columns, found)
            for name in cm.metrics:
                if name == "*":
                    self.wide.extend((i, columns[i]) for i in rest
                                     if (i, columns[i]) not in self.wide)
                    continue
                i = _find(columns, name)
                if i is None:
                    die("the column map's metrics name %r, which %s does "
                        "not have" % (name, where))
                self.wide.append((i, columns[i]))
        elif "metric" in found and "value" in found:
            self.long = (found["metric"], found["value"])
        elif "value" in found:
            self.wide = [(found["value"], columns[found["value"]])]
        else:
            self.wide = [(i, columns[i])
                         for i in self._others(columns, found)]
        if self.long is None and not self.wide:
            die("%s has a time and a host column but nothing else: no "
                "metric to read" % where)

    @staticmethod
    def _others(columns, found):
        used = set(found.values())
        return [i for i, c in enumerate(columns)
                if i not in used and c and not c.startswith("_")
                and not c.lower().startswith("date_")
                and c.lower() not in WIDE_SKIP]

    def describe(self):
        c = self.columns
        parts = ["time=%s" % c[self.time], "host=%s" % c[self.host]]
        if self.long:
            parts += ["metric=%s" % c[self.long[0]],
                      "value=%s" % c[self.long[1]]]
        else:
            names = [m for _, m in self.wide]
            parts.append("a column per metric (%s%s)" % (
                ", ".join(names[:6]), " ..." if len(names) > 6 else ""))
        return " ".join(parts)


def samples(source, shape, cmap=None, aliases=None, keeper=None,
            tally=None):
    """(time, host, metric, value, cell) for every sample in an export:
    the time in UTC epoch seconds, the host as the alias map names it,
    the value a number and `cell` as written.  A blank or non-numeric
    reading, or a time that cannot be read, is not a sample -- it is
    counted in `tally`, never read as 0.  `keeper` (.host(name) -> a key
    or None, .time(key, t) -> bool) drops what nothing will use before
    its time is even parsed, so an export bigger than memory can be read
    for the few hosts and minutes that matter."""
    cm = cmap or ColumnMap()
    fmt, tz = cm.time_format, cm.tz
    ti, hi = shape.time, shape.host
    tally = tally if tally is not None else {}
    for k in ("rows", "no_host", "bad_time", "skipped", "not_numeric"):
        tally.setdefault(k, 0)
    width = 1 + max([ti, hi] + list(shape.long or []) +
                    [i for i, _ in shape.wide])
    for r in source.rows:
        tally["rows"] += 1
        if len(r) < width:
            r = list(r) + [""] * (width - len(r))
        host = r[hi].strip()
        if not host:
            tally["no_host"] += 1
            continue
        if aliases:
            host = aliases.get(host, host)
        key = None
        if keeper is not None:
            key = keeper.host(host)
            if key is None:
                tally["skipped"] += 1
                continue
        t = epoch_of(r[ti], fmt, tz)
        if t is None:
            tally["bad_time"] += 1
            continue
        if keeper is not None and not keeper.time(key, t):
            tally["skipped"] += 1
            continue
        if shape.long:
            mi, vi = shape.long
            metric, cell = r[mi].strip(), r[vi].strip()
            v = to_num(cell)
            if not metric or v is None:
                tally["not_numeric"] += 1
                continue
            yield t, host, metric, v, cell
            continue
        for i, metric in shape.wide:
            cell = r[i].strip()
            v = to_num(cell)
            if v is None:
                if cell:
                    tally["not_numeric"] += 1
                continue
            yield t, host, metric, v, cell


def tally_notes(tally, source=None):
    """What reading an export left out, in words."""
    out = []
    bits = []
    if tally.get("bad_time"):
        bits.append("%s with a time that could not be read (a column map's "
                    "time_format reads others)"
                    % plural(tally["bad_time"], "row"))
    if tally.get("no_host"):
        bits.append("%s naming no host" % plural(tally["no_host"], "row"))
    if tally.get("not_numeric"):
        bits.append("%s that %s not a number" % (
            plural(tally["not_numeric"], "reading"),
            "was" if tally["not_numeric"] == 1 else "were"))
    if source is not None and source.bad:
        bits.append("%s that %s not JSON" % (
            plural(source.bad, "line"), "was" if source.bad == 1 else "were"))
    if bits:
        out.append("left out, never read as 0: " + "; ".join(bits))
    return out


def telemetry_table(path, cmap=None, aliases=None, name="telemetry"):
    """An export as `qd import --telemetry` keeps it: a row a sample --
    time (UTC, ISO 8601 to the millisecond), host, metric, value as
    written -- whatever shape it arrived in.  Read a line at a time."""
    src = telemetry_source(path)
    shape = Shape(src.columns, cmap, path)
    tally = {}
    rows, hosts, metrics = [], set(), []
    lo = hi = None
    for t, h, m, _, cell in samples(src, shape, cmap, aliases,
                                    tally=tally):
        rows.append([iso_ms(t), h, m, cell])
        hosts.add(h)
        if m not in metrics:
            metrics.append(m)
        lo = t if lo is None or t < lo else lo
        hi = t if hi is None or t > hi else hi
    notes = ["telemetry: %s of %s, %s%s" % (
        plural(len(rows), "sample"), plural(len(hosts), "host"),
        plural(len(metrics), "metric"),
        (", %s to %s" % (iso_ms(lo), iso_ms(hi))) if rows else "")]
    notes.append("read as " + shape.describe() + (
        " (column map %s)" % cmap.origin if cmap and cmap.origin else ""))
    if cmap and cmap.tz:
        notes.append("times that name no zone read as UTC%+g h" % (
            cmap.tz / 3600.0))
    notes.extend(src.notes)
    notes.extend(tally_notes(tally, src))
    return Table(list(TELEMETRY), rows, name, path, notes=notes)
