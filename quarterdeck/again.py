# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Martin J. Gallagher
"""qd again [RUN]: RUN once more, as it ran, then what changed (QD-061).

"What changed since last time?" without retyping anything: the command,
the hosts, --via, --sudo, --timeout, --name and the passes come from
RUN's own qd.runs row, and the hosts from its host file when it still
has one (read again, so a host added since is in it), else from its
qd.hosts rows, with the addresses and attributes they ran with.

Nothing here runs or compares on its own.  The new run is `qd run`,
given the Namespace build_parser() makes of the plain command (cli
cmd_run: filing, the policy, the danger guard, --store and every QD_*
variable as there); what changed is `qd diff RUN NEW` (cli.cmd_diff).
This module says what will run before it does, asks before a --sudo run
when somebody is at the terminal, and sums up which step found what.

Exit status: 0 when every host answered and nothing changed, 1 when a
host did not answer or something changed (the summary says which), 2
when RUN cannot be run again exactly, and why.
"""

import os
import shlex
import sys

from .common import PROG, QdError, die, plural, warn
from . import fleet
from . import hosts as hostmod
from . import store as storemod

# the options the record sets, which `qd again` does not take: changing
# one would not be running RUN again
RECORDED = ("via", "sudo", "timeout", "name", "every", "count", "command",
            "servers", "server", "layout", "select", "first", "rerun",
            "push", "script", "no_store", "quiet", "preview")


def refuse(ref, why):
    die("cannot run %s again: %s" % (ref, why))


def the_run(cli, args):
    """RUN, resolved, or exit 2 saying why it cannot be run again."""
    ref = args.ref
    if os.path.exists(ref):
        refuse(ref, "a file, not a run: qd again repeats a run the store "
               "keeps (latest, an id, a name)")
    st, r = cli.ref_store(args, ref)
    r, table = storemod.split_ref(r)
    if table is not None:
        refuse(ref, ":%s is one of a run's tables; qd again repeats the "
               "whole run: qd again %s" % (table, ref.replace(":" + table,
                                                              "", 1)))
    e = st.resolve(r)
    if not isinstance(e, storemod.Run):
        refuse(ref, "%s is a dataset, not a run" % cli.shown_id(e))
    why = why_not(cli, e)
    if why:
        refuse(ref, why)
    return e


def why_not(cli, e):
    """Why the run e cannot be run again, or None when it can: what qd
    run suggests `qd again` by (QD-065) is what qd again accepts."""
    m = e.meta
    kind = m.get("kind")
    sid = cli.shown_id(e)
    if kind == "do":
        return ("%s is a qd do run, which ran a tool here: run it again "
                "with `qd do -- %s`, then `qd diff %s latest`"
                % (sid, m.get("command", "TOOL ..."), sid))
    if kind == "import":
        return ("%s is a qd import: nothing ran, so there is nothing to "
                "run again" % sid)
    if kind != "run":
        return ("%s is a qd %s, not a run on the fleet"
                % (sid, kind or "entry"))
    if m.get("factors"):
        return ("%s is a design point of %s: qd doe run %s runs the "
                "design's points" % (sid, m.get("group", "a design"),
                                      m.get("group", "DESIGN")))
    if m.get("part") or m.get("group"):
        return ("%s is part %s of campaign %s: qd campaign retry %s %s "
                "runs a part again" % (sid, m.get("part", "?"),
                                       m.get("group", "?"),
                                       m.get("group", "NAME"),
                                       m.get("part", "PART")))
    if m.get("tool") == "probe":
        return ("%s is a probe: qd probe %s asks it again, and qd diff "
                "latest then compares it with this one"
                % (sid, m.get("name", "NAME")))
    if not m.get("timeout_s"):
        return ("%s's record does not keep its --timeout (it was filed "
                "before qd 0.40.0, or not by qd run): run it again with qd "
                "run, then qd diff %s latest" % (sid, sid))
    if str(m.get("pushed") or "0") != "0":
        return ("%s pushed files (--push, --script), which the store "
                "does not keep: qd run --push ... again, then qd diff %s "
                "latest" % (sid, sid))
    if not (m.get("command") or "").strip():
        return ("%s's record keeps no command" % sid)
    try:
        float(m["timeout_s"])
    except ValueError:
        return ("%s's record has a timeout of %r, not a number of "
                "seconds" % (sid, m["timeout_s"]))
    return None


def hosts_of(cli, e):
    """(hosts, files, why): RUN's hosts, the host files they were read
    from (still there) or [], and a word on where they came from."""
    files = [f for f in (e.meta.get("host_list") or "").split("\n") if f]
    if files and all(os.path.isfile(f) for f in files):
        hs = hostmod.collect_hosts(servers=files)
        return hs, files, "from %s" % ", ".join(
            storemod.tilde(f) for f in files)
    hs = [h for h, _ in cli.last_pass_hosts(e)]
    if not hs:
        die("cannot run %s again: its record keeps no hosts" % e.id)
    gone = [f for f in files if not os.path.isfile(f)]
    why = "the ones %s ran on" % e.id
    if gone:
        why += " (%s %s gone)" % (", ".join(storemod.tilde(f)
                                            for f in gone),
                                  "is" if len(gone) == 1 else "are")
    return hs, [], why


def run_argv(e, hs, files, timeout):
    """The plain `qd run` command RUN's record makes, as a word list; and
    whether it is whole (its hosts are on it: a host file, or a short
    list of names that need nothing else)."""
    m = e.meta
    argv = ["run"]
    whole = True
    if files:
        for f in files:
            argv += ["-s", f]
    elif len(hs) <= 12 and all(not h.attrs for h in hs):
        argv += ["-S", ",".join(h.token(plain=True) for h in hs)]
    else:
        whole = False
    via = m.get("via") or "ssh"
    if via != "ssh":
        argv += ["--via", via]
    if m.get("sudo") == "yes":
        argv.append("--sudo")
    argv += ["--timeout", "%g" % timeout]
    passes = int(m.get("passes") or 1)
    every = m.get("every")
    if every:
        argv += ["--every", "%g" % float(every)]
    if passes != 1 or every:
        argv += ["--count", str(passes)]
    command = m["command"]
    words = command.split()
    default = os.path.basename(words[0]) if words else "run"
    if m.get("name") and m["name"] != default:
        argv += ["--name", m["name"]]
    argv += ["--", command]
    return argv, whole


def shown(argv):
    return " ".join([PROG] + [shlex.quote(a) for a in argv])


def confirm_sudo(n):
    """--sudo, at a terminal: ask first.  With nothing attached to stdin,
    never ask: the command says what it runs, and runs it."""
    if not hostmod.stdin_is_tty():
        return
    sys.stderr.write("%s: run this as root (sudo) on %s? [y/N] "
                     % (PROG, plural(n, "host")))
    sys.stderr.flush()
    try:
        answer = sys.stdin.readline()
    except (IOError, OSError, KeyboardInterrupt):
        answer = ""
    if answer.strip().lower() not in ("y", "yes"):
        die("not confirmed: nothing was run")


def cmd_again(cli, args):
    old = the_run(cli, args)
    m = old.meta
    oid = cli.shown_id(old)
    hs, files, where = hosts_of(cli, old)
    timeout = float(m["timeout_s"])
    argv, whole = run_argv(old, hs, files, timeout)
    parser, _ = cli.build_parser()
    rargs = parser.parse_args(argv)
    for k, v in vars(args).items():
        if k in ("verb", "fn", "ref") or k in RECORDED:
            continue
        if hasattr(rargs, k) or k.startswith("_"):
            setattr(rargs, k, v)
    if rargs.count is None:     # as main() leaves it for qd run
        rargs.count = 0 if rargs.every else 1
    rargs.quiet = True
    rargs.preview = 0
    if not files:
        # the hosts it ran on, as they ran: a host file is read again by
        # qd run itself, so the new run records it too
        rargs._hosts_given = hs
    rargs._argv = list(argv)
    via = m.get("via") or "ssh"
    passes = int(m.get("passes") or 1)
    lines = ["%s again -- %s: %s" % (PROG, oid, m["command"]),
             "  hosts    %s, %s" % (plural(len(hs), "host"), where),
             "  as       via %s, %s, timeout %gs%s%s" % (
                 via, "under sudo" if m.get("sudo") == "yes" else "no sudo",
                 timeout, (", %d passes" % passes) if passes > 1 else "",
                 (" every %gs" % float(m["every"])) if m.get("every")
                 else ""),
             "  name     %s" % m.get("name", "")]
    if whole:
        lines.append("  runs     %s" % shown(argv))
    lines.append("")
    sys.stdout.write("\n".join(lines) + "\n")
    sys.stdout.flush()
    if m.get("sudo") == "yes" and not args.yes and not args.dry_run:
        confirm_sudo(len(hs))
    run_rc = cli.cmd_run(rargs)
    job = getattr(rargs, "_job", None)
    if job is None:
        return run_rc          # --dry-run: nothing ran, nothing to compare
    new = job.entry
    bad = [r for r in job.last if r.outcome != fleet.OK]
    sys.stdout.write("\n")
    dargs = parser.parse_args(["diff", oid, new.id])
    # its own stores, opened now: the ones read before hold no new run
    for k in ("store", "width", "no_fetch"):
        if k in vars(args):
            setattr(dargs, k, getattr(args, k))
    diff_rc, diff_err = 2, None
    try:
        diff_rc = cli.cmd_diff(dargs)
    except QdError as exc:
        diff_err = str(exc)
        warn(diff_err)
    sys.stdout.write("\n".join(summary(oid, new.id, job, bad, diff_rc,
                                       diff_err)) + "\n")
    sys.stdout.write("\n".join(cli.next_steps(tips(
        oid, new.id, m["command"], bad, argv, whole))) + "\n")
    if diff_err is not None:
        return 2
    return 1 if (bad or job.stopped or diff_rc) else 0


def summary(oid, nid, job, bad, diff_rc, diff_err):
    names = [r.host.name for r in bad]
    found = []
    if bad:
        found.append("the run: %s did not answer (%s%s)" % (
            plural(len(bad), "host"), ", ".join(names[:8]),
            " and %d more" % (len(names) - 8) if len(names) > 8 else ""))
    if job.stopped:
        found.append("the run: stopped, %s" % job.stopped)
    if diff_err is not None:
        found.append("the diff: could not be made (%s)" % diff_err)
    elif diff_rc:
        found.append("the diff: %s and %s differ (above)" % (oid, nid))
    lines = ["", "%s again -- %s -> %s" % (PROG, oid, nid)]
    if found:
        for f in found:
            lines.append("  FOUND    %s" % f)
    else:
        lines.append("  same     every host answered, and nothing changed")
    return lines


def tips(oid, nid, command, bad, argv, whole):
    t = [("%s diff %s %s" % (PROG, oid, nid),
          "what changed, again (--format csv for the table)")]
    if bad:
        t.append(("%s show %s --where status!=ok" % (PROG, nid),
                  "the %s that did not answer, with why"
                  % plural(len(bad), "host")))
        t.append(("%s run --rerun %s -- %s" % (PROG, nid,
                                               shlex.quote(command)),
                  "the same again on only those hosts"))
    if whole:
        t.append((shown(argv), "the run on its own, as qd again ran it"))
    t.append(("%s log %s" % (PROG, nid), "the new run: what ran, where, "
              "how it went"))
    t.append(("%s again %s" % (PROG, nid), "once more, later"))
    return t
