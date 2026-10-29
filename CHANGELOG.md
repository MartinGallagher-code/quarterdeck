<!--
SPDX-License-Identifier: GPL-3.0-or-later
SPDX-FileCopyrightText: 2026 Martin J. Gallagher
-->

# Changelog

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
  median moved past `--drift` percent or a status was not ok. Exit 1 when
  anything changed.
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
  floor-plan hand-off and export. The page computes nothing; every figure
  comes from the same functions the terminal verbs print.
- `qd view`: the same, full-screen in a terminal, driven by keys.
- `qd log`, `qd hosts` (`--plain` for the tools without attributes),
  `qd doctor` (provost, and whether it batches), `qd hints`, `qd help`.
