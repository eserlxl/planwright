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
# Read-only and informational: by default the exit code is always 0 (unlike doctor,
# which fails on a broken environment) — "no plan / no final point" is a valid state,
# not an error. The opt-in --exit-code flag is the one exception: it returns 0 only when
# the project is at a *current* final point (a final point is recorded, its sha is HEAD,
# and nothing is pending) and 1 otherwise, so a wrapper or CI gate can check convergence.

import argparse
import json
import os
import subprocess
import sys

# status.py lives in scripts/; when run as a script (or imported by state.py) that
# directory is sys.path[0], so the canonical plan parser imports directly.
import plan_parse


def _parse(path):
    """Parse a plan-style file through the one canonical parser, or [] when absent."""
    try:
        with open(path, encoding="utf-8") as fh:
            return plan_parse.parse_items(fh.read())
    except OSError:
        return []


def _count_checkbox(path, marker):
    """Count lines beginning with the given checkbox marker (e.g. '- [ ] ' / '- [x] ')
    in a plan-style file. A missing file counts as 0 — an absent log is a valid state.
    Case-insensitive on the marker so an uppercase '- [X]' completed item (which
    lifecycle.py and lint-plan.py both accept) is counted, not silently dropped."""
    marker = marker.lower()
    try:
        with open(path, encoding="utf-8") as fh:
            return sum(1 for line in fh if line.lower().startswith(marker))
    except OSError:
        return 0


def _pending_titles(path):
    """Return the titles of pending (`- [ ] <title>`) items in a plan file, in order.
    A missing file yields an empty list — an absent plan is a valid state."""
    return [it["title"] for it in _parse(path) if not it["checked"]]


# Canonical mode order for the pending breakdown (matches the plan OUTPUT FORMAT mode
# table); an absent or unrecognised Mode is tallied under "other" so the per-mode counts
# always sum to the pending total.
_MODE_ORDER = ("repair", "improve", "develop", "docs", "reorganize")


def _pending_modes(path):
    """Tally pending (`- [ ] `) items by their `Mode:` continuation line. Returns an
    ordered dict {mode: count} following _MODE_ORDER (then "other" for any absent or
    unrecognised mode), with zero-count modes omitted. The counts sum to the pending
    total, so the breakdown always reconciles. A missing file yields an empty dict."""
    raw = {}
    for it in _parse(path):
        if it["checked"]:
            continue
        mode = it["fields"].get("Mode", "").strip().lower()
        key = mode if mode in _MODE_ORDER else "other"
        raw[key] = raw.get(key, 0) + 1
    ordered = {m: raw[m] for m in _MODE_ORDER if raw.get(m)}
    if raw.get("other"):
        ordered["other"] = raw["other"]
    return ordered


def _rejected_items(path):
    """Return rejected items as {"title","reason"} dicts, in file order. Each rejected
    entry is a `- [ ] <title>` (or `- [x]`) line followed by indented continuation lines;
    its reason is taken from the item's `Rejection:` continuation line ("" when absent, as
    a freshly value-gated reject may carry only `Status: Rejected`). A missing file yields
    an empty list — an absent rejected log is a valid state."""
    return [{"title": it["title"], "reason": it["fields"].get("Rejection", "")}
            for it in _parse(path)]


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


def collect(root: str) -> dict:
    """Build the read-only state record from <root>/.planwright/."""
    pw = os.path.join(root, ".planwright")
    pending_titles = _pending_titles(os.path.join(pw, "plan.md"))
    pending = len(pending_titles)
    pending_modes = _pending_modes(os.path.join(pw, "plan.md"))
    completed = _count_checkbox(os.path.join(pw, "completed.md"), "- [x]")
    rejected = _count_checkbox(os.path.join(pw, "rejected.md"), "- [")
    rejected_items = _rejected_items(os.path.join(pw, "rejected.md"))
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
        built = graph.get("graph_built_at_sha", "")
        graph_rec = {
            # Coerce to str: report() slices built_at_sha ([:10]), so a corrupt graph with a
            # numeric graph_built_at_sha would otherwise crash the human report despite the
            # shape guard below (which only protects collect()'s own .get()/len() calls).
            "built_at_sha": built if isinstance(built, str) else "",
            "node_count": len(nodes),
            "dirty_node_count": len(dirty.get("nodes", []) or []),
        }
    except (OSError, ValueError):
        graph_rec = None
    except (AttributeError, TypeError):
        # A graph file that is valid JSON but the wrong shape (not an object, or a
        # non-dict "nodes"/"dirty") — e.g. a truncated or hand-edited write — would make
        # .get()/len() raise. Degrade to "graph: none" rather than crash a read-only tool.
        graph_rec = None

    return {
        "root": os.path.abspath(root),
        "head": head,
        "pending": pending,
        "pending_titles": pending_titles,
        "pending_modes": pending_modes,
        "completed": completed,
        "rejected": rejected,
        "rejected_items": rejected_items,
        "final_point": final_rec,
        "graph": graph_rec,
    }


def report(state, quiet):
    """Print the human-readable status report. Always returns 0 (read-only)."""
    if quiet:
        return 0
    print("planwright status — " + state["root"])
    modes = state.get("pending_modes") or {}
    breakdown = "  (%s)" % ", ".join("%s %d" % (m, c) for m, c in modes.items()) if modes else ""
    print("  pending:   %d%s" % (state["pending"], breakdown))
    for title in state["pending_titles"]:
        print("    - " + title)
    print("  completed: %d" % state["completed"])
    print("  rejected:  %d" % state["rejected"])
    for item in state["rejected_items"]:
        suffix = " — " + item["reason"] if item["reason"] else ""
        print("    - " + item["title"] + suffix)

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


def _converged(state):
    """True when the project is at a *current* final point with no pending work: a final
    point is recorded, it is not stale (its sha is HEAD), and nothing is pending. This is
    the machine-checkable form of the north star — "when planwright says final point, it
    means it" — that the opt-in --exit-code flag maps to a 0/1 exit status."""
    fp = state["final_point"]
    return bool(fp) and not fp["stale"] and state["pending"] == 0


def main():
    ap = argparse.ArgumentParser(
        description="planwright planning-state summary (read-only).")
    ap.add_argument("--root", default=".",
                    help="the target repo to inspect (default: current directory)")
    ap.add_argument("--json", action="store_true",
                    help="emit the state as JSON instead of the readable report")
    ap.add_argument("--quiet", action="store_true",
                    help="suppress the readable report (exit code only)")
    ap.add_argument("--exit-code", action="store_true",
                    help="exit 0 only at a current final point with no pending items, "
                         "else 1 (composes with --json/--quiet; off by default)")
    args = ap.parse_args()

    state = collect(args.root)
    # Surface the convergence verdict as a first-class field so a JSON consumer reads one
    # canonical boolean instead of re-deriving it from final_point.stale + pending (the
    # same definition the --exit-code flag uses).
    state["converged"] = _converged(state)
    if args.json:
        print(json.dumps(state, indent=2))
    else:
        report(state, args.quiet)
    if args.exit_code:
        return 0 if state["converged"] else 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
