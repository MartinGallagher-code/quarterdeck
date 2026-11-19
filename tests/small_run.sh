#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Martin J. Gallagher
#
# small_run.sh -- how long a one-host `qd run -- ls` takes, and how many
# processes it starts (QD-056).  Not one of the suites (it is not
# test_*.sh, so run_tests.sh skips it): it measures and never asserts, so
# a slow machine cannot fail it.  CI runs it as a report.
#
#   bash tests/small_run.sh              5 runs of each
#   SMALL_RUNS=9 bash tests/small_run.sh
#
# The host is the suites' fake ssh (a local bash in a directory of four
# entries), so no ssh time is counted.  It prints, for `qd run --no-store`,
# the first `qd run` into a new store, and the runs after it (the store
# already has the run's datasets): the median wall time of SMALL_RUNS runs,
# and, where strace is installed, the processes and the awk processes one
# run starts.  The difference between --no-store and a filed run is
# provost's filing.  Exit status 0 unless qd itself failed.

set -u
source "$(dirname "${BASH_SOURCE[0]}")/test_helper.bash"

RUNS="${SMALL_RUNS:-5}"
[[ "$RUNS" =~ ^[1-9][0-9]*$ ]] || RUNS=5

if [ -z "$PROVOST_CMD" ]; then
    echo "small_run: no provost (set QD_PROVOST or put provost on PATH); nothing measured."
    exit 0
fi

now() { "$PY" -c 'import time; print("%.4f" % time.time())'; }

# median of the numbers on stdin, to 2 places
median() {
    sort -n | awk '{ v[NR] = $1 } END {
        if (NR == 0) { print "-"; exit }
        m = (NR % 2) ? v[(NR + 1) / 2] : (v[NR / 2] + v[NR / 2 + 1]) / 2
        printf "%.2f\n", m }'
}

# one qd run: its wall seconds on stdout; status qd's
one_run() {
    local t0 t1 rc
    t0="$(now)"
    "$PY" "$QD_DIR/qd" run --ssh "$FAKE_BIN/ssh" --scp "$FAKE_BIN/scp" \
        -S h1 -q "$@" -- ls > "$TEST_TMPDIR/out" 2>&1
    rc=$?
    t1="$(now)"
    awk -v a="$t0" -v b="$t1" 'BEGIN { printf "%.3f\n", b - a }'
    return "$rc"
}

# processes and awk processes one run starts: "N A", or "- -" without strace
count_run() {
    local tr="$TEST_TMPDIR/strace.out" n a
    if ! command -v strace > /dev/null 2>&1; then echo "- -"; return 0; fi
    rm -f "$tr"
    strace -f -qq -e trace=execve -e signal=none -o "$tr" \
        "$PY" "$QD_DIR/qd" run --ssh "$FAKE_BIN/ssh" --scp "$FAKE_BIN/scp" \
        -S h1 -q "$@" -- ls > "$TEST_TMPDIR/out" 2>&1 || true
    if [ ! -s "$tr" ]; then echo "- -"; return 0; fi
    # each successful execve is one program started
    n="$(grep -c 'execve(.*= 0$' "$tr" || true)"
    a="$(grep 'execve(.*= 0$' "$tr" | grep -c 'execve("[^"]*/[gmn]\{0,1\}awk"' || true)"
    echo "${n:-0} ${a:-0}"
}

setup_env
install_fake_ssh
mkdir -p "$FAKE_ROOT/h1"
for f in alpha bravo charlie delta; do : > "$FAKE_ROOT/h1/$f"; done

# shellcheck disable=SC2086  # QD_PROVOST may be a command line
ver="$($PROVOST_CMD --version 2>/dev/null | head -n 1)"
echo "small_run: one host, 'qd run -- ls', median of $RUNS runs"
echo "provost: ${ver:-unknown} ($PROVOST_CMD)$( [ "${QD_PROVOST_BATCH:-}" = 0 ] && echo ', one capture at a time')"
printf '%-22s %8s %10s %6s\n' "run" "wall s" "processes" "awk"

failed=0
report() {
    local label="$1"; shift
    local times="$TEST_TMPDIR/times" i t
    : > "$times"
    for (( i = 0; i < RUNS; i++ )); do
        t="$(one_run "$@")" || failed=1
        echo "$t" >> "$times"
    done
    row "$label" "$(median < "$times")" "$@"
}

# a table row: LABEL MEDIAN [QD ARGS...], with one more run counted
row() {
    local label="$1" med="$2" n a
    shift 2
    read -r n a <<< "$(count_run "$@")"
    printf '%-22s %8s %10s %6s\n' "$label" "$med" "$n" "$a"
}

report "--no-store" --no-store
# the first filed run into a new store: no dataset of the run's is there yet
first="$TEST_TMPDIR/first"; : > "$first"
for (( i = 0; i < RUNS; i++ )); do
    export QD_STORE="$TEST_TMPDIR/store.$i"
    t="$(one_run)" || failed=1
    echo "$t" >> "$first"
done
export QD_STORE="$TEST_TMPDIR/store.c"
row "filed, new store" "$(median < "$first")"
export QD_STORE="$TEST_TMPDIR/store"
one_run > /dev/null || failed=1
report "filed, store has it"

if (( failed )); then
    echo "small_run: qd failed; its last output:"
    sed 's/^/    /' "$TEST_TMPDIR/out"
fi
cd "$QD_DIR" && teardown_env
exit "$failed"
