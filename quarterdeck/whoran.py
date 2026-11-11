# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Martin J. Gallagher
"""Who ran it: the fields of a qd.runs row that make a run attributable.

Every run records the operator (QD_OPERATOR, else the login user) and the
machine qd ran on.  A fan-out records how it reached the hosts as well:
the launcher (--via), the ssh user, the fingerprint of the key it offered,
whether it ran under sudo, and srun's job.  Anything that cannot be found out is left blank -- blank is
"not recorded", never a guess -- and nothing here ever stops a run.

`qd doctor HOST` reads ssh's view of a host here too (ssh_settings and
the lookups after it): what qd's ssh resolves from the config, whether a
master is open, a Kerberos ticket held, a certificate in date.  None of
them contacts the host.
"""

import getpass
import os
import socket
import subprocess
from concurrent.futures import ThreadPoolExecutor

from .common import env

# ssh -G, ssh-add and ssh-keygen only read local files and the agent; a
# wrapper that hangs must still not hold the run up for long
LOOKUP_TIMEOUT = 5


def operator():
    """QD_OPERATOR, else the login user, else blank."""
    who = (env("OPERATOR") or "").strip()
    if who:
        return who
    try:
        return getpass.getuser()
    except Exception:           # no LOGNAME/USER and no passwd entry
        return ""


def operator_host():
    try:
        return socket.gethostname()
    except OSError:
        return ""


def local():
    """The fields every run records."""
    return {"operator": operator(), "operator_host": operator_host()}


def _out(argv):
    """A command's stdout, or None if it would not run or failed."""
    try:
        p = subprocess.run(argv, stdout=subprocess.PIPE,
                           stderr=subprocess.DEVNULL,
                           stdin=subprocess.DEVNULL, timeout=LOOKUP_TIMEOUT)
    except (OSError, subprocess.SubprocessError):
        return None
    if p.returncode != 0:
        return None
    return p.stdout.decode("utf-8", "replace")


def resolved_user(runner, host):
    """The user ssh config gives `host`, as `ssh -G` prints it; None if
    that cannot be found out (not OpenSSH 6.8+, a wrapper, a timeout)."""
    argv = list(runner.ssh) + runner.config_options() + ["-G"]
    if host.port:
        argv += ["-p", str(host.port)]
    text = _out(argv + [host.addr])
    if text is None:
        return None
    for ln in text.splitlines():
        k, _, v = ln.strip().partition(" ")
        if k.lower() == "user" and v.strip():
            return v.strip()
    return None


def ssh_user(runner, hosts, jobs=8):
    """--user if given; else what ssh config resolves for every host.  One
    user is that user; hosts whose config differs give each, comma
    separated; if any host's cannot be found out, blank."""
    if runner.user:
        return runner.user
    seen, distinct = set(), []
    for h in hosts:
        key = (h.addr, h.port)
        if key not in seen:
            seen.add(key)
            distinct.append(h)
    if not distinct:
        return ""
    with ThreadPoolExecutor(max_workers=max(1, min(jobs, 32,
                                                   len(distinct)))) as ex:
        users = list(ex.map(lambda h: resolved_user(runner, h), distinct))
    if any(u is None for u in users):
        return ""
    return ",".join(sorted(set(users)))


def identity_files(ssh_argv):
    """The keys --ssh names: `-i KEY`, `-iKEY`, `-o IdentityFile=KEY`."""
    out = []
    i = 1
    while i < len(ssh_argv):
        a = ssh_argv[i]
        val = None
        if a == "-i" and i + 1 < len(ssh_argv):
            val = ssh_argv[i + 1]
            i += 1
        elif a.startswith("-i") and len(a) > 2:
            val = a[2:]
        elif a == "-o" and i + 1 < len(ssh_argv):
            opt = ssh_argv[i + 1]
            i += 1
            k, _, v = opt.replace("=", " ", 1).partition(" ")
            if k.lower() == "identityfile":
                val = v.strip()
        elif a.startswith("-o") and len(a) > 2:
            k, _, v = a[2:].replace("=", " ", 1).partition(" ")
            if k.lower() == "identityfile":
                val = v.strip()
        if val:
            out.append(val)
        i += 1
    return out


def _fingerprints(text):
    """The SHA256:... (or MD5:...) field of ssh-keygen -l / ssh-add -l
    lines: `256 SHA256:abc comment (ED25519)`."""
    out = []
    for ln in (text or "").splitlines():
        parts = ln.split()
        if len(parts) >= 2 and ":" in parts[1]:
            out.append(parts[1])
    return out


def ssh_key(runner):
    """The fingerprint of each key qd offered: the -i keys in --ssh, else
    the agent's (ssh-add -l).  Never the key itself.  Blank when it cannot
    be found out (no ssh-keygen, no agent, an empty agent)."""
    files = identity_files(runner.ssh)
    if files:
        fps = []
        for f in files:
            got = _fingerprints(_out(["ssh-keygen", "-l", "-f",
                                      os.path.expanduser(f)]))
            if not got:
                return ""       # one key we cannot read: not a partial list
            fps.extend(got)
        return " ".join(fps)
    return " ".join(_fingerprints(_out(["ssh-add", "-l"])))


def _host_argv(runner, host):
    """qd's ssh for `host` up to the host: its options, and -l and -p."""
    argv = list(runner.ssh) + runner.ssh_options()
    if runner.user:
        argv += ["-l", runner.user]
    if host.port:
        argv += ["-p", str(host.port)]
    return argv


def ssh_settings(runner, host):
    """What qd's ssh resolves for `host`, with qd's own options, the
    config file and the user: `ssh -G`, which reads the config and
    contacts nothing.  -> ([(key, value)] in ssh's order, keys in lower
    case, a key repeated as ssh repeats it; '') or (None, why not)."""
    return _dash_g(_host_argv(runner, host) + ["-G", host.addr])


def first_hop(spec):
    """The first bastion of a ProxyJump value (`[user@]host[:port]`, comma
    separated, or ssh://...) -> (user, host, port), any of them blank."""
    first = spec.split(",")[0].strip()
    if "://" in first:
        first = first.split("://", 1)[1]
    user, _, hp = first.rpartition("@")
    port = ""
    if hp.startswith("["):
        host, _, rest = hp[1:].partition("]")
        port = rest[1:] if rest.startswith(":") else ""
    elif hp.count(":") == 1:
        host, _, port = hp.partition(":")
    else:
        host = hp
    return user, host, port if port.isdigit() else ""


def hop_settings(runner, spec):
    """The first bastion of a ProxyJump, as ssh resolves it for the hop.
    ssh reaches a bastion with a second ssh, which is given the config
    file (-F) and nothing else of the command line: none of qd's -o
    options.  So this is the config alone.  -> as ssh_settings, and the
    bastion's name."""
    user, host, port = first_hop(spec)
    argv = list(runner.ssh) + runner.config_options()
    if user:
        argv += ["-l", user]
    if port:
        argv += ["-p", port]
    pairs, why = _dash_g(argv + ["-G", host])
    return host, pairs, why


def _dash_g(argv):
    try:
        p = subprocess.run(argv, stdout=subprocess.PIPE,
                           stderr=subprocess.PIPE, stdin=subprocess.DEVNULL,
                           timeout=LOOKUP_TIMEOUT)
    except OSError as exc:
        return None, "cannot run %s: %s" % (argv[0], exc)
    except subprocess.SubprocessError:
        return None, "ssh -G took longer than %d s" % LOOKUP_TIMEOUT
    if p.returncode != 0:
        said = [ln.strip() for ln in p.stderr.decode(
            "utf-8", "replace").splitlines() if ln.strip()]
        return None, said[0] if said else "ssh -G: exit %d" % p.returncode
    pairs = []
    for ln in p.stdout.decode("utf-8", "replace").splitlines():
        k, _, v = ln.strip().partition(" ")
        if k:
            pairs.append((k.lower(), v.strip()))
    return pairs, ""


def master_running(runner, host):
    """Whether a master is open for `host` at the ControlPath its config
    names (`ssh -O check`: the local socket, not the host)."""
    argv = _host_argv(runner, host) + ["-O", "check", host.addr]
    try:
        p = subprocess.run(argv, stdout=subprocess.DEVNULL,
                           stderr=subprocess.DEVNULL,
                           stdin=subprocess.DEVNULL, timeout=LOOKUP_TIMEOUT)
    except (OSError, subprocess.SubprocessError):
        return False
    return p.returncode == 0


def kerberos_ticket():
    """True when a Kerberos ticket is held (`klist -s`), False when not,
    None when there is no klist to ask."""
    try:
        p = subprocess.run(["klist", "-s"], stdout=subprocess.DEVNULL,
                           stderr=subprocess.DEVNULL,
                           stdin=subprocess.DEVNULL, timeout=LOOKUP_TIMEOUT)
    except (OSError, subprocess.SubprocessError):
        return None
    return p.returncode == 0


def certificate_validity(path):
    """A certificate's `Valid:` line as ssh-keygen -L prints it ("from
    2026-11-10T08:00:00 to 2026-11-11T08:00:00", "forever"), or None when
    it cannot be read."""
    text = _out(["ssh-keygen", "-L", "-f", os.path.expanduser(path)])
    for ln in (text or "").splitlines():
        k, _, v = ln.strip().partition(":")
        if k == "Valid" and v.strip():
            return v.strip()
    return None


def fan_out(runner, hosts, jobs=8):
    """The fields a fan-out records on top of local(), and how the hosts
    were reached (via, and srun's job).  ssh -G and the keys describe
    qd's own ssh: srun has none, and pdsh and clush start theirs as their
    own configuration says, so for them only a --user given is kept."""
    if getattr(runner, "via", "ssh") == "ssh":
        fields = {"ssh_user": ssh_user(runner, hosts, jobs),
                  "ssh_key": ssh_key(runner)}
    else:
        fields = {"ssh_user": runner.user or "", "ssh_key": ""}
    fields["sudo"] = "yes" if runner.sudo else "no"
    fields.update(runner.run_fields())
    return fields

