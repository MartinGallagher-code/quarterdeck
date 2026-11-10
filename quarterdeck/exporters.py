# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Martin J. Gallagher
"""Writers for other systems' ingest formats: Splunk HEC events and
Prometheus/OpenMetrics text.

Both write a file and nothing else -- qd makes no network call and holds
no token.  Send the file with curl or let the other side's file reader
pick it up (README, "Sending a run to Splunk or Prometheus").

The rule that holds through every reader holds here too: a blank cell is
not measured, so it is left out of the event or the sample, never written
as 0 or "".
"""

import json
import re

from .common import die
from .importers import epoch_of
from .table import slug, to_base

# The columns that name the host, in the order qd looks for them (the same
# list the floor-plan overlay uses).
TARGET_COLS = ("host", "target", "ssh_host", "name", "src", "source")
PEER_COLS = ("peer", "dst")
# A row's own time, best first.
ROW_TIME_COLS = ("ts", "timestamp", "time")
# Numbers that are qd's bookkeeping, not measurements: no metric of them.
NOT_METRICS = ("rc", "pass", "ts", "timestamp", "time", "#", "n", "capture",
               "addr", "line_no", "bytes")


def to_epoch(text):
    """Seconds since the epoch for a cell: an epoch number (seconds, or
    milliseconds, microseconds or nanoseconds when it is too large to be
    seconds) or an ISO 8601 time, UTC unless it says otherwise.  None when
    it is neither.  The one reader of times: importers.epoch_of, which
    `qd join` reads telemetry with too."""
    return epoch_of(text)


def _first(table, names):
    for c in names:
        if table.has(c):
            return table.colname(c)
    return None


def _json_value(table, col, v):
    from .table import _json_value as jv
    return jv(table, col, v)


def _run_fields(entry):
    """What a run says about itself, for every event of it: its id, name,
    kind and tool."""
    if entry is None:
        return {}
    m = entry.meta
    out = {}
    from .store import shown_id
    out["qd_run"] = shown_id(entry)
    for k in ("name", "kind", "tool"):
        if m.get(k):
            out["qd_" + k] = str(m[k])
    return out


def _setting_columns(table, entry):
    """The columns that say where a row was run (host attributes such as
    rack, a design's factors), which go on each event's indexed fields."""
    if entry is None or not hasattr(entry, "setting_columns"):
        return []
    names = entry.setting_columns()
    return [i for i, c in enumerate(table.columns) if c in names]


def run_time(entry):
    """The run's own time, for rows that carry none: when it finished,
    else when it started."""
    if entry is None:
        return None
    for k in ("finished", "created"):
        t = to_epoch(entry.meta.get(k, ""))
        if t is not None:
            return t
    return None


def to_hec(table, entry=None, sourcetype=None, index=None, source="qd"):
    """Newline-delimited Splunk HEC events, one per row, and how many took
    the run's time because the row had none of its own.

    Each event is {"time", "host", "source", "sourcetype", ["index"],
    "fields", "event"}: `event` is the row with its blank cells left out,
    `fields` the run's id, name and kind and the row's settings (host
    attributes, a design's factors): indexed fields, so a search can
    filter on them without reading the event.  The time is the
    row's own (ts, timestamp, time) where it has one, else the run's, else
    left out, and Splunk stamps it on arrival."""
    hcol = _first(table, TARGET_COLS)
    tcol = _first(table, ROW_TIME_COLS)
    fallback = run_time(entry)
    fields = _run_fields(entry)
    settings = _setting_columns(table, entry)
    st = sourcetype or "qd:" + (slug(table.name) or "data")
    lines = []
    borrowed = untimed = 0
    for r in table.rows:
        ev = {}
        for c, v in zip(table.columns, r):
            jv = _json_value(table, c, v)
            if jv is not None:
                ev[c] = jv
        if not ev:
            continue
        o = {"source": source, "sourcetype": st, "event": ev}
        t = to_epoch(r[table.index(tcol)]) if tcol else None
        if t is None:
            t = fallback
            if t is not None:
                borrowed += 1
            else:
                untimed += 1
        if t is not None:
            o["time"] = round(t, 3) if t != int(t) else int(t)
        if hcol and r[table.index(hcol)].strip():
            o["host"] = r[table.index(hcol)].strip()
        if index:
            o["index"] = index
        f = dict(fields)
        for i in settings:
            if r[i].strip():
                f[table.columns[i]] = r[i].strip()
        if f:
            o["fields"] = f
        lines.append(json.dumps(o, sort_keys=True))
    text = "\n".join(lines) + ("\n" if lines else "")
    return text, borrowed, untimed


# ---------------------------------------------------------------------------
# OpenMetrics
# ---------------------------------------------------------------------------

_NAME_BAD = re.compile(r"[^a-zA-Z0-9_]")


def metric_name(prefix, col, suffix):
    name = _NAME_BAD.sub("_", prefix + (slug(col) or "value"))
    if re.match(r"^[0-9]", name):
        name = "_" + name
    if suffix and not name.endswith("_" + suffix):
        name += "_" + suffix
    return name


def label_name(col):
    name = _NAME_BAD.sub("_", slug(col) or col)
    if not name or re.match(r"^[0-9]", name):
        name = "_" + name
    if name.startswith("__"):
        name = "x" + name    # __ is Prometheus's own
    return name


def _esc(v):
    return v.replace("\\", "\\\\").replace("\n", "\\n").replace('"', '\\"')


def _fmt(v):
    if v == int(v) and abs(v) < 1e15:
        return str(int(v))
    return repr(float(v))


def _column_scale(table, col):
    """(values, suffix, unit said) for a numeric column: sizes in bytes,
    times in seconds, anything else as written with its unit named in the
    help text."""
    cells = table.values(col)
    based = [to_base(c) for c in cells]
    fams = set(f for v, f in based if v is not None)
    if fams == {"size"}:
        return [v for v, _ in based], "bytes", "bytes"
    if fams == {"time"}:
        return [v for v, _ in based], "seconds", "seconds"
    unit = table.unit(col)
    suffix = {"%": "percent"}.get(unit, slug(unit).replace("_", ""))
    return table.numbers(col), suffix, unit


def to_openmetrics(table, entry=None, prefix="qd_", labels=None):
    """Prometheus/OpenMetrics text: one gauge per numeric column, one sample
    per row that measured it, labelled by host, peer, run and the columns
    named in `labels`.  No timestamps: node_exporter's textfile collector
    and the Pushgateway both refuse them.  Free text never becomes a
    label unless asked for, since every distinct value is a new series."""
    hcol = _first(table, TARGET_COLS)
    pcol = _first(table, PEER_COLS)
    if pcol == hcol:
        pcol = None
    lcols = []
    for c in ([hcol] if hcol else []) + ([pcol] if pcol else []):
        lcols.append((label_name("host" if c == hcol else "peer"),
                      table.index(c)))
    for c in labels or []:
        i = table.index(c)
        if i not in [j for _, j in lcols]:
            lcols.append((label_name(table.columns[i]), i))
    if table.has("pass") and len(set(table.values("pass"))) > 1 and \
            table.index("pass") not in [j for _, j in lcols]:
        lcols.append(("pass", table.index("pass")))
    names = [n for n, _ in lcols]
    if len(set(names)) != len(names):
        die("two label columns make the same label name: %s"
            % ", ".join(names))
    run = None
    if entry is not None and "run" not in names:
        from .store import shown_id
        run = shown_id(entry)
    taken = set(j for _, j in lcols)
    out = []
    for i, c in enumerate(table.columns):
        if i in taken or slug(c) in NOT_METRICS or c.lower() in NOT_METRICS:
            continue
        if table.kind(c) != "num":
            continue
        vals, suffix, unit = _column_scale(table, c)
        name = metric_name(prefix, c, suffix)
        seen = {}
        samples = []
        for r, v in zip(table.rows, vals):
            if v is None:
                continue
            lab = [(n, r[j].strip()) for n, j in lcols if r[j].strip()]
            if run:
                lab.append(("run", run))
            key = tuple(lab)
            if key in seen:
                die("%s: two rows give the same series %s{%s}; name the "
                    "column that tells them apart with --labels"
                    % (c, name, ",".join("%s=%s" % p for p in lab)))
            seen[key] = True
            body = ",".join('%s="%s"' % (n, _esc(lv)) for n, lv in lab)
            samples.append("%s%s %s" % (name, "{%s}" % body if body else "",
                                        _fmt(v)))
        if not samples:
            continue
        out.append("# HELP %s %s" % (name, _esc(
            "%s from %s%s" % (c, table.name,
                              " (%s)" % unit if unit else ""))))
        out.append("# TYPE %s gauge" % name)
        out.extend(samples)
    out.append("# EOF")
    return "\n".join(out) + "\n"
