# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Martin J. Gallagher
"""What qd may send to a fleet: a command allow-list and a read-only mode.

DANGER in cli.py is a deny-list, a typo guard, and a deny-list is never
complete.  This is the other way round, for a system under test that must
not be changed: name what may run, and everything else is refused.

    --allow FILE   (QD_ALLOW)      patterns, one a line, of commands that
                                   may run; anything else needs --confirm
                                   and a typed confirmation at a terminal
    --read-only    (QD_READ_ONLY)  only the probes qd ships and allow-listed
                                   commands; never --push, --script, --sudo
                                   or `qd do`, and no confirmation lifts it

It is policy, not a sandbox: a pushed script, an allow-listed shell or a
quoting trick gets past any list of patterns.  The real control is the
account's own ssh and sudo rights on the hosts (README, "Allow-lists and
read-only").

Every run under a policy says so in its qd.runs notes (the list's name
and hash, read-only, and any confirmed override, with who confirmed),
and every refusal is appended to `policy.log` in qd's cache, since a
refused run files nothing.
"""

import fnmatch
import hashlib
import os
import sys
import time

from .common import PROG, die, env

CONFIRM_WORD = "CONFIRM"


def _truthy(v):
    return (v or "").strip().lower() in ("1", "yes", "true", "on")


def operator():
    for k in ("QD_OPERATOR", "USER", "LOGNAME", "USERNAME"):
        v = os.environ.get(k)
        if v:
            return v
    return "unknown"


class Policy(object):
    def __init__(self, allow_file=None, read_only=False, confirm=False):
        self.allow_file = allow_file or None
        self.read_only = bool(read_only)
        self.confirm = bool(confirm)
        self.patterns = []
        self.digest = ""
        self.overrides = []
        if self.allow_file:
            self.patterns, self.digest = read_allow(self.allow_file)

    @property
    def active(self):
        return bool(self.allow_file or self.read_only)

    def allowed(self, command):
        c = " ".join(command.split())
        return any(fnmatch.fnmatchcase(c, p) for p in self.patterns)

    def notes(self):
        """What a run under this policy records in its notes."""
        bits = []
        if self.read_only:
            bits.append("policy: read-only")
        if self.allow_file:
            bits.append("policy: allow-list %s sha256:%s" % (
                os.path.basename(self.allow_file), self.digest[:12]))
        for o in self.overrides:
            bits.append("policy: confirmed outside the allow-list by %s: %s"
                        % (operator(), o))
        return "; ".join(bits)


def read_allow(path):
    """The patterns in an allow-list file, and the file's sha256."""
    if not os.path.isfile(path):
        die("no such allow-list: %s (--allow, QD_ALLOW)" % path)
    try:
        with open(path, "rb") as f:
            raw = f.read()
        text = raw.decode("utf-8")
    except (IOError, OSError, UnicodeDecodeError) as exc:
        die("cannot read the allow-list %s: %s" % (path, exc))
    pats = []
    for ln in text.splitlines():
        ln = ln.strip()
        if not ln or ln.startswith("#"):
            continue
        pats.append(" ".join(ln.split()))
    return pats, hashlib.sha256(raw).hexdigest()


def from_args(args):
    """The policy a command line asks for: flags, else QD_ALLOW and
    QD_READ_ONLY."""
    allow = getattr(args, "allow", None) or env("ALLOW") or None
    ro = getattr(args, "read_only", False) or _truthy(env("READ_ONLY"))
    return Policy(allow, ro, getattr(args, "confirm", False))


def log_refusal(verb, command, why):
    """A refusal on record: a refused run files nothing, so it goes in
    qd's cache, one tab-separated line each."""
    try:
        from .store import cache_root
        d = cache_root()
        if not os.path.isdir(d):
            os.makedirs(d)
        line = "\t".join([
            time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), operator(),
            verb, " ".join(command.split()), " ".join(why.split())])
        with open(os.path.join(d, "policy.log"), "a") as f:
            f.write(line + "\n")
    except (IOError, OSError):
        pass


def refuse(verb, command, why):
    log_refusal(verb, command, why)
    die(why)


def stdin_is_tty():
    try:
        return sys.stdin.isatty()
    except (AttributeError, ValueError):
        return False


def check(policy, command, verb="run", nhosts=0, pushing=False, sudo=False,
          probe=False):
    """Refuse what the policy does not allow; ask for a typed confirmation
    where it allows one.  A probe qd ships is allowed by name."""
    if not policy.active:
        return
    if policy.read_only:
        for flag, on in (("--push or --script", pushing), ("--sudo", sudo)):
            if on:
                refuse(verb, command, "read-only (--read-only, QD_READ_ONLY):"
                       " %s is refused, since it changes the hosts" % flag)
    if probe:
        return
    if policy.allowed(command):
        return
    if " ".join(command.split()) in policy.overrides:
        return      # confirmed once already: a campaign's next part
    where = ("the allow-list %s" % policy.allow_file) if policy.allow_file \
        else "no allow-list"
    if policy.read_only:
        refuse(verb, command, "read-only: %r is not on %s, and read-only "
               "allows only the probes qd ships and allow-listed commands"
               % (command, where))
    if not policy.confirm:
        refuse(verb, command, "%r is not on %s.\n  To run it anyway, add "
               "--confirm and type %s at the prompt." % (
                   command, where, CONFIRM_WORD))
    if not stdin_is_tty():
        refuse(verb, command, "%r is not on %s, and nothing is attached to "
               "this terminal to confirm it" % (command, where))
    sys.stderr.write("%s: %r is not on %s.\n  Type %s to run it on %d "
                     "host%s: " % (PROG, command, where, CONFIRM_WORD,
                                   nhosts, "" if nhosts == 1 else "s"))
    sys.stderr.flush()
    try:
        answer = sys.stdin.readline()
    except (IOError, OSError, KeyboardInterrupt):
        answer = ""
    if answer.strip() != CONFIRM_WORD:
        refuse(verb, command, "not confirmed: %r was not run" % command)
    policy.overrides.append(" ".join(command.split()))


def check_do(policy, cmdline):
    if policy.read_only:
        refuse("do", cmdline, "read-only (--read-only, QD_READ_ONLY): qd do "
               "is refused, since the tools it drives deploy agents and "
               "servers to the hosts")
