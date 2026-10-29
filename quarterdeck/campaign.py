# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Martin J. Gallagher
"""Campaigns: a system run in parts, its progress kept by binnacle's muster.

    qd campaign new NAME -s hosts.txt --by rack -- COMMAND
    qd campaign run NAME [--parts N]       take the next part(s), run, file
    qd campaign status NAME                done, held, left; how each went
    qd campaign retry NAME [PART...]       put failed (or named) parts back
    qd campaign ls

A campaign is a command and a host list cut into parts (any `qd split`
cut: a rack each, waves of ten, shards).  Which parts are done is muster's
to keep: its pool hands each part out once, under a lease, so two
terminals running the same campaign never take the same rack, a part
whose worker died comes back when its lease runs out, and `muster status`
reads the same progress qd shows.  What each part found is provost's: a
part is a qd run like any other, named after the campaign, with its
campaign and part on every row -- so `qd compare --group NAME` lines the
parts up and `provost show NAME` holds every answer.

The definition (parts, hosts, command, where the pool is) is filed in
provost too, as qd.campaigns, so a campaign started on one machine can be
carried on from another that shares the store and the pool.
"""

import os
import re
import socket
import subprocess
import tempfile

from .common import die, read_text, write_text
from . import filing, store as storemod, tools

CAMPAIGNS = "qd.campaigns"
COLUMNS = ("campaign", "part", "host", "attrs", "command", "split", "pool",
           "created")
NAME_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]*$")


def muster_argv():
    argv = tools.find_tool("muster")
    if not argv:
        die("campaigns keep their progress in binnacle's muster, which is "
            "not installed here: pip install binnacle")
    return argv


def muster(args, pool, check=True):
    """Run muster on a pool: (rc, stdout, stderr)."""
    argv = muster_argv() + list(args) + ["--pool", pool]
    try:
        p = subprocess.Popen(argv, stdout=subprocess.PIPE,
                             stderr=subprocess.PIPE, stdin=subprocess.DEVNULL)
        out, err = p.communicate()
    except OSError as exc:
        die("cannot run muster: %s" % exc)
    out, err = out.decode("utf-8", "replace"), err.decode("utf-8", "replace")
    if check and p.returncode not in (0, 1):
        die("muster %s failed (exit %d): %s" % (
            args[0], p.returncode, err.strip()[-300:] or out.strip()[-300:]))
    return p.returncode, out, err


def ticket_items(path):
    if not os.path.isfile(path):
        return []
    return [ln.strip() for ln in read_text(path).splitlines()
            if ln.strip() and not ln.startswith("#")]


def default_pool(name):
    return os.path.join(storemod.cache_root(), "campaigns", name + ".csv")


class Campaign(object):
    def __init__(self, name, rows):
        self.name = name
        self.parts = []             # [(part, [Host])]
        self.command = rows[0].get("command", "")
        self.split = rows[0].get("split", "")
        self.pool = rows[0].get("pool", "")
        self.created = rows[0].get("created", "")
        from .hosts import parse_host_token
        seen = {}
        for r in rows:
            p = r["part"]
            if p not in seen:
                seen[p] = []
                self.parts.append((p, seen[p]))
            seen[p].append(parse_host_token(
                r["host"], storemod.split_attrs(r.get("attrs"))))

    def hosts(self, part):
        for p, hs in self.parts:
            if p == part:
                return hs
        die("campaign %s has no part %r (parts: %s)" % (
            self.name, part, ", ".join(p for p, _ in self.parts)))


def load_all(st):
    """{name: Campaign}, each from its latest definition."""
    rows = st._read_own(CAMPAIGNS)
    latest = {}
    for r in rows:
        name = r.get("campaign", "")
        cap = storemod.cnum(r.get("_capture")) or 0
        if name and cap >= latest.get(name, (-1,))[0]:
            if cap > latest.get(name, (-1,))[0]:
                latest[name] = (cap, [])
            latest[name][1].append(r)
    return dict((n, Campaign(n, rs)) for n, (_, rs) in latest.items())


def load(st, name):
    c = load_all(st).get(name)
    if c is None:
        die("no campaign %r in the store %s (`qd campaign ls`)"
            % (name, st.shown()))
    return c


def define(st, prov, name, groups, command, split_how, pool):
    if not NAME_RE.match(name):
        die("a campaign name is letters, digits, '.', '_' and '-'; "
            "got %r" % name)
    if not groups or not any(hs for _, hs in groups):
        die("nothing to run: the split left no hosts")
    created = storemod.now_iso()
    rows = []
    for part, hs in groups:
        for h in hs:
            rows.append([name, part, h.token(plain=True),
                         " ".join("%s=%s" % kv for kv in h.attrs), command,
                         split_how, pool, created])
    b = filing.Batch()
    b.add_own(CAMPAIGNS, filing.own_tsv(COLUMNS, rows))
    try:
        filing.notes_of(prov, b, "campaign")
    finally:
        b.cleanup()
    # the pool: one item per part, muster's to hand out
    d = os.path.dirname(pool)
    if d and not os.path.isdir(d):
        os.makedirs(d)
    if os.path.exists(pool):
        die("the pool %s already exists: a campaign of that name was "
            "started before (`qd campaign status %s`, or another --pool)"
            % (pool, name))
    tmp = tempfile.mkdtemp(prefix="qd-campaign-")
    try:
        lst = os.path.join(tmp, "parts.txt")
        write_text(lst, "".join(p + "\n" for p, hs in groups if hs))
        muster(["add", lst], pool)
    finally:
        try:
            os.remove(lst)
            os.rmdir(tmp)
        except OSError:
            pass


def take(c, lease):
    """The next part muster hands out, or None when the pool is empty."""
    tmp = tempfile.mkdtemp(prefix="qd-ticket-")
    ticket = os.path.join(tmp, "ticket")
    muster(["take", "1", "-o", ticket, "--lease", lease, "--quiet",
            "--as", "qd@%s:%d" % (socket.gethostname(), os.getpid())],
           c.pool)
    items = ticket_items(ticket)
    if not items:
        _rm(ticket, tmp)
        return None, None
    return items[0], (ticket, tmp)


def finish(c, held, done=True):
    ticket, tmp = held
    muster(["done" if done else "release", ticket, "--quiet"], c.pool)
    _rm(ticket, tmp)


def _rm(ticket, tmp):
    try:
        if os.path.exists(ticket):
            os.remove(ticket)
        os.rmdir(tmp)
    except OSError:
        pass


def pool_states(c):
    """{part: muster state} and the summary row (total, done, held,
    available, done_pct, stuck)."""
    if not os.path.isfile(c.pool):
        return {}, {}
    _, out, _ = muster(["list", "--state", "any", "--quiet"], c.pool)
    from .table import parse_delimited
    t = parse_delimited(out, "pool")
    states = {}
    if t.has("item") and t.has("state"):
        for r in t.rows:
            states[r[t.index("item")]] = r[t.index("state")]
    _, out, _ = muster(["status", "--csv", "--quiet"], c.pool)
    s = parse_delimited(out, "status")
    summary = dict(zip(s.columns, s.rows[0])) if s.rows else {}
    return states, summary


def part_runs(st, name):
    """{part: [run entries, oldest first]} for a campaign."""
    out = {}
    for e in st.entries():
        if e.meta.get("group") == name and e.meta.get("part"):
            out.setdefault(e.meta["part"], []).append(e)
    return out


def describe(st, c):
    """The status page's lines and its table rows."""
    states, summ = pool_states(c)
    runs = part_runs(st, c.name)
    rows = []
    for part, hs in c.parts:
        rs = runs.get(part, [])
        last = rs[-1] if rs else None
        h = (last.meta.get("hosts") or {}) if last else {}
        ok = ("%d/%d" % (h.get("ok", 0), h.get("total", 0))) if h else ""
        state = states.get(part, "?")
        verdict = ""
        if last is not None:
            verdict = "ok" if h.get("ok", 0) == h.get("total", 0) \
                else "hosts failed"
        rows.append([part, str(len(hs)), state, str(len(rs)),
                     last.id if last else "", ok, verdict,
                     last.meta.get("finished", "") if last else ""])
    return summ, rows


def progress_line(summ, nparts):
    if not summ:
        return "  PROGRESS   the pool is not here (another machine's? --pool)"
    return "  PROGRESS   %s of %s parts done (%s%%), %s held, %s left%s" % (
        summ.get("done", "?"), summ.get("total", nparts),
        summ.get("done_pct", "?").split(".")[0], summ.get("held", "?"),
        summ.get("available", "?"),
        (", %s stuck" % summ["stuck"]) if summ.get("stuck", "0") not in
        ("", "0") else "")


def retry(c, st, parts=None):
    """Put parts back in the pool: the named ones, else every part whose
    last run had a host that did not answer."""
    if not parts:
        runs = part_runs(st, c.name)
        parts = []
        for part, _ in c.parts:
            rs = runs.get(part, [])
            if rs:
                h = rs[-1].meta.get("hosts") or {}
                if h.get("ok", 0) != h.get("total", 0):
                    parts.append(part)
    for p in parts:
        c.hosts(p)
    if not parts:
        return []
    args = ["reset"]
    for p in parts:
        args += ["--item", p]
    muster(args + ["--quiet"], c.pool)
    return parts
