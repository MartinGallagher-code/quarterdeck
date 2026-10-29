# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Martin J. Gallagher
"""Filing through provost.

Everything qd keeps goes into the store by running provost, never by
writing the store's files: provost owns the format, the parsing, the lock
and the commit.  A run files

    a capture per host (and pass) that printed anything:
        '#% run=RUN host=HOST [pass=N] [attr=value ...]', then its stdout
    qd.hosts   one table: every host's status, whether it printed or not
    qd.runs    one row: what ran, where, when -- filed last, so a run that
               is listed has everything it filed in place

as one `provost batch` where provost has it: one commit, the answers
parsed in parallel, and --context-columns, so `provost show NAME` says
which host said what without qd.  A provost without batch (2.1.0, on
PyPI) files them one capture at a time, a few in parallel, and qd puts
the host back from each capture's prologue just the same.
"""

import os
import re
import shutil
import subprocess
import tempfile
from concurrent.futures import ThreadPoolExecutor

from .common import die, env, env_int, plural, write_text
from . import store as storemod, tools


def find():
    """argv that runs provost, or None (QD_PROVOST, PATH, the module)."""
    argv = tools.find_tool("provost")
    if argv and not (shutil.which(argv[0]) or os.path.isfile(argv[0])):
        return None
    return argv


def dataset_name(label):
    """A name provost takes: letters, digits, '.', '_', '-', starting with
    a letter or digit, no '..' -- and never one of qd's own tables."""
    s = re.sub(r"[^A-Za-z0-9._-]+", "_", label or "")
    s = re.sub(r"\.{2,}", ".", s).strip("._-")
    if not s:
        s = "run"
    if s == "unsorted" or s.startswith("qd."):
        s = "run-" + s
    return s


def cell(text):
    return (text or "").replace("\t", " ").replace("\r", " ") \
        .replace("\n", " ")


def own_tsv(columns, rows):
    """qd's own tables, as provost is to read them: free text escaped."""
    text = [c in storemod.TEXT_COLUMNS for c in columns]
    lines = ["\t".join(columns)]
    for r in rows:
        lines.append("\t".join(storemod.escape(v) if t else cell(v)
                               for t, v in zip(text, r)))
    return "\n".join(lines) + "\n"


def table_tsv(t):
    """A table qd read, as plain TSV: tabs and newlines in a cell become
    spaces, a blank stays blank."""
    lines = ["\t".join(cell(c) for c in t.columns)]
    for r in t.rows:
        lines.append("\t".join(cell(v) for v in r))
    return "\n".join(lines) + "\n"


def prologue(pairs, extra=()):
    words = " ".join("%s=%s" % (k, re.sub(r"\s+", "_", v)) for k, v in pairs
                     if v != "" and storemod.KEY_RE.match(k))
    lines = (["#% " + words] if words else []) + list(extra)
    return "".join(ln + "\n" for ln in lines)


def body(text):
    """What follows a prologue.  An answer that itself starts with '#%'
    lines gets a blank line first, so provost keeps them as data."""
    return ("\n" + text) if text.startswith("#%") else text


class Batch(object):
    """The inputs of one filing, written to a scratch directory, in the
    order their captures are to take ids."""

    def __init__(self):
        self.dir = tempfile.mkdtemp(prefix="qd-file-")
        self.inputs = []

    def add(self, dataset, text):
        path = os.path.join(self.dir, "%05d.txt" % len(self.inputs))
        write_text(path, text)
        self.inputs.append((dataset, path))
        return path

    def cleanup(self):
        shutil.rmtree(self.dir, ignore_errors=True)


class Provost(object):
    def __init__(self, store, argv=None):
        self.store = store
        self.argv = argv if argv is not None else find()
        self._batch = None

    def require(self, why="keep it"):
        if not self.argv:
            die("qd files what it brings back through provost, which is "
                "not installed here, so there is nowhere to %s.\n"
                "  pip install provost   (or point QD_PROVOST at one; "
                "--no-store only shows it)" % why)

    def _env(self):
        e = dict(os.environ)
        e["PROVOST_WORKSPACE"] = self.store.root
        e["PROVOST_ASYNC"] = "0"
        e.pop("PROVOST_CONTEXT_COLUMNS", None)
        return e

    def call(self, args):
        try:
            p = subprocess.Popen(self.argv + list(args),
                                 stdout=subprocess.PIPE,
                                 stderr=subprocess.PIPE,
                                 stdin=subprocess.DEVNULL, env=self._env())
            out, err = p.communicate()
        except OSError as exc:
            die("cannot run provost (%s): %s"
                % (" ".join(self.argv), exc.strerror or exc))
        return (p.returncode, out.decode("utf-8", "replace"),
                err.decode("utf-8", "replace"))

    def has_batch(self):
        """`provost batch` came with --context-columns: one probe says
        whether this provost has both."""
        if self._batch is None:
            if env("PROVOST_BATCH") == "0":
                self._batch = False     # QD_PROVOST_BATCH=0: one at a time
            else:
                rc, out, _ = self.call(["batch", "--help"])
                self._batch = rc == 0 and "usage: provost batch" in out
        return self._batch

    def file(self, batch, jobs=None):
        """File every input of a Batch.  Returns the problems provost
        reported (an input it could not file is said, and the rest are
        filed); raises if it filed nothing at all."""
        self.require()
        if not batch.inputs:
            return []
        jobs = jobs or env_int("FILE_JOBS", 0) or None
        if self.has_batch():
            lst = os.path.join(batch.dir, "inputs.list")
            write_text(lst, "".join("%s\t%s\n" % (n, p)
                                    for n, p in batch.inputs))
            args = ["batch", "-q", "--context-columns"] + (
                ["-j", str(jobs)] if jobs else []) + ["--from", lst]
            rc, _, err = self.call(args)
            problems = complaints(err)
            if rc != 0 and not problems:
                die("provost batch failed (exit %d)" % rc)
            return problems
        # One capture at a time: the answers a few in parallel (provost
        # parses outside its lock), the run's own row last, alone.
        head, last = batch.inputs[:-1], batch.inputs[-1]
        problems = []

        def one(item):
            name, path = item
            rc, _, err = self.call(["--sync", "-q", "--name", name, path])
            return (path, rc, complaints(err))

        with ThreadPoolExecutor(max_workers=jobs or 4) as pool:
            for path, rc, errs in pool.map(one, head):
                if rc != 0:
                    problems.append("%s: %s" % (
                        os.path.basename(path),
                        errs[-1] if errs else "exit %d" % rc))
        _, rc, errs = one(last)
        if rc != 0:
            die("provost did not file the run itself: %s"
                % (errs[-1] if errs else "exit %d" % rc))
        return problems


def complaints(err):
    """provost's error and warning lines, without its colour."""
    out = []
    for ln in err.splitlines():
        ln = re.sub(r"\x1b\[[0-9;]*m", "", ln).strip()
        if ln:
            out.append(ln)
    return out


def notes_of(prov, batch, what):
    """File a batch; a problem is said, never lost.  Returns the notes."""
    problems = prov.file(batch)
    if problems:
        return ["provost did not file %s of the %s: %s" % (
            plural(len(problems), "input"), what, problems[-1])]
    return []
