#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Martin J. Gallagher
#
# test_export.sh -- qd export's formats for other systems: Splunk HEC
# events and Prometheus/OpenMetrics text (QD-013).


set -u
source "$(dirname "${BASH_SOURCE[0]}")/test_helper.bash"

seed() {
    install_fake_ssh
    for h in node01 node02 node03; do fake_host "$h"; done
    printf 'load: 0.5\nmem: 512M\nlat: 900ms\n' > "$FAKE_ROOT/node01/m"
    printf 'load: 1.5\nmem: 2G\nlat: 1.2s\n' > "$FAKE_ROOT/node02/m"
    printf 'load:\nmem: 1G\n' > "$FAKE_ROOT/node03/m"
    fake_host_unreachable node09
    printf 'node01 rack=r1\nnode02 rack=r1\nnode03 rack=r2\nnode09 rack=r2\n' \
        > hosts.txt
    qdf_rc run -q -s hosts.txt -- cat m > /dev/null 2>&1
}

# every line of $1 is one JSON object; prints field $2 of line $3 (1-based)
jfield() {
    "$PY" -c '
import json, sys
lines = open(sys.argv[1]).read().splitlines()
for ln in lines:
    json.loads(ln)
o = json.loads(lines[int(sys.argv[3]) - 1])
for k in sys.argv[2].split("."):
    o = o.get(k) if isinstance(o, dict) else None
print("<absent>" if o is None else json.dumps(o, sort_keys=True))
' "$@"
}

t_hec_one_event_per_row() {
    seed
    qd export latest --format hec -o ev.json
    assert_eq "$(wc -l < ev.json | tr -d ' ')" "4"
    run="$(qd show latest --format csv >/dev/null; qd log latest | head -1 | cut -d' ' -f1)"
    assert_eq "$(jfield ev.json host 1)" '"node01"'
    assert_eq "$(jfield ev.json source 1)" '"qd"'
    assert_eq "$(jfield ev.json sourcetype 1)" '"qd:data"'
    assert_eq "$(jfield ev.json event.load 1)" '0.5'
    assert_eq "$(jfield ev.json event.mem 1)" '"512M"'
    assert_eq "$(jfield ev.json fields.qd_run 1)" "\"$run\""
    assert_eq "$(jfield ev.json fields.qd_kind 1)" '"run"'
    # a host attribute is an indexed field, so a search can filter on it
    assert_eq "$(jfield ev.json fields.rack 3)" '"r2"'
    assert_eq "$(jfield ev.json index 1)" '<absent>'
}

t_hec_blank_is_left_out() {
    seed
    qd export latest --format hec > ev.json
    # node03 measured no load and no lat: absent, never 0 or ""
    assert_eq "$(jfield ev.json host 3)" '"node03"'
    assert_eq "$(jfield ev.json event.load 3)" '<absent>'
    assert_eq "$(jfield ev.json event.lat 3)" '<absent>'
    assert_eq "$(jfield ev.json event.mem 3)" '"1G"'
    assert_not_contains "$(cat ev.json)" '""'
    assert_not_contains "$(cat ev.json)" 'null'
    # the unreachable host is an event too: its status is the finding
    assert_eq "$(jfield ev.json event.status 4)" '"unreachable"'
}

t_hec_time_is_the_run_s_without_a_row_time() {
    seed
    qd export latest --format hec > ev.json 2> err
    created="$(qd log latest | sed -n 's/^  created *//p')"
    from="$("$PY" -c '
import calendar, sys, time
print(calendar.timegm(time.strptime(sys.argv[1], "%Y-%m-%dT%H:%M:%SZ")))
' "$created")"
    t="$(jfield ev.json time 1)"
    # the run's own time (it finished within a minute of starting), as
    # epoch seconds, on every event
    if [ "$t" -lt "$from" ] || [ "$t" -gt $((from + 60)) ]; then
        fail "time $t is not the run's (created $created = $from)"
    fi
    assert_eq "$(jfield ev.json time 4)" "$t"
    assert_contains "$(cat err)" "4 rows had no time of their own"
}

t_hec_time_from_the_row() {
    printf 'host,ts,v\na,2026-05-05T14:22:01Z,1\nb,1778000000,2\nc,2026-05-05T15:22:01+01:00,\nd,,4\n' > d.csv
    qd export d.csv --format hec --index perf --sourcetype qd:bench > ev.json 2> err
    assert_eq "$(jfield ev.json time 1)" "1777990921"
    assert_eq "$(jfield ev.json time 2)" "1778000000"
    assert_eq "$(jfield ev.json time 3)" "1777990921"
    # a file is no run: no time to borrow, so none is sent, and it says so
    assert_eq "$(jfield ev.json time 4)" '<absent>'
    assert_contains "$(cat err)" "1 event had no time and no run"
    assert_eq "$(jfield ev.json index 1)" '"perf"'
    assert_eq "$(jfield ev.json sourcetype 1)" '"qd:bench"'
    assert_eq "$(jfield ev.json fields 1)" '<absent>'
    assert_eq "$(jfield ev.json event.v 3)" '<absent>'
}

t_openmetrics_gauges() {
    seed
    run="$(qd log latest | head -1 | cut -d' ' -f1)"
    out="$(qd export latest --format openmetrics)"
    assert_contains "$out" "# TYPE qd_load gauge"
    assert_contains "$out" "qd_load{host=\"node01\",run=\"$run\"} 0.5"
    assert_contains "$out" "qd_load{host=\"node02\",run=\"$run\"} 1.5"
    # sizes in bytes, times in seconds, and the name says which
    assert_contains "$out" "qd_mem_bytes{host=\"node01\",run=\"$run\"} 536870912"
    assert_contains "$out" "qd_mem_bytes{host=\"node02\",run=\"$run\"} 2147483648"
    assert_contains "$out" "qd_lat_seconds{host=\"node01\",run=\"$run\"} 0.9"
    # a blank is no sample, and free text is no metric
    assert_not_contains "$out" "qd_load{host=\"node03\""
    assert_not_contains "$out" "qd_lat_seconds{host=\"node03\""
    assert_not_contains "$out" "qd_status"
    assert_not_contains "$out" "qd_rack"
    assert_not_contains "$out" "qd_rc"
    # a column only named becomes a label
    out="$(qd export latest --format openmetrics --labels rack)"
    assert_contains "$out" "qd_load{host=\"node01\",rack=\"r1\",run=\"$run\"} 0.5"
    assert_eq "$(printf '%s\n' "$out" | tail -1)" "# EOF"
    # no timestamps: the textfile collector and the Pushgateway refuse them
    if printf '%s\n' "$out" | grep -v '^#' | awk '{ if (NF != 2) bad=1 } END { exit !bad }'; then
        fail "a sample line carries more than a name and a value"
    fi
}

t_openmetrics_escapes_and_refuses_a_clash() {
    printf 'host,disk,used\na,"sd""a",10%%\na,sdb,20%%\nb\\x,sda,30%%\n' > d.csv
    out="$(qd export d.csv --format openmetrics --labels disk -o d.prom; cat d.prom)"
    assert_contains "$out" 'qd_used_percent{host="a",disk="sd\"a"} 10'
    assert_contains "$out" 'qd_used_percent{host="b\\x",disk="sda"} 30'
    # two rows that would be one series: refused, not written half-valid
    qd_rc export d.csv --format openmetrics > out 2>&1
    assert_status "$QD_RC" 2
    assert_contains "$(cat out)" "--labels"
}

t_unknown_format_names_the_new_ones() {
    printf 'host,v\na,1\n' > d.csv
    qd_rc export d.csv --format splunk > out 2>&1
    assert_status "$QD_RC" 2
    assert_contains "$(cat out)" "hec, openmetrics"
}

run_test "hec: one event per row, run fields"        t_hec_one_event_per_row
run_test "hec: a blank cell is left out"             t_hec_blank_is_left_out
run_test "hec: the run's time without a row time"    t_hec_time_is_the_run_s_without_a_row_time
run_test "hec: the row's own time, index, sourcetype" t_hec_time_from_the_row
run_test "openmetrics: gauges, units, labels"        t_openmetrics_gauges
run_test "openmetrics: escaping, a clash refused"    t_openmetrics_escapes_and_refuses_a_clash
run_test "an unknown format names hec, openmetrics"  t_unknown_format_names_the_new_ones
finish
