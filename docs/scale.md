<!--
SPDX-License-Identifier: GPL-3.0-or-later
SPDX-FileCopyrightText: 2026 Martin J. Gallagher
-->

# How far qd's fan-out goes (QD-019)

Measured on 2026-11-09 with `tests/scale.sh`. A cloud container with 4
cores, 15 GB of memory and Python 3.13. provost 2.3.0 was on the batch
path, filing 200 answers per `provost batch`. Other test suites shared
the machine, so the wall times are upper bounds.

## Method

- Every host is the suites' fake ssh: a local `bash` in a directory of
  its own, which sleeps 0.05 s and prints one `key: value` line. What is
  timed is qd, not the network.
- For each N, `qd run` runs twice. The first run uses `--no-store`, so it
  times the fan-out alone. The second files the answers, and the
  difference is provost's filing.
- qd's own peak resident memory, threads and open file descriptors are
  sampled from `/proc` every 0.1 s.

```bash
bash tests/scale.sh 1000 5000                  # default --jobs 32
SCALE_JOBS=64 bash tests/scale.sh 300
```

## Results

| hosts | --jobs | fan-out alone | fan-out + filing | peak RSS | threads | fds |
|---:|---:|---:|---:|---:|---:|---:|
| 200 | 32 | 1.4 s | 46.9 s | 24 MB | 33 | 128 |
| 300 | 64 | 0.9 s | 71.7 s | 24 MB | 65 | 165 |
| 300 | 128 | 1.6 s | 71.8 s | 23 MB | 57 | 233 |
| 1,000 | 32 | 3.1 s | 163.2 s | 27 MB | 33 | 138 |

## What it shows

1. **The fan-out is not what limits qd.** A thousand hosts take about
   3 s at 32 at a time with this command. Memory stays near 25 MB, and
   threads stay at `--jobs` + 1, whatever the size of the fleet. Nothing
   grows with N except the list of answers.
2. **Filing is where the time goes: about 0.16 s per answer.** That is
   provost parsing and committing each capture, and qd waits on it.
   That is provost's to speed up, and PV-024 (provost's lock
   measurement) is the ticket for it. Until then, a big fleet's answers
   take minutes to file, even when the fan-out took seconds.
3. **Open files grow with `--jobs`, not with the fleet:** about 5 per
   host in flight, plus about 40. **This was a bug.** Under `ulimit -n 64`, a
   32-wide run over 100 hosts reported 81 of them *unreachable*, because
   every ssh that could not get a pipe looked like a host that did not
   answer. qd now checks first (`fleet.fit_jobs`):
   - It raises its soft limit towards the hard one.
   - If even that is too low, it runs fewer hosts at once and says so.

   macOS's default `ulimit -n` of 256 runs out near `--jobs 50`.
4. **Through one bastion, the limit is the bastion.** sshd drops
   unauthenticated connections past `MaxStartups` (10:30:100 by default),
   however fast qd is. `--rate N/s` (`QD_RATE`) spaces new connections
   evenly. Use a rate of 5 to 10 a second through a default sshd, or
   raise `MaxStartups`.

## Tree fan-out

No ticket is filed. Nothing here calls for qd on a head node fanning out
to its rack:
- The fan-out itself is seconds at a thousand hosts.
- Its resources are flat in N.
- The two limits found, filing and a bastion's `MaxStartups`, are not
  helped by a second hop.
- QD-008's pdsh and srun launchers fan out natively, where a site has
  them.

## Not yet measured

- **5,000 hosts:** at the filing rate above, that run is about 15 minutes
  of filing, and it was not run while other suites shared the machine.
  Run `bash tests/scale.sh 5000` on a quiet machine to add the row.
- **`qd probe facts`:** it runs a Python script on each host, so it costs
  more per host than this command. Run `SCALE_VERB=probe bash
  tests/scale.sh 1000` to measure it.
