<!--
SPDX-License-Identifier: GPL-3.0-or-later
SPDX-FileCopyrightText: 2026 Martin J. Gallagher
-->

# Telemetry, the floor plan and export

A run beside the telemetry (`qd join`), painted on the floor plan (`qd
floor`), and sent on to Splunk, Prometheus or a notebook (`qd export`).
Part of [the manual](README.md).

## Beside the telemetry: `qd join`

A benchmark row says what a host did. The telemetry another system kept
says what it was going through at the time: inlet temperature, power draw,
link errors. `qd join` puts the two side by side, matched by host and by
**time window**: for each row, each metric's samples from that host
inside the window it was measured in, reduced to a few figures.

```bash
qd import splunk-export.csv --telemetry        # keep an export as a dataset
qd join iperf latest                           # each iperf row, with the mean and max of each metric
qd join iperf splunk-export.csv --window +-30 --agg mean,max,p99 --metrics 'temp*,power*'
qd join latest export.csv --map cloudvision.map --alias bmc-names.txt
qd join iperf latest --where 'inlet_temp_c_max>35' --format csv -o hot.csv
```

```text
qd join -- 20261110-180048-iperf:data with 20261110-180051-splunk_csv: 6 rows; 2 metrics x mean, max; window run
  matched   5 of 6 rows had samples in their window
  note      windows: each host's own, from qd.hosts: when qd started it and how long it took
  note      telemetry: 210 samples kept for the run's hosts and windows, of 700 rows read from ...
  note      1 row with nothing in the window (blank, not 0): node05

host    window_from               window_to                 telemetry_host          inlet_temp_c_mean  inlet_temp_c_max  power_w_mean  power_w_max  rack  ...  mbps
node01  2026-11-10T18:00:47.109Z  2026-11-10T18:00:48.119Z  node01.dc1.example.com               25.3              26.9         439.9          468  r1    ...  9363
node03  2026-11-10T18:00:47.109Z  2026-11-10T18:00:48.119Z  node03.dc1.example.com              31.52              32.9         441.8          470  r1    ...  9289
node05  2026-11-10T18:00:47.110Z  2026-11-10T18:00:48.120Z                                                                                          r2    ...  9215
```

The joined table is the run's own columns, then `window_from` and
`window_to` (UTC, to the millisecond), `telemetry_host` (what the
telemetry called the host), and a `METRIC_FIGURE` column for each metric
and figure. In text the host comes first and the figures next, since a
terminal cuts from the right; `--format` writes the table in its own
order. `--where` reads the joined columns, so it can filter on the
telemetry. **A row with no sample in its window gets blanks, never
zeros**, a `count` included, and the notes name those rows. When no row
had any telemetry at all, the exit status is 1, and the notes say the
likeliest reason: names that matched no host, or a window or zone that
missed.

**The windows.**

| The rows are | Each row's window |
|---|---|
| a fan-out (`qd run`, a probe, a campaign's part, a design point) | its host's own, from `qd.hosts`: when qd started it (`ts`) and how long it took (`duration_s`), per pass |
| `qd do` | the run's own start and finish |
| anything, with `--time COL` | the row's own time, `--window +-N` either side of it |
| anything, with `--time START,END` | the row's own start and end |

An import, a `ds:NAME` dataset or a file says nothing of when it was
measured (an import keeps when it was imported), so those need `--time`.
`ts` is kept to the millisecond from 0.12.0. Runs filed before kept the
whole second, so their windows run a second longer to cover what was cut
off, and the notes say so. A sample counts when its time is at or after
the start and at or before the end: both edges are in.

**`--window +-N`** widens each window by N seconds either side (`+-30`,
`30s`, `2m`, `500ms`, `±30`). Telemetry sampled every 30 s may have no
sample inside a ten-second test at all, and two clocks rarely agree. The
windows are this machine's clock. The samples carry the hosts' (or their
collectors'). So `qd join` reads the latest `qd probe skew` in the store
(binnacle's skew, run on every host), and names each host whose clock was
further out than the window reaches, with the `--window` that would cover
it. `--skew RUN` reads another; `--skew none` reads none. Without a skew
run, the notes say that nothing has checked the clocks.

**Figures (`--agg`)**: `mean` and `max` unless told. Also `min`, `median`,
`p05`, `p25`, `p75`, `p95`, `p99` (linear between ranks, as `qd stats`),
`stdev`, `count`, `first` and `last` (by time), and, for counters,
`delta` (last less first) and `rate` (delta per second). `--metrics`
keeps some metrics by name or pattern (`'temp*,if_*_errors'`).

**Hosts** are matched by name: the alias file's first, then the run's
name exactly, then without case, then without a `:port` (Prometheus's
`instance`), then the short name (`node01` for `node01.dc1.example.com`)
when only one host of the run has it. A fan-out's addresses count as its
hosts' names too. A BMC or a switch port has a name of its own, so give an
alias file, one line per host: the run's name first, then the names the
telemetry uses.

```text
# bmc-names.txt: the run's name, then what the telemetry calls it
node01  node01-bmc  node01-ipmi.oob.example.com
node02  node02-bmc
```

The notes list the names in the telemetry that matched no host of the run,
with how many samples each had, and any name that fits two hosts and so
matches neither.

### Telemetry exports

`qd` reads an export **from a file**, never from Splunk or CloudVision
directly. No API client, no credentials, no network. Export with the
other system's own tools, then join or import the file. Exports can be
big: `qd join` reads a CSV, TSV or NDJSON export a line at a time and
keeps only the samples of the run's hosts inside its windows. NDJSON is
read twice, once for every line's keys, since collectors write different
fields on different lines. A JSON list is read whole: the standard library
has no streaming reader for one.

Two shapes are read: **long**, a row per sample (`time, host, metric,
value`), or **wide**, a column per metric (`time, host, temp, power`).
Columns are found by name: the time in `_time`, `time`, `timestamp`,
`ts`, `@timestamp` or `datetime`; the host in `host`, `hostname`,
`device`, `node`, `instance`, `target`, `server`, `tags.host` or
`tags.source` (nested JSON keys are joined with dots); the metric in `metric`,
`metric_name`, `__name__`, `name`, `path`, `key` or `field`; the value in
`value`, `_value`, `val` or `reading`. With a time and a host but no metric
and value, every other column is a metric, apart from Splunk's own fields
(`_*`, `date_*`, `index`, `source`, `sourcetype`, `linecount`, `punct`
...). Times are epoch seconds, milliseconds, microseconds or nanoseconds
(told apart by size), or ISO 8601. A time that names no zone is UTC. A
blank or non-numeric reading is not a sample, and neither is a time that
cannot be read. The notes count them.

| Export | Usually |
|---|---|
| Splunk: `... \| table _time host metric value`, *Export* as CSV | read as it is |
| Splunk: `... \| timechart span=10s avg(temp) by host` | wide, one column per host: export it `\| untable _time host temp` first, so that each row is one host's sample |
| Prometheus samples written out as CSV (`timestamp, instance, __name__, value`, say from its HTTP API's `query_range`) | read as it is; `instance`'s `:9100` is ignored |
| Telegraf's JSON output (NDJSON), from its `gnmi`, `ipmi_sensor` or `redfish` inputs among others | read as it is: `tags.host` (or `tags.source`, gnmi's) is the host and every field a metric (`fields.temp_c`) |
| CloudVision, or anything else, exported as CSV | a map naming its time and device columns, and its metrics |
| BMC or switch logs kept in local time | a map with `tz` |

**A column map** (`--map FILE`) says which column is which, for an export
whose names qd does not know. One `KEY VALUE` a line, `#` for comments:

```text
# cloudvision.map
time         Time
host         Device
metrics      Inlet Temp, Power Supply 1 Output Power   # wide: these columns
time_format  %d/%m/%Y %H:%M:%S                         # strptime, when not epoch or ISO 8601
tz           +01:00                                    # for times that name no zone
```

Instead of `metrics`, `metric COLUMN` and `value COLUMN` name a long
export's. `metrics *` takes every other column. `tz` is UTC or a fixed
offset: a zone name would need Python 3.9, and an export's times are in
one offset anyway (export in UTC where you can).

**`qd import EXPORT --telemetry`** (or `--map FILE`, or `--alias FILE`)
keeps an export as a run with one table, `telemetry`: `time` (UTC, ISO
8601 to the millisecond), `host`, `metric` and `value`, whatever shape it
arrived in. Several files become one table. `--alias` keeps each alias's
samples under the run's name for the host. `qd join RUN IMPORT` then reads
it from the store: from another one with `IMPORT@STORE`, and on the
**Telemetry** tab of `qd web`.

---

## On the floor plan

```bash
qd floor latest --layout floor.dc          # write the overlay and open dcviz
qd export latest --format overlay -o load.tsv
```

Each numeric column becomes an overlay named `qd_<column>` (`--prefix`),
one sample per host (per pass, for a run that repeated, which the viewer
reduces with its own mean, p95, last, ...), tagged `run=<run id>`. A host's `status` becomes a
PASS/FAIL overlay, so an unreachable host paints red rather than
disappearing. Free text (stdout, errors) and layout attributes (rack,
row) stay out. A unit is taken from a column's name where the name says
it (`_pct` is %, `_us` is µs, `_mbps` is Mb/s) and never guessed
otherwise. A dataset that's already in the viewer's format (mx export,
reckon) passes through unchanged.

---

## Into Splunk, Prometheus or a notebook

`qd export` writes a file in the other system's own format. qd makes no
network call and holds no token: send the file from wherever has the
credentials, or let the other side's file reader pick it up.

```bash
qd export latest --format hec -o run.json            # Splunk HEC events
curl -s https://splunk:8088/services/collector \
     -H "Authorization: Splunk $HEC_TOKEN" --data-binary @run.json

qd export latest --format openmetrics --labels rack \
     -o /var/lib/node_exporter/textfile/qd.prom      # node_exporter textfile
curl -s --data-binary @qd.prom http://pushgw:9091/metrics/job/qd   # or a Pushgateway
```

**`--format hec`** is one event per row, one per line:
`{"time", "host", "source": "qd", "sourcetype": "qd:<table>", "fields",
"event"}`. `event` is the row; `fields` (indexed, so a search can filter
on them without reading the event) are the run's id, name and kind as
`qd_run`, `qd_name`, `qd_kind`, and the row's settings: host attributes
such as `rack`, a design's factors. `time` is the row's own (`ts`,
`timestamp` or `time`, epoch or ISO 8601) where it has one, else the
run's, and qd says how many borrowed it; a file that is not a run has no
time to lend, so those events go without and Splunk stamps them on
arrival. `--sourcetype` and `--index` set those two. Splunk's file monitor
reads the same file with the `_json` sourcetype.

**`--format openmetrics`** (or `-o x.prom`) is one gauge per numeric
column, `qd_<column>` (`--prefix`), one sample per row that measured it,
labelled `host`, `peer` (when there is one), `run`, and the columns named
in `--labels`. Sizes go over in bytes and times in seconds, and the name
says so (`qd_mem_bytes`, `qd_lat_seconds`); any other unit is named in the
`# HELP` line, and `%` adds `_percent`. A column becomes a label only when
you name it: every distinct value is another series, so a free-text
column as a label would flood the server. Two rows that would make the
same series (two disks on one host) are refused, naming `--labels`, rather
than written as a file Prometheus rejects. There are no timestamps: the
textfile collector and the Pushgateway both refuse them.

In both, **a blank cell is left out** -- absent from the event, no sample
in the metric -- never sent as 0 or an empty string.

For a notebook, the CSV is already the format:

```python
import pandas as pd
df = pd.read_csv("run.csv")          # qd export latest -o run.csv
df.groupby("rack")["mbps"].describe()   # blanks read as NaN: not measured
```
