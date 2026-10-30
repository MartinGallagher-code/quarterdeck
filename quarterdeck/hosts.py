# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Martin J. Gallagher
"""Host lists: the grammar the rest of the toolchain already reads.

A line is `name[=addr[:port]] [key=value ...]`, `#` starts a comment, and
`node[01-24]` / `rack[a-c]-n[1,3]` expand -- so a `servers.txt` written
for mx, iperf_orchestrator, agree or dcprobe works here unchanged.  The
`key=value` words after a host are its attributes (`rack=r3 gbps=25`),
as dcprobe reads them: they ride along into every dataset as columns,
which is what lets a run be grouped by rack without joining two files.

The other way round needs care.  agree, mx and iperf_orchestrator have no
attributes -- agree reads `node01 rack=r1` as two hosts -- so give them
`qd hosts --plain`, the same fleet without the attributes.
"""

import csv
import io
import os
import re
import socket
import subprocess
import sys

from .common import die, env, read_text, warn

# Columns a run writes itself.  An attribute by one of these names would
# shadow a measurement, so it is carried as attr_<name> instead.
RESERVED = {"host", "addr", "status", "rc", "duration_s", "error", "pass",
            "ts", "stdout", "stderr", "line", "line_no", "value", "row",
            "run", "capture", "n", "dataset", "bytes", "attrs"}

ATTR_RE = re.compile(r"^[A-Za-z_][\w.-]*=")


class Host(object):
    __slots__ = ("name", "addr", "port", "attrs")

    def __init__(self, name, addr, port=None, attrs=None):
        self.name, self.addr, self.port = name, addr, port
        self.attrs = list(attrs or [])

    def __repr__(self):
        return self.name

    def token(self, plain=False):
        """The host as a host-list line would write it; `plain` leaves the
        attributes off, for the tools that have none."""
        if self.name == self.addr and not self.port:
            t = self.name
        else:
            addr = "[%s]" % self.addr if (":" in self.addr and self.port) \
                else self.addr
            t = "%s=%s%s" % (self.name, addr,
                             ":%d" % self.port if self.port else "")
        if plain:
            return t
        return " ".join([t] + ["%s=%s" % kv for kv in self.attrs])


# canonical copy of the range expander and the address parser:
# binnacle/agree.py expand_range(), split_commas(), split_host_port().
# Copied rather than imported -- quarterdeck must run where binnacle is
# not installed -- and kept to the same behaviour, so a host list means
# the same fleet to every tool that reads it.

RANGE_RE = re.compile(r"\[([^\]]+)\]")


def expand_range(spec):
    """node[01-24] / node[1,3,5-8] / rack[a-c]-node[01-04] (cartesian)."""
    m = RANGE_RE.search(spec)
    if not m:
        return [spec]
    # [::1] and [fe80::1]:22 are addresses, not ranges.
    if ":" in m.group(1):
        return [spec]
    before, body, after = spec[:m.start()], m.group(1), spec[m.end():]
    items = []
    for part in body.split(","):
        part = part.strip()
        if "-" in part and not part.startswith("-"):
            a, b = part.split("-", 1)
            a, b = a.strip(), b.strip()
            if a.isdigit() and b.isdigit():
                width = len(a) if a.startswith("0") else 0
                for v in range(int(a), int(b) + 1):
                    items.append(str(v).zfill(width) if width else str(v))
                continue
            if len(a) == 1 and len(b) == 1 and a.isalpha() and b.isalpha():
                for c in range(ord(a), ord(b) + 1):
                    items.append(chr(c))
                continue
            die("cannot expand range %r in %r" % (part, spec))
        else:
            items.append(part)
    out = []
    for it in items:
        out.extend(expand_range(before + it + after))
    return out


def split_commas(spec):
    """Split on commas outside [brackets]: 'a,b' is two, 'n[1,3]' is one."""
    out, depth, cur = [], 0, []
    for ch in spec:
        if ch == "[":
            depth += 1
        elif ch == "]":
            depth = max(0, depth - 1)
        if ch == "," and depth == 0:
            out.append("".join(cur))
            cur = []
        else:
            cur.append(ch)
    out.append("".join(cur))
    return [s for s in (x.strip() for x in out) if s]


def _port_of(text, spec):
    if not text.isdigit():
        die("bad port %r in host token %r" % (text, spec))
    port = int(text)
    if not 1 <= port <= 65535:
        die("port %d is out of range in host token %r (want 1-65535)"
            % (port, spec))
    return port


def split_host_port(spec):
    """'host', 'host:port', '[v6]', '[v6]:port', bare v6 -> (addr, port)."""
    spec = spec.strip()
    port = None
    if spec.startswith("["):
        addr, sep, rest = spec[1:].partition("]")
        if not sep:
            die("no closing ] in host token %r" % spec)
        if rest.startswith(":"):
            port = _port_of(rest[1:], spec)
        elif rest:
            die("unexpected %r after ] in host token %r" % (rest, spec))
    elif spec.count(":") > 1:
        addr = spec
    elif ":" in spec:
        addr, _, p = spec.rpartition(":")
        if p.isdigit():
            port = _port_of(p, spec)
        else:
            addr = spec
    else:
        addr = spec
    if ":" in addr:
        try:
            socket.inet_pton(socket.AF_INET6, addr)
        except (OSError, ValueError):
            die("not a valid IPv6 address: %r (in host token %r)"
                % (addr, spec))
    return addr, port


def parse_host_token(tok, attrs=None):
    tok = tok.strip()
    bare = "=" not in tok
    if bare:
        name = addr = tok
    else:
        name, addr = tok.split("=", 1)
        name, addr = name.strip(), addr.strip()
    addr, port = split_host_port(addr)
    if bare:
        name = addr
    if not name or not addr:
        die("bad host token %r (want name[=addr[:port]])" % tok)
    return Host(name, addr, port, attrs)


def _attr(word):
    k, _, v = word.partition("=")
    if k in RESERVED:
        k = "attr_" + k
    return (k, v)


def _is_address(text):
    addr = text.rsplit(":", 1)[0] if text.count(":") == 1 else text
    for fam in (socket.AF_INET, socket.AF_INET6):
        try:
            socket.inet_pton(fam, addr.strip("[]"))
            return True
        except (OSError, ValueError):
            pass
    return False


def parse_lines(text):
    """Host-list text -> [(token, attrs)], ranges not yet expanded.

    The first word on a line is a host; after it, a `key=value` word is
    that host's attribute and a bare word is another host.  So
    `r1h1=10.1.1.11 gbps=25` (dcprobe's shape) and `web01 web02` (agree's)
    both mean what they say.
    """
    out = []
    for line in text.splitlines():
        line = line.split("#", 1)[0].strip()
        if not line:
            continue
        words = line.split()
        hosts, attrs = [], []
        for i, w in enumerate(words):
            if i > 0 and ATTR_RE.match(w):
                attrs.append(_attr(w))
                if _is_address(w.partition("=")[2]):
                    # agree reads `a=10.0.0.1 b=10.0.0.2` as two hosts;
                    # here, as dcprobe does, the second is an attribute.
                    warn("%r after %s is read as an attribute, not a host: "
                         "a host that carries = goes on a line of its own"
                         % (w, words[0]))
            else:
                hosts.extend(split_commas(w))
        for h in hosts:
            out.append((h, attrs))
    return out


def read_host_file(path):
    """A host file's entries, or None when `path` is not a file at all."""
    if path != "-" and not os.path.isfile(path):
        if os.sep in path or os.path.isdir(path):
            die("no such host file: %s" % path)
        return None
    return parse_lines(read_text(path))


def layout_hosts(layout, selectors, manifest_argv):
    """The servers a .dc layout puts under these selectors, via manifest.

    manifest owns the selector language -- `rack[1-3]`, `+gpu`,
    `model=hgx*` -- so it is asked rather than reimplemented, and what it
    says about where each host sits (room, row, rack, slot) comes back as
    attributes.
    """
    if not os.path.isfile(layout):
        die("no such layout: %s" % layout)
    if manifest_argv is None:
        die("--layout needs binnacle's manifest to read the layout, and it "
            "is not installed here.\n  pip install binnacle  "
            "(or set QD_MANIFEST to its path)")
    argv = list(manifest_argv) + [layout] + list(selectors or ["*"]) + \
        ["--csv", "--quiet"]
    try:
        p = subprocess.Popen(argv, stdout=subprocess.PIPE,
                             stderr=subprocess.PIPE)
        out, err = p.communicate()
    except OSError as exc:
        die("cannot run manifest: %s" % exc)
    out = out.decode("utf-8-sig", "replace")
    err = err.decode("utf-8", "replace").strip()
    if p.returncode == 1:
        die("the selectors matched no servers in %s%s"
            % (layout, (": " + err.splitlines()[-1]) if err else ""), 1)
    if p.returncode != 0:
        die("manifest failed on %s: %s" % (layout, err or "exit %d"
                                            % p.returncode))
    rdr = csv.DictReader(io.StringIO(out))
    if "name" not in (rdr.fieldnames or []):
        # Something else called `manifest` can be first on PATH; reading
        # its output as an empty fleet would be a wrong answer, not an error.
        die("%s did not answer the way binnacle's manifest does (its --csv "
            "output has no name column); point QD_MANIFEST at binnacle's "
            "manifest" % " ".join(manifest_argv))
    hosts = []
    for row in rdr:
        name = (row.get("name") or "").strip()
        if not name:
            continue
        attrs = [(k, row[k]) for k in ("room", "row", "rack", "slot", "role",
                                       "path") if row.get(k)]
        hosts.append(Host(name, name, None, attrs))
    if not hosts:
        die("the selectors matched no servers in %s" % layout, 1)
    return hosts


def collect_hosts(servers=None, inline=None, layout=None, selectors=None,
                  first=None, manifest_argv=None):
    """Every way of naming a fleet, expanded, in order, without repeats."""
    entries = []
    for spec in (servers or []):
        got = read_host_file(spec)
        if got is not None:
            entries.extend(got)
        else:
            entries.extend((t, []) for t in split_commas(spec))
    for spec in (inline or []):
        entries.extend((t, []) for t in split_commas(spec))
    from_layout = []
    if layout:
        from_layout = layout_hosts(layout, selectors, manifest_argv)
    elif selectors:
        die("--select needs --layout FILE to select from")
    if not entries and not from_layout:
        default = env("SERVERS")
        if default:
            got = read_host_file(default)
            if got is None:
                entries.extend((t, []) for t in split_commas(default))
            else:
                entries.extend(got)
        else:
            for name in ("hosts.txt", "servers.txt"):
                if os.path.isfile(name):
                    entries.extend(read_host_file(name))
                    break
    if not entries and not from_layout:
        die("no hosts given (use --servers FILE, --servers 'node[01-09]', "
            "-S a,b,c or --layout floor.dc --select SEL; hosts.txt and "
            "servers.txt are used if present)")
    hosts, seen = [], set()
    for tok, attrs in entries:
        for one in expand_range(tok):
            h = parse_host_token(one, attrs)
            if h.name not in seen:
                seen.add(h.name)
                hosts.append(h)
    for h in from_layout:
        if h.name not in seen:
            seen.add(h.name)
            hosts.append(h)
    if first is not None:
        hosts = hosts[:first]
    return hosts


def attr_columns(hosts):
    """Attribute names in first-seen order, for a dataset's columns."""
    cols = []
    for h in hosts:
        for k, _ in h.attrs:
            if k not in cols:
                cols.append(k)
    return cols


def stdin_is_tty():
    try:
        return sys.stdin.isatty()
    except (AttributeError, ValueError):
        return False
