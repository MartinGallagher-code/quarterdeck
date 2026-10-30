#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Martin J. Gallagher

# check_python_compat.sh -- hold the Python 3.6 floor.
#
# quarterdeck runs on the machine the fleet is driven from, which is as
# often a RHEL 8 jump host (3.6) as anything newer.  This only compiles;
# CI additionally runs vermin for stdlib APIs newer than the floor, which
# a syntax check cannot see.

set -eu
cd "$(dirname "${BASH_SOURCE[0]}")/.."

PY="${PY:-python3}"
fail=0

for f in quarterdeck/*.py qd; do
    if ! "$PY" -m py_compile "$f" 2>/dev/null; then
        printf 'FAIL  %s does not compile under %s\n' "$f" "$("$PY" -V 2>&1)"
        "$PY" -m py_compile "$f" || true
        fail=1
    fi
done

find . -name '__pycache__' -prune -exec rm -rf {} + 2>/dev/null || true

if [ "$fail" -ne 0 ]; then
    exit 1
fi
printf 'all modules compile under %s\n' "$("$PY" -V 2>&1)"
