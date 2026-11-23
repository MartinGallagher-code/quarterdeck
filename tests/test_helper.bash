# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Martin J. Gallagher
#
# test_helper.bash -- shared harness for quarterdeck's suites.
#
# Sourced by every test_*.sh.  Provides:
#   run_test NAME FN        run one case in a subshell with a fresh temp dir
#                           (only if NAME contains $QD_TEST_ONLY, when set,
#                           and is in part $QD_TEST_PART, when set)
#   assert_eq/contains/not_contains/status/file_exists/no_file
#   fail MSG                fail a case with a reason no assert_ covers
#   qd ARGS...              the CLI under test, run from a clone
#   install_fake_ssh        an ssh+scp pair that run "remote" commands locally
#                           (FAKE_SSH_DETACH=1: apart from the client, as
#                           OpenSSH runs them; FAKE_SSH_RC=FILE: the host's
#                           login shell reads FILE first, as bash does
#                           ~/.bashrc under sshd, and prints what it prints)
#   install_fake_launchers  srun, scontrol, pdsh, pdcp and clush that do the
#                           same, on PATH; in_allocation sets a Slurm job
#   fake_host NAME          a sandbox root for one fake host
#   fake_host_unreachable NAME
#   pv ARGS...              provost itself, on the case's store
#   has_batch               whether that provost files a run as one batch
#   assert_dir_exists DIR   a directory is there
#   use_fixtures            a suite's cases all run in one directory path,
#                           so that `fixture` can hand each a copy (QD-074)
#   fixture NAME CMD...     a costly setup made once a suite: the first case
#                           to ask runs CMD, later ones get a copy of what it
#                           left (the store, the fake hosts, every file, the
#                           variables it exported); needs use_fixtures
#   stand_in_doe            a doe that designs and analyses as the real one
#   stand_in_fio            a fio whose JSON answer is a known function of
#                           its options (FIO_FAIL=TEXT: fails, as fio does,
#                           when its arguments contain TEXT)
#   path_without CMD...     this PATH without those commands
#   nojq_path               this PATH without jq, for provost's own readers
#   no_store_check DIR...   leave these stores out of QD_STORE_CHECK
#   has_store_check         whether that provost has `store check`
#
# QD_STORE_CHECK=1 runs `provost store check` (provost 2.16.0 on) on every
# store a case leaves, once the case has passed, and fails the case on what
# it finds: a filing that breaks provost's store format (its
# docs/store-format.md) fails here, not in somebody's store.  With a
# provost that has no `store check`, 1 checks nothing and `require` fails
# every case (CI's store-check job sets require).  QD-031.
#
# The harness is binnacle's (tests/test_helper.bash there), trimmed to what
# these suites use: every case runs in a subshell, so one failed assertion
# cannot abort the rest of the file, and each gets its own $TEST_TMPDIR.

QD_DIR="${QD_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
# Resolved once, to a path: a case that narrows PATH must still find the
# interpreter, which the python:3.6 image keeps in /usr/local/bin.
PY="$(command -v "${PY:-python3}")"
# qd keeps everything in provost's store, so the suites need a provost:
# QD_PROVOST (a path, or a command line), else the one on PATH.
PROVOST_CMD="${QD_PROVOST:-$(command -v provost 2>/dev/null || true)}"
export QD_PROVOST="$PROVOST_CMD"

TESTS_RUN=0
TESTS_FAILED=0
FAILED_NAMES=()

# QD_TEST_PART=I/P runs part I of P of this suite: its 1st, (P+1)th, ...
# case counted from the Ith, whatever QD_TEST_ONLY says.  run_tests.sh
# --shard splits its longest suites so (QD-024); unset or empty, every
# case.
TESTS_SEEN=0
TEST_PART_I=1
TEST_PART_P=1
case "${QD_TEST_PART:-}" in
    "") ;;
    [1-9]/[1-9] | [1-9]/[1-9][0-9] | [1-9][0-9]/[1-9][0-9])
        TEST_PART_I="${QD_TEST_PART%/*}"
        TEST_PART_P="${QD_TEST_PART#*/}" ;;
    *) TEST_PART_I=0 ;;
esac
if [ "$TEST_PART_I" -lt 1 ] || [ "$TEST_PART_I" -gt "$TEST_PART_P" ]; then
    echo "QD_TEST_PART is I/P, whole numbers with 1 <= I <= P < 100: $QD_TEST_PART" >&2
    exit 2
fi

setup_env() {
    # macOS's TMPDIR ends in a slash; a doubled one would not match the
    # paths qd prints
    local tmp="${TMPDIR:-/tmp}"
    if [ -n "${SUITE_TMPDIR:-}" ]; then
        # use_fixtures: one path for every case, so a fixture's copy -- whose
        # store, shims and logs name that path -- works in each
        TEST_TMPDIR="$SUITE_TMPDIR/case"
        mkdir "$TEST_TMPDIR"
    else
        TEST_TMPDIR="$(mktemp -d "${tmp%/}/qd-test.XXXXXX")"
    fi
    export TEST_TMPDIR
    export FAKE_BIN="$TEST_TMPDIR/bin"
    export FAKE_ROOT="$TEST_TMPDIR/hosts"
    export FAKE_SSH_LOG="$TEST_TMPDIR/ssh.log"
    # every ssh and scp the fakes are started with, options and all
    export FAKE_SSH_ARGV="$TEST_TMPDIR/ssh.argv"
    export FAKE_PY="$PY"
    unset FAKE_SSH_DETACH FAKE_SSH_RC
    mkdir -p "$FAKE_BIN" "$FAKE_ROOT"
    : > "$FAKE_SSH_LOG"
    : > "$FAKE_SSH_ARGV"
    # A stray variable from the caller's shell must never change a result.
    unset QD_STORE QD_SERVERS QD_JOBS QD_TIMEOUT QD_SSH QD_SCP QD_SSH_USER
    unset QD_REMOTE_DIR QD_MAX_OUTPUT QD_Z QD_ASCII QD_MANIFEST QD_CACHE
    unset QD_MX QD_IPERF_ORCHESTRATOR QD_AGREE QD_DCVIZ QD_WEB_HOST
    unset QD_WEB_PORT QD_TEST_KEYS QD_TEST_SCREEN QD_FILE_JOBS QD_RATE
    unset QD_WEB_TOKEN QD_WEB_TOKEN_FILE QD_WEB_TLS_CERT QD_WEB_TLS_KEY QD_TEST_CA
    unset QD_ALLOW QD_READ_ONLY QD_TEST_PART QD_SSH_CONFIG QD_SSH_REUSE
    unset QD_VIA PDSH_SSH_ARGS_APPEND QD_KEEP_PREAMBLE BASH_ENV ENV
    unset SLURM_JOB_ID SLURM_JOBID SLURM_JOB_NODELIST SLURM_NODELIST
    unset SLURM_JOB_PARTITION
    unset PROVOST_WORKSPACE PROVOST_HOME PROVOST_CONTEXT_COLUMNS PROVOST_QUIET
    unset QD_OPERATOR PROVOST_OPERATOR
    unset QD_WAIVERS QD_MANUAL QD_FAIL_LEVEL
    # Every case files into a store of its own; QD_PROVOST_BATCH=0 from
    # the caller runs the suites on the one-capture-at-a-time path.
    export QD_STORE="$TEST_TMPDIR/store"
    export XDG_CACHE_HOME="$TEST_TMPDIR/cache"
    # qd's config (named stores), where its stores live, and provost's
    # default store: the case's own, never this machine's
    export XDG_CONFIG_HOME="$TEST_TMPDIR/config"
    export XDG_DATA_HOME="$TEST_TMPDIR/data"
    export PROVOST_HOME="$TEST_TMPDIR/provost-home"
    export LANG=C
    # git 2.47 and later follow a commit or a fetch with a detached `git
    # maintenance run --auto`, which can still be writing into the store's
    # .git when the case ends and teardown removes it (CI, the suites side
    # by side).  These stores live for seconds: none of that here.
    export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=maintenance.auto \
        GIT_CONFIG_VALUE_0=false
    cd "$TEST_TMPDIR" || return 1
}

teardown_env() {
    local pid pidfile
    # a case's web server, and a case's sshd (test_ssh.sh)
    for pidfile in "$TEST_TMPDIR/web.pid" "$TEST_TMPDIR/sshd.pid"; do
        [ -f "$pidfile" ] || continue
        pid="$(cat "$pidfile")"
        kill "$pid" 2>/dev/null || true
        # gone before its directory is
        for _ in 1 2 3 4 5 6 7 8 9 10; do
            kill -0 "$pid" 2>/dev/null || break
            sleep 0.1
        done
    done
    cd / || true
    # a second go for anything the case started that outlived it
    if [ -n "$TEST_TMPDIR" ]; then
        rm -rf "$TEST_TMPDIR" 2> /dev/null || { sleep 1; rm -rf "$TEST_TMPDIR"; }
    fi
}

# use_fixtures: called once, at the top of a suite whose cases share a
# costly setup.  Every case of the suite then runs in $SUITE_TMPDIR/case
# (made afresh for each, and removed after it, as the random one is), and
# the fixtures live beside it until the suite ends.  A suite whose cases
# leave processes behind them should not use it: the next case has the
# same path.
use_fixtures() {
    local tmp="${TMPDIR:-/tmp}"
    SUITE_TMPDIR="$(mktemp -d "${tmp%/}/qd-suite.XXXXXX")"
    export SUITE_TMPDIR
    # shellcheck disable=SC2064  # the path now, not at exit
    trap "rm -rf '$SUITE_TMPDIR'" EXIT
}

# fixture NAME CMD...: in a case, the state CMD leaves -- run here the
# first time NAME is asked for in this suite (or this part of it), and a
# copy of what it left every later time: every file under the case's
# directory, the directory it ended in and the variables it exported or
# unset (a variable it set without exporting is not kept).  A
# case gets the same as if it had run CMD itself, in a fraction of the
# time when CMD files runs (QD-074).  NAME says what differs: two setups
# that differ in anything are two names.
fixture() {
    local name="$1" snap
    shift
    [ -n "${SUITE_TMPDIR:-}" ] || { fail "fixture $name: the suite has not called use_fixtures"; return 1; }
    snap="$SUITE_TMPDIR/fixture.$name"
    if [ -d "$snap" ]; then
        cp -a "$snap/files/." "$TEST_TMPDIR/"
        # shellcheck disable=SC1091
        . "$snap/env"
        cd "$(cat "$snap/pwd")" || return 1
        return 0
    fi
    local before names v
    before="$(export -p)"
    names="$(compgen -e)"
    "$@" || return 1
    mkdir -p "$snap/files"
    cp -a "$TEST_TMPDIR/." "$snap/files/"
    # what CMD exported, as global exports (sourced inside this function),
    # and what it unset
    export -p | grep -vxF -e "$before" | sed 's/^declare -x /declare -gx /' > "$snap/env" || true
    for v in $names; do
        [ -n "${!v+x}" ] || echo "unset $v" >> "$snap/env"
    done
    pwd > "$snap/pwd"
}

run_test() {
    local name="$1"; shift
    TESTS_SEEN=$((TESTS_SEEN + 1))
    [ $(((TESTS_SEEN - 1) % TEST_PART_P + 1)) -eq "$TEST_PART_I" ] || return 0
    # QD_TEST_ONLY=TEXT runs only the cases whose name contains TEXT
    case "$name" in
        *"${QD_TEST_ONLY:-}"*) ;;
        *) return 0 ;;
    esac
    TESTS_RUN=$((TESTS_RUN + 1))
    local out rc
    out="$(
        setup_env
        trap teardown_env EXIT
        set -e
        "$@" 2>&1
        store_check 2>&1
    )"
    rc=$?
    if [ $rc -eq 0 ]; then
        printf '  ok   %s\n' "$name"
    else
        TESTS_FAILED=$((TESTS_FAILED + 1))
        FAILED_NAMES+=("$name")
        printf '  FAIL %s\n' "$name"
        printf '%s\n' "$out" | sed 's/^/       /'
    fi
}

finish() {
    printf '\n%d run, %d failed\n' "$TESTS_RUN" "$TESTS_FAILED"
    if [ "$TESTS_FAILED" -gt 0 ]; then
        printf 'failed: %s\n' "${FAILED_NAMES[*]}"
        exit 1
    fi
    exit 0
}

qd() { "$PY" "$QD_DIR/qd" "$@"; }

# shellcheck disable=SC2086  # QD_PROVOST may be a command line
has_store_check() { $PROVOST_CMD store check --help > /dev/null 2>&1; }

# A store a case made by hand, or broke on purpose: not provost's to judge.
no_store_check() {
    local d
    for d in "$@"; do
        (cd "$d" 2>/dev/null && pwd -P) >> "$TEST_TMPDIR/.no-store-check" ||
            printf '%s\n' "$d" >> "$TEST_TMPDIR/.no-store-check"
    done
}

# `provost store check` on every store under the case's directory (each
# directory with a .store_format), but the copies of remote stores in the
# cache (QD-032's) and those no_store_check named; see QD_STORE_CHECK above.
store_check() {
    case "${QD_STORE_CHECK:-0}" in
        0 | "") return 0 ;;
        1 | require) ;;
        *) echo "QD_STORE_CHECK is 0, 1 or require: $QD_STORE_CHECK"; return 1 ;;
    esac
    if ! has_store_check; then
        [ "$QD_STORE_CHECK" = require ] || return 0
        echo "QD_STORE_CHECK=require: $PROVOST_CMD has no \`store check\` (provost 2.16.0 on)"
        return 1
    fi
    local f d real out bad=0 cache
    cache="$(cd "${XDG_CACHE_HOME:-/nonexistent}" 2>/dev/null && pwd -P)" || cache=""
    while IFS= read -r f; do
        d="${f%/.store_format}"
        real="$(cd "$d" && pwd -P)" || real="$d"
        if [ -n "$cache" ]; then
            case "$real/" in "$cache"/*) continue ;; esac
        fi
        if [ -f "$TEST_TMPDIR/.no-store-check" ] &&
            grep -qxF "$real" "$TEST_TMPDIR/.no-store-check"; then
            continue
        fi
        # shellcheck disable=SC2086  # QD_PROVOST may be a command line
        if ! out="$($PROVOST_CMD store check "$d" 2>&1)"; then
            printf 'provost store check %s failed:\n%s\n' "$d" "$out"
            bad=1
        fi
    done < <(find "$TEST_TMPDIR" -name .store_format -type f \
                  -not -path '*/.git/*' 2>/dev/null | sort)
    return "$bad"
}

# provost on the case's store, as qd files into it
# shellcheck disable=SC2086  # QD_PROVOST may be a command line
pv() { PROVOST_WORKSPACE="$QD_STORE" PROVOST_ASYNC=0 $PROVOST_CMD "$@"; }

# Whether this provost has `batch` (and --context-columns with it), and qd
# is using it.
has_batch() {
    [ "${QD_PROVOST_BATCH:-1}" != 0 ] && pv batch --help > /dev/null 2>&1
}

# This PATH without some commands: a directory of links to everything else
# on it. provost reads JSON with jq where it finds one and its own awk where
# it does not, and a probe answers differently on a host without ss or
# systemctl; `command -v` sees functions as well as files, so a command
# cannot be hidden any other way.
path_without() {
    local d p f b x hide base
    # in the case's own temp dir, so it goes when the case does
    base="${TEST_TMPDIR:-${TMPDIR:-/tmp}}"
    d="$(mktemp -d "${base%/}/qd-path.XXXXXX")"
    local IFS=:
    for p in $PATH; do
        for f in "$p"/*; do
            b="${f##*/}"
            hide=0
            for x in "$@"; do [ "$b" = "$x" ] && hide=1; done
            if [ -x "$f" ] && [ ! -d "$f" ] && [ "$hide" = 0 ] && \
                    [ ! -e "$d/$b" ]; then
                ln -s "$f" "$d/$b"
            fi
        done
    done
    echo "$d"
}

_NOJQ_PATH=""
nojq_path() {
    [ -n "$_NOJQ_PATH" ] || _NOJQ_PATH="$(path_without jq)"
    echo "$_NOJQ_PATH"
}

# Run qd and keep its exit status, for a case that expects a non-zero one
# under `set -e`.
# shellcheck disable=SC2034  # QD_RC is read by the suites
qd_rc() { set +e; "$PY" "$QD_DIR/qd" "$@"; QD_RC=$?; set -e; }

# The same with the fake transports put after the verb: qdf run -S a -- x
qdf() { qd "$1" --ssh "$FAKE_BIN/ssh" --scp "$FAKE_BIN/scp" "${@:2}"; }
qdf_rc() { qd_rc "$1" --ssh "$FAKE_BIN/ssh" --scp "$FAKE_BIN/scp" "${@:2}"; }

# -- assertions -------------------------------------------------------------

_fail() { printf 'assertion failed: %s\n' "$1" >&2; return 1; }
fail() { _fail "$1"; }

assert_eq() {
    [ "$1" = "$2" ] || _fail "expected '$2', got '$1'"
}

assert_contains() {
    case "$1" in
        *"$2"*) return 0 ;;
        *) _fail "expected output to contain '$2'; got: $(printf '%s' "$1" | head -c 900)" ;;
    esac
}

assert_not_contains() {
    case "$1" in
        *"$2"*) _fail "expected output NOT to contain '$2'; got: $(printf '%s' "$1" | head -c 900)" ;;
        *) return 0 ;;
    esac
}

assert_status() {
    [ "$1" -eq "$2" ] || _fail "expected exit status $2, got $1"
}

assert_file_exists() {
    [ -f "$1" ] || _fail "expected file to exist: $1"
}

assert_no_file() {
    [ ! -e "$1" ] || _fail "expected no such path: $1"
}

assert_dir_exists() {
    [ -d "$1" ] || _fail "expected a directory: $1"
}

# -- fake ssh / scp ---------------------------------------------------------
#
# The shim runs the "remote" command locally inside $FAKE_ROOT/<host>, so a
# whole fan-out can be exercised with no network and no second machine.
# Every invocation is logged so a case can assert what was invoked.

install_fake_ssh() {
    cat > "$FAKE_BIN/ssh" <<'SHIM'
#!/bin/bash
printf 'ssh %s\n' "$*" >> "$FAKE_SSH_ARGV"
args=(); host=""; config=""; ctl=""; cpath=""
while [ $# -gt 0 ]; do
  case "$1" in
    -o) case "$2" in ControlPath=*) cpath="${2#ControlPath=}";; esac
        shift 2;;
    -p|-i|-F|-l) shift 2;;
    -O) ctl="$2"; shift 2;;
    -G) config=1; shift;;
    *) if [ -z "$host" ]; then host="$1"; else args+=("$1"); fi; shift;;
  esac
done
host="${host#*@}"
# ssh -O: a master's control command, which talks to the local socket and
# no host.  --reuse's masters are played by a file per host beside
# ControlPath; FAKE_MASTER_OPEN says a config's own master is open.
if [ -n "$ctl" ]; then
  printf 'ssh-O %s %s\n' "$ctl" "$host" >> "$FAKE_SSH_LOG"
  m="${cpath%/*}/fake-master-$host"
  case "$ctl" in
    exit) [ -n "$cpath" ] && [ -e "$m" ] && { rm -f "$m"; exit 0; }
          exit 255;;
    check) { [ -n "$cpath" ] && [ -e "$m" ]; } || [ -n "${FAKE_MASTER_OPEN:-}" ] && exit 0
           exit 255;;
  esac
  exit 255
fi
if [ -n "$cpath" ] && [ -z "$config" ] && [ -d "${cpath%/*}" ] && \
    [ ! -f "$FAKE_ROOT/$host/.unreachable" ] && [ -d "$FAKE_ROOT/$host" ]; then
  : > "${cpath%/*}/fake-master-$host"
fi
# ssh -G: the config ssh would use, read locally and logged apart, so it
# is not counted as a connection.  FAKE_SSH_USER_<host> (dots and dashes
# as _) gives a host a user of its own, FAKE_NO_DASH_G an ssh without -G.
if [ -n "$config" ]; then
  printf 'ssh-G %s\n' "$host" >> "$FAKE_SSH_LOG"
  [ -n "${FAKE_NO_DASH_G:-}" ] && { echo "ssh: illegal option -- G" >&2; exit 255; }
  v="FAKE_SSH_USER_${host//[.-]/_}"
  printf 'user %s\nhostname %s\nport 22\n' "${!v:-${FAKE_SSH_USER:-$(id -un)}}" "$host"
  # FAKE_SSH_G: more of the config, as ssh -G would print it
  [ -n "${FAKE_SSH_G:-}" ] && printf '%s\n' "$FAKE_SSH_G"
  exit 0
fi
printf 'ssh %s %s\n' "$host" "${args[*]}" >> "$FAKE_SSH_LOG"
if [ -f "$FAKE_ROOT/$host/.unreachable" ]; then
  echo "ssh: connect to host $host port 22: Connection timed out" >&2
  exit 255
fi
[ -d "$FAKE_ROOT/$host" ] || { echo "ssh: Could not resolve hostname $host" >&2; exit 255; }
cd "$FAKE_ROOT/$host" || exit 255
export FAKE_HOST="$host"
# FAKE_SSH_DETACH=1: as OpenSSH does, the "remote" command runs in a
# session of its own, apart from this client, so killing the client
# leaves it running (QD-026).  Otherwise it is this process.
# FAKE_SSH_RC=FILE: the login shell reads FILE before the command, as
# bash reads ~/.bashrc when sshd starts it (QD-038), and only that shell:
# fake-login-rc unsets BASH_ENV before it reads FILE.
[ -n "${FAKE_SSH_RC:-}" ] && export BASH_ENV="$FAKE_BIN/fake-login-rc"
if [ -n "${FAKE_SSH_DETACH:-}" ]; then
  exec 3<&0
  "${FAKE_PY:-python3}" -c 'import os, sys
os.setsid()
os.execvp("bash", ["bash", "-c", sys.argv[1]])' "${args[*]}" <&3 3<&- &
  wait $!
  exit $?
fi
exec bash -c "${args[*]}"
SHIM
    cat > "$FAKE_BIN/scp" <<'SHIM'
#!/bin/bash
printf 'scp %s\n' "$*" >> "$FAKE_SSH_ARGV"
args=()
while [ $# -gt 0 ]; do
  case "$1" in
    -o) shift 2;; -P) shift 2;; -F) shift 2;; -q) shift;;
    *) args+=("$1"); shift;;
  esac
done
n=${#args[@]}; dest="${args[$((n-1))]}"; srcs=("${args[@]:0:$((n-1))}")
host="${dest%%:*}"; host="${host#*@}"; path="${dest#*:}"
printf 'scp %s %s\n' "$host" "$path" >> "$FAKE_SSH_LOG"
[ -f "$FAKE_ROOT/$host/.unreachable" ] && exit 1
target="$FAKE_ROOT/$host/${path#/}"
mkdir -p "$target" 2>/dev/null
cp "${srcs[@]}" "$target/" 2>/dev/null || exit 1
SHIM
    # Remote paths are absolute; the fake host's root stands in for /.
    chmod +x "$FAKE_BIN/ssh" "$FAKE_BIN/scp"
    fake_login_rc
}

# What a fake host's login shell reads first when FAKE_SSH_RC is set: that
# file, once, in that shell and none it starts (QD-038).
fake_login_rc() {
    # shellcheck disable=SC2016  # expanded by the fake host's shell
    printf '%s\n' 'unset BASH_ENV' '. "$FAKE_SSH_RC"' > "$FAKE_BIN/fake-login-rc"
}

fake_host() {
    mkdir -p "$FAKE_ROOT/$1"
}

fake_host_unreachable() {
    mkdir -p "$FAKE_ROOT/$1"
    touch "$FAKE_ROOT/$1/.unreachable"
}

ssh_calls() {
    local n=0
    if [ -f "$FAKE_SSH_LOG" ]; then
        n=$(grep -c '^ssh ' "$FAKE_SSH_LOG" 2>/dev/null) || n=0
    fi
    printf '%s\n' "$n"
}

# -- fake srun, scontrol, pdsh, pdcp and clush --------------------------------
#
# One stand-in, called by each name, that reaches the same fake hosts as
# the fake ssh ($FAKE_ROOT/<host>, .unreachable) and says what the real
# tool says: srun's "task 0: Exited with exit code N" and step errors,
# pdsh's and clush's "host: " before every line -- with the hosts' lines
# interleaved as they come -- and their own "exited with exit code" and
# "command timeout" lines.  Put on PATH ahead of anything real, and every
# call is logged in $FAKE_SSH_LOG.  A host with .nopdcp has no pdcp.

install_fake_launchers() {
    cat > "$FAKE_BIN/qd-fake-launcher" <<'EOF'
#!/usr/bin/env python3
import os, re, signal, subprocess, sys, threading, time
tool = os.path.basename(sys.argv[0])
args = sys.argv[1:]
root = os.environ["FAKE_ROOT"]
lock = threading.Lock()

def log(text):
    with open(os.environ["FAKE_SSH_LOG"], "a") as f:
        f.write(text + "\n")

def say(stream, text):
    with lock:
        stream.write(text + "\n")
        stream.flush()

def expand(spec):
    out = []
    for part in re.findall(r"[^,\[]+(?:\[[^\]]*\][^,\[]*)*", spec):
        m = re.match(r"^([^\[]*)\[([^\]]*)\](.*)$", part)
        if not m:
            out.append(part)
            continue
        for r in m.group(2).split(","):
            a, _, b = r.partition("-")
            for n in range(int(a), int(b or a) + 1):
                for tail in expand(m.group(3)) if m.group(3) else [""]:
                    out.append(m.group(1) + str(n).zfill(len(a)) + tail)
    return out

def state(host):
    d = os.path.join(root, host)
    if not os.path.isdir(d):
        return d, "unknown"
    if os.path.exists(os.path.join(d, ".unreachable")):
        return d, "unreachable"
    return d, "ok"

def run(argv, cwd, host, timeout, out, err, stdin=None):
    env = dict(os.environ, FAKE_HOST=host, SLURMD_NODENAME=host)
    # FAKE_SSH_RC: the host's login shell reads it first (QD-038)
    if env.get("FAKE_SSH_RC"):
        env["BASH_ENV"] = os.path.join(env["FAKE_BIN"], "fake-login-rc")
    p = subprocess.Popen(argv, cwd=cwd, env=env, stdout=subprocess.PIPE,
                         stderr=subprocess.PIPE, stdin=stdin,
                         start_new_session=True)
    def pump(f, fn):
        for raw in iter(f.readline, b""):
            fn(raw.decode("utf-8", "replace").rstrip("\n"))
    ts = [threading.Thread(target=pump, args=(p.stdout, out)),
          threading.Thread(target=pump, args=(p.stderr, err))]
    for t in ts:
        t.start()
    try:
        rc = p.wait(timeout=timeout)
    except subprocess.TimeoutExpired:
        os.killpg(p.pid, signal.SIGKILL)
        p.wait()
        rc = None
    for t in ts:
        t.join()
    return rc

def opts(names_with_value, flags=()):
    got, rest = {}, list(args)
    while rest and rest[0].startswith("-") and rest[0] != "--":
        a = rest.pop(0)
        if a in flags:
            got[a] = True
        elif a in names_with_value:
            got[a] = rest.pop(0)
        elif a[:2] in names_with_value and len(a) > 2:
            got[a[:2]] = a[2:]
        else:
            say(sys.stderr, "%s: unknown option %s" % (tool, a))
            sys.exit(2)
    if rest and rest[0] == "--":
        rest.pop(0)
    return got, rest

if tool == "scontrol":
    if args[:2] != ["show", "hostnames"]:
        sys.exit(1)
    log("scontrol " + args[2])
    for h in expand(args[2]):
        print(h)
    sys.exit(0)

if tool == "srun":
    o, cmd = opts(("-N", "-n", "-w"), ("--overlap",))
    host = o.get("-w", "")
    log("srun %s %s" % (host, " ".join(cmd[2:] if cmd[:2] == ["sh", "-c"]
                                       else cmd)))
    if not os.environ.get("SLURM_JOB_ID"):
        say(sys.stderr, "srun: error: no allocation here (the fake asks for none)")
        sys.exit(1)
    if "--overlap" not in o:
        say(sys.stderr, "srun: Job step creation temporarily disabled, retrying")
        sys.exit(1)
    d, st = state(host)
    if st == "unknown":
        say(sys.stderr, "srun: error: Unable to create step for job %s: "
            "Invalid node name specified" % os.environ["SLURM_JOB_ID"])
        sys.exit(1)
    if st == "unreachable":
        say(sys.stderr, "srun: error: Unable to create step for job %s: "
            "Requested node configuration is not available"
            % os.environ["SLURM_JOB_ID"])
        sys.exit(1)
    env = dict(os.environ, FAKE_HOST=host, SLURMD_NODENAME=host)
    # FAKE_SSH_RC: srun starts no login shell, but what the node prints
    # ahead of the task (a TaskProlog's `print` lines) comes first on the
    # task's own streams, as a login shell's would (QD-038)
    if env.get("FAKE_SSH_RC"):
        subprocess.call(["bash", env["FAKE_SSH_RC"]], cwd=d, env=env,
                        stdin=subprocess.DEVNULL)
    p = subprocess.Popen(cmd, cwd=d, env=env, start_new_session=True)
    def stop(sig, frame):
        os.killpg(p.pid, signal.SIGKILL)
        sys.exit(143)
    signal.signal(signal.SIGTERM, stop)
    rc = p.wait()
    if rc != 0:
        say(sys.stderr, "srun: error: %s: task 0: Exited with exit code %d"
            % (host, rc))
    sys.exit(rc)

if tool in ("pdsh", "pdcp", "clush"):
    o, rest = opts(("-f", "-t", "-u", "-l", "-w", "--dest"), ("--copy",))
    hosts = o["-w"].split(",")
    own = {"pdsh": "pdsh@fake: ", "pdcp": "pdcp@fake: ",
           "clush": "clush: "}[tool]
    exit_word = "ssh exited" if tool != "clush" else "exited"
    copying = tool == "pdcp" or "--copy" in o
    if tool == "clush" and copying and "--dest" in rest:
        i = rest.index("--dest")
        o["--dest"] = rest[i + 1]
        rest = rest[:i] + rest[i + 2:]
    log("%s %s %s%s" % (tool, o["-w"], "--copy " if "--copy" in o else "",
                         " ".join(rest)))
    timeout = float(o["-u"]) if "-u" in o else None
    bad = [0]
    sem = threading.Semaphore(int(o.get("-f", "32")))

    def one(host):
        with sem:
            d, st = state(host)
            if st != "ok":
                why = ("ssh: connect to host %s port 22: Connection timed out"
                       % host) if st == "unreachable" else \
                    ("ssh: Could not resolve hostname %s: Name or service "
                     "not known" % host)
                say(sys.stderr, "%s: %s" % (host, why))
                say(sys.stderr, "%s%s: %s with exit code 255" % (own, host, exit_word))
                bad[0] = 1
                return
            if copying:
                if tool == "pdcp":
                    files, dest = rest[:-1], rest[-1]
                else:
                    files, dest = rest, o["--dest"]
                if tool == "pdcp" and os.path.exists(os.path.join(d, ".nopdcp")):
                    say(sys.stderr, "%s: bash: pdcp: command not found" % host)
                    say(sys.stderr, "%s%s: %s with exit code 127" % (own, host, exit_word))
                    bad[0] = 1
                    return
                target = os.path.join(d, dest.lstrip("/"))
                for f in files:
                    try:
                        with open(f, "rb") as src, open(os.path.join(
                                target, os.path.basename(f)), "wb") as dst:
                            dst.write(src.read())
                    except (IOError, OSError) as exc:
                        say(sys.stderr, "%s: scp: %s" % (host, exc))
                        bad[0] = 1
                        return
                return
            rc = run(["bash", "-c", " ".join(rest)], d, host, timeout,
                     lambda t: say(sys.stdout, "%s: %s" % (host, t)),
                     lambda t: say(sys.stderr, "%s: %s" % (host, t)),
                     subprocess.DEVNULL)
            if rc is None and tool == "clush":
                timed.append(host)      # said once, for them all, below
                bad[0] = 1
            elif rc is None:
                say(sys.stderr, "%s%s: command timeout" % (own, host))
                bad[0] = 1
            elif rc != 0:
                say(sys.stderr, "%s%s: %s with exit code %d" % (own, host, exit_word, rc))
                bad[0] = 1

    timed = []
    ts = [threading.Thread(target=one, args=(h,)) for h in hosts]
    for t in ts:
        t.start()
    for t in ts:
        t.join()
    if timed:
        # clush names the hosts that timed out as one folded node set
        m = [re.match(r"^(\D+)(\d+)$", h) for h in sorted(timed)]
        if len(timed) > 1 and all(m) and len(set(x.group(1) for x in m)) == 1:
            folded = "%s[%s]" % (m[0].group(1), ",".join(x.group(2) for x in m))
        else:
            folded = ",".join(sorted(timed))
        say(sys.stderr, "clush: %s: command timeout" % folded)
    sys.exit(bad[0])
EOF
    chmod +x "$FAKE_BIN/qd-fake-launcher"
    fake_login_rc
    local t
    for t in srun scontrol pdsh pdcp clush; do
        ln -sf qd-fake-launcher "$FAKE_BIN/$t"
    done
    export PATH="$FAKE_BIN:$PATH"
}

# A Slurm allocation, as salloc leaves one in the environment.
in_allocation() {
    export SLURM_JOB_ID="${1:-4242}" SLURM_JOB_NODELIST="${2:-node[01-03]}"
    export SLURM_JOB_PARTITION="${3:-batch}"
}

# -- a stand-in doe ------------------------------------------------------------

# design_of_experiments' doe, for the suites: full factorial,
# Plackett-Burman, central composite and Box-Behnken designs, block_count
# copies of them, its suggest for a response surface, and two-level main
# effects for every response in the config -- the files, headings and
# --csv tables the real one has (it needs Python 3.10 and numpy).  Each
# value it was given is logged to $FAKE_BIN/doe-values, so a case can see
# what was analysed (and that a blank was not handed over as 0).
stand_in_doe() {
    cat > "$FAKE_BIN/doe" <<'EOF'
#!/usr/bin/env python3
# doe, for the suite: full factorial and Plackett-Burman designs,
# block_count copies of them, and two-level main effects -- the files,
# headings and --csv tables the real one has.
import csv, io, itertools, json, os, sys
# the real doe runs on Python 3.10+, which writes UTF-8 even under a C
# locale; this stand-in may run on 3.6 (CI's floor job), so it says so
sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding="utf-8")
a = sys.argv[1:]
def opt(n):
    return a[a.index(n) + 1] if n in a else None
def key(x):
    # doe's _numeric_sort_key: numbers by value, then the rest by name
    try:
        return (0, float(x), "")
    except ValueError:
        return (1, 0.0, x)
# Plackett-Burman's generating rows (8 and 12 runs), cycled, then all low
PB = {8: "+++-+--", 12: "++-+++---+-"}
def pbdesign(k):
    n = 8 if k <= 7 else 12
    g = PB[n]
    rows = [[g[(j - i) % (n - 1)] == "+" for j in range(n - 1)]
            for i in range(n - 1)] + [[False] * (n - 1)]
    return [r[:k] for r in rows]
def solve(A, y):
    # Gaussian elimination, partial pivoting: A x = y, or None if singular
    n = len(A)
    M = [list(map(float, A[i])) + [float(y[i])] for i in range(n)]
    for c in range(n):
        p = max(range(c, n), key=lambda r: abs(M[r][c]))
        if abs(M[p][c]) < 1e-12:
            return None
        M[c], M[p] = M[p], M[c]
        for r in range(n):
            if r != c:
                k = M[r][c] / M[c][c]
                M[r] = [x - k * z for x, z in zip(M[r], M[c])]
    return [M[i][n] / M[i][i] for i in range(n)]
def coding(f):
    lv = [float(x) for x in f["levels"]]
    return (min(lv) + max(lv)) / 2.0, (max(lv) - min(lv)) / 2.0
def quad(m, cfg, vals, linear=False):
    # doe's rsm.fit_rsm, least squares in coded units, or None where the
    # model cannot be fitted (a quadratic wants a middle level)
    fs = m["factor_names"]
    facs = dict((f["name"], f) for f in cfg["factors"])
    try:
        codes = dict((f, coding(facs[f])) for f in fs)
    except (KeyError, ValueError):
        return None
    rows = [r for r in m["runs"] if r["run_id"] in vals]
    x = [dict((f, (float(r["factor_values"][f]) - codes[f][0]) /
               (codes[f][1] or 1.0)) for f in fs) for r in rows]
    terms = ["intercept"] + fs
    if not linear:
        terms += ["%s*%s" % (p, q) for p, q in itertools.combinations(fs, 2)]
        terms += ["%s^2" % f for f in fs]
        if any(len(set(round(c[f], 9) for c in x)) < 3 for f in fs):
            return None
    if len(rows) < len(terms) + 1:
        return None
    def row(c):
        out = [1.0] + [c[f] for f in fs]
        if not linear:
            out += [c[p] * c[q] for p, q in itertools.combinations(fs, 2)]
            out += [c[f] ** 2 for f in fs]
        return out
    X = [row(c) for c in x]
    y = [float(vals[r["run_id"]]) for r in rows]
    k = len(terms)
    XtX = [[sum(X[n][i] * X[n][j] for n in range(len(X))) for j in range(k)]
           for i in range(k)]
    beta = solve(XtX, [sum(X[n][i] * y[n] for n in range(len(X)))
                       for i in range(k)])
    if beta is None:
        return None
    fit = [sum(b * v for b, v in zip(beta, xr)) for xr in X]
    mean = sum(y) / len(y)
    ss_res = sum((a - b) ** 2 for a, b in zip(y, fit))
    ss_tot = sum((a - mean) ** 2 for a in y)
    r2 = 1 - ss_res / ss_tot if ss_tot else 0.0
    n, p = len(y), k - 1
    adj = 1 - (ss_res / (n - p - 1)) / (ss_tot / (n - 1)) if ss_tot else r2
    inv = [solve(XtX, [1.0 if i == j else 0.0 for i in range(k)])
           for j in range(k)]
    h = [sum(X[r][i] * inv[i][j] * X[r][j] for i in range(k)
             for j in range(k)) for r in range(n)]
    press = sum(((a - b) / (1 - hh + 1e-12)) ** 2
                for a, b, hh in zip(y, fit, h))
    return dict(terms=terms, beta=beta, r2=r2, adj=adj, rows=rows, y=y,
                codes=codes, fs=fs, ss_res=ss_res, ss_tot=ss_tot,
                press=press, predict=lambda c: sum(
                    b * v for b, v in zip(beta, row(c))))
def stationary(q):
    # where the quadratic's gradient is 0, and its kind by the Hessian
    fs, b = q["fs"], dict(zip(q["terms"], q["beta"]))
    k = len(fs)
    H = [[2 * b["%s^2" % fs[i]] if i == j else
          b["%s*%s" % (fs[min(i, j)], fs[max(i, j)])] for j in range(k)]
         for i in range(k)]
    xs = solve(H, [-b[f] for f in fs])
    if xs is None:
        return None
    def det(M):
        if len(M) == 1:
            return M[0][0]
        return sum((-1) ** c * M[0][c] * det([r[:c] + r[c + 1:] for r in M[1:]])
                   for c in range(len(M)))
    # Sylvester: the leading minors' signs say definite, or neither
    minors = [det([r[:i] for r in H[:i]]) for i in range(1, k + 1)]
    if all(d > 0 for d in minors):
        kind = "minimum"
    elif all((d < 0) if i % 2 == 0 else (d > 0) for i, d in enumerate(minors)):
        kind = "maximum"
    else:
        kind = "saddle"
    c = dict(zip(fs, xs))
    return dict(kind=kind, coded=c, value=q["predict"](c),
                inside=all(abs(v) <= 1 + 1e-9 for v in xs))
def natural(q, f, c):
    return "%.6g" % (q["codes"][f][0] + c * q["codes"][f][1])
if a[0] == "suggest":
    # doe's response_surface rule (doe/suggest.py), in doe's words
    k, budget = int(opt("--factors")), int(opt("--budget"))
    why = ["Goal: response surface \u2014 fit a quadratic over %d factor(s)." % k]
    bb = {3: 13, 4: 25, 5: 41}.get(k)
    if bb and budget >= bb:
        op, n, rc = "box_behnken", bb, 3
        why.append("Box-Behnken on %d continuous factors uses %d runs (incl. "
                   "3 centre points) \u2014 rotatable and avoids the cube "
                   "corners." % (k, bb))
    elif budget >= 2 ** k + 2 * k + 5:
        op, n, rc = "central_composite", 2 ** k + 2 * k + 5, 5
        why.append("Central composite on %d continuous factors uses ~%d runs "
                   "(corners + axials + 5 centre)." % (k, n))
    elif k >= 3:
        op, n, rc = "definitive_screening", 2 * k + 1, 0
        why.append("Budget (%d) is too small for a Box-Behnken/CCD; "
                   "definitive screening fits %d runs and still detects main "
                   "effects + curvature." % (budget, n))
    else:
        op, n, rc = "full_factorial", 3 ** k, 0
        why.append("Few factors \u2014 a 3-level full factorial on %d factors "
                   "uses %d runs and supports a quadratic." % (k, n))
    print("\n=== Suggestion ===")
    print("  operation        : %s" % op)
    print("  estimated runs   : %d" % n)
    if rc:
        print("  replicate_center : %d" % rc)
    for w in why:
        print("  - %s" % w)
    sys.exit(0)
cfg = json.load(open(opt("--config")))
out = cfg["settings"]["out_directory"]
op = cfg["settings"].get("operation", "full_factorial")
if a[0] == "generate":
    import random
    names = [f["name"] for f in cfg["factors"]]
    if op == "plackett_burman":
        base = [tuple(f["levels"][int(hi)] for f, hi in zip(cfg["factors"], r))
                for r in pbdesign(len(names))]
    elif op in ("central_composite", "box_behnken"):
        # pyDOE3's face-centred ccdesign(k, center=(4, 4)) and
        # bbdesign(k, center=3), decoded as doe/design.py does
        k = len(names)
        if op == "central_composite":
            coded = [list(c) for c in itertools.product((-1, 1), repeat=k)]
            coded += [[0] * k] * 4
            for i in range(k):
                for s in (-1, 1):
                    coded.append([s if j == i else 0 for j in range(k)])
            coded += [[0] * k] * 4
        else:
            coded = []
            for i, j in itertools.combinations(range(k), 2):
                for si, sj in itertools.product((-1, 1), repeat=2):
                    c = [0] * k
                    c[i], c[j] = si, sj
                    coded.append(c)
            coded += [[0] * k] * 3
        def dec(c, f):
            lo, hi = float(f["levels"][0]), float(f["levels"][1])
            v = (lo + hi) / 2.0 + c * (hi - lo) / 2.0
            if op == "central_composite" and all(
                    float(x).is_integer() for x in f["levels"]):
                return str(int(round(v)))
            return "%.6g" % v
        base = [tuple(dec(c, f) for c, f in zip(row, cfg["factors"]))
                for row in coded]
    else:
        base = list(itertools.product(*[f["levels"] for f in cfg["factors"]]))
    # the run order is shuffled within each block, as the real one does,
    # and the same for the same --seed
    rnd = random.Random(int(opt("--seed"))) if opt("--seed") else random.Random()
    runs = []
    for b in range(int(cfg["settings"].get("block_count", 1))):
        order = list(base)
        rnd.shuffle(order)
        for combo in order:
            runs.append({"run_id": len(runs) + 1, "block_id": b + 1,
                         "factor_values": dict(zip(names, combo)),
                         "whole_plot_id": 0})
    if not os.path.isdir(out):
        os.makedirs(out)
    json.dump({"factor_names": names, "operation": op,
               "metadata": {}, "runs": runs},
              open(os.path.join(out, "design_matrix.json"), "w"))
    open(opt("--output"), "w").write("#!/bin/sh\n")
    print("Generated %d runs" % len(runs))
elif a[0] == "analyze":
    d = opt("--results-dir")
    m = json.load(open(os.path.join(d, "design_matrix.json")))
    got = [r for r in m["runs"]
           if os.path.exists(os.path.join(d, "run_%d.json" % r["run_id"]))]
    if len(got) < len(m["runs"]):
        print("Partial mode: analyzing %d/%d completed runs"
              % (len(got), len(m["runs"])))
    log = open(os.path.join(os.path.dirname(sys.argv[0]), "doe-values"), "a")
    surfaced = []
    for resp in [r["name"] for r in cfg["responses"]]:
        vals = {}
        for r in got:
            v = json.load(open(os.path.join(d, "run_%d.json" % r["run_id"])))
            if resp in v:
                vals[r["run_id"]] = v[resp]
                log.write("%s %d %r\n" % (resp, r["run_id"], v[resp]))
        print("=== Main Effects: %s ===" % resp)
        eff = []
        for f in m["factor_names"]:
            lv = sorted(set(r["factor_values"][f] for r in m["runs"]), key=key)
            mean = []
            for l in lv:
                xs = [vals[r["run_id"]] for r in m["runs"]
                      if r["factor_values"][f] == l and r["run_id"] in vals]
                mean.append(sum(xs) / len(xs))
            eff.append((f, mean[-1] - mean[0]))
        total = sum(abs(e) for _, e in eff) or 1.0
        eff.sort(key=lambda fe: abs(fe[1]), reverse=True)
        for f, e in eff:
            print("%-20s %10.4f" % (f, e))
        if opt("--csv"):
            if not os.path.isdir(opt("--csv")):
                os.makedirs(opt("--csv"))
            w = csv.writer(open(os.path.join(
                opt("--csv"), "main_effects_%s.csv" % resp), "w"))
            w.writerow(["factor_name", "main_effect", "std_error",
                        "pct_contribution", "ci_low", "ci_high"])
            for f, e in eff:
                w.writerow([f, e, 0.0, abs(e) / total * 100, 0.0, 0.0])
        # a design with a middle level gets doe's quadratic surface: its
        # lack of fit (where points repeat), adequacy, stationary point
        q = quad(m, cfg, vals)
        if q is None:
            continue
        surfaced.append(resp)
        groups = {}
        for r, yv in zip(q["rows"], q["y"]):
            groups.setdefault(tuple(sorted(r["factor_values"].items())),
                              []).append(yv)
        pe = sum(sum((v - sum(g) / len(g)) ** 2 for v in g)
                 for g in groups.values())
        df_pe = len(q["y"]) - len(groups)
        df_lof = len(groups) - len(q["terms"])
        print("\n=== ANOVA Table: %s ===" % resp)
        if df_pe > 0 and df_lof > 0 and pe > 0:
            f_lof = ((q["ss_res"] - pe) / df_lof) / (pe / df_pe)
            # not doe's F test: a p that falls as F grows, for the suite
            print("%-25s %4d %12.4f %12.4f %10.3f %10.4f" % (
                "Lack of Fit", df_lof, q["ss_res"] - pe,
                (q["ss_res"] - pe) / df_lof, f_lof, 2.718281828 ** -f_lof))
        sp = stationary(q)
        if not opt("--csv"):
            continue
        n = len(q["y"])
        w = csv.writer(open(os.path.join(
            opt("--csv"), "model_adequacy_%s.csv" % resp), "w"))
        w.writerow(["metric", "value"])
        for k_, v_ in (("model_type", "quadratic"), ("n_observations", n),
                       ("n_parameters", len(q["terms"])),
                       ("r_squared", q["r2"]), ("adj_r_squared", q["adj"]),
                       ("predicted_r_squared",
                        1 - q["press"] / q["ss_tot"] if q["ss_tot"] else 0),
                       ("press", q["press"])):
            w.writerow([k_, v_])
        w = csv.writer(open(os.path.join(
            opt("--csv"), "cross_validation_%s.csv" % resp), "w"))
        w.writerow(["scope", "fold", "run_id", "predicted", "actual",
                    "absolute_error"])
        w.writerow(["rmse_cv", "", "", (q["press"] / n) ** 0.5, "", ""])
        if sp is None:
            continue
        w = csv.writer(open(os.path.join(
            opt("--csv"), "stationary_point_%s.csv" % resp), "w"))
        w.writerow(["metric", "value"])
        w.writerow(["nature", sp["kind"]])
        w.writerow(["predicted_value", sp["value"]])
        w.writerow(["inside_design_region", sp["inside"]])
        w.writerow(["eigenvalues", ""])
        for f in q["fs"]:
            w.writerow(["coded[%s]" % f, sp["coded"][f]])
            w.writerow(["natural[%s]" % f, natural(q, f, sp["coded"][f])])
    # its plots and HTML report, unless told not to, where the real one
    # puts them: settings.processed_directory, else the results
    keep = cfg["settings"].get("processed_directory") or d
    names_ = [r["name"] for r in cfg["responses"]]
    if "--no-plots" not in a:
        for resp in names_:
            open(os.path.join(keep, "main_effects_%s.png" % resp),
                 "wb").write(b"\x89PNG\r\n\x1a\n")
        # and a surface plot of each pair, where it fitted a quadratic
        for resp in surfaced:
            for p_, q_ in itertools.combinations(m["factor_names"], 2):
                open(os.path.join(keep, "rsm_%s_%s_vs_%s.png" % (resp, p_, q_)),
                     "wb").write(b"\x89PNG\r\n\x1a\n")
    if "--no-report" not in a:
        open(os.path.join(keep, "report.html"), "w").write(
            "<html><body><h1>DOE report: %s</h1></body></html>\n"
            % ", ".join(names_))
        print("\nHTML report: %s" % os.path.join(keep, "report.html"))
elif a[0] == "optimize" and "--steepest" in a:
    # doe optimize --steepest (doe/rsm.py steepest_ascent): the linear
    # model's gradient in coded units, scaled so the factor that moves most
    # moves half a unit a step, ten steps, each decoded to six figures
    d = opt("--results-dir")
    m = json.load(open(os.path.join(d, "design_matrix.json")))
    for r in cfg["responses"]:
        vals = {}
        for run in m["runs"]:
            p = os.path.join(d, "run_%d.json" % run["run_id"])
            if os.path.exists(p) and r["name"] in json.load(open(p)):
                vals[run["run_id"]] = json.load(open(p))[r["name"]]
        if not vals:
            continue
        lin = quad(m, cfg, vals, linear=True)
        if lin is None:
            continue
        b = dict(zip(lin["terms"], lin["beta"]))
        fs = m["factor_names"]
        g = [b.get(f, 0.0) for f in fs]
        if r.get("optimize") == "minimize":
            g = [-x for x in g]
        top = max(abs(x) for x in g)
        print("\n=== Steepest %s: %s ===" % (
            "Ascent" if r.get("optimize", "maximize") == "maximize"
            else "Descent", r["name"]))
        print("%-6s" % "Step" + "".join("%14s" % f for f in fs)
              + "%14s" % "Predicted")
        print("-" * (6 + 14 * (len(fs) + 1)))
        if top == 0:
            continue
        for step in range(11):
            c = [x / top * step * 0.5 for x in g]
            pv = b["intercept"] + sum(b.get(f, 0.0) * x for f, x in zip(fs, c))
            print("%-6d" % step + "".join(
                "%14s" % natural(lin, f, x) for f, x in zip(fs, c))
                + "%14.4f" % pv)
elif a[0] == "next-batch":
    # doe next-batch: refine perturbs the largest value seen (whatever the
    # response's direction, as doe/adaptive.py does) within a quarter of
    # each factor's range; model_guided (and bayesian, here) puts the
    # model's best point inside the region first, then points spread over
    # it.  The runs are appended to the design matrix, as doe does.
    import random
    d = opt("--results-dir")
    m = json.load(open(os.path.join(d, "design_matrix.json")))
    r = cfg["responses"][0]
    vals = {}
    for run in m["runs"]:
        p = os.path.join(d, "run_%d.json" % run["run_id"])
        if os.path.exists(p) and r["name"] in json.load(open(p)):
            vals[run["run_id"]] = json.load(open(p))[r["name"]]
    rnd = random.Random(int(opt("--seed") or 0))
    n = int(opt("--batch-size") or 4)
    facs = dict((f["name"], f) for f in cfg["factors"])
    fs = m["factor_names"]
    def span(f):
        lv = [float(x) for x in facs[f]["levels"]]
        return lv[0], lv[1]
    new = []
    if (opt("--strategy") or "refine") == "refine":
        best = max(vals, key=lambda k: vals[k])
        brun = [x for x in m["runs"] if x["run_id"] == best][0]
        for _ in range(n):
            fv = {}
            for f in fs:
                lo, hi = span(f)
                c, h = float(brun["factor_values"][f]), (hi - lo) * 0.25
                fv[f] = "%.6g" % rnd.uniform(max(lo, c - h), min(hi, c + h))
            new.append(fv)
    else:
        q = quad(m, cfg, vals) or quad(m, cfg, vals, linear=True)
        sign = -1 if r.get("optimize") == "minimize" else 1
        grid = [-1 + 2.0 * i / 40 for i in range(41)]
        top = max((dict(zip(fs, c)) for c in itertools.product(
            grid, repeat=len(fs))), key=lambda c: sign * q["predict"](c))
        new.append(dict((f, natural(q, f, top[f])) for f in fs))
        while len(new) < n:
            new.append(dict((f, "%.6g" % rnd.uniform(*span(f))) for f in fs))
    k = max(x["run_id"] for x in m["runs"])
    for i, fv in enumerate(new):
        m["runs"].append({"run_id": k + 1 + i, "block_id": 1,
                          "factor_values": fv, "whole_plot_id": 0})
    json.dump(m, open(os.path.join(cfg["settings"]["out_directory"],
                                   "design_matrix.json"), "w"))
    open(opt("--output"), "w").write("#!/bin/sh\n")
    print("Phase 1: generated %d new runs -> %s" % (len(new), opt("--output")))
    print("Design matrix updated: %d total runs" % len(m["runs"]))
elif a[0] == "optimize":
    # doe optimize's text: the linear and quadratic models' coefficients,
    # and the best point inside the region (a fine grid, where doe uses
    # L-BFGS-B)
    d = opt("--results-dir")
    m = json.load(open(os.path.join(d, "design_matrix.json")))
    for r in cfg["responses"]:
        vals = {}
        for run in m["runs"]:
            p = os.path.join(d, "run_%d.json" % run["run_id"])
            if os.path.exists(p) and r["name"] in json.load(open(p)):
                vals[run["run_id"]] = json.load(open(p))[r["name"]]
        print("=== Optimization: %s ===" % r["name"])
        print("Direction: %s\n" % r.get("optimize", "maximize"))
        lin, q = quad(m, cfg, vals, linear=True), quad(m, cfg, vals)
        for label, mod in (("linear", lin), ("quadratic", q)):
            if mod is None:
                continue
            print("RSM Model (%s, R² = %.4f, Adj R² = %.4f):"
                  % (label, mod["r2"], mod["adj"]))
            print("  Coefficients:")
            for t, b in zip(mod["terms"], mod["beta"]):
                print("    %-30s %s%.4f" % (t, "+" if b >= 0 else "", b))
            print()
        best = q if q and (lin is None or q["adj"] > lin["adj"]) else lin
        if best is None:
            continue
        fs = best["fs"]
        n = {1: 400, 2: 100, 3: 20}.get(len(fs), 8)
        grid = [-1 + 2.0 * i / n for i in range(n + 1)]
        sign = -1 if r.get("optimize") == "minimize" else 1
        top = max((dict(zip(fs, c)) for c in itertools.product(
            grid, repeat=len(fs))), key=lambda c: sign * best["predict"](c))
        print("  Surface optimum (via L-BFGS-B, %s model):"
              % ("quadratic" if best is q else "linear"))
        for f in fs:
            print("    %s = %s" % (f, natural(best, f, top[f])))
        print("    Predicted value: %.4f\n" % best["predict"](top))
EOF
    chmod +x "$FAKE_BIN/doe"
    export QD_DOE="$FAKE_BIN/doe"
}

# -- a stand-in fio ------------------------------------------------------------

# fio, for the suites: reads the options qd's fio screen gives it and
# prints fio 3.36's --output-format=json, its numbers a known function of
# the options, so a screen's analysis must find exactly these:
#   read IOPS   20000 + 30000 at iodepth 32 - 15000 at bs 128k
#   write IOPS   8000 + 12000 at numjobs 8  -  5000 at rwmixread 70
#   bandwidth   IOPS x bs
#   read clat   mean 50us + 400 at iodepth 32 + 100 at numjobs 8;
#               p99 200us + 3000 for randrw + 1200 with libaio
#   write clat  mean 80us + 500 at numjobs 8;
#               p99 300us + 2500 buffered (direct=0) + 900 for randrw
# FIO_PEAK=iodepth=D,numjobs=J: read IOPS 90000 - 50 (iodepth-D)^2 -
# 1500 (numjobs-J)^2, a maximum at (D, J), and read clat's mean 100us +
# 0.5 (iodepth-D)^2 + 20 (numjobs-J)^2, a minimum there: a known surface,
# give or take a little noise.  FIO_PEAK=...,scale=S multiplies the
# squares by S: 0.2 keeps read IOPS above 0 over a whole fio screen
# (iodepth 1, numjobs 1), as a real drive's is (test_fio_study.sh).
# FIO_FAIL=TEXT: a job error (err=22) and exit 1 when the arguments contain
# TEXT, its JSON printed all the same, every figure 0 -- as fio does.
# FIO_INTERRUPT=N:PIDFILE (with FIO_PEAK): the Nth call sends SIGINT to
# the process whose id is in PIDFILE, as Ctrl-C would.
stand_in_fio() {
    cat > "$FAKE_BIN/fio" <<'EOF'
#!/usr/bin/env python3
import json, os, sys
o = {}
for x in sys.argv[1:]:
    if x.startswith("--"):
        k, _, v = x[2:].partition("=")
        o[k] = v
def num(k, d):
    v = o.get(k, d).lower().rstrip("kib")
    return float(v)
bs, depth, jobs = num("bs", "4k"), num("iodepth", "1"), num("numjobs", "1")
mix = num("rwmixread", "50")
fail = os.environ.get("FIO_FAIL")
err = 22 if fail and fail in " ".join(sys.argv[1:]) else 0
r_iops = 20000 + 30000 * (depth >= 32) - 15000 * (bs >= 128)
peak = dict(kv.split("=") for kv in os.environ.get("FIO_PEAK", "").split(",")
            if "=" in kv)
w_iops = 8000 + 12000 * (jobs >= 8) - 5000 * (mix >= 70)
r_mean = 50 + 400 * (depth >= 32) + 100 * (jobs >= 8)
r_p99 = 200 + 3000 * (o.get("rw") == "randrw") + 1200 * (o.get("ioengine") == "libaio")
w_mean = 80 + 500 * (jobs >= 8)
w_p99 = 300 + 2500 * (o.get("direct") == "0") + 900 * (o.get("rw") == "randrw")
if peak:
    # FIO_PEAK=iodepth=D,numjobs=J: read IOPS a smooth hill whose top is at
    # (D, J), read clat's mean a bowl whose bottom is there; each run's
    # noise -40..+40 IO/s and -0.4..+0.4us, in turn, so repeated points
    # differ as real ones do
    calls = os.path.join(os.path.dirname(os.path.abspath(sys.argv[0])),
                         "fio-calls")
    k = len(open(calls).read()) if os.path.exists(calls) else 0
    open(calls, "a").write(".")
    # FIO_INTERRUPT=N:PIDFILE: the Nth call sends SIGINT to the process
    # whose id PIDFILE holds (qd, interrupted mid-run as Ctrl-C would)
    stop = os.environ.get("FIO_INTERRUPT", "")
    if stop and k + 1 == int(stop.split(":", 1)[0]):
        import signal
        os.kill(int(open(stop.split(":", 1)[1]).read()), signal.SIGINT)
    dd, jj = depth - float(peak["iodepth"]), jobs - float(peak["numjobs"])
    sc = float(peak.get("scale", "1"))
    r_iops = 90000 - sc * (50 * dd ** 2 + 1500 * jj ** 2) + 20 * (k % 5 - 2)
    r_mean = 100 + sc * (0.5 * dd ** 2 + 20 * jj ** 2) + 0.2 * (k % 5 - 2)
def side(iops, mean_us, p99_us):
    if err:
        iops = mean_us = p99_us = 0
    bw = iops * bs
    st = lambda us: {"min": int(us * 500), "max": int(us * 3000),
                     "mean": us * 1000.0, "stddev": us * 100.0, "N": int(iops * 30)}
    clat = st(mean_us)
    clat["percentile"] = {"1.000000": int(mean_us * 300),
                          "50.000000": int(mean_us * 1000),
                          "99.000000": int(p99_us * 1000),
                          "99.900000": int(p99_us * 1500)}
    return {"io_bytes": int(bw * 1024 * 30), "io_kbytes": int(bw * 30),
            "bw_bytes": int(bw * 1024), "bw": int(bw), "iops": float(iops),
            "runtime": 30000, "total_ios": int(iops * 30), "short_ios": 0,
            "drop_ios": 0, "slat_ns": st(2), "clat_ns": clat,
            "lat_ns": st(mean_us + 2), "bw_min": int(bw * 0.9),
            "bw_max": int(bw * 1.1), "bw_mean": float(bw),
            "iops_min": int(iops * 0.9), "iops_max": int(iops * 1.1),
            "iops_mean": float(iops)}
job = {"jobname": o.get("name", "fio"), "groupid": 0, "error": err,
       "eta": 0, "elapsed": 31,
       "job options": dict((k, v) for k, v in o.items()
                           if k not in ("output-format",)),
       "read": side(r_iops, r_mean, r_p99),
       "write": side(w_iops, w_mean, w_p99),
       "usr_cpu": 5.1, "sys_cpu": 20.3, "ctx": 100000, "majf": 0, "minf": 50}
n = 1 if "group_reporting" in o else int(jobs)
print(json.dumps({"fio version": "fio-3.36", "timestamp": 1751880000,
                  "time": "Mon Jul  7 10:00:00 2025",
                  "jobs": [dict(job, jobname="%s" % job["jobname"])
                           for _ in range(n)]}, indent=2))
if err:
    sys.stderr.write("fio: pid=4242, err=22/file:filesetup.c:805, "
                     "func=open(%s), error=Invalid argument\n"
                     % o.get("filename", "?"))
    sys.exit(1)
EOF
    chmod +x "$FAKE_BIN/fio"
    export PATH="$FAKE_BIN:$PATH"
}

# -- a response surface design -----------------------------------------------

# a face-centred central composite named ccd on iodepth 4..36 and numjobs
# 1..9 (the centre 20, 5), its points run on host a by stand_in_fio with
# FIO_PEAK=$1: a known surface for doe to fit (test_doe_surface.sh, and
# test_web.sh's /api/surface); with $2, a design of the study $2
# (metadata.qd_study), as a screen's follow-up is
surface_design() {
    stand_in_fio
    install_fake_ssh
    fake_host a
    echo a > hosts.txt
    cat > ccd.json <<'JSON'
{
  "metadata": {
    "name": "ccd",
    "qd_command": "fio --name=qd --filename={filename} --size=1G --time_based --runtime=5 --group_reporting --output-format=json --rw=randrw --rwmixread=50 --bs=4k --iodepth={iodepth} --numjobs={numjobs} --ioengine=libaio --direct=1",
    "qd_follows": {"design": "screen", "response": "read_iops",
                   "column": "jobs.0.read.iops", "optimize": "maximize"}
  },
  "factors": [
    {"name": "iodepth", "levels": ["4", "36"], "type": "continuous"},
    {"name": "numjobs", "levels": ["1", "9"], "type": "continuous"}
  ],
  "fixed_factors": {"filename": "/srv/scratch/qd-fio.dat"},
  "responses": [
    {"name": "read_iops", "column": "jobs.0.read.iops", "optimize": "maximize"},
    {"name": "read_lat_mean", "column": "jobs.0.read.clat_ns.mean", "optimize": "minimize"}
  ],
  "settings": {"operation": "central_composite", "block_count": 1}
}
JSON
    if [ -n "${2:-}" ]; then
        "$PY" - "$2" <<'PYEOF'
import json, sys
c = json.load(open("ccd.json"))
c["metadata"]["qd_study"] = sys.argv[1]
json.dump(c, open("ccd.json", "w"), indent=2)
PYEOF
    fi
    # FIO_FAIL (stand_in_fio) fails a point: its run exits 1, and it stays
    # not measured
    FIO_PEAK="$1" qdf_rc doe run ccd.json -s hosts.txt -q > /dev/null
}
