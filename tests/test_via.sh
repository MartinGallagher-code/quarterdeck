#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Martin J. Gallagher

# --via: reaching the hosts through srun inside a Slurm allocation, pdsh or
# clush instead of ssh -- the same rows, the same outcomes, the same
# cleanup.  Slurm, pdsh and clush cannot run here, so every one of them is
# a stand-in (install_fake_launchers) that reaches the fake ssh's hosts and
# says what the real tool says.

set -u
source "$(dirname "${BASH_SOURCE[0]}")/test_helper.bash"

seed() {
    install_fake_ssh
    install_fake_launchers
    # Answers filed one provost after another on the one-capture-at-a-time
    # path: four at once lose a capture now and then where mkdir is uutils
    # coreutils before 0.11 (CI's provost 2.1.0 job, QD-022), and this suite
    # files dozens of runs.  What it tests is how hosts are reached, not
    # filing; QD-022 fixes the race itself.
    export QD_FILE_JOBS=1
    for h in node01 node02 node03; do fake_host "$h"; done
    echo "6.1.0-18" > "$FAKE_ROOT/node01/kernel"
    echo "6.1.0-13" > "$FAKE_ROOT/node03/kernel"
    fake_host_unreachable node04
}

# one host answers, one fails (no kernel file), one answers too, one is
# not reached
KERNEL='cat kernel'

# a binnacle with only skew in it, for a script probe: sent on stdin to
# `python3 -` on each host, as the real one is
stand_in_binnacle() {
    mkdir -p stand/binnacle
    : > stand/binnacle/__init__.py
    printf '%s\n' 'import sys' 'print("check,result")' \
        'print("clock,%s" % ("ok" if "--csv" in sys.argv else "no-csv"))' \
        > stand/binnacle/skew.py
    export PYTHONPATH="$PWD/stand"
}

srun_calls() { grep -c '^srun ' "$FAKE_SSH_LOG" || true; }

# One host's answer in a run, exactly as provost was given it, less its
# '#%' prologue line: from the store's own file, found by the host (every
# provost has it; `provost source cNNNN` is newer than 2.1.0, and on its
# one-at-a-time path a run's captures need not be numbered in host order)
answer_of() {
    local cap
    cap="$(qd show "$1" --cols host,capture --format csv |
        awk -F, -v h="$2" '$1 == h { print $2 }')"
    [ -n "$cap" ] || fail "no capture for $2 in $1"
    tail -n +2 "$QD_STORE/captures/$cap/output.txt"
}

# -- srun -----------------------------------------------------------------------

t_srun_runs_on_the_allocation() {
    seed
    in_allocation 4242 'node[01-04]' batch
    # a hosts.txt in the directory is not the fleet inside an allocation
    echo "elsewhere" > hosts.txt
    qd_rc run --via srun -q -- "$KERNEL"
    assert_status "$QD_RC" 1
    assert_contains "$(cat "$FAKE_SSH_LOG")" "scontrol node[01-04]"
    assert_eq "$(srun_calls)" "4"
    assert_not_contains "$(cat "$FAKE_SSH_LOG")" "elsewhere"
    csv="$(qd show latest --cols host,status,rc,error,A --format csv)"
    assert_contains "$csv" "node01,ok,0,,6.1.0-18"
    # the command's own error, not srun's "task 0: Exited with exit code 1"
    assert_contains "$csv" "node02,failed,1,cat: kernel: No such file or directory,"
    assert_contains "$csv" "node03,ok,0,,6.1.0-13"
    assert_contains "$csv" "node04,unreachable,255,srun: error: Unable to create step"
    assert_not_contains "$csv" "Exited with exit code"
    # the job on every answer, as provost's manifest key -- in its
    # prologue, and a column of every row where provost makes context
    # columns (with batch) -- and the run says how it reached them
    assert_contains "$(pv source 1)" "sched.job=4242 sched.partition=batch"
    assert_contains "$(pv source 2)" "sched.job=4242 sched.partition=batch"
    if has_batch; then
        ds="$(qd show ds:cat --cols host,sched.job,sched.partition --format csv)"
        assert_contains "$ds" "node01,4242,batch"
        assert_contains "$ds" "node03,4242,batch"
    fi
    assert_contains "$(qd log latest)" "via       srun, job 4242"
    runs="$(qd show ds:qd.runs --cols via,sched_job --format csv)"
    assert_contains "$runs" "srun,4242"
    # and the evidence package's record of the run says so too
    qd_rc report latest --out rep > /dev/null
    assert_contains "$(cat rep/summary.md)" "- **via**: srun, job 4242"
}

t_srun_needs_an_allocation() {
    seed
    qd_rc run --via srun -S node01 -- uptime 2> err
    assert_status "$QD_RC" 2
    assert_contains "$(cat err)" "SLURM_JOB_ID is not set, and qd does not ask for one"
    assert_eq "$(srun_calls)" "0"
}

t_srun_hosts_given_narrow_the_allocation() {
    seed
    in_allocation 4242 'node[01-04]'
    qd_rc run --via srun -S node01,node03 -q -- "$KERNEL"
    assert_status "$QD_RC" 0
    assert_eq "$(srun_calls)" "2"
    assert_not_contains "$(cat "$FAKE_SSH_LOG")" "scontrol"
    qd_rc run --via srun --first 1 -q -- "$KERNEL"
    assert_eq "$(qd show latest --cols host --format csv | tail -n +2)" "node01"
    # a port is ssh's: srun names a node
    qd_rc run --via srun -S node01:2222 -- uptime 2> err
    assert_status "$QD_RC" 2
    assert_contains "$(cat err)" "has a port (2222)"
}

# shellcheck disable=SC2016  # expanded on the far side, not here
t_srun_pushes_through_the_step_and_cleans_up() {
    seed
    in_allocation 4242 'node[01-03]'
    printf '#!/bin/sh\necho "args: $*"\n' > probe.sh
    qd_rc run --via srun --script probe.sh --remote-dir rd -q -- hello there
    assert_status "$QD_RC" 0
    assert_contains "$(qd show latest --format csv)" "node02,ok"
    assert_contains "$(pv source 1)" "args: hello there"
    # made, copied, run and removed: nothing left, rd included (qd made it)
    for h in node01 node02 node03; do assert_no_file "$FAKE_ROOT/$h/rd"; done
    # each host: the directory, the file (with its chmod), the run, the
    # cleanup -- one step each
    assert_eq "$(srun_calls)" "12"
}

# shellcheck disable=SC2016  # expanded on the far side, not here
t_srun_a_timeout_is_a_timeout() {
    seed
    in_allocation 4242 'node[01-03]'
    qd_rc run --via srun --timeout 1 -q -- \
        'if [ "$FAKE_HOST" = node02 ]; then sleep 8; fi; echo hi'
    assert_status "$QD_RC" 1
    csv="$(qd show latest --cols host,status,rc --format csv)"
    assert_contains "$csv" "node01,ok,0"
    assert_contains "$csv" "node02,timeout,124"
    assert_contains "$csv" "node03,ok,0"
}

# -- pdsh and clush -----------------------------------------------------------

# The same command through ssh and through pdsh (or clush): the same table,
# host for host -- answers, failures, a host not reached, its error and
# stderr, blank lines and a last line with no newline.
# shellcheck disable=SC2016  # expanded on the far side, not here
same_as_ssh() {
    local via="$1"
    seed
    printf 'node01 rack=r1\nnode02 rack=r1\nnode03 rack=r2\nnode04 rack=r2\n' \
        > hosts.txt
    printf 'k: v\n\nlast: line' > "$FAKE_ROOT/node03/out.txt"
    local cmd='case $FAKE_HOST in node02) echo "no luck" >&2; exit 3;;
        node03) cat out.txt;; *) cat kernel;; esac'
    qdf_rc run -s hosts.txt --name same -q -- "$cmd"
    assert_status "$QD_RC" 1
    qd_rc run -s hosts.txt --via "$via" --name same -q -- "$cmd"
    assert_status "$QD_RC" 1
    assert_eq "$(grep -c "^$via " "$FAKE_SSH_LOG")" "1"
    # all but duration_s and capture, which differ run to run
    a="$(qd show latest~1 --format csv | cut -d, -f1-4,6,8-)"
    b="$(qd show latest --format csv | cut -d, -f1-4,6,8-)"
    assert_contains "$a" "host,rack,status,rc,error,dataset,A,k,last"
    assert_eq "$b" "$a"
    a="$(qd show latest~1:hosts --cols host,status,rc,error,stderr,bytes --format csv)"
    b="$(qd show latest:hosts --cols host,status,rc,error,stderr,bytes --format csv)"
    assert_eq "$b" "$a"
    assert_contains "$a" "node04,unreachable,255,ssh: connect to host node04"
    assert_contains "$a" "node02,failed,3,no luck"
    # each host's answer exactly as ssh brought it back: node03's blank
    # line and unended last line included
    for h in node01 node03; do
        assert_eq "$(answer_of latest "$h" | od -c)" \
            "$(answer_of latest~1 "$h" | od -c)"
    done
    assert_contains "$(answer_of latest node01)" "6.1.0-18"
    assert_contains "$(answer_of latest node03)" "last: line"
    assert_contains "$(qd show ds:qd.runs --cols via --format csv)" "$via"
    qd_rc report latest --out rep > /dev/null
    assert_contains "$(cat rep/summary.md)" "- **via**: $via"
    qd_rc report latest~1 --out rep-ssh > /dev/null
    assert_not_contains "$(cat rep-ssh/summary.md)" "**via**"
}

t_pdsh_gives_the_same_dataset_as_ssh() { same_as_ssh pdsh; }
t_clush_gives_the_same_dataset_as_ssh() { same_as_ssh clush; }

# shellcheck disable=SC2016  # expanded on the far side, not here
t_pdsh_keeps_each_hosts_own_exit_status() {
    seed
    # pdsh does not say a host's status; the line qd adds after the command
    # does -- an `exit` in the command included, and 255 from the command
    # is a host that answered, not one that was not reached
    qd_rc run --via pdsh -S 'node[01-03]' -q -- \
        'case $FAKE_HOST in node01) exit 255;; node02) exit 7;; esac; echo ok'
    assert_status "$QD_RC" 1
    csv="$(qd show latest --cols host,status,rc --format csv)"
    assert_contains "$csv" "node01,failed,255"
    assert_contains "$csv" "node02,failed,7"
    assert_contains "$csv" "node03,ok,0"
}

# shellcheck disable=SC2016  # expanded on the far side, not here
t_pdsh_pushes_by_pdcp_and_cleans_up() {
    seed
    touch "$FAKE_ROOT/node03/.nopdcp"
    printf '#!/bin/sh\necho "args: $*"\n' > probe.sh
    qd_rc run --via pdsh -S 'node[01-04]' --script probe.sh --remote-dir rd \
        -q -- hello
    assert_status "$QD_RC" 1
    csv="$(qd show latest:hosts --cols host,status,error --format csv)"
    assert_contains "$csv" "node01,ok,"
    assert_contains "$csv" "node02,ok,"
    # a host without pdcp is a push that failed, and why
    assert_contains "$csv" "node03,push-failed,bash: pdcp: command not found"
    assert_contains "$csv" "node04,unreachable,"
    assert_contains "$(pv source 1)" "args: hello"
    for h in node01 node02 node03; do assert_no_file "$FAKE_ROOT/$h/rd"; done
    # one call each: the directory, the copy, the check, the run, cleanup
    assert_eq "$(grep -c '^pdsh ' "$FAKE_SSH_LOG")" "4"
    assert_eq "$(grep -c '^pdcp ' "$FAKE_SSH_LOG")" "1"
}

t_clush_pushes_by_copy() {
    seed
    echo payload > payload.txt
    qd_rc run --via clush -S 'node[01-03]' --push payload.txt --remote-dir rd \
        -q -- cat payload.txt
    assert_status "$QD_RC" 0
    assert_contains "$(grep '^clush ' "$FAKE_SSH_LOG")" "--copy"
    assert_contains "$(pv source 1)" "payload"
    for h in node01 node02 node03; do assert_no_file "$FAKE_ROOT/$h/rd"; done
}

# shellcheck disable=SC2016  # expanded on the far side, not here
t_pdsh_a_timeout_is_a_timeout() {
    seed
    qd_rc run --via pdsh -S 'node[01-03]' --timeout 1 -q -- \
        'if [ "$FAKE_HOST" = node02 ]; then sleep 8; fi; echo hi'
    assert_status "$QD_RC" 1
    csv="$(qd show latest --cols host,status,rc --format csv)"
    assert_contains "$csv" "node01,ok,0"
    assert_contains "$csv" "node02,timeout,124"
    assert_contains "$csv" "node03,ok,0"
}

# clush says the hosts that timed out in one line, as a node set
# shellcheck disable=SC2016  # expanded on the far side, not here
t_clush_a_timeout_names_a_node_set() {
    seed
    qd_rc run --via clush -S 'node[01-03]' --timeout 1 -q -- \
        'if [ "$FAKE_HOST" != node01 ]; then sleep 8; fi; echo hi'
    assert_status "$QD_RC" 1
    csv="$(qd show latest --cols host,status,rc --format csv)"
    assert_contains "$csv" "node01,ok,0"
    assert_contains "$csv" "node02,timeout,124"
    assert_contains "$csv" "node03,timeout,124"
}

# --rate spaces hosts out, which one call for them all cannot: each host
# is a call of its own then
t_pdsh_with_rate_calls_per_host() {
    seed
    qd_rc run --via pdsh -S 'node[01-03]' --rate 50/s -q -- "$KERNEL"
    assert_eq "$(grep -c '^pdsh ' "$FAKE_SSH_LOG")" "3"
    assert_contains "$(qd show latest --cols host,status --format csv)" "node02,failed"
}

t_passes_through_pdsh() {
    seed
    qd_rc run --via pdsh -S 'node01,node03' --count 2 --every 0.2 -q -- "$KERNEL"
    assert_status "$QD_RC" 0
    assert_eq "$(grep -c '^pdsh ' "$FAKE_SSH_LOG")" "2"
    assert_eq "$(qd show latest --cols host,pass --format csv | tail -n +2 | wc -l | tr -d ' ')" "4"
}

t_pdsh_refuses_what_it_cannot_tell_apart() {
    seed
    qd_rc run --via pdsh -S node01:2222 -- uptime 2> err
    assert_status "$QD_RC" 2
    assert_contains "$(cat err)" "cannot give one per host"
    qd_rc run --via pdsh -S 'a=node01,b=node01' -- uptime 2> err
    assert_status "$QD_RC" 2
    assert_contains "$(cat err)" "could not be told apart"
    assert_eq "$(grep -c '^pdsh ' "$FAKE_SSH_LOG")" "0"
}

# srun's sched.job, like a host attribute, is a column of the dataset that
# other runs in it did not carry: each run still reads as its own, with no
# record number shown and key: value answers one row per host
t_runs_with_other_keys_share_a_dataset() {
    seed
    in_allocation 4242 'node[01-03]'
    printf 'node01 rack=r1\nnode03 rack=r2\n' > hosts.txt
    kv='printf "os: Linux\nmtu: 1500\n"'
    qdf run -s hosts.txt --name kv -q -- "$kv" > /dev/null
    qd run --via srun -S node01,node03 --name kv -q -- "$kv" > /dev/null
    assert_eq "$(qd show latest --format csv | head -n 1)" \
        "host,status,rc,duration_s,error,capture,os,mtu"
    assert_eq "$(qd show latest --format csv | tail -n +2 | wc -l | tr -d ' ')" "2"
    qdf run -S node01,node03 --name kv -q -- "$kv" > /dev/null
    assert_eq "$(qd show latest --format csv | head -n 1)" \
        "host,status,rc,duration_s,error,capture,os,mtu"
    qdf run -s hosts.txt --name k2 -q -- "$KERNEL" > /dev/null
    qdf run -S node01,node03 --name k2 -q -- "$KERNEL" > /dev/null
    assert_eq "$(qd show latest --format csv | head -n 1)" \
        "host,status,rc,duration_s,error,capture,A"
}

# -- probes, every launcher ------------------------------------------------------

t_probes_through_every_launcher() {
    seed
    stand_in_binnacle
    in_allocation 4242 'node[01-03]'
    for via in ssh srun pdsh clush; do
        : > "$FAKE_SSH_LOG"
        # a script probe (on stdin), and two command probes run together
        qd_rc probe skew --via "$via" --ssh "$FAKE_BIN/ssh" \
            -S 'node[01-03]' --remote-dir rd -q
        assert_status "$QD_RC" 0
        assert_eq "$(qd show latest --cols host,check,result --format csv | tail -n +2)" \
            "$(printf 'node01,clock,ok\nnode02,clock,ok\nnode03,clock,ok')"
        qd_rc probe os mounts --via "$via" --ssh "$FAKE_BIN/ssh" \
            -S 'node[01-03]' -q
        assert_status "$QD_RC" 0
        assert_contains "$(qd show os --cols host,kernel --format csv)" "node02,"
        for h in node01 node02 node03; do assert_no_file "$FAKE_ROOT/$h/rd"; done
        if [ "$via" != ssh ]; then
            assert_eq "$(ssh_calls)" "0"
        fi
    done
}

t_a_tool_probe_says_it_uses_ssh() {
    seed
    printf '#!/bin/sh\necho "host,ok"\n' > "$FAKE_BIN/reachable"
    chmod +x "$FAKE_BIN/reachable"
    QD_REACHABLE="$FAKE_BIN/reachable" qd_rc probe reach --via pdsh \
        -S node01 -q > out 2> err
    assert_contains "$(cat err)" "--via pdsh does not apply to it"
}

# -- what is said before anything runs ------------------------------------------

t_dry_run_through_each_launcher() {
    seed
    in_allocation 4242 'node[01-02]'
    out="$(qd run --via srun --dry-run -- uptime)"
    assert_eq "$out" "$(printf '%s\n%s' \
        'srun --overlap -N1 -n1 -w node01 sh -c uptime' \
        'srun --overlap -N1 -n1 -w node02 sh -c uptime')"
    out="$(qd run --via pdsh -S 'node[01-03]' -j 2 --dry-run -- uptime)"
    assert_contains "$out" "pdsh -f 2 -t 8 -u 60 -w node01,node02,node03 '(eval uptime);"
    assert_eq "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" "1"
    out="$(qd run --via clush -S node01 --dry-run -- uptime)"
    assert_contains "$out" "clush -f 1 -t 8 -u 60 -w node01"
    assert_eq "$(srun_calls)" "0"
    assert_eq "$(grep -c '^pdsh \|^clush ' "$FAKE_SSH_LOG")" "0"
}

t_a_launcher_not_here_is_refused() {
    seed
    nop="$(path_without pdsh pdcp clush srun)"
    PATH="$nop" qd_rc run --via pdsh -S node01 -- uptime 2> err
    assert_status "$QD_RC" 2
    assert_contains "$(cat err)" "cannot run pdsh: not found (--via pdsh)"
    qd_rc run --via rsh -S node01 -- uptime 2> err
    assert_status "$QD_RC" 2
    assert_contains "$(cat err)" "not a launcher qd knows"
    QD_VIA=pdsh qd run -S node01 --dry-run -- uptime > out
    assert_contains "$(cat out)" "pdsh -f 1"
}

t_doctor_checks_the_launcher() {
    seed
    qd_rc doctor > out
    assert_contains "$(cat out)" "launcher  ssh, scp for pushed files"
    assert_contains "$(cat out)" "--via pdsh: every host in one call"
    qd_rc doctor --via srun > out
    assert_status "$QD_RC" 1
    assert_contains "$(cat out)" "not inside a Slurm allocation"
    in_allocation 4242 'node[01-04]' batch
    qd_rc doctor --via srun > out
    assert_status "$QD_RC" 0
    assert_contains "$(cat out)" "job 4242, partition batch, nodes node[01-04]"
    qd_rc doctor --via clush > out
    assert_status "$QD_RC" 0
    nop="$(path_without pdsh pdcp clush srun)"
    PATH="$nop" qd_rc doctor --via pdsh > out
    assert_status "$QD_RC" 1
    assert_contains "$(cat out)" "pdsh: not found here"
}

run_test "srun: the allocation's nodes, a step each, the job on each" t_srun_runs_on_the_allocation
run_test "srun: only inside an allocation"                t_srun_needs_an_allocation
run_test "srun: hosts given narrow the allocation"        t_srun_hosts_given_narrow_the_allocation
run_test "srun: --script through the step, cleaned up"    t_srun_pushes_through_the_step_and_cleans_up
run_test "srun: a timeout is a timeout"                   t_srun_a_timeout_is_a_timeout
run_test "pdsh: the same dataset as ssh"                  t_pdsh_gives_the_same_dataset_as_ssh
run_test "clush: the same dataset as ssh"                 t_clush_gives_the_same_dataset_as_ssh
run_test "pdsh: each host's own exit status"              t_pdsh_keeps_each_hosts_own_exit_status
run_test "pdsh: --script by pdcp, cleaned up"             t_pdsh_pushes_by_pdcp_and_cleans_up
run_test "clush: --push by clush --copy"                  t_clush_pushes_by_copy
run_test "pdsh: a timeout is a timeout"                   t_pdsh_a_timeout_is_a_timeout
run_test "clush: a timeout named as a node set"           t_clush_a_timeout_names_a_node_set
run_test "pdsh: --rate makes a call per host"             t_pdsh_with_rate_calls_per_host
run_test "pdsh: repeated passes"                          t_passes_through_pdsh
run_test "pdsh: ports and shared addresses refused"       t_pdsh_refuses_what_it_cannot_tell_apart
run_test "runs with other #% keys share a dataset"        t_runs_with_other_keys_share_a_dataset
run_test "probes through every launcher"                  t_probes_through_every_launcher
run_test "a tool probe says it reaches hosts by ssh"      t_a_tool_probe_says_it_uses_ssh
run_test "--dry-run through each launcher"                t_dry_run_through_each_launcher
run_test "a launcher not here, or unknown, is refused"    t_a_launcher_not_here_is_refused
run_test "doctor checks the launcher"                     t_doctor_checks_the_launcher

finish
