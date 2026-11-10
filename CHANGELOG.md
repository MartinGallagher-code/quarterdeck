<!--
SPDX-License-Identifier: GPL-3.0-or-later
SPDX-FileCopyrightText: 2026 Martin J. Gallagher
-->

# Changelog

## 0.11.0 — 2026-11-10

`qd join`: a run's rows beside another system's telemetry (Splunk,
CloudVision, Prometheus, a gNMI collector), matched by host and time
window (QD-011).

Its pull request first took 0.9.0, then 0.10.0, but each reached `main`
first from another: 0.9.0 is QD-009's peer groups and baselines, 0.9.1
QD-023's `release.yml` change, and 0.10.0 QD-021's `qd report`. So this
is 0.11.0. Every version before it, QD-022's 0.10.1 included, still
keeps `ts` to the whole second.

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
  and skew, a real fan-out's windows, the pre-0.11.0 whole second,
  import against file, NDJSON at nanoseconds, a memory bound on a big
  export, and the mistakes.

### Changed
- **`qd.hosts` keeps each host's start (`ts`) to the millisecond**, not
  the whole second, so a host's window is exact. `qd show` of a run with
  several passes shows `ts` with three decimals. Runs filed before 0.11.0
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
