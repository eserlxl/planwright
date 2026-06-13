#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Eser KUBALI
# SPDX-License-Identifier: GPL-3.0-or-later
#
# planwright state — emit a single machine-readable snapshot of the planning state
# as JSON, so an external consumer (the read-only `planwright dashboard`) has one
# stable data contract instead of scraping the human-facing markdown itself.
#
# It builds on scripts/status.py: status.collect() already derives the counts, the
# pending titles + mode breakdown, the rejected items (title + reason), the recorded
# final point, the graph summary, and the convergence verdict. state.py adds the two
# things a dashboard needs beyond the summary — the *full* pending item bodies (all
# eight plan fields) and the completed-item list — and writes the whole record to
# .planwright/state.json (or stdout).
#
#   python3 scripts/state.py --root .                       # write .planwright/state.json
#   python3 scripts/state.py --root . --out -               # print to stdout instead
#
# Read-only and derived: it reads only the gitignored .planwright/ tool-state plus
# git HEAD (via status.py), and writes nothing except its own output artifact. The
# markdown remains the source of truth; state.json is a rendered view of it.
#
# The one deliberate exception is the run-activity beacon — the command flows
# (codmaster/codshard/codcycle and the skill's plan/execute/cycle paths) stamp
# .planwright/activity.json at start and remove it at end, so the dashboard's
# reactor can show WHICH command is running right now (plan counts alone cannot
# tell "pending work exists" apart from "a run is executing this second"):
#
#   python3 scripts/state.py activity start <command> [--detail TEXT] [--if-absent] --root .
#   python3 scripts/state.py activity stop [<command>] --root .

import argparse
import json
import os
import re
import sys
import tempfile
import time
from datetime import datetime, timezone

# state.py lives beside status.py in scripts/; when run as a script that directory is
# sys.path[0], so a plain import resolves it without any package machinery.
import status
import plan_parse

SCHEMA_VERSION = 1

# The eight continuation fields of the plan OUTPUT FORMAT, mapped to the snake_case
# keys used in the JSON (so a consumer reads stable identifiers, not display labels).
_FIELD_KEYS = {
    "Mode": "mode",
    "Rationale": "rationale",
    "Evidence": "evidence",
    "Surfaces": "surfaces",
    "New Surfaces": "new_surfaces",
    "Development": "development",
    "Acceptance": "acceptance",
    "Verification": "verification",
}
# Fields whose value is a comma-separated path list, surfaced as a JSON array.
_LIST_FIELDS = {"surfaces", "new_surfaces"}


def _split_paths(value):
    """Split a comma-separated Surfaces/New Surfaces value into a clean path list.
    An empty or whitespace-only value yields an empty list."""
    return [p.strip() for p in value.split(",") if p.strip()]


def _parse_items(path):
    """Parse a plan-style markdown file into a list of item dicts. Each item is a
    `- [ ]`/`- [x]` checkbox line followed by 6-space-indented `Field: value`
    continuation lines. Returns, per item: title, checked (bool), and the parsed
    fields keyed by _FIELD_KEYS (list fields as arrays, others as strings). Unknown
    continuation lines are ignored. A missing file yields an empty list.

    Parsing of the shared plan format is delegated to plan_parse (the one canonical
    parser, also used by lint-plan.py and status.py); this only re-keys the fields to
    the dashboard's snake_case JSON identifiers and splits the path-list fields."""
    try:
        with open(path, encoding="utf-8") as fh:
            text = fh.read()
    except (OSError, ValueError):
        # Mirror status.py's readers: a non-UTF-8/undecodable plan.md or completed.md
        # (UnicodeDecodeError is a ValueError subclass) degrades to [] rather than crashing
        # this read-only snapshot — the dashboard surface must survive corrupt input.
        return []
    items = []
    for it in plan_parse.parse_items(text):
        rec = {"title": it["title"], "checked": it["checked"]}
        for label, key in _FIELD_KEYS.items():
            if label in it["fields"]:
                value = it["fields"][label]
                rec[key] = _split_paths(value) if key in _LIST_FIELDS else value
        # The Commit: provenance stamp the execute path appends on pass. Captured
        # outside _FIELD_KEYS so the pending-item shape (which whitelists that map's
        # keys) stays the eight plan fields; only _completed_item surfaces it.
        if "Commit" in it["fields"]:
            rec["commit"] = it["fields"]["Commit"]
        items.append(rec)
    return items


def _pending_item(item):
    """Shape a parsed plan.md item into the dashboard's pending record: title plus
    every plan field (missing string fields default to "", missing list fields to [])."""
    rec = {"title": item["title"]}
    for key in _FIELD_KEYS.values():
        default = [] if key in _LIST_FIELDS else ""
        rec[key] = item.get(key, default)
    return rec


def _completed_item(item):
    """Shape a parsed completed.md item into the dashboard's completed record: the
    title, its Mode, and the Commit: provenance stamp ("" for history that predates
    the stamp — the execute path only began appending it once the field landed)."""
    return {"title": item["title"], "mode": item.get("mode", ""),
            "commit": item.get("commit", "")}


def _verify_manifest(state):
    """The pending plan's Verification commands, deduped in plan order, each paired with the
    titles that share it — planwright's 'every item carries a runnable verification' promise as
    a consumable artifact. Reuses collect()'s already-shaped pending[] (each carries a
    `verification` field), so it adds no new parsing surface. Deterministic: plan order + a
    first-seen dedupe is byte-stable on an unchanged plan, matching state.json's own guarantee."""
    seen, order = {}, []
    for item in state.get("pending", []):
        cmd = (item.get("verification") or "").strip()
        if not cmd:
            continue
        if cmd not in seen:
            seen[cmd] = []
            order.append(cmd)
        seen[cmd].append((item.get("title") or "").strip())
    return [{"command": c, "titles": seen[c]} for c in order]


def _render_verify_manifest(manifest, fmt):
    """Render the manifest as JSON (default — an array of {command, titles}) or as a runnable
    `set -euo pipefail` shell script (`--as sh`) that runs each unique command once, each
    preceded by its titles as comments. Read-only: both forms go to stdout, no file is written."""
    if fmt == "sh":
        lines = ["#!/usr/bin/env bash",
                 "# planwright verification manifest — every pending item's Verification command,",
                 "# deduped in plan order. Generated read-only by `state.py --verify-manifest --as sh`.",
                 "set -euo pipefail"]
        for entry in manifest:
            lines.append("")
            for t in entry["titles"]:
                lines.append("# - " + t.replace("\n", " "))
            lines.append(entry["command"])
        return "\n".join(lines) + "\n"
    return json.dumps(manifest, indent=2) + "\n"


# ---- run-activity beacon (write side) ----------------------------------------------------
# The beacon is a deliberately tiny contract: one JSON object {command, started,
# updated[, detail]} in .planwright/activity.json. Freshness comes from the file
# MTIME, not the recorded fields — an interrupted agent run leaves the file behind
# with no process to clean it up, and the mtime is the one signal a leftover cannot
# keep current. A beacon that has not been (re-)stamped within PW_ACTIVITY_TTL
# seconds reads as stale, and stale counts as absent for `start --if-absent`, so an
# abandoned run never blocks the next one from taking the beacon over.
#
# The READ side (_activity_ttl/_activity_path/_read_activity/_activity_block) lives
# in status.py so the no-browser `planwright status` surface reports the beacon too;
# the import direction (state imports status, never the reverse) puts the canonical
# readers there. These aliases keep the write path below — and existing consumers
# such as dashboard._mtime_signature — on the same single implementation.
_activity_ttl = status._activity_ttl
_activity_path = status._activity_path
_read_activity = status._read_activity
_activity_block = status._activity_block

# Command names are short lowercase tokens (codmaster, plan, execute…); the bound
# keeps a typo'd shell fragment from becoming the dashboard's headline.
_ACTIVITY_NAME_RE = re.compile(r"^[a-z][a-z0-9_-]{0,39}$")
_ACTIVITY_DETAIL_MAX = 160


def _utc_now() -> str:
    # Matches build-graph.py's built_at convention (UTC ISO-8601, Z, second precision).
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _write_activity(path, record):
    """Atomic write (mirrors the state.json write below): same-directory temp +
    os.replace, temp removed on any failure."""
    os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path) or ".",
                               prefix=".activity-", suffix=".tmp")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            fh.write(json.dumps(record, indent=2) + "\n")
        os.replace(tmp, path)
    except BaseException:
        try:
            os.remove(tmp)
        except OSError:
            pass
        raise


def _register_project(root):
    """Best-effort: enter this repo into the cross-repo dashboard registry (see registry.py)
    so a project that is *running* appears in the single-server switcher with zero user
    effort. Imported lazily to avoid any import-time coupling, and every failure is
    swallowed — the beacon is best-effort telemetry, so an unwritable/absent registry must
    never block or error a beacon stamp."""
    try:
        import registry
        registry.upsert(os.path.abspath(root))
    except Exception:
        pass


def activity_start(root, name, detail=None, if_absent=False):
    """Stamp the beacon. With if_absent, ANOTHER command's live beacon (fresh within
    the TTL) is kept untouched — that is how an inner skill flow avoids clobbering
    the orchestrator that dispatched it — while the same command refreshing its own
    beacon, or a stale leftover, writes through. Re-stamping the same command
    preserves its original `started` (an orchestrator updating --detail between
    steps keeps one run clock) — but only while the beacon is FRESH: a stale
    same-name leftover is a dead run, so its takeover gets a new clock instead of
    wearing the dead run's `since` stamp. Returns the one-line report to print."""
    path = _activity_path(root)
    existing, mtime = _read_activity(path)
    fresh = False
    if existing is not None and mtime is not None:
        fresh = (time.time() - mtime) <= _activity_ttl()
        if if_absent and fresh and existing["command"].strip() != name:
            return "activity: kept %s (already running)" % existing["command"].strip()
    now = _utc_now()
    started = now
    if fresh and existing is not None and existing["command"].strip() == name:
        prev = existing.get("started")
        if isinstance(prev, str) and prev:
            started = prev
    record = {"command": name, "started": started, "updated": now}
    if detail:
        record["detail"] = detail
    _write_activity(path, record)
    _register_project(root)
    return "activity: started %s" % name


def activity_stop(root, name=None):
    """Remove the beacon. With a name, remove only a beacon that command owns —
    an inner flow's stop must not erase its orchestrator's beacon — while a
    malformed file is removed regardless (it is noise, not anyone's run). Always
    succeeds: a missing beacon is already the goal state."""
    path = _activity_path(root)
    existing, _mtime = _read_activity(path)
    if existing is None:
        if os.path.exists(path):
            # unreadable/malformed beacon: self-heal by clearing it
            try:
                os.remove(path)
            except OSError:
                pass
            return "activity: cleared malformed beacon"
        return "activity: none"
    current = existing["command"].strip()
    if name is not None and current != name:
        return "activity: kept %s (not %s)" % (current, name)
    try:
        os.remove(path)
    except OSError:
        return "activity: none"
    return "activity: stopped %s" % current


def _sanitize_detail(detail):
    """One display line: whitespace collapsed, capped at _ACTIVITY_DETAIL_MAX. The
    dashboard renders via textContent so this is a UI bound, not an escape."""
    if detail is None:
        return None
    flat = " ".join(detail.split())
    return flat[:_ACTIVITY_DETAIL_MAX] if flat else None


def activity_main(argv):
    """CLI for the beacon (state.py activity …). Positional action+name, mirroring
    lifecycle.py's positional-choices style rather than argparse subparsers."""
    ap = argparse.ArgumentParser(
        prog="state.py activity",
        description="stamp/clear the run-activity beacon the dashboard reactor shows.")
    ap.add_argument("action", choices=["start", "stop"],
                    help="start: stamp .planwright/activity.json; stop: remove it")
    ap.add_argument("name", nargs="?", default=None,
                    help="command name (required for start; for stop, remove only "
                         "a beacon owned by this name)")
    ap.add_argument("--detail", default=None,
                    help="free-text progress line shown next to the command "
                         "(e.g. 'shard 3/5: scripts/')")
    ap.add_argument("--if-absent", action="store_true",
                    help="start only when no OTHER live beacon exists (a stale one "
                         "counts as absent, and the same command may refresh its "
                         "own); inner flows use this so they never clobber the "
                         "orchestrator that dispatched them")
    ap.add_argument("--root", default=".",
                    help="the target repo (default: current directory)")
    args = ap.parse_args(argv)

    if args.action == "start":
        if not args.name:
            ap.error("start requires a command name")
        if not _ACTIVITY_NAME_RE.match(args.name):
            ap.error("invalid command name %r (want a short lowercase token)" % args.name)
        print(activity_start(args.root, args.name,
                             detail=_sanitize_detail(args.detail),
                             if_absent=args.if_absent))
        return 0
    print(activity_stop(args.root, args.name))
    return 0


def collect(root: str) -> dict:
    """Build the full dashboard state record from <root>/.planwright/, reusing
    status.collect() for the summary and adding the full pending/completed bodies."""
    pw = os.path.join(root, ".planwright")
    base = status.collect(root)

    # Only unchecked lines are pending. During `execute` an item is checked off
    # (`- [x]`) in plan.md before lifecycle drains it to completed.md; without this
    # filter that transient checked item leaks into `pending`, disagreeing with
    # counts.pending (status counts only `- [ ]`) in the very same snapshot.
    pending_items = [
        _pending_item(i)
        for i in _parse_items(os.path.join(pw, "plan.md")) if not i["checked"]
    ]
    completed_items = [
        _completed_item(i)
        for i in _parse_items(os.path.join(pw, "completed.md")) if i["checked"]
    ]

    return {
        "schema_version": SCHEMA_VERSION,
        "root": base["root"],
        "head": base["head"],
        "counts": {
            "pending": base["pending"],
            "completed": base["completed"],
            "rejected": base["rejected"],
            # Verified-but-cut dossier findings carried in the planning digest
            # (status._carried_count) — the backlog a bare "0 pending" can hide.
            "carried": base["carried"],
        },
        "pending_modes": base["pending_modes"],
        "pending": pending_items,
        "completed": completed_items,
        "rejected": base["rejected_items"],
        "final_point": base["final_point"],
        "graph": base["graph"],
        # codshard's shard enumeration ({tracked_files, shardable_dirs, folded_dirs,
        # large}, or null when git is unavailable), surfaced so the dashboard's Shards
        # view shows the same partition codshard would sweep instead of re-deriving an
        # approximation from graph node paths (graph nodes ≠ git-tracked files).
        "repo": status._repo_block(root),
        # The run-activity beacon ({command, detail, started, age_seconds, stale},
        # or null when no command flow has stamped one) — the Console reactor's
        # "which command is running right now" line. Distinct from the pending-work
        # verdict: IN PROGRESS means items exist, activity means a run is executing.
        # Reused from status.collect() (the canonical read side) rather than re-read.
        "activity": base["activity"],
        "converged": status._converged(base),
    }


def main():
    # The activity subcommand peels off before the flat snapshot parser so the
    # historical flag-only invocation (`state.py --root .`) keeps working unchanged.
    if len(sys.argv) > 1 and sys.argv[1] == "activity":
        return activity_main(sys.argv[2:])
    ap = argparse.ArgumentParser(
        description="planwright machine-readable state snapshot (read-only).")
    ap.add_argument("--root", default=".",
                    help="the target repo to inspect (default: current directory)")
    ap.add_argument("--out", default=None,
                    help="output path for the JSON (default: <root>/.planwright/state.json; "
                         "use '-' for stdout)")
    ap.add_argument("--verify-manifest", action="store_true",
                    help="instead of writing the snapshot, emit the pending plan's Verification "
                         "commands (deduped, in plan order) to stdout as a runnable manifest — a "
                         "file-based artifact an external CI step or agent can run; read-only")
    ap.add_argument("--as", dest="as_fmt", choices=("json", "sh"), default="json",
                    help="with --verify-manifest: 'json' (default, an array of {command, titles}) "
                         "or 'sh' (a `set -euo pipefail` script running each unique command once)")
    args = ap.parse_args()

    if args.verify_manifest:
        # Read-only: emit the manifest to stdout and write no snapshot. Deterministic, so an
        # external consumer can regenerate and diff it.
        print(_render_verify_manifest(_verify_manifest(collect(args.root)), args.as_fmt), end="")
        return 0

    state = collect(args.root)
    text = json.dumps(state, indent=2)

    out = args.out
    if out == "-":
        print(text)
        return 0
    if out is None:
        out = os.path.join(args.root, ".planwright", "state.json")
    os.makedirs(os.path.dirname(out) or ".", exist_ok=True)
    # Atomic write (mirrors lifecycle.write): a plain open(out, "w") truncates the
    # artifact before the new bytes land, so an interruption between truncate and
    # flush leaves a torn, unparseable state.json for any external consumer until a
    # later run replaces it. A same-directory temp keeps os.replace on one
    # filesystem; on any failure the temp is removed and the original is untouched.
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(out) or ".",
                               prefix=".state-", suffix=".tmp")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            fh.write(text + "\n")
        os.replace(tmp, out)
    except BaseException:
        try:
            os.remove(tmp)
        except OSError:
            pass
        raise
    return 0


if __name__ == "__main__":
    sys.exit(main())
