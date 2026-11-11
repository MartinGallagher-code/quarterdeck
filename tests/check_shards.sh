#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Martin J. Gallagher

# check_shards.sh -- every suite runs in exactly one of CI's shares.
#
# Usage: bash tests/check_shards.sh [WORKFLOW]
#
# WORKFLOW is .github/workflows/ci.yml unless one is named.  Each job there
# that runs `run_tests.sh --shard ${{ matrix.shard }}/N` must list shard 1
# to N in its matrix, each once, so no share goes unrun.  And for every
# such N, and for 1 to 8 besides, what run_tests.sh deals to shares 1/N to
# N/N must be, put together, every suite once: whole in one share, or split
# into parts 1/P to P/P, each in one share and no two in the same one.
#
# Exit status: 0 when that holds, 1 when it does not, 2 on bad usage.

set -u
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
case "${1:-}" in
    -h | --help) sed -n '5,17p' "$here/check_shards.sh" | sed 's/^# \{0,1\}//'; exit 0 ;;
esac
[ $# -le 1 ] || { echo "usage: check_shards.sh [WORKFLOW]" >&2; exit 2; }
wf="${1:-$here/../.github/workflows/ci.yml}"
[ -f "$wf" ] || { echo "no such workflow: $wf" >&2; exit 2; }
runner="$here/run_tests.sh"

all="$(bash "$runner" --list | LC_ALL=C sort)"
if [ -z "$all" ]; then
    echo "run_tests.sh --list names no suites" >&2
    exit 1
fi
bad=0

# Each job that runs a share: its name, the N it passes, and the shards its
# matrix lists (comma-separated, "-" for none).  A --shard that is not
# ${{ matrix.shard }}/N is reported with N "?".
jobs="$(awk '
    /^[ \t]*#/ { next }
    /^  [A-Za-z0-9_-]+:[ \t]*$/ { job = $1; sub(/:$/, "", job); next }
    /^[ \t]+shard:[ \t]*\[/ {
        s = $0; sub(/^[^[]*\[/, "", s); sub(/\].*$/, "", s)
        gsub(/[ \t]/, "", s); shards[job] = s; next
    }
    {
        p = index($0, "--shard")
        if (p == 0) next
        rest = substr($0, p + 7)
        key = "${{ matrix.shard }}/"
        q = index(rest, key)
        num = (q > 0 && q <= 3) ? substr(rest, q + length(key)) : ""
        sub(/[^0-9].*$/, "", num)
        n[job] = (num == "") ? "?" : num
    }
    END { for (j in n) print j, n[j], ((j in shards) ? shards[j] : "-") }
' "$wf" | LC_ALL=C sort)"

ns=""
sharded=""
while read -r job n listed; do
    [ -n "$job" ] || continue
    if [ "$n" = "?" ]; then
        echo "$job: --shard is not \${{ matrix.shard }}/N"
        bad=1
        continue
    fi
    # 1,2,...,N (BSD's seq -s puts a comma after the last one too)
    want=1
    k=2
    while [ "$k" -le "$n" ]; do want="$want,$k"; k=$((k + 1)); done
    if [ "$listed" != "$want" ]; then
        echo "$job: runs shares of $n but its matrix lists shard: [$listed], not [$want]"
        bad=1
    fi
    ns="$ns $n"
    sharded="$sharded $job ($n)"
done <<EOF
$jobs
EOF

# cover N: shares 1/N to N/N together are every suite, once.  Each line
# of --list is a suite, or a part of one as SUITE:I/P.
cover() {
    local n=$1 k=1 got problems
    got="$(while [ "$k" -le "$n" ]; do
        bash "$runner" --list --shard "$k/$n" | sed "s|^|$k |"
        k=$((k + 1))
    done)"
    problems="$(echo "$got" | awk -v all="$(echo "$all" | tr '\n' ' ')" -v n="$n" '
        NF == 0 { next }
        {
            share = $1; label = $2; suite = label
            sub(/:.*/, "", suite)
            if (!(suite in known)) { extra = extra " " label; next }
            if (label == suite) { whole[suite]++; next }
            ip = label; sub(/^[^:]*:/, "", ip)
            i = ip; sub(/\/.*/, "", i); p = ip; sub(/.*\//, "", p)
            if ((suite in size) && size[suite] != p) mixed = mixed " " suite
            size[suite] = p
            seen[suite, i]++
            if (++held[share, suite] > 1) together = together " " suite
        }
        BEGIN { m = split(all, names, " "); for (j = 1; j <= m; j++) known[names[j]] = 1 }
        END {
            for (j = 1; j <= m; j++) {
                s = names[j]
                if (!(s in size)) {
                    if (whole[s] == 0) none = none " " s
                    if (whole[s] > 1) twice = twice " " s
                    continue
                }
                if (whole[s] > 0) twice = twice " " s
                for (i = 1; i <= size[s]; i++) {
                    if (seen[s, i] == 0) none = none " " s ":" i "/" size[s]
                    if (seen[s, i] > 1) twice = twice " " s ":" i "/" size[s]
                }
            }
            if (none != "") print n " shares: in none:" none
            if (twice != "") print n " shares: in two or more:" twice
            if (extra != "") print n " shares: not a suite:" extra
            if (mixed != "") print n " shares: parts of two sizes:" mixed
            if (together != "") print n " shares: two parts in one share:" together
        }')"
    if [ -n "$problems" ]; then
        echo "$problems"
        bad=1
    fi
}

checked=""
for n in 1 2 3 4 5 6 7 8 $ns; do
    case " $checked " in *" $n "*) continue ;; esac
    checked="$checked $n"
    cover "$n"
done

suites=$(echo "$all" | wc -l | tr -d ' ')
if [ "$bad" != 0 ]; then
    echo "check_shards: FAILED"
    exit 1
fi
echo "check_shards: $suites suites, each in exactly one share for N =$checked"
echo "check_shards: sharded jobs, each running every share:${sharded:- none}"
