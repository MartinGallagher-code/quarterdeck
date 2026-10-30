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
"""

import os
import re

from .common import die
from .table import Table, load_file

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
