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

# a waivers file from rows of fields, as limits() writes a thresholds file
waivers() {
    local f="$1"
    shift
    printf 'req\tjustification\texpires\twhere\texpect\tgranted_by\n' > "$f"
    for row in "$@"; do printf '%s\n' "$row" | tr '|' '\t' >> "$f"; done
}

field() {   # field REQ COLUMN: one cell of the verdict table v.csv
    "$PY" -c '
import csv, sys
for r in csv.DictReader(open(sys.argv[1])):
    if r["req"] == sys.argv[2]:
        print(r[sys.argv[3]])
' v.csv "$1" "$2"
}

t_unchanged_without_the_new_columns() {
    # QD-028: a thresholds file with none of the new columns, and no
    # --waivers, gives what 0.14.0 gave, byte for byte
    data
    printf 'req\tcolumn\top\tlimit\tlimit2\twhere\tagg\tunit\tnote\n%s\n%s\n%s\n%s\n' \
        'R1	mbps	>=	900		status=ok			' \
        'R2	temp	between	20	45	rack=r1	max		hot' \
        'R3	rtt	<=	250				us	' \
        'R4	status	in	ok						' > t.tsv
    qd_rc check d.csv --against t.tsv --format csv > got.csv 2> /dev/null
    assert_status "$QD_RC" 1
    cat > want.csv <<'CSV'
req,column,agg,where,observed,limit,unit,measured,verdict,note
R1,mbps,each,status=ok,880,>= 900,,2/3,fail,1 of 3 failed: b; 1 not measured
R2,temp,max,rack=r1,44,between 20 and 45,,2/2,pass,hot
R3,rtt,each,,300,<= 250,us,3/4,fail,1 of 4 failed: b; 1 not measured
R4,status,each,,unreachable,in ok,,4/4,fail,1 of 4 failed: d
CSV
    assert_eq "$(cat got.csv)" "$(cat want.csv)"
    # (no note long enough to be cut: 3.6 in C cuts with ~, not an ellipsis)
    qd_rc check d.csv --against t.tsv > got.txt 2> /dev/null
    cat > want.txt <<'TXT'
qd check -- d.csv against t.tsv (4 rows): 1 pass, 3 fail, 0 not measured

  req  column  agg   where      observed     limit              unit  measured  verdict  note
  R1   mbps    each  status=ok  880          >= 900                   2/3       fail     1 of 3 failed: b; 1 not measured
  R2   temp    max   rack=r1    44           between 20 and 45        2/2       pass     hot
  R3   rtt     each             300          <= 250             us    3/4       fail     1 of 4 failed: b; 1 not measured
  R4   status  each             unreachable  in ok                    4/4       fail     1 of 4 failed: d
TXT
    assert_eq "$(cat got.txt)" "$(cat want.txt)"
    qd_rc check d.csv --against t.tsv --each --format csv > got.csv 2> /dev/null
    assert_eq "$(head -1 got.csv)" "req,row,column,observed,limit,unit,verdict"
    assert_contains "$(cat got.csv)" "R1,b,mbps,880,>= 900,,fail"
}

t_waivers() {
    data
    limits t.tsv 'R1|mbps|>=|900||status=ok||' 'R2|temp|<=|45||status=ok||' \
        'R3|temp|<=|45||status=ok|max|' 'R4|rtt|<=|250||||us' 'R5|temp|<=|60||rack=r1||' \
        'R6|temp|<=|60||status=ok||' 'R7|temp|<=|45||status=ok|max|'
    # R1: b's 880 waived, but c is blank: not measured is never waived
    # R2: c's 50 waived for host c; R3: the max waived as a whole
    # R4: an expired waiver does nothing; R5: expect fail, and it passed
    # R6: a waiver on a pass changes nothing; R7: a where short of every row
    waivers w.tsv 'R1|NIC firmware 2.1 bug|2999-12-31|host=b||J. Smith' \
        'R2|c runs hot, FSE-12|2999-12-31|host=c||' \
        'R3|thermal rework due|||fail|QA board' \
        'R4|old deviation|2000-01-01|||' \
        'R5|known slow rack|||fail|' \
        'R6|belt and braces||||' \
        'R7|only rack r1||rack=r1||'
    qd_rc check d.csv --against t.tsv --waivers w.tsv --format csv -o v.csv
    assert_status "$QD_RC" 1
    assert_eq "$(field R1 verdict)" "not measured"
    assert_eq "$(field R1 justification)" "NIC firmware 2.1 bug"
    assert_eq "$(field R1 granted_by)" "J. Smith"
    assert_eq "$(field R2 verdict)" "waived"
    assert_eq "$(field R2 justification)" "c runs hot, FSE-12"
    assert_eq "$(field R2 expires)" "2999-12-31"
    assert_contains "$(field R2 note)" "1 of 3 failed under a waiver: c"
    assert_eq "$(field R3 verdict)" "waived"
    assert_eq "$(field R4 verdict)" "fail"
    assert_eq "$(field R4 expires)" "2000-01-01 (expired)"
    assert_contains "$(field R4 note)" "waiver expired 2000-01-01: not applied"
    assert_eq "$(field R5 verdict)" "unexpected pass"
    assert_contains "$(field R5 note)" "expected to fail under a waiver, and passed"
    assert_eq "$(field R6 verdict)" "pass"
    assert_eq "$(field R6 justification)" ""
    assert_eq "$(field R7 verdict)" "fail"
    assert_contains "$(field R7 note)" "does not cover every row"
    # the head line counts waived apart from passed
    qd_rc check d.csv --against t.tsv --waivers w.tsv > out
    assert_contains "$(cat out)" "waived"
    assert_contains "$(cat out)" "1 unexpected pass"
    assert_contains "$(cat out)" "waivers w.tsv: 7, 1 expired"
    # --each: the waived row carries its justification, the others none
    qd_rc check d.csv --against t.tsv --waivers w.tsv --each --format csv -o e.csv
    assert_contains "$(cat e.csv)" "R1,b,mbps,880,>= 900,,waived,NIC firmware 2.1 bug,2999-12-31,J. Smith"
    assert_contains "$(cat e.csv)" "R1,a,mbps,950,>= 900,,pass,,,"
    # json, and QD_WAIVERS for the flag
    QD_WAIVERS=w.tsv qd_rc check d.csv --against t.tsv --format json -o v.json
    assert_contains "$(cat v.json)" '"justification": "NIC firmware 2.1 bug"'
    assert_contains "$(cat v.json)" '"verdict": "unexpected pass"'
}

t_a_waived_failure_passes_the_run() {
    data
    limits t.tsv 'R1|mbps|>=|900||status=ok and host!=c||' 'R2|temp|<=|45||rack=r1||'
    qd_rc check d.csv --against t.tsv > /dev/null 2>&1
    assert_status "$QD_RC" 1
    waivers w.tsv 'R1|b is a 1G port by design||||'
    qd_rc check d.csv --against t.tsv --waivers w.tsv --format csv -o v.csv
    assert_status "$QD_RC" 0
    assert_eq "$(field R1 verdict)" "waived"
    # an unexpected pass fails the run, as ReFrame's xfail does
    waivers x.tsv 'R1|b is a 1G port by design||||' 'R2|expected hot|||fail|'
    qd_rc check d.csv --against t.tsv --waivers x.tsv > out
    assert_status "$QD_RC" 1
    assert_contains "$(cat out)" "0 pass, 0 fail, 0 not measured, 1 waived, 1 unexpected pass"
}

t_bad_waivers_are_exit_2() {
    data
    limits t.tsv 'R1|mbps|>=|900||||'
    bad() {
        qd_rc check d.csv --against t.tsv --waivers "$1" > out 2>&1
        assert_status "$QD_RC" 2
        assert_contains "$(cat out)" "$2"
    }
    bad nosuch.tsv "no such waivers file"
    waivers w1.tsv 'R9|a typo||||'
    bad w1.tsv "no check has req R9"
    waivers w2.tsv 'R1|||||'
    bad w2.tsv "justification is blank"
    waivers w3.tsv 'R1|why|31/12/2026|||'
    bad w3.tsv "is not a date"
    waivers w4.tsv 'R1|why|||pass|'
    bad w4.tsv "the only expectation is fail"
    waivers w5.tsv 'R1|why||((||'
    bad w5.tsv "where"
    printf 'req\tjustification\tcolour\nR1\twhy\tred\n' > w6.tsv
    bad w6.tsv "unknown column colour"
    printf 'req\tnote\nR1\twhy\n' > w7.tsv
    bad w7.tsv "the header needs justification"
    qd_rc check d.csv --against t.tsv --fail-level urgent > out 2>&1
    assert_status "$QD_RC" 2
    assert_contains "$(cat out)" "--fail-level urgent"
    printf 'req\tcolumn\top\tlimit\tseverity\nR1\tmbps\t>=\t1\tsevere\n' > s.tsv
    qd_rc check d.csv --against s.tsv > out 2>&1
    assert_status "$QD_RC" 2
    assert_contains "$(cat out)" "unknown severity"
}

t_severity_and_fail_level() {
    data
    sev() {
        printf 'req\tcolumn\top\tlimit\twhere\tseverity\n' > s.tsv
        for row in "$@"; do printf '%s\n' "$row" | tr '|' '\t' >> s.tsv; done
    }
    # every check measured; R-low fails at low, R-high at 0.8 (high)
    sev 'R-low|temp|<=|45|status=ok|low' 'R-high|mbps|>=|900|host!=c and host!=d|0.8' \
        'R-ok|temp|<=|60|status=ok|critical'
    for lv in info low; do
        qd_rc check d.csv --against s.tsv --fail-level "$lv" > out
        assert_status "$QD_RC" 1
    done
    for lv in medium high; do
        qd_rc check d.csv --against s.tsv --fail-level "$lv" > out
        assert_status "$QD_RC" 1
    done
    qd_rc check d.csv --against s.tsv --fail-level critical > out
    assert_status "$QD_RC" 0
    assert_contains "$(cat out)" "2 failures below --fail-level critical"
    QD_FAIL_LEVEL=medium qd_rc check d.csv --against s.tsv --format csv -o v.csv
    assert_status "$QD_RC" 1
    assert_eq "$(field R-high severity)" "high"
    assert_eq "$(field R-low severity)" "low"
    # only the low one failing: medium lets it off, low does not
    sev 'R-low|temp|<=|45|status=ok|low' 'R-ok|temp|<=|60|status=ok|critical'
    qd_rc check d.csv --against s.tsv --fail-level medium > out
    assert_status "$QD_RC" 0
    assert_contains "$(cat out)" "1 failure below --fail-level medium (R-low)"
    qd_rc check d.csv --against s.tsv --fail-level low > /dev/null
    assert_status "$QD_RC" 1
    qd_rc check d.csv --against s.tsv > /dev/null
    assert_status "$QD_RC" 1
    # a check with no severity is never let off; not measured never is
    sev 'R-none|temp|<=|45|status=ok|' 'R-ok|temp|<=|60|status=ok|critical'
    qd_rc check d.csv --against s.tsv --fail-level critical > /dev/null
    assert_status "$QD_RC" 1
    sev 'R-blank|mbps|>=|1|status=ok|info'
    qd_rc check d.csv --against s.tsv --fail-level critical > /dev/null
    assert_status "$QD_RC" 1
}

t_within() {
    printf 'host,v,t\na,45,200us\nb,50,0.21ms\nc,55,250us\n' > d.csv
    limits t.tsv 'sym|v|within|50|+-10%|||' 'sym-f|v|within|50|±5%|||' \
        'asym|v|within|50|-10%,+10%|||' 'asym-f|v|within|50|-5%,+20%|||' \
        'abs|v|within|50|+-5|||' 'abs-f|v|within|50|-4;+5|||' \
        'agg|v|within|50|+-1||median|' 'unit|t|within|0.2ms|+-50us|||' \
        'unit-f|t|within|200|+-20||max|us' 'pct-u|t|within|210us|+-20%|||'
    qd_rc check d.csv --against t.tsv --format csv -o v.csv
    for r in sym asym abs agg unit pct-u; do
        assert_eq "$(field "$r" verdict) $r" "pass $r"
    done
    for r in sym-f asym-f abs-f unit-f; do
        assert_eq "$(field "$r" verdict) $r" "fail $r"
    done
    assert_eq "$(field sym limit)" "within 50 (-10%, +10%)"
    assert_eq "$(field asym-f limit)" "within 50 (-5%, +20%)"
    assert_eq "$(field abs-f limit)" "within 50 (-4, +5)"
    # 250us read in the limit's unit, as qd check scales any other op
    assert_eq "$(field unit-f observed)" "250"
    assert_eq "$(field unit observed)" "0.25"
    assert_contains "$(field sym-f note)" "a, c"
    limits b1.tsv 'R1|v|within|50||||'
    qd_rc check d.csv --against b1.tsv > out 2>&1
    assert_status "$QD_RC" 2
    assert_contains "$(cat out)" "within needs a tolerance"
    limits b2.tsv 'R1|v|within|50|10%|||'
    qd_rc check d.csv --against b2.tsv > out 2>&1
    assert_status "$QD_RC" 2
    limits b3.tsv 'R1|t|within|200us|+-1G|||'
    qd_rc check d.csv --against b3.tsv > out 2>&1
    assert_status "$QD_RC" 2
    assert_contains "$(cat out)" "not in the limit's unit"
    limits b4.tsv 'R1|v|within|fast|+-1|||'
    qd_rc check d.csv --against b4.tsv > out 2>&1
    assert_status "$QD_RC" 2
}

t_kept_waivers() {
    data
    limits t.tsv 'R1|mbps|>=|900||status=ok and host!=c||'
    printf 'req\tcolumn\top\tlimit\twhere\tseverity\nR1\tmbps\t>=\t900\tstatus=ok and host!=c\thigh\n' > t.tsv
    waivers w.tsv 'R1|b is a 1G port|2999-12-31||| A. N. Other'
    qd_rc check d.csv --against t.tsv --waivers w.tsv --keep > out
    assert_status "$QD_RC" 0
    csv="$(qd show latest --format csv)"
    assert_contains "$csv" "verdict,note,severity,justification,expires,granted_by"
    assert_contains "$csv" ",waived,"
    assert_contains "$csv" "high,b is a 1G port,2999-12-31"
    assert_contains "$(qd export latest --format json)" '"justification": "b is a 1G port"'
    assert_contains "$(qd log latest)" "--waivers"
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
run_test "unchanged without the new columns"    t_unchanged_without_the_new_columns
run_test "waivers: waived, expired, unexpected" t_waivers
run_test "a waived failure passes the run"      t_a_waived_failure_passes_the_run
run_test "a bad waivers file is exit 2"         t_bad_waivers_are_exit_2
run_test "severity and --fail-level"            t_severity_and_fail_level
run_test "within: a tolerance around a value"   t_within
run_test "kept verdicts carry the waivers"      t_kept_waivers
finish
