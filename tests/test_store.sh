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
    # whatever this provost writes: 3 since 2.2.0, 2 before it
    fmt="$(cat "$(STORES)/lab/.store_format" 2>/dev/null || echo 1)"
    assert_contains "$(cat out)" "store format $fmt"
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
    assert_contains "$(head -1 manifest.out)" " $fmt 2 "
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
    assert_contains "$(cat err)" "reads formats 1, 2, 3, 4"
    echo "not an archive" > junk.tgz
    qd_rc store import junk.tgz --as t4 2> err
    assert_contains "$(cat err)" "is not a qd store archive"
    # nothing was registered, and nothing was left half-made
    assert_not_contains "$(qd store ls)" "t1"
    assert_eq "$(find "$(STORES)" -mindepth 1 -maxdepth 1 | sed 's|.*/||' | tr '\n' ' ')" "lab "
}

# provost's store format 4 (PV-015) changed data, not layout: column 2 is
# the capture id in every row, named _capture where the data has a column
# called capture.  Made by hand, so any provost can run it.
t_a_format_4_store_reads_and_round_trips() {
    unset QD_STORE
    qd store new f4 > /dev/null
    csv a 1
    qd import a.csv --store f4 > /dev/null 2>&1
    st="$(STORES)/f4"
    cids=("$st"/captures/c*); cid="${cids[0]##*/}"
    printf '#\t_capture\tn\tv\tcapture\n900\t%s\t1\t5\tdata\n' "$cid" \
        > "$st/datasets/mixed.tsv"
    echo 4 > "$st/.store_format"
    git -C "$st" add -A
    git -C "$st" -c user.name=t -c user.email=t@t commit -qm format4
    want="capture,n,v,capture_2
$cid,1,5,data"
    assert_eq "$(qd show ds:mixed --store f4 --format csv)" "$want"
    qd store export f4 f4.tgz > out
    assert_contains "$(cat out)" "store format 4"
    qd store import f4.tgz --as f4copy > out
    assert_contains "$(cat out)" "f4copy = "
    assert_eq "$(qd show ds:mixed --store f4copy --format csv)" "$want"
    assert_eq "$(runs_in --store f4copy)" "$(runs_in --store f4)"
    # row 900 is in no provenance.tsv: made by hand, not by provost
    no_store_check "$st" "$(STORES)/f4copy"
}

# QD-031: provost's store format spec (its docs/store-format.md), what a
# reader must do.  These run on any provost; the stores are made by hand.

# py SCRIPT ARGS...: Python with this quarterdeck importable
py() { "$PY" - "$QD_DIR" "$@"; }

# A '#%' word is key=value; a value may be double-quoted to hold spaces,
# with \" and \\ inside (provost's _prologue_kv).
t_quoted_prologue_values_read_as_provost_reads_them() {
    printf '%s\n' \
        '#% cc="gcc 13.2" plain=1 quote="say \"hi\"" back="a\\b" x=1' \
        '#% open="no close here  bad=word =x _ok=y' \
        '#% tabbed="a	b" late=1 x=2' \
        '#% glued="a"b empty="" eq=a=b' > ctx.txt
    py ctx.txt > out <<'EOF'
import json, sys
sys.path.insert(0, sys.argv[1])
from quarterdeck.store import parse_context
with open(sys.argv[2]) as fh:
    print(json.dumps(parse_context(fh.read()), sort_keys=True))
EOF
    assert_eq "$(cat out)" '{"_ok": "y", "back": "a\\b", "bad": "word", "cc": "gcc 13.2", "empty": "", "eq": "a=b", "glued": "\"a\"b", "late": "1", "open": "\"no", "plain": "1", "quote": "say \"hi\"", "tabbed": "a b", "x": "2"}'
    # and provost's own reader agrees, where this provost is its script
    if [ -f "$PROVOST_CMD" ] && grep -q '^_prologue_kv () {' "$PROVOST_CMD"; then
        bash -c 'source <(sed -n "/^_prologue_kv () {/,/^}/p" "$1"); _prologue_kv "$2"' \
            _ "$PROVOST_CMD" ctx.txt | "$PY" -c '
import json, sys
d = {}
for ln in sys.stdin.read().split("\n"):
    if ln:
        k, v = ln.split("\t", 1)
        d[k] = v
print(json.dumps(d, sort_keys=True))' > theirs
        assert_eq "$(cat theirs)" "$(cat out)"
    fi
}

# A store qd made, rewritten by hand into another format: datasets/x.tsv
# with a capture column that holds data in row 2 (provost's PV-015), and
# provenance.tsv that has it right.
hand_store() {
    unset QD_STORE
    qd store new "$1" > /dev/null
    st="$(STORES)/$1"
    mkdir -p "$st/datasets"
    printf '#\tcapture\tv\n1\tc0001\t5\n2\tc9999\t6\n' > "$st/datasets/x.tsv"
    printf '#\tdataset\tcapture\n1\tx\tc0001\n2\tx\tc0002\n' > "$st/provenance.tsv"
    echo "$2" > "$st/.store_format"
    no_store_check "$st"
}

t_a_format_3_store_takes_captures_from_provenance() {
    hand_store f3 3
    assert_eq "$(qd show ds:x --store f3 --format csv)" "capture,v
c0001,5
c0002,6"
    # format 4: column 2 is the capture id in every row, read by place
    echo 4 > "$st/.store_format"
    assert_eq "$(qd show ds:x --store f3 --format csv)" "capture,v
c0001,5
c9999,6"
}

t_a_store_of_an_unknown_format_is_refused() {
    hand_store f9 9
    qd_rc show ds:x --store f9 2> err
    assert_eq "$QD_RC" 2
    assert_contains "$(cat err)" "is a store in format 9; this qd reads formats 1, 2, 3, 4"
    qd_rc log --store f9 2> err
    assert_contains "$(cat err)" "format 9"
    qd_rc store export f9 f9.tgz 2> err
    assert_contains "$(cat err)" "format 9"
    assert_no_file f9.tgz
}

# provost writes a tab in a meta.tsv value as \t and a newline as \n
t_meta_values_are_unescaped() {
    hand_store m 4
    mkdir -p "$st/captures/c0001"
    printf 'id\tc0001\ncommand\tprintf a\\tb\\nc\nrow_ids\t1-1\n' \
        > "$st/captures/c0001/meta.tsv"
    py "$st" > out <<'EOF'
import sys
sys.path.insert(0, sys.argv[1])
from quarterdeck.store import Store
print(repr(Store(sys.argv[2]).meta("c0001")["command"]))
EOF
    assert_eq "$(cat out)" "'printf a\\tb\\nc'"
}

# kept: make capture CID of store ST truncated, its whole input WHOLE kept
# beside the store by its sha256, as provost 2.15.0 on does
kept() {
    local st="$1" cid="$2" whole="$3" sha
    sha="$("$PY" -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$whole")"
    mkdir -p "$st.artifacts"
    cp "$whole" "$st.artifacts/$sha"
    chmod 444 "$st.artifacts/$sha"
    printf 'truncated\t1\nparsed_bytes\t%s\nraw_artifact\t%s\nraw_sha256\t%s\nraw_bytes\t%s\nraw_redacted\tnone\n' \
        "$(wc -c < "$st/captures/$cid/output.txt" | tr -d ' ')" \
        "$st.artifacts/$sha" "$sha" "$(wc -c < "$whole" | tr -d ' ')" \
        >> "$st/captures/$cid/meta.tsv"
    echo "$sha"
}

# label ST CID: what a raw answer is shown under, and the whole input's
# first line
label() {
    py "$1" "$2" <<'EOF'
import sys
sys.path.insert(0, sys.argv[1])
from quarterdeck.store import Store, source_label
st = Store(sys.argv[2])
print(source_label(st, sys.argv[3]))
print(st.whole_output(sys.argv[3]).splitlines()[0])
EOF
}

t_a_truncated_capture_is_marked_and_its_input_found() {
    unset QD_STORE
    qd store new big > /dev/null
    st="$(STORES)/big"
    csv a 1
    qd import a.csv --store big > /dev/null 2>&1
    cid="$(grep -l '^dataset' "$st"/captures/c*/meta.tsv | head -1)"
    cid="$(basename "$(dirname "$cid")")"
    printf 'the whole input\nhost,v\na,1\n' > whole.txt
    sha="$(kept "$st" "$cid" whole.txt)"
    git -C "$st" add -A
    git -C "$st" -c user.name=t -c user.email=t@t commit -qm truncated
    no_store_check "$st"
    label "$st" "$cid" > out
    assert_contains "$(sed -n 1p out)" "truncated: only the head provost parsed, "
    assert_contains "$(sed -n 1p out)" "the whole input is kept at "
    assert_eq "$(sed -n 2p out)" "the whole input"
    # moved with the store: found by its sha256 in STORE.artifacts
    mv "$st.artifacts" moved
    label "$st" "$cid" > out
    assert_contains "$(sed -n 1p out)" "the whole input (sha256 ${sha:0:12}) is not in "
    mv moved "$st.artifacts"
    # an archive carries it, and an import puts it beside the store
    qd store export big big.tgz > out
    assert_contains "$(cat out)" "1 kept input"
    "$PY" -c 'import json,sys,tarfile; t=tarfile.open(sys.argv[1]); m=json.load(t.extractfile(t.next())); print(m["archive_version"], sorted(m["artifacts"]), [i.name for i in t if "/artifacts/" in i.name])' big.tgz > out
    assert_eq "$(cat out)" "2 ['$sha'] ['quarterdeck-store/artifacts/$sha']"
    qd store import big.tgz --as copy > out
    assert_contains "$(cat out)" "1 truncated capture's input, kept whole beside it"
    no_store_check "$(STORES)/copy"
    assert_file_exists "$(STORES)/copy.artifacts/$sha"
    # raw_artifact names the first store's copy: gone, the copy's is found
    chmod -R u+w "$st.artifacts"; rm -rf "$st.artifacts"
    label "$(STORES)/copy" "$cid" > out
    assert_contains "$(sed -n 1p out)" "kept at "
    assert_contains "$(sed -n 1p out)" "copy.artifacts/$sha"
    # a kept input that is not what the manifest says is refused
    "$PY" - big.tgz <<'EOF'
import io, sys, tarfile
src = tarfile.open(sys.argv[1])
with tarfile.open("bad.tgz", "w:gz") as out:
    for i in src:
        data = src.extractfile(i).read() if i.isfile() else None
        if "/artifacts/" in i.name:
            data = b"changed\n"; i.size = len(data)
        out.addfile(i, io.BytesIO(data) if data is not None else None)
EOF
    qd_rc store import bad.tgz --as bad 2> err
    assert_contains "$(cat err)" "does not match its sha256"
    assert_no_file "$(STORES)/bad"
    assert_no_file "$(STORES)/bad.artifacts"
}

# The real thing, where this provost keeps inputs over its cap (2.15.0
# on; `store check` came in 2.16.0, which is what is asked)
t_provost_truncates_and_qd_reads_it() {
    if ! has_store_check; then
        echo "skipped: this provost has no store check"
        return 0
    fi
    unset QD_STORE
    qd store new real > /dev/null
    st="$(STORES)/real"
    "$PY" -c 'print("host,v"); [print("h%04d,%d" % (i, i)) for i in range(400)]' > big.csv
    PROVOST_MAX_INPUT=600 qd import big.csv --store real > /dev/null 2>&1
    f="$(grep -l '^truncated	1' "$st"/captures/c*/meta.tsv | head -1)"
    [ -n "$f" ] || fail "provost truncated nothing"
    cid="$(basename "$(dirname "$f")")"
    label "$st" "$cid" > out
    assert_contains "$(sed -n 1p out)" "truncated: only the head provost parsed"
    assert_contains "$(sed -n 1p out)" "kept at "
    qd store export real real.tgz > out
    assert_contains "$(cat out)" "1 kept input"
    qd store import real.tgz --as realcopy > /dev/null
    sha="$(sed -n 's/^raw_sha256	//p' "$f")"
    assert_file_exists "$(STORES)/realcopy.artifacts/$sha"
}

run_test "a fresh machine: warned, then default"    t_a_fresh_machine_warns_then_registers_default
run_test "a store's name, in every command"         t_names_are_used_by_every_command
run_test "a path still works"                       t_a_path_still_works
run_test "rename moves a store qd made"             t_rename_moves_a_store_qd_made
run_test "rm forgets, --delete deletes"             t_rm_forgets_or_deletes
run_test "export and import: a round trip"          t_export_and_import_round_trip
run_test "export refuses while a run files"         t_export_refuses_while_a_run_files
run_test "import checks what it is given"           t_import_checks_what_it_is_given
run_test "a format-4 store reads and round-trips"   t_a_format_4_store_reads_and_round_trips
run_test "quoted prologue values, as provost reads"  t_quoted_prologue_values_read_as_provost_reads_them
run_test "format 3: a row's capture from provenance" t_a_format_3_store_takes_captures_from_provenance
run_test "a store of an unknown format is refused"  t_a_store_of_an_unknown_format_is_refused
run_test "meta.tsv values are unescaped"            t_meta_values_are_unescaped
run_test "a truncated capture: marked, input found" t_a_truncated_capture_is_marked_and_its_input_found
run_test "provost truncates, qd reads it"           t_provost_truncates_and_qd_reads_it
finish
