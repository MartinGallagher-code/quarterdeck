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
    TEST_TMPDIR="$(mktemp -d "${tmp%/}/qd-test.XXXXXX")"
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
    # its plots and HTML report, unless told not to, where the real one
    # puts them: settings.processed_directory, else the results
    keep = cfg["settings"].get("processed_directory") or d
    names_ = [r["name"] for r in cfg["responses"]]
    if "--no-plots" not in a:
        for resp in names_:
            open(os.path.join(keep, "main_effects_%s.png" % resp),
                 "wb").write(b"\x89PNG\r\n\x1a\n")
    if "--no-report" not in a:
        open(os.path.join(keep, "report.html"), "w").write(
            "<html><body><h1>DOE report: %s</h1></body></html>\n"
            % ", ".join(names_))
        print("\nHTML report: %s" % os.path.join(keep, "report.html"))
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
# FIO_FAIL=TEXT: a job error (err=22) and exit 1 when the arguments contain
# TEXT, its JSON printed all the same, every figure 0 -- as fio does.
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
w_iops = 8000 + 12000 * (jobs >= 8) - 5000 * (mix >= 70)
r_mean = 50 + 400 * (depth >= 32) + 100 * (jobs >= 8)
r_p99 = 200 + 3000 * (o.get("rw") == "randrw") + 1200 * (o.get("ioengine") == "libaio")
w_mean = 80 + 500 * (jobs >= 8)
w_p99 = 300 + 2500 * (o.get("direct") == "0") + 900 * (o.get("rw") == "randrw")
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
