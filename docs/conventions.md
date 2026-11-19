<!--
SPDX-License-Identifier: GPL-3.0-or-later
SPDX-FileCopyrightText: 2026 Martin J. Gallagher
-->

# Conventions and exit status

The rules every command keeps, and what its exit status means. Part of
[the manual](README.md).

## Conventions

These are binnacle's, for the same reasons:

- **Blank means not measured.** A blank cell stays blank through every
  read, filter, statistic, pivot and diff, and is never averaged in as
  zero. Averaging a gap as zero is the one mistake that makes every
  number look better than it is.
- **Failures are findings.** A host that didn't answer is a row with a
  status and a reason. It isn't dropped or left on stderr to scroll past.
- **Say what was done to the data.** The datasets provost filed into, the
  columns a diff ignored, keys it reduced, the filters behind every report.
- **Deterministic output.** Fan-out answers come back in host-list order,
  never completion order, so two runs can be diffed.
- **Diagnose, don't dump.** Every run ends with what to look at next.
- **Every knob has a flag and an environment variable.**
- **Tidy data, rendering separate.** Every report has a `--format`
  that's the table behind it.
- **Standard library only; Python 3.6 floor;** reads decode `utf-8-sig`
  and a C locale can't lose a report.

---

## Exit status

| | |
|---|---|
| 0 | done, and every host answered |
| 1 | a finding: a host that did not answer, answers that differ (`qd ask`), a host `qd odd` finds unlike the rest, a diff or compare that differs, a change or a slide `qd changes` found, a check that failed or was not measured, nothing to bin, a join that found no telemetry in any window, a host that still owes a test `qd coverage` names, a report that records any of these |
| 2 | a usage error, or something could not be read or written |
| other | `qd do` passes on the tool's own |
