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

# the JUnit XML file $1, parsed by Python's own XML reader: the counts of
# <testsuites> and <testsuite>, then a line per testcase
junit() {
    "$PY" - "$1" <<'PYEOF'
import sys
import xml.etree.ElementTree as ET
root = ET.parse(sys.argv[1]).getroot()
suite = root.find("testsuite")
def say(text):   # UTF-8 whatever the locale (Python 3.6 under LANG=C)
    sys.stdout.buffer.write((text + "\n").encode("utf-8"))
for el in (root, suite):
    say("%s tests=%s failures=%s errors=%s skipped=%s" % (
        el.tag, el.get("tests"), el.get("failures"), el.get("errors"),
        el.get("skipped")))
for tc in suite.findall("testcase"):
    out = "pass"
    msg = ""
    for kind in ("failure", "error", "skipped"):
        el = tc.find(kind)
        if el is not None:
            out, msg = kind, el.get("message") or ""
    say("%s|%s|%s|%s" % (tc.get("classname"), tc.get("name"), out, msg))
PYEOF
}

# the counts JUnit should give, from the verdict column of a csv: tests,
# failures (fail, unexpected pass), errors (not measured), skipped (waived)
csv_counts() {
    "$PY" - "$1" <<'PYEOF'
import csv, sys
vs = [r["verdict"] for r in csv.DictReader(open(sys.argv[1]))]
print("tests=%d failures=%d errors=%d skipped=%d" % (
    len(vs), sum(v in ("fail", "unexpected pass") for v in vs),
    vs.count("not measured"), vs.count("waived")))
PYEOF
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

t_junit_one_case_per_outcome() {
    data
    limits t.tsv 'R1|mbps|>=|900||host=a||' 'R2|mbps|>=|900||host=b||' \
        'R3|mbps|>=|900||host=c||' 'R4|temp|<=|45||host=c||' 'R5|temp|<=|60||rack=r1||'
    waivers w.tsv 'R4|c runs hot|2999-12-31|||QA' 'R5|known slow rack|||fail|'
    qd_rc check d.csv --against t.tsv --waivers w.tsv --format junit -o v.xml
    assert_status "$QD_RC" 1
    qd_rc check d.csv --against t.tsv --waivers w.tsv --format csv -o v.csv
    got="$(junit v.xml)"
    want="$(csv_counts v.csv)"
    assert_eq "$want" "tests=5 failures=2 errors=1 skipped=1"
    assert_contains "$got" "testsuites $want"
    assert_contains "$got" "testsuite $want"
    # pass, fail, not measured, waived, unexpected pass: one testcase each
    assert_contains "$got" "R1|mbps >= 900 where host=a|pass|"
    assert_contains "$got" "R2|mbps >= 900 where host=b|failure|observed 880; want >= 900"
    assert_contains "$got" "R3|mbps >= 900 where host=c|error|not measured: "
    assert_contains "$got" "R4|temp <= 45 where host=c|skipped|waived: c runs hot (expires 2999-12-31; granted by QA); observed 50; want <= 45"
    assert_contains "$got" "R5|temp <= 60 where rack=r1|failure|unexpected pass: "
    # the suite names what it was: the dataset, and the files' hashes
    assert_contains "$(cat v.xml)" '<testsuite name="d.csv"'
    assert_contains "$(cat v.xml)" "\"thresholds.sha256\" value=\"$("$PY" -c 'import hashlib, sys; print(hashlib.sha256(open(sys.argv[1], "rb").read()).hexdigest())' t.tsv)\""
    assert_contains "$(cat v.xml)" '"waivers.sha256"'
    # without waivers, as the text summary counts it
    qd_rc check d.csv --against t.tsv > out
    qd_rc check d.csv --against t.tsv --format junit -o x.xml
    assert_contains "$(cat out)" "2 pass, 2 fail, 1 not measured"
    assert_contains "$(junit x.xml)" "testsuite tests=5 failures=2 errors=1 skipped=0"
    # a severity rides on its testcase
    printf 'req\tcolumn\top\tlimit\tseverity\nS1\tmbps\t>=\t900\tlow\n' > s.tsv
    qd_rc check d.csv --against s.tsv --format junit -o s.xml
    assert_contains "$(cat s.xml)" '<property name="severity" value="low"/>'
}

t_junit_each_host() {
    data
    limits t.tsv 'R1|mbps|>=|900||status=ok||' 'R2|temp|<=|45||||' 'R2|mbps|>=|100||||'
    qd_rc check d.csv --against t.tsv --each --format junit -o e.xml
    assert_status "$QD_RC" 1
    qd_rc check d.csv --against t.tsv --each --format csv -o e.csv
    got="$(junit e.xml)"
    # 3 hosts for R1, 4 each for R2's two checks: a testcase per host per check
    assert_eq "$(csv_counts e.csv)" "tests=11 failures=2 errors=4 skipped=0"
    assert_contains "$got" "testsuite $(csv_counts e.csv)"
    assert_contains "$got" "R1|a|pass|"
    assert_contains "$got" "R1|b|failure|observed 880; want >= 900"
    assert_contains "$got" "R1|c|error|not measured: blank"
    # a req with two checks names the column beside the host
    assert_contains "$got" "R2|c, temp <= 45|failure|observed 50; want <= 45"
    assert_contains "$got" "R2|d, mbps >= 100|error|not measured: blank"
}

t_junit_hostile_strings() {
    # <, &, ]]>, a control character and non-ASCII, in the data, the
    # thresholds and the waivers; the file still parses, and says them
    printf 'host,m<&]]>\n%s,10\n%s,1\n' "h<1>&]]>" "$(printf 'h\001\303\251\360\237\232\200')" > h.csv
    printf 'req\tcolumn\top\tlimit\tnote\n%s\tm<&]]>\t>=\t5\t%s\n' \
        "R<&]]>é" "$(printf 'n\002<"&\047')" > h.tsv
    printf 'req\tjustification\twhere\n%s\t%s\thost=nobody\n' "R<&]]>é" \
        "$(printf 'why <b>&amp; ]]> \001é')" > hw.tsv
    qd_rc check h.csv --against h.tsv --format junit -o h.xml
    assert_status "$QD_RC" 1
    got="$(junit h.xml)"
    assert_contains "$got" "R<&]]>é|m<&]]> >= 5|failure|observed 1; want >= 5"
    assert_not_contains "$(cat h.xml)" "]]>"
    if LC_ALL=C grep -q "$(printf '[\001-\010]')" h.xml; then fail "a control character in the XML"; fi
    qd_rc check h.csv --against h.tsv --each --format junit -o he.xml
    got="$(junit he.xml)"
    assert_contains "$got" "R<&]]>é|h<1>&]]>|pass|"
    assert_contains "$got" "$(printf 'R<&]]>é|h\303\251\360\237\232\200|failure|')"
    qd_rc check h.csv --against h.tsv --waivers hw.tsv --format junit -o hw.xml
    assert_contains "$(junit hw.xml)" "testsuite tests=1 failures=1"
}

t_junit_real_reader() {
    # provost reads JUnit XML (PV-030, provost 2.5.0): a row per testcase
    local v
    v="$(pv --version 2>/dev/null | head -1 | awk '{print $2}')"
    if [ "$("$PY" -c 'import sys; print(tuple(int(x) for x in sys.argv[1].split(".")[:2]) >= (2, 5))' "${v:-0.0}" 2>/dev/null)" != True ]; then
        echo "  (provost ${v:-?} reads no JUnit XML; 2.5.0 does)"
        return 0
    fi
    data
    limits t.tsv 'R1|mbps|>=|900||host=a||' 'R2|mbps|>=|900||host=b||' 'R3|mbps|>=|900||host=c||'
    qd_rc check d.csv --against t.tsv --format junit -o v.xml
    pv -q --name junit < v.xml
    out="$(pv show junit)"
    assert_contains "$out" "classname"
    assert_eq "$(pv show junit | tail -n +2 | grep -c 'R[123]')" "3"
}

# QD-033: limits relative to a baseline -- an earlier run, or a qualified
# baseline from qd baseline set

# a run of four hosts' mbps, imported under a name
runof() {
    local name=$1
    shift
    printf 'host,rack,mbps\na,r1,%s\nb,r1,%s\nc,r2,%s\nd,r2,%s\n' "$@" > "$name.csv"
    qd import "$name.csv" --name "$name" > /dev/null
}

# the verdict of one host under --each, from v.csv: verdict|observed|limit|baseline|drift
row_verdict() {
    "$PY" -c '
import csv, sys
for r in csv.DictReader(open(sys.argv[1])):
    if r["req"] == sys.argv[2] and r["row"] == sys.argv[3]:
        print("|".join((r["verdict"], r["observed"], r["limit"],
                        r["baseline"], r["drift_pct"])))
' v.csv "$1" "$2"
}

t_baseline_a_drifted_host_fails() {
    runof before 1000 1000 900 800
    # b drifted 8% against a 5% limit; the rest moved less
    runof after 980 920 890 800
    limits t.tsv 'D1|mbps|>=|baseline-5%||||'
    qd_rc check after --against t.tsv --baseline before --each --format csv -o v.csv
    assert_status "$QD_RC" 1
    assert_eq "$(row_verdict D1 a)" "pass|980|>= baseline-5% (>= 950)|1000|-2.0"
    assert_eq "$(row_verdict D1 b)" "fail|920|>= baseline-5% (>= 950)|1000|-8.0"
    assert_eq "$(row_verdict D1 c)" "pass|890|>= baseline-5% (>= 855)|900|-1.1"
    assert_eq "$(row_verdict D1 d)" "pass|800|>= baseline-5% (>= 760)|800|0.0"
    qd_rc check after --against t.tsv --baseline before > out
    assert_status "$QD_RC" 1
    assert_contains "$(cat out)" "0 pass, 1 fail, 0 not measured"
    assert_contains "$(cat out)" "held to run 20"
    assert_contains "$(cat out)" "1 of 4 failed: b"
    qd_rc check after --against t.tsv --baseline before --format csv -o v.csv
    assert_contains "$(cat v.csv)" "decided on medians, no rank test"
    # an absolute difference, a tolerance and an aggregate: b's 80 down
    # is past 50; the median, 905 against the baseline's 950, moved 4.7%:
    # within 5%, and below 950 less 2%
    limits t2.tsv 'A1|mbps|>=|baseline-50||||' 'W1|mbps|within|baseline|+-5%||median|' \
        'G1|mbps|>=|baseline-2%|||median|'
    qd_rc check after --against t2.tsv --baseline before --format csv -o v.csv
    assert_status "$QD_RC" 1
    assert_eq "$(verdict A1)" "fail|920|4/4"
    assert_eq "$(verdict W1)" "pass|905|4/4"
    assert_eq "$(verdict G1)" "fail|905|4/4"
    assert_contains "$(cat v.csv)" "within baseline (-5%, +5%) (between 902.5 and 997.5)"
    assert_contains "$(cat v.csv)" ">= baseline-2% (>= 931)"
    assert_contains "$(cat v.csv)" ",950,-4.7"
    # the same run against itself: nothing moved, every check passes
    qd_rc check after --against t2.tsv --baseline after > out
    assert_status "$QD_RC" 0
    assert_contains "$(cat out)" "3 pass, 0 fail, 0 not measured"
    qd_rc check after --against t.tsv --baseline after > out
    assert_status "$QD_RC" 0
    # a file as the baseline reads the same as the run it was imported from
    qd_rc check after --against t.tsv --baseline before.csv --each --format csv -o v.csv
    assert_eq "$(row_verdict D1 b)" "fail|920|>= baseline-5% (>= 950)|1000|-8.0"
}

t_baseline_a_host_it_lacks_is_not_measured() {
    printf 'host,mbps\na,1000\nb,1000\nc,900\n' > before.csv
    printf 'host,mbps\na,990\nb,1000\nc,900\nnew,2000\n' > after.csv
    limits t.tsv 'D1|mbps|>=|baseline-5%||||'
    qd_rc check after.csv --against t.tsv --baseline before.csv --each --format csv -o v.csv
    assert_status "$QD_RC" 1
    assert_eq "$(row_verdict D1 new | cut -d'|' -f1-3)" \
        "not measured|2000|>= baseline-5% (not in the baseline)"
    qd_rc check after.csv --against t.tsv --baseline before.csv --format csv -o v.csv
    assert_eq "$(verdict D1)" "not measured||3/4"
    assert_contains "$(cat v.csv)" "1 not in run before.csv: new"
    # a column the baseline lacks is not measured either
    printf 'host,other\na,1\n' > nocol.csv
    qd_rc check after.csv --against t.tsv --baseline nocol.csv --format csv -o v.csv
    assert_status "$QD_RC" 1
    assert_contains "$(verdict D1)" "not measured"
    assert_contains "$(cat v.csv)" "has no column mbps"
    # an aggregate over hosts the baseline does not all hold compares
    # different populations: not measured
    limits g.tsv 'G1|mbps|>=|baseline-5%|||median|'
    qd_rc check after.csv --against g.tsv --baseline before.csv --format csv -o v.csv
    assert_eq "$(verdict G1 | cut -d'|' -f1)" "not measured"
    assert_contains "$(cat v.csv)" "so the median would be over other hosts"
    # with no baseline at all, a relative limit is not measured, never a pass
    qd_rc check after.csv --against t.tsv --format csv -o v.csv
    assert_status "$QD_RC" 1
    assert_eq "$(verdict D1)" "not measured||0/4"
    assert_contains "$(cat v.csv)" "give one with --baseline"
}

t_baseline_where_and_units() {
    printf 'host,rack,rtt\na,r1,200us\nb,r1,300us\nc,r2,1ms\n' > before.csv
    printf 'host,rack,rtt\na,r1,0.25ms\nb,r1,300us\nc,r2,5ms\n' > after.csv
    # only rack r1 is held: c's slide is not this check's; a's 50us rise
    # is past +40us, and the offset is read in the cells' own unit
    limits t.tsv 'L1|rtt|<=|baseline+40us||rack=r1||' 'L2|rtt|<=|baseline+10%||rack=r1|max|'
    qd_rc check after.csv --against t.tsv --baseline before.csv --each --format csv -o v.csv
    assert_status "$QD_RC" 1
    assert_eq "$(row_verdict L1 a | cut -d'|' -f1-4)" "fail|250|<= baseline+40us (<= 240)|200"
    assert_eq "$(row_verdict L1 b | cut -d'|' -f1)" "pass"
    assert_eq "$(row_verdict L1 c)" ""
    qd_rc check after.csv --against t.tsv --baseline before.csv --format csv -o v.csv
    # the max over r1 is 300us in both (shown in ms, the cells'
    # commonest unit): the same population, no drift
    assert_eq "$(verdict L2)" "pass|0.3|2/2"
    # a unit the column is not in is refused, not guessed
    limits u.tsv 'U1|rtt|<=|baseline+5GB||||'
    qd_rc check after.csv --against u.tsv --baseline before.csv --format csv -o v.csv
    assert_status "$QD_RC" 1
    assert_contains "$(cat v.csv)" "the limit's unit does not fit rtt's"
}

t_baseline_old_files_and_bad_limits() {
    # a limit of words is still words: == baseline is the word baseline
    printf 'host,s\na,baseline\nb,other\n' > d.csv
    limits t.tsv 'S1|s|==|baseline|||'
    qd_rc check d.csv --against t.tsv --format csv -o v.csv
    assert_eq "$(verdict S1 | cut -d'|' -f1)" "fail"
    assert_contains "$(cat v.csv)" "1 of 2 failed: b"
    for lim in 'baseline*2' 'baseline-' 'baseline-x%' 'baselin-5%'; do
        limits b.tsv "B1|v|>=|$lim||||"
        qd_rc check d.csv --against b.tsv 2> err
        assert_status "$QD_RC" 2
    done
    limits b.tsv 'B1|v|>=|baseline*2||||'
    qd_rc check d.csv --against b.tsv 2> err
    assert_contains "$(cat err)" "baseline, baseline+N, baseline-N or baseline-N%"
    limits b.tsv 'B1|v|within|baseline|5||||'
    qd_rc check d.csv --against b.tsv 2> err
    assert_status "$QD_RC" 2
    assert_contains "$(cat err)" "within needs a tolerance"
    # without --baseline the verdict table is the one it always was
    data
    limits t.tsv 'R1|mbps|>=|900||status=ok||'
    assert_eq "$(qd check d.csv --against t.tsv --format csv 2>/dev/null | head -1 || true)" \
        "req,column,agg,where,observed,limit,unit,measured,verdict,note"
}

t_baseline_waivers_severity_junit_keep() {
    runof before 1000 1000 900 800
    runof after 980 920 890 800
    printf 'req\tcolumn\top\tlimit\tseverity\nD1\tmbps\t>=\tbaseline-5%%\tlow\n' > t.tsv
    # a low failure under --fail-level high is shown, not failing the run
    qd_rc check after --against t.tsv --baseline before --fail-level high > out
    assert_status "$QD_RC" 0
    assert_contains "$(cat out)" "below --fail-level high"
    # a waiver excuses the measured failure, as it does a fixed limit's
    printf 'req\tjustification\twhere\nD1\tb is being reseated\thost=b\n' > w.tsv
    qd_rc check after --against t.tsv --baseline before --waivers w.tsv --each --format csv -o v.csv
    assert_status "$QD_RC" 0
    assert_eq "$(row_verdict D1 b | cut -d'|' -f1)" "waived"
    qd_rc check after --against t.tsv --baseline before --each --format junit -o v.xml
    assert_status "$QD_RC" 1
    out="$(junit v.xml)"
    assert_contains "$out" "testsuite tests=4 failures=1 errors=0 skipped=0"
    assert_contains "$out" "|failure|"
    qd_rc check after --against t.tsv --baseline before --keep > out
    assert_status "$QD_RC" 1
    assert_contains "$(cat out)" "filed as"
    csv="$(qd show latest --format csv)"
    assert_contains "$csv" "D1,mbps,each,,920,>= baseline-5%,,4/4,fail"
    qd_rc check after --against t.tsv --baseline before --each --format ndjson -o v.nd
    assert_contains "$(cat v.nd)" '"baseline": 1000'
}

# a qualified baseline: one run of it gives what that run gives; five
# runs and five samples a host put the rank test in charge
t_baseline_qualified() {
    runof before 1000 1000 900 800
    qd baseline set gold before -c mbps > /dev/null
    runof after 980 920 890 800
    limits t.tsv 'D1|mbps|>=|baseline-5%||||'
    qd_rc check after --against t.tsv --baseline gold --each --format csv -o g.csv
    assert_status "$QD_RC" 1
    qd_rc check after --against t.tsv --baseline before --each --format csv -o r.csv
    assert_eq "$(cut -d, -f1-9 g.csv)" "$(cut -d, -f1-9 r.csv)"
    qd_rc check after --against t.tsv --baseline gold > out
    assert_contains "$(cat out)" "held to baseline gold (1 run)"

    for v in 100.0 100.2 99.9 100.1 99.8; do
        printf 'host,v\na,%s\nb,%s\n' "$v" "$v" > q.csv
        qd import q.csv --name quiet > /dev/null
    done
    qd baseline set good quiet --last 5 -c v > /dev/null
    # a: five samples, every one 8% down -- a change; b: a median 7% down
    # but samples either side of the baseline -- past the limit, not
    # significant, so not failed
    printf 'host,v\na,92\na,92.1\na,91.9\na,92.2\na,91.8\nb,80\nb,85\nb,93\nb,110\nb,120\n' > now.csv
    limits q.tsv 'Q1|v|>=|baseline-5%||||'
    qd_rc check now.csv --against q.tsv --baseline good --each --format csv -o v.csv
    assert_status "$QD_RC" 1
    assert_eq "$(row_verdict Q1 a | cut -d'|' -f1-2)" "fail|92"
    assert_eq "$(row_verdict Q1 b | cut -d'|' -f1-2)" "pass|93"
    qd_rc check now.csv --against q.tsv --baseline good --format csv -o v.csv
    assert_contains "$(cat v.csv)" "past the limit but not significant"
    assert_contains "$(cat v.csv)" "the rank test decided each host"
    # one sample a host: too few for the test, the medians decide
    printf 'host,v\na,92\nb,93\n' > one.csv
    qd_rc check one.csv --against q.tsv --baseline good --each --format csv -o v.csv
    assert_eq "$(row_verdict Q1 b | cut -d'|' -f1)" "fail"
    qd_rc check one.csv --against q.tsv --baseline good --format csv -o v.csv
    assert_contains "$(cat v.csv)" "decided on medians (the rank test wants 3 values"
}

# QD-050: cv, skew, kurtosis and zmax -- spread and shape over the rows

shape_data() {
    printf 'host,v,rtt,zero,same,two\na,1,1ms,0,5,1\nb,2,2ms,0,5,2\nc,3,3ms,1,5,\nd,4,4000us,-1,5,\ne,100,0.1s,0,6,\n' > d.csv
}

t_shape_known_values() {
    shape_data
    # 1, 2, 3, 4, 100 worked by hand: mean 22, deviations -21 -20 -19 -18
    # 78, their squares sum to 7610.
    #   cv: the sample stdev sqrt(7610/4) = 43.618, over 22 = 1.983
    #   skew (adjusted Fisher-Pearson, Excel's SKEW): m2 = 7610/5 = 1522,
    #     m3 = 444600/5 = 88920; g1 = 88920 / 1522^1.5 = 1.4975, and
    #     G1 = g1 sqrt(5*4)/3 = 2.232
    #   kurtosis (sample excess, Excel's KURT): m4 = 37604834/5, g2 =
    #     m4/m2^2 - 3 = 0.24671; G2 = (6 g2 + 6) * 4 / (3*2) = 4.987
    #   zmax: median 3, |x - 3| = 2 1 0 1 97, MAD 1; e's 0.6745*97 = 65.43
    limits t.tsv 'C|v|<=|0.05|||cv|' 'S|v|<|3|||skew|' 'K|v|>=|5|||kurtosis|' \
        'Z|v|<=|3.5|||zmax|' 'Z2|v|between|60|70||zmax|' 'C2|v|within|2|+-1%||cv|' \
        'S2|v|>|2.2|||skew|' 'K2|v|<=|4.99|||kurtosis|'
    qd_rc check d.csv --against t.tsv --format csv -o v.csv
    assert_status "$QD_RC" 1
    assert_eq "$(verdict C)" "fail|1.983|5/5"
    assert_eq "$(verdict S)" "pass|2.232|5/5"
    assert_eq "$(verdict K)" "fail|4.987|5/5"
    assert_eq "$(verdict Z)" "fail|65.43|5/5"
    assert_eq "$(verdict Z2)" "pass|65.43|5/5"
    assert_eq "$(verdict C2)" "pass|1.983|5/5"
    assert_eq "$(verdict S2)" "pass|2.232|5/5"
    assert_eq "$(verdict K2)" "pass|4.987|5/5"
    # the note names the worst host; the figures carry no unit
    assert_eq "$(field Z note)" "worst |z|: e (robust z +65.4; median 3, MAD 1)"
    assert_eq "$(field C unit)" ""
    # a column in units is read on one scale, and the unit does not scale
    # the figure: 1ms..0.1s is 1..100 in ms, so the same four figures
    limits u.tsv 'C|rtt|<=|0.05|||cv|' 'S|rtt|<|3|||skew|' 'K|rtt|>=|5|||kurtosis|' \
        'Z|rtt|<=|3.5|||zmax|'
    qd_rc check d.csv --against u.tsv --format csv -o v.csv
    assert_eq "$(verdict C)" "fail|1.983|5/5"
    assert_eq "$(verdict S)" "pass|2.232|5/5"
    assert_eq "$(verdict K)" "fail|4.987|5/5"
    assert_eq "$(verdict Z)" "fail|65.43|5/5"
    assert_eq "$(field Z unit)" ""
    # --each: a zmax row is its host's own robust z, held to the limit by
    # its size; a cv row carries the fleet's verdict
    qd_rc check d.csv --against t.tsv --each --format csv -o e.csv
    assert_contains "$(cat e.csv)" "Z,a,v,-1.349,<= 3.5,,pass"
    assert_contains "$(cat e.csv)" "Z,e,v,65.43,<= 3.5,,fail"
    assert_contains "$(cat e.csv)" "C,a,v,1,<= 0.05,,fail"
}

t_shape_not_measured() {
    shape_data
    limits t.tsv 'C1|v|<=|1||host=a|cv|' 'S2|two|<=|1|||skew|' 'K3|v|<=|1||v<10 and host!=d|kurtosis|' \
        'Z2|two|<=|3.5|||zmax|' 'C0|zero|<=|1|||cv|' 'Z0|same|<=|3.5|||zmax|' \
        'S0|same|<=|1||host!=e|skew|' 'K0|same|<=|1||host!=e|kurtosis|' 'ZB|two|<=|3.5||host=a|zmax|'
    qd_rc check d.csv --against t.tsv --format csv -o v.csv
    assert_status "$QD_RC" 1
    # blank is never a pass: each says why, and none shows a figure
    assert_eq "$(verdict C1)" "not measured||1/1"
    assert_eq "$(field C1 note)" "cv wants 2 values or more, and has 1"
    assert_eq "$(verdict S2)" "not measured||2/5"
    assert_contains "$(field S2 note)" "skew wants 3 values or more, and has 2"
    assert_contains "$(field S2 note)" "not measured: c, d, e"
    assert_eq "$(field K3 note)" "kurtosis wants 4 values or more, and has 3"
    assert_contains "$(field Z2 note)" "zmax wants 3 values or more, and has 2"
    assert_eq "$(verdict C0)" "not measured||5/5"
    assert_eq "$(field C0 note)" "the mean is 0, so cv (stdev / mean) is not defined"
    assert_eq "$(verdict Z0)" "not measured||5/5"
    assert_contains "$(field Z0 note)" "the MAD is 0"
    assert_eq "$(field S0 note)" "every value is the same, so skew is not defined"
    assert_eq "$(field K0 note)" "every value is the same, so kurtosis is not defined"
    # a figure over some rows but not all is shown, and not passed
    limits b.tsv 'C|two|<=|1|||cv|'
    qd_rc check d.csv --against b.tsv --format csv -o v.csv
    assert_eq "$(verdict C)" "not measured|0.4714|2/5"
    assert_contains "$(field C note)" "cv over 2 of 5 (cv would pass); not measured: c, d, e"
    qd_rc check d.csv --against t.tsv --format junit -o v.xml
    assert_contains "$(junit v.xml)" "Z0|zmax of same <= 3.5|error|not measured: the MAD is 0"
}

t_shape_units_refused() {
    shape_data
    for row in 'C|v|<=|5%|||cv|' 'S|v|<=|1ms|||skew|' 'K|v|between|1|2s||kurtosis|' \
        'Z|v|<=|3.5|||zmax|us' 'Z|v|<=|baseline+2ms|||zmax|' 'S|v|within|1|+-2us||skew|' \
        'Z|v|within|baseline|+-1ms||zmax|'; do
        limits t.tsv 'OK|v|<=|1000||||' "$row"
        qd_rc check d.csv --against t.tsv > out 2>&1
        assert_status "$QD_RC" 2
        assert_contains "$(cat out)" "t.tsv, check 2 ("
    done
    limits t.tsv 'Z|v|<=|3.5|||zmax|us'
    qd_rc check d.csv --against t.tsv > out 2>&1
    assert_contains "$(cat out)" "check 1 (Z): zmax is unitless, so its limit takes no unit (unit us)"
    # a percentage tolerance, or of the baseline, is a share, not a unit
    limits t.tsv 'C|v|within|2|+-10%||cv|' 'Z|v|<=|baseline+10%|||zmax|'
    qd_rc check d.csv --against t.tsv --baseline d.csv --format csv -o v.csv
    assert_eq "$(verdict C | cut -d'|' -f1)" "pass"
    assert_eq "$(verdict Z | cut -d'|' -f1)" "pass"
}

t_shape_zmax_is_qd_outliers() {
    printf 'host,mbps\nn1,940\nn2,951\nn3,948\nn4,612\nn5,955\nn6,944\nn7,990\n' > d.csv
    limits t.tsv 'Z|mbps|<=|3.5|||zmax|'
    qd_rc check d.csv --against t.tsv --format csv -o v.csv
    assert_status "$QD_RC" 1
    out="$(qd outliers d.csv mbps --format csv)"
    worst="$(printf '%s\n' "$out" | sed -n 2p)"
    # the same host, and the same score: outliers' robust_z to one place
    assert_eq "$(printf '%s' "$worst" | cut -d, -f1)" "n4"
    assert_contains "$(field Z note)" "worst |z|: n4 (robust z $(printf '%s' "$worst" | cut -d, -f4);"
    assert_eq "$("$PY" -c 'import sys; print("%.1f" % -float(sys.argv[1]))' "$(field Z observed)")" \
        "$(printf '%s' "$worst" | cut -d, -f4)"
    # hosts that repeat: each host's median, as outliers takes them
    printf 'host,v\na,1\na,2\nb,2\nb,3\nc,3\nc,3\nd,50\nd,60\n' > r.csv
    limits t.tsv 'Z|v|<=|3.5|||zmax|'
    qd_rc check r.csv --against t.tsv --format csv -o v.csv
    out="$(qd outliers r.csv v --format csv | sed -n 2p)"
    assert_eq "$(printf '%s' "$out" | cut -d, -f1,4)" "d,+47.0"
    assert_eq "$(verdict Z)" "fail|46.99|8/8"
    assert_contains "$(field Z note)" "worst |z|: d (robust z +47.0; median 2.75, MAD 0.75, per host)"
}

t_shape_old_files_unchanged() {
    # a thresholds file gives the same rows with the new aggregates beside
    # it as without (and t_unchanged_without_the_new_columns pins the
    # bytes of one without)
    data
    limits old.tsv 'R1|mbps|>=|900||status=ok||' 'R2|temp|between|20|45|rack=r1|max|' \
        'R3|rtt|<=|250||||us' 'R4|mem|<=|1.5G||status=ok|p99|' 'R5|temp|<=|45|||stdev|'
    qd_rc check d.csv --against old.tsv --format csv -o before.csv
    cp old.tsv new.tsv
    printf 'N1\ttemp\t<=\t1\t\t\tcv\t\nN2\ttemp\t<=\t3.5\t\t\tzmax\t\n' >> new.tsv
    qd_rc check d.csv --against new.tsv --format csv -o after.csv
    assert_eq "$(grep -v '^N' after.csv)" "$(cat before.csv)"
    qd_rc check d.csv --against old.tsv --each --format csv -o before.csv
    qd_rc check d.csv --against new.tsv --each --format csv -o after.csv
    assert_eq "$(grep -v '^N' after.csv)" "$(cat before.csv)"
}

t_shape_junit_waivers_severity_keep() {
    shape_data
    printf 'req\tcolumn\top\tlimit\tagg\tseverity\nZ\tv\t<=\t3.5\tzmax\tlow\nC\tv\t<=\t3\tcv\t\n' > t.tsv
    qd_rc check d.csv --against t.tsv --format junit -o v.xml
    assert_status "$QD_RC" 1
    got="$(junit v.xml)"
    assert_contains "$got" "testsuite tests=2 failures=1 errors=0 skipped=0"
    assert_contains "$got" "Z|zmax of v <= 3.5|failure|observed 65.43; want <= 3.5"
    qd_rc check d.csv --against t.tsv --each --format junit -o e.xml
    assert_contains "$(junit e.xml)" "|failure|observed 65.43; want <= 3.5"
    # a low failure under --fail-level high is let off, as any other
    qd_rc check d.csv --against t.tsv --fail-level high > out
    assert_status "$QD_RC" 0
    # a waiver over every row excuses the figure
    waivers w.tsv 'Z|e is a known slow host||||QA'
    qd_rc check d.csv --against t.tsv --waivers w.tsv --format csv -o v.csv
    assert_status "$QD_RC" 0
    assert_eq "$(verdict Z | cut -d'|' -f1)" "waived"
    qd_rc check d.csv --against t.tsv --keep > out
    assert_contains "$(cat out)" "filed as"
    assert_contains "$(qd show latest --format csv)" "Z,v,zmax,,65.43,<= 3.5,,5/5,fail"
}

t_shape_baseline() {
    printf 'host,v\na,100\nb,101\nc,99\nd,100\ne,102\n' > before.csv
    printf 'host,v\na,100\nb,101\nc,99\nd,100\ne,130\n' > after.csv
    # the baseline's figure over the same hosts: cv 0.01136, zmax 1.349
    limits t.tsv 'C|v|<=|baseline+0.05|||cv|' 'Z|v|<=|baseline+2|||zmax|' \
        'P|v|<=|baseline+50%|||cv|' 'W|v|within|baseline|+-1||skew|'
    qd_rc check after.csv --against t.tsv --baseline before.csv --format csv -o v.csv
    assert_status "$QD_RC" 1
    assert_eq "$(verdict C)" "fail|0.1267|5/5"
    assert_eq "$(field C limit)" "<= baseline+0.05 (<= 0.06136)"
    assert_eq "$(field C baseline)" "0.01136"
    assert_eq "$(verdict Z)" "fail|20.23|5/5"
    assert_eq "$(field Z limit)" "<= baseline+2 (<= 3.349)"
    assert_eq "$(field P limit)" "<= baseline+50% (<= 0.01703)"
    # against itself, nothing moved
    qd_rc check before.csv --against t.tsv --baseline before.csv > out
    assert_status "$QD_RC" 0
    assert_contains "$(cat out)" "4 pass, 0 fail, 0 not measured"
    # a host the baseline lacks: a figure over other hosts is not measured
    printf 'host,v\na,100\nb,101\nc,99\nd,100\nnew,500\n' > n.csv
    qd_rc check n.csv --against t.tsv --baseline before.csv --format csv -o v.csv
    assert_eq "$(verdict Z)" "not measured||5/5"
    assert_contains "$(field Z note)" "1 not in run before.csv, so the zmax would be over other hosts: new"
    # a baseline whose own figure cannot be had is not measured either
    printf 'host,v\na,5\nb,5\nc,5\nd,5\ne,5\n' > flat.csv
    qd_rc check after.csv --against t.tsv --baseline flat.csv --format csv -o v.csv
    assert_eq "$(verdict Z | cut -d'|' -f1)" "not measured"
    assert_contains "$(field Z note)" "in run flat.csv: the MAD is 0"
}

# --rule (QD-051): a fixed verdict table.  S1, S2 pass; F1, F2 fail; U1 is
# not measured (b has no u).  The weights: S2 2, the rest 1.
rule_data() {
    printf 'host,s,f,u\na,1,9,1\nb,1,9,\n' > r.csv
    printf 'req\tcolumn\top\tlimit\tseverity\tweight\n' > r.tsv
    printf '%s\n' 'S1|s|<=|5||' 'S2|s|<|5||2' 'F1|f|<=|5|low|' \
        'F2|f|<|5||1' 'U1|u|<=|5||' | tr '|' '\t' >> r.tsv
}

# rule_is RULE VERDICT RC [ARGS...]: the head's overall verdict and the
# exit status
rule_is() {
    qd_rc check r.csv --against r.tsv --rule "$1" "${@:4}" > out 2> err
    assert_status "$QD_RC" "$3"
    assert_contains "$(head -1 out)" "; rule $2: "
}

t_rule_each_kind_nested() {
    rule_data
    rule_is 'all(S*, any(F1, S1))'                  pass 0
    rule_is 'all(S*, not(any(F*)))'                 pass 0
    rule_is 'any(F1, all(F2, S1))'                  fail 1
    rule_is 'atleast(2, S1, F1, all(S2, not(F2)))'  pass 0
    rule_is 'not(atleast(3, S*, F*))'               pass 0
    rule_is 'any(not(all(S1, atleast(1, S2, F2))), F1)' fail 1
    # S1 1 + S2 2 + F1 1: 3 of 4 is 0.75
    rule_is 'all(weighted(0.75, S*, F1), not(F2))'  pass 0
    assert_contains "$(cat out)" "weighted score 0.75 of 3 (3 of 4), need 0.75"
    rule_is 'all(weighted(0.8, S*, F1), not(F2))'   fail 1
    assert_contains "$(cat out)" "rule fail         all(weighted(0.8, S*, F1), not(F2))"
    assert_contains "$(cat out)" "weighted score 0.75 of 3 (3 of 4), need 0.8"
    rule_is 'weighted(0.5, S1, F*)'                 fail 1
    # the head says why: 2 of 4, need 3; by the glob when one gave them all
    rule_is 'atleast(3, S*, F*)' fail 1
    assert_contains "$(head -1 out)" "; rule fail: 2 of 4 passed, need 3"
    rule_is 'atleast(2, S*)' pass 0
    assert_contains "$(head -1 out)" "; rule pass: 2 of 2 S* passed, need 2"
    # one req alone is a rule too; what the rule leaves out counts for nothing
    rule_is 'S1' pass 0
    assert_contains "$(cat out)" "not in the rule, so not counted: S2, F1, F2, U1"
    rule_is 'F1' fail 1
    # QD_RULE, and case in the calls' names
    QD_RULE='ALL(S1, Not(F2))' qd_rc check r.csv --against r.tsv > out
    assert_status "$QD_RC" 0
    assert_contains "$(head -1 out)" "; rule pass: all 2 passed"
    # the verdicts of the checks themselves are not changed
    qd_rc check r.csv --against r.tsv --rule 'S1' --format csv -o v.csv
    assert_eq "$(field F1 verdict)" "fail"
    assert_eq "$(field U1 verdict)" "not measured"
}

t_rule_unmeasured_waived_unexpected() {
    rule_data
    # not measured is not a pass, and not() of it is not measured either
    rule_is 'all(S1, U1)'               "not measured" 1
    assert_contains "$(head -1 out)" "1 of 2 passed, need all 2; 1 not measured: U1"
    rule_is 'not(U1)'                   "not measured" 1
    rule_is 'any(S1, U1)'               pass 0
    rule_is 'any(F1, U1)'               "not measured" 1
    rule_is 'atleast(2, S1, U1, F1)'    "not measured" 1
    rule_is 'atleast(2, S1, U1, S2)'    pass 0
    rule_is 'atleast(3, S1, U1, F1, F2)' fail 1
    # U1 weighs 1 of 5: S is 3 of 5, 0.6; with U1 it could be 0.8
    rule_is 'weighted(0.8, S*, U1, F2)' "not measured" 1
    rule_is 'weighted(0.6, S*, U1, F2)' pass 0
    # a waived failure counts as a pass
    waivers w.tsv 'F2|agreed deviation, FSE-9||||'
    rule_is 'all(S1, F2)' pass 0 --waivers w.tsv
    assert_contains "$(cat out)" "F2 passed (waived)"
    # an unexpected pass as a fail
    waivers w.tsv 'S1|thought broken|||fail|'
    rule_is 'all(S1, S2)' fail 1 --waivers w.tsv
    rule_is 'S1' fail 1 --waivers w.tsv
    assert_contains "$(head -1 out)" "S1 failed (unexpected pass)"
    # --fail-level lets F1 (low) off inside the rule; F2 has no severity
    rule_is 'all(S1, F1)' pass 0 --fail-level medium
    assert_contains "$(cat out)" "F1 passed (below --fail-level)"
    rule_is 'all(S1, F1)' fail 1
    rule_is 'all(S1, F2)' fail 1 --fail-level critical
    # a req's checks are taken together: one failing check fails it
    printf 'S1\tf\t<=\t5\t\t\n' >> r.tsv
    rule_is 'S1' fail 1
}

t_rule_refused() {
    rule_data
    refused() {   # refused RULE MESSAGE
        qd_rc check r.csv --against r.tsv --rule "$1" > out 2> err
        assert_status "$QD_RC" 2
        assert_contains "$(cat err)" "$2"
        assert_eq "$(cat out)" ""
    }
    refused 'all(S1, X9)'            "--rule 'all(S1, X9)': unknown req X9 (the thresholds file has S1, S2, F1, F2, U1)"
    refused 'any(Z*)'                "Z* matches no req of the thresholds file"
    refused 'atleast(3, S*)'         "atleast(3, ...) of 2 items: N is 1 to 2"
    refused 'atleast(0, S*)'         "N is 1 to 2"
    refused 'atleast(2.5, S*)'       "atleast wants a whole number first, not '2.5'"
    refused 'weighted(1.2, S*)'      "weighted wants a threshold from 0 to 1 first, not '1.2'"
    refused 'weighted(-0.1, S*)'     "weighted wants a threshold from 0 to 1 first"
    refused 'weighted(x, S*)'        "weighted wants a threshold from 0 to 1 first, not 'x'"
    refused 'all(S1'                 "it ends too soon: want )"
    refused 'all(S1,)'               "want a req or a call, not ')'"
    refused 'all()'                  "all() is empty"
    refused 'both(S1)'               "unknown call both()"
    refused 'S*'                     "S* matches 2 reqs where one belongs"
    refused 'not(F*)'                "F* matches 2 reqs where one belongs"
    refused 'not(S1, S2)'            "want ), not ','"
    refused 'S1 S2'                  "'S2' after the end of the rule"
    refused 'all(S1, S*)'            "S1 is named twice in one list"
    refused 'weighted(0.5, all(S1))' "weighted takes reqs and globs, not all()"
    refused '   ,'                   "want a req or a call, not ','"
    # weights: a number 0 or more, one per requirement, and not all 0
    printf 'S1\tf\t>\t1\t\tx\n' >> r.tsv
    refused 'S1' "check 6 (S1): weight 'x' is not a number 0 or more"
    rule_data
    printf 'S2\tf\t>\t1\t\t3\n' >> r.tsv
    refused 'S2' "weight 3, but check 2 gives S2 weight 2; a requirement has one weight"
    rule_data
    printf 'Z1\tf\t>\t1\t\t0\n' >> r.tsv
    refused 'weighted(0.5, Z1)' "the weights of weighted(0.5, ...) add up to 0"
}

t_rule_none_unchanged() {
    rule_data
    # no rule, a blank QD_RULE, and the weight column taken away: the same
    qd_rc check r.csv --against r.tsv > a.txt 2> /dev/null
    assert_status "$QD_RC" 1
    QD_RULE= qd_rc check r.csv --against r.tsv > b.txt 2> /dev/null
    assert_status "$QD_RC" 1
    cut -f1-5 r.tsv > n.tsv
    qd_rc check r.csv --against n.tsv > c.txt 2> /dev/null
    assert_status "$QD_RC" 1
    assert_eq "$(cat b.txt)" "$(cat a.txt)"
    assert_eq "$(sed 1d c.txt)" "$(sed 1d a.txt)"
    assert_not_contains "$(cat a.txt)" "rule"
    for f in csv json junit; do
        qd_rc check r.csv --against r.tsv --format "$f" > a.out 2> /dev/null
        qd_rc check r.csv --against n.tsv --format "$f" > c.out 2> /dev/null
        assert_not_contains "$(cat a.out)" "(rule)"
        [ "$f" = junit ] || assert_eq "$(cat c.out)" "$(cat a.out)"
    done
    # --fail-level alone exits as it always did: F2 has no severity
    qd_rc check r.csv --against n.tsv --fail-level critical > /dev/null 2>&1
    assert_status "$QD_RC" 1
}

rule_props() {   # the rule's properties of JUnit file $1, name=value
    "$PY" - "$1" <<'PYEOF'
import sys
import xml.etree.ElementTree as ET
s = ET.parse(sys.argv[1]).getroot().find("testsuite")
for p in s.find("properties"):
    if p.get("name").startswith("rule"):
        print("%s=%s" % (p.get("name"), p.get("value")))
PYEOF
}

t_rule_formats_junit_keep() {
    rule_data
    qd_rc check r.csv --against r.tsv --rule 'all(S*, atleast(1, F*))' \
        --format csv -o v.csv
    assert_status "$QD_RC" 1
    assert_eq "$(tail -1 v.csv)" '(rule),,,,"2 of 3 passed, need all 3; failed: atleast(1, F*)","all(S*, atleast(1, F*))",,,fail,,'
    qd_rc check r.csv --against r.tsv --rule 'atleast(1, F*)' --format json -o v.json
    assert_status "$QD_RC" 1
    "$PY" - v.json > got <<'PYEOF'
import json, sys
rows = json.load(open(sys.argv[1]))
rows = rows["rows"] if isinstance(rows, dict) else rows
r = [x for x in rows if x["req"] == "(rule)"][0]
print("%s|%s|%s" % (r["limit"], r["verdict"], r["observed"]))
PYEOF
    assert_eq "$(cat got)" "atleast(1, F*)|fail|0 of 2 F* passed, need 1"
    qd_rc check r.csv --against r.tsv --rule 'all(S1, S2)' --each --format csv -o e.csv
    assert_status "$QD_RC" 0
    assert_eq "$(tail -1 e.csv)" '(rule),,,all 2 passed,"all(S1, S2)",,pass,'
    # JUnit: one more testcase, and the suite's properties
    qd_rc check r.csv --against r.tsv --rule 'all(S*, not(U1))' --format junit -o j.xml
    assert_status "$QD_RC" 1
    got="$(junit j.xml)"
    assert_contains "$got" "testsuite tests=6 failures=2 errors=2 skipped=0"
    assert_contains "$got" "rule|all(S*, not(U1))|error|rule not measured: 2 of 3 passed, need all 3; 1 not measured: not(U1)"
    props="$(rule_props j.xml)"
    assert_contains "$props" "rule=all(S*, not(U1))"
    assert_contains "$props" "rule.verdict=not measured"
    qd_rc check r.csv --against r.tsv --rule 'any(S1, F1)' --format junit -o j.xml
    assert_status "$QD_RC" 0
    assert_contains "$(junit j.xml)" "rule|any(S1, F1)|pass|"
    assert_contains "$(rule_props j.xml)" "rule.verdict=pass"
    qd_rc check r.csv --against r.tsv --rule 'F1' --format junit -o j.xml
    assert_contains "$(junit j.xml)" "rule|F1|failure|rule failed: F1 failed"
    # --keep files it, and the command it came from
    qd_rc check r.csv --against r.tsv --rule 'all(S*, atleast(1, F*))' --keep > out
    assert_status "$QD_RC" 1
    csv="$(qd show latest --format csv)"
    assert_contains "$csv" '(rule),,,,"2 of 3 passed, need all 3; failed: atleast(1, F*)","all(S*, atleast(1, F*))",,,fail,,'
    assert_contains "$(qd log latest)" "--rule 'all(S*, atleast(1, F*))'"
}

# ---------------------------------------------------------------------------
# A person's results for requirements nothing measures (QD-052)
# ---------------------------------------------------------------------------

# the thresholds of the manual cases: a measured check, a manual one
# over every row, and one over rack r1 with no column
manual_data() {
    data
    printf 'req\tcolumn\top\tlimit\twhere\tnote\n' > t.tsv
    printf '%s\n' 'R1|status|in|ok,unreachable||' \
        'M1|cabling|manual|||as built' 'M2||manual||rack=r1|' \
        | tr '|' '\t' >> t.tsv
}

# results REQ|verdict|by|date|where|note ...: a manual file m.tsv
results() {
    printf 'req\tverdict\tby\tdate\twhere\tnote\n' > m.tsv
    for row in "$@"; do printf '%s\n' "$row" | tr '|' '\t' >> m.tsv; done
}

# the manual cells of one row of v.csv: verdict|observed|by|date|note
manual_row() {
    "$PY" -c '
import csv, sys
for r in csv.DictReader(open(sys.argv[1])):
    if r["req"] == sys.argv[2] and r.get("row", "") == sys.argv[3]:
        print("|".join((r["verdict"], r["observed"], r["decided_by"],
                        r["decided"], r["decision_note"])))
' v.csv "$1" "${2:-}"
}

t_manual_none_is_not_measured() {
    manual_data
    qd_rc check d.csv --against t.tsv --format csv -o v.csv
    assert_status "$QD_RC" 1
    assert_eq "$(verdict M1)" "not measured||0/4"
    assert_eq "$(verdict M2)" "not measured||0/2"
    assert_contains "$(cat v.csv)" "manual: no result given for it (--manual FILE)"
    # the measured check is as it was, and no manual columns appear
    assert_eq "$(verdict R1)" "pass|ok|4/4"
    assert_eq "$(head -1 v.csv)" "req,column,agg,where,observed,limit,unit,measured,verdict,note"
    # a result for one req leaves the other not measured
    results 'M1|pass|J. Smith|2999-01-01||'
    qd_rc check d.csv --against t.tsv --manual m.tsv --format csv -o v.csv
    assert_status "$QD_RC" 1
    assert_eq "$(verdict M1)" "pass|manual pass|4/4"
    assert_eq "$(verdict M2)" "not measured||0/2"
    # a result whose where picks some rows leaves the rest not measured
    results 'M1|pass|J. Smith|||' 'M2|pass|QA||host=a|'
    qd_rc check d.csv --against t.tsv --manual m.tsv --format csv -o v.csv
    assert_status "$QD_RC" 1
    assert_eq "$(verdict M2)" "not measured||1/2"
    assert_contains "$(cat v.csv)" "1 of 2 not measured: b"
    # a where no row matches decides nothing either
    results 'M1|pass|J. Smith||host=zz|' 'M2|pass|QA|||'
    qd_rc check d.csv --against t.tsv --manual m.tsv --format csv -o v.csv
    assert_eq "$(verdict M1)" "not measured||0/4"
}

t_manual_pass_and_fail() {
    manual_data
    # pass, without where: every row of the check; the run passes
    results 'M1|pass|J. Smith|2026-11-17||all patched' 'M2|PASS|QA|2026-11-18 09:30||'
    qd_rc check d.csv --against t.tsv --manual m.tsv --format csv -o v.csv
    assert_status "$QD_RC" 0
    assert_eq "$(manual_row M1)" "pass|manual pass|J. Smith|2026-11-17|all patched"
    assert_eq "$(manual_row M2)" "pass|manual pass|QA|2026-11-18 09:30|"
    assert_eq "$(manual_row R1)" "pass|ok|||"
    assert_eq "$(head -1 v.csv)" "req,column,agg,where,observed,limit,unit,measured,verdict,note,decided_by,decided,decision_note"
    qd_rc check d.csv --against t.tsv --manual m.tsv > out
    assert_contains "$(head -1 out)" "3 pass, 0 fail, 0 not measured"
    assert_contains "$(cat out)" "manual m.tsv: 2 results by J. Smith, QA"
    # --each: a row per host, each with who decided it
    qd_rc check d.csv --against t.tsv --manual m.tsv --each --format csv -o v.csv
    assert_status "$QD_RC" 0
    assert_eq "$(manual_row M1 d)" "pass|manual pass|J. Smith|2026-11-17|all patched"
    assert_eq "$(grep -c '^M1,' v.csv)" "4"
    assert_eq "$(grep -c '^M2,' v.csv)" "2"
    # fail, without where: the check fails, on every host under --each
    results 'M1|fail|J. Smith|2026-11-17||loose patch lead' 'M2|pass|QA||'
    qd_rc check d.csv --against t.tsv --manual m.tsv --format csv -o v.csv
    assert_status "$QD_RC" 1
    assert_eq "$(manual_row M1)" "fail|manual fail|J. Smith|2026-11-17|loose patch lead"
    assert_contains "$(cat v.csv)" "4 of 4 failed: a, b, c, d"
    qd_rc check d.csv --against t.tsv --manual m.tsv --each --format csv -o v.csv
    assert_eq "$(manual_row M1 c | cut -d'|' -f1)" "fail"
    # with where (a bare word is a host): only the rows it picks
    results 'M1|pass|J. Smith|||' 'M2|pass|QA||a|' 'M2|fail|QA|2026-11-18|b|label swapped'
    qd_rc check d.csv --against t.tsv --manual m.tsv --format csv -o v.csv
    assert_status "$QD_RC" 1
    assert_eq "$(manual_row M2)" "fail|manual fail|QA|2026-11-18|label swapped"
    assert_contains "$(cat v.csv)" "1 of 2 failed: b"
    qd_rc check d.csv --against t.tsv --manual m.tsv --each --format csv -o v.csv
    assert_eq "$(manual_row M2 a)" "pass|manual pass|QA||"
    assert_eq "$(manual_row M2 b)" "fail|manual fail|QA|2026-11-18|label swapped"
    # a pass for every row and a fail for one: the fail stands
    results 'M1|pass|J. Smith|||' 'M2|pass|QA|||' 'M2|fail|Ops||host=b|'
    qd_rc check d.csv --against t.tsv --manual m.tsv --format csv -o v.csv
    assert_eq "$(verdict M2 | cut -d'|' -f1)" "fail"
    assert_contains "$(cat v.csv)" "results disagree on b: the fail stands"
    # with where, a pass for the rows it picks under --each
    results 'M1|pass|J. Smith||rack=r2|' 'M1|pass|Ops||rack=r1|' 'M2|pass|QA||rack=r1|'
    qd_rc check d.csv --against t.tsv --manual m.tsv --each --format csv -o v.csv
    assert_status "$QD_RC" 0
    assert_eq "$(manual_row M1 a | cut -d'|' -f3)" "Ops"
    assert_eq "$(manual_row M1 d | cut -d'|' -f3)" "J. Smith"
    # QD_MANUAL for the flag
    QD_MANUAL=m.tsv qd_rc check d.csv --against t.tsv --format csv -o v.csv
    assert_status "$QD_RC" 0
    # --rule takes a manual verdict as any other
    results 'M1|pass|J. Smith|||' 'M2|fail|QA|||'
    qd_rc check d.csv --against t.tsv --manual m.tsv --rule 'all(R1, M1)' > out
    assert_status "$QD_RC" 0
    qd_rc check d.csv --against t.tsv --manual m.tsv --rule 'all(M*)' > out
    assert_status "$QD_RC" 1
    assert_contains "$(head -1 out)" "; rule fail: "
}

t_manual_waived() {
    manual_data
    results 'M1|fail|J. Smith|2026-11-17||loose patch lead' 'M2|pass|QA|||'
    printf 'req\tjustification\twhere\tgranted_by\nM1\trecabled next week, FSE-9\t\tQA board\n' > w.tsv
    qd_rc check d.csv --against t.tsv --manual m.tsv --waivers w.tsv --format csv -o v.csv
    assert_status "$QD_RC" 0
    assert_eq "$(verdict M1 | cut -d'|' -f1)" "waived"
    assert_contains "$(cat v.csv)" "recabled next week, FSE-9"
    assert_eq "$(manual_row M1 | cut -d'|' -f3)" "J. Smith"
    # a waiver whose where covers some hosts: the rest still fail
    printf 'req\tjustification\twhere\nM1\tc is spare\thost=c\n' > w.tsv
    qd_rc check d.csv --against t.tsv --manual m.tsv --waivers w.tsv --each --format csv -o v.csv
    assert_status "$QD_RC" 1
    assert_eq "$(manual_row M1 c | cut -d'|' -f1)" "waived"
    assert_eq "$(manual_row M1 a | cut -d'|' -f1)" "fail"
    # expect fail on a manual pass is an unexpected pass
    results 'M1|pass|J. Smith|||' 'M2|pass|QA|||'
    printf 'req\tjustification\texpect\nM1\tlead still loose\tfail\n' > w.tsv
    qd_rc check d.csv --against t.tsv --manual m.tsv --waivers w.tsv --format csv -o v.csv
    assert_status "$QD_RC" 1
    assert_eq "$(verdict M1 | cut -d'|' -f1)" "unexpected pass"
    # not measured is never waived, manual or not
    results 'M2|pass|QA|||'
    printf 'req\tjustification\nM1\tnot inspected yet\n' > w.tsv
    qd_rc check d.csv --against t.tsv --manual m.tsv --waivers w.tsv --format csv -o v.csv
    assert_eq "$(verdict M1 | cut -d'|' -f1)" "not measured"
}

t_manual_refused() {
    manual_data
    bad_manual() {   # bad_manual TEXT: m.tsv of TEXT is exit 2 naming TEXT
        local want="$1"
        shift
        printf '%s\n' "$@" > m.tsv
        qd_rc check d.csv --against t.tsv --manual m.tsv > out 2> err
        assert_status "$QD_RC" 2
        assert_contains "$(cat err)" "$want"
    }
    bad_manual "m.tsv, result 2 (M9): no check has req M9, so it would decide nothing" \
        $'req\tverdict\tby' $'M1\tpass\tme' $'M9\tpass\tme'
    bad_manual "m.tsv, result 1 (R1): R1 is measured, not manual" \
        $'req\tverdict\tby' $'R1\tpass\tme'
    bad_manual "m.tsv, result 1 (M1): verdict 'ok': want pass or fail" \
        $'req\tverdict\tby' $'M1\tok\tme'
    bad_manual "m.tsv, result 1 (M1): verdict 'waived': want pass or fail" \
        $'req\tverdict\tby' $'M1\twaived\tme'
    bad_manual "m.tsv, result 1 (M1): by is blank" \
        $'req\tverdict\tby' $'M1\tpass\t '
    bad_manual "m.tsv, result 1 (M1): verdict is blank" \
        $'req\tverdict\tby' $'M1\t\tme'
    bad_manual "m.tsv, result 1 (M1): date '17/11/2026' is not a date" \
        $'req\tverdict\tby\tdate' $'M1\tpass\tme\t17/11/2026'
    bad_manual "m.tsv, result 1 (M1): date '2026-02-30' is not a date" \
        $'req\tverdict\tby\tdate' $'M1\tpass\tme\t2026-02-30'
    bad_manual "m.tsv, result 1 (M1): date '2026-11-17T25:00' is not a date" \
        $'req\tverdict\tby\tdate' $'M1\tpass\tme\t2026-11-17T25:00'
    bad_manual "m.tsv, result 1 (M1): where 'host=(': " \
        $'req\tverdict\tby\twhere' $'M1\tpass\tme\thost=('
    bad_manual "m.tsv: the header needs by" $'req\tverdict' $'M1\tpass'
    bad_manual "m.tsv: unknown column who" $'req\tverdict\tby\twho' $'M1\tpass\tme\tx'
    bad_manual "m.tsv holds no results" $'req\tverdict\tby'
    qd_rc check d.csv --against t.tsv --manual nope.tsv 2> err
    assert_status "$QD_RC" 2
    assert_contains "$(cat err)" "no such manual file: nope.tsv"
    # and in the thresholds file: a manual check has no limit or agg
    printf 'req\tcolumn\top\tlimit\nM1\tx\tmanual\t5\n' > b.tsv
    qd_rc check d.csv --against b.tsv 2> err
    assert_status "$QD_RC" 2
    assert_contains "$(cat err)" "b.tsv, check 1 (M1): op manual takes no limit ('5')"
    printf 'req\tcolumn\top\tlimit\tagg\nM1\t\tmanual\t\tmax\n' > b.tsv
    qd_rc check d.csv --against b.tsv 2> err
    assert_status "$QD_RC" 2
    assert_contains "$(cat err)" "op manual takes no agg ('max')"
    # a measured check still needs its column and limit
    printf 'req\tcolumn\top\tlimit\nR1\tmbps\t>=\t\n' > b.tsv
    qd_rc check d.csv --against b.tsv 2> err
    assert_status "$QD_RC" 2
    assert_contains "$(cat err)" "limit is blank"
}

t_manual_junit_keep() {
    manual_data
    results 'M1|fail|J. Smith|2026-11-17||loose lead' 'M2|pass|QA|2026-11-18||'
    qd_rc check d.csv --against t.tsv --manual m.tsv --format junit -o v.xml
    assert_status "$QD_RC" 1
    got="$(junit v.xml)"
    assert_contains "$got" "testsuite tests=3 failures=1 errors=0 skipped=0"
    assert_contains "$got" "M1|cabling manual|failure|failed by a person's decision: J. Smith on 2026-11-17: loose lead"
    assert_contains "$got" "M2|manual where rack=r1|pass|"
    "$PY" - v.xml > props <<'PYEOF'
import sys
import xml.etree.ElementTree as ET
s = ET.parse(sys.argv[1]).getroot().find("testsuite")
for p in s.find("properties"):
    print("suite %s=%s" % (p.get("name"), p.get("value")))
for tc in s.findall("testcase"):
    ps = tc.find("properties")
    for p in (ps if ps is not None else []):
        print("%s %s=%s" % (tc.get("classname"), p.get("name"), p.get("value")))
PYEOF
    sum="$("$PY" -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' m.tsv)"
    assert_contains "$(cat props)" "suite manual=m.tsv"
    assert_contains "$(cat props)" "suite manual.sha256=$sum"
    assert_contains "$(cat props)" "M1 by=J. Smith"
    assert_contains "$(cat props)" "M1 date=2026-11-17"
    assert_contains "$(cat props)" "M2 by=QA"
    # --each: a testcase per host, each carrying who decided it
    qd_rc check d.csv --against t.tsv --manual m.tsv --each --format junit -o e.xml
    assert_contains "$(junit e.xml)" "M1|b|failure|failed by a person's decision: J. Smith"
    # waived: skipped, as any waived failure
    printf 'req\tjustification\nM1\tFSE-9\n' > w.tsv
    qd_rc check d.csv --against t.tsv --manual m.tsv --waivers w.tsv --format junit -o w.xml
    assert_status "$QD_RC" 0
    assert_contains "$(junit w.xml)" "M1|cabling manual|skipped|waived: FSE-9"
    # --keep: the verdicts with who decided, and the file by name and sha256
    qd_rc check d.csv --against t.tsv --manual m.tsv --keep > out
    assert_status "$QD_RC" 1
    csv="$(qd show latest --format csv)"
    assert_contains "$csv" "decided_by,decided,decision_note"
    assert_contains "$csv" 'M1,cabling,each,,manual fail,manual,,4/4,fail,"4 of 4 failed: a, b, c, d; as built",J. Smith,2026-11-17,loose lead'
    log="$(qd log latest)"
    assert_contains "$log" "--manual $PWD/m.tsv"
    assert_contains "$log" "manual m.tsv sha256 $sum"
}

t_manual_dated_before_the_run() {
    runof now 900 900 900 900
    printf 'req\tcolumn\top\tlimit\nM1\t\tmanual\t\n' > t.tsv
    results 'M1|pass|J. Smith|2020-01-02||'
    qd_rc check now --against t.tsv --manual m.tsv > out
    # warned of, not refused: the verdict stands
    assert_status "$QD_RC" 0
    assert_contains "$(cat out)" "1 dated before the run"
    assert_contains "$(qd check now --against t.tsv --manual m.tsv --format csv 2>/dev/null)" \
        "decided 2020-01-02, before the run ("
    results 'M1|pass|J. Smith|2999-01-02||'
    qd_rc check now --against t.tsv --manual m.tsv > out
    assert_not_contains "$(cat out)" "before the run"
    results 'M1|pass|J. Smith|||'
    qd_rc check now --against t.tsv --manual m.tsv > out
    assert_contains "$(cat out)" "1 result by J. Smith, 1 undated"
}

t_manual_none_unchanged() {
    # no manual rows and no --manual: the output 0.29.0 gave, byte for byte
    data
    limits t.tsv 'R1|mbps|>=|900||status=ok||' 'R2|temp|between|20|45|rack=r1|max|'
    for f in text csv junit; do
        qd_rc check d.csv --against t.tsv --format "$f" -o "a.$f"
        assert_status "$QD_RC" 1
        qd_rc check d.csv --against t.tsv --each --format "$f" -o "e.$f"
    done
    assert_eq "$(cat a.csv)" 'req,column,agg,where,observed,limit,unit,measured,verdict,note
R1,mbps,each,status=ok,880,>= 900,,2/3,fail,1 of 3 failed: b; 1 not measured
R2,temp,max,rack=r1,44,between 20 and 45,,2/2,pass,'
    assert_eq "$(cat e.csv)" 'req,row,column,observed,limit,unit,verdict
R1,a,mbps,950,>= 900,,pass
R1,b,mbps,880,>= 900,,fail
R1,c,mbps,,>= 900,,not measured
R2,a,temp,30,between 20 and 45,,pass
R2,b,temp,44,between 20 and 45,,pass'
    assert_not_contains "$(cat a.junit e.junit)" "manual"
    assert_not_contains "$(cat a.junit e.junit)" "decided"
    assert_not_contains "$(cat a.text)" "manual"
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
run_test "junit: one testcase per outcome"   t_junit_one_case_per_outcome
run_test "junit: --each, per host per check" t_junit_each_host
run_test "junit: hostile strings parse"      t_junit_hostile_strings
run_test "junit: provost reads it back"      t_junit_real_reader
run_test "baseline: a drifted host fails"      t_baseline_a_drifted_host_fails
run_test "baseline: a host it lacks is not measured" t_baseline_a_host_it_lacks_is_not_measured
run_test "baseline: where and units"           t_baseline_where_and_units
run_test "baseline: old files, bad limits"     t_baseline_old_files_and_bad_limits
run_test "baseline: waivers, severity, junit, keep" t_baseline_waivers_severity_junit_keep
run_test "baseline: a qualified baseline"      t_baseline_qualified
run_test "shape: known values"                 t_shape_known_values
run_test "shape: not measured, and why"        t_shape_not_measured
run_test "shape: a unit is refused"            t_shape_units_refused
run_test "shape: zmax is qd outliers' z"       t_shape_zmax_is_qd_outliers
run_test "shape: old files unchanged"          t_shape_old_files_unchanged
run_test "shape: junit, waivers, severity, keep" t_shape_junit_waivers_severity_keep
run_test "shape: against a baseline"           t_shape_baseline
run_test "rule: each kind, nested"             t_rule_each_kind_nested
run_test "rule: not measured, waived, unexpected" t_rule_unmeasured_waived_unexpected
run_test "rule: refused, exit 2"               t_rule_refused
run_test "rule: none, output unchanged"        t_rule_none_unchanged
run_test "rule: formats, junit, keep"          t_rule_formats_junit_keep
run_test "manual: none given is not measured" t_manual_none_is_not_measured
run_test "manual: pass and fail, where, --each" t_manual_pass_and_fail
run_test "manual: a waiver on a manual fail"   t_manual_waived
run_test "manual: refused, exit 2"             t_manual_refused
run_test "manual: junit and --keep"            t_manual_junit_keep
run_test "manual: dated before the run"        t_manual_dated_before_the_run
run_test "manual: none, output unchanged"      t_manual_none_unchanged
finish
