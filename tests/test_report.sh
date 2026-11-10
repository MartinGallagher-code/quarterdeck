#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Martin J. Gallagher
#
# test_report.sh -- qd report: an evidence package for a run or a campaign
# (QD-021).  Every file is in SHA256SUMS and checks; the tables are qd
# export's and the figures qd stats's, outliers', check's and compare's;
# the HTML runs nothing and escapes everything a dataset says; a section
# whose feature is missing is left out, and said to be.

set -u
source "$(dirname "${BASH_SOURCE[0]}")/test_helper.bash"

# five hosts: one slow, one down, and one whose answer is hostile HTML
seed() {
    install_fake_ssh
    for h in n1 n2 n3 n4 n5; do fake_host "$h"; done
    printf 'mbps: 950\nrtt: 200\nnote: <script>alert(1)</script>\n' > "$FAKE_ROOT/n1/m"
    printf 'mbps: 940\nrtt: 210\nnote: <script>alert(1)</script>\n' > "$FAKE_ROOT/n2/m"
    printf 'mbps: 945\nrtt: 205\nnote: ok\n' > "$FAKE_ROOT/n3/m"
    printf 'mbps: 100\nrtt: 900\nnote: slow\n' > "$FAKE_ROOT/n4/m"
    fake_host_unreachable n5
    printf 'n1 rack=r1\nn2 rack=r1\nn3 rack=r2\nn4 rack=r2\nn5 rack=r2\n' > hosts.txt
    qdf_rc run -q -s hosts.txt --name bw -- cat m > /dev/null 2>&1
    RUN="$(qd log | tail -1 | cut -d' ' -f1)"
}

# a thresholds file from rows of fields, '|' between them
limits() {
    local f="$1"
    shift
    printf 'req\tcolumn\top\tlimit\tlimit2\twhere\tagg\tunit\n' > "$f"
    for row in "$@"; do printf '%s\n' "$row" | tr '|' '\t' >> "$f"; done
}

# a field of manifest.json: a Python expression over m
mf() {
    "$PY" -c '
import json, sys
m = json.load(open(sys.argv[1]))
v = eval(sys.argv[2])
print(json.dumps(v) if isinstance(v, (dict, list, bool)) or v is None else v)
' "$1/manifest.json" "$2"
}

# sha256sum -c, or shasum's, or Python's where neither is installed
sums_check() {
    if command -v sha256sum > /dev/null 2>&1; then
        (cd "$1" && sha256sum -c --quiet SHA256SUMS)
    elif command -v shasum > /dev/null 2>&1; then
        (cd "$1" && shasum -a 256 -c --quiet SHA256SUMS)
    else
        (cd "$1" && "$PY" -c '
import hashlib, sys
bad = 0
for ln in open("SHA256SUMS"):
    h, p = ln.rstrip("\n").split("  ", 1)
    if hashlib.sha256(open(p, "rb").read()).hexdigest() != h:
        print(p + ": FAILED"); bad = 1
sys.exit(bad)')
    fi
}

has_verify() { pv verify --help > /dev/null 2>&1; }

t_a_run_package_and_its_sums() {
    seed
    qd_rc report "$RUN" --out rep > out
    # a host that did not answer is a finding, as it was for qd run
    assert_status "$QD_RC" 1
    assert_contains "$(cat out)" "1 of 5 hosts did not answer"
    for f in manifest.json SHA256SUMS summary.md summary.html \
            "data/$RUN/data.csv" "data/$RUN/data.json" \
            "data/$RUN/data.stats.csv" "data/$RUN/hosts.csv" \
            "data/$RUN/hosts.json" "data/$RUN/outliers.csv" \
            "data/$RUN/captures/c0001.txt"; do
        assert_file_exists "rep/$f"
    done
    # four answers kept, exactly as provost keeps them
    assert_eq "$(find "rep/data/$RUN/captures" -type f | wc -l | tr -d ' ')" "4"
    cmp "rep/data/$RUN/captures/c0001.txt" "$QD_STORE/captures/c0001/output.txt"
    sums_check rep
    # SHA256SUMS lists every file but itself, and nothing else
    listed="$(cut -c67- rep/SHA256SUMS | sort)"
    present="$(cd rep && find . -type f ! -name SHA256SUMS | sed 's|^\./||' | sort)"
    assert_eq "$listed" "$present"
    # and a changed byte is caught
    printf 'x' >> "rep/data/$RUN/data.csv"
    if sums_check rep > /dev/null 2>&1; then fail "a changed file passed"; fi
    # the run record, its captures and their hashes are in the manifest
    assert_eq "$(mf rep 'm["kind"]')" "qd-report"
    assert_eq "$(mf rep 'm["runs"][0]["record"]["run"]')" "$RUN"
    assert_eq "$(mf rep 'm["runs"][0]["record"]["unreachable"]')" "1"
    assert_eq "$(mf rep 'len(m["runs"][0]["captures"])')" "4"
    assert_eq "$(mf rep 'm["versions"]["qd"]')" \
        "$("$PY" -c 'import sys; sys.path.insert(0, sys.argv[1]); import quarterdeck; print(quarterdeck.VERSION)' "$QD_DIR")"
    assert_contains "$(mf rep 'm["versions"]["provost"]')" "provost"
    assert_eq "$(mf rep 'm["store"]["head"]')" "$(git -C "$QD_STORE" rev-parse HEAD)"
    # each capture names the provost command that shows it, by row number,
    # which every provost takes
    src="$(mf rep 'm["runs"][0]["captures"][0]["source"]')"
    assert_contains "$src" "provost source "
    assert_contains "$(pv source "${src##* }" 2>&1)" "c0001"
    # the captures' own #% keys: the hosts' racks, qd's run and host left out
    assert_eq "$(mf rep 'sorted(m["manifest_keys"]["run"])')" '["rack"]'
}

t_the_figures_are_the_commands() {
    seed
    qd_rc report "$RUN" --out rep > /dev/null
    d="rep/data/$RUN"
    assert_eq "$(cat "$d/data.csv")" "$(qd export "$RUN" --format csv)"
    assert_eq "$(cat "$d/data.json")" "$(qd export "$RUN" --format json)"
    assert_eq "$(cat "$d/hosts.csv")" "$(qd export "$RUN:hosts" --format csv)"
    assert_eq "$(cat "$d/data.stats.csv")" "$(qd stats "$RUN" --format csv)"
    assert_eq "$(cat "$d/hosts.stats.csv")" "$(qd stats "$RUN:hosts" --format csv)"
    # outliers.csv holds qd outliers' rows, after table, column and per
    want="$(qd outliers "$RUN" mbps --format csv | tail -n +2)"
    got="$(grep '^data,mbps,host,' "$d/outliers.csv" | cut -d, -f4-)"
    assert_eq "$got" "$want"
    # the summary shows qd stats' median and qd outliers' z, and says how
    med="$("$PY" -c '
import csv, sys
for r in csv.DictReader(open(sys.argv[1])):
    if r["column"] == "mbps": print(r["median"])' "$d/data.stats.csv")"
    assert_eq "$med" "942.5"
    assert_contains "$(cat rep/summary.md)" "| mbps | num | 4 | 1 | 4 | 733.8 | 942.5 | 100 | 949.2 | 950 |"
    assert_contains "$(cat rep/summary.md)" "qd stats $RUN --store"
    assert_contains "$(cat rep/summary.md)" "qd outliers $RUN mbps --store"
    assert_contains "$(cat rep/summary.html)" "<td class=\"n\">942.5</td>"
    # every command a section names is in the manifest
    assert_contains "$(mf rep '[c["command"] for c in m["commands"]]')" "qd show $RUN:hosts --where 'status!=ok'"
}

t_the_html_runs_nothing() {
    seed
    # what a summary shows of a dataset (the commonest note) and of a
    # thresholds file (its notes), each hostile
    printf 'req\tcolumn\top\tlimit\tnote\n%s\n%s\n' \
        'R1	mbps	>=	1	x"><img src=x onerror=alert(2)>' \
        'R2	rtt	>=	1	a|b & `c` *d* [e](f)' > t.tsv
    qd_rc report "$RUN" --out rep --check t.tsv > /dev/null
    html="$(cat rep/summary.html)"
    # no script element and no element a dataset could have brought in
    # every element is one the report itself writes, and none has an
    # event handler or a source: read as a browser would, not by grep
    "$PY" - rep/summary.html <<'PYEOF'
import sys
from html.parser import HTMLParser
ALLOWED = {"html", "head", "meta", "title", "style", "body", "h1", "h2",
           "h3", "section", "p", "table", "thead", "tbody", "tr", "th",
           "td", "ul", "li", "a", "pre", "code", "br"}
class P(HTMLParser):
    def handle_starttag(self, tag, attrs):
        assert tag in ALLOWED, "element <%s> in the HTML" % tag
        for k, v in attrs:
            assert not k.startswith("on"), "handler %s on <%s>" % (k, tag)
            assert k not in ("src", "srcdoc", "formaction"), k
            if k == "href":
                assert "://" not in v and not v.startswith(("/", "javascript:")), v
P().feed(open(sys.argv[1], encoding="utf-8").read())
PYEOF
    assert_contains "$html" "&lt;script&gt;alert(1)&lt;/script&gt;"
    assert_contains "$html" "x&quot;&gt;&lt;img src=x onerror=alert(2)&gt;"
    assert_contains "$html" "Content-Security-Policy\" content=\"default-src 'none'"
    # nothing fetched: the only links are to the package's own files
    if grep -Eo '(href|src)="[^"]*"' rep/summary.html | grep -v 'href="data/\|href="inputs/\|href="verify\|href="manifest.json"\|href="summary.md"\|href="summary.html"\|href="SHA256SUMS"'; then
        fail "a link out of the package"
    fi
    # the Markdown shows the same text and lets none of it be markup
    md="$(cat rep/summary.md)"
    assert_contains "$md" '\<script\>alert(1)\</script\>'
    assert_contains "$md" 'a\|b \& \`c\` \*d\* \[e\](f)'
    if grep -Eq '(^|[^\\])<' rep/summary.md; then fail "a raw < in the Markdown"; fi
}

t_checks_baseline_verify_and_operator() {
    seed
    # the seeded run is the baseline; since then the fleet slowed down
    base="$RUN"
    for h in n1 n2 n3; do
        sed -i.bak 's/^mbps: 9/mbps: 7/' "$FAKE_ROOT/$h/m"
    done
    QD_OPERATOR="Jane Doe" qdf_rc run -q -s hosts.txt --name bw -- cat m > /dev/null 2>&1
    run="$(qd log | tail -1 | cut -d' ' -f1)"
    limits t.tsv 'R1|mbps|>=|900||status=ok||' 'R2|rtt|<=|1000|||max|'
    qd_rc report "$run" --out rep --check t.tsv --baseline "$base" > out
    assert_status "$QD_RC" 1
    # the checks are qd check's, against the copy kept in the package
    cmp t.tsv rep/inputs/t.tsv
    assert_eq "$(cat "rep/data/$run/check.csv")" \
        "$(qd check "$run" --against t.tsv --format csv 2>/dev/null || true)"
    assert_contains "$(cat rep/summary.md)" "## Checks"
    assert_contains "$(cat rep/summary.md)" "0 pass, 1 fail, 1 not measured"
    assert_eq "$(mf rep 'm["runs"][-1]["check"]["fail"]')" "1"
    # the baseline: medians side by side, mbps moved past 5%, rtt did not
    assert_contains "$(cat rep/summary.md)" "## Against the baseline"
    assert_contains "$(cat rep/data/baseline.csv)" "mbps,942.5,742.5,run -21.2%"
    assert_contains "$(cat rep/data/baseline.csv)" "rtt,207.5,207.5,"
    assert_eq "$(mf rep 'm["baseline"]["moved"]')" "1"
    assert_eq "$(mf rep 'm["baseline"]["run"]')" "$base"
    assert_contains "$(cat out)" "against $base: 1 column moved more than 5%"
    assert_eq "$(cat rep/data/baseline-hosts.csv)" \
        "$(qd compare "$base" "$run" --format csv 2>/dev/null || true)"
    # who ran it (QD-016), in the record and the summary
    assert_eq "$(mf rep 'm["runs"][0]["record"]["operator"]')" "Jane Doe"
    assert_eq "$(mf rep 'm["runs"][0]["record"]["ssh_user"]')" "$(whoami)"
    assert_contains "$(cat rep/summary.md)" "**by**: Jane Doe@"
    # provost verify (PV-026), where this provost has it
    if has_verify; then
        assert_file_exists rep/verify.txt
        assert_eq "$(mf rep 'm["verify"]["exit"]')" "0"
        assert_contains "$(cat rep/verify.txt)" "no findings"
        assert_contains "$(cat rep/summary.md)" "## Store integrity"
        assert_eq "$(mf rep 'm["verify"]["head"]')" "$(git -C "$QD_STORE" rev-parse HEAD)"
    else
        assert_contains "$(mf rep 'm["left_out"]')" "store integrity"
    fi
    sums_check rep
}

t_what_does_not_exist_is_left_out() {
    seed
    # a provost that has no verify: the rest of provost as it is
    real="$PROVOST_CMD"
    cat > "$FAKE_BIN/old-provost" <<EOF
#!/bin/sh
[ "\$1" = verify ] && { echo "provost: unknown command: verify" >&2; exit 2; }
exec $real "\$@"
EOF
    chmod +x "$FAKE_BIN/old-provost"
    QD_PROVOST="$FAKE_BIN/old-provost" qd_rc report "$RUN" --out rep > out
    md="$(cat rep/summary.md)"
    assert_not_contains "$md" "## Checks"
    assert_not_contains "$md" "## Against the baseline"
    assert_not_contains "$md" "## Store integrity"
    assert_no_file rep/verify.txt
    assert_contains "$md" "## Not in this report"
    assert_contains "$md" "no --check FILE given"
    assert_contains "$md" "no --baseline RUN given"
    assert_contains "$md" "has no verify"
    assert_eq "$(mf rep '"checks" in m or "baseline" in m or "verify" in m')" "false"
    assert_eq "$(mf rep 'sorted(x["section"] for x in m["left_out"])')" \
        '["against a baseline", "checks", "store integrity"]'
    assert_contains "$(cat out)" "LEFT OUT"
    sums_check rep
}

t_kept_verdicts_without_check() {
    seed
    limits t.tsv 'R1|mbps|>=|900||status=ok||'
    qd_rc check "$RUN" --against t.tsv --keep > /dev/null
    qd_rc report "$RUN" --out rep > /dev/null
    md="$(cat rep/summary.md)"
    assert_contains "$md" "## Checks"
    assert_contains "$md" "qd check --keep filed for this run"
    assert_contains "$(mf rep 'm["runs"][0]["check"]["from"]')" "kept: "
    assert_contains "$(cat "rep/data/$RUN/check.csv")" "R1,mbps,each,status=ok,100,>= 900"
}

t_an_import_has_its_tables() {
    printf 'host,v\na,1\nb,2\nc,40\n' > one.csv
    printf 'k\tw\nx\t<b>bold</b>\n' > two.tsv
    mkdir in && cp one.csv two.tsv in/
    qd import in --name both > /dev/null
    qd_rc report latest --out rep > out
    assert_status "$QD_RC" 0
    run="$(qd log | tail -1 | cut -d' ' -f1)"
    assert_file_exists "rep/data/$run/one.csv"
    assert_file_exists "rep/data/$run/two.json"
    assert_eq "$(cat "rep/data/$run/two.csv")" "$(qd export "$run:two" --format csv)"
    md="$(cat rep/summary.md)"
    assert_not_contains "$md" "## Hosts"
    assert_contains "$md" "Table one: 3 rows"
    assert_contains "$md" "qd stats $run:two --store"
    assert_contains "$(cat rep/summary.html)" "&lt;b&gt;bold&lt;/b&gt;"
    sums_check rep
}

t_refusals_write_nothing() {
    seed
    mkdir full && touch full/x
    qd_rc report "$RUN" --out full > out 2>&1
    assert_status "$QD_RC" 2
    assert_contains "$(cat out)" "is not empty"
    assert_eq "$(ls full)" "x"
    qd_rc report "$RUN" --out "$QD_STORE/rep" > out 2>&1
    assert_status "$QD_RC" 2
    assert_contains "$(cat out)" "inside the store"
    qd_rc report "$RUN:hosts" --out r1 > out 2>&1
    assert_status "$QD_RC" 2
    assert_contains "$(cat out)" "every table of a run"
    qd_rc report ds:bw --out r1 > out 2>&1
    assert_status "$QD_RC" 2
    assert_contains "$(cat out)" "not a run"
    qd_rc report hosts.txt --out r1 > out 2>&1
    assert_status "$QD_RC" 2
    assert_contains "$(cat out)" "qd import"
    qd_rc report campaign:nope --out r1 > out 2>&1
    assert_status "$QD_RC" 2
    assert_contains "$(cat out)" "no campaign or design"
    qd_rc report "$RUN" --baseline "$RUN" --out r1 > out 2>&1
    assert_status "$QD_RC" 2
    assert_contains "$(cat out)" "is the run being reported on"
    limits bad.tsv 'R1|mbps|~|1||||'
    qd_rc report "$RUN" --check bad.tsv --out r1 > out 2>&1
    assert_status "$QD_RC" 2
    assert_contains "$(cat out)" "unknown op"
    assert_no_file r1
    # nothing half-made is left beside them
    assert_eq "$(find . -maxdepth 1 -name '.qd-report.*' | wc -l | tr -d ' ')" "0"
    # an empty directory is a new one; a zip already there is refused
    mkdir empty
    qd_rc report "$RUN" --out empty > /dev/null
    assert_file_exists empty/SHA256SUMS
    touch z.zip
    qd_rc report "$RUN" --out z --zip > out 2>&1
    assert_status "$QD_RC" 2
    assert_contains "$(cat out)" "z.zip is there already"
    assert_no_file z
}

have_muster() {
    command -v muster > /dev/null 2>&1 || "$PY" -c 'import binnacle.muster' 2>/dev/null
}

t_a_campaign_covers_its_parts() {
    have_muster || { echo "  (no muster here: pip install binnacle)"; return 0; }
    install_fake_ssh
    for h in a b c d; do fake_host "$h"; done
    printf 'mbps: 950\n' > "$FAKE_ROOT/a/m"
    printf 'mbps: 940\n' > "$FAKE_ROOT/b/m"
    printf 'mbps: 700\n' > "$FAKE_ROOT/c/m"
    fake_host_unreachable d
    printf 'a rack=r1\nb rack=r1\nc rack=r2\nd rack=r2\nx rack=r3\n' > hosts.txt
    fake_host x
    printf 'mbps: 930\n' > "$FAKE_ROOT/x/m"
    qd campaign new burn -s hosts.txt --by rack -- cat m > /dev/null
    qdf_rc campaign run burn --parts 2 > /dev/null
    r1="$(qd log | grep rack_r1 | cut -d' ' -f1)"
    r2="$(qd log | grep rack_r2 | cut -d' ' -f1)"
    limits t.tsv 'R1|mbps|>=|900||||'
    qd_rc report campaign:burn --out rep --check t.tsv --zip > out
    assert_status "$QD_RC" 1
    assert_contains "$(cat out)" "2 run, 1 not yet"
    for r in "$r1" "$r2"; do
        assert_file_exists "rep/data/$r/data.csv"
        assert_eq "$(cat "rep/data/$r/data.stats.csv")" "$(qd stats "$r" --format csv)"
        assert_eq "$(cat "rep/data/$r/check.csv")" \
            "$(qd check "$r" --against t.tsv --format csv 2>/dev/null || true)"
    done
    md="$(cat rep/summary.md)"
    assert_contains "$md" "## Campaign burn"
    assert_contains "$md" "| R1 | pass (940) | fail (700) |"
    assert_contains "$md" "| mbps | 945 | 700 |"
    assert_contains "$md" "## Part rack-r1: run $r1"
    assert_contains "$md" "## Part rack-r2: run $r2"
    assert_contains "$md" "4 hosts asked: 3 ok, 1 did not answer"
    assert_contains "$md" "1 part of 3 parts not run yet: rack-r3"
    assert_eq "$(mf rep 'm["campaign"]["not_run"]')" '["rack-r3"]'
    assert_eq "$(mf rep 'len(m["runs"])')" "2"
    sums_check rep
    # the zip holds the same files under the directory's name
    "$PY" - <<'PYEOF'
import hashlib, sys, zipfile
z = zipfile.ZipFile("rep.zip")
sums = dict((p, h) for h, p in (ln.rstrip("\n").split("  ", 1)
                                for ln in open("rep/SHA256SUMS")))
names = set(n[len("rep/"):] for n in z.namelist())
assert names == set(sums) | {"SHA256SUMS"}, sorted(names ^ set(sums))
for p, h in sums.items():
    assert hashlib.sha256(z.read("rep/" + p)).hexdigest() == h, p
PYEOF
}

run_test "a run's package, and its sums"         t_a_run_package_and_its_sums
run_test "the figures are the commands'"         t_the_figures_are_the_commands
run_test "the HTML runs nothing"                 t_the_html_runs_nothing
run_test "checks, baseline, verify, operator"    t_checks_baseline_verify_and_operator
run_test "what does not exist is left out"       t_what_does_not_exist_is_left_out
run_test "kept verdicts without --check"         t_kept_verdicts_without_check
run_test "an import, table by table"             t_an_import_has_its_tables
run_test "refusals write nothing"                t_refusals_write_nothing
run_test "a campaign covers its parts"           t_a_campaign_covers_its_parts
finish
