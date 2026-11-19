# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Martin J. Gallagher
"""qd setup: from nothing to a first run, a step at a time (QD-063).

Four steps, each one a plain command qd already has, run as that command
runs it:

  1. what this machine can drive: `qd doctor`, its own report;
  2. a store to keep the answers in: when none is active, `qd store new
     main` and `qd store use main`, asked first;
  3. the host list: -s, -S, --layout, QD_SERVERS, hosts.txt or
     servers.txt, as `qd run` finds it; when there is none, an offer to
     write hosts.txt from names typed at the terminal;
  4. who answers: `qd run -- true` on every host, keeping nothing, and for
     each host that did not answer, why and what to do about it.

Every question checks that stdin is a terminal first, so a script or CI
never waits on one: there, setup checks and changes nothing that needs an
answer, and says what to do instead (`--yes` answers the store's
question).  Nothing is overwritten: hosts.txt is opened to be created and
never truncated, and `qd store new` refuses a name or a directory that is
taken.  The test run is filed nowhere, so a second `qd setup` changes
nothing and finds every step done.

Exit status: 0 when this machine is ready and every host answered; 1 when
it is not ready (step 1) or a host did not answer (step 4), and the
summary names the step; 2 on a usage error or a write that was refused.
"""

import contextlib
import io
import os
import re
import shlex
import sys

from .common import PROG, QdError, env, plural
from . import demo, filing, fleet, stores
from . import hosts as hostmod
from . import store as storemod

# the store setup makes when none is active (--store-name)
STORE_NAME = "main"
# the host list it writes, and where qd run looks with no -s
HOSTS_FILE = "hosts.txt"
# setup's own attributes, never handed to the plain commands
OWN = ("verb", "fn", "command", "store_name", "host", "action", "words")


# ---------------------------------------------------------------------------
# questions: only ever at a terminal
# ---------------------------------------------------------------------------

def at_terminal():
    """Whether a question can be answered: stdin is a terminal.  Asked
    before every question, never once for all of them."""
    return hostmod.stdin_is_tty()


def ask(question):
    """One line typed at the terminal, or None: stdin is not a terminal,
    or it ended."""
    if not at_terminal():
        return None
    sys.stdout.flush()
    try:
        return input(question)
    except EOFError:
        sys.stdout.write("\n")
        return None


def agree(question):
    """Yes (Enter is yes), no, or None when nothing could be asked."""
    a = ask(question + " [Y/n] ")
    if a is None:
        return None
    return a.strip().lower() in ("", "y", "yes")


# ---------------------------------------------------------------------------
# the plain commands, as they would be typed
# ---------------------------------------------------------------------------

def plain(cli, args, argv, **over):
    """The Namespace `qd ARGV...` would get, with setup's own options
    (--store, the host and ssh options) carried over where that verb
    takes them, so every QD_* variable and flag means what it means in the
    plain command."""
    parser, _ = cli.build_parser()
    ns = parser.parse_args(argv)
    mine = vars(ns)
    for k, v in vars(args).items():
        if k in mine and k not in OWN and not k.startswith("_"):
            setattr(ns, k, v)
    for k, v in over.items():
        setattr(ns, k, v)
    ns._argv = list(argv)
    return ns


def quietly(fn, ns):
    """Run a cmd_* and keep what it printed. -> (status, lines)"""
    buf = io.StringIO()
    with contextlib.redirect_stdout(buf):
        rc = fn(ns) or 0
    return rc, buf.getvalue().splitlines()


def split_tips(lines):
    """A report's lines without its WHAT TO DO NEXT, and that block's
    entries as next_steps takes them."""
    body, tips, inside = [], [], False
    for ln in lines:
        if ln.strip() == "WHAT TO DO NEXT":
            inside = True
            continue
        if not inside:
            body.append(ln)
            continue
        m = re.match(r"\s*\* (.*)$", ln)
        if not m:
            continue
        parts = re.split(r"\s{2,}", m.group(1).strip(), 1)
        tips.append((parts[0], parts[1]) if len(parts) == 2
                    else ("", parts[0]))
    while body and not body[-1].strip():
        body.pop()
    return body, tips


class Report(object):
    """What each step did, for the summary, and the status it sets."""

    def __init__(self):
        self.rows = []          # (step, what)
        self.tips = []          # (command, why), next_steps' shape
        self.finding = []       # steps that found something: status 1
        self.refused = []       # steps that could not write: status 2

    def row(self, step, what):
        self.rows.append((step, what))

    def tip(self, cmd, why):
        if cmd and any(c == cmd for c, _ in self.tips):
            return
        self.tips.append((cmd, why))


def say(text=""):
    sys.stdout.write(text + "\n")
    sys.stdout.flush()


def heading(n, text):
    say("")
    say("%d. %s" % (n, text))


# ---------------------------------------------------------------------------
# 1. this machine
# ---------------------------------------------------------------------------

def step_machine(cli, args, rep):
    heading(1, "What this machine can drive (%s doctor)" % PROG)
    ns = plain(cli, args, ["doctor"])
    rc, lines = quietly(cli.cmd_doctor, ns)
    body, tips = split_tips(lines)
    if body and body[0].startswith(PROG + " doctor"):
        body = body[1:]
    while body and not body[0].strip():
        body = body[1:]
    for ln in body:
        say(ln)
    # what a first run needs; the rest of the toolchain is for later, and
    # qd doctor lists it
    for cmd, why in tips:
        if "ssh" in why or "provost" in why:
            rep.tip(cmd, why)
    provost = filing.find()
    if rc == 0 and provost:
        rep.row("machine", "ready")
        return
    why = []
    if rc:
        why.append("%s doctor exits %d: the launcher cannot run from here"
                   % (PROG, rc))
    if not provost:
        why.append("no provost here, so nothing can be kept")
    rep.row("machine", "NOT READY: " + "; ".join(why))
    rep.finding.append("step 1, this machine is not ready")


# ---------------------------------------------------------------------------
# 2. a store
# ---------------------------------------------------------------------------

def store_line(path, name):
    n = stores.run_count(path)
    runs = "not made yet" if n is None and not os.path.exists(path) else \
        "unreadable" if n is None else plural(n, "run")
    return "%s%s (%s)" % (name + " = " if name else "",
                          storemod.tilde(path), runs)


def make_store(cli, args, name, rep, demo_active=False):
    """qd store new NAME, then qd store use NAME, as typed."""
    cfg = stores.load()
    # registered but not active: only selecting it is left
    made = name not in cfg["stores"]
    try:
        if made:
            quietly(cli.cmd_store, plain(cli, args, ["store", "new", name]))
        quietly(cli.cmd_store, plain(cli, args, ["store", "use", name]))
    except QdError as exc:
        say("  refused: %s" % exc)
        rep.row("store", "%s not %s" % (name, "made" if made
                                        else "selected"))
        rep.refused.append("step 2, the store %s could not be %s"
                           % (name, "made" if made else "selected"))
        return
    path = stores.load()["stores"][name]
    say("  done: %s the store %s (%s), and made it the active store%s"
        % ("made" if made else "selected", name, storemod.tilde(path),
           " in place of the demo" if demo_active else ""))
    say("        (%s)" % "; ".join(
        (["%s store new %s" % (PROG, name)] if made else []) +
        ["%s store use %s" % (PROG, name)]))
    rep.row("store", "%s, active (%s now)" % (
        name, "made" if made else "selected"))


def step_store(cli, args, rep):
    heading(2, "A store to keep the answers in (%s store)" % PROG)
    name = stores.check_name(args.store_name or STORE_NAME)
    path, have, how = stores.choose(getattr(args, "store", None),
                                    quiet=True, fetch=False)
    cfg = stores.load()
    if how in ("--store", "QD_STORE", "provost"):
        what = {"--store": "--store", "QD_STORE": "QD_STORE",
                "provost": "PROVOST_WORKSPACE, or the provost-controlled "
                "directory you are in"}[how]
        say("  already done: %s chooses the store, %s; nothing to set up"
            % (what, store_line(path, have)))
        rep.row("store", "%s (chosen by %s; already done)" % (
            have or storemod.tilde(path), what))
        return
    if how == "active" and have != demo.NAME:
        say("  already done: the active store is %s"
            % store_line(path, have))
        rep.row("store", "%s, active (already done)" % have)
        return
    demo_active = how == "active"
    others = sorted(n for n in cfg["stores"] if n != demo.NAME)
    if demo_active:
        say("  the active store is the demo's, %s: a fleet's own runs "
            "and the demo's are better kept apart" % storemod.tilde(path))
    else:
        say("  no store is active, so a run would go to provost's default, "
            "%s" % storemod.tilde(path))
    if others and name not in cfg["stores"]:
        # stores to choose from: which one is the user's to say
        say("  registered: %s" % ", ".join(others))
        pick = ask("  Which should commands use from now on? Type its "
                   "name, or press Enter to leave it: ")
        if pick and pick.strip() in others:
            make_store(cli, args, pick.strip(), rep, demo_active)
            return
        if pick and pick.strip():
            say("  %r is not one of them; nothing changed" % pick.strip())
        else:
            say("  nothing changed%s" % ("" if at_terminal() else
                                         ": stdin is not a terminal, so "
                                         "nothing was asked"))
        rep.row("store", "none active: not chosen")
        rep.tip("%s store use NAME" % PROG,
                "pick the store commands use: %s" % ", ".join(others))
        return
    target = os.path.join(stores.data_root(), name) \
        if name not in cfg["stores"] else cfg["stores"][name]
    verb = "select the store %s (%s)" % (name, storemod.tilde(target)) \
        if name in cfg["stores"] else \
        "make a store named %s (%s)" % (name, storemod.tilde(target))
    if args.yes:
        ok = True
    else:
        ok = agree("  %s%s and make it the active store?" % (
            verb[0].upper(), verb[1:]))
    if ok:
        make_store(cli, args, name, rep, demo_active)
        return
    if ok is None:
        say("  nothing changed: stdin is not a terminal, so nothing was "
            "asked")
        say("  (%s setup --yes would %s)" % (PROG, verb))
    else:
        say("  nothing changed")
    rep.row("store", "none of the fleet's own active: not made")
    if name not in cfg["stores"]:
        rep.tip("%s store new %s" % (PROG, name),
                "a store of the fleet's own, in %s"
                % storemod.tilde(stores.data_root()))
    rep.tip("%s store use %s" % (PROG, name),
            "the store commands use from now on")


# ---------------------------------------------------------------------------
# 3. the host list
# ---------------------------------------------------------------------------

def named_on_line(args):
    return bool(args.servers or args.server or args.layout or args.rerun)


def host_flags(args):
    """The host options as typed, for the commands setup suggests."""
    words = []
    for s in args.servers or []:
        words += ["-s", shlex.quote(s)]
    for s in args.server or []:
        words += ["-S", shlex.quote(s)]
    if args.layout:
        words += ["--layout", shlex.quote(args.layout)]
    for s in args.select or []:
        words += ["--select", shlex.quote(s)]
    return (" " + " ".join(words)) if words else ""


def found_somewhere(args):
    """Whether anything names a fleet: what collect_hosts reads, and
    --via srun's allocation."""
    if named_on_line(args) or env("SERVERS"):
        return True
    if any(os.path.isfile(n) for n in ("hosts.txt", "servers.txt")):
        return True
    return getattr(args, "via", None) == "srun"


def type_hosts():
    """Host names typed at the terminal, checked as a host list reads
    them. -> (text, [Host]) or (None, None)"""
    if not at_terminal():
        return None, None
    say("  Type the hosts, as hosts.txt holds them: one or more a line "
        "(node[01-12],")
    say("  web1 web2, or a host with attributes: node01 rack=r1).  An "
        "empty line ends;")
    say("  an empty first line skips.")
    while True:
        typed = []
        while True:
            ln = ask("  host> ")
            if ln is None or not ln.strip():
                break
            typed.append(ln.rstrip())
        if not typed:
            return None, None
        text = "\n".join(typed) + "\n"
        try:
            hs = hostmod.collect_hosts(inline=[text])
        except QdError as exc:
            say("  that is not a host list (%s); type it again" % exc)
            continue
        return text, hs


def write_hosts(text, rep):
    """hosts.txt, created and never overwritten. -> True when written"""
    try:
        with io.open(HOSTS_FILE, "x", encoding="utf-8") as fh:
            fh.write("# written by %s setup: a host a line, attributes "
                     "after it\n" % PROG)
            fh.write(text)
    except FileExistsError:
        say("  refused: %s is there already, and setup never overwrites "
            "it" % HOSTS_FILE)
        rep.refused.append("step 3, %s is there already" % HOSTS_FILE)
        return False
    except OSError as exc:
        say("  refused: cannot write %s: %s" % (HOSTS_FILE, exc))
        rep.refused.append("step 3, %s could not be written" % HOSTS_FILE)
        return False
    return True


def step_hosts(cli, args, run_ns, rep):
    """-> the hosts to test, or None"""
    heading(3, "The host list (%s hosts)" % PROG)
    if found_somewhere(args):
        try:
            hs = cli.collect(run_ns)
        except QdError as exc:
            say("  the host list cannot be read: %s" % exc)
            rep.row("hosts", "cannot be read")
            rep.refused.append("step 3, the host list cannot be read")
            return None
        where = "named on the command line" if named_on_line(args) else \
            cli.bare_hosts(run_ns)
        say("  already done: %s, %s" % (plural(len(hs), "host"), where))
        rep.row("hosts", "%s, %s (already done)" % (
            plural(len(hs), "host"), where))
        return hs
    say("  none here: no -s, -S or --layout, no QD_SERVERS, and no "
        "hosts.txt or")
    say("  servers.txt in %s" % storemod.tilde(os.getcwd()))
    text, hs = type_hosts()
    if text is None:
        say("  nothing written%s" % ("" if at_terminal() else
                                     ": stdin is not a terminal, so "
                                     "nothing was asked"))
        rep.row("hosts", "none: nothing to test")
        rep.tip("%s hosts -S node01,node02 > %s" % (PROG, HOSTS_FILE),
                "a host list here, a host a line; then %s setup again"
                % PROG)
        return None
    if not write_hosts(text, rep):
        rep.row("hosts", "%s not written" % HOSTS_FILE)
        return None
    say("  done: wrote %s, %s (%s hosts prints them)"
        % (HOSTS_FILE, plural(len(hs), "host"), PROG))
    rep.row("hosts", "%s, %s (written now)" % (
        plural(len(hs), "host"), HOSTS_FILE))
    return cli.collect(run_ns)


# ---------------------------------------------------------------------------
# 4. who answers
# ---------------------------------------------------------------------------

def advice(r):
    """(why, what to do) for a host that did not answer, by the kind of
    failure."""
    err = r.error()
    low = err.lower()
    name = r.host.name
    if r.outcome == fleet.TIMEOUT:
        return ("no answer within --timeout",
                "a slow login or a hung host: %s doctor %s; --timeout N to "
                "wait longer" % (PROG, name))
    if r.outcome == fleet.FAILED:
        return ("ssh got in, but `true` failed (%s)" % err,
                "its login shell, or sudo -n with --sudo: ssh %s true "
                "shows it" % name)
    if "permission denied" in low:
        return ("no key it accepts (%s)" % err,
                "keys: ssh-copy-id %s (qd never types a password); %s "
                "doctor %s" % (name, PROG, name))
    if "host key" in low:
        return ("its host key is not known or has changed (%s)" % err,
                "ssh %s once to check and accept it; %s doctor %s"
                % (name, PROG, name))
    if "resolve" in low or "no such host" in low or \
            "not known" in low:
        return ("the name does not resolve (%s)" % err,
                "check its spelling in the host list, or give its "
                "address: %s=10.0.0.5" % name)
    if "refused" in low:
        return ("nothing listens for ssh there (%s)" % err,
                "is sshd running, on that port? reachable (binnacle) "
                "comments dead entries out")
    if "timed out" in low or "route" in low or "unreachable" in low:
        return ("down, or a firewall between (%s)" % err,
                "reachable (binnacle) comments dead entries out; %s doctor "
                "%s" % (PROG, name))
    return (err or r.outcome,
            "%s doctor %s: what ssh will do for it, contacting nothing"
            % (PROG, name))


def step_reach(cli, args, run_ns, hs, rep):
    heading(4, "Who answers (%s run%s -- true, nothing kept)"
            % (PROG, host_flags(args)))
    if not hs:
        say("  nothing to test: no host list")
        rep.row("answered", "not tested: no host list")
        return
    try:
        job = cli.fleet_run(run_ns, hs, "true", "setup", store=False)
    except QdError as exc:
        say("  the test was refused: %s" % exc)
        rep.row("answered", "not tested: refused")
        rep.refused.append("step 4, the test run was refused")
        return
    last = job.last
    bad = [r for r in last if r.outcome != fleet.OK]
    say("  %s: %d answered, %d did not" % (
        plural(len(last), "host"), len(last) - len(bad), len(bad)))
    if not bad:
        say("  done: every host answered")
        rep.row("answered", "every host, %d of %d" % (len(last), len(last)))
        return
    say("")
    say("  DID NOT ANSWER")
    w = max(len(r.host.name) for r in bad)
    for r in bad:
        why, todo = advice(r)
        say("    %-*s  %s" % (w, r.host.name, why))
        say("    %-*s  -> %s" % (w, "", todo))
    rep.row("answered", "%d of %d; %s did not" % (
        len(last) - len(bad), len(last), plural(len(bad), "host")))
    rep.finding.append("step 4, %s did not answer"
                       % plural(len(bad), "host"))
    rep.tip("%s doctor %s" % (PROG, bad[0].host.name),
            "what ssh will do for it, contacting nothing")
    if not named_on_line(args):
        rep.tip("reachable %s -i" % (
            HOSTS_FILE if os.path.isfile(HOSTS_FILE) else "servers.txt"),
            "binnacle: comment dead entries out of the list")
    rep.tip("%s setup%s" % (PROG, host_flags(args)),
            "again once they are fixed: what is done stays done")


# ---------------------------------------------------------------------------
# the command
# ---------------------------------------------------------------------------

def first_commands(cli, args, rep):
    """What to try once set up: qd ask and qd survey where this qd has
    them (QD-059, QD-060), the plain commands they are built from where
    it does not, and the demo."""
    _, sub = cli.build_parser()
    flags = host_flags(args)
    if "ask" in sub.choices:
        rep.tip("%s ask%s -- uname -r" % (PROG, flags),
                "ask every host; see who agrees and who differs")
    else:
        rep.tip("%s run%s -- uname -r" % (PROG, flags),
                "ask every host, and keep the answers")
        rep.tip("%s freq latest A" % PROG, "who said which")
    if "survey" in sub.choices:
        rep.tip("%s survey%s" % (PROG, flags),
                "everything about every host, and who stands out")
    else:
        rep.tip("%s probe facts inventory%s" % (PROG, flags),
                "everything about every host, a column each")
    rep.tip("%s demo" % PROG, "a made-up fleet's week to learn on "
            "(docs/getting-started.md)")


def cmd_setup(cli, args):
    if getattr(args, "store_name", None):
        stores.check_name(args.store_name)
    rep = Report()
    say("%s setup -- check this machine, make a store, test the hosts"
        % PROG)
    if not at_terminal():
        say("(stdin is not a terminal: nothing is asked, and nothing that "
            "needs an answer is changed)")
    run_ns = plain(cli, args, ["run", "--", "true"], no_store=True,
                   count=1, quiet=True, preview=0)
    step_machine(cli, args, rep)
    step_store(cli, args, rep)
    hs = step_hosts(cli, args, run_ns, rep)
    step_reach(cli, args, run_ns, hs, rep)
    first_commands(cli, args, rep)
    rc = 2 if rep.refused else 1 if rep.finding else 0
    say("")
    say("  SUMMARY")
    w = max(len(k) for k, _ in rep.rows)
    for k, v in rep.rows:
        say("    %-*s  %s" % (w, k, v))
    if rc == 2:
        say("    status 2: %s" % "; ".join(rep.refused))
    elif rc == 1:
        say("    status 1: %s" % "; ".join(rep.finding))
    else:
        say("    status 0: this machine is ready, and every host answered")
    for ln in cli.next_steps(rep.tips):
        say(ln)
    return rc
