#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Martin J. Gallagher

# qd "do": a toolchain command run here, recorded, and what it left read
# back.  The tools are stand-ins that write what the real ones write, in
# the places the real ones write it.

set -u
source "$(dirname "${BASH_SOURCE[0]}")/test_helper.bash"

fake_mx() {
    cat > "$FAKE_BIN/mx" <<'EOF'
#!/bin/bash
# mx stand-in: `run` writes reports/<host>.csv; `export` writes overlays.
if [ "$1" = "--version" ]; then echo "mx 1.11.1"; exit 0; fi
verb="$1"; shift
reports=reports; out=-
while [ $# -gt 0 ]; do
  case "$1" in
    --reports) reports="$2"; shift 2;;
    -o|--output) out="$2"; shift 2;;
    *) shift;;
  esac
done
case "$verb" in
  run)
    mkdir -p "$reports"
    printf 'ts,host,dir,peer,pps\n1,alpha,tx,beta,1000\n' > "$reports/alpha.csv"
    printf 'ts,host,dir,peer,pps\n1,beta,tx,alpha,990\n' > "$reports/beta.csv"
    echo "mx run -- 2 hosts, REQUESTS 1990 pps";;
  export)
    body='{"!test": "mx_pps", "unit": "pps"}
{"test": "mx_pps", "target": "alpha", "value": 1000}
{"test": "mx_pps", "target": "beta", "value": 990}'
    if [ "$out" = "-" ]; then echo "$body"; else echo "$body" > "$out"; fi;;
  *) echo "mx: $verb";;
esac
EOF
    chmod +x "$FAKE_BIN/mx"
}

fake_iperf() {
    cat > "$FAKE_BIN/iperf-orchestrator" <<'EOF'
#!/bin/bash
if [ "$1" = "--version" ]; then echo "iperf-orchestrator 2.5.0"; exit 0; fi
d=results/2026-10-29_12-00-00
mkdir -p "$d"
printf 'timestamp,source,target,status,mbps\n1,a,b,OK,9400\n' > "$d/iperf_results.csv"
printf 'host,source,peak_total_pct\na,mpstat,30\n' > "$d/cpu_summary.csv"
ln -sfn 2026-10-29_12-00-00 results/latest
echo "done"
EOF
    chmod +x "$FAKE_BIN/iperf-orchestrator"
}

fake_agree() {
    cat > "$FAKE_BIN/agree" <<'EOF'
#!/bin/bash
# agree stand-in: honours --csv PATH, and records what it was given.
if [ "$1" = "--version" ]; then echo "agree.py 0.8.0"; exit 0; fi
printf '%s\n' "$@" > agree.args
while [ $# -gt 0 ]; do
  case "$1" in
    --csv) printf 'host,group_id,outcome\nn1,1,ok\nn2,2,unreachable\n' > "$2"; shift 2;;
    --) break;;
    *) shift;;
  esac
done
echo "agree -- 2 hosts, 2 groups"
exit 1
EOF
    chmod +x "$FAKE_BIN/agree"
}

t_mx_run_reads_reports_and_exports() {
    fake_mx
    PATH="$FAKE_BIN:$PATH" qd "do" -- mx run --for 60 > out 2> err
    assert_contains "$(cat out)" "mx run -- 2 hosts"
    err="$(cat err)"
    assert_contains "$err" "mx export --no-collect --json -o"
    assert_contains "$err" "reports"
    assert_contains "$err" "mx_export"
    out="$(qd show latest:reports --format csv)"
    assert_contains "$out" "1,beta,tx,alpha,990"
    out="$(qd show latest:mx_export --format csv)"
    assert_contains "$out" "mx_pps,alpha,1000"
    assert_contains "$(qd log latest)" "mx 1.11.1"
}

t_mx_export_to_stdout_is_read() {
    fake_mx
    PATH="$FAKE_BIN:$PATH" qd "do" -- mx export --no-collect --json > /dev/null 2>&1
    out="$(qd show latest --format csv)"
    assert_contains "$out" "mx_pps,beta,990"
}

t_iperf_reads_the_latest_run() {
    fake_iperf
    PATH="$FAKE_BIN:$PATH" qd "do" -- iperf-orchestrator --servers s.txt run > /dev/null 2> err
    assert_contains "$(cat err)" "iperf_results"
    out="$(qd show latest:iperf_results --format csv)"
    assert_contains "$out" "1,a,b,OK,9400"
    assert_contains "$(qd log latest)" "cpu_summary"
}

t_agree_gets_csv_added_and_its_status_passes_through() {
    fake_agree
    set +e
    PATH="$FAKE_BIN:$PATH" qd "do" -- agree --servers h.txt -- uname -r > /dev/null 2> err
    rc=$?
    set -e
    assert_status "$rc" 1
    assert_contains "$(cat err)" "added --csv"
    args="$(cat agree.args)"
    assert_contains "$args" "--csv"
    # the flag goes before the --, never into the remote command
    assert_eq "$(sed -n '$p' agree.args)" "-r"
    out="$(qd show latest --format csv)"
    assert_contains "$out" "n2,2,unreachable"
    assert_contains "$(qd log latest)" "exit      1"
}

t_stdout_table_and_explicit_import() {
    printf 'a,b\n1,2\n' > made.csv
    qd "do" --import made.csv -- printf 'host,v\nx,1\ny,2\n' > /dev/null 2>&1
    e="$(qd log latest)"
    assert_contains "$e" "made"
    assert_contains "$e" "stdout"
    out="$(qd show latest:stdout --format csv)"
    assert_contains "$out" "y,2"
}

t_plain_text_output_is_filed_for_provost_to_read() {
    qd "do" -- echo hello world > /dev/null 2>&1
    out="$(qd show latest --format csv)"
    assert_contains "$out" "hello world"
    assert_contains "$(qd log latest)" "stdout"
    # the output itself, exactly, is provost's to show
    assert_contains "$(pv source 1)" "hello world"
}

t_missing_tool_says_how_to_get_it() {
    qd_rc "do" -- reckon-not-here --x 2> err
    assert_status "$QD_RC" 127
    assert_contains "$(cat err)" "cannot run reckon-not-here"
    PATH="/usr/bin:/bin" qd_rc "do" -- mx run 2> err
    if [ "$QD_RC" -eq 127 ]; then
        assert_contains "$(cat err)" "pip install matrix-orchestrator"
    fi
}

t_qd_tool_variable_names_the_tool() {
    fake_mx
    mv "$FAKE_BIN/mx" "$FAKE_BIN/my-mx"
    QD_MX="$FAKE_BIN/my-mx" qd "do" -- mx export > /dev/null 2>&1
    out="$(qd show latest --format csv)"
    assert_contains "$out" "mx_pps,alpha,1000"
}

run_test "mx run: reports/ and mx export read back"     t_mx_run_reads_reports_and_exports
run_test "mx export to stdout is read"                  t_mx_export_to_stdout_is_read
run_test "iperf-orchestrator: results/latest read"      t_iperf_reads_the_latest_run
run_test "agree: --csv added, exit status passed on"    t_agree_gets_csv_added_and_its_status_passes_through
run_test "stdout table and --import"                    t_stdout_table_and_explicit_import
run_test "plain text output is filed for provost"       t_plain_text_output_is_filed_for_provost_to_read
run_test "a missing tool says how to get it"            t_missing_tool_says_how_to_get_it
run_test "QD_MX names the tool"                         t_qd_tool_variable_names_the_tool
finish
