#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Martin J. Gallagher

# How qd reaches hosts through the setups secure sites use (QD-018):
# --ssh-config (ssh -F) for ssh, scp, ssh -G and a remote store's git;
# --reuse, one ssh master per host for the whole command, its sockets in a
# short private directory that is gone afterwards; and `qd doctor HOST`,
# what ssh resolves for a host without contacting it.
#
# The first cases use the fake ssh, which records every argv
# ($FAKE_SSH_ARGV).  The last ones start a real sshd of their own on
# loopback, as this user, and prove the real thing: a ProxyJump through a
# bastion (and that qd's -o options do not reach the hop), one login per
# host under --reuse, a master opened beforehand carrying a run with no
# login left to make (the one-time-code setup), and a certificate login.
# Where there is no sshd they are skipped, and said so; QD_TEST_SSHD=require
# (CI's ssh job, which installs one) fails them instead.  Kerberos needs a
# KDC and is not run here: doctor's reading of klist is, with stand-ins.

set -u
source "$(dirname "${BASH_SOURCE[0]}")/test_helper.bash"

push_tool() {
    # shellcheck disable=SC2016  # for the far side to expand
    printf '#!/bin/sh\necho ran-on-$FAKE_HOST\n' > tool.sh
    chmod +x tool.sh
}

# the ControlPath directories the fake ssh and scp were given
ctl_dirs() {
    sed -n 's|.* ControlPath=\([^ ]*\)/%C .*|\1|p' "$FAKE_SSH_ARGV" | sort -u
}

# the connections the fakes saw: not ssh -G, not ssh -O (and not the
# owner test `[ -O dir ]` in qd's mkdir, which is a connection)
connections() {
    grep -vE -e ' -G [^ ]+$' -e ' -O (exit|check) [^ ]+$' "$FAKE_SSH_ARGV" || true
}

# every connection carries TEXT
each_connection_has() {
    local bad
    bad="$(connections | grep -vF -- "$1" || true)"
    [ -z "$bad" ] || fail "a connection without $1: $bad"
}

# -- --ssh-config -------------------------------------------------------------

t_ssh_config_reaches_ssh_scp_and_dash_g() {
    install_fake_ssh
    fake_host h1
    push_tool
    printf 'Host *\n  ConnectTimeout 3\n' > my.cfg
    # a stored run, so ssh -G is asked who logs in, through the same file
    qdf run --ssh-config my.cfg -S h1 --push tool.sh --remote-dir rd -q \
        -- ./tool.sh > /dev/null
    cfg="$(pwd -P)/my.cfg"
    # relative on the command line, absolute to ssh: the same file from
    # any directory
    bad="$(grep -v -e "^ssh -F $cfg " -e "^scp -F $cfg " "$FAKE_SSH_ARGV" || true)"
    [ -z "$bad" ] || fail "a call without -F $cfg: $bad"
    assert_contains "$(cat "$FAKE_SSH_ARGV")" "scp -F $cfg"
    assert_contains "$(cat "$FAKE_SSH_ARGV")" " -G h1"
    assert_contains "$(qd show latest --cols host,A --format csv)" "h1,ran-on-h1"
    # and nothing about connection sharing unless asked for
    assert_not_contains "$(cat "$FAKE_SSH_ARGV")" "Control"
}

t_qd_ssh_config_is_the_same() {
    install_fake_ssh
    fake_host h1
    printf 'Host *\n' > my.cfg
    QD_SSH_CONFIG=my.cfg qdf run -S h1 --no-store -q -- true > /dev/null
    assert_contains "$(cat "$FAKE_SSH_ARGV")" "ssh -F $(pwd -P)/my.cfg -o BatchMode=yes"
}

t_a_missing_ssh_config_is_refused_before_any_host() {
    install_fake_ssh
    fake_host h1
    qdf_rc run --ssh-config nope.cfg -S h1 -- true 2> err
    assert_status "$QD_RC" 2
    assert_contains "$(cat err)" "cannot read --ssh-config"
    assert_contains "$(cat err)" "no host was contacted"
    qdf_rc run --ssh-config nope.cfg -S h1 --dry-run -- true 2> err
    assert_status "$QD_RC" 2
    assert_eq "$(ssh_calls)" "0"
    assert_eq "$(cat "$FAKE_SSH_ARGV")" ""
}

t_a_remote_store_reads_qd_ssh_config() {
    printf 'Host *\n' > my.cfg
    # shellcheck disable=SC2016  # Python, not shell
    out="$(QD_SSH_CONFIG=my.cfg "$PY" -c '
import sys
sys.path.insert(0, sys.argv[1])
from quarterdeck import stores
print(stores._git_env()["GIT_SSH_COMMAND"])' "$QD_DIR")"
    assert_contains "$out" "-F $(pwd -P)/my.cfg -o BatchMode=yes"
}

# -- --reuse --------------------------------------------------------------------

t_reuse_shares_one_master_per_host_and_cleans_up() {
    install_fake_ssh
    fake_host h1
    fake_host h2
    push_tool
    export TMPDIR="$TEST_TMPDIR/t"
    mkdir -p "$TMPDIR"
    qdf run --reuse -S h1,h2 --push tool.sh --remote-dir rd -q \
        -- ./tool.sh > /dev/null
    # mkdir, scp, chmod, the command and the clean-up, on each host
    n="$(connections | wc -l | tr -d ' ')"
    [ "$n" -eq 10 ] || fail "$n connections, not 10: $(cat "$FAKE_SSH_ARGV")"
    each_connection_has "ControlMaster=auto"
    each_connection_has "ControlPersist=60"
    dirs="$(ctl_dirs)"
    case "$dirs" in
        "$TMPDIR"/qd-ssh-????????) ;;
        *) fail "not one directory in TMPDIR: $dirs" ;;
    esac
    each_connection_has "ControlPath=$dirs/%C"
    assert_contains "$(grep '^scp ' "$FAKE_SSH_ARGV")" "ControlPath=$dirs/%C"
    # every master closed, by the same options it was opened with, and the
    # directory gone, sockets and all
    # shellcheck disable=SC2153  # set by test_helper.bash
    log="$(cat "$FAKE_SSH_LOG")"
    assert_contains "$log" "ssh-O exit h1"
    assert_contains "$log" "ssh-O exit h2"
    assert_contains "$(grep ' -O exit ' "$FAKE_SSH_ARGV")" "ControlPath=$dirs/%C"
    assert_no_file "$dirs"
    assert_eq "$(ls -A "$TMPDIR")" ""
    assert_contains "$(qd show latest --cols host,A --format csv)" "h2,ran-on-h2"
}

t_qd_ssh_reuse_is_the_same() {
    install_fake_ssh
    fake_host h1
    QD_SSH_REUSE=1 qdf run -S h1 --no-store -q -- true > /dev/null
    each_connection_has "ControlMaster=auto"
    : > "$FAKE_SSH_ARGV"
    QD_SSH_REUSE=0 qdf run -S h1 --no-store -q -- true > /dev/null
    assert_not_contains "$(cat "$FAKE_SSH_ARGV")" "Control"
}

t_reuse_keeps_a_master_from_pass_to_pass() {
    install_fake_ssh
    fake_host h1
    # a master idles at least to the next pass, 90 s away
    qdf run --reuse -S h1 --every 90 --count 1 --no-store -q -- true > /dev/null
    each_connection_has "ControlPersist=120"
}

t_reuse_cleans_up_after_failed_and_unreachable_hosts() {
    install_fake_ssh
    fake_host h1
    fake_host_unreachable h9
    export TMPDIR="$TEST_TMPDIR/t"
    mkdir -p "$TMPDIR"
    qdf_rc run --reuse -S h1,h9 --no-store -q -- false > /dev/null
    assert_status "$QD_RC" 1
    assert_no_file "$(ctl_dirs)"
    assert_eq "$(ls -A "$TMPDIR")" ""
}

t_reuse_cleans_up_when_qd_is_terminated() {
    install_fake_ssh
    fake_host h1
    export TMPDIR="$TEST_TMPDIR/t"
    mkdir -p "$TMPDIR"
    # qd itself, not the qd function: $! must be its pid
    "$PY" "$QD_DIR/qd" run --ssh "$FAKE_BIN/ssh" --reuse -S h1 --no-store \
        -- sleep 3 > /dev/null 2>&1 &
    pid=$!
    # until the run's master is open on h1
    for _ in $(seq 1 50); do
        ls "$TMPDIR"/qd-ssh-*/fake-master-h1 > /dev/null 2>&1 && break
        sleep 0.1
    done
    ls "$TMPDIR"/qd-ssh-*/fake-master-h1 > /dev/null 2>&1 ||
        fail "no master opened: $(cat "$FAKE_SSH_ARGV")"
    kill -TERM "$pid"
    rc=0
    wait "$pid" || rc=$?
    assert_status "$rc" 143
    assert_contains "$(cat "$FAKE_SSH_LOG")" "ssh-O exit h1"
    assert_eq "$(ls -A "$TMPDIR")" ""
}

t_reuse_dry_run_shows_the_options_and_leaves_nothing() {
    install_fake_ssh
    fake_host h1
    export TMPDIR="$TEST_TMPDIR/t"
    mkdir -p "$TMPDIR"
    out="$(qdf run --reuse --dry-run -S h1 -- uptime)"
    assert_contains "$out" "-o ControlMaster=auto -o ControlPath=$TMPDIR/qd-ssh-"
    assert_eq "$(ssh_calls)" "0"
    assert_eq "$(ls -A "$TMPDIR")" ""
}

t_reuse_shares_masters_across_a_probes_runs() {
    install_fake_ssh
    fake_host h1
    qdf run --reuse -S h1 --no-store -q -- true > /dev/null
    first="$(ctl_dirs)"
    : > "$FAKE_SSH_ARGV"
    : > "$FAKE_SSH_LOG"
    # two probes, filed as two runs from one pool of connections
    qdf probe os mounts --reuse -S h1 -q > /dev/null
    assert_eq "$(qd log | grep -cE '^[0-9]+-[0-9]+-(os|mounts) ')" "2"
    dirs="$(ctl_dirs)"
    [ -n "$dirs" ] || fail "no ControlPath: $(cat "$FAKE_SSH_ARGV")"
    assert_eq "$(printf '%s\n' "$dirs" | wc -l | tr -d ' ')" "1"
    [ "$dirs" != "$first" ] || fail "a second command reused the first's directory"
    # one master for both runs, closed once
    assert_eq "$(grep -c 'ssh-O exit h1' "$FAKE_SSH_LOG")" "1"
    assert_no_file "$dirs"
}

t_the_socket_directory_is_short_and_private() {
    long="$TEST_TMPDIR/$(printf 'x%.0s' $(seq 1 80))"
    short="$(mktemp -d /tmp/qd-t.XXXXXX)"
    mkdir -p "$long"
    rc=0
    "$PY" - "$QD_DIR" "$long" "$short" <<'EOF' || rc=$?
import os, stat, sys
sys.path.insert(0, sys.argv[1])
from quarterdeck import fleet
long, short = sys.argv[2], sys.argv[3]
d = fleet.control_dir([long, short])
assert d and os.path.dirname(d) == short, d
assert stat.S_IMODE(os.stat(d).st_mode) == 0o700, oct(os.stat(d).st_mode)
# room for ssh's own part of the path: /%C, and a master's .XXXXXXXXXXXXXXXX
assert len(d) + len("/") + 40 + 17 < fleet.SUN_PATH, len(d)
assert fleet.control_dir([long]) is None
r = fleet.Reuse(bases=[long])
try:
    r.directory()
except OSError as exc:
    assert "TMPDIR" in str(exc), exc
else:
    raise AssertionError("a directory too long for a socket was taken")
r.close()
r.close()
EOF
    rm -rf "$short"
    assert_status "$rc" 0
    # macOS's TMPDIR is too long for a socket: qd falls back to /tmp
    install_fake_ssh
    fake_host h1
    out="$(TMPDIR="$long" qdf run --reuse --dry-run -S h1 -- true)"
    assert_contains "$out" "ControlPath=/tmp/qd-ssh-"
    assert_eq "$(ls -A "$long")" ""
}

# -- qd doctor HOST -------------------------------------------------------------

t_doctor_shows_what_ssh_resolves() {
    install_fake_ssh
    printf 'Host *\n' > my.cfg
    : > id_here
    printf '#!/bin/sh\nexit 0\n' > "$FAKE_BIN/klist"
    chmod +x "$FAKE_BIN/klist"
    export FAKE_SSH_G="proxyjump bastion.example
certificatefile $TEST_TMPDIR/absent-cert.pub
identityfile $TEST_TMPDIR/id_here
identityfile $TEST_TMPDIR/id_absent
gssapiauthentication yes
gssapidelegatecredentials no
controlmaster auto
controlpath $TEST_TMPDIR/cm-abc
controlpersist 14400
batchmode yes"
    export FAKE_MASTER_OPEN=1
    PATH="$FAKE_BIN:$PATH" qd doctor web01:2222 --ssh "$FAKE_BIN/ssh" \
        --ssh-config my.cfg -u ops > out
    o="$(cat out)"
    assert_contains "$o" "web01:2222, as qd's ssh resolves it"
    assert_contains "$o" "no host is contacted"
    assert_contains "$o" "bastion.example  (through this bastion)"
    assert_contains "$o" "absent-cert.pub: not here"
    assert_contains "$o" "$TEST_TMPDIR/id_here"
    assert_not_contains "$o" "id_absent"
    assert_contains "$o" "yes: a Kerberos ticket is held (klist -s)"
    assert_contains "$o" "cm-abc: a master is open"
    assert_contains "$o" "no password or one-time code can be typed"
    # ssh -G was asked as qd's ssh connects: the file, qd's own options,
    # the user and the port
    g="$(grep ' -G ' "$FAKE_SSH_ARGV")"
    assert_contains "$g" "-F $(pwd -P)/my.cfg"
    assert_contains "$g" "-o BatchMode=yes"
    assert_contains "$g" "-l ops"
    assert_contains "$g" "-p 2222"
    assert_contains "$g" "-G web01"
    # the bastion as the hop reaches it: the file, and none of qd's -o
    assert_contains "$o" "bastion.example, as"
    assert_contains "$o" "qd's -o options do not reach the hop"
    hop="$(grep ' -G bastion.example$' "$FAKE_SSH_ARGV")"
    assert_contains "$hop" "-F $(pwd -P)/my.cfg"
    assert_not_contains "$hop" "BatchMode"
    # it reads, it never connects
    assert_eq "$(ssh_calls)" "0"
}

t_doctor_says_when_there_is_no_ticket_or_no_klist() {
    install_fake_ssh
    export FAKE_SSH_G="gssapiauthentication yes"
    printf '#!/bin/sh\nexit 1\n' > "$FAKE_BIN/klist"
    chmod +x "$FAKE_BIN/klist"
    out="$(PATH="$FAKE_BIN:$PATH" qd doctor h1 --ssh "$FAKE_BIN/ssh")"
    assert_contains "$out" "no Kerberos ticket held (klist -s): kinit first"
    rm "$FAKE_BIN/klist"
    out="$(PATH="$(path_without klist)" qd doctor h1 --ssh "$FAKE_BIN/ssh")"
    assert_contains "$out" "klist is not here"
}

t_doctor_says_when_ssh_dash_g_fails() {
    install_fake_ssh
    FAKE_NO_DASH_G=1 qd_rc doctor h1 --ssh "$FAKE_BIN/ssh" > out
    assert_status "$QD_RC" 1
    assert_contains "$(cat out)" "ssh -G failed: ssh: illegal option -- G"
    qd_rc doctor h1 --ssh "$FAKE_BIN/ssh" --ssh-config nope.cfg 2> err
    assert_status "$QD_RC" 2
    assert_contains "$(cat err)" "cannot read --ssh-config"
}

t_doctor_without_a_host_asks_ssh_nothing() {
    install_fake_ssh
    QD_SSH="$FAKE_BIN/ssh" qd_rc doctor > out
    assert_not_contains "$(cat out)" "as qd's ssh resolves it"
    assert_eq "$(cat "$FAKE_SSH_ARGV")" ""
}

# -- a real sshd on loopback ----------------------------------------------------

sshd_bin() {
    command -v sshd 2> /dev/null && return 0
    [ -x /usr/sbin/sshd ] && echo /usr/sbin/sshd
}

# Why a real sshd cannot run here, or nothing when it can.
sshd_why_not() {
    if [ -z "$(sshd_bin)" ] || ! command -v ssh > /dev/null ||
            ! command -v ssh-keygen > /dev/null; then
        echo "no sshd, ssh and ssh-keygen here (install openssh-server)"
    elif [ "$(id -u)" = 0 ] && [ ! -d /run/sshd ] && [ ! -d /var/run/sshd ] &&
            [ ! -d /var/empty ]; then
        echo "as root, sshd needs its privilege separation directory, /run/sshd"
    fi
}

# client_cfg CHECK: $SSHD_DIR/ssh.cfg, naming the case's sshd `direct` and,
# through `direct` as through a bastion, `jumped`.  The bastion has a block
# of its own, as the README says it must -- BatchMode, and CHECK for its
# StrictHostKeyChecking -- since ssh reaches it with a second ssh that
# reads this file and none of qd's -o options.
client_cfg() {
    local d="$SSHD_DIR"
    cat > "$d/ssh.cfg" <<EOF
Host direct
  BatchMode yes
  StrictHostKeyChecking $1
Host direct jumped
  HostName 127.0.0.1
  Port $SSHD_PORT
  User $(id -un)
  IdentityFile $d/user_key
  $SSHD_CERT_LINE
  IdentitiesOnly yes
  IdentityAgent none
  UserKnownHostsFile $d/known_hosts
  GlobalKnownHostsFile /dev/null
Host jumped
  ProxyJump direct
EOF
}

# start_sshd [cert]: an sshd of this case's own on a free loopback port, as
# this user, logging every login to $SSHD_DIR/sshd.log, and client_cfg's
# config for it.  With cert, it trusts a CA's certificates and no plain key
# at all, and the client offers a certificate that CA signed.
start_sshd() {
    SSHD_DIR="$TEST_TMPDIR/sshd"
    local d="$SSHD_DIR" auth cert_line="" ca_line="" me
    me="$(id -un)"
    mkdir -p "$d"
    ssh-keygen -q -t ed25519 -N '' -f "$d/host_key"
    ssh-keygen -q -t ed25519 -N '' -C qd-test -f "$d/user_key"
    if [ "${1:-}" = cert ]; then
        ssh-keygen -q -t ed25519 -N '' -C qd-test-ca -f "$d/ca"
        ssh-keygen -q -s "$d/ca" -I qd-test -n "$me" -V -5m:+1h "$d/user_key.pub"
        auth="AuthorizedKeysFile none"
        ca_line="TrustedUserCAKeys $d/ca.pub"
        cert_line="CertificateFile $d/user_key-cert.pub"
    else
        cp "$d/user_key.pub" "$d/authorized_keys"
        auth="AuthorizedKeysFile $d/authorized_keys"
    fi
    SSHD_PORT="$("$PY" -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')"
    cat > "$d/sshd_config" <<EOF
ListenAddress 127.0.0.1
Port $SSHD_PORT
HostKey $d/host_key
PidFile $TEST_TMPDIR/sshd.pid
$auth
$ca_line
StrictModes no
UsePAM no
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin prohibit-password
LogLevel DEBUG1
Subsystem sftp internal-sftp
EOF
    SSHD_CERT_LINE="$cert_line"
    client_cfg accept-new
    "$(sshd_bin)" -f "$d/sshd_config" -E "$d/sshd.log" ||
        { fail "sshd would not start: $(cat "$d/sshd.log")"; return 1; }
    for _ in $(seq 1 50); do
        [ -s "$TEST_TMPDIR/sshd.pid" ] && return 0
        sleep 0.1
    done
    fail "sshd did not come up: $(cat "$d/sshd.log")"
}

logins() { grep -c "Accepted publickey" "$SSHD_DIR/sshd.log" || true; }

t_real_proxyjump_through_a_bastion() {
    start_sshd
    cfg="$SSHD_DIR/ssh.cfg"
    # The hop to the bastion takes none of qd's -o options: with its own
    # block saying StrictHostKeyChecking yes and its key not yet known, it
    # fails, though qd asks for accept-new.  (yes, not ask: it never
    # prompts, at a terminal or not.)
    client_cfg yes
    qd_rc run --ssh-config "$cfg" -S jumped --no-store -- true > out
    assert_status "$QD_RC" 1
    assert_contains "$(cat out)" "you have requested strict checking"
    out="$(qd doctor jumped --ssh-config "$cfg")"
    assert_contains "$out" "direct  (through this bastion)"
    assert_contains "$out" "qd's -o options do not reach the hop"
    assert_contains "$out" "an unknown bastion key fails every host"
    # As the README says: the bastion's block takes what qd's -o would
    client_cfg accept-new
    # shellcheck disable=SC2016  # for the far side to expand
    out="$(qd run --ssh-config "$cfg" -S jumped --no-store -- 'echo through-$((6 * 7))')"
    assert_contains "$out" "through-42"
    # the bastion opened a channel on to the host: ProxyJump's hop, which a
    # straight connection never makes
    log="$(cat "$SSHD_DIR/sshd.log")"
    assert_contains "$log" "server_request_direct_tcpip"
    assert_contains "$log" "target 127.0.0.1 port $SSHD_PORT"
    out="$(qd doctor jumped --ssh-config "$cfg")"
    assert_contains "$out" "its batchmode"
    assert_not_contains "$out" "the hop can stop at a password"
}

t_real_reuse_logs_in_once_per_host() {
    start_sshd
    push_tool
    cfg="$SSHD_DIR/ssh.cfg"
    export TMPDIR="$TEST_TMPDIR/t"
    mkdir -p "$TMPDIR"
    n0="$(logins)"
    qd run --ssh-config "$cfg" -S direct --push tool.sh \
        --remote-dir "$TEST_TMPDIR/rd" --no-store -- ./tool.sh > out
    assert_contains "$(cat out)" "ran-on-"
    n1="$(logins)"
    [ $((n1 - n0)) -ge 4 ] || fail "a push without --reuse logged in $((n1 - n0)) times"
    qd run --reuse --ssh-config "$cfg" -S direct --push tool.sh \
        --remote-dir "$TEST_TMPDIR/rd" --no-store -- ./tool.sh > out
    assert_contains "$(cat out)" "ran-on-"
    # mkdir, scp, chmod, the command and the clean-up: one login
    assert_eq "$(( $(logins) - n1 ))" "1"
    assert_eq "$(ls -A "$TMPDIR")" ""
    # the master has gone too: its title names its socket, in TMPDIR
    if command -v pgrep > /dev/null; then
        for _ in $(seq 1 30); do
            pgrep -f "$TMPDIR/qd-ssh-" > /dev/null || break
            sleep 0.1
        done
        if pgrep -f "$TMPDIR/qd-ssh-" > /dev/null; then
            fail "a master outlived qd"
        fi
    fi
}

t_real_a_master_opened_first_carries_the_run() {
    # The one-time-code setup: a master opened by hand, once, then every
    # BatchMode call rides on it.  The key is withdrawn once the master is
    # up, so a fresh login -- which a code would have to answer -- fails.
    start_sshd
    cfg="$SSHD_DIR/ssh.cfg"
    # short: a socket's path has 104 bytes (macOS's TMPDIR alone is ~50)
    cm="$(mktemp -d /tmp/qd-cm.XXXXXX)"
    cat >> "$cfg" <<EOF
Host held
  HostName 127.0.0.1
  Port $SSHD_PORT
  User $(id -un)
  IdentityFile $SSHD_DIR/user_key
  IdentitiesOnly yes
  IdentityAgent none
  UserKnownHostsFile $SSHD_DIR/known_hosts
  StrictHostKeyChecking accept-new
  ControlMaster auto
  ControlPath $cm/%C
  ControlPersist 60
EOF
    # (its output elsewhere: the master would hold this case's open)
    ssh -F "$cfg" -fN held < /dev/null > /dev/null 2>&1
    : > "$SSHD_DIR/authorized_keys"
    n0="$(logins)"
    rc=0
    out="$(qd run --ssh-config "$cfg" -S held --no-store -- echo held-ok)" || rc=$?
    doc="$(qd doctor held --ssh-config "$cfg")"
    # --reuse makes masters of its own, and so would need a login
    qd_rc run --reuse --ssh-config "$cfg" -S held --no-store -- true > reuse.out
    ssh -F "$cfg" -O exit held > /dev/null 2>&1 || true
    rm -rf "$cm"
    assert_status "$rc" 0
    assert_contains "$out" "held-ok"
    assert_eq "$(logins)" "$n0"
    assert_contains "$doc" ": a master is open"
    assert_status "$QD_RC" 1
    assert_contains "$(cat reuse.out)" "Permission denied"
}

t_real_certificate_login() {
    start_sshd cert
    out="$(qd run --ssh-config "$SSHD_DIR/ssh.cfg" -S direct --no-store -- echo by-certificate)"
    assert_contains "$out" "by-certificate"
    # sshd took the certificate: it has no plain key to take
    assert_contains "$(cat "$SSHD_DIR/sshd.log")" "ED25519-CERT"
    out="$(qd doctor direct --ssh-config "$SSHD_DIR/ssh.cfg")"
    assert_contains "$out" "user_key-cert.pub: valid from "
}

run_test "--ssh-config: -F for ssh, scp and ssh -G"      t_ssh_config_reaches_ssh_scp_and_dash_g
run_test "QD_SSH_CONFIG does the same"                   t_qd_ssh_config_is_the_same
run_test "a missing --ssh-config: refused, no host"      t_a_missing_ssh_config_is_refused_before_any_host
run_test "a remote store's git reads QD_SSH_CONFIG"      t_a_remote_store_reads_qd_ssh_config
run_test "--reuse: one master a host, then none"         t_reuse_shares_one_master_per_host_and_cleans_up
run_test "QD_SSH_REUSE=1 does the same"                  t_qd_ssh_reuse_is_the_same
run_test "--reuse: a master lasts to the next pass"      t_reuse_keeps_a_master_from_pass_to_pass
run_test "--reuse: cleaned up after failed hosts"        t_reuse_cleans_up_after_failed_and_unreachable_hosts
run_test "--reuse: cleaned up when qd is terminated"     t_reuse_cleans_up_when_qd_is_terminated
run_test "--reuse --dry-run: shown, nothing left"        t_reuse_dry_run_shows_the_options_and_leaves_nothing
run_test "--reuse: a probe's runs share the masters"     t_reuse_shares_masters_across_a_probes_runs
run_test "the socket directory: short and private"       t_the_socket_directory_is_short_and_private
run_test "doctor HOST: what ssh resolves"                t_doctor_shows_what_ssh_resolves
run_test "doctor HOST: no ticket, no klist"              t_doctor_says_when_there_is_no_ticket_or_no_klist
run_test "doctor HOST: when ssh -G fails"                t_doctor_says_when_ssh_dash_g_fails
run_test "doctor alone asks ssh nothing"                 t_doctor_without_a_host_asks_ssh_nothing

why="$(sshd_why_not)"
for c in "real sshd: ProxyJump through a bastion:t_real_proxyjump_through_a_bastion" \
         "real sshd: --reuse logs in once a host:t_real_reuse_logs_in_once_per_host" \
         "real sshd: a master opened first carries a run:t_real_a_master_opened_first_carries_the_run" \
         "real sshd: a certificate login:t_real_certificate_login"; do
    name="${c%%:t_*}"
    fn="t_${c##*:t_}"
    if [ -z "$why" ]; then
        run_test "$name" "$fn"
    elif [ "${QD_TEST_SSHD:-}" = require ]; then
        run_test "$name" fail "QD_TEST_SSHD=require, but $why"
    else
        printf '  skip %s: %s\n' "$name" "$why"
    fi
done
finish
