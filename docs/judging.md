<!--
SPDX-License-Identifier: GPL-3.0-or-later
SPDX-FileCopyrightText: 2026 Martin J. Gallagher
-->

# Judging: requirements, waivers and test reports

`qd check` against requirements (spread and shape, waivers, `--manual`,
`--baseline`, JUnit, `--rule`), and `qd report`'s evidence package. Part
of [the manual](README.md).

## Against requirements: `qd check`

`qd compare` and `qd outliers` say what moved and who stands out. `qd
check` says whether a run meets fixed limits, one verdict per
requirement, as a table for a test-readiness review:

```bash
qd check latest --against limits.tsv          # one row per requirement
qd check latest --against limits.tsv --each   # one row per host per requirement
qd check latest --against limits.tsv --keep   # and file the verdicts (qd web, qd export)
qd check latest --against limits.tsv --format csv -o trr.csv
qd check latest --against limits.tsv --waivers waivers.tsv   # agreed deviations
qd check latest --against limits.tsv --manual inspected.tsv  # a person's pass or fail
qd check latest --against limits.tsv --fail-level high       # exit 1 only for high and critical
qd check latest --against limits.tsv --format junit -o qd-check.xml   # for CI
qd check latest --against drift.tsv --baseline RUN|NAME     # limits relative to an earlier run
qd check latest --against limits.tsv --rule 'all(SYS-1*, atleast(3, SYS-2*))'   # one verdict
```

The thresholds file is TSV (or CSV) with a header. `req`, `column`, `op`
and `limit` are required; `limit2`, `where`, `agg`, `unit`, `note`,
`severity` and `weight` (for `--rule`, below) may be left out or blank:

```text
req      column  op       limit  limit2  where      agg   unit
SYS-101  mbps    >=       900            status=ok        Mbps
SYS-102  rtt     <=       250            rack=r2    p99   us
SYS-103  status  in       ok,pass
SYS-104  temp    between  20     45                 max
```

- **`op`**: `<`, `<=`, `>`, `>=`, `==`, `!=`, `in` (a comma list of
  words, without regard to case), `between` (`limit` to `limit2`,
  inclusive), `within` (below) or `manual` (a person decides it, with
  `--manual`; below). `==` and `!=` compare numbers as numbers and words
  as words.
- **`within`** holds a value to a reference give or take a tolerance, as
  ReFrame's references do: `limit` is the reference and `limit2` the
  tolerance, `+-10%` (or `±10%`), `-5%,+10%` (or `-5%;+10%` in a CSV),
  or absolute, `+-3` or `-3,+5`. A percentage is of the reference; an
  absolute tolerance is in the reference's unit, or in one of its family
  (`within 0.2ms` give or take `+-50us`). It reads as `within 50 (-10%,
  +10%)`, inclusive at both ends, and is scaled by unit as every other op
  is.
- **`severity`**: `critical`, `high`, `medium`, `low` or `info` (InSpec's
  words; its `none` is `info`, and an impact from 0.0 to 1.0 maps onto
  them as InSpec maps it: below 0.4 low, below 0.7 medium, below 0.9
  high). It is a column of the verdict table when the file has it.
- **`where`** narrows the rows, in `--where`'s grammar. `--where` on the
  command line narrows them for every check.
- **`agg`**: `each` (the default: every row must pass) or one figure over
  the rows -- `mean`, `median`, `min`, `max`, `sum`, `stdev`, `range`,
  `p05`, `p25`, `p75`, `p95`, `p99`, or the spread and shape figures
  `cv`, `skew`, `kurtosis` and `zmax` (below).
- **`unit`** is the limit's unit, if the limit does not carry one
  (`250us` does). Sizes and times are put on one scale, so `0.3ms`
  fails `<= 250us` and `2G` passes `<= 4096M`, and the observed value is
  shown in the limit's unit. Units that cannot be compared (a time
  against a rate) are refused, and the check is not measured; a column
  that carries no unit is read in the limit's, and the note says so.

Each check is **pass**, **fail** or **not measured**. Blank is never a
pass: a missing column, no rows left by `where`, or a blank cell is not
measured. Under `each`, one row that failed fails the check; otherwise
one unmeasured row makes it not measured. An aggregate over some hosts
but not all is not measured either, and the note gives the figure it
would have had and who measured nothing. The `measured` column says how
many of the rows did.

The exit status is 0 when every check passed, and 1 when any failed or
was not measured: a finding, as everywhere else in qd. A thresholds
file qd cannot read (a missing column, an unknown `op`, `agg` or
`severity`, a `between` or `within` without `limit2`, a word where a
number belongs, the same check twice) is refused with exit 2, naming the
check.

**`--fail-level LEVEL`** (`QD_FAIL_LEVEL`, default `info`) makes the exit
status 1 only for a failure at or above that severity; a lesser one is
still a failure in the table, and the head says how many were let off.
Two things are never let off: a check with **no** severity (it counts at
every level, so a file without the column behaves as it always did), and
**not measured**, whatever its severity.

### Spread and shape: `cv`, `skew`, `kurtosis`, `zmax`

`qd stats` and `qd outliers` show how alike the hosts are; these four
aggregates let a check pass or fail on it. `agg zmax` with `op <= 3.5`
reads "no host is an outlier", and `agg cv` with `op <= 0.05` "the hosts
agree within 5%":

```text
req      column  op  limit  agg
FLT-001  mbps    <=  3.5    zmax
FLT-002  mbps    <=  0.05   cv
FLT-003  rtt     <   1      skew
```

| `agg` | what it is | fewest values |
|---|---|---|
| `cv` | coefficient of variation: the sample stdev (n - 1, as `stdev`) over the mean's size, `stdev / abs(mean)` | 2 |
| `skew` | the adjusted Fisher-Pearson sample skewness, G1 = g1 sqrt(n(n-1)) / (n-2) with g1 = m3 / m2^1.5 (Excel's `SKEW`): 0 for a symmetric spread, positive when a long tail runs high | 3 |
| `kurtosis` | the sample **excess** kurtosis, G2 = ((n+1) g2 + 6)(n-1) / ((n-2)(n-3)) with g2 = m4 / m2^2 - 3 (Excel's `KURT`): 0 for a normal distribution, positive for heavier tails | 4 |
| `zmax` | the largest robust \|z\| over the rows, 0.6745 (x - median) / MAD, as `qd outliers` scores it | 3 |

(m2, m3 and m4 are the central moments, sums of (x - mean)^k over n.)

- **They are unitless.** Cells in units are read on one scale, as `qd
  outliers` reads them (`1ms` beside `0.1s`), and the figure is shown as
  it is: the column's unit does not scale it, and the `unit` column of
  the verdict is blank. A limit with a unit on one of them -- in `unit`,
  in `limit` or `limit2` (`5%` included: write `0.05`), or in a `within`
  tolerance or a baseline offset -- is refused with exit 2, naming the
  check. A tolerance or an offset in percent (`+-10%`, `baseline+10%`)
  is a share of the figure, not a unit, and is taken.
- **Not measured, never a pass**, when the figure cannot be had: fewer
  values than the table's last column, a mean of 0 for `cv`, every value
  the same for `skew` and `kurtosis`, and a MAD of 0 for `zmax` (most
  hosts agree exactly: `qd outliers` lists every one that differs). The
  note says which. A figure over some rows but not all is shown and not
  passed, as every aggregate's is.
- **`zmax` is `qd outliers`' score**: the same median, MAD and formula,
  so the two agree on the worst host and its z. Where hosts repeat (a
  time series), each host's median is scored, as `qd outliers` does by
  default; its fewest values are then hosts. The note names the host
  with the worst |z|, its signed z to one place as `qd outliers` prints
  it, and the median and MAD. A zmax over three or four hosts is noisy:
  with so few, the MAD is small and a host a little off can score high.
- **Under `--each`**, a row of a `zmax` check is that host's own robust
  z, held to the limit by its size; a row of a `cv`, `skew` or
  `kurtosis` check shows the host's value and carries the check's
  verdict, since the figure is the fleet's, not the host's.
- **With `--baseline`, a relative limit works** as it does on the other
  aggregates: `baseline+0.02` or `baseline+50%` is held to the same
  figure over the baseline's rows of the same hosts (each host's median
  there for a `zmax` over hosts that repeat, and for a qualified
  baseline), and a host the baseline lacks makes it not measured, as
  does a baseline whose own figure cannot be had. The `baseline` and
  `drift_pct` columns give the baseline's figure and the change from it;
  a percentage of a skew or kurtosis near 0 swings widely, so prefer an
  absolute offset there.
- Waivers, severities, `--fail-level`, `--keep` and every `--format`,
  JUnit included, treat these verdicts as any other aggregate's. A
  thresholds file with none of them gives the output it always gave.

### Waivers

At a test-readiness review, a requirement that fails under an agreed
deviation -- a known firmware bug, one class of node excused -- is not a
plain failure, and editing the thresholds would change the requirement
and lose the record. **`--waivers FILE`** (`QD_WAIVERS`) names a second
file, TSV or CSV like the first, as Chef InSpec's waiver file does:

```text
req      justification                 expires     where    expect  granted_by
SYS-101  NIC firmware 2.1 bug, FSE-12  2026-12-31  host=n4          J. Smith
SYS-104  thermal rework not done yet   2027-03-01           fail    QA board
```

`req` and `justification` are required; `expires` (YYYY-MM-DD, the last
day it holds), `where` (only these rows, in `--where`'s grammar),
`expect` and `granted_by` may be blank.

- A check that **failed** under a waiver in force is **waived**, not
  failed, and does not fail the run. Under `each` only the rows the
  waiver's `where` picks are excused; any other failing row still fails
  it. An aggregate is waived only when the waiver covers every row it was
  taken over.
- A check that passed stays a **pass**. With `expect fail`, it is an
  **unexpected pass** instead, which fails the run (as ReFrame's `xfail`
  does): the deviation is over, so the waiver should go.
- **Not measured is never waived.** A waiver excuses a measured failure
  only.
- An **expired** waiver does nothing; the verdict stays a failure, and
  the table shows the waiver with `(expired)` beside its date.
- A waiver whose `req` no check has is refused with exit 2, so a typo
  cannot quietly excuse nothing; so is a blank justification, a date qd
  cannot read, or an `expect` other than `fail`.

With waivers, the verdict table gains `justification`, `expires` and
`granted_by`, and the head counts waived apart from passed. Without
`--waivers` and without a `severity` column the output is what it was.

### A person's results: `--manual`

Some requirements nothing measures: the cabling inspected, the labels
right, a host's console checked. A review needs them in the same record
as the measured ones, not in a spreadsheet beside it. Write such a
requirement in the thresholds file with **`op manual`**; `column` may
name what was looked at or be blank, and `limit`, `limit2`, `unit` and
`agg` stay blank (say what is wanted in `note`). `where`, `severity`,
`weight` and `note` work as on any check:

```text
req      column   op      limit  where    note
SYS-201  cabling  manual                  as built, drawing E-104
SYS-202  labels   manual         rack=r2
```

A manual requirement is **not measured** until a person's result is
given, so the run exits 1: blank is never a pass. **`--manual FILE`**
(`QD_MANUAL`) names the results, TSV or CSV like the waivers file:

```text
req      verdict  by        date        where    note
SYS-201  pass     J. Smith  2026-11-17
SYS-202  pass     QA board  2026-11-18
SYS-202  fail     QA board  2026-11-18  n4       label swapped with n5
```

`req`, `verdict` (`pass` or `fail`, without regard to case) and `by` are
required; `date` (YYYY-MM-DD, or with a time: `2026-11-17T14:30` or
`2026-11-17 14:30`), `where` and `note` may be blank.

- A result covers **the rows its `where` picks** (in `--where`'s grammar;
  one bare word is a host, so `n4` is `host=n4`), or every row of the
  check without one. Each row is what the results that cover it say, and
  when they disagree **the fail stands** (the note says so); a row no
  result covers is not measured. The check's verdict is then taken over
  its rows as `each` takes it: one row failed fails it, otherwise one
  row not covered makes it not measured. With **`--each`**, a row per
  host, each with its own result.
- With `--manual`, the verdict table gains **`decided_by`**, **`decided`**
  (the date as written) and **`decision_note`**: who decided each manual
  verdict, when, and what they wrote; `observed` reads `manual pass` or
  `manual fail`. The head line counts the results and names who gave
  them.
- **Waivers apply to a manual fail** as to any fail (waived, and expect
  `fail` on a manual pass is an unexpected pass); `--rule`, severities,
  `--fail-level` and every `--format` take a manual verdict as any
  other. In **JUnit**, a manual testcase carries `by` and `date` as
  properties, a manual fail is `<failure type="manual" message="failed by
  a person's decision: J. Smith on 2026-11-17: ...">`, and the suite
  names the manual file with its sha256, as it does the thresholds and
  waivers files.
- **A result dated before the run is warned of, not refused**: the note
  says `decided 2026-11-01, before the run (2026-11-17)` and the head
  counts them. An inspection is often made the day before a run, so a
  date cannot decide it alone; but a manual file kept from an earlier
  run would otherwise pass a later one unremarked. A dataset read from a
  file has no start, so there is nothing to compare with. The head also
  counts results with no date.
- **Refused with exit 2**, naming the line: a result whose `req` no
  check has, or one whose check is measured rather than manual (a
  person's result does not override a measurement); a verdict other than
  `pass` or `fail`; a blank `req`, `verdict` or `by`; a date qd cannot
  read; a `where` it cannot parse. A manual check with a `limit`,
  `limit2`, `unit` or an `agg` is refused in the thresholds file.

`--keep` files the manual columns with the verdicts, names the manual
file in the filed run's command, and keeps a note of its name and its
sha256 (`qd log RUN`), since a person's result is a claim nobody can
recheck. Without `--manual` and without a manual row the output is what
it was.

### Against an earlier run: `--baseline`

A fixed limit says whether a run is good enough; it cannot say a host
slid 8% since last month and is still above the line. **`--baseline
RUN|NAME`** holds limits written relative to a baseline to an earlier
run (or a file), or to a qualified baseline from `qd baseline set`:

```bash
qd check latest --against drift.tsv --baseline 20261101-093000-load --each
qd check latest --against drift.tsv --baseline gold   # qd baseline set gold ...
```

```text
req     column  op      limit          limit2  where    agg
DRIFT1  mbps    >=      baseline-5%                     each
DRIFT2  rtt     <=      baseline+40us           rack=r2
DRIFT3  mbps    within  baseline       +-5%             median
DRIFT4  temp    between baseline-2     baseline+2
```

- A **relative limit** is `baseline`, `baseline+N` or `baseline-N`, a
  percentage of the baseline's value (`baseline-5%`) or an absolute
  difference (`baseline+2`, `baseline+40us`, read in the column's unit
  when it carries none). It goes in `limit` of `<`, `<=`, `>`, `>=` and
  `within` (whose `limit2` tolerance is then around the baseline's value),
  and in either side of `between`. `in`, `==` and `!=` keep their words:
  `== baseline` is still the word. A file with no relative limit means
  what it always meant, and needs no `--baseline`.
- Under **`each`**, every host is held to **its own** value in the
  baseline, matched as `qd compare` matches them (the host, and the
  record number where a host has several) or on a qualified baseline's
  own key. A host whose several rows reduce to one figure is reduced by
  its median, as compare reduces it; the verdict table has a row per
  host, and its `limit` shows the figure each was held to.
- Under an **aggregate**, the figure is taken over the baseline's rows
  of the same hosts, through the same `where`, so the two are of one
  population; for a qualified baseline it is taken over each host's
  median there.
- **Blank is never a pass**: a host or a column the baseline lacks is
  not measured, so is an aggregate over hosts some of which the baseline
  lacks, and so is a relative limit with no `--baseline` given.
- **A qualified baseline of three runs or more decides by test.** Where
  a host has three values or more in the run as well (repeated rows: a
  test's iterations), a limit crossed fails only when the Mann-Whitney U
  test that `qd compare --baseline NAME` makes finds the difference
  significant (Holm-adjusted over the check's hosts, below 0.05); a
  crossing it does not is a pass, named in the note. Otherwise the
  medians decide, and the note says which it was ("against one run:
  decided on medians"), so a verdict on a single noisy run reads as one.

With `--baseline` the verdict table gains `baseline` (the baseline's
value) and `drift_pct` (the run's change from it, as `qd compare`
computes it). Waivers, severities, `--fail-level`, `--each`, `--keep`
and every `--format` treat a relative verdict exactly as a fixed one,
and `--keep` names the baseline in the filed run's command.

`--keep` files the verdict table in the store as a run of kind `check`,
named `check-<run>`, so `qd show`, `qd export` and `qd web` read it like
any other dataset; with its severity and waiver columns, and the
`--waivers` file named in its command (and the `--manual` file, with its
sha256).

### JUnit XML, for CI

**`--format junit`** writes the verdicts as JUnit XML, the result format
Jenkins, GitLab and the GitHub Actions test reporters read, so a CI job
that runs `qd check` shows each requirement as a test:

- One `<testsuite>` per run: its name is the run's id, its `timestamp`
  the run's start, and its properties the operator, the store, and the
  thresholds file (and the waivers file) by name with its sha256. A
  dataset read from a file is named by the file, with no timestamp.
- One `<testcase>` per check, `classname` the `req` and `name` the column
  with its limit (`mbps >= 900 where status=ok`; `max of temp between 20
  and 45` for an aggregate). With **`--each`**, one per host per check,
  `name` the host (and the column and limit too, when a `req` has more
  than one check). A `severity` is a property of its testcase.

| Verdict | In JUnit |
|---|---|
| pass | a `<testcase>` with nothing in it |
| fail | `<failure type="fail" message="observed 880; want >= 900">`, the note inside |
| unexpected pass | `<failure type="unexpected pass">`: it fails the run, so it fails the build |
| not measured | `<error type="not measured" message="not measured: ...">`: never a pass, and not counted as one |
| waived | `<skipped message="waived: justification (expires ...; granted by ...)">` |
| manual fail | `<failure type="manual" message="failed by a person's decision: ...">`, with `by` and `date` as properties |

So `tests`, `failures`, `errors` and `skipped` on `<testsuite>` are the
head line's counts: failures are fail and unexpected pass, errors not
measured, skipped waived. A failure below `--fail-level` is still a
`<failure>` (the verdict is fail; only the exit status lets it off), and
the suite carries `fail_level` as a property. Every string is escaped,
and the characters XML 1.0 cannot hold (NUL and the other control
characters) are dropped, so a hostile host name or note cannot break the
file. The exit status is the same as for any other format.

With `--rule`, the overall verdict is one more `<testcase>`, `classname`
`rule` and `name` the rule: nothing in it for a pass, a `<failure
type="rule">` for a fail, an `<error type="not measured">` for not
measured, the why as its message. The suite carries `rule`,
`rule.verdict` and `rule.why` as properties.

### One verdict from many: `--rule`

A test-readiness review often accepts a run that meets most of a group of
requirements: every SYS-1xx, and three of the four SYS-2xx. **`--rule
RULE`** (`QD_RULE`) builds one overall verdict from the requirements, and
the exit status follows it: 0 when it passes, 1 when it fails or is not
measured. The verdict of every check is the same as without it; the rule
is one more layer on top.

```bash
qd check latest --against limits.tsv --rule 'all(SYS-1*, atleast(3, SYS-2*))'
qd check latest --against limits.tsv --rule 'weighted(0.8, SYS-*)'
QD_RULE='all(SYS-101, any(SYS-201, SYS-202))' qd check latest --against limits.tsv
```

The rule is calls and names, nothing else (quote it, for the shell):

| Written | Passes when |
|---|---|
| `SYS-101` | that requirement passes |
| `all(A, B, ...)` | every one passes |
| `any(A, B, ...)` | one or more passes |
| `not(A)` | A fails |
| `atleast(N, A, B, ...)` | N or more pass; N is a whole number from 1 to how many there are |
| `weighted(T, A, B, ...)` | the weights of those that pass, over the weights of all, come to T or more; T is from 0 to 1 |

- A name is a `req` of the thresholds file, or a glob over them (`*`,
  `?`, `[...]`, case counts): `SYS-2*` in a list is every SYS-2 requirement,
  one item each. Where one requirement belongs (the whole rule, or
  `not`'s), a glob must match exactly one.
- The calls nest: `all`, `any`, `not` and `atleast` take requirements and
  other calls; `weighted` takes requirements and globs.
- A requirement with several checks passes when all of them do.
- **Weights** come from a `weight` column in the thresholds file: a
  number 0 or more, written on any one of the requirement's rows (two
  different weights for one requirement are refused); blank is 1.
- In the rule, a **waived** check counts as a pass, an **unexpected
  pass** as a fail, and a failure below `--fail-level` as a pass.
  **Not measured is never a pass**: a call is not measured when the
  requirements not measured could still decide it (`all(A, U)` with A
  passing, `atleast(2, A, U, F)`), and `not` of not measured is not
  measured.
- A requirement the rule does not name counts for nothing, and the head
  says which those are.

Worked example. With these limits, SYS-203 failing and SYS-204 not
measured:

```text
req      column  op  limit  weight
SYS-101  mbps    >=  900    2
SYS-102  rtt     <=  250us
SYS-201  temp    <=  70
SYS-202  fan     >=  1000
SYS-203  psu_w   <=  400
SYS-204  ecc     ==  0
```

```console
$ qd check latest --against limits.tsv --rule 'all(SYS-1*, atleast(2, SYS-2*))'
qd check -- run-... against limits.tsv (...): 4 pass, 1 fail, 1 not measured; rule pass: all 3 passed
  rule pass         all(SYS-1*, atleast(2, SYS-2*)): all 3 passed
         pass         atleast(2, SYS-2*): 2 of 4 SYS-2* passed, need 2; 1 not measured: SYS-204
```

With `atleast(3, SYS-2*)` the same run is **not measured**, `2 of 4
SYS-2* passed, need 3; 1 not measured: SYS-204` (SYS-204 could still have
made it 3), and the exit status is 1. `weighted(0.8, SYS-*)` is not
measured either: `weighted score 0.7143 of SYS-* (5 of 7), need 0.8; 1
not measured: SYS-204`. SYS-101 weighs 2, so the four that passed weigh
5 of 7, and SYS-204 passing would have made it 6 of 7.

The overall verdict is in every format: the head line in text, with a
line per call beneath it; one more row of the verdict table (`req`
`(rule)`, the rule as its `limit`, the why as its `observed`) in CSV,
TSV, JSON and the rest, and in what `--keep` files, whose command names
the rule; and in JUnit as above. A rule qd cannot read is refused with
exit 2, naming what is wrong: a `req` no check has, a glob that matches
nothing (or several where one belongs), N above the count, a threshold
outside 0 to 1, the same requirement twice in one list, weights that add
up to 0, or anything left over. Without `--rule` the output and the exit
status are what they always were.

---

## For a test report: `qd report`

The other commands answer one question each. `qd report` puts their
answers for a run, or a whole campaign, into one directory an evaluator
can read, check and attach without qd:

```bash
qd report latest --out evidence/                      # one run
qd report latest --out evidence/ --check limits.tsv --baseline accepted --zip
qd report campaign:burnin --out burnin-evidence/      # every part of a campaign
```

```text
evidence/
  summary.html, summary.md       what to read first: findings, then each section
  manifest.json                  the run records, versions, store head, what was left out
  SHA256SUMS                     every other file:  cd evidence && sha256sum -c SHA256SUMS
  data/RUN/data.csv, data.json   each table, as qd export writes it
  data/RUN/data.stats.csv, .json qd stats on it
  data/RUN/outliers.csv, .json   qd outliers on every numeric column
  data/RUN/check.csv, .json      qd check's verdicts
  data/RUN/check.junit.xml       the same verdicts as JUnit XML (qd check --format junit)
  data/RUN/captures/c0001.txt    every host's answer, exactly as provost keeps it
  data/baseline.csv, .json       medians against --baseline
  inputs/limits.tsv              the --check file, as given
  inputs/waivers.tsv             the --waivers file, as given
  data/waivers.csv, .json        every verdict a waiver touched
  verify.txt                     provost verify on the report's captures
```

- **Every figure is the engine's.** The summaries show what `qd stats`,
  `qd outliers`, `qd check` and `qd compare` print for the same run,
  computed by the same functions, and each section ends with the exact
  command that prints it again (with `--store`, so it works from
  anywhere). `manifest.json` lists every one of those commands.
- **The summary**, in order: findings; the run (its `qd.runs` record,
  with who ran it, and the launcher and job for a run not over ssh); hosts asked, ok and not answering, with why; the
  figures of every column; the checks; the waivers (`--waivers FILE`
  with `--check`, or the waived verdicts `qd check --keep` filed), each
  with its justification, expiry and who granted it, and waived counted
  apart from passed; drift against the baseline; the
  outliers; the captures' `#%` keys, the run manifest provost reads
  (PV-020), and the ones `provost annotate` added later; `provost verify`'s
  verdict and the store's head commit; the files; how the report was made.
- **A campaign** (`campaign:NAME`, or a design's name) adds its parts and
  their states (`qd campaign status`), the hosts over every part's last
  run, the parts' medians side by side (`qd compare --group`) and a
  requirement-by-part table of checks, then each part's last run as above.
  Earlier runs of a retried part are in `data/` too; a part not run yet
  is a finding.
- **A section with nothing to say is left out, and named** under *Not in
  this report* with why: no `--check` given and no verdicts kept by `qd
  check --keep` (which are used when there are); no `--baseline`; a
  provost without `verify` (provost after 2.3.0 has it); captures with no
  `#%` keys of their own. Sections fill in as those arrive.
- **`summary.html` runs nothing.** It is static: no script, no request
  for anything outside the package, every string from a dataset or a
  thresholds file escaped, and a Content-Security-Policy that would refuse
  a script if one got in. `summary.md` escapes the same text so no
  Markdown renderer reads it as markup or HTML.
- **What the hashes prove.** `SHA256SUMS` shows the package is as it was
  written; qd prints the sha256 of `SHA256SUMS` itself, which is the one
  line to record in the test report. Each copied capture is also checked
  against the sha256 provost recorded for it, and `provost verify` checks
  the store; neither proves the store's history was never rewritten, which
  is why its head commit is recorded too. Signing the package waits for
  provost's signing key (PV-027).
- **Where it goes.** `--out DIR` must be new or empty (default
  `qd-report-RUN`), never inside the store, which provost commits whole.
  The package is written beside it and moved into place whole, so a
  report that fails leaves nothing behind. `--zip` also writes `DIR.zip`.
- `--drift PCT` (`QD_DRIFT`, 5) is how far a median may move from the
  baseline's before it is a finding; `--z` (`QD_Z`, 3.5) is outliers'.

The exit status is 1 when the report records a finding (a host that did
not answer, a check that failed or was not measured, drift, a verify
finding, a part not run), as the command that found it would have, and
0 when it records none. Either way the package is written. A thresholds
file qd cannot read, an `--out` that is taken, or a run that is not there
is exit 2, before anything is written.
