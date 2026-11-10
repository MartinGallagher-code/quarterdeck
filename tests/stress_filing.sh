#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Martin J. Gallagher
#
# stress_filing.sh -- every table of a run reads back when provost files it
# one capture at a time (QD-022).  Not one of the suites (it is not
# test_*.sh, so run_tests.sh skips it): it loops, because what it looks for
# shows only now and then.
#
#   bash tests/stress_filing.sh [ROUNDS]             default 20
#   STRESS_TABLES=4 STRESS_SIDE=8 bash tests/stress_filing.sh 50
#   STRESS_MKDIR=racy bash tests/stress_filing.sh    mkdir as uutils' was
#   STRESS_MKDIR=racy STRESS_FILE_JOBS=4 bash ...    qd as it was: fails
#   STRESS_RAW=1 bash tests/stress_filing.sh         provost alone, no qd
#
# A round is a fresh store and two `qd do` runs into it, each importing
# STRESS_TABLES small tables (default 3), on provost's one-capture-at-a-time
# path (QD_PROVOST_BATCH=0) whatever provost is installed.  STRESS_SIDE
# rounds (default 4) start together, as CI starts four suites at once.
# After each run, and the first again after the second, every table must
# read back with its own rows.
#
# Why: provost's store lock is `mkdir .lock`, which locks only where mkdir
# fails on a directory another process has just made.  uutils coreutils'
# mkdir before 0.11.0 -- /usr/bin/mkdir on Ubuntu 25.10 and 26.04, so on
# GitHub's ubuntu-latest -- reports success when it loses that race, and
# two provost processes started together can both hold the lock: one
# capture id for two captures, or a git index.lock between them, and a
# table goes missing.  STRESS_MKDIR=racy puts first on PATH a mkdir that
# loses the race the same way (more often: its window is a fork wide), so
# it shows on any machine.  qd files one capture after another since
# 0.8.7; STRESS_FILE_JOBS=N is QD_FILE_JOBS=N in each round, N at once as
# qd filed four before, so the case can be seen to fail.  STRESS_RAW=1
# leaves qd out and files STRESS_TABLES captures with provost at once, to
# show what this machine's mkdir does to provost's lock.
#
# Exit status: 0 when every round read back whole, 1 when one did not, 2
# on bad usage or with no provost.

set -u
source "$(dirname "${BASH_SOURCE[0]}")/test_helper.bash"

ROUNDS="${1:-20}"
TABLES="${STRESS_TABLES:-3}"
SIDE="${STRESS_SIDE:-4}"
FILE_JOBS="${STRESS_FILE_JOBS:-}"
for v in "$ROUNDS" "$TABLES" "$SIDE" ${FILE_JOBS:+"$FILE_JOBS"}; do
    case "$v" in
        "" | *[!0-9]* | 0*)
            echo "ROUNDS, STRESS_TABLES, STRESS_SIDE and STRESS_FILE_JOBS" \
                "are whole numbers, 1 or more: $v" >&2
            exit 2 ;;
    esac
done
if [ -z "$PROVOST_CMD" ]; then
    echo "no provost: pip install provost, or point QD_PROVOST at one" >&2
    exit 2
fi
export QD_PROVOST_BATCH=0

WORK="$(mktemp -d "${TMPDIR:-/tmp}/qd-stress.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# Which mkdir provost will find, as it names itself (GNU's and uutils' do).
real="$(command -v mkdir)"
shown="$real ($("$real" --version 2> /dev/null | head -n 1 || true))"
case "${STRESS_MKDIR:-}" in
    "") ;;
    racy)
        shown="a racy stand-in in front of $shown"
        mkdir -p "$WORK/bin"
        cat > "$WORK/bin/mkdir" <<EOF
#!/usr/bin/env bash
# mkdir as uutils coreutils' before 0.11.0, for one directory and no -p:
# one there before it looked fails, but one another process made between
# its look and its make is reported as made, here.
if [ \$# -eq 1 ] && [ "\${1#-}" = "\$1" ]; then
    [ -e "\$1" ] && { echo "mkdir: \$1: File exists" >&2; exit 1; }
    "$real" "\$1" 2> /dev/null && exit 0
    [ -d "\$1" ] && exit 0
    exec "$real" "\$1"
fi
exec "$real" "\$@"
EOF
        chmod +x "$WORK/bin/mkdir"
        export PATH="$WORK/bin:$PATH" ;;
    *) echo "STRESS_MKDIR is racy, or unset: $STRESS_MKDIR" >&2; exit 2 ;;
esac

# One round of qd: what went missing, one line each; nothing when every
# table read back.
qd_round() {
    local r="$1" pass k
    local -a imports
    setup_env || return 1
    [ -z "$FILE_JOBS" ] || export QD_FILE_JOBS="$FILE_JOBS"
    for pass in 1 2; do
        imports=()
        for k in $(seq 1 "$TABLES"); do
            printf 'host\tround\tpass\ttable\na\t%d\t%d\t%d\nb\t%d\t%d\t%d\n' \
                "$r" "$pass" "$k" "$r" "$pass" "$k" > "t$k.tsv"
            imports+=(--import "t$k.tsv")
        done
        if ! qd "do" --name stress "${imports[@]}" -- true \
                > /dev/null 2> "do.$pass.err"; then
            echo "round $r, run $pass: qd do failed: $(tail -n 1 "do.$pass.err")"
            continue
        fi
        # what qd said provost would not file, if anything
        grep -h "provost did not file" "do.$pass.err" |
            sed "s/^/round $r, run $pass: /"
        check "$r" "$pass" latest
    done
    check "$r" 1 latest~1
    teardown_env
}

# check ROUND PASS REF: each table of the run REF is there, with its rows
check() {
    local k out
    for k in $(seq 1 "$TABLES"); do
        out="$(qd show "$3:t$k" --format csv 2>&1)" || true
        case "$out" in
            *"b,$1,$2,$k"*) ;;
            *) echo "round $1, run $2 ($3): table t$k: $(printf '%s' "$out" |
                   tail -n 1)" ;;
        esac
    done
}

# One round of provost alone: STRESS_TABLES captures at once.
raw_round() {
    local r="$1" k n
    setup_env || return 1
    for k in $(seq 1 "$TABLES"); do
        printf '#%% run=stress-%d table=t%d\nhost,v\na,%d\nb,%d\n' \
            "$r" "$k" "$k" "$k" > "in.$k.csv"
    done
    for k in $(seq 1 "$TABLES"); do
        pv --sync -q --name "t$k" "in.$k.csv" 2> "pv.$k.err" &
    done
    wait
    n="$(grep -l "run=stress-$r " "$QD_STORE"/captures/c*/context.txt \
        2> /dev/null | wc -l | tr -d ' ')"
    if [ "$n" != "$TABLES" ]; then
        echo "round $r: $n of $TABLES captures filed;" \
            "$(cat pv.*.err | grep . | head -n 2 | tr '\n' ' ')"
    fi
    teardown_env
}

fn=qd_round
what="two qd do runs of $TABLES tables each, ${FILE_JOBS:-1} filed at once"
if [ "${STRESS_RAW:-0}" = 1 ]; then
    fn=raw_round
    what="$TABLES provost captures at once"
fi
echo "provost: $PROVOST_CMD, one capture at a time"
echo "mkdir:   $shown"
echo "rounds:  $ROUNDS, $SIDE side by side, $what"

# SIDE rounds at a time, started together; each round's lines kept apart
r=0
while [ "$r" -lt "$ROUNDS" ]; do
    for _ in $(seq 1 "$SIDE"); do
        [ "$r" -lt "$ROUNDS" ] || break
        r=$((r + 1))
        ( "$fn" "$r" > "$WORK/round.$r" 2>&1 ) &
    done
    wait
done

bad=0
for r in $(seq 1 "$ROUNDS"); do
    if [ -s "$WORK/round.$r" ]; then
        bad=$((bad + 1))
        sed 's/^/  /' "$WORK/round.$r"
    fi
done
echo "$bad of $ROUNDS rounds lost something"
[ "$bad" -eq 0 ]
