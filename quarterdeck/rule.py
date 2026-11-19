# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Martin J. Gallagher
"""qd check --rule: one overall verdict from the requirements (QD-051).

The grammar is prefix calls, and nothing else:

    rule     := term
    term     := REQ | GLOB | call
    call     := all(items) | any(items) | not(term)
              | atleast(N, items) | weighted(T, members)
    items    := term {, term}            (a glob gives one item per req)
    members  := REQ-or-GLOB {, REQ-or-GLOB}

A word is a run of anything but `(`, `)`, `,` and white space; it is a
call when `(` follows it (the five names, in any case), otherwise a `req`
of the thresholds file, or a glob (`*`, `?`, `[...]`) over them.  Where
one term belongs (the whole rule, `not`'s), a glob must match exactly one
req.  N is a whole number from 1 to the items' count; T a number from 0
to 1, held against sum(weight of the members that passed) / sum(weight).

Every requirement is pass, fail or not measured: its checks taken
together, as all() takes them.  A waived check counts as a pass, an
unexpected pass as a fail, a failure below --fail-level as a pass, and
not measured as neither.  The calls follow three-valued logic, so not
measured never becomes a pass: not() of it is not measured; atleast and
weighted are not measured when the unmeasured could still decide them.
The verdicts of the checks themselves are not changed.
"""

import fnmatch
import re

from . import check as checkmod
from .common import die, plural

CALLS = ("all", "any", "not", "atleast", "weighted")
PASS, FAIL, UNMEASURED = checkmod.PASS, checkmod.FAIL, checkmod.UNMEASURED
# the req of the overall verdict's row in the verdict table; `(` cannot
# be in a rule's word, so no rule can name a check of that req
ROW_REQ = "(rule)"
GLOB_CHARS = "*?["
TOKEN = re.compile(r"\s*(?:([(),])|([^\s(),]+))")


class Node(object):
    def __init__(self, kind, items=(), name="", n=None, label=""):
        self.kind = kind          # req, all, any, not, atleast, weighted
        self.items = list(items)  # sub-nodes
        self.name = name          # a req's name
        self.n = n                # atleast's N, weighted's threshold
        self.label = label        # the glob the items came from, if one
        self.shown = ""           # as written, tidied
        self.verdict = UNMEASURED
        self.why = ""

    def text(self):
        return self.shown


def _tokens(text):
    out, pos = [], 0
    text = text.rstrip()
    while pos < len(text):
        m = TOKEN.match(text, pos)
        if not m or m.end() == pos:
            die("--rule %r: cannot read it at %r" % (text, text[pos:]), 2)
        out.append(m.group(1) or m.group(2))
        pos = m.end()
    return out


class _Parser(object):
    def __init__(self, text, reqs, weights):
        self.text = text
        self.toks = _tokens(text)
        self.i = 0
        self.reqs = reqs
        self.weights = weights

    def bad(self, msg):
        die("--rule %r: %s" % (self.text, msg), 2)

    def peek(self):
        return self.toks[self.i] if self.i < len(self.toks) else None

    def take(self, want=None):
        t = self.peek()
        if t is None:
            self.bad("it ends too soon%s" % (
                (": want %s" % want) if want else ""))
        if want is not None and t != want:
            self.bad("want %s, not %r" % (want, t))
        self.i += 1
        return t

    def word(self):
        t = self.take()
        if t in ("(", ")", ","):
            self.bad("want a req or a call, not %r" % t)
        return t

    def reqs_of(self, w):
        """The reqs a word names: itself, or a glob's matches."""
        if any(c in w for c in GLOB_CHARS):
            got = [r for r in self.reqs if fnmatch.fnmatchcase(r, w)]
            if not got:
                self.bad("%s matches no req of the thresholds file" % w)
            return got
        if w not in self.reqs:
            self.bad("unknown req %s (the thresholds file has %s)" % (
                w, ", ".join(self.reqs[:12]) +
                (" ..." if len(self.reqs) > 12 else "")))
        return [w]

    def leaf(self, r):
        n = Node("req", name=r)
        n.shown = r
        return n

    def one(self):
        """A term where one belongs: a call, or a word naming one req."""
        w = self.word()
        if self.peek() == "(":
            return self.call(w)
        got = self.reqs_of(w)
        if len(got) != 1:
            self.bad("%s matches %d reqs where one belongs; put them in "
                     "all(), any() or atleast()" % (w, len(got)))
        return self.leaf(got[0])

    def items(self, plain=False):
        """A comma list of terms, globs spread out; (nodes, the glob when
        one word gave them all, the list as written)."""
        out, words, shown = [], [], []
        while True:
            w = self.word()
            if self.peek() == "(":
                if plain:
                    self.bad("weighted takes reqs and globs, not %s()" % w)
                out.append(self.call(w))
                words.append(None)
                shown.append(out[-1].shown)
            else:
                for r in self.reqs_of(w):
                    out.append(self.leaf(r))
                words.append(w)
                shown.append(w)
            if self.peek() == ",":
                self.take()
                continue
            break
        seen = set()
        for x in out:
            if x.kind == "req":
                if x.name in seen:
                    self.bad("%s is named twice in one list" % x.name)
                seen.add(x.name)
        label = words[0] if len(words) == 1 and words[0] is not None and \
            any(c in words[0] for c in GLOB_CHARS) else ""
        return out, label, ", ".join(shown)

    def number(self):
        t = self.word()
        self.take(",")
        return t

    def call(self, w):
        name = w.lower()
        if name not in CALLS:
            self.bad("unknown call %s() (want %s)" % (
                w, ", ".join(c + "()" for c in CALLS)))
        self.take("(")
        if self.peek() == ")":
            self.bad("%s() is empty" % name)
        n = None
        if name == "not":
            items, label = [self.one()], ""
            written = items[0].shown
        elif name == "atleast":
            t = self.number()
            if not re.match(r"^[0-9]+$", t):
                self.bad("atleast wants a whole number first, not %r" % t)
            n = int(t)
            items, label, written = self.items()
            if n < 1 or n > len(items):
                self.bad("atleast(%d, ...) of %s: N is 1 to %d" % (
                    n, plural(len(items), "item"), len(items)))
        elif name == "weighted":
            t = self.number()
            try:
                n = float(t)
            except ValueError:
                n = None
            if n is None or not 0.0 <= n <= 1.0:
                self.bad("weighted wants a threshold from 0 to 1 first, "
                         "not %r" % t)
            items, label, written = self.items(plain=True)
            if not sum(self.weights.get(x.name, 1.0) for x in items) > 0:
                self.bad("the weights of weighted(%s, ...) add up to 0" % t)
        else:
            items, label, written = self.items()
        self.take(")")
        node = Node(name, items, n=n, label=label)
        inner = written
        if name == "atleast":
            inner = "%d, %s" % (n, written)
        elif name == "weighted":
            inner = "%s, %s" % (_num(n), written)
        node.shown = "%s(%s)" % (name, inner)
        return node


def _num(v):
    return ("%.4g" % v) if v is not None else ""


def parse(text, checks):
    """The rule's tree, or exit 2 naming what it cannot read."""
    reqs = []
    for c in checks:
        if c.req not in reqs:
            reqs.append(c.req)
    weights = checkmod.req_weights(checks)
    p = _Parser(text.strip(), reqs, weights)
    if not p.toks:
        p.bad("it is empty")
    node = p.one()
    if p.peek() is not None:
        p.bad("%r after the end of the rule" % " ".join(p.toks[p.i:]))
    node.weights = weights
    return node


def _req_state(results, level):
    """A requirement's verdict for the rule, and a word on why."""
    vs, how = [], []
    for r in results:
        if r.verdict == checkmod.WAIVED:
            vs.append(PASS)
            how.append("waived")
        elif r.verdict in (checkmod.FAIL, checkmod.UNEXPECTED):
            if checkmod.rank(r.chk.severity) < checkmod.rank(level):
                vs.append(PASS)
                how.append("below --fail-level")
            else:
                vs.append(FAIL)
                if r.verdict == checkmod.UNEXPECTED:
                    how.append("unexpected pass")
        else:
            vs.append(r.verdict)
    return _all(vs), how


def _all(vs):
    if FAIL in vs:
        return FAIL
    if UNMEASURED in vs:
        return UNMEASURED
    return PASS


def _names(nodes, verdict, most=3):
    got = [x.shown for x in nodes if x.verdict == verdict]
    return ", ".join(got[:most]) + (" ..." if len(got) > most else "")


def _of(node):
    return (" " + node.label) if node.label else ""


def evaluate(node, results, level="info"):
    """Work out every node's verdict and why; the top's verdict."""
    by = {}
    for r in results:
        by.setdefault(r.chk.req, []).append(r)
    _walk(node, by, level, getattr(node, "weights", {}))
    return node.verdict


def _walk(node, by, level, weights):
    if node.kind == "req":
        node.verdict, how = _req_state(by.get(node.name, []), level)
        node.how = how
        word = {PASS: "passed", FAIL: "failed",
                UNMEASURED: "not measured"}[node.verdict]
        node.why = "%s %s%s" % (node.name, word,
                                (" (%s)" % ", ".join(sorted(set(how))))
                                if how else "")
        return
    for x in node.items:
        _walk(x, by, level, weights)
    vs = [x.verdict for x in node.items]
    k = len(vs)
    p, u = vs.count(PASS), vs.count(UNMEASURED)
    tail = ("; %d not measured: %s" % (u, _names(node.items, UNMEASURED))) \
        if u else ""
    if node.kind == "not":
        x = node.items[0]
        node.verdict = {PASS: FAIL, FAIL: PASS,
                        UNMEASURED: UNMEASURED}[x.verdict]
        node.why = "not: %s" % x.why
    elif node.kind == "all":
        node.verdict = _all(vs)
        if node.verdict == PASS:
            node.why = "all %d%s passed" % (k, _of(node))
        else:
            f = vs.count(FAIL)
            node.why = "%d of %d%s passed, need all %d%s%s" % (
                p, k, _of(node), k,
                ("; failed: %s" % _names(node.items, FAIL)) if f else "",
                tail)
    elif node.kind in ("any", "atleast"):
        need = 1 if node.kind == "any" else node.n
        if p >= need:
            node.verdict = PASS
        elif p + u >= need:
            node.verdict = UNMEASURED
        else:
            node.verdict = FAIL
        node.why = "%d of %d%s passed, need %d%s" % (p, k, _of(node), need,
                                                    tail)
    elif node.kind == "weighted":
        total = sum(weights.get(x.name, 1.0) for x in node.items)
        got = sum(weights.get(x.name, 1.0) for x in node.items
                  if x.verdict == PASS)
        maybe = sum(weights.get(x.name, 1.0) for x in node.items
                    if x.verdict == UNMEASURED)
        eps = 1e-9
        if got / total + eps >= node.n:
            node.verdict = PASS
        elif (got + maybe) / total + eps >= node.n:
            node.verdict = UNMEASURED
        else:
            node.verdict = FAIL
        node.why = "weighted score %s of%s (%s of %s), need %s%s" % (
            _num(got / total), _of(node) or " %d" % k, _num(got),
            _num(total), _num(node.n), tail)


def lines(node, indent="  "):
    """The tree, one line a call: its verdict, as written, and why; and
    a line for a req counted otherwise than its verdict reads (waived, an
    unexpected pass, a failure below --fail-level)."""
    out = []

    def walk(x, depth):
        lead = (indent if not depth else " " * len(indent)) + "  " * depth
        if x.kind == "req":
            # a req is in the verdict table; here only when the rule
            # counts it otherwise than its verdict reads
            if getattr(x, "how", None) and depth:
                out.append("%s%-12s %s" % (lead, x.verdict, x.why))
            return
        out.append("%s%-12s %s: %s" % (lead, x.verdict, x.shown, x.why))
        for y in x.items:
            walk(y, depth + 1)
    walk(node, 0)
    return out


def named(node):
    """Every req the rule names."""
    if node.kind == "req":
        return set([node.name])
    out = set()
    for x in node.items:
        out |= named(x)
    return out
