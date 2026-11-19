# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Martin J. Gallagher
"""Every manual pointer in qd's code names a section the manual has.

    check_readme_pointers.py [ROOT]

ROOT is the tree to check (default: the one this file is in).  A pointer
is `docs/CHAPTER.md: "Section"` (or `README: "Section"` for the front
page), the whole of it on one line; inside a Python string the quotes
are escaped, `docs/judging.md: \\"Waivers\\"`, which reads the same.
"Section" is a heading of the file it names, compared without backticks,
case or runs of spaces: `docs/judging.md: "Against requirements: qd
check"` lands on `## Against requirements: `qd check``.  Headings are
the `#` lines outside fenced code blocks, so a `# comment` in an example
is not one.

Read: quarterdeck/*.py, quarterdeck/web/*.js|html|css and qd.  Every
`README` in them that is not a pointer of that shape (`(README, "X")`,
`README: qd join`, a pointer cut over two lines) is reported too, since
nothing could check where it lands; `README.md`, the file's name, is not
a pointer.  The manual is README.md and docs/*.md, relative to ROOT
(QD-041 moved all but the front page into docs/).

Exit status: 0 when every pointer lands (and says how many there are),
1 with one line a problem (PATH:LINE: what is wrong), 2 when ROOT has no
manual.  Standard library only, Python 3.6 on.
"""

import glob
import io
import os
import re
import sys

MANUAL = ["README.md", "docs/*.md"]
SOURCES = ["quarterdeck/*.py", "quarterdeck/web/*.js",
           "quarterdeck/web/*.html", "quarterdeck/web/*.css", "qd"]

POINTER = re.compile(r'(README|docs/[\w.-]+\.md): (\\?)"([^"\\]+)\2"')
MENTION = re.compile(r"\bREADME\b(?!\.md)")
FENCE = re.compile(r"^ {0,3}(```|~~~)")
HEADING = re.compile(r"^ {0,3}#{1,6}\s+(.*?)\s*#*\s*$")


def norm(title):
    return " ".join(title.replace("`", "").split()).casefold()


def sections(path):
    """The headings of one manual file, normalised."""
    found = set()
    fenced = False
    with io.open(path, encoding="utf-8-sig") as f:
        for line in f:
            if FENCE.match(line):
                fenced = not fenced
                continue
            m = None if fenced else HEADING.match(line)
            if m:
                found.add(norm(m.group(1)))
    return found


def main():
    root = sys.argv[1] if len(sys.argv) > 1 else \
        os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    manual = {}
    if not os.path.isfile(os.path.join(root, "README.md")):
        sys.stderr.write("check_readme_pointers: no README.md in %s\n"
                         % root)
        return 2
    for pattern in MANUAL:
        for path in sorted(glob.glob(os.path.join(root, pattern))):
            rel = os.path.relpath(path, root).replace(os.sep, "/")
            manual["README" if rel == "README.md" else rel] = sections(path)
    problems = []
    count = 0
    for pattern in SOURCES:
        for path in sorted(glob.glob(os.path.join(root, pattern))):
            rel = os.path.relpath(path, root)
            with io.open(path, encoding="utf-8") as f:
                lines = f.read().splitlines()
            for n, line in enumerate(lines, 1):
                pointers = POINTER.findall(line)
                count += len(pointers)
                for page, _, title in pointers:
                    if page not in manual:
                        problems.append('%s:%d: no %s in the manual'
                                        % (rel, n, page))
                    elif norm(title) not in manual[page]:
                        problems.append('%s:%d: %s has no section "%s"'
                                        % (rel, n, page, title))
                readmes = sum(1 for p in pointers if p[0] == "README")
                if len(MENTION.findall(line)) > readmes:
                    problems.append('%s:%d: a README mention this check '
                                    'cannot read: write it README: '
                                    '"Section", on one line' % (rel, n))
    if problems:
        sys.stdout.write("".join(p + "\n" for p in problems))
        return 1
    print("manual pointers: %d, every one names a section of the page "
          "it names (README.md, docs/*.md)" % count)
    return 0


if __name__ == "__main__":
    sys.exit(main())
