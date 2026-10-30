#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Martin J. Gallagher

# qd store: named stores -- new, ls, use, rename, rm, export, import -- and
# which store a command uses: --store, QD_STORE, provost's explicit choice,
# the active store, provost's default.  The helper gives each case its own
# config (XDG_CONFIG_HOME), data directory and PROVOST_HOME.

set -u
source "$(dirname "${BASH_SOURCE[0]}")/test_helper.bash"

STORES() { echo "$XDG_DATA_HOME/quarterdeck/stores"; }

csv() { printf 'host,v\n%s,%s\n' "$1" "$2" > "$1.csv"; }

# a qd store's log, as its run names
runs_in() { qd log "$@" 2>/dev/null | tail -n +2 | awk '{print $NF}' | tr '\n' ' '; }

t_a_fresh_machine_warns_then_registers_default() {
    unset QD_STORE
    csv a 1
    qd import a.csv --name first > out 2> err
    assert_contains "$(cat err)" "no store is active: using provost's default"
    assert_dir_exists "$PROVOST_HOME/datasets"
    # found once it is there: registered as default, and active
    out="$(qd store ls)"
    assert_contains "$out" "*  default"
    qd log > out 2> err
    assert_not_contains "$(cat err)" "no store is active"
    assert_contains "$(cat out)" "a.csv"
    # forgotten, it stays forgotten
    qd store rm default > /dev/null
    assert_contains "$(qd store ls 2>/dev/null)" "0 named stores"
}

t_names_are_used_by_every_command() {
    unset QD_STORE
    qd store new lab > out
    assert_contains "$(cat out)" "lab = "
    assert_dir_exists "$(STORES)/lab"
    qd store new other > /dev/null
    qd store use lab > /dev/null
    csv a 1; csv b 2
    qd import a.csv --name in_lab > /dev/null 2>&1
    qd import b.csv --name in_other --store other > /dev/null 2>&1
    assert_contains "$(runs_in)" "a.csv"
    assert_not_contains "$(runs_in)" "b.csv"
    assert_contains "$(runs_in --store other)" "b.csv"
    assert_contains "$(qd show latest --store other --format csv)" "b,2"
    # --store, then QD_STORE, then the active store
    assert_contains "$(QD_STORE=other runs_in)" "b.csv"
    assert_contains "$(QD_STORE=other runs_in --store lab)" "a.csv"
    # PROVOST_WORKSPACE is provost's explicit choice: before the active one
    assert_contains "$(PROVOST_WORKSPACE="$(STORES)/other" runs_in)" "b.csv"
    assert_contains "$(qd store ls)" "*  lab"
    qd_rc store new lab 2> err
    assert_contains "$(cat err)" "there is a store named lab already"
    qd_rc store new 'a/b' 2> err
    assert_contains "$(cat err)" "is not one"
}

t_a_path_still_works() {
    unset QD_STORE
    csv a 1
    qd import a.csv --store ./mine > /dev/null 2>&1
    assert_contains "$(runs_in --store ./mine)" "a.csv"
    assert_contains "$(runs_in --store "$PWD/mine")" "a.csv"
    # a bare directory name, as scripts gave one before stores had names
    assert_contains "$(runs_in --store mine)" "a.csv"
    assert_contains "$(QD_STORE=mine runs_in)" "a.csv"
    qd_rc log --store nosuch 2> err
    assert_status "$QD_RC" 2
    assert_contains "$(cat err)" "no store named 'nosuch'"
}

t_rename_moves_a_store_qd_made() {
    unset QD_STORE
    qd store new lab > /dev/null
    qd store use lab > /dev/null
    csv a 1
    qd import a.csv > /dev/null 2>&1
    qd store rename lab bench > out
    assert_contains "$(cat out)" "lab is now bench"
    assert_no_file "$(STORES)/lab"
    assert_dir_exists "$(STORES)/bench/datasets"
    assert_no_file "$(STORES)/bench/.lock"
    assert_contains "$(qd store ls)" "*  bench"
    assert_contains "$(runs_in)" "a.csv"
    # one registered by --path stays where it was put
    qd store new kept --path "$PWD/elsewhere" > /dev/null
    qd store rename kept moved > /dev/null
    assert_contains "$(qd store ls)" "elsewhere"
    assert_dir_exists "$PWD/elsewhere"
}

t_rm_forgets_or_deletes() {
    unset QD_STORE
    qd store new lab > /dev/null
    qd store new gone > /dev/null
    qd store use gone > /dev/null
    csv a 1
    qd import a.csv --store lab > /dev/null 2>&1
    qd import a.csv --store gone > /dev/null 2>&1
    qd store rm lab > out
    assert_contains "$(cat out)" "its files stay"
    assert_dir_exists "$(STORES)/lab/datasets"
    qd store rm gone --delete > out
    assert_contains "$(cat out)" "no store is active now"
    assert_no_file "$(STORES)/gone"
    # never deletes what is not a store
    mkdir notstore && echo precious > notstore/f
    qd store new odd --path "$PWD/empty" > /dev/null
    rmdir empty && cp -r notstore empty
    qd_rc store rm odd --delete 2> err
    assert_contains "$(cat err)" "not a provost store"
    assert_eq "$(cat empty/f)" "precious"
}

t_export_and_import_round_trip() {
    unset QD_STORE
    qd store new lab > /dev/null
    csv a 1; csv b 2
    qd import a.csv --store lab > /dev/null 2>&1
    qd import b.csv --store lab > /dev/null 2>&1
    qd store export lab lab.tgz > out
    assert_contains "$(cat out)" "2 runs"
    assert_contains "$(cat out)" "store format 3"
    # the manifest first: versions, store format, run count, checksums
    "$PY" - lab.tgz > manifest.out <<'EOF'
import json, sys, tarfile
t = tarfile.open(sys.argv[1])
m = json.load(t.extractfile(t.next()))
print(m["kind"], m["qd"], m["store_format"], m["runs"], len(m["files"]))
print(sorted(m["files"])[0], m["files"][sorted(m["files"])[0]]["sha256"][:8])
print(any(f.startswith(".git/") for f in m["files"]),
      any(f.startswith("captures/") and f.endswith("/output.txt") for f in m["files"]))
EOF
    assert_contains "$(head -1 manifest.out)" "quarterdeck store"
    assert_contains "$(head -1 manifest.out)" " 3 2 "
    # the full history, and the raw answers
    assert_eq "$(sed -n 3p manifest.out)" "True True"
    qd_rc store import lab.tgz 2> err
    assert_contains "$(cat err)" "there is a store named lab already"
    qd store import lab.tgz --as copy > out
    assert_contains "$(cat out)" "copy = "
    assert_eq "$(runs_in --store copy)" "$(runs_in --store lab)"
    assert_eq "$(git -C "$(STORES)/copy" rev-list --count HEAD)" \
        "$(git -C "$(STORES)/lab" rev-list --count HEAD)"
    assert_eq "$(git -C "$(STORES)/copy" status --porcelain)" ""
    # the active store's, with no name given
    qd store use copy > /dev/null
    qd store export again.tgz > out
    assert_contains "$(cat out)" "copy -> again.tgz"
}

# a run filing holds provost's store lock: the export waits for no one
t_export_refuses_while_a_run_files() {
    unset QD_STORE
    qd store new lab > /dev/null
    csv a 1
    qd import a.csv --store lab > /dev/null 2>&1
    mkdir "$(STORES)/lab/.lock"
    printf 'otherhost\t4242\t0\t1\n' > "$(STORES)/lab/.lock/owner"
    qd_rc store export lab lab.tgz 2> err
    assert_status "$QD_RC" 2
    assert_contains "$(cat err)" "a run is filing"
    assert_contains "$(cat err)" "otherhost 4242"
    assert_no_file lab.tgz
    # the run's lock is the run's: left as it was
    assert_eq "$(cut -f2 "$(STORES)/lab/.lock/owner")" "4242"
    rm -rf "$(STORES)/lab/.lock"
    qd store export lab lab.tgz > /dev/null
    # and the export's own lock is gone when it is done
    assert_no_file "$(STORES)/lab/.lock"
}

# an archive is checked whole before a store is given a name
t_import_checks_what_it_is_given() {
    unset QD_STORE
    qd store new lab > /dev/null
    csv a 1
    qd import a.csv --store lab > /dev/null 2>&1
    qd store export lab lab.tgz > /dev/null
    # rewritten: one file changed, one member added, the format moved on
    "$PY" - lab.tgz <<'EOF'
import copy, io, json, sys, tarfile
src = tarfile.open(sys.argv[1])
members = [(i, src.extractfile(i).read() if i.isfile() else None) for i in src]
def write(path, change=None, extra=None, manifest=None):
    with tarfile.open(path, "w:gz") as out:
        for i, data in members:
            i = copy.copy(i)
            if i.name.endswith("manifest.json") and manifest:
                m = json.loads(data); manifest(m); data = json.dumps(m).encode()
                i.size = len(data)
            if change and i.name.endswith(change):
                data = data + b"tampered\n"; i.size = len(data)
            out.addfile(i, io.BytesIO(data) if data is not None else None)
        if extra:
            i = tarfile.TarInfo(extra); i.size = 4
            out.addfile(i, io.BytesIO(b"evil"))
write("tampered.tgz", change="datasets/qd.runs.tsv")
write("escape.tgz", extra="quarterdeck-store/store/../../escaped")
write("newer.tgz", manifest=lambda m: m.update(store_format=99))
EOF
    qd_rc store import tampered.tgz --as t1 2> err
    assert_contains "$(cat err)" "does not match its checksum"
    qd_rc store import escape.tgz --as t2 2> err
    assert_contains "$(cat err)" "which no qd export writes"
    assert_no_file "$(STORES)/../escaped"
    qd_rc store import newer.tgz --as t3 2> err
    assert_contains "$(cat err)" "format 99"
    echo "not an archive" > junk.tgz
    qd_rc store import junk.tgz --as t4 2> err
    assert_contains "$(cat err)" "is not a qd store archive"
    # nothing was registered, and nothing was left half-made
    assert_not_contains "$(qd store ls)" "t1"
    assert_eq "$(find "$(STORES)" -mindepth 1 -maxdepth 1 -printf '%f ')" "lab "
}

run_test "a fresh machine: warned, then default"    t_a_fresh_machine_warns_then_registers_default
run_test "a store's name, in every command"         t_names_are_used_by_every_command
run_test "a path still works"                       t_a_path_still_works
run_test "rename moves a store qd made"             t_rename_moves_a_store_qd_made
run_test "rm forgets, --delete deletes"             t_rm_forgets_or_deletes
run_test "export and import: a round trip"          t_export_and_import_round_trip
run_test "export refuses while a run files"         t_export_refuses_while_a_run_files
run_test "import checks what it is given"           t_import_checks_what_it_is_given
finish
