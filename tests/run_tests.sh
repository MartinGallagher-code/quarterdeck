#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Martin J. Gallagher

# run_tests.sh -- run every test_*.sh in this directory.
#
# Usage: run_tests.sh [NAME...]     e.g. run_tests.sh run diff
#
# No network and no second machine: ssh and scp are replaced by a shim that
# runs the "remote" command locally in a sandbox per fake host, and the
# toolchain (mx, iperf-orchestrator, agree) by small stand-ins that write
# what the real ones write.  The web suite talks to its own server on
# loopback.

set -u
cd "$(dirname "${BASH_SOURCE[0]}")" || exit 2

QD_DIR="$(cd .. && pwd)"
export QD_DIR
export PY="${PY:-python3}"

if [ $# -gt 0 ]; then
    files=()
    for name in "$@"; do
        f="test_${name#test_}"
        f="${f%.sh}.sh"
        [ -f "$f" ] || { echo "no such suite: $f" >&2; exit 2; }
        files+=("$f")
    done
else
    files=(test_*.sh)
fi

total_failed=0
for f in "${files[@]}"; do
    name="${f#test_}"
    echo "${name%.sh}"
    bash "$f" || total_failed=$((total_failed + 1))
    echo
done

if [ "$total_failed" -gt 0 ]; then
    echo "$total_failed suite(s) failed"
    exit 1
fi
echo "all suites passed"
