<!--
SPDX-License-Identifier: GPL-3.0-or-later
SPDX-FileCopyrightText: 2026 Martin J. Gallagher
-->

# Over time: many runs, peers and baselines

Runs side by side (`qd compare`, `qd changes`), and the hosts and runs a
result should agree with (`qd peers`, `qd baseline`). Part of
[the manual](README.md).

## Many runs side by side: `qd compare`

```bash
qd compare facts -c cpu.busy_pct --last 5        # the last five runs of facts
qd compare monday tuesday latest -c mbps         # these three
qd compare --group burnin -c temp_c              # a campaign's parts, a design's points
qd compare --campaigns burnin-oct burnin-nov     # two whole campaigns, host by host
qd compare kernel --last 10                      # no column: every numeric median
```

One row per run (hosts that answered, n, median, mean, min, p95, max, and
the change from the baseline), then host by host every run's value side by
side, flagged where a median moved more than `--drift` percent (5) from the
baseline or the host's status was not ok. The baseline is the first run, or
`--baseline RUN`, or a qualified baseline's name (`--baseline NAME`, next
section), which adds a significance test. `--peers NAME` with `-c` adds a
row per peer group: its median in each run, flagged where it moved past
`--drift`; `--format csv` is then that table. Runs over different hosts (a
campaign's parts) are compared as wholes. With no column, every numeric column the runs share is
compared by its median, leaving out what the runs *were* rather than what
they measured: a design's factors and the hosts' attributes. `--format csv`
is the host-by-run table. The exit status is 1 when anything changed, as
with `diff`. `qd web` shows the same comparison on its Compare tab. Runs
from other stores go in as `RUN@STORE` (see *Runs from different stores
side by side*); `--last N@STORE` takes the last N from that store.

### Two whole campaigns: `qd compare --campaigns A B`

```bash
qd compare --campaigns burnin-oct burnin-nov            # every column, host by host
qd compare --campaigns burnin-oct burnin-nov -c mbps --drift 3
qd compare --campaigns burnin-oct burnin-nov --format csv -o both.csv
```

`--group` lines up one campaign's parts, and `--baseline` holds runs
against one run. `--campaigns A B` takes two whole campaigns (or designs)
and puts them side by side (QD-036):

- **Each side** is every part of its campaign, the latest run of each
  part (a part run again after `campaign retry` counts once, as it now
  stands), stacked into one table. `--where` and `--table` apply to every
  run.
- **Key by key** (the host, or `test,target` for viewer results, as `qd
  compare` and `qd diff` match them; `--key` to choose), each numeric
  column's value in A and in B and the change. The value is a key's
  median (`--agg`), computed by the same function `qd compare` uses, so
  the two cannot disagree. With `-c`, only that column.
- **Flagged**: a change past `--drift` percent (5); a host in only one
  campaign (`only in A`, `only in B`); a value measured in one campaign
  and blank in the other. The text lists the flagged rows (`--limit`,
  30; 0 for all), then counts the hosts, tests and numeric columns that
  are in only one campaign.
- `--format csv`, `tsv`, `json`, `ndjson`, `md`: every key and column,
  `host,column,A,B,change_pct,flags`.

The exit status is 1 when anything moved, or is in only one campaign; 0
when they agree, as a campaign compared with itself does. `--baseline`,
`--group`, `--last` and `--peers` do not go with `--campaigns`.

### Where a slow slide started: `qd changes`

```bash
qd changes iperf -c mbps                         # every run of iperf so far
qd changes iperf -c mbps --last 60 --higher-is-better
qd changes iperf -c mbps --peers sku             # one series per peer group
qd changes --group burnin -c temp_c --format csv
```

`compare` holds runs against a fixed reference. A node whose bandwidth
slips 2% a month never crosses a 5% drift from last week's run, and a
baseline set last quarter shows the gap but not when it opened.
`qd changes` finds *where* in a series each host's level moved -- "between
run 14 and run 15" -- so it can be lined up with whatever changed then (a
firmware update, a facts run: `qd diff` the two runs either side).

It takes the runs `compare` would (one `RUN` means every run like it up to
that one, `--last N` the last N, `--group` a campaign's or a design's), and
reduces each the same way: a host's rows in a run to their median
(`--agg`), and with `--peers NAME` a peer group to the median of its hosts.
Each host (or group) then has one value per run, and a run where it was
not measured is **left out of its series**, never counted as zero, and
named. Fewer than five measured runs says **too few runs**, not "no
change".

The statistic is **e-divisive means** (Matteson and James, 2014) with a
permutation test, as MongoDB runs it on its performance CI (Daly et al.,
ICPE 2020; their `signal-processing-algorithms` 2.1.6, ported in the
standard library, its own published test values reproduced in
`tests/changes_unit.py`). Every split of a stretch is scored by how far
apart the two sides' values are against how far apart each side's are
among themselves; the best split is a change point when no more than `--p`
(0.05) of `--permutations` (100) shuffles of that stretch score as high;
then the stretches either side are searched again. The shuffles come from
Python's own `random` with a fixed seed, so the same runs always give the
same answer, on Python 3.6 as on 3.13. With no change at all, about one
series in sixteen shows a change point by chance (p 0.05 over 100
permutations is at most 5 of 101); the tests hold it there.

What it reports, for each host:

| | |
|---|---|
| **changes** | each step between stable stretches, by the run ids either side, with the median before and after, the step in percent of the level before, and in MADs (of the noisier stretch either side). A step smaller than `--min-change` percent (1, `QD_MIN_CHANGE`) is listed in the CSV but not reported. |
| **stretches** | (`--format csv` or `json`, one row each) the first and last run, the count, median and MAD |
| **slides** | asv's rule: the gap from the best stretch to the latest, and every step that explains it -- so a slide made of steps each under the floor is still reported once they add up past it. "Best" needs `--higher-is-better` or `--lower-is-better`; without, it is the stretch farthest from the latest. |
| **outliers** | a run that jumps and comes straight back is not a step (Conbench's rule): a stretch of one run between two is dropped and the run named, and so is one run alone at either end |
| **gaps** | the runs a host was not measured in |

With a direction a step is a **regression** or an **improvement**;
without, it **rose** or **fell**. The exit status is 1 when anything
changed (with a direction, a regression) or slid, as with `compare`.

**Lag.** The newest run can never be a change point by itself (one run is
an outlier until a second agrees), so a change shows a run or two after it
happens. That is the price of not crying wolf at every slow run.

**Speed.** On an Apple M4, one host's series of 100 runs takes 0.02 to
0.08 s (Python 3.9; half that on 3.13), and 500 runs 0.1 s with no change,
0.3 s with one and 0.5 s with three, so a thousand hosts of 500 runs is a
few minutes. (`tests/changes_unit.py` holds 100 runs under a second.)

The statistic is qd's for the same reason the Mann-Whitney test is
(*Peer groups and qualified baselines*, below): design_of_experiments needs numpy, scipy and Python 3.9.
Not yet: marking a change point as understood, and saying which facts
changed at it.

---

## Peer groups and qualified baselines: `qd peers`, `qd baseline`

A drift threshold says a host moved 5%. It cannot say whether 3% is a
real slide or a run that happened to be slow, and it says nothing until
the 5% is crossed. Two things kept in the store answer that: **peer
groups**, the hosts that ought to measure alike, and **qualified
baselines**, what those groups measured on runs someone vouched for.

```bash
qd peers define sku --by sku                     # a row's group is its sku column
qd peers define pods --from pods.tsv             # host and group, from a file
qd peers define hw --facts kernel,bios           # each host's kernel and BIOS, from the latest facts run
qd peers ls                                      # qd peers show NAME [RUN], qd peers rm NAME --yes

qd stats latest mbps --peers sku                 # centre and spread, group by group
qd outliers latest mbps --peers sku              # each host against its own peers

qd baseline set gold iperf --last 5 --peers sku -c mbps --note "after the BIOS update"
qd baseline show gold                            # what it holds, run by run; qd baseline ls, rm
qd compare iperf --last 5 --baseline gold        # later runs against it
```

**A peer group** is one of two kinds. `--by COLS` is a rule: a row's group
is its value of those columns (a host attribute like `rack` or `sku`, which
qd puts on every row), in whatever is read. `--from FILE` (a `host` and a
`group` column, or two words a line) and `--facts COLS` are lists, frozen
when defined: `--facts kernel,bios` reads each host's values from the
latest `facts` run (`--run RUN` reads another), so the groups are what the
hosts actually are, and a later facts run moves nobody until the group is
defined again. A blank in a `by` column, a blank fact, or a host the list
does not name is in no group, and is said to be left out: not measured is
not a group of its own. `--replace` files a new definition over an old
one; the old one stays in the store's history.

`qd stats --peers NAME` groups by the peer group first (before any
`--by`). `qd outliers --peers NAME` holds each host against its own group's
median and spread rather than the fleet's, so a host that is ordinary
fleet-wide but far from its own SKU is found, and one that only looks odd
because its SKU is different is not.

### The odd one out by value: `qd outliers --categorical`

A firmware version, a driver, an offload left on, an MTU: these are not
far from a median, they are simply different. `qd outliers RUN
--categorical` reads them as binnacle's `agree` reads answers (QD-034):

```bash
qd probe firmware -s hosts.txt                     # what every host and NIC is set to
qd outliers firmware --categorical                 # who differs from its rack-mates
qd outliers firmware bios_version,mtu --categorical --peers sku
```

- **The groups** are the hosts' `rack` (the attribute qd puts on every
  row), or `--peers NAME`'s groups, or with neither the whole fleet. What
  they are grouped by is not itself compared.
- **Within each group, each column**: the value more than half of the
  hosts that measured it share is the majority, and every host with
  another value is named, with the majority beside it (`differs`). With no
  such value -- one against one, two against two against one -- the
  column is **split**: every host and its value is listed, and none is
  called the odd one.
- **Like with like.** Where a host has several rows (one per NIC), each
  is compared with the same NIC on its rack-mates (`--match COLS`; `nic`
  by default). A value the same on every row of a host, its BIOS, is
  compared once a host.
- **Blank is not measured**: a host that measured nothing in a column is
  neither a vote for the majority nor an odd one out, and is named apart.
  A group with fewer than two hosts that measured a column says nothing.
- **What is meant to differ is left out**: serials, UUIDs, MAC and IP
  addresses, host names, uptime, and bookkeeping (`rc`, `duration_s`,
  ...). Name a column as `COL` (a comma list) to compare exactly those.

The table is `group, match, column, host, value, majority, agree,
measured, verdict` (no `match` when every host has one row). The exit
status is 1 when any host differs or any column splits, as with `qd
compare`, so a CI job can gate on it; 0 when every group agrees.

**A qualified baseline** is set from one or more runs (named, `RUN --last
N`, or `--group CAMPAIGN`) and kept as qd's own table, `qd.baselines`:
who set it (the operator, as on a run) and when, the note, the runs, and,
for each column, peer group and host, the value every run gave, with their
median, spread (MAD) and count. It is not "the first run in the list": a
bad run cannot become the baseline by being first, and who blessed it is on
record. A name that is a run's is refused, so `--baseline NAME` is never
ambiguous; `--replace` sets it again.

Each run is reduced the way `compare` reduces one (a host's rows to their
median, `--agg`), and a peer group to the median of its hosts, so the
group has one value per run and the runs are the replicates.
`qd compare ... --baseline NAME` then gives, per column and peer group:

| Figure | What |
|---|---|
| `drift_pct` | the runs' median against the baseline's, in percent |
| `effect` | the rank-biserial correlation, −1 to +1: +1 when every run is above every baseline run |
| `p` | the Mann–Whitney U test, two-sided: exact for 8 runs or fewer with no ties, else the normal approximation with the tie and continuity corrections (scipy's `mannwhitneyu` figures) |
| `p_holm` | `p` adjusted by Holm's method for the number of tests in the comparison (columns × peer groups), so many groups do not multiply false alarms |
| `verdict` | significant (`p_holm` below `--alpha`, 0.05), not significant, too few runs, not measured |

A significant difference is a change even inside `--drift`: that is the
point, a slide seen before a fixed limit is crossed. It has to be at least
`--min-drift` percent (1, `QD_MIN_DRIFT`), because runs with no noise at
all make any difference a sure one, and 0.03% is not a slide anyone acts
on: smaller, the verdict says "significant (under 1%)" and nothing is
flagged. A median past `--drift` is still a change whatever the test
says. The test needs **three
runs a side**; with fewer the drift alone is used and the verdict says so.
With exactly three a side the smallest p a rank test can give is 0.1, so
nothing can be significant at 0.05 and the report says that too: four a
side reach 0.029, five 0.008. Host by host, each host's median over the
runs is held against its baseline median by the drift alone (one test per
host would be hundreds of tests on a handful of runs). The runs the
baseline was set from are left out of what is held against it. A blank is
not measured: a run that did not measure a host gives it no value, never a
zero, and a baseline's count is of the runs that measured it. `--format
csv` is the per-group table; the exit status is 1 when anything changed.

The test is qd's, in the standard library: design_of_experiments' `doe`
compares two sessions run by run (a paired t-test, matched by factor
levels), which is not this question, and needs numpy, scipy and Python
3.9 or newer.
