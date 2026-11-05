#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Martin J. Gallagher

# check_version.sh -- the version is said in three places, and they agree.
#
# Every change moves the version (CLAUDE.md): quarterdeck/__init__.py,
# pyproject.toml, and a "## X.Y.Z — YYYY-MM-DD" section at the top of
# CHANGELOG.md, all in the same pull request.  This fails when any of the
# three is missing or disagrees with the others.

set -eu
cd "$(dirname "${BASH_SOURCE[0]}")/.."

init=$(sed -n 's/^VERSION = "\(.*\)"$/\1/p' quarterdeck/__init__.py | head -n 1)
proj=$(sed -n 's/^version = "\(.*\)"$/\1/p' pyproject.toml | head -n 1)
head=$(grep -m 1 '^## ' CHANGELOG.md || true)
log=$(printf '%s\n' "$head" | sed -n 's/^## \([^ ]*\) — [0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\}$/\1/p')

fail=0
[ -n "$init" ] || { echo 'FAIL  quarterdeck/__init__.py: no VERSION = "X.Y.Z" line'; fail=1; }
[ -n "$proj" ] || { echo 'FAIL  pyproject.toml: no version = "X.Y.Z" line'; fail=1; }
[ -n "$log" ] || { printf 'FAIL  CHANGELOG.md: the first section is not "## X.Y.Z — YYYY-MM-DD": %s\n' "${head:-(none)}"; fail=1; }

if [ "$fail" -eq 0 ] && { [ "$init" != "$proj" ] || [ "$init" != "$log" ]; }; then
    echo "FAIL  the version disagrees:"
    echo "        quarterdeck/__init__.py  $init"
    echo "        pyproject.toml           $proj"
    echo "        CHANGELOG.md (top)       $log"
    fail=1
fi

[ "$fail" -eq 0 ] || exit 1
echo "version $init in all three places"
