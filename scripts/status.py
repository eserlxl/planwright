#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Eser KUBALI
# SPDX-License-Identifier: GPL-3.0-or-later
#
# planwright status — a read-only summary of the current planning state, so a
# maintainer can see at a glance what planwright thinks the project is at without
# running a full plan/cycle. It reads only the gitignored .planwright/ tool-state
# directory (the plan, the completed/rejected logs, the recorded final point, and
# the graph memory) — it mutates nothing and never plans.
#
# It reports, from <root>/.planwright/:
#   - pending / completed / rejected item counts (plan.md, completed.md, rejected.md)
#   - the recorded final point (final.md): sha, date, deepest_tier, and whether it is
#     STALE — i.e. its sha is not HEAD, so the tree has moved on since the ladder was
#     last exhausted and a fresh run would re-open it
#   - the graph memory (graph.json): the sha it was built at, its node count, and how
#     many nodes the last build marked dirty
#
#   python3 scripts/status.py --root .
#   python3 scripts/status.py --root . --json
#
# Read-only and informational: the exit code is always 0 (unlike doctor, which fails
# on a broken environment) — "no plan / no final point" is a valid state, not an error.

import argparse
import json
import os
import subprocess
import sys


def _count_checkbox(path, marker):
    """Count lines beginning with the given checkbox marker (e.g. '- [ ] ' / '- [x] ')
    in a plan-style file. A missing file counts as 0 — an absent log is a valid state."""
    try:
        with open(path, encoding="utf-8") as fh:
            return sum(1 for line in fh if line.startswith(marker))
    except OSError:
        return 0


def _head_sha(root):
    """The target's current HEAD sha, or '' when git is unavailable / not a work tree."""
    try:
        out = subprocess.run(
            ["git", "-C", root, "rev-parse", "HEAD"],
            capture_output=True, text=True, timeout=5,
        )
        return out.stdout.strip() if out.returncode == 0 else ""
    except (OSError, subprocess.SubprocessError):
        return ""


def _parse_final(path):
    """Parse the recorded final point (final.md). Returns a dict with sha/date/
    deepest_tier (each '' when absent) or None when there is no final-point file."""
    try:
        with open(path, encoding="utf-8") as fh:
            text = fh.read()
    except OSError:
        return None
    fields = {"sha": "", "date": "", "deepest_tier": ""}
    for line in text.splitlines():
        for key in fields:
            prefix = key + ":"
            if line.startswith(prefix):
                fields[key] = line[len(prefix):].strip()
    return fields


def _shas_match(a, b):
    """True when two shas refer to the same commit, tolerating short/long forms."""
    if not a or not b:
        return False
    return a.startswith(b) or b.startswith(a)


def collect(root):
    """Build the read-only state record from <root>/.planwright/."""
    pw = os.path.join(root, ".planwright")
    pending = _count_checkbox(os.path.join(pw, "plan.md"), "- [ ]")
    completed = _count_checkbox(os.path.join(pw, "completed.md"), "- [x]")
    rejected = _count_checkbox(os.path.join(pw, "rejected.md"), "- [")
    head = _head_sha(root)

    final = _parse_final(os.path.join(pw, "final.md"))
    final_rec = None
    if final is not None:
        stale = bool(head) and not _shas_match(final["sha"], head)
        final_rec = {
            "sha": final["sha"],
            "date": final["date"],
            "deepest_tier": final["deepest_tier"],
            "stale": stale,
        }

    graph_rec = None
    try:
        with open(os.path.join(pw, "graph.json"), encoding="utf-8") as fh:
            graph = json.load(fh)
        nodes = graph.get("nodes", {})
        dirty = graph.get("dirty", {}) or {}
        graph_rec = {
            "built_at_sha": graph.get("graph_built_at_sha", ""),
            "node_count": len(nodes),
            "dirty_node_count": len(dirty.get("nodes", []) or []),
        }
    except (OSError, ValueError):
        graph_rec = None

    return {
        "root": os.path.abspath(root),
        "head": head,
        "pending": pending,
        "completed": completed,
        "rejected": rejected,
        "final_point": final_rec,
        "graph": graph_rec,
    }


def report(state, quiet):
    """Print the human-readable status report. Always returns 0 (read-only)."""
    if quiet:
        return 0
    print("planwright status — " + state["root"])
    print("  pending:   %d" % state["pending"])
    print("  completed: %d" % state["completed"])
    print("  rejected:  %d" % state["rejected"])

    fp = state["final_point"]
    if fp is None:
        print("  final point: none recorded (the ladder is open)")
    else:
        tier = fp["deepest_tier"] or "(unrecorded tier)"
        flag = "STALE — HEAD has moved; a fresh run re-opens the ladder" if fp["stale"] \
            else "current"
        print("  final point: %s (%s) deepest_tier=%s — %s"
              % (fp["sha"] or "?", fp["date"] or "?", tier, flag))

    g = state["graph"]
    if g is None:
        print("  graph: none (run a plan to build .planwright/graph.json)")
    else:
        print("  graph: %d nodes, %d dirty, built at %s"
              % (g["node_count"], g["dirty_node_count"], (g["built_at_sha"] or "?")[:10]))
    return 0


def main():
    ap = argparse.ArgumentParser(
        description="planwright planning-state summary (read-only).")
    ap.add_argument("--root", default=".",
                    help="the target repo to inspect (default: current directory)")
    ap.add_argument("--json", action="store_true",
                    help="emit the state as JSON instead of the readable report")
    ap.add_argument("--quiet", action="store_true",
                    help="suppress the readable report (exit code only)")
    args = ap.parse_args()

    state = collect(args.root)
    if args.json:
        print(json.dumps(state, indent=2))
        return 0
    return report(state, args.quiet)


if __name__ == "__main__":
    sys.exit(main())
