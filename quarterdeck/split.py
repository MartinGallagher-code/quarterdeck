# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Martin J. Gallagher
"""Splitting one host list into several.

    --by ATTR         a list per value: rack, row, room, role, any attribute
                      (with --layout, the manifest's room/row/rack/slot)
    --into N          N shards in list order, as even as they come
    --deal N          N shards dealt round-robin, so each spans the list
    --size N          waves of N in list order (testing-orchestrator's waves)
    --random N        N groups at random (--seed); --stratify ATTR spreads
                      every value of ATTR across them
    --ab              two halves for an A/B comparison, stratified by rack
                      when there is one
    --canary N        the first N, then the rest
    --pairs           two by two, for tests that need a peer (--ring: each
                      with the next, all the way round)
    --reachable       those that answer and those that do not -- binnacle's
                      reachable decides, qd only sorts
    --answers RUN     by what each host said in a stored run: identical
                      answers together, largest group first, the way agree
                      groups a fleet; a host that did not answer is grouped
                      by how it failed

Every list keeps its hosts' attributes and is a host file any of the suite
reads (`qd run -s`, agree --servers, muster add).  The order inside a list
is the host list's own: a split never reorders hosts, it only chooses.
"""

import hashlib
import os
import random
import re
import subprocess
import tempfile

from .common import die, write_text
from .table import Table, slug

NAME_RE = re.compile(r"[^\w.-]+")


def group_name(prefix, value):
    v = NAME_RE.sub("_", str(value)).strip("_") or "blank"
    return "%s%s" % (prefix, v) if prefix else v


def unique(groups):
    """Each group a name of its own.  rack=a/b and rack=a_b both clean to
    rack-a_b, and one host file would overwrite the other (one campaign
    part, one doe block, take the other's hosts); so would rack-R1 and
    rack-r1 on a file system that ignores case."""
    seen, out = set(), []
    for g, hs in groups:
        name, k = g, 2
        while name.lower() in seen:
            name = "%s-%d" % (g, k)
            k += 1
        seen.add(name.lower())
        out.append((name, hs))
    return out


def by_attr(hosts, attr):
    groups, order = {}, []
    for h in hosts:
        v = dict(h.attrs).get(attr, "")
        if attr == "host":
            v = h.name
        if v not in groups:
            groups[v] = []
            order.append(v)
        groups[v].append(h)
    if order == [""]:
        die("no host has a %r attribute (attributes here: %s)" % (
            attr, ", ".join(sorted(set(k for h in hosts for k, _ in h.attrs)))
            or "none"))
    from .stats import natural_sorted
    return unique([(group_name("%s-" % slug(attr), v), groups[v])
                   for v in natural_sorted(order)])


def into(hosts, n, deal=False):
    if n < 1:
        die("--into wants 1 or more")
    n = min(n, len(hosts))
    out = [[] for _ in range(n)]
    if deal:
        for i, h in enumerate(hosts):
            out[i % n].append(h)
    else:
        base, extra = divmod(len(hosts), n)
        i = 0
        for g in range(n):
            size = base + (1 if g < extra else 0)
            out[g] = hosts[i:i + size]
            i += size
    w = len(str(n))
    return [("shard-%0*d" % (w, g + 1), hs) for g, hs in enumerate(out)]


def waves(hosts, size):
    if size < 1:
        die("--size wants 1 or more")
    chunks = [hosts[i:i + size] for i in range(0, len(hosts), size)]
    w = len(str(len(chunks)))
    return [("wave-%0*d" % (w, g + 1), hs) for g, hs in enumerate(chunks)]


def at_random(hosts, n, seed=None, stratify=None):
    """N groups, sizes within one of each other.  With a stratum, each
    stratum's hosts are shuffled and dealt in turn, so every group gets
    its share of every rack (or whatever ATTR is)."""
    if n < 1:
        die("--random wants 1 or more")
    n = min(n, len(hosts))
    rng = random.Random(seed)
    pos = dict((id(h), i) for i, h in enumerate(hosts))
    if stratify:
        strata, order = {}, []
        for h in hosts:
            v = dict(h.attrs).get(stratify, "")
            if v not in strata:
                strata[v] = []
                order.append(v)
            strata[v].append(h)
        seq = []
        for v in order:
            s = list(strata[v])
            rng.shuffle(s)
            seq.extend(s)
    else:
        seq = list(hosts)
        rng.shuffle(seq)
    out = [[] for _ in range(n)]
    # deal starting at the emptiest group so strata do not pile on group 1
    for h in seq:
        g = min(range(n), key=lambda i: (len(out[i]), i))
        out[g].append(h)
    w = len(str(n))
    return [("group-%0*d" % (w, g + 1), sorted(hs, key=lambda h: pos[id(h)]))
            for g, hs in enumerate(out)]


def ab(hosts, seed=None, stratify=None):
    if stratify is None and any(dict(h.attrs).get("rack") for h in hosts):
        stratify = "rack"
    groups = at_random(hosts, 2, seed, stratify)
    return [("a", groups[0][1]), ("b", groups[1][1] if len(groups) > 1
                                  else [])]


def canary(hosts, n):
    if n < 1:
        die("--canary wants 1 or more")
    return [("canary", hosts[:n]), ("rest", hosts[n:])]


def pairs(hosts, ring=False):
    if len(hosts) < 2:
        die("pairs need two hosts or more")
    out = []
    if ring:
        for i, h in enumerate(hosts):
            out.append([h, hosts[(i + 1) % len(hosts)]])
    else:
        for i in range(0, len(hosts) - 1, 2):
            out.append([hosts[i], hosts[i + 1]])
        if len(hosts) % 2:
            # the odd one out pairs with the first, rather than with nobody
            out.append([hosts[-1], hosts[0]])
    w = len(str(len(out)))
    return [("pair-%0*d" % (w, g + 1), hs) for g, hs in enumerate(out)]


def reachable(hosts, argv):
    """binnacle's reachable decides who answers; qd sorts by its verdict."""
    if not argv:
        die("--reachable asks binnacle's reachable, which is not installed "
            "here: pip install binnacle")
    tmp = tempfile.mkdtemp(prefix="qd-split-")
    lst = os.path.join(tmp, "hosts.txt")
    write_text(lst, "".join(h.token(plain=True) + "\n" for h in hosts))
    try:
        p = subprocess.Popen(argv + [lst, "--csv"], stdout=subprocess.PIPE,
                             stderr=subprocess.PIPE, stdin=subprocess.DEVNULL)
        out, err = p.communicate()
    except OSError as exc:
        die("cannot run reachable: %s" % exc)
    finally:
        try:
            os.remove(lst)
            os.rmdir(tmp)
        except OSError:
            pass
    from .table import parse_delimited
    t = parse_delimited(out.decode("utf-8", "replace"), "reachable")
    if not t.has("host") or not t.has("usable"):
        die("reachable said nothing qd can read (exit %d): %s" % (
            p.returncode, err.decode("utf-8", "replace").strip()[-300:]))
    verdict = {}
    for r in t.rows:
        verdict[r[t.index("host")]] = r
    up, down = [], []
    for h in hosts:
        r = verdict.get(h.name)
        usable = r is not None and r[t.index("usable")].lower() in (
            "yes", "true", "1", "ok")
        (up if usable else down).append(h)
    return [("up", up), ("down", down)]


def by_answers(hosts, entry):
    """Hosts grouped by what they said in a run: the same answer, byte for
    byte once trailing space is gone, is one group (agree's model, read
    from the store rather than asked again)."""
    t = entry.load("hosts")
    names = dict((h.name, h) for h in hosts)
    # a run of several passes has a row per host per pass: a host's answer
    # is its last one, and each host goes in one list once
    last, seen = {}, []
    for r in t.rows:
        host = r[t.index("host")]
        if host in names:
            if host not in last:
                seen.append(host)
            last[host] = r
    groups, order = {}, []
    for host in seen:
        r = last[host]
        status = r[t.index("status")]
        cap = r[t.index("capture")] if t.has("capture") else ""
        if status != "ok":
            key = ("failed", status)
        else:
            text = entry.store.output(cap) if cap else ""
            norm = "\n".join(ln.rstrip() for ln in (text or "").strip()
                             .splitlines())
            key = ("ok", hashlib.sha1(norm.encode("utf-8")).hexdigest())
        if key not in groups:
            groups[key] = []
            order.append(key)
        groups[key].append(names[host])
    if not order:
        die("none of these hosts is in %s" % entry.id)
    ok = sorted([k for k in order if k[0] == "ok"],
                key=lambda k: -len(groups[k]))
    bad = [k for k in order if k[0] != "ok"]
    w = len(str(len(ok)))
    out = [("answer-%0*d" % (w, i + 1), groups[k]) for i, k in enumerate(ok)]
    out += [(group_name("", k[1]), groups[k]) for k in bad]
    return unique(out)


def as_table(groups):
    attrs = []
    for _, hs in groups:
        for h in hs:
            for k, _ in h.attrs:
                if k not in attrs:
                    attrs.append(k)
    rows = []
    for g, hs in groups:
        for h in hs:
            ad = dict(h.attrs)
            rows.append([g, h.name] + [ad.get(a, "") for a in attrs])
    return Table(["group", "host"] + attrs, rows, "split")


def write_lists(groups, out_dir, prefix="", how="", plain=False):
    """One host file per group; returns their paths.  `plain` leaves the
    attributes off, for the tools that read every word as a host."""
    paths = []
    for g, hs in groups:
        path = os.path.join(out_dir, "%s%s.txt" % (prefix, g))
        body = ["# %s: %d host(s)%s" % (g, len(hs), (" -- " + how) if how
                                       else "")]
        body += [h.token(plain=plain) for h in hs]
        write_text(path, "\n".join(body) + "\n")
        paths.append(path)
    return paths
