# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Martin J. Gallagher
"""qd demo: a week of a small fleet's runs, to learn qd on with no fleet.

`qd demo` files a store named `demo`: 24 made-up hosts in two racks and
two SKUs, asked three things over a week -- why-slow's readings every
morning, `uname -r`, a throughput test -- with something planted in each
for qd's read side to find: a host that did not answer, one kernel that
disagrees, one host whose free memory slides day by day, and one slow
host that fails a requirement in limits.csv.  docs/getting-started.md
walks through it, one question at a time.

Nothing runs.  Every host's name starts `demo-`, and what each one says
is a text file beside this module (quarterdeck/demo/), which a stand-in
launcher, DemoRunner, reads back in place of ssh.  What it answers goes
through the same code as `qd run` -- cli.fleet_run: the same fan-out, the
same qd.runs and qd.hosts rows, and provost filing every answer -- so the
store is a store like any other, in the current format.  The demo only
supplies answers, as a fleet would, and the time each run is filed as
having started (plan.tsv), so its runs are a week apart and its run ids
are the same on every machine.

The stand-in is no --via choice, and no flag or variable selects it:
only this module hands it to fleet_run.  It runs nothing, answers only
from its files, and only for the demo's own hosts.
"""

import calendar
import io
import os
import re
import shutil
import sys
import time

from .common import PROG, QdError, die, plural
from . import fleet, filing, stores
from . import hosts as hostmod
from . import store as storemod

# the store qd demo files into, by name
NAME = "demo"
# where the demo's hosts, plan, answers and limits are: package data
DATA = os.path.join(os.path.dirname(os.path.abspath(__file__)), "demo")
# the walkthrough, for a qd installed with no clone beside it
GUIDE = ("https://github.com/MartinGallagher-code/quarterdeck/blob/main/"
         "docs/getting-started.md")
# what the qd.runs rows say ran them: nobody, on no machine
OPERATOR = "demo"
# a host's section in an answers file: ==> NAME STATUS SECONDS <==
HEAD_RE = re.compile(r"^==> (\S+) (ok|unreachable|failed:\d+) "
                     r"([0-9]+(?:\.[0-9]+)?) <==$")


def data(name):
    return os.path.join(DATA, name)


def read(name):
    with io.open(data(name), encoding="utf-8") as fh:
        return fh.read()


def epoch(text):
    """2026-11-09T08:00:00Z -> seconds since the epoch."""
    return calendar.timegm(time.strptime(text, "%Y-%m-%dT%H:%M:%SZ"))


def read_plan():
    """plan.tsv: [(at, name, answers file, command)], in filing order."""
    rows, head = [], None
    for ln in read("plan.tsv").splitlines():
        if not ln.strip() or ln.startswith("#"):
            continue
        cells = ln.split("\t")
        if head is None:
            head = cells
            continue
        d = dict(zip(head, cells))
        rows.append((epoch(d["at"]), d["name"], d["answers"], d["command"]))
    return rows


class Answer(object):
    __slots__ = ("status", "seconds", "text")

    def __init__(self, status, seconds, text):
        self.status, self.seconds, self.text = status, seconds, text


def read_answers(name):
    """An answers file: {host: Answer}.  Lines before the first section
    are its comment; a section's text is everything up to the next one,
    ending in one newline."""
    out, host, lines = {}, None, []

    def done():
        if host is not None:
            text = "\n".join(lines).rstrip("\n")
            out[host] = Answer(status, seconds, text + "\n" if text else "")

    status = seconds = None
    for ln in read(name).split("\n"):
        m = HEAD_RE.match(ln)
        if m:
            done()
            host, status, seconds = m.group(1), m.group(2), float(m.group(3))
            lines = []
        elif host is not None:
            lines.append(ln)
    done()
    return out


class DemoRunner(fleet.Runner):
    """The demo's launcher: each host's answer from its answers file, as
    ssh would have brought it back -- stdout and exit 0, or ssh's own
    complaint and 255 for a host that did not answer -- started a few
    milliseconds apart from the run's time, taking the seconds the file
    gives.  It runs nothing, here or anywhere."""

    via = "demo"

    def __init__(self, answers, at):
        fleet.Runner.__init__(self)
        self.answers = answers
        self.at = at
        self.order = {}

    def needs(self, pushing, stdin=False):
        return []

    def check_hosts(self, hosts):
        for i, h in enumerate(hosts):
            if h.name not in self.answers:
                return ("%s is not one of the demo's hosts: qd demo answers "
                        "only for its own" % h.name)
            self.order[h.name] = i
        return None

    def run_fields(self):
        return {"via": self.via}

    def run_one(self, host, command, push=None, cleanup=True, pass_no=1,
                stdin=None):
        a = self.answers[host.name]
        r = fleet.Result(host, pass_no)
        r.started = self.at + 0.01 * self.order.get(host.name, 0)
        r.duration = a.seconds
        if a.status == "ok":
            r.outcome, r.rc, r.stdout = fleet.OK, 0, a.text
        elif a.status == "unreachable":
            r.outcome, r.rc, r.stderr = fleet.UNREACHABLE, 255, a.text
        else:
            r.outcome, r.rc = fleet.FAILED, int(a.status.split(":")[1])
            r.stderr = a.text
        return r


def run_args(cli):
    """What fleet_run is given for each of the demo's runs: `qd run
    --store demo` as the parser makes it, with everything a shell's QD_*
    variables could set for a fleet put back to what a plain `qd run`
    does -- one pass, no retries, no --max-fail, no pacing, no allow-list
    -- since nothing here goes near one."""
    from . import policy as policymod
    parser, _ = cli.build_parser()
    args = parser.parse_args(["run", "--store", NAME])
    args.count, args.every = 1, None
    args.max_fail, args.max_fail_on = None, "any"
    args.retries, args.retry_delay, args.retry_failed = 0, 0.0, False
    args.rate, args.jobs, args.user, args.sudo = None, 32, None, False
    args.keep_preamble = args.keep_remote = args.dry_run = False
    args.no_store = False
    args._policy = policymod.Policy()
    return args


def is_demo(path):
    """Whether `path` is a demo qd made, and so qd demo's to delete: a
    store every run of which DemoRunner answered, and every dataset of
    which is a demo run's or qd's own -- or nothing at all (no directory,
    or an empty one).  Anything else is somebody's, and left alone."""
    if not os.path.exists(path):
        return True
    if os.path.isdir(path) and not os.listdir(path):
        return True
    if not stores.is_store(path):
        return False
    try:
        st = storemod.Store(path)
        rows = st.run_rows()
        names = st.dataset_names()
    except (QdError, OSError):
        return False
    return all(r.get("via") == DemoRunner.via for r in rows) and all(
        n.startswith("demo-") or n.startswith("qd.") for n in names)


def remove(cfg, path):
    """Delete the demo's store and forget its name: a half-built one, or
    one --rebuild replaces."""
    if os.path.isdir(path):
        lock, owner = stores.hold_lock(path, "delete it")
        try:
            shutil.rmtree(path)
        except OSError as exc:
            stores.let_go(lock, owner)
            die("could not delete all of %s: %s" % (storemod.tilde(path),
                                                    exc))
    if cfg["stores"].get(NAME) == path:
        del cfg["stores"][NAME]
        stores.save(cfg)


def build(cli, path):
    """File every run in plan.tsv into the store at `path`, in order."""
    st = storemod.Store(path)
    # ids a demo built before claimed in qd's cache: that store is gone
    shutil.rmtree(cli.id_claims(st), ignore_errors=True)
    hs = hostmod.collect_hosts(servers=[data("hosts.txt")])
    extra = {"operator": OPERATOR, "operator_host": "", "cwd": ""}
    plan = read_plan()
    for k, (at, name, answers, command) in enumerate(plan, 1):
        if sys.stderr.isatty():
            sys.stderr.write("\r\033[K%s demo: filing %s of %s, %s ..." % (
                PROG, name, time.strftime("%a %Y-%m-%d %H:%M", time.gmtime(
                    at)), "%d of %d" % (k, len(plan))))
            sys.stderr.flush()
        runner = DemoRunner(read_answers(answers), at)
        cli.fleet_run(run_args(cli), hs, command, name, extra=dict(extra),
                      runner=runner, at=at)
    if sys.stderr.isatty():
        sys.stderr.write("\r\033[K")


def summary(cli, path, made):
    """The store's runs, and where to go next."""
    from . import render
    st = storemod.Store(path)
    entries = st.entries()
    hosts = sorted(read_answers(read_plan()[0][2]))
    lines = ["%s demo -- %s: a made-up fleet's week, %s of %s" % (
        PROG, "filed the store %s" % NAME if made else
        "the store %s is there already" % NAME,
        plural(len(entries), "run"), plural(len(hosts), "host")),
        "  in %s" % storemod.tilde(path), ""]
    rows = []
    for e in entries:
        h = e.meta.get("hosts") or {}
        rows.append([e.id, str(h.get("total", "")), str(h.get("ok", 0)),
                     e.meta.get("command", "")])
    lines.extend(render.render_rows(["run", "hosts", "ok", "command"], rows,
                                    numeric=[1, 2], max_cell=48,
                                    indent="  "))
    lines.append("")
    lines.append("  Nothing ran: the hosts are made up (%s .. %s), and every "
                 "answer came with qd," % (hosts[0], hosts[-1]))
    lines.append("  filed through provost as a real run's answers are.")
    if not made:
        planned = len(read_plan())
        if len(entries) != planned:
            lines.append("  It holds %d of the demo's %d runs: it was not "
                         "filed to the end." % (len(entries), planned))
        lines.append("  %s demo --rebuild files it again; %s store rm %s "
                     "--delete removes it." % (PROG, PROG, NAME))
    lines.extend(cli.next_steps([
        ("%s store use %s" % (PROG, NAME),
         "read the demo from here on (qd store ls: the others)"),
        ("%s log" % PROG, "the runs it holds, oldest first"),
        ("%s freq demo-kernel A" % PROG,
         "who runs which kernel (A: uname -r's answer)"),
        ("", "the walkthrough, ten minutes, a question a step: "
         "docs/getting-started.md,\n      " + GUIDE)]))
    sys.stdout.write(render.page(lines))


def cmd_demo(cli, args):
    if args.limits:
        sys.stdout.write(read("limits.csv"))
        return 0
    cfg = stores.load()
    path = cfg["stores"].get(NAME)
    if path is not None and not is_demo(path):
        die("there is a store named %s that is not qd's demo (%s): it is "
            "left as it is.  qd store rename %s OTHER, then qd demo"
            % (NAME, storemod.tilde(path), NAME))
    if path is not None and not args.rebuild:
        if not stores.is_store(path):
            die("the store %s is registered, but holds no demo (%s): qd "
                "demo --rebuild files it" % (NAME, storemod.tilde(path)))
        summary(cli, path, made=False)
        return 0
    home = os.path.join(stores.data_root(), NAME)
    # before anything is deleted: a rebuild with no provost would only
    # take the demo away
    filing.Provost(storemod.Store(home)).require("file the demo")
    if path is not None:
        remove(cfg, path)
    path = home
    if not is_demo(path):
        die("%s holds files that are not qd's demo: nothing deleted, and "
            "no demo filed" % storemod.tilde(path))
    remove(cfg, path)
    try:
        os.makedirs(path, exist_ok=True)
    except OSError as exc:
        die("cannot make %s: %s" % (path, exc))
    cfg = stores.load()
    cfg["stores"][NAME] = path
    stores.save(cfg)
    try:
        build(cli, path)
    except BaseException:
        # a demo is all of it or nothing: a half-filed one would read
        # back as a week with days missing
        remove(stores.load(), path)
        raise
    summary(cli, path, made=True)
    return 0
