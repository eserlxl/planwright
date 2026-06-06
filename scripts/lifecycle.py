#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Eser KUBALI
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Mechanizes planwright Stage 0 lifecycle housekeeping (SKILL.md "Stage 0 — Lifecycle
# housekeeping"), so the most error-prone bookkeeping has a deterministic, test-covered
# backing instead of being done by hand:
#
#   1. drain-completed — move every completed (`- [x]`) item to completed.md (append),
#      then FIFO-cap completed.md at 100 (drop the oldest from the top).
#   2. drain-rejected  — move every item carrying a `Status: Rejected` line to
#      rejected.md (append, preserving its `Rejection:` reason), FIFO-cap at 100.
#   3. reset-if-empty  — if no pending (`- [ ]`) items remain, DELETE plan.md (start
#      fresh). An empty plan is deleted, never archived; when pending items remain the
#      plan is left untouched so the next run merges into it.
#   housekeep — run 1 -> 2 -> 3 in order and print the Stage 0 report.
#
# Item parsing mirrors lint-plan.py: a checkbox line plus its indented continuation
# lines, with blocks separated by a blank line. It only edits files under --root.
#
#   python3 scripts/lifecycle.py housekeep --root .planwright
#   python3 scripts/lifecycle.py {drain-completed|drain-rejected|reset-if-empty} --root DIR

import argparse
import os
import re
import sys

FIFO_CAP = 100
CHECKBOX = re.compile(r"^- \[([ xX])\]")
REJECTED = re.compile(r"(?mi)^\s*Status:\s*Rejected\b")


def parse(text):
    """Split plan text into (preamble_lines, blocks). preamble = the lines before the
    first checkbox (the `# planwright Plan` header + Session comment). Each block is
    {checked, rejected, lines}, where lines is the verbatim checkbox line plus its
    indented continuation lines; blank lines separate blocks and are not kept inside one."""
    lines = text.splitlines()
    first = next((i for i, ln in enumerate(lines) if CHECKBOX.match(ln)), len(lines))
    preamble = lines[:first]
    blocks, cur = [], None
    for ln in lines[first:]:
        if CHECKBOX.match(ln):
            cur = {"checked": ln[3:4].lower() == "x", "lines": [ln]}
            blocks.append(cur)
        elif cur is not None and ln.startswith((" ", "\t")):
            cur["lines"].append(ln)
        elif ln.strip() == "":
            cur = None  # a blank line ends the current block
        else:
            # Non-indented, non-checkbox text between blocks (a header, note, or
            # separator) is kept as an `interstitial` block so parse()->render()
            # round-trips it instead of silently dropping it. Interstitials never
            # count as pending and are never drained (see reset_if_empty / drain).
            if cur is not None and cur.get("interstitial"):
                cur["lines"].append(ln)
            else:
                cur = {"interstitial": True, "checked": False, "lines": [ln]}
                blocks.append(cur)
    for b in blocks:
        b["rejected"] = bool(REJECTED.search("\n".join(b["lines"])))
    return preamble, blocks


def render(preamble, blocks):
    """Reassemble preamble + blocks into plan text (one blank line between blocks)."""
    parts = []
    pre = "\n".join(preamble).strip("\n")
    if pre:
        parts.append(pre)
    body = "\n\n".join("\n".join(b["lines"]) for b in blocks)
    if body:
        parts.append(body)
    return ("\n\n".join(parts) + "\n") if parts else ""


def read_blocks(path):
    # open() + handle the missing-file case rather than exists()-then-open, which
    # has a TOCTOU window if the file vanishes between the two calls.
    try:
        with open(path, encoding="utf-8") as fh:
            return parse(fh.read())
    except FileNotFoundError:
        return [], []


def write(path, preamble, blocks):
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(render(preamble, blocks))


def append_capped(path, new_blocks):
    """Append new_blocks to a lifecycle file, then keep only the most recent FIFO_CAP."""
    pre, existing = read_blocks(path)
    combined = existing + new_blocks
    if len(combined) > FIFO_CAP:
        combined = combined[len(combined) - FIFO_CAP:]
    write(path, pre, combined)


def drain(plan_path, target_path, pred):
    """Move blocks matching pred out of plan.md into target_path (FIFO-capped)."""
    pre, blocks = read_blocks(plan_path)
    moved = [b for b in blocks if pred(b)]
    if moved:
        append_capped(target_path, moved)
        write(plan_path, pre, [b for b in blocks if not pred(b)])
    return len(moved)


def reset_if_empty(plan_path):
    """Delete plan.md when it holds no pending (- [ ], non-rejected) item. Returns True
    if it was deleted. Pending items are left untouched (the next run merges into them)."""
    # open()/remove() with FileNotFoundError handling rather than exists()-then-act,
    # which races if the file is removed concurrently between check and use.
    try:
        with open(plan_path, encoding="utf-8") as fh:
            _, blocks = parse(fh.read())
    except FileNotFoundError:
        return False
    pending = [b for b in blocks
               if not b.get("interstitial") and not b["checked"] and not b["rejected"]]
    if not pending:
        try:
            os.remove(plan_path)
        except FileNotFoundError:
            return False
        return True
    return False


def main():
    ap = argparse.ArgumentParser(description="planwright Stage 0 lifecycle housekeeping.")
    ap.add_argument("command",
                    choices=["drain-completed", "drain-rejected", "reset-if-empty", "housekeep"])
    ap.add_argument("--root", default=".planwright",
                    help="the .planwright/ directory to operate on (default: .planwright)")
    ap.add_argument("--quiet", action="store_true", help="suppress the report line")
    args = ap.parse_args()
    # Validate the deletion boundary at the argument edge: reset_if_empty()
    # os.remove()s <root>/plan.md, so a --root carrying parent-directory traversal
    # could point the deletion outside the intended directory. Reject '..' components
    # (same posture as lint-plan.py's unsafe_surface); an explicit absolute/relative
    # root without traversal stays valid (the tool operates on arbitrary .planwright).
    if ".." in args.root.replace("\\", "/").split("/"):
        sys.stderr.write(
            f"lifecycle: --root '{args.root}' contains parent-directory traversal '..'\n")
        return 2
    root = args.root
    plan = os.path.join(root, "plan.md")
    completed = os.path.join(root, "completed.md")
    rejected = os.path.join(root, "rejected.md")

    compacted = rdrained = 0
    deleted = False
    if args.command in ("drain-completed", "housekeep"):
        compacted = drain(plan, completed, lambda b: b["checked"])
    if args.command in ("drain-rejected", "housekeep"):
        rdrained = drain(plan, rejected, lambda b: b["rejected"])
    if args.command in ("reset-if-empty", "housekeep"):
        deleted = reset_if_empty(plan)

    if not args.quiet:
        bits = []
        if args.command in ("drain-completed", "housekeep"):
            bits.append(f"compacted {compacted}")
        if args.command in ("drain-rejected", "housekeep"):
            bits.append(f"rejected-drained {rdrained}")
        if args.command in ("reset-if-empty", "housekeep"):
            bits.append(f"plan {'deleted (empty)' if deleted else 'kept'}")
        print("lifecycle: " + ", ".join(bits))
    return 0


if __name__ == "__main__":
    sys.exit(main())
