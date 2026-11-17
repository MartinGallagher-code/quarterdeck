# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Martin J. Gallagher
"""The help qd gives, checked against its own parser: tests/test_help.sh's
unit.

    help_unit.py QD_DIR card FILE

card: FILE is what `qd --help` printed.  Prints every verb build_parser()
registers that has no usage line on it, one a line, and exits 1; prints
"ok" when there is none.  A usage line is one from "Usage:" to the first
blank line that starts `qd VERB`; `a|b|c` names three verbs, and so does
`a | b [X] | c`, but a verb's own sub-commands (`campaign new|run|...`)
name none: `run` there is campaign's, not qd's.

Standard library only, Python 3.6 on.
"""

import re
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


def main():
    case = sys.argv[2]
    if case == "card":
        return case_card(sys.argv[3])
    sys.stderr.write("help_unit.py: no such case: %s\n" % case)
    return 2


if __name__ == "__main__":
    sys.exit(main())
