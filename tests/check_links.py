# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Martin J. Gallagher
"""Every link between the README and the manual in docs/ lands.

    check_links.py [ROOT]

ROOT is the tree to check (default: the one this file is in).  Read:
README.md and docs/*.md.  Checked, in each: every Markdown link and
image, `[text](target)` or `![alt](target)`, outside fenced code blocks
and `code spans`.  A relative target must name a file that exists; a
`#anchor` (alone, or after a .md file) must be a heading of that file,
by GitHub's slug: lower case, punctuation dropped, spaces to hyphens, a
repeated heading's second anchor `-1`.  A link to this repository on
GitHub (blob/main/ or tree/main/, as the front page uses so it works on
PyPI) is checked against ROOT the same way.  Other URLs are not checked:
no network.

Exit status: 0 when every link lands (and says how many), 1 with one line
a problem (PATH:LINE: TARGET: what is wrong), 2 when ROOT has no
README.md.  Standard library only, Python 3.6 on.
"""

import glob
import io
import os
import re
import sys

OURS = "https://github.com/MartinGallagher-code/quarterdeck/"
FENCE = re.compile(r"^ {0,3}(```|~~~)")
HEADING = re.compile(r"^ {0,3}#{1,6}\s+(.*?)\s*#*\s*$")
CODE = re.compile(r"(`+).*?\1")
LINK = re.compile(r"!?\[(?:[^\[\]]|\[[^\]]*\])*\]\(\s*<?([^)\s>]+)>?"
                  r"(?:\s+\"[^\"]*\")?\s*\)")


def prose(path):
    """(line number, line) for each line outside a fenced block."""
    fenced = False
    with io.open(path, encoding="utf-8-sig") as f:
        for n, line in enumerate(f, 1):
            if FENCE.match(line):
                fenced = not fenced
            elif not fenced:
                yield n, line.rstrip("\n")


def slug(title):
    """GitHub's anchor for a heading."""
    t = re.sub(r"\[([^\]]*)\]\([^)]*\)", r"\1", title).strip().lower()
    return re.sub(r"[^\w\- ]", "", t, flags=re.U).replace(" ", "-")


_anchors = {}


def anchors(path):
    if path not in _anchors:
        found, count = set(), {}
        for _, line in prose(path):
            m = HEADING.match(line)
            if m:
                s = slug(m.group(1))
                n = count.get(s, 0)
                count[s] = n + 1
                found.add(s if n == 0 else "%s-%d" % (s, n))
        _anchors[path] = found
    return _anchors[path]


def landing(root, path, target):
    """The file a link names and its anchor, or (None, None) when it is
    not ours to check."""
    where, _, anchor = target.partition("#")
    if not where:
        return path, anchor
    if where.startswith(OURS):
        m = re.match(r"(?:blob|tree)/main/(.*)$", where[len(OURS):])
        if not m:
            return None, None
        return os.path.join(root, m.group(1).rstrip("/")), anchor
    if re.match(r"^[A-Za-z][A-Za-z0-9+.-]*:", where):
        return None, None
    return os.path.normpath(os.path.join(os.path.dirname(path), where)), \
        anchor


def main():
    root = sys.argv[1] if len(sys.argv) > 1 else \
        os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    readme = os.path.join(root, "README.md")
    if not os.path.isfile(readme):
        sys.stderr.write("check_links: no README.md in %s\n" % root)
        return 2
    pages = [readme] + sorted(glob.glob(os.path.join(root, "docs", "*.md")))
    problems = []
    count = 0
    for path in pages:
        rel = os.path.relpath(path, root)
        for n, line in prose(path):
            for target in LINK.findall(CODE.sub("", line)):
                dest, anchor = landing(root, path, target)
                if dest is None:
                    continue
                count += 1
                if not os.path.exists(dest):
                    problems.append("%s:%d: %s: no such file"
                                    % (rel, n, target))
                elif anchor and os.path.isdir(dest):
                    problems.append("%s:%d: %s: an anchor on a directory"
                                    % (rel, n, target))
                elif anchor and dest.endswith(".md") and \
                        anchor not in anchors(dest):
                    problems.append("%s:%d: %s: no heading #%s in %s"
                                    % (rel, n, target, anchor,
                                       os.path.relpath(dest, root)))
    if problems:
        sys.stdout.write("".join(p + "\n" for p in problems))
        return 1
    print("manual links: %d, every one lands, in %d pages"
          % (count, len(pages)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
