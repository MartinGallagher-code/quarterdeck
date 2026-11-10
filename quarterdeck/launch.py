# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Martin J. Gallagher
"""How the hosts are reached: ssh, or srun, pdsh or clush (`--via`, QD_VIA).

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
import subprocess
import tempfile
import time

from . import fleet
from .common import die
from .hosts import Host, expand_range, split_commas

VIAS = ("ssh", "srun", "pdsh", "clush")

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
    # srun stopped with SIGTERM ends its step; SIGKILL would leave it
    stop_grace = 5

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

    def _exec(self, argv, timeout, stdin=None):
        rc, out, err = fleet.Runner._exec(self, argv, timeout, stdin)
        if isinstance(rc, fleet.TimedOut):
            return rc, out, err
        if rc == 255 and err.startswith("cannot run "):
            return fleet.Unlaunched(255), out, err
        lines = err.splitlines(True)
        ran = any(TASK_RE.match(ln) for ln in lines)
        kept = "".join(ln for ln in lines if not TASK_EXIT_RE.match(ln))
        if rc != 0 and not ran and any(SRUN_ERR_RE.match(ln)
                                       for ln in lines):
            return fleet.Unlaunched(255), out, kept
        return rc, out, kept

    def _copy(self, host, files):
        # through the step's stdin: the host's own copy, in the same step
        # as its chmod, and nothing on the hosts but a shell and cat
        for f in files:
            dest = shlex.quote("%s/%s" % (self.work_dir,
                                          os.path.basename(f)))
            rc, _, err = self._exec(
                self.argv(host, "cat > %s && chmod +x %s" % (dest, dest)),
                max(60, self.timeout), f)
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

    def remote(self, command, stdin_file=None):
        """What each host runs: the command in a subshell of its own (so
        an `exit` in it ends only that), then a line with its status."""
        inner = "(eval %s)" % shlex.quote(command)
        if stdin_file:
            inner += " < %s" % shlex.quote(stdin_file)
        return "%s; printf '\\n%%s %%d\\n' %s \"$?\"" % (inner, self.token)

    def fan_argv(self, hosts, command, timeout, jobs, stdin_file=None):
        return self._common(jobs, timeout) + [
            "-w", ",".join(h.addr for h in hosts),
            self.remote(command, stdin_file)]

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
        return self.fan_argv([host], command, self.timeout, 1)

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
        stderr, when it answered)}"""
        by_addr = dict((h.addr, h) for h in hosts)
        st = dict((h.name, {"out": [], "err": [], "bytes": 0, "ebytes": 0,
                            "flood": False, "rc": None, "t": None,
                            "timeout": False}) for h in hosts)
        stray = []
        done = [0]
        limit = int(self.max_output)

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
                    s["rc"], s["t"] = int(m.group(1)), time.monotonic()
                    done[0] += 1
                    if label is not None:
                        fleet.progress("%s%d/%d done" % (label, done[0],
                                                         len(hosts)))
                    return
                if s["flood"]:
                    return
                s["bytes"] += len(rest.encode("utf-8")) + 1
                if s["bytes"] > limit:
                    s["flood"], s["out"] = True, []
                    return
                s["out"].append(rest)
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
                if m and EXIT_RE.match(rest):
                    continue
                if m and "command timeout" in rest:
                    s["timeout"] = True
                s["ebytes"] += len(rest) + 1
                if s["ebytes"] <= limit:
                    s["err"].append(rest)

        argv = self.fan_argv(hosts, command, timeout, jobs, stdin_file)
        rc, why = self._stream(argv, self._overall(len(hosts), jobs,
                                                   timeout), on_line)
        if why:
            stray.append(why)
        stopped = rc is None and not why
        res = {}
        for h in hosts:
            s = st[h.name]
            err = "".join(ln + "\n" for ln in s["err"])
            if s["flood"]:
                res[h.name] = (125, "", (
                    "output exceeded --max-output (%d bytes); the rest of "
                    "it was dropped\n" % limit) + err, s["t"])
            elif s["rc"] is not None:
                res[h.name] = (s["rc"], self._text(s["out"]), err, s["t"])
            elif s["timeout"] or stopped:
                res[h.name] = (fleet.TimedOut(124), "",
                               "timed out after %ss" % timeout, None)
            else:
                res[h.name] = (fleet.Unlaunched(255), self._text(s["out"]),
                               err + "".join(ln + "\n" for ln in stray)
                               or "%s: no answer\n" % self.via, None)
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
                    rc, out, err, when = ans[h.name]
                    r = by[h.name]
                    r.rc, r.stdout, r.stderr = rc, out, err
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

    def _failed(self, r, rc, err, t0):
        r.outcome = fleet.UNREACHABLE if rc == 255 else fleet.PUSH_FAILED
        r.rc, r.stderr = rc, err
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
            rc, out, err, _ = ans[h.name]
            if rc != 0:
                self._failed(by[h.name], rc, err, t0)
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
            rc, _, err, _ = ans[h.name]
            if rc == 0:
                live.append(h)
                continue
            why = "".join(ln + "\n" for ln in errs.get(h.name, []))
            self._failed(by[h.name], rc if rc == 255 else 1,
                         why + (err or ""), t0)
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
                rc, _, err, _ = ans[h.name]
                if rc != 0:
                    first = (err or "").strip().splitlines()
                    out[h.name] = ("qd: could not remove %s from this host: "
                                   "%s" % (self.work_dir, first[-1] if first
                                           else "exit %d" % rc))
        return out


# ---------------------------------------------------------------------------

def make(via, **kw):
    """The launcher for --via, built from the Runner keywords."""
    if via == "ssh":
        return fleet.Runner(**kw)
    if via == "srun":
        return SrunRunner(alloc=need_allocation(allocation()), **kw)
    if via in ("pdsh", "clush"):
        return FanRunner(via=via, **kw)
    die("--via %s: not a launcher qd knows (%s)" % (via, ", ".join(VIAS)))
