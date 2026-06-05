#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Eser KUBALI
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Canonical, deterministic linter for planwright plan items (.planwright/plan.md).
# It enforces the *machine-checkable subset* of the SKILL.md OUTPUT FORMAT, Stage 10
# strict quality gate, and Hard rules — the structural invariants that do not need
# the active agent's judgement, so they never have to be re-checked by hand:
#
#   * every pending item carries all required fields (Mode, Rationale, Evidence,
#     Surfaces, Development, Acceptance, Verification; New Surfaces optional);
#   * Mode is one of the five valid modes;
#   * Evidence never cites .planwright/graph.json or .planwright/digest.md
#     (graph memory routes attention, it is never proof);
#   * a `repair` item's Evidence carries a file:line anchor (`:N` / `line N`),
#     not bare structural absence — improve/docs are exempt;
#   * Surfaces are existing repo files; New Surfaces do not already exist;
#     no path appears in both Surfaces and New Surfaces; no Surface is under the
#     tool-owned .planwright/ tree;
#   * a CMakeLists surface is spelled with its .txt extension;
#   * Verification is present, non-empty, and not a bare placeholder
#     (TODO / tbd / manual / n-a / ... — never a runnable command);
#   * no two pending items share a title (the maturity ladder's monotonic-drain
#     guard). As a non-failing advisory it also notes pending titles that match a
#     completed.md / rejected.md item, for the active agent to confirm a regression or a
#     resolved rejection rather than blocking it.
#
# Semantic checks that need code understanding (is the Evidence a *real* defect?
# does Development name a real call site?) stay the active agent's job — this linter is
# deliberately precise over clever so it never raises a false failure.
#
# It only reads the plan + the working tree; it prints findings and exits non-zero
# when any pending item violates a rule (0 when the plan is clean or empty).
#
#   python3 scripts/lint-plan.py [--root DIR] [--plan PATH] [--all] [--quiet] [--scope GRAPH]
#
# With --scope GRAPH (a graph.json built with build-graph.py --scope), it also
# enforces the Stage 10 Surfaces-in-Focus gate for a scoped run: a pending item's
# existing Surfaces must lie in the graph's `focus` set; a `repair` Surface one hop
# upstream (in `context`) is a non-failing advisory; any other out-of-Focus Surface
# fails. No-op when the graph's focus is empty (a whole-repo build).
import argparse
import json
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
# Bare Verification values that are never a runnable command. Matched as the WHOLE
# normalized value (lowercased, de-ticked, trailing period dropped) so a real command
# that merely contains one of these words ("manual smoke test then bash tests/run.sh")
# is never flagged — the mission requires an exact verification command per item.
PLACEHOLDER_VERIFICATION = {
    "todo", "tbd", "n/a", "na", "none", "manual", "manually",
    "pending", "fixme", "xxx", "?", "...", "tba",
}


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
    # Stage 10: a `repair` item's Evidence must cite the wrong call site as
    # file:line — a bare "X is absent" is insufficient for a confirmed defect.
    # Require a line anchor (`:N`, `line N`, or `lines N`); improve/docs may use
    # structural-absence Evidence and are exempt.
    if mode == "repair" and ev and not re.search(r"(?::\d+|\blines?\s+\d+)", ev, re.IGNORECASE):
        v.append("repair Evidence lacks a file:line anchor "
                 "(Stage 10: cite the wrong call site, not just structural absence)")

    # Verification must be a runnable command, not a bare placeholder. The
    # REQUIRED_FIELDS loop already rejects an empty value; this rejects the
    # equally-unverifiable "TODO"/"manual"/"n/a" class before execute wastes a
    # cycle discovering the item cannot be verified.
    verif = f.get("Verification", "")
    if verif:
        norm = verif.strip().strip("`").strip().rstrip(".").lower()
        # A value that normalizes to empty was all dots/backticks/whitespace
        # (e.g. the "..." ellipsis placeholder, which rstrip(".") collapses to ""):
        # never a runnable command, so it is a placeholder too.
        if norm in PLACEHOLDER_VERIFICATION or norm == "":
            v.append(f"Verification '{verif}' is a placeholder, not a runnable command")

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
    # Plan items edit application source; planwright's own .planwright/ tree
    # (plan, graph memory, digest, final point) is tool-owned routing/state and
    # is never a Surface — editing it is the destructive tool-owned-file class
    # Stage 10 bars, and it complements the graph-memory-in-Evidence rule above.
    for p in surfaces + new_surfaces:
        np = p.replace("\\", "/")
        if np == ".planwright" or np.startswith(".planwright/"):
            v.append(f"'{p}' is tool-owned planwright state (.planwright/), not an editable Surface")
    return v


def load_focus(scope_path):
    """Load the builder's (focus, context) node sets from a graph.json emitted with
    --scope (docs/scope-design.md). Returns (focus_set, context_set); focus is empty
    when the graph is whole-repo (no/empty `focus` key) or unreadable — callers treat
    an empty focus as 'no scope active', so the gate stays a no-op by default."""
    try:
        g = json.load(open(scope_path, encoding="utf-8"))
    except (ValueError, OSError):
        return set(), set()
    return set(g.get("focus") or []), set(g.get("context") or [])


def scope_check(item, focus, context):
    """Stage 10 Surfaces-in-Focus gate for a scoped run. Returns (violations,
    advisories). Only the item's existing `Surfaces` are checked — `New Surfaces`
    name not-yet-created files that are not graph nodes, so they cannot be matched
    against a file-list focus without risking a false failure (this linter stays
    precise over clever), and stay Claude's Stage 10 judgement. A Surface in Focus
    passes; a `repair` Surface in Context (1-hop upstream of Focus) is a non-failing
    advisory (the proven-impact escape stays Claude's call); any other out-of-Focus
    Surface is a violation."""
    f = item["fields"]
    mode = f.get("Mode", "")
    viols, advs = [], []
    for p in split_paths(f.get("Surfaces", "")):
        if p in focus:
            continue
        if p in context:
            if mode == "repair":
                advs.append(f"repair Surface '{p}' is upstream of Focus (Context) — "
                            "confirm Evidence proves the in-Focus impact")
            else:
                viols.append(f"Surface '{p}' is in Context but not Focus, and the item is "
                             "not 'repair' (only a repair with proven in-Focus impact may "
                             "reach upstream of the scoped component)")
        else:
            viols.append(f"Surface '{p}' is outside the scoped component "
                         "(not in Focus or its 1-hop Context)")
    return viols, advs


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
    ap.add_argument("--scope", default=None,
                    help="a graph.json (built with --scope) whose focus/context node sets gate "
                         "Surfaces-in-Focus for a scoped run; no-op when its focus is empty")
    args = ap.parse_args()
    root = os.path.abspath(args.root)

    focus, context = (set(), set())
    if args.scope:
        focus, context = load_focus(args.scope)
    scope_active = bool(focus)  # an empty focus (whole-repo graph) means no scope to enforce

    if not os.path.exists(args.plan):
        if not args.quiet:
            print(f"lint-plan: no plan file at {args.plan} (nothing to lint)")
        return 0
    text = open(args.plan, encoding="utf-8").read()
    items = [it for it in parse_items(text) if args.all or not it["checked"]]

    total, scope_notes = 0, 0
    for idx, item in enumerate(items, 1):
        violations = lint_item(item, root)
        advisories = []
        if scope_active:
            sv, advisories = scope_check(item, focus, context)
            violations += sv
        if violations:
            total += len(violations)
            if not args.quiet:
                print(f"item {idx} (line {item['line']}): {item['title'] or '<untitled>'}")
                for msg in violations:
                    print(f"  - {msg}")
        for msg in advisories:
            scope_notes += 1
            if not args.quiet:
                print(f"note: item {idx} '{item['title'] or '<untitled>'}': {msg}")

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
        note_total = notes + scope_notes
        suffix = f" ({note_total} advisory note(s))" if note_total else ""
        if total == 0:
            print(f"lint-plan: {n} item(s) OK{suffix}")
        else:
            print(f"lint-plan: {total} violation(s) across {n} item(s){suffix}")
    return 1 if total else 0


if __name__ == "__main__":
    sys.exit(main())
