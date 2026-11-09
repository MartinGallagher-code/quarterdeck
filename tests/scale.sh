#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Martin J. Gallagher
#
# scale.sh -- how qd's fan-out holds up at thousands of hosts (QD-019).
# Not one of the suites (it is not test_*.sh, so run_tests.sh skips it):
# it takes minutes and measures rather than asserts.
#
#   bash tests/scale.sh [N ...]          default: 1000 5000
#   SCALE_SLEEP=0.05 SCALE_JOBS=32 SCALE_VERB=run|probe bash tests/scale.sh 1000
#
# Each host is the suites' fake ssh (a local bash in a directory of its
# own) holding on SCALE_SLEEP seconds, so the fan-out, not the command, is
# what is timed.  For each N it prints the wall time of the whole run, and
# of the same run with --no-store (so filing is the difference), and the
# peak resident memory, threads and open file descriptors of qd itself,
# sampled from /proc every 0.1 s.  Linux only (it reads /proc).

set -u
source "$(dirname "${BASH_SOURCE[0]}")/test_helper.bash"

SLEEP="${SCALE_SLEEP:-0.05}"
JOBS="${SCALE_JOBS:-32}"
VERB="${SCALE_VERB:-run}"

# qd in the background, its peaks sampled while it runs: "wall rss_kb
# threads fds rc"
measure() {
    local t0 t1 pid rss=0 thr=0 fds=0 r t f rc
    t0="$("$PY" -c 'import time; print(time.time())')"
    "$PY" "$QD_DIR/qd" "$@" > "$TEST_TMPDIR/out" 2>&1 &
    pid=$!
    while kill -0 "$pid" 2> /dev/null; do
        r="$(awk '/VmHWM/ {print $2}' "/proc/$pid/status" 2> /dev/null || true)"
        t="$(awk '/Threads/ {print $2}' "/proc/$pid/status" 2> /dev/null || true)"
        f="$(find "/proc/$pid/fd" -mindepth 1 -maxdepth 1 2> /dev/null | wc -l)"
        [ -n "$r" ] && [ "$r" -gt "$rss" ] && rss="$r"
        [ -n "$t" ] && [ "$t" -gt "$thr" ] && thr="$t"
        [ "$f" -gt "$fds" ] && fds="$f"
        sleep 0.1
    done
    wait "$pid"
    rc=$?
    t1="$("$PY" -c 'import time; print(time.time())')"
    "$PY" -c 'import sys; print("%.1f" % (float(sys.argv[2]) - float(sys.argv[1])))' "$t0" "$t1" | tr -d '\n'
    echo " $rss $thr $fds $rc"
}

one() {
    local n="$1" i
    setup_env
    cd "$TEST_TMPDIR" || exit 2
    install_fake_ssh
    : > hosts.txt
    for i in $(seq 1 "$n"); do
        mkdir -p "$FAKE_ROOT/h$i"
        printf 'v: %d\n' "$i" > "$FAKE_ROOT/h$i/v"
        echo "h$i rack=r$((i % 40))" >> hosts.txt
    done
    local cmd=(-- bash -c "sleep $SLEEP; cat v")
    [ "$VERB" = probe ] && cmd=(os)
    local bare filed
    bare="$(measure "$VERB" --ssh "$FAKE_BIN/ssh" --scp "$FAKE_BIN/scp" \
        -s hosts.txt -q -j "$JOBS" --no-store "${cmd[@]}")"
    filed="$(measure "$VERB" --ssh "$FAKE_BIN/ssh" --scp "$FAKE_BIN/scp" \
        -s hosts.txt -q -j "$JOBS" "${cmd[@]}")"
    printf '%-6s %-5s %-5s  no-store: %-24s  filed: %s\n' "$n" "$VERB" "$JOBS" "$bare" "$filed"
    tail -n 3 "$TEST_TMPDIR/out" | sed 's/^/        /'
    cd "$QD_DIR" && teardown_env
}

echo "hosts  verb  jobs   (wall s, peak RSS kB, threads, fds, exit)"
for n in "${@:-1000 5000}"; do
    # shellcheck disable=SC2086
    for m in $n; do one "$m"; done
done
