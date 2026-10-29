# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Martin J. Gallagher
"""qd -- run it everywhere, keep what came back, read it any way you like.

Usage: qd run [HOSTS] [OPTIONS] -- COMMAND     on every host -> a dataset
       qd do  [OPTIONS] -- TOOL ARGS...        mx, iperf, agree, reckon, ...
       qd import PATH...                       output already on disk
       qd log [RUN]                            what the store holds
       qd view [RUN]                           full-screen explorer
       qd show|stats|freq|hist|outliers|pivot|trend RUN ...
       qd diff [OLD] NEW                       what changed between two
       qd export RUN [--format overlay]        CSV, JSON, the viewer's TSV
       qd web                                  the store in a browser
       qd floor RUN --layout   floor.dc        paint it on the floor plan
       qd hosts | doctor | hints | help

Examples:
  qd run --servers hosts.txt -- uname -r
  qd run -S 'node[01-24]' -- 'sysctl net.core.somaxconn vm.swappiness'
  qd run --layout floor.dc --select 'rack[1-3]' -- cat /proc/loadavg
  qd do -- mx run --for 60
  qd do -- agree script why-slow --servers hosts.txt --fleet-csv -- --csv
  qd stats latest A --by rack           qd freq latest A
  qd outliers latest mbps               qd diff latest
  qd view latest                        qd web

RUN is latest, latest~1, a run id or a unique part of one, a run's
--name, ds:NAME for a whole provost dataset, or a file or directory to read
without filing it.  Add :TABLE to pick one of a run's tables (latest:hosts).

Everything is kept in provost's store (provost ls, provost source cNNNN):
--store, QD_STORE, else provost's own choice.

Exit status
  0   done, and every host answered
  1   a finding: a host that did not answer, a diff that differs
  2   usage error, or something could not be read or written

Full manual: https://github.com/MartinGallagher-code/quarterdeck#readme
"""

import argparse
import os
import re
import shlex
import subprocess
import sys
import tempfile
import time

from . import VERSION
from .common import (PROG, VERSION_TEXT, QdError, _stdio_safe, die, env,
                     env_float, env_int, plural, warn, write_text)
from . import diff as diffmod
from . import filing, fleet, hosts as hostmod, importers, query
from . import render, stats, store as storemod, table as tablemod, tools
from .store import describe_entry, load_ref, now_iso, split_ref

# ---------------------------------------------------------------------------
# Safety: the same typo guard as agree's, for the same 3am reason
# ---------------------------------------------------------------------------
#
# canonical copy: binnacle/agree.py DANGER.  A typo guard, not security:
# --yes defeats it and so does quoting cleverness.

DANGER = [
    (r"\brm\s+(-\w+\s+)*-\w*[rf]", "rm -rf"),
    (r"\bmkfs(\.\w+)?\b", "mkfs"),
    (r"\bdd\b.*\bof=", "dd of="),
    (r">\s*/dev/[sh]d[a-z]", "writing to a raw disk"),
    (r"\b(shutdown|reboot|halt|poweroff)\b", "shutdown/reboot"),
    (r"\bsystemctl\s+(stop|restart|disable|mask)\b", "systemctl stop/restart"),
    (r"\b(apt|apt-get|yum|dnf|zypper)\b.*\b(remove|purge|erase)\b",
     "package removal"),
    (r"\buserdel\b|\bgroupdel\b", "user deletion"),
    (r"\bchmod\s+-R\b|\bchown\s+-R\b", "recursive chmod/chown"),
    (r"\btruncate\b", "truncate"),
    (r":\(\)\s*\{", "fork bomb"),
    (r"\biptables\s+-F\b|\bnft\s+flush\b", "firewall flush"),
]


def check_danger(command, yes):
    for pat, label in DANGER:
        if re.search(pat, command):
            if yes:
                return
            extra = ""
            if not hostmod.stdin_is_tty():
                extra = ("  (nothing is attached to this terminal, so there "
                         "is nobody to confirm)")
            die("refusing to run this on a fleet: it looks like %s.%s\n"
                "  If you meant it, add --yes:\n    %s run --yes ... -- %s"
                % (label, extra, PROG, command))


# ---------------------------------------------------------------------------
# Small shared pieces
# ---------------------------------------------------------------------------

def out(text=""):
    sys.stdout.write(text + "\n")


def store_of(args):
    return storemod.Store(getattr(args, "store", None))


def manifest_argv():
    return tools.find_tool("manifest")


def collect(args):
    return hostmod.collect_hosts(
        servers=args.servers, inline=args.server, layout=args.layout,
        selectors=args.select, first=args.first,
        manifest_argv=manifest_argv() if args.layout else None)


def strip_dashes(cmd):
    return cmd[1:] if cmd and cmd[0] == "--" else cmd


def subset(args, t):
    """The rows --where keeps, in --sort order, as a table."""
    rows = query.where(t, getattr(args, "where", None))
    if getattr(args, "sort", None):
        rows = query.sort_rows(t, rows, args.sort)
    s = t.derive(rows=rows)
    if getattr(args, "cols", None):
        s = s.derive(columns=[c.strip() for c in args.cols.split(",")
                              if c.strip()])
    return s


def scope(args, t, s):
    """What a report says about which rows it read."""
    bits = []
    if getattr(args, "where", None):
        bits.append("where " + " and ".join(args.where))
    if len(s.rows) != len(t.rows):
        bits.append("%d of %d rows" % (len(s.rows), len(t.rows)))
    else:
        bits.append(plural(len(t.rows), "row"))
    return ", ".join(bits)


def source_name(t):
    e = getattr(t, "entry", None)
    if e is not None:
        return "%s:%s" % (e.id, t.name) if len(e.tables) > 1 else e.id
    return t.source or t.name


def emit(args, t, text_lines):
    """Write a result as the format asked for: text for people, or the
    tidy table behind it for whatever comes next."""
    fmt = getattr(args, "format", None) or "text"
    dest = getattr(args, "output", None) or "-"
    if fmt == "text":
        write_text(dest, render.page(text_lines))
        return
    if fmt not in tablemod.WRITERS:
        die("unknown --format %r (want text, %s)"
            % (fmt, ", ".join(sorted(tablemod.WRITERS))))
    write_text(dest, tablemod.WRITERS[fmt](t))


def width_of(args):
    return render.terminal_width(getattr(args, "width", None))


def num_or_blank(v):
    return stats.fmt_num(v) if v is not None else ""


# ---------------------------------------------------------------------------
# hosts
# ---------------------------------------------------------------------------

def cmd_hosts(args):
    if args.selectors:
        if not args.layout:
            die("selectors need --layout FILE")
        args.select = (args.select or []) + args.selectors
    hs = collect(args)
    if args.csv:
        attrs = hostmod.attr_columns(hs)
        t = tablemod.Table(["host", "addr", "port"] + attrs, [
            [h.name, h.addr, str(h.port or "")] +
            [dict(h.attrs).get(a, "") for a in attrs] for h in hs], "hosts")
        sys.stdout.write(tablemod.to_csv(t))
        return 0
    for h in hs:
        out(h.token(plain=args.plain))
    return 0


# ---------------------------------------------------------------------------
# run
# ---------------------------------------------------------------------------

# A host's stderr is kept in qd.hosts up to this much; the first line of it
# is the `error` column either way.
STDERR_KEEP = 16384


def outcome_counts(results):
    counts = {}
    for r in results:
        counts[r.outcome] = counts.get(r.outcome, 0) + 1
    return counts


def new_run_id(st, label):
    stamp = time.strftime("%Y%m%d-%H%M%S")
    base = "%s-%s" % (stamp, tablemod.slug(label or "")[:32].strip("_")
                      or "run")
    taken = st.run_ids()
    rid, k = base, 2
    while rid in taken:
        rid = "%s-%d" % (base, k)
        k += 1
    return rid


def run_row(rid, kind, name, command, created, **kw):
    """The qd.runs row: what ran, where, when, how it went."""
    d = {"run": rid, "kind": kind, "name": name, "command": command,
         "created": created, "finished": now_iso(), "cwd": os.getcwd(),
         "qd": VERSION}
    d.update(kw)
    return ["" if d.get(c) is None else str(d[c])
            for c in storemod.RUN_COLUMNS]


def host_row(rid, r):
    h = r.host
    addr = h.addr + (":%d" % h.port if h.port else "")
    return [rid, h.name, addr if (h.addr != h.name or h.port) else "",
            str(r.pass_no), "%d" % int(r.started), r.outcome, str(r.rc),
            "%.2f" % r.duration, str(len(r.stdout.encode("utf-8"))),
            r.error(), " ".join("%s=%s" % kv for kv in h.attrs),
            r.stderr[:STDERR_KEEP]]


def filed(st, rid, notes, batch):
    """The run just filed, read back from the store -- proof it is there.
    If it is not, the answers are still on disk, and how to file them is
    said: a fleet's answers are never thrown away for want of a store."""
    st.reset()
    for e in reversed(st.entries()):
        if e.id == rid:
            batch.cleanup()
            if notes:
                e.meta.setdefault("notes", []).extend(notes)
            return e
    die("provost did not file this run%s\n  what came back is kept in %s"
        % ((": " + notes[-1]) if notes else "", batch.dir))


def file_batch(prov, batch, what):
    try:
        return filing.notes_of(prov, batch, what)
    except QdError as exc:
        die("%s\n  what came back is kept in %s" % (exc, batch.dir), exc.code)


def cmd_run(args):
    cmd = strip_dashes(args.command)
    if args.script:
        if not os.path.isfile(args.script):
            die("no such script: %s" % args.script)
    elif not cmd:
        die("nothing to run: put the command after --, e.g.\n"
            "  %s run --servers hosts.txt -- uptime" % PROG)
    hs = collect(args)
    if args.limit is not None and len(hs) > args.limit and not args.yes:
        die("refusing to run on %d hosts: --limit is %d (add --yes)"
            % (len(hs), args.limit))
    push = list(args.push or [])
    for f in push:
        if not os.path.isfile(f):
            die("no such file to push: %s" % f)
    if args.script:
        push.append(args.script)
        command = " ".join(
            [shlex.quote("%s/%s" % (args.remote_dir,
                                    os.path.basename(args.script)))] +
            [shlex.quote(a) for a in cmd])
    else:
        command = " ".join(cmd)
    check_danger(command, args.yes)
    if args.count < 0 or (args.count == 0 and not args.every):
        die("--count wants 1 or more (0, meaning until Ctrl-C, needs "
            "--every)")
    if args.every is not None and args.every <= 0:
        die("--every wants a number of seconds above 0")
    runner = fleet.Runner(ssh=args.ssh, scp=args.scp, user=args.user,
                          timeout=args.timeout, max_output=args.max_output,
                          remote_dir=args.remote_dir, sudo=args.sudo)
    if args.dry_run:
        for h in hs:
            out(" ".join(shlex.quote(a) for a in runner.ssh_argv(
                h, runner.wrap(command))))
        return 0
    st = prov = None
    if not args.no_store:
        # before the fleet, not after: answers with nowhere to go are lost
        st = store_of(args)
        prov = filing.Provost(st)
        prov.require("keep the answers")
    count = args.count if args.count else 10 ** 9
    t0 = time.time()
    created = now_iso()
    results, interrupted = fleet.run_passes(
        hs, lambda h, k: runner.run_one(h, command, push or None,
                                        not args.keep_remote, k),
        args.jobs, count, args.every or 0)
    if not results:
        die("interrupted before any pass finished; nothing was kept", 130)
    took = round(time.time() - t0, 2)
    passes = max(r.pass_no for r in results)
    last = [r for r in results if r.pass_no == passes]
    entry = None
    if st is not None:
        label = args.name or (os.path.basename(args.script) if args.script
                              else os.path.basename(command.split()[0])
                              if command.split() else "run")
        rid = new_run_id(st, label)
        ds = filing.dataset_name(label)
        b = filing.Batch()
        for r in results:
            if r.stdout.strip():
                pairs = [("run", rid), ("host", r.host.name)] + (
                    [("pass", str(r.pass_no))] if passes > 1 else []) + \
                    list(r.host.attrs)
                b.add(ds, filing.prologue(pairs) + filing.body(r.stdout))
        ncap = len(b.inputs)
        b.add_own(storemod.HOSTS, filing.own_tsv(
            storemod.HOST_COLUMNS, [host_row(rid, r) for r in results]))
        counts = outcome_counts(last)
        b.add_own(storemod.RUNS, filing.own_tsv(storemod.RUN_COLUMNS, [run_row(
            rid, "run", label, command, created, duration_s=took,
            hosts=len(hs), ok=counts.get(fleet.OK, 0),
            failed=counts.get(fleet.FAILED, 0),
            timeout=counts.get(fleet.TIMEOUT, 0),
            unreachable=counts.get(fleet.UNREACHABLE, 0),
            push_failed=counts.get(fleet.PUSH_FAILED, 0), passes=passes,
            every=args.every, captures=ncap,
            notes=("interrupted after %s" % plural(passes, "pass", "passes"))
            if interrupted else None)]))
        if ncap > 8 and sys.stderr.isatty():
            sys.stderr.write("%s run: filing %s through provost ...\n"
                             % (PROG, plural(ncap, "answer")))
        notes = file_batch(prov, b, "answers")
        entry = filed(st, rid, notes, b)
        t = entry.load("data")
    else:
        t = unfiled_table(results, passes)
    report_run(args, command, hs, results, t, entry, passes, interrupted)
    return 0 if all(r.outcome == fleet.OK for r in last) else 1


def unfiled_table(results, passes):
    """--no-store: what came back, with nothing parsed and nothing kept."""
    cols = ["host"] + (["pass"] if passes > 1 else []) + [
        "status", "rc", "duration_s", "error", "stdout"]
    rows = []
    for r in results:
        rows.append([r.host.name] + ([str(r.pass_no)] if passes > 1
                                     else []) +
                    [r.outcome, str(r.rc), "%.2f" % r.duration, r.error(),
                     r.stdout.rstrip("\n")])
    return tablemod.Table(cols, rows, "data")


def data_columns(t):
    """What the hosts said, as provost read it: the columns after qd's own
    (host ... status, rc, duration_s, error, capture, and dataset)."""
    if "capture" in t.columns:
        rest = t.columns[t.columns.index("capture") + 1:]
    elif "stdout" in t.columns:
        rest = ["stdout"]
    else:
        rest = []
    return [c for c in rest if c != "dataset"]


def report_run(args, command, hs, results, t, entry, passes, interrupted):
    last = [r for r in results if r.pass_no == passes]
    counts = outcome_counts(last)
    parts = ["%d ok" % counts.get(fleet.OK, 0)] + [
        "%d %s" % (counts[k], k) for k in (fleet.FAILED, fleet.TIMEOUT,
                                           fleet.UNREACHABLE,
                                           fleet.PUSH_FAILED)
        if counts.get(k)]
    dcols = data_columns(t)
    if entry is None:
        shape = "not kept (--no-store)"
    else:
        names = entry.tables[0].get("datasets") or []
        shape = "provost: %s" % (", ".join(names) or "nothing to file")
        if dcols:
            shape += ": " + ", ".join(dcols[:6]) + (" ..." if len(dcols) > 6
                                                     else "")
    lines = ["%s run -- %s: %s, %s%s   [%s]" % (
        PROG, command if len(command) < 60 else command[:57] + "...",
        plural(len(hs), "host"), ", ".join(parts),
        (", %d passes" % passes) if passes > 1 else "", shape)]
    if interrupted:
        lines.append("  interrupted: kept the %s that finished"
                     % plural(passes, "pass", "passes"))
    if entry is not None:
        caps = sorted(entry.captures(), key=storemod.cnum)
        lines.append("  stored   %s in %s  (%s%s)" % (
            entry.id, entry.store.shown(), plural(len(t.rows), "row"),
            (", %d captures %s..%s" % (len(caps), caps[0], caps[-1]))
            if len(caps) > 1 else (", capture %s" % caps[0]) if caps
            else ""))
        for n in entry.meta.get("notes", []):
            lines.append("  note     %s" % n)
    if args.quiet:
        sys.stdout.write(render.page(lines))
        return
    bad = [r for r in last if r.outcome != fleet.OK]
    if bad:
        lines.append("")
        lines.append("  DID NOT ANSWER")
        w = max(len(r.host.name) for r in bad)
        for r in bad:
            what = r.outcome if r.outcome != fleet.FAILED else \
                "failed (exit %d)" % r.rc
            lines.append("    %-*s  %-16s %s" % (w, r.host.name, what,
                                                 r.error()))
    ok_rows = [row for row in t.rows if row[t.index("status")] == fleet.OK]
    if args.preview and ok_rows:
        show = ["host"] + (["pass"] if passes > 1 else []) + (
            ["dataset"] if "dataset" in t.columns else []) + dcols[:8]
        sub = t.derive(rows=ok_rows[:args.preview], columns=show)
        lines.append("")
        lines.extend(render.render_table(sub, max_cell=48,
                                         width=width_of(args), indent="  "))
        if len(ok_rows) > args.preview:
            lines.append("  ... %d more row(s): %s show %s" % (
                len(ok_rows) - args.preview, PROG,
                entry.id if entry else "..."))
    lines.extend(run_next_steps(t, dcols, entry, bad, passes))
    sys.stdout.write(render.page(lines))


def run_next_steps(t, dcols, entry, bad, passes):
    ref = "latest" if entry else "<run>"
    tips = []
    if bad:
        tips.append(("%s show %s --where status!=ok" % (PROG, ref),
                     "the %s that did not answer, with why"
                     % plural(len(bad), "host")))
        tips.append(("reachable hosts.txt -i",
                     "binnacle: comment dead entries out of the list"))
    ok = t.derive(rows=query.where(t, ["status=ok"]))
    filled = [c for c in dcols if ok.has(c) and ok.kind(c) != "empty"]
    if ok.rows and len(filled) == 1 and ok.kind(filled[0]) != "num":
        distinct = len(set(ok.values(filled[0])))
        if distinct > 1:
            tips.append(("%s freq %s %s" % (PROG, ref, filled[0]),
                         "%d different answers: who said which" % distinct))
        else:
            tips.append(("", "every host that answered said the same thing"))
    nums = [c for c in filled if ok.kind(c) == "num" and c != "n"]
    if nums:
        c = nums[0]
        if passes > 1:
            tips.append(("%s trend %s %s" % (PROG, ref, c),
                         "%s over the passes, host by host" % c))
        tips.append(("%s outliers %s %s" % (PROG, ref, c),
                     "who is far from the fleet's median"))
        attrs = [a for a in ("rack", "row", "room", "role") if t.has(a)]
        tips.append(("%s stats %s %s%s" % (PROG, ref, c,
                                          " --by " + attrs[0] if attrs
                                          else ""),
                     "centre and spread" + (" per " + attrs[0]
                                            if attrs else "")))
    if "dataset" in t.columns and "unsorted" in set(t.values("dataset")):
        tips.append(("provost triage",
                     "answers provost could not read as a table, and why"))
    if entry is not None:
        prev = entry.store.previous_like(entry)
        if prev is not None:
            tips.append(("%s diff %s" % (PROG, ref),
                         "against the last time this ran (%s)" % prev.id))
        caps = entry.captures()
        n = storemod.first_row(entry.store.meta(caps[0])) if caps else None
        if n is not None:
            tips.append(("provost source %d" % n,
                         "one host's answer exactly as it came back"))
    tips.append(("%s view %s" % (PROG, ref), "explore it full-screen"))
    return next_steps(tips)


def next_steps(tips):
    if not tips:
        return []
    lines = ["", "  WHAT TO DO NEXT"]
    w = max(len(c) for c, _ in tips if c) if any(c for c, _ in tips) else 0
    for c, why in tips:
        if c:
            lines.append("    * %-*s  %s" % (w, c, why))
        else:
            lines.append("    * %s" % why)
    return lines


# ---------------------------------------------------------------------------
# do: a tool from the toolchain, run here and filed
# ---------------------------------------------------------------------------

def run_teed(argv):
    """Run argv with stdout shown live and kept; stderr and stdin stay the
    terminal's, so progress lines and prompts work as they always do."""
    try:
        p = subprocess.Popen(argv, stdout=subprocess.PIPE)
    except OSError as exc:
        name = os.path.basename(argv[0])
        hint = tools.install_hint(name)
        die("cannot run %s: %s%s" % (argv[0], exc.strerror or exc,
                                     ("\n  " + hint) if hint else ""), 127)
    chunks = []
    try:
        while True:
            chunk = p.stdout.read1(65536) if hasattr(p.stdout, "read1") \
                else p.stdout.read(65536)
            if not chunk:
                break
            chunks.append(chunk)
            try:
                sys.stdout.buffer.write(chunk)
                sys.stdout.flush()
            except (AttributeError, ValueError):
                sys.stdout.write(chunk.decode("utf-8", "replace"))
    except KeyboardInterrupt:
        p.wait()
    rc = p.wait()
    return rc, b"".join(chunks).decode("utf-8-sig", "replace")


def resolve_argv(cmd):
    """A bare tool name that is not on PATH but is installed as a module
    (or named by QD_<TOOL>) runs from there."""
    name, _ = tools.tool_of(cmd)
    if os.path.sep not in cmd[0] and name in tools.TOOL_NAMES:
        import shutil
        if env(name.upper().replace("-", "_")) or not shutil.which(cmd[0]):
            found = tools.find_tool(name)
            if found:
                return found + cmd[1:]
    return cmd


def add_tables(b, rid, label, tables):
    """File each table qd read as a capture of its own: '#% run=RUN', a
    qd-table line with its name, notes and display metadata, then the
    table as plain TSV.  Returns [(table name, dataset, rows, origin)]."""
    added, taken = [], set()
    for origin, t in tables:
        if not t.columns or not t.rows:
            continue
        base = tablemod.slug(t.name) or "data"
        name, k = base, 2
        while name in taken:
            name = "%s_%d" % (base, k)
            k += 1
        taken.add(name)
        ds = filing.dataset_name(label if name == tablemod.slug(label)
                                 else "%s.%s" % (label, name))
        info = {"name": name, "from": origin, "index": len(added)}
        if t.notes:
            info["notes"] = list(t.notes)
        if t.tests:
            info["tests"] = t.tests
        b.add(ds, filing.prologue([("run", rid)], [storemod.table_line(info)])
              + filing.table_tsv(t))
        added.append((name, ds, len(t.rows), origin))
    return added


def cmd_do(args):
    cmd = strip_dashes(args.command)
    if not cmd:
        die("nothing to do: put the tool and its arguments after --, e.g.\n"
            "  %s do -- mx run --for 60" % PROG)
    cmd = resolve_argv(cmd)
    st = store_of(args)
    prov = filing.Provost(st)
    prov.require("keep what it leaves")
    name, _ = tools.tool_of(cmd)
    label = args.name or name or "do"
    cmdline = " ".join(shlex.quote(a) for a in strip_dashes(args.command))
    work = tempfile.mkdtemp(prefix="qd-do-")
    try:
        return _do(args, cmd, st, prov, name, label, cmdline, work)
    finally:
        import shutil
        shutil.rmtree(work, ignore_errors=True)


def _do(args, cmd, st, prov, name, label, cmdline, work):
    plan = tools.plan(cmd, work)
    if args.no_import:
        plan.imports, plan.after = [], []
    for path in args.import_ or []:
        plan.imports.append((path, None))
    shown = " ".join(shlex.quote(a) for a in plan.argv)
    sys.stderr.write("%s do: %s\n" % (PROG, shown))
    for n in plan.notes:
        sys.stderr.write("%s do: %s\n" % (PROG, n))
    created = now_iso()
    t0 = time.time()
    rc, stdout = run_teed(plan.argv)
    took = round(time.time() - t0, 2)
    log = []
    for argv, outpath, tname in plan.after:
        log.append("  + %s" % " ".join(shlex.quote(a) for a in argv))
        try:
            p = subprocess.Popen(argv, stdout=subprocess.PIPE,
                                 stderr=subprocess.PIPE)
            _, err = p.communicate()
        except OSError as exc:
            log.append("    could not run it: %s" % exc)
            continue
        if p.returncode != 0:
            first = err.decode("utf-8", "replace").strip().splitlines()
            log.append("    exit %d: %s" % (p.returncode,
                                            first[-1] if first else ""))
        if os.path.exists(outpath):
            plan.imports.append((outpath, tname))
    tables = []
    for path, tname in plan.imports:
        if not os.path.exists(path):
            log.append("  - %s: not there, nothing read" % path)
            continue
        try:
            got = importers.read_path(path)
        except QdError as exc:
            log.append("  - %s: %s" % (path, exc))
            continue
        for t in got:
            if tname and len(got) == 1:
                t.name = tname
            origin = "qd" if os.path.abspath(path).startswith(work + os.sep) \
                else os.path.abspath(path)
            tables.append((origin, t))
    rid = new_run_id(st, label)
    b = filing.Batch()
    added = add_tables(b, rid, label, tables)
    fmt = tablemod.detect(stdout)
    if stdout.strip() and (fmt not in ("lines", "empty") or not added):
        # what it printed is provost's to read, as any captured output is
        ds = filing.dataset_name("%s.stdout" % label)
        b.add(ds, filing.prologue([("run", rid)], [storemod.table_line(
            {"name": "stdout", "from": "stdout", "index": len(added)})]) +
            filing.body(stdout))
        added.append(("stdout", ds, None, "stdout"))
    ver = tools.tool_version(plan.argv[:len(plan.argv) - len(
        tools.tool_of(plan.argv)[1])]) if name in tools.TOOL_NAMES else ""
    b.add_own(storemod.RUNS, filing.own_tsv(storemod.RUN_COLUMNS, [run_row(
        rid, "do", label, cmdline, created, duration_s=took, rc=rc,
        captures=len(b.inputs), tool=name, ran=shown, version=ver)]))
    notes = file_batch(prov, b, "tables")
    entry = filed(st, rid, notes, b)
    rows = dict((t["name"], t.get("rows", 0)) for t in entry.tables)
    for tname, ds, _, origin in added:
        log.append("  + %-16s %6d rows  %s  <- %s" % (
            tname, rows.get(tname, 0), ds, origin))
    lines = ["", "%s do -- %s exited %d after %ss" % (PROG, name or cmd[0],
                                                     rc, took),
             "  stored   %s in %s" % (entry.id, st.shown())] + log + [
        "  note     %s" % n for n in notes]
    tips = []
    if added:
        tips.append(("%s view latest" % PROG, "explore what it left"))
        tips.append(("%s log latest" % PROG, "what was run and kept"))
        if len(added) > 1:
            tips.append(("%s stats latest:%s" % (PROG, added[0][0]),
                         "one table of several"))
    else:
        tips.append(("%s do --import PATH -- ..." % PROG,
                     "nothing was recognised as data; name the file"))
    lines.extend(next_steps(tips))
    sys.stderr.write(render.page(lines))
    return rc


# ---------------------------------------------------------------------------
# import / log
# ---------------------------------------------------------------------------

def cmd_import(args):
    st = store_of(args)
    prov = filing.Provost(st)
    prov.require("file it")
    label = args.name or os.path.basename(os.path.abspath(args.paths[0]))
    for p in args.paths:
        if not os.path.exists(p):
            die("no such file or directory: %s" % p)
    tables = []
    for p in args.paths:
        for t in importers.read_path(p, args.as_):
            tables.append((os.path.abspath(p), t))
    created = now_iso()
    rid = new_run_id(st, label)
    b = filing.Batch()
    added = add_tables(b, rid, label, tables)
    if not added:
        b.cleanup()
        die("nothing to file: no table with rows in %s" % " ".join(args.paths))
    b.add_own(storemod.RUNS, filing.own_tsv(storemod.RUN_COLUMNS, [run_row(
        rid, "import", label, " ".join(args.paths), created,
        captures=len(b.inputs))]))
    notes = file_batch(prov, b, "tables")
    entry = filed(st, rid, notes, b)
    rows = dict((t["name"], t.get("rows", 0)) for t in entry.tables)
    lines = ["%s import -- %s in %s" % (PROG, entry.id, st.shown())]
    for (origin, t), (tname, ds, _, _) in zip(
            [x for x in tables if x[1].columns and x[1].rows], added):
        lines.append("  + %-18s %6d rows  %s  %s  <- %s" % (
            tname, rows.get(tname, 0), ds, "results" if t.is_results() else
            plural(len(t.columns), "column"), origin))
    for n in notes:
        lines.append("  note     %s" % n)
    lines.extend(next_steps([("%s view latest" % PROG, "explore it"),
                             ("%s stats latest" % PROG, "describe it")]))
    sys.stdout.write(render.page(lines))
    return 0


def cmd_log(args):
    st = store_of(args)
    if args.ref:
        e = st.resolve(args.ref)
        sys.stdout.write(render.page(describe_entry(e)))
        return 0
    entries = st.entries()
    if not entries:
        out("no runs in the store %s yet%s" % (
            st.shown(), " (provost ls lists its datasets)"
            if st.dataset_names() else ""))
        return 0
    shown = entries if args.all else entries[-args.n:]
    rows = []
    for e in shown:
        cmdline = e.meta.get("command") or ""
        rows.append([e.id, e.meta.get("kind", ""),
                     str(e.table_count()), e.summary(),
                     cmdline if len(cmdline) <= 50 else cmdline[:47] + "..."])
    lines = render.render_rows(["run", "kind", "tables", "size",
                                "command"], rows, numeric=[2], max_cell=64,
                               width=width_of(args))
    if len(shown) < len(entries):
        lines.append("(%d earlier; --all lists them)"
                     % (len(entries) - len(shown)))
    sys.stdout.write(render.page(lines))
    return 0


# ---------------------------------------------------------------------------
# Reading a dataset
# ---------------------------------------------------------------------------

def load(args, ref=None):
    return load_ref(store_of(args), ref or args.ref or "latest",
                    getattr(args, "as_", None))


def cmd_show(args):
    t = load(args)
    s = subset(args, t)
    rows = s.rows if args.limit is None else s.rows[:args.limit]
    s2 = s.derive(rows=rows)
    if args.vertical:
        lines = []
        w = max([len(c) for c in s2.columns] or [0])
        for n, r in enumerate(s2.rows, 1):
            lines.append("-- row %d" % n)
            for c, v in zip(s2.columns, r):
                vl = v.split("\n")
                lines.append("%-*s  %s" % (w, c, vl[0]))
                for more in vl[1:]:
                    lines.append("%-*s  %s" % (w, "", more))
        emit(args, s2, lines)
        return 0
    lines = render.render_table(s2, max_cell=None if args.full else 40,
                                width=None if args.full else width_of(args))
    if render.isatty() and (args.format or "text") == "text":
        lines.append("(%s from %s)" % (scope(args, t, s2), source_name(t)))
    emit(args, s2, lines)
    return 0


def _one_column_report(t, s, col, args):
    name = s.colname(col)
    kind = s.kind(name)
    vals = s.values(name)
    filled = [v for v in vals if v.strip()]
    lines = ["%s stats -- %s in %s (%s)" % (PROG, name, source_name(t),
                                            scope(args, t, s)), ""]
    lines.append("  kind      %s" % kind)
    lines.append("  measured  %d   blank %d   distinct %d"
                 % (len(filled), len(vals) - len(filled), len(set(filled))))
    unit = dict(t.tests.get(name, [])).get("unit") if t.tests else None
    if s.is_results() and name == "value" and s.rows:
        tests = sorted(set(s.values("test")))
        if len(tests) == 1:
            unit = dict(t.tests.get(tests[0], [])).get("unit")
        else:
            lines.append("  note      value mixes %d tests here (%s); "
                         "--where test=NAME reads one" % (
                             len(tests), ", ".join(tests[:4]) +
                             (" ..." if len(tests) > 4 else "")))
    if kind in ("num", "mixed"):
        sm = stats.summary(s.numbers(name))
        if kind == "mixed":
            lines.append("  numbers   %d of the %d measured; the words are "
                         "left out of the figures below" % (sm["n"],
                                                             len(filled)))
        if sm["n"]:
            lines.append("  mean      %s   stdev %s%s" % (
                num_or_blank(sm["mean"]), num_or_blank(sm["stdev"]),
                ("   cv %s%%" % stats.fmt_num(100 * sm["stdev"] /
                                              abs(sm["mean"])))
                if sm.get("stdev") and sm["mean"] else ""))
            figures = tuple(num_or_blank(sm[k]) for k in (
                "min", "p05", "p25", "median", "p75", "p95", "max"))
            lines.append("  min       %s   p05 %s   p25 %s   median %s   "
                         "p75 %s   p95 %s   max %s" % figures +
                         ("  (%s)" % unit if unit else ""))
            lines.append("  sum       %s" % num_or_blank(sm["sum"]))
            lines.append("")
            lines.extend(hist_lines(s.numbers(name), None, 30, args))
    top = stats.freq(s, name)
    # Value counts of a continuous number are every value once: noise.
    if kind != "num" or (top and top[0][1] > 1 and len(top) <= 20):
        lines.append("")
        lines.append("  most common")
        for v, n, _ in top[:8]:
            lines.append("    %6d  %5.1f%%  %s" % (
                n, 100.0 * n / max(1, len(vals)),
                render.clip(render.first_line(v) if v else "(blank)", 70)))
    return lines


def cmd_stats(args):
    t = load(args)
    s = subset(args, t)
    by = []
    for b in args.by or []:
        by.extend(x.strip() for x in b.split(",") if x.strip())
    aggs = [a.strip() for a in args.agg.split(",")] if args.agg else None
    if by:
        g = stats.group_by(s, by, args.columns or None, aggs)
        lines = ["%s stats -- %s by %s (%s): %s" % (
            PROG, source_name(t), ", ".join(by), scope(args, t, s),
            plural(len(g.rows), "group")), ""]
        lines.extend(render.render_table(g, width=width_of(args)))
        emit(args, g, lines)
        return 0
    if len(args.columns or []) == 1 and (args.format or "text") == "text":
        lines = _one_column_report(t, s, args.columns[0], args)
        emit(args, stats.describe(s, args.columns), lines)
        return 0
    d = stats.describe(s, args.columns or None)
    lines = ["%s stats -- %s (%s), %s" % (
        PROG, source_name(t), scope(args, t, s),
        plural(len(s.columns), "column")), ""]
    lines.extend(render.render_table(d, max_cell=30, width=width_of(args)))
    if t.notes:
        lines.append("")
        for n in t.notes[:8]:
            lines.append("  # %s" % n)
    emit(args, d, lines)
    return 0


def cmd_freq(args):
    t = load(args)
    s = subset(args, t)
    lines, ft = report_freq(args, t, s)
    emit(args, ft, lines)
    return 0


def report_freq(args, t, s):
    col = s.colname(args.column)
    fr = stats.freq(s, col, loose=args.loose, label_col=args.label)
    total = len(s.rows)
    lines = ["%s freq -- %s in %s (%s): %s%s" % (
        PROG, col, source_name(t), scope(args, t, s),
        plural(len(fr), "distinct value"),
        "   [normalized: loose -- whitespace squeezed, numbers masked]"
        if args.loose else "")]
    if fr and len(fr) > 1:
        lines.append("  %d agree on the most common; %d do not"
                     % (fr[0][1], total - fr[0][1]))
    lines.append("")
    top_n = fr if args.top == 0 else fr[:args.top]
    biggest = fr[0][1] if fr else 1
    multi = any("\n" in v for v, _, _ in top_n)
    rows = []
    for k, (v, n, labels) in enumerate(top_n, 1):
        pct = 100.0 * n / max(1, total)
        shown = render.first_line(v) if v else "(blank)"
        if multi:
            lines.append("  GROUP %d  %d (%.1f%%)%s" % (
                k, n, pct, "  <- most common" if k == 1 else ""))
            if labels:
                lines.append("    hosts: %s" % label_list(labels, args.all_labels))
            if k == 1 or not fr[0][0] or "\n" not in fr[0][0]:
                for ln in v.split("\n")[:args.lines]:
                    lines.append("    | %s" % ln)
                extra = len(v.split("\n")) - args.lines
                if extra > 0:
                    lines.append("    | ... %d more line(s)" % extra)
            else:
                for ln in diffmod.text_diff(fr[0][0], v, args.lines):
                    lines.append("    %s" % ln)
            lines.append("")
        else:
            lines.append("  %6d  %5.1f%%  %-22s %s" % (
                n, pct, render.bar(n, biggest, 20), shown))
            if labels and len(fr) > 1 and (k > 1 or args.all_labels):
                lines.append(" " * 41 + label_list(labels, args.all_labels))
        rows.append([v, str(n), stats.fmt_num(pct), " ".join(labels)])
    if len(fr) > len(top_n):
        lines.append("  ... %d more value(s): --top 0 shows every one"
                     % (len(fr) - len(top_n)))
    ft = tablemod.Table([col, "count", "pct", "labels"], rows, "freq")
    return lines, ft


def label_list(labels, all_labels=False, limit=8):
    if all_labels or len(labels) <= limit:
        return " ".join(labels)
    return "%s (+%d more)" % (" ".join(labels[:limit]), len(labels) - limit)


def hist_lines(nums, bins, width, args):
    h = stats.histogram(nums, bins)
    if not h:
        return ["  nothing measured"]
    top = max(c for _, _, c in h)
    exact = all(lo == hi for lo, hi, _ in h)
    los = [stats.fmt_num(lo) for lo, _, _ in h]
    his = [stats.fmt_num(hi) for _, hi, _ in h]
    wl, wh = max(len(x) for x in los), max(len(x) for x in his)
    out_ = []
    for lo, hi, (_, _, c) in zip(los, his, h):
        lab = lo.rjust(wl) if exact else "%s - %s" % (lo.rjust(wl),
                                                      hi.rjust(wh))
        out_.append("  %s  %-*s %d" % (lab, width,
                                       render.bar(c, top, width), c))
    return out_


def cmd_hist(args):
    t = load(args)
    s = subset(args, t)
    lines, ht = report_hist(args, t, s)
    emit(args, ht, lines)
    return 0


def report_hist(args, t, s):
    col = s.colname(args.column)
    nums = s.numbers(col)
    sm = stats.summary(nums)
    if not sm["n"]:
        die("%s holds no numbers to bin (try qd freq for words)" % col, 1)
    lines = ["%s hist -- %s in %s (%s): %d measured, %d blank   min %s  "
             "median %s  max %s" % (
                 PROG, col, source_name(t), scope(args, t, s), sm["n"],
                 len(nums) - sm["n"], stats.fmt_num(sm["min"]),
                 stats.fmt_num(sm["median"]), stats.fmt_num(sm["max"])), ""]
    lines.extend(hist_lines(nums, args.bins, args.bar_width, args))
    h = stats.histogram(nums, args.bins)
    ht = tablemod.Table(["lo", "hi", "count"], [
        [stats.fmt_num(lo), stats.fmt_num(hi), str(c)] for lo, hi, c in h],
        "hist")
    return lines, ht


def cmd_outliers(args):
    t = load(args)
    s = subset(args, t)
    lines, ot = report_outliers(args, t, s)
    emit(args, ot, lines)
    return 0


def report_outliers(args, t, s):
    col = s.colname(args.column)
    if s.is_results() and col == "value" and len(set(s.values("test"))) > 1:
        die("value mixes %d tests here; pick one: --where test=%s"
            % (len(set(s.values("test"))), s.values("test")[0]))
    per = None if args.no_per else (args.per or stats.default_per(s, col))
    rows, info = stats.outliers(s, col, per, args.z)
    if not info["n"]:
        die("%s holds no numbers to compare" % col, 1)
    who = per or ("host" if s.has("host") else "row")
    lines = ["%s outliers -- %s%s in %s (%s): %d %ss, median %s, MAD %s, "
             "robust z beyond %s" % (
                 PROG, col, " (median per %s)" % per if per else "",
                 source_name(t), scope(args, t, s), info["n"], who,
                 stats.fmt_num(info["median"]), stats.fmt_num(info["mad"]),
                 stats.fmt_num(args.z)), ""]
    tr = []
    for key, v, med, rel, rz, side in rows:
        tr.append([key, stats.fmt_num(v), "" if rel is None else
                   stats.fmt_num(rel) + "%",
                   ("%+.1f" % rz) if abs(rz) != float("inf") else
                   ("+inf" if rz > 0 else "-inf"), side])
    ot = tablemod.Table([who, "value", "of_median", "robust_z", "side"], tr,
                        "outliers")
    if rows:
        lines.extend(render.render_table(ot, width=width_of(args),
                                         indent="  "))
        lines.append("")
        lines.append("  %d of %d %ss sit far from the rest%s" % (
            len(rows), info["n"], who,
            "; most of them agree exactly, so every value that differs is "
            "listed" if not info["mad"] else ""))
    else:
        lines.append("  none: every %s is within %s robust z of the median"
                     % (who, stats.fmt_num(args.z)))
    return lines, ot


def cmd_pivot(args):
    t = load(args)
    s = subset(args, t)
    lines, p = report_pivot(args, t, s)
    emit(args, p, lines)
    return 0


def report_pivot(args, t, s):
    rows_c, cols_c, vals_c = args.rows, args.cols_, args.values
    if s.is_results():
        rows_c, cols_c = rows_c or "target", cols_c or "test"
        vals_c = vals_c or "value"
    if not rows_c or not cols_c:
        die("pivot wants --rows COL and --cols COL")
    p = stats.pivot(s, rows_c, cols_c, vals_c, args.agg)
    lines = ["%s pivot -- %s: %s by %s%s (%s)" % (
        PROG, source_name(t), rows_c, cols_c,
        ", %s of %s" % (args.agg, vals_c) if vals_c else ", counts",
        scope(args, t, s)), ""]
    lines.extend(render.render_table(p, max_cell=24, width=width_of(args)))
    return lines, p


def cmd_trend(args):
    t = load(args)
    s = subset(args, t)
    lines, tt = report_trend(args, t, s)
    emit(args, tt, lines)
    return 0


def report_trend(args, t, s):
    col = s.colname(args.column)
    by = args.by
    if by is None and s.has("host") and s.colname("host") != col:
        by = "host"
    if by is None and s.is_results():
        by = "target"
    over = args.over or stats.default_over(s)
    series = stats.trend(s, col, by, over)
    allv = [v for _, sr in series for v in sr if v is not None]
    if not allv:
        die("%s holds no numbers to draw" % col, 1)
    lo, hi = min(allv), max(allv)
    lines = ["%s trend -- %s%s over %s in %s (%s); one scale for all, %s .. %s"
             % (PROG, col, " by %s" % by if by else "",
                over or "row order", source_name(t), scope(args, t, s),
                stats.fmt_num(lo), stats.fmt_num(hi)), ""]
    rows = []
    for g, sr in series:
        xs = [v for v in sr if v is not None]
        if not xs:
            continue
        rows.append([g, str(len(xs)), stats.fmt_num(xs[0]),
                     stats.fmt_num(xs[-1]), stats.fmt_num(min(xs)),
                     stats.fmt_num(max(xs)),
                     render.sparkline(stats.resample(sr, args.points),
                                      lo, hi)])
    tt = tablemod.Table([by or "series", "n", "first", "last", "min", "max",
                         "trend"], rows, "trend")
    lines.extend(render.render_rows(tt.columns, rows, numeric=[1, 2, 3, 4, 5],
                                    max_cell=max(40, args.points),
                                    width=width_of(args), indent="  "))
    return lines, tt


# ---------------------------------------------------------------------------
# diff
# ---------------------------------------------------------------------------

def cmd_diff(args):
    book = store_of(args)
    if len(args.refs) == 1:
        ref, tname = split_ref(args.refs[0])
        if os.path.exists(ref):
            die("diff of a file needs two: %s diff OLD NEW" % PROG)
        new_e = book.resolve(ref)
        old_e = book.previous_like(new_e)
        if old_e is None:
            die("nothing earlier in the store ran what %s ran; name two "
                "runs: %s diff OLD NEW" % (new_e.id, PROG))
        a, b = old_e.load(tname), new_e.load(tname)
    elif len(args.refs) == 2:
        a = load_ref(book, args.refs[0])
        b = load_ref(book, args.refs[1])
    else:
        die("diff wants one run (against the one before it) or two")
    if args.where:
        a = a.derive(rows=query.where(a, args.where))
        b = b.derive(rows=query.where(b, args.where))
    key = [k.strip() for k in args.key.split(",")] if args.key else None
    cols = [c.strip() for c in args.cols.split(",")] if args.cols else None
    res = diffmod.diff_tables(a, b, key, cols, args.tolerance, args.agg)
    lines = diff_report(a, b, res, args)
    emit(args, diffmod.as_table(res), lines)
    return 1 if res.differs else 0


def diff_report(a, b, res, args):
    lines = ["%s diff -- A %s (%s) -> B %s (%s), matched on %s" % (
        PROG, source_name(a), plural(len(a.rows), "row"), source_name(b),
        plural(len(b.rows), "row"), ",".join(res.key))]
    lines.append("  compared  %s" % (", ".join(res.cols) or "nothing"))
    if res.ignored:
        lines.append("  ignored   %s (they differ on every run by "
                     "construction; --cols compares them)"
                     % ", ".join(res.ignored))
    if args.tolerance:
        lines.append("  tolerance changes within %s%% are not counted"
                     % stats.fmt_num(args.tolerance))
    for n in res.notes:
        lines.append("  note      %s" % n)
    both = len(res.changed) + res.same
    lines.append("")
    lines.append("  %s in both: %d changed, %d the same; %d only in A "
                 "(gone), %d only in B (new)" % (
                     plural(both, "key"), len(res.changed), res.same,
                     len(res.only_a), len(res.only_b)))
    if res.col_summary:
        rows = []
        for c in res.col_summary:
            rows.append([c["column"], str(c["n"]), num_or_blank(c["mean_a"]),
                         num_or_blank(c["mean_b"]),
                         ("%+.1f%%" % c["mean_pct"]) if c["mean_pct"]
                         is not None else "",
                         num_or_blank(c["median_delta"]), str(c["rose"]),
                         str(c["fell"]), str(c["same"])])
        lines.append("")
        lines.extend(render.render_rows(
            ["column", "pairs", "mean A", "mean B", "change",
             "median delta", "rose", "fell", "same"], rows,
            numeric=range(1, 9), width=width_of(args), indent="  "))
    if res.changed:
        lines.append("")
        lines.append("  CHANGED")
        limit = len(res.changed) if args.limit == 0 else args.limit
        for k, changes in res.changed[:limit]:
            parts = []
            texts = []
            for ch in changes:
                if "\n" in ch.a or "\n" in ch.b:
                    texts.append(ch)
                    parts.append("%s: text changed" % ch.col)
                elif ch.kind in ("appeared", "went blank"):
                    parts.append("%s %s (%s)" % (
                        ch.col, ch.kind, ch.b if ch.b else ch.a))
                elif ch.pct is not None:
                    parts.append("%s %s -> %s (%+.1f%%)" % (
                        ch.col, ch.a, ch.b, ch.pct))
                else:
                    parts.append("%s %s -> %s" % (ch.col, ch.a, ch.b))
            lines.append("    %s  %s" % (" ".join(k), "   ".join(parts)))
            for ch in texts:
                for ln in diffmod.text_diff(ch.a, ch.b, args.lines):
                    lines.append("        %s" % ln)
        if len(res.changed) > limit:
            lines.append("    ... %d more: --limit 0 lists every one"
                         % (len(res.changed) - limit))
    for title, keys in (("ONLY IN A (gone)", res.only_a),
                        ("ONLY IN B (new)", res.only_b)):
        if keys:
            lines.append("")
            lines.append("  %s" % title)
            names = [" ".join(k) for k in keys]
            lines.append("    " + label_list(names, args.limit == 0, 20))
    if not res.differs:
        lines.append("")
        lines.append("  no differences")
    return lines


# ---------------------------------------------------------------------------
# export / floor
# ---------------------------------------------------------------------------

def run_label(t):
    e = getattr(t, "entry", None)
    return e.id if e is not None else None


def cmd_export(args):
    t = load(args)
    s = subset(args, t)
    fmt = args.format or (tablemod.format_for(args.output)
                          if args.output and args.output != "-" else "csv")
    if fmt in ("overlay", "results"):
        o = tools.to_overlay(s, args.run or run_label(t), args.prefix,
                             args.target)
        write_text(args.output or "-", tablemod.to_results(o))
        if args.output and args.output != "-":
            warn("%d samples over %s to %s" % (
                len(o.rows), plural(len(set(o.values("test"))), "overlay"),
                args.output))
        return 0
    if fmt not in tablemod.WRITERS:
        die("unknown --format %r (want csv, tsv, json, ndjson, md, overlay)"
            % fmt)
    write_text(args.output or "-", tablemod.WRITERS[fmt](s))
    return 0


def floor_dir(e):
    """Where a run's overlay is written: qd's cache, never the store
    (provost commits everything in it)."""
    return os.path.join(storemod.cache_root(), "floor",
                        re.sub(r"[^\w.@-]+", "_", e.id))


def cmd_floor(args):
    t = load(args)
    s = subset(args, t)
    o = tools.to_overlay(s, run_label(t), args.prefix, args.target)
    e = getattr(t, "entry", None)
    d = floor_dir(e) if e is not None else os.getcwd()
    path = os.path.join(d, "overlay.tsv" if e is not None
                        else "qd-overlay.tsv")
    write_text(path, tablemod.to_results(o))
    sys.stderr.write("%s floor: %d samples, %s -> %s\n" % (
        PROG, len(o.rows), plural(len(set(o.values("test"))), "overlay"),
        path))
    argv = tools.find_tool("dcviz")
    serve = ["serve", "-d", d, "--results", "files/" +
             os.path.basename(path)]
    if args.layout:
        if not os.path.isfile(args.layout):
            die("no such layout: %s" % args.layout)
        lay = os.path.join(d, os.path.basename(args.layout))
        if os.path.abspath(lay) != os.path.abspath(args.layout):
            import shutil
            shutil.copyfile(args.layout, lay)
        serve += ["--layout", "files/" + os.path.basename(lay)]
    else:
        serve += []
    if args.port:
        serve += ["-p", str(args.port)]
    if args.no_browser:
        serve += ["-n"]
    if argv is None:
        sys.stderr.write(
            "%s floor: the viewer is not installed here, so it is not "
            "started.\n  pip install datacenter-layout-viewer, then:\n    "
            "dcviz %s\n  or load %s into any copy of the viewer, with "
            "Build from data if there is no layout.\n"
            % (PROG, " ".join(shlex.quote(a) for a in serve), path))
        return 0
    full = argv + serve
    if not args.layout:
        sys.stderr.write("%s floor: no --layout, so open Structure -> Build "
                         "from data in the viewer to read a floor plan out "
                         "of the hostnames\n" % PROG)
    if args.dry_run:
        out(" ".join(shlex.quote(a) for a in full))
        return 0
    sys.stdout.flush()
    sys.stderr.flush()
    try:
        return subprocess.call(full)
    except KeyboardInterrupt:
        return 0


# ---------------------------------------------------------------------------
# view / doctor / hints / help
# ---------------------------------------------------------------------------

def cmd_view(args):
    from . import explore
    book = store_of(args)
    ref = args.ref
    if ref is None and not book.entries():
        die("nothing to view: no runs in the store %s yet -- give a file, "
            "or make one with qd run / qd do / qd import" % book.shown())
    t = load_ref(book, ref or "latest", args.as_)
    return explore.run(t, book, where=args.where, sort=args.sort)


def cmd_web(args):
    from . import web
    book = store_of(args)
    if not book.exists():
        die("no store at %s yet -- qd run, qd do or qd import makes one "
            "(or point --store at another)" % book.shown())
    return web.serve(book, host=args.host, port=args.port,
                     layout=args.layout, open_browser=not args.no_browser,
                     quiet=args.quiet)


def cmd_doctor(args):
    rows = tools.doctor_rows()
    lines = ["%s doctor -- what this machine can drive" % PROG, ""]
    lines.extend(render.render_rows(["tool", "here", "runs as", "version",
                                     "for"], rows, max_cell=44,
                                    width=width_of(args), indent="  "))
    missing = [r[0] for r in rows if r[1] != "ok"]
    book = store_of(args)
    lines.append("")
    if book.exists():
        what = "%s, %s" % (plural(len(book.entries()), "run"),
                           plural(len(book.dataset_names()), "dataset"))
    else:
        what = "not made yet; the first run makes it"
    lines.append("  store     %s (%s)" % (book.shown(), what))
    prov = filing.Provost(book)
    if prov.argv:
        lines.append("  filing    %s" % (
            "provost batch: a run is one commit, its answers parsed in "
            "parallel" if prov.has_batch() else
            "one capture at a time (this provost has no batch; a newer "
            "one files a run as one commit)"))
    hints = sorted(set(tools.install_hint(m) for m in missing
                       if tools.install_hint(m)))
    if "ssh" in missing:
        hints.insert(0, "ssh/scp are needed for qd run: install openssh")
    if hints:
        lines.extend(next_steps([("", h) for h in hints]))
    sys.stdout.write(render.page(lines))
    return 1 if "ssh" in missing or "scp" in missing else 0


HINTS = [
    ("Is my host list even real?",
     "qd run --servers hosts.txt -- true            (then: reachable hosts.txt -i)"),
    ("What does every host say about X?",
     "qd run --servers hosts.txt -- uname -r   ->   qd freq latest A"),
    ("Settings as columns",
     "qd run -s hosts.txt -- 'sysctl net.core.somaxconn vm.swappiness'"),
    ("Watch it over time",
     "qd run -s hosts.txt --every 10 --count 30 -- cat /proc/loadavg"),
    ("The servers in racks 1-3",
     "qd run --layout floor.dc --select 'rack[1-3]' -- ...   (needs binnacle)"),
    ("Why is the fleet slow?",
     "qd do -- agree script why-slow --servers hosts.txt --fleet-csv -- --csv"),
    ("Packets per second, everyone to everyone",
     "qd do -- mx run --for 60"),
    ("TCP bandwidth, full mesh",
     "qd do -- iperf-orchestrator --servers hosts.txt run"),
    ("Was that what the hardware should do?",
     "qd do -- reckon floor.dc --mx reports/ --overlay reckon.tsv"),
    ("How is every host doing right now?",
     "qd do -- dcprobe scan --servers hosts.txt -o host_status.tsv"),
    ("Who is far from the rest?", "qd outliers latest COLUMN"),
    ("Centre and spread, per rack", "qd stats latest COLUMN --by rack"),
    ("What changed since last time?", "qd diff latest"),
    ("One host's answer, exactly", "provost source cNNNN   (qd log latest names them)"),
    ("Every run of it, ever", "qd show ds:NAME   or   provost show NAME"),
    ("Look around", "qd view latest"),
    ("On the floor plan", "qd floor latest --layout floor.dc"),
]


def cmd_hints(args):
    w = max(len(q) for q, _ in HINTS)
    lines = ["%s hints -- what you want to know, and the command" % PROG, ""]
    for q, c in HINTS:
        lines.append("  %-*s  %s" % (w, q, c))
    sys.stdout.write(render.page(lines))
    return 0


# ---------------------------------------------------------------------------
# Parser
# ---------------------------------------------------------------------------

def add_common(p):
    p.add_argument("--store", metavar="DIR",
                   help="the provost store to file into and read (QD_STORE; "
                   "default provost's own: PROVOST_WORKSPACE, the controlled "
                   "directory you are in, PROVOST_HOME, ~/.provost)")
    p.add_argument("--width", type=int, metavar="N",
                   help="cut tables to N columns of text (default: the "
                   "terminal's, none when piped)")


def add_hosts(p):
    g = p.add_argument_group("hosts")
    g.add_argument("-s", "--servers", action="append", metavar="FILE|SPEC",
                   help="a host file, a range like node[01-24], or - for "
                   "stdin; repeatable (QD_SERVERS; hosts.txt or "
                   "servers.txt if present)")
    g.add_argument("-S", "--server", action="append", metavar="a,b,c",
                   help="hosts inline, repeatable")
    g.add_argument("--layout", metavar="FILE",
                   help="a .dc layout to select hosts from (via binnacle's "
                   "manifest)")
    g.add_argument("--select", action="append", metavar="SEL",
                   help="manifest selector: rack[1-3], +gpu, model=hgx*; "
                   "repeatable")
    g.add_argument("--first", type=positive, metavar="N",
                   help="only the first N hosts -- the canary before the "
                   "fleet")


def add_query(p, sort=True):
    p.add_argument("--where", action="append", metavar="EXPR",
                   help="keep rows matching EXPR (mbps<900, status!=ok, "
                   "host~^wr01); repeatable, all must hold")
    if sort:
        p.add_argument("--sort", metavar="COLS",
                       help="order by these columns, -col descending; blanks "
                       "last")
    p.add_argument("--as", dest="as_", metavar="FORMAT",
                   help="read a file as this format rather than detecting it "
                   "(results, csv, json, grid, lines)")


def add_format(p, default_hint="text"):
    p.add_argument("--format", metavar="FMT",
                   help="text (default), csv, tsv, json, ndjson or md: the "
                   "table behind the report, for whatever comes next")
    p.add_argument("-o", "--output", metavar="FILE",
                   help="write there instead of stdout")


def positive(text):
    try:
        v = int(text)
    except ValueError:
        raise argparse.ArgumentTypeError("%r is not a whole number" % text)
    if v < 1:
        # A guard that reads 0 as "not given" is a guard that is not there.
        raise argparse.ArgumentTypeError("wants 1 or more, got %d" % v)
    return v


def nonneg(text):
    try:
        v = int(text)
    except ValueError:
        raise argparse.ArgumentTypeError("%r is not a whole number" % text)
    if v < 0:
        raise argparse.ArgumentTypeError("wants 0 or more, got %d" % v)
    return v


def seconds(text):
    try:
        v = float(text)
    except ValueError:
        raise argparse.ArgumentTypeError("%r is not a number of seconds"
                                         % text)
    if v <= 0:
        raise argparse.ArgumentTypeError("wants more than 0 seconds")
    return v


def build_parser():
    p = argparse.ArgumentParser(
        prog=PROG, add_help=False,
        formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("-h", "--help", action="store_true")
    p.add_argument("-V", "--version", action="store_true")
    sub = p.add_subparsers(dest="verb", metavar="VERB")

    def verb(name, helptext):
        sp = sub.add_parser(name, help=helptext, description=helptext,
                            formatter_class=argparse.RawDescriptionHelpFormatter)
        add_common(sp)
        return sp

    sp = verb("hosts", "expand and print the host list")
    add_hosts(sp)
    sp.add_argument("selectors", nargs="*", metavar="SEL",
                    help="manifest selectors, with --layout")
    sp.add_argument("--csv", action="store_true",
                    help="host,addr,port and every attribute, as CSV")
    sp.add_argument("--plain", action="store_true",
                    help="name[=addr[:port]] only, no attributes: the list "
                    "agree, mx and iperf-orchestrator read")
    sp.set_defaults(fn=cmd_hosts)

    sp = verb("run", "run a command on every host and keep the answers")
    add_hosts(sp)
    g = sp.add_argument_group("ssh")
    g.add_argument("-u", "--user", default=env("SSH_USER"),
                   help="ssh user (QD_SSH_USER; default: your ssh config)")
    g.add_argument("-j", "--jobs", type=positive,
                   default=env_int("JOBS", 32),
                   help="hosts contacted at once (QD_JOBS, 32)")
    g.add_argument("--timeout", type=seconds,
                   default=env_float("TIMEOUT", 60.0),
                   help="per-host command timeout, seconds (QD_TIMEOUT, 60)")
    g.add_argument("--max-output", type=positive, metavar="BYTES",
                   default=env_int("MAX_OUTPUT", 4 * 1024 * 1024),
                   help="per-host output cap; past it the host is killed and "
                   "reported (QD_MAX_OUTPUT, 4 MiB)")
    g.add_argument("--ssh", default=env("SSH", "ssh"), metavar="CMD",
                   help="ssh transport (QD_SSH)")
    g.add_argument("--scp", default=env("SCP", "scp"), metavar="CMD",
                   help="scp transport (QD_SCP)")
    g.add_argument("--sudo", action="store_true",
                   help="run the command under sudo -n")
    g.add_argument("--push", action="append", metavar="FILE",
                   help="copy FILE to each host first, repeatable")
    g.add_argument("--script", metavar="FILE",
                   help="push FILE and run it; the words after -- are its "
                   "arguments")
    g.add_argument("--remote-dir", default=env("REMOTE_DIR", "/var/tmp/qd"),
                   help="where pushed files go, removed afterwards "
                   "(QD_REMOTE_DIR, /var/tmp/qd)")
    g.add_argument("--keep-remote", action="store_true",
                   help="leave pushed files on the hosts")
    g = sp.add_argument_group("what comes back")
    g.add_argument("--every", type=seconds, metavar="S",
                   help="repeat: a pass every S seconds")
    g.add_argument("--count", type=nonneg, default=None, metavar="N",
                   help="passes to run (1; 0 with --every runs until Ctrl-C)")
    g.add_argument("--name", help="the run's name: the provost dataset its "
                   "answers go to, and what `qd show NAME` finds")
    g.add_argument("--no-store", action="store_true",
                   help="print the answers but keep nothing")
    g.add_argument("--preview", type=nonneg, default=20, metavar="N",
                   help="rows of the dataset to print (20; 0 for none)")
    g.add_argument("-q", "--quiet", action="store_true",
                   help="the summary line only")
    g = sp.add_argument_group("safety")
    g.add_argument("--dry-run", action="store_true",
                   help="print the ssh command per host and stop")
    g.add_argument("--limit", type=positive, metavar="N",
                   help="refuse to run wider than N hosts without --yes")
    g.add_argument("--yes", action="store_true",
                   help="proceed past --limit and the mutation guard")
    sp.add_argument("command", nargs=argparse.REMAINDER,
                    help="-- COMMAND...")
    sp.set_defaults(fn=cmd_run)

    sp = verb("do", "run a toolchain command here and keep what it left")
    sp.add_argument("--name", help="the run's name (default the tool's)")
    sp.add_argument("--import", dest="import_", action="append",
                    metavar="PATH", help="also read this file or directory "
                    "afterwards; repeatable")
    sp.add_argument("--no-import", action="store_true",
                    help="keep stdout only; read nothing back")
    sp.add_argument("command", nargs=argparse.REMAINDER,
                    help="-- TOOL ARGS...")
    sp.set_defaults(fn=cmd_do)

    sp = verb("import", "file output already on disk into the store")
    sp.add_argument("paths", nargs="+", metavar="PATH")
    sp.add_argument("--name", help="the run's name (default the first "
                    "path's)")
    sp.add_argument("--as", dest="as_", metavar="FORMAT",
                    help="read as this format rather than detecting it")
    sp.set_defaults(fn=cmd_import)

    sp = verb("log", "list the runs in the store, or describe one")
    sp.add_argument("ref", nargs="?", metavar="RUN")
    sp.add_argument("-n", type=positive, default=20,
                    help="the last N runs (20)")
    sp.add_argument("--all", action="store_true", help="every run")
    sp.set_defaults(fn=cmd_log)

    sp = verb("show", "print a dataset as a table")
    sp.add_argument("ref", nargs="?", metavar="RUN")
    add_query(sp)
    sp.add_argument("--cols", metavar="A,B", help="only these columns")
    sp.add_argument("--limit", type=nonneg, metavar="N",
                    help="the first N rows")
    sp.add_argument("--full", action="store_true",
                    help="no cell or line cut short")
    sp.add_argument("--vertical", action="store_true",
                    help="one field per line: for wide rows and long text")
    add_format(sp)
    sp.set_defaults(fn=cmd_show)

    sp = verb("stats", "describe columns, or one in depth, or per group")
    sp.add_argument("ref", nargs="?", metavar="RUN")
    sp.add_argument("columns", nargs="*", metavar="COL")
    sp.add_argument("--by", action="append", metavar="COL",
                    help="one row per value of COL (repeatable, or a,b)")
    sp.add_argument("--agg", metavar="LIST",
                    help="with --by: mean,median,min,max,sum,stdev,p05,p95,"
                    "p99,range,count,distinct,first,last,top,worst,auto")
    add_query(sp, sort=False)
    add_format(sp)
    sp.set_defaults(fn=cmd_stats)

    sp = verb("freq", "how often each value occurs, and who holds it")
    sp.add_argument("ref", metavar="RUN")
    sp.add_argument("column", metavar="COL")
    sp.add_argument("--top", type=nonneg, default=20,
                    help="the N most common (20; 0 for all)")
    sp.add_argument("--loose", action="store_true",
                    help="squeeze whitespace and mask numbers before "
                    "counting")
    sp.add_argument("--label", metavar="COL",
                    help="name holders by COL (default host)")
    sp.add_argument("--all-labels", action="store_true",
                    help="every holder, not the first few")
    sp.add_argument("--lines", type=positive, default=12,
                    help="lines of a multi-line value or its diff (12)")
    add_query(sp, sort=False)
    add_format(sp)
    sp.set_defaults(fn=cmd_freq)

    sp = verb("hist", "a histogram of a numeric column")
    sp.add_argument("ref", metavar="RUN")
    sp.add_argument("column", metavar="COL")
    sp.add_argument("--bins", type=positive, help="number of bins")
    sp.add_argument("--bar-width", type=positive, default=40,
                    help="longest bar, in characters (40)")
    add_query(sp, sort=False)
    add_format(sp)
    sp.set_defaults(fn=cmd_hist)

    sp = verb("outliers", "who sits far from the rest (median and MAD)")
    sp.add_argument("ref", metavar="RUN")
    sp.add_argument("column", metavar="COL")
    sp.add_argument("--per", metavar="COL",
                    help="one value per COL first, its median (default: per "
                    "host when hosts repeat)")
    sp.add_argument("--no-per", action="store_true",
                    help="every row is its own opinion")
    sp.add_argument("--z", type=float, default=env_float("Z", 3.5),
                    help="robust z-score past which a value is an outlier "
                    "(QD_Z, 3.5)")
    add_query(sp, sort=False)
    add_format(sp)
    sp.set_defaults(fn=cmd_outliers)

    sp = verb("pivot", "long to wide: rows by columns")
    sp.add_argument("ref", metavar="RUN")
    sp.add_argument("--rows", metavar="COL")
    sp.add_argument("--cols", dest="cols_", metavar="COL")
    sp.add_argument("--values", metavar="COL",
                    help="aggregate this (default: count)")
    sp.add_argument("--agg", default="auto",
                    help="how cells reduce (auto: numbers mean, verdicts "
                    "worst, words most common)")
    add_query(sp, sort=False)
    add_format(sp)
    sp.set_defaults(fn=cmd_pivot)

    sp = verb("trend", "a sparkline per host over time")
    sp.add_argument("ref", metavar="RUN")
    sp.add_argument("column", metavar="COL")
    sp.add_argument("--by", metavar="COL",
                    help="one line per value (default host)")
    sp.add_argument("--over", metavar="COL",
                    help="order by (default ts, timestamp, time, pass, ...)")
    sp.add_argument("--points", type=positive, default=40,
                    help="sparkline width (40)")
    add_query(sp, sort=False)
    add_format(sp)
    sp.set_defaults(fn=cmd_trend)

    sp = verb("diff", "what changed between two datasets")
    sp.add_argument("refs", nargs="+", metavar="RUN",
                    help="OLD NEW, or one run against the last run of the "
                    "same thing")
    sp.add_argument("--key", metavar="COLS",
                    help="match rows on these (default: host, test+target, "
                    "src+dst ...)")
    sp.add_argument("--cols", metavar="COLS", help="compare only these")
    sp.add_argument("--tolerance", type=float, default=0.0, metavar="PCT",
                    help="numeric changes within PCT %% do not count")
    sp.add_argument("--agg", default="auto",
                    help="how a repeated key reduces (auto)")
    sp.add_argument("--limit", type=nonneg, default=30,
                    help="changed keys to list (30; 0 for all)")
    sp.add_argument("--lines", type=positive, default=12,
                    help="lines of a text diff (12)")
    sp.add_argument("--where", action="append", metavar="EXPR",
                    help="applied to both sides")
    add_format(sp)
    sp.set_defaults(fn=cmd_diff)

    sp = verb("export", "write a dataset out: csv, tsv, json, ndjson, md, "
              "overlay")
    sp.add_argument("ref", nargs="?", metavar="RUN")
    add_query(sp)
    sp.add_argument("--cols", metavar="A,B", help="only these columns")
    sp.add_argument("--format", metavar="FMT",
                    help="csv, tsv, json, ndjson, md, or overlay (the "
                    "floor-plan viewer's results); default from -o's "
                    "extension, else csv")
    sp.add_argument("-o", "--output", metavar="FILE")
    sp.add_argument("--prefix", default="qd_",
                    help="overlay: prefix on every test name (qd_)")
    sp.add_argument("--target", metavar="COL",
                    help="overlay: the column naming hosts (default host)")
    sp.add_argument("--run", metavar="LABEL",
                    help="overlay: tag samples run=LABEL (default the "
                    "run id)")
    sp.set_defaults(fn=cmd_export)

    sp = verb("floor", "paint a dataset on the floor plan (dcviz serve)")
    sp.add_argument("ref", nargs="?", metavar="RUN")
    add_query(sp)
    sp.add_argument("--layout", metavar="FILE", help="the .dc floor plan")
    sp.add_argument("--prefix", default="qd_",
                    help="prefix on every overlay name (qd_)")
    sp.add_argument("--target", metavar="COL",
                    help="the column naming hosts (default host)")
    sp.add_argument("-p", "--port", type=positive)
    sp.add_argument("-n", "--no-browser", action="store_true")
    sp.add_argument("--dry-run", action="store_true",
                    help="write the overlay, print the dcviz command, stop")
    sp.set_defaults(fn=cmd_floor)

    sp = verb("view", "explore a dataset full-screen")
    sp.add_argument("ref", nargs="?", metavar="RUN")
    add_query(sp)
    sp.set_defaults(fn=cmd_view)

    sp = verb("web", "the store in a browser: tables, charts, diffs")
    sp.add_argument("--host", default=env("WEB_HOST", "127.0.0.1"),
                    help="address to listen on (QD_WEB_HOST, 127.0.0.1 -- "
                    "this machine only; 0.0.0.0 shares it)")
    sp.add_argument("-p", "--port", type=positive,
                    default=env_int("WEB_PORT", 8100),
                    help="port, or the next free one above it (QD_WEB_PORT, "
                    "8100)")
    sp.add_argument("--layout", metavar="FILE",
                    help="a .dc floor plan for the Floor plan button")
    sp.add_argument("-n", "--no-browser", action="store_true",
                    help="do not open a browser")
    sp.add_argument("-q", "--quiet", action="store_true",
                    help="do not log every request")
    sp.set_defaults(fn=cmd_web)

    sp = verb("doctor", "which of the toolchain this machine can drive")
    sp.set_defaults(fn=cmd_doctor)
    sp = verb("hints", "what you want to know -> the command")
    sp.set_defaults(fn=cmd_hints)
    sp = verb("help", "every verb and every flag")
    sp.set_defaults(fn=None)
    return p, sub


def full_help(parser, sub):
    parts = [__doc__.strip(), ""]
    for name, sp in sub.choices.items():
        if name == "help":
            continue
        parts.append("=" * 72)
        parts.append(sp.format_help().rstrip())
        parts.append("")
    return "\n".join(parts) + "\n"


def glue_sort(argv):
    """`--sort -mbps` means descending, but argparse reads any word that
    starts with a dash as a flag; glue the value on so it reads as one.
    Nothing after `--` is touched: that is somebody's command."""
    out, i = [], 0
    while i < len(argv):
        a = argv[i]
        if a == "--":
            out.extend(argv[i:])
            break
        if a == "--sort" and i + 1 < len(argv) and \
                argv[i + 1].startswith("-") and argv[i + 1] != "--":
            out.append("--sort=" + argv[i + 1])
            i += 2
            continue
        out.append(a)
        i += 1
    return out


def main(argv=None):
    _stdio_safe()
    argv = list(sys.argv[1:] if argv is None else argv)
    argv = glue_sort(argv)
    parser, sub = build_parser()
    if not argv:
        sys.stdout.write(__doc__.lstrip())
        return 0
    try:
        args = parser.parse_args(argv)
    except SystemExit as exc:
        return exc.code if isinstance(exc.code, int) else 2
    if args.version:
        out(VERSION_TEXT)
        return 0
    if args.help or not args.verb:
        sys.stdout.write(__doc__.lstrip())
        return 0
    if args.verb == "help":
        sys.stdout.write(full_help(parser, sub))
        return 0
    if getattr(args, "count", "x") is None:
        args.count = 0 if args.every else 1
    try:
        return args.fn(args) or 0
    except QdError as exc:
        warn(str(exc))
        return exc.code
    except BrokenPipeError:
        try:
            sys.stdout = open(os.devnull, "w")
        except OSError:
            pass
        return 0
    except KeyboardInterrupt:
        sys.stderr.write("\n")
        return 130


if __name__ == "__main__":
    sys.exit(main())
