# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Martin J. Gallagher
"""qd survey: ask every host the standard questions, and show one screen
of who stands out (QD-060, from QD-057's beginner layer).

It is `qd probe facts inventory`, run as that command runs it -- the same
fan-out, the same runs filed under the same names -- followed by what a
newcomer would otherwise put together from `qd freq`, `qd outliers
--categorical` and `qd outliers`, each with column names they do not know
yet.  Nothing here reads or counts on its own: the probes are
cli.run_probes, the values most hosts share are stats.freq, the hosts that
differ are cli.report_categorical (differs.find), and the numeric
outliers are stats.outliers, each read from the store through a Namespace
the plain command's own parser makes from the very command line printed
under WHAT TO DO NEXT.

What it looks at is a fixed, short list (SHARED, NUMERIC), so the screen
stays one screen for any fleet: about 40 lines at most.  A cell a host
left blank is not measured -- never a value of its own, never zero.

Exit status: 0 when every host answered every probe and nothing stands
out; 1 when a host did not answer, differs or is a numeric outlier (the
summary's FOUND line says which step found it); 2 on a usage error.
"""

import shlex
import sys

from .common import PROG, die, plural
from . import probes, render, stats, query

# what `qd survey` asks: the standard questions
ASKED = ["facts", "inventory"]

# the values most hosts share, one line each: (probe, column, what it is).
# OS, kernel, firmware, CPU, memory -- and no more, so it stays one screen
SHARED = [
    ("os", "os", "OS"),
    ("os", "kernel", "kernel"),
    ("firmware", "bios_version", "firmware (BIOS)"),
    ("firmware", "cpu_model", "CPU"),
    ("facts", "cpu.count", "CPUs"),
    ("facts", "mem.total_kb", "memory (kB)"),
]

# the numbers held against the fleet's median and MAD, as qd outliers does
NUMERIC = [
    ("facts", "cpu.busy_pct"),
    ("facts", "cpu.load1"),
    ("facts", "cpu.iowait_pct"),
    ("facts", "mem.available_pct"),
    ("facts", "fs.fullest_pct"),
    ("facts", "net.tcp_retrans_pct"),
    ("facts", "therm.max_temp_c"),
    ("packages", "packages"),
]

# how many hosts each section names before it says how many more
SHOW = 3
# a value is cut to this many characters on the screen
CELL = 38


def cut(v, n=CELL):
    v = render.first_line(v)
    return v if len(v) <= n else v[:n - 3] + "..."


def quoted(words):
    return " ".join(shlex.quote(w) for w in words)


def store_words(args):
    return ["--store", args.store] if getattr(args, "store", None) else []


def probe_command(args, names):
    """The plain `qd probe` command this survey ran: its own command line
    with `survey` turned into `probe NAMES`."""
    argv = list(getattr(args, "_argv", None) or ["survey"])
    if "survey" in argv:
        i = argv.index("survey")
        argv = argv[:i] + ["probe"] + names + argv[i + 1:]
    else:
        argv = ["probe"] + names + argv
    return "%s %s" % (PROG, quoted(argv))


def plain(cli, words):
    """A plain read command's Namespace, made by qd's own parser from the
    words printed for it: what ran is what is shown."""
    parser, _ = cli.build_parser()
    try:
        return parser.parse_args(words)
    except SystemExit:
        die("qd survey made a command its own parser refuses: qd %s"
            % quoted(words))


def ok_rows(t):
    return t.derive(rows=query.where(t, ["status=ok"])) if t.has(
        "status", prefix=False) else t


def cmd_survey(cli, args):
    if args.every or (args.count or 1) != 1:
        die("qd survey asks once: --every and --count are qd probe's "
            "(qd probe facts inventory --every S)")
    names = probes.expand(ASKED)
    skipped, run = [], []
    for n in names:
        ok, where = probes.available(probes.get(n))
        if ok:
            run.append(n)
        else:
            skipped.append((n, where))
    if args.dry_run:
        return cli.run_probes(args, run)[0]
    # not the probes' worst status: the summary says what each step found
    _, jobs = cli.run_probes(args, run, say=False)
    return summarise(cli, args, names, run, skipped, jobs)


def summarise(cli, args, names, run, skipped, jobs):
    order = [n for n in run if n in jobs]
    if not order:
        die("qd survey filed nothing to read back", 2)
    first = jobs[order[0]]
    hosts = [r.host.name for r in first.last]
    lone = len(hosts) == 1
    asked = [n for n in ASKED if n not in [s for s, _ in skipped]] or \
        [n for n in names if n in run]
    tables = {}
    for n in order:
        ns = plain(cli, ["show", jobs[n].entry.id] + store_words(args))
        tables[n] = cli.load(ns)

    # -- who did not answer: any probe, any host, the last pass ----------
    bad = {}
    for n in order:
        for r in jobs[n].last:
            if r.outcome != cli.fleet.OK:
                bad.setdefault(r.host.name, []).append((n, r))
    lines = []
    lines.append("%s survey -- %s asked %s (%s): %s" % (
        PROG, plural(len(hosts), "host"), " and ".join(asked),
        plural(len(order), "probe"),
        "every host answered every probe" if not bad else
        "%s did not answer every probe" % plural(len(bad), "host")))
    lines.append("  stored   %s in %s" % (
        ", ".join(order), first.entry.store.shown()))
    if skipped:
        lines.append("  skipped  %s" % "; ".join(
            "%s: not installed here (%s)" % (n, w) for n, w in skipped))

    # -- the values most hosts share -------------------------------------
    lines.append("")
    lines.append("  WHAT MOST HOSTS SAY")
    shared = []
    for probe, col, what in SHARED:
        t = tables.get(probe)
        if t is None or not t.has(col, prefix=False):
            continue
        s = ok_rows(t)
        name = s.colname(col)
        ci = s.index(name)
        # blank is not measured: neither a value nor counted
        s = s.derive(rows=[r for r in s.rows if r[ci].strip()])
        if not s.rows:
            continue
        fr = stats.freq(s, name)
        measured = sum(len(lab) or n for _, n, lab in fr)
        v, n, lab = fr[0]
        held = len(lab) or n
        shared.append((probe, name))
        lines.append("    %-16s %-*s %d of %d%s" % (
            what, CELL, cut(v), held, measured,
            ("   (+%s)" % plural(len(fr) - 1, "other value"))
            if len(fr) > 1 else ""))
    if not shared:
        lines.append("    nothing measured")

    # -- the hosts that differ from the rest, value by value -------------
    differ, splits, cat_cmds = [], [], []
    for probe in [p for p in ("os", "firmware") if p in tables]:
        cols = [c for p, c in shared if p == probe]
        if not cols:
            continue
        words = ["outliers", probe, ",".join(cols), "--categorical"]
        ns = plain(cli, words + store_words(args))
        t = cli.load(ns, jobs[probe].entry.id)
        _, ot, found = cli.report_categorical(ns, t, cli.subset(ns, t))
        gname = ot.columns[0]
        for row in ot.rows:
            r = dict(zip(ot.columns, row))
            if r["verdict"] == "split":
                splits.append((probe, r, gname))
            else:
                differ.append((probe, r, gname))
        cat_cmds.append((words, gname, found))
    if not lone:
        lines.append("")
        who = sorted(set(r["host"] for _, r, _ in differ))
        lines.append("  WHO DIFFERS FROM THE REST%s" % (
            "  none" if not who and not splits else ""))
        for h in who[:SHOW]:
            mine = [(p, r, g) for p, r, g in differ if r["host"] == h]
            lines.append("    %-16s %s" % (h, "; ".join(
                "%s %s (most%s: %s)" % (
                    r["column"], cut(r["value"], 24),
                    (" in %s %s" % (g, r[g])) if g != "group" else "",
                    cut(r["majority"], 24)) for _, r, g in mine[:2]) + (
                "; +%d more" % (len(mine) - 2) if len(mine) > 2 else "")))
        if len(who) > SHOW:
            lines.append("    ... and %s" % plural(len(who) - SHOW,
                                                 "more host"))
        if splits:
            cols = sorted(set(r["column"] for _, r, _ in splits))
            lines.append("    no majority at all in %s" % ", ".join(cols))

    # -- the numeric outliers: median and MAD, as qd outliers ------------
    found_num, num_cmd, z = [], None, None
    for probe, col in NUMERIC:
        if probe not in tables or not tables[probe].has(col, prefix=False):
            continue
        words = ["outliers", probe, tables[probe].colname(col)]
        ns = plain(cli, words + store_words(args))
        t = cli.load(ns, jobs[probe].entry.id)
        s = cli.subset(ns, t)
        name = s.colname(ns.column)
        if not any(v is not None for v in s.numbers(name)):
            continue
        per = None if ns.no_per else (ns.per or stats.default_per(s, name))
        rows, info = stats.outliers(s, name, per, ns.z, ns.method, ns.k)
        z = ns.z
        if num_cmd is None or (rows and not found_num):
            num_cmd = words
        for r in rows:
            found_num.append((name, r, info))
    if not lone:
        lines.append("")
        lines.append("  FAR FROM THE MEDIAN%s" % (
            ("  (robust z beyond %s)" % stats.fmt_num(z)) if found_num
            else "  none" if num_cmd else "  nothing numeric measured"))
        for name, r, info in found_num[:SHOW]:
            cells = stats.outlier_cells([r])[0]
            lines.append("    %-16s %s %s (median %s, z %s)" % (
                cut(str(cells[0]), 16), name, cells[1],
                stats.fmt_num(info["median"]), cells[3]))
        if len(found_num) > SHOW:
            lines.append("    ... and %d more" % (len(found_num) - SHOW))
    else:
        lines.append("")
        lines.append("  ONE HOST  nothing to compare it against: who differs "
                     "and who is far from")
        lines.append("            the median need two or more.  `%s demo` "
                     "makes a practice fleet." % PROG)

    # -- who did not answer -----------------------------------------------
    if bad:
        lines.append("")
        lines.append("  DID NOT ANSWER")
        for h in sorted(bad)[:SHOW]:
            outs = bad[h]
            kinds = sorted(set(r.outcome for _, r in outs))
            if len(outs) == len(order) and len(kinds) == 1:
                lines.append("    %-16s %s: %s" % (h, kinds[0], cut(
                    outs[0][1].error(), 58)))
            else:
                lines.append("    %-16s %s in %s" % (h, "/".join(kinds),
                                                    ", ".join(
                                                        n for n, _ in outs)))
        if len(bad) > SHOW:
            lines.append("    ... and %s" % plural(len(bad) - SHOW,
                                                 "more host"))

    # -- what was found, and by which step --------------------------------
    found = []
    if bad:
        found.append("%s did not answer (qd probe)" % plural(len(bad),
                                                             "host"))
    ndiff = len(set(r["host"] for _, r, _ in differ))
    if ndiff:
        found.append("%s differ%s (qd outliers --categorical)" % (
            plural(ndiff, "host"), "s" if ndiff == 1 else ""))
    if splits:
        found.append("%s with no majority (qd outliers --categorical)"
                     % plural(len(set(r["column"] for _, r, _ in splits)),
                              "column"))
    if found_num:
        found.append("%s far from the median (qd outliers)"
                     % plural(len(found_num), "value"))
    lines.append("")
    lines.append("  FOUND  %s" % (found[0] if found else
                                  "nothing: every host answered, and none "
                                  "stands out"))
    lines.extend("         %s" % f for f in found[1:])

    # -- the plain commands it used, with real column names ---------------
    sw = store_words(args)
    tips = [(probe_command(args, asked),
             "the same questions; each probe's report in full")]
    if bad:
        tips.append(("%s show %s" % (PROG, quoted(
            [("os" if "os" in order else order[0]), "--where",
             "status!=ok"] + sw)),
            "who did not answer, and why"))
    fcol = None
    for probe, col in shared:
        if any(r["column"] == col for p, r, _ in differ + splits
               if p == probe):
            fcol = (probe, col)
            break
    fcol = fcol or (shared[1] if len(shared) > 1 else
                    shared[0] if shared else None)
    if fcol:
        tips.append(("%s freq %s" % (PROG, quoted(list(fcol) + sw)),
                     "every value of %s, and who holds it" % fcol[1]))
    hits = [(w, g) for w, g, hit in cat_cmds if hit] or \
        [(w, g) for w, g, _ in cat_cmds[:1]]
    for words, gname in hits:
        tips.append(("%s %s" % (PROG, quoted(words + sw)),
                     "who differs from the rest of their %s" % (
                         "rack" if gname != "group" else "fleet")))
    if num_cmd:
        tips.append(("%s %s" % (PROG, quoted(num_cmd + sw)),
                     "who is far from the median of %s" % num_cmd[2]))
    lines.extend(cli.next_steps(tips))
    sys.stdout.write(render.page(lines))
    return 1 if found else 0

