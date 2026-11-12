#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Martin J. Gallagher

# Remote stores: a store on another machine, read here from a shallow git
# copy fetched over ssh.  The fake ssh runs "remote" commands in the fake
# host's directory, so git's own upload-pack serves a store kept there.

set -u
source "$(dirname "${BASH_SOURCE[0]}")/test_helper.bash"

# a store on fake host wr01, at wr01:store, with one run in it
seed() {
    install_fake_ssh
    fake_host wr01
    export QD_SSH="$FAKE_BIN/ssh"
    unset QD_STORE
    printf 'host,load\nh01,0.5\n' > load.csv
    there import load.csv --name load > /dev/null
}

# qd, filing into the store on wr01 as a run there would
there() { QD_STORE="$FAKE_ROOT/wr01/store" qd "$@"; }

COPY() { echo "$XDG_CACHE_HOME/quarterdeck/remotes/$1"; }

runs_in() { qd log "$@" 2>/dev/null | tail -n +2 | awk '{print $1}' | tr '\n' ' '; }

t_a_remote_store_reads_and_refreshes() {
    seed
    qd store new wr01 --remote wr01:store > out
    assert_contains "$(cat out)" "wr01 = wr01:store"
    assert_contains "$(cat out)" "fetched now: 1 run"
    # shallow: the store as it is now
    assert_eq "$(git -C "$(COPY wr01)" rev-parse --is-shallow-repository)" "true"
    assert_contains "$(qd show latest --store wr01 --format csv)" "h01,0.5"
    assert_contains "$(qd store ls)" "wr01:store   (a copy, fetched"
    # a run there: not fetched again within QD_REMOTE_REFRESH, then it is
    printf 'host,load\nh02,0.9\n' > l2.csv
    there import l2.csv --name later > /dev/null
    n="$(ssh_calls)"
    assert_not_contains "$(runs_in --store wr01)" "later"
    assert_eq "$(ssh_calls)" "$n"
    assert_contains "$(QD_REMOTE_REFRESH=0 runs_in --store wr01)" "later"
    assert_eq "$(ssh_calls)" "$((n + 1))"
    # --no-fetch reads the copy and nothing else
    assert_contains "$(QD_REMOTE_REFRESH=0 runs_in --store wr01 --no-fetch)" "later"
    assert_eq "$(ssh_calls)" "$((n + 1))"
    # the copy is git's alone: nothing of qd's in the store's files
    assert_eq "$(git -C "$(COPY wr01)" status --porcelain)" ""
    # a SHA-1 store's copy is refreshed where it is, never made again
    assert_eq "$(git -C "$(COPY wr01)" rev-parse --show-object-format)" "sha1"
    touch "$(COPY wr01)/.git/kept"
    printf 'host,load\nh03,0.1\n' > l3.csv
    there import l3.csv --name third > /dev/null
    QD_REMOTE_REFRESH=0 qd log --store wr01 > out 2> err
    assert_contains "$(cat out)" "third"
    assert_eq "$(cat err)" ""
    assert_file_exists "$(COPY wr01)/.git/kept"
}

# refused before anything is done: no host contacted, nothing fetched
t_nothing_files_into_a_copy() {
    seed
    qd store new wr01 --remote wr01:store > /dev/null
    fake_host node01
    n="$(ssh_calls)"
    qdf_rc run -S node01 --store wr01 -- uptime 2> err
    assert_status "$QD_RC" 2
    assert_contains "$(cat err)" "wr01 is a copy of wr01:store, read over ssh"
    assert_contains "$(cat err)" "ssh wr01 qd"
    qd_rc import load.csv --store wr01 2> err
    assert_status "$QD_RC" 2
    assert_contains "$(cat err)" "does not file into it"
    qd_rc rm latest --store wr01 --yes 2> err
    assert_contains "$(cat err)" "does not delete from it"
    qd_rc store clear wr01 --yes 2> err
    assert_contains "$(cat err)" "does not clear it"
    # a campaign's and a design's runs, by their store, before anything
    qd_rc campaign run burn --store wr01 2> err
    assert_status "$QD_RC" 2
    assert_contains "$(cat err)" "does not file into it"
    printf '{"factors": {"mtu": [1500, 9000]}}' > d.json
    qd_rc doe run d.json -S node01 --store wr01 -- echo x 2> err
    assert_status "$QD_RC" 2
    assert_contains "$(cat err)" "does not file into it"
    # QD_STORE and the active store are refused the same way
    qd store use wr01 > /dev/null
    qd_rc import load.csv 2> err
    assert_status "$QD_RC" 2
    assert_eq "$(ssh_calls)" "$n"
    assert_eq "$(git -C "$(COPY wr01)" status --porcelain)" ""
    # and the store there is as it was
    assert_eq "$(there log | tail -n +2 | wc -l | tr -d ' ')" "1"
}

# QD_SSH_USER, as qd run logs in, unless the spec names a user
t_the_fleets_ssh_user() {
    seed
    cat > "$FAKE_BIN/ssh-who" <<EOF
#!/bin/bash
echo "\$*" >> "$TEST_TMPDIR/who.log"
exec "$FAKE_BIN/ssh" "\$@"
EOF
    chmod +x "$FAKE_BIN/ssh-who"
    QD_SSH="$FAKE_BIN/ssh-who" QD_SSH_USER=lab qd store new a --remote wr01:store > /dev/null
    assert_contains "$(cat who.log)" "lab@wr01"
    : > who.log
    QD_SSH="$FAKE_BIN/ssh-who" QD_SSH_USER=lab qd store new b --remote ops@wr01:store > /dev/null
    assert_contains "$(cat who.log)" "ops@wr01"
    assert_not_contains "$(cat who.log)" "lab@"
    # a copy keeps no reflog: what a fetch replaces can be pruned
    assert_eq "$(git -C "$(COPY a)" config core.logAllRefUpdates)" "false"
}

# every ten fetches a gc: the copy is one store, not its history
t_a_copy_stays_one_store() {
    seed
    qd store new wr01 --remote wr01:store > /dev/null
    for i in $(seq 1 11); do
        printf 'host,load\nh%s,0.%s\n' "$i" "$i" > n.csv
        there import n.csv --name "n$i" > /dev/null
        QD_REMOTE_REFRESH=0 qd log --store wr01 > /dev/null 2>&1
    done
    packs="$(find "$(COPY wr01)/.git/objects/pack" -name '*.pack' | wc -l)"
    [ "$packs" -le 10 ] || fail "$packs packs: the copy was never gc'd"
    assert_contains "$(runs_in --store wr01 --no-fetch)" "n11"
}

t_an_unreachable_host_leaves_the_copy() {
    seed
    qd store new wr01 --remote wr01:store > /dev/null
    touch "$FAKE_ROOT/wr01/.unreachable"
    QD_REMOTE_REFRESH=0 qd log --store wr01 > out 2> err
    assert_contains "$(cat err)" "cannot reach wr01: connect to host wr01 port 22"
    assert_contains "$(cat err)" "reading the copy fetched"
    assert_contains "$(cat out)" "load.csv"
    # tried once: the next command does not wait on it again
    n="$(ssh_calls)"
    qd log --store wr01 > /dev/null 2> err
    assert_eq "$(ssh_calls)" "$n"
    assert_eq "$(cat err)" ""
}

t_what_cannot_be_a_remote_store() {
    seed
    qd_rc store new a --remote wr01:nowhere 2> err
    assert_status "$QD_RC" 2
    assert_contains "$(cat err)" "nowhere on wr01 is not a provost store"
    git init -q "$FAKE_ROOT/wr01/plain"
    git -C "$FAKE_ROOT/wr01/plain" -c user.name=t -c user.email=t@t \
        commit -q --allow-empty -m x
    qd_rc store new b --remote wr01:plain 2> err
    assert_contains "$(cat err)" "a git repository, but not a provost store"
    qd_rc store new c --remote zz9:store 2> err
    assert_contains "$(cat err)" "cannot reach zz9: Could not resolve hostname"
    qd_rc store new d --remote justaname 2> err
    assert_contains "$(cat err)" "is [USER@]HOST:PATH"
    qd_rc store new e --remote wr01:store --path "$PWD/x" 2> err
    assert_contains "$(cat err)" "not both"
    # nothing registered, nothing half made
    assert_contains "$(qd store ls)" "0 named stores"
    assert_eq "$(ls -A "$XDG_CACHE_HOME/quarterdeck/remotes")" ""
}

# what git says over ssh of a store owned by someone else, put in words
t_another_users_store_is_explained() {
    seed
    cat > "$FAKE_BIN/ssh-dubious" <<'EOF'
#!/bin/bash
echo "fatal: detected dubious ownership in repository at '/srv/store'" >&2
exit 128
EOF
    chmod +x "$FAKE_BIN/ssh-dubious"
    QD_SSH="$FAKE_BIN/ssh-dubious" qd_rc store new o --remote wr01:/srv/store 2> err
    assert_status "$QD_RC" 2
    assert_contains "$(cat err)" "git on wr01 will not read /srv/store: it belongs to another user"
    assert_contains "$(cat err)" "git config --global --add safe.directory /srv/store"
}

t_rename_and_rm_a_remote_store() {
    seed
    qd store new wr01 --remote wr01:store > /dev/null
    qd store rename wr01 rack1 > /dev/null
    assert_no_file "$(COPY wr01)"
    assert_dir_exists "$(COPY rack1)/datasets"
    assert_contains "$(qd store ls)" "rack1     1  wr01:store"
    assert_contains "$(runs_in --store rack1)" "load"
    qd store rm rack1 > out
    assert_contains "$(cat out)" "its copy here deleted; the store on wr01 is as it was"
    assert_no_file "$(COPY rack1)"
    assert_dir_exists "$FAKE_ROOT/wr01/store/datasets"
}

# git's words for a copy in one object format and a store in the other
t_a_mismatched_format_is_explained() {
    seed
    cat > "$FAKE_BIN/ssh-mismatch" <<'EOF2'
#!/bin/bash
echo "fatal: mismatched algorithms: client sha1; server sha256" >&2
exit 128
EOF2
    chmod +x "$FAKE_BIN/ssh-mismatch"
    QD_SSH="$FAKE_BIN/ssh-mismatch" qd_rc store new m --remote wr01:/srv/store 2> err
    assert_status "$QD_RC" 2
    assert_contains "$(cat err)" "/srv/store on wr01 is in git's SHA-256 object format and the copy here is SHA-1"
    assert_contains "$(cat err)" "the copy has to be made again"
    assert_eq "$(ls -A "$XDG_CACHE_HOME/quarterdeck/remotes")" ""
}

# a git too old for SHA-256 (2.29) is named when a copy cannot be made
t_an_old_git_is_named() {
    seed
    real="$(command -v git)"
    mkdir -p oldgit
    cat > oldgit/git <<EOF2
#!/bin/bash
[ "\$1" = --version ] && { echo "git version 2.25.1"; exit 0; }
exec "$real" "\$@"
EOF2
    chmod +x oldgit/git
    # what an old git might make of a SHA-256 store's advertisement
    cat > "$FAKE_BIN/ssh-old" <<'EOF2'
#!/bin/bash
echo "fatal: protocol error: unexpected capabilities^{}" >&2
exit 128
EOF2
    chmod +x "$FAKE_BIN/ssh-old"
    PATH="$PWD/oldgit:$PATH" QD_SSH="$FAKE_BIN/ssh-old" qd_rc store new p --remote wr01:store 2> err
    assert_status "$QD_RC" 2
    assert_contains "$(cat err)" "cannot fetch wr01:store: fatal: protocol error"
    assert_contains "$(cat err)" "this git is 2.25"
    assert_contains "$(cat err)" "needs git 2.29 or newer here"
}

# Why a SHA-256 case cannot run here, or nothing: a git that keeps sha256
# (2.29 on) and a provost whose init takes --object-format (2.18.0 on).
sha256_why_not() {
    local v
    v="$(git --version | sed -n 's/^git version \([0-9]*\)\.\([0-9]*\).*/\1 \2/p')"
    # shellcheck disable=SC2086  # "MAJOR MINOR"
    set -- $v
    if [ -z "${1:-}" ] || [ "$1" -lt 2 ] || { [ "$1" -eq 2 ] && [ "$2" -lt 29 ]; }; then
        echo "git here is $(git --version | sed 's/^git version //'); SHA-256 needs 2.29 or newer"
        return
    fi
    # shellcheck disable=SC2086  # QD_PROVOST may be a command line
    if ! $PROVOST_CMD init --help 2>&1 | grep -q -- --object-format; then
        echo "this provost's init has no --object-format (provost 2.18.0 on)"
    fi
}

# a store on wr01 made SHA-256, by provost itself
sha256_store() {
    rm -rf "$FAKE_ROOT/wr01/store"
    # shellcheck disable=SC2086  # QD_PROVOST may be a command line
    PROVOST_WORKSPACE="$FAKE_ROOT/wr01/store" $PROVOST_CMD init \
        --object-format sha256 > /dev/null
    assert_eq "$(git -C "$FAKE_ROOT/wr01/store" rev-parse --show-object-format)" "sha256"
}

t_a_sha256_store_reads_and_refreshes() {
    install_fake_ssh
    fake_host wr01
    export QD_SSH="$FAKE_BIN/ssh"
    unset QD_STORE
    sha256_store
    printf 'host,load\nh01,0.5\n' > load.csv
    there import load.csv --name load > /dev/null
    qd store new wr01 --remote wr01:store > out
    assert_contains "$(cat out)" "fetched now: 1 run"
    assert_eq "$(git -C "$(COPY wr01)" rev-parse --show-object-format)" "sha256"
    assert_eq "$(git -C "$(COPY wr01)" rev-parse --is-shallow-repository)" "true"
    assert_contains "$(qd show latest --store wr01 --format csv)" "h01,0.5"
    # refreshed in place, as a SHA-1 store's copy is
    touch "$(COPY wr01)/.git/kept"
    printf 'host,load\nh02,0.9\n' > l2.csv
    there import l2.csv --name later > /dev/null
    QD_REMOTE_REFRESH=0 qd log --store wr01 > out 2> err
    assert_contains "$(cat out)" "later"
    assert_eq "$(cat err)" ""
    assert_file_exists "$(COPY wr01)/.git/kept"
}

# a SHA-1 store remade SHA-256: its copy is made again, and said
t_a_store_remade_sha256_remakes_its_copy() {
    seed
    qd store new wr01 --remote wr01:store > /dev/null
    assert_eq "$(git -C "$(COPY wr01)" rev-parse --show-object-format)" "sha1"
    touch "$(COPY wr01)/.git/kept"
    sha256_store
    printf 'host,load\nh09,0.7\n' > l9.csv
    there import l9.csv --name remade > /dev/null
    QD_REMOTE_REFRESH=0 qd log --store wr01 > out 2> err
    assert_contains "$(cat err)" "wr01:store is now in git's SHA-256 object format and its copy here was SHA-1: making the copy again"
    assert_contains "$(cat out)" "remade"
    assert_eq "$(git -C "$(COPY wr01)" rev-parse --show-object-format)" "sha256"
    assert_no_file "$(COPY wr01)/.git/kept"
    # nothing left beside it, and the next refresh is a plain one
    assert_eq "$(ls -A "$XDG_CACHE_HOME/quarterdeck/remotes")" "wr01"
    QD_REMOTE_REFRESH=0 qd log --store wr01 > /dev/null 2> err
    assert_eq "$(cat err)" ""
}

web_get() {
    "$PY" - "$URL" "$1" <<'EOF'
import sys, urllib.request
with urllib.request.urlopen(sys.argv[1].rstrip("/") + sys.argv[2]) as r:
    sys.stdout.buffer.write(r.read() + b"\n")
EOF
}

t_the_web_page_reads_a_remote_store() {
    seed
    qd store new wr01 --remote wr01:store > /dev/null
    # a port range of this suite's own (test_xstore.sh says why)
    QD_REMOTE_REFRESH=0 "$PY" "$QD_DIR/qd" web -n -q --port 18140 \
        --store wr01 > web.out 2> web.err &
    echo $! > web.pid
    URL=""
    for _ in $(seq 1 50); do
        URL="$(sed -n 's/^qd web: \(http:[^ ]*\).*/\1/p' web.err | tail -1)"
        [ -n "$URL" ] && break
        sleep 0.1
    done
    [ -n "$URL" ] || { cat web.err; fail "the server did not start"; }
    out="$(web_get /api/stores)"
    assert_contains "$out" '"remote": "wr01"'
    assert_contains "$out" '"path": "wr01:store"'
    assert_not_contains "$(web_get /api/entries)" "later"
    # a run there shows on the page's next read, the server still up
    printf 'host,load\nh02,0.9\n' > l2.csv
    there import l2.csv --name later > /dev/null
    assert_contains "$(web_get /api/entries)" "later"
}

run_test "a remote store reads, and refreshes"       t_a_remote_store_reads_and_refreshes
run_test "nothing files into a copy"                 t_nothing_files_into_a_copy
run_test "the fleet's ssh user"                     t_the_fleets_ssh_user
run_test "a copy stays one store"                  t_a_copy_stays_one_store
run_test "an unreachable host leaves the copy"       t_an_unreachable_host_leaves_the_copy
run_test "what cannot be a remote store"             t_what_cannot_be_a_remote_store
run_test "another user's store, explained"           t_another_users_store_is_explained
run_test "rename and rm a remote store"              t_rename_and_rm_a_remote_store
run_test "the web page reads a remote store"         t_the_web_page_reads_a_remote_store
run_test "a mismatched object format, explained"     t_a_mismatched_format_is_explained
run_test "an old git is named"                       t_an_old_git_is_named

# QD_TEST_SHA256=require (CI's store-check job) fails these rather than
# skipping them where git or provost cannot make a SHA-256 store
why="$(sha256_why_not)"
for c in "a SHA-256 store reads, and refreshes:t_a_sha256_store_reads_and_refreshes" \
         "a store remade SHA-256 remakes its copy:t_a_store_remade_sha256_remakes_its_copy"; do
    name="${c%%:t_*}"
    fn="t_${c##*:t_}"
    if [ -z "$why" ]; then
        run_test "$name" "$fn"
    elif [ "${QD_TEST_SHA256:-}" = require ]; then
        run_test "$name" fail "QD_TEST_SHA256=require, but $why"
    else
        printf '  skip %s: %s\n' "$name" "$why"
    fi
done
finish
