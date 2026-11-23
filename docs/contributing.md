<!--
SPDX-License-Identifier: GPL-3.0-or-later
SPDX-FileCopyrightText: 2026 Martin J. Gallagher
-->

# Contributing: tests and working on quarterdeck

The test suite, what CI runs, and how to work on qd itself. Part of
[the manual](README.md).

## Tests

```bash
bash tests/run_tests.sh             # every suite, one per core at a time
bash tests/run_tests.sh run web     # some of them
bash tests/run_tests.sh -j 1        # one at a time, each suite's output as it comes
bash tests/run_tests.sh --shard 2/3 # the second of three shares, as CI runs it
bash tests/run_tests.sh --list      # which suites a run would take; runs none
```

The suites run side by side: `-j N` (or `QD_TEST_JOBS=N`) runs N at a
time, and the default is the machine's core count. Each suite's output is
held until it ends and then printed whole, in name order, so the log reads
as it does one at a time; the slowest suites start first, and the run ends
with its wall time, the three longest, and every suite's seconds. `-j 1`,
or naming a single suite, is the serial run. Ctrl-C stops every suite still
running, and each case still clears up after itself. Suites can share a
machine because every case has a temp dir, a store and XDG directories of
its own, and each suite that starts a web server has a range of ports of
its own. On four cores the whole suite takes about seven minutes.

Most of a suite's time is provost filing runs, so a setup that files runs
and that several cases start from is made once a suite, not once a case:
the suite calls `use_fixtures`, and a case calls `fixture NAME FUNCTION`
where it would have called `FUNCTION`. The first case to ask runs it; each
later one gets a copy of what it left (the store, the fake hosts, every
file, the variables it exported or unset), so it starts exactly where it
would have. A suite's cases then all run in one directory path, because a
store records its path. Use it only for a setup that is a case's first
step, and give two setups that differ in anything two names (QD-074).

`--shard K/N` runs share K of N, which is how CI spreads one job over N
runners. The suites are dealt by their measured seconds (`TIMES` in
`tests/run_tests.sh`), the longest first, each to the share with the
fewest seconds so far, so every machine deals the same way. The longest
suites (`PARTS` there) are split into parts, each a share of their cases
(`QD_TEST_PART=I/P` runs the Ith case and every Pth after it), and each
part goes to a different share. `tests/check_shards.sh` checks that every
suite is in exactly one share, whole or as all of its parts, and that CI's
jobs run every share. A new suite goes into `TIMES`, with its seconds from
a run's last line (`seconds:`; a part is named there as `doe:2/3:56`, and a
suite's parts add up to its seconds); `tests/test_runner.sh` fails until it
is there.

### What CI runs

On every pull request and every push to `main` (`.github/workflows/ci.yml`):

| Job | Runs | Runners |
|---|---|---|
| test (python 3.9 to 3.13) | the whole suite, PyPI's newest provost (`batch`), binnacle, and doe from 3.10 | 3 each, `--shard 1/3` to `3/3` |
| Python 3.6 compatibility | vermin and the compile check, then the whole suite under a real Python 3.6 in a container, provost's bundle | 3 |
| test (provost 2.1.0) | the whole suite, one capture at a time | 3 |
| ssh (a real sshd on loopback) | `test_ssh.sh` with openssh-server installed and `QD_TEST_SSHD=require`: a bastion, `--reuse`, a master opened first, a certificate, a `~/.bashrc` that prints | 1 |
| version, web page syntax, shellcheck and the shard check, REUSE, build the wheel | once each | 1 each |

A newer push to a pull request cancels that pull request's run still in
progress; a push to `main` is never cancelled, so the version check on
every push to `main` always runs. Every job has a time limit well above
its usual time (15 minutes for a share of the suite, 25 on provost 2.1.0,
which files one capture at a time), so a case that hangs fails its job
within minutes, not GitHub's six hours.

The tests need no network and no second machine, but a real provost
(`pip install provost`, or `QD_PROVOST`): every case files into a store of
its own. `QD_PROVOST_BATCH=0` runs them on the one-capture-at-a-time path.
`ssh` and `scp` are replaced by a shim that runs the "remote" command in a
sandbox directory per fake host, and `srun`, `scontrol`, `pdsh`, `pdcp`
and `clush` by stand-ins that reach the same hosts and say what the real
ones say (`tests/test_via.sh`); Slurm, pdsh and clush themselves never run
in the suite. mx, iperf-orchestrator, agree, dcprobe
and doe are replaced by stand-ins that write what the real ones write,
where they write it; muster and the probes' binnacle scripts are the real
ones where binnacle is installed, and doe too where it is. The explorer is
driven by a script of keys (`QD_TEST_KEYS`, as binnacle's `rig` does it)
and the web suite talks to a real server on loopback.

`tests/test_demo.sh` files the demo on a fresh home with no ssh on
`PATH`, then runs every ```` ```console ```` block of
[Getting started](getting-started.md) in order (`tests/walkthrough.py`)
and fails when a command prints anything but what the page shows, or exits
with a status the page does not show. After a change meant to alter what a
command prints, `QD_WALKTHROUGH_UPDATE=1 QD_TEST_ONLY=walkthrough bash
tests/test_demo.sh` writes what they print back into the page, to read in
the diff.

`tests/test_ssh.sh` records every argv the fake ssh and scp are given,
and then, where `sshd` is installed, starts a real one of its own on
loopback, as the user running it, to log in through: a ProxyJump through
it as a bastion, `--reuse`'s one login per host, a master opened
beforehand carrying a run once the key is withdrawn (the MFA setup), a
certificate login, and a `~/.bashrc` that greets, warns and runs `stty`,
cut from the answers by what real sshd and bash do at login (the login's
`HOME` is the case's own, through `authorized_keys`' `environment=`, so
this user's own `~/.bashrc` is never touched). `tests/test_preamble.sh`
plays a printing login shell through the fake ssh (`FAKE_SSH_RC`), and
`tests/test_via.sh` through each launcher. Where there is no sshd those
cases are skipped and
named; `QD_TEST_SSHD=require`, as in CI's ssh job, fails them instead.
`tests/test_remote.sh` reads a store made in git's SHA-256 object format
(`provost init --object-format sha256`); where git is older than 2.29 or
provost's `init` has no `--object-format` those cases are skipped and
named, and `QD_TEST_SHA256=require`, as in CI's store-check job, fails
them instead.
Kerberos is not tested: it needs a KDC. `qd doctor`'s reading of `klist`
is, with stand-ins.

---

## Working on quarterdeck

```bash
python3 -m venv ~/.venvs/qd && . ~/.venvs/qd/bin/activate
pip install provost binnacle doehelper           # what the suites drive
pip install vermin reuse build twine shellcheck-py   # what the checks use
bash tests/check.sh                              # everything below, before pushing
```

`tests/check.sh` runs every check CI runs that can run on one machine, in
CI's order, and ends with a summary:

| Check | Tool |
|---|---|
| the version agrees in `quarterdeck/__init__.py`, `pyproject.toml` and the top of `CHANGELOG.md` | `tests/check_version.sh` (CI too; CI also checks it is greater than the base branch's) |
| every module compiles; no post-3.6 stdlib API | `tests/check_python_compat.sh`, vermin |
| the test harness | shellcheck `-e SC1091` |
| the page parses | `node --check quarterdeck/web/app.js` |
| licensing headers | `reuse lint` |
| the wheel builds and its metadata is valid | `python -m build`, `twine check` |
| the whole suite, with provost's `batch` and with `QD_PROVOST_BATCH=0` | `tests/run_tests.sh` |
| every store the batch run's cases leave is one provost's spec allows | `provost store check` (provost 2.16.0 on), with `QD_STORE_CHECK=1` |

A check whose tool is missing is skipped and named in the summary, never
failed. `--quick` leaves out the two slow ones (the suites and the wheel).
What only CI does: the suite under a real Python 3.6 (in a container),
under each of 3.9 to 3.13, under PyPI's provost 2.1.0 (`pip install
"provost==2.1.0"` into a second venv and point `QD_PROVOST` at it to try it
here), the installed wheel's smoke test, and the suite under provost
2.28.0 from its repository with `QD_STORE_CHECK=require`: every store a
case leaves must pass `provost store check` (PyPI's newest provost, 2.3.0,
has no `store check`). A case that makes a store by hand, or breaks one on
purpose, names it to `no_store_check` in `tests/test_helper.bash`.

While changing something, run less:

```bash
bash tests/run_tests.sh store                    # one suite (tests/test_store.sh)
QD_TEST_ONLY=import bash tests/run_tests.sh store   # only its cases whose name has "import"
```

doehelper wants Python 3.10 or newer; on an older one the doe suite uses its
stand-in, as CI's 3.9 and 3.6 jobs do.

`tests/check_real_sshd.sh` is not one of the suites either, nor in CI: it
starts a throwaway sshd on 127.0.0.1 as you (`openssh-server`; it skips
without one) and checks against real OpenSSH what the fake ssh cannot
prove, that a command past `--timeout` or `--max-output` is stopped on
the host (see *When a host takes too long*).

`tests/stress_filing.sh` is not one of the suites: it loops, for a race
that shows only now and then. It files `qd do` runs of several tables one
capture at a time, several rounds side by side, and checks that every
table reads back. Its header lists the knobs. `STRESS_MKDIR=racy` gives
provost a `mkdir` that loses the race as uutils coreutils' did before
0.11.0, so the race shows on any machine:

```bash
bash tests/stress_filing.sh 50                       # this machine's mkdir
STRESS_MKDIR=racy bash tests/stress_filing.sh 50     # passes: one after another
STRESS_MKDIR=racy STRESS_FILE_JOBS=4 bash tests/stress_filing.sh 50   # fails: four at once
```

The fake hosts are directories on the machine running the tests, so a probe
case runs that machine's real commands. On macOS three probe cases fail for
that reason and no other (*a group expands to its probes*, *several probes
run together*, *binnacle's scripts run on the hosts*: there is no
`vm.swappiness`, and binnacle's why-slow fails on every host); CI runs them
on Linux. Run with `TMPDIR=/tmp` there too: macOS's own temp path is long
enough that `qd store ls` shortens it, and *rename moves a store qd made*
looks for the part it cut. Every change moves the version in all
three places (`tests/check_version.sh` says where they disagree), to a
number greater than `main`'s (`bash tests/check_version.sh origin/main`
checks that here; CI checks it on every pull request and push to `main`).
