<!--
SPDX-License-Identifier: GPL-3.0-or-later
SPDX-FileCopyrightText: 2026 Martin J. Gallagher
-->

# Changelog

## 0.1.0 — 2026-10-29

The first release.

### Added

- `qd run`: one command on every host over ssh, every answer kept as a
  dataset in the logbook. Host lists in the toolchain's grammar, with
  `key=value` attributes that become columns, and `--layout`/`--select`
  through binnacle's manifest. Answers are parsed by `--parse`
  (`auto`, `text`, `lines`, `number`, `kv`, `csv`, `json`, `table`) or
  `--extract`. Repeated passes with `--every`/`--count`, plus `--script`,
  `--push`, `--sudo`, `--dry-run`, `--first`, `--limit` and agree's
  mutation guard. A host that does not answer is a row with a status and a
  reason.
- `qd do`: a toolchain command run here and recorded, with what it wrote
  read back. That covers mx reports and export, iperf-orchestrator run
  directories, agree's CSV and JSON (added when not asked for), dcprobe,
  reckon and netmesh outputs, and stdout when it is a table.
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
  `qd floor`, which writes the overlay and opens `dcviz serve` on it.
- `qd web`: the logbook in a browser. It has tables, a column's figures,
  histogram, outliers and values, plus group, pivot, trend chart, diff,
  floor-plan hand-off and export. The page computes nothing; every figure
  comes from the same functions the terminal verbs print.
- `qd view`: the same, full-screen in a terminal, driven by keys.
- `qd log`, `qd hosts` (`--plain` for the tools without attributes),
  `qd doctor`, `qd hints`, `qd help`.
