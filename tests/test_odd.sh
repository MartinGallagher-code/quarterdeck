#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Martin J. Gallagher

# qd odd (QD-062): every column of a run through the outlier code `qd
# outliers` and `qd outliers --categorical` use, the hosts unlike the rest
# ranked -- numbers by robust z, words by rarity, in two lists.  The
# demo's planted slow host and odd kernel come first; a run where every
# host agrees exits 0; a blank is never a zero; --top, --peers, --format;
# every command under WHAT TO DO NEXT parses, and runs.

set -u
source "$(dirname "${BASH_SOURCE[0]}")/test_helper.bash"

# demo_runs ANSWERS...: the demo's runs that read these answers files
# (quarterdeck/demo/plan.tsv), filed into the case's store as qd demo
# files them -- its hosts, its stand-in launcher, fleet_run -- but only
# those, since the whole week is a few hundred captures.
demo_runs() {
    "$PY" - "$QD_DIR" "$QD_STORE" "$@" > /dev/null <<'EOF'
import sys
sys.path.insert(0, sys.argv[1])
from quarterdeck import cli, demo, hosts as hostmod
hs = hostmod.collect_hosts(servers=[demo.data("hosts.txt")])
for at, name, answers, command in demo.read_plan():
    if answers in sys.argv[3:]:
        args = demo.run_args(cli)
        args.store = sys.argv[2]
        cli.fleet_run(args, hs, command, name, at=at,
                      runner=demo.DemoRunner(demo.read_answers(answers), at),
                      extra={"operator": demo.OPERATOR, "operator_host": "",
                             "cwd": ""})
EOF
}

# next_ok FILE: every command under WHAT TO DO NEXT in FILE (qd's
# output) parses as qd parses it, and runs: exit 0 or 1, never 2.  At
# least MIN of them (default 1).
next_ok() {
    local file=$1 min=${2:-1} n=0 c
    "$PY" - "$QD_DIR" "$file" > cmds.txt <<'EOF' || fail "a WHAT TO DO NEXT command does not parse"
import re, shlex, sys
sys.path.insert(0, sys.argv[1])
from quarterdeck import cli
text = open(sys.argv[2]).read()
assert "WHAT TO DO NEXT" in text, text
tail = text.split("WHAT TO DO NEXT", 1)[1]
for line in tail.splitlines():
    m = re.match(r"\s+\* (qd .*?)(\s{2,}.*)?$", line)
    if not m:
        continue
    argv = shlex.split(m.group(1))
    parser, _ = cli.build_parser()
    try:
        parser.parse_args(argv[1:])
    except SystemExit:
        sys.stderr.write("does not parse: %s\n" % m.group(1))
        sys.exit(1)
    print(m.group(1))
EOF
    while IFS= read -r c; do
        n=$((n + 1))
        set +e
        eval "$c" > /dev/null 2>&1
        local rc=$?
        set -e
        [ "$rc" -le 1 ] || fail "exit $rc: $c"
    done < cmds.txt
    [ "$n" -ge "$min" ] || fail "only $n commands under WHAT TO DO NEXT"
}

# rows LIST: the --format tsv rows of one list, numbers or values
rows() { awk -F'\t' -v l="$1" 'NR > 1 && $1 == l' odd.tsv; }

# -- the demo ----------------------------------------------------------------

t_demo_slow_host_and_odd_kernel_first() {
    demo_runs kernel.txt iperf.txt
    # the latest: the throughput run, and its slow host
    qd_rc odd > out
    assert_status "$QD_RC" 1
    assert_contains "$(cat out)" "1 host stands out, in 1 of 1 column checked"
    assert_contains "$(cat out)" "robust z beyond 3.5"
    qd_rc odd --format tsv > odd.tsv
    assert_status "$QD_RC" 1
    assert_eq "$(rows numbers | head -n 1 | cut -f3,4,5,6)" \
        "$(printf 'demo-r2n03\tmbps\t4882\t9402')"
    # robust z, not a percentage
    assert_eq "$(rows numbers | head -n 1 | cut -f7)" "-225.8"
    next_ok out 2
    assert_contains "$(cat cmds.txt)" "qd outliers latest mbps"
    # the kernel run: the odd kernel, first among the values; the host
    # that did not answer is not measured, and not odd
    qd_rc odd demo-kernel > out
    assert_status "$QD_RC" 1
    qd odd demo-kernel --format tsv > odd.tsv || true
    assert_eq "$(rows values | head -n 1 | cut -f2,3,4,5,6,7,8)" \
        "$(printf 'r2\tdemo-r2n05\tA\t6.8.0-31-generic\t6.8.0-48-generic\t92%%\t11 of 12')"
    assert_eq "$(rows values | wc -l | tr -d ' ')" "1"
    assert_not_contains "$(cut -f3 odd.tsv)" "demo-r1n09"
    assert_contains "$(cat out)" "did not answer in this run, so not measured: demo-r1n09 (unreachable)"
    # the host list's attributes are not what the hosts said
    assert_not_contains "$(cat out)" "storage"
    next_ok out 2
    assert_contains "$(cat cmds.txt)" "qd outliers demo-kernel A --categorical"
}

# -- agreement, and blanks -------------------------------------------------------

t_all_alike_exits_0() {
    printf 'host,rack,mbps,kernel\n' > alike.csv
    for h in a b c d e f; do printf '%s,r1,9400,6.8.0-48\n' "$h" >> alike.csv; done
    qd import alike.csv --name alike > /dev/null
    qd_rc odd > out
    assert_status "$QD_RC" 0
    assert_contains "$(cat out)" "0 hosts stand out"
    assert_contains "$(cat out)" "none: no host stands out in any column"
    assert_contains "$(cat out)" "every host agrees in mbps, kernel"
    next_ok out 1
    assert_contains "$(cat cmds.txt)" "qd stats latest"
    # a spread with nobody far out: checked, and 0
    printf 'host,mbps,kernel\na,9400,6.8\nb,9410,6.8\nc,9390,6.8\nd,9405,6.8\ne,9398,6.8\n' > near.csv
    qd import near.csv --name near > /dev/null
    qd_rc odd > out
    assert_status "$QD_RC" 0
    assert_contains "$(cat out)" "checked: 1 column of numbers (mbps)"
}

t_blank_is_not_zero() {
    # e measured nothing: as a zero it would be the farthest of all
    printf 'host,mbps,kernel,note\na,9400,6.8,\nb,9410,6.8,x\nc,9390,6.8,\nd,9405,6.8,\ne,,,\nf,9398,6.8,\n' > b.csv
    qd import b.csv --name b > /dev/null
    qd_rc odd > out
    assert_status "$QD_RC" 0
    assert_contains "$(cat out)" "checked: 1 column of numbers (mbps)"
    assert_contains "$(cat out)" "mostly blank: note"
    assert_contains "$(cat out)" "every host agrees in kernel"
    assert_not_contains "$(cat out)" "  e "
    # and a blank is no word of its own: e is not odd in kernel either,
    # when another host is
    printf 'host,mbps,kernel\na,9400,k6.8\nb,9410,k6.8\nc,9390,k6.8\nd,9405,k6.1\ne,,\nf,9398,k6.8\n' > c.csv
    qd import c.csv --name c > /dev/null
    qd_rc odd --format tsv > odd.tsv
    assert_status "$QD_RC" 1
    assert_eq "$(rows values | cut -f3,4,5,6,8)" "$(printf 'd\tkernel\tk6.1\tk6.8\t4 of 5')"
    assert_eq "$(rows numbers | wc -l | tr -d ' ')" "0"
}

# -- options ---------------------------------------------------------------------

t_top_limits_each_list() {
    # cores: four hosts of eight differ from an exact majority (MAD 0)
    printf 'host,cores,bios\n' > t.csv
    for h in a b c d; do printf '%s,64,v2.1\n' "$h" >> t.csv; done
    printf 'e,64,v2.1\nf,32,v1.9\ng,16,v1.9\nh,8,v1.8\n' >> t.csv
    qd import t.csv --name t > /dev/null
    qd_rc odd --format tsv > odd.tsv
    assert_status "$QD_RC" 1
    assert_eq "$(rows numbers | wc -l | tr -d ' ')" "3"
    assert_eq "$(rows values | wc -l | tr -d ' ')" "3"
    # the rarer word first: 1.8 is one host's, 1.9 two hosts'
    assert_eq "$(rows values | head -n 1 | cut -f3,5)" "$(printf 'h\tv1.8')"
    qd_rc odd --top 1 --format tsv > odd.tsv
    assert_status "$QD_RC" 1
    assert_eq "$(rows numbers | wc -l | tr -d ' ')" "1"
    assert_eq "$(rows values | wc -l | tr -d ' ')" "1"
    qd_rc odd --top 2 > out
    assert_contains "$(cat out)" "... and 1 more (--top N shows more)"
    qd_rc odd --format json > odd.json
    assert_status "$QD_RC" 1
    "$PY" -c 'import json, sys; d = json.load(open(sys.argv[1]))
assert len(d) == 6 and d[0]["list"] == "numbers", d' odd.json
}

t_peers_compares_within_groups() {
    # storage hosts are slower by design; one compute host is slow, and
    # one compute host runs another kernel
    {
        printf 'host,sku,mbps,kernel\n'
        printf '%s,compute,%s,k6.8\n' a 9400 b 9410 c 9390 d 9405 e 4700 f 9398
        printf '%s,storage,%s,k6.8\n' g 4700 h 4710 i 4690 j 4705
        printf 'k,compute,9401,k6.1\n'
    } > p.csv
    qd import p.csv --name p > /dev/null
    qd peers define sku --by sku > /dev/null
    qd_rc odd --format tsv > odd.tsv
    # against the whole run, the five slow ones are all far out
    assert_eq "$(rows numbers | wc -l | tr -d ' ')" "5"
    qd_rc odd --peers sku --format tsv > odd.tsv
    assert_status "$QD_RC" 1
    assert_eq "$(rows numbers | cut -f2,3,4)" "$(printf 'compute\te\tmbps')"
    assert_eq "$(rows values | cut -f2,3,4,5,6)" "$(printf 'compute\tk\tkernel\tk6.1\tk6.8')"
    # what the groups are made by is not compared within them
    assert_not_contains "$(cut -f4 odd.tsv)" "sku"
    qd_rc odd --peers sku > out
    assert_contains "$(cat out)" "the median of each host's peer group sku (by sku)"
    next_ok out 2
    assert_contains "$(cat cmds.txt)" "qd outliers latest mbps --peers sku"
    assert_contains "$(cat cmds.txt)" "qd outliers latest kernel --categorical --peers sku"
    # the plain command finds what qd odd found
    qd_rc outliers latest mbps --peers sku --format tsv > o.tsv
    assert_contains "$(cat o.tsv)" "$(printf 'compute\te\t4700')"
    qd_rc odd --peers nosuch
    assert_status "$QD_RC" 2
}

# -- a run, filed --------------------------------------------------------------------

t_a_run_on_both_paths() {
    install_fake_ssh
    local h
    for h in n1 n2 n3 n4 n5 n6; do
        fake_host "$h"
        printf 'mbps: 9400\nkernel: 6.8.0-48\n' > "$FAKE_ROOT/$h/m"
    done
    printf 'mbps: 9410\nkernel: 6.8.0-48\n' > "$FAKE_ROOT/n2/m"
    printf 'mbps: 9390\nkernel: 6.8.0-48\n' > "$FAKE_ROOT/n3/m"
    printf 'mbps: 3100\nkernel: 6.8.0-48\n' > "$FAKE_ROOT/n4/m"
    printf 'mbps: 9405\nkernel: 6.8.0-31\n' > "$FAKE_ROOT/n5/m"
    fake_host_unreachable n7
    qdf_rc run -S n1,n2,n3,n4,n5,n6,n7 --name m -- cat m > /dev/null 2>&1
    assert_status "$QD_RC" 1
    qd_rc odd m > out
    assert_status "$QD_RC" 1
    assert_contains "$(cat out)" "2 hosts stand out, in 2 of 2 columns checked"
    # qd's own columns -- rc, duration_s, the capture -- are not read
    assert_not_contains "$(cat out)" "duration_s"
    assert_contains "$(cat out)" "did not answer in this run, so not measured: n7 (unreachable)"
    qd odd m --format tsv > odd.tsv || true
    assert_eq "$(rows numbers | cut -f3,4,5)" "$(printf 'n4\tmbps\t3100')"
    assert_eq "$(rows values | cut -f3,4,5,6)" "$(printf 'n5\tkernel\t6.8.0-31\t6.8.0-48')"
    next_ok out 3
    # read-only: nothing filed
    assert_eq "$(qd log | tail -n +2 | grep -c .)" "1"
}

# -- usage, and the help -----------------------------------------------------------------

t_usage_errors_exit_2() {
    printf 'host,v\na,1\nb,1\n' > u.csv
    qd import u.csv --name u > /dev/null
    local bad
    for bad in "--top 0" "--top x" "--bogus" "latest latest" "nosuchrun"; do
        # shellcheck disable=SC2086  # the words are the arguments
        qd_rc odd $bad 2> err
        assert_status "$QD_RC" 2
    done
}

t_on_the_card_in_hints_and_help() {
    assert_contains "$(qd --help)" "qd odd [RUN]"
    assert_contains "$(qd hints)" "qd odd latest"
    out="$(qd help odd)"
    assert_contains "$out" "--top N"
    assert_contains "$out" "--peers NAME"
    # shellcheck disable=SC2016  # the backquotes are the heading's own text
    assert_contains "$(cat "$QD_DIR/README.md")" '### Who is odd: `qd odd`'
}

run_test "the demo: the slow host and the odd kernel, ranked first" t_demo_slow_host_and_odd_kernel_first
run_test "every host alike: exit 0"                               t_all_alike_exits_0
run_test "a blank is not measured, never a zero"                  t_blank_is_not_zero
run_test "--top limits each list; --format"                       t_top_limits_each_list
run_test "--peers: each host against its own group"               t_peers_compares_within_groups
run_test "a filed run: qd's own columns are not read"             t_a_run_on_both_paths
run_test "usage errors exit 2"                                    t_usage_errors_exit_2
run_test "on the card, in qd hints, and qd help odd"              t_on_the_card_in_hints_and_help
finish
