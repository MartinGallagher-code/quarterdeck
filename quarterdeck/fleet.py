# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Martin J. Gallagher
"""Running one command on many hosts and keeping every answer.

canonical copy of the runner: binnacle/agree.py Runner and fan_out().  The
transport, the bounded capture and the failure classes are agree's, so
`unreachable` means the same thing in a quarterdeck dataset as in an agree
group.  What differs is what is kept: agree compares the answers, this
keeps them -- raw, per host, in host-list order -- so they can be parsed
into columns and read back later.
"""

import os
import secrets
import selectors
import shlex
import subprocess
import sys
import time
from concurrent.futures import ThreadPoolExecutor

SSH_OPTS = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=8",
            "-o", "StrictHostKeyChecking=accept-new"]

OK, FAILED, TIMEOUT, UNREACHABLE, PUSH_FAILED = (
    "ok", "failed", "timeout", "unreachable", "push-failed")


class TimedOut(int):
    """qd's own timeout, 124 as `timeout` says it, but told apart from a
    command on the host that exited 124 itself (`timeout 5 check` does):
    that host answered."""


class Result(object):
    __slots__ = ("host", "outcome", "rc", "stdout", "stderr", "duration",
                 "started", "pass_no")

    def __init__(self, host, pass_no=1):
        self.host = host
        self.outcome = OK
        self.rc = 0
        self.stdout = ""
        self.stderr = ""
        self.duration = 0.0
        self.started = time.time()
        self.pass_no = pass_no

    def error(self):
        """The first line of what went wrong, for a column."""
        if self.outcome == OK:
            return ""
        for ln in (self.stderr or "").splitlines():
            if ln.strip():
                return ln.strip()[:200]
        return "exit %d" % self.rc


class Runner(object):
    def __init__(self, ssh="ssh", scp="scp", user=None, timeout=60,
                 max_output=4 * 1024 * 1024, remote_dir="/var/tmp",
                 sudo=False):
        self.ssh = shlex.split(ssh)
        self.scp = shlex.split(scp)
        self.user = user
        self.timeout = timeout
        self.max_output = max_output
        self.remote_dir = remote_dir
        # Pushed files go in a directory of this run's own under
        # --remote-dir, and only that is removed afterwards: never
        # --remote-dir itself (~/bin, say, and everything in it), nor a
        # directory another run or another user is working in.
        self.work_dir = "%s/qd.%s" % (remote_dir.rstrip("/"),
                                      secrets.token_hex(6))
        # hosts where this run made the work directory, and where it made
        # --remote-dir too (so that is removed again, if it is empty)
        self._made = {}
        self.sudo = sudo

    def target(self, host):
        return "%s@%s" % (self.user, host.addr) if self.user else host.addr

    def scp_target(self, host):
        addr = "[%s]" % host.addr if ":" in host.addr else host.addr
        return "%s@%s" % (self.user, addr) if self.user else addr

    def ssh_argv(self, host, command):
        argv = list(self.ssh) + SSH_OPTS
        if host.port:
            argv += ["-p", str(host.port)]
        return argv + [self.target(host), command]

    def wrap(self, command):
        if self.sudo:
            return "sudo -n sh -c %s" % shlex.quote(command)
        return command

    def command_for(self, command, pushed=False):
        """What runs on a host, as --dry-run prints it: beside the pushed
        files when there are any (so `--push x -- tool x` finds x), under
        `sudo -n` with --sudo."""
        if pushed:
            command = "cd %s && %s" % (shlex.quote(self.work_dir), command)
        return self.wrap(command)

    def _exec(self, argv, timeout):
        """Bounded capture: one host in a log storm must not sink the run."""
        limit = int(self.max_output)
        try:
            p = subprocess.Popen(argv, stdout=subprocess.PIPE,
                                 stderr=subprocess.PIPE,
                                 stdin=subprocess.DEVNULL)
        except OSError as exc:
            # ssh (or scp) itself would not start: no host was reached
            return 255, "", "cannot run %s: %s" % (argv[0], exc)
        chunks = {p.stdout: [], p.stderr: []}
        sizes = {p.stdout: 0, p.stderr: 0}
        deadline = time.monotonic() + timeout
        flooded = False
        sel = selectors.DefaultSelector()
        sel.register(p.stdout, selectors.EVENT_READ)
        sel.register(p.stderr, selectors.EVENT_READ)
        open_count = 2
        while open_count:
            left = deadline - time.monotonic()
            if left <= 0:
                sel.close()
                p.kill()
                p.wait()
                for f in (p.stdout, p.stderr):
                    f.close()
                return TimedOut(124), "", "timed out after %ss" % timeout
            for key, _ in sel.select(left):
                f = key.fileobj
                chunk = os.read(f.fileno(), 65536)
                if not chunk:
                    sel.unregister(f)
                    open_count -= 1
                    continue
                room = limit - sizes[f]
                if room > 0:
                    chunks[f].append(chunk[:room])
                sizes[f] += len(chunk)
                if sizes[f] > limit:
                    flooded = True
            if flooded:
                p.kill()
                break
        sel.close()
        try:
            rc = p.wait(timeout=max(1.0, deadline - time.monotonic()))
        except subprocess.TimeoutExpired:
            p.kill()
            rc = p.wait()
        for f in (p.stdout, p.stderr):
            f.close()

        def text(f):
            return b"".join(chunks[f]).decode("utf-8-sig", "replace")

        if flooded:
            return 125, "", ("output exceeded --max-output (%d bytes); "
                             "host killed" % limit)
        return rc, text(p.stdout), text(p.stderr)

    def push(self, host, files):
        d, w = shlex.quote(self.remote_dir), shlex.quote(self.work_dir)
        # mkdir -m 700 refuses a path that is there already, so nothing
        # someone else put there (a directory, a link) is written into; a
        # later pass of a --keep-remote run finds its own directory again
        cmd = ("{ [ -d %s ] || echo qd-made-parent; } && mkdir -p %s && "
               "{ mkdir -m 700 %s 2>/dev/null || "
               "{ [ -d %s ] && [ ! -L %s ] && [ -O %s ]; } || "
               "{ echo %s >&2; exit 1; }; }") % (
                   d, d, w, w, w, w, shlex.quote(
                       "qd: %s is there already, and is not this run's"
                       % self.work_dir))
        rc, out, err = self._exec(self.ssh_argv(host, cmd), 60)
        if rc != 0:
            return rc, err
        if host.name not in self._made:
            self._made[host.name] = "qd-made-parent" in out
        argv = list(self.scp) + SSH_OPTS
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
        --remote-dir too if this run made it and it is empty now.
        -> an error to report, or ''."""
        if host.name not in self._made:
            return ""
        cmd = self.wrap("rm -rf %s" % shlex.quote(self.work_dir))
        if self._made[host.name]:
            cmd += " && { rmdir %s 2>/dev/null || true; }" % shlex.quote(
                self.remote_dir)
        rc, _, err = self._exec(self.ssh_argv(host, cmd), 60)
        if rc == 0:
            return ""
        first = (err or "").strip().splitlines()
        return "qd: could not remove %s from this host: %s" % (
            self.work_dir, first[-1] if first else "exit %d" % rc)

    def run_one(self, host, command, push=None, cleanup=True, pass_no=1):
        r = Result(host, pass_no)
        t0 = time.monotonic()
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
        rc, out, err = self._exec(
            self.ssh_argv(host, self.command_for(command, bool(push))),
            self.timeout)
        r.rc, r.stdout, r.stderr = rc, out, err
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


def run_passes(hosts, fn, jobs, count=1, every=0.0, sleep=time.sleep):
    """`count` passes over the fleet, one starting every `every` seconds.

    A pass that runs longer than the interval is followed straight away by
    the next rather than overlapping it.  Ctrl-C between or during passes
    keeps every pass that finished.  -> (results, interrupted)
    """
    results = []
    interrupted = False
    try:
        for k in range(1, count + 1):
            t0 = time.monotonic()
            label = "pass %d/%d: " % (k, count) if count > 1 else ""
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
