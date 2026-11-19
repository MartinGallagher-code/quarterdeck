#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Martin J. Gallagher

# qd setup (QD-063): the first-run guide.  It checks this machine (qd
# doctor), makes and selects a store when none is active (qd store new,
# qd store use), finds the host list or offers to write hosts.txt, and
# runs `true` on every host, keeping nothing.  Each case is an account of
# its own (XDG_CONFIG_HOME, XDG_DATA_HOME and PROVOST_HOME in its temp
# directory, from the helper) with no QD_STORE, and the fake fleet; the
# fake ssh and scp are on PATH so qd doctor finds a launcher.  One case
# drives a terminal, with Python's pty, to answer the questions.

set -u
source "$(dirname "${BASH_SOURCE[0]}")/test_helper.bash"

CONFIG() { echo "$XDG_CONFIG_HOME/quarterdeck/config.json"; }
STORES() { echo "$XDG_DATA_HOME/quarterdeck/stores"; }

# A fresh account: no store, no host list, ssh on PATH.
fresh() {
    unset QD_STORE
    install_fake_ssh
    export PATH="$FAKE_BIN:$PATH"
    mkdir -p work
    cd work || return 1
}

# qd setup with stdin from /dev/null, OUT and RC kept
setup_quiet() {
    set +e
    OUT="$(qdf setup "$@" < /dev/null 2>&1)"
    RC=$?
    set -e
}

# The commands under WHAT TO DO NEXT, each parsed by build_parser(): one
# line for any that does not parse, nothing when all do.
next_commands_parse() {
    printf '%s\n' "$1" | "$PY" -c '
import contextlib, io, re, shlex, sys
sys.path.insert(0, sys.argv[1])
from quarterdeck import cli
parser, _ = cli.build_parser()
inside = False
for line in sys.stdin:
    if line.strip() == "WHAT TO DO NEXT":
        inside = True
        continue
    m = re.match(r"\s*\* (qd \S.*?)(\s{2,}|$)", line) if inside else None
    if not m:
        continue
    cmd = m.group(1).split(" > ")[0]
    argv = shlex.split(cmd)[1:]
    try:
        with contextlib.redirect_stderr(io.StringIO()):
            parser.parse_args(argv)
    except SystemExit:
        print("does not parse: " + cmd)
' "$QD_DIR"
}

t_fresh_and_not_a_terminal_asks_nothing_changes_nothing() {
    fresh
    setup_quiet
    assert_status "$RC" 0
    assert_contains "$OUT" "stdin is not a terminal"
    assert_not_contains "$OUT" "host>"
    assert_not_contains "$OUT" "[Y/n]"
    # every step says what it did
    assert_contains "$OUT" "1. What this machine can drive (qd doctor)"
    assert_contains "$OUT" "2. A store to keep the answers in"
    assert_contains "$OUT" "qd setup --yes would make a store named main"
    assert_contains "$OUT" "3. The host list"
    assert_contains "$OUT" "nothing written: stdin is not a terminal"
    assert_contains "$OUT" "4. Who answers"
    assert_contains "$OUT" "nothing to test: no host list"
    # nothing changed: no store made or chosen, no host list written
    assert_no_file hosts.txt
    [ ! -d "$(STORES)/main" ] || fail "a store was made with nobody asked"
    if [ -f "$(CONFIG)" ]; then
        assert_not_contains "$(cat "$(CONFIG)")" '"main"'
    fi
    # what to do instead
    assert_contains "$OUT" "qd store new main"
    assert_contains "$OUT" "qd store use main"
    assert_contains "$OUT" "qd hosts -S node01,node02 > hosts.txt"
    assert_contains "$OUT" "qd demo"
    assert_contains "$OUT" "status 0"
    assert_eq "$(next_commands_parse "$OUT")" ""
}

t_fresh_with_yes_then_again_changes_nothing() {
    fresh
    fake_host web1
    fake_host web2
    setup_quiet -S web1,web2 --yes
    assert_status "$RC" 0
    assert_contains "$OUT" "done: made the store main"
    assert_contains "$OUT" "(qd store new main; qd store use main)"
    assert_contains "$OUT" "already done: 2 hosts, named on the command line"
    assert_contains "$OUT" "2 hosts: 2 answered, 0 did not"
    assert_contains "$OUT" "status 0: this machine is ready, and every host answered"
    assert_dir_exists "$(STORES)/main"
    assert_contains "$(qd store ls)" "*  main"
    # the test run keeps nothing
    assert_eq "$(find "$(STORES)/main" -mindepth 1 | wc -l | tr -d ' ')" "0"
    cp "$(CONFIG)" config.before
    # what to try next: qd ask and qd survey where this qd has them, with
    # the hosts as they were named
    if qd help ask > /dev/null 2>&1; then
        assert_contains "$OUT" "qd ask -S web1,web2 -- uname -r"
    else
        assert_contains "$OUT" "qd run -S web1,web2 -- uname -r"
    fi
    if qd help survey > /dev/null 2>&1; then
        assert_contains "$OUT" "qd survey -S web1,web2"
    else
        assert_contains "$OUT" "qd probe facts inventory -S web1,web2"
    fi
    assert_contains "$OUT" "qd demo"
    assert_eq "$(next_commands_parse "$OUT")" ""
    # a second time: every step already done, nothing changed
    setup_quiet -S web1,web2 --yes
    assert_status "$RC" 0
    assert_contains "$OUT" "already done: the active store is main"
    assert_contains "$OUT" "already done: 2 hosts"
    assert_not_contains "$OUT" "done: made"
    cmp -s config.before "$(CONFIG)" || fail "the second run changed qd's config"
    assert_eq "$(find "$(STORES)/main" -mindepth 1 | wc -l | tr -d ' ')" "0"
    assert_no_file hosts.txt
}

t_a_store_already_is_left_as_it_is() {
    fresh
    qd store new fleet > /dev/null
    qd store use fleet > /dev/null
    printf '%s\n' web1 > hosts.txt
    cp hosts.txt hosts.before
    fake_host web1
    cp "$(CONFIG)" config.before
    setup_quiet --yes
    assert_status "$RC" 0
    assert_contains "$OUT" "already done: the active store is fleet"
    assert_contains "$OUT" "already done: 1 host, hosts.txt in this directory"
    cmp -s config.before "$(CONFIG)" || fail "the active store was changed"
    cmp -s hosts.before hosts.txt || fail "hosts.txt was changed"
    [ ! -d "$(STORES)/main" ] || fail "a second store was made"
}

t_stores_but_none_active_is_never_chosen_for_you() {
    fresh
    qd store new lab > /dev/null
    qd store new bench > /dev/null
    cp "$(CONFIG)" config.before
    # --yes makes a store when there is none to choose from; with some, the
    # choice is the user's
    setup_quiet --yes
    assert_status "$RC" 0
    assert_contains "$OUT" "registered: bench, lab"
    assert_contains "$OUT" "qd store use NAME"
    cmp -s config.before "$(CONFIG)" || fail "the active store was changed"
}

t_the_demo_active_is_replaced_only_when_asked() {
    fresh
    # a store named demo, active, as `qd store use demo` leaves it
    qd store new demo > /dev/null
    qd store use demo > /dev/null
    cp "$(CONFIG)" config.before
    setup_quiet
    assert_contains "$OUT" "the active store is the demo's"
    cmp -s config.before "$(CONFIG)" || fail "changed without asking"
    setup_quiet --yes
    assert_contains "$OUT" "made it the active store in place of the demo"
    assert_contains "$(qd store ls)" "*  main"
}

t_unreachable_hosts_are_listed_with_why_and_what_to_do() {
    fresh
    fake_host web1
    fake_host_unreachable web2
    # web3 has no fake host: its name does not resolve
    printf '%s\n' web1 web2 web3 > hosts.txt
    setup_quiet --yes
    assert_status "$RC" 1
    assert_contains "$OUT" "3 hosts: 1 answered, 2 did not"
    assert_contains "$OUT" "DID NOT ANSWER"
    assert_contains "$OUT" "web2  down, or a firewall between (ssh: connect to host web2 port 22: Connection timed out)"
    assert_contains "$OUT" "web3  the name does not resolve (ssh: Could not resolve hostname web3)"
    assert_contains "$OUT" "give its address: web3=10.0.0.5"
    assert_contains "$OUT" "status 1: step 4, 2 hosts did not answer"
    assert_contains "$OUT" "qd doctor web2"
    assert_contains "$OUT" "reachable hosts.txt -i"
    assert_eq "$(next_commands_parse "$OUT")" ""
}

t_usage_errors_and_refused_writes_exit_2() {
    fresh
    setup_quiet --store-name 'no good'
    assert_status "$RC" 2
    assert_contains "$OUT" "is not one"
    [ ! -f "$(CONFIG)" ] || assert_not_contains "$(cat "$(CONFIG)")" "no good"
    # a hosts.txt that names no host cannot be read
    : > hosts.txt
    setup_quiet
    assert_status "$RC" 2
    assert_contains "$OUT" "the host list cannot be read"
    assert_contains "$OUT" "status 2: step 3"
    # hosts.txt is created, never overwritten
    printf '%s\n' keep > hosts.txt
    "$PY" - "$QD_DIR" <<'EOF'
import contextlib, io, sys
sys.path.insert(0, sys.argv[1])
from quarterdeck import firstrun
rep = firstrun.Report()
with contextlib.redirect_stdout(io.StringIO()):
    ok = firstrun.write_hosts("web9\n", rep)
assert ok is False and rep.refused, (ok, rep.refused)
assert open("hosts.txt").read() == "keep\n"
EOF
}

t_at_a_terminal_it_asks_and_writes_hosts_txt() {
    fresh
    fake_host web1
    fake_host web2
    "$PY" - "$PY" "$QD_DIR/qd" "$FAKE_BIN" <<'EOF' > pty.out
# Drive qd setup at a terminal: answer each question as it is asked.
import os, pty, select, subprocess, sys, time
py, qd, fakebin = sys.argv[1:4]
answers = [b"y\n", b"web1 web2\n", b"\n"]
prompts = (b"[Y/n] ", b"host> ")
master, slave = pty.openpty()
p = subprocess.Popen([py, qd, "setup", "--ssh", fakebin + "/ssh",
                      "--scp", fakebin + "/scp"],
                     stdin=slave, stdout=slave, stderr=slave)
os.close(slave)
out, sent, end = b"", 0, time.time() + 120
while time.time() < end:
    r = select.select([master], [], [], 0.2)[0]
    if r:
        try:
            chunk = os.read(master, 4096)
        except OSError:
            break
        if not chunk:
            break
        out += chunk
        asked = sum(out.count(q) for q in prompts)
        while sent < asked and sent < len(answers):
            os.write(master, answers[sent])
            sent += 1
    elif p.poll() is not None:
        break
else:
    p.kill()
    out += b"\nTIMED OUT\n"
rc = p.wait()
sys.stdout.write(out.decode("utf-8", "replace"))
sys.stdout.write("\nrc=%d\n" % rc)
EOF
    out="$(cat pty.out)"
    assert_not_contains "$out" "TIMED OUT"
    assert_contains "$out" "and make it the active store? [Y/n]"
    assert_contains "$out" "done: made the store main"
    assert_contains "$out" "done: wrote hosts.txt, 2 hosts"
    assert_contains "$out" "2 hosts: 2 answered, 0 did not"
    assert_contains "$out" "rc=0"
    assert_contains "$(cat hosts.txt)" "web1 web2"
    assert_contains "$(qd store ls)" "*  main"
    # and then nothing is left to do
    setup_quiet
    assert_status "$RC" 0
    assert_contains "$OUT" "already done: the active store is main"
    assert_contains "$OUT" "already done: 2 hosts, hosts.txt in this directory"
}

t_setup_is_on_the_card_and_in_the_hints() {
    assert_contains "$(qd --help)" "qd setup [HOSTS]"
    assert_contains "$(qd --help)" "your own fleet: qd setup"
    assert_contains "$(qd)" "qd setup "
    assert_contains "$(qd hints)" "qd setup"
    assert_contains "$(qd setup --help)" "--store-name NAME"
}

run_test "fresh, not a terminal: asks nothing, changes nothing" t_fresh_and_not_a_terminal_asks_nothing_changes_nothing
run_test "fresh, --yes; then again, nothing changes"            t_fresh_with_yes_then_again_changes_nothing
run_test "a store already is left as it is"                     t_a_store_already_is_left_as_it_is
run_test "stores but none active: never chosen for you"         t_stores_but_none_active_is_never_chosen_for_you
run_test "the demo active: replaced only when asked"            t_the_demo_active_is_replaced_only_when_asked
run_test "unreachable hosts: why, and what to do"               t_unreachable_hosts_are_listed_with_why_and_what_to_do
run_test "usage errors and refused writes exit 2"               t_usage_errors_and_refused_writes_exit_2
run_test "at a terminal: asks, writes hosts.txt"                t_at_a_terminal_it_asks_and_writes_hosts_txt
run_test "on the card and in the hints"                         t_setup_is_on_the_card_and_in_the_hints
finish
