#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Eser KUBALI
# SPDX-License-Identifier: GPL-3.0-or-later
#
# planwright project registry — the cross-repo list a single dashboard server reads so it
# can list (and switch between) every tracked project from one process, instead of one
# server per repo. Unlike .planwright/ (which is per-repo planning state), the registry
# spans repos, so it lives in user-level config — never inside any viewed repo — and stays
# local (no network), consistent with planwright's "no hidden network dependence" mission.
#
# It is the only cross-repo state planwright writes. A project is identified by an opaque,
# URL-safe id derived from its canonical absolute path; the dashboard selects a project by
# that id resolved against this allow-list, never by a client-supplied path (which would be
# an arbitrary-directory read + git-config/hook execution vector).
#
#   python3 scripts/registry.py add <dir>        # register a repo (canonical path)
#   python3 scripts/registry.py remove <dir>     # drop a repo
#   python3 scripts/registry.py discover <parent> # register each child holding a .planwright/
#   python3 scripts/registry.py list             # print the (pruned) registry as JSON
#
# The file format is {"version": 1, "projects": [{"id": ..., "path": ...}, ...]}, written
# atomically (temp + os.replace) so a concurrent reader never sees a half-written file.

import hashlib
import json
import os
import sys
import tempfile

VERSION = 1

# The per-repo planning-state directory name. A path whose final component is this is a
# state directory, never a project root, so it must never enter the registry (see
# is_registerable).
STATE_DIRNAME = ".planwright"


def registry_path():
    """The absolute path to the user-level registry file. Honors XDG_CONFIG_HOME (so a test
    can redirect the whole registry to a temp dir), else ~/.config. This is deliberately
    outside any repo's .planwright/ — the registry spans repos."""
    base = os.environ.get("XDG_CONFIG_HOME") or os.path.join(
        os.path.expanduser("~"), ".config")
    return os.path.join(base, "planwright", "projects.json")


def project_id(path):
    """A stable, URL-safe id for a project: a short hex hash of its canonical absolute path.
    Hex is URL-safe, so it drops straight into a ?project=<id> query without escaping, and it
    never leaks the filesystem path to the client. Two distinct paths cannot collide on the
    same id (sha256), so duplicate basenames stay distinguishable."""
    canon = os.path.abspath(path)
    return hashlib.sha256(canon.encode("utf-8")).hexdigest()[:16]


def _planwright_dir(path):
    return os.path.join(path, STATE_DIRNAME)


def is_registerable(path):
    """True unless `path` is itself a planwright state directory. `<repo>/.planwright` holds a
    repo's planning state and is never a project root; when a tool runs with that state dir as
    its cwd it can grow a nested `.planwright/.planwright`, which used to let discover() and
    the prune liveness check mistake the state dir for a project — surfacing a phantom
    `.planwright` row in the switcher and Fleet view. Reject any path whose final component is
    the reserved state-dir name so a state dir can never be registered, listed, or selected."""
    return os.path.basename(os.path.normpath(path)) != STATE_DIRNAME


def load():
    """Read the registry, returning a dict {id: abspath}. A missing or unreadable/corrupt
    file yields an empty registry (a valid state) rather than raising — the dashboard must
    never 500 because the registry has not been created yet."""
    try:
        with open(registry_path(), "r", encoding="utf-8") as fh:
            data = json.load(fh)
    except (OSError, ValueError):
        return {}
    if not isinstance(data, dict) or data.get("version") != VERSION:
        # An unsupported or missing schema version (or a non-object top level) is
        # unreadable: fail closed to the empty registry rather than returning entries
        # from a format this version cannot vouch for.
        return {}
    out = {}
    for entry in (data.get("projects") or []):
        try:
            pid, p = entry["id"], entry["path"]
        except (KeyError, TypeError):
            continue
        if isinstance(pid, str) and isinstance(p, str):
            out[pid] = p
    return out


def save(entries):
    """Write the registry atomically (temp file + os.replace in the same directory), mirroring
    state.py's _write_activity so a concurrent reader never observes a partial file. `entries`
    is a dict {id: abspath}; it is serialized as a path-sorted list for deterministic output."""
    path = registry_path()
    os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
    projects = [{"id": pid, "path": entries[pid]}
                for pid in sorted(entries, key=lambda k: entries[k])]
    body = json.dumps({"version": VERSION, "projects": projects}, indent=2)
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path) or ".",
                               prefix=".projects-", suffix=".tmp")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            fh.write(body)
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def upsert(path):
    """Register (or refresh) a repo by its canonical absolute path. Returns the project id, or
    None if `path` is a planwright state directory (not a project — see is_registerable), which
    is refused rather than registered. Idempotent: re-registering the same path is a no-op
    beyond rewriting the file."""
    canon = os.path.abspath(path)
    if not is_registerable(canon):
        return None
    pid = project_id(canon)
    entries = load()
    entries[pid] = canon
    save(entries)
    return pid


def remove(path):
    """Drop a repo from the registry by its path. Returns True if an entry was removed."""
    pid = project_id(path)
    entries = load()
    if pid in entries:
        del entries[pid]
        save(entries)
        return True
    return False


def discover(parent):
    """Register every immediate child of `parent` that holds a .planwright/ directory. A
    one-time opt-in scan: the user chooses the parent, so the registry never grows behind
    their back. Returns the list of canonical paths registered this call."""
    found = []
    try:
        names = sorted(os.listdir(parent))
    except OSError:
        return found
    for name in names:
        if name == STATE_DIRNAME:
            # A `.planwright` child is the parent's own state dir, never a project — skip it
            # even if it has grown a nested `.planwright/` (which would otherwise look like a
            # registerable repo root and surface a phantom `.planwright` switcher entry).
            continue
        child = os.path.join(parent, name)
        if os.path.isdir(_planwright_dir(child)) and upsert(child):
            found.append(os.path.abspath(child))
    return found


def list_projects(prune=True):
    """Return the registry as a sorted list of {"id", "path"}. With prune (the default),
    entries whose .planwright/ no longer exists are dropped and the file is rewritten, so a
    deleted/moved project self-cleans instead of lingering as a dead switcher entry."""
    entries = load()
    if prune:
        alive = {pid: p for pid, p in entries.items()
                 if os.path.isdir(_planwright_dir(p)) and is_registerable(p)}
        if alive != entries:
            save(alive)
        entries = alive
    return [{"id": pid, "path": entries[pid]}
            for pid in sorted(entries, key=lambda k: entries[k])]


def main(argv=None):
    argv = list(sys.argv[1:] if argv is None else argv)
    if not argv:
        sys.stderr.write("usage: registry.py {add|remove|discover|list} [dir]\n")
        return 2
    action, rest = argv[0], argv[1:]
    if action == "list":
        print(json.dumps({"projects": list_projects()}, indent=2))
        return 0
    if action in ("add", "remove", "discover"):
        if not rest:
            sys.stderr.write("registry.py %s requires a directory\n" % action)
            return 2
        target = rest[0]
        if action == "add":
            pid = upsert(target)
            print("registry: added %s" % pid if pid
                  else "registry: refused %s (a .planwright state dir is not a project)" % target)
        elif action == "remove":
            print("registry: removed" if remove(target) else "registry: not found")
        else:
            found = discover(target)
            print("registry: discovered %d project(s)" % len(found))
        return 0
    sys.stderr.write("registry.py: unknown action %r\n" % action)
    return 2


if __name__ == "__main__":
    sys.exit(main())
