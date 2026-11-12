#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Martin J. Gallagher

# Who ran it (QD-016): every run records the operator and the machine qd
# ran on; a fan-out records the ssh user, the fingerprint of the key it
# offered, and whether it ran under sudo.  What cannot be found out is
# blank, never a guess, and an older run without the columns lists as it
# did.  The fake ssh answers `ssh -G` from FAKE_SSH_USER*; ssh-add and
# ssh-keygen are stand-ins in $FAKE_BIN.

set -u
source "$(dirname "${BASH_SOURCE[0]}")/test_helper.bash"

seed() {
    install_fake_ssh
    for h in node01 node02; do
        fake_host "$h"
        echo "6.1.0" > "$FAKE_ROOT/$h/kernel"
    done
    printf 'node01\nnode02\n' > hosts.txt
    export PATH="$FAKE_BIN:$PATH"
}

# an agent holding one key; a keygen that knows the key files named here
agent() {
    cat > "$FAKE_BIN/ssh-add" <<'EOF'
#!/bin/sh
echo "256 SHA256:agentkey me@laptop (ED25519)"
EOF
    chmod +x "$FAKE_BIN/ssh-add"
}
keygen() {
    cat > "$FAKE_BIN/ssh-keygen" <<'EOF'
#!/bin/sh
# ssh-keygen -l -f FILE
[ -f "$3" ] || { echo "$3: No such file or directory" >&2; exit 1; }
echo "256 SHA256:$(basename "$3") me@laptop (ED25519)"
EOF
    chmod +x "$FAKE_BIN/ssh-keygen"
}

# a field of the newest run's qd.runs row
field() {
    qd show ds:qd.runs --format json 2>/dev/null | "$PY" -c '
import json, sys
rows = json.load(sys.stdin)
rows = rows.get("rows", rows) if isinstance(rows, dict) else rows
v = rows[-1].get(sys.argv[1])
print("" if v is None else v)' "$1"
}

t_a_fan_out_records_who_ran_it() {
    seed
    agent
    export FAKE_SSH_USER=ops
    QD_OPERATOR="Jane Doe" qdf run -s hosts.txt --name kern -- cat kernel \
        > /dev/null
    assert_eq "$(field operator)" "Jane Doe"
    assert_eq "$(field operator_host)" "$("$PY" -c 'import socket; print(socket.gethostname())')"
    assert_eq "$(field ssh_user)" "ops"
    assert_eq "$(field ssh_key)" "SHA256:agentkey"
    assert_eq "$(field sudo)" "no"
    out="$(qd log latest)"
    assert_contains "$out" "by        Jane Doe@"
    assert_contains "$out" "ssh       as ops, key SHA256:agentkey, no sudo"
    assert_contains "$(qd log | head -1)" "operator"
    assert_contains "$(qd log | tail -1)" "Jane Doe"
    # ssh -G is read once per host, and is not a connection
    assert_eq "$(grep -c '^ssh-G ' "$FAKE_SSH_LOG")" "2"
    assert_eq "$(ssh_calls)" "2"
}

t_the_login_user_without_qd_operator() {
    seed
    qdf run -s hosts.txt -- cat kernel > /dev/null
    assert_eq "$(field operator)" "$("$PY" -c 'import getpass; print(getpass.getuser())')"
}

t_user_wins_and_reads_no_config() {
    seed
    export FAKE_SSH_USER=ops
    qdf run -s hosts.txt --user admin -- cat kernel > /dev/null
    assert_eq "$(field ssh_user)" "admin"
    assert_eq "$(grep -c '^ssh-G ' "$FAKE_SSH_LOG")" "0"
}

t_hosts_with_users_of_their_own() {
    seed
    export FAKE_SSH_USER=ops FAKE_SSH_USER_node02=bob
    qdf run -s hosts.txt -- cat kernel > /dev/null
    assert_eq "$(field ssh_user)" "bob,ops"
}

t_an_ssh_without_dash_g_leaves_it_blank() {
    seed
    export FAKE_NO_DASH_G=1
    qdf run -s hosts.txt -- cat kernel > out
    assert_contains "$(qd log latest)" "2 hosts, 2 ok"
    assert_eq "$(field ssh_user)" ""
}

t_the_key_named_in_ssh_and_none_without_tools() {
    seed
    agent
    keygen
    touch id_test
    qdf run -s hosts.txt --ssh "$FAKE_BIN/ssh -i $PWD/id_test" -- cat kernel \
        > /dev/null
    # the -i key, not the agent's
    assert_eq "$(field ssh_key)" "SHA256:id_test"
    qdf run -s hosts.txt --ssh "$FAKE_BIN/ssh -o IdentityFile=$PWD/id_test" \
        -- cat kernel > /dev/null
    assert_eq "$(field ssh_key)" "SHA256:id_test"
    # a key that cannot be read: blank, not the agent's
    qdf run -s hosts.txt --ssh "$FAKE_BIN/ssh -i $PWD/nosuch" -- cat kernel \
        > /dev/null
    assert_eq "$(field ssh_key)" ""
    # two keys, one unreadable: blank, not half a list
    qdf run -s hosts.txt --ssh "$FAKE_BIN/ssh -i $PWD/id_test -i $PWD/nosuch" \
        -- cat kernel > /dev/null
    assert_eq "$(field ssh_key)" ""
    # no ssh-add at all: blank, and the run is not held up
    rm "$FAKE_BIN/ssh-add"
    PATH="$(path_without ssh-add)" qdf run -s hosts.txt -- cat kernel \
        > /dev/null
    assert_eq "$(field ssh_key)" ""
    assert_contains "$(qd log latest)" "2 hosts, 2 ok"
}

t_sudo_is_recorded() {
    seed
    cat > "$FAKE_BIN/sudo" <<'EOF'
#!/bin/sh
# sudo -n sh -c CMD
shift
exec "$@"
EOF
    chmod +x "$FAKE_BIN/sudo"
    qdf run -s hosts.txt --sudo -- cat kernel > /dev/null
    assert_eq "$(field sudo)" "yes"
    assert_contains "$(qd log latest)" "under sudo"
}

t_do_and_import_record_the_operator_only() {
    seed
    printf 'host,load\nh01,0.5\n' > load.csv
    QD_OPERATOR=ann qd import load.csv --name load > /dev/null
    assert_eq "$(field operator)" "ann"
    assert_eq "$(field ssh_user)" ""
    assert_eq "$(field sudo)" ""
    QD_OPERATOR=ann qd "do" --import load.csv -- true > /dev/null 2>&1
    assert_eq "$(field operator)" "ann"
    assert_eq "$(field sudo)" ""
    assert_not_contains "$(qd log latest)" "ssh       "
}

t_free_text_in_qd_operator_round_trips() {
    seed
    QD_OPERATOR="$(printf 'Jane "JD"\tDoe')" qdf run -s hosts.txt -- cat kernel \
        > /dev/null
    assert_contains "$(qd log latest)" "$(printf 'by        Jane "JD"\tDoe@')"
}

t_provost_is_told_the_operator() {
    seed
    # QD_PROVOST may be a command line (the 3.6 job's is `bash .../provost`)
    cat > "$FAKE_BIN/provost-logged" <<EOF
#!/bin/sh
printf '%s\n' "\${PROVOST_OPERATOR-unset}" >> "$TEST_TMPDIR/provost-op"
exec $PROVOST_CMD "\$@"
EOF
    chmod +x "$FAKE_BIN/provost-logged"
    QD_PROVOST="$FAKE_BIN/provost-logged" QD_OPERATOR=ann \
        qdf run -s hosts.txt -- cat kernel > /dev/null
    assert_contains "$(sort -u "$TEST_TMPDIR/provost-op")" "ann"
    assert_not_contains "$(cat "$TEST_TMPDIR/provost-op")" "unset"
    # one the caller set is theirs to keep
    : > "$TEST_TMPDIR/provost-op"
    PROVOST_OPERATOR=svc QD_PROVOST="$FAKE_BIN/provost-logged" \
        QD_OPERATOR=ann qdf run -s hosts.txt -- cat kernel > /dev/null
    assert_eq "$(sort -u "$TEST_TMPDIR/provost-op")" "svc"
    # provost 2.18.0 on refuses a control character in it: a tab and a
    # line break reach provost as spaces, and qd's own row keeps them
    : > "$TEST_TMPDIR/provost-op"
    QD_PROVOST="$FAKE_BIN/provost-logged" \
        QD_OPERATOR="$(printf 'Jane\tDoe\nlab 2')" \
        qdf run -s hosts.txt -- cat kernel > /dev/null
    assert_eq "$(sort -u "$TEST_TMPDIR/provost-op")" "Jane Doe lab 2"
}

# qd 0.6.4 wrote qd.runs without the five columns: run qd with them cut
# off, which writes exactly that header, then a run of today's beside it
t_an_older_run_lists_blank() {
    seed
    "$PY" - "$QD_DIR" <<'EOF' > /dev/null
import sys
sys.path.insert(0, sys.argv[1])
from quarterdeck import store, cli
store.RUN_COLUMNS = store.RUN_COLUMNS[:store.RUN_COLUMNS.index("operator")]
sys.exit(cli.main(["import", "hosts.txt", "--name", "old"]))
EOF
    old="$(qd log | tail -1 | awk '{print $1}')"
    QD_OPERATOR=ann qdf run -s hosts.txt --name new -- cat kernel > /dev/null
    out="$(qd log)"
    assert_contains "$out" "$old"
    assert_contains "$(echo "$out" | grep -F "$old")" "import"
    assert_not_contains "$(echo "$out" | grep -F "$old")" "ann"
    assert_contains "$(echo "$out" | tail -1)" "ann"
    assert_not_contains "$(qd log "$old")" "by        "
    assert_contains "$(qd log latest)" "by        ann@"
}

run_test "a fan-out records who ran it"             t_a_fan_out_records_who_ran_it
run_test "the login user, without QD_OPERATOR"      t_the_login_user_without_qd_operator
run_test "--user wins, and reads no config"         t_user_wins_and_reads_no_config
run_test "hosts with users of their own"            t_hosts_with_users_of_their_own
run_test "an ssh without -G leaves it blank"        t_an_ssh_without_dash_g_leaves_it_blank
run_test "the key --ssh names; none without tools"  t_the_key_named_in_ssh_and_none_without_tools
run_test "--sudo is recorded"                       t_sudo_is_recorded
run_test "do and import: the operator only"         t_do_and_import_record_the_operator_only
run_test "free text in QD_OPERATOR round-trips"     t_free_text_in_qd_operator_round_trips
run_test "provost is told the operator"             t_provost_is_told_the_operator
run_test "an older run lists blank"                 t_an_older_run_lists_blank
finish
