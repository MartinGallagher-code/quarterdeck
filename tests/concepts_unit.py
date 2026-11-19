# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Martin J. Gallagher
"""docs/concepts.md, checked against qd itself: tests/test_concepts.sh's
unit (QD-042), and tests/test_demo.sh's for `run`.

    concepts_unit.py ROOT examples
    concepts_unit.py ROOT forms
    concepts_unit.py ROOT links [PROVOST_TREE]
    concepts_unit.py ROOT run QD...

ROOT is the tree to check: its docs/concepts.md (PAGE), and for examples
its quarterdeck package.

examples: every qd command on the page -- an inline `qd ...` span, or a
line starting `qd ` in a fenced block -- parses with ROOT's
build_parser(), as `qd` would parse it (campaign and doe cut at `--`);
a bare `qd VERB` is a verb named in a sentence, and only has to be one.
Prints one line per command that does not, with argparse's complaint.

forms: every way of naming a run that ROOT's quarterdeck/store.py
accepts is a form in the first column of the page's "Naming a run"
table, and every form there is one it accepts.  The forms are read from
the code: the words of Store.resolve()'s `latest|last|prev` pattern (and
`~N` when it takes a count), each `ref.startswith("ds:")` prefix as
`ds:NAME`, the separator split_ref() and split_store() split on as
`RUN:TABLE` and `RUN@STORE`, load_ref()'s file or directory as `FILE`,
`DIR`, and each `return` of resolve() by what it returns: a run's id
(`ID`), part of one (`PART`), a run's name (`NAME`), a dataset no run is
named (`DATASET`).  A return this check does not know is reported: a new
form, to document on the page and teach this check.

links: every link on the page lands, and so does every link to the page
in README.md and docs/*.md: a relative file exists, and a `#anchor` is a
heading of the file it names (GitHub's slug: lower case, punctuation
dropped, spaces to hyphens).  A link to this repository on GitHub
(github.com/MartinGallagher-code/quarterdeck/blob/main/PATH) is checked
against ROOT, and one to provost's against PROVOST_TREE when given (a
provost clone); others are not checked (no network).  README.md and
docs/getting-started.md must each link to the page.

run: every example of the "Naming a run" table is run, as QD... (the
command that is qd) with the example's words, in a directory of its own
holding the results.tsv the page names, against the active store, which
is the demo's; each must exit 0, as the page says.

Each case prints "ok" and a count when nothing is wrong and exits 0;
otherwise one line a problem, exit 1.  Exit 2 on bad usage.  Standard
library only, Python 3.6 on.
"""

import contextlib
import glob
import io
import os
import re
import shlex
import shutil
import subprocess
import sys
import tempfile

PAGE = os.path.join("docs", "concepts.md")
FENCE = re.compile(r"^ {0,3}(```|~~~)")
HEADING = re.compile(r"^ {0,3}#{1,6}\s+(.*?)\s*#*\s*$")
LINK = re.compile(r"\[[^\]]*\]\(([^)\s]+)\)")
SPAN = re.compile(r"`([^`]+)`")
OURS = "https://github.com/MartinGallagher-code/quarterdeck/"
PROVOSTS = "https://github.com/MartinGallagher-code/provost/"


def read(path):
    with io.open(path, encoding="utf-8") as f:
        return f.read()


def prose(text):
    """(line number, line, fenced) for every line of a Markdown file."""
    fenced = False
    for n, line in enumerate(text.splitlines(), 1):
        if FENCE.match(line):
            fenced = not fenced
            continue
        yield n, line, fenced


# -- examples -----------------------------------------------------------------

def page_commands(text):
    """(line, command) for every qd command the page shows.  A span cut
    over two lines is joined first, as Markdown joins it."""
    out = []
    para, start = [], 0
    for n, line, fenced in list(prose(text)) + [(0, "", False)]:
        if fenced:
            if line.strip().startswith("qd "):
                out.append((n, line.strip().split("  #")[0].strip()))
            continue
        if line.strip():
            if not para:
                start = n
            para.append(line.strip())
            continue
        for span in SPAN.findall(" ".join(para)):
            if span.startswith("qd "):
                out.append((start, span))
        para = []
    return out


def complaint(cli, parser, argv):
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


def case_examples(root):
    sys.path.insert(0, root)
    from quarterdeck import cli
    parser, sub = cli.build_parser()
    cmds = page_commands(read(os.path.join(root, PAGE)))
    bad = []
    for n, cmd in cmds:
        argv = shlex.split(cmd)[1:]
        if len(argv) == 1 and argv[0] in sub.choices:
            continue    # the command named, as `qd check` is in a sentence
        why = complaint(cli, parser, argv)
        if why:
            bad.append("%s:%d: %s: %s" % (PAGE, n, cmd, why))
    if not cmds:
        bad.append("%s: no qd command found" % PAGE)
    return report(bad, "%d qd commands, every one parses" % len(cmds))


# -- forms --------------------------------------------------------------------

def naming_table(text):
    """[(line, forms, example)] of the page's "Naming a run" table."""
    rows = []
    inside = False
    for n, line, fenced in prose(text):
        m = None if fenced else HEADING.match(line)
        if m:
            inside = m.group(1) == "Naming a run"
            continue
        if inside and line.startswith("|"):
            cells = [c.strip() for c in line.strip().strip("|").split("|")]
            if len(cells) < 3 or cells[0] in ("Form", "") or \
                    set(cells[0]) <= set("-: "):
                continue
            ex = SPAN.findall(cells[2])
            rows.append((n, SPAN.findall(cells[0]), ex[0] if ex else ""))
    return rows


def body(text, name, indent=""):
    """The source of one function, from its def to the next one."""
    m = re.search(r"\n%sdef %s\(.*?(?=\n%sdef |\nclass |\ndef |\Z)"
                  % (indent, name, indent), text, re.S)
    return m.group(0) if m else ""


RETURNS = [  # what resolve() returns -> the form that names it
    (r"Dataset\(self, ref\[\d+:\]\)", None),   # the prefix: ds:NAME
    (r"entries\[-1 - back\]", None),           # the words: latest ...
    (r"e", "ID"),
    (r"named\[-1\]", "NAME"),
    (r"Dataset\(self, ref\)", "DATASET"),
    (r"pre\[0\]", "PART"),
    (r"sub\[0\]", "PART"),
]


def code_forms(root):
    """(forms the resolver takes, forms it may also be written as,
    problems)."""
    src = read(os.path.join(root, "quarterdeck", "store.py"))
    res = body(src, "resolve", "    ")
    need, also, bad = [], [], []
    if not res:
        return need, also, ["quarterdeck/store.py: no Store.resolve()"]
    words, tilde = [], False
    for lit in re.findall(r'\br"([^"]*)"', res):
        for group in re.findall(r"\(([a-z]+(?:\|[a-z]+)+)\)", lit):
            words += group.split("|")
        tilde = tilde or "~(" in lit
    need += words
    if tilde:
        need.append("~N")
        if words:
            need.append(words[0] + "~N")
        also += [w + "~N" for w in words]
    for prefix in re.findall(r'ref\.startswith\("([^"]+)"\)', res):
        need.append(prefix + "NAME")
    for ret in re.findall(r"^\s*return (.+?)\s*$", res, re.M):
        forms = [f for pat, f in RETURNS if re.match(pat + r"$", ret)]
        if not forms:
            bad.append("quarterdeck/store.py: resolve() returns %s, a form "
                       "this check does not know: name it on %s and in "
                       "RETURNS" % (ret, PAGE))
        elif forms[0]:
            need.append(forms[0])
    for fn, what in (("split_ref", "TABLE"), ("split_store", "STORE")):
        sep = re.findall(r'\.rpartition\("([^"]+)"\)', body(src, fn))
        if sep:
            need.append("RUN" + sep[0] + what)
        else:
            bad.append("quarterdeck/store.py: %s() splits on nothing this "
                       "check can find" % fn)
    if "os.path.exists(ref_)" in body(src, "load_ref"):
        need += ["FILE", "DIR"]
    seen = []
    for f in need:
        if f not in seen:
            seen.append(f)
    return seen, also, bad


def case_forms(root):
    need, also, bad = code_forms(root)
    rows = naming_table(read(os.path.join(root, PAGE)))
    on_page = [f for _, forms, _ in rows for f in forms]
    if not rows:
        bad.append('%s: no "Naming a run" table' % PAGE)
    for f in need:
        if f not in on_page:
            bad.append("%s: the resolver takes %s, which the page does not "
                       "name" % (PAGE, f))
    for n, forms, ex in rows:
        for f in forms:
            if f not in need and f not in also:
                bad.append("%s:%d: %s is no form the resolver takes"
                           % (PAGE, n, f))
        if not ex.startswith("qd "):
            bad.append("%s:%d: %s has no example" % (PAGE, n, "/".join(forms)))
    return report(bad, "%d forms, every one on the page: %s"
                  % (len(need), " ".join(need)))


# -- links --------------------------------------------------------------------

def slug(title):
    """GitHub's anchor for a heading."""
    t = re.sub(r"\[([^\]]*)\]\([^)]*\)", r"\1", title).strip().lower()
    return re.sub(r"[^\w\- ]", "", t, flags=re.U).replace(" ", "-")


def anchors(path):
    found, count = set(), {}
    for _, line, fenced in prose(read(path)):
        m = None if fenced else HEADING.match(line)
        if m:
            s = slug(m.group(1))
            n = count.get(s, 0)
            count[s] = n + 1
            found.add(s if n == 0 else "%s-%d" % (s, n))
    return found


def links(path):
    for n, line, fenced in prose(read(path)):
        if not fenced:
            for target in LINK.findall(line):
                yield n, target


def landing(root, path, target, provost):
    """Where a link lands, as a file to check (and its anchor), or a
    reason it is not checked."""
    where, _, anchor = target.partition("#")
    if not where:
        return path, anchor
    for base, tree in ((OURS, root), (PROVOSTS, provost)):
        if where.startswith(base):
            m = re.match(r"(?:blob|tree)/main/(.+)$", where[len(base):])
            if not m or not tree:
                return None, None
            return os.path.join(tree, m.group(1)), anchor
    if re.match(r"^[a-z]+:", where):
        return None, None
    return os.path.normpath(os.path.join(os.path.dirname(path), where)), \
        anchor


def check_link(root, path, n, target, provost, bad):
    dest, anchor = landing(root, path, target, provost)
    if dest is None:
        return 0
    rel = os.path.relpath(path, root)
    if not os.path.exists(dest):
        bad.append("%s:%d: %s: no such file" % (rel, n, target))
    elif anchor and dest.endswith(".md") and anchor not in anchors(dest):
        bad.append("%s:%d: %s: no heading #%s there" % (rel, n, target,
                                                         anchor))
    return 1


def case_links(root, provost=None):
    page = os.path.join(root, PAGE)
    bad = []
    checked = 0
    for n, target in links(page):
        checked += check_link(root, page, n, target, provost, bad)
    to_page = {}
    others = [os.path.join(root, "README.md")] + sorted(
        glob.glob(os.path.join(root, "docs", "*.md")))
    for path in others:
        if os.path.abspath(path) == os.path.abspath(page):
            continue
        for n, target in links(path):
            dest, _ = landing(root, path, target, provost)
            if dest and os.path.abspath(dest) == os.path.abspath(page):
                to_page[os.path.relpath(path, root)] = True
                checked += check_link(root, path, n, target, provost, bad)
    for rel in ("README.md", os.path.join("docs", "getting-started.md")):
        if rel not in to_page:
            bad.append("%s: no link to %s" % (rel, PAGE))
    return report(bad, "%d links, every one lands" % checked)


# -- run ----------------------------------------------------------------------

def case_run(root, qd):
    rows = naming_table(read(os.path.join(root, PAGE)))
    where = tempfile.mkdtemp()
    bad = []
    try:
        with io.open(os.path.join(where, "results.tsv"), "w") as f:
            f.write(u"host\tmbps\nn1\t900\n")
        for n, forms, ex in rows:
            argv = qd + shlex.split(ex)[1:]
            p = subprocess.Popen(argv, cwd=where, stdout=subprocess.PIPE,
                                 stderr=subprocess.PIPE)
            _, err = p.communicate()
            if p.returncode != 0:
                tail = err.decode("utf-8", "replace").strip().splitlines()
                bad.append("%s:%d: %s exits %d: %s" % (
                    PAGE, n, ex, p.returncode, tail[-1] if tail else ""))
    finally:
        shutil.rmtree(where)
    if not rows:
        bad.append('%s: no "Naming a run" table' % PAGE)
    return report(bad, "%d examples, every one exits 0" % len(rows))


def report(bad, good):
    if bad:
        sys.stdout.write("".join(b + "\n" for b in bad))
        return 1
    print("ok: " + good)
    return 0


def main():
    if len(sys.argv) < 3:
        sys.stderr.write("usage: concepts_unit.py ROOT examples|forms|"
                         "links [PROVOST_TREE]|run QD...\n")
        return 2
    root, case = os.path.abspath(sys.argv[1]), sys.argv[2]
    if case == "examples":
        return case_examples(root)
    if case == "forms":
        return case_forms(root)
    if case == "links":
        return case_links(root, sys.argv[3] if len(sys.argv) > 3 else None)
    if case == "run" and len(sys.argv) > 3:
        return case_run(root, sys.argv[3:])
    sys.stderr.write("concepts_unit.py: no such case: %s\n" % case)
    return 2


if __name__ == "__main__":
    sys.exit(main())
