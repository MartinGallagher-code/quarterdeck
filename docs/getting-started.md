<!--
SPDX-License-Identifier: GPL-3.0-or-later
SPDX-FileCopyrightText: 2026 Martin J. Gallagher
-->

# Getting started: a first day, and no fleet

<!-- walkthrough: width 120 -->
<!-- walkthrough: this machine is myhost -->
<!--
tests/test_demo.sh runs every ```console block on this page, in order,
and fails when a command prints anything but what is shown under it, or
exits with a status the page does not show (`$ echo $?`). After a change
that alters what a command prints on purpose:
  QD_WALKTHROUGH_UPDATE=1 QD_TEST_ONLY=walkthrough bash tests/test_demo.sh
writes what the commands print back into this page; read the diff before
committing it. A block after a `walkthrough: loose` line asks this
machine, so `[...]` stands for what is the reader's own there (see
tests/walkthrough.py); --update leaves those blocks to be put right by
hand. ```bash blocks are not run: they need a fleet.
-->

qd sends a command to every host of a fleet, keeps every answer as a row
of a table, and reads the tables back: who agrees, who is far from the
rest, what changed since last time. This page is a newcomer's first day
with it, five questions in order, each with the one command that answers
it and the plain qd commands that command stands for. None of it needs a
fleet: `qd demo` makes a practice one, a made-up week of 24 hosts, and
the commands that must ask a real host ask this machine.

What each command prints below is qd's real output, which the test suite
checks against this page on every change, as a terminal 120 columns wide
shows it. A narrower terminal cuts wide tables and names what it cut;
`--width 120` puts it back.

## The start card

`qd` on its own prints the start card: the few commands a first day
needs, and where everything else is.

```console
$ qd
qd -- run a command on many machines, keep every answer, and read it back.

Getting started
  qd demo                      a practice fleet to learn on, no machines needed
  qd setup                     check this machine, make a store, test your hosts
  qd ask -- uname -r           ask every host; see who agrees and who differs
  qd survey                    everything about every host, and who stands out
  qd again                     run the last thing again; show what changed
  qd odd                       which hosts are unlike the rest, and in what

Looking at what you have
  qd log                       what is kept
  qd show latest               the last answers, as a table
  qd web                       all of it in a browser

Everything else: qd --help    One command: qd help VERB    Ideas: qd hints
A first day with these, a question a step: docs/getting-started.md
```

The five under `qd demo` answer a newcomer's first questions, and this
page takes them in that order:

1. Can I reach my hosts? `qd setup`
2. Who agrees, and who differs? `qd ask`
3. What is every host like? `qd survey`
4. What changed? `qd again`
5. Who is odd? `qd odd`

## Before you start

```bash
pip install quarterdeck provost     # qd, and provost, which keeps everything qd brings back
```

qd is Python 3.6 or later, standard library only; provost needs 3.8. From
a clone, `./qd` works with nothing installed but provost.

## The practice fleet

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
    * qd freq demo-kernel A  who runs which kernel (A: uname -r's answer)
    * the walkthrough, ten minutes, a question a step: docs/getting-started.md,
      https://github.com/MartinGallagher-code/quarterdeck/blob/main/docs/getting-started.md
```

That is the fleet's week: why-slow's readings every morning
(`demo-facts`), then on Friday which kernel every host runs
(`demo-kernel`) and how fast each moves data to a peer (`demo-iperf`).
Each was filed through provost exactly as a real run is. That takes a
minute or so (several, with a provost too old to have `batch`), and once
is enough: run again, `qd demo` leaves the store as it is and says so
(`--rebuild` files it afresh). It leaves the store you use alone too;
make the demo's the one qd reads:

```console
$ qd store use demo
qd store: demo is the active store (~/.local/share/quarterdeck/stores/demo)
```

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
is that run's other table. [Concepts](concepts.md) has these words and
the rest qd uses, and every way to name a run, an example each.

## 1. Can I reach my hosts? `qd setup`

The demo's hosts are made up, so the three commands that have to ask a
host (`qd setup`, `qd ask`, `qd survey`) and `qd again`, which asks it
again, practise here on this machine: the one host every reader has,
reached without ssh. What it says is your own (its name, its kernel, the
time), so where this page shows `myhost` yours shows this machine's
name, and `[...]` stands for lines or words that are yours alone: the
test suite checks everything else.

```console
$ qd store ls
qd store -- 1 named store

     store  runs  path
  *  demo      7  ~/.local/share/quarterdeck/stores/demo

  in use here: demo = ~/.local/share/quarterdeck/stores/demo  (the active store)

  WHAT TO DO NEXT
    * qd store new NAME          a store of its own, in ~/.local/share/quarterdeck/stores
    * qd store use NAME          the store commands use from now on
    * qd store export NAME FILE  one archive: its history, its answers, a manifest
```

<!-- walkthrough: loose -->
```console
$ qd setup --yes --via local
qd setup -- check this machine, make a store, test the hosts
(stdin is not a terminal: nothing is asked, and nothing that needs an answer is changed)

1. What this machine can drive (qd doctor)
[...]
  store     ~/.local/share/quarterdeck/stores/demo (7 runs, 5 datasets)
[...]
  launcher  local: this machine only, without ssh (sh -c here, cp for pushed files)
  hosts     none named here, so a command runs on this machine, myhost, without ssh (--via local)

2. A store to keep the answers in (qd store)
  the active store is the demo's, ~/.local/share/quarterdeck/stores/demo: a fleet's own runs and the demo's are better kept apart
  done: made the store main (~/.local/share/quarterdeck/stores/main), and made it the active store in place of the demo
        (qd store new main; qd store use main)

3. The host list (qd hosts)
  none here: no -s, -S or --layout, no QD_SERVERS, and no hosts.txt or
  servers.txt in [...]
  nothing written: stdin is not a terminal, so nothing was asked

4. Who answers (qd run -- true, nothing kept)
  nothing to test: no host list

  SUMMARY
    machine   ready
    store     main, active (made now)
    hosts     none: nothing to test
    answered  not tested: no host list
    status 0: this machine is ready, and every host answered

  WHAT TO DO NEXT
    * qd hosts -S node01,node02 > hosts.txt  a host list here, a host a line; then qd setup again
    * qd ask -- uname -r                     ask every host; see who agrees and who differs
    * qd survey                              everything about every host, and who stands out
    * qd demo                                a made-up fleet's week to learn on (docs/getting-started.md)
```

Setup takes four steps and says what it did at each. Step 1 is `qd
doctor`'s table of what this machine can drive (ssh, provost, binnacle
and the rest), yours to read. Step 2 found the demo's store in use and
made `main`, a store of this fleet's own, so its runs and the demo's
never mix. With no host list (step 3) there is nothing to test (step 4):
every command below then runs on this machine alone.

At a terminal setup asks before it changes anything, and offers to write
a `hosts.txt` from the names you type; this page's run is not at one, so
it asks nothing, and `--yes` answers the one question it would ask, the
store. `--via local` says this machine is reached without ssh, as every
command is when no host is named. On your own fleet it is `qd setup` in
the directory that holds the `hosts.txt` (see [Your own fleet](#your-own-fleet)),
and a second run finds every step done and changes nothing.

It stands for: `qd doctor`, `qd store new main`, `qd store use main`,
`qd hosts`, and `qd run -- true` on every host, keeping nothing.

## 2. Who agrees, and who differs? `qd ask`

<!-- walkthrough: loose -->
```console
$ qd ask -- uname -r
qd: no hosts named, so the fleet is this machine, myhost, reached without ssh (--via local); name hosts with -s FILE, -S a,b,c, QD_SERVERS or a hosts.txt here
qd ask -- uname -r: 1 host, 1 ok   [provost: uname: A]
  stored   20261119-160338-uname in ~/.local/share/quarterdeck/stores/main  (1 row, capture c0001)

  ANSWERS  one answer from 1 host (column A)
    1  [...]
       myhost

  ALIKE  the one host answered

  WHAT TO DO NEXT
    * qd freq latest A  the count above, as qd freq gives it
    * qd show latest    every host's answer, as a table
    * qd view latest    explore it full-screen
```

`qd ask` runs the command on every host, keeps the run in the store in
use (`main`), and prints each answer with the hosts that gave it, most
hosts first. `uname -r` prints one word, and provost files a one-word
answer as a single column. Nothing names it, so provost names it as a
spreadsheet would, `A` (then `B`, `C`, ... for more; see
[Concepts](concepts.md#the-objects)). One host always agrees with itself. The
demo's Friday run, `demo-kernel`, asked its 24 hosts the same, and what
`qd ask` prints after its run is `qd freq` of it:

```console
$ qd freq demo-kernel A --store demo
qd freq -- A in 20261113-083000-demo_kernel:data (24 rows): 3 distinct values
  22 agree on the most common; 2 do not

      22   91.7%  ████████████████████   6.8.0-48-generic
       1    4.2%  ▉                      (blank)
                                         demo-r1n09
       1    4.2%  ▉                      6.8.0-31-generic
                                         demo-r2n05
```

22 hosts agree. demo-r2n05 runs an older kernel, and demo-r1n09 is blank:
it did not answer. Blank is never zero in qd; it means nothing was
measured. Why it did not answer is in the run's rows (`--store demo`
reads the demo while `main` is the store in use):

```console
$ qd show demo-kernel --where status!=ok --cols host,status,error --full --store demo
host        status       error
demo-r1n09  unreachable  ssh: connect to host demo-r1n09 port 22: Connection timed out
```

`--where` keeps the rows that match (`mbps<9000`, `host~^demo-r2`,
`status!=ok`), `--cols` the columns, and `--full` cuts no cell short.

It stands for: `qd run -- uname -r`, then `qd freq latest A`.

## 3. What is every host like? `qd survey`

<!-- walkthrough: loose -->
```console
$ qd survey
qd: no hosts named, so the fleet is this machine, myhost, reached without ssh (--via local); name hosts with -s FILE, -S a,b,c, QD_SERVERS or a hosts.txt here
qd survey -- 1 host asked [...]: every host answered every probe
  stored   [...] in ~/.local/share/quarterdeck/stores/main
[...]
  WHAT MOST HOSTS SAY
[...]
    kernel           [...]1 of 1
[...]
  ONE HOST  nothing to compare it against: who differs and who is far from
            the median need two or more.  `qd demo` makes a practice fleet.

  FOUND  nothing: every host answered, and none stands out

  WHAT TO DO NEXT
[...]
```

`qd survey` asks every host the standard questions, qd's probes: the OS
and kernel, firmware, disks, mounts, NUMA, GPUs and packages, and
binnacle's why-slow readings (`facts`) where binnacle is installed. It
files a run for each, then gives one screen: what most hosts say, who
differs from the rest, and who is far from the median. On one host the
last two have nothing to compare it with. On the demo's 24, why-slow's
readings are `demo-facts`, and the screen's parts are these:

```console
$ qd freq demo-facts sys.kernel --store demo
qd freq -- sys.kernel in 20261113-080000-demo_facts:data (24 rows): 2 distinct values
  23 agree on the most common; 1 do not

      23   95.8%  ████████████████████   6.8.0-48-generic
       1    4.2%  ▉                      6.8.0-31-generic
                                         demo-r2n05
```

```console
$ qd outliers demo-iperf mbps --store demo
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
$ qd stats demo-facts cpu.busy_pct --by sku --store demo
qd stats -- 20261113-080000-demo_facts:data by sku (24 rows): 2 groups

sku      n   cpu.busy_pct_mean  cpu.busy_pct_median  cpu.busy_pct_min  cpu.busy_pct_max
compute  16              44.55                 45.5              37.8              49.4
storage   8               11.5                 11.3               9.5              14.2
```

It stands for: `qd probe facts inventory`, then `qd freq` of the values
most hosts share (`qd freq os kernel`), `qd outliers os os,kernel
--categorical` for who differs, and `qd outliers facts COLUMN` for who is
far from the median. Its WHAT TO DO NEXT names the ones it ran.

## 4. What changed? `qd again`

<!-- walkthrough: loose -->
```console
$ qd again uname
qd again -- 20261119-160338-uname: uname -r
  hosts    1 host, the ones 20261119-160338-uname ran on
  as       via local, no sudo, timeout 60s
  name     uname
  runs     qd run -S myhost=127.0.0.1 --via local --timeout 60 -- 'uname -r'

qd run -- uname -r: 1 host, 1 ok   [provost: uname: A]
  stored   20261119-160402-uname in ~/.local/share/quarterdeck/stores/main  (1 row, capture c[...])

qd diff -- A 20261119-160338-uname:data (1 row) -> B 20261119-160402-uname:data (1 row), matched on host
  compared  addr, status, rc, error, A
  ignored   duration_s, capture (they differ on every run by construction; --cols compares them)

  1 key in both: 0 changed, 1 the same; 0 only in A (gone), 0 only in B (new)

  column  pairs  mean A  mean B  change  median delta  rose  fell  same
  rc          1       0       0                     0     0     0     1

  no differences

qd again -- 20261119-160338-uname -> 20261119-160402-uname
  same     every host answered, and nothing changed

  WHAT TO DO NEXT
    * qd diff 20261119-160338-uname 20261119-160402-uname                what changed, again (--format csv for the table)
    * qd run -S myhost=127.0.0.1 --via local --timeout 60 -- 'uname -r'  the run on its own, as qd again ran it
    * qd log 20261119-160402-uname                                       the new run: what ran, where, how it went
    * qd again 20261119-160402-uname                                     once more, later
```

`qd again RUN` runs RUN once more as it ran (its command, its hosts, how
they were reached), then shows what changed. Plain `qd again` repeats the
latest run, which after `qd survey` is its last probe; `uname` names the
`qd ask` run, by its name. Its first lines say what it will run, and the
rest is the two plain commands it stands for: that `qd run`, then `qd
diff` of the old run and the new. Nothing changed here, so it exits 0; a
changed answer or a host that stopped answering is exit 1, qd's word for
a finding.

A week has more to show. Back to the demo for the rest of the page:

```console
$ qd store use demo
qd store: demo is the active store (~/.local/share/quarterdeck/stores/demo)
```

Five mornings of the demo, side by side:

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
memory in four days. Exit status 1 is the finding, and a script can stop
on it. When did it start?

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
between those two: `qd diff`, the command `qd again` ends with.

It stands for: the run again (`qd run`, with the command and hosts the
run kept), then `qd diff OLD NEW`.

## 5. Who is odd? `qd odd`

```console
$ qd odd
qd odd -- 20261113-090000-demo_iperf:data (24 rows): 1 host stands out, in 1 of 1 column checked

  Numbers far from the rest: robust z beyond 3.5, against the whole run's median
  host        column  value  typical  robust_z
  demo-r2n03  mbps     4882     9402    -225.8

  checked: 1 column of numbers (mbps)
           0 columns of words

  WHAT TO DO NEXT
    * qd outliers latest mbps                            every host's mbps against the rest, in full
    * qd show latest --where host=demo-r2n03 --vertical  everything demo-r2n03 said
$ echo $?
1
```

`qd odd` reads a run (the latest, with none named) and holds every
column against the rest at once: numbers against the run's median, as
`qd outliers` does, and words against the rest of each host's rack. The
latest run here is the demo's iperf, and its slow host is the one that
stands out. Name a run to read another:

```console
$ qd odd demo-kernel
qd odd -- 20261113-083000-demo_kernel:data (24 rows): 1 host stands out, in 1 of 1 column checked

  Values unlike the rest of their rack: rarity is the share of it that says otherwise
  rack  host        column  value             typical           rarity  agree
  r2    demo-r2n05  A       6.8.0-31-generic  6.8.0-48-generic     92%  11 of 12

  checked: 0 columns of numbers
           1 column of words (A), within each rack
  did not answer in this run, so not measured: demo-r1n09 (unreachable)

  WHAT TO DO NEXT
    * qd outliers demo-kernel A --categorical                 every host's A against the rest, in full
    * qd show demo-kernel --where host=demo-r2n05 --vertical  everything demo-r2n05 said
$ echo $?
1
```

The odd kernel, and the host that did not answer, which is not measured
rather than odd.

It stands for: `qd outliers RUN COLUMN` for every column of numbers, and
`qd outliers RUN COLUMN --categorical` for every column of words.

## One more: does it meet spec?

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

The same five, on real hosts. A `hosts.txt` or `servers.txt` in the
directory is the fleet when no `-s` is given, and `qd setup` asks for
one at a terminal; by hand:

```bash
# a host list: a host a line, attributes after it (they become columns)
printf '%s\n' 'node[01-12] rack=r1' 'node[13-24] rack=r2' > hosts.txt
qd hosts                  # what it expands to

# key-based ssh to every host: qd never types a password
ssh-copy-id node01        # and the rest
qd setup                  # this machine, a store of the fleet's own, who answers
qd doctor node01          # what ssh will do for a host that did not, contacting nothing

# the first day, on the fleet
qd ask -- uname -r        # who runs which kernel
qd survey                 # everything about every host, and who stands out
qd again                  # tomorrow: the last run once more, and what changed
qd odd                    # who is unlike the rest, in the latest run
```

When the demo has taught what it can, `qd store rm demo --delete`
removes it, and `qd store use main` goes back to the store setup made.

## Where to go next

- `qd --help`: the full reference card, every command by what it is for.
- `qd help VERB` (or `qd VERB --help`): one command's options.
- `qd hints`: questions, and the command that answers each.
- [Concepts](concepts.md): runs, tables, captures, datasets, stores, and
  every way to name a run.
- The [README](../README.md): the manual, command by command.

### Every command, by what it is for

The headings are `qd --help`'s.

| What for | Commands |
|---|---|
| Run | `qd setup` (your own fleet, the first time: a store, a host list, who answers), `qd run` (a command on every host), `qd ask` (a command, then who agrees and who differs), `qd probe` (by name: facts, sysctl, gpu ..., and your own: `qd probe add NAME -- COMMAND`, `qd probe rm NAME`), `qd survey` (the standard questions; who stands out), `qd do` (a toolchain tool, run here), `qd import` (output already on disk), `qd hosts` (the host list) |
| Read it back | `qd log` (the runs), `qd coverage` (which hosts each test has reached), `qd show` (a table), `qd stats` (centre and spread), `qd freq` (who said which), `qd hist`, `qd outliers` (far from the rest), `qd odd` (every column at once: who is unlike the rest), `qd pivot` (long to wide), `qd trend` (a sparkline a host), `qd view` (full-screen), `qd web` (a browser) |
| Over time | `qd again` (the last run once more, and what changed), `qd diff` (two runs), `qd compare` (N runs), `qd changes` (when it stepped) |
| Judge and report | `qd check` (pass or fail by requirement), `qd report` (an evidence package), `qd peers` (hosts that should agree, named), `qd baseline` (blessed runs to compare with) |
| Larger jobs | `qd split` (a host list into several), `qd campaign` (part by part, progress kept), `qd doe` (designed experiments; `qd doe surface`, the best settings on a response surface), `qd join` (telemetry by host and time) |
| Stores and output | `qd store` (named stores: new, use, export, import ...), `qd rm` (delete runs), `qd export` (CSV, JSON, Splunk, OpenMetrics ...), `qd floor` (on the floor plan) |
| Help | `qd hints`, `qd doctor`, `qd start`, `qd demo`, `qd help` |
