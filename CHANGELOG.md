<!--
SPDX-License-Identifier: GPL-3.0-or-later
SPDX-FileCopyrightText: 2026 Martin J. Gallagher
-->

# Changelog

## 0.51.5 — 2026-11-23

CI's suite jobs have 15 minutes again, not 25 (QD-075, the owner's "lower
the job limit to 15 minutes"), now that provost 2.28.0 is on PyPI.
Patch: CI only.

### Changed
- **`timeout-minutes` on the jobs that run a share of the suite**: 15 on
  the Python 3.9 to 3.13 jobs, the Python 3.6 jobs and the store-check
  jobs, and 20 on the provost 2.1.0 jobs, which file one capture at a
  time. On quarterdeck#73's last run, on PyPI's provost 2.24.0, three
  Python shares took 17 to 20 minutes; the store-check shares, on
  provost 2.28.0, took 6 to 11, and the provost 2.1.0 shares up to 14.4.
  The Python jobs take PyPI's newest provost, 2.28.0 since today, which
  files a run in a fraction of the time (QD-074). QD-070 raised the limit
  to 25 as a stopgap until then. `docs/contributing.md` gives the limits.

### Tests
- **`TIMES` in `tests/run_tests.sh` re-measured from CI**, as QD-024 first
  measured it: each suite's seconds in each of the eight jobs that run the
  suite (quarterdeck#77's first run), parts added up, the mean of the
  eight. The old figures had drifted (survey was 160 and took 447,
  doe_optimize 1200 and took 610), so the deal was uneven: on that run
  provost 2.1.0's third share took 18.5 minutes, near its new 20, while
  its first two took 12 to 13. Dealt by the new figures, the same
  seconds come to at most 866 s a share on provost 2.1.0 (was 1073) and
  501 s on the Python jobs (was 628).

## 0.51.4 — 2026-11-23

A fio tuning study, start to finish (QD-066): the seven steps QD-067 to
QD-072 built, joined up, written down and tested as one. Numbered 0.51.2
on its pull request (quarterdeck#75) until QD-049 took that number on
`main`, then 0.51.3 until QD-074 took that; it is 0.51.4, on top of
0.51.3, with nothing else changed.

### Documentation
- `docs/fio-study.md`, a new chapter: one drive's best fio settings in
  seven `qd doe` steps (the screen, its effects, the follow-up, run
  `--like` the screen, the study compared, the response surface, the
  rounds to the command line to use), with what to decide and what to
  read at each, the real doe's output for each, what the study costs
  the drive, and what to do when `qd doe optimize` stops short. Linked
  from the README, the manual's contents and "Designed experiments".

### Tests
- `tests/test_fio_study.sh`: the whole study in one case, every step run
  on what the one before it filed, from `qd doe init fio` to the
  confirmed settings and their command line, and qd web's views of the
  screen's effects, the study and the region's surface; and again with
  the real doe where it is installed. With the real doe, the case checks
  only what does not turn on whether scipy says doe's search for a
  region's best point converged, which differs between machines for the
  same fit (doe 0.5.0): on CI's runners doe printed no best point where it
  did here. The stand-in doe's case checks every step exactly.
- `stand_in_fio`'s `FIO_PEAK` takes `scale=S`, which flattens its hill so
  read IOPS stays above 0 over a whole screen (the default, 1, leaves
  every other suite's numbers as they were).

## 0.51.3 — 2026-11-23

The slowest suites make their costly setup once, not once a case (QD-074,
the owner's "it should be much faster"), and CI's store-check job takes
provost 2.28.0, which files a run in a fraction of the time. Patch: tests
and CI only. This was 0.50.1 on its pull request (quarterdeck#73), built
on 0.50.0; it is rebased onto 0.51.2 (QD-049, after QD-072's 0.51.1) and
takes the next number, so 0.50.1 is never published. QD-072's
`doe_optimize` suite keeps its `TIMES` figure (1200 s): it does not use
fixtures.

### Tests
- **Where the time goes:** in `tests/test_doe_next.sh`, 320 of 338
  seconds were `provost batch`, at about 1.3 s a run filed, nearly all of
  it provost working out the format of what it is given. Starting qd takes
  80 ms. The rest of the fix is provost's (PV-046: a repeat filing reuses
  the dataset's strategy).
- **`use_fixtures` and `fixture NAME FUNCTION`** in
  `tests/test_helper.bash`: the first case to ask runs the setup, and
  every later case of the suite gets a copy of what it left -- the store,
  the fake hosts, every file, the directory it ended in, the variables it
  exported or unset -- so it starts where it would have. A suite that uses
  it runs each case in one directory path, as a store records its path.
  `tests/test_runner.sh` checks it (made once; files, directory and
  variables kept; a case's own changes reach no other case; refused
  without `use_fixtures`), with mutations that make it fail.
- **The suites that use it**, seconds here before and after (four at a
  time, or alone): web 233 to 115, xstore 135 to 27, compare 169 to 89,
  again 138 to 89, report 86 to 51, remote 85 to 65, rm 73 to 35, view 64
  to 38, study 125 to 67, doe_next 338 to 271, doe_fio 186 to 148, and
  QD-071's doe_surface 290 to 219. Every
  case is the same case; only where its setup comes from changed. `TIMES`
  in `tests/run_tests.sh` has their new seconds, so the three shares stay
  even.

### Changed
- **CI's store-check job takes provost 2.28.0** (`PROVOST_REF` at provost's
  main, d7ce5ea; the job and `docs/contributing.md` say so), not 2.19.0.
  2.28.0 reads a capture into a dataset the store already has with that
  dataset's last strategy first, and scans its strategy ceilings once
  (provost QD-056): a filing takes a fraction of the time. The whole suite
  here on 2.28.0, every store checked: 784 s, four at a time, against 1522
  s on 2.24.0 before this release's fixtures (one case fails here, as on
  `main`: `ssh`'s klist case, which needs ssh and klist this machine has
  not). The other suite jobs take PyPI's newest provost, still 2.24.0:
  they gain this when 2.28.0 is published there.

## 0.51.2 — 2026-11-20

Every way to name a run is one click from where readers start (QD-049).
QD-042 had already moved the table out of "Named stores" into
`docs/concepts.md`, "Naming a run"; this points at it from the places
people look first. Nothing else moves, and no table is copied.

### Documentation
- `qd --help`'s RUN paragraph ends with `docs/concepts.md: "Naming a
  run"`, in place of a bare `See docs/concepts.md` that hung off the
  "Stored by provost" sentence, which now comes first. The card is still
  50 lines of at most 80 columns, so the RUN lines are shorter: "a run
  id" is "an id", and "@STORE a registered store" is "@STORE a store".
- README, "Thirty seconds": what `latest`, `latest~1` and `facts` mean in
  the commands above, and a link to Concepts: Naming a run.
- `docs/reading.md`, "Reading it back", opens with the same link and the
  forms a RUN can take.

### Tests
- `tests/test_help.sh` checks that the card's RUN paragraph ends with
  the pointer; `tests/check_readme_pointers.py` checks that it lands.

## 0.51.1 — 2026-11-20

A test fix in the same pull request as 0.51.0 (QD-072), which is not
published on its own.

### Tests
- `tests/test_doe_optimize.sh`'s interrupted optimize starts qd with
  SIGINT set back to its default, as `test_run.sh`'s `interrupt_when`
  does. A suite run in the background starts with SIGINT ignored, so on
  CI's provost 2.1.0 job the Ctrl-C the stand-in fio sends never reached
  qd, which ran on to the end and exited 0. The suite's figure in
  `TIMES` is now CI's measured one (1200 s over its three parts, not
  600).

## 0.51.0 — 2026-11-20

qd runs the rounds of a tuning study itself until it finds an optimum,
and ends with the settings to use and the command line that uses them
(QD-072, step 7 of QD-066). Built on 0.50.0 (QD-071, quarterdeck#72),
which is not merged yet: the two go to `main` together, or 0.50.0
first.

### Added
- **`qd doe optimize STUDY -c RESPONSE --budget N`** starts from the
  study's central composite or Box-Behnken follow-up and runs every
  round on the hosts and target it ran on, straight through. While doe's
  surface puts the best point on the region's edge it walks doe's
  steepest path (`doe optimize --steepest`) a step at a time until a
  step is no better, then lays a design of the same kind and size
  around the best point measured (doe generate). Once the optimum is
  inside, `doe next-batch` adds points near it (`--batch`, `--strategy`;
  `model_guided` for a response to minimise, since doe's refine centres
  on the largest value) and qd runs confirmation runs
  (`--confirm-runs`) at doe's best point inside the region. It stops on
  the owner's rule (the confirmation mean within doe's prediction, give
  or take twice doe's cross-validated error, and that round's gain in
  the best measured under 2%, `--min-gain`), when the budget is spent
  (never passed: a round it cannot finish is not begun), or when it
  cannot go on, and says which. The report gives every round, the
  recommended settings beside the starting ones, the measured response
  (mean, range, sd) and doe's prediction, the change from the start,
  whether it is only the best of the region searched or the best the
  study has measured anywhere, and the command line with every held
  factor. `--json` prints it as JSON. Exit status 0 for an optimum, 1
  for a stop short of one, 130 for Ctrl-C (`quarterdeck/optimize.py`;
  `quarterdeck/doe.py`: `steepest`, `next_batch`, `one_response`;
  `quarterdeck/cli.py`: `doe_optimize`, `optimize_start`,
  `optimize_lines`).
- Every round is a design of the study (`STUDY-RESPONSE-path1`,
  `-region1`, `-confirm1`, with `metadata.qd_round`; a refinement adds
  points to the design it refines, `metadata.qd_refines`), so `qd doe
  status`, `qd compare --study` and qd web's study view show them.
  Everything is decided again from the store, so an interrupted
  optimize, or one out of budget, carries on when run again, nothing
  measured twice; the budget counts the runs it made before.
- A factor's `qd_min` and `qd_max` in a doe config (doe ignores them)
  limit what later rounds set it to; a count is rounded and kept at 1 or
  more. `qd doe init fio` gives `rwmixread` 1 to 99.
- `qd hints`: "Run the rounds until the best fio settings are found".

### Tests
- `tests/test_doe_optimize.sh`: a hill and a bowl whose top is outside
  the first region, walked to and confirmed (maximise and minimise), the
  recommended command run through the stand-in giving what was
  measured, the budget kept to the run and carried on, an optimize
  interrupted by Ctrl-C carrying on, the stop when nothing measures, the
  factors' limits, and the real doe where installed. The stand-in doe
  gains `optimize --steepest` and `next-batch`, the stand-in fio
  `FIO_INTERRUPT`.

## 0.50.0 — 2026-11-20

A response surface fitted to a central composite or Box-Behnken
follow-up, with its maximum or minimum and whether that is inside the
design region or on its edge, and contour charts of it in `qd web`
(QD-071, step 6 of QD-066).

### Added
- **`qd doe surface NAME [-c RESPONSE]`** runs `doe analyze` (with its
  `--csv` tables) and `doe optimize` for one response and reports what
  doe found: its fitted model (the quadratic, or linear with too few
  points, in doe's coding), the fit (R², adjusted and predicted R², the
  lack-of-fit test of doe's ANOVA where points repeat), the stationary
  point with its kind (maximum, minimum, saddle, ridge), its settings in
  the factors' own units and coded, and doe's predicted response there
  with doe's cross-validated error, and doe optimize's best point inside
  the design region. It then says plainly whether the optimum is inside
  the region (confirm it) or on its edge, naming the factor and the end
  (another round is needed). With no `-c` a follow-up's own response
  (`metadata.qd_follows`) is used. `--report [DIR]` keeps doe's report
  and its response-surface plots (`rsm_*.png`) as `qd doe analyze
  --report` does; `--json` prints the figures and qd web's contours
  (`quarterdeck/doe.py`: `surface`, `verdict`, `surface_grids`,
  `optimize_text`, `lack_of_fit`, `read_tables`; `quarterdeck/cli.py`:
  `doe_surface`).
- **`/api/surface?name=NAME&c=COL&agg=AGG`** in `qd web`, and a
  "Response surface" card on a central composite or Box-Behnken
  design's page (a button on any other design's): doe's figures and the
  verdict, and a contour chart for each pair of numeric factors, the
  others held at doe's best point. The grid is doe's own fitted
  polynomial evaluated by the engine, which also places the contour
  levels, lines and shading; the page only draws them, with the design
  region, the design's points (hollow where not measured), the
  stationary point and the best point marked (`quarterdeck/web.py`:
  `surface`; `quarterdeck/web/app.js`: `surfaceCard`, `contourChart`).
  `/api/design` says whether a design is a surface design and which of
  its factors are numeric.
- Tests: `tests/test_doe_surface.sh` (new) runs a central composite on a
  stand-in fio whose read IOPS is a known hill and read latency a known
  bowl (`FIO_PEAK`): the stationary point is found within tolerance and
  called a maximum (and a minimum), an optimum beyond iodepth's high
  level is reported on the edge, a point fio failed is left out (never
  0), `--report` keeps the surface plots, `--json`'s grid is doe's
  model, and a two-level design has no surface; with the real doe where
  it is installed. `tests/test_web.sh` checks `/api/surface`. The
  suite's stand-in doe now fits the quadratic as doe does (least
  squares in coded units), writes doe's model-adequacy, cross-validation
  and stationary-point tables, a lack-of-fit row and surface plots, and
  prints `doe optimize`'s models and surface optimum.

### Changed
- `qd --help`'s doe line names `surface`, `qd hints` has a surface
  line, and docs/getting-started.md's map names it.
- **The manual:** `docs/larger-jobs.md` has a new section, "The response
  surface: `qd doe surface`", after the doe follow-up and before "A
  study, every run of it", and the `qd doe` command block names
  `qd doe surface`; `docs/reading.md`'s `qd web` list names the
  response surface card.

## 0.49.1 — 2026-11-20

CI's suite jobs have 25 minutes, not 15 (QD-070). 0.49.0 and 0.49.1 share
one pull request, so 0.49.0 is not published on its own.

### Changed
- **`.github/workflows/ci.yml`:** the four jobs that run a share of the
  suite (Python 3.9 to 3.13, Python 3.6, provost 2.1.0 and the store
  check) time out at 25 minutes. A share usually takes 7 to 9 minutes,
  and a slow runner runs every suite about twice as long: on `main`'s own
  run for 0.48.0, Python 3.10's first share took 14.6 minutes and
  provost 2.1.0's second 14.7, against a limit of 15. 0.49.0's run lost
  Python 3.10's first share to it, and QD-071's run lost five shares, each
  stopped at 15 minutes with every case that had finished passing. 25 is
  still about three times a share's usual time, as QD-024 set out.

## 0.49.0 — 2026-11-19

Every run of a study -- a screen, its follow-up and every later round --
side by side, in `qd compare --study` and in `qd web` (QD-070, step 5 of
QD-066's fio tuning study).

### Added
- **`qd compare --study STUDY`** lines up every run of every design of a
  study: a row per run and host, with the design, the point, each
  response (`-c COL,COL`, a column or a config's response by name; by
  default every response the configs name a column for, each one number
  from the host's ok rows: the median, or `--agg`), every factor as a
  column, the host's status and the run. Where a design varied a factor
  the cell is the point's level; where it held it, the level it held (a
  follow-up's `rw=rw`, which the screen varied). A factor every design
  held at one level is said once above the table; one a design neither
  varied nor held is blank on its rows, and said. A host that failed a
  point has a blank response, never 0. `--where`, `--sort` (new, for
  `--study` only) and `--format` as elsewhere; `--group`, `--last`,
  `--baseline`, `--peers`, `--key` and `--table` are refused beside it
  (`quarterdeck/study.py`, new: `studies`, `members`, `build`,
  `run_cells`, `chart`; `quarterdeck/cli.py`: `compare_study`).
- **`qd doe status`** lists a study's designs (type, points measured,
  runs, what each follows and varies) under the screen's own points once
  the study has two, and `qd doe status STUDY` for a study named for no
  design lists them alone; a follow-up's status points at its study
  (`study_lines`, `doe_study_status`).
- **qd web's study view**: a study of two designs or more is listed above
  the campaigns and designs (`/api/groups`' `studies`). Its page lists the
  designs, then every run in one table, sorted by a column's heading and
  filtered by the filter bar, a held factor's level in grey italics, a row
  opening its run; and a chart of a response against a chosen factor,
  each design a colour, a dot per run and host and a line through the
  design's median at each level. `/api/study` (new) gives the rows, the
  filter and sort, the points and the medians, from the same engine as
  `qd compare --study`: the page computes nothing.
- `tests/test_study.sh` (new suite, in `TIMES` and `PARTS`): a study of
  two designs with different factors, every run once with the right
  varied and held levels, blank staying blank, the refusals, `qd doe
  status`, and the web API's rows, filter, sort and chart.

### Changed
- Nothing is filed for a study: a design's study is its config's
  `metadata.qd_study` (QD-069), else its own name, so `qd.designs` keeps
  its columns and a store written before reads as one study per design.
- `qd --help`'s compare line names `--study`; qd web's sidebar heading
  is "Studies, campaigns and designs".
- **The manual:** `docs/larger-jobs.md` has a new section, "A study,
  every run of it", after the doe follow-up; `docs/over-time.md`'s
  `qd compare` examples carry `--study`, and `docs/reading.md`'s `qd web`
  list names the study view.

## 0.48.0 — 2026-11-19

A design's main effects, interactions and a Pareto of effect sizes as
charts on its page in `qd web`, and doe's own HTML report and plots kept
by `qd doe analyze --report` and linked from there (QD-068, step 2 of
QD-066).

### Added
- **`qd doe analyze NAME -c COL --report [DIR]`** runs `doe analyze`
  without `--no-plots --no-report`, so doe makes its Pareto,
  main-effects, half-normal and other plots and its HTML report, and
  keeps them, with the results and config that made them, in DIR or
  else in qd's cache (`~/.cache/quarterdeck/doe/STORE/DESIGN/COLUMN`, never
  the store). It says where the report is and names the plots. A
  directory qd made before is emptied first; one holding anything else
  is refused, never emptied (`quarterdeck/doe.py`: `report_dir`,
  `report_files`; `quarterdeck/cli.py`: `doe_report_lines`).
- **`/api/design?name=NAME&c=COL&agg=AGG`** in `qd web`: each point's
  value, each factor's level means, each pair of factors' cell means, the
  two-level interaction effects and a Pareto of effect sizes, all from
  `doe.effects()` (plain means of the points measured; the statistics
  stay doe's), with the design's response columns and a link to doe's
  report when one is kept. doe's reports and plots are served at `/doe/`
  from qd's cache only, in a sandbox (`Content-Security-Policy: sandbox
  allow-scripts`), so a report can neither act as the page nor read its
  API.
- **A design's page in `qd web`** has a column and a per-point figure
  picker, the Pareto chart, a main-effects chart per factor on one shared
  scale, an interaction chart for a chosen pair, and the link to doe's
  report (`quarterdeck/web/app.js`: `designCharts`, `paretoChart`,
  `levelChart`). A point not measured is left out of every mean and
  drawn as a gap, never as zero.
- Tests: `tests/test_web.sh` checks every figure for a design with known
  responses, blank points left out, the report served sandboxed from the
  cache and nothing else; `tests/test_doe.sh` checks `--report` (where,
  remade, a directory named, a foreign directory refused), and with the
  real doe where it is installed. The suite's stand-in doe writes a plot
  and a report unless told not to, as the real one does.

## 0.47.0 — 2026-11-19

The advice qd already prints now points newcomers at the beginner
commands, where they save steps (QD-065).

### Added
- **`qd hints` opens with Getting started**: `qd setup`, `qd ask`, `qd
  survey`, `qd again` and `qd odd`, each with its question, in the start
  card's order. Their hints moved there from Run, Read it back, Over time
  and Help, so each command is hinted once. The heading is the start
  card's own (bare `qd`); the full card, at its 50-line limit, keeps its
  headings, and the rest of `qd hints` stays under them
  (`quarterdeck/cli.py`: `HINT_GROUPS`, `HINTS`, `cmd_hints()`).
- **WHAT TO DO NEXT after `qd run` and `qd probe`** suggests:
  - `qd odd latest` for a run of several columns, in place of one
    column's `qd outliers` (the block keeps its length);
  - `qd again latest` for a run every host answered with no earlier one
    to diff against, and only when `qd again` would accept it: not a
    probe, a pushed run, a campaign part or a design point
    (`quarterdeck/again.py`: `why_not()`, the refusals `the_run()` makes,
    now shared);
  - `qd survey` with the hosts and options typed, after `qd probe facts`,
    for next time: facts and inventory, and one screen of who stands
    out. Not after `--every`/`--count`, which survey refuses
    (`quarterdeck/cli.py`: `report_run()`'s `probe`, `survey_tip()`,
    `run_next_steps()`).
- **An empty store says the two ways in:** `qd log` on a store with no
  runs (and no datasets) prints WHAT TO DO NEXT with `qd setup` and `qd
  demo`; `qd doctor` on one adds `qd setup` beside its `qd demo`; and a
  read of `latest` in one ends its error with "new to qd: `qd setup`, or
  `qd demo` to practise" (`quarterdeck/cli.py`: `cmd_log()`,
  `cmd_doctor()`; `quarterdeck/store.py`: `resolve()`).

### Tests
- `tests/test_help.sh`: `qd hints` opens with Getting started and the
  five commands in order, each hinted once; its first heading is the
  start card's and the rest the full card's; the hints check fails on a
  misspelt heading (`tests/help_unit.py`: `HINT_GROUPS`, and a new `next
  FILE` case: every `qd` command under a WHAT TO DO NEXT parses).
- `tests/test_run.sh`: `qd again` after a first run, `qd diff` and no `qd
  again` after a second, `--rerun` and no `qd again` when a host did not
  answer, `qd odd` in place of `qd outliers` for several columns, none
  after `--script`, every suggestion parsing and each block six lines at
  most; an empty store's `qd log` and `qd show latest`.
- `tests/test_probe.sh`: `qd probe facts` suggests `qd survey` with the
  options typed, and `qd odd`, never `qd again`; not after another probe,
  or with `--count`.
- `tests/test_demo.sh`: `qd doctor` on an empty store names `qd setup`
  too.
- `tests/test_ask.sh`: `qd ask` falling back to qd run's summary for
  several columns suggests `qd odd` and `qd again` as qd run does.

## 0.46.4 — 2026-11-19

The README is now a short front page, and the manual is in `docs/`, a
chapter for each thing you are trying to do (QD-041). A move, not a
rewrite: every section of the old README is in exactly one place, word
for word, with only heading levels and links changed (and four
cross-references on the front page made links, since their sections
moved).

- **`README.md`** (202 lines, PyPI's page): what qd is, install, *Thirty
  seconds*, the commands by what they are for, the manual's chapters,
  Related and License. Its links into `docs/` are absolute GitHub links,
  so they work on PyPI too.
- **`docs/README.md`**: the contents. The chapters: `running.md` (the
  demo fleet, `qd setup`, `qd run`, `qd ask`, `qd probe` with saved probes
  and `qd survey`, `qd do`, at scale), `reading.md` (`--where`, `freq`,
  `outliers`, `odd`, `diff`, `again`, `qd view`, `qd web` and its
  screenshots), `over-time.md` (`qd compare`, `qd changes`, peers and
  baselines), `judging.md` (`qd check` with waivers, `--manual`,
  `--baseline`, JUnit and `--rule`; `qd report`), `larger-jobs.md` (`qd
  split`, `qd coverage`, `qd campaign`, `qd doe`),
  `telemetry-and-export.md` (`qd join`, the floor plan, export),
  `stores.md` (provost's store, who ran it, named stores),
  `conventions.md` (conventions, exit status) and `contributing.md`
  (tests, what CI runs, working on quarterdeck). `getting-started.md`,
  `concepts.md` and `scale.md` keep their names; `concepts.md`'s links
  now land in the chapters.
- **`tests/check_links.py`**, new: every link and image between
  `README.md` and `docs/*.md` lands, `#anchors` by GitHub's slugs,
  absolute links to this repository checked against the tree. Run by
  `tests/check.sh`, by `tests/test_help.sh` (with broken copies to show it
  fails) and by a new CI job, *manual links and pointers*.
- **`tests/check_readme_pointers.py`** reads the whole manual, and a
  pointer names its page: `docs/judging.md: "Waivers"`. The seven
  pointers in `cli.py`, `coverage.py`, `exporters.py` and `policy.py` name
  their chapters.
- `qd --help`'s *Full manual*, `common.DOCS` and `pyproject.toml`'s
  Documentation URL point at `docs/`; `MANIFEST.in` ships every `docs/*.md`
  and screenshot; `CLAUDE.md` says README.md and docs/ are the manual.
  `tests/test_saved.sh`, `test_odd.sh` and `test_concepts.sh` read the
  chapters their text moved to.

## 0.46.3 — 2026-11-19

The README's everyday read commands now come right after `qd run` and
`qd probe`, ahead of the specialist sections (QD-048). A pure move of whole
sections: no heading or prose changed but one cross-reference.

### Changed
- **README:** the H2 sections now run: the introduction and "Thirty
  seconds"; `qd run`, `qd ask`, `qd probe`; "Reading it back"; `qd view`,
  `qd web`; `qd compare`; then the specialist sections in their old order
  (`qd split`, `qd coverage`, `qd campaign`, `qd peers`/`qd baseline`,
  `qd check`, `qd report`, `qd doe`, `qd do`, `qd join`, the floor plan,
  Splunk/Prometheus/notebook); "What it keeps: provost's store", with Named
  stores; Conventions, At scale, Exit status; Tests, Working on quarterdeck;
  Related, License. The sorted lines before and after differ in one line:
  `qd compare`'s "(next section)" for the Mann-Whitney test, now "(*Peer
  groups and qualified baselines*, below)".
- **tests/test_concepts.sh:** the Named stores excerpt ends at
  "## Conventions", the section that now follows it.

## 0.46.2 — 2026-11-19

The getting-started page is a newcomer's first day: the start card, then
the five beginner commands in order, each run and checked (QD-064).

### Changed
- **`docs/getting-started.md`** opens with the start card (bare `qd`) and
  takes QD-057's five first-day questions in order: can I reach my hosts
  (`qd setup`), who agrees and who differs (`qd ask`), what is every host
  like (`qd survey`), what changed (`qd again`) and who is odd (`qd odd`).
  Each shows the command's real output and the plain qd commands it
  stands for. `qd odd` and the plain commands read the demo; setup, ask,
  survey and again ask this machine, reached without ssh, into the store
  `main` setup makes, so the demo's store keeps only the demo. It ends
  with where to go next: `qd --help`, `qd help VERB`, `qd hints`, the
  Concepts page and the README.
- **The start card names the page**, on a line of its own under its
  footer.

### Tests
- `tests/walkthrough.py` checks a block opened by `<!-- walkthrough:
  loose -->` (a command that asks this machine) with `[...]` for what is
  the reader's own, this machine's name read as the page's `<!--
  walkthrough: this machine is NAME -->`, and time stamps and widened
  columns matched; everything else is compared exactly, and `--update`
  leaves a loose block to be put right by hand.
- `tests/test_demo.sh`: the checker on a page of its own, each rule
  broken in turn; a changed line of the real page fails on the demo; the
  page is the start card, the five questions in order, each with what it
  stands for, and where to go next last; every qd command on it parses
  with `build_parser()`. That `qd demo` ignores the shell's fleet
  settings is checked on `--rebuild`, since the page's fleet commands
  honour them. `tests/test_help.sh`: the start card names the page.

## 0.46.1 — 2026-11-19

Every use of column `A` in the docs and help now says what it is: provost's
name for a column nothing names, `A`, `B`, ... as a spreadsheet's (QD-047).

### Changed
- **README:** "Thirty seconds" also says that `qd show latest` shows the
  columns, and reads the sample run's `[provost: uname: A]` (the dataset,
  then its columns); the demo block, "Over time"'s `qd trend latest A`,
  `qd ask`'s opening paragraph (linking Concepts) and "Reading it back"'s
  `qd freq latest A` each carry a short gloss.
- **`qd --help`**'s core-loop `qd freq latest A` (reworded, still 50 lines
  of at most 80 columns), **`qd hints`**' `qd ask` entry, **`qd help
  ask`**, the demo's WHAT TO DO NEXT and `qd setup`'s run tip say what `A`
  is (`quarterdeck/cli.py`, `demo.py`, `firstrun.py`).
- **docs/getting-started.md:** the demo's WHAT TO DO NEXT, the kernel
  step (now linking Concepts) and the own-fleet loop.

### Tests
- `tests/test_run.sh`: a one-word answer files a column named `A`
  (`[...: A]` on the summary, `host,A` from `qd show`), on whichever
  provost path the suite runs, so a change in provost's naming fails
  rather than leaving the docs wrong.

## 0.46.0 — 2026-11-19

A central composite or Box-Behnken follow-up from a screen's big
factors, run on the same host and target as the screen (QD-069, steps 3
and 4 of QD-066's fio tuning study, on one drive of one host).

### Added
- **`qd doe next SCREEN -c RESPONSE`** writes a follow-up doe config for
  one response: the screen's big numeric factors (inside doe's 80% Pareto
  line, at most four; topped up to two from the next numeric factor that
  moved it; `--factors` to choose) varied over the screen's own levels,
  every other factor held at the level the screen found better for that
  response (or its first level where it saw no effect), the screen's own
  fixed factors, command and responses kept. The design is doe's: `doe
  suggest --goal response_surface` for that many factors and `--budget`
  runs (30), its choice and reasons shown, and the point count `doe
  generate` lays out. A categorical factor is never varied: it is held,
  with a line saying so; a response moved only by categorical factors has
  nothing to fit a surface over, and is refused. A suggestion that is not
  a central composite or Box-Behnken (too small a budget) is refused, as
  is writing over a file. Box-Behnken's fractional middle level of a
  whole-number factor (16.5 between 1 and 32) is warned about
  (`quarterdeck/doe.py`: `choose`, `suggest`, `follow_up`, `between`;
  `quarterdeck/cli.py`: `doe_next`).
- **`qd doe run CONFIG --like DESIGN`** runs on exactly the hosts DESIGN's
  points ran on (addresses and attributes), and says so; it takes no other
  host list. The config holds what DESIGN held: a fixed factor it leaves
  out is taken from DESIGN, one it sets otherwise is refused. A host that
  answered at none of the points run is named at the end, as gone, rather
  than skipped (`like_design`, `like_hosts`).
- **A study**: the follow-up's config names the study it belongs to
  (`metadata.qd_study`, the screen's) and what it follows
  (`metadata.qd_follows`), filed with the design; `qd doe status` shows
  it. QD-070 builds its study view on this.
- The stand-in doe in `tests/test_helper.bash` makes central composite
  and Box-Behnken designs as doe/pyDOE3 do, and answers `suggest`;
  `tests/test_doe_next.sh` is the new suite (in `TIMES`).

### Changed
- `qd --help`'s doe line names `next` (and `init fio` beside it).

## 0.44.0 — 2026-11-19

A Plackett-Burman screen of fio's parameters on one drive of one host,
and an analysis that ranks which parameters move each of several fio
responses at once (QD-067, the first step of QD-066's fio tuning study).

### Added
- **`qd doe init fio`** writes `fio-screen.json`, a doe config for a
  Plackett-Burman screen of seven fio parameters at two levels each (bs
  4k/128k, iodepth 1/32, numjobs 1/8, rwmixread 30/70, rw rw/randrw,
  ioengine libaio/io_uring, direct 0/1: 8 points), with the reason for
  each in its `description`; size 8G, runtime 60 s, ramp 10 s and the
  file held fixed (doe's `fixed_factors`); the fio command in
  `metadata.qd_command`; and eight responses, each naming the column of
  fio's JSON (as provost parses it) it is read from: read/write IOPS,
  bandwidth, mean and p99 completion latency. The factor set is a
  proposal for the owner to approve before the first real run
  (`quarterdeck/doe.py`: `FIO_SCREEN`, `init`).
- **A config can say how long one point needs** (`metadata.qd_timeout`,
  seconds), and `qd doe run` uses at least that as its per-host
  `--timeout`, saying so. The fio screen asks for 180 s: one point is a
  10 s ramp and a 60 s run, past qd's 60 s default, which would have
  stopped every point part-way (`quarterdeck/doe.py`: `timeout_of`).
- **`qd doe run CONFIG`** needs no command after `--` when the config
  names one (`metadata.qd_command`), and puts doe's `fixed_factors` into
  the command by `{name}` like the factors. A design run again with other
  fixed factors is refused, as another command is: `--name` a new one.
- **`qd doe analyze NAME`** analyses several responses in one go:
  `-c COL,COL,...` (a column, or a response of the config by name), or by
  default every response of the config that names its column. Each
  point's responses go to doe as one `run_<id>.json`, with no key at all
  for a response that point did not measure, so doe leaves it out of
  that response (blank, never 0). After a table of the responses per
  point, qd ranks doe's main effects per response (read from `doe
  analyze --csv`): the big factors are those inside doe's own 80% Pareto
  line, each with the level that maximises or minimises that response,
  then the rest.
- **The typo guard refuses fio writing a raw device** (`--filename=/dev/...`
  with a writing `--rw`) without `--yes`, in `qd run`, `qd doe run` and
  every verb that checks; reading a device, or writing a file, `/dev/null`
  or `/dev/shm`, is not refused. binnacle's copy of the guard does not
  have this rule yet (`quarterdeck/cli.py`: `DANGER`).
- `tests/test_doe_fio.sh` (new suite, in `TIMES`), with a stand-in fio in
  `tests/test_helper.bash` that prints fio 3.36's JSON, its numbers a
  known function of its options; the stand-in doe now makes
  Plackett-Burman designs, analyses every response and writes doe's
  `--csv` main-effects tables.

### Changed
- **A point whose every run failed on every host is not measured**: `qd
  doe run` runs it again (without `--redo`), and `qd doe run` and `qd doe
  status` count only points where a host answered ok. Before, a point
  that had failed was counted as measured and skipped.
- README's "Designed experiments" has a worked fio screen;
  docs/getting-started.md's map and `qd hints` name `qd doe init fio`.
## 0.43.0 — 2026-11-19

Your own named probes: `qd probe add NAME -- COMMAND` gives a command a
name, asked for like the probes qd ships, with fio as the README's worked
example (QD-054).

### Added
- **`qd probe add NAME [--note TEXT] [--replace] -- COMMAND`** saves a
  probe, **`qd probe rm NAME...`** forgets it, and **`qd probe`** lists the
  saved ones beside qd's own, kind `yours`, with each command in full
  under the table. `qd probe NAME [HOSTS]` runs one exactly as `qd run
  --name NAME -- COMMAND` would: every fleet option `qd probe` takes, a run
  named after the probe with its command whole and no tool, so `qd show`,
  `qd compare NAME --last 5` and `qd check NAME` find it; its notes say
  `your probe NAME`. Named beside qd's own probes it runs after them, a
  run of its own (`quarterdeck/probes.py`: `load_saved()`, `add_saved()`,
  `rm_saved()`, `check_saved_name()`, `get()` and `available()` knowing
  kind `saved`; `quarterdeck/cli.py`: `cmd_probe()`, `probe_catalogue()`,
  `probe_saved()`, the probe verb's `--note` and `--replace`, and `main()`
  cutting `qd probe`'s command off at `--` as it does `campaign`'s and
  `doe`'s).
- **Kept in `probes.json` beside `config.json`** (`~/.config/quarterdeck/`,
  `$XDG_CONFIG_HOME/quarterdeck/`), written whole and renamed into place,
  never in a store: a store from another machine brings no commands to run
  on this fleet.
- **Refused, exit 2:** a name that is not a run's name as it is (letters,
  digits, `.`, `_`, `-`, starting and ending with a letter or digit, at
  most 64, no `..`, not `unsorted` or `qd.*`), a probe or group qd ships,
  the words `add`, `rm` and `latest`, and `add` over a saved name without
  `--replace`.
- **Never a way around a policy.** A saved probe is not a probe qd ships:
  `--allow` and `--read-only` check its command (not its name), and the
  mutation guard reads it, a saved `rm -rf` needing `--yes` at every run
  (`add` warns). Asked beside qd's own probes, it is checked before any of
  them runs, so a refusal leaves nothing half done. `check_danger()` takes
  the line to repeat with `--yes`, so it names `qd probe NAME --yes`.
- **`qd --help`**, **`qd hints`** and `docs/getting-started.md`'s command
  map name `qd probe add` and `rm`; the README's "Asking by name: `qd
  probe`" has "Your own probes: `qd probe add`", with a fio random-read
  probe (`--output-format=json`), the columns provost files from fio's
  JSON and a `qd check` limit on IOPS and on p99 latency; "Allow-lists and
  read-only" says a saved probe's command must match.

### Tests
- **`tests/test_saved.sh`** (new, in `TIMES`): add, list, run, replace and
  rm with the config in a temporary `HOME`; a run filed under its name,
  its command whole, and `qd compare NAME` reading two (and three, beside
  qd's own probes); clashes, bad names and `add` without `--replace` each
  exit 2 and change nothing; `--read-only` with no allow-list refusing a
  saved probe (nothing filed, `policy.log` written) while `os` runs, a
  saved probe asked beside `os` refused before `os` runs, an allow-list
  naming the probe's name not allowing it and one matching its command
  allowing it; the mutation guard stopping a saved `rm -rf` (with `--allow
  'rm *'` too) until `--yes`; another config over the same store listing
  no probe; and fio's JSON (`tests/corpus/fio/randread.json`, fio 3.36's
  shape, no fio needed) filed by the provost under test into the README's
  columns and values, with the README's limits giving a pass and a fail.
- `tests/help_unit.py` cuts `qd probe`'s command at `--`, as `main()` does.
- Merged after QD-040's regrouped `qd --help` card and QD-060's `qd
  survey`: `run_probes()` keeps survey's `say` and returned runs beside
  the saved probes' fifth field, and the card's `survey | probe` line
  names your own probes.

## 0.42.0 — 2026-11-19

`qd setup`: a first-run guide that checks this machine, makes and selects
a store, finds or writes the host list, and tests every host (QD-063,
from the design in QD-057).

### Added
- **`qd setup [HOSTS] [--yes] [--store-name NAME]`** (new
  `quarterdeck/firstrun.py`; `cmd_setup` and the verb in
  `quarterdeck/cli.py`). Four steps, each a plain command called as that
  command runs, so `--store`, `--via`, `--sudo` and every `QD_*` variable
  mean what they mean there: `qd doctor`'s report; when no store is active
  (or the demo is), an offer to make `main` and select it (`qd store new`,
  `qd store use`); the host list as `qd run` finds it, or an offer to write
  `hosts.txt` from typed names; `qd run -- true` on every host, keeping
  nothing, with each host that did not answer listed with why and what to
  do for its kind of failure (a key, a host key, a name that does not
  resolve, a host that is down, a timeout, a login that fails). Then a
  summary, and WHAT TO DO NEXT naming `qd ask -- uname -r`, `qd survey`
  (`qd run` and `qd probe facts inventory` in a qd without them yet) and
  `qd demo`.
- **It asks only at a terminal**, checking `sys.stdin.isatty()` before
  every question: with stdin not a terminal it checks everything, changes
  nothing that needs an answer, and says what to run instead. `--yes`
  answers the store's question for a script; it never writes `hosts.txt`
  and never picks among stores already registered. `hosts.txt` is created
  (`open(..., "x")`), never overwritten, and the active store is changed
  only when asked. The test run is filed nowhere, so a second `qd setup`
  changes nothing and reports every step done.
- **Exit status:** 0 when this machine is ready (`qd doctor` exits 0 and
  provost is here) and every host answered; 1 when it is not ready or a
  host did not answer, the summary naming the step; 2 on a usage error, a
  host list that cannot be read, or a write that was refused.
- **`qd --help`** has a `qd setup` line, and its "New to qd?" note names
  it; **`qd hints`** has a hint for it; the README has "Your own fleet,
  the first time: `qd setup`"; `docs/getting-started.md` names it in "Your
  own fleet" and in its map of every command.

### Tests
- **`tests/test_setup.sh`** (new, 9 cases), each an account of its own
  with no `QD_STORE` and the fake fleet: a fresh account with stdin from
  `/dev/null` asks nothing and changes nothing; `--yes` makes and selects
  `main`, and a second run changes neither qd's config nor the store; a
  store already active, and stores registered with none active, are left
  as they are; the demo active is replaced only when asked; an unreachable
  host and one whose name does not resolve are each listed with why and
  what to do, exit 1; a bad `--store-name`, an empty `hosts.txt` and a
  `hosts.txt` already there exit 2 or are refused, the file unchanged;
  driven at a terminal by Python's `pty`, it asks, makes the store and
  writes `hosts.txt` from the answers, and a run after it finds it all
  done. Every command it lists under WHAT TO DO NEXT parses with
  `build_parser()`. `TIMES` gives the setup suite 20 seconds.
- Merged after QD-040's regrouped `qd --help` card: `setup` shares the
  Run line with `hosts`, `import` moves to `rm`'s line under Stores and
  output to keep the card at 50 lines, and `setup` is on the start card
  under Getting started, as QD-058's note above `START` asks.

## 0.41.0 — 2026-11-19

`qd survey [HOSTS]`: every host asked the standard questions, and one
screen of who stands out (QD-060, from QD-057's beginner layer).

### Added
- **`qd survey`** runs `qd probe facts inventory` -- the same runs, under
  the same names, with `qd run`'s host options -- and prints, in about 40
  lines at most for any fleet: the values most hosts share (`os`,
  `kernel`, `bios_version`, `cpu_model`, `cpu.count`, `mem.total_kb`: a
  fixed list, blanks not counted), the hosts that differ from the rest of
  their rack in them (`outliers --categorical`), the numeric outliers by
  median and MAD (`facts`' load, memory, disk, retransmit and temperature
  readings, and `packages`' count), and the hosts that did not answer.
  Each section names three hosts and counts the rest; `FOUND` names the
  step that found each thing; WHAT TO DO NEXT lists the plain `probe`,
  `freq` and `outliers` commands with real column names. binnacle missing
  skips `facts`, named with how to get it; no hosts named surveys this
  machine and points to `qd demo`. Exit 0 when every host answered and
  nothing stands out, 1 otherwise, 2 on a usage error
  (`quarterdeck/survey.py`, new; `quarterdeck/cli.py`: `cmd_survey`, the
  `survey` verb, and `run_probes()`, `qd probe`'s fan-out taken out of
  `cmd_probe` so the survey runs exactly it). Nothing is recounted: the
  figures are `stats.freq`, `report_categorical` and `stats.outliers`,
  each given the Namespace qd's own parser makes from the command printed
  for it.
- **`qd --help`** lists `qd survey [HOSTS]`; **`qd hints`**' "Everything
  about every host" names it beside `qd probe facts inventory`; README's
  "Every host, and who stands out: `qd survey`"; `docs/getting-started.md`'s
  map of every command (`tests/test_demo.sh` requires every verb there).

### Tests
- **`tests/test_survey.sh`** (new, in `TIMES`): on the fake fleet, with a
  stand-in `uname -r` and a stand-in binnacle: one odd kernel, one numeric
  outlier and one unreachable host are named, exit 1, with the step that
  found each; the runs filed match `qd probe facts inventory`'s; binnacle
  missing is a skip, exit 0; no hosts is this machine, pointing to `qd
  demo`; every WHAT TO DO NEXT command parses and the read ones run; 16
  hosts with four of each finding stay within 40 lines; usage errors exit
  2; the card, hints and `qd help survey` name it.
- Merged after QD-040's regrouped `qd --help` card: `survey` leads the
  line `probe` had under Run, and is on the start card under Getting
  started, as QD-058's note above `START` asks.

## 0.40.0 — 2026-11-19

`qd again [RUN]` runs a run once more, as it ran, and shows what changed
(QD-061).

### Added
- **`qd again [RUN]`** (default `latest`; any reference `qd diff` takes)
  runs RUN's command again on RUN's hosts with its `--via`, `--sudo`,
  `--timeout`, `--name` and passes, files the new run, then prints `qd
  diff RUN NEW`. The hosts are RUN's host file read again while it is
  there, else the hosts RUN ran on, with their addresses and attributes.
  It prints the command, the hosts and the plain `qd run` before it runs,
  asks before a `--sudo` run when stdin is a terminal (never otherwise;
  `--yes` skips it), and ends with which step found what and WHAT TO DO
  NEXT. Exit 0 when every host answered and nothing changed, 1 when a host
  did not answer or something changed, 2 when RUN cannot be run again
  exactly: a `qd do` run, a `qd import`, a campaign's part, a design point,
  a probe, a run that pushed files, or one filed before 0.40.0. It is
  composed of `qd run` (`cmd_run`, given the Namespace the parser makes of
  the plain command) and `qd diff` (`cmd_diff`): no reader or statistic of
  its own (`quarterdeck/again.py`; `cli.py`: the verb, `cmd_again`).
- **`qd.runs` keeps `timeout_s`, `pushed` and `host_list`** for a `qd run`:
  its `--timeout`, how many files it pushed, and the host files its list
  was read from (`quarterdeck/store.py`; `cli.py` `cmd_run`, `collect()`;
  `hosts.py` `collect_hosts(files=...)`). Blank in older runs.
- **`qd --help`** has `qd again`'s line, **`qd hints`** suggests it, and the
  README has "`again`: the same run once more, and what changed", and
  `docs/getting-started.md`'s map of every command names it.

### Changed
- `--rerun`'s host reading is `last_pass_hosts()`, which `qd again` shares
  (`cli.py`); `--rerun` behaves as before.

### Tests
- **`tests/test_again.sh`**: nothing changed (exit 0), a changed answer
  (exit 1, the host named), a host now unreachable (exit 1), the host file
  read again or its hosts kept, `--via pdsh` with `--timeout` and `--name`,
  a `--via local` run, a `--sudo` run (no prompt with no terminal; asked
  under a pseudo-terminal, `n` runs nothing), `--dry-run`, and every
  refusal (exit 2); every WHAT TO DO NEXT command parses. `TIMES` gives it
  90 seconds (530 here under load, scaled as diff and help scale).
- Merged after QD-040's regrouped `qd --help` card: `again` shares the
  Over time line with `diff`, and is on the start card under Getting
  started, as QD-058's note above `START` asks.

## 0.39.0 — 2026-11-19

`qd ask [HOSTS] -- CMD` runs CMD on every host, files the run as `qd run`
does, and prints who agrees and who differs: `qd run`, then `qd freq
latest A`, in one step (QD-059, from the beginner design QD-057).

### Added
- **`qd ask`**: the run is `qd run`'s own (`start_run()`, the part of
  `cmd_run` before it reports, now shared), so filing, `--store`, `--via`,
  `--sudo`, `--rerun`, `--retries`, `--max-fail`, the safety options and
  every `QD_*` variable behave as in `qd run`; with no hosts named it is
  this machine, by `--via local` (QD-037). It prints the run's summary
  line, then ANSWERS: each distinct answer, most common first, with its
  count and its hosts (past eight, `(+N more)`), counted by `stats.freq`
  as `qd freq` counts; the hosts that answered with nothing, apart (blank
  is not measured); DID NOT ANSWER, each host with its status and why; a
  verdict, ALIKE or NOT ALIKE, naming the step that found something ("1
  host did not answer (the run)", "2 different answers (the count)"); and
  WHAT TO DO NEXT: `qd freq latest A`, `qd show latest`, `qd view latest`,
  and for hosts that did not answer `qd show latest --where status!=ok`
  and `qd run --rerun latest -- ...`. An answer provost read as more than
  one column has no single value to count: it says so and prints `qd
  run`'s summary instead. Exit 0 when every host answered alike, 1 when a
  host did not answer or the answers differ, 2 on a usage error. One pass,
  always kept: no `--every`, `--count` or `--no-store` (`qd run` has them).
  (`quarterdeck/cli.py`: `cmd_ask`, `ask_answer_lines`, `ask_next_steps`,
  the `ask` verb in `build_parser()`.)
- **`qd --help`** lists `qd ask` under Run, and `qd hints`' "What does
  every host say about X?" now suggests it. Bare `qd`'s start card shows
  `qd ask -- uname -r` in place of the `qd run` stand-in (QD-058). README:
  *Who agrees, who differs: `qd ask`*, a line in *Thirty seconds*, the
  `qd --help` heading table and the exit-status table;
  `docs/getting-started.md`'s map of every command names it (under Run).

### Changed
- `report_run()`'s summary line and its DID NOT ANSWER block are now
  `run_head_lines()` and `did_not_answer_lines()`, which `qd ask` shares;
  `qd run`'s output is unchanged. "nothing to run" names the verb typed
  (`qd ask ... -- uptime` from `qd ask`).

### Tests
- **`tests/test_ask.sh`** (new, in `TIMES`): every host agreeing (0); two
  answers, most common first, with counts and hosts (1, "the count"); a
  host unreachable and a failed command, listed with status and reason
  (1, "the run"); both at once; a three-column answer falling back to `qd
  run`'s summary; hosts that printed nothing; a long host list cut short;
  its run compared with `qd run`'s for the same command and hosts through
  `qd log`, the rows, `qd.runs` and `qd.hosts`; no hosts named (this
  machine, no ssh); `qd run`'s host options (`--first`, `--name`,
  `--dry-run`, `--limit`, `--rerun`, `--retries`, `--max-fail`, `--sudo`);
  usage errors (2); the card and the hints. Every WHAT TO DO NEXT command
  is parsed by `build_parser()`.
- Merged after QD-040's regrouped `qd --help` card: `ask` has its own
  line under Run, and on the start card `qd ask -- uname -r` takes the
  place of `qd run -- uname -r`, as QD-058's note above `START` asks.
  `tests/test_help.sh`'s not-a-verb case names `qd poll` now.

## 0.38.0 — 2026-11-19

`qd odd [RUN]`: the hosts unlike the rest, in any column, ranked -- every
column's outliers at once, for when you do not know which column to ask
about (QD-062, from the beginner design QD-057).

### Added
- **`qd odd [RUN]`** (default: latest) runs the outlier checks `qd
  outliers` already has over every column of RUN: numbers by the median
  and MAD (`stats.outliers`, or `stats.peer_outliers` with `--peers`),
  words by the value most of the rack or peer group has
  (`differs.find`, as `--categorical` groups them). Nothing is
  recomputed: it calls that code a column at a time. Each host that
  stands out is listed with the column, its value and the typical one.
- **Two ranked lists**, not one: numbers by robust z (MAD 0: the column
  fewer hosts differ in first), words by rarity, the share of the
  host's group that says something else. A robust z has no ceiling and a
  rarity is a share, so one scale for both would mislead. `--top N` (20)
  limits each list; `--format` gives one table of both (`list, group,
  host, column, value, typical, score, agree`).
- What it reads: in a `qd run`, the columns after `capture` (what the
  hosts said, not the host list's attributes or qd's bookkeeping); in a
  file, every column. Per-host identities, uptime and times are left out
  and named. A column every host agrees in, and one fewer than half the
  rows measured, is not checked: blank is not measured, never zero. A
  host that did not answer the run is named apart, not called odd; a
  column split with no majority is named, with no odd one.
- `--peers NAME` holds each host against its own peer group, as `qd
  outliers --peers` does; `--z` (`QD_Z`, 3.5) and `--where` as there.
- WHAT TO DO NEXT gives the `qd outliers` command for the top column of
  each list (two at most), with the same `--peers`, `--z`, `--where` and
  `--store`, and `qd show RUN --where host=H --vertical` for the first
  host named; `qd stats RUN` when nothing stands out.
- Exit status: 0 when nothing stands out, 1 when a host does, 2 on a
  usage error. Read-only: it files nothing.
- On the `qd --help` card's usage lines, in `qd hints` ("Who is odd, and
  in what?"), in the README ("Who is odd: `qd odd`", under Reading
  it back; a line in Thirty seconds and the exit status table), and in
  the map of docs/getting-started.md (its test wants every verb there).

### Changed
- `quarterdeck/cli.py`: `report_categorical`'s grouping (peer group, else
  rack, else the whole fleet) is now `categorical_groups()`, shared with
  `qd odd`; `qd outliers --categorical` is unchanged.

### Tests
- **`tests/test_odd.sh`** (new, in `TIMES`): the demo's planted slow host
  (`demo-iperf`, robust z −225.8) and odd kernel (`demo-kernel`, 92%)
  each ranked first, from the demo's own answers through its stand-in
  launcher; a run where every host agrees exits 0; a blank is neither a
  zero nor a word of its own, and a mostly blank column is not checked;
  `--top` per list and `--format json`; `--peers`, beside the plain `qd
  outliers --peers`; a filed `qd run` on fake hosts, where qd's own
  columns are not read and the host that did not answer is named apart;
  usage errors exit 2; the card, `qd hints` and `qd help odd`. Every
  WHAT TO DO NEXT command is parsed by `build_parser()` and then run.
- Merged after QD-040's regrouped `qd --help` card: `odd` leads the
  Read it back line with `pivot` and `trend`, and on the start card under
  Getting started, as QD-058's note above `START` asks.

## 0.37.0 — 2026-11-19

`qd coverage`: which hosts each named test has run on, how it went, and
a host list of the ones that still owe it (QD-053).

### Added
- **`qd coverage [NAME...] [HOSTS]`** (`quarterdeck/coverage.py`, new,
  and `cmd_coverage` in `quarterdeck/cli.py`). A row per host of the list
  (`-s`, `-S`, `--layout`, `QD_SERVERS`, a `hosts.txt`; none is an error,
  not this machine), a column per name (a run's `--name`, a probe's, a
  campaign's), each cell the host's latest status in a run of that name
  and the run it came from: `ok`, `failed`/`timeout`/`push-failed`
  (counted as failed), `unreachable`, or `never`. Latest is by when the
  run started, then the order filed, never by id; a host's last pass and
  try count; a `not-run` row is not an answer. The head counts each name's
  ok, failed, unreachable and never. Read from `qd.runs` and `qd.hosts`
  alone.
- **A host the runs saw that the list does not hold** is listed under the
  grid, and not counted.
- **With no NAME**, the eight names run most recently, newest first, and
  how many more there are; `--all` for every one.
- **`--since DATE|RUN`**: a run that started before a date
  (`YYYY-MM-DD`, UTC) or a run (`latest~3`, an id, a name) is not read,
  so an old ok is never.
- **`--owed DIR`** writes `DIR/NAME.txt` per name: the hosts that owe it
  (never, or not ok), with the list's attributes, a host list `qd run -s`
  reads back. A name nothing is owed for gets a file with no hosts in it.
- **`--format csv|tsv|json|ndjson|md`**: `host, name, status, counted,
  owed, run, when, listed`, a row per host and name.
- **Exit status** 1 when a listed host owes a name shown, 0 when none
  does, 2 for usage. A name the store has no run of is every host never,
  said on stderr; a name with no runs on the fleet (`qd do`, `qd
  import`), and an empty store with no NAME, are exit 2.
- The `qd --help` card has its line, `qd hints` a hint, and README a
  section, "Which hosts have had it: `qd coverage`"; the exit-status
  table and card name it.

### Tests
- **`tests/test_coverage.sh`** (new, in `TIMES`): three named runs over
  overlapping hosts, some failed and one unreachable, with a host off the
  list: the grid, the counts, the CSV and JSON and the exit status; a list
  owing nothing is exit 0; no NAME is every name, newest first; the owed
  list written, run with `qd run -s` on the stand-in ssh, and nothing
  owed after; `--since` a run and a date; a name the store lacks, an empty
  store, no host list, a name not on the fleet.

## 0.36.1 — 2026-11-19

A Concepts page: the words and run references every qd command assumes,
in one place, checked against qd itself (QD-042).

### Added
- **`docs/concepts.md`** (new): run, pass, table (`data`, `hosts`), row,
  capture, dataset and column, with provost's `A`, `B`, ... for a field
  it found no name for (linked to provost's rule, not restated); the
  store, the active, a named and a remote store; blank; how to name a
  run; peer group, baseline, campaign, requirement, waiver and
  telemetry; and exit status 0, 1 (a finding) and 2. A sentence or two
  and one example each, and a link to the manual's section. A small
  plain-text picture (60 columns) of run, hosts, captures, rows and
  dataset. The sdist ships it (`MANIFEST.in`).

### Changed
- **The run-reference table moved** from README's "Named stores" to the
  page's "Naming a run", with an example each against the demo store and
  the forms the table had left out (`last`, `~N`, `prev~N`, a bare
  dataset name). "Named stores" links to it and keeps `@STORE`'s details.
- **README:** the front matter links the page, and the first `qd freq
  latest A` is followed by what `A` is.
- **`docs/getting-started.md`:** "Four words" links the page.
- **`qd --help`:** the RUN paragraph ends with a pointer to
  `docs/concepts.md`.

### Tests
- **`tests/test_concepts.sh`** (new suite, in `TIMES`) with
  **`tests/concepts_unit.py`**: every `qd` command on the page parses
  with `build_parser()`; every reference form `quarterdeck/store.py`
  resolves (read from `Store.resolve()`'s pattern, prefixes and returns,
  `split_ref()`, `split_store()` and `load_ref()`) is in the page's
  table, and nothing the resolver does not take; the page's links, and
  the links to it from README.md and docs/, land (files and anchors;
  provost's docs too where `QD_PROVOST` is a clone); and README,
  the walkthrough and `qd --help` point at it. Each check is also run on
  a broken copy.
- **`tests/test_demo.sh`**: the walkthrough case runs every "Naming a
  run" example against the demo store, each exiting 0 as the page says.

## 0.36.0 — 2026-11-19

`qd check --manual FILE` records a person's pass or fail for a
requirement nothing measures, with who decided, when and why, in the same
verdict table, JUnit and `--keep` record as the measured ones (QD-052).

### Added
- **`op manual`** in the thresholds file: a requirement a person decides
  (the cabling inspected, the labels right). `column` may be blank;
  `limit`, `limit2`, `unit` and `agg` must be (refused with exit 2
  otherwise). Without a result it is **not measured**, so the run exits
  1 (`quarterdeck/check.py`).
- **`--manual FILE`** (`QD_MANUAL`) on `qd check`: a TSV or CSV of `req`,
  `verdict` (pass or fail), `by` [`date`, `where`, `note`]. A result
  covers the rows its `where` picks (one bare word is a host), or every
  row of the check; when results disagree on a row the fail stands; a
  row no result covers is not measured. Folded in before waivers, so a
  waiver excuses a manual fail and `expect fail` makes a manual pass an
  unexpected pass; `--rule`, `--each`, severities and every format take
  it as any verdict (`quarterdeck/check.py`, `quarterdeck/cli.py`).
- **Refused with exit 2, naming the line**: a `req` no check has, or one
  whose check is measured; a verdict other than pass or fail; a blank
  `req`, `verdict` or `by`; a date qd cannot read (YYYY-MM-DD, or with a
  time); a `where` it cannot parse.
- With `--manual`, the verdict table gains `decided_by`, `decided` and
  `decision_note`, and the head counts the results, who gave them, the
  undated ones and those **dated before the run**. A result older than
  the run is warned of in its check's note, not refused: an inspection
  is often made the day before.
- **JUnit**: a manual testcase carries `by` and `date` as properties; a
  manual fail is `<failure type="manual">` naming who decided and when;
  the suite names the manual file with its sha256
  (`quarterdeck/exporters.py`). A testcase of a check with no column is
  named by its limit alone.
- **`--keep`** files the manual columns, names `--manual` in the run's
  command, and adds a note of the file's name and sha256 (`qd log`).
- README "A person's results: `--manual`", beside "Waivers"; a `--help`
  line; `tests/test_check.sh` (seven cases).

### Unchanged
- Without `--manual` and without a manual row, every format's output is
  what 0.35.0 gave (checked byte for byte against 0.35.0 for text, csv,
  json, junit and md, with and without `--each`, waivers and `--rule`).
- `qd report --check` does not take `--manual`: a manual check there is
  not measured.

## 0.35.0 — 2026-11-19

`qd check --rule` gives one overall verdict built from the requirements:
all, any, not, at least N of, and a weighted score against a threshold
(QD-051).

### Added
- **`--rule RULE`** (`QD_RULE`) on `qd check`: a small prefix grammar,
  `all(..)`, `any(..)`, `not(..)`, `atleast(N, ..)` and `weighted(T,
  ..)`, over `req`s and globs of them (`SYS-2*`), nested as deep as
  wanted; `weighted` takes requirements and globs only. With a rule, the
  exit status is 0 when the overall verdict passes and 1 when it fails or
  is not measured; a requirement the rule does not name counts for
  nothing, and the head says which. The verdicts of the checks are not
  changed (`quarterdeck/rule.py`, new).
- **Three-valued, so blank is never a pass**: a requirement is pass,
  fail or not measured (its checks taken together); a call is not
  measured when the unmeasured could still decide it, and `not` of not
  measured is not measured. A waived check counts as a pass, an
  unexpected pass as a fail, a failure below `--fail-level` as a pass.
- **A `weight` column** in the thresholds file for `weighted()`: a
  number 0 or more, once per requirement (two different weights for one
  are refused with exit 2); blank is 1 (`quarterdeck/check.py`).
- **The overall verdict in every format**: the head line gives it and why
  (`2 of 4 SYS-2* passed, need 3`), with a line per call beneath; CSV,
  TSV, JSON and the rest carry one more row, `req` `(rule)`, the rule as
  its `limit` and the why as its `observed`, and so does what `--keep`
  files, whose command names the rule; JUnit has one more testcase
  (`classname` `rule`) and the suite properties `rule`, `rule.verdict`
  and `rule.why` (`quarterdeck/cli.py`, `quarterdeck/exporters.py`).
  `qd report` does not count that row as a check
  (`quarterdeck/report.py`).
- **A rule qd cannot read is refused with exit 2**, naming what is wrong:
  an unknown `req`, a glob matching nothing (or several where one
  belongs), N outside 1 to the count, a threshold outside 0 to 1, the
  same requirement twice in one list, weights adding up to 0, an unknown
  call, or anything left over.
- README "One verdict from many: `--rule`", with a worked example;
  `qd check --help` names the calls. Five cases in `tests/test_check.sh`.

### Unchanged
- Without `--rule`, output and exit status are what they were.

## 0.34.0 — 2026-11-19

`qd check` can pass or fail on how alike the hosts are: `agg` takes `cv`,
`skew`, `kurtosis` and `zmax` (QD-050).

### Added
- **Four spread and shape aggregates for a thresholds file's `agg`.**
  `cv` is the sample stdev over the mean's size; `skew` the adjusted
  Fisher-Pearson sample skewness (G1, Excel's `SKEW`); `kurtosis` the
  sample excess kurtosis (G2, Excel's `KURT`, 0 for a normal
  distribution); `zmax` the largest robust |z|, 0.6745 (x - median) /
  MAD, worked out by `qd outliers`' own code, so the two agree on the
  worst host and its score, which the note names. `agg zmax`, `op <=
  3.5` reads "no host is an outlier".
- **Not measured, with the reason**, below each one's fewest values (2,
  3, 4 and 3), for a mean of 0 (`cv`), every value the same (`skew`,
  `kurtosis`) and a MAD of 0 (`zmax`).
- **Unitless**: a limit with a unit on one of them is refused with exit
  2, naming the check, and the column's unit does not scale them. A
  percentage tolerance or baseline offset is a share, and is taken.
- **`--baseline` works on them**: a relative limit is held to the same
  figure over the baseline's rows of the same hosts.
- `qd check --help` names every `agg`; README "Against requirements: `qd
  check`" has a "Spread and shape" section with the definitions.

### Changed
- `quarterdeck/stats.py`: `robust_z()` is the one formula `outliers()`
  and `zmax` score by; `shape()` works out the four. In
  `quarterdeck/check.py` the baseline values an aggregate is held to are
  found by one helper, `_baseline_values()`, shared by the old
  aggregates and the new; their output is unchanged.
- Tests: seven cases in `tests/test_check.sh` (hand-worked values on 1,
  2, 3, 4, 100; not measured; units refused; zmax against `qd outliers`;
  a file's old rows unchanged beside new ones; JUnit, waivers, severity,
  `--keep`; `--baseline`).

## 0.33.1 — 2026-11-19

How long a small run takes to file, measured and recorded, and the provost
that files it quickly named (QD-056).

### Changed
- **The README names provost 2.28.0 as the version that files a small run
  quickly.** A one-host `qd run -- ls` spent almost all of its time in
  provost's filing; 2.28.0 reads its strategies' confidence ceilings in one
  scan rather than one process per strategy file, and reads a capture of a
  dataset the store already has (`qd.runs`, `qd.hosts`, a command run
  before) with that dataset's strategy first. qd is unchanged: any provost
  still works, an older one is only slower. Measured on a shared 4-core
  Linux machine, a one-host run into a store that has its datasets went
  from 747 processes to 275, and its `provost batch` took 41% of the time
  (33% with `-j 1`).

### Docs
- **`docs/scale.md` has a "Small runs" section:** a one-host run's time and
  process count before and after, and what changed.

### Tests
- **`tests/small_run.sh`** (new) prints a one-host `qd run -- ls`'s median
  time over 5 runs, with `--no-store`, into a new store and into a store
  that has the run's datasets, and the processes (and `awk` processes) one
  run starts, counted with strace where it is installed. It never fails on
  a time or a count. CI runs it as a report (the **small run** job, which
  cannot fail the run), with PyPI's provost and with provost's `main`.

## 0.33.0 — 2026-11-18

Bare `qd` prints a short start card for newcomers in place of the full
card, which `qd --help` and `qd -h` still print (QD-058).

### Changed
- **Bare `qd`'s output changes**: it prints the start card, 12 lines of
  at most 80 columns (`qd demo`, `qd run -- uname -r`, `qd log`, `qd show
  latest`, `qd web`, and where to go next: `qd --help`, `qd help VERB`,
  `qd hints`), not the 49-line reference card. A script that ran bare
  `qd` for the full card should run `qd --help`; none was found in
  quarterdeck or provost (`quarterdeck/cli.py`: `START`, `main()`).
- The beginner commands QD-057 designed (`setup`, `ask`, `survey`,
  `again`, `odd`) go on the start card as each lands; until `qd ask`
  does, `qd run -- uname -r` stands in for it. A comment above `START`
  says where each goes.

### Added
- **`qd start`** and **`qd help basics`** print the start card and exit 0.
  `start` is on the full card's Help line, in the README's table and in
  docs/getting-started.md's map.
  `qd help stat` now names `stats, start` as the closest verbs.

### Tests
- **`tests/test_help.sh`**: bare `qd` prints the start card in at most 25
  lines of 80 columns, and `qd start` and `qd help basics` print the same;
  `qd --help` and `qd -h` print the full card; every command on the start
  card names a verb `build_parser()` registers and parses
  (`tests/help_unit.py start`), shown failing on a card that names `qd
  ask` before it lands and on a bad flag. `tests/test_run.sh` reads
  "Full manual:" from `qd --help`, no longer from bare `qd`.

## 0.28.1 — 2026-11-18

`qd --help` groups every command by what it is for, everyday ones first,
on one screen, and `qd hints` asks its questions under the same headings
(QD-040).

### Changed
- **`qd --help`, the reference card, is regrouped by goal**: Run, Read it
  back, Over time, Judge and report, Larger jobs, Stores and output, Help,
  in that order, every verb `build_parser()` registers on one line under
  one of them (`hosts` under Run, `demo` under Help). It is 49 lines of at
  most 80 columns (it was 78, some over 80), and its 18 example lines are
  five, the core loop: run, freq, outliers, compare, web. The RUN
  paragraph, the store paragraph and the exit status are shortened to a
  few lines each; `qd demo`, the walkthrough and the "Full manual" link
  stay (`quarterdeck/cli.py`: the module docstring).
- **`qd hints`** prints its questions under the card's headings, in the
  card's order (`cli.GROUPS`; each `HINTS` entry now carries its
  heading), and has three more: keeping one project's runs apart (`qd
  store new`, `qd store use`), into a spreadsheet (`qd export --format
  csv`) and whether this machine can drive the toolchain (`qd doctor`).
- **The README** shows the card's headings and their commands under the
  install lines; **docs/getting-started.md**'s map of every command uses
  the same headings.

### Tests
- **`tests/test_help.sh`**: the card check reads the commands under the
  headings, and fails on a verb on no line, a verb on two lines, headings
  that are not `cli.GROUPS` in order, and a core-loop example that no
  longer parses, each shown on a broken copy; new `qd --help fits a
  screen` (at most 50 lines, none over 80 columns, one to six examples);
  `qd hints prints every hint` checks its headings are the card's, in
  order; the hints check also fails a hint whose heading is not one of
  the card's (`tests/help_unit.py`: `card_parts()`, `groups`).

## 0.26.0 — 2026-11-18

`qd help VERB` prints that verb's help, as `qd VERB --help` does, instead
of an error (QD-044).

### Added
- **`qd help VERB`** prints exactly what `qd VERB --help` prints and exits
  0, for every verb (`campaign` and `doe` included: `main()` cuts only their
  own argument lists at `--`). A global option before VERB is fine (`qd
  help --store x run`). An unknown VERB exits 2 naming the three closest
  verbs (`difflib`, standard library) and pointing to `qd --help`: `qd
  help stat` says `the closest: stats`. Bare `qd help` still prints every
  verb's help (`quarterdeck/cli.py`: `verb_help()`, the help verb's
  optional `VERB`).
- **`qd --help`** shows `help [VERB]` on its last usage line, and the
  README says once, under the install lines, that `qd help VERB` gives one
  verb's flags.

### Tests
- **`tests/test_help.sh`**: `qd help VERB prints qd VERB --help` (every
  verb `build_parser()` registers, through `main()` both ways by
  `tests/help_unit.py verb-help`, and its `cut` mutation to show it fails;
  `run`, `campaign` and `doe` through `qd` itself; a global option before
  VERB; bare `qd help`; the card's line) and `qd help NOSUCH names the
  closest verbs`. `TIMES` gives the help suite 5 seconds.

## 0.25.3 — 2026-11-18

Every README pointer in qd's code names a section the README has, and a
check keeps it so (QD-046).

### Fixed
- **A pointer into the README had gone stale.** `quarterdeck/exporters.py`
  sent readers to "Sending a run to Splunk or Prometheus", a section since
  renamed "Into Splunk, Prometheus or a notebook". It names the section as
  it is now.
- **The five pointers are written one way:** `README: "Section"`, on one
  line. `qd import --map` and `qd join --map` now point at "Telemetry
  exports", the part of `qd join`'s section that explains a column map;
  `qd check --against` at "Against requirements: qd check"; `policy.py` at
  "Allow-lists and read-only", as before.
- **`tests/check.sh --help` left out the last line of its own header.**
  It prints all of it.

### Tests
- **`tests/check_readme_pointers.py`** (new), run by `tests/check.sh` and
  by `tests/test_help.sh`: every `README` in `quarterdeck/*.py`, the page's
  files and `qd` is a pointer of that shape, and names a heading of the
  README (compared without backticks, case or runs of spaces; a `#`
  comment inside an example's code block is not a heading). It is also
  run on a copy with the stale pointer put back, with a heading renamed,
  with a pointer at an example's comment, in the old `(README, "X")`
  style and cut over two lines, so it is shown to fail on each. Its list
  of manual files is one line, for when the manual has more than one.

0.25.1 and 0.25.2 are in the same pull request and are not published on
their own.

## 0.25.2 — 2026-11-18

`qd hints` is tested: it prints every hint, and every command it
suggests still parses (QD-045).

### Tests
- **`qd hints` had no test.** `tests/test_help.sh` now runs it and checks
  that it prints one line a hint, and `tests/help_unit.py hints` takes
  every `qd` command out of `HINTS` (31 of them, in 27 hints) and parses
  each with qd's own parser, as `qd` would: a renamed flag or verb fails
  the suite instead of leaving a hint that no longer works. How a hint is
  read: notes in parentheses are not commands; commands are split at
  `->`, `;` and `or`; `...` and words in capitals stand for values;
  `campaign` and `doe` are cut at `--`, as `main()` cuts them. It is also
  run with a flag and a verb misspelt, so it is shown to fail. Every hint
  parsed as it was: nothing in `qd hints` changed.

0.25.1 is in the same pull request and is not published on its own.

## 0.25.1 — 2026-11-18

`qd --help` lists `qd store`, and a test keeps it listing every command
(QD-043). This pull request first took 0.23.1, which QD-039 and QD-037
reached `main` past first.

### Fixed
- **`qd --help` had no line for `qd store`**, the named stores' commands
  (`new`, `ls`, `use`, `rename`, `rm`, `clear`, `export`, `import`), though
  `qd doctor` and every "no store" message point to `qd store use` and
  `qd store ls`. It is listed now, after `qd rm`.

### Tests
- A new suite, `tests/test_help.sh`, with `tests/help_unit.py` beside it:
  every verb the parser registers has a usage line on `qd --help`. It is
  also run on cards with a line taken out (`store`, a verb run together
  with others, a verb after a spaced `|`, and `run`, which campaign's and
  doe's own `run` must not stand in for), so it is shown to fail.

## 0.25.0 — 2026-11-18

A command given no hosts runs on this machine (QD-037). This pull
request first took 0.23.0, then 0.24.0, which QD-038 and QD-039 reached
`main` with first.

### Added
- **No hosts named: this machine.** With no `-s`, `-S`, `--layout` or
  `--rerun`, no `QD_SERVERS` and no `hosts.txt` or `servers.txt` in the
  directory, `qd run`, `qd probe`, `qd doe run` and `qd hosts` run on
  this machine: one host, named as its hostname is up to the first dot,
  at 127.0.0.1, reached without ssh. qd says so once on stderr. Before,
  they stopped with "no hosts given". `qd split` and `qd campaign new`
  still do, and `--sudo` is refused on that host unless it is named
  (`-S localhost`, or `--via local`). Everything that names hosts wins
  as before, `--via srun`'s allocation included, and a `--via` or
  `QD_VIA` given reaches the host by that launcher at 127.0.0.1.
- **`--via local`** (`QD_VIA=local`): this machine without ssh, `sh -c
  CMD` in a session of its own as sshd would start it. Pushed files go
  by `cp` into the run's own directory, removed afterwards as over ssh;
  stdin, `--timeout` and `--max-output` (the command stopped with all it
  started), `--every`, `--retries` and the allow-list behave as over
  ssh, and Ctrl-C (or a TERM or HUP to qd) stops the command as well. A
  host list naming any other host, a port, or this machine twice is
  refused before anything runs; `--user` is warned about and not used.
  The run's `via` is `local`, and `--rerun` of such a run stays local.
- `qd doctor` says where a command run in this directory would get its
  hosts (`--via srun`'s allocation, `QD_SERVERS`, `hosts.txt` or
  `servers.txt`, or this machine), and checks `--via local`.

### Changed
- `--via`'s default is no longer written as `ssh`: not given, it is ssh
  for hosts that are named and local for this machine when none are.

## 0.24.0 — 2026-11-17

`qd demo`, and a ten-minute walkthrough on it, so qd can be learned with
no fleet (QD-039).

### Added
- **`qd demo`** files a store named `demo`: 24 made-up hosts
  (`demo-r1n01` to `demo-r2n12`, two racks, two SKUs) asked three things
  over a week, why-slow's readings every morning (`demo-facts`), `uname
  -r` (`demo-kernel`) and a throughput test (`demo-iperf`), with a host
  that did not answer, a kernel that disagrees, a host whose free memory
  slides day by day and a slow host planted for the read side to find.
  Nothing runs and nothing needs ssh, a network or a host list: the
  answers ship with qd as text (`quarterdeck/demo/`), and a stand-in
  launcher plays them back through the same code as `qd run`, provost
  filing every answer, so `provost store check` passes on the store and
  every command reads it. The stand-in is no `--via` choice, and nothing
  but `qd demo` reaches it. Each run is filed as having started at its
  time in the week (UTC), so its run id is the same on every machine.
  `qd demo` leaves the active store and `~/.provost` alone; run again, it
  shows the demo it filed; `--rebuild` files it afresh; a store named
  `demo` that is not qd's is never touched; a demo stopped part-way
  leaves nothing behind. `qd demo --limits` prints its requirements, a
  CSV for `qd check --against`.
- **[Getting started](docs/getting-started.md)**, linked from the top of
  the README and from "Thirty seconds": the core loop on the demo, one
  question a step (who runs which kernel, who did not answer, who is far
  from the rest, did it get worse, when did it start, does it meet spec),
  each with the command and what it prints; four words (run, capture,
  dataset, store) and how a command names a run; the move to a real fleet
  (a host list, key-based ssh, `qd doctor`, a store of its own, `qd run`);
  and a map of every command by what it is for.
- `tests/test_demo.sh` runs every command on that page, on a fresh home
  with no ssh on `PATH`, and fails when one prints anything but what the
  page shows (`tests/walkthrough.py`; `QD_WALKTHROUGH_UPDATE=1` writes the
  output back after a change meant to alter it), and checks the findings
  the demo was built for, the stand-in's reach, and the package data.
- `qd --help` and `qd hints` name `qd demo` and the walkthrough, and `qd
  doctor`'s WHAT TO DO NEXT suggests `qd demo` when the store has no runs.
- The CI wheel job and `tests/check.sh` install the wheel and run `qd
  demo` from it, which proves the answers are package data.

### Fixed
- **`qd diff`, `qd compare`, `qd changes` and `qd check --baseline` no
  longer match rows on a column they only guessed by its first letters.**
  The key a table's rows are matched on is `host` and the columns that
  repeat within a host (`n`, provost's record number, among them); each was
  looked for as a column name could be typed, a unique prefix included, so
  in a table whose only column starting with `n` was `net.tcp_retrans_pct`,
  that measurement became part of the key and every host came out gone
  and new. A key column is now found by its name alone.

## 0.23.0 — 2026-11-17

What a host's login shell prints before the command is cut from its
answer (QD-038).

### Changed
- **A greeting from `~/.bashrc` is no longer filed as the answer.** sshd
  runs a command through the login shell, which reads its startup files
  first; a greeting, a maintenance notice or a `setlocale` warning they
  printed came back with the answer, so a table was filed as lines, JSON
  as text, and the warning became the host's `error`, under an `ok` run.
  Every command now goes out after a start line on stdout and stderr,
  written by `sh -c` just before the command runs, and what came before
  it is cut: never filed, never the `error` column. The same through
  `--via srun`, `pdsh` and `clush`, and for qd's own calls on a host
  (`--push`/`--script`'s mkdir, copy, chmod and cleanup, and the stop),
  so a failed push's row says the push's own error. With no start line,
  or past 64 KiB before it, nothing is cut. A host whose shell prints
  nothing gives the same answer, row and exit status as before. ssh's
  line naming the command's process group (QD-026) is the start line on
  stderr, now with a newline of its own ahead of it, so it is found after
  a greeting that did not end its line.

### Added
- **`qd.hosts`' `preamble` column**: what the login shell printed before
  the command, stdout's then stderr's, up to 16 KiB (blank for a run
  filed before 0.23.0). `qd show RUN:hosts` shows it when any host has
  one, and `qd web` and `qd view` beside a row's raw answer. A host
  attribute named `preamble` is carried as `attr_preamble`, as one named
  `stderr` or `error` is.
- The run says once on stderr which hosts' shells printed before the
  command, and where to see it; a run where none did says nothing new.
- **`--keep-preamble`** (`QD_KEEP_PREAMBLE=1`): no start line, and the
  answer as it came, as before 0.23.0.
- `FAKE_SSH_RC` in the suites' fake ssh and launchers, a host's
  `~/.bashrc`; `tests/test_preamble.sh`; and in `tests/test_ssh.sh`, a
  real sshd and bash reading a `~/.bashrc` that greets, warns and runs
  `stty`.

## 0.22.0 — 2026-11-17

Two whole campaigns side by side (QD-036).

### Added
- **`qd compare --campaigns A B`**: every part of each campaign (or
  design), the latest run of each part, stacked and matched key by key
  (host, or test and target), with each numeric column's value in A, in
  B and the change, as `qd compare` reduces and measures it. Changes past
  `--drift`, hosts in only one campaign, and values measured on one side
  only are flagged; tests and numeric columns found in only one are
  listed. `-c`, `--key`, `--agg`, `--where`, `--table` and every format
  apply. Exit 1 when anything moved or is in only one; 0 when they agree.

## 0.21.0 — 2026-11-17

A campaign's duration and windows, estimated before it starts, and a
power budget in watts (QD-035).

### Added
- **`qd campaign estimate NAME`**: the wall time (with a p10-p90
  spread), the windows it needs and when each closes, any part that
  overruns its window, and the most hosts (and watts) running at once
  per capped attribute. Each host's duration is the median of its own
  earlier runs of the command, else the fleet's, else `--assume
  SECONDS`, and the source is named. A part with none is unknown, never
  zero (exit 1). The parts go through the scheduler `campaign run` uses
  (`pacing.Gate`), with `--jobs` and `--workers N`, and caps per worker.
  `--start` sets the start time, and `--json` gives the figures as
  JSON. `campaign run --dry-run` prints the same summary first.
- **A power budget**: `--max-watts [ATTR=]W` on `campaign new` and
  `run` caps the watts drawn at once per ATTR value (`pdu=7200`) or in
  all (`30000`). A host's draw is its `watts` attribute, else `--watts
  W`. A host with an unknown draw, or one bigger than its budget, is
  refused before anything starts. The budget is kept with the campaign
  and enforced by the same gate as `--max-per`.

## 0.20.0 — 2026-11-17

A firmware probe, and the host that differs from its rack-mates by value
(QD-034): the fleet drift checker, inside qd.

### Added
- **`qd probe firmware`** (in `inventory`): BIOS, board and product
  strings from `/sys/class/dmi/id`, CPU microcode from `/proc/cpuinfo`,
  and per NIC its MTU and ethtool's driver, driver and firmware versions,
  offloads (`-k`), rings (`-g`), coalescing (`-c`) and pause (`-a`), one
  row per NIC, without root. Every `key: value` line ethtool prints is
  kept. A file only root can read says `needs root`, a host with no DMI
  says `dmi: absent`, and a host without ethtool says `ethtool: not
  installed` and still files the rest. Serials, UUIDs and MACs are never
  read.
- **`qd outliers RUN [COLS] --categorical`**: within each rack (or `--peers`
  group), each column's majority value and every host that differs from
  it; a group with no majority is split, never two outliers; NIC compared
  with NIC (`--match`), host-wide values once a host; blanks not counted;
  per-host identities left out unless named. Exit 1 when a host differs
  or a column splits.

### Changed
- `qd outliers`' column is optional with `--categorical`; without it a
  column is still required, as before.
## 0.19.0 — 2026-11-17

`qd check` judges a run against an earlier run, not only against fixed
limits (QD-033): the regression watcher, inside the gate.

### Added
- **`qd check --baseline RUN|NAME`**: a thresholds row can give its
  limit relative to the baseline -- `baseline-5%`, `baseline+2`,
  `baseline+40us`, `within baseline +-5%`, either side of `between` --
  held to an earlier run (or a file) or a qualified baseline from `qd
  baseline set`. Under `each` every host is held to its own value in the
  baseline; an aggregate is taken over the same hosts through the same
  `where`. A host or column the baseline lacks is not measured, never a
  pass, and so is a relative limit with no `--baseline`.
- Against a qualified baseline of three runs or more, with three values
  or more for a host in the run, a crossed limit fails only when the
  Mann-Whitney U test (Holm-adjusted, as `qd compare --baseline NAME`
  makes it) finds the change significant; otherwise the medians decide,
  and the note says which.
- The verdict table gains `baseline` and `drift_pct` with `--baseline`;
  waivers, severities, `--fail-level`, `--keep`, junit and every format
  treat a relative verdict as they treat a fixed one. A thresholds file
  with no relative limit reads and reports as it did.

## 0.18.1 — 2026-11-11

A remote store made in git's SHA-256 object format is read (QD-032,
following provost's PV-027).

### Fixed
- **A remote SHA-256 store reads.** A copy was made with `git init`, in
  SHA-1, and git refused the fetch from a store made by `provost init
  --object-format sha256` ("mismatched algorithms"). A copy now takes the
  store's object format, and refreshes in place as a SHA-1 store's does.
- **A store remade in the other object format gets a new copy**, said on
  stderr ("is now in git's SHA-256 object format and its copy here was
  SHA-1: making the copy again"), and the old copy is kept until the new
  one is in place. A SHA-1 store's existing copy is refreshed where it is,
  as before.
- **`why_not()` says a mismatch in words**: the store's format, the
  copy's, and that the copy has to be made again; and where this git is
  older than 2.29, which cannot keep a SHA-256 store, a failed copy says
  so.

### Tests
- `tests/test_remote.sh`: a SHA-256 store made by `provost init
  --object-format sha256`, read and refreshed; a SHA-1 store remade
  SHA-256; the mismatch and an old git explained. The SHA-256 cases skip
  where git is older than 2.29 or provost's `init` has no
  `--object-format`, and are required in CI's store-check job
  (`QD_TEST_SHA256=require`).

### Known
- A remote store's copy holds what is in the store's git and nothing
  else, so the inputs provost keeps beside it for truncated captures
  (QD-031) are never in it.

## 0.18.0 — 2026-11-11

qd's reading of provost's store brought in line with provost's store
format spec (its `docs/store-format.md`, PV-022), checked against provost
2.19.0 (QD-031).

### Changed
- **A live store of a format qd does not know is refused**, as an archive
  of one already was: `.store_format` above 4 stops every read with "is a
  store in format N; this qd reads formats 1, 2, 3, 4". The formats and
  how a store's is read now live in `quarterdeck/store.py`, for the live
  store and the archive alike.
- **Below format 4 a row's capture comes from `provenance.tsv`**, not from
  column 2: in a format-3 store a reconcile could leave a data value there
  (provost's PV-015). `qd show ds:NAME` and qd's own tables read it so.
- **A quoted `#%` value reads as provost reads it**: `cc="gcc 13.2"` is
  one value, with `\"` and `\\` inside, a tab in it a space, and an
  unterminated quote an ordinary word (a port of provost's
  `_prologue_kv`). qd read `cc="gcc` before.
- **`meta.tsv` values are unescaped**: provost writes a tab in a value as
  `\t` and a newline as `\n`; qd now turns them back.

### Fixed
- **A `QD_OPERATOR` with a tab or a line break no longer stops filing**
  under provost 2.18.0 and later, which refuses a control character in
  `PROVOST_OPERATOR` (its `Operator:` trailer, PV-027). provost is given
  each run of control characters as a space, cut to 512 bytes; qd's own
  `qd.runs` row keeps the text as given. The new store-check job found it.

### Added
- **Truncated captures** (provost 2.15.0 on: an input over
  `PROVOST_MAX_INPUT` is parsed from its head, and kept whole outside git
  by its sha256). A raw answer from one is labelled *truncated*, with how
  many bytes were parsed of how many, and where the whole input is kept
  -- at `raw_artifact`, or, when that is gone, by `raw_sha256` in
  `PROVOST_ARTIFACT_DIR` or `STORE.artifacts` -- or, in words, that it is
  not there or no longer hashes right. `qd split` compares hosts by the
  whole input where it is kept.
- **`qd store export` carries the kept inputs** under `artifacts/` (an
  archive with any is version 2; one with none stays version 1, readable
  by an older qd), and `qd store import` checks each against its sha256
  and puts it beside the new store, as `NAME.artifacts`. An export whose
  truncated capture has lost its kept input says so. provost's own
  `export` leaves them out; its `archive` carries them, as this does.

### Tests
- `tests/test_store.sh`: quoted prologue values, checked against
  provost's own `_prologue_kv` where the provost under test is its script;
  a format-3 store's captures from `provenance.tsv` and a format-4
  store's by place; a store in format 9 refused by `show`, `log` and
  `store export`; escaped `meta.tsv` values; a truncated capture made by
  hand (its label, its kept input found where it was and after the store
  moved, carried by an export and put beside an import, a changed one
  refused); and, with a provost that has `store check`, a real one filed
  under `PROVOST_MAX_INPUT=600`.
- `QD_STORE_CHECK=1` (or `require`) in `tests/test_helper.bash` runs
  `provost store check` on every store a passing case leaves, and fails
  the case on what it finds; `no_store_check DIR` leaves out a store a
  case made by hand. `tests/check.sh` sets it for the batch run.
- CI: a new **store check** job runs the whole suite, in three shares,
  with provost 2.19.0 fetched from its repository by commit (PyPI's
  newest is 2.3.0, which has no `store check`) and
  `QD_STORE_CHECK=require`.

## 0.17.0 — 2026-11-11

`qd changes` finds where in a series of runs each host's level moved, so a
slow slide shows before any limit is crossed (QD-030).

### Added
- **`qd changes RUN... | --last N | --group NAME -c COL [--peers NAME]`**:
  each host's (or peer group's) value per run, reduced as `compare`
  reduces one, then **e-divisive means with a permutation test**
  (Matteson and James 2014; MongoDB's `signal-processing-algorithms`
  2.1.6, ported to the standard library in `quarterdeck/changes.py`;
  `--p 0.05`, `--permutations 100`, a fixed seed, so the answer repeats).
  It reports each change between stable stretches by the run ids either
  side, in percent and in MADs; each stretch's median, MAD and count
  (`--format csv`, `json`); asv's best-to-latest gap with the steps that
  explain it, so small steps that add up are reported; a run that jumps
  and comes straight back as an outlier, not a step; the runs a host was
  not measured in, left out of its series; and "too few runs" under five.
  `--min-change PCT` (1, `QD_MIN_CHANGE`) is the floor for a step;
  `--higher-is-better` / `--lower-is-better` call a step a regression or
  an improvement. Exit status 1 on a change (with a direction, a
  regression) or a slide.

### Tests
- `tests/test_changes.sh`, a new suite: the statistic against the values
  `signal-processing-algorithms`' own tests assert, and against every
  ordered pair written out; a known step found at its run over 40 seeds;
  no step, a false-positive rate near p over 300 seeds, with which seeds
  pinned (the same on every Python); a single outlier never a change; a
  slide of steps under the floor; blanks; a 100-run series under a
  second; and runs in a store: a step at run 7, a host measured in three
  runs, an outlier, a missed run, a peer group, CSV, JSON, the floor.

## 0.16.0 — 2026-11-11

`qd check` writes its verdicts as JUnit XML, and `qd report` adds them to
the package (QD-029).

### Added
- **`qd check --format junit`**: one `<testsuite>` per run (named by the
  run's id, timestamped with its start, with the operator, the store and
  the thresholds and waivers files' sha256 as properties) and one
  `<testcase>` per check, `classname` the `req`, `name` the column and
  its limit; with `--each`, one per host per check. A fail is a
  `<failure>` with the value observed and the limit; an unexpected pass is
  a `<failure>` too; **not measured is an `<error>`**, never a pass; a
  waived check is `<skipped message="waived: justification (expires
  ...)">`. The suite's `tests`, `failures`, `errors` and `skipped` are the
  head line's counts. Every string is escaped and the characters XML 1.0
  refuses are dropped. Standard library only.
- **`qd report`** writes `data/RUN/check.junit.xml` beside `check.csv`
  and `check.json` whenever there are checks (against `--check`, or the
  verdicts `qd check --keep` filed), listed in `manifest.json` and in
  `SHA256SUMS`.

### Tests
- `tests/test_check.sh`: the XML parsed with Python's `xml.etree` and its
  counts compared with `--format csv`'s; a testcase per outcome; `--each`;
  `<`, `&`, `]]>`, control characters and non-ASCII in the data, the
  thresholds and the waivers; and provost (2.5.0 and later) reading the
  file back as a row per testcase.
- `tests/test_report.sh`: `check.junit.xml` is `qd check --format junit`'s,
  in the manifest, and passes `sha256sum -c`.

## 0.15.0 — 2026-11-11

Waivers with a justification and an expiry, severity with a fail level,
and a tolerance form for `qd check` (QD-028).

### Added
- **`qd check --waivers FILE`** (`QD_WAIVERS`): a TSV or CSV of `req`,
  `justification`, and optionally `expires` (YYYY-MM-DD), `where`,
  `expect` and `granted_by`. A measured failure under a waiver in force is
  **waived**, and does not fail the run; under `each` only the rows the
  waiver's `where` picks. A pass stays a pass, or is an **unexpected
  pass** under `expect fail`, which fails the run. An expired waiver does
  nothing, and the table says it expired. **Not measured is never
  waived.** A waiver for a `req` no check has is refused with exit 2.
- **A `severity` column** in the thresholds file (`critical`, `high`,
  `medium`, `low`, `info`, or an InSpec impact 0.0-1.0), and **`--fail-level
  LEVEL`** (`QD_FAIL_LEVEL`, `info`): exit 1 only for a failure at or above
  the level. A check with no severity, and not measured, always count.
- **`op within`**: `limit` is the reference and `limit2` the tolerance,
  `+-10%`, `-5%,+10%` or an absolute `+-3`, scaled by unit as every op is,
  and shown as `within 50 (-10%, +10%)`.
- The verdict table, `--each`, `--format csv` and `json`, and `--keep`
  carry `severity` (when the file has it) and `justification`, `expires`
  and `granted_by` (with `--waivers`). Without either, the output is
  byte for byte what 0.14.0 printed.
- **`qd report --waivers FILE`** (with `--check`): copied into `inputs/`
  and hashed; a **Waivers** section lists the waivers given and every
  verdict a waiver touched (`data/waivers.csv`), and the counts and the
  manifest give waived apart from passed. Kept verdicts made under
  waivers are shown the same way.

## 0.14.0 — 2026-11-11

Stop a fan-out when too many hosts fail, rerun only the hosts that
failed, try a flaky host again, and keep what answered when interrupted
(QD-027).

### Added
- **`--max-fail N|P%`** (`QD_MAX_FAIL`) on `qd run`, `qd probe`, `qd
  campaign` and `qd doe`: once more than N hosts, or P% of those started
  (judged from three on), are not ok, no new host starts; the running ones
  finish, every host not started is a row with the new status
  **`not-run`**, the summary and `qd log` say why it stopped, and the run
  exits 1. **`--max-fail-on unreachable`** (`QD_MAX_FAIL_ON`) counts only
  unreachable, timeout and push-failed. The stop is asked before every host
  in both fan-out loops (`fleet.fan_out`, `pacing.gated_fan_out`), above
  the launcher.
- **`--rerun RUN`** (repeatable): the host list is the hosts whose last
  pass in RUN was not ok (`not-run` included), with their addresses and
  attributes. The new run's `qd.runs` row carries `rerun_of`, `qd log`
  shows it, and `qd diff NEW` compares with that run. `qd hosts --rerun
  RUN` lists them. `qd campaign run` refuses it (`qd campaign retry` is
  part by part).
- **`--retries N`** (`QD_RETRIES`, 0), **`--retry-delay S`**
  (`QD_RETRY_DELAY`, 0) and **`--retry-failed`**: an unreachable or
  timed-out host is tried again in the same run; every try is a row with an
  `attempt` column (`qd.hosts` has it too), and the run's note names the
  hosts tried again. A command's non-zero exit is not retried without
  `--retry-failed`; a host where the command may still be running (QD-026)
  is never retried.
- `--dry-run` prints the plan for these (`qd: plan: ...`, on stderr).
- `qd.runs` has a `not_run` count; `not-run` reads as not measured in
  `qd stats`, `qd compare`, `qd check` and `qd report`, and as a warning
  on the floor plan.

### Changed
- **Ctrl-C keeps what answered.** The pass it comes in is filed as far as
  it got, the hosts that had not answered as `not-run` rows; before, a
  one-pass run kept nothing and a run of passes dropped the one in
  progress. Through pdsh or clush every host of that pass is `not-run`.
- A host list read from a file or `-s -` whose first line is a `host`
  header is read as CSV or TSV: `qd show ... --cols host --format csv |
  qd run -s - ...` no longer tries a host called `host`.
- With `--max-fail` or `--retries`, pdsh and clush go host by host.

## 0.13.0 — 2026-11-11

Hosts reached through a Slurm allocation, pdsh or clush as well as ssh
(QD-008).

### Added
- **`--via ssh|srun|pdsh|clush`** (`QD_VIA`) on `qd run`, `qd probe`,
  `qd campaign` and `qd doe`: how the hosts are reached. ssh stays the
  default and is unchanged. Every launcher keeps the same contract -- a row
  per host, a host that did not answer a row too, the same outcomes, the
  same push and cleanup -- in `quarterdeck/launch.py`, behind the hooks
  `fleet.Runner` now has (`argv`, `_copy`, `outcome_of`, `needs`,
  `context`).
  - **srun**: inside the allocation qd is given (never one it asks for),
    one `srun --overlap -N1 -n1 -w NODE sh -c CMD` step per host. With no
    hosts named, the fleet is the allocation's nodes (`scontrol show
    hostnames`). Every answer's prologue carries `sched.job` (provost's
    run-manifest key, PV-020) and `sched.partition`; a node srun could not
    start a step on is `unreachable` with srun's reason; srun's own "task
    0: Exited with exit code N" line is dropped from stderr, the status
    being `rc`. Files and stdin go through the step's stdin; a timeout
    stops srun with SIGTERM so its step ends.
  - **pdsh** and **clush**: one call for every host, the answers told
    apart by the `host: ` before each line, and each host's exit status
    from a line qd adds after the command (an `exit` in the command, and a
    command's own 255, included). Files by `pdcp` or `clush --copy`, then
    checked on each host for size; a command's stdin is pushed as a file.
    `--jobs` is the fan-out, `--timeout` each host's `-u`. With `--rate`,
    each host is a call of its own. A port per host, or two hosts at one
    address, is refused.
- `qd doctor --via LAUNCHER` checks it: found here, and for srun, the
  allocation (job, partition, nodes); exit 1 if it cannot run. Every
  `qd doctor` lists srun, scontrol, pdsh, pdcp and clush.
- With QD-026 (0.10.3) and QD-018 (0.11.0) on main: the line every ssh
  command goes out after, and the stop on the host when qd gives up on
  one, are ssh's alone (`Runner.marks`). srun stops its own step with
  SIGTERM, as before; pdsh and clush send no such line, and their
  `--dry-run` call shows none. `--ssh-config` and `--reuse` are ssh's
  too: with another `--via` qd says so and does not use them.
- `qd.runs` has `via` and `sched_job` columns, and `qd log RUN` says
  `via  srun, job N` for a run that was not over ssh; so does the run's
  record in `qd report` (QD-021, which merged first).
- `--dry-run` prints the srun line per host, or the one pdsh or clush call.
- `tests/test_via.sh`, with stand-ins for srun, scontrol, pdsh, pdcp and
  clush: every node answering, one failing, one not reached, the job
  captured, the same table through ssh and through pdsh or clush, pushes,
  timeouts, probes through every launcher, the doctor, and that the
  stop on the host stays ssh's (no marker line, no ssh after a srun or
  pdsh timeout; `--ssh-config` with pdsh says so). It is in
  `run_tests.sh`'s TIMES (224 s, timed beside report and scaled to CI)
  and PARTS (three parts), so CI's shares stay even.

### Fixed
- A run filed into a dataset whose other runs carried other `#%` keys --
  a host attribute they had and it did not, or srun's `sched.job` --
  showed provost's record number as a column `n`, and `key: value`
  answers as a row per line instead of one per host.
## 0.12.0 — 2026-11-10

`qd join`: a run's rows beside another system's telemetry (Splunk,
CloudVision, Prometheus, a gNMI collector), matched by host and time
window (QD-011).

Its pull request first took 0.9.0, then 0.10.0, but each reached `main`
first from another: 0.9.0 is QD-009's peer groups and baselines, 0.9.1
QD-023's `release.yml` change, 0.10.0 QD-021's `qd report`, and then
0.11.0 QD-018's ssh work. So this is 0.12.0. Every version before it
(0.10.1 to 0.11.0 included) still keeps `ts` to the whole second.

### Added
- **`qd join RUN TELEMETRY`.** Each row of the run gets the window it was
  measured in and, for each metric, figures from its host's samples in
  that window (`--agg`: mean and max unless told; min, median, p05 to p99,
  stdev, count, first, last, and delta and rate for counters).
  - **The windows.** A fan-out's are each host's own, from `qd.hosts`:
    start (`ts`) plus `duration_s`, per pass. A `qd do`'s are the run's
    start and finish. `--time COL` or `--time START,END` gives the rows'
    own times, for an import, a dataset or a file. Both edges count.
  - **`--window +-N`** (`30s`, `2m`, `±30`) widens every window either
    side, for sparse sampling and for clocks that disagree.
  - **Clock skew.** The latest `qd probe skew` in the store (binnacle's
    skew) is read, and a host whose clock was further out than the window
    is named, with the `--window` that would cover it. `--skew RUN` reads
    another; `--skew none` reads none.
  - **Hosts** match by an alias file (`--alias`: `NAME ALIAS ...`), then
    exactly, without case, without a `:port`, and by the short name when
    it is unique. A fan-out's addresses count as names too. The notes name
    any telemetry names that matched nothing, and any that fit two hosts.
  - **Blanks, never zeros**, where a row has no sample in its window. A
    join with no telemetry in any window exits 1, and its notes say why
    that is likely.
  - `--metrics` (patterns), `--where` over the joined columns, `--cols`
    and `--format`, as the other reading verbs have.
- **Telemetry exports are read from a file**: no API client, no
  credentials, no network. CSV, TSV and NDJSON are read a line at a
  time, and only the samples of the run's hosts inside its windows are
  kept, so an export bigger than memory joins (a 600,000-line export
  stays under 100 MB). A JSON list is read whole. Long exports (a row per
  sample) and wide ones (a column per metric) are both read. Columns are
  found by name (Splunk's `_time` and `host`, Prometheus's `timestamp`,
  `instance` and `__name__`, Telegraf's `tags.host` and `fields.*`), or
  named by a **column map** (`--map FILE`: `time`, `host`, `metric`,
  `value` or `metrics`, `time_format`, `tz`). Epoch seconds, ms, µs and
  ns, and ISO 8601, are read; a time naming no zone is UTC unless the
  map's `tz` says otherwise.
- **`qd import EXPORT --telemetry`** (or `--map`, `--alias`) keeps an
  export as a run with one `telemetry` table: `time` (UTC, to the
  millisecond), `host`, `metric`, `value`, whatever shape it came in.
  `qd join RUN IMPORT` reads it from the store, `@STORE` included.
- **`qd web`: a Telemetry tab and `/api/join`.** It is `qd join` on the
  page, over telemetry the store keeps, with its figures from the engine.
  The filter bar reads the joined columns. The server joins only what is
  in a store and never reads a file.
- `qd hints` names it. `tests/test_join.sh` has twelve cases, and
  `tests/test_web.sh` one more. The cases check window edges, every
  figure against a hand-worked value, blanks, host matching, widening
  and skew, a real fan-out's windows, the pre-0.12.0 whole second,
  import against file, NDJSON at nanoseconds, a memory bound on a big
  export, and the mistakes.
  `join` is in `tests/run_tests.sh`'s `TIMES` at 30 seconds, so CI's
  shares deal it like the rest: timed beside compare, do and view on
  both of provost's paths and scaled to their seconds in CI, as
  `report` was.

### Changed
- **`qd.hosts` keeps each host's start (`ts`) to the millisecond**, not
  the whole second, so a host's window is exact. `qd show` of a run with
  several passes shows `ts` with three decimals. Runs filed before 0.12.0
  keep their whole seconds, and `qd join` gives their windows a second more to
  cover what was cut off.
- **One reader of times.** `qd export --format hec` reads row times with
  the same function as `qd join`. It now also reads microsecond and
  nanosecond epochs (they used to come out thousands of years ahead), a
  ` UTC` or `GMT` suffix, and `+01` offsets.

### Not done, by design
- No live query of Splunk, CloudVision or Prometheus: that would need
  credentials and a network, which qd has never held. Export a file and
  join that.

## 0.11.0 — 2026-11-10

qd through the ssh setups secure sites use: bastions, certificates,
Kerberos and one-time codes, proved against a real sshd, and one ssh login
per host instead of one per call (QD-018).

### Added
- **`--reuse`** (`QD_SSH_REUSE=1`), on every verb that reaches hosts: one
  ssh login per host for the whole command (`ControlMaster=auto`,
  `ControlPersist=60`, or to the next pass with `--every`), shared by the
  push, the run, the clean-up, every pass and every run of a `qd probe A
  B`. The sockets go in a new 0700 directory, `qd-ssh-XXXXXXXX`, in
  `TMPDIR`, or in `/tmp` where `TMPDIR` is too long for a socket's path
  (macOS's is). When qd ends, however it ends short of `kill -9`, every
  master is closed with `ssh -O exit` and the directory removed. On a real
  sshd a push run on one host went from five logins to one.
- **`--ssh-config FILE`** (`QD_SSH_CONFIG`): ssh and scp read FILE
  (`ssh -F`), and so do the `ssh -G` behind a run's `ssh_user`, `qd
  doctor` and a remote store's git. A missing file is refused before any
  host is contacted, `--dry-run` included.
- **`qd doctor HOST`** (with `--ssh`, `--ssh-config`, `--user`): what qd's
  ssh resolves for a host, from `ssh -G`, contacting nothing: user, port,
  the bastion and the bastion's own BatchMode and host-key checking, the
  certificate and its `Valid:` dates, the identity files that exist,
  GSSAPI and whether `klist -s` finds a ticket, a ControlPath and whether
  a master is open, BatchMode. Exit 1 when `ssh -G` cannot say.
- README: **Bastions, certificates, Kerberos and MFA**, with worked
  `ssh_config` for each, what `BatchMode=yes` rules out, and how a master
  opened by hand carries a run past a one-time code.

### Found on the way
- ssh reaches a ProxyJump bastion with a second ssh that reads the config
  file and none of qd's `-o` options: qd's `BatchMode=yes` and
  `StrictHostKeyChecking=accept-new` never reached the hop. The README now
  says the bastion's own `Host` block must carry them, and `qd doctor`
  shows the hop's settings and warns. A test proves it on a real sshd.

### Tests
- `tests/test_ssh.sh`, 20 cases. The fake ssh and scp now record every
  argv (`$FAKE_SSH_ARGV`) and play `-F`, `-l`, `-O exit|check` and
  masters. Where `sshd` is installed, four cases start one of their own on
  loopback as the user running them: a ProxyJump (and the hop ignoring
  qd's `-o`), `--reuse`'s one login, a master opened first carrying a run
  with the key withdrawn, and a certificate login. Elsewhere they are
  skipped and named; CI's new **ssh** job installs openssh-server and
  requires them (`QD_TEST_SSHD=require`). Kerberos needs a KDC and is not
  run; doctor's reading of `klist` is, with stand-ins.

## 0.10.3 — 2026-11-10

A command `qd` gives up on is stopped on the host, not only its local ssh
(QD-026).

### Fixed
- **Past `--timeout` or `--max-output`, the command is stopped on the
  host.** qd killed only its own ssh, and with no terminal the host's sshd
  does not hang the command up, so it went on running there after qd had
  reported the host done, and a pushed script lost its `qd.<run id>`
  directory under it. Reproduced against OpenSSH 9.6 on localhost before
  the fix: `qd run --timeout 2 -- 'sleep 6; touch MARK'` said `timeout`,
  and MARK appeared four seconds later. Now every command goes out after
  one line on stderr naming the process group sshd started it in (taken
  off again; written by `sh -c` with builtins only, so any login shell
  works); when qd gives up, a second ssh sends that group TERM, then KILL
  2 s later, under `sudo -n` with `--sudo`. A shell that does not lead its
  own group is never signalled.
- **The row says what happened.** `error` reads `timed out after 60s; qd
  stopped it on the host`, or `..., and may still be running on the host:
  qd could not stop it (why)` when the host could not be reached again,
  part of the command ran as another user, or the host never said where
  it ran. Such hosts are named on the summary (`NOT STOPPED`, under
  `--quiet` too) and in the run's note (`qd log RUN`), and their `--script`
  or `--push` directory is left with the command rather than removed under
  it.
- **Past `--max-output` no longer says "host killed"**, which was never
  so: `output exceeded --max-output (N bytes); qd stopped it on the host`.
- **A command that closed its output and ran on past the deadline** is a
  `timeout`, stopped as above; it was `failed`, exit -9.

### Unchanged
- A command that finishes in time answers byte for byte as before: no
  terminal, no CRLF, stderr apart, and `--max-output` counts the same bytes
  (the line naming the group is not counted).
- `--dry-run` prints the command without that line, so it can still be
  read; its help says so.

### Tests
- `tests/test_stop.sh` (new, in `TIMES`): the fake ssh's new
  `FAKE_SSH_DETACH=1` runs the "remote" command apart from the client, as
  OpenSSH does, so killing the client leaves it running (its first case
  shows that); then a timed-out command and its children, a flooding one,
  a `--script` (stopped before its directory goes), a probe on stdin, a
  stop that cannot be confirmed, and answers in time byte for byte. On
  main's `fleet.py` it fails: the marks are written.
- `tests/check_real_sshd.sh` (new, not in CI): starts a throwaway sshd on
  127.0.0.1 as the current user and checks the same against real OpenSSH;
  it skips where there is no sshd.

## 0.10.2 — 2026-11-10

CI finishes sooner (QD-024). Nothing `qd` does has changed: only CI, the
test runner and the docs.

### Measured first
- **Before:** the last 22 CI runs (#73 to #94, pull requests and pushes to
  `main`) took 10 min 34 s at the median, wall clock, from 8 min 38 s to
  12 min 43 s when they passed. Jobs waited for a runner 2 s at the median
  and 70 s at most, so the time was the long pole, not the queue: the
  provost 2.1.0 job (median 10 min 31 s) was last in 17 of the 22, and the
  doe suite was the longest suite in 150 of the 154 suite jobs (118 to
  400 s).
- **After:** this pull request's runs took 301 s (#101), 291 s (#104) and
  299 s (#108), wall clock: 5 min at most, under half the baseline's 10 min
  25 s for pull requests (half is 5 min 12 s). The last job is now a share
  of the provost 2.1.0 job, 271 to 297 s; jobs waited 3 to 15 s for a
  runner. A newer push cancelled the run still going (#103, cancelled when
  #104 started).

### Changed
- **The seven jobs that run the whole suite each run it on three runners**
  (`test` for Python 3.9 to 3.13, `Python 3.6 compatibility`, `test
  (provost 2.1.0)`): 26 jobs a run where there were 12, and nothing taken
  off a pull request: every Python, the 3.6 floor and provost 2.1.0 still
  run every suite.
- **A newer push to a pull request cancels that pull request's run still in
  progress.** A push to `main` is never cancelled: each has a concurrency
  group of its own, so the version job's push check runs on every one.
- **Every job has `timeout-minutes`**, about three times its usual time (15
  for a share of the suite, 5 or 10 for the rest). A hung case used to hold
  its runner for GitHub's six hours.
- The shellcheck job uses the runner's own shellcheck, and installs one only
  where there is none; it also runs the shard check (below).

### Added
- **`run_tests.sh --shard K/N`** runs share K of N. Suites are dealt by
  their measured seconds (`TIMES`), the longest first, each to the share
  with the fewest seconds so far, so every machine deals the same. The
  longest suites (`PARTS`: doe, peers and web in three; run, xstore,
  compare and probe in two) are split into parts, each a share of their
  cases, each part in a different share. Without `--shard` every suite runs
  whole, as before.
- **`QD_TEST_PART=I/P`** in `tests/test_helper.bash`: a suite runs its Ith
  case and every Pth after it.
- **`run_tests.sh --list`** prints what a run would take, without running
  it or needing provost.
- **The start order comes from measured times** for every suite, where it
  named seven: each suite's seconds in CI's seven suite jobs, averaged.
  Every run ends with a `seconds:` line, every suite's seconds, in the form
  `TIMES` takes.
- **`tests/check_shards.sh`**, run by CI and `tests/check.sh`: every suite
  is in exactly one share, whole or as all its parts with no two on one
  runner, for every N CI uses and 1 to 8; and every sharded job's matrix
  runs shares 1 to N.
- **`tests/test_runner.sh`**, a suite for the runner: `--list`, the deal,
  bad `--shard` arguments (exit 2), a failing suite failing its own share
  with its output whole, the split parts running every case once, the exit
  statuses as before, and `check_shards.sh` failing a broken runner or
  workflow (mutations). It also fails when a suite is missing from `TIMES`.

## 0.10.1 — 2026-11-10

A run filed one capture at a time no longer reads back a table short
(QD-022). Started as 0.8.7, then 0.9.1 and 0.9.2; renumbered on top
of 0.10.0 (QD-021).

### Fixed
- **Without provost's `batch` (PyPI's provost 2.1.0, or
  `QD_PROVOST_BATCH=0`), qd files a run's captures one after another**,
  where it filed the answers four at once. provost's store lock is
  `mkdir .lock`, which locks only if `mkdir` fails on a directory another
  process has just made. uutils coreutils' `mkdir` before 0.11.0 reports
  success instead. That is `/usr/bin/mkdir` on Ubuntu 25.10 and 26.04, and
  so on GitHub's `ubuntu-latest`. On such a machine two provost processes
  started together could both hold the lock: two captures took one id, or
  one died on the other's `git` index lock or lock file. The run then read
  back a table short (`has no single table 'iperf_results' (tables:
  cpu_summary)`). That was CI's intermittent provost 2.1.0 failure on
  #21 and #22.
- The price: on that path a run's filing is no longer parallel. One run of
  24 tables on an idle four-core machine took 35 s, against 10 s four at
  once. `provost batch` (provost 2.2.0 and later) is untouched: one
  process, which parses in parallel inside it.
- `QD_FILE_JOBS=N` files N at once on that path again. It is safe only
  where `mkdir --version` is not uutils' before 0.11.0. With `batch` it is
  still `batch -j N`.
- The web case *references are never paths* checked that a refusal held no
  `42`, the secret's value. The refusal names its temp directory, and one
  named `qd-test.Bz42H2` failed it. The secret is now a value no temp path
  can hold.

### Added
- A `do` case, *one capture at a time: one provost at a time*. A
  stand-in provost takes a marker with noclobber (not `mkdir`) and notes
  any provost started while it is held. It fails on qd as it was.
- `tests/stress_filing.sh`, not one of the suites. It files multi-table
  `qd do` runs on the one-at-a-time path in a loop, rounds side by side,
  and checks every table reads back. `STRESS_MKDIR=racy` puts in front of
  `mkdir` a stand-in that loses the race as uutils' did, so it shows on
  any machine. `STRESS_FILE_JOBS=4` is qd as it was, and fails.
  `STRESS_RAW=1` files captures with provost alone.

### Not fixed here
- Two writers into one store at once still depend on provost's lock, with
  any provost: a second terminal working the same campaign, or two `qd
  run`s side by side. On a machine with that `mkdir`, the two can take the
  lock together and a capture can be lost. README says so where it
  describes a second campaign worker. The fix belongs in provost.

## 0.10.0 — 2026-11-10

`qd report`: an evidence package for a run or a campaign (QD-021). Written as
0.9.0; QD-009 merged first with that number, so this is 0.10.0, rebased
onto it.

### Added
- **`qd report RUN|campaign:NAME --out DIR`** writes a directory an
  evaluator can read, check and attach without qd: each table as CSV and
  JSON (`qd export`'s), `qd stats` and `qd outliers` on it, every host's
  answer exactly as provost keeps it, `manifest.json`, `summary.md`,
  `summary.html`, and `SHA256SUMS` over every other file (`sha256sum -c`
  passes). qd prints the sha256 of `SHA256SUMS`: the line to record in the
  test report.
- **Sections that fill in as the features do.** Checks with `--check FILE`
  (`qd check`, QD-010), or the verdicts `qd check --keep` filed; medians
  and status changes against `--baseline RUN` (`qd compare`; stored named
  baselines are QD-009's); who ran it (QD-016) in each run's record; the
  captures' `#%` keys and `provost annotate`'s post-run keys (PV-020);
  `provost verify` on the report's captures, with the store's head commit
  (PV-026). One that has nothing to say is left out and listed, with why,
  under *Not in this report* and in `manifest.json`.
- **A campaign** (`campaign:NAME`, or a design's name): its parts and
  their states, hosts over every part's last run, the parts' medians side
  by side, a requirement-by-part table of checks, and each part's last run
  in full. A part not run yet is a finding.
- **Every figure is the engine's**, computed by the functions the
  commands use, and each section ends with the exact command (with
  `--store`) that prints it again; `manifest.json` lists them all.
- **`summary.html` runs nothing**: static, no script, no request outside
  the package, every dataset and thresholds-file string escaped, and a
  Content-Security-Policy of `default-src 'none'`. `summary.md` escapes
  the same text so no renderer reads it as markup.
- Each copied capture is checked against the sha256 provost recorded for
  it; a mismatch is a finding.
- `--zip` also writes `DIR.zip`; `--drift` (`QD_DRIFT`) and `--z` (`QD_Z`)
  as `qd compare` and `qd outliers` take them.
- The package is written beside `--out` and moved into place whole, so a
  failed report leaves nothing; `--out` must be new or empty and outside
  the store. Exit 1 when the report records a finding, 2 when it cannot
  be written (nothing is).
- `tests/test_report.sh`: the package and its sums, tables and figures
  against `qd export`, `qd stats`, `qd outliers`, `qd check` and `qd
  compare` on the same run, hostile HTML and Markdown in a dataset and a
  thresholds file, sections left out, kept verdicts, an import, the
  refusals, and a campaign with its zip.

### Changed
- `qd outliers` builds its rows with `stats.outlier_cells`, which the
  report shares; and a run's table can be read by its listing
  (`Run.load_info`), which two of a `qd do`'s same-named tables need.
  Neither changes any output.

## 0.9.1 — 2026-11-10

`release.yml` publishes to PyPI only (QD-023). Nothing about `qd` itself
changed. (This pull request first took 0.8.7; 0.9.0 reached `main` while
it was open, so it is 0.9.1 instead, and 0.8.7 was never on `main`.)

### Changed
- **No TestPyPI dry run.** The `publish to TestPyPI (dry run)` job, the
  `testpypi` environment and "Run workflow"'s `target` choice are gone,
  along with the TestPyPI setup in the workflow's header. PyPI's trusted
  publisher is the only one this needs.
- **"Run workflow" uploads to PyPI**, from `main` only (a run on any other
  ref stops before building), and now runs `tests/check_version.sh` first,
  as a release always did. It makes no tag and no GitHub release; a
  published GitHub release tagged `vX.Y.Z` still does both, and still has
  its tag checked against the version.

## 0.9.0 — 2026-11-10

Peer groups and qualified baselines, kept in the store, and a significance
test that tells a small real slide from run-to-run noise (QD-009).

### Added
- **`qd peers define NAME`**: a peer group, the hosts that ought to measure
  alike, kept in the store as qd's own table `qd.peers`. `--by COLS` is a
  rule (a row's group is its value of COLS, read from whatever is looked
  at); `--from FILE` (host and group) and `--facts COLS` (each host's COLS
  from the latest facts run, or `--run RUN`) are lists, frozen when
  defined. `qd peers ls`, `show NAME [RUN]`, `rm NAME --yes`;
  `--replace` files a new definition over an old one.
- **`--peers NAME`** on `qd stats` (a row per peer group, before any
  `--by`), `qd outliers` (each host against its own group's median and
  spread, not the fleet's) and `qd compare -c COL` (each group's median per
  run, flagged past `--drift`).
- **`qd baseline set NAME RUN...`** (or `RUN --last N`, `--group NAME`;
  `--peers`, `-c`, `--key`, `--agg`, `--where`, `--note`): a qualified
  baseline, kept as `qd.baselines` with who set it and when, the runs, and
  per column, peer group and host every run's value with their median,
  MAD and count. `qd baseline ls`, `show NAME`, `rm NAME --yes`. A name
  that is a run's is refused.
- **`qd compare ... --baseline NAME`** with a qualified baseline: per
  column and peer group the drift, the effect size (rank-biserial), the
  Mann-Whitney U p, the Holm-adjusted p across every test in the
  comparison, and a verdict; host by host, the drift from the baseline's
  median. A significant difference of `--min-drift` percent or more (1,
  `QD_MIN_DRIFT`) is a change even inside `--drift`; a drift past `--drift`
  is still one. Fewer than three runs a side: "too few
  runs", and the drift alone. `--alpha P` (`QD_ALPHA`, 0.05). The runs the
  baseline was set from are left out.
- `qd outliers --method iqr` (Tukey's fences, `--k`, 1.5) beside the robust
  z, which stays the default.
- `qd web`'s Compare tab: a Peer groups picker, and qualified baselines in
  the Baseline list, with the engine's figures (`/api/compare` takes
  `peers=` and a qualified `baseline=`, and lists both).
- `stats.mann_whitney`, `smallest_p` and `holm`, standard library only,
  matching scipy's `mannwhitneyu` (exact for 8 or fewer with no ties, else
  the normal approximation with tie and continuity corrections) to 1e-15
  over 4,000 random samples; the suite holds scipy's figures as constants.
- `tests/test_peers.sh`.

### Changed
- `qd rm` refuses to delete `qd.peers` and `qd.baselines` whole, as it
  refuses qd's other records.
- qd's own tables may escape a space as `\x20` (`filing.own_tsv(...,
  spaces=True)`, used by the two new tables): provost's TSV reader splits
  a column of cells like `see 3 4` into two. Reading any table unescapes
  it; nothing already filed changes.

### Not changed
- doe has no unpaired two-sample test (its `compare` is a paired t-test
  between two sessions matched by factor levels, and needs numpy and
  scipy), so the test is qd's, in the standard library.

## 0.8.6 — 2026-11-10

The version check also compares with the base branch (shared_tools BN-002).
Nothing about `qd` itself changed.

### Tests
- **`tests/check_version.sh` is shared_tools' template copy now**: the same
  agreement check (`quarterdeck/__init__.py`, `pyproject.toml`, the top of
  `CHANGELOG.md`) that `tests/check.sh`, CI and `release.yml` run, and given
  a commit it also fails unless the version is greater than that commit's.
  CI's **version** job runs it against the base branch on a pull request and
  against what `main` was before a push to it, so a pull request that
  forgets the bump, or two that take the same number, fail there.
  `CLAUDE.md` and README say so, and the ticket snippet in `CLAUDE.md` is
  the current one.

## 0.8.5 — 2026-11-10

Ready for PyPI (QD-007). Nothing `qd` does has changed.

### Added
- **`.github/workflows/release.yml`**: publishing a GitHub release tagged
  `vX.Y.Z` builds the sdist and wheel, checks the tag against the version
  in all three places, runs `twine check --strict`, installs the wheel in
  a fresh venv on Python 3.12 and on 3.6 (the floor), and uploads to PyPI
  through Trusted Publishing with attestations -- no token anywhere.
  "Run workflow" uploads to TestPyPI instead, for the dry run before the
  first release. The one-time PyPI setup is in the workflow's header.
- Extras: `quarterdeck[provost]`, `[binnacle]` and `[all]` bring the
  tools qd drives (provost only on Python 3.8+, which it needs). qd still
  imports none of them.
- CI's wheel job also installs the wheel on Python 3.6, and runs
  `twine check --strict`.

### Changed
- README's install section leads with `pip install 'quarterdeck[all]'`.
- The licence stays in the `{ text = ... }` form with the GPLv3+
  classifier: the PEP 639 string needs setuptools 77, which needs Python
  3.9, and the package advertises 3.6. PyPI shows the licence from
  either.

## 0.8.4 — 2026-11-10

`qd web` served beyond this machine needs a token, can serve https, and is
read-only there (QD-017).

### Added
- **A token on every request when `qd web` listens beyond loopback**
  (`--host` anything but 127.0.0.1, localhost or ::1). With none given, one
  is made (`secrets`) and printed once, in the link it starts with. Given
  as `QD_WEB_TOKEN`, or the first line of `--token-file`
  (`QD_WEB_TOKEN_FILE`), it is never printed; it must be 16 or more
  printable characters with no spaces, quotes, commas, semicolons or
  backslashes. It is accepted as `Authorization: Bearer`, as the
  `qd_web_token` cookie (HttpOnly, SameSite=Strict, Secure under https),
  or as the link's `?token=`, which sets the cookie and redirects to the
  same page without it. Every offer is compared with `hmac.compare_digest`,
  and request logs show `token=-` in its place. A wrong or missing token
  gets 401, for the API, the page and `/floor/` alike.
- **Giving a token on loopback requires it there too**, for a login node
  whose 127.0.0.1 every user shares. No token on loopback is as before.
- **`--tls-cert FILE` and `--tls-key FILE`** (`QD_WEB_TLS_CERT`,
  `QD_WEB_TLS_KEY`) serve https with the standard library's `ssl`, TLS 1.2
  or newer, the handshake in the request's own thread. A bad or missing
  file is refused with exit 2.
- **`--allow-writes`.** Beyond loopback `/api/overlay`, the one request
  that writes anything (the Floor plan overlay, into qd's cache), is
  refused with 403 unless it is given.

### Changed
- Listening beyond loopback without TLS prints a warning that the token and
  the data cross the network in the clear, and says whether writes are
  allowed.
- A request path starting `//` is collapsed to one slash before it is
  routed, as Python 3.12's `http.server` already does, so `//name/` is a
  path on every Python and never read as a host.

## 0.8.3 — 2026-11-10

What may be sent to a fleet: an allow-list and a read-only mode (QD-015).

### Added
- **`--allow FILE`** (`QD_ALLOW`) on `qd run`, `probe`, `campaign` and
  `doe`: only commands matching a pattern in FILE run. Anything else is
  refused (exit 2), unless `--confirm` is given and `CONFIRM` is typed at
  the terminal; with no terminal it is refused outright. The probes qd
  ships run by name.
- **`--read-only`** (`QD_READ_ONLY=1`): only the probes and allow-listed
  commands; `--push`, `--script`, `--sudo` and `qd do` are refused, and
  no confirmation lifts it.
- Every run under a policy records it in its qd.runs notes (read-only,
  the allow-list's name and sha256, any confirmed override and who
  confirmed it); every refusal goes to `policy.log` in qd's cache.
- The mutation guard (DANGER) still applies on top. README's new
  "Allow-lists and read-only" says plainly that this is policy, not a
  sandbox.
- New module `quarterdeck/policy.py`; new suite `tests/test_policy.sh`
  (9 cases, the confirmation typed at a real pseudo-terminal).

## 0.8.2 — 2026-11-10

Every run records who ran it (QD-016).

### Added
- **`qd.runs` says who ran each run**: five new columns. Every run (`qd
  run`, `probe`, `campaign`, `doe`, `do`, `import`, `check`) records
  `operator` (`QD_OPERATOR`, else the login user) and `operator_host` (the
  machine qd ran on). A fan-out also records `ssh_user` (`--user`, else what
  `ssh -G` gives each host, comma-separated where hosts differ), `ssh_key`
  (the fingerprint of each key offered: the `-i` or `IdentityFile` keys in
  `--ssh`, else the agent's from `ssh-add -l`; never the key) and `sudo`
  (`yes`/`no`). What cannot be found out (no `-G`, no agent, an unreadable
  key, a lookup over 5 s) is blank, never a guess, and never stops the run.
  `ssh -G` is a local read of ssh's config, once per distinct host, through
  the same `--ssh` command, before the fan-out.
- `qd log RUN` shows `by OPERATOR@HOST` and an `ssh` line (user, key,
  sudo); `qd log` lists an `operator` column; `qd web`'s `/api/entries`
  carries `operator` and the run's header shows it.
- qd sets `PROVOST_OPERATOR` for the provost it runs, unless the caller set
  one, so a provost that records the operator (PV-027) gets qd's. provost
  2.3.0 ignores it.

### Compatibility
- Runs filed by an older qd have none of the columns and show blank; the
  new columns go at the end of `qd.runs`, and qd 0.6.4 reads a store that
  holds them (checked by hand: both versions list a store with one run of
  each).

### Tests
- `tests/test_operator.sh`, a new suite: the fields of a fan-out,
  `QD_OPERATOR` and the login user, `--user` reading no config, hosts with
  users of their own, an ssh without `-G`, the `-i` key and a missing or
  unreadable one, `--sudo`, `do`/`import` recording the operator only, free
  text round-tripping, `PROVOST_OPERATOR`, and an older run beside a new
  one. `tests/test_web.sh` checks the API. The fake ssh answers `ssh -G`
  (`FAKE_SSH_USER`, `FAKE_SSH_USER_<host>`, `FAKE_NO_DASH_G`) and logs it
  apart, so `ssh_calls` still counts connections only.

## 0.8.1 — 2026-11-10

Runs go to Splunk and Prometheus as files (QD-013).

### Added
- **`qd export --format hec`**: newline-delimited Splunk HTTP Event
  Collector events, one per row, with `time`, `host`, `source` (`qd`),
  `sourcetype` (`qd:<table>`, or `--sourcetype`), optional `--index`,
  indexed `fields` (`qd_run`, `qd_name`, `qd_kind` and the row's host
  attributes and factors) and the row as `event`. The time is the row's
  own `ts`/`timestamp`/`time` (epoch or ISO 8601), else the run's, and qd
  says on stderr how many rows borrowed the run's or went without.
- **`qd export --format openmetrics`** (also `prom`, and `-o x.prom`):
  one gauge per numeric column, labelled by host, peer, run and the
  columns named in `--labels`; sizes in bytes and times in seconds, with
  `_bytes`/`_seconds` on the name; no timestamps, so node_exporter's
  textfile collector and the Pushgateway take it. Two rows that would
  make one series are refused (exit 2), naming `--labels`.
- Both leave a blank cell out (no field, no sample), never 0 or "".
  qd makes no network call for either: README's new "Into Splunk,
  Prometheus or a notebook" shows the `curl` and the pandas one-liner.
- New module `quarterdeck/exporters.py`; new suite `tests/test_export.sh`
  (7 cases).

## 0.8.0 — 2026-11-10

A run against fixed limits, by requirement (QD-010).

### Added
- **`qd check RUN --against FILE`**: one verdict per requirement --
  pass, fail or not measured -- from a thresholds file (TSV or CSV with
  `req`, `column`, `op`, `limit`, and optionally `limit2`, `where`,
  `agg`, `unit`, `note`). Ops `<`, `<=`, `>`, `>=`, `==`, `!=`, `in`,
  `between`; `agg` is `each` (every row must pass) or a figure over the
  rows (median, p99, max, ...). Sizes and times compare on one scale and
  read in the limit's unit; units that cannot be compared are refused.
- Blank is never a pass: a missing column, no rows, a blank cell, or an
  aggregate over only some hosts is not measured, and exits 1 as a
  failure does. A thresholds file qd cannot read exits 2, naming the
  check.
- `--each` gives a row per host per check; `--keep` files the verdicts
  as a run of kind `check`, which `qd show`, `qd export` and `qd web`
  read like any other.
- New module `quarterdeck/check.py`; new suite `tests/test_check.sh`
  (8 cases, its web server on port 18160); README "Against requirements".

## 0.7.2 — 2026-11-10

qd at a thousand hosts (QD-019).

### Added
- **`--rate N/s`** (`QD_RATE`) on every verb that fans out: new
  connections spaced evenly, for a bastion's sshd `MaxStartups`. With a
  campaign's `--ramp`, the slower of the two holds.
- `tests/scale.sh` (not one of the suites): times the fan-out and the
  filing against N fake hosts, and samples qd's peak memory, threads and
  open files. `docs/scale.md` has the numbers.

### Fixed
- **A fan-out no longer outruns the open-file limit.** About 5 files per
  host in flight: under `ulimit -n 64`, 32 at once reported 81 of 100
  hosts unreachable, every ssh that could not get a pipe read as a host
  that did not answer. qd now raises its soft limit towards the hard one,
  and if that is not enough runs fewer hosts at once and says so.

## 0.7.1 — 2026-11-10

Campaigns paced for power (QD-020).

### Added
- **`qd campaign new|run --max-per ATTR=N`**: no more than N hosts sharing
  a host attribute's value (a PDU, a rack) run at once; other values go
  past a full one.
- **`--ramp RATE`** (`6/min`, `1/s`, `120/h`): host starts spaced evenly.
- **`--window "Mon-Fri 18:00-06:00"`** (repeatable): parts start only
  inside a window, local time; outside one, `campaign run` starts nothing
  and says when the next opens. `campaign status` shows the limits and
  whether a window is open, until when, or when the next opens.
- All three are kept on the campaign (three new columns at the end of
  `qd.campaigns`, blank for campaigns defined before), so a resumed or
  carried-on campaign paces the same; `campaign run`'s flags override.
- New module `quarterdeck/pacing.py`: the scheduler is a pure function of
  what is running and the time, so it is tested with a fake clock. New
  suite `tests/test_pacing.sh` (6 cases).

## 0.7.0 — 2026-11-09

qd deletes only what it made on a host, and a suite holds it to that
(QD-014).

### Changed
- **Every directory qd makes on a host is marked.** `--push` and
  `--script` write `.qd-owned`, holding the run's id, into the run's
  `qd.<id>` directory as they make it. A later pass of the same run
  pushes into it again only while that mark is still its own; a file
  named `.qd-owned` cannot be pushed.
- **Cleanup checks on the host before it deletes**, under the same
  `sudo -n` as the delete: the path must end in exactly this run's
  `qd.<id>`, hold no `..`, be a directory and not a symlink, and hold a
  plain `.qd-owned` with this run's id. Anything else is refused and
  reported in the host's `error` (`qd: could not remove ...: qd: refusing
  to remove ...`), and nothing is deleted. Before, cleanup ran `rm -rf` on
  the computed path on trust. A missing directory is nothing to remove,
  as before.

### Added
- `tests/test_cleanup.sh`: the invariant as a suite. It makes a run's
  directory through the fake ssh, then breaks it the ways a bug could (an
  empty path, `/`, `~`, `.`, `..`, `--remote-dir` itself, a `..` in the
  path, a symlinked directory, a missing mark, another run's id, a mark
  that is a link, a file in its place, another run's `qd.*`), under
  `--sudo` too, and checks each is refused with every canary left. A
  stand-in `rm` refuses any delete outside the case's temp dir, so no case
  can reach a real path. A mutation case takes the id check out of a copy
  of `fleet.py` and shows the suite then fails.

### Fixed
- CI's test matrix runs on `ubuntu-24.04`: `ubuntu-latest` moved to 26.04,
  where setup-python has no Python 3.9, so the 3.9 job failed before it
  ran anything.

### Reviewed
- Every other delete in qd is local and was checked: the temp
  directories of `qd do`, `doe`, `split`, `campaign` and filing
  (`tempfile.mkdtemp`, removed in `finally`); the id-claims cache (`rmdir`
  of empty entries only); `qd store rm --delete` (only a provost store or
  an empty directory, under the store's lock); a remote store's copy (in
  qd's own `remotes` directory, under a name `NAME_RE` allows, no `..`);
  the store lock (removed only while it carries this process's owner
  record); the export's temp file. `qd rm` deletes through provost. None
  needed a change.

## 0.6.4 — 2026-11-05

Nothing `qd` does has changed; the suites run side by side (QD-005).

### Changed
- **`tests/run_tests.sh` runs several suites at once**: `-j N` (or
  `QD_TEST_JOBS=N`), one per core by default. Each suite's output is held
  until it ends and printed whole, in name order, with the same `ok`/`FAIL`
  lines and counts, the same last line and the same exit status (0, 1, 2);
  the slowest suites start first, and the run ends with its wall time and
  the three longest. `-j 1`, or naming one suite, is the serial run, as
  before. Ctrl-C stops every suite running, each case clearing up as it
  does now. It is written for macOS's bash 3.2 (no `wait -n`). CI's suite
  jobs and `tests/check.sh` get it by default. CI took 7 min 48 s and
  9 min 33 s (runs 46 and 48), against 20 min 27 s on main (run 45): its
  slowest job, provost 2.1.0's, went from 20 minutes to 6 to 9, the suite
  jobs run the suite in 4 to 9 minutes, four suites at a time, and the
  runner's speed is most of the spread. On four cores here the whole suite
  took 332 to 397 s, against 891 s one at a time. The doe suite, the
  longest (3.5 to 6 minutes beside the others), is now the floor.
- **Each suite that starts a web server has a port range of its own**:
  web 18100, xstore 18120, remote 18140. xstore and remote both asked for
  18110, and `qd web` checks a port is free before it binds, so two run at
  once could both pick it and one fail to start.
- **The harness's PATH-without-a-command directory** (`path_without`, for
  the probe and run suites) is made in the case's own temp dir, so it goes
  with the case; four were left in `/tmp` on every run.
- **The run suite's two-runs-at-once case** waits for the slow run's
  directory on the host before it starts the quick one, not a fixed 0.7 s
  that a busy machine can outlast.

### Fixed
- **A case could fail after it passed**, in its teardown: git 2.47 and
  later follow a commit or a fetch with a detached `git maintenance run
  --auto`, and one still writing into a store's `.git` when the case ended
  made teardown's `rm -rf` fail ("Directory not empty"). CI's second run
  with the suites side by side failed so (the remote suite's web page
  case, git 2.56). Every case now runs git with `maintenance.auto` off
  (through `GIT_CONFIG_COUNT`, so the stores' own config is untouched);
  teardown waits for a case's web server to exit and tries the removal a
  second time.
- `run_tests.sh --help` (new) and `check.sh --help` print their usage from
  any directory; `check.sh` read itself by a path relative to where it was
  started.

## 0.6.3 — 2026-11-05

Nothing `qd` does has changed; this is for whoever works on it (QD-004).

### Added
- **`tests/check.sh`**: every check CI runs that can run on one machine,
  in CI's order -- the version check, the 3.6 compile check, vermin,
  shellcheck, `node --check` on the page, `reuse lint`, a wheel build with
  `twine check`, and the whole suite with provost's `batch` and with
  `QD_PROVOST_BATCH=0`. A check whose tool is missing is skipped and named
  in the summary, never failed; `--quick` leaves out the suites and the
  wheel.
- **`tests/check_version.sh`**, and a CI job running it: fails when
  `quarterdeck/__init__.py`, `pyproject.toml` and the top of `CHANGELOG.md`
  do not say the same version, or the top section is not
  `## X.Y.Z — YYYY-MM-DD`.
- **`QD_TEST_ONLY=TEXT`** runs only the cases whose name contains TEXT
  (`QD_TEST_ONLY=import bash tests/run_tests.sh store`).
- README: **Working on quarterdeck** -- the dev setup, the check command,
  running one suite or some cases, and what only runs on Linux.

### Fixed
- **The suites on macOS**: `find -printf` (GNU only) in the store suite is
  gone, and the harness no longer doubles the slash at the end of macOS's
  `TMPDIR`, which broke the run suite's assertions on provost's tips.

## 0.6.2 — 2026-11-05

### Fixed
- **shellcheck is green again** (QD-003). 0.6.1's format-4 test took a
  capture id with `ls | head -1`, which CI's shellcheck refuses (SC2012);
  it takes it from a glob now. A test-only change.

## 0.6.1 — 2026-11-04

### Fixed
- **provost's store format 4 reads** (QD-003). provost main writes it since
  PV-015; its next release would have made `qd store import` refuse every
  archive of a store it had touched ("a newer provost made it"), and
  quarterdeck's CI, which installs PyPI's newest provost, red the same day.
  Format 4 changes data, not layout: column 2 holds the capture id in every
  row. `STORE_FORMATS` is now 1-4, and an unknown format (99) is still
  refused, its message naming 1, 2, 3, 4.
- **The capture column is found by place, not by name.** In a dataset
  whose data has a column called `capture`, provost names its own
  `_capture` (column 2) and leaves the data's `capture` at the end; qd read
  the data's as the capture id, so `ds:NAME` showed the wrong capture and
  its raw answer could not be found. qd now takes column 2 (`#` then
  `capture`, `_capture`, ...), and `ds:NAME` shows provost's id as `capture`
  with the data column as `capture_2` (the first free `capture_K`), the way
  provost renames a data column called `#`. qd's own datasets file no such
  column, so runs read as before.
- Tests: `test_store.sh` builds a format-4 store with a `_capture` dataset
  and round-trips it through `store export` / `store import`.

## 0.6.0 — 2026-11-04

### Added
- **`REF@STORE`: a run read from any registered store** (#7, QD-002).
  Wherever a command reads a run -- `show`, `stats`, `freq`, `hist`,
  `outliers`, `pivot`, `trend`, `export`, `floor`, `log RUN`, `diff`,
  `compare`, `view` -- a reference may name the store it is in:
  `qd diff kernel@wr01 kernel@wr02`, `qd show latest:hosts@wr01`. Two
  stores' runs are compared without exporting one into the other, remote
  stores included. Without `@STORE` a reference means what it did.
  - Only a registered name; an unknown one is an error listing the stores,
    never `--store` instead. A file whose name has an `@` is still a file.
  - One store is opened once per command, a remote copy fetched once.
  - `qd diff RUN@STORE` compares with the run before it in that store.
  - `qd compare` labels each run from another store `RUN@STORE`, and
    `--last N@STORE` takes the last N from one store. A host only one
    store measured is blank on the other side, never zero.
  - Report headers name a run from another store `RUN@STORE`.
  - `qd web`: Diff can take its A side from another store, and Compare
    can add runs from other stores. The API takes a store per side
    (`a_store`/`b_store` or `RUN@STORE` on `/api/diff`, `also=RUN@STORE`
    on `/api/compare`); the page still computes nothing.
  - Writing commands take no `@STORE`: `qd rm RUN@STORE` is refused, with
    the `--store` that does it.

## 0.5.2 — 2026-11-04

### Changed
- **Step 3 of `CLAUDE.md`'s ticket section puts its command on one line**,
  in a code block of its own, as shared_tools' copy now does (ST-008,
  ST-010). The command used to wrap across two lines inside one code span,
  so pasting it into a shell ran two commands and failed. Nothing outside
  the notes and the version changes.

## 0.5.1 — 2026-11-04

### Changed
- **quarterdeck's work goes through the shared ticket board** (QD-001).
  `CLAUDE.md` carries the "Every task is a ticket" section from
  `MartinGallagher-code/shared_tools`, verbatim, and quarterdeck is
  registered there with the prefix `QD`. Nothing outside the notes and the
  version changes.

## 0.5.0 — 2026-11-02

### Added
- **Remote stores: `qd store new NAME --remote [USER@]HOST:PATH`** (#6). A
  provost store on another machine is read from a shallow git copy here,
  in `~/.cache/quarterdeck/remotes/NAME`. It holds the store as it is now,
  and no read needs its history. Every read command works on it unchanged:
  `log`, `show`, `view`, `compare`, `diff`, `stats`, `web`. `qd store new`
  makes the copy at once, and registers nothing that cannot be reached or
  is not a provost store (`stores.py`: `fetch`, `ready`, `why_not`;
  `cli.py`: `new_remote`).
  - **Fetched before reading:** only what is new, over the ssh `qd run`
    uses (`QD_SSH`, and `QD_SSH_USER` when the spec names no user), at most
    every `QD_REMOTE_REFRESH` seconds (30). `--no-fetch` (`QD_NO_FETCH=1`)
    reads the copy as it is.
  - **The copy stays one store's size:** it keeps no reflog, keeps each
    fetch as a pack, and is gc'd here every ten fetches (`_tidy`), which
    drops what the fetches replaced. git's own `gc --auto` waits for
    thousands of objects, and then detaches. Measured over real ssh, with
    24 refreshes of a store whose history reached 17 MB: the copy fell
    back to 784 KB at the 10th and 1.4 MB at the 20th, each the store as
    it then was.
  - **An unreachable host:** the last copy is read, and its age said. The
    host is not tried again until `QD_REMOTE_REFRESH` has passed, so `qd
    web` never waits on it twice in a row.
  - **Nothing files into a copy:** `run`, `probe`, `do`, `import`, `rm`,
    `store clear`, and a campaign's or design's runs are refused before any
    host is contacted (`cli.py` `store_of`). `filing.py` refuses as well,
    whatever path a write comes by.
  - **What a failed fetch means:** an unreachable host, ssh refusing the
    login, no store at that path, a git repository that is not a provost
    store, or git's refusal of a store another user owns, which comes with
    the `safe.directory` command to run there.
  - **`qd web`:** fetches as the page reads (one fetch at a time across
    its threads). Its store picker shows a remote store's host
    (`web.py`, `app.js`).
  - **The other store commands:** `qd store ls` shows the host and the
    copy's age. `rename` moves the copy. `rm` deletes the copy and leaves
    the store there as it was. `qd doctor` says what the store is a copy
    of.

Checked over real ssh too, against a Debian 12 container running sshd and
git 2.39: the copy made and refreshed in about 0.3 s a fetch, a stopped
host falling back to the copy, a refused login, and a store chowned to
another user, each said as above.

### Tests
- `tests/test_remote.sh`, over the suite's fake ssh with git's own
  upload-pack:
  - the copy is made, shallow, read, and refreshed only when due;
  - `--no-fetch`;
  - `QD_SSH_USER`, and a spec's own user before it;
  - writes refused before any ssh call (a campaign's and a design's runs
    among them), with the copy and the store there unchanged;
  - an unreachable host leaves the copy, and is tried once;
  - what cannot be a remote store, with nothing left behind;
  - another user's store, explained;
  - rename and rm;
  - `qd web`'s picker, and a run filed there showing without a restart.

## 0.4.0 — 2026-11-02

### Added
- **`qd rm RUN... [--yes]`**: delete runs from the store. A run goes whole,
  through provost: every host's answer and every table it filed, from
  whichever datasets they are in (other runs' rows there stay), and its
  rows in `qd.runs` and `qd.hosts`. RUN is any reference `qd show` takes;
  `ds:NAME` deletes a whole dataset (`provost rm NAME`). Without `--yes` it
  lists what would go, deletes nothing and exits 2. Then it is one commit,
  so the store's history keeps it. It refuses qd's own records as whole
  datasets, and a capture that holds another run's rows too. A run that
  was part of a campaign is said, with the `qd campaign retry` that runs
  it again (`cli.py` `cmd_rm`, `store.py` `all_run_captures`,
  `own_holders`, `filing.py` `rm_captures`, `rm_datasets`).
- **`qd store clear [NAME] [--yes]`**: empty a store: every dataset, qd's
  or not, and the captures that fed them, through `provost rm`. It stays
  registered, and its history is kept. Without `--yes` it says what it
  holds and deletes nothing.
- Deleting one run needs `provost rm --capture` (provost after 2.2.0). An
  older provost is refused with that reason, and nothing is changed.
  `qd store clear` and `qd rm ds:NAME` work with any provost.

### Tests
- `tests/test_rm.sh`: what goes is said and nothing goes without `--yes`;
  one fleet run of two deleted, the other whole and the store clean;
  several runs and a dataset at once; qd's own records and unknown names
  refused; `store clear`. On a provost without `rm --capture`, the
  refusal.

## 0.3.0 — 2026-10-30

### Changed
- **`qd view` with no RUN opens on everything in the store**: every run,
  newest first, then every dataset provost keeps there (`ds:NAME`, the
  runs' own `qd.runs` and `qd.hosts` among them), each with its kind and
  size. Enter opens one. `qd view RUN` opens on that run as before, with
  the contents under it (`explore.py` `StoreView`, `cli.py` `cmd_view`).
- **Page through the store without leaving the table**: `]` and `[` open
  the next and the previous table, through a run's tables and on to the
  next run's, then the datasets; `}` and `{` jump a whole run (or
  dataset). The title says where you are, `3 of 40 in the store`. From a
  report on a table (`d`, `c`, ...) they page that table. The contents
  is read again when provost has filed something since (`App.page`,
  `App.everything`).
- **`q` from a table goes back to the contents**, on the one you were
  looking at, ready for Enter on the next; `L` goes there from anywhere.
  `Q` quits, as before. `L` used to list the runs only.
- A run's size reads `1 row`, not `1 rows` (`qd log`, `qd web`, the
  contents).

## 0.2.0 — 2026-10-30

### Added
- **Named stores: `qd store new NAME [--path DIR]`, `ls`, `use NAME`,
  `rename OLD NEW`, `rm NAME [--delete]`.** A store qd makes lives in
  `~/.local/share/quarterdeck/stores/NAME` (`XDG_DATA_HOME`). The registry
  and the active store are kept in `~/.config/quarterdeck/config.json`
  (`XDG_CONFIG_HOME`), written whole and renamed into place.
  - `rename` moves a store qd made, and leaves one registered with `--path`
    where it is.
  - `rm` forgets a store; `--delete` also deletes its files, but never a
    directory that is not a provost store.
  - Both take provost's store lock (`stores.py`, `cli.py` `cmd_store`).
- **Every command's `--store` takes a store's name, or a directory as
  before.** Which store a command uses: `--store`, then `QD_STORE` (a name
  or a directory), then provost's explicit choice (`PROVOST_WORKSPACE`, or
  the controlled directory you are in), then the active store, then
  provost's default with a warning that no store is active (`stores.py`
  `choose`, `store.py` `default_root`).
- **provost's default store** (`PROVOST_HOME` or `~/.provost`) is registered
  as `default` once it exists, and made the active store if none is. A
  machine that used qd before keeps working without a step, and an `rm` of
  it sticks.
- **`qd store export [NAME] FILE`**: one gzipped tar holding the store whole,
  its git history and the raw answers under `captures/`, after a manifest:
  qd's and provost's versions, the store format, the run count, the
  capture count and a sha256 for every file. It takes provost's own store
  lock (`STORE/.lock` with an owner record provost reads). So it refuses
  while a run is filing, and no run starts filing until it is done.
- **`qd store import FILE [--as NAME]`**: checks the manifest, every checksum,
  that no file is missing or added, and that the store format is one this
  qd reads. It refuses a member outside the store, a link or a device. The
  store is unpacked beside where it will live, and renamed into place only
  once every check has passed. It refuses a name already taken, rather than
  merging.
- **`qd web` has a store picker** (`/api/stores`). Every API call takes
  `store=NAME`, a registered name only and never a path. With a store
  picked, the "same in a terminal" commands carry `--store NAME`
  (`web.py` `StoreApis`, `web/app.js`).

### Tests
- `tests/test_store.sh`, 8 cases: a fresh machine warns, then registers
  `default`; names work in every command, in the precedence above; a path
  still works; rename, rm and `--delete`; an export and import round trip
  (same runs, same git history, a clean tree); export refuses while a run's
  lock is held and leaves that lock alone; import refuses a tampered file,
  an escaping member, a newer store format and a non-archive, and leaves
  nothing behind. In `test_web.sh`, the picker's API.
- The test helper gives each case its own `XDG_CONFIG_HOME`,
  `XDG_DATA_HOME` and `PROVOST_HOME`, so no test reads or registers this
  machine's stores.

## 0.1.2 — 2026-10-30

### Changed
- **The probes named in one `qd probe` run together.** Each probe had run
  on every host in parallel, but the probes ran one after another, and each
  paid its own round of ssh, its own 8 s connect timeout on a host that is
  down (56 s for a dead host over `facts inventory`), and its own provost
  call and commit. Now every (probe, host) pair goes through one pool of
  `--jobs`, and every run is filed by one provost call, in one commit. Each
  probe is still a run of its own name. On six hosts, `qd probe facts
  inventory` went from 41 s to 26 s; of what is left, 23 s is provost
  reading the answers. With `--every` or `--count`, the probes still run one
  after another (`cli.py` `fleet_runs_together`, `cmd_probe`).
- **A binnacle probe (`facts`, `why-slow`, `skew`) is sent to `python3 -`
  over ssh's stdin**, as why-slow's own `--ssh` sends itself. It used to be
  pushed and run: mkdir, scp, chmod, the run and a cleanup, five
  connections per host where one does. Nothing is copied to a host or left
  on one (`fleet.py` `Runner._exec`, `run_one`).
- **A probe is matched with its own earlier runs by its name**, not by the
  command qd sent, which changes between versions (it just did, for the
  binnacle probes). So `qd diff facts` still compares today's run with
  yesterday's (`store.py` `previous_like`).

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
- `qd do` filed whatever was at a tool's output path. A run that failed
  before it wrote anything (an ssh error, exit 1) had the last run's
  `results/latest` filed under its own id. An output is now filed only if
  the run changed it, judged by comparing each file's size, mtime and
  inode before and after the run (no clock is consulted). `--import` still
  files what it names as it is (`cli.py` `written_mark`, `_do`). The
  follow-up `mx export` reads `reports/`, so it is not run when this run
  did not write them. Before, it filed the last run's numbers as
  `mx_export`.
- The floor-plan overlay (`qd floor`, `qd export --format overlay`, the
  web page's) wrote a size or a time as it was written: `512M` and `900ms`
  went to the viewer as values it could not read as numbers. A column's
  numbers now go over on its scale (bytes when sizes are mixed, seconds
  when times are), with its unit in the `!test` line. A plain number is
  still written as it was (`tools.py` `to_overlay`).
- A directory of grids (netmesh `--grid`: `rtt_p50_grid.csv`,
  `loss_grid.csv`, `mtu_grid.csv`, ...) was stacked like reports. Every grid
  reads as `src,dst,value`, so rtt, loss and mtu landed in one `value`
  column and its statistics mixed them. The grids are now joined: a row
  per pair, a column per grid, and blank where a grid has no value for
  that pair (`importers.py` `join_grids`).
- `qd view` crashed when an empty list was moved in, for example the
  counts of a column after a filter that matched nothing, then `j`. The
  cursor went to -1 (`explore.py` `ListView`).
- `r` (reload) in a view worked out from another one (grouped, a pivot,
  outliers, every column described) replaced it with the raw rows under
  the derived view's title. It now says to go back and reload there.
- `qd do -- agree ... -- why-slow --csv x` read why-slow's `--csv x` as
  agree's. That file is written on the far side, and qd added no `--csv`
  of its own, so the groups went unfiled. A tool's options now end at `--`.
  `agree script TOOL` with no `--` also gets the added `--csv` and
  `--merge-csv` (`tools.py` `opt`, `plan`).
- `QD_<TOOL>` overrides: the README's own example,
  `QD_MX="python3 ~/src/matrix_orchestrator/mx"`, could not run, because no
  shell expands the `~`. qd now expands it. A command that spells out how
  to run a tool (`python3 ./mx.py run`) was rewritten as well:
  `python3` was swapped for the override and the rest kept. Only a bare
  tool name is replaced now (`tools.py` `find_tool`, `cli.py`
  `resolve_argv`).
- A column's unit, in `qd stats` and on the web page, came from the
  `!test` lines or a guess from the column's name, never from its cells.
  `512M` beside `2G` was summarised in bytes and labelled as nothing.
  Both now read one function, which takes the scale of the figures
  first (`tools.py` `column_unit`).
- Two attribute values that clean to one name (`room=a/b`, `room=a:b`)
  were two groups with one name. `qd split --out` wrote both to one file
  and said it had written three lists, and campaign parts and doe blocks
  took each other's hosts. The second is now `room-a_b-2`, judged
  ignoring case, as a Mac's file system does (`split.py` `unique`).
- A host line with a space in an attribute value (a layout's
  `role=gpu server`, from manifest) was written as it was. Read back, the
  line held a second host, `server`, and qd would have sshed to it. The
  space is now written as `_` (`hosts.py` `Host.token`).
- `row=A` in a host file became the attribute `attr_row`, while a
  layout's `row` stayed `row`. So `qd split --by row` refused a host file
  ("no host has a 'row' attribute"), and the overlay's skip list missed
  it. `row` is no longer a reserved name; qd writes no column called that
  (`hosts.py` `RESERVED`).
- `qd do -- dcprobe scan` with no `-o` filed only dcprobe's summary line,
  not the `host_status.tsv` it writes by default. Each verb's default file
  is now read: `host_status.tsv` after `scan` and `watch`,
  `preflight.tsv` after `preflight` (`tools.py` `DCPROBE_OUT`).
- The web page worked out some figures itself, against the rule that it
  computes nothing: a value's share of the rows, how many agree on the
  most common value, the trend table's n, first, last, min and max, and
  the diff's keys-in-both. The API now gives each one: `top` entries
  carry their share, `agree` and `disagree`, each series a `summary`,
  and the diff `both` (`web.py`, `web/app.js`).
- The lists `qd split --out` writes keep each host's attributes, and
  agree reads every word on a line as a host. Handed a list, it would
  have sshed to a host called `rack`, at address `r1`. `qd split --plain`
  writes names only, as `qd hosts --plain` does, and the README says
  which tools need it (`split.py` `write_lists`).

- `qd run`'s cleanup ran `rm -rf` on `--remote-dir` itself, so
  `--remote-dir ~/bin` deleted that directory, and whatever was in it, on
  every host. Every run and every user also shared `/var/tmp/qd`, so the
  first of two runs to finish deleted the other's pushed files under it.
  Each run now makes a directory of its own, `--remote-dir/qd.<random>`,
  with `mkdir -m 700`, which refuses a path that is there already. Only
  that directory is removed, under `sudo` when the command ran under it,
  and `--remote-dir` is removed only if the run made it and it is empty.
  The default `--remote-dir` is now `/var/tmp`. A push that fails partway
  is cleaned up too, and a cleanup that fails is said in the host's
  stderr. `--keep-remote` says where it left the files (`fleet.py`
  `Runner.push`, `cleanup`).
- A host spec on the command line (`-s` when it is not a file, `-S`,
  `QD_SERVERS`) was split only on commas. So `-s 'web[1-2] rack=r1'` was
  a host called "web1 rack" at the address `r1`, and the command went to
  `r1`; `-S 'db1 role=primary'` went to `primary`. A spec now reads as a
  host file's line does, and a host token with a space in it is refused
  (`hosts.py` `collect_hosts`, `parse_host_token`).
- Two qd processes running the same command into one store in the same
  second chose the same run id, each before the other had filed, and were
  filed as one run holding both runs' hosts. A run id is now claimed with
  an atomic `mkdir` in qd's cache (never the store) before it is used
  (`cli.py` `new_run_id`, `claim_id`).
- `qd probe health` and `preflight` handed dcprobe a host list with the
  attributes stripped. dcprobe judges a NIC by the `gbps=`, `mtu=` and
  `nic=` on its host line, so a host whose NICs had all dropped to 10G
  passed. dcprobe now gets the attributes; `reachable` still gets names
  only (`tools.py` `READS_ATTRIBUTES`).
- `gpu` probe: a `nvidia-smi` that could not reach its driver came back
  `ok` (the pipeline's status was `sed`'s), and `[N/A]` was filed as a
  reading. Now it says `nvidia_smi: failed` with the error and exits 1,
  and a bracketed cell is blank.
- `packages` probe: a package tool that failed was counted as `packages:
  0`; now it says `packages_error: rpm failed`. On dpkg hosts
  `reboot_required: no` was written wherever `/var/run/reboot-required`
  was absent, including hosts with nothing installed that would ever
  write it. It is now said only where update-notifier is there to write
  it (`probes.py`).
- A host attribute named as a design factor (`mtu=9000` on the host, the
  factor `mtu`) overwrote the factor: the point run at 1500 was filed and
  shown as 9000. The attribute is now filed and shown as `attr_mtu`
  (`cli.py` `fleet_run`, `store.py` `Run._host_lead`).
- A host attribute named `port` doubled the ssh port's column
  (`host,addr,port,port`); it is now `attr_port`, as other reserved
  names are.
- An IPv6 host with a port was written to the run's hosts table as
  `fd00::1:2222`, which `split --answers` read back as another address
  on port 22. It is written `[fd00::1]:2222`, as a host line writes it.
- `qd do -- path/to/iperf_orchestrator.sh run` looked for results in
  `./results`. The script run as itself keeps them beside it (its
  `SCRIPT_DIR/results`; only the installed command uses `./results`), so
  nothing was filed. qd now looks where the script writes
  (`tools.py` `iperf_results_base`).
- On provost 2.1.0 (PyPI's, without `batch`), a double quote in a cell of
  a table `qd do`, `qd import` or a tool probe filed was lost:
  `PRETTY_NAME="Ubuntu 24.04"` came back without its quotes, because
  that provost's TSV reader drops them. A table with a quote in it is
  now filed as quoted CSV, which every provost reads whole
  (`filing.py` `table_tsv`).
- A file a tool appends to (`dcprobe --history`, `dcprobe scan
  --append`, `mx export --append`) was filed whole, so every run filed
  all the earlier runs' rows again as its own, and its statistics mixed
  them. qd notes the file's size before the run and files only the rows
  added since (`cli.py` `only_added`, `tools.py` `Plan.appends`).
- A command on a host that exited 124 itself (`timeout 5 check`) was
  reported as a qd timeout and listed as not answering. qd's own timeout
  is now marked as such (`fleet.py` `TimedOut`).

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
