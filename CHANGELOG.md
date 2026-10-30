<!--
SPDX-License-Identifier: GPL-3.0-or-later
SPDX-FileCopyrightText: 2026 Martin J. Gallagher
-->

# Changelog

## 0.1.1 — 2026-10-30

What a fleet of real hosts found: qd run over real ssh against Debian 12,
Ubuntu 24.04, Rocky 9 and Alpine 3.20 (busybox), where the suite's fake
ssh had passed.

### Fixed

- `--push`: the command now runs in `--remote-dir`, beside the files, so
  `--push x -- tool x` finds x; a pushed `--script` runs as `./name`, which
  makes a relative `--remote-dir` work too.
- A command that exits 127 (command not found -- `--sudo` where sudo is not
  installed) is `failed`, not `unreachable`: the host answered.
- Probes no longer report what they could not read as a value:
  - `listen` said `listening: 0` where neither ss nor netstat is (Alpine,
    with sshd listening); it reads ss, else netstat (busybox's too), else
    says `listen_tool: none`. ss without `-H`, which older iproute lacks.
  - `services` said `failed_units: 0` where systemd is not running; it
    counts failed units only where systemd runs, and says `system_state: no
    systemd` where there is none.
  - `os` said `virt: unknown` where systemd-detect-virt is missing (now
    blank), and on bare metal, where that tool prints `none` and exits 1,
    added a stray `unknown` line.
  - `numa`'s balancing and `packages`' reboot flag are left out where they
    cannot be told.
- `packages` knows apk and pacman as well as dpkg and rpm, and asks
  `needs-restarting` on rpm hosts that have it.
- `disks` reads `/sys/block` (`size_bytes`, exact) and `mounts`
  `/proc/self/mounts`, so neither needs util-linux; on Alpine both came back
  as a second table shape before.
- `gpu` says `nvidia_smi: absent` rather than `gpu: none` where there is no
  nvidia-smi: no NVIDIA tool is not no GPU.
- `facts` is one row per host again: why-slow's list of top processes was
  filed a row an element; it is a cell of JSON now.
- `reach` gave reachable `-o`, which writes the annotated host list, where
  its CSV path goes after `--csv`.
- A big run is filed 200 inputs at a time (`QD_FILE_CHUNK`), a commit
  each: provost's batch holds its store lock about 50 ms an input, so a
  thousand hosts in one batch kept any other writer (a second campaign
  worker) waiting past provost's 30 s lock timeout.
- From a review of the above: `--dry-run` prints the command as it runs
  (from beside pushed files); a chunk provost fails on is said input by
  input while the rest -- the run's own row -- are still filed; an ssh or
  scp that will not start is refused before any host rather than filed as
  a fleet of failures; `facts` keeps why-slow's own exit status and stderr
  through its filter; `packages` reports a pending reboot only from
  needs-restarting's own answers (0, 1); `numa` gives no node count
  without /sys/devices/system/node; `containers` and `listen` say when
  docker ps or ss fails rather than counting none; `disks` calls an
  optical drive `rom` and skips an idle network block device (its size
  column is `size_bytes` now, in bytes, where 0.1.0's was `size`);
  `qd compare` and `qd view` show a multi-line command (a probe's) as its
  first line.
- The typo guard (agree's) names the command to repeat with `--yes` --
  `qd doe run`, `qd campaign new` -- where it said `qd run` for all, and
  `qd doe run` checks every point's command before the first runs, rather
  than refusing half way through a design.
- From a review of qd itself:
  - A data column called `n` is data: provost names its own record number
    `_n` beside one, and qd dropped the data's `n` and kept provost's
    (`qd import` of `host,n,mbps` lost the n). provost's own columns are
    found by place now (`provost_columns`), past the context columns.
  - `qd campaign run --dry-run` took every part from muster's pool and
    marked it done; it prints what each part would run and takes nothing.
  - `qd campaign new` filed the campaign before muster had made its pool,
    so a failure there (muster not installed) left the name taken and
    nothing to hand out; the pool comes first, and a definition that cannot
    be filed takes the pool away again.
  - A campaign part's run id carries its part (`...-burn_rack_r1`): two
    workers finishing parts in the same second took the same id.
  - `qd doe run` filed a new design before its checks, so a run the typo
    guard refused left the design tied to the refused command; and `qd doe
    plan` showed a different run order from the one `run` used, both
    drawing doe's random order unseeded. The default seed comes from the
    config, so plan shows what run will do.
  - `qd diff RUN` (and the web page's "previous") compared a campaign part
    with the part before it -- every key gone or new -- because the parts
    share a command and a name; the part is part of the match now.
  - `qd split --answers RUN` on a run of several passes put each host in
    its lists once per pass; a host is in one list, by its last answer.
  - `qd compare --agg top` (or worst, first, ...) crashed on a repeated
    key; compare reduces to a number, and says which aggregations do.
  - `qd diff` rounded a key reduced from repeated rows to four figures and
    compared it with the other side's exact value, so identical data read
    as changed.
  - A log whose first line opens with `[` (`[INFO] ...`) was refused as
    JSON; JSON's `NaN` crashed the reader, and is blank now (Infinity
    reads `inf`).
  - A column in mixed units (512M beside 2G, 900ms beside 1.2s) was put
    on one scale by `qd stats` and the column panel, but read cell by cell
    -- unit dropped -- everywhere else: `--where 'used>600M'` matched
    neither 1G nor 2G, `--sort` put 512M after 2G, a group's mean averaged
    512 with 2, `qd diff` read 980M -> 1.1G as -99.9%, trends drew 1.1G
    below 980M, a design's responses mixed scales across runs, and JSON
    export wrote 50G as 50. Such a column is now read on its base scale
    (bytes, seconds) throughout -- `normalize_units`, `to_base` -- and a
    literal with a unit compares on it; export keeps a unit as written.
    Mixed times were dropped to their commonest unit; they are seconds now.
  - A value with a space in it -- a design level `-w 1M`, a host
    attribute from a manifest -- was split on the space when read back
    (`-w`); such a value is quoted where qd keeps it (`join_attrs`) and
    read back whole, and shown as written.
  - `qd log` (and the web page's list) counted a run's `key: value`
    answers by provost's long rows -- 9 for 3 hosts -- where the table has
    a row a host; it counts the rows the table shows.
  - A TSV with an unbalanced quote (`"5 inch`) read every line after it
    into that one cell; a TSV is read line by line, such a quote a
    character. A header whose first cell is blank (pandas' and R's index
    column, `,host,mbps`) was taken for data; it is a header.
  - `qd doe run --blocks-by ATTR` said nothing of the host groups a design
    with fewer blocks leaves out, and a re-run without the same
    `--blocks-by` was allowed; the first is said, the second refused.
- A tip to read an answer with provost (`provost source N`) names the store
  when provost would not find it on its own (`--store`, `QD_STORE`):
  `PROVOST_WORKSPACE=... provost source N`.

### Security

- `qd web` read any `.tsv` file on the machine through a reference: `e=`
  went to the store's dataset lookup unchecked, so `/api/rows?e=/path/x`
  or `e=ds:../../x` returned `/path/x.tsv` (and `/api/export` the whole
  file), and `/api/overlay` could write its overlay outside the cache. A
  dataset name is a provost name now (letters, digits, `.`, `_`, `-`, no
  `..`), in the CLI as in the server, and an overlay's file name is
  sanitised. Bound to loopback, the server answers only requests made to
  127.0.0.1 or localhost, so a web page that points its own name at it
  (DNS rebinding) is turned away.

### Tests

- Cases for each of the above, with commands hidden from a fake host
  (`path_without` in the helper); each fails on 0.1.0.

## 0.1.0 — 2026-10-29

The first release.

### Added

- **Everything is kept in provost's store.** qd keeps nothing of its own:
  every host's answer is a provost capture, opening with
  `#% run=RUN host=HOST [attr=value ...]`, and two tables of qd's own,
  `qd.hosts` (every host's status, stderr kept, whether it printed
  anything) and `qd.runs` (what ran, filed last), sit beside them. Where
  provost has `batch` a run is one commit, the answers parsed in parallel,
  with `--context-columns`; an older provost files one capture at a time.
  qd reads the store's files back and puts each host's status beside what
  provost parsed out of its answer, with a row for a host that printed
  nothing. The store is provost's to choose (`--store`, `QD_STORE`,
  `PROVOST_WORKSPACE`, a controlled directory, `PROVOST_HOME`,
  `~/.provost`); `ds:NAME` reads any provost dataset whole.
- `qd run`: one command on every host over ssh, every answer kept. Host
  lists in the toolchain's grammar, with `key=value` attributes that become
  columns, and `--layout`/`--select` through binnacle's manifest. provost
  reads each answer; numbers with units (`16384 kB`, `50G`, `0.42 ms`)
  read as numbers, mixed size units on one scale, and an answer provost
  files long (`field, value`) is read back as the host's columns.
  Repeated passes with `--every`/`--count`, plus `--script`, `--push`,
  `--sudo`, `--dry-run`, `--first`, `--limit`, `--no-store` and agree's
  mutation guard. A host that does not answer is a row with a status and a
  reason.
- `qd probe`: a catalogue of named probes, each a run of its own name.
  binnacle's why-slow (`facts`, its two hundred readings, and `why-slow`,
  its findings) and skew are pushed to every host and run there; dcprobe's
  `health` and `preflight` and binnacle's `reach` drive the fleet from
  here; shell commands cover what no instrument measures: `os`, `sysctl`,
  `services`, `gpu`, `mounts`, `disks`, `packages`, `numa`, `pagecache`,
  `listen`, `containers`. Groups: `inventory`, `settings`, `state`.
- `qd split`: one host list into several, `--by ATTR`, `--into N`,
  `--deal N`, `--size N`, `--random N` (`--seed`, `--stratify ATTR`),
  `--ab`, `--canary N`, `--pairs` (`--ring`), `--reachable` (binnacle's
  reachable decides) and `--answers RUN` (grouped by what each host said);
  `--out DIR` writes host files the whole suite reads.
- `qd campaign new|run|status|retry|ls`: a command run on a system in
  parts (any `qd split` cut), binnacle's muster keeping which parts are
  done -- each handed out once under a lease, so several workers can share
  a campaign and a dead worker's part comes back -- and every part a run
  in provost, its campaign and part on every row.
- `qd compare`: N stored runs side by side (`--last N`, `--group NAME`,
  or named): one row per run (hosts that answered, median, spread, change
  from the baseline), then host by host every run's value, flagged where a
  median moved past `--drift` percent or a status was not ok. With no
  column, every numeric column's median, a design's factors and the hosts'
  attributes left out. Exit 1 when anything changed.
- `qd doe plan|run|status|analyze`: designed experiments.
  design_of_experiments' `doe` makes the design from its config; qd runs
  each point on the fleet with every `{factor}` in the command replaced by
  its level (`--blocks-by ATTR` for blocks on host groups), files it with
  its factors on every row, skips points already measured, and hands each
  point's response back to `doe analyze` (and `doe optimize`).
- `qd do`: a toolchain command run here and recorded, with what it wrote
  read back and filed. That covers mx reports and export,
  iperf-orchestrator run directories, agree's CSV and JSON (added when not
  asked for), dcprobe, reckon and netmesh outputs, and stdout.
- `qd import`: output already on disk, in any of the formats below.
- Readers for CSV/TSV, the floor-plan viewer's results format (with its
  `!test` metadata, written back unchanged), NDJSON and JSON, `src\dst`
  grids and wide monitoring tables, detected from what is inside a file.
- `qd show`, `stats` (`--by`, `--agg`), `freq` (consensus with holders;
  multi-line values diffed against the majority), `hist`, `outliers`
  (median and MAD), `pivot`, `trend` and `diff` (keys found on their own,
  volatile columns named, repeated keys reduced). All take `--where`, a
  small expression language, and `--format csv|tsv|json|ndjson|md`.
- `qd export`, including `--format overlay` for the floor-plan viewer, and
  `qd floor`, which writes the overlay into qd's cache and opens
  `dcviz serve` on it.
- `qd web`: the store in a browser. It has tables, a column's figures,
  histogram, outliers and values, plus group, pivot, trend chart, diff,
  compare, floor-plan hand-off and export, and the campaigns and designs
  with their progress, parts and points. The page computes nothing; every
  figure comes from the same functions the terminal verbs print.
- `qd view`: the same, full-screen in a terminal, driven by keys.
- `qd log`, `qd hosts` (`--plain` for the tools without attributes),
  `qd doctor` (provost, and whether it batches), `qd hints`, `qd help`.
