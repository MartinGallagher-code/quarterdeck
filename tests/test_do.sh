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

# iperf_orchestrator.sh run as itself keeps its results beside it, not
# here: that is where they are read from
t_iperf_s_script_keeps_its_results_beside_it() {
    mkdir -p src/iperf
    sed 's|^d=results/|cd "$(dirname "$0")"; d=results/|' > src/iperf/iperf_orchestrator.sh <<'EOF2'
#!/bin/bash
if [ "$1" = "--version" ]; then echo "iperf-orchestrator 2.5.0"; exit 0; fi
d=results/2026-10-29_12-00-00
mkdir -p "$d"
printf 'timestamp,source,target,status,mbps\n1,a,b,OK,9400\n' > "$d/iperf_results.csv"
ln -sfn 2026-10-29_12-00-00 results/latest
EOF2
    chmod +x src/iperf/iperf_orchestrator.sh
    qd "do" -- ./src/iperf/iperf_orchestrator.sh --servers s.txt run > /dev/null 2>&1
    assert_no_file results
    assert_contains "$(qd show latest:iperf_results --format csv)" "1,a,b,OK,9400"
}

# a run that fails before it writes leaves the last run's results where
# they were: they are that run's, not this one's
t_an_earlier_run_s_output_is_not_filed() {
    fake_iperf
    PATH="$FAKE_BIN:$PATH" qd "do" -- iperf-orchestrator --servers s.txt run > /dev/null 2>&1
    cat > "$FAKE_BIN/iperf-orchestrator" <<'EOF2'
#!/bin/bash
if [ "$1" = "--version" ]; then echo "iperf-orchestrator 2.5.0"; exit 0; fi
echo "ssh: connect to host s1: refused" >&2
exit 1
EOF2
    PATH="$FAKE_BIN:$PATH" qd "do" -- iperf-orchestrator --servers s.txt run > /dev/null 2> err \
        || true
    assert_contains "$(cat err)" "results/latest: not written by this run"
    assert_contains "$(qd log latest)" "exit      1"
    assert_not_contains "$(qd log latest)" "iperf_results"
    # the first run's are still the first run's
    assert_contains "$(qd show latest~1:iperf_results --format csv)" "1,a,b,OK,9400"
    # and the user's own --import is read whatever it holds
    PATH="$FAKE_BIN:$PATH" qd "do" --import results/latest -- \
        iperf-orchestrator --servers s.txt run > /dev/null 2>&1 || true
    assert_contains "$(qd log latest)" "iperf_results"
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

# what follows -- is the remote command's: its --csv is not agree's, and
# agree script takes no -- at all
t_agree_s_own_options_end_at_the_double_dash() {
    fake_agree
    printf 'zzz,1\n' > remote.csv
    PATH="$FAKE_BIN:$PATH" qd "do" -- agree --servers h.txt -- \
        why-slow --csv remote.csv > /dev/null 2> err || true
    assert_contains "$(cat err)" "added --csv"
    assert_contains "$(qd show latest --format csv)" "n2,2,unreachable"
    assert_eq "$(sed -n '$p' agree.args)" "remote.csv"
    PATH="$FAKE_BIN:$PATH" qd "do" -- agree script why-slow --servers h.txt \
        > /dev/null 2> err || true
    assert_contains "$(cat err)" "added --csv --merge-csv"
    assert_contains "$(qd show latest:agree_hosts --format csv)" "n2,2,unreachable"
}

# mx export reads reports/: after a run that wrote none, it would file
# the last run's numbers as this one's
t_mx_export_of_an_earlier_run_s_reports_is_not_run() {
    fake_mx
    PATH="$FAKE_BIN:$PATH" qd "do" -- mx run > /dev/null 2>&1
    cat > "$FAKE_BIN/mx" <<'EOF2'
#!/bin/bash
if [ "$1" = "--version" ]; then echo "mx 1.11.1"; exit 0; fi
if [ "$1" = "export" ]; then echo '{"test": "mx_pps", "target": "alpha", "value": 1000}' > "${@: -1}"; exit 0; fi
echo "mx: cannot start: no matrix" >&2; exit 1
EOF2
    PATH="$FAKE_BIN:$PATH" qd "do" -- mx run > /dev/null 2> err || true
    assert_contains "$(cat err)" "not run; it reads reports"
    assert_not_contains "$(qd log latest)" "mx_export"
}

# dcprobe scan writes host_status.tsv when no -o says otherwise
t_dcprobe_s_own_file_is_read() {
    cat > "$FAKE_BIN/dcprobe" <<'EOF2'
#!/bin/bash
if [ "$1" = "--version" ]; then echo "dcprobe 1.19.1"; exit 0; fi
printf '!test\tload1\tunit=load\nload1\ta\t0.5\nload1\tb\t9.0\n' > host_status.tsv
echo "dcprobe: 2 hosts -> host_status.tsv"
EOF2
    chmod +x "$FAKE_BIN/dcprobe"
    PATH="$FAKE_BIN:$PATH" qd "do" -- dcprobe scan --servers h.txt > /dev/null 2>&1
    assert_contains "$(qd show latest --format csv)" "load1,b,9.0"
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

# QD_MX is read by no shell: its ~ is qd's to expand.  And a command that
# says how to run the tool is run as it says, override or not
t_qd_tool_variable_is_expanded_and_only_replaces_a_bare_name() {
    fake_mx
    # a home of the case's own: nothing is written to the real one
    mkdir -p home/src
    mv "$FAKE_BIN/mx" home/src/my-mx
    # shellcheck disable=SC2088  # the ~ is qd's to expand, not this shell's
    HOME="$PWD/home" QD_MX="bash ~/src/my-mx" qd "do" -- mx export > /dev/null 2> err
    assert_contains "$(qd show latest --format csv)" "mx_pps,alpha,1000"
    cat > mx.py <<'EOF2'
import sys
print('{"test": "mx_pps", "target": "alpha", "value": 1000}' if sys.argv[1:] == ["export"] else "mx 1.11.1")
EOF2
    # shellcheck disable=SC2088
    HOME="$PWD/home" QD_MX="bash ~/nowhere/mx" qd "do" -- python3 ./mx.py export > /dev/null 2> err
    assert_contains "$(cat err)" "./mx.py export"
    assert_contains "$(qd show latest --format csv)" "mx_pps,alpha,1000"
}

run_test "QD_MX: ~ expanded, a bare name replaced"      t_qd_tool_variable_is_expanded_and_only_replaces_a_bare_name
run_test "mx run: reports/ and mx export read back"     t_mx_run_reads_reports_and_exports
run_test "mx export to stdout is read"                  t_mx_export_to_stdout_is_read
run_test "iperf-orchestrator: results/latest read"      t_iperf_reads_the_latest_run
run_test "iperf_orchestrator.sh: results beside it"   t_iperf_s_script_keeps_its_results_beside_it
run_test "an earlier run's output is not filed"         t_an_earlier_run_s_output_is_not_filed
run_test "agree: --csv added, exit status passed on"    t_agree_gets_csv_added_and_its_status_passes_through
run_test "agree's own options end at --"                t_agree_s_own_options_end_at_the_double_dash
run_test "mx export after a run that wrote nothing"     t_mx_export_of_an_earlier_run_s_reports_is_not_run
run_test "dcprobe: its own file read, unasked"          t_dcprobe_s_own_file_is_read
run_test "stdout table and --import"                    t_stdout_table_and_explicit_import
run_test "plain text output is filed for provost"       t_plain_text_output_is_filed_for_provost_to_read
run_test "a missing tool says how to get it"            t_missing_tool_says_how_to_get_it
run_test "QD_MX names the tool"                         t_qd_tool_variable_names_the_tool
finish
