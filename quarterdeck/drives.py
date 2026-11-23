# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Martin J. Gallagher
"""Every drive on every host (QD-073): a design point run on each drive.

A host line names its drives with two attributes:

    node01 drives=/srv/nvme0/qd-fio.dat,/srv/nvme1/qd-fio.dat drive_model=PM9A3
    node02 drives=/srv/nvme0/qd-fio.dat drive_model=PM9A3

`drives` lists the file the command writes on each drive (a file on the
drive's filesystem, not the raw device: fio writing /dev/... destroys what
is on it, and qd's guard refuses that without --yes, as it always has);
`drive_model` is one model for all of a host's drives, or a list in the
same order.  `{drive}` in a design's command is each drive's file
(`fio --filename={drive} ...`).

Each drive is a target: the host, with `drive=FILE` and `drive_model=MODEL`
in place of the two lists, so both ride into every row as columns the way
any host attribute does.  A design point runs once on every target: one
drive at a time on each host by default (the drive's own bottleneck is the
one measured), the hosts side by side; `--drives-together` starts all of a
host's drives at once, for the bottlenecks a host's drives share (PCIe
lanes, the controller, CPU threads).

The analysis reads the rows per group (`--per`): each drive, each drive
model (the default when drives are named), each host, or the fleet as one.
`--block host|drive` makes each host's (or drive's) value at a point an
observation of its own, in a block of its own, so doe's ANOVA takes the
differences between them out as a Block term.  The manual says it at
more length, docs/larger-jobs.md: "Every drive on every host: `drives=` and `{drive}`"
"""

import re

from .common import die, warn
from . import hosts as hostmod

DRIVES = "drives"          # the host attribute: a file per drive
MODEL = "drive_model"      # one model, or one per drive
DRIVE = "drive"            # a target's own attribute, and its rows' column
PLACEHOLDER = "drive"      # {drive} in a design's command
PERS = ("drive", "model", "host", "fleet")
BLOCKS = ("host", "drive")
TOGETHER, EACH = "together", "each"
# a drive's file goes into the command as written: letters, digits and
# @%+=:./-_ only, so it can be neither two words nor a shell's to expand
SAFE = re.compile(r"^[A-Za-z0-9_@%+=:./-]+$")
NAME_RE = re.compile(r"\{([A-Za-z_][A-Za-z0-9_.-]*)\}")    # doe.FACTOR_RE


def drives_of(host):
    """[(file, model or "")]: the drives a host line names; [] for none."""
    attrs = dict(host.attrs)
    text = attrs.get(DRIVES, "")
    if not text.strip():
        if attrs.get(MODEL):
            die("%s has %s=%s but no %s=: name the file the command writes "
                "on each drive (%s=/srv/nvme0/qd-fio.dat,...)" % (
                    host.name, MODEL, attrs[MODEL], DRIVES, DRIVES))
        return []
    files = [f.strip() for f in text.split(",")]
    if any(not f for f in files):
        die("%s: %s=%s has an empty entry (a file per drive, joined by "
            "commas)" % (host.name, DRIVES, text))
    bad = [f for f in files if not SAFE.match(f)]
    if bad:
        die("%s: the drive file %s has characters a command cannot take as "
            "they are (letters, digits and @%%+=:./-_ only)"
            % (host.name, bad[0]))
    seen = set()
    for f in files:
        if f in seen:
            die("%s names the drive %s twice in %s=" % (host.name, f, DRIVES))
        seen.add(f)
    models = [m.strip() for m in attrs.get(MODEL, "").split(",")] \
        if attrs.get(MODEL, "").strip() else []
    if len(models) == 1:
        models = models * len(files)
    elif models and len(models) != len(files):
        die("%s names %d drives and %d drive models: give one %s for all of "
            "them, or one per drive in the same order" % (
                host.name, len(files), len(models), MODEL))
    if not models:
        models = [""] * len(files)
    return list(zip(files, models))


def named(hosts):
    """Whether any host names its drives."""
    return any(drives_of(h) for h in hosts)


def targets(hosts):
    """Each drive of each host as a host of its own: the same name and
    address, its attributes less the two lists, plus drive= and (when one
    is known) drive_model=.  A host naming no drives is itself."""
    out = []
    for h in hosts:
        ds = drives_of(h)
        if not ds:
            out.append(h)
            continue
        rest = [(k, v) for k, v in h.attrs if k not in (DRIVES, MODEL)]
        for f, m in ds:
            out.append(hostmod.Host(h.name, h.addr, h.port, rest + [
                (DRIVE, f)] + ([(MODEL, m)] if m else [])))
    return out


def drive_of(target):
    return dict(target.attrs).get(DRIVE, "")


def model_of(target):
    return dict(target.attrs).get(MODEL, "")


def by_host(ts):
    """[(host name, [its targets])], in the order the hosts first come."""
    order, out = [], {}
    for t in ts:
        if t.name not in out:
            order.append(t.name)
            out[t.name] = []
        out[t.name].append(t)
    return [(n, out[n]) for n in order]


def slots(ts):
    """One drive at a time: [[the k-th drive of every host that has one]],
    k from the first -- each slot a run, its hosts side by side."""
    hs = [g for _, g in by_host(ts)]
    n = max([len(g) for g in hs] or [0])
    return [[g[k] for g in hs if k < len(g)] for k in range(n)]


def uses(template):
    """Whether a command names {drive}."""
    return PLACEHOLDER in NAME_RE.findall(template or "")


def fill(command, target):
    """{drive} in a command, as this target's file."""
    return command.replace("{%s}" % PLACEHOLDER, drive_of(target))


def check(hosts, template, factors=()):
    """Refuse a command and a host list that do not agree about drives: a
    {drive} with no drives named, or some hosts naming drives and others
    none.  Drives named with no {drive} to put them in are said, and the
    command runs once a host, as it did before drives."""
    if PLACEHOLDER in factors:
        if uses(template) and named(hosts):
            die("the design has a factor named drive, and the hosts name "
                "their drives (drives=): {drive} is each drive's file, so "
                "call the factor something else")
        return
    if not uses(template):
        has = [h.name for h in hosts if dict(h.attrs).get(DRIVES, "").strip()]
        if has:
            warn("%s name%s drives (%s=), but the command has no {drive}: "
                 "each host runs it once. Put {drive} where the command "
                 "names its file (fio --filename={drive} ...) to run it on "
                 "every drive" % (
                     ", ".join(has[:3]) + (" and %d more" % (len(has) - 3)
                                           if len(has) > 3 else ""),
                     "s" if len(has) == 1 else "", DRIVES))
        return
    has = [h.name for h in hosts if drives_of(h)]
    if not has:
        die("the command names {drive}, but no host names its drives: "
            "add %s=FILE[,FILE...] to each host line (the file the "
            "command writes on each drive)" % DRIVES)
    bare = [h.name for h in hosts if not drives_of(h)]
    if bare:
        die("the command names {drive}, and %s name%s no drives: every "
            "host needs %s=FILE[,FILE...]" % (
                ", ".join(bare), "s" if len(bare) == 1 else "", DRIVES))


# ---------------------------------------------------------------------------
# Groups: --per, --group, --block
# ---------------------------------------------------------------------------

def target_label(host, drive):
    return "%s:%s" % (host, drive) if drive else host


def key(per, host, drive, model):
    """The group a row (or target) falls in, as --group names it."""
    if per == "fleet":
        return "fleet"
    if per == "host":
        return host
    one = target_label(host, drive)
    if per == "drive":
        return one
    return model or one


def unit(block, host, drive):
    """What a row is an observation of, under --block."""
    return host if block == "host" else target_label(host, drive)


class Selection(object):
    """Which rows an analysis reads, and how: --per (what a group is),
    --group (one of them; None, every row), --block (each host's or drive's
    value an observation of its own, in its own block)."""

    def __init__(self, per="fleet", group=None, block=None):
        if per not in PERS:
            die("--per wants one of %s, not %r" % (", ".join(PERS), per))
        if block is not None and block not in BLOCKS:
            die("--block wants host or drive, not %r" % block)
        if block == "host" and per in ("host", "drive"):
            die("--block host with --per %s: a %s is on one host, so there "
                "is nothing to block" % (per, per))
        if block == "drive" and per == "drive":
            die("--block drive with --per drive: each group is one drive, "
                "so there is nothing to block")
        self.per, self.group, self.block = per, group, block

    def key(self, host, drive, model):
        return key(self.per, host, drive, model)

    def wants(self, host, drive, model):
        return self.group is None or \
            self.key(host, drive, model) == self.group

    def wants_target(self, t):
        return self.wants(t.name, drive_of(t), model_of(t))

    def unit(self, host, drive):
        return unit(self.block, host, drive)

    def pooled(self):
        """Every row, one value a point: the analysis as it was before
        drives (--per fleet, no --block)."""
        return self.group is None and self.block is None

    def meta(self):
        out = {"per": self.per}
        if self.group is not None:
            out["group"] = self.group
        if self.block:
            out["block"] = self.block
        return out

    def words(self):
        """How a heading says which rows: 'model PM9A3', 'the fleet'."""
        if self.per == "fleet" or self.group is None:
            text = "every host and drive"
        else:
            text = "%s %s" % (self.per, self.group)
        if self.block:
            text += ", each %s a block" % self.block
        return text

    def __eq__(self, other):
        return isinstance(other, Selection) and \
            (self.per, self.group, self.block) == \
            (other.per, other.group, other.block)

    def __ne__(self, other):
        return not self == other

    def __repr__(self):
        return "Selection(%r, %r, %r)" % (self.per, self.group, self.block)


def from_meta(meta):
    """A Selection from a design's metadata.qd_group, or None."""
    if not isinstance(meta, dict) or not meta.get("per"):
        return None
    return Selection(meta.get("per"), meta.get("group"), meta.get("block"))


# ---------------------------------------------------------------------------
# Running: each target its own command, a host's drives one task
# ---------------------------------------------------------------------------

class PerDrive(object):
    """A runner that gives each drive target its own command ({drive} as
    its file), and everything else to the runner it wraps.  With together
    ({host name: [targets]}), a host is one task: run_one(host) starts all
    its drives at once and answers with a Together, so --jobs, --rate and
    --max-fail count hosts, and a host's drives are never split.  One call
    for every host (pdsh, clush) cannot give each its own command, so it
    goes host by host."""

    batched = False

    def __init__(self, inner, together=None):
        self.inner = inner
        self.together = together

    def __getattr__(self, name):
        return getattr(self.inner, name)

    def run_one(self, host, command, push=None, cleanup=True, pass_no=1,
                stdin=None):
        if not self.together:
            return self.inner.run_one(host, fill(command, host), push,
                                      cleanup, pass_no, stdin)
        import threading
        ts = self.together.get(host.name) or [host]
        out = [None] * len(ts)

        def one(i):
            out[i] = self.inner.run_one(ts[i], fill(command, ts[i]), push,
                                        cleanup, pass_no, stdin)
        threads = [threading.Thread(target=one, args=(i,))
                   for i in range(len(ts))]
        for t in threads:
            t.daemon = True
            t.start()
        for t in threads:
            t.join()
        return Together(host, pass_no, out)


def _together_base():
    from . import fleet
    return fleet.Result


class Together(_together_base()):
    """A host's drives, run at once: one answer for the fan-out to count
    (its worst outcome), the drives' own answers in parts."""

    def __init__(self, host, pass_no, parts):
        from . import fleet
        fleet.Result.__init__(self, host, pass_no)
        self.parts = parts
        bad = [p for p in parts if p.outcome != fleet.OK]
        first = bad[0] if bad else (parts[0] if parts else None)
        if first is not None:
            self.outcome, self.rc = first.outcome, first.rc
            self.stderr, self.preamble = first.stderr, first.preamble
        starts = [p.started for p in parts if p.started is not None]
        self.started = min(starts) if starts else None
        ends = [p.started + p.duration for p in parts
                if p.started is not None and p.duration is not None]
        self.duration = (max(ends) - self.started) if ends and starts \
            else None
        self.left_running = any(p.left_running for p in parts)


def flatten(results, together):
    """A drive's answer a result, from the hosts' Together answers; a host
    not run at all (--max-fail, Ctrl-C) a not-run row for each drive.  A
    host --retries tried again keeps each try of each drive."""
    from . import fleet
    out = []
    for r in results:
        ts = together.get(r.host.name) or []
        if isinstance(r, Together):
            tries = [x for x in r.earlier if isinstance(x, Together)]
            for i, p in enumerate(r.parts):
                p.pass_no, p.attempt = r.pass_no, r.attempt
                earlier = []
                for x in tries:
                    if i < len(x.parts):
                        e = x.parts[i]
                        e.pass_no, e.attempt = x.pass_no, x.attempt
                        earlier.append(e)
                p.earlier = earlier
                out.append(p)
        elif ts:
            for t in ts:
                nr = fleet.not_run(t, r.pass_no)
                nr.stderr = r.stderr
                out.append(nr)
        else:
            out.append(r)
    return out
