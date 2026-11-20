<!--
SPDX-License-Identifier: GPL-3.0-or-later
SPDX-FileCopyrightText: 2026 Martin J. Gallagher
-->

# The quarterdeck manual

Organised by what you are trying to do. New to qd: start with the first
two. `qd --help` is the reference card, `qd help VERB` one verb's flags.
The front page is [the README](../README.md).

- **[Getting started](getting-started.md)**: ten minutes on the demo fleet, a question a step.
- **[Concepts](concepts.md)**: the words every command assumes, and every way to name a run.
- **[Running: commands, probes and tools on many hosts](running.md)**
  - [A fleet to learn on: `qd demo`](running.md#a-fleet-to-learn-on-qd-demo)
  - [Your own fleet, the first time: `qd setup`](running.md#your-own-fleet-the-first-time-qd-setup)
  - [Running commands on many hosts: `qd run`](running.md#running-commands-on-many-hosts-qd-run)
  - [Who agrees, who differs: `qd ask`](running.md#who-agrees-who-differs-qd-ask)
  - [Asking by name: `qd probe`](running.md#asking-by-name-qd-probe)
  - [Driving the toolchain: `qd do`](running.md#driving-the-toolchain-qd-do)
  - [At scale](running.md#at-scale)
- **[Reading the answers: tables, statistics, a terminal, a browser](reading.md)**
  - [Reading it back](reading.md#reading-it-back)
  - [In a terminal: `qd view`](reading.md#in-a-terminal-qd-view)
  - [In a browser: `qd web`](reading.md#in-a-browser-qd-web)
- **[Over time: many runs, peers and baselines](over-time.md)**
  - [Many runs side by side: `qd compare`](over-time.md#many-runs-side-by-side-qd-compare)
  - [Peer groups and qualified baselines: `qd peers`, `qd baseline`](over-time.md#peer-groups-and-qualified-baselines-qd-peers-qd-baseline)
- **[Judging: requirements, waivers and test reports](judging.md)**
  - [Against requirements: `qd check`](judging.md#against-requirements-qd-check)
  - [For a test report: `qd report`](judging.md#for-a-test-report-qd-report)
- **[Larger jobs: split, coverage, campaigns and experiments](larger-jobs.md)**
  - [Cutting a host list: `qd split`](larger-jobs.md#cutting-a-host-list-qd-split)
  - [Which hosts have had it: `qd coverage`](larger-jobs.md#which-hosts-have-had-it-qd-coverage)
  - [A system in parts: `qd campaign`](larger-jobs.md#a-system-in-parts-qd-campaign)
  - [Designed experiments: `qd doe`](larger-jobs.md#designed-experiments-qd-doe)
- **[A fio tuning study, start to finish](fio-study.md)**: a drive's best fio settings in seven `qd doe` steps.
- **[Telemetry, the floor plan and export](telemetry-and-export.md)**
  - [Beside the telemetry: `qd join`](telemetry-and-export.md#beside-the-telemetry-qd-join)
  - [On the floor plan](telemetry-and-export.md#on-the-floor-plan)
  - [Into Splunk, Prometheus or a notebook](telemetry-and-export.md#into-splunk-prometheus-or-a-notebook)
- **[Stores: where the answers are kept](stores.md)**
  - [What it keeps: provost's store](stores.md#what-it-keeps-provosts-store)
- **[Conventions and exit status](conventions.md)**
  - [Conventions](conventions.md#conventions)
  - [Exit status](conventions.md#exit-status)
- **[Contributing: tests and working on quarterdeck](contributing.md)**
  - [Tests](contributing.md#tests)
  - [Working on quarterdeck](contributing.md#working-on-quarterdeck)
- **[How far qd's fan-out goes](scale.md)**: the measurements behind *At scale* in Running.
