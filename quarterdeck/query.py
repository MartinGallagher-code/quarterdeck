# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Martin J. Gallagher
"""--where expressions and --sort keys.

    mbps<900                    numbers compare as numbers
    status!=ok and host~^wr01   ~ and !~ are regular expressions
    rtt_p99=                    blank: not measured
    rtt_p99!=                   measured at all
    status=ok                   text compares without regard to case
    not (loss>0 or rc!=0)
    "rtt (us)">200              quote a column name that has spaces

Nothing here is evaluated as Python: the grammar is the whole language.
A value that holds spaces or parentheses is quoted; a bare word ends at
whitespace or a parenthesis.
"""

import re

from .common import die
from .table import to_num

TOKEN_RE = re.compile(r"""
    (?P<ws>\s+)
  | (?P<lp>\()
  | (?P<rp>\))
  | (?P<op><=|>=|==|!=|!~|=|<|>|~)
  | (?P<str>"(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*')
  | (?P<word>[^\s()<>=!~"']+|!)
""", re.X)

OPS = ("<=", ">=", "==", "!=", "!~", "=", "<", ">", "~")


def tokenize(text):
    out, pos = [], 0
    while pos < len(text):
        m = TOKEN_RE.match(text, pos)
        if not m:
            die("cannot read %r at %r" % (text, text[pos:]))
        pos = m.end()
        kind = m.lastgroup
        if kind == "ws":
            continue
        val = m.group(kind)
        if kind == "str":
            val = re.sub(r"\\(.)", r"\1", val[1:-1])
        out.append((kind, val))
    return out


class Cond(object):
    def __init__(self, col, op, value):
        self.col, self.op, self.value = col, op, value
        self.num = to_num(value) if value else None
        self.rx = None
        if op in ("~", "!~"):
            try:
                self.rx = re.compile(value)
            except re.error as exc:
                die("bad regular expression %r: %s" % (value, exc))

    def bind(self, table):
        self.i = table.index(self.col)
        self.colname = table.columns[self.i]
        return self

    def test(self, row):
        cell = row[self.i].strip()
        op, v = self.op, self.value
        if op is None:                  # a bare column: is it measured?
            return bool(cell)
        if op in ("~", "!~"):
            hit = self.rx.search(cell) is not None
            return hit if op == "~" else not hit
        if v == "":
            if op in ("=", "=="):
                return cell == ""
            if op == "!=":
                return cell != ""
        n = to_num(cell)
        if self.num is not None and n is not None:
            a, b = n, self.num
        else:
            if op in ("<", "<=", ">", ">=") and not cell:
                return False            # blank is not less than anything
            # Text compares without regard to case: `status=ok` should not
            # miss a host that said OK.  ~ is the exact tool when it matters.
            a, b = cell.lower(), v.lower()
        if op in ("=", "=="):
            return a == b
        if op == "!=":
            return a != b
        if op == "<":
            return a < b
        if op == "<=":
            return a <= b
        if op == ">":
            return a > b
        return a >= b

    def __str__(self):
        if self.op is None:
            return self.col
        v = self.value
        if not v or re.search(r"[\s()]", v):
            v = '"%s"' % v.replace('"', '\\"')
        return "%s%s%s" % (self.col, self.op, v)


class Not(object):
    def __init__(self, a):
        self.a = a

    def bind(self, t):
        self.a.bind(t)
        return self

    def test(self, row):
        return not self.a.test(row)

    def __str__(self):
        return "not %s" % self.a


class BoolOp(object):
    def __init__(self, op, parts):
        self.op, self.parts = op, parts

    def bind(self, t):
        for p in self.parts:
            p.bind(t)
        return self

    def test(self, row):
        if self.op == "and":
            return all(p.test(row) for p in self.parts)
        return any(p.test(row) for p in self.parts)

    def __str__(self):
        return (" %s " % self.op).join(
            "(%s)" % p if isinstance(p, BoolOp) else str(p)
            for p in self.parts)


class _Parser(object):
    def __init__(self, text):
        self.text = text
        self.toks = tokenize(text)
        self.i = 0

    def peek(self):
        return self.toks[self.i] if self.i < len(self.toks) else (None, None)

    def take(self):
        t = self.peek()
        self.i += 1
        return t

    def kw(self, word):
        k, v = self.peek()
        return k == "word" and v.lower() == word

    def parse(self):
        if not self.toks:
            die("empty --where expression")
        e = self.or_()
        if self.i < len(self.toks):
            die("cannot read %r: unexpected %r" % (self.text, self.peek()[1]))
        return e

    def or_(self):
        parts = [self.and_()]
        while self.kw("or"):
            self.take()
            parts.append(self.and_())
        return parts[0] if len(parts) == 1 else BoolOp("or", parts)

    def and_(self):
        parts = [self.not_()]
        while self.kw("and"):
            self.take()
            parts.append(self.not_())
        return parts[0] if len(parts) == 1 else BoolOp("and", parts)

    def not_(self):
        if self.kw("not") or self.peek() == ("word", "!"):
            self.take()
            return Not(self.not_())
        return self.atom()

    def atom(self):
        k, v = self.take()
        if k == "lp":
            e = self.or_()
            if self.take()[0] != "rp":
                die("cannot read %r: a ( is not closed" % self.text)
            return e
        if k not in ("word", "str"):
            die("cannot read %r: expected a column name, got %r"
                % (self.text, v))
        col = v
        k2, op = self.peek()
        if k2 != "op":
            return Cond(col, None, "")
        self.take()
        k3, val = self.peek()
        if k3 in ("word", "str") and not (k3 == "word" and val.lower() in
                                          ("and", "or")):
            self.take()
        else:
            val = ""
        return Cond(col, op, val)


def parse(text):
    return _Parser(text).parse()


def where(table, exprs):
    """The rows every expression keeps.  Several --where flags AND."""
    if not exprs:
        return table.rows
    bound = [parse(e).bind(table) for e in exprs]
    return [r for r in table.rows if all(b.test(r) for b in bound)]


def sort_key_fn(table, spec):
    """--sort a,-b: numbers numerically, then text, blanks always last."""
    keys = []
    for part in [p.strip() for p in spec.split(",") if p.strip()]:
        desc = part.startswith("-")
        name = part.lstrip("+-")
        keys.append((table.index(name), desc))
    return keys


def sort_rows(table, rows, spec):
    if not spec:
        return list(rows)
    keys = sort_key_fn(table, spec)
    rows = list(rows)
    # Stable sorts applied last key first: each pass orders by one key, and
    # blanks go to the end in either direction -- "not measured" is never
    # the smallest value or the largest.
    for i, desc in reversed(keys):
        def k(r, i=i):
            cell = r[i].strip()
            n = to_num(cell)
            if n is not None:
                return (0, n, "")
            return (1, 0, cell.lower())
        filled = [r for r in rows if r[i].strip()]
        blank = [r for r in rows if not r[i].strip()]
        filled.sort(key=k, reverse=desc)
        rows = filled + blank
    return rows
