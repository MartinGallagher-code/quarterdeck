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
