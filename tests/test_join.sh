#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Martin J. Gallagher

# qd join: a run's rows beside another system's telemetry, by host and time
# window; qd import --telemetry, which keeps an export for it.  Most cases
# give the rows' windows as times of their own (--time), so every edge and
# every figure is known in advance; one runs a real fan-out and builds the
# telemetry from the windows qd.hosts kept.

set -u
source "$(dirname "${BASH_SOURCE[0]}")/test_helper.bash"

# A run of three hosts, each measured from 10:00:00 to 10:01:00 UTC.
rows_csv() {
    printf 'host,start,end,mbps\n' > rows.csv
    for h in node01 node02 node03; do
        printf '%s,2026-11-10T10:00:00Z,2026-11-10T10:01:00Z,9400\n' "$h" \
            >> rows.csv
    done
}

# The CSV row qd join wrote for HOST (the first column), from FILE.
row_of() { grep "^$1," "$2"; }

t_window_edges_count_both_ends() {
    rows_csv
    cat > tel.csv <<'EOF'
_time,host,metric,value
2026-11-10T09:59:59.999Z,node01,temp_c,99
2026-11-10T10:00:00.000Z,node01,temp_c,40
2026-11-10T10:00:30Z,node01,temp_c,50
2026-11-10T10:01:00Z,node01,temp_c,60
2026-11-10T10:01:00.001Z,node01,temp_c,98
EOF
    qd join rows.csv tel.csv --time start,end --agg min,max,count \
        --skew none --format csv > out.csv
    # 10:00:00 and 10:01:00 are in; a millisecond either side is not
    assert_contains "$(row_of node01 out.csv)" \
        ",2026-11-10T10:00:00.000Z,2026-11-10T10:01:00.000Z,node01,40,60,3"
}

t_figures_match_hand_computed() {
    rows_csv
    # 10, 20, 30, 40 at 0, 10, 20 and 30 s past the start, out of order
    cat > tel.csv <<'EOF'
_time,host,metric,value
2026-11-10T10:00:20Z,node01,load,30
2026-11-10T10:00:00Z,node01,load,10
2026-11-10T10:00:30Z,node01,load,40
2026-11-10T10:00:10Z,node01,load,20
EOF
    qd join rows.csv tel.csv --time start,end --skew none --format csv \
        --agg mean,max,min,median,p05,p25,p75,p95,p99,stdev,count,first,last,delta,rate \
        > out.csv
    # by hand: quantiles linear between ranks over 10 20 30 40 (p05 at
    # rank 0.15: 11.5; p25 0.75: 17.5; p75 2.25: 32.5; p95 2.85: 38.5; p99
    # 2.97: 39.7); stdev sqrt(500/3) = 12.91; first and last by time, not
    # by place in the file; delta 40-10; rate 30 over 30 s
    assert_contains "$(head -1 out.csv)" "load_mean,load_max,load_min,load_median,load_p05,load_p25,load_p75,load_p95,load_p99,load_stdev,load_count,load_first,load_last,load_delta,load_rate"
    assert_contains "$(row_of node01 out.csv)" \
        ",node01,25,40,10,25,11.5,17.5,32.5,38.5,39.7,12.91,4,10,40,30,1"
}

t_a_host_without_telemetry_is_blank_not_zero() {
    rows_csv
    printf '_time,host,metric,value\n2026-11-10T10:00:05Z,node01,temp_c,40\n' \
        > tel.csv
    qd join rows.csv tel.csv --time start,end --agg mean,count --skew none \
        --format csv > out.csv
    assert_contains "$(row_of node01 out.csv)" ",node01,40,1"
    # node02: its window, then nothing -- not 0, not a count of 0
    assert_contains "$(row_of node02 out.csv)" \
        ",2026-11-10T10:00:00.000Z,2026-11-10T10:01:00.000Z,,,"
    assert_not_contains "$(row_of node02 out.csv)" ",0"
    out="$(qd join rows.csv tel.csv --time start,end --skew none 2>&1)"
    assert_contains "$out" "2 rows with nothing in the window (blank, not 0): node02, node03"
    # nothing at all in any window is a finding: exit 1
    printf '_time,host,metric,value\n2026-11-10T11:00:00Z,node01,temp_c,40\n' \
        > late.csv
    qd_rc join rows.csv late.csv --time start,end --skew none > /dev/null 2>&1
    assert_status "$QD_RC" 1
    qd_rc join rows.csv late.csv --time start,end --skew none > err 2>&1
    out="$(cat err)"
    assert_contains "$out" "no row had any telemetry in its window"
}

t_hosts_matched_by_alias_fqdn_case_and_port() {
    printf 'host,start,end\n' > rows.csv
    for h in node01 node02 node03 node04 web.a.example web.b.example; do
        printf '%s,2026-11-10T10:00:00Z,2026-11-10T10:01:00Z\n' "$h" >> rows.csv
    done
    cat > tel.csv <<'EOF'
_time,host,metric,value
2026-11-10T10:00:05Z,node01.dc1.example.com,temp_c,41
2026-11-10T10:00:05Z,NODE02,temp_c,42
2026-11-10T10:00:05Z,node03:9100,temp_c,43
2026-11-10T10:00:05Z,node04-bmc,temp_c,44
2026-11-10T10:00:05Z,web,temp_c,45
EOF
    printf '# the run name, then what the BMCs are called\nnode04 node04-bmc\n' \
        > aliases.txt
    qd join rows.csv tel.csv --time start,end --alias aliases.txt --agg max \
        --skew none --format csv > out.csv
    assert_contains "$(row_of node01 out.csv)" ",node01.dc1.example.com,41"
    assert_contains "$(row_of node02 out.csv)" ",NODE02,42"
    assert_contains "$(row_of node03 out.csv)" ",node03:9100,43"
    assert_contains "$(row_of node04 out.csv)" ",node04-bmc,44"
    # `web` is the short name of two hosts: it matches neither
    assert_contains "$(row_of web.a.example out.csv)" ".000Z,,"
    out="$(qd join rows.csv tel.csv --time start,end --alias aliases.txt \
        --skew none 2>&1)"
    assert_contains "$out" "names that fit more than one host, so match none: web"
    # without the alias file, node04-bmc is named as matching nothing
    out="$(qd join rows.csv tel.csv --time start,end --skew none 2>&1)"
    assert_contains "$out" "no samples at all for node04"
    assert_contains "$out" "matched no host of the run: node04-bmc (1)"
}

t_window_widened_for_skew() {
    rows_csv
    # a sample 5 s after the window: a host whose clock runs 5 s fast
    printf '_time,host,metric,value\n2026-11-10T10:01:05Z,node01,temp_c,40\n' \
        > tel.csv
    qd_rc join rows.csv tel.csv --time start,end --skew none --format csv > /dev/null 2>&1
    assert_status "$QD_RC" 1
    for w in +-5 5s run+-5s 5000ms; do
        qd join rows.csv tel.csv --time start,end --window "$w" --agg max \
            --skew none --format csv > out.csv
        assert_contains "$(row_of node01 out.csv)" \
            ",2026-11-10T09:59:55.000Z,2026-11-10T10:01:05.000Z,node01,40"
    done
    # one time per row is an instant: the window is around it
    printf 'host,at\nnode01,2026-11-10T10:01:00Z\n' > at.csv
    qd join at.csv tel.csv --time at --window +-5 --agg max --skew none \
        --format csv > out.csv
    assert_contains "$(row_of node01 out.csv)" ",node01,40"
}

t_clock_skew_from_a_stored_skew_run() {
    install_fake_ssh
    for h in node01 node02; do fake_host "$h"; done
    # binnacle skew --csv, as `qd probe skew` files it: node01 2.5 s fast
    cat > "$FAKE_ROOT/node01/skew.csv" <<'EOF'
host,ts,rule_id,severity,title,detail,fix
node01,1794330000,CLOCK_OFFSET,WARN,the clock is wrong,2.5s fast the 1 source that answered,"Every timestamp this box writes is 2.5s fast."
EOF
    cat > "$FAKE_ROOT/node02/skew.csv" <<'EOF'
host,ts,rule_id,severity,title,detail,fix
node02,1794330000,OK,INFO,nothing wrong,no rule fired,
EOF
    qdf run -S node01,node02 --name skew -q -- cat skew.csv > /dev/null
    rows_csv
    printf '_time,host,metric,value\n2026-11-10T10:00:05Z,node01,temp_c,40\n' \
        > tel.csv
    out="$(qd join rows.csv tel.csv --time start,end --skew skew 2>&1)"
    assert_contains "$out" "clocks: node01 2.5s fast"
    assert_contains "$out" "--window +-3s covers it"
    assert_contains "$out" "checked no clock of node03"
    # node02's clock was fine: no word of it
    assert_not_contains "$(printf '%s\n' "$out" | grep 'clocks:')" "node02"
    # a window that reaches past the offset says nothing of it
    out="$(qd join rows.csv tel.csv --time start,end --skew skew \
        --window +-3 2>&1)"
    assert_not_contains "$out" "2.5s fast"
    # no skew run in the store: it says what would tell
    out="$(qd join rows.csv tel.csv --time start,end 2>&1)"
    assert_contains "$out" "qd probe skew"
    # skew's own wording, every unit it writes
    "$PY" - "$QD_DIR" <<'EOF'
import sys
sys.path.insert(0, sys.argv[1])
from quarterdeck.join import parse_offset, parse_window
cases = [("2.5s fast the 1 source that answered", 2.5),
         ("3m 05s slow the 2 sources that answered", -185),
         ("1h 02m fast the 3 sources that answered", 3720),
         ("1d 02h slow x", -93600), ("500ms slow x", -0.5),
         ("no rule fired", None), ("", None)]
for text, want in cases:
    got = parse_offset(text)
    assert (got is None and want is None) or abs(got - want) < 1e-9, \
        (text, got, want)
for text, want in [("run", 0), ("", 0), ("+-30", 30), ("30", 30),
                   ("30s", 30), ("2m", 120), ("500ms", 0.5),
                   ("run+-1.5s", 1.5), (u"±30", 30), ("+/-1h", 3600)]:
    assert parse_window(text) == want, (text, parse_window(text), want)
EOF
}

t_fan_out_windows_from_qd_hosts() {
    install_fake_ssh
    for h in a b c; do fake_host "$h"; done
    qdf run -S a,b,c -q -- 'sleep 0.3; echo "mbps: 9400"' > /dev/null
    qd show ds:qd.hosts --format csv > hosts.csv
    # the start is kept to the millisecond
    assert_contains "$(sed -n 2p hosts.csv)" "."
    # Prometheus's shape: ms epochs, instance with its port.  Inside each
    # host's window, and 2 ms either side of it
    "$PY" - <<'EOF'
import csv
out = ["timestamp,instance,__name__,value"]
for r in csv.DictReader(open("hosts.csv")):
    t, d = float(r["ts"]), float(r["duration_s"])
    n = ord(r["host"]) - ord("a")
    for at, v in ((t + d / 2, 40 + n), (t - 0.002, 99), (t + d + 0.002, 98)):
        out.append("%d,%s:9100,node_temp,%s" % (round(at * 1000), r["host"], v))
open("prom.csv", "w").write("\n".join(out) + "\n")
EOF
    qd join latest prom.csv --agg max,count --skew none --format csv > out.csv
    assert_contains "$(row_of a out.csv)" ",a:9100,40,1"
    assert_contains "$(row_of b out.csv)" ",b:9100,41,1"
    assert_contains "$(row_of c out.csv)" ",c:9100,42,1"
    out="$(qd join latest prom.csv --skew none 2>&1)"
    assert_contains "$out" "each host's own, from qd.hosts"
    # --where reads the joined columns too
    out="$(qd join latest prom.csv --skew none --where 'node_temp_max>40' \
        --format csv)"
    assert_not_contains "$out" "a:9100"
    assert_contains "$out" "c:9100"
}

t_runs_filed_before_ms_get_a_second_more() {
    # a qd.hosts row from before 0.10.0: ts a whole second, so the start
    # may have been cut by up to a second, and the end with it
    "$PY" - "$QD_DIR" <<'EOF'
import sys
sys.path.insert(0, sys.argv[1])
from quarterdeck.join import row_windows
from quarterdeck.table import Table
class St(object):
    def host_rows(self, rid):
        return [{"host": "a", "pass": "1", "ts": "1000", "duration_s": "2.00"},
                {"host": "b", "pass": "1", "ts": "1000.250",
                 "duration_s": "2.00", "addr": "10.0.0.2"}]
class E(object):
    id, meta, store = "r1", {"kind": "run"}, St()
t = Table(["host", "v"], [["a", "1"], ["b", "2"]])
hosts, wins, how, notes, addrs = row_windows(t, E(), margin=5)
assert wins == [(995.0, 1008.0), (995.25, 1007.25)], wins
assert addrs == {"10.0.0.2": "b"}, addrs
assert any("before 0.10.0" in n for n in notes), notes
EOF
}

t_import_telemetry_then_join_the_same() {
    rows_csv
    # a wide export, ; between fields, day-first local times at +01:00 --
    # 11:00:10 there is 10:00:10 UTC
    cat > export.csv <<'EOF'
# exported from somewhere
Zeit;Geraet;temp;power;note
10/11/2026 11:00:10;node01;45;310;fine
10/11/2026 11:00:40;node01;55;;fine
10/11/2026 11:00:40;node02;;290;
EOF
    cat > map.txt <<'EOF'
# which column is which
time         Zeit
host: Geraet
metrics      temp, power
time_format  %d/%m/%Y %H:%M:%S
tz           +01:00
EOF
    out="$(qd import export.csv --map map.txt)"
    assert_contains "$out" "telemetry"
    assert_contains "$out" "4 samples of 2 hosts, 2 metrics"
    qd show latest --format csv > kept.csv
    assert_eq "$(head -1 kept.csv)" "time,host,metric,value"
    assert_contains "$(cat kept.csv)" "2026-11-10T10:00:10.000Z,node01,temp,45"
    # a blank reading is not a sample: node01 has no power at 11:00:40
    assert_not_contains "$(cat kept.csv)" "10:00:40.000Z,node01,power"
    qd join rows.csv export.csv --map map.txt --time start,end --skew none \
        --agg mean,max --format csv > from_file.csv
    qd join rows.csv latest --time start,end --skew none --agg mean,max \
        --format csv > from_store.csv
    assert_eq "$(cat from_store.csv)" "$(cat from_file.csv)"
    assert_contains "$(row_of node01 from_file.csv)" ",node01,50,55,310,310"
    assert_contains "$(row_of node02 from_file.csv)" ",node02,,,290,290"
    # an alias file at import keeps the samples under the run's names
    printf '_time,host,metric,value\n2026-11-10T10:00:05Z,n1-bmc,temp_c,40\n' \
        > bmc.csv
    printf 'node01 n1-bmc\n' > aliases.txt
    qd import bmc.csv --alias aliases.txt > /dev/null
    assert_contains "$(qd show latest --format csv)" ",node01,temp_c,40"
}

t_ndjson_with_nanosecond_times() {
    printf 'host,start,end\nsw1,2026-11-10T10:00:00Z,2026-11-10T10:01:00Z\n' \
        > rows.csv
    # a gNMI collector's shape: ns epochs, the device under tags
    "$PY" - <<'EOF'
import calendar, json
t0 = calendar.timegm((2026, 11, 10, 10, 0, 0, 0, 0, 0))
with open("gnmi.ndjson", "w") as f:
    for s, v in ((10, 100), (40, 160), (90, 999)):
        f.write(json.dumps({"timestamp": (t0 + s) * 10 ** 9,
                            "tags": {"source": "sw1"},
                            "name": "in_errors", "value": v}) + "\n")
EOF
    printf 'host tags.source\n' > map.txt
    qd join rows.csv gnmi.ndjson --map map.txt --time start,end --skew none \
        --agg first,last,delta,rate --format csv > out.csv
    # 100 at 10 s, 160 at 40 s: 60 more, 2 a second; 999 is past the end
    assert_contains "$(row_of sw1 out.csv)" ",sw1,100,160,60,2"
    # Telegraf's JSON, no map: tags.host, a field a metric, and different
    # fields on different lines -- the second line's are not lost
    cat > telegraf.json <<'EOF2'
{"fields":{"usage_idle":90},"name":"cpu","tags":{"host":"sw1"},"timestamp":1794304810}
not json at all
{"fields":{"temp_c":41.5},"name":"ipmi_sensor","tags":{"host":"sw1"},"timestamp":1794304820}
EOF2
    qd join rows.csv telegraf.json --time start,end --skew none --agg max \
        --format csv > out.csv
    assert_contains "$(head -1 out.csv)" "fields.usage_idle_max,fields.temp_c_max"
    assert_contains "$(row_of sw1 out.csv)" ",sw1,90,41.5"
    out="$(qd join rows.csv telegraf.json --time start,end --skew none 2>&1)"
    assert_contains "$out" "1 line that was not JSON"
}

t_a_big_export_is_streamed() {
    rows_csv
    # 600,000 lines for a thousand other hosts, and three of the run's:
    # read whole, they would take hundreds of MB; kept, a few samples
    "$PY" - <<'EOF'
with open("big.csv", "w") as f:
    f.write("_time,host,metric,value\n")
    for i in range(600000):
        f.write("2026-11-10T10:00:%02dZ,other%04d,temp_c,%d\n"
                % (i % 60, i % 1000, i % 90))
    for h, v in (("node01", 41), ("node02", 42), ("node03", 43)):
        f.write("2026-11-10T10:00:30Z,%s,temp_c,%d\n" % (h, v))
EOF
    "$PY" - "$PY" "$QD_DIR/qd" <<'EOF'
import resource, subprocess, sys
out = subprocess.check_output([sys.argv[1], sys.argv[2], "join", "rows.csv",
                               "big.csv", "--time", "start,end", "--skew",
                               "none", "--agg", "max", "--format", "csv"])
peak = resource.getrusage(resource.RUSAGE_CHILDREN).ru_maxrss
if sys.platform == "darwin":
    peak //= 1024                         # bytes there, KB on Linux
assert b",node03,43" in out, out
assert peak < 100 * 1024, "qd join peaked at %d MB" % (peak // 1024)
EOF
}

t_mistakes_say_what_to_do() {
    rows_csv
    printf '_time,host,metric,value\n2026-11-10T10:00:05Z,node01,temp_c,40\n' \
        > tel.csv
    qd_rc join rows.csv tel.csv --time start > err 2>&1
    out="$(cat err)"
    assert_status "$QD_RC" 2
    assert_contains "$out" "is an instant"
    qd_rc join rows.csv tel.csv --time start,end --window soon > err 2>&1
    out="$(cat err)"
    assert_status "$QD_RC" 2
    assert_contains "$out" "--window wants run"
    qd_rc join rows.csv tel.csv --time start,end --agg avg > err 2>&1
    out="$(cat err)"
    assert_status "$QD_RC" 2
    assert_contains "$out" "unknown --agg 'avg'"
    qd_rc join rows.csv tel.csv --time nope,end > err 2>&1
    out="$(cat err)"
    assert_status "$QD_RC" 2
    assert_contains "$out" "no column 'nope'"
    # a file of rows says nothing of when it was measured
    qd_rc join rows.csv tel.csv > err 2>&1
    out="$(cat err)"
    assert_status "$QD_RC" 2
    assert_contains "$out" "--time COL"
    # nor does an import: when it was imported is not when it was measured
    qd import rows.csv > /dev/null
    qd_rc join latest tel.csv > err 2>&1
    out="$(cat err)"
    assert_status "$QD_RC" 2
    assert_contains "$out" "an import keeps when it was imported"
    # an export with no host column, and a map that names what is not there
    printf 'when,v\n2026-11-10T10:00:05Z,1\n' > nohost.csv
    qd_rc join rows.csv nohost.csv --time start,end > err 2>&1
    out="$(cat err)"
    assert_status "$QD_RC" 2
    assert_contains "$out" "each sample's time? None is called"
    printf 'time when\nhost box\n' > bad.map
    qd_rc join rows.csv nohost.csv --map bad.map --time start,end > err 2>&1
    out="$(cat err)"
    assert_status "$QD_RC" 2
    assert_contains "$out" "gives host as 'box'"
    printf 'colour blue\n' > worse.map
    qd_rc import tel.csv --map worse.map > err 2>&1
    out="$(cat err)"
    assert_status "$QD_RC" 2
    assert_contains "$out" "'colour' is not a column map key"
    printf 'tz Europe/Paris\n' > zone.map
    qd_rc import tel.csv --map zone.map > err 2>&1
    out="$(cat err)"
    assert_status "$QD_RC" 2
    assert_contains "$out" "tz wants UTC or an offset"
    printf 'node01 x\nnode02 x\n' > twice.txt
    qd_rc join rows.csv tel.csv --time start,end --alias twice.txt > err 2>&1
    out="$(cat err)"
    assert_status "$QD_RC" 2
    assert_contains "$out" "x is an alias of node01 and of node02"
}

echo "qd join"
run_test "both edges of a window count, a millisecond out does not" t_window_edges_count_both_ends
run_test "every figure matches one worked by hand" t_figures_match_hand_computed
run_test "a host without telemetry is blank, not zero" t_a_host_without_telemetry_is_blank_not_zero
run_test "hosts matched by alias, FQDN, case and port" t_hosts_matched_by_alias_fqdn_case_and_port
run_test "a window widened for skew" t_window_widened_for_skew
run_test "clock skew read from a stored skew run" t_clock_skew_from_a_stored_skew_run
run_test "a fan-out's windows come from qd.hosts" t_fan_out_windows_from_qd_hosts
run_test "runs filed before ms windows get a second more" t_runs_filed_before_ms_get_a_second_more
run_test "import telemetry, then join it the same as the file" t_import_telemetry_then_join_the_same
run_test "NDJSON with nanosecond times" t_ndjson_with_nanosecond_times
run_test "a big export is streamed, not read whole" t_a_big_export_is_streamed
run_test "mistakes say what to do" t_mistakes_say_what_to_do
finish
