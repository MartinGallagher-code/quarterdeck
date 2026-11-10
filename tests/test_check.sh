#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Martin J. Gallagher
#
# test_check.sh -- qd check: a dataset against a thresholds file keyed by
# requirement (QD-010).  Blank is never a pass.

set -u
source "$(dirname "${BASH_SOURCE[0]}")/test_helper.bash"

data() {
    cat > d.csv <<'CSV'
host,rack,status,mbps,rtt,mem,temp
a,r1,ok,950,200us,512M,30
b,r1,ok,880,0.3ms,2G,44
c,r2,ok,,150us,1G,50
d,r2,unreachable,,,,
CSV
}

# a thresholds file from rows of fields; tab-separated, blank fields kept
limits() {
    local f="$1"
    shift
    printf 'req\tcolumn\top\tlimit\tlimit2\twhere\tagg\tunit\n' > "$f"
    for row in "$@"; do printf '%s\n' "$row" | tr '|' '\t' >> "$f"; done
}

verdict() {   # verdict REQ: the verdict column of that check
    "$PY" -c '
import csv, sys
for r in csv.DictReader(open(sys.argv[1])):
    if r["req"] == sys.argv[2]:
        print(r["verdict"] + "|" + r["observed"] + "|" + r["measured"])
' v.csv "$1"
}

t_pass_fail_and_exit_status() {
    data
    limits t.tsv 'R1|mbps|>=|900||status=ok||' 'R2|temp|between|20|45|rack=r1|max|'
    qd_rc check d.csv --against t.tsv --format csv -o v.csv
    assert_status "$QD_RC" 1
    # b's 880 fails R1, though c is also blank: a failure is the finding
    assert_eq "$(verdict R1)" "fail|880|2/3"
    assert_eq "$(verdict R2)" "pass|44|2/2"
    limits ok.tsv 'R2|temp|between|20|45|rack=r1|max|' 'R3|mbps|>=|900||mbps!=|max|'
    qd_rc check d.csv --against ok.tsv > out
    assert_status "$QD_RC" 0
    assert_contains "$(cat out)" "2 pass, 0 fail, 0 not measured"
}

t_blank_is_never_a_pass() {
    data
    limits t.tsv 'R1|mbps|>=|100||||' 'R2|nope|<|1||||' 'R3|mbps|>=|100||rack=r9||' \
        'R4|rtt|<=|1000|||median|us'
    qd_rc check d.csv --against t.tsv --format csv -o v.csv
    assert_status "$QD_RC" 1
    # every measured value passes, but c and d measured nothing
    assert_eq "$(verdict R1)" "not measured||2/4"
    assert_eq "$(verdict R2)" "not measured||0/0"
    assert_eq "$(verdict R3)" "not measured||0/0"
    # an aggregate over the hosts that answered is shown, not passed
    assert_eq "$(verdict R4)" "not measured|200|3/4"
    assert_contains "$(cat v.csv)" "no column nope"
    assert_contains "$(cat v.csv)" "no rows where rack=r9"
    # only blanks: a not-measured run exits 1 as a failure does
    printf 'host,v\na,\nb,\n' > e.csv
    limits e.tsv 'R9|v|<|1||||'
    qd_rc check e.csv --against e.tsv > out
    assert_status "$QD_RC" 1
    assert_contains "$(cat out)" "0 pass, 0 fail, 1 not measured"
}

t_every_op() {
    printf 'host,v,s\na,5,ok\nb,10,OK\n' > d.csv
    limits t.tsv 'lt|v|<|11||||' 'le|v|<=|10||||' 'gt|v|>|4||||' 'ge|v|>=|5||||' \
        'eq|v|==|5||host=a||' 'ne|v|!=|7||||' 'in|s|in|ok,pass||||' \
        'bt|v|between|5|10|||' 'eqs|s|==|ok||||' 'lt-f|v|<|10||||' \
        'bt-f|v|between|6|10|||' 'in-f|s|in|pass||||'
    qd_rc check d.csv --against t.tsv --format csv -o v.csv
    for r in lt le gt ge eq ne in bt eqs; do
        assert_eq "$(verdict $r | cut -d'|' -f1)" "pass"
    done
    for r in lt-f bt-f in-f; do
        assert_eq "$(verdict $r | cut -d'|' -f1)" "fail"
    done
}

t_aggregates_and_each() {
    data
    limits t.tsv 'R1|temp|<=|45|||max|' 'R2|temp|<=|45|||median|' \
        'R3|temp|<=|45||||' 'R4|mem|<=|1.5G||status=ok|p99|'
    qd_rc check d.csv --against t.tsv --where 'status=ok' --format csv -o v.csv
    assert_eq "$(verdict R1)" "fail|50|3/3"
    assert_eq "$(verdict R2)" "pass|44|3/3"
    assert_eq "$(verdict R3)" "fail|50|3/3"
    # sizes compare on one scale and read in the limit's unit
    assert_eq "$(verdict R4 | cut -d'|' -f1)" "fail"
    qd_rc check d.csv --against t.tsv --where 'status=ok' --each --format csv -o e.csv
    assert_contains "$(cat e.csv)" "R3,c,temp,50,<= 45,,fail"
    assert_contains "$(cat e.csv)" "R3,a,temp,30,<= 45,,pass"
    assert_eq "$(grep -c '^R3,' e.csv)" "3"
}

t_units() {
    data
    limits t.tsv 'R1|rtt|<=|250||||us' 'R2|rtt|<=|0.25ms||||' 'R3|mem|<=|4096M||status=ok||' \
        'R4|rtt|<=|250||||MB/s' 'R5|mbps|>=|100||status=ok||MB/s' 'R6|rtt|<=|1|||max|s'
    qd_rc check d.csv --against t.tsv --format csv -o v.csv
    # 0.3ms is 300us: over 250us whichever way the limit is written
    assert_contains "$(grep '^R1,' v.csv)" "300,<= 250,us"
    assert_eq "$(verdict R1 | cut -d'|' -f1)" "fail"
    assert_eq "$(verdict R2 | cut -d'|' -f1)" "fail"
    assert_eq "$(verdict R3)" "pass|2048|3/3"
    # a time against a rate is refused, never compared
    assert_eq "$(verdict R4 | cut -d'|' -f1)" "not measured"
    assert_contains "$(grep '^R4,' v.csv)" "unit mismatch"
    # a column with no unit is read in the limit's, and says so
    assert_contains "$(grep '^R5,' v.csv)" "carries no unit"
    assert_eq "$(verdict R6)" "not measured|0.0003|3/4"
}

t_a_bad_file_is_exit_2() {
    data
    bad() {
        qd_rc check d.csv --against "$1" > out 2>&1
        assert_status "$QD_RC" 2
        assert_contains "$(cat out)" "$2"
    }
    bad nosuch.tsv "no such thresholds file"
    printf 'req\tcolumn\tlimit\nR1\tv\t1\n' > t1.tsv
    bad t1.tsv "the header needs op"
    limits t2.tsv 'R1|mbps|~|1||||'
    bad t2.tsv "unknown op"
    limits t3.tsv 'R1|mbps|<|fast||||'
    bad t3.tsv "needs a number"
    limits t4.tsv 'R1|mbps|between|1||||'
    bad t4.tsv "between needs limit2"
    limits t5.tsv 'R1|mbps|<|1|||p42|'
    bad t5.tsv "unknown agg"
    limits t6.tsv 'R1|mbps|<|1||((|'
    bad t6.tsv "where"
    limits t7.tsv 'R1|mbps|<|1||||' 'R1|mbps|<|2||||'
    bad t7.tsv "the same check"
    limits t8.tsv '|mbps|<|1||||'
    bad t8.tsv "req is blank"
    printf 'req\tcolumn\top\tlimit\tcolour\nR1\tv\t<\t1\tred\n' > t9.tsv
    bad t9.tsv "unknown column colour"
    limits t10.tsv
    bad t10.tsv "holds no checks"
}

start_web() {
    "$PY" "$QD_DIR/qd" web -n -q --port 18160 > web.out 2> web.err &
    echo $! > web.pid
    for _ in $(seq 1 50); do
        URL="$(sed -n 's/^qd web: \(http:[^ ]*\).*/\1/p' web.err | tail -1)"
        [ -n "$URL" ] && break
        sleep 0.1
    done
    [ -n "$URL" ] || { cat web.err; fail "the server did not start"; }
}

stop_web() { kill "$(cat web.pid)" 2> /dev/null || true; wait 2> /dev/null || true; }

t_kept_verdicts_are_a_dataset() {
    data
    limits t.tsv 'R1|mbps|>=|900||status=ok||' 'R2|temp|between|20|45|rack=r1|max|'
    qd_rc check d.csv --against t.tsv --keep > out
    assert_status "$QD_RC" 1
    assert_contains "$(cat out)" "filed as"
    assert_contains "$(qd log latest)" "kind      check"
    # read back from the store, the verdicts are the terminal's
    csv="$(qd show latest --format csv)"
    assert_contains "$csv" "R1,mbps,each,status=ok,880,>= 900,,2/3,fail"
    assert_contains "$csv" "R2,temp,max,rack=r1,44,between 20 and 45,,2/2,pass"
    assert_contains "$(qd export latest --format json)" '"verdict": "fail"'
    start_web
    body="$("$PY" - "$URL" <<'PYEOF'
import json, sys, urllib.request
base = sys.argv[1].rstrip("/")
with urllib.request.urlopen(base + "/api/rows?e=latest") as r:
    d = json.loads(r.read().decode())
cols = d["columns"]
for row in d["rows"]:
    cells = row["cells"] if isinstance(row, dict) else row
    print(",".join(str(c) for c in cells[cols.index("req"):cols.index("verdict") + 1]))
PYEOF
)" || true
    stop_web
    assert_contains "$body" "R1,mbps,each,status=ok,880,>= 900,,2/3,fail"
    assert_contains "$body" "R2,temp,max,rack=r1,44,between 20 and 45,,2/2,pass"
}

t_on_a_run() {
    install_fake_ssh
    for h in n1 n2 n3; do fake_host "$h"; done
    echo "load: 0.5" > "$FAKE_ROOT/n1/m"
    echo "load: 3.5" > "$FAKE_ROOT/n2/m"
    echo "load:" > "$FAKE_ROOT/n3/m"
    printf 'n1\nn2\nn3\n' > hosts.txt
    qdf_rc run -q -s hosts.txt -- cat m > /dev/null 2>&1
    limits t.tsv 'L1|load|<=|2||||'
    qd_rc check latest --against t.tsv --each > out
    assert_status "$QD_RC" 1
    assert_contains "$(cat out)" "run 2"
    assert_contains "$(cat out)" "n2"
    assert_contains "$(cat out)" "fail"
    assert_contains "$(qd check latest --against t.tsv --format csv 2>/dev/null || true)" "1 of 3 failed: n2; 1 not measured"
}

run_test "pass, fail and the exit status"       t_pass_fail_and_exit_status
run_test "blank is never a pass"                t_blank_is_never_a_pass
run_test "every op"                             t_every_op
run_test "aggregates over hosts, and --each"    t_aggregates_and_each
run_test "units: one scale, or refused"         t_units
run_test "a bad thresholds file is exit 2"      t_a_bad_file_is_exit_2
run_test "kept verdicts: store, export, web"    t_kept_verdicts_are_a_dataset
run_test "a fan-out run, host by host"          t_on_a_run
finish
