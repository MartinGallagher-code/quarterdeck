# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Martin J. Gallagher
"""qd view: a dataset on a full screen, to move around in and ask of.

The explorer is a stack of views -- the table, a column's statistics, the
counts of its values, a group-by, a diff -- each a plain object that turns
keys into state and state into lines of text.  curses only draws those
lines, so the whole thing runs without a terminal too: QD_TEST_KEYS
drives it with a script of keys (`fstatus!=ok<enter>d`) and the last
screen is printed, which is how the suite tests it.

Every report here is the one the matching verb prints (`d` is `qd stats
COL`, `c` is `qd freq`, `x` is `qd diff`), over the rows the view holds.
"""

import argparse
import os
import re
import sys

from .common import PROG, QdError, die, plural, write_text
from . import query, render, stats, table as tablemod

HELP = """\
qd view -- keys

  moving          arrows (or j k), PgUp/PgDn (b/space), Home/End,
                  0 and $ for the first and last column
  sorting         s  sort by this column (again: reverse)   S  descending
  filtering       f  filter: an expression, as --where takes one
                  =  keep rows with this cell's value
                  !  drop rows with this cell's value
                  u  undo the last filter       F  clear every filter
  searching       /  search for a regular expression   n N  next, previous
  columns         -  hide this column   *  show them all   w  widen it
  asking          d  this column in depth: centre, spread, histogram
                  D  every column described, as a table to explore
                  c  counts of each value, and who holds it (Enter filters)
                  g  group by this column (Enter on a group filters to it)
                  h  histogram          o  outliers by median and MAD
                  t  trend over time, per host
                  p  pivot: rows,cols[,values]
                  x  diff against another entry (default: its last run)
  rows            Enter  every field of this row, and the host's raw answer
  elsewhere       T  another table of this run     L  the runs in the store
                  e  export this view to a file    r  reload from disk
  leaving         q or Esc  back one view   Q  quit

A blank cell is "not measured" and stays out of every figure.
Expressions: mbps<900  status!=ok  host~^wr01  rtt_p99=  not (a>1 or b=x)
"""

UP, DOWN, LEFT, RIGHT = "UP", "DOWN", "LEFT", "RIGHT"
PGUP, PGDN, HOME, END = "PGUP", "PGDN", "HOME", "END"
ENTER, ESC, BS, TAB, DEL, KILL = "ENTER", "ESC", "BS", "TAB", "DEL", "KILL"

TEST_KEYS = {
    "<up>": UP, "<down>": DOWN, "<left>": LEFT, "<right>": RIGHT,
    "<pgup>": PGUP, "<pgdn>": PGDN, "<home>": HOME, "<end>": END,
    "<enter>": ENTER, "<esc>": ESC, "<bs>": BS, "<tab>": TAB, "<del>": DEL,
    "<kill>": KILL,
}

GOOD = ("ok", "pass", "tested", "reporting")
BAD = ("failed", "fail", "unreachable", "timeout", "push-failed", "no-data")
WARN = ("warn", "silent", "skipped")


def test_tokens(script):
    """QD_TEST_KEYS as keys: `fhost~01<enter>d` -- rig's convention."""
    out, i = [], 0
    while i < len(script):
        if script[i] == "<":
            j = script.find(">", i)
            name = script[i:j + 1].lower() if j > i else ""
            if name in TEST_KEYS:
                out.append(TEST_KEYS[name])
                i = j + 1
                continue
        out.append(script[i])
        i += 1
    return out


def opts(**kw):
    """The options a verb's report reads, with the defaults its flags have."""
    base = dict(where=None, loose=False, label=None, top=20,
                all_labels=False, lines=12, bins=None, bar_width=36, per=None,
                no_per=False, z=3.5, by=None, over=None, points=40,
                rows=None, cols_=None, values=None, agg="auto", width=None,
                key=None, cols=None, tolerance=0.0, limit=30, format=None)
    base.update(kw)
    return argparse.Namespace(**base)


def quote_value(v):
    if v and re.match(r"""^[^\s()<>=!~"']+$""", v):
        return v
    return '"%s"' % v.replace("\\", "\\\\").replace('"', '\\"')


def quote_col(c):
    return c if re.match(r"""^[^\s()<>=!~"']+$""", c) else quote_value(c)


class Line(object):
    __slots__ = ("text", "spans")

    def __init__(self, text, spans=None):
        self.text, self.spans = text, spans or []


def fit(text, w):
    return text[:w].ljust(w)


# ---------------------------------------------------------------------------
# Views
# ---------------------------------------------------------------------------

class View(object):
    title = ""

    def __init__(self, app):
        self.app = app

    def key(self, k):
        return False

    def render(self, h, w):
        return []

    def status(self):
        return ""


class TextView(View):
    """A report to scroll: what a verb would have printed."""

    def __init__(self, app, title, lines):
        View.__init__(self, app)
        self.title = title
        self.lines = [ln.rstrip() for ln in lines]
        self.top = 0
        self.search = None

    def key(self, k):
        n = len(self.lines)
        page = max(1, self.app.h - 3)
        if k in (DOWN, "j"):
            self.top = min(max(0, n - 1), self.top + 1)
        elif k in (UP, "k"):
            self.top = max(0, self.top - 1)
        elif k in (PGDN, " "):
            self.top = min(max(0, n - page), self.top + page)
        elif k in (PGUP, "b"):
            self.top = max(0, self.top - page)
        elif k in (HOME, "g"):
            self.top = 0
        elif k in (END, "G"):
            self.top = max(0, n - page)
        elif k == "/":
            self.app.ask("search /", self._search)
        elif k == "n" and self.search:
            self._find(self.top + 1)
        else:
            return False
        return True

    def _search(self, text):
        try:
            self.search = re.compile(text)
        except re.error as exc:
            die("bad regular expression: %s" % exc)
        self._find(self.top)

    def _find(self, start):
        for i in list(range(start, len(self.lines))) + list(range(0, start)):
            if self.search.search(self.lines[i]):
                self.top = i
                return
        self.app.message = "no match for /%s/" % self.search.pattern

    def render(self, h, w):
        body = self.lines[self.top:self.top + h]
        return [Line(fit(ln, w)) for ln in body]

    def status(self):
        n = len(self.lines)
        return "line %d of %d   / search   q back" % (
            min(n, self.top + 1), n)


class ListView(View):
    """Lines to choose from: value counts, tables, runs."""

    def __init__(self, app, title, head, items, on_enter, hint="Enter picks"):
        View.__init__(self, app)
        self.title = title
        self.head = head
        self.items = items        # [(text, payload)]
        self.on_enter = on_enter
        self.cur = 0
        self.top = 0
        self.hint = hint

    def key(self, k):
        n = len(self.items)
        page = max(1, self.app.h - 3 - len(self.head))
        if k in (DOWN, "j"):
            self.cur = min(n - 1, self.cur + 1)
        elif k in (UP, "k"):
            self.cur = max(0, self.cur - 1)
        elif k in (PGDN, " "):
            self.cur = min(n - 1, self.cur + page)
        elif k in (PGUP, "b"):
            self.cur = max(0, self.cur - page)
        elif k in (HOME, "g"):
            self.cur = 0
        elif k in (END, "G"):
            self.cur = max(0, n - 1)
        elif k == ENTER and self.items:
            self.on_enter(self.items[self.cur][1])
        else:
            return False
        return True

    def render(self, h, w):
        out = [Line(fit(ln, w), [(0, w, "dim")]) for ln in self.head]
        room = max(1, h - len(out))
        if self.cur < self.top:
            self.top = self.cur
        elif self.cur >= self.top + room:
            self.top = self.cur - room + 1
        for i in range(self.top, min(len(self.items), self.top + room)):
            text = fit(self.items[i][0], w)
            spans = [(0, w, "cursor")] if i == self.cur else []
            out.append(Line(text, spans))
        return out

    def status(self):
        return "%d of %d   %s   q back" % (
            self.cur + 1 if self.items else 0, len(self.items), self.hint)


class TableView(View):
    """The dataset itself, filtered and sorted however you have asked."""

    def __init__(self, app, t, where=None, sort=None, on_enter=None,
                 title=None):
        View.__init__(self, app)
        self.base = t
        self.filters = list(where or [])
        self.sort = sort or ""
        self.hidden = set()
        self.wide = set()
        self.on_enter = on_enter
        self.title = title or source_title(t)
        self.r = self.c = 0
        self.top = self.left = 0
        self.search = None
        self._stats = {}
        self.recompute()

    # -- data -----------------------------------------------------------------

    def recompute(self):
        rows = query.where(self.base, [f for f in self.filters
                                       if isinstance(f, str)])
        for f in self.filters:
            if not isinstance(f, str):
                _, i, value, _ = f
                rows = [r for r in rows if r[i] == value]
        if self.sort:
            rows = query.sort_rows(self.base, rows, self.sort)
        self.view = self.base.derive(rows=rows)
        self._stats = {}
        self.r = min(self.r, max(0, len(rows) - 1))
        self.c = min(self.c, max(0, len(self.cols()) - 1))

    def cols(self):
        return [c for c in self.base.columns if c not in self.hidden]

    def col(self):
        cs = self.cols()
        return cs[self.c] if cs else None

    def cell(self):
        c = self.col()
        if c is None or not self.view.rows:
            return None
        return self.view.rows[self.r][self.base.columns.index(c)]

    def add_filter(self, expr):
        query.parse(expr).bind(self.base)       # refuse before keeping it
        self.filters.append(expr)
        self.recompute()
        self.app.message = "%s where %s" % (plural(len(self.view.rows), "row"),
                                            expr)

    # -- keys -----------------------------------------------------------------

    def key(self, k):
        n = len(self.view.rows)
        ncols = len(self.cols())
        page = max(1, self.app.h - 5)
        if k in (DOWN, "j"):
            self.r = min(max(0, n - 1), self.r + 1)
        elif k in (UP, "k"):
            self.r = max(0, self.r - 1)
        elif k == RIGHT:
            self.c = min(max(0, ncols - 1), self.c + 1)
        elif k == LEFT:
            self.c = max(0, self.c - 1)
        elif k in (PGDN, " "):
            self.r = min(max(0, n - 1), self.r + page)
        elif k in (PGUP, "b"):
            self.r = max(0, self.r - page)
        elif k == HOME:
            self.r = 0
        elif k == END:
            self.r = max(0, n - 1)
        elif k == "0":
            self.c = 0
        elif k == "$":
            self.c = max(0, ncols - 1)
        elif k in ("s", "S"):
            self.sort_by(k == "S")
        elif k == "f":
            self.app.ask("filter where", self.add_filter,
                         complete=self.base.columns)
        elif k in ("=", "!"):
            self.quick_filter(k)
        elif k == "u":
            if self.filters:
                gone = self.filters.pop()
                self.recompute()
                self.app.message = "dropped filter %s" % (
                    gone if isinstance(gone, str) else gone[3])
        elif k == "F":
            self.filters = []
            self.recompute()
            self.app.message = "every filter cleared"
        elif k == "/":
            self.app.ask("search /", self.start_search)
        elif k in ("n", "N") and self.search:
            self.find(1 if k == "n" else -1)
        elif k == "-":
            c = self.col()
            if c is not None and len(self.cols()) > 1:
                self.hidden.add(c)
                self.c = min(self.c, len(self.cols()) - 1)
                self.app.message = "hid %s (* shows every column)" % c
        elif k == "*":
            self.hidden = set()
        elif k == "w":
            c = self.col()
            if c in self.wide:
                self.wide.discard(c)
            elif c is not None:
                self.wide.add(c)
        elif k == ENTER:
            if self.on_enter and self.view.rows:
                self.on_enter(self.view, self.view.rows[self.r])
            else:
                self.detail()
        elif k in ("d", "D", "c", "g", "h", "o", "t", "p", "x"):
            self.ask_of(k)
        elif k == "e":
            self.app.ask("export to", self.export)
        elif k == "r":
            self.reload()
        else:
            return False
        return True

    def sort_by(self, desc):
        c = self.col()
        if c is None:
            return
        name = quote_col(c) if "," not in c else c
        if not desc and self.sort == name:
            desc = True
        self.sort = ("-" if desc else "") + name
        self.recompute()
        self.app.message = "sorted by %s%s" % (c, " descending" if desc
                                                else "")

    def quick_filter(self, k):
        c, v = self.col(), self.cell()
        if c is None or v is None:
            return
        if "\n" in v:
            self.app.message = "a multi-line value: use c for its counts"
            return
        op = "=" if k == "=" else "!="
        expr = "%s%s%s" % (quote_col(c), op, quote_value(v) if v else "")
        self.add_filter(expr)

    def start_search(self, text):
        try:
            self.search = re.compile(text, re.I)
        except re.error as exc:
            die("bad regular expression: %s" % exc)
        self.find(0)

    def find(self, step):
        rows = self.view.rows
        if not rows:
            return
        idx = [self.base.columns.index(c) for c in self.cols()]
        order = range(1, len(rows) + 1) if step >= 0 else \
            range(-1, -len(rows) - 1, -1)
        start = self.r if step else self.r - 1
        for d in order:
            i = (start + d) % len(rows)
            for ci, j in enumerate(idx):
                if self.search.search(rows[i][j]):
                    self.r, self.c = i, ci
                    self.app.message = "/%s/ row %d" % (
                        self.search.pattern, i + 1)
                    return
        self.app.message = "no match for /%s/" % self.search.pattern

    def export(self, path):
        fmt = tablemod.format_for(path)
        write_text(path, tablemod.WRITERS[fmt](self.view))
        self.app.message = "wrote %d rows to %s" % (len(self.view.rows), path)

    def reload(self):
        e = getattr(self.base, "entry", None)
        if e is None:
            from .store import load_ref
            src = self.base.source
            if not src or not os.path.exists(src):
                die("nothing to reload this from")
            t = load_ref(self.app.book, src)
        else:
            t = e.load(self.base.name)
        self.base = t
        self.recompute()
        self.app.message = "reloaded: %d rows" % len(self.base.rows)

    def detail(self):
        if not self.view.rows:
            return
        row = self.view.rows[self.r]
        w = max(len(c) for c in self.base.columns)
        lines = []
        for c, v in zip(self.base.columns, row):
            vl = v.split("\n") if v else ["(blank)"]
            lines.append("%-*s  %s" % (w, c, vl[0]))
            for more in vl[1:]:
                lines.append("%-*s  %s" % (w, "", more))
        for label, text in self.raw_answers(row):
            lines.append("")
            lines.append("-- %s" % label)
            lines.extend(text.splitlines()[:2000])
        self.app.push(TextView(self.app, "row %d of %s" % (
            self.r + 1, self.title), lines))

    def raw_answers(self, row):
        """[(label, text)]: the answer this row came from, and stderr."""
        e = getattr(self.base, "entry", None)
        if e is None:
            return []
        cols = self.base.columns

        def get(c):
            return row[cols.index(c)] if c in cols else None
        if get("capture") is None and get("host") is None:
            return []
        return e.raw(host=get("host"), pas=get("pass"),
                     capture=get("capture"))

    def ask_of(self, k):
        from . import cli
        c = self.col()
        v = self.view
        a = self.app
        if c is None:
            return
        if k == "d":
            a.push(TextView(a, "%s in depth" % c, cli._one_column_report(
                self.base, v, c, opts(where=[
                    f if isinstance(f, str) else f[3]
                    for f in self.filters]))))
        elif k == "D":
            a.push(TableView(a, stats.describe(v), title="every column of "
                             "%s" % self.title))
        elif k == "c":
            fr = stats.freq(v, c)
            total = max(1, len(v.rows))
            top = fr[0][1] if fr else 1
            items = []
            for val, n, labels in fr:
                shown = render.first_line(val) if val else "(blank)"
                items.append(("%7d %5.1f%%  %-16s %s%s" % (
                    n, 100.0 * n / total, render.bar(n, top, 16), shown,
                    ("   " + cli.label_list(labels, limit=5)) if labels
                    and len(fr) > 1 else ""), val))
            head = ["%s: %s over %s" % (c, plural(len(fr), "distinct value"),
                                        plural(len(v.rows), "row"))]
            if len(fr) > 1:
                head.append("%d agree on the most common, %d do not" % (
                    fr[0][1], len(v.rows) - fr[0][1]))
            a.push(ListView(a, "counts of %s" % c, head, items,
                            lambda val, c=c: self.drill(c, val),
                            "Enter keeps those rows"))
        elif k == "g":
            g = stats.group_by(v, [c])
            a.push(TableView(a, g, title="%s grouped by %s" % (
                self.title, c), on_enter=lambda gt, row, c=c: self.drill(
                    c, row[0])))
        elif k == "h":
            lines, _ = cli.report_hist(opts(column=c), self.base, v)
            a.push(TextView(a, "histogram of %s" % c, lines))
        elif k == "o":
            lines, ot = cli.report_outliers(opts(column=c), self.base, v)
            key = ot.columns[0]
            if ot.rows and key in self.base.columns:
                a.push(TableView(a, ot, title="outliers in %s" % c,
                                 on_enter=lambda gt, row, key=key:
                                 self.drill(key, row[0])))
                a.message = lines[0]
            else:
                a.push(TextView(a, "outliers in %s" % c, lines))
        elif k == "t":
            lines, _ = cli.report_trend(opts(column=c), self.base, v)
            a.push(TextView(a, "trend of %s" % c, lines))
        elif k == "p":
            default = "target,test,value" if v.is_results() else ""
            a.ask("pivot rows,cols[,values]", self.pivot, initial=default,
                  complete=self.base.columns)
        elif k == "x":
            default = ""
            e = getattr(self.base, "entry", None)
            if e is not None:
                prev = a.book.previous_like(e)
                if prev is not None:
                    default = prev.id
            a.ask("diff against", self.diff, initial=default)

    def drill(self, col, value):
        """Back to this table, keeping only the rows holding `value`."""
        while self.app.views[-1] is not self:
            self.app.views.pop()
        if "\n" in value:
            # An expression cannot spell a multi-line value, so this one
            # is matched exactly, and u undoes it like any other.
            i = self.base.columns.index(col)
            label = "%s=<%s>" % (col, render.clip(render.first_line(value),
                                                  24))
            self.filters.append(("exact", i, value, label))
            self.recompute()
            self.app.message = "%d rows holding that value of %s" % (
                len(self.view.rows), col)
            return
        self.add_filter("%s%s%s" % (quote_col(col), "=",
                                    quote_value(value) if value else ""))

    def pivot(self, text):
        from . import cli
        parts = [p.strip() for p in text.split(",")]
        if len(parts) < 2:
            die("pivot wants rows,cols or rows,cols,values")
        lines, p = cli.report_pivot(opts(rows=parts[0], cols_=parts[1],
                                         values=parts[2] if len(parts) > 2
                                         else None), self.base, self.view)
        self.app.push(TableView(self.app, p, title="pivot " + text))

    def diff(self, ref):
        from . import cli, diff as diffmod
        from .store import load_ref
        if not ref:
            die("diff against what? a run, or a file")
        other = load_ref(self.app.book, ref)
        exprs = [f for f in self.filters if isinstance(f, str)]
        if exprs:
            other = other.derive(rows=query.where(other, exprs))
        res = diffmod.diff_tables(other, self.view)
        lines = cli.diff_report(other, self.view, res, opts())
        self.app.push(TextView(self.app, "diff %s -> this" % ref, lines))

    # -- drawing --------------------------------------------------------------

    def widths(self):
        out = {}
        sample = self.view.rows[:400]
        for c in self.cols():
            i = self.base.columns.index(c)
            w = max([len(c)] + [len(render.first_line(r[i])) for r in sample])
            cap = 80 if c in self.wide else 28
            out[c] = max(3, min(w, cap))
        return out

    def render(self, h, w):
        cols = self.cols()
        if not cols:
            return [Line(fit("(no columns)", w))]
        widths = self.widths()
        if self.c < self.left:
            self.left = self.c
        while True:
            total, last = 0, self.left
            for i in range(self.left, len(cols)):
                total += widths[cols[i]] + 2
                if total > w and i > self.left:
                    break
                last = i
            if self.c <= last or self.left >= self.c:
                break
            self.left += 1
        shown = cols[self.left:last + 1]
        idx = [self.base.columns.index(c) for c in shown]
        num = set(c for c in shown if self.base.kind(c) == "num")
        body = h - 1
        n = len(self.view.rows)
        if self.r < self.top:
            self.top = self.r
        elif self.r >= self.top + body:
            self.top = self.r - body + 1
        out = []
        head, spans, x = "", [], 0
        for c in shown:
            cw = widths[c]
            mark = c
            if self.sort.lstrip("-").strip('"') == c:
                mark = c + ("v" if self.sort.startswith("-") else "^")
            cellt = render.clip(mark, cw).ljust(cw)
            if c == self.col():
                spans.append((x, x + cw, "headcur"))
            head += cellt + "  "
            x += cw + 2
        out.append(Line(fit(head, w), [(0, w, "header")] + spans))
        for ri in range(self.top, min(n, self.top + body)):
            row = self.view.rows[ri]
            text, spans, x = "", [], 0
            for c, i in zip(shown, idx):
                cw = widths[c]
                v = render.clip(render.first_line(row[i]), cw)
                v = v.rjust(cw) if c in num else v.ljust(cw)
                low = row[i].strip().lower()
                if low in BAD:
                    spans.append((x, x + cw, "bad"))
                elif low in WARN:
                    spans.append((x, x + cw, "warn"))
                elif low in GOOD:
                    spans.append((x, x + cw, "good"))
                if ri == self.r and c == self.col():
                    spans.append((x, x + cw, "cursor"))
                text += v + "  "
                x += cw + 2
            if ri == self.r:
                spans.insert(0, (0, w, "select"))
            out.append(Line(fit(text, w), spans))
        if not n:
            out.append(Line(fit("  (no rows%s)" % (
                " -- u undoes the last filter" if self.filters else ""), w),
                [(0, w, "dim")]))
        return out

    def column_strip(self):
        c = self.col()
        if c is None:
            return ""
        if c in self._stats:
            return self._stats[c]
        kind = self.view.kind(c)
        vals = self.view.values(c)
        filled = sum(1 for v in vals if v.strip())
        bits = ["%s  %s" % (c, kind), "n %d" % filled]
        if len(vals) - filled:
            bits.append("blank %d" % (len(vals) - filled))
        if kind in ("num", "mixed"):
            sm = stats.summary(self.view.numbers(c))
            if sm["n"]:
                bits.append("min %s  median %s  mean %s  max %s" % tuple(
                    stats.fmt_num(sm[k]) for k in ("min", "median", "mean",
                                                   "max")))
                if sm.get("stdev") is not None:
                    bits.append("sd %s" % stats.fmt_num(sm["stdev"]))
        else:
            fr = stats.freq(self.view, c)
            bits.append("%d distinct" % len(fr))
            if fr:
                bits.append("top %s (%d)" % (render.clip(
                    render.first_line(fr[0][0]) or "(blank)", 30), fr[0][1]))
        s = "   ".join(bits)
        self._stats[c] = s
        return s

    def status(self):
        bits = ["row %d/%d" % (min(self.r + 1, len(self.view.rows)),
                               len(self.view.rows))]
        if len(self.view.rows) != len(self.base.rows):
            bits.append("of %d" % len(self.base.rows))
        if self.filters:
            bits.append("where " + " and ".join(
                f if isinstance(f, str) else f[3] for f in self.filters))
        if self.sort:
            bits.append("sort " + self.sort)
        if self.hidden:
            bits.append("%d hidden" % len(self.hidden))
        bits.append("? keys  q %s" % ("back" if len(self.app.views) > 1
                                      else "quit"))
        return "   ".join(bits)


def source_title(t):
    e = getattr(t, "entry", None)
    if e is not None:
        return "%s : %s" % (e.id, t.name)
    return t.source or t.name


# ---------------------------------------------------------------------------
# The application: a stack of views, a prompt, a message line
# ---------------------------------------------------------------------------

class Prompt(object):
    def __init__(self, label, on_submit, initial="", complete=None):
        self.label = label
        self.on_submit = on_submit
        self.text = initial
        self.pos = len(initial)
        self.complete = complete or []

    def key(self, k):
        if k == ENTER:
            return "submit"
        if k == ESC:
            return "cancel"
        if k == BS:
            if self.pos:
                self.text = self.text[:self.pos - 1] + self.text[self.pos:]
                self.pos -= 1
        elif k == DEL:
            self.text = self.text[:self.pos] + self.text[self.pos + 1:]
        elif k == LEFT:
            self.pos = max(0, self.pos - 1)
        elif k == RIGHT:
            self.pos = min(len(self.text), self.pos + 1)
        elif k == HOME:
            self.pos = 0
        elif k == END:
            self.pos = len(self.text)
        elif k == KILL:
            self.text, self.pos = "", 0
        elif k == TAB:
            self.tab()
        elif isinstance(k, str) and len(k) == 1 and k >= " ":
            self.text = self.text[:self.pos] + k + self.text[self.pos:]
            self.pos += 1
        return None

    def tab(self):
        """Complete the word before the cursor to a column name."""
        m = re.search(r"[\w.%-]*$", self.text[:self.pos])
        word = m.group(0) if m else ""
        hits = [c for c in self.complete if c.lower().startswith(word.lower())]
        if len(hits) == 1:
            add = hits[0][len(word):]
            self.text = self.text[:self.pos] + add + self.text[self.pos:]
            self.pos += len(add)


class App(object):
    def __init__(self, t, book, where=None, sort=None):
        self.book = book
        self.h, self.w = 24, 80
        self.views = []
        self.prompt = None
        self.message = ""
        self.done = False
        self.push(TableView(self, t, where, sort))

    def push(self, view):
        self.views.append(view)

    def ask(self, label, fn, initial="", complete=None):
        self.prompt = Prompt(label, fn, initial, complete)

    def key(self, k):
        if self.prompt is not None:
            what = self.prompt.key(k)
            if what == "cancel":
                self.prompt = None
            elif what == "submit":
                p, self.prompt = self.prompt, None
                try:
                    p.on_submit(p.text)
                except QdError as exc:
                    self.message = str(exc).splitlines()[0]
            return
        self.message = ""
        top = self.views[-1]
        try:
            if top.key(k):
                return
        except QdError as exc:
            self.message = str(exc).splitlines()[0]
            return
        if k in ("q", ESC):
            self.views.pop()
            if not self.views:
                self.done = True
        elif k == "Q":
            self.done = True
        elif k == "?":
            self.push(TextView(self, "keys", HELP.splitlines()))
        elif k == "T":
            self.pick_table(top)
        elif k == "L":
            self.pick_entry()

    def pick_table(self, top):
        base = getattr(top, "base", None)
        e = getattr(base, "entry", None)
        if e is None:
            self.message = "not a run in the store: it has no other tables"
            return
        items = [("%-20s %8d rows  %s" % (t["name"], t.get("rows", 0),
                                          t.get("from", "")), t["name"])
                 for t in e.tables]
        self.push(ListView(self, "tables of %s" % e.id, [e.id], items,
                           lambda name: self.open_entry(e, name)))

    def pick_entry(self):
        entries = list(reversed(self.book.entries()))
        if not entries:
            self.message = "no runs in the store %s yet" % self.book.shown()
            return
        items = []
        for e in entries:
            cmd = render.first_line(e.meta.get("command") or "")
            items.append(("%-32s %-7s %-12s %s" % (
                e.id, e.meta.get("kind", ""), e.summary(), cmd[:60]), e))
        self.push(ListView(self, "runs in %s" % self.book.shown(),
                           ["newest first"], items,
                           lambda e: self.open_entry(e, None)))

    def open_entry(self, e, name):
        t = e.load(name)
        self.views = [v for v in self.views if not isinstance(v, ListView)]
        self.push(TableView(self, t))

    # -- drawing --------------------------------------------------------------

    def screen(self, h, w):
        self.h, self.w = h, w
        top = self.views[-1]
        title = " %s view  %s" % (PROG, top.title)
        lines = [Line(fit(title, w), [(0, w, "title")])]
        strip = top.column_strip() if isinstance(top, TableView) else ""
        body_h = h - 2 - (1 if strip else 0)
        body = top.render(body_h, w)
        lines.extend(body)
        while len(lines) < 1 + body_h:
            lines.append(Line(" " * w))
        if strip:
            lines.append(Line(fit(" " + strip, w), [(0, w, "strip")]))
        if self.prompt is not None:
            text = " %s: %s" % (self.prompt.label, self.prompt.text)
            cur = len(" %s: " % self.prompt.label) + self.prompt.pos
            lines.append(Line(fit(text, w), [(0, w, "prompt")] + (
                [(cur, cur + 1, "cursor")] if cur < w else [])))
        else:
            msg = self.message or top.status()
            lines.append(Line(fit(" " + msg, w), [(0, w, "status")]))
        return lines


# ---------------------------------------------------------------------------
# Drivers: a script of keys, or a terminal
# ---------------------------------------------------------------------------

def run_scripted(app, script, size):
    try:
        w, h = [int(x) for x in size.lower().split("x")]
    except ValueError:
        die("QD_TEST_SCREEN wants WxH, like 100x30")
    app.screen(h, w)
    for k in test_tokens(script):
        app.key(k)
        if app.done:
            break
        app.screen(h, w)
    if app.done:
        return 0
    for ln in app.screen(h, w):
        sys.stdout.write(ln.text.rstrip() + "\n")
    return 0


def _key_name(curses, k):
    if isinstance(k, int):
        return {
            curses.KEY_UP: UP, curses.KEY_DOWN: DOWN, curses.KEY_LEFT: LEFT,
            curses.KEY_RIGHT: RIGHT, curses.KEY_PPAGE: PGUP,
            curses.KEY_NPAGE: PGDN, curses.KEY_HOME: HOME,
            curses.KEY_END: END, curses.KEY_ENTER: ENTER,
            curses.KEY_BACKSPACE: BS, curses.KEY_DC: DEL,
            curses.KEY_RESIZE: None,
        }.get(k)
    named = {"\n": ENTER, "\r": ENTER, "\x1b": ESC, "\x7f": BS, "\x08": BS,
             "\t": TAB, "\x15": KILL, "\x01": HOME, "\x05": END}
    if k in named:
        return named[k]
    return k if k >= " " else None


def _loop(stdscr, app):
    import curses
    try:
        curses.curs_set(0)
    except curses.error:
        pass
    styles = {"title": curses.A_REVERSE | curses.A_BOLD,
              "header": curses.A_BOLD | curses.A_UNDERLINE,
              "headcur": curses.A_REVERSE | curses.A_BOLD,
              "select": curses.A_BOLD, "cursor": curses.A_REVERSE,
              "dim": curses.A_DIM, "strip": curses.A_REVERSE,
              "status": curses.A_NORMAL, "prompt": curses.A_BOLD,
              "good": 0, "bad": curses.A_BOLD, "warn": 0}
    if curses.has_colors():
        try:
            curses.use_default_colors()
            curses.init_pair(1, curses.COLOR_GREEN, -1)
            curses.init_pair(2, curses.COLOR_RED, -1)
            curses.init_pair(3, curses.COLOR_YELLOW, -1)
            styles["good"] = curses.color_pair(1)
            styles["bad"] = curses.color_pair(2) | curses.A_BOLD
            styles["warn"] = curses.color_pair(3)
        except curses.error:
            pass
    while not app.done:
        h, w = stdscr.getmaxyx()
        stdscr.erase()
        for y, ln in enumerate(app.screen(h, w)[:h]):
            text = ln.text[:w - 1] if y == h - 1 else ln.text[:w]
            try:
                stdscr.addstr(y, 0, text)
                for a, b, style in ln.spans:
                    b = min(b, len(text))
                    if b > a:
                        stdscr.chgat(y, a, b - a, styles.get(style, 0))
            except curses.error:
                pass
        stdscr.refresh()
        try:
            k = stdscr.get_wch()
        except curses.error:
            continue
        except KeyboardInterrupt:
            break
        name = _key_name(curses, k)
        if name is not None:
            app.key(name)


def run(t, book, where=None, sort=None):
    app = App(t, book, where, sort)
    script = os.environ.get("QD_TEST_KEYS")
    if script is not None:
        return run_scripted(app, script,
                            os.environ.get("QD_TEST_SCREEN", "100x30"))
    if not (sys.stdin.isatty() and sys.stdout.isatty()):
        die("qd view needs a terminal; `qd show`, `qd stats` and the other "
            "verbs read the same data without one")
    try:
        import curses
    except ImportError:
        die("this Python has no curses, so qd view cannot draw; `qd show` "
            "and `qd stats` still work")
    os.environ.setdefault("ESCDELAY", "25")
    curses.wrapper(_loop, app)
    return 0
