<!--
SPDX-License-Identifier: GPL-3.0-or-later
SPDX-FileCopyrightText: 2026 Martin J. Gallagher
-->

# Running: commands, probes and tools on many hosts

Starting out (the demo fleet, `qd setup`), then everything that sends
something to the hosts: `qd run`, `qd ask`, `qd probe` and `qd survey`,
`qd do`, and how far the fan-out goes. Part of [the manual](README.md).

## A fleet to learn on: `qd demo`

```bash
qd demo                    # file the store demo: a made-up fleet's week
qd store use demo          # read it from here on (or --store demo on each command)
qd freq demo-kernel A      # A: uname -r's answer; on in docs/getting-started.md
```

`qd demo` files a store named `demo`: 24 made-up hosts (`demo-r1n01` to
`demo-r2n12`, in racks `r1` and `r2`, SKUs `compute` and `storage`), asked
three things over a week. `demo-facts` is why-slow's readings every
morning, Monday to Friday; `demo-kernel` is `uname -r` on Friday;
`demo-iperf` is each host's throughput to a peer. Something is planted in
each for the read side to find: a host that did not answer, a kernel that
disagrees, a host whose free memory slides day by day, and a slow host
that fails one requirement of `qd demo --limits` (a CSV for `qd check
--against`). [Getting started](getting-started.md) finds them one
question at a time, and the test suite runs every command on that page.

Nothing runs. The answers ship with qd, as text (`quarterdeck/demo/`),
and a stand-in launcher plays them back for the demo's hosts in place of
ssh; it is no `--via` choice, and nothing but `qd demo` can reach it.
What it plays back goes through the same code as `qd run`, and provost
files every answer as it files a real run's, so the store is a store
like any other: `provost store check` passes on it, and every command
reads it. Each run is filed as having started at its time in the week
(UTC), so its id is the same on every machine.

`qd demo` leaves the store you use, and `~/.provost`, alone. Run again,
it says the demo is there already and shows it; `qd demo --rebuild` files
it afresh, and `qd store rm demo --delete` removes it. A store named
`demo` that is not qd's own is never touched. Filing takes a minute or
so, several with a provost that has no `batch` (2.1.0); a demo stopped
part-way leaves nothing behind.

## Your own fleet, the first time: `qd setup`

```bash
qd setup                            # at a terminal: asks, then does
qd setup -s hosts.txt --yes         # in a script: makes and selects the store, asks nothing
```

`qd setup` takes a newcomer from nothing to a first run in four steps,
each one a plain command, run as that command runs, and says what each
did:

1. **This machine:** `qd doctor`'s report: ssh, provost, the launcher.
2. **A store:** when none is active (or the demo is), it offers to make
   one named `main` (`--store-name`) and select it: `qd store new main`,
   `qd store use main`. A store chosen by `--store`, `QD_STORE` or
   provost, or one already active, is left as it is; with stores
   registered and none active it asks which, and never picks one itself.
3. **The host list:** `-s`, `-S`, `--layout`, `QD_SERVERS`, `hosts.txt`
   or `servers.txt`, as `qd run` finds it. With none, it offers to write
   `hosts.txt` from the names typed (`node[01-12]`, `web1 web2`, `node01
   rack=r1`), and never overwrites one.
4. **Who answers:** `qd run -- true` on every host, keeping nothing. Each
   host that did not answer is listed with why and what to do: a key
   (`ssh-copy-id`), a host key to accept, a name that does not resolve, a
   host that is down (`reachable`), or `qd doctor HOST`.

A summary follows, then WHAT TO DO NEXT: `qd ask -- uname -r`, `qd
survey` (the plain `qd run` and `qd probe` in a qd without them) and `qd
demo`.

A question is asked only when stdin is a terminal, checked before each
one, so a script or CI never waits: there it checks everything, changes
nothing that needs an answer, and says what to run instead. `--yes`
answers the store's question for a script; nothing answers the host
list's. Run again, it finds every step done and changes nothing. Exit
status: 0 when this machine is ready and every host answered; 1 when it
is not ready or a host did not answer, and the summary names which step;
2 on a usage error or a write that was refused.

---

## Running commands on many hosts: `qd run`

```bash
qd run --servers hosts.txt -- 'sysctl net.core.somaxconn'
qd run -S 'node[01-24]' -- uptime
qd run --layout floor.dc --select 'rack[1-3]' -- cat /proc/loadavg
```

### Host lists

Host lists use the grammar mx, iperf_orchestrator, agree and dcprobe
already read: one `name[=addr[:port]]` per line, `#` comments, and ranges
that expand (`node[01-24]`, `rack[a-c]-n[1,3]`). `hosts.txt` or
`servers.txt` in the current directory is used if you name none, and
with neither, the fleet is this machine (below).

`key=value` words after a host are its **attributes**, as dcprobe reads
them:

```text
wr01r01u01=10.1.1.11 rack=r01 row=A gbps=25
wr01r01u02=10.1.1.12 rack=r01 row=A gbps=25
```

Attributes become columns in every dataset. That's what lets you write
`qd stats latest load1 --by rack` without joining two files.

> agree, mx and iperf_orchestrator don't have attributes. agree reads
> `node01 rack=r1` as *two hosts*. Give those tools the plain list:
> `qd hosts --plain > servers.txt`. In the other direction, a host that
> carries `=` goes on a line of its own: `a=10.0.0.1 b=10.0.0.2` on one
> line is a host with an attribute here, and qd warns when it sees that.

`--layout floor.dc --select SEL` asks binnacle's
[`manifest`](https://binnacle.readthedocs.io/en/latest/tools/manifest.html)
which servers a `.dc` layout puts under the selectors (`rack[1-3]`,
`row[A,C]`, `+gpu`, `model=hgx*`). Where each one sits (room, row,
rack, slot) comes back as attributes. `qd hosts` prints any of this
without running anything.

A host list read from a file or from `-s -` whose first line is a `host`
header is read as a table, CSV or TSV: what `qd show ... --cols host
--format csv` and `qd hosts --csv` write. So the obvious pipe works:

```bash
qd show latest --where status!=ok --cols host --format csv | qd run -s - -- uname -s
```

Only the `host` column is read, with `addr` and `port` where there are
such columns; `qd hosts --csv`'s shape (`host,addr,port`, then
attributes) is read back with its attributes. To carry a run's
attributes over, use `--rerun` (below).

#### No hosts named: this machine

With no `-s`, `-S`, `--layout` or `--rerun`, no `QD_SERVERS`, and no
`hosts.txt` or `servers.txt` in the directory, `qd run`, `qd probe`,
`qd doe run` and `qd hosts` run on this machine: one host, named as its
hostname is up to the first dot (so a later fleet run that names this
machine lines up with it in `qd diff` and `qd trend`), at 127.0.0.1, and
reached without ssh (`--via local`, below). qd says so on stderr, once,
with how to name hosts. It is the quickest way to try a command or a
probe:

```bash
qd run -- uptime      # qd: no hosts named, so the fleet is this machine, ws01, reached without ssh (--via local); ...
qd probe facts        # why-slow's readings of this machine
```

- Anything that names hosts wins, as before, `--via srun`'s allocation
  included. An empty `hosts.txt` names no hosts and is still an error.
- `qd split` and `qd campaign new` still refuse (`no hosts given`): one
  workstation cut in parts is more likely a forgotten `-s` than meant.
- `--sudo` is refused on it unless you name it (`-S localhost`, or
  `--via local`), so a forgotten `-s` never runs a command as root here.
- `--via` or `QD_VIA` given, that launcher reaches it at 127.0.0.1
  instead (over ssh, that needs an sshd here and a key to yourself).
- `--rerun` of a run made this way reaches its host the same way again.
- `qd hosts --plain > servers.txt` in such a directory writes this
  machine (`ws01=127.0.0.1`), which a later run reaches by ssh, as it
  does any host it is given. `qd doctor` says where a command run here
  would get its hosts.

### Reaching the hosts: ssh, srun, pdsh, clush or local

ssh is the default: one connection per host, `--jobs` at a time. Where a
test event reaches its nodes some other way, `--via` (`QD_VIA`) changes
how the hosts are reached and nothing about what is kept: every host is
still a row, a host that did not answer is a row too, and the outcomes,
`--push`, `--script`, `--sudo`, `--every` and the cleanup are the same.

```bash
salloc -N 64 -p gpu                        # or inside an sbatch script
qd run --via srun -- nvidia-smi -L         # every node of the allocation
qd run --via pdsh -s hosts.txt -- uptime   # one pdsh for all of them
QD_VIA=clush qd probe inventory -s 'node[01-64]'
```

| `--via` | How | Pushed files and stdin |
|---|---|---|
| `ssh` | one `ssh` per host (`--ssh`, `--scp`) | `scp` |
| `srun` | inside a Slurm allocation: one step per host, `srun --overlap -N1 -n1 -w NODE sh -c CMD` | through the step's own stdin, a step per file |
| `pdsh` | one `pdsh -w a,b,c -f JOBS` for every host | `pdcp` (which must be on the hosts too) |
| `clush` | one `clush -w a,b,c -f JOBS` for every host | `clush --copy` |
| `local` | this machine only: `sh -c CMD` here, no ssh | `cp`; stdin straight in |

**srun.** qd runs only inside an allocation it is given (`salloc`,
`sbatch`, or `SLURM_JOB_ID` set to one of yours); it never asks Slurm for
one. With no hosts named, the fleet is the allocation's nodes, as
`scontrol show hostnames $SLURM_JOB_NODELIST` lists them, even if there
is a `hosts.txt` in the directory; `-s` or `-S` names a subset.
`--overlap` lets each step run beside the job's own. Every answer's `#%`
prologue carries the job as `sched.job` (provost's run-manifest key,
PV-020) and the partition as `sched.partition`: columns of every row in
the dataset (`qd show ds:NAME`) with a provost that has `batch`, and in
each capture's context (`provost source`) with any. The run's `qd.runs`
row says `via=srun` and the job. A node srun could not start a step on
is `unreachable` with srun's reason. srun runs as you (`--user` is not
used) and in the directory qd was started from, as srun does. A command
that times out is stopped with SIGTERM, which ends its step.

**pdsh and clush.** One call answers for every host: pdsh (or clush) puts
`host: ` before each line, which tells the answers apart, and qd adds a
line after the command with its exit status, which pdsh does not report
per host, and one before it on each stream, where the command starts
(see *What the login shell says first*). A host with no status line did
not answer. `--jobs` is the
fan-out (`-f`), `--timeout` each host's limit (`-u`), and `--user` its
`-l`. pdsh's ssh gets the options qd's own ssh uses (`BatchMode=yes`,
`StrictHostKeyChecking=accept-new`) after any you set in
`PDSH_SSH_ARGS_APPEND`; which remote shell it uses is pdsh's own setting
(`PDSH_RCMD_TYPE`). Some limits:

- A host is reached by name: no port per host (put it in your ssh
  config), and two hosts at one address are refused.
- A command's stdin (the script probes send binnacle's scripts on it) is
  pushed as a file beside the command and read from there, since pdsh
  forwards none (clush is treated the same way).
- `--rate` spaces hosts out, which one call cannot: with it, each host is
  a call of its own.
- Some pdsh builds merge a host's stderr into its stdout, or cut very long
  lines; qd keeps what pdsh gives it.

**local.** This machine, without ssh: the launcher a command gets when
no hosts are named (*No hosts named: this machine*), and one you can
name (`--via local`, `QD_VIA=local`) for a host list that is this
machine: `localhost`, a 127.x address, `::1` or its hostname, once, with
no port. Any other host is refused before anything runs. The command
runs as `sh -c CMD` in a session of its own, as sshd would start it on a
host, so the rest is as over ssh: pushed files go by `cp` into a
directory of the run's own in `--remote-dir`, which only that run
removes; stdin, `--timeout` and `--max-output` (the command stopped with
everything it started), `--every`, `--retries` and the allow-list all
behave the same. Ctrl-C, or a TERM or HUP to qd, stops the command too,
since nothing else would. It runs as you (`--user` is not used) and in
the directory qd was started from.

The probes that are tools driving the fleet themselves (`health`,
`preflight`, `reach`) still reach it over ssh, and say so. `qd doctor
--via srun` (or pdsh, clush, local) checks the launcher: found here, and
for srun, the allocation qd is in. `qd doctor` also says where a command
run here would get its hosts: `--via srun`'s allocation, `QD_SERVERS`, a
`hosts.txt` or `servers.txt` in the directory, or this machine.

### What comes back

provost reads each host's answer: CSV and TSV, JSON, `key: value` and
`key = value` lines, aligned tables like `df -P` and `ss`, a lone number,
and two hundred tool-specific formats besides. A provost that has `batch`
also reads the floor-plan viewer's results format (`!test` lines over
`test target value` samples) and JSON Lines under `#` comment lines, keeps
quotes inside TSV cells, and reads nested JSON the same with or without
`jq`; PyPI's 2.1.0 drops those quotes, and nested JSON keys where there is
no `jq`. `MemTotal: 16384 kB` stays
`16384 kB`, and qd reads it as the number 16384 in kB; sizes in mixed
units (`512M` beside `50G`) are put on one scale before any statistic. A
host whose answer provost could not read as a table is held in its
`unsorted` bucket (`provost triage` says why) and its row says so. Every
host's answer is kept, exactly, either way.

Every dataset a run makes has these columns: `host`, its attributes,
`status` (`ok`, `failed`, `timeout`, `unreachable`, `push-failed`, in
agree's sense of each, and `not-run` for a host qd never tried), `rc`, `duration_s`, `error` (the first line of what
went wrong) and `capture` (provost's id for the answer), then what provost
read.

### What the login shell says first

sshd runs a command through your login shell, and that shell reads its
startup files before it runs anything: `~/.bashrc` (which bash reads
under sshd, interactive or not), `/etc/bash.bashrc`, `~/.zshenv`, conda's
or `module`'s init. Whatever they print comes back on the same stdout and
stderr as the answer: a greeting, a maintenance notice, `bash: warning:
setlocale: LC_ALL: cannot change locale`, `stty: Inappropriate ioctl for
device`. Left in, one greeting line turned a host's table into lines and
its JSON into text, and a setlocale warning became its `error`, with the
run still saying `ok`.

So qd cuts it. Every command goes out after a start line, written on each
stream by `sh -c` once the startup files have been read, just before the
command runs, and what came before that line is the shell's, not the
command's:

- it is not filed as the answer, and it is never the `error` column;
- it is kept in `qd.hosts`' `preamble` column (stdout's, then stderr's,
  up to 16 KiB): `qd show RUN:hosts`, and beside a row's raw answer in
  `qd web` and `qd view`;
- the run says so once on stderr, with where to look:

  ```
  qd: the login shell printed before the command on 2 hosts (n07, n12): cut from the answers, kept in the preamble column (qd show 20261117-101500-df:hosts); --keep-preamble leaves it in
  ```

  A run where no shell printed anything says nothing, and its hosts table
  has no `preamble` column. Either way the host stays `ok`.

It is the same through every launcher (pdsh and clush get a start line on
each host; with srun, what a node prints ahead of the task, such as a
TaskProlog's `print` lines, is cut the same way; `--via local` starts
`sh -c` here, which reads no startup files, so there is seldom anything
to cut) and for qd's own calls
on a host: the mkdir, copy, chmod and cleanup of `--push` and `--script`,
and the stop, so a failed push's row says the push's own error. The line
is written before `sudo` starts, so what sudo says is the command's.

qd cuts only at that line. Where it never comes (the command never
started, a startup file `exec`'d something else) or more than 64 KiB
came before it, nothing is cut and the host's output is kept as it came.
The command's own output is never cut, whatever it prints: the line
carries the run's random id, and qd stops looking once it has it. What is
cut is held apart from `--max-output`.

`--keep-preamble` (`QD_KEEP_PREAMBLE=1`) sends no start line and keeps it
all in the answer, as qd did before 0.23.0. Better is to quiet the host:
in `~/.bashrc`, print only for an interactive shell (`case $- in *i*)
echo hello ;; esac`) or only at a terminal (`[ -t 1 ] && echo hello`).
Output a startup file arranges to come after the command (an `EXIT`
trap) is not cut.

### When a host takes too long

A host whose command runs past `--timeout`, or sends more than
`--max-output`, is given up on: its row is `timeout` (or `failed`, rc
125, past the cap), and the command is **stopped on the host**. Killing
the local ssh is not enough: ssh asks for no terminal, so the host's sshd
does not hang the command up, and it would go on loading the host after
qd reported it finished (pdsh, pssh and parallel-ssh document the same of
theirs). So every command goes out after one line written to stderr,
which qd takes off again: the process group sshd started the command in.
When qd gives up, a second ssh sends that group TERM, then KILL 2 s later,
under `sudo -n` with `--sudo`; children it started go with it (not a
daemon that left for a session of its own). `--script` and `--push`
files are removed only after that.

The row's `error` says which: `timed out after 60s; qd stopped it on the
host`, or `..., and may still be running on the host: qd could not stop
it (why)` when the host could not be reached again, a part of the command
ran as another user, or the host never said where it ran. Such a host is
named on the run's summary (`NOT STOPPED`, `--quiet` too) and in its note
(`qd log RUN`), and its `--script`/`--push` directory is left there with
the command. A command that finishes in time comes back exactly as
before.

### Over time

```bash
qd run --every 10 --count 30 -- 'cut -d" " -f1 /proc/loadavg'
qd trend latest A                        # a sparkline per host (A: 1-min load)
```

`--every S --count N` runs N passes, one starting every S seconds, into a
single dataset with `pass` and `ts` columns. `--count 0` runs until
Ctrl-C, and every pass that finished is kept.

### When hosts fail: stop, rerun, try again

```bash
qd run -s hosts.txt --max-fail 5 -- ./check.sh     # stop starting hosts past 5 failures
qd run -s hosts.txt --max-fail 10% -- ./check.sh   # or past 10% of those started
qd run --rerun latest -- ./check.sh                # only the hosts that were not ok
qd run -s hosts.txt --retries 2 --retry-delay 5 -- uptime
```

**`--max-fail N|P%`** (`QD_MAX_FAIL`) stops a fan-out part-way. Once more
than N hosts, or more than P% of the hosts started so far (judged once
three have started, so one early failure is not 100% of the fleet), have
ended in anything but `ok`, qd starts no new host. The ones running
finish and are filed as they answered; every host it never started is a
row of its own, status **`not-run`**, so the run says exactly who was not
tried. The summary says why it stopped (`STOPPED --max-fail 5: 6 of 40
hosts started were not ok`), so does `qd log`, and the run exits 1.
`--max-fail 0` stops at the first failure (Ansible's `any_errors_fatal`,
pdsh's `-k`). It counts a command that ran and failed as well as a host
that did not answer; **`--max-fail-on unreachable`** (`QD_MAX_FAIL_ON`)
counts only the fleet's failures -- `unreachable`, `timeout`,
`push-failed` -- for a test whose failures are findings, not a reason to
stop. Each pass counts afresh, and a pass that trips it is the last.

**`--rerun RUN`** (repeatable, `latest` too) is the host list: the hosts
whose last pass in RUN ended in anything but `ok` -- unreachable, timed
out, failed, or `not-run` -- with their addresses and attributes, in
RUN's order. A host that answered on a later try (`--retries`) was ok.
The new run's record names the run it reran (`qd log`: `rerun of`; the
`rerun_of` column of `qd.runs`), and `qd diff NEW` compares it with that
run. `qd hosts --rerun RUN` lists them without running anything. This is
host by host where `qd campaign retry` is part by part: a rack with one
bad host is one host here, the whole rack there. `qd campaign run` takes
no `--rerun`; `qd campaign new --rerun RUN ...` makes a campaign of them.

**`--retries N`** (`QD_RETRIES`, 0) tries a host that was `unreachable`
or timed out again within the run, up to N more times, `--retry-delay S`
apart (`QD_RETRY_DELAY`, 0). Every try is a row, with an **`attempt`**
column, so a flaky host is seen rather than hidden by its last success,
and the run's note names it. A command that ran and failed (rc != 0) is a
finding and is not tried again without **`--retry-failed`**; a host where
qd gave up on the command and could not stop it (`NOT STOPPED`, above)
is never tried again, since another try would measure a busy node.
Retries are off by default: a run reports what happened.

**Ctrl-C keeps what answered.** The pass it comes in is filed as far as
it got: the hosts that had answered, as they answered; the ones still
running and the ones not started, `not-run` (`qd: interrupted (Ctrl-C)
before it answered`, `qd: not started: interrupted (Ctrl-C)`). What the
running ones say after Ctrl-C is not kept. `--rerun latest` picks them up.
Through pdsh or clush one call answers for every host, so a pass
interrupted there keeps none of it: every host is `not-run`.

`not-run` is a status like any other that is not `ok`: its `rc`,
`duration_s` and `ts` are blank, never zero, and `qd stats`, `qd
compare`, `qd check` and `qd report` count it as not measured. With
`--max-fail` or `--retries`, pdsh and clush go host by host, so qd can
stop or try again between hosts. `qd probe`, a campaign's parts and a
design's points run through the same fan-out and take the same flags.
`--dry-run` says what they would do (`qd: plan: ...`, on stderr).

### Scripts, sudo, and safety

| Flag | |
|---|---|
| `--script FILE -- ARGS` | push FILE, run it with ARGS, remove it again |
| `--push FILE` | copy a file over first (repeatable); the command runs beside it, in a directory of the run's own in `--remote-dir` |
| `--sudo` | run under `sudo -n` |
| `--dry-run` | print the ssh (or srun, or local `sh -c`) command per host, or the one pdsh or clush call, less the lines qd puts ahead of the command (where it starts, see *What the login shell says first*; for ssh, how to stop it, see *When a host takes too long*); contact nothing |
| `--first N` | the first N hosts only, the canary before the fleet |
| `--limit N` | refuse to run wider than N hosts without `--yes` |
| `--no-store` | print the answers, keep nothing |

The mutation guard is agree's: `rm -rf`, `mkfs`, `reboot`, `systemctl
stop` and the rest are refused without `--yes`. It's a typo guard, not
security.

**qd deletes only what it made.** A run that pushes makes a directory of
its own, `qd.<run id>`, in `--remote-dir`, and writes `.qd-owned` into it
with that id. Afterwards it removes that directory, and `--remote-dir`
only if this run made it and it is empty. The checks run on the host,
under the same `sudo -n` as the delete: the path must end in exactly this
run's `qd.<run id>`, hold no `..`, be a directory and not a symlink, and
hold a `.qd-owned` with this run's id. Otherwise nothing is deleted, and
the host's `error` says `qd: refusing to remove` and why.
`--keep-remote` leaves the directory, mark and all.
`tests/test_cleanup.sh` holds qd to this.

### Allow-lists and read-only

The mutation guard says what may *not* run, and no such list is ever
complete. For a system under test that must not be changed, say what
*may*:

```bash
cat allow.txt
# what may run on the system under test
uname *
cat /proc/*
nvidia-smi --query-gpu=* --format=csv

qd run --allow allow.txt -s hosts.txt -- uname -r       # runs
qd run --allow allow.txt -s hosts.txt -- echo hi        # refused
qd run --allow allow.txt --confirm -s hosts.txt -- echo hi   # asks: type CONFIRM
qd probe facts inventory --read-only -s hosts.txt       # probes still run
```

- **`--allow FILE`** (`QD_ALLOW`): one pattern a line, `#` for comments.
  A pattern matches the whole command as it would be sent (spaces
  collapsed), with `*` for anything and `?` for one character, so
  `uname *` does not allow `uname -r; reboot`. A command no pattern
  matches is refused, with exit 2, unless `--confirm` is given *and*
  someone at the terminal types `CONFIRM`; with nothing attached to the
  terminal it is refused outright. The probes qd ships run by name;
  your own (`qd probe add`) do not: their command must match, as `qd
  run`'s does.
- **`--read-only`** (`QD_READ_ONLY=1`): only the probes qd ships and
  allow-listed commands run, and no confirmation lifts it. A probe you
  saved is a command like any other here. `--push`, `--script` and
  `--sudo` are refused, and so is `qd do`, whose tools deploy agents and
  servers to the hosts.
- **On record:** every run under a policy says so in its notes (`qd log
  RUN`): read-only, the allow-list's name and the first 12 hex digits of
  its sha256, and any command confirmed outside it, with who confirmed.
  A refusal files no run, so each one is appended to `policy.log` in
  qd's cache (`~/.cache/quarterdeck/`): time, operator, verb, command and
  reason, tab-separated.
- The mutation guard still applies on top: an allow-list that names
  `rm *` does not let `rm -rf` past it without `--yes`.

**This is policy, not a sandbox.** An allow-listed shell, a script the
hosts already hold, or a quoting trick gets past any list of patterns.
It stops the mistakes and the out-of-scope commands; the real control is
the account's own ssh and sudo rights on the hosts.

### Bastions, certificates, Kerberos and MFA

qd runs the system's OpenSSH (`ssh`, `scp`) with three options of its
own: `BatchMode=yes`, `ConnectTimeout=8` and
`StrictHostKeyChecking=accept-new`. Everything else comes from your ssh
config, so whatever it can do, qd does: a bastion, certificates, Kerberos,
a connection held open. Two flags help, and `qd doctor HOST` shows what
ssh will do for a host before anything runs.

| | |
|---|---|
| `--ssh-config FILE` (`QD_SSH_CONFIG`) | ssh and scp read FILE (`ssh -F`) instead of `~/.ssh/config`: a test event's own config, and yours untouched. `qd doctor`, the `ssh_user` a run records and a remote store's git read it too |
| `--reuse` (`QD_SSH_REUSE=1`) | one ssh login per host for the whole command (below) |
| `qd doctor HOST` | what qd's ssh resolves for HOST (`ssh -G`, which reads the config and contacts nothing): user, port, the bastion and the bastion's own settings, the certificate and the dates it is valid, the identity files that exist, Kerberos and whether a ticket is held, a master and whether it is open, BatchMode. `--ssh-config`, `--user` and `--ssh` as for `qd run` |

**`BatchMode=yes` means nothing can be typed.** No password, passphrase,
one-time code or "are you sure?" about a host key: anything that would
ask fails that host instead, reported unreachable with ssh's reason. That
is what you want across five hundred hosts, and it means every setup below
logs in without a prompt: a key in an agent, a certificate, a Kerberos
ticket, or a master already open.

**A bastion (ProxyJump).**

```
Host bastion
    HostName bastion.example.mil
    User ops
    BatchMode yes
    StrictHostKeyChecking yes      # its key already in known_hosts
Host node-* 10.20.*
    ProxyJump bastion
    User ops
```

```bash
qd doctor node-01 --ssh-config event.cfg
qd run --ssh-config event.cfg -s hosts.txt --rate 10/s --reuse -- uname -r
```

ssh reaches the bastion with a second ssh, which reads the config file
and **none of qd's `-o` options**. So the bastion's own `Host` block needs
`BatchMode yes`, or that hop can stop at a prompt on your terminal in the
middle of a run. Its host key must be known already, or that block must
say `StrictHostKeyChecking accept-new`: qd's `accept-new` does not reach
it. `qd doctor` shows the bastion's own settings and says when one would
stop a run. `--rate` keeps qd inside the bastion's `MaxStartups` (see At
scale), and `--reuse` makes one hop per host instead of one per call.

**SSH certificates.** ssh offers `KEY-cert.pub` beside `KEY` by itself;
name one kept elsewhere with `CertificateFile`:

```
Host node-*
    IdentityFile ~/.ssh/id_ed25519
    CertificateFile ~/.ssh/id_ed25519-cert.pub
```

`qd doctor HOST` shows the certificate ssh will offer and its `Valid:`
dates (`ssh-keygen -L`). A certificate past its date is the usual reason a
whole fleet starts refusing at once.

**Kerberos (GSSAPI).** With a ticket (`kinit`) and

```
Host *.example.mil
    GSSAPIAuthentication yes
    GSSAPIDelegateCredentials no
```

ssh logs in with the ticket, and nothing is asked. Get the ticket before
the run, and one that outlasts it: qd cannot renew it. `qd doctor HOST`
says whether GSSAPI is on for the host and whether `klist -s` finds a
ticket.

**MFA (a one-time code, a card PIN).** A login that asks for a code
cannot happen under BatchMode. Open a master to each host, or only to the
bastion where only the bastion asks, by hand, once; every call qd makes
then rides on it:

```
Host bastion node-*
    ControlMaster auto
    ControlPath ~/.ssh/cm-%C
    ControlPersist 8h
```

```bash
ssh -fN bastion                    # type the code once
qd doctor node-01                  # controlpath ...: a master is open
qd run -s hosts.txt -- uptime      # no prompt: the hop rides the master
```

Leave `--reuse` off for this: it opens masters of its own, in a directory
of its own, and would not find yours.

**Connection reuse: `--reuse`.** Every call qd makes to a host is a new
ssh login: a push run makes four or five (make the run's directory, copy,
`chmod`, run, clean up), and `--every 10 --count 30` thirty. `--reuse`
makes one per host for the whole command (`ControlMaster`). On a real
sshd, a push run on one host went from five logins to one
(`tests/test_ssh.sh`).

- The sockets go in a new directory of this command's own,
  `qd-ssh-XXXXXXXX`, mode 0700, in `TMPDIR`, or in `/tmp` where `TMPDIR`
  is too long for a socket's path, as macOS's is (104 bytes on macOS, 108
  on Linux, and ssh's own name for a socket takes 58 of them). Each
  socket is `%C`, a hash of the host, port and user.
- A master idles 60 s for the next call (`ControlPersist`), or, with
  `--every`, until the next pass.
- When qd ends (done, failed, Ctrl-C, `kill`, a closed terminal) it
  closes every master with `ssh -O exit`, which talks to the socket and
  not the host, and removes the directory. A `kill -9` leaves the masters
  to close themselves after `ControlPersist`.
- `--dry-run` shows the options it adds, and `qd probe A B` shares
  one set of masters between its runs.

### Every knob has a flag and a variable

| Flag | Variable | Default |
|---|---|---|
| `--servers` | `QD_SERVERS` | `hosts.txt` or `servers.txt`; with neither, this machine |
| `--via` | `QD_VIA` | `ssh`, or `local` when no hosts are named; or `srun`, `pdsh`, `clush`, `local` (see Reaching the hosts) |
| `--user` | `QD_SSH_USER` | your ssh config |
| `--jobs` | `QD_JOBS` | 32 hosts at once |
| `--timeout` | `QD_TIMEOUT` | 60 s per host; past it the command is stopped on the host and reported |
| `--max-output` | `QD_MAX_OUTPUT` | 4 MiB per host; past it the command is stopped on the host and reported |
| `--ssh`, `--scp` | `QD_SSH`, `QD_SCP` | `ssh`, `scp` |
| `--ssh-config` | `QD_SSH_CONFIG` | none: ssh's own, `~/.ssh/config` |
| `--reuse` | `QD_SSH_REUSE=1` | off: a login per call |
| `--remote-dir` | `QD_REMOTE_DIR` | `/var/tmp` |
| `--keep-preamble` | `QD_KEEP_PREAMBLE=1` | off: what a host's login shell prints before the command is cut from its answer (see What the login shell says first) |
| `--rate` | `QD_RATE` | none: new connections as fast as `--jobs` allows; `10/s` for a bastion's `MaxStartups` |
| `--max-fail` | `QD_MAX_FAIL` | none: every host runs; `N` or `P%` stops starting hosts past it |
| `--max-fail-on` | `QD_MAX_FAIL_ON` | `any`: every status but ok; `unreachable` counts only the fleet's failures |
| `--retries` | `QD_RETRIES` | 0: a host is tried once |
| `--retry-delay` | `QD_RETRY_DELAY` | 0 s between tries |
| `--allow` | `QD_ALLOW` | none: every command may run |
| `--read-only` | `QD_READ_ONLY=1` | off |
| | `QD_OPERATOR` | your login user: who a run says ran it (see Who ran it) |
| `--store` | `QD_STORE` | a name from `qd store ls` or a directory; else the active store (see Named stores) |
| | `QD_PROVOST` | `provost` on `PATH` |
| | `QD_PROVOST_BATCH=0` | file one capture at a time even where provost has `batch` |
| | `QD_FILE_JOBS` | one capture at a time: one provost after another. N files N at once, but only where `mkdir --version` is not uutils coreutils' before 0.11.0 (Ubuntu 25.10 and 26.04): there two can share provost's lock and lose a capture. With `batch`: its `-j` |
| | `QD_FILE_CHUNK` | 200 inputs per `provost batch`, each a commit, so its lock is never held for a whole big fleet |

Exit status is 0 when every host answered, 1 when one didn't (or
`--max-fail` stopped the run), and 2 for a usage error.

---

## Who agrees, who differs: `qd ask`

"What does every host say about X?" in one step: `qd ask` is `qd run`
followed by `qd freq latest A`, `A` being the answer's column (provost
names a column nothing names `A`, `B`, ...; see
[Concepts](concepts.md#the-objects)). It runs the command, files
the run exactly as `qd run` would, and prints the consensus instead of
the whole table: each answer, how many hosts gave it and who they are,
the most common first; then the hosts that did not answer, and why.

```bash
qd ask -s hosts.txt -- uname -r            # who runs which kernel
qd ask -- uname -r                         # no hosts named: this machine (--via local)
qd ask -s hosts.txt --sudo -- 'sysctl -n vm.swappiness'
qd ask --rerun latest -- uname -r          # only the hosts that did not answer last time
```

```text
qd ask -- uname -r: 4 hosts, 3 ok, 1 unreachable   [provost: uname: A]
  stored   20261118-201754-uname in ~/.provost  (4 rows, 3 captures c0001..c0003)

  ANSWERS  2 different answers from 3 hosts (column A)
    2  6.1.0-18-amd64
       node01 node02
    1  6.1.0-13-amd64
       node03

  DID NOT ANSWER
    node09  unreachable      ssh: connect to host node09 port 22: Connection timed out

  NOT ALIKE  1 host did not answer (the run); 2 different answers (the count)

  WHAT TO DO NEXT
    * qd freq latest A                   the count above, as qd freq gives it
    * qd show latest --where status!=ok  the 1 host that did not answer, with why
    * qd run --rerun latest -- ...       the same again on only those 1 host
    * qd show latest                     every host's answer, as a table
    * qd view latest                     explore it full-screen
```

- **Every host option `qd run` takes** (`-s`, `-S`, `--layout`/`--select`,
  `--first`, `--rerun`), and its ssh, failure and safety options (`--via`,
  `--sudo`, `--push`, `--script`, `--retries`, `--max-fail`, `--dry-run`,
  `--limit`, `--allow`, `--read-only`, ...), with the same `QD_*`
  variables. It is one pass and always kept: `--every`, `--count` and
  `--no-store` are `qd run`'s.
- **A host list longer than eight** is cut short (`(+N more)`); `qd freq
  latest A --all-labels` names every host, and WHAT TO DO NEXT then says
  so.
- **A host that answered but printed nothing** is shown apart, as
  `(printed nothing)`: blank is not measured, so it is not an answer that
  agrees with anything.
- **An answer of several columns** (`df`, `cat /proc/meminfo`) has no one
  value to count. `qd ask` says so and prints `qd run`'s summary instead,
  with its preview and its next steps; `qd freq latest COLUMN` counts one
  of them.

Exit status is 0 when every host answered and all said the same, 1 when
a host did not answer or the answers differ (the verdict line names
which: *the run* or *the count*), and 2 for a usage error.

---

## Asking by name: `qd probe`

```bash
qd probe                                  # the catalogue, and what's installed here
qd probe facts inventory -s hosts.txt     # each probe is a run of its own name
qd show facts --cols host,cpu.busy_pct,mem.available_pct
```

| Probe | Kind | What |
|---|---|---|
| `facts` | binnacle, on each host | why-slow `--facts`: cpu.\*, mem.\*, disk.\*, net.\*, fs.\*, lim.\*, cg.\*, therm.\* |
| `why-slow` | binnacle, on each host | why-slow's findings: rule, severity, detail, fix |
| `skew` | binnacle, on each host | clock and time sync |
| `health` | dcprobe, from here | load, CPU, iowait, steal, memory, swap, disk, NIC link and drops, kernel errors, inventory |
| `preflight` | dcprobe, from here | ssh, skew, nofile, bind, tools: before a test |
| `reach` | binnacle, from here | `reachable --csv`: ping and ssh, and why not |
| `firmware` | a shell command | BIOS, board, CPU microcode; per NIC its driver, firmware, offloads, rings, coalescing, pause and MTU (below) |
| `os`, `sysctl`, `services`, `gpu`, `mounts`, `disks`, `packages`, `numa`, `pagecache`, `listen`, `containers` | a shell command | what none of the instruments measures |

Groups: `inventory` (os, firmware, disks, mounts, numa, gpu, packages), `settings`
(sysctl, numa), `state` (services, listen, containers, pagecache). A
binnacle tool is sent to `python3 -` on each host over ssh's stdin, as
why-slow's own `--ssh` sends itself: one connection per host, nothing
copied there and nothing left behind. The hosts need python3, and binnacle
needs to be installed here, nowhere else. A probe whose tool isn't here
says what to install before it contacts a host.

**`firmware`** reads what a host's firmware and NICs are set to, without
root, so that the one host configured differently can be found (`qd
outliers firmware --categorical`, below). One row per NIC (an interface
with a device behind it, so not `lo`, a bridge or a veth), with the host's
own fields beside each:

- `bios_vendor`, `bios_version`, `bios_date`, `bios_release`,
  `board_vendor`, `board_name`, `board_version`, `product_name`,
  `product_version`, `product_family`, `sys_vendor`: the world-readable
  files in `/sys/class/dmi/id`. Serials and UUIDs are root-only and are
  never asked for. A file that is there but unreadable says `needs root`;
  a host with no DMI at all (many VMs) says `dmi: absent`.
- `microcode` and `cpu_model`, from `/proc/cpuinfo`.
- per NIC: `mtu` (from `/sys/class/net`), and from ethtool `driver`,
  `driver_version`, `firmware_version`, `bus_info` (`-i`), every offload
  as `offload.NAME` (`-k`, `[fixed]` dropped), `ring.rx` and
  `ring_max.rx` and the rest (`-g`), `coalesce.NAME` (`-c`), and
  `pause.NAME` (`-a`). Every `key: value` line ethtool prints is kept, so
  a driver's own settings come through, and what a driver cannot say
  (virtio has no firmware version and no coalescing) is left blank: not
  measured. No MAC address is read.
- `ethtool: not installed` when it is not on the host: the DMI and
  microcode rows are filed all the same.

BMC firmware needs ipmitool and root, and is not read.

The probes you name run together. Every host is asked every probe at once,
`--jobs` at a time in all. Every run is then filed by one provost call, in
one commit, and each is still a run of its own name. Asked one after
another, each probe paid its own round of ssh, its own 8 s wait on a host
that is down, and its own provost call. On six hosts, `qd probe facts
inventory` went from 41 s to 26 s. The tools that drive the fleet from here
(`health`, `preflight`, `reach`) run after them, one at a time. With
`--every` or `--count`, the probes run one after another as before.

The shell probes are POSIX sh, run the same under bash, dash and busybox
ash, and read `/proc` and `/sys` where a command might be missing (`disks`
from `/sys/block`, sizes in bytes; `mounts` from `/proc/self/mounts`). A
host without what a probe asks says so (`listen_tool: none`, `system_state:
no systemd`, `nvidia_smi: absent`), and a value it could not read is left
out: blank, never 0 or "unknown". They were run against Debian 12, Ubuntu
24.04, Rocky 9 and Alpine 3.20 over real ssh.

### Your own probes: `qd probe add`

A command you run often can have a name, and be asked for by it like the
probes qd ships:

```bash
qd probe add NAME [--note TEXT] -- COMMAND   # save it (--replace to save over one of yours)
qd probe                                     # listed beside qd's own, kind "yours", the command in full
qd probe NAME -s hosts.txt                   # run it: a run named NAME
qd probe rm NAME                             # forget it
```

`qd probe NAME` runs a saved probe exactly as `qd run --name NAME --
COMMAND` would: on every host, with every fleet option `qd probe` takes
(`--jobs`, `--timeout`, `--every`, `--count`, `--retries`, `--via`,
`--sudo`, `--dry-run` ...), filed as a run named after the probe, so `qd
show NAME`, `qd compare NAME --last 5` and `qd check NAME` find it. Its
notes say `your probe NAME`. Named beside qd's own (`qd probe os
fio-randread`), it runs after them, a run of its own.

- **The name** is the run's: letters, digits, `.`, `_` and `-`, starting
  and ending with a letter or digit, at most 64. A probe or group qd ships
  (`facts`, `inventory` ...) and the words `add`, `rm` and `latest` are
  refused, exit 2, and so is `add` over a name you have saved already,
  unless `--replace`.
- **Where it is kept:** `probes.json` beside qd's own config, in
  `~/.config/quarterdeck/` (`$XDG_CONFIG_HOME/quarterdeck/`). Never in a
  store: a store exported from another machine, or read from one, brings
  its runs, never a command to run on your fleet. Your probes go with your
  account, not with the data.
- **It is not a probe qd ships.** "The probes qd ships run by name" does
  not extend to it: under `--allow` its command has to match a pattern
  (its name is not enough), under `--read-only` with no allow-list it is
  refused, and the mutation guard reads its command, so a saved `rm -rf`
  needs `--yes` every time it runs (`add` warns). A probe asked beside qd's
  own is checked before any of them runs. A saved probe is never a way
  around a policy.

**A worked example: fio.** [fio](https://fio.readthedocs.io/) measures
storage, and `--output-format=json` makes its answer one JSON document,
which provost files as a row a host:

```bash
qd probe add fio-randread --note "4k random reads, 30 s, in /var/tmp" -- \
  fio --name=randread --rw=randread --bs=4k --size=256M --runtime=30 --time_based --directory=/var/tmp --direct=1 --ioengine=libaio --iodepth=4 --output-format=json
qd probe fio-randread -s hosts.txt
qd show fio-randread --cols host,jobs.0.read.iops,jobs.0.read.bw,jobs.0.read.clat_ns.percentile.99.000000
qd compare fio-randread -c jobs.0.read.iops --last 5
qd check fio-randread --against fio-limits.tsv
```

The columns are fio's JSON keys, flattened by provost with dots, a list's
elements numbered from 0. The ones to read first:

| Column | What |
|---|---|
| `jobs.0.read.iops` | read IOPS (`write.`, `trim.` alike) |
| `jobs.0.read.bw` | bandwidth in KiB/s (`bw_bytes`: bytes/s) |
| `jobs.0.read.clat_ns.percentile.99.000000` | completion latency's 99th percentile, in ns (`.50.000000`, `.99.900000` ...) |
| `jobs.0.read.lat_ns.mean` | total latency's mean, in ns (`min`, `max`, `stddev`) |
| `jobs.0.usr_cpu`, `jobs.0.sys_cpu` | fio's own CPU, percent |
| `disk_util.0.util` | the device's utilisation, percent (`disk_util.0.name` says which) |

A limit on IOPS and one on the tail, for `qd check` (the latency column
carries no unit, so the limit says ns):

```text
req    column                                    op  limit   agg  unit
STO-1  jobs.0.read.iops                          >=  20000   min
STO-2  jobs.0.read.clat_ns.percentile.99.000000  <=  250000  max  ns
```

fio needs a writable directory with room on each host, and loads the
disk while it runs: keep `--size` small, use `/var/tmp` (not a tmpfs
`/tmp`), and do not point it at a busy host's data disk. `--rw=randwrite`
or `write` writes `--size` bytes into `--directory` (fio leaves the file
there unless `--unlink=1`), so a saved write test is one an allow-list
should name on purpose. provost reads fio's `"fio version"` and `"job
options"` keys, which have a space in them, as a key and a value (a `fio`
column of `version fio-3.36`): the figures above are not affected.

### Every host, and who stands out: `qd survey`

```bash
qd survey -s hosts.txt      # qd probe facts inventory, then one screen
qd survey                   # no hosts named: this machine
```

`qd survey` asks every host the standard questions -- it runs `qd probe
facts inventory`, the same runs under the same names, with the same host
options, `--store`, `--via` and `--sudo` -- and then prints one screen, about
40 lines at most for any fleet, in place of each probe's report:

- **WHAT MOST HOSTS SAY**: for a fixed, short list -- `os` and `kernel`
  (from `os`), `bios_version` and `cpu_model` (from `firmware`),
  `cpu.count` and `mem.total_kb` (from `facts`) -- the most common value,
  and how many hosts said it of those that measured it. A blank is not
  measured: not a value, and not counted.
- **WHO DIFFERS FROM THE REST**: those columns, as `qd outliers RUN
  COLS --categorical` holds each host against the majority of its rack.
- **FAR FROM THE MEDIAN**: `facts`' `cpu.busy_pct`, `cpu.load1`,
  `cpu.iowait_pct`, `mem.available_pct`, `fs.fullest_pct`,
  `net.tcp_retrans_pct` and `therm.max_temp_c`, and `packages`' count, by
  the median and MAD, as `qd outliers` reports them.
- **DID NOT ANSWER**: the hosts that did not answer every probe, and why.

Each section names three hosts and counts the rest. `FOUND` says what
stood out and which step found it, and WHAT TO DO NEXT lists the plain
commands, with real column names, to see all of it: `qd probe facts
inventory ...`, `qd freq os kernel`, `qd outliers os os,kernel
--categorical`, `qd outliers facts mem.available_pct`.

Without binnacle here, `facts` is skipped and named, with how to get it
(`pip install binnacle`), and the rest runs. With no hosts named it
surveys this machine, which has nothing to compare against: `qd demo`
makes a practice fleet for that. Exit status: 0 when every host answered
and nothing stands out, 1 otherwise, 2 on a usage error.

---

## Driving the toolchain: `qd do`

`qd do` runs a tool here, with its output on your screen as usual. It
records the command, the tool's version and its exit status, then reads
back what the tool wrote:

```bash
qd do -- mx run --for 60
qd do -- iperf-orchestrator --servers servers.txt run
qd do -- agree script why-slow --servers servers.txt --fleet-csv -- --csv
qd do -- reckon floor.dc --mx reports/ --overlay reckon.tsv
qd do -- dcprobe scan --servers hosts.txt -o host_status.tsv
qd do -- netmesh check --reports idle/ web03 db01
```

| Tool | What is read back |
|---|---|
| `mx run`, `mx summarize` | `reports/` (`--reports`, `MX_REPORTS`) as table `reports`, then `mx export --no-collect --json` as table `mx_export`. That's no ssh, and it's the overlay numbers mx computes by its own rules |
| `mx export` | `-o FILE`, or what it printed |
| `iperf-orchestrator` | `results/<run>/` after `run`, `all`, `summarize`, `process`, `parse-csv`, `export-overlay`: `iperf_results`, `cpu_summary` and the overlay |
| `agree` | `--json`, `--csv`, `--merge-csv` files. With none of them, qd adds `--csv` (and `--merge-csv` for `script`) and says so |
| `dcprobe` | `-o FILE`, else where it writes unasked (`host_status.tsv` after `scan` and `watch`, `preflight.tsv` after `preflight`), and `--history FILE` |
| `reckon` | `--overlay`, `--csv`, `--json` files |
| `netmesh` | `--reports DIR`, `--grid DIR` |
| any `--csv PATH` | that file; a bare `--csv` prints to stdout |
| anything else | stdout, when it is a table, or when nothing else came back: filed for provost to read |

Only what the tool wrote this time is filed. A run that fails before it
writes leaves the last run's `results/latest` where it was, and that is
said and left alone, not filed as this run's. `--import PATH` reads more
files afterwards, whatever they hold; `--no-import` reads nothing
back. A tool is found on `PATH`, as an installed module, or wherever
`QD_<TOOL>` points (`QD_MX="python3 ~/src/matrix_orchestrator/mx"`).
`qd doctor` says which tools this machine can drive (and `qd doctor
HOST` how ssh reaches a host: see Bastions, certificates, Kerberos and
MFA). The exit status is the tool's.

Each table read back is filed in provost as a capture of its own, as
TSV, its notes and display metadata kept with it.

**`qd import PATH...`** files output that's already on disk: a file in any
format below, mx's `reports/`, netmesh's
`--reports`, an iperf `results/` directory (its `latest` run) or one run
of it, or a folder of monitoring tables. Files in a folder that share a
header stack into one table. A folder of grids (netmesh's `--grid`)
becomes one table with a row per pair and a column per grid: `rtt_p50`,
`loss`, `mtu`. Stacking them would put rtt and loss in one column.

### Formats read

Every reader works on what's *inside* a file, never its name:

- **CSV and TSV**: `iperf_results.csv`, mx and netmesh reports, every
  binnacle `--csv`, `agree --merge-csv`.
- **The floor-plan viewer's results format**: `test target value
  [key=value ...]` with its `!test` lines. That covers mx export, iperf
  export-overlay, reckon `--overlay`, dcprobe and dcimport. The `!test`
  metadata (units, labels, palettes) is kept and written back out
  unchanged.
- **NDJSON and JSON**: the same results as objects, `agree --json` (two
  tables, `hosts` and `groups`), or any list of objects.
- **`src\dst` grids**: mx `matrix.csv` and `--grid`, netmesh grids,
  `iperf gen --grid`. They become one row per measured pair. Blank cells
  are pairs that weren't measured, and they stay out.
- **Wide tables**: `Timestamp host rtt (us) loss %`, which is what
  monitoring writes and the viewer reads. A commented-out header works.
- **Telemetry exports**, with `qd import --telemetry`: Splunk, CloudVision,
  Prometheus or a gNMI collector's samples, kept as one `time, host,
  metric, value` table for `qd join` (see *Beside the telemetry*).
- A BOM, CRLF line ends and a header repeated mid-file are all handled.

---

## At scale

A thousand hosts fan out in seconds at the default `--jobs 32`. qd's
memory (about 25 MB) and threads (`--jobs` + 1) do not grow with the
fleet. Filing the answers is what takes the time, about 0.16 s each in
provost. Two limits matter more than raw size:

- **Open files:** about 5 per host in flight. qd raises its soft
  `ulimit -n` towards the hard one before a fan-out. If that is still
  short, it runs fewer at once and says so, rather than letting hosts
  that could not get a pipe read as unreachable. macOS's default of 256
  fits about `--jobs 50`.
- **A bastion:** sshd drops connections past its `MaxStartups`, so
  through one jump host use `--rate 10/s` (`QD_RATE`).

The numbers, and how they were measured, are in
[docs/scale.md](scale.md) (`tests/scale.sh` reruns them).
