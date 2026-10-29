# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Martin J. Gallagher
"""Text for people: aligned tables, bars and sparklines.

Rendering is kept apart from the data on purpose -- every verb that draws
something can also write it as CSV or JSON instead -- and is deterministic,
so two runs over the same dataset print byte-identical reports that can
be diffed.  When stdout is not a terminal nothing is cut to fit one.
"""

import os
import shutil
import sys

from .common import ascii_only

BLOCKS = u"▁▂▃▄▅▆▇█"
ASCII_SPARK = " .:-=+*#%@"
EIGHTHS = u" ▏▎▍▌▋▊▉█"


def terminal_width(override=None):
    if override:
        return override
    if not sys.stdout.isatty():
        return None
    return shutil.get_terminal_size((100, 24)).columns


def first_line(cell, ascii=None):
    """A multi-line cell as its first line, with how much it hides."""
    if "\n" not in cell:
        return cell
    lines = cell.split("\n")
    mark = " [+%d lines]" if (ascii if ascii is not None
                              else ascii_only()) else u" ⏎+%d"
    return lines[0] + mark % (len(lines) - 1)


def clip(text, width, ascii=None):
    if width is None or len(text) <= width:
        return text
    if width <= 1:
        return text[:width]
    tail = "~" if (ascii if ascii is not None else ascii_only()) else u"…"
    return text[:width - 1] + tail


def render_rows(columns, rows, numeric=None, max_cell=40, width=None,
                ascii=None, indent=""):
    """Lines of an aligned table.  numeric: column indexes to right-align."""
    numeric = set(numeric or ())
    shown = [[first_line(c, ascii) for c in r] for r in rows]
    widths = []
    for i, c in enumerate(columns):
        w = max([len(c)] + [len(r[i]) for r in shown]) if shown else len(c)
        widths.append(min(w, max_cell) if max_cell else w)
    hidden = []
    if width:
        total, keep = len(indent), 0
        for i, w in enumerate(widths):
            if keep and total + w + 2 > width:
                break
            total += w + 2
            keep = i + 1
        hidden = columns[keep:]
        columns, widths = columns[:keep], widths[:keep]
        shown = [r[:keep] for r in shown]

    def fmt(cells, head=False):
        parts = []
        for i, (c, w) in enumerate(zip(cells, widths)):
            c = clip(c, w, ascii)
            if i in numeric and not head:
                parts.append(c.rjust(w))
            else:
                parts.append(c.ljust(w))
        return (indent + "  ".join(parts)).rstrip()

    out = [fmt(columns, True)]
    for r in shown:
        out.append(fmt(r))
    if hidden:
        out.append("%s(+%d column%s not shown: %s -- use --cols or --width)"
                   % (indent, len(hidden), "" if len(hidden) == 1 else "s",
                      ", ".join(hidden[:8]) + (" ..." if len(hidden) > 8
                                               else "")))
    return out


def render_table(table, rows=None, max_cell=40, width=None, ascii=None,
                 indent=""):
    rows = table.rows if rows is None else rows
    num = [i for i, c in enumerate(table.columns)
           if table.kind(c) in ("num",)]
    return render_rows(table.columns, rows, num, max_cell, width, ascii,
                       indent)


def bar(n, top, width, ascii=None):
    if top <= 0 or n <= 0:
        return ""
    ascii = ascii if ascii is not None else ascii_only()
    full = n * width / float(top)
    if ascii:
        return "#" * max(1, int(round(full)))
    whole = int(full)
    part = int(round((full - whole) * 8))
    if part == 8:
        whole, part = whole + 1, 0
    s = EIGHTHS[8] * whole + (EIGHTHS[part] if part else "")
    return s or EIGHTHS[1]


def sparkline(series, lo=None, hi=None, ascii=None):
    ascii = ascii if ascii is not None else ascii_only()
    vals = [v for v in series if v is not None]
    if not vals:
        return " " * len(series)
    lo = min(vals) if lo is None else lo
    hi = max(vals) if hi is None else hi
    chars = ASCII_SPARK[1:] if ascii else BLOCKS
    out = []
    for v in series:
        if v is None:
            out.append(" ")
        elif hi == lo:
            out.append(chars[len(chars) // 2])
        else:
            k = int((v - lo) / (hi - lo) * (len(chars) - 1) + 0.5)
            out.append(chars[max(0, min(len(chars) - 1, k))])
    return "".join(out)


def page(lines):
    """Join report lines; one newline at the end, never trailing spaces."""
    return "\n".join(ln.rstrip() for ln in lines) + "\n"


def isatty():
    try:
        return os.isatty(sys.stdout.fileno())
    except (AttributeError, ValueError, OSError):
        return False
