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

import argparse
import json
import os
import sys

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
    except OSError:
        return []
    items = []
    for it in plan_parse.parse_items(text):
        rec = {"title": it["title"], "checked": it["checked"]}
        for label, key in _FIELD_KEYS.items():
            if label in it["fields"]:
                value = it["fields"][label]
                rec[key] = _split_paths(value) if key in _LIST_FIELDS else value
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
    title and its Mode (the only field the timeline/plan views need for a done item)."""
    return {"title": item["title"], "mode": item.get("mode", "")}


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
        },
        "pending_modes": base["pending_modes"],
        "pending": pending_items,
        "completed": completed_items,
        "rejected": base["rejected_items"],
        "final_point": base["final_point"],
        "graph": base["graph"],
        "converged": status._converged(base),
    }


def main():
    ap = argparse.ArgumentParser(
        description="planwright machine-readable state snapshot (read-only).")
    ap.add_argument("--root", default=".",
                    help="the target repo to inspect (default: current directory)")
    ap.add_argument("--out", default=None,
                    help="output path for the JSON (default: <root>/.planwright/state.json; "
                         "use '-' for stdout)")
    args = ap.parse_args()

    state = collect(args.root)
    text = json.dumps(state, indent=2)

    out = args.out
    if out == "-":
        print(text)
        return 0
    if out is None:
        out = os.path.join(args.root, ".planwright", "state.json")
    os.makedirs(os.path.dirname(out) or ".", exist_ok=True)
    with open(out, "w", encoding="utf-8") as fh:
        fh.write(text + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
