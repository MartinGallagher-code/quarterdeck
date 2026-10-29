# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Martin J. Gallagher
#
# test_helper.bash -- shared harness for quarterdeck's suites.
#
# Sourced by every test_*.sh.  Provides:
#   run_test NAME FN        run one case in a subshell with a fresh temp dir
#   assert_eq/contains/not_contains/status/file_exists/no_file
#   fail MSG                fail a case with a reason no assert_ covers
#   qd ARGS...              the CLI under test, run from a clone
#   install_fake_ssh        an ssh+scp pair that run "remote" commands locally
#   fake_host NAME          a sandbox root for one fake host
#   fake_host_unreachable NAME
#
# The harness is binnacle's (tests/test_helper.bash there), trimmed to what
# these suites use: every case runs in a subshell, so one failed assertion
# cannot abort the rest of the file, and each gets its own $TEST_TMPDIR.

QD_DIR="${QD_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
PY="${PY:-python3}"

TESTS_RUN=0
TESTS_FAILED=0
FAILED_NAMES=()

setup_env() {
    TEST_TMPDIR="$(mktemp -d "${TMPDIR:-/tmp}/qd-test.XXXXXX")"
    export TEST_TMPDIR
    export FAKE_BIN="$TEST_TMPDIR/bin"
    export FAKE_ROOT="$TEST_TMPDIR/hosts"
    export FAKE_SSH_LOG="$TEST_TMPDIR/ssh.log"
    mkdir -p "$FAKE_BIN" "$FAKE_ROOT"
    : > "$FAKE_SSH_LOG"
    # A stray variable from the caller's shell must never change a result.
    unset QD_LOGBOOK QD_SERVERS QD_JOBS QD_TIMEOUT QD_SSH QD_SCP QD_SSH_USER
    unset QD_REMOTE_DIR QD_PARSE QD_MAX_OUTPUT QD_Z QD_ASCII QD_MANIFEST
    unset QD_MX QD_IPERF_ORCHESTRATOR QD_AGREE QD_DCVIZ QD_WEB_HOST
    unset QD_WEB_PORT QD_TEST_KEYS QD_TEST_SCREEN
    export LANG=C
    cd "$TEST_TMPDIR" || return 1
}

teardown_env() {
    if [ -f "$TEST_TMPDIR/web.pid" ]; then
        kill "$(cat "$TEST_TMPDIR/web.pid")" 2>/dev/null || true
    fi
    cd / || true
    [ -n "$TEST_TMPDIR" ] && rm -rf "$TEST_TMPDIR"
}

run_test() {
    local name="$1"; shift
    TESTS_RUN=$((TESTS_RUN + 1))
    local out rc
    out="$(
        setup_env
        trap teardown_env EXIT
        set -e
        "$@" 2>&1
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

# -- fake ssh / scp ---------------------------------------------------------
#
# The shim runs the "remote" command locally inside $FAKE_ROOT/<host>, so a
# whole fan-out can be exercised with no network and no second machine.
# Every invocation is logged so a case can assert what was invoked.

install_fake_ssh() {
    cat > "$FAKE_BIN/ssh" <<'SHIM'
#!/bin/bash
args=(); host=""
while [ $# -gt 0 ]; do
  case "$1" in
    -o) shift 2;;
    -p) shift 2;;
    *) if [ -z "$host" ]; then host="$1"; else args+=("$1"); fi; shift;;
  esac
done
host="${host#*@}"
printf 'ssh %s %s\n' "$host" "${args[*]}" >> "$FAKE_SSH_LOG"
if [ -f "$FAKE_ROOT/$host/.unreachable" ]; then
  echo "ssh: connect to host $host port 22: Connection timed out" >&2
  exit 255
fi
[ -d "$FAKE_ROOT/$host" ] || { echo "ssh: Could not resolve hostname $host" >&2; exit 255; }
cd "$FAKE_ROOT/$host" || exit 255
export FAKE_HOST="$host"
exec bash -c "${args[*]}"
SHIM
    cat > "$FAKE_BIN/scp" <<'SHIM'
#!/bin/bash
args=()
while [ $# -gt 0 ]; do
  case "$1" in
    -o) shift 2;; -P) shift 2;; -q) shift;;
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
