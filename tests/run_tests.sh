#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Martin J. Gallagher

# run_tests.sh -- run every test_*.sh in this directory, several at once.
#
# Usage: run_tests.sh [-j N] [NAME...]     e.g. run_tests.sh run diff
#        QD_TEST_ONLY=TEXT run_tests.sh store   only cases whose name has TEXT
#
#   -j N   run N suites at a time (QD_TEST_JOBS=N does the same); the
#          default is this machine's core count.  Each suite's output is
#          kept until that suite ends and then printed whole, in name
#          order, so two suites never interleave.  -j 1 is the serial run,
#          each suite's output as it comes, and so is naming one suite.
#
# Exit status: 0 when every suite passed, 1 when one failed, 2 on bad usage
# or with no provost.
#
# No network and no second machine: ssh and scp are replaced by a shim that
# runs the "remote" command locally in a sandbox per fake host, and the
# toolchain (mx, iperf-orchestrator, agree) by small stand-ins that write
# what the real ones write.  The web suite talks to its own server on
# loopback.  Every case has a temp dir, a store and a web port range of its
# suite's own, which is why suites can run side by side.

set -u
cd "$(dirname "${BASH_SOURCE[0]}")" || exit 2

usage() { sed -n '5,17p' run_tests.sh | sed 's/^# \{0,1\}//'; }

# The slowest suites start first, so the longest of them is not left to
# begin last (seconds, one at a time, in CI's provost 2.1.0 job: doe 203,
# xstore 130, web 121, run 116, compare 113, probe 107).  This sets only
# the order they start in; the output is in name order whatever it says.
SLOW="doe xstore web run compare probe"

# This machine's cores: Linux, then POSIX, then macOS and the BSDs.
cores() {
    local n
    n=$(nproc 2> /dev/null) || n=$(getconf _NPROCESSORS_ONLN 2> /dev/null) ||
        n=$(sysctl -n hw.ncpu 2> /dev/null) || n=1
    case "$n" in "" | *[!0-9]* | 0) n=1 ;; esac
    echo "$n"
}

njobs="${QD_TEST_JOBS:-}"
while [ $# -gt 0 ]; do
    case "$1" in
        -h | --help) usage; exit 0 ;;
        -j) [ $# -ge 2 ] || { echo "-j wants a number of suites" >&2; exit 2; }
            njobs="$2"; shift 2 ;;
        -j*) njobs="${1#-j}"; shift ;;
        --) shift; break ;;
        -*) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
        *) break ;;
    esac
done
[ -n "$njobs" ] || njobs=$(cores)
case "$njobs" in
    *[!0-9]* | 0*)
        echo "-j wants a whole number of suites, 1 or more: $njobs" >&2
        exit 2 ;;
esac

QD_DIR="$(cd .. && pwd)"
export QD_DIR
export PY="${PY:-python3}"

# qd files everything through provost: the suites need a real one
QD_PROVOST="${QD_PROVOST:-$(command -v provost 2>/dev/null || true)}"
export QD_PROVOST
if [ -z "$QD_PROVOST" ]; then
    echo "no provost: pip install provost, or point QD_PROVOST at one" >&2
    exit 2
fi
# shellcheck disable=SC2086  # QD_PROVOST may be a command line
if [ "${QD_PROVOST_BATCH:-1}" != 0 ] && $QD_PROVOST batch --help > /dev/null 2>&1; then
    echo "provost: $QD_PROVOST (batch: a run is one commit)"
else
    echo "provost: $QD_PROVOST (one capture at a time)"
fi

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
n=${#files[@]}
[ "$njobs" -le "$n" ] || njobs=$n

# -- one at a time: each suite's output as it comes --------------------------

if [ "$njobs" -le 1 ]; then
    echo
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
    exit 0
fi

# -- several at a time -------------------------------------------------------
#
# Bash 3.2 (macOS) has no `wait -n`, so this is a loop over slots: a suite
# runs in a subshell that writes its exit status and seconds to N.rc when it
# ends, and the loop starts another whenever one of those turns up.

echo "suites: $n, $njobs at a time"
echo

tmp="${TMPDIR:-/tmp}"
out=$(mktemp -d "${tmp%/}/qd-suites.XXXXXX") || exit 2
trap 'rm -rf "$out"' EXIT

# Index i is a suite's place in files, which is the order its output is
# printed in.  state: 0 waiting, 1 running, 2 ended.
order=()
pid=()
state=()
secs=()
for slow in $SLOW; do
    for i in "${!files[@]}"; do
        [ "${files[$i]}" = "test_$slow.sh" ] && order+=("$i")
    done
done
for i in "${!files[@]}"; do
    state[i]=0
    name="${files[$i]#test_}"
    case " $SLOW " in
        *" ${name%.sh} "*) ;;
        *) order+=("$i") ;;
    esac
done

start_suite() {
    local i=$1
    (
        SECONDS=0
        bash "${files[$i]}" < /dev/null > "$out/$i.out" 2>&1
        echo "$? $SECONDS" > "$out/$i.rc.part"
        mv "$out/$i.rc.part" "$out/$i.rc"
    ) &
    pid[i]=$!
    state[i]=1
}

# A suite's subshell, the suite, its case and whatever that case started
# (a web server among them): every process under PID, found with ps.
tree() {
    local p kids
    echo "$1"
    kids=$(ps -A -o pid= -o ppid= 2> /dev/null | awk -v p="$1" '$2 == p { print $1 }')
    for p in $kids; do tree "$p"; done
}

# Interrupted: stop every suite still running, whole, so nothing is left
# behind -- each case's own trap still removes its temp dir.
stop() {
    trap '' INT TERM
    local i
    for i in "${!files[@]}"; do
        [ "${state[$i]}" = 1 ] || continue
        # shellcheck disable=SC2046  # one pid per word
        kill -TERM $(tree "${pid[$i]}") 2> /dev/null
    done
    wait
    echo "interrupted" >&2
    exit "$1"
}
trap 'stop 130' INT
trap 'stop 143' TERM

next=0
running=0
printed=0
total_failed=0
SECONDS=0
while [ "$printed" -lt "$n" ]; do
    while [ "$running" -lt "$njobs" ] && [ "$next" -lt "$n" ]; do
        start_suite "${order[$next]}"
        next=$((next + 1))
        running=$((running + 1))
    done
    moved=0
    for i in "${!files[@]}"; do
        [ "${state[$i]}" = 1 ] || continue
        if [ ! -f "$out/$i.rc" ]; then
            # still running -- unless it went without saying how it ended
            kill -0 "${pid[$i]}" 2> /dev/null && continue
            if [ ! -f "$out/$i.rc" ]; then
                echo "  the suite ended without saying how" >> "$out/$i.out"
                echo "1 0" > "$out/$i.rc"
            fi
        fi
        read -r r s < "$out/$i.rc"
        wait "${pid[$i]}" 2> /dev/null
        secs[i]=$s
        state[i]=2
        running=$((running - 1))
        [ "$r" = 0 ] || total_failed=$((total_failed + 1))
        moved=1
    done
    # every suite whose turn it is, in name order
    while [ "$printed" -lt "$n" ] && [ "${state[$printed]}" = 2 ]; do
        name="${files[$printed]#test_}"
        echo "${name%.sh}"
        cat "$out/$printed.out"
        echo
        printed=$((printed + 1))
        moved=1
    done
    [ "$moved" = 1 ] || sleep 0.2
done

longest=$(for i in "${!files[@]}"; do
    name="${files[$i]#test_}"
    echo "${secs[$i]} ${name%.sh}"
done | sort -rn | head -n 3 | awk '{ printf "%s%s %d s", (NR > 1 ? ", " : ""), $2, $1 }')
echo "time: $SECONDS s for $n suites, $njobs at a time (longest: $longest)"

if [ "$total_failed" -gt 0 ]; then
    echo "$total_failed suite(s) failed"
    exit 1
fi
echo "all suites passed"
