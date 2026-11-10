# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Martin J. Gallagher
"""Peer groups: hosts that ought to measure alike, named and kept.

    qd peers define sku --by sku                  the column says, row by row
    qd peers define pods --from pods.tsv          host -> group, from a file
    qd peers define hw --facts kernel,bios        what the hosts are, frozen
                                                  from the latest facts run
    qd peers ls | show NAME [RUN] | rm NAME --yes

A definition is filed in the store as qd's own table, qd.peers, so it is
versioned with the evidence it groups.  It is one of two kinds:

  by      a rule: a row's group is its value of these columns (rack, sku),
          read from whatever table is being looked at.
  map     a list: this host is in that group.  From a file, or from a run
          (--facts COLS, --run RUN): each host's values of COLS there.

A row with a blank in a `by` column, or a host the list does not name, is
in no group: not measured is not a group of its own.  `qd stats --peers`,
`qd outliers --peers` and `qd compare --peers` read a definition, and `qd
baseline set --peers` keeps one with its figures.
"""

import os
import re

from .common import die, read_text
from . import filing, store as storemod, table as tablemod

PEERS = "qd.peers"
COLUMNS = ("peers", "created", "operator", "by", "source", "member", "peer",
           "note")
NAME_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]*$")
NONE = "(none)"


class Peers(object):
    """One definition: a name, and either `by` columns or a `members` map."""

    def __init__(self, name, by=(), members=None, source="", created="",
                 operator="", note=""):
        self.name = name
        self.by = list(by)
        self.members = members          # {host: group} for a map, else None
        self.source = source
        self.created = created
        self.operator = operator
        self.note = note

    def kind(self):
        return "map" if self.members is not None else "by"

    def how(self):
        """What it groups by, as one would say it."""
        if self.members is None:
            return "by " + ",".join(self.by)
        if self.by:
            return "%s in %s" % (",".join(self.by), self.source)
        return "from %s" % self.source

    def groups(self):
        """The groups a map names, in natural order."""
        from .stats import natural_sorted
        return natural_sorted(sorted(set((self.members or {}).values())))

    def assigner(self, table):
        """row -> its group, or None (in no group) for rows of `table`."""
        if self.members is None:
            idx = []
            for b in self.by:
                if not table.has(b):
                    die("peer group %s groups by %s, which %s has no column "
                        "of (columns: %s)" % (self.name, b, table.name,
                                              ", ".join(table.columns)))
                idx.append(table.index(b))

            def by(row):
                vals = [row[i].strip() for i in idx]
                if any(not v for v in vals):
                    return None
                return ",".join(vals)
            return by
        hi = host_index(table)
        if hi is None:
            die("peer group %s names hosts, and %s has no host column to "
                "find them by" % (self.name, table.name))
        members = self.members

        def by_host(row):
            return members.get(row[hi])
        return by_host

    def split(self, table):
        """[(group, the rows in it as a Table)] in natural order, and how
        many rows are in no group."""
        from .stats import natural_sorted
        at = self.assigner(table)
        order, rows, none = [], {}, 0
        for r in table.rows:
            g = at(r)
            if g is None:
                none += 1
                continue
            if g not in rows:
                rows[g] = []
                order.append(g)
            rows[g].append(r)
        return [(g, table.derive(rows=rows[g])) for g in
                natural_sorted(order)], none

    def tagged(self, table, column=None):
        """The table with its group as a first column (the definition's
        name, unless it clashes), rows in no group left out; and how many
        were left out."""
        col = column or self.name
        while table.has(col) and table.colname(col) == col:
            col = "_" + col
        at = self.assigner(table)
        rows, none = [], 0
        for r in table.rows:
            g = at(r)
            if g is None:
                none += 1
                continue
            rows.append([g] + list(r))
        t = tablemod.Table([col] + table.columns, rows, table.name,
                           table.source, table.tests, table.notes)
        if getattr(table, "entry", None) is not None:
            t.entry = table.entry
        return t, col, none


def host_index(table):
    for c in ("host", "ssh_host", "target", "name"):
        if table.has(c) and table.colname(c).lower() == c:
            return table.index(c)
    return None


def check_name(name):
    if not NAME_RE.match(name or "") or ".." in name:
        die("a peer group's name is letters, digits, '.', '_' and '-', "
            "starting with a letter or digit: %r" % name)
    return name


# -- reading --------------------------------------------------------------

def _rows(st):
    return st._read_own(PEERS)


def _latest(rows, name):
    """The rows of the latest filing of NAME: one filing is one capture."""
    mine = [r for r in rows if r.get("peers") == name]
    if not mine:
        return []
    last = mine[-1].get("_capture")
    return [r for r in mine if r.get("_capture") == last]


def names(st):
    """Every peer group in the store, in the order first defined."""
    rows = _rows(st)
    out = []
    for r in rows:
        n = r.get("peers")
        if n and n not in out:
            out.append(n)
    return [n for n in out if not _gone(_latest(rows, n))]


def _gone(rows):
    return any(r.get("source") == "-removed-" for r in rows)


def exists(st, name):
    rows = _latest(_rows(st), name)
    return bool(rows) and not _gone(rows)


def load(st, name):
    rows = _latest(_rows(st), name)
    if not rows or _gone(rows):
        known = names(st)
        die("no peer group %r in the store %s%s" % (
            name, st.shown(), (" (peer groups: %s; qd peers ls)"
                               % ", ".join(known)) if known else
            " -- qd peers define %s --by COLUMN makes one" % name))
    head = rows[0]
    by = [b for b in (head.get("by") or "").split(",") if b]
    members = None
    if any(r.get("member") for r in rows):
        members = {}
        for r in rows:
            if r.get("member"):
                members[r["member"]] = r.get("peer", "")
    return Peers(name, by, members, head.get("source", ""),
                 head.get("created", ""), head.get("operator", ""),
                 head.get("note", ""))


def every(st):
    return [load(st, n) for n in names(st)]


# -- defining -------------------------------------------------------------

def from_file(path):
    """{host: group} from a file with `host` and `group` (or `peer`)
    columns -- TSV, CSV, JSON, as qd reads any table -- or of two plain
    words a line, host then group, with no header."""
    if not os.path.isfile(path):
        die("no such file: %s" % path)
    text = read_text(path)
    t = tablemod.parse_text(text, os.path.basename(path), path)[0]
    hi, gi = host_index(t), None
    for c in ("group", "peer", "peers"):
        if t.has(c) and t.colname(c).lower() == c:
            gi = t.index(c)
            break
    if hi is not None and gi is not None:
        pairs = [(r[hi].strip(), r[gi].strip()) for r in t.rows]
    elif hi is None and gi is None:
        pairs = []
        for ln in text.splitlines():
            if not ln.strip() or ln.lstrip().startswith("#"):
                continue
            w = ln.split("\t") if "\t" in ln else \
                ln.split(",") if "," in ln else ln.split()
            if len(w) < 2:
                die("%s: %r is not a host and a group" % (path, ln))
            pairs.append((w[0].strip(), w[1].strip()))
    else:
        die("%s has a %s column and no %s column: it wants host and group"
            % (path, "host" if hi is not None else "group",
               "group" if hi is not None else "host"))
    out = {}
    for h, g in pairs:
        if not h or not g:
            continue                    # no group given: in none
        if h in out and out[h] != g:
            die("%s puts %s in two groups: %s and %s" % (path, h, out[h], g))
        out[h] = g
    if not out:
        die("%s names no host with a group" % path)
    return out


def from_run(table, cols, name):
    """{host: "v1,v2"} from a run's table (a facts run: one row a host);
    a host with any of COLS blank is in no group, and a host whose rows
    disagree is refused."""
    hi = host_index(table)
    if hi is None:
        die("%s has no host column to make peer group %s from"
            % (table.name, name))
    idx = [table.index(c) for c in cols]
    out, blank = {}, []
    for r in table.rows:
        h = r[hi]
        if not h:
            continue
        vals = [r[i].strip() for i in idx]
        if any(not v for v in vals):
            if h not in blank:
                blank.append(h)
            continue
        g = ",".join(vals)
        if h in out and out[h] != g:
            die("%s says two things of %s on host %s (%s, %s): a peer group "
                "takes one" % (table.name, ",".join(cols), h, out[h], g))
        out[h] = g
    return out, [h for h in blank if h not in out]


def define(st, prov, p, replace=False):
    """File a definition.  Refused when NAME exists, unless replace."""
    check_name(p.name)
    if exists(st, p.name) and not replace:
        die("peer group %s is defined already (%s): --replace files the new "
            "definition over it (the old one stays in the store's history)"
            % (p.name, load(st, p.name).how()))
    from .whoran import operator
    p.created = storemod.now_iso()
    p.operator = operator()
    rows = []
    head = [p.name, p.created, p.operator, ",".join(p.by), p.source]
    if p.members is None:
        rows.append(head + ["", "", p.note])
    else:
        from .stats import natural_sorted
        for h in natural_sorted(sorted(p.members)):
            rows.append(head + [h, p.members[h], p.note])
    _file(prov, rows)
    st.reset()
    got = _latest(_rows(st), p.name)
    if not got or got[0].get("created") != p.created:
        die("provost did not file peer group %s where qd reads it (%s): "
            "`provost ls` there says where it went" % (p.name, PEERS))
    return p


def remove(st, prov, name):
    """A definition is removed by filing a tombstone over it: the store is
    git, and the definitions a baseline was set by stay readable there."""
    p = load(st, name)
    from .whoran import operator
    _file(prov, [[name, storemod.now_iso(), operator(), "", "-removed-",
                  "", "", ""]])
    st.reset()
    if exists(st, name):
        die("provost did not file the removal of %s where qd reads it (%s)"
            % (name, PEERS))
    return p


def _file(prov, rows):
    prov.require("keep the peer group")
    b = filing.Batch()
    try:
        b.add_own(PEERS, filing.own_tsv(COLUMNS, rows, spaces=True))
        notes = filing.notes_of(prov, b, "peer group")
    finally:
        b.cleanup()
    if notes:
        die(notes[0])
