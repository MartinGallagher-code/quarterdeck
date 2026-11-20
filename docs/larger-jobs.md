<!--
SPDX-License-Identifier: GPL-3.0-or-later
SPDX-FileCopyrightText: 2026 Martin J. Gallagher
-->

# Larger jobs: split, coverage, campaigns and experiments

A system in parts: `qd split`, `qd coverage`, `qd campaign` (pacing,
estimates) and designed experiments with `qd doe`. Part of
[the manual](README.md).

## Cutting a host list: `qd split`

```bash
qd split -s hosts.txt --by rack --out lists/     # lists/rack-r1.txt, rack-r2.txt, ...
qd run -s lists/rack-r1.txt -- ...
```

The lists keep each host's attributes, so qd and dcprobe read them as
they were. `--plain` writes names only, for agree, mx and
iperf_orchestrator, which would read `rack=r1` as a host.

| Flag | Lists |
|---|---|
| `--by ATTR` | one per value of an attribute (with `--layout`, the manifest's room, row, rack, slot) |
| `--into N` / `--deal N` | N shards in list order / dealt round-robin |
| `--size N` | waves of N, in list order |
| `--random N --seed S` | N groups at random; `--stratify rack` spreads every rack across them |
| `--ab` | two halves for an A/B comparison, stratified by rack when there is one |
| `--canary N` | the first N, then the rest |
| `--pairs`, `--pairs --ring` | two by two, or each host with the next all the way round |
| `--reachable` | up and down, as binnacle's `reachable` finds them |
| `--answers RUN` | by what each host said in a stored run: identical answers together, the way agree groups a fleet |

Every list keeps its hosts' attributes and is a host file the whole suite
reads. `--format csv` gives `group,host,...` instead.

---

## Which hosts have had it: `qd coverage`

```bash
qd coverage facts iperf burnin -s hosts.txt               # a host a row, a test a column
qd coverage facts iperf burnin -s hosts.txt --owed owed/  # and owed/NAME.txt: the hosts that owe it
qd run -s owed/burnin.txt --name burnin -- ./burnin.sh    # close the gap
qd coverage -s hosts.txt --since 2026-11-01               # covered this month?
```

A campaign keeps its own progress (`qd campaign status`). Ordinary runs
have none, so `qd coverage` answers "has every host had its facts, iperf
and burn-in, and which haven't?" across them. A test is a run's name
(`--name`, a probe's name, a campaign's). The hosts are the list `qd run`
would read (`-s`, `-S`, `--layout`, `QD_SERVERS` or a `hosts.txt`; naming
none is an error, not this machine). For each host and each name it shows
the host's latest answer in any run of that name, and the run it came
from:

| Shown | Counted as | Owed |
|---|---|---|
| `ok` | ok | no |
| `failed`, `timeout`, `push-failed` | failed | yes |
| `unreachable` | unreachable | yes |
| `never`: no run of that name reached the host | never | yes |

The head gives the counts per name: ok, failed, unreachable, never, and
how many hosts owe it.

- **Latest is by when the run started** (`created` in `qd.runs`, then
  the order the store filed them), never by id. Within a run, a host's
  last pass and last try count, as `--rerun` reads them.
- **A `not-run` row is not an answer.** A run stopped before it reached
  a host leaves the host as it was: its earlier answer, or never.
- **A host the runs saw that the list does not hold** is listed apart,
  under the grid, and is not counted.
- **With no NAME,** the eight names run most recently are shown, newest
  first, and the head says how many more there are. `--all` shows every
  one.
- **`--since DATE|RUN`** reads no run that started before it, so an old
  ok is never. A date is `YYYY-MM-DD` (UTC midnight) or
  `YYYY-MM-DDTHH:MM`, UTC. A run (`latest~3`, an id, a name) counts
  itself and what came after.
- **`--owed DIR`** writes `DIR/NAME.txt` for each name shown. It holds
  the hosts that owe the test (never, or not ok) with the attributes the
  list gave them, in the list's order: a host list `qd run -s`, `qd
  probe -s` and the rest of the suite read. A name nothing is owed for
  gets a file with no hosts, so an older list is never left standing.
- **A name the store has no run of** is shown with every host never, and
  qd says so on stderr. A name whose runs are not on the fleet (`qd do`,
  `qd import`) has no host rows and is refused. An empty store with no
  NAME has nothing to show (exit 2).
- `--format csv|tsv|json|ndjson|md` gives the table behind it, a row per
  host and name: `host, name, status, counted, owed, run, when, listed`.
  `when` is when the host's answer started, in UTC. The hosts outside the
  list come last, `listed` no and `owed` blank.

The exit status is 1 when any host in the list owes any name shown (a
finding), 0 when none does, and 2 for a usage error. It reads only
`qd.runs` and `qd.hosts`, never the answers.

---

## A system in parts: `qd campaign`

```bash
qd campaign new burnin -s hosts.txt --by rack -- ./burnin.sh --minutes 30
qd campaign run burnin              # every rack in turn; Ctrl-C and come back later
qd campaign run burnin --parts 2    # or two racks now
qd campaign status burnin           # PROGRESS 5 of 12 parts done, and how each went
qd campaign retry burnin            # the racks that had a host fail, back in the pool
qd compare --group burnin -c temp_c # the racks side by side
```

A campaign is a command and a host list cut into parts, any way `qd split`
cuts one. Which parts are done is binnacle's
[`muster`](https://binnacle.readthedocs.io/en/latest/tools/muster.html) to
keep: its pool hands each part out once, under a lease, so a second
terminal running the same campaign takes the next rack rather than the
same one, and a part whose worker died comes back when its lease runs out.
`muster status --pool ...` reads the same progress. What each part found is
provost's: a part is a run named after the campaign, its campaign and part
on every row. The definition is filed too (`qd.campaigns`), and the pool
can live anywhere every worker can read (`--pool`).

### Pacing: power domains, a ramp, maintenance windows

A burn-in that loads every node on one PDU at once can trip its breaker.
`campaign new` keeps three limits with the campaign, so every `campaign
run` -- resumed, or carried on from another machine -- paces the same:

```bash
qd campaign new burnin -s hosts.txt --by rack --max-per pdu=4 \
    --ramp 6/min --window "Mon-Fri 18:00-06:00" --window "Sat,Sun 00:00-24:00" \
    -- ./burnin.sh --minutes 30
qd campaign status burnin   # at most 4 per pdu; ramp 6/min; windows ... (closed; the next opens Mon 18:00)
```

- **`--max-per ATTR=N`** (repeatable, or `pdu=4,rack=8`): no more than N
  hosts sharing a value of ATTR run at once. ATTR is any host attribute
  in the host list (`node07 pdu=p3 rack=r2`), the same ones `--by` reads.
  Hosts without it share one count rather than going unlimited. Other
  values go past a full one, so a cap holds a PDU back without holding
  the fleet back.
- **`--ramp RATE`** (`6/min`, `1/s`, `120/h`): host starts are spaced
  evenly, so the draw rises in steps. The spacing carries on from one
  part to the next.
- **`--window SPEC`** (repeatable, `;` between several): `[DAYS]
  HH:MM-HH:MM` in local time, days as `Mon-Fri` or `Sat,Sun`, a span past
  midnight belonging to the day it starts (`Fri 18:00-06:00` runs into
  Saturday morning), no days for every day. `campaign run` starts a part
  only inside a window; outside one it starts nothing, says when the next
  opens, and exits 0. A part already running finishes.
- **`--max-watts [ATTR=]W`** (repeatable, or `pdu=7200,rack=12kW`): a
  power budget. No more than W watts are drawn at once by the hosts that
  share a value of ATTR, or by all of them with no ATTR (`--max-watts
  30000`). A host's draw is its `watts` attribute in the host list
  (`node07 pdu=p3 watts=450`), else **`--watts W`**. A host with neither
  is refused before anything starts (an unknown draw is not zero), and
  so is a host that draws more than a budget it falls under, since it
  could never start. A host with no ATTR shares one budget with the
  others that lack it, as under `--max-per`.
- Flags given to `campaign run` override the kept ones for that run.

The caps, the power budget and the ramp hold within one worker. Two terminals running one
campaign each keep their own count; muster still gives them different
parts.

### How long it will take: `qd campaign estimate`

```bash
qd campaign estimate burnin                       # wall time, windows, the load on the fleet
qd campaign estimate burnin --workers 2 --start 2026-11-20T18:00
qd campaign estimate burnin --assume 1800 --json  # where nothing has run it yet
qd campaign run burnin --dry-run                  # the same figures first, then each part
```

Before a campaign starts, `estimate` works out how long it will take
from what the store already holds and the campaign's own pacing:

- **Each host's duration** is the median `duration_s` of its own earlier
  runs of the campaign's command, or of runs named after the campaign (its
  parts, a probe of that name), counting only hosts that answered ok.
  Without any, it is the median over every host that ran it, then
  `--assume SECONDS`. The table names the source for each part (`same
  hosts`, `fleet`, `assumed`) and how many values it rests on. A part
  none of them covers is **unknown**: the wall time is then unknown, never
  zero, and the exit status is 1.
- **The scheduler** is the one `campaign run` uses: `pacing.Gate` with the
  campaign's `--max-per` caps, power budget and ramp, `--jobs` hosts at
  a time. With `--workers N` (1 by default), N workers take parts as
  muster hands them out, each with its own caps, as real workers do.
- **The windows** gate when a part starts, as in a run. A part started
  inside a window runs to its end, and the estimate says by how much it
  overruns the close. A run stops when its window closes, and the
  estimate assumes `campaign run` is started again when the next window
  opens.
- **The result**: the wall time, with a p10-p90 spread from each host's
  own p10 and p90; the windows it takes, with when each opens and closes;
  the most hosts running at once per capped attribute, and the most
  watts per power budget, against what is allowed. `--json` gives the
  same figures. `--start` sets the start time (now by default).

`campaign run --dry-run` prints the same summary, as `#` lines, above
what each part would run.

Two workers filing into one store at the same moment rely on provost's
store lock, and that lock is `mkdir`. Where `mkdir --version` says uutils
coreutils before 0.11.0 (the default on Ubuntu 25.10 and 26.04), two
provost processes can both take it, and a part's answers can be lost. On
such a machine, run one worker per store, or switch the machine to GNU's
`mkdir` (Ubuntu's `coreutils-from-gnu`).

---

## Designed experiments: `qd doe`

```bash
qd doe plan iperf.json                      # the design doe makes: points, blocks, levels
qd doe run iperf.json -s hosts.txt -- 'iperf3 -c peer -P {streams} -w {window}'
qd doe status iperf                         # which points are measured
qd doe analyze iperf -c mbps                # doe's main effects, interactions, ANOVA, power
qd doe analyze iperf -c mbps --optimize     # and its recommended settings
qd doe analyze iperf -c mbps --report       # and keep doe's plots and HTML report
qd doe init fio                             # a starting config: a screen of fio's settings
qd doe next fio-screen -c read_iops         # a CCD/Box-Behnken follow-up on its big factors
qd doe run fio-screen-read-iops-ccd.json --like fio-screen   # where the screen ran
qd doe surface fio-screen-read-iops-ccd      # doe's response surface: where the best is
```

The design is
[design_of_experiments](https://github.com/MartinGallagher-code/design_of_experiments)'
(`doe`, `pip install doehelper`): its config names the factors and their
levels and the design (full or fractional factorial, Plackett-Burman,
Latin hypercube, central composite, Box-Behnken, ...), and its generator
lays out the points. qd runs each point on the fleet with every `{factor}`
in the command replaced by that point's level, and files it as a run named
after the design, the factors on every row. `--blocks-by rack` runs the
design's blocks on different racks. A point already measured is not run
again (an interrupted design carries on), and `--count N` measures each
point N times. `qd doe analyze` reduces each point to one response (the
median of the column over the hosts that answered, or `--agg`), writes it
as doe reads results (`run_<id>.json` beside the design's
`design_matrix.json`) and runs `doe analyze`. doe wants Python 3.10 and
numpy; qd runs it as a command, so qd keeps its 3.6 floor.

`-c` takes several columns (`-c mbps,retrans`), or a response of the
config by its name, and with no `-c` qd analyses every response of the
config that names its `column`. They go to doe in one go: each point's
responses are one `run_<id>.json`, and a response a point did not
measure (its hosts failed, or the column is not there) is no key in it
at all, so doe leaves that point out of that response. Blank, never 0.
After the responses per point, qd ranks doe's main effects for each
response (doe's `--csv` tables): the **big** factors are those inside
doe's own 80% Pareto line, each with the level that maximises (or, for a
response the config says to minimise, minimises) it, then the rest.

A config can carry the command its points run (`metadata.qd_command`),
so `qd doe run CONFIG -s hosts.txt` needs nothing after `--`, and what
the design holds still goes in doe's `fixed_factors`, put into the
command by `{name}` like a factor. A design run again with another
command or other fixed factors is refused: `--name` a new one. A point
whose every run failed on every host has measured nothing, and `qd doe
run` runs it again; `--redo` runs every point again.

**Seeing the effects.** `--report` lets doe make its plots (Pareto, main
effects, half-normal, response surfaces where it fits one) and its HTML
report, and keeps them with the results and config that made them: in
qd's cache (`~/.cache/quarterdeck/doe/`, never the store) unless you
name a directory (`--report out/`, new or empty, or one qd made before,
which it empties first). qd says where the report is. A design's page in
`qd web` charts the same column: a Pareto of effect sizes, a main-effects
chart per factor (the mean response at each level, on one scale) and an
interaction chart for any two factors (a line per level of the second;
lines that are not parallel are an interaction), with a picker for the
column and for how each point is reduced over its hosts. The figures are
plain means of the points measured, worked out by qd's engine; a point
not measured is left out of every mean and shows as a gap, never as
zero. Significance, ANOVA and the fitted models are doe's: its report
is linked from the page once `--report` has kept one in the cache.

### A screen of fio's parameters: `qd doe init fio`

Which of fio's settings matter for one drive (QD-067, the first step of
a tuning study: a central composite or Box-Behnken follow-up on the few
that matter comes after, with `qd doe next`, below):

```bash
qd doe init fio                              # writes fio-screen.json
$EDITOR fio-screen.json                      # fixed_factors.filename: a file on the drive
qd doe plan fio-screen.json                  # the 8 points doe lays out
echo db07 > host.txt                         # one host
qd doe run fio-screen.json -s host.txt       # about 10 minutes: 8 x (60 s + 10 s ramp)
qd doe analyze fio-screen                    # what moves each response
```

A point runs past qd's 60 s default `--timeout`, so the config's
`metadata.qd_timeout` (180) raises it for `qd doe run`, which says so. A
longer `--timeout` given is kept.

`fio-screen.json` is a Plackett-Burman design of seven fio parameters at
two levels each, eight points. It is a **proposal, for the owner to
approve or change before the first real run**; the reason for each
factor is its `description` in the file:

| Factor | Low / high | Why it is in the screen |
|---|---|---|
| `bs` | 4k / 128k | 4k is the small random I/O IOPS is quoted for, 128k the large I/O streaming work issues; it trades IOPS for bandwidth more than any other setting |
| `iodepth` | 1 / 32 | I/Os each job keeps in flight: 1 is latency-bound, 32 fills a SATA/SAS queue and goes a long way towards an NVMe drive's |
| `numjobs` | 1 / 8 | parallelism on the host side, which iodepth alone does not give an NVMe drive's many queues; 8 stays under a server's core count |
| `rwmixread` | 30 / 70 | the share of reads, kept off 0 and 100 so every point does both and every response is measured at every point (fio reports 0 for a direction that did no I/O, which would read as a measurement) |
| `rw` | `rw` / `randrw` | sequential or random, both mixed so `rwmixread` applies everywhere |
| `ioengine` | `libaio` / `io_uring` | both asynchronous, so iodepth means the same at both (a synchronous engine such as `psync` ignores it); io_uring needs Linux 5.1+ and a fio built with it (`fio --enghelp`) |
| `direct` | 0 / 1 | through the page cache, or around it (`O_DIRECT`): what most applications get, or what the drive does |

Held fixed (`fixed_factors`): the file, `size` 8G, `runtime` 60 s with
`time_based`, `ramp_time` 10 s; `--group_reporting` (one result for all
of a point's jobs) and `--output-format=json`, which provost parses into
columns. The command, `metadata.qd_command` in the file:

```
fio --name=qd-screen --filename={filename} --size={size} --time_based
    --runtime={runtime} --ramp_time={ramp_time} --group_reporting
    --output-format=json --rw={rw} --rwmixread={rwmixread} --bs={bs}k
    --iodepth={iodepth} --numjobs={numjobs} --ioengine={ioengine}
    --direct={direct}
```

The responses are read from those columns (the same with PyPI's provost
2.1.0 as with today's):

| Response | Column | |
|---|---|---|
| `read_iops`, `write_iops` | `jobs.0.read.iops`, `jobs.0.write.iops` | maximise |
| `read_bw`, `write_bw` | `jobs.0.read.bw_bytes`, `jobs.0.write.bw_bytes` (B/s) | maximise |
| `read_lat_mean`, `write_lat_mean` | `jobs.0.read.clat_ns.mean`, `jobs.0.write.clat_ns.mean` (ns) | minimise |
| `read_lat_p99`, `write_lat_p99` | `jobs.0.read.clat_ns.percentile.99.000000`, and write's (ns) | minimise |

The response to optimise is not chosen in advance: the screen ranks the
factors for all eight, and that ranking is what the follow-up's response
is chosen from. `qd doe analyze fio-screen -c read_iops,read_lat_p99`
analyses only some.

```
  what moves each response: doe's main effects as shares, largest first;
  big: inside doe's 80% Pareto line, with the level that is best for it
  read_iops       big: iodepth 67% (max 32), bs 33% (max 4)
                  then: numjobs 0%, rwmixread 0%, rw 0%, ioengine 0%, direct 0%
  write_iops      big: numjobs 71% (max 8), rwmixread 29% (max 30)
                  then: bs 0%, iodepth 0%, rw 0%, ioengine 0%, direct 0%
  read_lat_p99    big: rw 71% (min rw), ioengine 29% (min io_uring)
  ...
```

Read it knowing what a screen is:

- **Eight points for seven factors leaves nothing over**: no estimate of
  noise, so every point counts. A point that failed (fio exits non-zero;
  qd files its JSON, zeros and all, beside a status that is not ok) is
  left out of every response, never counted as 0, but one lost point of
  eight biases every effect: run `qd doe run` again, and only the failed
  points are measured again, before analysing.
- **A main effect here may be an interaction**: Plackett-Burman's main
  effects are partly aliased with two-factor interactions (doe prints the
  alias structure). `libaio` is only asynchronous with `direct=1`, and
  bandwidth is IOPS times block size: interactions a screen cannot pull
  apart from the main effects. The follow-up design can.
- **`rw`, `ioengine` and `direct` are categorical.** A central composite
  or Box-Behnken follow-up cannot vary them; it holds each at its better
  level.
- **`direct=0` measures the page cache** as much as the drive, once the
  file fits in memory; 8G is a starting size, not a rule. Make it larger
  than the host's memory if buffered I/O should reach the drive.
- **fio writes the file**; it writes nothing else. Setting `filename` to a
  device (`/dev/nvme0n1`) writes the raw device and destroys what is on
  it: the typo guard refuses any fio command with a `/dev/` filename and
  a writing `--rw` unless `--yes` is given, in `qd doe run` as in `qd
  run`.
- A config made by `qd doe init` is yours: edit levels, drop a factor,
  add one (doe sizes the Plackett-Burman design to the factor count; 8
  to 11 factors make 12 points), then `qd doe plan` it again.

### The follow-up: `qd doe next` and `qd doe run --like`

Once the screen has ranked the factors, a central composite or
Box-Behnken design on the few that matter finds the shape of the
response between their levels (QD-069, steps 3 and 4 of a tuning study):

```bash
qd doe next fio-screen -c read_iops          # writes fio-screen-read-iops-ccd.json
qd doe plan fio-screen-read-iops-ccd.json    # the 16 points doe lays out
qd doe run fio-screen-read-iops-ccd.json --like fio-screen
qd doe status fio-screen-read-iops-ccd       # its study: fio-screen
```

`qd doe next SCREEN -c RESPONSE` is for one response, chosen from what
`qd doe analyze` showed. It analyses the screen for it (doe's main
effects, as `analyze` ranks them) and writes the follow-up's config:

- **Which factors are varied.** The big ones, inside doe's 80% Pareto
  line, that are numbers, at most four. A surface over one factor has no
  shape to show, so when only one big factor is numeric, the next numeric
  factor that moved the response at all is added, and said.
  `--factors A,B,C` chooses them instead.
- **Categorical factors are never varied** (`rw`, `ioengine`, `direct`
  in the fio screen): a central composite or Box-Behnken varies a number
  between two levels. A big categorical factor, or one named in
  `--factors`, is held at its better level, with a line saying so. When
  nothing numeric moved the response (the fio screen's read p99, moved
  by `rw` and `ioengine` alone), there is nothing to fit a surface over,
  and qd says that and writes nothing.
- **Everything not varied is held** (doe's `fixed_factors`): at the
  level the screen found better for this response (maximised or
  minimised, as the config says), or, where the screen saw it move
  nothing, at its first level, and the table says which. What the screen
  held (the file, size, run time) is held as it was.
- **The design is doe's choice**: `doe suggest --goal response_surface`
  for that many numeric factors and `--budget` runs (30 by default, room
  for a central composite on two factors and a Box-Behnken on three or
  four). What doe suggests, and why, is shown; the point count is the one
  `doe generate` lays out (a central composite on two factors is 16
  points, eight of them centre points; a Box-Behnken on three is 15). If
  doe suggests something else for a small budget, qd says so and writes
  nothing.
- **The levels are the screen's own range**, not re-centred on the
  screen's best corner: the follow-up measures the region the screen
  measured, with middle levels. Moving the region is a judgement, so it
  is yours: edit the levels in the config, and `qd doe plan` it again.
  Box-Behnken puts a middle level at the mean of the two (1 and 32 make
  16.5), which a count such as `iodepth` or `numjobs` cannot take; qd
  warns, and making the two levels sum to an even number (2 and 32)
  fixes it. (doe's central composite rounds whole-number factors; its
  Box-Behnken does not.)
- The config keeps the screen's command and responses, and names the
  study it belongs to (`metadata.qd_study`, the screen's own name or its
  study) and what it follows (`metadata.qd_follows`). `-o FILE` names
  the file; one that is there already is not written over.

`qd doe run CONFIG --like SCREEN` runs the follow-up on exactly the hosts
the screen's points ran on, with their addresses and attributes, and
says so. It takes no `-s`, `-S`, `--layout` or `--rerun`: `--like` is
the host list. It holds what the screen held: a fixed factor the config
leaves out is taken from the screen, and one the config sets otherwise
(another `filename`, another drive) is refused. With no command after
`--` and none in the config, the screen's is used; another command is
run but warned about. A host the screen ran on that answers at none of
the follow-up's points is named at the end (`b answered at none of the
16 points run here (b unreachable) -- fio-screen ran there; has it
gone?`), and the run exits 1: its points there are not measured, never
skipped in silence. `qd doe status` shows the study a follow-up belongs
to.

### The response surface: `qd doe surface`

Once the follow-up is measured, doe fits a response surface to it and
finds where the best settings are (QD-071, step 6 of a tuning study):

```bash
qd doe surface fio-screen-read-iops-ccd                 # the follow-up's own response
qd doe surface fio-screen-read-iops-ccd -c read_lat_p99 # another one
qd doe surface fio-screen-read-iops-ccd --report        # and keep doe's surface plots
```

For a central composite on `iodepth` (4 to 36) and `numjobs` (1 to 9),
with the test suite's stand-in fio, whose read IOPS peaks at iodepth 24
and 6 jobs, the real doe gives:

```
qd doe surface -- ccd: read_iops (jobs.0.read.iops, maximise), 16 of 16 points measured
  model      doe's quadratic fit, each factor coded -1 to +1 over its levels:
             read_iops = 87697 + 6393 iodepth + 12023 numjobs + 15
             iodepth*numjobs - 12814 iodepth^2 - 23984 numjobs^2
  fit        quadratic: R2 1.0000; adjusted 1.0000; predicted 1.0000; lack of
             fit p=1.0000 (none detected)
  stationary a maximum, inside the design region: read_iops = 90002, give or
             take 56.35 (doe's cross-validated error; it gives no prediction
             interval)
    factor   stationary  coded   best inside  coded
    iodepth     23.9938  +0.250      23.9938  +0.250
    numjobs     6.00292  +0.251      6.00292  +0.251
  best       inside the design region (doe optimize): read_iops = 90002 at
             iodepth=23.9938 numjobs=6.00292
  so         the maximum is inside the design region: confirm it with a run at
             these settings
```

Every statistic is doe's. qd hands it the points' responses as `qd doe
analyze` does (blank, never 0, for a point not measured) and reads back
what doe found:

- **The model** is doe optimize's: the quadratic (or, with too few points
  for one, linear) polynomial it fitted, in doe's coding, each factor -1
  at its low level and +1 at its high one. doe prints the coefficients to
  four decimals.
- **The fit**: R², adjusted and predicted R² (doe's model adequacy), and
  the lack-of-fit test of doe's ANOVA where the design repeats points
  (its centre points). A small p means the model misses structure.
- **The stationary point**, where the surface is flat: what kind it is
  (a maximum, a minimum, a saddle, or a ridge, from the signs of doe's
  eigenvalues), where it is, in each factor's units and coded, whether
  it lies inside the design region (every factor between its two
  levels), and doe's predicted response there. doe gives no prediction
  interval; its cross-validated error (RMSE) is shown as how far off a
  prediction typically is.
- **The best point inside the region**, doe optimize's search of the
  fitted surface within the levels.
- **What it means**, said plainly. The optimum is *inside* when the
  stationary point is the kind wanted (a maximum for a response to
  maximise, a minimum for one to minimise) and lies inside the region:
  confirm it with a run there. It is *on the edge* when the best point
  inside the region sits at a factor's low or high level (`the best
  point inside the design region is on its edge (iodepth at its high
  level)`): the optimum is beyond the region, and another round, moved
  that way, is needed. Moving the region is still yours to do (edit the
  levels in the config); qd running the rounds itself is QD-072.

A count such as `iodepth` or `numjobs` takes whole numbers; doe rounds a
factor whose config says `"dtype": "int"`, and reports any other to six
figures.

`-c` takes one response, by name or column; with none, a follow-up's own
response (`metadata.qd_follows`), or the config's only one. `--agg`
reduces each point over its hosts as `analyze` does. `--report [DIR]`
keeps doe's report and plots as `qd doe analyze --report` does, its
response-surface plots (`rsm_RESPONSE_A_vs_B.png`, one per pair of
factors) among them, where `qd web` links them. `--json` prints the
figures, and the contours `qd web` draws, as JSON.

**In `qd web`**, a central composite or Box-Behnken design's page has a
"Response surface" card for the column it shows (any other design has a
button to fit one anyway): the same figures and verdict, and a contour
chart for each pair of numeric factors, picked from a list when there
are more than two. The contours are doe's fitted model evaluated by qd's
engine on a 25 by 25 grid over the design region (and its star points),
the other factors held at doe's best point; the engine also places the
contour levels and lines, so the page draws and computes nothing. The
dashed box is the design region, dots are the design's points (hollow
where a point is not measured), + is the stationary point and the
diamond the best point inside the region.

### A study, every run of it: `qd compare --study` and `qd web`

The screen, its follow-up and every later round are one **study** (QD-070,
step 5 of a tuning study). Their designs have different factors and
different points, so `qd compare --group` (one design's points) and
`--campaigns A B` (two designs, key by key) do not line them up; a study
does:

```bash
qd doe status fio-screen                       # the screen's points, then every design of its study
qd compare --study fio-screen                  # every run of every design, a row per run and host
qd compare --study fio-screen -c read_iops --sort -read_iops
qd compare --study fio-screen --where 'iodepth>=16' --format csv
qd web                                         # Studies: the same table, sortable and filterable, and a chart
```

- **Which designs.** A design is in the study its config names
  (`metadata.qd_study`, which `qd doe next` writes and `qd doe run --like`
  fills in), and a design that names none starts a study of its own name,
  so a screen's study is called what the screen is called. Nothing new is
  filed for it: a store written before studies existed reads as one study
  per design. `qd doe status SCREEN` lists the study's designs under the
  screen's own points once there are two; `qd doe status STUDY` for a
  study named for no design lists its designs alone.
- **The rows.** One per run and host: the design, the point, the host,
  then each response (`-c COL,COL`, a column or a config's response by
  name; by default every response the configs name a column for), then
  every factor, then the host's status and the run. A response is one
  number from that host's rows that are ok (the median, or `--agg`), on
  its family's base scale as `qd doe analyze` reads it. Every run is
  there once, a point measured again (`--redo`) as a second row.
- **The factors.** A factor is a column when any design varied it, or
  the designs held it at different levels. On a design's row it is the
  point's level where the design varied it and the level the design held
  where it did not (the follow-up's `rw=rw`, which the screen varied). A
  factor every design held at one level (the file, the size) is said
  once above the table, not repeated. A factor a design neither varied
  nor held is blank on its rows, and said.
- **Blank is not measured.** A host that failed a point has no response
  on its row, never 0, and its status says why.
- `--where` and `--sort` work as in `qd show`; `--format csv` gives every
  column for a spreadsheet. `--group`, `--last`, `--baseline`, `--peers`,
  `--key` and `--table` do not go with `--study`.

In `qd web` a study of two designs or more is listed above the campaigns
and designs. Its page lists the designs (what each varies and holds, how
far it got, what it follows), then every run in one table, sorted by a
click on a column's heading and filtered by the bar above it, a held
factor's level in grey italics; a row opens its run. Above the table, a
chart of a response against a factor (by default the factor the latest
design varied first), each design a colour: a dot per run and host, and
a line through the design's median at each level. The server works out
the rows, their order, the filter, the points and the medians
(`/api/study`), with the same code as `qd compare --study`.
