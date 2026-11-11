#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Martin J. Gallagher

# run_tests.sh -- run every test_*.sh in this directory, several at once.
#
# Usage: run_tests.sh [-j N] [--shard K/N] [NAME...]   e.g. run_tests.sh run diff
#        run_tests.sh --list [--shard K/N] [NAME...]
#        QD_TEST_ONLY=TEXT run_tests.sh store   only cases whose name has TEXT
#
#   -j N         run N suites at a time (QD_TEST_JOBS=N does the same); the
#                default is this machine's core count.  Each suite's output
#                is kept until that suite ends and then printed whole, in
#                name order, so two suites never interleave.  -j 1 is the
#                serial run, each suite's output as it comes, and so is
#                naming one suite.
#   --shard K/N  run share K of N of the suites, as CI does on N runners.
#                The suites are dealt by their seconds in TIMES below, the
#                longest first, each to the share with the fewest seconds so
#                far: every machine deals the same suites to the same share,
#                each suite to exactly one (tests/check_shards.sh checks).
#   --list       print the suites that would run, one a line; run none.
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

usage() { sed -n '5,25p' run_tests.sh | sed 's/^# \{0,1\}//'; }

# Each suite's seconds, measured: they set the order the suites start in,
# the longest first, so the longest is not left to begin last, and how
# --shard deals them out.  A suite not listed counts as UNLISTED seconds
# until it is (tests/test_runner.sh fails until it is).  The output is in
# name order whatever this says.  Measured in CI on 2026-11-10 (run #101,
# QD-024): each suite's seconds in each of the seven jobs that run the
# suite, four at a time on four cores, parts added up, then the mean of
# the seven; report and join, which came after, timed here beside
# compare, do and view on both of provost's paths and scaled to their
# seconds in CI; ssh (QD-018) timed here, a real sshd and all, on four
# cores; via (QD-008) beside report, scaled the same way.  A run's last
# line, `seconds:`, gives every suite's, to measure them again from.
TIMES="doe:236 peers:231 web:225 via:224 run:176 xstore:146 compare:132 probe:108 operator:98 report:87 campaign:86 rm:81 do:78 remote:77 view:74 pacing:54 store:41 stop:40 policy:37 read:35 join:30 ssh:25 export:24 runner:18 split:15 diff:14 check:12 analyze:6 cleanup:3"
UNLISTED=30

# With --shard K/N, a suite listed here is split into that many parts (or
# N, if fewer), each a share of its cases (QD_TEST_PART=I/P: the Ith case,
# then every Pth), each part dealt to a different share: no suite outlasts
# the rest of its share's.  A suite whose cases start a server can be split
# too, since its parts never run on one machine.  Without --shard, every
# suite runs whole.
PARTS="doe:3 peers:3 web:3 via:3 run:2 xstore:2 compare:2 probe:2"

# This machine's cores: Linux, then POSIX, then macOS and the BSDs.
cores() {
    local n
    n=$(nproc 2> /dev/null) || n=$(getconf _NPROCESSORS_ONLN 2> /dev/null) ||
        n=$(sysctl -n hw.ncpu 2> /dev/null) || n=1
    case "$n" in "" | *[!0-9]* | 0) n=1 ;; esac
    echo "$n"
}

njobs="${QD_TEST_JOBS:-}"
shard=""
sharded=0
list=0
while [ $# -gt 0 ]; do
    case "$1" in
        -h | --help) usage; exit 0 ;;
        -j) [ $# -ge 2 ] || { echo "-j wants a number of suites" >&2; exit 2; }
            njobs="$2"; shift 2 ;;
        -j*) njobs="${1#-j}"; shift ;;
        --shard) [ $# -ge 2 ] || { echo "--shard wants K/N, as in 2/3" >&2; exit 2; }
            shard="$2"; sharded=1; shift 2 ;;
        --shard=*) shard="${1#--shard=}"; sharded=1; shift ;;
        --list) list=1; shift ;;
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
# K/N: whole numbers, 1 <= K <= N, at most four digits each
if [ "$sharded" = 1 ]; then
    k="${shard%%/*}"
    nshards="${shard#*/}"
    case "$k/$nshards" in
        "$shard") ;;
        *) k="" ;;
    esac
    case "$k" in "" | *[!0-9]* | 0* | ?????*) k="" ;; esac
    case "$nshards" in "" | *[!0-9]* | 0* | ?????*) k="" ;; esac
    if [ -z "$k" ] || [ "$k" -gt "$nshards" ]; then
        echo "--shard wants K/N, whole numbers with 1 <= K <= N: $shard" >&2
        exit 2
    fi
fi

if [ $# -gt 0 ]; then
    suites=()
    for name in "$@"; do
        f="test_${name#test_}"
        f="${f%.sh}.sh"
        [ -f "$f" ] || { echo "no such suite: $f" >&2; exit 2; }
        suites+=("$f")
    done
else
    suites=(test_*.sh)
fi

# lookup TABLE NAME DEFAULT: NAME's number in a "name:number ..." table
lookup() {
    local t
    for t in $1; do
        [ "${t%%:*}" = "$2" ] && { echo "${t#*:}"; return; }
    done
    echo "$3"
}

# What runs: a unit is a whole suite, or with --shard a part of one.
#   files[i]  the suite's file        part[i]  I/P, or empty for the whole
#   label[i]  what the log calls it   wt[i]    its seconds, from TIMES
files=()
part=()
label=()
wt=()
for f in "${suites[@]}"; do
    name="${f#test_}"
    name="${name%.sh}"
    sec=$(lookup "$TIMES" "$name" "$UNLISTED")
    p=1
    if [ "$sharded" = 1 ]; then
        p=$(lookup "$PARTS" "$name" 1)
        [ "$p" -le "$nshards" ] || p=$nshards
    fi
    if [ "$p" -le 1 ]; then
        files+=("$f"); part+=(""); label+=("$name"); wt+=("$sec")
        continue
    fi
    j=1
    while [ "$j" -le "$p" ]; do
        files+=("$f"); part+=("$j/$p"); label+=("$name:$j/$p")
        wt+=($(((sec + p - 1) / p)))
        j=$((j + 1))
    done
done

# The indices of the units, the longest first, then by label: the same
# order on every machine, whatever order the shell globbed them in.
by_time() {
    local i
    for i in "${!files[@]}"; do
        echo "${wt[$i]} ${label[$i]} $i"
    done | LC_ALL=C sort -k1,1nr -k2,2 | awk '{ print $3 }'
}

# --shard K/N: deal every unit, the longest first, to the share with the
# fewest seconds so far (the first such share on a tie) that holds no
# other part of its suite, and keep share K.
if [ "$sharded" = 1 ]; then
    load=()
    held=()
    keep=()
    g=0
    while [ "$g" -lt "$nshards" ]; do load[g]=0; held[g]=" "; g=$((g + 1)); done
    for i in $(by_time); do
        best=-1
        g=0
        while [ "$g" -lt "$nshards" ]; do
            case "${held[g]}" in
                *" ${files[$i]} "*) ;;
                *) if [ "$best" -lt 0 ] || [ "${load[g]}" -lt "${load[best]}" ]; then
                       best=$g
                   fi ;;
            esac
            g=$((g + 1))
        done
        # a suite named twice, in more copies than there are shares: the
        # lightest share, whatever it holds
        if [ "$best" -lt 0 ]; then
            best=0
            g=1
            while [ "$g" -lt "$nshards" ]; do
                [ "${load[g]}" -lt "${load[best]}" ] && best=$g
                g=$((g + 1))
            done
        fi
        load[best]=$((load[best] + wt[i]))
        held[best]="${held[best]}${files[$i]} "
        [ "$best" -eq $((k - 1)) ] && keep[i]=1
    done
    # keep share K's units, in name order; an empty array is unset to bash
    # 3.2's set -u, so none is ever expanded
    kf=(); kp=(); kl=(); kw=()
    for i in "${!files[@]}"; do
        [ -n "${keep[i]:-}" ] || continue
        kf+=("${files[$i]}"); kp+=("${part[$i]}"); kl+=("${label[$i]}"); kw+=("${wt[$i]}")
    done
    files=(); part=(); label=(); wt=()
    if [ ${#kf[@]} -gt 0 ]; then
        files=("${kf[@]}"); part=("${kp[@]}"); label=("${kl[@]}"); wt=("${kw[@]}")
    fi
fi
n=${#files[@]}

if [ "$list" = 1 ]; then
    [ "$n" -eq 0 ] && exit 0
    for i in "${!files[@]}"; do echo "${label[$i]}"; done
    exit 0
fi

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

if [ "$sharded" = 1 ]; then
    if [ "$n" -eq 0 ]; then
        echo "shard $k/$nshards: no suites (more shares than suites)"
        echo "nothing to run"
        exit 0
    fi
    names=""
    for i in "${!files[@]}"; do names="$names ${label[$i]}"; done
    echo "shard $k/$nshards:$names"
fi
[ "$njobs" -le "$n" ] || njobs=$n

# -- one at a time: each suite's output as it comes --------------------------

if [ "$njobs" -le 1 ]; then
    echo
    total_failed=0
    for i in "${!files[@]}"; do
        echo "${label[$i]}"
        QD_TEST_PART="${part[$i]}" bash "${files[$i]}" ||
            total_failed=$((total_failed + 1))
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
# order: the indices, the longest suite first.
order=()
pid=()
state=()
secs=()
for i in $(by_time); do order+=("$i"); done
for i in "${!files[@]}"; do state[i]=0; done

start_suite() {
    local i=$1
    (
        SECONDS=0
        QD_TEST_PART="${part[$i]}" bash "${files[$i]}" < /dev/null > "$out/$i.out" 2>&1
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
        echo "${label[$printed]}"
        cat "$out/$printed.out"
        echo
        printed=$((printed + 1))
        moved=1
    done
    [ "$moved" = 1 ] || sleep 0.2
done

took=$(for i in "${!files[@]}"; do
    echo "${secs[$i]} ${label[$i]}"
done | LC_ALL=C sort -k1,1nr -k2,2)
longest=$(echo "$took" | head -n 3 | awk '{ printf "%s%s %d s", (NR > 1 ? ", " : ""), $2, $1 }')
echo "time: $SECONDS s for $n suites, $njobs at a time (longest: $longest)"
# every suite's seconds in TIMES's form, to measure TIMES again from; a
# part says which (doe:2/3:56), and a suite's parts add up to its seconds
echo "seconds: $(echo "$took" | awk '{ printf "%s%s:%d", (NR > 1 ? " " : ""), $2, $1 }')"

if [ "$total_failed" -gt 0 ]; then
    echo "$total_failed suite(s) failed"
    exit 1
fi
echo "all suites passed"
