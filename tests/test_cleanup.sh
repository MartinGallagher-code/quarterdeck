#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Martin J. Gallagher

# The one rm -rf qd sends to a host, as an invariant: qd deletes only a
# directory it made, `qd.<run id>` holding a .qd-owned with that id.  Each
# case makes a run's directory the real way (a push through the fake ssh),
# then breaks the path or the mark the way a bug could, calls cleanup, and
# checks it refused, said so, and left everything -- the canaries -- where
# it was.  A stand-in rm on PATH turns any delete outside the case's temp
# dir into a logged refusal, so even a broken guard (the mutation case)
# cannot reach this machine's / or ~.

set -u
source "$(dirname "${BASH_SOURCE[0]}")/test_helper.bash"

# A driver for fleet.Runner on one fake host.  argv: CASE [PKGDIR]; prints
# what cleanup returned, so the case can assert on it.
write_driver() {
    cat > "$TEST_TMPDIR/drive.py" <<'EOF'
import os, sys
sys.path.insert(0, sys.argv[2])
from quarterdeck import fleet
from quarterdeck.hosts import Host

case = sys.argv[1]
sudo = os.environ.get("CASE_SUDO") == "1"
r = fleet.Runner(ssh=os.environ["FAKE_BIN"] + "/ssh",
                 scp=os.environ["FAKE_BIN"] + "/scp", remote_dir="rd",
                 sudo=sudo)
h = Host("h", "h")
root = os.path.join(os.environ["FAKE_ROOT"], "h")
open("payload.txt", "w").write("x\n")
rc, err = r.push(h, ["payload.txt"])
assert rc == 0, err
mine = os.path.join(root, r.work_dir)
mark = os.path.join(mine, fleet.SENTINEL)
assert open(mark).read() == r.run_id + "\n"
open(os.path.join(root, "rd", "canary"), "w").write("keep\n")
open(os.path.join(mine, "inside"), "w").write("x\n")

if case == "empty":
    r.work_dir = ""
elif case in ("root", "tilde", "dot", "dotdot-name"):
    r.work_dir = {"root": "/", "tilde": "~", "dot": ".",
                  "dotdot-name": ".."}[case]
elif case == "remote-dir":
    # a refactor that lost the qd.<id> part
    r.work_dir = "rd"
elif case == "dotdot":
    r.work_dir = "rd/x/../" + os.path.basename(r.work_dir)
    os.makedirs(os.path.join(root, "rd", "x"))
elif case == "other-run":
    # a qd.* that is another run's, with its own mark
    other = os.path.join(root, "rd", "qd.0123456789ab")
    os.makedirs(other)
    open(os.path.join(other, fleet.SENTINEL), "w").write("0123456789ab\n")
    r.work_dir = "rd/qd.0123456789ab"
elif case == "symlink":
    # the run's directory swapped for a link to one that even holds a
    # matching mark: the link is refused, not followed
    target = os.path.join(root, "elsewhere")
    os.makedirs(target)
    open(os.path.join(target, fleet.SENTINEL), "w").write(r.run_id + "\n")
    open(os.path.join(target, "canary"), "w").write("keep\n")
    os.rename(mine, os.path.join(root, "moved"))
    os.symlink(target, mine)
elif case == "no-sentinel":
    os.remove(mark)
elif case == "wrong-id":
    open(mark, "w").write("ffffffffffff\n")
elif case == "sentinel-link":
    os.remove(mark)
    open(os.path.join(root, "fake-mark"), "w").write(r.run_id + "\n")
    os.symlink(os.path.join(root, "fake-mark"), mark)
elif case == "not-a-dir":
    os.rename(mine, os.path.join(root, "moved"))
    open(mine, "w").write("a file\n")
elif case == "repush":
    # a later pass finds its own directory and pushes into it again
    rc, err = r.push(h, ["payload.txt"])
    print("repush rc=%d %s" % (rc, err.strip()))
    open(mark, "w").write("ffffffffffff\n")
    rc, err = r.push(h, ["payload.txt"])
    print("tampered rc=%d %s" % (rc, err.strip()))
    open(mark, "w").write(r.run_id + "\n")
elif case == "push-sentinel":
    open(fleet.SENTINEL, "w").write("x\n")
    rc, err = r.push(h, [fleet.SENTINEL])
    print("push rc=%d %s" % (rc, err.strip()))
elif case != "normal":
    sys.exit("no such case: " + case)

print("WORK " + os.path.join(root, r.work_dir) if r.work_dir else "WORK ")
print("RESULT " + r.cleanup(h))
EOF
}

setup_host() {
    install_fake_ssh
    fake_host h
    # canaries in the host's root and beside it: nothing may touch them
    echo keep > "$FAKE_ROOT/h/canary"
    echo keep > "$FAKE_ROOT/canary"
    write_driver
    # the stand-in rm: deletes inside this case's temp dir, refuses (and
    # logs) anything else, so no case can reach a real path
    mkdir -p "$TEST_TMPDIR/guard"
    cat > "$TEST_TMPDIR/guard/rm" <<'EOF'
#!/bin/bash
t="$(cd "$TEST_TMPDIR" && pwd -P)"
for a in "$@"; do
    case "$a" in -*) continue ;; esac
    d="$(cd "$(dirname -- "$a")" 2> /dev/null && pwd -P)" || d="?"
    case "$d/$(basename -- "$a")/" in
        "$t"/*) ;;
        *) echo "$a" >> "$TEST_TMPDIR/outside.log"; exit 1 ;;
    esac
done
exec /bin/rm "$@"
EOF
    # a sudo that runs the command as it is, for the --sudo case
    cat > "$TEST_TMPDIR/guard/sudo" <<'EOF'
#!/bin/bash
[ "$1" = -n ] && shift
echo "sudo $*" >> "$TEST_TMPDIR/sudo.log"
exec "$@"
EOF
    chmod +x "$TEST_TMPDIR/guard/rm" "$TEST_TMPDIR/guard/sudo"
    export PATH="$TEST_TMPDIR/guard:$PATH"
}

drive() { "$PY" "$TEST_TMPDIR/drive.py" "$1" "${2:-$QD_DIR}"; }

# what every refusal leaves: the run's directory, the canaries, and no
# delete outside the case
assert_untouched() {
    local root="$FAKE_ROOT/h" mine
    assert_eq "$(cat "$root/canary")" "keep"
    assert_eq "$(cat "$FAKE_ROOT/canary")" "keep"
    assert_eq "$(cat "$root/rd/canary")" "keep"
    assert_no_file "$TEST_TMPDIR/outside.log"
    mine=""
    for d in "$root"/moved "$root"/rd/qd.*; do
        [ -e "$d" ] && { mine="$d"; break; }
    done
    [ -n "$mine" ] || fail "the run's directory is gone"
    assert_file_exists "$mine/inside"
}

refused() {
    setup_host
    out="$(drive "$1")"
    assert_contains "$out" "RESULT qd: could not remove"
    assert_contains "$out" "qd: refusing to remove"
    [ -z "${2:-}" ] || assert_contains "$out" "$2"
    assert_untouched
}

t_normal_cleanup_removes_only_the_run() {
    setup_host
    out="$(drive normal)"
    assert_contains "$out" "RESULT "
    assert_not_contains "$out" "qd:"
    assert_eq "$(ls "$FAKE_ROOT/h/rd")" "canary"
    assert_eq "$(cat "$FAKE_ROOT/h/canary")" "keep"
    assert_no_file "$TEST_TMPDIR/outside.log"
}

t_empty_path() { refused empty "not this run's"; }
t_root() { refused root "not this run's"; }
t_tilde() { refused tilde "not this run's"; }
t_dot() { refused dot "not this run's"; }
t_dotdot_name() { refused dotdot-name "not this run's"; }
t_remote_dir_itself() { refused remote-dir "not this run's"; }
t_dotdot_in_path() { refused dotdot "has a .. in it"; }
t_symlink() {
    refused symlink "it is a symlink"
    assert_eq "$(cat "$FAKE_ROOT/h/elsewhere/canary")" "keep"
    [ -L "$(ls -d "$FAKE_ROOT"/h/rd/qd.*)" ] || fail "the link went"
}
t_no_sentinel() { refused no-sentinel "holds no .qd-owned"; }
t_wrong_run_id() { refused wrong-id "another run's"; }
t_sentinel_is_a_link() {
    refused sentinel-link "holds no .qd-owned"
    assert_file_exists "$FAKE_ROOT/h/fake-mark"
}
t_not_a_directory() { refused not-a-dir "not a directory"; }

t_another_runs_directory() {
    setup_host
    out="$(drive other-run)"
    assert_contains "$out" "not this run's"
    assert_file_exists "$FAKE_ROOT/h/rd/qd.0123456789ab/.qd-owned"
    assert_no_file "$TEST_TMPDIR/outside.log"
}

# --sudo: the checks run under the same sudo as the delete
t_under_sudo() {
    setup_host
    out="$(CASE_SUDO=1 drive wrong-id)"
    assert_contains "$out" "another run's"
    assert_contains "$(cat "$TEST_TMPDIR/sudo.log")" "refusing to remove"
    assert_untouched
    rm -f "$TEST_TMPDIR/sudo.log"
    rm -rf "$FAKE_ROOT/h/rd"
    out="$(CASE_SUDO=1 drive normal)"
    assert_not_contains "$out" "qd:"
    assert_contains "$(cat "$TEST_TMPDIR/sudo.log")" ".qd-owned"
    assert_eq "$(ls "$FAKE_ROOT/h/rd")" "canary"
}

t_a_later_pass_needs_its_own_mark() {
    setup_host
    out="$(drive repush)"
    assert_contains "$out" "repush rc=0"
    assert_contains "$out" "tampered rc=1 qd: rd/qd."
    assert_contains "$out" "is there already, and is not this run's"
    assert_not_contains "$out" "RESULT qd:"
}

t_a_pushed_file_cannot_be_the_mark() {
    setup_host
    out="$(drive push-sentinel)"
    assert_contains "$out" "push rc=1 qd: cannot push a file named .qd-owned"
}

# The suite can fail: with the run-id check taken out of guarded_rm, the
# wrong-id case deletes another run's directory and the assertions see it.
t_mutation_without_the_id_check_fails() {
    setup_host
    mkdir -p "$TEST_TMPDIR/mut"
    cp -R "$QD_DIR/quarterdeck" "$TEST_TMPDIR/mut/"
    "$PY" - "$TEST_TMPDIR/mut/quarterdeck/fleet.py" <<'EOF'
import sys
p = sys.argv[1]
s = open(p).read()
cut = '"[ \\"$(cat %s)\\" = %s ] || %s; "'
args = 's, rid, refuse("its %s is another run\'s" % SENTINEL))'
if cut not in s or args not in s:
    sys.exit("the mutation no longer applies to fleet.py")
s = s.replace(cut, '').replace(args, ')')
s = s.replace('s, s, refuse("it holds no %s" % SENTINEL),',
              's, s, refuse("it holds no %s" % SENTINEL)')
open(p, "w").write(s)
EOF
    out="$(drive wrong-id "$TEST_TMPDIR/mut")"
    assert_not_contains "$out" "refusing"
    if (assert_untouched) 2> /dev/null; then
        fail "the mutant kept the directory: the suite cannot see the check go"
    fi
}

run_test "cleanup removes the run's directory, nothing else" t_normal_cleanup_removes_only_the_run
run_test "refused: an empty work dir"                t_empty_path
run_test "refused: /"                                t_root
run_test "refused: ~"                                t_tilde
run_test "refused: ."                                t_dot
run_test "refused: .."                               t_dotdot_name
run_test "refused: --remote-dir itself"              t_remote_dir_itself
run_test "refused: a .. in the path"                 t_dotdot_in_path
run_test "refused: a symlinked work dir"             t_symlink
run_test "refused: no sentinel"                      t_no_sentinel
run_test "refused: another run's id"                 t_wrong_run_id
run_test "refused: a sentinel that is a link"        t_sentinel_is_a_link
run_test "refused: not a directory"                  t_not_a_directory
run_test "refused: another run's qd.* directory"     t_another_runs_directory
run_test "under --sudo the checks run under sudo"    t_under_sudo
run_test "a later pass needs its own mark"           t_a_later_pass_needs_its_own_mark
run_test "a pushed file cannot be the mark"          t_a_pushed_file_cannot_be_the_mark
run_test "mutation: no id check, and the suite fails" t_mutation_without_the_id_check_fails
finish
