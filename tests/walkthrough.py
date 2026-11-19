#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Martin J. Gallagher
"""Run a page's commands, and compare what they print with the page.

    walkthrough.py PAGE DIR [--update]

Every ```console block in PAGE (docs/getting-started.md) is a
transcript: a line that starts `$ ` is a command, and the lines after it,
up to the next command or the end of the block, are what it prints.
`$ echo $?` prints the exit status of the command before it, and any
other command must exit 0, so a status the page does not show is a
failure.  A block fenced as anything else (```bash, ```text) is not run:
it needs a fleet, a browser or a terminal.

The commands run in bash, one after another, in DIR, so a file one of
them writes is there for the next; `qd` is whichever is first on PATH.
A qd command is given --width after its verb, so its tables are cut as a
terminal that wide cuts them: the width is the page's own, from its
`<!-- walkthrough: width N -->` line (100 when there is none).  Each
line is compared without its trailing blanks.

A block whose opening fence follows a `<!-- walkthrough: loose -->` line
runs a command that asks this machine, whose answers are the reader's own
(its name, its kernel, the time).  In such a block, and only there:
  - a line that is `[...]` and nothing else stands for any number of
    lines, none included; `[...]` inside a line, for any text in it;
  - this machine's name, as qd gives it (the hostname up to its first
    dot), is compared as the name the page's `<!-- walkthrough: this
    machine is NAME -->` line gives, so the page can show one name;
  - a run's time stamp (20261119-160338) matches any other, and a run of
    two or more blanks any other such run, since a longer name or a later
    run widens the columns it sits in.
Everything else in a loose block is compared as exactly as anywhere else.
--update does not rewrite a loose block (it would lose its `[...]`): one
that no longer matches is reported, to be put right by hand.

Exit 0 when every command printed what the page shows, 1 with a diff of
each one that did not.  --update writes what the commands printed back
into the page instead, and exits 0: for a change to a reader that alters
what the page shows on purpose (then read the diff before committing it).
"""

import difflib
import io
import re
import socket
import subprocess
import sys

FENCE_RE = re.compile(r"^(```+|~~~+)\s*(\S*)\s*$")
WIDTH_RE = re.compile(r"<!--\s*walkthrough:\s*width\s+(\d+)\s*-->")
LOOSE_RE = re.compile(r"^\s*<!--\s*walkthrough:\s*loose\s*-->\s*$")
MACHINE_RE = re.compile(
    r"<!--\s*walkthrough:\s*this machine is\s+(\S+)\s*-->")
STATUS = "echo $?"
ANY = "[...]"
STAMP_RE = re.compile(r"\d{8}-\d{6}")
BLANKS_RE = re.compile(r" {2,}")


def blocks(lines):
    """[(first, last, loose)]: the lines of each ```console block, fences
    out, and whether a `<!-- walkthrough: loose -->` line opens it."""
    out, i = [], 0
    while i < len(lines):
        m = FENCE_RE.match(lines[i])
        if not m:
            i += 1
            continue
        fence, lang = m.group(1), m.group(2)
        j = i + 1
        while j < len(lines) and not lines[j].startswith(fence[:3]):
            j += 1
        if lang == "console":
            out.append((i + 1, j, i > 0 and bool(LOOSE_RE.match(lines[i - 1]))))
        i = j + 1
    return out


def steps(lines, first, last):
    """[(command, [expected lines], index of its first output line,
    index after its last)] for one block."""
    out = []
    i = first
    while i < last:
        if not lines[i].startswith("$ "):
            raise SystemExit("walkthrough: line %d is in a console block but "
                             "follows no command: %r" % (i + 1, lines[i]))
        cmd = lines[i][2:]
        j = i + 1
        while j < last and not lines[j].startswith("$ "):
            j += 1
        out.append((cmd, lines[i + 1:j], i + 1, j))
        i = j
    return out


def widened(cmd, width):
    """`qd VERB ...` as `qd VERB --width W ...`; anything else as it is."""
    words = cmd.split(" ")
    if len(words) >= 2 and words[0] == "qd" and \
            re.match(r"^[a-z]+$", words[1]):
        return " ".join(words[:2] + ["--width", str(width)] + words[2:])
    return cmd


def this_machine():
    """This machine's name as qd gives it (hosts.local_name)."""
    try:
        name = socket.gethostname().strip()
    except OSError:
        name = ""
    if not name:
        return "localhost"
    return name if re.match(r"^[0-9.:]+$", name) else (
        name.split(".", 1)[0] or "localhost")


def line_re(want):
    """A loose block's line as a pattern: `[...]` any text, a time stamp
    any stamp, two or more blanks any two or more."""
    parts = []
    for piece in want.split(ANY):
        out, at = [], 0
        for m in re.finditer(r"\d{8}-\d{6}| {2,}", piece):
            out.append(re.escape(piece[at:m.start()]))
            out.append(r"\d{8}-\d{6}" if m.group(0)[0].isdigit()
                       else " {2,}")
            at = m.end()
        out.append(re.escape(piece[at:]))
        parts.append("".join(out))
    return re.compile("^" + ".*?".join(parts) + "$")


def loose_match(want, got):
    """Whether got (a loose block's output) is what want shows."""
    pats = [None if w.strip() == ANY else line_re(w) for w in want]
    memo = {}

    def at(i, j):
        if (i, j) in memo:
            return memo[(i, j)]
        if i == len(pats):
            ok = j == len(got)
        elif pats[i] is None:
            ok = any(at(i + 1, k) for k in range(j, len(got) + 1))
        else:
            ok = j < len(got) and bool(pats[i].match(got[j])) and \
                at(i + 1, j + 1)
        memo[(i, j)] = ok
        return ok
    return at(0, 0)


def as_named(got, machine, name):
    """got with this machine's name given as the page's NAME."""
    if not name or machine == name:
        return got
    word = re.compile(r"(?<![A-Za-z0-9_.-])%s(?![A-Za-z0-9_-]|\.\w)"
                      % re.escape(machine))
    return [word.sub(name, ln) for ln in got]


def run(cmd, cwd, width):
    p = subprocess.Popen(["bash", "-c", widened(cmd, width)], cwd=cwd,
                         stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                         stdin=subprocess.DEVNULL)
    out, _ = p.communicate()
    text = out.decode("utf-8", "replace")
    got = [ln.rstrip() for ln in text.split("\n")]
    if got and got[-1] == "":
        got.pop()
    return p.returncode, got


def main(argv):
    update = "--update" in argv
    argv = [a for a in argv if a != "--update"]
    if len(argv) != 2:
        sys.stderr.write(__doc__.split("\n\n")[1] + "\n")
        return 2
    page, cwd = argv
    with io.open(page, encoding="utf-8") as fh:
        text = fh.read()
    lines = text.split("\n")
    m = WIDTH_RE.search(text)
    width = int(m.group(1)) if m else 100
    m = MACHINE_RE.search(text)
    name, machine = (m.group(1) if m else None), this_machine()
    bad, n, prev = [], 0, None
    # (first, last, new lines) to put back, last first
    edits = []
    for first, last, loose in blocks(lines):
        rc = None
        for cmd, want, lo, hi in steps(lines, first, last):
            n += 1
            if cmd == STATUS:
                if rc is None:
                    raise SystemExit("walkthrough: line %d: `$ %s` follows "
                                     "no command" % (lo, STATUS))
                got = [str(rc)]
                rc = 0
            else:
                if rc not in (None, 0):
                    bad.append("%s: exit %d, and the page shows no `$ %s` "
                               "after it" % (prev, rc, STATUS))
                rc, got = run(cmd, cwd, width)
                prev = cmd
            want = [ln.rstrip() for ln in want]
            if loose and cmd != STATUS:
                got = as_named(got, machine, name)
                if not loose_match(want, got):
                    bad.append("$ %s  (line %d, a loose block: put it right "
                               "by hand)\n%s" % (cmd, lo, "\n".join(
                                   difflib.unified_diff(
                                       want, got, "the page",
                                       "what it printed", lineterm=""))))
            elif got != want:
                if update:
                    edits.append((lo, hi, got))
                else:
                    bad.append("$ %s  (line %d)\n%s" % (cmd, lo, "\n".join(
                        difflib.unified_diff(
                            want, got,
                            "the page", "what it printed", lineterm=""))))
        if rc not in (None, 0):
            bad.append("%s: exit %d, and the page shows no `$ %s` after it"
                       % (prev, rc, STATUS))
    if update:
        for lo, hi, got in sorted(edits, reverse=True):
            lines[lo:hi] = got
        with io.open(page, "w", encoding="utf-8") as fh:
            fh.write("\n".join(lines))
        sys.stdout.write("walkthrough: %d commands, %d outputs rewritten in "
                         "%s\n" % (n, len(edits), page))
        for b in bad:
            sys.stdout.write(b + "\n\n")
        return 1 if bad else 0
    if not n:
        sys.stdout.write("walkthrough: no commands in %s\n" % page)
        return 1
    for b in bad:
        sys.stdout.write(b + "\n\n")
    sys.stdout.write("walkthrough: %d commands, %d not as the page shows\n"
                     % (n, len(bad)))
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
