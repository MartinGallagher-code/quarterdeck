# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Martin J. Gallagher
"""The store: provost's, read straight from its files.

qd keeps nothing of its own.  What it brings back is filed by provost
(filing.py) and read back here from provost's store, which is plain files:

    datasets/NAME.tsv            '#', 'capture', context columns, 'n', data
    captures/cNNNN/meta.tsv      what a capture was: dataset, row_ids, ...
    captures/cNNNN/output.txt    the input as provost stored it (CRs out,
                                 secrets scrubbed; for a truncated capture
                                 only the head it parsed)
    captures/cNNNN/context.txt   its '#%' prologue
    provenance.tsv               '#' -> dataset, capture

A qd run is three things in there:

    qd.runs    a row per run: what ran, where, when, how it went
    qd.hosts   a row per host and pass: how it answered (status, rc,
               duration, stderr) -- whether or not it printed anything
    NAME       what the hosts printed: a capture per host, opening with
               '#% run=RUN host=HOST [pass=N] [attr=value ...]'

and this module puts them back together: each host's status beside the
rows provost parsed out of its answer, and a row of blanks for a host that
printed nothing, because a host that did not answer is a finding, not a
gap.  `qd do` and `qd import` file their tables the same way, each capture
opening with '#% run=RUN' and a 'qd-table' line that names the table.
Any other provost dataset reads too: `ds:NAME`, or a bare NAME no run has.

The layout and what a reader must do with it are provost's spec, its
docs/store-format.md: a .store_format this qd does not know is refused,
a row's capture is read from provenance.tsv below format 4, a quoted '#%'
value is read as provost reads it, meta.tsv values are unescaped, and a
truncated capture's whole input is found beside the store by its sha256.
qd reads no git refs, so the capture-* tags (annotated and signed in a
store provost signs) and the Operator: trailers are not its concern.

Which store: --store NAME|DIR, QD_STORE, provost's explicit choice
(PROVOST_WORKSPACE, the nearest controlled directory above this one), the
active named store, provost's default (PROVOST_HOME, ~/.provost) -- see
stores.py.  Whichever it is, `provost ls` there lists what qd filed and
`provost source cNNNN` shows a host's answer.
"""

import binascii
import hashlib
import io
import json
import os
import re
import shlex
import time

from .common import die, env, plural, read_text
from .table import Table

RUNS, HOSTS = "qd.runs", "qd.hosts"

RUN_COLUMNS = ("run", "kind", "name", "command", "created", "finished",
               "duration_s", "hosts", "ok", "failed", "timeout",
               "unreachable", "push_failed", "passes", "every", "rc",
               "captures", "tool", "ran", "version", "cwd", "qd", "notes",
               "group", "part", "factors", "operator", "operator_host",
               "ssh_user", "ssh_key", "sudo", "via", "sched_job",
               "not_run", "rerun_of")
HOST_COLUMNS = ("run", "host", "addr", "pass", "ts", "status", "rc",
                "duration_s", "bytes", "error", "attrs", "stderr",
                "attempt")
OUTCOMES = ("ok", "failed", "timeout", "unreachable", "push-failed",
            "not-run")

# Free text is escaped in qd's own tables: a tab or a newline would end the
# cell, and provost's TSV reader dropped double quotes until the release
# with `batch` (PyPI's 2.1.0 still does), so they are escaped too.
TEXT_COLUMNS = ("command", "ran", "version", "cwd", "notes", "error",
                "stderr", "attrs", "factors", "operator", "operator_host",
                "ssh_user", "ssh_key",
                # qd.peers and qd.baselines: column names and group values
                # are anyone's words (a facts run's cpu.model)
                "note", "by", "source", "peer", "key", "key_cols", "column")

KEY_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_.-]*$")

# How far before a run's own row its captures are looked for, beyond the
# number it filed: other captures filed at the same moment can sit between.
SCAN_SLACK = 5000

_ESC = {"\\": "\\\\", "\t": "\\t", "\n": "\\n", "\r": "\\r", '"': "\\x22"}
_ESC_RE = re.compile(r'[\\\t\n\r"]')
_UNESC = {"\\\\": "\\", "\\t": "\t", "\\n": "\n", "\\r": "\r",
          "\\x22": '"', "\\x20": " "}
_UNESC_RE = re.compile(r"\\(?:\\|t|n|r|x22|x20)")


def escape(text):
    return _ESC_RE.sub(lambda m: _ESC[m.group(0)], text or "")


def escape_spaces(text):
    """escape, and a space as \\x20 too (filing.own_tsv says why)."""
    return escape(text).replace(" ", "\\x20")


def unescape(text):
    return _UNESC_RE.sub(lambda m: _UNESC[m.group(0)], text or "")


_META_UNESC = {"\\t": "\t", "\\n": "\n"}
_META_UNESC_RE = re.compile(r"\\[tn]")


def unescape_meta(text):
    """A meta.tsv value as provost was given it: its _meta_safe writes a
    tab as \\t and a newline as \\n, and nothing else."""
    return _META_UNESC_RE.sub(lambda m: _META_UNESC[m.group(0)], text or "")


def now_iso(t=None):
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(t or time.time()))


def cnum(cid):
    """c0042 -> 42; anything else -> None."""
    m = re.match(r"^c(\d+)$", cid or "")
    return int(m.group(1)) if m else None


def cname(n):
    return "c%04d" % n


_QUOTED_RE = re.compile(r'([A-Za-z_][A-Za-z0-9_.-]*)="')
_WORD_RE = re.compile(r"[^ \t]+")


def prologue_words(line):
    """[(key, value)]: the key=value words of one '#%' line, in order, as
    provost's _prologue_kv reads them (its store format spec): words part
    at spaces and tabs; a value may be double-quoted to hold spaces
    (key="gcc 13.2"), a backslash inside taking the character after it
    as it is (\\" and \\\\); an unterminated quote, or one not followed by
    a space, is an ordinary word; a word that is not key=value is passed
    over; a tab in a value becomes a space."""
    out = []
    rest = line[2:] if line.startswith("#%") else line
    while True:
        rest = rest.lstrip(" \t")
        if not rest:
            break
        m = _QUOTED_RE.match(rest)
        if m:
            i, v, closed = m.end(), [], False
            while i < len(rest):
                c = rest[i]
                if c == "\\" and i + 1 < len(rest):
                    v.append(rest[i + 1])
                    i += 2
                    continue
                if c == '"':
                    i += 1
                    closed = True
                    break
                v.append(c)
                i += 1
            if closed and (i == len(rest) or rest[i] in " \t"):
                out.append((m.group(1), "".join(v).replace("\t", " ")))
                rest = rest[i:]
                continue
        w = _WORD_RE.match(rest).group(0)
        rest = rest[len(w):]
        k, sep, v = w.partition("=")
        if sep and KEY_RE.match(k):
            out.append((k, v))
    return out


def parse_context(text):
    """The key=value words of a '#%' prologue, as provost reads them for
    --context-columns: the last value of a repeated key wins."""
    out = {}
    for ln in text.splitlines():
        if ln.startswith("#%"):
            out.update(prologue_words(ln))
    return out


def table_line(info):
    """The '#%' line that says which of an entry's tables a capture is.
    Hex, so no word of it is a key=value for provost to make a column of."""
    blob = json.dumps(info, sort_keys=True, separators=(",", ":"))
    return "#% qd-table " + binascii.hexlify(blob.encode("utf-8")).decode()


def read_table_line(text):
    for ln in text.splitlines():
        if ln.startswith("#% qd-table "):
            try:
                return json.loads(binascii.unhexlify(
                    ln.split(None, 2)[2].strip()).decode("utf-8"))
            except (ValueError, TypeError, binascii.Error, IndexError):
                return {}
    return {}


def join_attrs(pairs):
    """key=value words, as split_attrs reads them back: a value with a
    space or a quote in it is quoted (a design level `-w 1M`)."""
    return " ".join("%s=%s" % (k, shlex.quote(v) if re.search(r"[\s'\"]", v)
                               else v) for k, v in pairs)


def shown_attrs(text):
    """Stored key=value words as one reads them: args=-w 1M."""
    return " ".join("%s=%s" % kv for kv in split_attrs(text))


def split_attrs(text):
    text = text or ""
    words = text.split()
    if "='" in text or '="' in text:
        # a quoted value (join_attrs): shell words, backslashes as written
        lex = shlex.shlex(text, posix=True)
        lex.whitespace_split = True
        lex.escape = ""
        try:
            words = list(lex)
        except ValueError:
            pass                    # an unbalanced quote: words as written
    out = []
    for w in words:
        k, sep, v = w.partition("=")
        if sep and k:
            out.append((k, v))
    return out


def row_count(meta):
    m = re.match(r"^(\d+)-(\d+)$", meta.get("row_ids", ""))
    return int(m.group(2)) - int(m.group(1)) + 1 if m else 0


def first_row(meta):
    """The first row number a capture filed, or None: what `provost source
    N` takes in every provost (a capture id only in newer ones)."""
    m = re.match(r"^(\d+)-\d+$", meta.get("row_ids", ""))
    return int(m.group(1)) if m else None


def context_columns(meta):
    """The dataset columns a capture's context became (provost records
    them as context_columns key=column,...)."""
    out = set()
    for pair in (meta.get("context_columns") or "").split(","):
        k, sep, c = pair.partition("=")
        if sep and c:
            out.add(c)
    return out


# provost's record number in a run's rows, kept apart from a data column
# that happens to be called n (see provost_columns)
REC = "\x00n"


def provost_columns(columns, context=(), rows=None):
    """The indexes of the columns provost puts first in a dataset -- '#',
    its capture id, its record number -- found by place, under whatever its
    clash rule named them (`_capture`, `_n` beside a data column of that
    name), past the capture's context columns (`context`, which provost
    puts between the capture id and the record number).  A data column
    called n or capture is data.

    Given the capture's `rows`, a column blank in all of them is passed
    over on the way to the record number too: it is another capture's
    context -- a host attribute, srun's sched.job -- that provost put
    there when the dataset was made, and this capture did not carry."""
    blank = set()
    if rows is not None:
        blank = set(i for i in range(len(columns))
                    if not any(i < len(r) and r[i].strip() for r in rows))
    pats = (r"^#$", r"^_*capture$", r"^_*n$")
    out, k = [], 0
    for i, c in enumerate(columns):
        if i and c in context:
            continue
        if k == 2 and i in blank and not re.match(pats[2], c):
            continue
        while k < len(pats) and not re.match(pats[k], c):
            k += 1
        if k == len(pats):
            break
        out.append(i)
        k += 1
    return out


# The store formats qd reads (provost's docs/store-format.md): a store
# records its own in .store_format (none means 1), and one qd does not know
# is refused, live or archived -- a newer provost wrote it.  provost moves
# an older store up to its own format the next time it files into it.
STORE_FORMATS = (1, 2, 3, 4)


def store_format(root):
    """A store's format, from its .store_format: 1 when there is none (or
    it is not a number, which `provost store check` reports)."""
    try:
        with io.open(os.path.join(root, ".store_format"),
                     encoding="utf-8") as fh:
            v = fh.read().strip()
    except (OSError, UnicodeDecodeError):
        return 1
    return int(v) if v.isdigit() else 1


def known_formats():
    return ", ".join(str(f) for f in STORE_FORMATS)


def capture_column(columns):
    """The index of provost's capture column, or None in a store older
    than it (format 3 on: always the second).  Found by place, not by
    name: a dataset whose data has a column called capture holds provost's
    as `_capture` (provost's store format 4), and the data's is data.
    Format 3 has it, but a row's capture is read from provenance.tsv
    there (Store.row_capture: PV-015 could leave data in it)."""
    if len(columns) > 1 and columns[0] == "#" and \
            re.match(r"^_*capture$", columns[1]):
        return 1
    return None


# what provost takes for a dataset's name: letters, digits, '.', '_', '-'
DATASET_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]*$")

LONG_KEYS = ("field", "key", "name")
# What provost files beside a long key and value: its row number, and a
# group -- a `key:` line with nothing after it (a setting not measured on
# that host) reads to it as a section header, and the lines after carry it.
LONG_EXTRA = ("n", "group")


def widen(records):
    """One host's answer filed long -- a `field, value` row per setting,
    which is how provost reads `key: value` lines it judges a list -- as
    the one row it describes: each field a column.  None when the rows
    are not that shape (a real table stays a table)."""
    if not records:
        return None
    # a column blank on every row is another capture's context, not this
    # answer's (see provost_columns)
    cols = [c for c, _ in records[0] if c not in LONG_EXTRA and c != REC
            and (c in LONG_KEYS or c == "value"
                 or any(dict(r).get(c, "").strip() for r in records))]
    if len(cols) != 2 or cols[0] not in LONG_KEYS or cols[1] != "value":
        return None
    out, seen = [], set()
    for rec in records:
        d = dict(rec)
        f = d.get(cols[0], "")
        if not f or f in seen:
            return None              # a repeated field: a list, not a record
        seen.add(f)
        out.append((f, d.get("value", "")))
    return out


def read_dataset(path, name):
    """A provost dataset: a header and rows, tab-separated, nothing quoted
    (a '#' header is a header here, not a comment)."""
    lines = read_text(path).split("\n")
    lines = [ln[:-1] if ln.endswith("\r") else ln for ln in lines if ln]
    if not lines:
        return Table([], [], name, path)
    return Table(lines[0].split("\t"), [ln.split("\t") for ln in lines[1:]],
                 name, path)


def default_root():
    """The store a command uses with no --store: named stores' rule
    (stores.py) -- QD_STORE, provost's explicit choice, the active store,
    provost's default."""
    from . import stores
    return stores.choose(None)[0]


def tilde(path):
    """A path as one would type it: ~/... under the home directory."""
    home = os.path.expanduser("~")
    if home not in ("", "/") and (path + "/").startswith(home + "/"):
        return "~" + path[len(home):]
    return path


def provost_explicit():
    """The store provost was told to use, rather than its default: the
    PROVOST_WORKSPACE setting, or the controlled directory you are in.
    None when it would fall back to PROVOST_HOME or ~/.provost."""
    v = os.environ.get("PROVOST_WORKSPACE")
    if v:
        return os.path.abspath(os.path.expanduser(v))
    d = os.getcwd()
    while True:
        if os.path.isfile(os.path.join(d, ".provost", "CONTROLLED")):
            return os.path.join(d, ".provost")
        up = os.path.dirname(d)
        if up == d:
            return None
        d = up


def provost_root():
    """The store provost finds on its own: PROVOST_WORKSPACE, the controlled
    directory around here, PROVOST_HOME, ~/.provost -- qd's rule less
    --store, QD_STORE and the active store, which provost does not read."""
    return provost_explicit() or os.path.abspath(os.path.expanduser(
        os.environ.get("PROVOST_HOME") or "~/.provost"))


def cache_root():
    """Where qd writes what it makes from a store (floor-plan overlays):
    never the store itself, which provost commits whole."""
    v = env("CACHE")
    if v:
        return os.path.abspath(os.path.expanduser(v))
    base = os.environ.get("XDG_CACHE_HOME") or os.path.expanduser("~/.cache")
    return os.path.join(base, "quarterdeck")


class Store(object):
    def __init__(self, root=None):
        self.root = os.path.abspath(os.path.expanduser(root)) if root \
            else default_root()
        # the registered name it was opened by, when a reference named it
        # (REF@STORE) rather than the command's own store: what shown_id
        # puts after an `@`
        self.via = None
        self.reset()

    def reset(self):
        self._provost_env = None
        self._tables = {}
        self._index = {}
        self._meta = {}
        self._ctx = {}
        self._ctx_text = {}
        self._prov = None
        self._runs = None
        self._hosts = None
        self._format = None
        self._kept = {}
        self._stamp = self.stamp()

    def stamp(self):
        """What moves whenever provost files something."""
        out = []
        for p in ("datasets", ".store_format", os.path.join(".git", "index"),
                  os.path.join(".git", "HEAD")):
            try:
                out.append(os.path.getmtime(os.path.join(self.root, p)))
            except OSError:
                out.append(0)
        return tuple(out)

    def refresh(self):
        """Forget what was read, if provost has filed something since."""
        if self.stamp() != self._stamp:
            self.reset()

    def exists(self):
        return os.path.isdir(os.path.join(self.root, "datasets"))

    def path(self, *parts):
        return os.path.join(self.root, *parts)

    def shown(self):
        return tilde(self.root)

    def format(self):
        """The store's format (.store_format), refused when it is one this
        qd does not know: provost's spec says a reader must, since a newer
        format can mean something an older reader would get wrong."""
        if self._format is None:
            fmt = store_format(self.root)
            if fmt not in STORE_FORMATS:
                die("%s is a store in format %d; this qd reads formats %s "
                    "(a newer provost wrote it: upgrade qd)"
                    % (self.shown(), fmt, known_formats()))
            self._format = fmt
        return self._format

    def provost(self, words):
        """`provost WORDS` as typed to reach this store: with
        PROVOST_WORKSPACE in front when provost would not find it on its
        own (a store named by --store or QD_STORE)."""
        if self._provost_env is None:
            self._provost_env = ""
            if os.path.realpath(provost_root()) != \
                    os.path.realpath(self.root):
                where = self.shown()
                if not re.match(r"^[\w~@%+=:,./-]+$", where):
                    where = shlex.quote(self.root)
                self._provost_env = "PROVOST_WORKSPACE=%s " % where
        return self._provost_env + "provost " + words

    # -- datasets -----------------------------------------------------------

    def dataset_names(self):
        self.format()
        try:
            names = os.listdir(self.path("datasets"))
        except OSError:
            return []
        return sorted(n[:-4] for n in names if n.endswith(".tsv"))

    def has_dataset(self, name):
        # a provost name, never a path: `ds:../../x` is not a dataset
        return bool(DATASET_RE.match(name or "")) and ".." not in name \
            and os.path.isfile(self.path("datasets", name + ".tsv"))

    def dataset(self, name):
        if name not in self._tables:
            if not self.has_dataset(name):
                die("no dataset %r in %s (provost ls lists them)"
                    % (name, self.shown()))
            self.format()
            self._tables[name] = read_dataset(
                self.path("datasets", name + ".tsv"), name)
        return self._tables[name]

    def family(self, name):
        """NAME and the variants provost files another shape into
        (NAME.v2, NAME.v3, ...)."""
        pat = re.compile(r"^%s(\.v\d+)?$" % re.escape(name))
        return [n for n in self.dataset_names() if pat.match(n)]

    def row_index(self, name):
        if name not in self._index:
            t = self.dataset(name)
            idx = {}
            if "#" in t.columns:
                i = t.columns.index("#")
                for r in t.rows:
                    if r[i].isdigit():
                        idx[int(r[i])] = r
            self._index[name] = idx
        return self._index[name]

    def provenance(self):
        """'#' -> capture: what a row's capture is read from in a store
        older than format 4 (see row_capture)."""
        if self._prov is None:
            self.format()
            self._prov = {}
            p = self.path("provenance.tsv")
            if os.path.isfile(p):
                for ln in read_text(p).splitlines()[1:]:
                    f = ln.split("\t")
                    if len(f) >= 3 and f[0].isdigit():
                        self._prov[int(f[0])] = f[2]
        return self._prov

    def row_capture(self, t, row):
        """The capture a dataset row came from: column 2, by place, in a
        format-4 store; provenance.tsv below that -- format 1 and 2 have no
        capture column, and in format 3 a reconcile could leave a data
        value in it (provost's PV-015; the spec says to prefer
        provenance.tsv there)."""
        i = capture_column(t.columns)
        col = row[i] if i is not None and i < len(row) else ""
        if i is not None and self.format() >= 4:
            return col
        if "#" in t.columns and row[t.columns.index("#")].isdigit():
            return self.provenance().get(int(row[t.columns.index("#")]),
                                         col)
        return col

    # -- captures -----------------------------------------------------------

    def meta(self, cid):
        """A capture's meta.tsv as {key: value}, each value with provost's
        \\t and \\n turned back into a tab and a newline (_meta_safe
        writes them so; it does not escape a backslash, so a value that
        held a backslash and a t cannot be told from one that held a
        tab)."""
        if cid not in self._meta:
            self.format()
            m = {}
            p = self.path("captures", cid, "meta.tsv")
            if os.path.isfile(p):
                for ln in read_text(p).split("\n"):
                    k, sep, v = ln.partition("\t")
                    if sep:
                        m[k] = unescape_meta(v)
            self._meta[cid] = m
        return self._meta[cid]

    def context_text(self, cid):
        if cid not in self._ctx_text:
            self.format()
            p = self.path("captures", cid, "context.txt")
            self._ctx_text[cid] = read_text(p) if os.path.isfile(p) else ""
        return self._ctx_text[cid]

    def context(self, cid):
        if cid not in self._ctx:
            self._ctx[cid] = parse_context(self.context_text(cid))
        return self._ctx[cid]

    def output(self, cid):
        """A capture's input as provost stored it (output.txt), less its
        prologue: carriage returns removed and secrets scrubbed, and, for
        a truncated capture (truncated(cid)), only the head provost
        parsed -- whole_output() reads the whole input where it is kept."""
        if not re.match(r"^c\d+$", cid or ""):
            return None
        self.format()
        p = self.path("captures", cid, "output.txt")
        if not os.path.isfile(p):
            return None
        return _less_prologue(read_text(p))

    def truncated(self, cid):
        """Whether the capture's input was over provost's size cap
        (PROVOST_MAX_INPUT, provost 2.15.0 on): output.txt then holds only
        the part provost parsed, and the whole input is kept outside git,
        by its sha256 (raw_sha256), beside the store."""
        return self.meta(cid).get("truncated") == "1"

    def artifact_dirs(self):
        """Where provost keeps inputs over its size cap, as its spec says:
        PROVOST_ARTIFACT_DIR when set, else STORE.artifacts beside the
        store."""
        out = []
        v = os.environ.get("PROVOST_ARTIFACT_DIR")
        if v:
            out.append(os.path.abspath(os.path.expanduser(v)))
        out.append(self.root.rstrip(os.sep) + ".artifacts")
        return out

    def kept_input(self, cid):
        """(path, problem) for a truncated capture's whole input: the path
        meta.tsv's raw_artifact names, or, when that is gone (the store and
        its artifacts moved together), the file named by raw_sha256 in the
        artifact directory as it is now.  The path is None when it is not
        found, or does not hash to raw_sha256; problem says which, in
        words.  (None, "") for a capture that was not truncated."""
        if not self.truncated(cid):
            return None, ""
        if cid in self._kept:
            return self._kept[cid]
        m = self.meta(cid)
        sha = m.get("raw_sha256", "")
        found = None
        if not re.match(r"^[0-9a-f]{64}$", sha):
            got = (None, "its meta.tsv records no raw_sha256")
        else:
            places = [m.get("raw_artifact") or ""] + \
                [os.path.join(d, sha) for d in self.artifact_dirs()]
            for p in places:
                if p and os.path.isfile(p):
                    found = p
                    break
            if found is None:
                got = (None, "the whole input (sha256 %s) is not in %s"
                       % (sha[:12], " or ".join(
                           tilde(d) for d in self.artifact_dirs())))
            elif _file_sha256(found) != sha:
                got = (None, "the whole input kept at %s no longer hashes "
                       "to its raw_sha256" % tilde(found))
            else:
                got = (found, "")
        self._kept[cid] = got
        return got

    def whole_output(self, cid):
        """output(), but a truncated capture's whole input where it is
        kept (less its prologue), and its parsed head where it is not."""
        path, _ = self.kept_input(cid)
        if path:
            return _less_prologue(read_text(path))
        return self.output(cid)

    def truncation_note(self, cid):
        """What a reader of output() must know of a truncated capture, in
        words; "" for one that was not."""
        if not self.truncated(cid):
            return ""
        m = self.meta(cid)
        size = ""
        if m.get("parsed_bytes", "").isdigit():
            whole = m.get("raw_bytes") or m.get("input_bytes") or ""
            size = ", %s of %s bytes" % (
                m["parsed_bytes"], whole if whole.isdigit() else "?")
        path, problem = self.kept_input(cid)
        return "truncated: only the head provost parsed%s; %s" % (
            size, ("the whole input is kept at %s" % tilde(path))
            if path else problem)

    def capture_rows(self, cid):
        """[(dataset, Table)]: the rows a capture filed, dataset by dataset
        (one, unless provost split the input into several)."""
        m = self.meta(cid)
        rng = re.match(r"^(\d+)-(\d+)$", m.get("row_ids", ""))
        out = []
        for name in [n for n in m.get("dataset", "").split(",") if n]:
            if not self.has_dataset(name):
                continue                    # removed since (provost rm)
            t = self.dataset(name)
            rows = []
            if rng:
                idx = self.row_index(name)
                rows = [idx[n] for n in range(int(rng.group(1)),
                                              int(rng.group(2)) + 1)
                        if n in idx]
            out.append((name, t.derive(rows=rows)))
        return out

    # -- qd's own tables ------------------------------------------------------

    def _read_own(self, name):
        out = []
        for ds in self.family(name):
            t = self.dataset(ds)
            for r in t.rows:
                d = dict(zip(t.columns, r))
                for c in TEXT_COLUMNS:
                    if c in d:
                        d[c] = unescape(d[c])
                d["_rowid"] = int(d["#"]) if d.get("#", "").isdigit() else 0
                d["_capture"] = self.row_capture(t, r) or \
                    self.provenance().get(d["_rowid"], "")
                out.append(d)
        out.sort(key=lambda d: d["_rowid"])
        return out

    def run_rows(self):
        if self._runs is None:
            self._runs = [r for r in self._read_own(RUNS) if r.get("run")]
        return self._runs

    def host_rows(self, run_id):
        if self._hosts is None:
            by = {}
            for d in self._read_own(HOSTS):
                by.setdefault(d.get("run", ""), []).append(d)
            self._hosts = by
        return self._hosts.get(run_id, [])

    def run_captures(self, row):
        """The captures filed with '#% run=RUN', oldest first.  qd files a
        run's own row last, so they come just before it: walk back from
        there until there are as many as the run says it filed."""
        want = int(row.get("captures") or 0)
        start = cnum(row.get("_capture"))
        if not want or start is None:
            return []
        found = []
        n, floor = start - 1, max(1, start - 1 - want - SCAN_SLACK)
        while n >= floor and len(found) < want:
            cid = cname(n)
            if self.context(cid).get("run") == row["run"]:
                found.append(cid)
            n -= 1
        found.reverse()
        return found

    def capture_ids(self):
        try:
            names = os.listdir(self.path("captures"))
        except OSError:
            return []
        return sorted(n for n in names if re.match(r"^c\d+$", n))

    def all_run_captures(self, e):
        """Every capture run `e` filed: its answers and tables (the
        '#% run=RUN' ones, every capture read if walking back from its row
        does not find them all), its qd.hosts rows and its qd.runs row --
        what deleting it deletes."""
        caps = list(e.captures())
        if len(caps) < int(e.row.get("captures") or 0):
            caps = [c for c in self.capture_ids()
                    if self.context(c).get("run") == e.id]
        own = [e.row.get("_capture")] + [h.get("_capture") for h in
                                         self.host_rows(e.id)]
        return sorted(set(c for c in caps + own if c))

    def own_holders(self):
        """{capture: set of the runs it holds a qd.runs or qd.hosts row
        of}: whether a capture is one run's alone."""
        out = {}
        for name in (RUNS, HOSTS):
            for d in self._read_own(name):
                if d.get("_capture"):
                    out.setdefault(d["_capture"], set()).add(d.get("run", ""))
        return out

    # -- entries --------------------------------------------------------------

    def entries(self):
        return [Run(self, r) for r in self.run_rows()]

    def run_ids(self):
        return set(r["run"] for r in self.run_rows())

    def resolve(self, ref):
        """latest, latest~N, a run id or a unique part of one, a run's
        --name (its latest), ds:NAME or a dataset no run is named."""
        if ref.startswith("ds:"):
            if not self.has_dataset(ref[3:]):
                die("no dataset %r in %s (provost ls lists them)"
                    % (ref[3:], self.shown()))
            return Dataset(self, ref[3:])
        entries = self.entries()
        m = re.match(r"^(latest|last|prev)?(?:~(\d+))?$", ref)
        if m and (m.group(1) or m.group(2)):
            if not entries:
                die("no runs in the store %s yet -- `qd run`, `qd do` or "
                    "`qd import` files one (or point --store at another)"
                    % self.shown())
            back = int(m.group(2) or 0) + (1 if m.group(1) == "prev" else 0)
            if back >= len(entries):
                die("%s goes back further than the %d runs in %s"
                    % (ref, len(entries), self.shown()))
            return entries[-1 - back]
        for e in entries:
            if e.id == ref:
                return e
        named = [e for e in entries if e.name == ref]
        if named:
            return named[-1]
        if self.has_dataset(ref):
            return Dataset(self, ref)
        pre = [e for e in entries if e.id.startswith(ref)]
        if len(pre) == 1:
            return pre[0]
        sub = [e for e in entries if ref in e.id]
        if len(sub) == 1:
            return sub[0]
        if len(pre) > 1 or len(sub) > 1:
            many = pre if len(pre) > 1 else sub
            die("%r matches %d runs: %s" % (
                ref, len(many), ", ".join(e.id for e in many[-6:])))
        die("no run or dataset %r in %s (try `qd log`, or `provost ls`)"
            % (ref, self.shown()))

    def previous_like(self, entry):
        """The last run before this one that ran the same thing -- what
        `qd diff latest` compares against when given one reference."""
        if not isinstance(entry, Run):
            return None
        entries = self.entries()
        # a rerun (QD-027) is compared with the run it reran
        for rid in (entry.meta.get("rerun_of") or "").split(","):
            for e in entries:
                if rid and e.id == rid:
                    return e
        # a campaign's parts run one command under one name: the part is
        # what tells them apart, so rack-r2 is compared with rack-r2.  A
        # probe is its name: how qd asks it (the command) changes between
        # versions, and today's facts are still compared with yesterday's
        def key(e):
            probe = e.meta.get("tool") == "probe"
            return (e.meta.get("kind"), "" if probe else e.meta.get("command"),
                    e.meta.get("name"), e.meta.get("part") or "")
        ids = [e.id for e in entries]
        earlier = entries[:ids.index(entry.id)] if entry.id in ids else []
        for e in reversed(earlier):
            if key(e) == key(entry):
                return e
        return None


def host_key(d):
    """(host, pass, attempt) of a qd.hosts row or a capture's prologue:
    which answer is which host's, try by try."""
    return (d.get("host", ""), d.get("pass") or "1", d.get("attempt") or "1")


def _pick(tables, name, eid):
    if name is None:
        return tables[0]
    hits = [t for t in tables if t["name"] == name] or \
        [t for t in tables if t["name"].startswith(name)]
    if len(hits) != 1:
        die("%s has no single table %r (tables: %s)"
            % (eid, name, ", ".join(t["name"] for t in tables)))
    return hits[0]


class Run(object):
    """A qd run, `qd do` or `qd import`, put back together from the store."""

    def __init__(self, store, row):
        self.store = store
        self.row = row
        self.id = row["run"]
        m = dict((k, v) for k, v in row.items()
                 if k in RUN_COLUMNS and v != "")
        m["id"] = self.id
        m["capture"] = row.get("_capture", "")
        for k in ("duration_s", "every"):
            if k in m:
                try:
                    m[k] = float(m[k])
                except ValueError:
                    pass
        for k in ("passes", "rc", "captures"):
            if k in m and re.match(r"^-?\d+$", m[k]):
                m[k] = int(m[k])
        if m.get("kind") == "run":
            h = {"total": int(row.get("hosts") or 0)}
            for k in OUTCOMES:
                v = row.get(k.replace("-", "_"), "")
                if v.isdigit() and int(v):
                    h[k] = int(v)
            m["hosts"] = h
        else:
            m.pop("hosts", None)
        if m.get("tool") and m.get("version"):
            m["tools"] = {m["tool"]: m.pop("version")}
        notes = m.pop("notes", "")
        if notes:
            m["notes"] = notes.split("\n")
        self.meta = m
        self._caps = None
        self._tables = None

    @property
    def name(self):
        return self.meta.get("name") or ""

    def captures(self):
        if self._caps is None:
            self._caps = self.store.run_captures(self.row)
        return self._caps

    @property
    def tables(self):
        if self._tables is None:
            self._tables = self._list()
        return self._tables

    def table_names(self):
        return [t["name"] for t in self.tables]

    def table_count(self):
        """How many tables, without reading them: what `qd log` shows."""
        if self.meta.get("kind") == "run":
            return 2
        return int(self.meta.get("captures") or 0)

    def _shown_rows(self, cid):
        """How many rows a capture is in the run's table: provost's count,
        or one where its rows are `key: value` lines filed long, which the
        table widens into one row (see widen)."""
        m = self.store.meta(cid)
        n = row_count(m)
        names = [x for x in m.get("dataset", "").split(",") if x]
        if n > 1 and len(names) == 1 and self.store.has_dataset(names[0]):
            cols = self.store.dataset(names[0]).columns
            ctx = context_columns(m)
            own = provost_columns(cols, ctx)
            rest = [c for i, c in enumerate(cols) if i not in own
                    and c not in ctx and c not in LONG_EXTRA]
            if len(rest) == 2 and rest[0] in LONG_KEYS and rest[1] == "value":
                return 1
        return n

    def _list(self):
        caps = self.captures()
        if self.meta.get("kind") == "run":
            hosts = self.store.host_rows(self.id)
            per = {}
            for cid in caps:
                ctx = self.store.context(cid)
                per[host_key(ctx)] = self._shown_rows(cid)
            rows = sum(max(1, per.get(host_key(h), 0)) for h in hosts)
            names = sorted(set(n for cid in caps for n in
                               self.store.meta(cid).get("dataset", "")
                               .split(",") if n))
            return [{"name": "data", "rows": rows, "from": "ssh",
                     "datasets": names},
                    {"name": "hosts", "rows": len(hosts), "from": "ssh",
                     "datasets": [HOSTS]}]
        out = []
        for cid in caps:
            info = read_table_line(self.store.context_text(cid))
            m = self.store.meta(cid)
            out.append({"name": info.get("name") or cid,
                        "index": info.get("index", len(out)),
                        "rows": row_count(m), "from": info.get("from", ""),
                        "capture": cid, "notes": info.get("notes") or [],
                        "datasets": [n for n in m.get("dataset", "")
                                     .split(",") if n]})
        # in the order qd read them, whatever order provost filed them in
        out.sort(key=lambda t: t["index"])
        return out

    def load(self, name=None):
        tabs = self.tables
        if not tabs:
            die("%s holds no tables: nothing it filed is in the store any "
                "more (provost rm, prune or archive --purge -- disposals.tsv"
                " names those two -- or a store restored to before it)"
                % self.id)
        return self.load_info(_pick(tabs, name, self.id))

    def load_info(self, info):
        """One of self.tables, read: by its listing rather than its name,
        which two of a `qd do`'s tables can share."""
        if self.meta.get("kind") == "run":
            t = self._data() if info["name"] == "data" else self._hosts()
        else:
            t = self._filed(info)
        t.entry = self
        return t

    def setting_columns(self):
        """The columns that say what was run where, not what came back:
        the design's factors and the hosts' attributes."""
        names = [k for k, _ in split_attrs(self.meta.get("factors"))]
        factors = set(names)
        for h in self.store.host_rows(self.id):
            names.extend(("attr_" + k) if k in factors else k
                         for k, _ in split_attrs(h.get("attrs")))
        return set(names)

    def _host_lead(self, hosts):
        """host, addr, its attributes, the run's design factors, pass."""
        factors = split_attrs(self.meta.get("factors"))
        fnames = [k for k, _ in factors]
        attrs = []
        for h in hosts:
            for k, _ in split_attrs(h.get("attrs")):
                if k not in attrs:
                    attrs.append(k)
        # a host attribute named as a factor is shown as attr_<name>, as
        # it was filed: the factor is what the point ran at
        shown = [("attr_" + a) if a in fnames else a for a in attrs]
        show_addr = any(h.get("addr") for h in hosts)
        multi = int(self.meta.get("passes") or 1) > 1
        # --retries (QD-027): a host tried more than once has a row a try
        tries = any((h.get("attempt") or "1") != "1" for h in hosts)
        cols = ["host"] + (["addr"] if show_addr else []) + shown + \
            fnames + (["pass", "ts"] if multi else []) + \
            (["attempt"] if tries else [])
        fvals = dict(factors)

        def cells(h):
            ad = dict(split_attrs(h.get("attrs")))
            return [h.get("host", "")] + ([h.get("addr", "")]
                                          if show_addr else []) + \
                [ad.get(a, "") for a in attrs] + \
                [fvals.get(f, "") for f in fnames] + (
                    [h.get("pass") or "1", h.get("ts", "")]
                    if multi else []) + (
                    [h.get("attempt") or "1"] if tries else [])
        return cols, cells

    def _hosts(self):
        hosts = self.store.host_rows(self.id)
        cols, cells = self._host_lead(hosts)
        caps = self._by_host()
        tail = ["status", "rc", "duration_s", "bytes", "error", "stderr",
                "capture"]
        rows = [cells(h) + [h.get(c, "") for c in tail[:-1]] +
                [caps.get(host_key(h), "")]
                for h in hosts]
        return Table(cols + tail, rows, "hosts", self.store.root)

    def _by_host(self):
        out = {}
        for cid in self.captures():
            ctx = self.store.context(cid)
            out[host_key(ctx)] = cid
        return out

    def _data(self):
        """Every host's status beside the rows provost parsed out of its
        answer; a host that printed nothing still has its row."""
        hosts = self.store.host_rows(self.id)
        lead, cells = self._host_lead(hosts)
        lead = lead + ["status", "rc", "duration_s", "error", "capture"]
        caps = self._by_host()
        parts, datasets, many = [], [], False
        for h in hosts:
            cid = caps.get(host_key(h), "")
            recs = []
            if cid:
                drop = context_columns(self.store.meta(cid))
                for ds, t in self.store.capture_rows(cid):
                    if ds not in datasets:
                        datasets.append(ds)
                    if ds == "unsorted":
                        recs.append((ds, []))   # held: its text is raw
                        continue
                    own = provost_columns(t.columns, drop, t.rows)
                    rec = own[-1] if own and re.match(
                        r"^_*n$", t.columns[own[-1]]) else None
                    keep = [i for i, c in enumerate(t.columns)
                            if (i not in own or i == rec) and c not in drop]
                    pairs = [[(REC if i == rec else t.columns[i], r[i])
                              for i in keep] for r in t.rows]
                    wide = widen(pairs)
                    recs.extend((ds, p) for p in
                                ([wide] if wide is not None else pairs))
                many = many or len(recs) > 1
            parts.append((h, cid, recs))
        # Data columns in the order they first appear, less any blank on
        # every row of this run: provost unions a dataset's columns across
        # captures, and another run's shape is not this run's measurement.
        order, filled = [], set()
        for _, _, recs in parts:
            for _, pairs in recs:
                for c, v in pairs:
                    if c == REC and not many:
                        continue
                    if c not in order:
                        order.append(c)
                    if v.strip():
                        filled.add(c)
        datacols = [c for c in order if c in filled or c == REC]
        names, taken = {}, set(lead) | {"dataset"}
        # data columns keep their own names; provost's record number is n,
        # or _n beside a data column called n
        for c in [c for c in datacols if c != REC] + \
                [c for c in datacols if c == REC]:
            m = "n" if c == REC else c
            while m in taken:
                m = "_" + m
            taken.add(m)
            names[c] = m
        show_ds = len(datasets) > 1
        cols = lead + (["dataset"] if show_ds else []) + \
            [names[c] for c in datacols]
        rows = []
        for h, cid, recs in parts:
            base = cells(h) + [h.get("status", ""), h.get("rc", ""),
                               h.get("duration_s", ""), h.get("error", ""),
                               cid]
            for ds, pairs in recs or [("", [])]:
                d = dict(pairs)
                rows.append(base + ([ds] if show_ds else []) +
                            [d.get(c, "") for c in datacols])
        t = Table(cols, rows, "data", self.store.root)
        if len(datasets) > 1:
            t.notes.append("filed by provost into %s" % ", ".join(datasets))
        return t

    def _filed(self, info):
        cid = info.get("capture", "")
        meta = self.store.meta(cid)
        drop = context_columns(meta)
        extra = read_table_line(self.store.context_text(cid))
        cols, rows = [], []
        for ds, t in self.store.capture_rows(cid):
            own = set(t.columns[i] for i in provost_columns(t.columns,
                                                            drop, t.rows))
            keep = [c for c in t.columns if c not in own and c not in drop]
            for c in keep:
                if c not in cols:
                    cols.append(c)
            for r in t.rows:
                d = dict(zip(t.columns, r))
                rows.append(d)
        t = Table(cols, [[d.get(c, "") for c in cols] for d in rows],
                  info["name"], info.get("from") or self.store.root,
                  tests=extra.get("tests") or {},
                  notes=list(extra.get("notes") or []))
        return t

    def summary(self):
        h = self.meta.get("hosts") or {}
        if h:
            return "%d/%d ok" % (h.get("ok", 0), h.get("total", 0))
        return plural(sum(t.get("rows", 0) for t in self.tables), "row")

    def raw(self, host=None, pas=None, capture=None):
        """[(label, text)]: the answer a row came from, and its stderr."""
        out = []
        if not capture and host is not None:
            # the last try that left an answer (QD-027: --retries)
            got = sorted((int(k[2]) if k[2].isdigit() else 0, cid)
                         for k, cid in self._by_host().items()
                         if k[:2] == (host, pas or "1"))
            capture = got[-1][1] if got else ""
        if capture:
            text = self.store.output(capture)
            if text is not None:
                out.append((source_label(self.store, capture), text))
        if host is not None and self.meta.get("kind") == "run":
            for h in self.store.host_rows(self.id):
                if h.get("host") == host and \
                        (h.get("pass") or "1") == (pas or "1") and \
                        h.get("stderr"):
                    out.append(("stderr", h["stderr"]))
        return out


class Dataset(object):
    """A provost dataset read whole: everything every capture filed in it,
    run by qd or not (`provost run df -h` makes one)."""

    def __init__(self, store, name):
        if not store.has_dataset(name):
            die("no dataset %r in %s (provost ls lists them)"
                % (name, store.shown()))
        self.store = store
        self.name = name
        self.id = "ds:" + name
        self.meta = {"id": self.id, "kind": "dataset", "name": name,
                     "command": ""}

    @property
    def tables(self):
        t = self.store.dataset(self.name)
        return [{"name": self.name, "rows": len(t.rows), "from": "provost"}]

    def table_names(self):
        return [self.name]

    def table_count(self):
        return 1

    def load(self, name=None):
        if name not in (None, self.name):
            die("%s has one table, %s" % (self.id, self.name))
        t = self.store.dataset(self.name)
        # provost's capture id first, as `capture` whatever provost named
        # it; a data column of that name becomes capture_2 (the first free
        # capture_K), the way provost renames a data column called `#`
        ci = capture_column(t.columns)
        keep = [i for i, c in enumerate(t.columns) if c != "#" and i != ci]
        names = [t.columns[i] for i in keep]
        if "capture" in names:
            k = 2
            while "capture_%d" % k in names:
                k += 1
            names[names.index("capture")] = "capture_%d" % k
        out = Table(["capture"] + names,
                    [[self.store.row_capture(t, r)] + [r[i] for i in keep]
                     for r in t.rows], self.name, t.source, t.tests,
                    t.notes)
        out.entry = self
        return out

    def summary(self):
        return plural(len(self.store.dataset(self.name).rows), "row")

    def row_count(self):
        """Its rows, counted without reading them in: one a line, as
        read_dataset takes them."""
        if self.name in self.store._tables:
            return len(self.store._tables[self.name].rows)
        n = 0
        with open(self.store.path("datasets", self.name + ".tsv"),
                  "rb") as f:
            for ln in f:
                if ln.strip(b"\r\n"):
                    n += 1
        return max(0, n - 1)

    def raw(self, host=None, pas=None, capture=None):
        if capture:
            text = self.store.output(capture)
            if text is not None:
                return [(source_label(self.store, capture), text)]
        return []


def source_label(store, cid):
    n = first_row(store.meta(cid))
    note = store.truncation_note(cid)
    return "raw answer: capture %s%s%s" % (
        cid, (", " + store.provost("source %d" % n)) if n is not None
        else "", (" -- " + note) if note else "")


def _less_prologue(text):
    """A stored input less its leading '#%' lines."""
    lines = text.split("\n")
    i = 0
    while i < len(lines) and lines[i].startswith("#%"):
        i += 1
    return "\n".join(lines[i:])


def _file_sha256(path):
    h = hashlib.sha256()
    try:
        with open(path, "rb") as fh:
            for chunk in iter(lambda: fh.read(1 << 20), b""):
                h.update(chunk)
    except OSError:
        return ""
    return h.hexdigest()


def split_ref(ref):
    """`ENTRY:TABLE` -> (ENTRY, TABLE); a bare ref has no table (and
    ds:NAME is a dataset, not a table of an entry called ds)."""
    if ":" in ref and not os.path.exists(ref):
        a, _, b = ref.rpartition(":")
        if a and b and "/" not in b and a != "ds":
            return a, b
    return ref, None


def split_store(ref):
    """`REF@STORE` -> (REF, STORE): a reference that names the registered
    store it is read from (`kernel@wr01`, `latest:hosts@wr01`).  The split
    is on the last `@`, which is in no run id or provost dataset name; a
    file or directory whose name has one in it is still a file."""
    if "@" in ref and not os.path.exists(ref) and \
            not os.path.exists(split_ref(ref)[0]):
        a, _, b = ref.rpartition("@")
        if a and b and "/" not in b:
            return a, b
    return ref, None


def shown_id(e, table=None):
    """A run (or dataset) as a reference to it: `ID`, `ID:TABLE`, and
    `@STORE` after either when it was read from a store other than the
    command's own -- so a pasted report says where each side came from,
    and the words can be typed back."""
    via = getattr(getattr(e, "store", None), "via", None)
    return "%s%s%s" % (e.id, (":" + table) if table else "",
                       ("@" + via) if via else "")


def load_ref(store, ref, fmt=None):
    """A table from a store reference or straight from a file/directory.

    Files and directories are read through the importers, so anything
    `qd import` would take can be looked at without filing it first.
    """
    from . import importers
    ref_, tname = split_ref(ref)
    if os.path.exists(ref_):
        tables = importers.read_path(ref_, fmt)
        if not tables:
            die("nothing readable in %s" % ref_)
        if tname:
            hits = [t for t in tables if t.name == tname]
            if not hits:
                die("%s has no table %r (tables: %s)" % (
                    ref_, tname, ", ".join(t.name for t in tables)))
            return hits[0]
        return tables[0]
    return store.resolve(ref_).load(tname)


def operator_shown(meta):
    """`alice@build1`, `alice`, `@build1`, or blank: who ran a run, where."""
    who, where = meta.get("operator", ""), meta.get("operator_host", "")
    if who and where:
        return "%s@%s" % (who, where)
    return who or ("@" + where if where else "")


def describe_entry(e):
    """What `qd log ENTRY` prints."""
    m = e.meta
    out = ["%s  %s" % (shown_id(e), m.get("name") or "")]
    out.append("  kind      %s" % m.get("kind", "?"))
    if m.get("created"):
        out.append("  created   %s" % m["created"])
    if m.get("command"):
        out.append("  command   %s" % m["command"])
    if m.get("cwd"):
        out.append("  cwd       %s" % m["cwd"])
    if m.get("operator") or m.get("operator_host"):
        out.append("  by        %s" % operator_shown(m))
    via = [("as " + m["ssh_user"]) if m.get("ssh_user") else "",
           ("key " + m["ssh_key"]) if m.get("ssh_key") else "",
           {"yes": "under sudo", "no": "no sudo"}.get(m.get("sudo", ""), "")]
    if any(via):
        out.append("  ssh       %s" % ", ".join(v for v in via if v))
    if m.get("via") and m["via"] != "ssh":
        out.append("  via       %s%s" % (m["via"], (", job %s" % m[
            "sched_job"]) if m.get("sched_job") else ""))
    h = m.get("hosts")
    if h:
        parts = ["%d hosts" % h.get("total", 0)] + [
            "%d %s" % (h[k], k) for k in OUTCOMES if h.get(k)]
        out.append("  hosts     %s" % ", ".join(parts))
    if m.get("rerun_of"):
        out.append("  rerun of  %s  (the hosts that were not ok there)"
                   % m["rerun_of"].replace(",", ", "))
    if (m.get("passes") or 1) > 1:
        out.append("  passes    %d every %ss" % (m["passes"], m.get("every")))
    if m.get("duration_s") is not None:
        out.append("  took      %ss" % m["duration_s"])
    if m.get("rc") is not None:
        out.append("  exit      %s" % m["rc"])
    for k, v in sorted((m.get("tools") or {}).items()):
        out.append("  tool      %s" % v)
    caps = e.captures() if hasattr(e, "captures") else []
    if caps:
        lo, hi = min(caps, key=cnum), max(caps, key=cnum)
        out.append("  filed     %s, %s%s" % (
            "%d capture%s" % (len(caps), "" if len(caps) == 1 else "s"),
            lo, (".." + hi) if len(caps) > 1 else ""))
        n = first_row(e.store.meta(caps[0]))
        if n is not None:
            out.append("  answers   %s  (one per row: qd show "
                       "%s --cols host,capture)" % (
                           e.store.provost("source %d" % n), shown_id(e)))
    out.append("  store     %s" % e.store.shown())
    out.append("  tables")
    for t in e.tables:
        out.append("    %-18s %6d rows  %s%s" % (
            t["name"], t.get("rows", 0), ", ".join(t.get("datasets") or []),
            ("  <- %s" % t["from"]) if t.get("from") not in
            (None, "", "ssh", "provost") else ""))
        for n in (t.get("notes") or [])[:6]:
            out.append("      # %s" % n)
    for n in m.get("notes", []):
        out.append("  note      %s" % n)
    return out
