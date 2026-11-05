<!--
SPDX-License-Identifier: GPL-3.0-or-later
SPDX-FileCopyrightText: 2026 Martin J. Gallagher
-->

# Notes for Claude

## What this is

`qd` drives the toolchain (binnacle, matrix_orchestrator, iperf_orchestrator,
datacenter_visualization, design_of_experiments) and keeps what comes back in
provost's store. It reads their output; it does not reimplement them. When a
tool's output format or flags change, `quarterdeck/tools.py` (what `qd do`
reads back), `quarterdeck/probes.py` (what `qd probe` runs) and
`quarterdeck/table.py` (the readers) are where that knowledge lives; what qd
knows of provost's store is in `quarterdeck/store.py` (reading) and
`quarterdeck/filing.py` (filing, only ever by running provost), and which
store a command uses -- named stores, their export and import, remote
stores read from a git copy -- is `quarterdeck/stores.py`.

## Rules that hold everywhere

- **Use the toolchain; never reinvent it.** If a tool in any
  MartinGallagher-code repository already does something -- provost
  parsing and keeping, binnacle measuring (why-slow, skew, reachable,
  muster, manifest), dcprobe, doe designing and analysing -- qd calls it
  (as a command where it needs a newer Python) and does only what is
  left. Survey the repos before building anything new.
- **Blank is not measured, never zero**, through every reader, statistic,
  pivot and diff.
- **The web page computes nothing.** Every figure comes from the Python
  engine through `quarterdeck/web.py`, so the browser and the terminal
  cannot disagree. Add a figure to the engine and the API, not to app.js.
  Anything from a dataset goes into the page with `textContent`.
- **Standard library only, Python 3.6 floor** (`tests/check_python_compat.sh`
  here, vermin in CI). No f-strings, by the house style.
- **Every change moves the version**: `quarterdeck/__init__.py`,
  `pyproject.toml`, and a `## X.Y.Z — YYYY-MM-DD` section at the top of
  `CHANGELOG.md`, all in the same pull request.
- `--help` stays a reference card; README.md is the manual.

## Tests

```bash
bash tests/check.sh                    # before pushing: everything CI runs that runs here
bash tests/run_tests.sh [SUITE...]     # the suites alone; QD_TEST_ONLY=TEXT for some cases
```

`tests/check.sh` runs the version check, the 3.6 checks, shellcheck, `node
--check`, `reuse lint`, the wheel build and the suite on both provost paths,
skipping (and naming) what is not installed. README's "Working on
quarterdeck" is the setup.

No network: a fake ssh/scp, stand-in tools, `QD_TEST_KEYS` for the
explorer, and a real server on loopback for the web API -- but a real
provost (`QD_PROVOST` or `provost` on PATH; CI installs PyPI's newest, and
2.1.0 in one job), and the real binnacle and doe where installed. Run them
on both of provost's paths before pushing: with a provost that has `batch`,
and with `QD_PROVOST_BATCH=0` (or PyPI's 2.1.0), which files one capture at
a time. The page's look is checked by hand in a browser; there is deliberately no browser-driving
test in the tree. A test that starts a server, spawns a process and drives
a browser is the shape upload scanners refuse in a handover --
datacenter_visualization's `tests/browser.mjs` was refused for exactly that,
per shared_tools' CLAUDE.md.

## Every task is a ticket

Everything done here goes through a ticket in `MartinGallagher-code/shared_tools`,
which keeps every project's tickets as files and moves each one Backlog → In Progress
→ Review → Done (Adversarial Test only when the owner asks). Before any change:

1. Attach `MartinGallagher-code/shared_tools` with `add_repo` and push access, and
   clone it. If a clone is already here, pull it instead
   (`git -C <shared_tools clone> pull --ff-only`): a stale clone has a stale
   `CLAUDE.md` and a stale `ticket.py`.
2. Read the "Every task is a ticket" section of its `CLAUDE.md`. It sets out what each
   column requires, and none of it is optional.
3. Open the ticket with the shared_tools clone's script, not a path in this
   repository:

   ~~~bash
   <shared_tools clone>/scripts/ticket.py new quarterdeck "Imperative title" --request "the request, in the user's own words"
   ~~~

The board: https://claude.ai/artifact/HrB3RpVpqGGQS7UZgZsMJm

## Bundling this repo

When packing this repository into a text bundle for handover, use the
canonical scripts in
[`shared_tools`](https://github.com/MartinGallagher-code/shared_tools)
(`scripts/handover.sh`, or `merge.sh`, `split.sh`, `b64bundle.sh`) and read
that repo's `CLAUDE.md` first.

**Never include git internals in the bundle.** Export with
`git archive main | tar -x -C /tmp/tree`, never a working tree or a plain
`cp -r` of a live checkout; `.git/config` can carry credentials. `docs/*.png`
are README screenshots: payload in a handover.
