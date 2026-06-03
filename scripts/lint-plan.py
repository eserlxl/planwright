#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Eser KUBALI
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Canonical, deterministic linter for planwright plan items (.planwright/plan.md).
# It enforces the *machine-checkable subset* of the SKILL.md OUTPUT FORMAT, Stage 10
# strict quality gate, and Hard rules — the structural invariants that do not need
# Claude's judgement, so they never have to be re-checked by hand:
#
#   * every pending item carries all required fields (Mode, Rationale, Evidence,
#     Surfaces, Development, Acceptance, Verification; New Surfaces optional);
#   * Mode is one of the five valid modes;
#   * Evidence never cites .planwright/graph.json or .planwright/digest.md
#     (graph memory routes attention, it is never proof);
#   * Surfaces are existing repo files; New Surfaces do not already exist;
#     no path appears in both Surfaces and New Surfaces;
#   * a CMakeLists surface is spelled with its .txt extension;
#   * Verification is present and non-empty;
#   * no two pending items share a title (the maturity ladder's monotonic-drain
#     guard). As a non-failing advisory it also notes pending titles that match a
#     completed.md / rejected.md item, for Claude to confirm a regression or a
#     resolved rejection rather than blocking it.
#
# Semantic checks that need code understanding (is the Evidence a *real* defect?
# does Development name a real call site?) stay Claude's job — this linter is
# deliberately precise over clever so it never raises a false failure.
#
# It only reads the plan + the working tree; it prints findings and exits non-zero
# when any pending item violates a rule (0 when the plan is clean or empty).
#
#   python3 scripts/lint-plan.py [--root DIR] [--plan PATH] [--all] [--quiet]
import argparse
import os
import re
import sys

VALID_MODES = {"develop", "improve", "repair", "docs", "reorganize"}
REQUIRED_FIELDS = ("Mode", "Rationale", "Evidence", "Surfaces",
                   "Development", "Acceptance", "Verification")
KNOWN_FIELDS = set(REQUIRED_FIELDS) | {"New Surfaces", "Status", "Rejection"}
# Graph-memory artifacts Stage 10 bars from Evidence (routing only, never proof).
GRAPH_MEMORY = (".planwright/graph.json", ".planwright/digest.md",
                "graph.json", "digest.md")


def parse_items(text):
    """Parse plan.md into a list of items: {checked, title, line, fields}.
    fields maps a known field name to its (possibly multi-line) value string."""
    items = []
    cur = None
    field = None
    for i, raw in enumerate(text.splitlines(), 1):
        head = re.match(r"^- \[([ xX])\]\s*(.*)$", raw)
        if head:
            cur = {"checked": head.group(1).lower() == "x",
                   "title": head.group(2).strip(), "line": i, "fields": {}}
            items.append(cur)
            field = None
            continue
        if cur is None:
            continue
        m = re.match(r"^\s+([A-Z][A-Za-z ]*?):\s*(.*)$", raw)
        if m and m.group(1) in KNOWN_FIELDS:
            field = m.group(1)
            cur["fields"][field] = m.group(2).strip()
        elif field is not None and raw.strip():
            # wrapped continuation of the current field's value
            cur["fields"][field] = (cur["fields"][field] + " " + raw.strip()).strip()
        elif not raw.strip():
            field = None  # blank line ends a field block
    return items


def split_paths(value):
    out = []
    for p in value.split(","):
        p = p.strip().strip("`")
        if p and p.lower() != "none":
            out.append(p)
    return out


def lint_item(item, root):
    """Return a list of violation strings for one pending item."""
    v = []
    f = item["fields"]
    if not item["title"]:
        v.append("empty title")
    for req in REQUIRED_FIELDS:
        if req not in f:
            v.append(f"missing required field '{req}:'")
        elif not f[req]:
            v.append(f"empty field '{req}:'")

    mode = f.get("Mode", "")
    if mode and mode not in VALID_MODES:
        v.append(f"invalid Mode '{mode}' (use {'|'.join(sorted(VALID_MODES))})")

    ev = f.get("Evidence", "")
    for g in GRAPH_MEMORY:
        if g in ev:
            v.append(f"Evidence cites graph memory '{g}' (routing only, never proof)")
            break

    surfaces = split_paths(f.get("Surfaces", ""))
    new_surfaces = split_paths(f.get("New Surfaces", ""))
    if not surfaces and not new_surfaces:
        v.append("no Surfaces and no New Surfaces (item changes nothing)")
    for p in surfaces:
        if os.path.basename(p) == "CMakeLists":
            v.append(f"Surface '{p}' must be spelled CMakeLists.txt")
        elif not os.path.exists(os.path.join(root, p)):
            v.append(f"Surface '{p}' does not exist under root")
    for p in new_surfaces:
        if os.path.basename(p) == "CMakeLists":
            v.append(f"New Surface '{p}' must be spelled CMakeLists.txt")
        elif os.path.exists(os.path.join(root, p)):
            v.append(f"New Surface '{p}' already exists (move it to Surfaces:)")
    overlap = sorted(set(surfaces) & set(new_surfaces))
    if overlap:
        v.append(f"path(s) in both Surfaces and New Surfaces: {', '.join(overlap)}")
    return v


def past_titles(plan_path, fname):
    """Titles of items in a sibling lifecycle file (completed.md / rejected.md)."""
    path = os.path.join(os.path.dirname(os.path.abspath(plan_path)), fname)
    if not os.path.exists(path):
        return set()
    return {it["title"] for it in parse_items(open(path, encoding="utf-8").read()) if it["title"]}


def main():
    ap = argparse.ArgumentParser(description="Lint planwright plan items against the Stage 10 structural gate.")
    ap.add_argument("--root", default=".", help="repo root for Surfaces existence checks (default: cwd)")
    ap.add_argument("--plan", default=".planwright/plan.md", help="plan file to lint")
    ap.add_argument("--all", action="store_true", help="lint completed (- [x]) items too, not just pending")
    ap.add_argument("--quiet", action="store_true", help="print nothing; only set the exit code")
    args = ap.parse_args()
    root = os.path.abspath(args.root)

    if not os.path.exists(args.plan):
        if not args.quiet:
            print(f"lint-plan: no plan file at {args.plan} (nothing to lint)")
        return 0
    text = open(args.plan, encoding="utf-8").read()
    items = [it for it in parse_items(text) if args.all or not it["checked"]]

    total = 0
    for idx, item in enumerate(items, 1):
        violations = lint_item(item, root)
        if violations:
            total += len(violations)
            if not args.quiet:
                print(f"item {idx} (line {item['line']}): {item['title'] or '<untitled>'}")
                for msg in violations:
                    print(f"  - {msg}")

    # Cross-item: a title repeated among pending items is always a violation
    # (you cannot have two identical pending items). Reported once per dup title.
    seen, dups = set(), []
    for it in items:
        t = it["title"]
        if t and t in seen and t not in dups:
            dups.append(t)
        seen.add(t)
    for t in dups:
        total += 1
        if not args.quiet:
            print(f"duplicate pending title: '{t}'")

    # Advisory (does NOT fail the gate): re-proposing completed/rejected work is a
    # Hard-rule concern but legitimate for a regression or a resolved rejection, so
    # surface it for Claude to confirm rather than block it.
    completed = past_titles(args.plan, "completed.md")
    rejected = past_titles(args.plan, "rejected.md")
    notes = 0
    if not args.quiet:
        for it in items:
            if it["title"] in completed:
                notes += 1
                print(f"note: '{it['title']}' matches a completed item — confirm this is a regression")
            if it["title"] in rejected:
                notes += 1
                print(f"note: '{it['title']}' matches a rejected item — confirm the rejection reason is resolved")

    if not args.quiet:
        n = len(items)
        suffix = f" ({notes} advisory note(s))" if notes else ""
        if total == 0:
            print(f"lint-plan: {n} item(s) OK{suffix}")
        else:
            print(f"lint-plan: {total} violation(s) across {n} item(s){suffix}")
    return 1 if total else 0


if __name__ == "__main__":
    sys.exit(main())
