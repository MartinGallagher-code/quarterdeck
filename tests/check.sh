#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Martin J. Gallagher

# check.sh -- run, before pushing, every check CI runs that can run here.
#
# Usage: check.sh [--quick]
#
#   --quick   leave out the two slow ones: the test suites and the wheel
#
# What it runs, in order: the version check, the Python 3.6 compile check,
# vermin, shellcheck, node --check on the page, reuse lint, a wheel build
# with twine check, and the whole suite on both of provost's paths (with
# `batch`, then QD_PROVOST_BATCH=0).  A check whose tool is not installed is
# skipped and said so, never failed; the summary at the end names every one.
# Exit status: 0 when nothing failed, 1 when something did, 2 on bad usage.
#
# Left to CI: the suite under a real Python 3.6, under each of 3.9-3.13,
# under PyPI's provost 2.1.0, and the installed wheel's smoke test.

set -u
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 2

PY="${PY:-python3}"
quick=0
case "${1:-}" in
    "") ;;
    --quick) quick=1 ;;
    -h|--help) sed -n '5,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "usage: check.sh [--quick]" >&2; exit 2 ;;
esac

summary=()
failed=0

# step NAME COMMAND...: run one check and record how it went
step() {
    local name=$1
    shift
    printf '== %s\n' "$name"
    if "$@"; then
        summary+=("pass  $name")
    else
        summary+=("FAIL  $name")
        failed=$((failed + 1))
    fi
    echo
}

# skip NAME WHY: record a check that could not run here
skip() {
    printf '== %s\nskipped: %s\n\n' "$1" "$2"
    summary+=("skip  $1 ($2)")
}

have() { command -v "$1" > /dev/null 2>&1; }

step "version in three places" bash tests/check_version.sh
step "Python 3.6 floor: compile" env PY="$PY" bash tests/check_python_compat.sh

if have vermin; then
    step "Python 3.6 floor: vermin" vermin --eval-annotations --violations --target=3.6- quarterdeck/*.py qd
else
    skip "Python 3.6 floor: vermin" "pip install vermin"
fi

if have shellcheck; then
    step "shellcheck" shellcheck -e SC1091 tests/*.sh tests/test_helper.bash
else
    skip "shellcheck" "install shellcheck, or pip install shellcheck-py"
fi

if have node; then
    step "web page syntax" node --check quarterdeck/web/app.js
else
    skip "web page syntax" "install node"
fi

if have reuse; then
    step "REUSE compliance" reuse lint
else
    skip "REUSE compliance" "pip install reuse"
fi

# build the wheel somewhere else, so the tree is left as it was found
build_wheel() {
    local out rc
    out=$(mktemp -d) || return 1
    "$PY" -m build --outdir "$out" . && "$PY" -m twine check "$out"/*
    rc=$?
    rm -rf "$out" build quarterdeck.egg-info
    return $rc
}

if [ "$quick" -eq 1 ]; then
    skip "wheel build" "--quick"
elif "$PY" -c 'import build, twine' 2> /dev/null; then
    step "wheel build" build_wheel
else
    skip "wheel build" "pip install build twine"
fi

provost="${QD_PROVOST:-$(command -v provost 2> /dev/null || true)}"
if [ "$quick" -eq 1 ]; then
    skip "test suite" "--quick"
elif [ -z "$provost" ]; then
    skip "test suite" "pip install provost, or point QD_PROVOST at one"
else
    # shellcheck disable=SC2086  # QD_PROVOST may be a command line
    if $provost batch --help > /dev/null 2>&1; then
        step "test suite (provost batch)" bash tests/run_tests.sh
        step "test suite (one capture at a time)" env QD_PROVOST_BATCH=0 bash tests/run_tests.sh
    else
        step "test suite (one capture at a time)" bash tests/run_tests.sh
        skip "test suite (provost batch)" "this provost has no batch"
    fi
fi

echo "== summary"
printf '%s\n' "${summary[@]}"
if [ "$failed" -gt 0 ]; then
    echo "$failed check(s) failed"
    exit 1
fi
echo "nothing failed"
