<!--
SPDX-License-Identifier: GPL-3.0-or-later
SPDX-FileCopyrightText: 2026 Martin J. Gallagher
-->

# Stores: where the answers are kept

provost's store, who ran what, named stores (`qd store`), remote stores
and `RUN@STORE`. Part of [the manual](README.md).

## What it keeps: provost's store

qd keeps nothing of its own. What comes back is filed by
[provost](https://github.com/MartinGallagher-code/provost), which turns
command output into data and keeps it in git: every host's answer is a
**capture** of its own (`provost source N` shows it exactly as it came
back), opening with a `#%` line that says which run and which host it is.
Where provost has `batch`, a whole run is one commit, the answers parsed in
parallel, and `--context-columns` puts the host (and its rack, and the
run) on every row, so `provost show NAME` says who said what without qd.
An older provost files one capture at a time, one after another, and qd
puts the host back from each capture's prologue just the same.

Besides the answers, a run files two tables of qd's own:

| Dataset | One row per | What |
|---|---|---|
| `qd.runs` | run | what ran, where, when, how many hosts answered |
| `qd.hosts` | host and pass | status, rc, duration, stderr, whether it printed anything, and what its login shell printed before the command (`preamble`) |

and qd puts them back together when you read a run: each host's status
beside the rows provost parsed out of its answer, and a row for a host
that printed nothing. Whichever store it is, `provost ls` there lists what
qd filed.

qd reads the store's files itself, as provost's store format spec
([`docs/store-format.md`](https://github.com/MartinGallagher-code/provost/blob/main/docs/store-format.md))
says a reader must: it refuses a store whose `.store_format` is newer than
the formats it knows (1 to 4), takes a row's capture from `provenance.tsv`
below format 4, reads a quoted `#%` value (`cc="gcc 13.2"`) as provost
does, and turns `\t` and `\n` in a `meta.tsv` value back into a tab and a
newline. A capture whose input was over provost's size cap is shown as
what it is: the raw answer is labelled *truncated*, with the part parsed
and where the whole input is kept (or that it is not to be found), and
`qd split` compares hosts by the whole input where it is kept.

### Who ran it

Every run says who ran it and from where, so a fan-out is attributable
after the fact. `qd log RUN` shows it, `qd log` lists the operator beside
each run, and `qd web` puts it in the run's header.

| `qd.runs` column | What | Recorded by |
|---|---|---|
| `operator` | `QD_OPERATOR`, else your login user | every run |
| `operator_host` | the machine qd ran on | every run |
| `ssh_user` | `--user`, else what your ssh config gives each host (`ssh -G`); hosts with users of their own give each, comma-separated | a fan-out |
| `ssh_key` | the fingerprint of each key qd offered: the `-i` keys (or `IdentityFile`) in `--ssh`, else your agent's (`ssh-add -l`). Never the key itself | a fan-out |
| `sudo` | `yes` or `no` | a fan-out |
| `via` | how the hosts were reached: `ssh`, `srun`, `pdsh`, `clush` or `local` | a fan-out |
| `sched_job` | the Slurm job `--via srun` ran in (each answer carries it as `sched.job`) | `--via srun` |

Anything qd cannot find out is blank, never a guess: an ssh without `-G`
(older than OpenSSH 6.8, or a wrapper), no `ssh-add` or an empty agent,
or a key file `ssh-keygen` cannot read. Which of several offered keys a
host accepted is not known without connecting, so `ssh_key` lists every
one offered. With `--via` other than ssh, `ssh_user` is the `--user`
given (pdsh's and clush's `-l`) or blank, and `ssh_key` is blank: their
ssh is configured apart from qd's. Runs filed before 0.8.2 have none of
these columns, and runs before 0.13.0 no `via` or `sched_job`; they show
blank. qd also passes the operator to provost as `PROVOST_OPERATOR` (unless
you set it yourself), for a provost that records it (PV-027); provost
2.3.0 does not yet.

### Named stores: `qd store`

```bash
qd store new lab               # ~/.local/share/quarterdeck/stores/lab
qd store new bench --path /data/bench
qd store use lab               # the store commands use from now on
qd store ls                    # every store, its runs, which is active
qd run -s hosts.txt --store bench -- uptime
qd store rename lab lab-2026   # a store qd made moves with its name
qd store rm bench              # forgotten; --delete deletes its files too
qd store clear lab --yes       # empty it: every run and dataset goes
```

Which store a command uses, the first of these that applies:

1. `--store NAME` or `--store DIR`: a store's name, or a directory as
   before, so existing scripts keep working.
2. `QD_STORE`: a name or a directory.
3. provost's own explicit choice: `PROVOST_WORKSPACE`, or the controlled
   directory you are in (`provost control`). qd and provost never disagree
   about where you are.
4. The active store: `qd store use NAME`, kept in
   `~/.config/quarterdeck/config.json`.
5. provost's default, `PROVOST_HOME` or `~/.provost`, with a warning that
   no store is active.

Once provost's default store exists, qd registers it as `default`, and
makes it the active store if none is. So a machine that used qd before
stores had names keeps working without a step. `qd log`, `show`, `view`,
`compare`, `diff`, `stats` and the rest all read the store chosen this way.
`qd web` has a picker for the named stores.

**Moving a store between machines**:

```bash
qd store export lab lab.tgz    # NAME is optional: the store in use
qd store import lab.tgz --as lab-from-rig2
```

An export is one archive: the store whole, with its git history and every
raw answer under `captures/`. First comes a manifest: qd's and provost's
versions, the store format, the run count and a sha256 for every file. The
export takes provost's own store lock, so it refuses while a run is filing,
and no run starts filing until the archive is written. (A run that finishes
during a long export waits up to provost's lock timeout, 30 s.)

An input over provost's size cap (`PROVOST_MAX_INPUT`, provost 2.15.0 on)
is filed truncated: the store holds the part provost parsed, and the whole
input is kept outside its git history, beside it, as `STORE.artifacts/SHA256`.
An export carries those kept inputs too, under `artifacts/` (provost's own
`export` does not), and an import puts them beside the new store, as
`NAME.artifacts`. An archive with any is version 2, which a qd before
0.18.0 refuses by its version; one with none is version 1, as before.

An import checks the manifest, every checksum, that nothing is missing or
added, and that this qd reads the store format. It refuses a member that
would land outside the store, and a link or a device. Only then is the
store given its name. It refuses a name that is taken: it never merges
into an existing store.

**A store on another machine**:

```bash
qd store new wr01 --remote wr01:~/.provost     # [USER@]HOST:PATH, as scp takes it
qd web --store wr01                            # or log, show, view, compare, diff
qd log --store wr01 --no-fetch                 # the copy as it is, offline
```

A remote store is read from a copy here, in
`~/.cache/quarterdeck/remotes/NAME`. The copy is shallow: it holds the
store as it is now, with no history, and no read needs history. `qd store
new` makes the copy at once, so a store that cannot be reached is reported
straight away.

- **Fetching:** before a command reads the store, qd fetches what is new
  over the same ssh `qd run` uses (`QD_SSH`, `QD_SSH_USER` unless the spec
  names a user, your keys, your jump hosts),
  at most once every `QD_REMOTE_REFRESH` seconds (30). `qd web` fetches the
  same way while the page is open, so new runs show without a restart, and
  its store picker lists the remote store with its host.
- **SHA-256 stores:** a store made in git's SHA-256 object format
  (`provost init --object-format sha256`) is read the same way; its copy
  is made in that format too, which needs git 2.29 or newer here. A store
  remade in the other format since its copy was made gets a new copy, said
  on stderr; the old copy is read until the new one is in place.
- **An unreachable host:** qd reads the last copy and says how old it is.
  It does not try that host again until `QD_REMOTE_REFRESH` has passed.
- **Writing is refused:** nothing files into a copy, because the copy would
  then differ from the store. `qd run`, `do`, `import`, `probe`, `rm`,
  `store clear`, and a campaign's or design's runs are refused before they
  contact a host, with the `ssh HOST qd ...` that does it where the store
  is.
- **Another user's store:** if the store belongs to another user on that
  machine, git refuses to read it. qd says so, with the `git config
  --global --add safe.directory PATH` to run there.
- **Renaming and removing:** `qd store rename` moves the copy with the
  name. `qd store rm` deletes the copy and leaves the store on the other
  machine as it was.

Every way to name a run (`latest`, `latest~1`, `prev`, an id or part of
one, a run's name, `ds:NAME`, `RUN:TABLE`, a file, `RUN@STORE`) is set
out, with an example each, in
[Concepts: Naming a run](concepts.md#naming-a-run).
`qd log` lists the runs and `qd log RUN` describes one.

**Runs from different stores side by side**: add `@STORE` to a reference
and it is read in that registered store, whatever `--store` says, so two
labs' or two machines' runs are compared without exporting one store into
the other:

```bash
qd diff kernel@wr01 kernel@wr02          # the same probe, two machines' stores
qd diff kernel@wr01                      # against the run before it in wr01
qd compare facts@lab facts@bench -c cpu.busy_pct
qd compare facts --last 5@lab            # five runs, all of them lab's
qd show latest:hosts@wr01
qd view latest@wr02
```

- **Which commands:** every one that reads a run -- `show`, `stats`,
  `freq`, `hist`, `outliers`, `pivot`, `trend`, `export`, `floor`, `log
  RUN`, `diff`, `compare`, `view` -- and the Diff and Compare tabs of `qd
  web`. Commands that file or delete (`run`, `do`, `import`, `probe`, `rm`,
  ...) take no `@STORE`: they use `--store`, as before.
- **Only a registered name** (`qd store ls`), never a directory: a
  directory is `--store`'s job. A name that is not registered is an error
  that lists the stores, never a quiet fallback to `--store`. A file or
  directory whose name has an `@` in it is still read as a file.
- **Where it splits:** on the last `@`, which is in no run id or provost
  dataset name. A table goes before it: `latest:hosts@wr01`.
- **Remote stores** are read like any other: the copy is fetched as
  `--store` would fetch it, and once per command however many references
  name that store.
- **Reports say where each side came from:** a run from a store other
  than the command's own is shown as `RUN@STORE` in report headers and in
  `compare`'s list of runs, since the same run id can be in two stores.
  Paste it back and it reads the same run.
- **Different fleets:** `compare` matches hosts by name, so a host one
  store measured and the other did not is blank on the other side (not
  measured), never zero.

**Deleting**:

```bash
qd rm latest~1                 # says what would go, and deletes nothing
qd rm latest~1 kernel --yes    # those runs: answers, tables, their rows
qd rm ds:loose --yes           # a whole dataset, every run's rows in it
qd store clear lab --yes       # everything in the store
```

`qd rm` and `qd store clear` first list what would go, and delete nothing
without `--yes`. Then provost deletes it, as one commit, so the store's git
history keeps what was there. A run goes whole: every host's answer and
every table it filed, from whichever datasets they are in (other runs'
rows in those datasets stay), and its rows in `qd.runs` and `qd.hosts`.
qd's own records (`qd.runs`, `qd.hosts`, `qd.campaigns`, `qd.designs`,
`qd.peers`, `qd.baselines`) are never deleted whole by `qd rm`. A run that was part of a campaign is said,
with the `qd campaign retry` that runs that part again.

Deleting one run needs `provost rm --capture`, which is newer than provost
2.2.0. An older provost is refused with that reason, and the store is left
as it was. `qd store clear` and `qd rm ds:NAME` work with any provost.
`qd store clear` keeps the history; for a store with none, `qd store rm
NAME --delete` and then `qd store new NAME`.
