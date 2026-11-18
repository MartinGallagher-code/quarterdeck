# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Martin J. Gallagher
"""The help qd gives, checked against its own parser: tests/test_help.sh's
unit.

    help_unit.py QD_DIR card FILE
    help_unit.py QD_DIR hints [flag|verb]
    help_unit.py QD_DIR hints-count
    help_unit.py QD_DIR verb-help [cut]

card: FILE is what `qd --help` printed.  Prints every verb build_parser()
registers that has no usage line on it, one a line, and exits 1; prints
"ok" when there is none.  A usage line is one from "Usage:" to the first
blank line that starts `qd VERB`; `a|b|c` names three verbs, and so does
`a | b [X] | c`, but a verb's own sub-commands (`campaign new|run|...`)
name none: `run` there is campaign's, not qd's.

hints: every qd command `qd hints` suggests is parsed by build_parser(),
as `qd` would parse it.  Prints one line per command that does not parse
(the question, the command and argparse's complaint) and exits 1; prints
"ok" when every one does.  How a hint's text is read:
  - a note in parentheses after two or more spaces is not a command
    ("(then: ...)", "(needs binnacle)");
  - commands are split at " -> ", at ";" and at "  or  ";
  - only the ones starting `qd ` are qd's (provost's are provost's);
  - `...` stands for one value the reader fills in, and so does a word in
    capitals (NAME, COLUMN, CMD), as it is;
  - campaign and doe are cut at `--`, as main() cuts them.
flag or verb runs the same check on a copy of the hints with a flag or a
verb misspelt, to show it fails.  hints-count prints how many hints
there are.

verb-help: for every verb build_parser() registers, `qd help VERB` and
`qd VERB --help`, both through cli.main(), exit 0 and print the same
text, which starts with the verb's usage line (QD-044).  Prints one line
per verb where they differ and exits 1; prints "ok N", N the verbs
checked, when none does.  cut runs it with `qd help VERB` losing its last
line, to show it fails.

Standard library only, Python 3.6 on.
"""

import contextlib
import io
import re
import shlex
import sys

sys.path.insert(0, sys.argv[1])
from quarterdeck import cli  # noqa: E402


def verbs():
    _, sub = cli.build_parser()
    return list(sub.choices)


def card_verbs(text):
    """The verbs the card's usage lines name."""
    named = set()
    inside = False
    for line in text.splitlines():
        if line.startswith("Usage:"):
            inside = True
            line = line[len("Usage:"):]
        elif inside and not line.strip():
            break
        if not inside:
            continue
        m = re.match(r"\s*qd\s+(.*)", line)
        if not m:
            continue
        for group in re.split(r"\s+\|\s+", m.group(1)):
            words = group.split()
            if words:
                named.update(words[0].split("|"))
    return named


def case_card(path):
    with open(path) as f:
        named = card_verbs(f.read())
    missing = [v for v in verbs() if v not in named]
    if missing:
        sys.stdout.write("".join(v + "\n" for v in missing))
        return 1
    print("ok")
    return 0


NOTE = re.compile(r"\s{2,}\([^()]*\)")
SPLIT = re.compile(r"\s+->\s+|\s*;\s+|\s{2,}or\s{2,}")


def hint_commands(text):
    """The qd commands in one hint's text, each as an argv after `qd`."""
    out = []
    for seg in SPLIT.split(NOTE.sub("", text)):
        seg = seg.strip()
        if not seg.startswith("qd "):
            continue
        argv = ["X" if a == "..." else a for a in shlex.split(seg)[1:]]
        out.append((seg, argv))
    return out


def complaint(parser, argv):
    """What argparse says about argv, or None when it parses."""
    argv = cli.glue_sort(argv)
    if argv and argv[0] in ("campaign", "doe") and "--" in argv:
        argv = argv[:argv.index("--")]
    err = io.StringIO()
    try:
        with contextlib.redirect_stderr(err):
            parser.parse_args(argv)
    except SystemExit:
        lines = err.getvalue().strip().splitlines()
        return lines[-1] if lines else "refused"
    return None


def case_hints(mutation=None):
    hints = list(cli.HINTS)
    if mutation == "flag":
        hints = [(q, c.replace("--servers", "--srevers")) for q, c in hints]
    elif mutation == "verb":
        hints = [(q, c.replace("qd outliers", "qd outlyers"))
                 for q, c in hints]
    elif mutation is not None:
        sys.stderr.write("help_unit.py: no such mutation: %s\n" % mutation)
        return 2
    parser, _ = cli.build_parser()
    bad = []
    for q, text in hints:
        cmds = hint_commands(text)
        if text.startswith("qd ") and not cmds:
            bad.append("%s: no qd command found in %r" % (q, text))
        for seg, argv in cmds:
            why = complaint(parser, argv)
            if why:
                bad.append("%s: %s: %s" % (q, seg, why))
    if bad:
        sys.stdout.write("".join(b + "\n" for b in bad))
        return 1
    print("ok")
    return 0


def run_main(argv):
    """cli.main(argv): its exit status and what it printed."""
    out, err = io.StringIO(), io.StringIO()
    with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
        try:
            rc = cli.main(argv)
        except SystemExit as exc:
            rc = exc.code
    return rc, out.getvalue()


def case_verb_help(mutation=None):
    if mutation == "cut":
        real = cli.verb_help

        def cut(sub, name):
            sp = sub.choices.get(name)
            if sp is None:
                return real(sub, name)
            sys.stdout.write(sp.format_help().rstrip("\n").rsplit("\n", 1)[0])
            return 0
        cli.verb_help = cut
    elif mutation is not None:
        sys.stderr.write("help_unit.py: no such mutation: %s\n" % mutation)
        return 2
    bad = []
    names = verbs()
    for v in names:
        rc_a, a = run_main(["help", v])
        rc_b, b = run_main([v, "--help"])
        if rc_a != 0 or rc_b != 0:
            bad.append("%s: qd help %s exits %s, qd %s --help %s"
                       % (v, v, rc_a, v, rc_b))
        elif a != b:
            bad.append("%s: qd help %s and qd %s --help differ" % (v, v, v))
        elif not a.startswith("usage: qd %s " % v):
            bad.append("%s: no usage line: %r" % (v, a[:40]))
    if bad:
        sys.stdout.write("".join(b + "\n" for b in bad))
        return 1
    print("ok %d" % len(names))
    return 0


def main():
    case = sys.argv[2]
    if case == "card":
        return case_card(sys.argv[3])
    if case == "hints":
        return case_hints(sys.argv[3] if len(sys.argv) > 3 else None)
    if case == "hints-count":
        print(len(cli.HINTS))
        return 0
    if case == "verb-help":
        return case_verb_help(sys.argv[3] if len(sys.argv) > 3 else None)
    sys.stderr.write("help_unit.py: no such case: %s\n" % case)
    return 2


if __name__ == "__main__":
    sys.exit(main())
