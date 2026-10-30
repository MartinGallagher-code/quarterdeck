# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Martin J. Gallagher
"""Helpers every module here leans on: errors, codecs, environment."""

import io
import os
import sys

from . import VERSION

PROG = "qd"

VERSION_TEXT = """%s %s
Copyright (C) 2026 Martin J. Gallagher
License: GPL-3.0-or-later <https://www.gnu.org/licenses/gpl-3.0.html>
This is free software: you are free to change and redistribute it.
There is no warranty, to the extent permitted by law.""" % (PROG, VERSION)

DOCS = "https://github.com/MartinGallagher-code/quarterdeck#readme"


class QdError(Exception):
    """A refusal with a reason, and the exit status that goes with it.

    Raised rather than exiting on the spot so the explorer can show the
    message on its status line and carry on, where a command line exits.
    """

    def __init__(self, msg, code=2):
        Exception.__init__(self, msg)
        self.code = code


def die(msg, code=2):
    raise QdError(msg, code)


def warn(msg):
    sys.stderr.write("%s: %s\n" % (PROG, msg))


# canonical copy: binnacle/why_slow.py _stdio_safe().  The same bargain:
# a report is worth more than the byte a C locale cannot spell.
def _stdio_safe():
    """Never lose a report to a character the locale cannot spell.

    Data read back from a fleet carries whatever the far side printed, and
    a box with LANG=C has an ASCII stdout.  One UTF-8 hostname in a table
    would otherwise end the whole report in a UnicodeEncodeError.
    """
    for name in ("stdout", "stderr"):
        stream = getattr(sys, name, None)
        if stream is None or not hasattr(stream, "buffer"):
            continue
        enc = (getattr(stream, "encoding", None) or "").lower()
        if enc.replace("-", "_") in ("ascii", "ansi_x3.4_1968", "us_ascii"):
            setattr(sys, name, io.TextIOWrapper(
                stream.buffer, encoding=stream.encoding,
                errors="backslashreplace", line_buffering=True))


def read_text(path):
    """A file as text: utf-8-sig, an undecodable byte costs one character.

    A BOM from Notepad or Excel is decoded away rather than glued to the
    first column name, which would otherwise make `host` unfindable.
    """
    if path == "-":
        return sys.stdin.read().lstrip("﻿")
    try:
        with io.open(path, encoding="utf-8-sig", errors="replace") as fh:
            return fh.read()
    except OSError as exc:
        die("cannot read %s: %s" % (path, exc.strerror or exc))


def write_text(path, text):
    """Plain UTF-8 out, and a full disk named rather than a traceback."""
    if path == "-":
        sys.stdout.write(text)
        return
    try:
        d = os.path.dirname(path)
        if d and not os.path.isdir(d):
            os.makedirs(d)
        with io.open(path, "w", encoding="utf-8", newline="") as fh:
            fh.write(text)
    except OSError as exc:
        die("cannot write %s: %s" % (path, exc.strerror or exc))


def env(name, default=None):
    """QD_<NAME>, or the default: every knob has a variable as well."""
    v = os.environ.get("QD_" + name)
    return default if v is None or v == "" else v


def env_int(name, default):
    v = env(name)
    if v is None:
        return default
    try:
        return int(v)
    except ValueError:
        die("QD_%s=%r is not a whole number" % (name, v))


def env_float(name, default):
    v = env(name)
    if v is None:
        return default
    try:
        return float(v)
    except ValueError:
        die("QD_%s=%r is not a number" % (name, v))


def ascii_only():
    """Draw bars and sparklines in ASCII when the terminal cannot spell
    the block characters, or when asked (QD_ASCII=1)."""
    if env("ASCII") not in (None, "0"):
        return True
    enc = (getattr(sys.stdout, "encoding", None) or "").lower()
    return "utf" not in enc


def plural(n, word, many=None):
    return "%d %s" % (n, word if n == 1 else (many or word + "s"))
