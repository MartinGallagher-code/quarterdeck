#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Martin J. Gallagher

# Reading what the toolchain writes: the viewer's results format and its
# NDJSON, wide tables, src\dst grids, report directories, iperf run
# directories, agree --json, CSV with a BOM -- and writing them back out.

set -u
source "$(dirname "${BASH_SOURCE[0]}")/test_helper.bash"

mx_export() {
    printf '%s\n' \
        '# mx 1.7.0 export -- 2 host(s), last 60s' \
        '!test	mx_pps	unit=pps higher=good decimals=0 short=PPS label="Requests sent"' \
        '!test	mx_loss	unit=% higher=bad decimals=2 label="Round-trip loss"' \
        'mx_pps	wr01r01u01	80000	run=demo-01' \
        'mx_loss	wr01r01u01	0.05	run=demo-01' \
        'mx_pps	wr01r01u02	79000	run=demo-01' \
        'mx_loss	wr01r01u02	1.5	run=demo-01	peer=wr01r01u01' \
        'iperf_state	wr01r01u03	PASS' > mx.tsv
}

t_results_format_with_meta() {
    mx_export
    out="$(qd show mx.tsv --format csv)"
    assert_contains "$out" "test,target,value,run,peer"
    assert_contains "$out" "mx_loss,wr01r01u02,1.5,demo-01,wr01r01u01"
    out="$(qd stats mx.tsv)"
    assert_contains "$out" "mx 1.7.0 export"
    out="$(qd stats mx.tsv value --where test=mx_loss)"
    assert_contains "$out" "(%)"
}

t_results_round_trip_through_the_store() {
    mx_export
    qd import mx.tsv --name mx > /dev/null
    # filed by provost, and read back as the same results, display
    # metadata and the tool's own header included
    assert_contains "$(pv ls)" "mx"
    out="$(qd show latest --format csv)"
    assert_contains "$out" "test,target,value,run,peer"
    assert_contains "$out" "mx_loss,wr01r01u02,1.5,demo-01,wr01r01u01"
    body="$(qd export latest --format results)"
    assert_contains "$body" '!test	mx_pps	unit=pps	higher=good	decimals=0	short=PPS	label="Requests sent"'
    assert_contains "$body" "mx_loss	wr01r01u02	1.5	run=demo-01	peer=wr01r01u01"
    assert_contains "$(qd log latest)" "mx 1.7.0 export"
    assert_contains "$(qd stats latest value --where test=mx_loss)" "(%)"
}

t_results_without_meta_lines_are_detected() {
    printf 'temp_c DH1/A/R01/u05 61.2 run=n1\nburnin DH1/A/R01/u05 PASS\n' > r.txt
    out="$(qd show r.txt --format csv)"
    assert_contains "$out" "test,target,value,run"
    assert_contains "$out" "burnin,DH1/A/R01/u05,PASS,"
}

t_ndjson_samples_and_documents() {
    printf '%s\n' '# a comment line' \
        '{"!test": "rtt_p50", "unit": "us", "higher": "bad"}' \
        '{"test": "rtt_p50", "target": "wr12r06u15", "value": 184.2, "meta": {"peer": "wr12r06u16"}}' \
        > r.ndjson
    out="$(qd show r.ndjson --format csv)"
    assert_contains "$out" "rtt_p50,wr12r06u15,184.2,wr12r06u16"
    printf '{"tests": {"t": {"unit": "C"}}, "samples": [{"test": "t", "target": "h1", "value": 3}]}' > doc.json
    out="$(qd show doc.json --format csv)"
    assert_contains "$out" "t,h1,3"
    printf '[{"host": "a", "v": 1}, {"host": "b", "v": 2, "x": {"y": true}}]' > list.json
    out="$(qd show list.json --format csv)"
    assert_contains "$out" "host,v,x.y"
    assert_contains "$out" "b,2,true"
}

t_agree_json_becomes_two_tables() {
    cat > agree.json <<'EOF'
{"groups": [{"id": 1, "size": 2, "outcome": "ok", "digest": "abc", "baseline": true, "hosts": ["n1", "n2"], "sample": "x"}],
 "hosts": [{"host": "n1", "group": 1, "outcome": "ok", "exit_code": 0, "duration_s": 0.1},
           {"host": "n2", "group": 1, "outcome": "ok", "exit_code": 0, "duration_s": 0.2}],
 "meta": {"command": "uname -r"}}
EOF
    out="$(qd import agree.json)"
    assert_contains "$out" "groups"
    assert_contains "$out" "hosts"
    out="$(qd show latest:hosts --format csv)"
    assert_contains "$out" "n2,1,ok,0,0.2"
    out="$(qd show latest:groups --format csv)"
    assert_contains "$out" "n1 n2"
}

t_wide_table_with_commented_header_and_units() {
    printf '%s\n' '# A monitoring script' \
        "# Timestamp	host	rtt (us)	loss %" \
        "2026-09-16T12:00:00	wr01r01u01	123.8	0.072" \
        "2026-09-16T12:00:10	wr01r01u01	130.1	" > live.tsv
    out="$(qd show live.tsv --format csv)"
    assert_contains "$out" "Timestamp,host,rtt (us),loss %"
    out="$(qd stats live.tsv "rtt (us)")"
    assert_contains "$out" "measured  2"
    out="$(qd stats live.tsv rtt_us)"
    assert_contains "$out" "rtt (us)"
    out="$(qd stats live.tsv loss)"
    assert_contains "$out" "blank 1"
}

t_grid_becomes_long_and_blank_cells_stay_out() {
    printf '%s\n' '# mx matrix v1 -- rows send, columns receive' \
        'src\dst,a,b,c' 'a,,100,200' 'b,150,,' 'c,90,80,' > grid.csv
    out="$(qd show grid.csv --format csv)"
    assert_contains "$out" "src,dst,value"
    assert_contains "$out" "a,c,200"
    assert_not_contains "$out" "b,c,"
    out="$(qd pivot grid.csv --rows src --cols dst --values value)"
    assert_contains "$out" "src"
}

# netmesh --grid: six grids of one header, six measures -- side by side,
# never stacked into one column of rtt and loss and mtu
t_a_directory_of_grids_is_one_row_per_pair() {
    mkdir grids
    printf 'src\\dst,a,b\na,,100\nb,150,\n' > grids/rtt_p50_grid.csv
    printf 'src\\dst,a,b\na,,0.000\nb,1.500,\n' > grids/loss_grid.csv
    printf 'src\\dst,a,b\na,,9000\nb,,\n' > grids/mtu_grid.csv
    out="$(qd show grids --format csv)"
    assert_contains "$out" "src,dst,loss,mtu,rtt_p50"
    assert_contains "$out" "a,b,0.000,9000,100"
    # b->a has no mtu: blank, not zero
    assert_contains "$out" "b,a,1.500,,150"
    assert_contains "$(qd stats grids rtt_p50)" "median 125"
}

t_reports_directory_stacks_by_header() {
    mkdir reports
    printf 'ts,host,dir,peer,pps\n1,alpha,tx,beta,100\n2,alpha,tx,beta,110\n' > reports/alpha.csv
    printf 'ts,host,dir,peer,pps\n1,beta,tx,alpha,90\n' > reports/beta.csv
    printf 'something,else\n1,2\n' > reports/other.csv
    out="$(qd import reports)"
    assert_contains "$out" "reports_alpha"
    assert_contains "$out" "3 rows"
    out="$(qd show latest --format csv)"
    assert_contains "$out" "2,alpha,tx,beta,110"
    assert_contains "$out" "1,beta,tx,alpha,90"
    assert_contains "$(qd log latest)" "2 files stacked"
}

t_folder_without_host_column_gets_source_file() {
    mkdir d
    printf 'a,b\n1,2\n' > d/one.csv
    printf 'a,b\n3,4\n' > d/two.csv
    out="$(qd show d --format csv)"
    assert_contains "$out" "a,b,source_file"
    assert_contains "$out" "3,4,two.csv"
}

t_iperf_run_directory_and_latest() {
    mkdir -p results/2026-05-05_14-22-01
    printf 'parallel\n' > results/2026-05-05_14-22-01/.run_mode
    printf 'timestamp,source,target,status,mbps\n1,a,b,OK,9400\n1,b,a,OK,9100\n' \
        > results/2026-05-05_14-22-01/iperf_results.csv
    printf 'host,source,peak_total_pct\na,mpstat,30\nb,mpstat,\n' \
        > results/2026-05-05_14-22-01/cpu_summary.csv
    ln -s 2026-05-05_14-22-01 results/latest
    out="$(qd import results)"
    assert_contains "$out" "iperf_results"
    assert_contains "$out" "cpu_summary"
    assert_contains "$(qd log latest)" "mode parallel"
    out="$(qd stats latest:cpu_summary peak_total_pct)"
    assert_contains "$out" "blank 1"
}

t_bom_crlf_and_repeated_headers() {
    printf '\xef\xbb\xbfhost,v\r\na,1\r\nhost,v\r\nb,2\r\n' > bom.csv
    out="$(qd show bom.csv --format csv)"
    assert_eq "$out" "$(printf 'host,v\na,1\nb,2')"
}

t_export_formats_and_overlay() {
    printf 'host,status,load1,stdout,rack\na,ok,0.5,x,r1\nb,unreachable,,,r1\nc,ok,1.5,y,r2\n' > d.csv
    out="$(qd export d.csv --format json)"
    assert_contains "$out" '"load1": 0.5'
    assert_contains "$out" '"load1": null'
    out="$(qd export d.csv --format ndjson)"
    assert_contains "$out" '{"host": "a", "load1": 0.5'
    out="$(qd export d.csv --format md)"
    assert_contains "$out" "| host | status | load1 |"
    out="$(qd export d.csv --format overlay --run r7)"
    assert_contains "$out" '!test	qd_status'
    assert_contains "$out" "qd_status	b	FAIL	run=r7"
    assert_contains "$out" "qd_load1	c	1.5	run=r7"
    # free text and layout attributes are not overlays; a blank is no sample
    assert_not_contains "$out" "qd_stdout"
    assert_not_contains "$out" "qd_rack"
    assert_not_contains "$out" "qd_load1	b"
    qd export d.csv -o out.tsv
    assert_contains "$(cat out.tsv)" "host	status"
    # a sample is a number: sizes in bytes, times in seconds, unit said
    printf 'host,mem,lat,cpu\na,512M,900ms,37%%\nb,2G,1.2s,40%%\n' > u.csv
    out="$(qd export u.csv --format overlay)"
    assert_contains "$out" "qd_mem	a	536870912"
    assert_contains "$out" "qd_mem	b	2147483648"
    assert_contains "$out" "qd_lat	a	0.9"
    assert_contains "$out" "qd_cpu	b	40"
    assert_contains "$out" "unit=B"
    assert_not_contains "$out" "512M"
}

# a quote in a cell is the cell's: kept through provost on either of
# its paths (2.1.0's TSV reader drops quotes; its CSV reader does not)
t_a_quote_in_a_cell_is_kept() {
    printf 'host,os\na,"PRETTY_NAME=""Ubuntu 24.04"""\nb,plain\n' > q.csv
    qd import q.csv > /dev/null
    assert_contains "$(qd show latest --format json)" '"os": "PRETTY_NAME=\"Ubuntu 24.04\""'
}

t_as_overrides_detection() {
    printf 'x y 3\n' > f.txt
    out="$(qd show f.txt --format csv)"
    assert_contains "$out" "test,target,value"
    out="$(qd show f.txt --as csv --format csv)"
    assert_contains "$out" "A,B,C"
}

# a data column called n is data: provost names its own record number _n
# beside it, and qd must not drop the one for the other
t_a_data_column_called_n_is_kept() {
    printf 'host,n,mbps\na,4,940\nb,7,610\n' > n.csv
    qd import n.csv > /dev/null
    out="$(qd show latest --format csv)"
    assert_contains "$out" "host,n,mbps"
    assert_contains "$out" "b,7,610"
    install_fake_ssh
    for h in x y; do fake_host "$h"; printf 'dev,n\nsda,4\n' > "$FAKE_ROOT/$h/f"; done
    printf 'x\ny\n' > hosts.txt
    qdf run -s hosts.txt -q -- cat f > /dev/null
    assert_contains "$(qd show latest --cols host,dev,n --format csv)" "y,sda,4"
}

# a log whose first line opens with [ is a log; JSON NaN is not measured
t_brackets_and_nan() {
    printf '[INFO] started\n[WARN] slow disk\n' > log.txt
    assert_contains "$(qd show log.txt --format csv)" "[WARN]"
    printf '[{"host":"a","mbps":NaN},{"host":"b","mbps":Infinity}]\n' > nan.json
    out="$(qd show nan.json --format csv)"
    assert_contains "$out" "a,"
    assert_contains "$out" "b,inf"
    assert_not_contains "$out" "nan"
}

# an unbalanced quote in a TSV is a character, not the start of a cell
# that swallows every line after it
t_an_unbalanced_quote_in_tsv() {
    printf 'disk\tnote\tgb\nsda\t"5 inch\t100\nsdb\tok\t200\nsdc\tok\t300\n' > q.tsv
    out="$(qd show q.tsv --format csv)"
    assert_eq "$(printf '%s\n' "$out" | tail -n +2 | wc -l | tr -d ' ')" "3"
    assert_contains "$out" "sdc,ok,300"
}

# a header whose first cell is blank (pandas' index column) is a header
t_a_blank_first_header_cell() {
    printf ',host,mbps\n0,a,940\n1,b,610\n' > pd.csv
    assert_contains "$(qd show pd.csv --cols host,mbps --format csv)" "b,610"
    assert_contains "$(qd stats pd.csv mbps)" "max 940"
}

run_test "a blank first header cell"                 t_a_blank_first_header_cell
run_test "an unbalanced quote in a TSV"             t_an_unbalanced_quote_in_tsv
run_test "[INFO] logs, and JSON NaN"                t_brackets_and_nan
run_test "a data column called n is kept"            t_a_data_column_called_n_is_kept
run_test "results format, !test lines, meta"            t_results_format_with_meta
run_test "results round-trip through the store"         t_results_round_trip_through_the_store
run_test "results without !test lines are detected"     t_results_without_meta_lines_are_detected
run_test "NDJSON samples, JSON documents and lists"     t_ndjson_samples_and_documents
run_test "agree --json: groups and hosts"               t_agree_json_becomes_two_tables
run_test "wide table, commented header, units"          t_wide_table_with_commented_header_and_units
run_test "src\\dst grid to long, blanks left out"        t_grid_becomes_long_and_blank_cells_stay_out
run_test "a directory of grids: a row per pair"         t_a_directory_of_grids_is_one_row_per_pair
run_test "a reports/ directory stacks by header"        t_reports_directory_stacks_by_header
run_test "no host column: source_file is added"         t_folder_without_host_column_gets_source_file
run_test "iperf results/latest run directory"           t_iperf_run_directory_and_latest
run_test "BOM, CRLF and a repeated header"              t_bom_crlf_and_repeated_headers
run_test "a quote in a cell is kept"                   t_a_quote_in_a_cell_is_kept
run_test "export: json, ndjson, md, overlay"            t_export_formats_and_overlay
run_test "--as overrides detection"                     t_as_overrides_detection
finish
