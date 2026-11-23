#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Martin J. Gallagher

# qd again (QD-061): a run once more, as it ran -- its command, its hosts
# (its host file read again, or the hosts it ran on when the file is gone),
# --via, --sudo, --timeout and --name -- then `qd diff RUN NEW`.  Exit 0
# when nothing changed and every host answered, 1 when either did not
# hold, 2 when the run cannot be run again exactly.

set -u
source "$(dirname "${BASH_SOURCE[0]}")/test_helper.bash"
# seed's runs are filed once and copied into each case that starts from them
use_fixtures

seed() {
    install_fake_ssh
    for h in node01 node02 node03; do
        fake_host "$h"
        echo "6.1.0-18" > "$FAKE_ROOT/$h/kernel"
    done
    printf 'node01 rack=r1\nnode02 rack=r1\nnode03 rack=r2\n' > hosts.txt
    qdf run -q -s hosts.txt -- cat kernel > /dev/null
}

runs() { qd show ds:qd.runs --cols run --format csv | tail -n +2 | wc -l | tr -d ' '; }

# qd again with the fake transports
again() { qdf_rc again "$@"; }

# Every command under WHAT TO DO NEXT in FILE parses as qd would parse it.
next_steps_parse() {
    "$PY" - "$QD_DIR" "$1" <<'PYEOF'
import shlex, sys
sys.path.insert(0, sys.argv[1])
from quarterdeck import cli
text = open(sys.argv[2]).read().split("WHAT TO DO NEXT", 1)[1]
parser, _ = cli.build_parser()
n = 0
for line in text.splitlines():
    line = line.strip()
    if not line.startswith("* qd "):
        continue
    cmd = line[2:].split("  ")[0]
    try:
        parser.parse_args(shlex.split(cmd)[1:])
    except SystemExit:
        print("does not parse: " + cmd)
        sys.exit(1)
    n += 1
print("ok %d" % n)
PYEOF
}

# qd again under a pseudo-terminal, typing $1 at the prompt
on_tty() {
    local answer="$1"
    shift
    "$PY" - "$answer" "$PY" "$QD_DIR/qd" "$@" <<'PYEOF'
import os, pty, sys, select
answer = sys.argv[1].encode() + b"\n"
pid, fd = pty.fork()
if pid == 0:
    os.execv(sys.argv[2], sys.argv[2:])
out, sent = b"", False
while True:
    r, _, _ = select.select([fd], [], [], 60)
    if not r:
        break
    try:
        chunk = os.read(fd, 4096)
    except OSError:
        break
    if not chunk:
        break
    out += chunk
    if not sent and b"[y/N]" in out:
        os.write(fd, answer)
        sent = True
_, status = os.waitpid(pid, 0)
sys.stdout.write(out.decode("utf-8", "replace"))
sys.exit(os.WEXITSTATUS(status) if os.WIFEXITED(status) else 1)
PYEOF
}

# a sudo on the fake hosts' PATH that runs the command, as sudo -n does
fake_sudo() {
    # shellcheck disable=SC2016  # expanded when the stand-in sudo runs
    printf '#!/bin/sh\n[ "$1" = -n ] && shift\necho "$*" >> "$FAKE_ROOT/sudo.log"\nexec "$@"\n' \
        > "$FAKE_BIN/sudo"
    chmod +x "$FAKE_BIN/sudo"
    export PATH="$FAKE_BIN:$PATH"
}

t_nothing_changed_exits_zero() {
    fixture seed seed
    first="$(qd show ds:qd.runs --cols run --format csv | tail -1)"
    : > "$FAKE_SSH_LOG"
    again > out
    assert_status "$QD_RC" 0
    out="$(cat out)"
    # what it will run, before it runs it
    assert_contains "$out" "qd again -- $first: cat kernel"
    assert_contains "$out" "hosts    3 hosts, from $TEST_TMPDIR/hosts.txt"
    assert_contains "$out" "as       via ssh, no sudo, timeout 60s"
    assert_contains "$out" "runs     qd run -s $TEST_TMPDIR/hosts.txt --timeout 60 -- 'cat kernel'"
    # then the run, and the diff against the run it repeated
    assert_contains "$out" "qd run -- cat kernel: 3 hosts, 3 ok"
    assert_contains "$out" "qd diff -- A $first:data"
    assert_contains "$out" "no differences"
    assert_contains "$out" "same     every host answered, and nothing changed"
    assert_contains "$out" "WHAT TO DO NEXT"
    assert_eq "$(next_steps_parse out)" "ok 4"
    # one run more, on the same hosts, with the same name and timeout
    assert_eq "$(runs)" "2"
    assert_eq "$(grep -c '^ssh node' "$FAKE_SSH_LOG")" "3"
    assert_eq "$(qd show ds:qd.runs --cols name,command,timeout_s,pushed,host_list --format csv | tail -n +2 | sort -u)" \
        "cat,cat kernel,60,0,$TEST_TMPDIR/hosts.txt"
    # the plain run it printed makes the same dataset
    second="$(qd show ds:qd.runs --cols run --format csv | tail -1)"
    assert_eq "$(qd show latest --cols host,rack,A --format csv)" \
        "$(qd show "$first" --cols host,rack,A --format csv)"
    # qd again of a name, and of an id's unique part
    again cat > /dev/null
    assert_status "$QD_RC" 0
    again "${second:0:20}" > out
    assert_status "$QD_RC" 0
    assert_contains "$(cat out)" "A $second:data"
}

t_a_changed_answer_exits_one_and_names_the_host() {
    fixture seed seed
    echo "6.1.0-20" > "$FAKE_ROOT/node02/kernel"
    again > out
    assert_status "$QD_RC" 1
    out="$(cat out)"
    assert_contains "$out" "CHANGED"
    assert_contains "$out" "node02  A 6.1.0-18 -> 6.1.0-20"
    assert_not_contains "$out" "node01  A"
    assert_contains "$out" "FOUND    the diff: "
    assert_not_contains "$out" "FOUND    the run"
    assert_eq "$(next_steps_parse out)" "ok 4"
}

t_a_host_now_unreachable_exits_one() {
    fixture seed seed
    fake_host_unreachable node03
    again > out
    assert_status "$QD_RC" 1
    out="$(cat out)"
    assert_contains "$out" "3 hosts, 2 ok, 1 unreachable"
    assert_contains "$out" "node03  status ok -> unreachable"
    assert_contains "$out" "FOUND    the run: 1 host did not answer (node03)"
    assert_contains "$out" "FOUND    the diff: "
    assert_contains "$out" "--where status!=ok"
    assert_eq "$(next_steps_parse out)" "ok 6"
}

t_the_host_file_is_read_again_or_its_hosts_kept() {
    fixture seed seed
    # a host added to the list since: in the new run, and new in the diff
    fake_host node04
    echo "6.1.0-18" > "$FAKE_ROOT/node04/kernel"
    echo "node04 rack=r3" >> hosts.txt
    again > out
    assert_status "$QD_RC" 1
    assert_contains "$(cat out)" "hosts    4 hosts, from"
    assert_contains "$(cat out)" "ONLY IN B (new)"
    # the list gone: the hosts the run ran on, with their attributes
    rm hosts.txt
    : > "$FAKE_SSH_LOG"
    again > out
    assert_status "$QD_RC" 0
    assert_contains "$(cat out)" "hosts    4 hosts, the ones "
    assert_contains "$(cat out)" "($TEST_TMPDIR/hosts.txt is gone)"
    assert_eq "$(grep -c '^ssh node' "$FAKE_SSH_LOG")" "4"
    assert_contains "$(qd show latest --cols host,rack --format csv)" "node04,r3"
    assert_eq "$(qd show latest --cols host_list --format csv 2>/dev/null | tail -n +2)" ""
    # with no list to read, the next again still has its hosts
    again > out
    assert_status "$QD_RC" 0
    # -S names: a list short and plain enough to print whole
    qdf run -q -S node01,node02 -- cat kernel > /dev/null
    again > out
    assert_status "$QD_RC" 0
    assert_contains "$(cat out)" "runs     qd run -S node01,node02 --timeout 60 -- 'cat kernel'"
    assert_eq "$(next_steps_parse out)" "ok 4"
}

t_via_timeout_and_name_are_kept() {
    fixture seed seed
    install_fake_launchers
    qd_rc run --via pdsh -s hosts.txt --timeout 7 --name kern -q -- cat kernel > /dev/null
    assert_status "$QD_RC" 0
    : > "$FAKE_SSH_LOG"
    qd_rc again > out
    assert_status "$QD_RC" 0
    assert_contains "$(cat out)" "as       via pdsh, no sudo, timeout 7s"
    assert_contains "$(cat out)" "runs     qd run -s $TEST_TMPDIR/hosts.txt --via pdsh --timeout 7 --name kern -- 'cat kernel'"
    assert_eq "$(grep -c '^pdsh ' "$FAKE_SSH_LOG")" "1"
    assert_eq "$(grep -c '^ssh node' "$FAKE_SSH_LOG")" "0"
    assert_eq "$(qd show ds:qd.runs --cols name,via,timeout_s --format csv | tail -n 2 | sort -u)" \
        "kern,pdsh,7"
    assert_eq "$(next_steps_parse out)" "ok 4"
}

t_a_local_run_stays_local() {
    install_fake_ssh
    qd_rc run --via local -q -- echo hi > /dev/null 2>&1
    assert_status "$QD_RC" 0
    qd_rc again > out 2> err
    assert_status "$QD_RC" 0
    assert_contains "$(cat out)" "via local"
    assert_eq "$(qd show ds:qd.runs --cols via --format csv | tail -n +2 | tr '\n' ' ')" \
        "local local "
    assert_eq "$(qd show latest --cols addr,A --format csv | tail -n +2)" "127.0.0.1,hi"
    assert_eq "$(cat "$FAKE_SSH_LOG")" ""
}

t_a_sudo_run_is_rerun_under_sudo() {
    fixture seed seed
    fake_sudo
    qdf_rc run -q -s hosts.txt --sudo -- cat kernel > /dev/null
    assert_status "$QD_RC" 0
    : > "$FAKE_ROOT/sudo.log"
    : > "$FAKE_SSH_LOG"
    # nothing at the terminal: it says what it runs, and runs it
    again < /dev/null > out 2> err
    assert_status "$QD_RC" 0
    assert_contains "$(cat out)" "as       via ssh, under sudo, timeout 60s"
    assert_contains "$(cat out)" "--sudo --timeout 60"
    assert_not_contains "$(cat err)" "[y/N]"
    assert_eq "$(grep -c 'sudo -n' "$FAKE_SSH_LOG")" "3"
    assert_eq "$(grep -c 'cat kernel' "$FAKE_ROOT/sudo.log")" "3"
    assert_eq "$(qd show ds:qd.runs --cols sudo --format csv | tail -n +2 | tr '\n' ' ')" \
        "no yes yes "
    # at a terminal it asks; anything but y runs nothing
    set +e
    on_tty n again --ssh "$FAKE_BIN/ssh" --scp "$FAKE_BIN/scp" > out 2>&1
    rc=$?
    set -e
    assert_status "$rc" 2
    assert_contains "$(cat out)" "run this as root (sudo) on 3 hosts? [y/N]"
    assert_contains "$(cat out)" "not confirmed: nothing was run"
    assert_eq "$(runs)" "3"
    set +e
    on_tty y again --ssh "$FAKE_BIN/ssh" --scp "$FAKE_BIN/scp" > out 2>&1
    rc=$?
    set -e
    assert_status "$rc" 0
    assert_eq "$(runs)" "4"
    # --yes does not ask
    again --yes > out 2>&1
    assert_status "$QD_RC" 0
    assert_not_contains "$(cat out)" "[y/N]"
}

t_dry_run_runs_and_files_nothing() {
    fixture seed seed
    : > "$FAKE_SSH_LOG"
    again --dry-run > out
    assert_status "$QD_RC" 0
    assert_contains "$(cat out)" "runs     qd run -s"
    assert_contains "$(cat out)" "node03 'cat kernel'"
    assert_eq "$(runs)" "1"
    assert_eq "$(grep -c '^ssh node' "$FAKE_SSH_LOG")" "0"
}

t_what_cannot_be_rerun_is_refused() {
    install_fake_ssh
    fake_host a
    qd_rc again 2> err
    assert_status "$QD_RC" 2
    assert_contains "$(cat err)" "no runs in the store"
    # qd do: a tool run here
    qd "do" -- echo hi > /dev/null
    qd_rc again 2> err
    assert_status "$QD_RC" 2
    assert_contains "$(cat err)" "is a qd do run, which ran a tool here: run it again with \`qd do -- echo hi\`"
    # qd import: nothing ran
    printf 'host,v\na,1\n' > x.csv
    qd import x.csv > /dev/null
    qd_rc again 2> err
    assert_status "$QD_RC" 2
    assert_contains "$(cat err)" "is a qd import: nothing ran"
    # a dataset, a table, a file
    qd_rc again ds:x.csv.x 2> err
    assert_status "$QD_RC" 2
    assert_contains "$(cat err)" "is a dataset, not a run"
    qd_rc again latest:data 2> err
    assert_status "$QD_RC" 2
    assert_contains "$(cat err)" "one of a run's tables"
    qd_rc again x.csv 2> err
    assert_status "$QD_RC" 2
    assert_contains "$(cat err)" "a file, not a run"
    # pushed files, which the store does not keep
    printf 'echo hi\n' > s.sh
    qdf_rc run -q -S a --script s.sh > /dev/null
    qd_rc again 2> err
    assert_status "$QD_RC" 2
    assert_contains "$(cat err)" "pushed files (--push, --script)"
    # a probe: qd probe asks it again
    qdf_rc probe os -S a -q > /dev/null 2>&1
    qd_rc again 2> err
    assert_status "$QD_RC" 2
    assert_contains "$(cat err)" "is a probe: qd probe os asks it again"
    # a run filed before 0.40.0 kept no timeout: played by qd run with
    # the record's new fields left out
    "$PY" - "$QD_DIR" --ssh "$FAKE_BIN/ssh" -S a -q -- echo old > /dev/null <<'PYEOF'
import sys
sys.path.insert(0, sys.argv[1])
from quarterdeck import cli
real = cli.fleet_run
def older(*a, **kw):
    kw["extra"] = None
    return real(*a, **kw)
cli.fleet_run = older
sys.exit(cli.main(["run"] + sys.argv[2:]))
PYEOF
    n="$(runs)"
    qd_rc again 2> err
    assert_status "$QD_RC" 2
    assert_contains "$(cat err)" "record does not keep its --timeout (it was filed before qd 0.40.0"
    # and nothing was run or filed
    assert_eq "$(runs)" "$n"
}

t_a_design_point_is_refused() {
    stand_in_doe
    install_fake_ssh
    fake_host a
    cat > bench.json <<'EOF'
{"metadata": {"name": "Stream test"},
 "factors": [{"name": "streams", "levels": ["1", "4"], "type": "continuous"}],
 "responses": [{"name": "mbps", "optimize": "maximize"}],
 "settings": {"operation": "full_factorial", "block_count": 1}}
EOF
    qdf_rc doe run bench.json -S a -q -- 'echo "mbps: {streams}"' > /dev/null
    assert_status "$QD_RC" 0
    qd_rc again 2> err
    assert_status "$QD_RC" 2
    assert_contains "$(cat err)" "is a design point of stream-test: qd doe run stream-test"
}

# A campaign's part needs binnacle's muster to make; the refusal reads
# only the record, so it is checked on one too where muster is missing.
t_a_campaign_part_is_refused() {
    "$PY" - "$QD_DIR" <<'PYEOF'
import sys
sys.path.insert(0, sys.argv[1])
from quarterdeck import again, store, common
class St(object):
    def resolve(self, r):
        e = store.Run.__new__(store.Run)
        e.id = "20261118-000000-burn-rack-r1"
        e.store = self
        e.meta = {"kind": "run", "group": "burn", "part": "rack-r1",
                  "command": "cat v", "timeout_s": "60", "pushed": "0"}
        return e
class Cli(object):
    def ref_store(self, args, ref):
        return St(), ref
    shown_id = staticmethod(store.shown_id)
class Args(object):
    ref = "latest"
try:
    again.the_run(Cli(), Args())
except common.QdError as exc:
    assert exc.code == 2, exc.code
    assert "is part rack-r1 of campaign burn: qd campaign retry burn " \
        "rack-r1 runs a part again" in str(exc), str(exc)
    print("refused")
else:
    print("not refused")
    sys.exit(1)
PYEOF
}

run_test "nothing changed: exit 0"                       t_nothing_changed_exits_zero
run_test "a changed answer: exit 1, the host named"      t_a_changed_answer_exits_one_and_names_the_host
run_test "a host now unreachable: exit 1"                t_a_host_now_unreachable_exits_one
run_test "the host file is read again, or its hosts kept" t_the_host_file_is_read_again_or_its_hosts_kept
run_test "--via, --timeout and --name are kept"          t_via_timeout_and_name_are_kept
run_test "a local run stays local"                       t_a_local_run_stays_local
run_test "a --sudo run is rerun under sudo, asked first" t_a_sudo_run_is_rerun_under_sudo
run_test "--dry-run runs and files nothing"              t_dry_run_runs_and_files_nothing
run_test "what cannot be rerun is refused, exit 2"       t_what_cannot_be_rerun_is_refused
run_test "a design point is refused"                     t_a_design_point_is_refused
run_test "a campaign's part is refused"                  t_a_campaign_part_is_refused
finish
