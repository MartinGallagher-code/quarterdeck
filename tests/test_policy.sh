#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Martin J. Gallagher
#
# test_policy.sh -- what qd may send to a fleet: --allow (QD_ALLOW), a
# command allow-list, and --read-only (QD_READ_ONLY) (QD-015).

set -u
source "$(dirname "${BASH_SOURCE[0]}")/test_helper.bash"

seed() {
    install_fake_ssh
    for h in a b; do fake_host "$h"; done
    echo "6.1.0" > "$FAKE_ROOT/a/kernel"
    echo "6.1.0" > "$FAKE_ROOT/b/kernel"
    printf 'a\nb\n' > hosts.txt
    printf '# what may run on the system under test\nuname *\ncat kernel\n\n' > allow.txt
}

no_runs() { assert_contains "$(qd log 2>&1)" "no runs in the store"; }

# qd run under a pseudo-terminal, typing $1 at the prompt
on_tty() {
    local answer="$1"
    shift
    "$PY" - "$answer" "$PY" "$QD_DIR/qd" "$@" <<'PYEOF'
import os, pty, sys, time, select
answer = sys.argv[1].encode() + b"\n"
pid, fd = pty.fork()
if pid == 0:
    os.execv(sys.argv[2], sys.argv[2:])
out, sent = b"", False
while True:
    r, _, _ = select.select([fd], [], [], 20)
    if not r:
        break
    try:
        chunk = os.read(fd, 4096)
    except OSError:
        break
    if not chunk:
        break
    out += chunk
    if not sent and b"Type CONFIRM" in out:
        os.write(fd, answer)
        sent = True
_, status = os.waitpid(pid, 0)
sys.stdout.write(out.decode("utf-8", "replace"))
sys.exit(os.WEXITSTATUS(status) if os.WIFEXITED(status) else 1)
PYEOF
}

t_nothing_changes_without_a_policy() {
    seed
    qdf_rc run -s hosts.txt -q -- echo hi > out 2>&1
    assert_status "$QD_RC" 0
    assert_not_contains "$(qd log latest)" "policy"
}

t_an_allowed_command_runs_and_says_so() {
    seed
    qdf_rc run -s hosts.txt -q --allow allow.txt -- cat kernel > out 2>&1
    assert_status "$QD_RC" 0
    assert_contains "$(qd log latest)" "policy: allow-list allow.txt sha256:"
    # QD_ALLOW is the same as --allow; extra spaces do not matter
    QD_ALLOW=allow.txt qdf_rc run -s hosts.txt -q -- uname   -r > out 2>&1
    assert_status "$QD_RC" 0
}

t_outside_the_list_is_refused() {
    seed
    qdf_rc run -s hosts.txt -q --allow allow.txt -- echo hi > out 2>&1
    assert_status "$QD_RC" 2
    assert_contains "$(cat out)" "'echo hi' is not on the allow-list allow.txt"
    assert_contains "$(cat out)" "--confirm"
    no_runs
    assert_eq "$(wc -l < "$FAKE_SSH_LOG" | tr -d ' ')" "0"
    # a refusal files nothing, so it is logged in qd's cache
    assert_contains "$(cat "$XDG_CACHE_HOME"/quarterdeck/policy.log)" "echo hi"
    # --confirm with no terminal: nobody to ask, so refused
    qdf_rc run -s hosts.txt -q --allow allow.txt --confirm -- echo hi < /dev/null > out 2>&1
    assert_status "$QD_RC" 2
    assert_contains "$(cat out)" "nothing is attached to this terminal"
    # a pattern is the whole command: uname * does not allow a chained one
    qdf_rc run -s hosts.txt -q --allow allow.txt -- 'uname -r; reboot' > out 2>&1
    assert_status "$QD_RC" 2
    # --dry-run is held to the list too
    qdf_rc run -s hosts.txt --dry-run --allow allow.txt -- echo hi > out 2>&1
    assert_status "$QD_RC" 2
}

t_a_typed_confirmation_runs_it_and_is_recorded() {
    seed
    on_tty CONFIRM run --ssh "$FAKE_BIN/ssh" --scp "$FAKE_BIN/scp" \
        -s hosts.txt -q --allow allow.txt --confirm -- echo hi > out 2>&1
    assert_status "$?" 0
    assert_contains "$(cat out)" "Type CONFIRM to run it on 2 hosts"
    assert_contains "$(qd log latest)" "confirmed outside the allow-list by"
    assert_contains "$(qd log latest)" "echo hi"
    # anything but the word is a no
    set +e
    on_tty yes run --ssh "$FAKE_BIN/ssh" --scp "$FAKE_BIN/scp" \
        -s hosts.txt -q --allow allow.txt --confirm -- echo bye > out 2>&1
    rc=$?
    set -e
    assert_status "$rc" 2
    assert_contains "$(cat out)" "not confirmed"
    assert_not_contains "$(qd log)" "bye"
}

t_read_only_refuses_push_sudo_and_unlisted() {
    seed
    printf 'echo x\n' > s.sh
    qdf_rc run -s hosts.txt -q --read-only --allow allow.txt --push s.sh -- cat kernel > out 2>&1
    assert_status "$QD_RC" 2
    assert_contains "$(cat out)" "--push or --script is refused"
    qdf_rc run -s hosts.txt -q --read-only --allow allow.txt --script s.sh > out 2>&1
    assert_status "$QD_RC" 2
    QD_READ_ONLY=1 qdf_rc run -s hosts.txt -q --allow allow.txt --sudo -- cat kernel > out 2>&1
    assert_status "$QD_RC" 2
    assert_contains "$(cat out)" "--sudo is refused"
    # no confirmation lifts read-only
    qdf_rc run -s hosts.txt -q --read-only --allow allow.txt --confirm -- echo hi > out 2>&1
    assert_status "$QD_RC" 2
    assert_contains "$(cat out)" "read-only allows only"
    # with no list at all, read-only runs nothing but probes
    qdf_rc run -s hosts.txt -q --read-only -- cat kernel > out 2>&1
    assert_status "$QD_RC" 2
    no_runs
    # an allow-listed command runs, and the run says it was read-only
    qdf_rc run -s hosts.txt -q --read-only --allow allow.txt -- cat kernel > out 2>&1
    assert_status "$QD_RC" 0
    assert_contains "$(qd log latest)" "policy: read-only"
}

t_read_only_still_probes() {
    seed
    qdf_rc probe os -s hosts.txt -q --read-only > out 2>&1
    assert_status "$QD_RC" 0
    assert_contains "$(qd log latest)" "policy: read-only"
    qdf_rc probe os packages -s hosts.txt -q --read-only --allow allow.txt > out 2>&1
    assert_status "$QD_RC" 0
    qdf_rc probe os -s hosts.txt -q --read-only --sudo > out 2>&1
    assert_status "$QD_RC" 2
}

t_read_only_refuses_qd_do() {
    seed
    QD_READ_ONLY=1 qd_rc "do" -- mx run > out 2>&1
    assert_status "$QD_RC" 2
    assert_contains "$(cat out)" "qd do is refused"
    qd_rc "do" --read-only -- echo hi > out 2>&1
    assert_status "$QD_RC" 2
}

t_danger_still_applies_on_top() {
    seed
    printf 'rm *\n' > rm.txt
    qdf_rc run -s hosts.txt -q --allow rm.txt -- rm -rf /tmp/x > out 2>&1
    assert_status "$QD_RC" 2
    assert_contains "$(cat out)" "rm -rf"
}

t_a_bad_allow_list() {
    seed
    qdf_rc run -s hosts.txt -q --allow nosuch.txt -- cat kernel > out 2>&1
    assert_status "$QD_RC" 2
    assert_contains "$(cat out)" "no such allow-list"
}

run_test "no policy: nothing changes"               t_nothing_changes_without_a_policy
run_test "allow-list: an allowed command runs"      t_an_allowed_command_runs_and_says_so
run_test "allow-list: outside it is refused"        t_outside_the_list_is_refused
run_test "allow-list: a typed confirmation"         t_a_typed_confirmation_runs_it_and_is_recorded
run_test "read-only: push, sudo, unlisted refused"  t_read_only_refuses_push_sudo_and_unlisted
run_test "read-only: probes still run"              t_read_only_still_probes
run_test "read-only: qd do refused"                 t_read_only_refuses_qd_do
run_test "DANGER still applies on top"              t_danger_still_applies_on_top
run_test "a missing allow-list is exit 2"           t_a_bad_allow_list
finish
