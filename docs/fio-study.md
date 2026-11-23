<!--
SPDX-License-Identifier: GPL-3.0-or-later
SPDX-FileCopyrightText: 2026 Martin J. Gallagher
-->

# A fio tuning study, start to finish

Which of fio's settings get the most out of a drive, and what are they?
This chapter takes one drive on one host from a first screen of seven
settings to the fio command line to use, in seven steps, each a qd
command run on what the step before it left in the store. Each step has
its own section in [Larger jobs](larger-jobs.md#designed-experiments-qd-doe),
which says everything it does; this is the order to run them in and what
to read in each answer. Part of [the manual](README.md).

```bash
qd doe init fio                                             # 1. the screen's config
qd doe run fio-screen.json -s host.txt                      #    its 8 points
qd doe analyze fio-screen                                   #    what moves each response
qd doe analyze fio-screen -c read_iops --report             # 2. doe's charts; qd web draws its own
qd doe next fio-screen -c read_iops                         # 3. a follow-up on the big factors
qd doe run fio-screen-read-iops-ccd.json --like fio-screen  # 4. on the same host and drive
qd compare --study fio-screen -c read_iops                  # 5. every run of the study
qd doe surface fio-screen-read-iops-ccd                     # 6. where the best settings are
qd doe optimize fio-screen -c read_iops --budget 80         # 7. rounds until the optimum: the command to use
```

Before you start:

- **doe** does the statistics (`pip install doehelper`, Python 3.10+ and
  numpy, on the machine qd runs on); **provost** keeps the runs and reads
  fio's JSON into columns; **fio** is on the host.
- **fio writes the file you name, and only that**: `fixed_factors.filename`
  in the config, a file on the drive's filesystem. A raw device
  (`/dev/nvme0n1`) destroys what is on it, and qd refuses a writing fio
  command on a `/dev/` path unless `--yes` is given.
- **It takes a while.** A point is a 60 s run after a 10 s ramp: the
  screen's 8 points are about 10 minutes, the follow-up's 16 about 20,
  and the rounds of step 7 as many runs as `--budget` allows (the example
  below made 29, about 35 minutes). Every run writes to the drive; the
  budget is the bound on how much.
- **One drive of one host.** The same study on every drive of every
  host, each drive model its own optimum (or one setting for the fleet),
  is
  [Larger jobs: "Every drive on every host"](larger-jobs.md#every-drive-on-every-host-drives-and-drive):
  the host lines name the drives, and `{drive}` in the command is each
  one's file.

The output below is from the test suite's run of this study
(`tests/test_fio_study.sh`), with the real doe and a stand-in fio whose
read IOPS is a hill with its top at iodepth 60 and 6 jobs. A real drive's
numbers are noisier; what to read in them is the same.

## 1. The screen: which settings matter

```bash
qd doe init fio                              # writes fio-screen.json
$EDITOR fio-screen.json                      # fixed_factors.filename: a file on the drive
echo db07 > host.txt
qd doe run fio-screen.json -s host.txt       # 8 points, about 10 minutes
qd doe analyze fio-screen                    # every response; -c read_iops for one
```

`fio-screen.json` is a Plackett-Burman design: seven settings (`bs`,
`iodepth`, `numjobs`, `rwmixread`, `rw`, `ioengine`, `direct`) at two
levels each, in eight runs. The levels are a starting proposal; change
them in the file before the first run if your drive calls for others
([the screen](larger-jobs.md#a-screen-of-fios-parameters-qd-doe-init-fio)
gives the reason for each). `qd doe analyze` ranks the settings for each
of eight responses (read and write IOPS, bandwidth, mean and p99
latency):

```
  read_iops  big: iodepth 81% (max 32)
             then: numjobs 19%, direct 0%, rw 0%, bs 0%, rwmixread 0%, ioengine
             0%
```

**What you decide here: which response to optimise.** The screen does not
choose it for you. Pick the one that matters for the drive's work (read
IOPS for a database's random reads, say) and look at what moves it. A
setting with a big share is worth a closer look; the rest can be held.

## 2. Seeing the effects

```bash
qd doe analyze fio-screen -c read_iops --report   # doe's plots and HTML report, kept
qd web                                            # the screen's page: its charts
```

On the screen's page in `qd web`: a Pareto chart of the effect sizes, a
main-effects chart for each setting (the mean response at each level),
and an interaction chart for any two (lines that are not parallel are an
interaction). `--report` keeps doe's own report and plots, and the page
links it. A screen's main effects can hide interactions (eight runs for
seven settings measure nothing twice): the follow-up is what separates
them ([seeing the effects](larger-jobs.md#designed-experiments-qd-doe)).

## 3. The follow-up: the big settings, between their levels

```bash
qd doe next fio-screen -c read_iops          # writes fio-screen-read-iops-ccd.json
```

qd analyses the screen for the one response and writes a central
composite or Box-Behnken design, doe's choice for that many settings:

```
qd doe -- wrote fio-screen-read-iops-ccd.json: central-composite on 2 factors, 16 points
  factor     level(s)                 effect  why
  iodepth    1 / 32                   81%     varied: the screen's range
  numjobs    1 / 8                    19%     varied: the screen's range
  direct     1                        0%      held: its better level
  rw         randrw                   0%      held: its better level
  ...
  note      numjobs added: the next largest numeric effect, so the surface has
            two dimensions
```

Only numeric settings are varied (a central composite cannot vary `rw`
or `ioengine`); everything else is held at the level the screen found
better, and what the screen held (the file, the size) stays held. The
file is yours to edit: another range, a setting added (`--factors`) or
taken out ([the follow-up](larger-jobs.md#the-follow-up-qd-doe-next-and-qd-doe-run---like)).

## 4. The follow-up, on the same host and drive

```bash
qd doe run fio-screen-read-iops-ccd.json --like fio-screen
```

`--like` runs it on exactly the hosts the screen ran on, with the
screen's command and the file it wrote, and refuses another file. A host
that has gone is named, and the run exits 1.

## 5. Every run of the study, side by side

```bash
qd doe status fio-screen                       # the study's designs, how far each got
qd compare --study fio-screen -c read_iops --sort -read_iops
qd web                                         # Studies: the same table, sortable, and a chart
```

The screen and every design that follows it are one study, named for the
screen. `qd compare --study` puts every run of all of them in one table,
each setting a column (a held setting shows the level it was held at):

```
qd compare --study fio-screen -- 2 designs, 24 rows (a run on one host each); ...
  fio-screen-read-iops-ccd: central composite, following fio-screen for
      read_iops, 16 of 16 points measured; varies iodepth numjobs; holds bs=4
      direct=1 ioengine=libaio rw=randrw rwmixread=30

  design                    point  host  read_iops  bs   iodepth  numjobs  ...
  fio-screen-read-iops-ccd     12  a         81000    4       32        8  ...
```

Step 7's rounds join the same study, so this is also where you watch
them ([a study](larger-jobs.md#a-study-every-run-of-it-qd-compare---study-and-qd-web)).

## 6. The response surface: where the best settings are

```bash
qd doe surface fio-screen-read-iops-ccd
qd doe surface fio-screen-read-iops-ccd --report   # and doe's surface plots, for qd web
```

doe fits a quadratic surface to the follow-up and finds where it is
flat:

```
  stationary a maximum, outside the design region: read_iops = 90138, give or
             take 74.9 (doe's cross-validated error; it gives no prediction
             interval)
    factor   stationary  coded   best inside  coded
    iodepth      60.316  +2.827           32  +1.000
    numjobs     6.02358  +0.435      6.00463  +0.430
  so         the best point inside the design region is on its edge (iodepth
             at its high level): the maximum lies beyond it, so another round
             is needed, moved that way
```

Read the last line first. **Inside**: the optimum is in the region
measured, and one confirmation run there settles it. **On its edge**: the
best is beyond the levels measured (here, more iodepth than the screen's
32), and another round is needed. A design's page in `qd web` draws the
surface as contours, with the design's points, the stationary point and
the best point inside ([the response surface](larger-jobs.md#the-response-surface-qd-doe-surface)).

## 7. Rounds until the optimum, and the command to use

```bash
qd doe optimize fio-screen -c read_iops --budget 80
```

qd runs the rounds itself, straight through: while the best point is on
the region's edge, doe's steepest-ascent path, one step at a time until
a step is no better; then a new central composite around the best point
measured; once the optimum is inside, more points near it (doe's
next-batch), then three confirmation runs at doe's predicted optimum.

```
qd doe optimize -- the best point inside fio-screen-read-iops-ccd is on its edge (iodepth at its high level): doe's steepest ascent from its centre, ...
  step 1: read_iops = 76780 (doe's line said 75014), better: on
  ...
  step 6: read_iops = 89650 (doe's line said 109899), no better than 89770: the path ends here
qd doe optimize -- a central composite around the best point measured, iodepth=55 numjobs=6 ...: fio-screen-read-iops-region1, iodepth 40..72 numjobs 3..11
qd doe optimize -- the maximum is inside fio-screen-read-iops-region1: doe next-batch (refine) adds 4 points near it, points 17 to 20
qd doe optimize -- confirmation: 3 runs at iodepth=60 numjobs=6, where doe predicts read_iops = 89992 +/- 71.96 (fio-screen-read-iops-confirm1)

qd doe optimize -- fio-screen: read_iops, an optimum found
  why        the confirmation runs measured read_iops = 89980 (mean of 3),
             inside doe's prediction 89992 +/- 71.96, and the round improved
             the best measured by 0.3% (under 2%)
  budget     29 of 80 runs made (29 in this run)
  recommend  the settings confirmed at doe's predicted maximum
    factor   starting  recommended
    iodepth        16           60
    numjobs         4            6
  measured   read_iops = 89980, mean of 3 runs (89960 to 90000, sd 20)
  starting   read_iops = 69442 at the centre of fio-screen-read-iops-ccd: the
             recommendation is 29.6% better
  optimum    a local maximum, the best of the region searched (iodepth 1 to
             72, numjobs 1 to 11), and the best the study has measured
             anywhere (53 points); a region not searched may still hold a
             better one
  command    fio --name=qd-screen --filename=/srv/scratch/qd-fio.dat --size=8G
             --time_based --runtime=60 --ramp_time=10 --group_reporting
             --output-format=json --rw=randrw --rwmixread=30 --bs=4k
             --iodepth=60 --numjobs=6 --ioengine=libaio --direct=1
```

**The answer is the `command` line**: the screen's command with the
recommended settings and everything the study held. It stops when the
confirmation runs agree with doe's prediction and the last round gained
under 2%, or when the budget is spent; the exit status is 0 only for a
confirmed optimum. Out of budget, the same command with a larger
`--budget` carries on where it stopped, and so does one that was
interrupted ([rounds until an optimum](larger-jobs.md#rounds-until-an-optimum-qd-doe-optimize)).

Read the `optimum` line before using the answer: it is the best of the
region searched, a local optimum. Settings the screen held (`bs`, `rw`,
`direct`) were never varied after it, so the answer is the best for those
held levels. A study for another response (write IOPS, p99 latency)
starts again at step 3 with its own `qd doe next -c`.

**When it stops short.** Confirmation runs that disagree with doe's
prediction, or a round that still gained 2% or more, mean another round
of points near the optimum and another confirmation. When the budget runs
out first, or doe proposes nothing new, qd says why, recommends the best
settings measured (marked not confirmed) and exits 1. doe 0.5.0 can also report no
best point for a region whose fit is good, when its optimiser flags the
search as not converged; qd then stops with "doe optimize found no best
point inside ... to confirm". The best point measured is still
recommended, and a `qd run` of its command at those settings is the
confirmation.
