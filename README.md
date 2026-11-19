<!--
SPDX-License-Identifier: GPL-3.0-or-later
SPDX-FileCopyrightText: 2026 Martin J. Gallagher
-->

# quarterdeck (`qd`)

[![CI](https://github.com/MartinGallagher-code/quarterdeck/actions/workflows/ci.yml/badge.svg)](https://github.com/MartinGallagher-code/quarterdeck/actions/workflows/ci.yml)
[![License: GPL-3.0-or-later](https://img.shields.io/badge/license-GPL--3.0--or--later-blue.svg)](https://www.gnu.org/licenses/gpl-3.0.html)
[![REUSE status](https://api.reuse.software/badge/github.com/MartinGallagher-code/quarterdeck)](https://api.reuse.software/info/github.com/MartinGallagher-code/quarterdeck)

**New to qd? Start with [Getting started](https://github.com/MartinGallagher-code/quarterdeck/blob/main/docs/getting-started.md)
(docs/getting-started.md):** ten minutes, a question a step, on a made-up
fleet's week that `qd demo` files for you. No hosts, ssh or network
needed. The words every command assumes (run, dataset, capture, store
...) and every way to name a run are on one page:
[Concepts](https://github.com/MartinGallagher-code/quarterdeck/blob/main/docs/concepts.md).

The quarterdeck is where a ship is commanded from: the binnacle's
instruments are read there and the log is kept there. This one does that
for a fleet of Linux boxes:

1. **Runs a command on every host and keeps every answer as a dataset.**
   It doesn't just show you N screens of output: each host is a row,
   whatever it printed is parsed into columns by
   [provost](https://github.com/MartinGallagher-code/provost), which keeps
   it, and a host that didn't answer is a row too.
2. **Asks by name.** `qd probe facts` is two hundred readings per host
   from binnacle's why-slow; `qd probe health` is dcprobe's scan;
   `sysctl`, `gpu`, `services`, `mounts` and the rest cover what no
   instrument measures yet.
3. **Drives the rest of the toolchain and keeps what it leaves.**
   [binnacle](https://github.com/MartinGallagher-code/binnacle),
   [matrix_orchestrator](https://github.com/MartinGallagher-code/matrix_orchestrator) (`mx`),
   [iperf_orchestrator](https://github.com/MartinGallagher-code/iperf_orchestrator) and
   [datacenter_visualization](https://github.com/MartinGallagher-code/datacenter_visualization)
   (`dcprobe`, the floor plan) all write files. `qd do` runs one and files
   its output in the same store, in the same shape.
4. **Runs a system in parts, and runs experiments.** `qd split` cuts a
   host list by rack, into shards, waves, random or stratified groups,
   A/B halves or pairs; `qd campaign` works through the parts with
   binnacle's `muster` keeping count; `qd doe` measures a designed
   experiment from design_of_experiments' `doe` and hands the results
   back to it for the analysis.
5. **Reads any of it back, any way you like.** Statistics, value counts
   (who agrees and who doesn't), histograms, robust outliers, group-bys,
   pivots, trends, diffs between two runs and comparisons of many. You can
   read them as text, as CSV/JSON, in a full-screen terminal explorer, in
   a browser, painted on the floor plan, or as an evidence package for a
   test report (`qd report`).

```bash
pip install 'quarterdeck[all]'           # qd, with provost (the store) and binnacle (the instruments)
pip install quarterdeck                  # or qd alone: it finds provost and binnacle on PATH
pip install doehelper                    # for qd doe (Python 3.10+)
```

Or from a clone, which needs nothing installed but provost:

```bash
git clone https://github.com/MartinGallagher-code/quarterdeck
pip install provost binnacle             # the store, and the instruments
./quarterdeck/qd hints                   # runs from the clone
pip install ./quarterdeck                # or put qd (and quarterdeck) on PATH
```

qd itself is Python 3.6+, standard library only. It needs provost to keep
anything (`--no-store` runs without it): any version files a run, and
provost 2.28.0 or later files a small one quickly, in well under half the
time 2.27.0 took (`docs/scale.md`, "Small runs"); binnacle gives it its probes'
instruments and campaigns' muster, and `doe` its designs, each found on
`PATH` or where `QD_<TOOL>` points. Nothing is installed on the fleet, and
a command qd gives up on (past `--timeout` or `--max-output`) is stopped
there, not only its ssh; where qd cannot confirm that, it says so (see
[When a host takes too long](https://github.com/MartinGallagher-code/quarterdeck/blob/main/docs/running.md#when-a-host-takes-too-long)). All it needs is key-based ssh, which the
rest of the toolchain needs anyway.

---

## Thirty seconds

No fleet to hand, or not yet? `qd demo` files a made-up one's week into a
store of its own, and [Getting started](https://github.com/MartinGallagher-code/quarterdeck/blob/main/docs/getting-started.md) walks
through it (see [A fleet to learn on](https://github.com/MartinGallagher-code/quarterdeck/blob/main/docs/running.md#a-fleet-to-learn-on-qd-demo)). With a fleet:

```bash
printf '%s\n' 'node[01-24] rack=r1' 'node[25-48] rack=r2' > hosts.txt

qd run -- uname -r                       # every host, every answer, kept
qd freq latest A                         # who runs which kernel
qd ask -- uname -r                       # both at once: who agrees, who differs
qd probe facts                           # why-slow's readings, a column each
qd stats facts cpu.busy_pct --by rack    # centre and spread, per rack
qd outliers facts mem.available_pct      # who is far from everybody else
qd odd facts                             # who is unlike the rest, in any column
qd compare facts -c cpu.busy_pct --last 5    # the last five runs, host by host
qd web                                   # all of it, in a browser
```

`A` is the column `uname -r` fills: provost names a field it found no
name for `A`, `B`, ... as a spreadsheet does (see
[Concepts](https://github.com/MartinGallagher-code/quarterdeck/blob/main/docs/concepts.md#the-objects)); `qd show latest` shows them.
The run's first line ends with what was filed: `[provost: uname: A]` is
the dataset, `uname`, and its columns, here `A` alone.

```text
qd run -- uname -r: 48 hosts, 46 ok, 2 unreachable   [provost: uname: A]
  stored   20261029-142233-uname in ~/.provost  (48 rows, 46 captures c0001..c0046)

  DID NOT ANSWER
    node09  unreachable      ssh: connect to host node09 port 22: Connection timed out
    node31  unreachable      ssh: connect to host node31 port 22: Connection timed out

  host    A
  node01  6.1.0-18-amd64
  ...

  WHAT TO DO NEXT
    * qd show latest --where status!=ok  the 2 hosts that did not answer, with why
    * reachable hosts.txt -i             binnacle: comment dead entries out of the list
    * qd freq latest A                   2 different answers: who said which
    * provost source 1                   one host's answer exactly as it came back
    * qd view latest                     explore it full-screen
```

No host list yet? `qd run -- uptime` in a directory without one runs on
this machine alone, without ssh (see [No hosts named: this machine](https://github.com/MartinGallagher-code/quarterdeck/blob/main/docs/running.md#no-hosts-named-this-machine)).

---

## Every command, by what it is for

Bare `qd` prints a short start card, the few commands to begin with
(`qd start` and `qd help basics` print it too); `qd --help` is the
reference card: every command, one screen, under what it is for, everyday
ones first.

| Heading | Commands |
|---|---|
| Run | `run`, `ask`, `survey`, `probe`, `do`, `setup`, `hosts` |
| Read it back | `log`, `show`, `coverage`, `stats`, `freq`, `hist`, `outliers`, `odd`, `pivot`, `trend`, `view`, `web` |
| Over time | `again`, `diff`, `compare`, `changes` |
| Judge and report | `check`, `report`, `peers`, `baseline` |
| Larger jobs | `split`, `campaign`, `doe`, `join` |
| Stores and output | `store`, `rm`, `import`, `export`, `floor` |
| Help | `hints`, `doctor`, `start`, `demo`, `help` |

`qd hints` maps questions to commands: first the five beginner commands,
under the start card's Getting started, then the rest under the same
headings. `qd help VERB` gives one verb's flags (`qd help run`, as `qd run --help` prints
them), and [the manual](https://github.com/MartinGallagher-code/quarterdeck/blob/main/docs/README.md) is the rest.

---

## The manual

The manual is in [`docs/`](https://github.com/MartinGallagher-code/quarterdeck/blob/main/docs/README.md), a chapter for each thing you are trying to do:

- [Getting started](https://github.com/MartinGallagher-code/quarterdeck/blob/main/docs/getting-started.md): ten minutes on the demo fleet, a question a step.
- [Concepts](https://github.com/MartinGallagher-code/quarterdeck/blob/main/docs/concepts.md): the words every command assumes, and every way to name a run.
- [Running: commands, probes and tools on many hosts](https://github.com/MartinGallagher-code/quarterdeck/blob/main/docs/running.md)
- [Reading the answers: tables, statistics, a terminal, a browser](https://github.com/MartinGallagher-code/quarterdeck/blob/main/docs/reading.md)
- [Over time: many runs, peers and baselines](https://github.com/MartinGallagher-code/quarterdeck/blob/main/docs/over-time.md)
- [Judging: requirements, waivers and test reports](https://github.com/MartinGallagher-code/quarterdeck/blob/main/docs/judging.md)
- [Larger jobs: split, coverage, campaigns and experiments](https://github.com/MartinGallagher-code/quarterdeck/blob/main/docs/larger-jobs.md)
- [Telemetry, the floor plan and export](https://github.com/MartinGallagher-code/quarterdeck/blob/main/docs/telemetry-and-export.md)
- [Stores: where the answers are kept](https://github.com/MartinGallagher-code/quarterdeck/blob/main/docs/stores.md)
- [Conventions and exit status](https://github.com/MartinGallagher-code/quarterdeck/blob/main/docs/conventions.md)
- [Contributing: tests and working on quarterdeck](https://github.com/MartinGallagher-code/quarterdeck/blob/main/docs/contributing.md)
- [How far qd's fan-out goes](https://github.com/MartinGallagher-code/quarterdeck/blob/main/docs/scale.md): the measurements behind *At scale* in Running.

---

## Related

- [provost](https://github.com/MartinGallagher-code/provost) — the store: command output turned into data, kept in git
- [binnacle](https://github.com/MartinGallagher-code/binnacle) — the instruments: why-slow, agree, netmesh, reckon, manifest, muster, ...
- [design_of_experiments](https://github.com/MartinGallagher-code/design_of_experiments) — `doe`: designs and their analysis
- [matrix_orchestrator](https://github.com/MartinGallagher-code/matrix_orchestrator) — request/response pps across a fleet
- [iperf_orchestrator](https://github.com/MartinGallagher-code/iperf_orchestrator) — full-mesh TCP bandwidth
- [datacenter_visualization](https://github.com/MartinGallagher-code/datacenter_visualization) — the `.dc` floor plan, dcprobe, and the viewer overlays paint on

## License

Copyright (C) 2026 Martin J. Gallagher

This program is free software: you can redistribute it and/or modify it under
the terms of the GNU General Public License as published by the Free Software
Foundation, either version 3 of the License, or (at your option) any later
version.

This program is distributed in the hope that it will be useful, but WITHOUT ANY
WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A
PARTICULAR PURPOSE. See the GNU General Public License for more details.

You should have received a copy of the GNU General Public License along with
this program. If not, see <https://www.gnu.org/licenses/>.

Full text: the `LICENSE` file at the repository root, or
<https://www.gnu.org/licenses/gpl-3.0.html> — SPDX identifier
`GPL-3.0-or-later`. This repository follows the
[REUSE Specification](https://reuse.software/): source files carry SPDX
copyright and licence headers, and the licence text lives in `LICENSES/`.
