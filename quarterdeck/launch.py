# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Martin J. Gallagher
"""How the hosts are reached: ssh, or srun, pdsh, clush or local (`--via`,
QD_VIA).

Every launcher keeps ssh's contract (fleet.Runner, which these extend):
one Result per host, in host-list order, with the same outcomes -- a host
that did not answer is a row too -- and pushed files in a directory of the
run's own that only that run removes.  Only the way a host is reached
changes.

srun   inside a Slurm allocation (SLURM_JOB_ID): one step per host,
       `srun --overlap -N1 -n1 -w HOST sh -c CMD`.  The allocation's nodes
       are the host list when none is given, and every answer's prologue
       carries the job (sched.job, provost's manifest key) and partition.
       Files and stdin reach the host through srun's own stdin.
pdsh   one pdsh for every host (`-w a,b,c`, `-f` = --jobs).  pdsh puts
       `host: ` before each line; that tells the answers apart, and a line
       qd adds after the command gives each host's exit status, which pdsh
       does not.  Files go by pdcp, stdin as a file pushed beside them.
clush  the same through ClusterShell's clush, files by `clush --copy`.
local  this machine, without ssh (QD-037): `sh -c CMD` here, as sshd would
       start it on a host.  The host a command runs on when nothing names
       any; only this machine (localhost, 127.0.0.1, its hostname) can be
       named with it.  Files are copied with cp, stdin goes straight in.

qd never asks Slurm for an allocation: --via srun runs in the one it is
given.
"""

import math
import os
import re
import secrets
import selectors
import shlex
import shutil
import signal
import subprocess
import tempfile
import threading
import time

from . import fleet
from .common import die
from .hosts import Host, expand_range, is_local, split_commas

VIAS = ("ssh", "srun", "pdsh", "clush", "local")

# what pushed stdin is called in the run's directory, for pdsh and clush
STDIN_NAME = ".qd-stdin"

# ssh's own options, for the ssh pdsh starts (PDSH_SSH_ARGS_APPEND): never
# a password prompt, a new host's key accepted -- as qd's own ssh does
PDSH_SSH_APPEND = "-o BatchMode=yes -o StrictHostKeyChecking=accept-new"

CONNECT_TIMEOUT = 8


# ---------------------------------------------------------------------------
# Slurm
# ---------------------------------------------------------------------------

def allocation(environ=None):
    """The Slurm allocation qd runs in -- {job, partition, nodelist} as
    salloc and sbatch set them -- or None outside one."""
    e = os.environ if environ is None else environ
    job = (e.get("SLURM_JOB_ID") or e.get("SLURM_JOBID") or "").strip()
    if not job:
        return None
    return {"job": job,
            "partition": (e.get("SLURM_JOB_PARTITION") or "").strip(),
            "nodelist": (e.get("SLURM_JOB_NODELIST")
                         or e.get("SLURM_NODELIST") or "").strip()}


def need_allocation(alloc):
    if alloc is None:
        die("--via srun runs inside a Slurm allocation (salloc, sbatch, or "
            "SLURM_JOB_ID set to one of yours): SLURM_JOB_ID is not set, "
            "and qd does not ask for one")
    return alloc


def allocation_hosts(alloc, scontrol="scontrol"):
    """The allocation's nodes, as `scontrol show hostnames` expands its
    node list, in that order."""
    if not alloc.get("nodelist"):
        die("job %s: SLURM_JOB_NODELIST is not set, so its nodes are not "
            "known here; give the hosts (--servers, -S)" % alloc["job"])
    try:
        p = subprocess.run([scontrol, "show", "hostnames", alloc["nodelist"]],
                           stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                           stdin=subprocess.DEVNULL, timeout=60)
    except (OSError, subprocess.SubprocessError) as exc:
        die("cannot run %s to list job %s's nodes: %s (or give the hosts: "
            "--servers, -S)" % (scontrol, alloc["job"], exc))
    if p.returncode != 0:
        why = p.stderr.decode("utf-8", "replace").strip().splitlines()
        die("%s show hostnames %s failed: %s" % (
            scontrol, alloc["nodelist"], why[-1] if why else
            "exit %d" % p.returncode))
    names = [ln.strip() for ln in
             p.stdout.decode("utf-8", "replace").splitlines() if ln.strip()]
    if not names:
        die("job %s: scontrol found no nodes in %s" % (
            alloc["job"], alloc["nodelist"]))
    return [Host(n, n) for n in names]


# srun's own lines about a task that ran: the task's exit status is the
# row's rc, so the line saying so again is dropped; one about a step that
# never started means the host was not reached
TASK_RE = re.compile(r"^srun: error: \S+: tasks? [0-9,-]+: ")
TASK_EXIT_RE = re.compile(
    r"^srun: error: \S+: tasks? [0-9,-]+: Exited with exit code \d+\s*$")
SRUN_ERR_RE = re.compile(r"^srun: (error|fatal)\b")


class SrunRunner(fleet.Runner):
    """One srun step per host, inside the allocation qd was started in."""

    via = "srun"
    # srun stopped with SIGTERM ends its step; SIGKILL would leave it.
    # That is how a command qd gives up on is stopped on the node, so no
    # MARK_SH line and no second call (QD-026's stop is ssh's).
    stop_grace = 5
    marks = False

    def __init__(self, alloc=None, srun="srun", **kw):
        fleet.Runner.__init__(self, **kw)
        self.srun = shlex.split(srun)
        self.alloc = alloc or {}

    def argv(self, host, command):
        # --overlap: a step beside the job's own, never queued behind it
        return list(self.srun) + ["--overlap", "-N1", "-n1", "-w",
                                  host.addr, "sh", "-c", command]

    def needs(self, pushing, stdin=False):
        return [self.srun[0]]

    def check_hosts(self, hosts):
        for h in hosts:
            if h.port:
                return ("%s has a port (%d): --via srun reaches a node by "
                        "its Slurm name, not by ssh" % (h.name, h.port))
        return None

    def context(self):
        return [(k, self.alloc.get(f)) for k, f in (
            ("sched.job", "job"), ("sched.partition", "partition"))
            if self.alloc.get(f)]

    def run_fields(self):
        return {"via": self.via, "sched_job": self.alloc.get("job", "")}

    def _capture(self, argv, timeout, stdin=None, marked=False,
                 started=False):
        rc, out, err, group, pre = fleet.Runner._capture(
            self, argv, timeout, stdin, marked, started)
        if isinstance(rc, (fleet.TimedOut, fleet.Flooded)):
            return rc, out, err, group, pre
        if rc == 255 and err.startswith("cannot run "):
            return fleet.Unlaunched(255), out, err, group, pre
        lines = err.splitlines(True)
        ran = any(TASK_RE.match(ln) for ln in lines)
        kept = "".join(ln for ln in lines if not TASK_EXIT_RE.match(ln))
        if rc != 0 and not ran and any(SRUN_ERR_RE.match(ln)
                                       for ln in lines):
            return fleet.Unlaunched(255), out, kept, group, pre
        return rc, out, kept, group, pre

    def _copy(self, host, files):
        # through the step's stdin: the host's own copy, in the same step
        # as its chmod, and nothing on the hosts but a shell and cat
        for f in files:
            dest = shlex.quote("%s/%s" % (self.work_dir,
                                          os.path.basename(f)))
            rc, _, err = self._exec(
                self.argv(host, self.started(
                    "cat > %s && chmod +x %s" % (dest, dest))),
                max(60, self.timeout), f, started=self.cut)
            if rc != 0:
                return rc, err
        return 0, ""

    def outcome_of(self, rc, out, err):
        if isinstance(rc, fleet.TimedOut):
            return fleet.TIMEOUT
        if isinstance(rc, fleet.Unlaunched):
            return fleet.UNREACHABLE
        return fleet.FAILED if rc != 0 else fleet.OK


# ---------------------------------------------------------------------------
# pdsh and clush: every host in one call
# ---------------------------------------------------------------------------

# a tool's own line about a host, before the host's name
TOOL_PREFIX_RE = re.compile(r"^(pdsh@[^:\s]*: |pdcp@[^:\s]*: |clush: )")
# ... saying how the remote side exited: each host's rc is its own line
EXIT_RE = re.compile(r"^(\S+ )?exited with exit code \d+\s*$")


class FanRunner(fleet.Runner):
    """pdsh or clush: one call for the whole host list, its answers told
    apart by the `host: ` each line comes with."""

    batched = True
    # one call for every host: there is no second one to stop a host's
    # command with, so no MARK_SH line either
    marks = False

    def __init__(self, via="pdsh", **kw):
        fleet.Runner.__init__(self, **kw)
        self.via = via
        # the status line qd puts after the command; random, so no output
        # is ever taken for it
        self.token = "qd-rc-" + secrets.token_hex(8)
        self._marker = re.compile(r"^%s (\d+)$" % re.escape(self.token))

    @property
    def copier(self):
        return "pdcp" if self.via == "pdsh" else "clush"

    def needs(self, pushing, stdin=False):
        return [self.via] + ([self.copier] if (pushing or stdin)
                             and self.copier != self.via else [])

    def check_hosts(self, hosts):
        """pdsh and clush take names: no port per host, and one answer per
        address."""
        seen = {}
        for h in hosts:
            if h.port:
                return ("%s has a port (%d): --via %s cannot give one per "
                        "host; set it in your ssh config instead"
                        % (h.name, h.port, self.via))
            if h.addr in seen:
                return ("%s and %s are both %s: --via %s answers by address, "
                        "so the two could not be told apart"
                        % (seen[h.addr], h.name, h.addr, self.via))
            if "," in h.addr or h.addr.startswith("-"):
                return "%s: not an address --via %s can take" % (
                    h.addr, self.via)
            seen[h.addr] = h.name
        return None

    def env(self):
        if self.via != "pdsh":
            return None
        e = dict(os.environ)
        # the user's own options first: ssh keeps the first value it gets
        e["PDSH_SSH_ARGS_APPEND"] = (
            (e.get("PDSH_SSH_ARGS_APPEND", "") + " " + PDSH_SSH_APPEND)
            .strip())
        return e

    def _common(self, jobs, timeout=None):
        argv = [self.via, "-f", str(max(1, jobs)), "-t",
                str(CONNECT_TIMEOUT)]
        if timeout is not None:
            argv += ["-u", str(int(math.ceil(timeout)))]
        if self.user:
            argv += ["-l", self.user]
        return argv

    def remote(self, command, stdin_file=None, marked=True):
        """What each host runs: the start line on both streams (QD-038;
        not with --keep-preamble, nor for --dry-run's `marked`), the
        command in a subshell of its own (so an `exit` in it ends only
        that), then a line with its status.  Every call qd makes through
        pdsh or clush goes this way -- mkdir, the check, cleanup -- so the
        login shell's preamble is cut from each."""
        inner = "(eval %s)" % shlex.quote(command)
        if stdin_file:
            inner += " < %s" % shlex.quote(stdin_file)
        head = ""
        if marked and self.cut:
            s = shlex.quote(self.start)
            head = "printf '\\n%%s\\n' %s; printf '\\n%%s\\n' %s >&2; " % (
                s, s)
        return "%s%s; printf '\\n%%s %%d\\n' %s \"$?\"" % (
            head, inner, self.token)

    def started(self, command):
        # the start line is remote()'s, in every call
        return command

    def fan_argv(self, hosts, command, timeout, jobs, stdin_file=None,
                 marked=True):
        return self._common(jobs, timeout) + [
            "-w", ",".join(h.addr for h in hosts),
            self.remote(command, stdin_file, marked)]

    def copy_argv(self, hosts, files, jobs):
        argv = self._common(jobs)
        if self.via == "pdsh":
            argv[0] = "pdcp"
            return argv + ["-w", ",".join(h.addr for h in hosts)] + \
                list(files) + [self.work_dir + "/"]
        return argv + ["-w", ",".join(h.addr for h in hosts), "--copy"] + \
            list(files) + ["--dest", self.work_dir + "/"]

    def argv(self, host, command):
        """One host's command, as --dry-run would print it alone."""
        return self.fan_argv([host], command, self.timeout, 1, marked=False)

    # -- reading what comes back ----------------------------------------

    @staticmethod
    def _split(line, by_addr):
        """'host: text' -> (host name, text); (None, line) if no host of
        this call said it."""
        name, sep, rest = line.partition(": ")
        if sep and name in by_addr:
            return by_addr[name].name, rest
        if line.endswith(":") and line[:-1] in by_addr:
            return by_addr[line[:-1]].name, ""
        return None, line

    @staticmethod
    def _folded(text, by_addr):
        """clush's own line about several hosts at once names them as one
        node set -- 'node[02-03]: command timeout' -> ([names], text);
        ([], text) if those are not this call's hosts."""
        spec, sep, rest = text.partition(": ")
        if not sep or "[" not in spec:
            return [], text
        addrs = [a for part in split_commas(spec) for a in expand_range(part)]
        if not addrs or any(a not in by_addr for a in addrs):
            return [], text
        return [by_addr[a].name for a in addrs], rest

    def _stream(self, argv, seconds, on_line):
        """Run argv, every line of its stdout and stderr to on_line(kind,
        text) as it comes.  -> (rc, why): rc None if it ran past
        `seconds` and was stopped, or would not start (why says so)."""
        try:
            p = subprocess.Popen(argv, stdout=subprocess.PIPE,
                                 stderr=subprocess.PIPE,
                                 stdin=subprocess.DEVNULL, env=self.env())
        except OSError as exc:
            return None, "cannot run %s: %s" % (argv[0], exc)
        kind = {p.stdout: "out", p.stderr: "err"}
        buf = {p.stdout: b"", p.stderr: b""}
        skip = {p.stdout: False, p.stderr: False}
        # a line longer than this is cut there: a host that never ends a
        # line must not hold the rest in memory
        cap = int(self.max_output) + 4096
        sel = selectors.DefaultSelector()
        sel.register(p.stdout, selectors.EVENT_READ)
        sel.register(p.stderr, selectors.EVENT_READ)
        deadline = time.monotonic() + seconds
        stopped = False

        def emit(f, raw):
            on_line(kind[f], raw.decode("utf-8", "replace").rstrip("\r"))

        try:
            open_count = 2
            while open_count:
                left = deadline - time.monotonic()
                if left <= 0:
                    stopped = True
                    break
                for key, _ in sel.select(left):
                    f = key.fileobj
                    chunk = os.read(f.fileno(), 65536)
                    if not chunk:
                        sel.unregister(f)
                        open_count -= 1
                        if buf[f] and not skip[f]:
                            emit(f, buf[f])
                        buf[f] = b""
                        continue
                    parts = (buf[f] + chunk).split(b"\n")
                    buf[f] = parts.pop()
                    for raw in parts:
                        if skip[f]:
                            skip[f] = False
                        else:
                            emit(f, raw)
                    if len(buf[f]) > cap:
                        if not skip[f]:
                            emit(f, buf[f])
                        buf[f] = b""
                        skip[f] = True
        finally:
            sel.close()
            if p.poll() is None:
                self._stop(p)
            rc = p.wait()
            for f in (p.stdout, p.stderr):
                f.close()
        return (None if stopped else rc), ""

    def _overall(self, n, jobs, timeout):
        waves = int(math.ceil(float(n) / max(1, jobs)))
        return (timeout + CONNECT_TIMEOUT + 7) * max(1, waves) + 30

    def _fan(self, hosts, command, timeout, jobs, stdin_file=None,
             label=None):
        """`command` on every host in one call.  -> {name: (rc, stdout,
        stderr, when it answered, preamble)}

        A host's lines on each stream are held until its start line comes
        (QD-038, remote()): those before it are its login shell's
        preamble, cut; with no start line, or past fleet.HEAD_MAX before
        it, they are its answer as they came."""
        by_addr = dict((h.addr, h) for h in hosts)
        cut = self.cut
        st = dict((h.name, {"out": [], "err": [], "bytes": 0, "ebytes": 0,
                            "flood": False, "rc": None, "t": None,
                            "timeout": False,
                            "head": {"out": [] if cut else None,
                                     "err": [] if cut else None},
                            "hbytes": {"out": 0, "err": 0},
                            "pre": {"out": [], "err": []},
                            "late": {"out": False, "err": False}})
                  for h in hosts)
        stray = []
        done = [0]
        limit = int(self.max_output)

        def keep_out(s, rest):
            if s["flood"]:
                return
            s["bytes"] += len(rest.encode("utf-8")) + 1
            if s["bytes"] > limit:
                s["flood"], s["out"] = True, []
                return
            s["out"].append(rest)

        def keep_err(s, rest):
            s["ebytes"] += len(rest) + 1
            if s["ebytes"] <= limit:
                s["err"].append(rest)

        keep = {"out": keep_out, "err": keep_err}

        def release(s, k, late=False):
            """A stream's held lines, as its answer: nothing cut."""
            head = s["head"][k]
            if head is None:
                return
            s["head"][k], s["late"][k] = None, late
            for ln in head:
                keep[k](s, ln)

        def taken(s, k, rest):
            """Whether a host's line is the start line or held before it."""
            head = s["head"][k]
            if head is None:
                if s["late"][k] and rest == self.start:
                    # came past HEAD_MAX: only it goes, with the newline
                    # it opens with
                    s["late"][k] = False
                    if s[k] and s[k][-1] == "":
                        s[k].pop()
                    return True
                return False
            if rest == self.start:
                if head and head[-1] == "":
                    head.pop()          # the newline it opens with
                s["pre"][k], s["head"][k] = head, None
                return True
            head.append(rest)
            s["hbytes"][k] += len(rest.encode("utf-8")) + 1
            if s["hbytes"][k] > fleet.HEAD_MAX:
                release(s, k, late=True)
            return True

        def on_line(kind, line):
            if kind == "out":
                name, rest = self._split(line, by_addr)
                if name is None:
                    return
                s = st[name]
                if s["rc"] is not None:
                    return
                m = self._marker.match(rest)
                if m:
                    release(s, "out")
                    s["rc"], s["t"] = int(m.group(1)), time.monotonic()
                    done[0] += 1
                    if label is not None:
                        fleet.progress("%s%d/%d done" % (label, done[0],
                                                         len(hosts)))
                    return
                if not taken(s, "out", rest):
                    keep_out(s, rest)
                return
            m = TOOL_PREFIX_RE.match(line)
            text = line[m.end():] if m else line
            name, rest = self._split(text, by_addr)
            names = [name] if name is not None else []
            if not names and m:
                names, rest = self._folded(text, by_addr)
            if not names:
                stray.append(line)
                return
            for name in names:
                s = st[name]
                if m:
                    # the tool's own line about the host: it is done, and
                    # what it held is said first, in the order it came
                    release(s, "err")
                elif taken(s, "err", rest):
                    continue
                if m and EXIT_RE.match(rest):
                    continue
                if m and "command timeout" in rest:
                    s["timeout"] = True
                keep_err(s, rest)

        argv = self.fan_argv(hosts, command, timeout, jobs, stdin_file)
        rc, why = self._stream(argv, self._overall(len(hosts), jobs,
                                                   timeout), on_line)
        if why:
            stray.append(why)
        stopped = rc is None and not why
        res = {}
        for h in hosts:
            s = st[h.name]
            release(s, "out")
            release(s, "err")
            pre = fleet.joined(*["".join(ln + "\n" for ln in s["pre"][k])
                                 for k in ("out", "err")])
            err = "".join(ln + "\n" for ln in s["err"])
            if s["flood"]:
                res[h.name] = (125, "", (
                    "output exceeded --max-output (%d bytes); the rest of "
                    "it was dropped\n" % limit) + err, s["t"], pre)
            elif s["rc"] is not None:
                res[h.name] = (s["rc"], self._text(s["out"]), err, s["t"],
                               pre)
            elif s["timeout"] or stopped:
                res[h.name] = (fleet.TimedOut(124), "",
                               "timed out after %ss" % timeout, None, pre)
            else:
                res[h.name] = (fleet.Unlaunched(255), self._text(s["out"]),
                               err + "".join(ln + "\n" for ln in stray)
                               or "%s: no answer\n" % self.via, None, pre)
        return res

    @staticmethod
    def _text(lines):
        """A host's stdout from its lines: the status line comes after a
        newline qd adds, so a last empty line is that newline."""
        if lines and lines[-1] == "":
            return "".join(ln + "\n" for ln in lines[:-1])
        return "\n".join(lines)

    def outcome_of(self, rc, out, err):
        if isinstance(rc, fleet.TimedOut):
            return fleet.TIMEOUT
        if isinstance(rc, fleet.Unlaunched):
            # it said something and then went quiet: it was reached
            return fleet.FAILED if out.strip() else fleet.UNREACHABLE
        return fleet.FAILED if rc != 0 else fleet.OK

    # -- a pass --------------------------------------------------------------

    def run_one(self, host, command, push=None, cleanup=True, pass_no=1,
                stdin=None):
        return self.run_many([host], command, push, cleanup, pass_no,
                             stdin, 1)[0]

    def run_many(self, hosts, command, push=None, cleanup=True, pass_no=1,
                 stdin=None, jobs=32, label=None):
        """One pass over every host: the push, the command and the
        cleanup each one call for them all.  -> [Result], host order"""
        t0 = time.monotonic()
        rs = [fleet.Result(h, pass_no) for h in hosts]
        by = dict((r.host.name, r) for r in rs)
        files = list(push or [])
        tmp = None
        try:
            live = list(hosts)
            sending = list(files)
            if stdin:
                tmp = tempfile.mkdtemp(prefix="qd-stdin-")
                staged = os.path.join(tmp, STDIN_NAME)
                shutil.copyfile(stdin, staged)
                sending.append(staged)
            if sending:
                live = self._push_all(live, sending, files, by, cleanup,
                                      jobs, t0)
            if live:
                feed = ("%s/%s" % (self.work_dir, STDIN_NAME)) if stdin \
                    else None
                ans = self._fan(live, self.command_for(command, bool(files)),
                                self.timeout, jobs, feed, label)
                for h in live:
                    rc, out, err, when, pre = ans[h.name]
                    r = by[h.name]
                    r.rc, r.stdout, r.stderr = rc, out, err
                    r.preamble = pre
                    r.outcome = self.outcome_of(rc, out, err)
                    r.duration = (when or time.monotonic()) - t0
            if sending and cleanup:
                left = self._cleanup_all([h for h in hosts
                                          if h.name in self._made], jobs)
                for name, msg in left.items():
                    r = by[name]
                    r.stderr = (r.stderr.rstrip("\n") + "\n" if r.stderr
                                else "") + msg
        finally:
            if tmp:
                shutil.rmtree(tmp, ignore_errors=True)
        return rs

    def _failed(self, r, rc, err, t0, pre=""):
        r.outcome = fleet.UNREACHABLE if rc == 255 else fleet.PUSH_FAILED
        r.rc, r.stderr, r.preamble = rc, err, pre
        r.duration = time.monotonic() - t0

    def _push_all(self, hosts, sending, files, by, cleanup, jobs, t0):
        """The run's directory on every host, the files in it, checked
        whole there.  -> the hosts it worked on"""
        for f in files:
            if os.path.basename(f) == fleet.SENTINEL:
                for h in hosts:
                    self._failed(by[h.name], 1, (
                        "qd: cannot push a file named %s: it is the mark qd "
                        "leaves in its own directory" % fleet.SENTINEL), t0)
                return []
        ans = self._fan(hosts, self.mkdir_command(), 60, jobs)
        made = []
        for h in hosts:
            rc, out, err, _, pre = ans[h.name]
            if rc != 0:
                self._failed(by[h.name], rc, err, t0, pre)
                continue
            if h.name not in self._made:
                self._made[h.name] = "qd-made-parent" in out
            made.append(h)
        if not made:
            return []
        errs = self._copy_all(made, sending, jobs)
        # what arrived is checked on the host, whatever the copier said:
        # every file there, at its size, and the pushed ones executable
        checks = []
        for f in sending:
            p = shlex.quote("%s/%s" % (self.work_dir, os.path.basename(f)))
            checks.append("{ [ -f %s ] && [ $(wc -c < %s) -eq %d ] || "
                          "{ echo %s >&2; exit 1; }; }" % (
                              p, p, os.path.getsize(f), shlex.quote(
                                  "qd: %s did not arrive whole"
                                  % os.path.basename(f))))
        if files:
            checks.append("chmod +x %s" % " ".join(
                shlex.quote("%s/%s" % (self.work_dir, os.path.basename(f)))
                for f in files))
        ans = self._fan(made, " && ".join(checks), 60, jobs)
        live = []
        for h in made:
            rc, _, err, _, pre = ans[h.name]
            if rc == 0:
                live.append(h)
                continue
            why = "".join(ln + "\n" for ln in errs.get(h.name, []))
            self._failed(by[h.name], rc if rc == 255 else 1,
                         why + (err or ""), t0, pre)
        return live

    def _copy_all(self, hosts, files, jobs):
        """pdcp or clush --copy, once for every host.  -> {name: lines it
        said about that host}"""
        by_addr = dict((h.addr, h) for h in hosts)
        errs = dict((h.name, []) for h in hosts)
        stray = []

        def on_line(kind, line):
            m = TOOL_PREFIX_RE.match(line)
            text = line[m.end():] if m else line
            name, rest = self._split(text, by_addr)
            names = [name] if name is not None else []
            if not names and m:
                names, rest = self._folded(text, by_addr)
            if not names:
                stray.append(line)
            elif not (m and EXIT_RE.match(rest)):
                for name in names:
                    errs[name].append(rest)

        rc, why = self._stream(self.copy_argv(hosts, files, jobs),
                               self._overall(len(hosts), jobs,
                                             max(60, self.timeout)), on_line)
        if why:
            stray.append(why)
        elif rc is None:
            stray.append("%s: timed out" % self.copier)
        for name in errs:
            errs[name].extend(stray)
        return errs

    def _cleanup_all(self, hosts, jobs):
        """This run's directory off every host it was made on, as cleanup()
        does one at a time.  -> {name: what could not be removed}"""
        out = {}
        for parent in (False, True):
            group = [h for h in hosts if bool(self._made[h.name]) == parent]
            if not group:
                continue
            cmd = fleet.guarded_rm(self.work_dir, self.run_id)
            if parent:
                cmd += " && { rmdir %s 2>/dev/null || true; }" % \
                    shlex.quote(self.remote_dir)
            ans = self._fan(group, self.wrap(cmd), 60, jobs)
            for h in group:
                rc, _, err, _, _ = ans[h.name]
                if rc != 0:
                    first = (err or "").strip().splitlines()
                    out[h.name] = ("qd: could not remove %s from this host: "
                                   "%s" % (self.work_dir, first[-1] if first
                                           else "exit %d" % rc))
        return out


# ---------------------------------------------------------------------------
# local: this machine, without ssh (QD-037)
# ---------------------------------------------------------------------------

# The commands --via local has started and not yet seen end, which
# stop_local() stops; once it has, no host starts (a try --retries would
# make, say) until the next command makes a LocalRunner.
_LIVE = set()
# reentrant: stop_local() runs from a signal handler too, on the main
# thread, which may hold it at that moment
_LIVE_LOCK = threading.RLock()
_STOPPING = [False]

# seconds stop_local() gives a group after TERM before KILL
LOCAL_GRACE = 2.0


class LocalRunner(fleet.Runner):
    """This machine, reached without ssh: `sh -c CMD` here, as sshd starts
    it on a host -- in a session of its own, so the group MARK_SH names is
    the command's, and one qd gives up on is stopped with everything it
    started (QD-026) by STOP_SH, run here too.  Pushed files are copied
    with cp into the run's own directory, which only that run removes
    (guarded_rm), as over ssh.

    Ctrl-C reaches qd and not the command, which is in a session of its
    own as a host's is; so qd stops it itself (stop_local), rather than
    leave it running here or wait for it."""

    via = "local"

    def __init__(self, **kw):
        fleet.Runner.__init__(self, **kw)
        self._mine = threading.local()

    def ssh_argv(self, host, command):
        return ["sh", "-c", command]

    def needs(self, pushing, stdin=False):
        return ["sh"] + (["cp"] if pushing else [])

    def check_hosts(self, hosts):
        """This machine, once: a host anywhere else is ssh's (or pdsh's,
        or srun's) to reach."""
        for h in hosts:
            if h.port:
                return ("%s has a port (%d): --via local runs on this "
                        "machine, with no ssh to give it to" % (h.name,
                                                               h.port))
            if not is_local(h.addr):
                return ("%s is not this machine: --via local runs here "
                        "only (localhost, 127.0.0.1 or this machine's "
                        "name); reach %s with ssh (--via ssh)"
                        % (h.name if h.name == h.addr
                           else "%s (%s)" % (h.name, h.addr), h.name))
        if len(hosts) > 1:
            return ("%s are all this machine: --via local runs on it once, "
                    "as one host" % ", ".join(h.name for h in hosts))
        return None

    def run_one(self, host, command, push=None, cleanup=True, pass_no=1,
                stdin=None):
        if _STOPPING[0]:
            return fleet.not_run(host, pass_no, "interrupted before it "
                                 "started")
        return fleet.Runner.run_one(self, host, command, push, cleanup,
                                    pass_no, stdin)

    def _popen(self, argv, src):
        with _LIVE_LOCK:
            p = subprocess.Popen(argv, stdout=subprocess.PIPE,
                                 stderr=subprocess.PIPE,
                                 stdin=src or subprocess.DEVNULL,
                                 start_new_session=True)
            _LIVE.add(p)
        self._mine.p = p
        return p

    def _capture(self, argv, timeout, stdin=None, marked=False,
                 started=False):
        self._mine.p = None
        try:
            rc, out, err, group, pre = fleet.Runner._capture(
                self, argv, timeout, stdin, marked, started)
        finally:
            p = getattr(self._mine, "p", None)
            if p is not None:
                with _LIVE_LOCK:
                    _LIVE.discard(p)
        if isinstance(rc, (fleet.TimedOut, fleet.Flooded)):
            return rc, out, err, group, pre
        if rc == 255 and err.startswith("cannot run "):
            # sh itself would not start
            return fleet.Unlaunched(255), out, err, group, pre
        if rc < 0:
            # ended by a signal: as a shell says it, 128 + the signal
            rc = 128 - rc
        return rc, out, err, group, pre

    def _copy(self, host, files):
        """The files into this run's directory, executable: cp, then the
        chmod an scp is followed by."""
        rc, _, err = self._exec(["cp", "--"] + list(files) +
                                [self.work_dir + "/"], max(60, self.timeout))
        if rc != 0:
            return rc, err
        names = " ".join(shlex.quote("%s/%s" % (self.work_dir,
                                                os.path.basename(f)))
                         for f in files)
        rc, _, err = self._exec(
            self.argv(host, self.started("chmod +x %s" % names)), 60,
            started=self.cut)
        return rc, err

    def outcome_of(self, rc, out, err):
        if isinstance(rc, fleet.TimedOut):
            return fleet.TIMEOUT
        if isinstance(rc, fleet.Unlaunched):
            return fleet.UNREACHABLE
        return fleet.FAILED if rc != 0 else fleet.OK


def stop_local(grace=None):
    """Every command --via local started and has not seen end, stopped
    with its process group: TERM, then KILL `grace` seconds on.  No host
    starts after (cleaning up behind one still does).  The CLI calls it
    when Ctrl-C comes, and however a command ends.  -> how many were
    running"""
    with _LIVE_LOCK:
        _STOPPING[0] = True
        live = [p for p in _LIVE if p.poll() is None]
    if not live:
        return 0
    for p in live:
        _signal_group(p.pid, signal.SIGTERM)
    deadline = time.monotonic() + (LOCAL_GRACE if grace is None else grace)
    while time.monotonic() < deadline and any(
            _signal_group(p.pid, 0) for p in live):
        time.sleep(0.05)
    for p in live:
        _signal_group(p.pid, signal.SIGKILL)
    return len(live)


def _signal_group(pgid, sig):
    """`sig` to the group; whether any of it was there to get it.  Never
    0 or 1, which are not a command's group."""
    if pgid <= 1:
        return False
    try:
        os.killpg(pgid, sig)
        return True
    except OSError:
        return False


def stop_local_on_signals():
    """A TERM or HUP still ends qd at once, as it always has, but stops
    the commands --via local has running first: they are in sessions of
    their own, so nothing else would.  A signal already handled or
    ignored (nohup, --reuse's) is left as it is.  Only the main thread can
    set a handler; elsewhere this does nothing."""
    def handler(signum, frame):
        stop_local(0.5)
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


# ---------------------------------------------------------------------------

def make(via, **kw):
    """The launcher for --via, built from the Runner keywords."""
    if via == "ssh":
        return fleet.Runner(**kw)
    if via == "local":
        _STOPPING[0] = False
        stop_local_on_signals()
        return LocalRunner(**kw)
    if via == "srun":
        return SrunRunner(alloc=need_allocation(allocation()), **kw)
    if via in ("pdsh", "clush"):
        return FanRunner(via=via, **kw)
    die("--via %s: not a launcher qd knows (%s)" % (via, ", ".join(VIAS)))
