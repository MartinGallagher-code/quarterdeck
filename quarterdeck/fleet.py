# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Martin J. Gallagher
"""Running one command on many hosts and keeping every answer.

canonical copy of the runner: binnacle/agree.py Runner and fan_out().  The
transport, the bounded capture and the failure classes are agree's, so
`unreachable` means the same thing in a quarterdeck dataset as in an agree
group.  What differs is what is kept: agree compares the answers, this
keeps them -- raw, per host, in host-list order -- so they can be parsed
into columns and read back later.  Stopping a command on the host when
qd gives up on it (QD-026) is this copy's only: binnacle's BN-004 is to
take it into agree.
"""

import os
import re
import secrets
import selectors
import shlex
import shutil
import subprocess
import sys
import tempfile
import threading
import time
from concurrent.futures import ThreadPoolExecutor

SSH_OPTS = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=8",
            "-o", "StrictHostKeyChecking=accept-new"]

# --reuse's control sockets.  A socket's path must fit sun_path: 108
# bytes on Linux, 104 on macOS and the BSDs (the smaller is the limit
# here).  A master binds at ControlPath plus "." and 16 random characters
# and renames it after, and %C is 40, so the directory gets what is left.
SUN_PATH = 104
CONTROL_TAIL = len("/") + 40 + len(".") + 16 + 1    # and the NUL
CONTROL_PERSIST = 60

# The file in every directory qd makes on a host, holding the run's id.
SENTINEL = ".qd-owned"

OK, FAILED, TIMEOUT, UNREACHABLE, PUSH_FAILED = (
    "ok", "failed", "timeout", "unreachable", "push-failed")

# Stopping a command on the host (QD-026).  qd's ssh asks for no terminal,
# so when qd kills its ssh -- past --timeout or --max-output -- sshd does
# not hang the command up: it goes on running on the host (pdsh, pssh and
# parallel-ssh say the same of theirs).  So every command goes out after
# one line to stderr, MARK_SH, naming the shell sshd started for it and
# that shell's process group, and _exec takes the line off again.  sshd
# starts that shell in a session of its own, so the group holds the
# command and everything it started; Runner.stop sends it TERM, then KILL,
# with a second ssh.  The line is written by `sh -c`, so the login shell
# may be any shell, and only builtins run in it: nothing else is started.
# Its group is read from /proc where there is one; a shell that does not
# lead its own group (an sshd that does not start a session) is never
# signalled, since its group is someone else's.
MARK_SH = ("p=$PPID; g=$p; s=; { read -r s < /proc/$p/stat; } 2>/dev/null "
           "&& { s=${s##*) }; set -- $s; g=$3; }; echo %s $p $g >&2")

# Most of a minute: the 8 s to connect, and a few seconds for TERM to
# work, then KILL.
STOP_TIMEOUT = 30

# The stop, on the host: TERM to the group, then KILL if any of it is
# still there 2 s later.  A group that is gone is stopped; one whose
# members are not this user's to signal (a command that ran sudo itself)
# is still running, and kill says "Operation not permitted" of it, which
# LC_ALL=C keeps in English.  Exit 0 when nothing of it is left, 4 when
# some of it is.  Never 0 or 1 as the group: `kill -- -1` is every process.
STOP_SH = (
    "LC_ALL=C; export LC_ALL; p=%d; [ \"$p\" -gt 1 ] || exit 3; "
    "alive() { e=$(kill -s 0 -- -$p 2>&1) && return 0; "
    "case $e in *ermi*) return 0 ;; esac; return 1; }; "
    "if sleep 0.1 2>/dev/null; then d=0.1 n=20; else d=1 n=2; fi; "
    "wait_gone() { i=0; while alive; do [ $i -lt $n ] || return 1; "
    "sleep $d; i=$((i + 1)); done; }; "
    "alive || exit 0; "
    "kill -s TERM -- -$p 2>/dev/null; wait_gone && exit 0; "
    "kill -s KILL -- -$p 2>/dev/null; wait_gone && exit 0; "
    "echo 'qd: still running after TERM and KILL' >&2; exit 4")


class TimedOut(int):
    """qd's own timeout, 124 as `timeout` says it, but told apart from a
    command on the host that exited 124 itself (`timeout 5 check` does):
    that host answered."""


class Flooded(int):
    """Past --max-output, 125, told apart from a command that exited 125
    itself, as TimedOut is."""


class Result(object):
    __slots__ = ("host", "outcome", "rc", "stdout", "stderr", "duration",
                 "started", "pass_no", "left_running")

    def __init__(self, host, pass_no=1):
        self.host = host
        self.outcome = OK
        self.rc = 0
        self.stdout = ""
        self.stderr = ""
        self.duration = 0.0
        self.started = time.time()
        self.pass_no = pass_no
        # qd gave up on the command and could not confirm it stopped on
        # the host: it may still be running there
        self.left_running = False

    def error(self):
        """The first line of what went wrong, for a column."""
        if self.outcome == OK:
            return ""
        for ln in (self.stderr or "").splitlines():
            if ln.strip():
                return ln.strip()[:200]
        return "exit %d" % self.rc


def control_dir(bases=None):
    """A new directory for --reuse's sockets, private to this user (mkdtemp
    makes it 0700), in the first of `bases` short enough for a socket path:
    TMPDIR, then /tmp (macOS's TMPDIR, /var/folders/..., is too long).
    -> the path, or None when none is short enough or writable."""
    if bases is None:
        bases = [tempfile.gettempdir(), "/tmp"]
    seen = set()
    for base in bases:
        if not base or base in seen or not os.path.isdir(base):
            continue
        seen.add(base)
        # mkdtemp's name is the prefix and 8 characters
        if len(base.rstrip("/")) + len("/qd-ssh-12345678") + CONTROL_TAIL \
                > SUN_PATH:
            continue
        try:
            return tempfile.mkdtemp(prefix="qd-ssh-", dir=base)
        except OSError:
            continue
    return None


class Reuse(object):
    """--reuse: one ssh connection to each host for the whole qd command,
    shared by every ssh and scp to it -- a push's four or five, every
    pass, every run of a `qd probe A B`.  OpenSSH's ControlMaster does it: the first call to
    a host opens a master, the rest ride on it.  The sockets live in a
    private directory of this command's own, named by %C (a hash of the
    host, port and user), and close() shuts every master and removes the
    directory when the command ends, however it ends."""

    def __init__(self, persist=CONTROL_PERSIST, bases=None):
        # how long an idle master waits for the next call: a pass every S
        # seconds keeps it for the next pass
        self.persist = max(1, int(persist))
        self._bases = bases
        self.dir = None
        # reentrant: close() runs from a signal handler too, on the main
        # thread, which may hold it at that moment
        self._lock = threading.RLock()
        self._hosts = {}        # (ssh argv, target, port): None
        self._closed = False

    def directory(self):
        """The socket directory, made the first time it is asked for."""
        with self._lock:
            if self.dir is None:
                self.dir = control_dir(self._bases)
                if self.dir is None:
                    raise OSError(
                        "no directory short enough for ssh's control "
                        "sockets (%d bytes at most): point TMPDIR at a short "
                        "one, such as /tmp" % SUN_PATH)
            return self.dir

    def options(self):
        return ["-o", "ControlMaster=auto",
                "-o", "ControlPath=%s/%%C" % self.directory(),
                "-o", "ControlPersist=%d" % self.persist]

    def used(self, argv, target, port):
        """A host this command connected to: its master is closed after."""
        with self._lock:
            self._hosts[(tuple(argv), target, port)] = None

    def close(self, jobs=32, timeout=10):
        """Every master closed (`ssh -O exit`, which contacts no host: it
        talks to the local socket), then the directory removed.  Never
        raises; safe to call twice."""
        with self._lock:
            if self._closed or self.dir is None:
                self._closed = True
                return
            self._closed = True
            hosts = list(self._hosts)
        try:
            masters = bool(os.listdir(self.dir))
        except OSError:
            masters = False

        def stop(key):
            argv, target, port = key
            cmd = list(argv) + (["-p", str(port)] if port else []) + \
                ["-O", "exit", target]
            try:
                subprocess.run(cmd, stdin=subprocess.DEVNULL,
                               stdout=subprocess.DEVNULL,
                               stderr=subprocess.DEVNULL, timeout=timeout)
            except (OSError, subprocess.SubprocessError):
                pass

        if masters and hosts:
            with ThreadPoolExecutor(
                    max_workers=max(1, min(jobs, len(hosts)))) as pool:
                list(pool.map(stop, hosts))
        shutil.rmtree(self.dir, ignore_errors=True)

    def close_on_signals(self):
        """A TERM or HUP (a timeout, a cancelled job, a closed terminal)
        still ends qd at once, as it always has, but closes the masters
        first: left alone they idle on for ControlPersist seconds.  A
        signal already ignored (nohup) stays ignored.  Only the main
        thread can set a handler; elsewhere this does nothing."""
        import signal

        def handler(signum, frame):
            self.close()
            os._exit(128 + signum)

        for name in ("SIGTERM", "SIGHUP"):
            sig = getattr(signal, name, None)
            if sig is None:
                continue
            try:
                if signal.getsignal(sig) == signal.SIG_DFL:
                    signal.signal(sig, handler)
            except (ValueError, OSError):
                pass


class Runner(object):
    def __init__(self, ssh="ssh", scp="scp", user=None, timeout=60,
                 max_output=4 * 1024 * 1024, remote_dir="/var/tmp",
                 sudo=False, ssh_config=None, reuse=None):
        self.ssh = shlex.split(ssh)
        self.scp = shlex.split(scp)
        # --ssh-config: ssh and scp alike read this file, not ~/.ssh/config
        self.ssh_config = ssh_config
        # a Reuse, shared by every Runner of one command, or None
        self.reuse = reuse
        self.user = user
        self.timeout = timeout
        self.max_output = max_output
        self.remote_dir = remote_dir
        # Pushed files go in a directory of this run's own under
        # --remote-dir, and only that is removed afterwards: never
        # --remote-dir itself (~/bin, say, and everything in it), nor a
        # directory another run or another user is working in.
        # The run id names the directory and is written into it, in
        # SENTINEL, when it is made: cleanup removes a directory only if
        # it is still this run's (see guarded_rm).
        self.run_id = secrets.token_hex(6)
        self.work_dir = "%s/qd.%s" % (remote_dir.rstrip("/"), self.run_id)
        # hosts where this run made the work directory, and where it made
        # --remote-dir too (so that is removed again, if it is empty)
        self._made = {}
        self.sudo = sudo
        # the line every command sends first (MARK_SH): this run's own, so
        # nothing a host prints can be taken for it
        self.mark = "qd.%s.pgid" % self.run_id
        self._mark_re = re.compile(
            b"(?m)^" + re.escape(self.mark.encode()) + b" ([0-9]+) ([0-9]+)\n")

    def target(self, host):
        return "%s@%s" % (self.user, host.addr) if self.user else host.addr

    def scp_target(self, host):
        addr = "[%s]" % host.addr if ":" in host.addr else host.addr
        return "%s@%s" % (self.user, addr) if self.user else addr

    def config_options(self):
        """-F FILE with --ssh-config: what ssh -G is given as well."""
        return ["-F", self.ssh_config] if self.ssh_config else []

    def ssh_options(self):
        """What every ssh and scp qd starts is given before the host: the
        config file, qd's own options, and --reuse's."""
        opts = self.config_options() + SSH_OPTS
        if self.reuse is not None:
            opts = opts + self.reuse.options()
        return opts

    def ssh_argv(self, host, command):
        argv = list(self.ssh) + self.ssh_options()
        if host.port:
            argv += ["-p", str(host.port)]
        return argv + [self.target(host), command]

    def _note_master(self, host):
        """With --reuse, a host this run connects to, so its master is
        closed when the command ends."""
        if self.reuse is not None:
            self.reuse.used(list(self.ssh) + self.ssh_options(),
                            self.target(host), host.port)

    def wrap(self, command):
        if self.sudo:
            return "sudo -n sh -c %s" % shlex.quote(command)
        return command

    def command_for(self, command, pushed=False, marked=True):
        """What runs on a host: beside the pushed files when there are any
        (so `--push x -- tool x` finds x), under `sudo -n` with --sudo,
        and after the line naming its process group (MARK_SH), which
        --dry-run leaves out (`marked`) so the command can be read."""
        if pushed:
            command = "cd %s && %s" % (shlex.quote(self.work_dir), command)
        if not marked:
            return self.wrap(command)
        return "sh -c %s; %s" % (shlex.quote(MARK_SH % self.mark),
                                 self.wrap(command))

    def _exec(self, argv, timeout, stdin=None):
        """Bounded capture: one host in a log storm must not sink the run.
        `stdin` is a local file fed to the command (a script for
        `python3 -`), else it reads nothing."""
        return self._capture(argv, timeout, stdin)[:3]

    def _capture(self, argv, timeout, stdin=None, marked=False):
        """_exec, and for a command sent by command_for (`marked`), the
        process group the host said it runs in, with that line taken off
        its stderr: -> (rc, stdout, stderr, group).  The group is None
        when the line never came, and 0 when the shell does not lead a
        group of its own.  Past the deadline rc is TimedOut, past
        --max-output Flooded; either way ssh is killed here, and the
        command is not."""
        limit = int(self.max_output)
        src = None
        try:
            src = open(stdin, "rb") if stdin else None
            p = subprocess.Popen(argv, stdout=subprocess.PIPE,
                                 stderr=subprocess.PIPE,
                                 stdin=src or subprocess.DEVNULL)
        except OSError as exc:
            # ssh (or scp) itself would not start: no host was reached
            return 255, "", "cannot run %s: %s" % (argv[0], exc), None
        finally:
            if src:
                src.close()
        chunks = {p.stdout: [], p.stderr: []}
        sizes = {p.stdout: 0, p.stderr: 0}
        deadline = time.monotonic() + timeout
        flooded = False
        # stderr is held here, uncounted, until the line naming the group
        # has come and been taken off (or 64 KiB came first, or it ended):
        # what is left counts against --max-output exactly as before
        head = [b""] if marked else None
        group = [None]

        def take(f, data):
            room = limit - sizes[f]
            if room > 0:
                chunks[f].append(data[:room])
            sizes[f] += len(data)
            return sizes[f] > limit

        def take_head(eof):
            buf = head[0]
            m = self._mark_re.search(buf)
            if m:
                pid, pgid = int(m.group(1)), int(m.group(2))
                # 0: the line came, but its shell leads no group of its own
                group[0] = pgid if pid == pgid > 1 else 0
                buf = buf[:m.start()] + buf[m.end():]
            elif not eof and len(buf) < 65536:
                return False
            head[0] = None
            return take(p.stderr, buf)

        sel = selectors.DefaultSelector()
        sel.register(p.stdout, selectors.EVENT_READ)
        sel.register(p.stderr, selectors.EVENT_READ)
        open_count = 2
        timed_out = False
        while open_count:
            left = deadline - time.monotonic()
            if left <= 0:
                timed_out = True
                break
            for key, _ in sel.select(left):
                f = key.fileobj
                chunk = os.read(f.fileno(), 65536)
                if not chunk:
                    sel.unregister(f)
                    open_count -= 1
                    if f is p.stderr and head and head[0] is not None:
                        flooded = take_head(True) or flooded
                    continue
                if f is p.stderr and head and head[0] is not None:
                    head[0] += chunk
                    flooded = take_head(False) or flooded
                    continue
                flooded = take(f, chunk) or flooded
            if flooded:
                break
        sel.close()
        if not timed_out and not flooded:
            try:
                rc = p.wait(timeout=max(1.0, deadline - time.monotonic()))
            except subprocess.TimeoutExpired:
                # both streams ended but ssh did not: the command closed
                # them and ran on, past the deadline
                timed_out = True
        if timed_out or flooded:
            p.kill()
            p.wait()
        for f in (p.stdout, p.stderr):
            f.close()

        def text(f):
            return b"".join(chunks[f]).decode("utf-8-sig", "replace")

        if timed_out and not flooded:
            return (TimedOut(124), "", "timed out after %ss" % timeout,
                    group[0])
        if flooded:
            return (Flooded(125), "", "output exceeded --max-output (%d "
                    "bytes)" % limit, group[0])
        return rc, text(p.stdout), text(p.stderr), group[0]

    def stop(self, host, group):
        """Stop a command qd gave up on, on the host: TERM to its process
        group, then KILL (STOP_SH), by a second ssh, under the same sudo
        as the command.  -> '' when nothing of it is left there, else why
        qd cannot say so."""
        if group is None:
            return ("it never said it had started there, so qd could not "
                    "stop it if it did")
        if not group:
            return ("its shell there leads no process group of its own, so "
                    "qd would not signal it")
        script = STOP_SH % group
        cmd = self.wrap(script) if self.sudo else "sh -c %s" % shlex.quote(
            script)
        rc, _, err = self._exec(self.ssh_argv(host, cmd), STOP_TIMEOUT)
        if rc == 0:
            return ""
        last = (err or "").strip().splitlines()
        why = last[-1].strip() if last else "exit %d" % rc
        if why.startswith("qd: "):
            why = why[4:]
        if isinstance(rc, TimedOut):
            why = "the stop itself timed out"
        return "qd could not stop it (%s)" % why

    def push(self, host, files):
        for f in files:
            if os.path.basename(f) == SENTINEL:
                return 1, ("qd: cannot push a file named %s: it is the "
                           "mark qd leaves in its own directory" % SENTINEL)
        d, w = shlex.quote(self.remote_dir), shlex.quote(self.work_dir)
        # mkdir -m 700 refuses a path that is there already, so nothing
        # someone else put there (a directory, a link) is written into; a
        # later pass of a --keep-remote run finds its own directory again
        s = shlex.quote("%s/%s" % (self.work_dir, SENTINEL))
        rid = shlex.quote(self.run_id)
        # a directory this run makes gets the sentinel at once; one that is
        # there already (a later pass) must hold this run's
        cmd = ("{ [ -d %s ] || echo qd-made-parent; } && mkdir -p %s && "
               "{ { mkdir -m 700 %s 2>/dev/null && "
               "printf '%%s\\n' %s > %s; } || "
               "{ [ -d %s ] && [ ! -L %s ] && [ -O %s ] && [ ! -L %s ] && "
               "[ \"$(cat %s 2>/dev/null)\" = %s ]; } || "
               "{ echo %s >&2; exit 1; }; }") % (
                   d, d, w, rid, s, w, w, w, s, s, rid, shlex.quote(
                       "qd: %s is there already, and is not this run's"
                       % self.work_dir))
        rc, out, err = self._exec(self.ssh_argv(host, cmd), 60)
        if rc != 0:
            return rc, err
        if host.name not in self._made:
            self._made[host.name] = "qd-made-parent" in out
        argv = list(self.scp) + self.ssh_options()
        if host.port:
            argv += ["-P", str(host.port)]
        argv += ["-q"] + list(files) + ["%s:%s/" % (self.scp_target(host),
                                                    self.work_dir)]
        rc, _, err = self._exec(argv, max(60, self.timeout))
        if rc != 0:
            return rc, err
        names = " ".join(shlex.quote("%s/%s" % (self.work_dir,
                                                os.path.basename(f)))
                         for f in files)
        rc, _, err = self._exec(self.ssh_argv(host, "chmod +x %s" % names), 60)
        return rc, err

    def cleanup(self, host):
        """Remove this run's directory from a host -- under sudo when the
        command ran under it, or what it made as root stays -- and
        --remote-dir too if this run made it and it is empty now.  The
        checks of guarded_rm run on the host, under the same sudo as the
        delete, so a work directory computed wrong is refused there and
        reported rather than removed.  -> an error to report, or ''."""
        if host.name not in self._made:
            return ""
        cmd = guarded_rm(self.work_dir, self.run_id)
        if self._made[host.name]:
            cmd += " && { rmdir %s 2>/dev/null || true; }" % shlex.quote(
                self.remote_dir)
        rc, _, err = self._exec(self.ssh_argv(host, self.wrap(cmd)), 60)
        if rc == 0:
            return ""
        first = (err or "").strip().splitlines()
        return "qd: could not remove %s from this host: %s" % (
            self.work_dir, first[-1] if first else "exit %d" % rc)

    def run_one(self, host, command, push=None, cleanup=True, pass_no=1,
                stdin=None):
        r = Result(host, pass_no)
        t0 = time.monotonic()
        self._note_master(host)
        if push:
            rc, err = self.push(host, push)
            if rc != 0:
                r.outcome, r.rc, r.stderr = PUSH_FAILED, rc, err
                if rc == 255:
                    r.outcome = UNREACHABLE
                elif cleanup:
                    # what got there before it failed is not left behind
                    left = self.cleanup(host)
                    if left:
                        r.stderr = (err or "").rstrip("\n") + "\n" + left
                r.duration = time.monotonic() - t0
                return r
        rc, out, err, group = self._capture(
            self.ssh_argv(host, self.command_for(command, bool(push))),
            self.timeout, stdin, marked=True)
        r.rc, r.stdout, r.stderr = rc, out, err
        if isinstance(rc, (TimedOut, Flooded)):
            # qd has given up on it, and killed its ssh; the command is
            # stopped on the host too, or the row says it may not be
            why = self.stop(host, group)
            if why:
                r.left_running = True
                r.stderr = "%s, and may still be running on the host: %s" % (
                    err, why)
                if push and cleanup:
                    r.stderr += ("\nqd: left %s there, since the command "
                                 "in it may still be running" % self.work_dir)
                    cleanup = False
            else:
                r.stderr = "%s; qd stopped it on the host" % err
        if push and cleanup:
            left = self.cleanup(host)
            if left:
                r.stderr = (r.stderr.rstrip("\n") + "\n" if r.stderr
                            else "") + left
        r.duration = time.monotonic() - t0
        if isinstance(rc, TimedOut):
            r.outcome = TIMEOUT
        elif rc == 255:
            # 255 is ssh's own failure; anything from the remote shell
            # comes back as that command's status instead -- 127, command
            # not found (sudo, say), is a host that answered.
            low = (err or "").lower()
            r.outcome = UNREACHABLE if (
                "connect" in low or "resolve" in low or "route" in low
                or "cannot run" in low
                or "refused" in low or "timed out" in low
                or "permission denied" in low or "no such host" in low
                or not out) else FAILED
        elif rc != 0:
            r.outcome = FAILED
        return r


def guarded_rm(work_dir, run_id):
    """The shell that removes a run's directory on a host, and nothing else.

    It deletes only when every check holds, on the host itself: the path's
    last part is exactly `qd.<run id>` (so never `/`, `~`, an empty path or
    --remote-dir itself), no part of it is `..`, it is a directory and not
    a symlink, and it holds SENTINEL, a plain file, with this run's id.
    A directory that is not there is nothing to remove.  Anything else is
    refused with a `qd: refusing to remove` line on stderr and exit 3,
    which cleanup reports.  This is the one `rm -rf` qd sends to a host.
    """
    w = shlex.quote(work_dir)
    s = shlex.quote("%s/%s" % (work_dir, SENTINEL))
    rid = shlex.quote(run_id)
    name = shlex.quote("qd." + run_id)

    def refuse(why):
        return "{ echo %s >&2; exit 3; }" % shlex.quote(
            "qd: refusing to remove %s: %s" % (work_dir, why))

    return (
        "( w=%s; "
        "case \"/$w\" in */%s) ;; *) %s ;; esac; "
        "case \"/$w/\" in */../*) %s ;; esac; "
        "if [ ! -e \"$w\" ] && [ ! -L \"$w\" ]; then exit 0; fi; "
        "[ ! -L \"$w\" ] || %s; "
        "[ -d \"$w\" ] || %s; "
        "[ -f %s ] && [ ! -L %s ] || %s; "
        "[ \"$(cat %s)\" = %s ] || %s; "
        "rm -rf -- \"$w\" )") % (
            w, name, refuse("not this run's qd.%s directory" % run_id),
            refuse("the path has a .. in it"),
            refuse("it is a symlink"),
            refuse("it is not a directory"),
            s, s, refuse("it holds no %s" % SENTINEL),
            s, rid, refuse("its %s is another run's" % SENTINEL))


def progress(msg):
    if sys.stderr.isatty():
        sys.stderr.write("\r\033[K%s" % msg)
        sys.stderr.flush()


def progress_done():
    if sys.stderr.isatty():
        sys.stderr.write("\r\033[K")
        sys.stderr.flush()


def fan_out(hosts, fn, jobs, label=""):
    """Capped concurrency, results in host-list order -- never completion
    order, or two runs of the same thing could not be diffed."""
    workers = max(1, min(jobs, len(hosts)))
    done = [0]
    total = len(hosts)

    def wrapped(h):
        try:
            return fn(h)
        finally:
            done[0] += 1
            progress("%s%d/%d done" % (label, done[0], total))

    with ThreadPoolExecutor(max_workers=workers) as pool:
        results = list(pool.map(wrapped, hosts))
    progress_done()
    return results


# Open files a host in flight holds in qd: its ssh's stdout and stderr
# pipes, a stdin file, the selector, and one for luck; and what qd keeps
# open besides (QD-019, measured by tests/scale.sh).
FDS_PER_HOST = 5
FDS_RESERVED = 40


def fit_jobs(jobs, limits=None):
    """(jobs, note): as many hosts at once as the open-file limit allows.
    The soft limit is raised towards the hard one when it is short; if
    even that is not enough, fewer hosts run at once and the note says
    why.  Running out mid-fan-out is worse than slower: every ssh that
    cannot get a pipe reads as a host that did not answer.  `limits`
    stands in for the resource module, for the tests."""
    try:
        res = limits
        if res is None:
            import resource as res
    except ImportError:             # not POSIX: nothing to ask
        return jobs, ""
    need = FDS_RESERVED + FDS_PER_HOST * jobs
    soft, hard = res.getrlimit(res.RLIMIT_NOFILE)
    if soft == res.RLIM_INFINITY or soft >= need:
        return jobs, ""
    want = need if hard == res.RLIM_INFINITY else min(hard, need)
    if want > soft:
        try:
            res.setrlimit(res.RLIMIT_NOFILE, (want, hard))
            soft = want
        except (ValueError, OSError):
            pass
    if soft >= need:
        return jobs, ""
    fit = max(1, (soft - FDS_RESERVED) // FDS_PER_HOST)
    return fit, ("%d hosts at once need about %d open files and the limit "
                 "is %d (ulimit -n), so %d run at once instead; raise "
                 "`ulimit -n` for more" % (jobs, need, soft, fit))


def run_passes(hosts, fn, jobs, count=1, every=0.0, sleep=time.sleep,
               gate=None):
    """`count` passes over the fleet, one starting every `every` seconds.

    A pass that runs longer than the interval is followed straight away by
    the next rather than overlapping it.  Ctrl-C between or during passes
    keeps every pass that finished.  `gate` (pacing.Gate) caps hosts
    per attribute value and spaces their starts.  -> (results, interrupted)
    """
    results = []
    interrupted = False
    jobs, note = fit_jobs(min(jobs, max(1, len(hosts))))
    if note:
        sys.stderr.write("qd: %s\n" % note)
    try:
        for k in range(1, count + 1):
            t0 = time.monotonic()
            label = "pass %d/%d: " % (k, count) if count > 1 else ""
            if gate is not None and gate.active():
                from .pacing import gated_fan_out
                results.extend(gated_fan_out(
                    hosts, lambda h, k=k: fn(h, k), jobs, gate,
                    label=label, progress=progress))
                progress_done()
            else:
                results.extend(fan_out(hosts, lambda h, k=k: fn(h, k), jobs,
                                       label))
            if k < count and every:
                left = every - (time.monotonic() - t0)
                if left > 0:
                    sleep(left)
    except KeyboardInterrupt:
        progress_done()
        interrupted = True
    return results, interrupted
