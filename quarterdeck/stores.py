# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Martin J. Gallagher
"""Named stores: which provost store qd files into and reads.

    qd store new lab           ~/.local/share/quarterdeck/stores/lab
    qd store use lab           remembered in ~/.config/quarterdeck/config.json
    qd log --store lab         a store's name, or a directory as before

Which store a command uses, the first of these that applies:

    --store NAME|DIR           this command
    QD_STORE=NAME|DIR          this shell
    PROVOST_WORKSPACE, or the  provost's own explicit choices, so qd and
      controlled directory     provost never disagree about where you are
      you are in
    the active store           qd store use NAME
    provost's default          PROVOST_HOME or ~/.provost, with a warning

provost's default store, once it exists, is registered as `default`, and
made the active store if none is: a machine that used qd before stores
keeps working without a step.

An export is one gzipped tar: a manifest first (qd's and provost's
versions, the store format, the run count, a sha256 per file), then the
store whole -- its git history, the raw answers under captures/, the
datasets.  It is written under provost's own store lock, so no run files
into the store while it is read.  An import checks all of that before the
store is given a name, and never merges into one that has one.
"""

import hashlib
import io
import json
import os
import re
import shutil
import tarfile
import tempfile
import time

from . import VERSION
from .common import QdError, die, env, warn
from . import store as storemod

NAME_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$")
ARCHIVE_KIND = "quarterdeck store"
ARCHIVE_VERSION = 1
TOP = "quarterdeck-store"
# the store formats qd reads (store.py): provost moves 1 and 2 up to 3 the
# next time it files into the store
STORE_FORMATS = (1, 2, 3)
# provost's runtime files, never part of a store's content: its .gitignore
SKIP = re.compile(r"^(\.lock(\..*)?(/.*)?|datasets/\.(recon|stage|rm|rmprov)"
                  r"\..*|captures/[^/]+/\.meta\.tmp|context/[^/]*\.tmp)$")


# ---------------------------------------------------------------------------
# where things are
# ---------------------------------------------------------------------------

def config_path():
    base = os.environ.get("XDG_CONFIG_HOME") or os.path.expanduser(
        "~/.config")
    return os.path.join(base, "quarterdeck", "config.json")


def data_root():
    """Where a store made by `qd store new NAME` lives, as NAME."""
    base = os.environ.get("XDG_DATA_HOME") or os.path.expanduser(
        "~/.local/share")
    return os.path.join(base, "quarterdeck", "stores")


def provost_home():
    """provost's default store: what it files into with nothing set."""
    return os.path.abspath(os.path.expanduser(
        os.environ.get("PROVOST_HOME") or "~/.provost"))


def is_store(path):
    return os.path.isdir(os.path.join(path, "datasets")) or os.path.isfile(
        os.path.join(path, ".store_format"))


def check_name(name):
    if not name or not NAME_RE.match(name) or ".." in name:
        die("a store's name is letters, digits, '.', '_' and '-', starting "
            "with a letter or digit: %r is not one" % (name or ""))
    return name


# ---------------------------------------------------------------------------
# the registry
# ---------------------------------------------------------------------------

def load():
    """{"active": NAME or None, "stores": {NAME: PATH}, ...} -- with
    provost's default store registered as `default` the first time it is
    found (and made active if nothing is): once, so that an `rm` sticks."""
    p = config_path()
    cfg = {}
    if os.path.isfile(p):
        try:
            with io.open(p, encoding="utf-8") as fh:
                cfg = json.load(fh)
        except (OSError, ValueError) as exc:
            die("cannot read qd's config %s: %s (fix or remove it)"
                % (p, exc))
        if not isinstance(cfg, dict):
            die("qd's config %s is not a JSON object" % p)
    cfg.setdefault("stores", {})
    cfg.setdefault("active", None)
    if not cfg.get("default_registered"):
        home = provost_home()
        if is_store(home):
            if home not in cfg["stores"].values() \
                    and "default" not in cfg["stores"]:
                cfg["stores"]["default"] = home
                if not cfg["active"]:
                    cfg["active"] = "default"
            cfg["default_registered"] = True
            try:
                save(cfg)
            except QdError:
                # a config qd cannot write is no reason to refuse to read
                # a store: it is registered next time
                pass
    return cfg


def save(cfg):
    """Written whole and renamed into place: a reader never sees half."""
    p = config_path()
    d = os.path.dirname(p)
    try:
        os.makedirs(d, exist_ok=True)
        fd, tmp = tempfile.mkstemp(prefix=".config.", dir=d)
        with os.fdopen(fd, "w") as fh:
            json.dump(cfg, fh, indent=2, sort_keys=True)
            fh.write("\n")
        os.replace(tmp, p)
    except OSError as exc:
        die("cannot write qd's config %s: %s" % (p, exc))


def looks_like_path(spec):
    return os.sep in spec or "/" in spec or spec.startswith(("~", "."))


def resolve(spec, cfg=None):
    """A --store or QD_STORE value: a registered name, else a directory.
    -> (path, name or None)"""
    if looks_like_path(spec):
        return os.path.abspath(os.path.expanduser(spec)), None
    cfg = cfg if cfg is not None else load()
    if spec in cfg["stores"]:
        return cfg["stores"][spec], spec
    if os.path.isdir(spec):
        # a bare directory name, as scripts gave it before stores had names
        return os.path.abspath(spec), None
    die("no store named %r (qd store ls lists them; qd store new %s makes "
        "one; ./%s for a directory of that name)" % (spec, spec, spec))


_warned = []


def choose(cli_value=None, quiet=False):
    """The store a command uses, and how it was chosen. -> (path, name, how)
    """
    if cli_value:
        path, name = resolve(cli_value)
        return path, name, "--store"
    v = env("STORE")
    if v:
        path, name = resolve(v)
        return path, name, "QD_STORE"
    explicit = storemod.provost_explicit()
    if explicit:
        return explicit, name_of(explicit), "provost"
    cfg = load()
    active = cfg.get("active")
    if active and active in cfg["stores"]:
        return cfg["stores"][active], active, "active"
    home = provost_home()
    if not quiet and not _warned:
        _warned.append(1)
        warn("no store is active: using provost's default, %s (qd store use "
             "NAME picks one; qd store ls lists them)" % storemod.tilde(home))
    return home, name_of(home, cfg), "default"


def name_of(path, cfg=None):
    cfg = cfg if cfg is not None else load()
    for n, p in cfg["stores"].items():
        if os.path.abspath(p) == os.path.abspath(path):
            return n
    return None


def registered(name, cfg):
    if name not in cfg["stores"]:
        die("no store named %r (qd store ls lists them)" % name)
    return cfg["stores"][name]


def run_count(path):
    """How many runs a store holds: 0 for a store nothing has been filed
    into yet, None for a path that is not there or not a store."""
    if not is_store(path):
        return 0 if os.path.isdir(path) and not os.listdir(path) else None
    try:
        return len(storemod.Store(path).run_rows())
    except Exception:       # a store qd cannot read is shown, not fatal
        return None


# ---------------------------------------------------------------------------
# provost's store lock, held by qd
# ---------------------------------------------------------------------------

def _owner():
    host = os.environ.get("HOSTNAME") or os.uname()[1] or "unknown"
    try:
        host += "/" + os.readlink("/proc/self/ns/pid")
    except OSError:
        pass
    return "%s\t%d\t%d\t%d" % (host, os.getpid(), os.getuid(),
                               int(time.time()))


def hold_lock(root, doing):
    """provost's lock -- STORE/.lock, made by mkdir, an owner record in it
    -- so that no run files into the store while `doing`.  One already
    there is a run filing (or one that died filing: any provost command
    clears that).  -> (lock dir, owner)"""
    lock = os.path.join(root, ".lock")
    try:
        os.mkdir(lock)
    except FileExistsError:
        try:
            with io.open(os.path.join(lock, "owner"),
                         encoding="utf-8") as fh:
                who = fh.read().strip().replace("\t", " ")
        except OSError:
            who = "unknown"
        die("a run is filing into %s (provost's store lock is held by %s): "
            "%s when it is done" % (storemod.tilde(root), who, doing))
    except OSError as exc:
        die("cannot lock %s: %s" % (root, exc))
    owner = _owner()
    tmp = os.path.join(lock, "owner.tmp")
    with io.open(tmp, "w", encoding="utf-8") as fh:
        fh.write(owner + "\n")
    os.replace(tmp, os.path.join(lock, "owner"))
    return lock, owner


def let_go(lock, owner):
    """Removed only while it still carries our owner record, as provost
    releases its own."""
    try:
        with io.open(os.path.join(lock, "owner"), encoding="utf-8") as fh:
            mine = fh.read().strip() == owner
    except OSError:
        return
    if mine:
        shutil.rmtree(lock, ignore_errors=True)


# ---------------------------------------------------------------------------
# export and import
# ---------------------------------------------------------------------------

def store_format(root):
    try:
        with io.open(os.path.join(root, ".store_format"),
                     encoding="utf-8") as fh:
            v = fh.read().strip()
    except OSError:
        return 1
    return int(v) if v.isdigit() else 1


def _walk(root):
    """Every directory and file of a store, relative, sorted, provost's
    runtime files left out.  -> (dirs, files)"""
    dirs, files = [], []
    for d, sub, names in os.walk(root):
        sub.sort()
        rel_d = os.path.relpath(d, root)
        rel_d = "" if rel_d == "." else rel_d.replace(os.sep, "/")
        if rel_d and SKIP.match(rel_d):
            sub[:] = []
            continue
        if rel_d:
            dirs.append(rel_d)
        for n in sub:
            if os.path.islink(os.path.join(d, n)):
                die("%s holds a symbolic link (%s): a store is files, and "
                    "an archive of a link could point anywhere"
                    % (root, (rel_d + "/" + n).lstrip("/")))
        for n in sorted(names):
            rel = (rel_d + "/" + n) if rel_d else n
            if SKIP.match(rel):
                continue
            full = os.path.join(d, n)
            if os.path.islink(full) or not os.path.isfile(full):
                die("%s holds %s, which is not a plain file: a store is "
                    "files, and that is not archived" % (root, rel))
            files.append(rel)
    return dirs, files


def _sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def provost_version():
    from . import filing
    argv = filing.find()
    if not argv:
        return ""
    import subprocess
    try:
        out = subprocess.run(list(argv) + ["--version"],
                             stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                             timeout=20).stdout
    except (OSError, subprocess.SubprocessError):
        return ""
    lines = out.decode("utf-8", "replace").strip().splitlines()
    return lines[0] if lines else ""


def export(root, name, dest):
    """The store at root as one archive at dest.  -> the manifest"""
    if not is_store(root):
        die("nothing has been filed into %s yet: there is no store there to "
            "export" % storemod.tilde(root) if os.path.isdir(root) else
            "no store at %s" % storemod.tilde(root))
    lock, owner = hold_lock(root, "export it")
    tmp = None
    try:
        dirs, files = _walk(root)
        manifest = {
            "kind": ARCHIVE_KIND, "archive_version": ARCHIVE_VERSION,
            "name": name, "exported": storemod.now_iso(),
            "qd": VERSION, "provost": provost_version(),
            "store_format": store_format(root),
            "runs": run_count(root) or 0,
            "captures": len([f for f in files if re.match(
                r"^captures/[^/]+/output\.txt$", f)]),
            "dirs": dirs,
            "files": dict((f, {"sha256": _sha256(os.path.join(root, f)),
                               "bytes": os.path.getsize(
                                   os.path.join(root, f))})
                          for f in files)}
        body = json.dumps(manifest, indent=1, sort_keys=True).encode("utf-8")
        d = os.path.dirname(os.path.abspath(dest)) or "."
        fd, tmp = tempfile.mkstemp(prefix=".qd-export.", dir=d)
        os.close(fd)
        with tarfile.open(tmp, "w:gz") as tar:
            info = tarfile.TarInfo(TOP + "/manifest.json")
            info.size, info.mtime, info.mode = len(body), int(time.time()), \
                0o644
            tar.addfile(info, io.BytesIO(body))
            for rel in dirs:
                tar.add(os.path.join(root, rel), TOP + "/store/" + rel,
                        recursive=False, filter=_plain)
            for rel in files:
                tar.add(os.path.join(root, rel), TOP + "/store/" + rel,
                        recursive=False, filter=_plain)
        os.replace(tmp, dest)
        tmp = None
        return manifest
    finally:
        if tmp and os.path.exists(tmp):
            os.unlink(tmp)
        let_go(lock, owner)


def _plain(info):
    """Whose files they were stays on this machine."""
    info.uid = info.gid = 0
    info.uname = info.gname = ""
    return info


def read_manifest(path):
    try:
        tar = tarfile.open(path, "r:*")
    except (OSError, tarfile.TarError) as exc:
        die("%s is not a qd store archive: %s" % (path, exc))
    with tar:
        first = tar.next()
        if first is None or first.name != TOP + "/manifest.json" \
                or not first.isfile():
            die("%s is not a qd store archive: it does not open with %s/"
                "manifest.json (qd store export writes one)" % (path, TOP))
        try:
            m = json.loads(tar.extractfile(first).read().decode("utf-8"))
        except (ValueError, UnicodeDecodeError) as exc:
            die("%s: its manifest is not JSON: %s" % (path, exc))
    if not isinstance(m, dict) or m.get("kind") != ARCHIVE_KIND:
        die("%s is not a qd store archive (its manifest says %r)"
            % (path, m.get("kind") if isinstance(m, dict) else m))
    if m.get("archive_version") != ARCHIVE_VERSION:
        die("%s is archive version %r; this qd reads version %d -- an "
            "archive from a newer qd" % (path, m.get("archive_version"),
                                         ARCHIVE_VERSION))
    fmt = m.get("store_format")
    if not isinstance(fmt, int) or fmt not in STORE_FORMATS:
        die("%s holds a store in format %r; this qd reads formats %s (a "
            "newer provost made it: upgrade qd and provost)"
            % (path, fmt, ", ".join(str(f) for f in STORE_FORMATS)))
    if not isinstance(m.get("files"), dict) or not isinstance(
            m.get("dirs"), list):
        die("%s: its manifest lists no files" % path)
    return m


def _member_rel(name):
    """An archive member's path inside the store, or None when it is not
    one a qd export writes (absolute, '..', outside store/)."""
    prefix = TOP + "/store/"
    if not name.startswith(prefix):
        return None
    rel = name[len(prefix):].rstrip("/")
    parts = rel.split("/")
    if not rel or rel.startswith("/") or any(
            p in ("", ".", "..") for p in parts) or "\\" in rel:
        return None
    return rel


def import_(path, as_name=None):
    """A store archive, checked, as a new named store.  -> (name, dest, m)"""
    m = read_manifest(path)
    name = check_name(as_name or m.get("name") or "")
    cfg = load()
    if name in cfg["stores"]:
        die("there is a store named %s already (%s): an import never merges"
            " into one -- --as NAME gives it another name"
            % (name, storemod.tilde(cfg["stores"][name])))
    root = data_root()
    dest = os.path.join(root, name)
    if os.path.exists(dest):
        die("%s is there already: an import never merges into a store "
            "(--as NAME, or move it away)" % storemod.tilde(dest))
    os.makedirs(root, exist_ok=True)
    work = tempfile.mkdtemp(prefix=".import-%s." % name, dir=root)
    try:
        seen = set()
        with tarfile.open(path, "r:*") as tar:
            for info in tar:
                if info.name == TOP + "/manifest.json":
                    continue
                rel = _member_rel(info.name)
                if rel is None:
                    die("%s holds %r, which no qd export writes: refused"
                        % (path, info.name))
                if info.isdir():
                    os.makedirs(os.path.join(work, rel), exist_ok=True)
                    continue
                if not info.isfile():
                    die("%s holds %s as a link or device, which no qd export"
                        " writes: refused" % (path, rel))
                want = m["files"].get(rel)
                if want is None:
                    die("%s holds %s, which its manifest does not list: "
                        "refused" % (path, rel))
                full = os.path.join(work, rel)
                os.makedirs(os.path.dirname(full), exist_ok=True)
                h = hashlib.sha256()
                src = tar.extractfile(info)
                with open(full, "wb") as out:
                    for chunk in iter(lambda: src.read(1 << 20), b""):
                        h.update(chunk)
                        out.write(chunk)
                os.chmod(full, (info.mode & 0o755) | 0o600)
                if h.hexdigest() != want.get("sha256"):
                    die("%s: %s does not match its checksum: the archive is "
                        "damaged (or changed since it was written)"
                        % (path, rel))
                seen.add(rel)
        missing = sorted(set(m["files"]) - seen)
        if missing:
            die("%s is missing %d of its files (%s%s): the archive is cut "
                "short" % (path, len(missing), ", ".join(missing[:3]),
                           " ..." if len(missing) > 3 else ""))
        for rel in m["dirs"]:
            if _member_rel(TOP + "/store/" + rel) is None:
                die("%s lists %r as a directory: refused" % (path, rel))
            os.makedirs(os.path.join(work, rel), exist_ok=True)
        if store_format(work) != m["store_format"]:
            die("%s: the store inside is format %d, its manifest says %d"
                % (path, store_format(work), m["store_format"]))
        runs = run_count(work) or 0
        if runs != m.get("runs"):
            die("%s: the store inside holds %d runs, its manifest says %r"
                % (path, runs, m.get("runs")))
        try:
            os.rename(work, dest)
        except OSError as exc:
            die("cannot put the store at %s: %s" % (dest, exc))
        work = None
    finally:
        if work:
            shutil.rmtree(work, ignore_errors=True)
    cfg = load()
    cfg["stores"][name] = dest
    save(cfg)
    return name, dest, m
