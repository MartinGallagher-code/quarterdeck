<!--
SPDX-License-Identifier: GPL-3.0-or-later
SPDX-FileCopyrightText: 2026 Martin J. Gallagher
-->

# Getting started: ten minutes, and no fleet

<!-- walkthrough: width 120 -->
<!--
tests/test_demo.sh runs every ```console block on this page, in order,
and fails when a command prints anything but what is shown under it, or
exits with a status the page does not show (`$ echo $?`). After a change
that alters what a command prints on purpose:
  QD_WALKTHROUGH_UPDATE=1 QD_TEST_ONLY=walkthrough bash tests/test_demo.sh
writes what the commands print back into this page; read the diff before
committing it. ```bash blocks are not run: they need a fleet.
-->

qd sends a command to every host of a fleet, keeps every answer as a row
of a table, and reads the tables back: who agrees, who is far from the
rest, what changed since last week, what fails the spec. This page
teaches that loop on a fleet that is not there. `qd demo` files a made-up
week of 24 hosts into a store of its own, and every command below reads
it. Nothing contacts a host, and nothing needs ssh or a network.

Each step is a question, the command that answers it, and what it prints:
qd's real output, which the test suite checks against this page on every
change, as a terminal 120 columns wide shows it. A narrower terminal cuts
wide tables and names what it cut; `--width 120` puts it back.

## Before you start

```bash
pip install quarterdeck provost     # qd, and provost, which keeps everything qd brings back
```

qd is Python 3.6 or later, standard library only; provost needs 3.8. From
a clone, `./qd` works with nothing installed but provost.

## The demo

```console
$ qd demo
qd demo -- filed the store demo: a made-up fleet's week, 7 runs of 24 hosts
  in ~/.local/share/quarterdeck/stores/demo

  run                          hosts  ok  command
  20261109-080000-demo_facts      24  24  why-slow --facts
  20261110-080000-demo_facts      24  24  why-slow --facts
  20261111-080000-demo_facts      24  24  why-slow --facts
  20261112-080000-demo_facts      24  24  why-slow --facts
  20261113-080000-demo_facts      24  24  why-slow --facts
  20261113-083000-demo_kernel     24  23  uname -r
  20261113-090000-demo_iperf      24  24  iperf3 -c demo-peer -f m -t 10 | awk '/receiver…

  Nothing ran: the hosts are made up (demo-r1n01 .. demo-r2n12), and every answer came with qd,
  filed through provost as a real run's answers are.

  WHAT TO DO NEXT
    * qd store use demo      read the demo from here on (qd store ls: the others)
    * qd log                 the runs it holds, oldest first
    * qd freq demo-kernel A  who runs which kernel
    * the walkthrough, ten minutes, a question a step: docs/getting-started.md,
      https://github.com/MartinGallagher-code/quarterdeck/blob/main/docs/getting-started.md
```

That is the fleet's week: why-slow's readings every morning
(`demo-facts`), then on Friday which kernel every host runs
(`demo-kernel`) and how fast each moves data to a peer (`demo-iperf`).
Each was filed through provost exactly as a real run is. That takes a
minute or so (several, with a provost too old to have `batch`), and once
is enough: run again, `qd demo` leaves the store as it is and says so
(`--rebuild` files it afresh).

`qd demo` leaves the store you use alone, whichever it is:

```console
$ qd store ls
qd store -- 1 named store

    store  runs  path
    demo      7  ~/.local/share/quarterdeck/stores/demo

  in use here: ~/.provost  (provost's default: no store is active)

  WHAT TO DO NEXT
    * qd store new NAME          a store of its own, in ~/.local/share/quarterdeck/stores
    * qd store use NAME          the store commands use from now on
    * qd store export NAME FILE  one archive: its history, its answers, a manifest
```

Make the demo's the one qd reads from here on:

```console
$ qd store use demo
qd store: demo is the active store (~/.local/share/quarterdeck/stores/demo)
```

`qd store ls` lists your stores, and `qd store use NAME` goes back to
another. (Or leave the active store as it is, and add `--store demo` to
every command below.)

```console
$ qd log
run                          kind  tables  size      operator  command
20261109-080000-demo_facts   run        2  24/24 ok  demo      why-slow --facts
20261110-080000-demo_facts   run        2  24/24 ok  demo      why-slow --facts
20261111-080000-demo_facts   run        2  24/24 ok  demo      why-slow --facts
20261112-080000-demo_facts   run        2  24/24 ok  demo      why-slow --facts
20261113-080000-demo_facts   run        2  24/24 ok  demo      why-slow --facts
20261113-083000-demo_kernel  run        2  23/24 ok  demo      uname -r
20261113-090000-demo_iperf   run        2  24/24 ok  demo      iperf3 -c demo-peer -f m -t 10 | awk '/receiver...
```

## Four words

A **run** is one command sent to every host, and everything that came
back: what each host said, its exit status, how long it took, and the
hosts that did not answer, which are rows too. qd keeps a run as two
tables: `data`, a row for every host with what it said parsed into
columns, and `hosts`, how every host's try went. A **capture** is one
host's answer exactly as it came back, which provost keeps word for word
(`provost source N` prints it). A **dataset** is everything filed under
one name, every `demo-facts` run's rows together, which `qd show
ds:demo-facts` reads. A **store** is where all of it lives: a git
repository provost looks after, one of `qd store ls`.

A command names a run by its name (`demo-kernel`: the latest run of that
name), `latest`, `latest~1` (the one before), its id or a unique part of
it, or `ds:NAME` for every run of a dataset at once; `demo-kernel:hosts`
is that run's other table.

## 1. Is the fleet consistent?

### Who runs which kernel?

```console
$ qd freq demo-kernel A
qd freq -- A in 20261113-083000-demo_kernel:data (24 rows): 3 distinct values
  22 agree on the most common; 2 do not

      22   91.7%  ████████████████████   6.8.0-48-generic
       1    4.2%  ▉                      (blank)
                                         demo-r1n09
       1    4.2%  ▉                      6.8.0-31-generic
                                         demo-r2n05
```

`uname -r` prints one word, and provost files a one-word answer as a
single column, `A`. 22 hosts agree. demo-r2n05 runs an older kernel, and
demo-r1n09 is blank: it did not answer. Blank is never zero in qd; it
means nothing was measured.

### Who did not answer, and why?

```console
$ qd show demo-kernel --where status!=ok --cols host,status,error --full
host        status       error
demo-r1n09  unreachable  ssh: connect to host demo-r1n09 port 22: Connection timed out
```

`--where` keeps the rows that match (`mbps<9000`, `host~^demo-r2`,
`status!=ok`), `--cols` the columns, and `--full` cuts no cell short.

### Who is far from the rest?

```console
$ qd outliers demo-iperf mbps
qd outliers -- mbps in 20261113-090000-demo_iperf:data (24 rows): 24 hosts, median 9402, MAD 13.5, robust z beyond 3.5

  host        value  of_median  robust_z  side
  demo-r2n03   4882     51.93%    -225.8  low

  1 of 24 hosts sit far from the rest
```

Far means far from the fleet's median, in units of its median absolute
deviation (MAD), which one bad host cannot drag the way it drags a mean.
Before blaming a host, check it is compared with its own kind: the
compute and storage hosts are different machines.

```console
$ qd stats demo-facts cpu.busy_pct --by sku
qd stats -- 20261113-080000-demo_facts:data by sku (24 rows): 2 groups

sku      n   cpu.busy_pct_mean  cpu.busy_pct_median  cpu.busy_pct_min  cpu.busy_pct_max
compute  16              44.55                 45.5              37.8              49.4
storage   8               11.5                 11.3               9.5              14.2
```

## 2. Did it get worse?

### Five mornings side by side

```console
$ qd compare demo-facts -c mem.available_pct --last 5
qd compare -- 5 runs, mem.available_pct by host (baseline R1; a change is a median past 5% or a status that is not ok)
  R1   20261109-080000-demo_facts  why-slow --facts
  R2   20261110-080000-demo_facts  why-slow --facts
  R3   20261111-080000-demo_facts  why-slow --facts
  R4   20261112-080000-demo_facts  why-slow --facts
  R5   20261113-080000-demo_facts  why-slow --facts

  mem.available_pct
  run  hosts_ok  n   median  mean   min   p95    max   change_pct
  R1   24/24     24    74.4  74.44  62.8   78.5  78.8         0.0
  R2   24/24     24    74.2     74  51.3   78.5  79.1        -0.3
  R3   24/24     24   74.25  73.41  39.6  78.34  79.3        -0.2
  R4   24/24     24   74.35  72.86  27.9  78.71  79.1        -0.1
  R5   24/24     24   74.15  72.44  15.4  78.58  78.8        -0.3

  1 of 24 keys changed
  host        R1    R2    R3    R4    R5    change_pct  flags
  demo-r2n07  62.8  51.3  39.6  27.9  15.4  -75.5       R2 drift -18.3%; R3 drift -36.9%; R4 drift -55.…

  WHAT TO DO NEXT
    * qd show 20261113-080000-demo_facts --where host=demo-r2n07  the latest run's rows for the first key that changed
    * qd compare ... --format csv                                 every key's value per run, for a spreadsheet
$ echo $?
1
```

The fleet's median barely moved; one host lost three quarters of its free
memory in four days. Exit status 1 is qd's word for a finding: a host
that did not answer, a diff that differs, a check that fails. A script
can stop on it.

### When did it start?

```console
$ qd changes demo-facts -c mem.available_pct
qd changes -- mem.available_pct over 5 runs, by host
  runs: 20261109-080000-demo_facts (2026-11-09T08:00:00Z) .. 20261113-080000-demo_facts (2026-11-13T08:00:00Z)
  e-divisive means, permutation test: p 0.05, 100 permutations, seed 20261110; a change: a step of 1% or more; the newest run or two can lag

  1 of 24 keys changed
  host        change  between                     and                         before  after  pct     MADs
  demo-r2n07  fell    20261111-080000-demo_facts  20261112-080000-demo_facts    51.3  21.65  -57.8%  -2.6

  no change: demo-r1n01, demo-r1n02, demo-r1n03, demo-r1n04, demo-r1n05, demo-r1n06, demo-r1n07, demo-r1n08, demo-r1n09, demo-r1n10, demo-r1n11, demo-r1n12, demo-r2n01, demo-r2n02, demo-r2n03, demo-r2n04, demo-r2n05, demo-r2n06, demo-r2n08, demo-r2n09, demo-r2n10, demo-r2n11, demo-r2n12

  WHAT TO DO NEXT
    * qd diff 20261111-080000-demo_facts 20261112-080000-demo_facts  what else changed between the two runs either side
    * qd changes ... --format csv                                    every stretch: its runs, median, MAD and the step into it
$ echo $?
1
```

`changes` looks for the point where each host's level stepped, not only
whether the first and last runs differ: here, between Wednesday's run and
Thursday's. Its WHAT TO DO NEXT is the next question, what else changed
between those two.

## 3. Does it meet spec?

A requirement is a line of a small table: which column, which test, which
limit, over each host or the fleet as a whole (`agg`). The demo comes
with three:

```console
$ qd demo --limits > limits.csv
$ cat limits.csv
req,column,op,limit,agg,note
NET-001,mbps,>=,9000,each,
NET-002,mbps,>=,9300,median,the fleet as a whole: 9.3 Gb/s
NET-003,status,in,ok,each,every host answered
```

```console
$ qd check demo-iperf --against limits.csv
qd check -- 20261113-090000-demo_iperf:data against limits.csv (24 rows): 2 pass, 1 fail, 0 not measured
  run 20261113-090000-demo_iperf  demo-iperf  2026-11-13T09:00:00Z  iperf3 -c demo-peer -f m -t 10 | awk '/receiver/ {print "mbps:", $7}'

  req      column  agg     where  observed  limit    unit  measured  verdict  note
  NET-001  mbps    each           4882      >= 9000        24/24     fail     1 of 24 failed: demo-r2n03
  NET-002  mbps    median         9402      >= 9300        24/24     pass     the fleet as a whole: 9.3 Gb/s
  NET-003  status  each           ok        in ok          24/24     pass     every host answered
$ echo $?
1
```

One requirement fails, and only one: the slow host. `qd report demo-iperf
--out evidence/ --check limits.csv` packs the same verdicts with the data,
a manifest and hashes, for a test report.

## Look around

These two need a screen, so this page does not run them:

```bash
qd view            # full-screen: ] and [ page through the runs, Enter opens one, q quits
qd web             # the same store in a browser, with charts
```

## Your own fleet

Four things, once:

```bash
# 1. a host list: a host a line, attributes after it (they become columns)
printf '%s\n' 'node[01-12] rack=r1' 'node[13-24] rack=r2' > hosts.txt

# 2. key-based ssh to every host: qd never types a password
ssh-copy-id node01        # and the rest
qd doctor                 # what this machine can drive: ssh, provost, binnacle
qd doctor node01          # what ssh will do for that host, contacting nothing

# 3. a store of the fleet's own, so its runs and the demo's never mix
qd store new fleet
qd store use fleet

# 4. the same loop, on the fleet
qd run -- uname -r        # every host in hosts.txt, one run, kept
qd freq latest A          # who runs which kernel
qd probe facts            # why-slow's readings, a column each (binnacle here, python3 there)
qd compare facts -c mem.available_pct --last 5    # after a few days of probes
```

A `hosts.txt` or `servers.txt` in the directory is the fleet when no `-s`
is given; `qd hosts` prints what it expands to. When the demo has taught
what it can, `qd store rm demo --delete` removes it.

## Every command, by what it is for

`qd COMMAND --help` gives any one's options, `qd help` all of them, and
`qd hints` maps questions to commands. The README is the manual.

| What for | Commands |
|---|---|
| Starting out | `qd demo`, `qd hints`, `qd doctor`, `qd help` |
| Asking the fleet | `qd hosts` (the host list), `qd run` (a command), `qd ask` (a command, then who agrees and who differs), `qd probe` (by name: facts, sysctl, gpu ...), `qd do` (a toolchain tool, run here), `qd import` (output already on disk) |
| Seeing what came back | `qd log` (the runs), `qd show` (a table), `qd view` (full-screen), `qd web` (a browser) |
| Is the fleet consistent? | `qd freq` (who said which), `qd stats` (centre and spread), `qd hist`, `qd outliers` (far from the rest), `qd pivot` (long to wide), `qd peers` (hosts that should agree, named) |
| Did it get worse? | `qd diff` (two runs), `qd compare` (N runs), `qd changes` (when it stepped), `qd trend` (a sparkline a host), `qd baseline` (blessed runs to compare with) |
| Does it meet spec? | `qd check` (pass or fail by requirement), `qd report` (an evidence package) |
| Beside other data | `qd join` (telemetry by host and time), `qd export` (CSV, JSON, Splunk, OpenMetrics ...), `qd floor` (on the floor plan) |
| A big system, in parts | `qd split` (a host list into several), `qd campaign` (part by part, progress kept), `qd doe` (designed experiments) |
| Keeping the store | `qd store` (named stores: new, use, export, import ...), `qd rm` (delete runs) |
