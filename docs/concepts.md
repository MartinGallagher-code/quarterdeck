<!--
SPDX-License-Identifier: GPL-3.0-or-later
SPDX-FileCopyrightText: 2026 Martin J. Gallagher
-->

# Concepts: the words every qd command assumes

Each word below gets a sentence or two, one example and a link to the
part of the [manual](README.md) that uses it. The examples read the
demo store: `qd demo`, then `qd store use demo`, as
[Getting started](getting-started.md) does.
`tests/test_concepts.sh` checks that every `qd` command here parses, and
`tests/test_demo.sh` runs every example of [Naming a run](#naming-a-run).

```text
run 20261113-083000-demo_kernel   (uname -r, 24 hosts)
 |
 +- host demo-r1n01 --> capture: its answer, as it came
 |                        |
 |                        +-> rows: what provost parsed
 +- host demo-r1n02 ...       (host, rack, ..., A)
 +- host demo-r1n09 --> no answer: a row, blank, with
 |                      status unreachable
 v
store: dataset demo-kernel, every such run's rows,
       beside qd.runs and qd.hosts
```

## The objects

- **Run:** one command sent to every host, and everything that came
  back, including the hosts that did not answer. `qd log` lists them:
  `qd log demo-kernel`.
- **Pass:** with `--every S --count N` a run asks every host N times,
  once every S seconds; each time is a pass, and its rows carry `pass`
  and `ts` ([Over time](running.md#over-time)):
  `qd run --every 60 --count 5 -- uptime`.
- **Table:** a run reads back as tables: `data` (the default), a row per
  host with what it said in columns, and `hosts`, how each host's try
  went (status, rc, duration, stderr): `qd show demo-kernel:hosts`.
- **Row:** one record of a table. A host's answer can be one row
  (`uname -r`) or many (`df`, a row per filesystem), and a host that did
  not answer is a row too: `qd show demo-kernel --where status!=ok`.
- **Capture:** one host's answer exactly as it came back, which provost
  keeps word for word; a row's `capture` column says which
  (`provost source N` prints it): `qd show demo-kernel --cols host,capture`.
- **Dataset:** everything provost has filed under one name, every run's
  rows together; a run is the part of a dataset it filed:
  `qd show ds:demo-facts`.
- **Column:** one field of a row, named by what printed it
  (`mem.available_pct`). A field provost found no name for is named as a
  spreadsheet names columns, `A`, `B`, ... `Z`, `AA`
  ([provost's rule](https://github.com/MartinGallagher-code/provost/blob/main/docs/0002-tidy-first-and-nameless-columns.md#3-nameless-columns-abc-over-c1c2c3)):
  `uname -r` prints one bare value, so `qd freq demo-kernel A`.

## Stores

- **Store:** where all of it is kept, a git repository provost looks
  after; its layout is provost's spec,
  [`docs/store-format.md`](https://github.com/MartinGallagher-code/provost/blob/main/docs/store-format.md)
  ([What it keeps](stores.md#what-it-keeps-provosts-store)):
  `qd store ls`.
- **Active store:** the one commands use when nothing more explicit
  (`--store`, `QD_STORE`, `PROVOST_WORKSPACE`) names another
  ([Named stores](stores.md#named-stores-qd-store)): `qd store use demo`.
- **Named store:** a store qd knows by a name, for `--store NAME` and
  `RUN@NAME`: `qd store new lab`.
- **Remote store:** a named store on another machine, read from a copy
  here and never written to: `qd store new wr01 --remote wr01:~/.provost`.

## Blank

**Blank** means not measured, never zero: a host that did not answer, or
a column its answer did not have, stays blank through every statistic,
pivot and diff ([Conventions](conventions.md#conventions)):
`qd stats demo-kernel A` counts the blank apart.

## Naming a run

Every command that reads takes a RUN, written any of these ways. Each
example reads the demo store and exits 0; `qd log` lists the runs, and
`qd log RUN` describes one.

| Form | Means | Example |
|---|---|---|
| `latest`, `last` | the newest run | `qd show latest` |
| `latest~N`, `~N` | N runs before the newest | `qd show latest~1` |
| `prev`, `prev~N` | the run before the newest (`latest~1`), and N before that | `qd log prev` |
| `ID` | that run, by its id | `qd show 20261113-083000-demo_kernel` |
| `PART` | a run by any part of its id that only it has | `qd show 083000` |
| `NAME` | the newest run of that name (`--name`, a probe's name) | `qd freq demo-kernel A` |
| `ds:NAME` | a whole provost dataset: every run that filed into it | `qd show ds:demo-facts` |
| `DATASET` | a dataset no run is named, without `ds:` | `qd show qd.runs` |
| `RUN:TABLE` | one table of a run: `data` (the default) or `hosts` | `qd show demo-kernel:hosts` |
| `FILE`, `DIR` | a file or directory, read without filing it | `qd show results.tsv` |
| `RUN@STORE` | any of the above, read in the named store STORE | `qd show latest:hosts@demo` |

`@STORE` works for reading commands only, and splits on the last `@`
([Runs from different stores side by side](stores.md#named-stores-qd-store)).

## The comparison words

- **Peer group:** the hosts that ought to measure alike, named, so each
  is held against its own peers rather than the whole fleet
  ([Peer groups](over-time.md#peer-groups-and-qualified-baselines-qd-peers-qd-baseline)):
  `qd peers define sku --by sku`.
- **Baseline:** what a peer group measured on runs someone vouched for,
  kept by name, for later runs to be compared with:
  `qd baseline set gold demo-iperf --peers sku -c mbps`.
- **Campaign:** a command and a host list cut into parts, worked through
  part by part, each part a run
  ([A system in parts](larger-jobs.md#a-system-in-parts-qd-campaign)):
  `qd campaign new burnin --by rack -- ./burnin.sh`.
- **Requirement:** one row of a limits file (`req`, `column`, `op`,
  `limit`), which `qd check` gives a verdict
  ([Against requirements](judging.md#against-requirements-qd-check)):
  `qd check demo-iperf --against limits.csv`.
- **Waiver:** an agreed deviation that turns one requirement's failure
  into *waived*, with a justification and an expiry
  ([Waivers](judging.md#waivers)):
  `qd check demo-iperf --against limits.csv --waivers waivers.tsv`.
- **Telemetry:** samples another system kept (temperatures, power, link
  errors), matched to a run's rows by host and time window
  ([Beside the telemetry](telemetry-and-export.md#beside-the-telemetry-qd-join)):
  `qd join demo-iperf splunk-export.csv`.

## Exit status

**0** is done, and every host answered. **1** is a finding: a host that
did not answer, a compare or diff that differs, a requirement that
failed; the command did its job, and what it found needs a look. **2** is
a usage error, or something that could not be read or written
([Exit status](conventions.md#exit-status)):
`qd compare demo-facts -c mem.available_pct --last 5` exits 1.
