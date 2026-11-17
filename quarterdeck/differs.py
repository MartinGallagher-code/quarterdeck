# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Martin J. Gallagher
"""The odd one out, by value rather than by number (QD-034).

`qd outliers RUN --categorical` reads columns of words -- a BIOS version,
a NIC driver, an offload left on -- as binnacle's `agree` reads answers:
within each group of hosts that ought to be alike (their rack, by
default, or a peer group), what most of them say is the majority, and
every host that says something else is named, with the majority beside
it.  A group with no majority (1 against 1, 2 against 2 against 1) is
split: every value is named, and no host is called the odd one.

A host that measured nothing in a column is not measured there, never a
value of its own: it neither counts towards a majority nor stands out
from one.  Rows a host has several of (one per NIC) are compared like
with like, NIC against the same NIC on the other hosts (`--match`).

Per-host identities -- serials, UUIDs, MAC and IP addresses, host names
-- differ by design, so they are left out unless named with -c.
"""

from .common import die
from .diff import VOLATILE
from .stats import BOOKKEEPING, natural_sorted

# what is meant to differ from host to host, by its column's name (its
# last dotted part: offload.tx-checksum-ip-generic is not an address)
IDENTITY = ("mac", "hwaddr", "address", "addr", "ip", "ipv4", "ipv6",
            "hostname", "fqdn", "machine_id", "boot_id", "asset_tag")
# what moves by the minute, not by configuration
MOVING = ("uptime", "uptime_s")
HOST_COLUMNS = ("host", "ssh_host", "target", "hostname")
MATCH_DEFAULT = ("nic", "dev", "device", "iface", "interface", "port",
                 "index", "disk", "name")
STATUS = ("status", "error", "stderr")

DIFFERS, SPLIT = "differs", "split"
COLUMNS = ["group", "match", "column", "host", "value", "majority",
           "agree", "measured", "verdict"]


class Odd(object):
    def __init__(self):
        self.rows = []          # [group, match, column, host, value,
        #                          majority, agree, measured, verdict]
        self.compared = 0       # (group, match, column) sets with 2+ hosts
        self.columns = []
        self.left_out = []      # columns left out as identities
        self.unmeasured = {}    # column -> hosts that measured nothing
        self.groups = []
        self.none = 0           # rows in no group
        self.match = []


def is_identity(name):
    seg = name.lower().split(".")[-1]
    return "serial" in seg or "uuid" in seg or seg in IDENTITY or \
        seg.endswith(tuple("_" + x for x in IDENTITY))


def host_column(table):
    for c in HOST_COLUMNS:
        if table.has(c):
            return table.colname(c)
    return None


def default_columns(table, skip):
    """Every column worth comparing: not the host, the grouping or the
    matching, not bookkeeping, not what moves by the minute, not a
    per-host identity.  ([columns], [identities left out])."""
    out, ident = [], []
    for c in table.columns:
        lc = c.lower()
        if c in skip or lc in HOST_COLUMNS or lc in STATUS or \
                lc in BOOKKEEPING or lc in VOLATILE or lc in MOVING:
            continue
        if is_identity(c):
            ident.append(c)
            continue
        out.append(c)
    return out, ident


def match_columns(table, asked=None):
    """The columns rows of one host are told apart by (one row per NIC):
    those asked for, else the first of MATCH_DEFAULT the table has when a
    host has several rows; else none."""
    if asked is not None:
        for c in asked:
            table.index(c)
        return [table.colname(c) for c in asked]
    hc = host_column(table)
    if hc is None:
        return []
    hi = table.index(hc)
    hosts = [r[hi] for r in table.rows]
    if len(set(hosts)) == len(hosts):
        return []
    for c in MATCH_DEFAULT:
        if table.has(c) and table.colname(c).lower() != hc.lower():
            return [table.colname(c)]
    return []


def find(table, group_of, columns=None, match=None, group_name="group",
         skip=()):
    """The categorical odd ones out of a table.  group_of(row) gives a
    row's group, or None for none."""
    res = Odd()
    hc = host_column(table)
    if hc is None:
        die("--categorical names the host that differs, and %s has no host "
            "column (host, ssh_host, target)" % table.name)
    hi = table.index(hc)
    res.match = match_columns(table, match)
    mi = [table.index(c) for c in res.match]
    if columns:
        cols = [table.colname(c) for c in columns]
    else:
        cols, res.left_out = default_columns(
            table, set(res.match) | set([group_name]) | set(skip))
    res.columns = cols
    ci = [table.index(c) for c in cols]
    # group -> match -> host -> {column: set of values}
    cells, gorder, horder = {}, [], {}
    for r in table.rows:
        g = group_of(r)
        host = r[hi].strip()
        if not host:
            continue
        if g is None:
            res.none += 1
            continue
        m = tuple(r[i].strip() for i in mi)
        if g not in cells:
            cells[g] = {}
            gorder.append(g)
            horder[g] = []
        if host not in horder[g]:
            horder[g].append(host)
        per = cells[g].setdefault(m, {}).setdefault(host, {})
        for c, i in zip(cols, ci):
            v = r[i].strip()
            if v:
                per.setdefault(c, set()).add(v)
    res.groups = natural_sorted(sorted(gorder))
    for g in res.groups:
        matches = sorted(cells[g])
        for c in cols:
            # a host-wide value (a BIOS version beside every NIC) is
            # compared once a host, not once a NIC
            sets = [(m, cells[g][m]) for m in matches]
            if len(matches) > 1 and _host_wide(c, sets):
                merged = {}
                for _, hosts in sets:
                    for h, per in hosts.items():
                        merged.setdefault(h, set()).update(per.get(c, ()))
                _judge(res, g, (), c, horder[g], merged)
                continue
            for m, hosts in sets:
                _judge(res, g, m, c, [h for h in horder[g] if h in hosts],
                       dict((h, per.get(c, set()))
                            for h, per in hosts.items()))
    return res


def _host_wide(c, sets):
    """Every host gives column c one value on all of its rows."""
    seen = {}
    for _, hosts in sets:
        for h, per in hosts.items():
            vs = per.get(c, set())
            if not vs:
                continue
            if h in seen and seen[h] != vs:
                return False
            if len(vs) > 1:
                return False
            seen[h] = vs
    return True


def _judge(res, g, m, c, hosts, values):
    """One column, in one group (and NIC): the majority and who differs,
    or a split."""
    vals, blank = {}, []
    for h in hosts:
        vs = values.get(h)
        if not vs:
            blank.append(h)
            continue
        vals[h] = " | ".join(sorted(vs))
    if blank:
        res.unmeasured.setdefault(c, []).extend(
            "%s%s" % (h, ("/" + ",".join(m)) if any(m) else "")
            for h in blank)
    if len(vals) < 2:
        return
    res.compared += 1
    count = {}
    for v in vals.values():
        count[v] = count.get(v, 0) + 1
    if len(count) == 1:
        return
    top = sorted(count, key=lambda v: (-count[v], v))
    n = len(vals)
    mtext = ",".join(m)
    if count[top[0]] * 2 > n:
        maj = top[0]
        for h in natural_sorted(sorted(vals)):
            if vals[h] != maj:
                res.rows.append([g, mtext, c, h, vals[h], maj,
                                 str(count[maj]), str(n), DIFFERS])
    else:
        for h in natural_sorted(sorted(vals)):
            res.rows.append([g, mtext, c, h, vals[h], "",
                             str(count[vals[h]]), str(n), SPLIT])
