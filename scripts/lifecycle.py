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
# It also mechanizes a deliberate full cold-start reset (NOT part of Stage 0):
#   reset (aka fresh / clean) — clear the .planwright/ tool-state directory so the next run
#      rebuilds graph + plan + final point from scratch (re-surfacing work an incremental
#      final point would skip). It deliberately KEEPS rejected.md in place: the rejection
#      feedback memory (Stage 1 PREVIOUSLY REJECTED) is the one piece that is not in git and
#      does not regenerate, and retaining it stops the cold-start run from re-proposing
#      already-rejected, known-bad work. Everything else (graph/digest/plan/final/completed/
#      state…) is regenerable or recorded in git, so it is removed.
#
# Item parsing ROUTES THROUGH plan_parse.parse_items (its `span` field is the block
# boundary), so this file shares the one canonical recognizer with lint-plan.py,
# state.py, and status.py instead of keeping a lockstep copy. It only edits files
# under --root.
#
#   python3 scripts/lifecycle.py housekeep --root .planwright
#   python3 scripts/lifecycle.py {drain-completed|drain-rejected|reset-if-empty} --root DIR
#   python3 scripts/lifecycle.py reset --root .planwright   (keeps rejected.md)

import argparse
import json
import os
import shutil
import sys
import tempfile

# plan_parse.py sits beside this script and owns the plan format (the single
# recognizer lint-plan/state/status already route through).
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from plan_parse import parse_items  # noqa: E402

FIFO_CAP = 100


def parse(text):
    """Split plan text into (preamble_lines, blocks). preamble = the lines before the
    first checkbox (the `# planwright Plan` header + Session comment). Each block is
    {checked, rejected, lines}, where lines is the verbatim checkbox line plus its
    attached continuation lines (interior blanks intact, so parse()->render()
    round-trips). Block boundaries come from the canonical parser's `span`
    (plan_parse.parse_items) — the format is recognised in exactly one place, so this
    file can no longer silently diverge from what lint-plan accepted. Lines no item
    claims (a header, note, or separator between blocks) are kept as `interstitial`
    blocks; interstitials never count as pending and are never drained (see
    reset_if_empty / drain)."""
    lines = text.splitlines()
    items = parse_items(lines)
    first = items[0]["span"][0] if items else len(lines)
    preamble = lines[:first]
    blocks = []
    span_by_start = {it["span"][0]: it for it in items}
    cur_inter = None
    i = first
    while i < len(lines):
        it = span_by_start.get(i)
        if it is not None:
            s, e = it["span"]
            # Rejection comes from the canonical parser's FIELD capture re-run over
            # THE SLICE ITSELF, so the flag can only ever reflect bytes the drain
            # actually moves. Classifying from the whole-document parse was wrong
            # twice over: a raw-text regex mis-drained column-0 prose wraps, and the
            # document-level fields can include a Status captured BEYOND the span
            # (plan_parse keeps capturing after a column-0 interstitial closes the
            # boundary) — which drained a live item the marker line never belonged to.
            slice_items = parse_items(lines[s:e + 1])
            rejected = bool(slice_items) and (
                slice_items[0]["fields"].get("Status", "").strip().lower() == "rejected")
            blocks.append({"checked": it["checked"], "rejected": rejected,
                           "lines": lines[s:e + 1]})
            cur_inter = None
            i = e + 1
            continue
        ln = lines[i]
        if ln.strip() == "":
            cur_inter = None  # a blank line ends an interstitial run
        else:
            if cur_inter is None:
                # Interstitials are never pending and never drained — rejected is
                # structurally False (they carry no fields).
                cur_inter = {"interstitial": True, "checked": False,
                             "rejected": False, "lines": []}
                blocks.append(cur_inter)
            cur_inter["lines"].append(ln)
        i += 1
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
    """Write atomically: render to a temp file in the target's own directory, then
    os.replace() it onto the target. A plain open(path, "w") truncates the file before
    the new content is written, so a housekeep interrupted (Ctrl-C / crash / OOM) between
    the truncate and the completed write would leave plan.md/completed.md/rejected.md
    truncated, silently losing tracked items. A same-directory temp keeps the rename on
    one filesystem (so os.replace is atomic); on any failure the temp is removed and the
    error re-raised, leaving the original target untouched."""
    data = render(preamble, blocks)
    d = os.path.dirname(path) or "."
    fd, tmp = tempfile.mkstemp(dir=d, prefix=".lifecycle-", suffix=".tmp")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            fh.write(data)
        os.replace(tmp, path)
    except BaseException:
        try:
            os.remove(tmp)
        except OSError:
            pass
        raise


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
    """Delete plan.md when it holds no pending (- [ ], non-rejected) item AND no
    undrained rejected item. Returns True if it was deleted. Pending items are left
    untouched (the next run merges into them). An undrained Status: Rejected block —
    the intermediate state execute creates before drain_rejected runs — also blocks
    deletion: its Rejection: reason is the irreplaceable feedback memory, and deleting
    the plan here would destroy it before it ever reaches rejected.md. (A no-op for
    housekeep, which drains rejected blocks before calling this.)"""
    # open()/remove() with FileNotFoundError handling rather than exists()-then-act,
    # which races if the file is removed concurrently between check and use.
    try:
        with open(plan_path, encoding="utf-8") as fh:
            _, blocks = parse(fh.read())
    except FileNotFoundError:
        return False
    blocking = [b for b in blocks
                if not b.get("interstitial") and (not b["checked"] or b["rejected"])]
    if not blocking:
        try:
            os.remove(plan_path)
        except FileNotFoundError:
            return False
        return True
    return False


RESET_KEEP = {"rejected.md"}


def reset_planwright(root):
    """Reset the .planwright/ state directory for a deliberate cold start: remove every
    entry so the next run rebuilds graph + plan + final point from scratch, EXCEPT
    rejected.md, which is kept in place. The rejection feedback memory (Stage 1 PREVIOUSLY
    REJECTED) is the one piece of state that is not in git and does not regenerate, and
    retaining it stops the cold-start run from re-proposing already-rejected, known-bad
    work; everything else is regenerable (graph/digest/plan/final/state) or recorded in git
    (completed history). Returns (count_of_entries_cleared, rejected_kept) — rejected_kept
    is True when a rejected.md was present and preserved. A missing root, or a root holding
    nothing but the kept file(s), is a clean no-op."""
    if not os.path.isdir(root):
        return 0, False
    rejected_kept = os.path.isfile(os.path.join(root, "rejected.md"))
    entries = [e for e in sorted(os.listdir(root)) if e not in RESET_KEEP]
    for e in entries:
        p = os.path.join(root, e)
        # islink first: a symlink to a directory must be unlinked (os.remove), not
        # followed and rmtree'd, so the link's target is never touched.
        if os.path.isdir(p) and not os.path.islink(p):
            shutil.rmtree(p)
        else:
            os.remove(p)
    return len(entries), rejected_kept


def main():
    ap = argparse.ArgumentParser(description="planwright Stage 0 lifecycle housekeeping.")
    ap.add_argument("command",
                    choices=["drain-completed", "drain-rejected", "reset-if-empty", "housekeep",
                             "reset", "fresh", "clean"])
    ap.add_argument("--root", default=".planwright",
                    help="the .planwright/ directory to operate on (default: .planwright)")
    ap.add_argument("--quiet", action="store_true", help="suppress the report line")
    ap.add_argument("--json", action="store_true",
                    help="emit the report as a JSON object (command/compacted/rejected_drained/"
                         "plan_deleted for housekeep; command/cleared/rejected_kept for reset) for CI "
                         "(parity with the sibling scripts); --quiet still suppresses all output")
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

    if args.command in ("reset", "fresh", "clean"):
        cleared, rejected_kept = reset_planwright(root)
        if not args.quiet and args.json:
            print(json.dumps({"command": "reset", "cleared": cleared, "rejected_kept": rejected_kept}))
        elif not args.quiet:
            noun = "entry" if cleared == 1 else "entries"
            if cleared == 0:
                print(f"lifecycle: nothing to reset ({root} already clean)")
            else:
                tail = ", kept rejected.md (rejection memory retained)" if rejected_kept else ""
                print(f"lifecycle: reset {cleared} {noun}{tail}")
        return 0

    plan = os.path.join(root, "plan.md")
    completed = os.path.join(root, "completed.md")
    rejected = os.path.join(root, "rejected.md")

    compacted = rdrained = 0
    deleted = False
    try:
        if args.command in ("drain-completed", "housekeep"):
            compacted = drain(plan, completed, lambda b: b["checked"])
        if args.command in ("drain-rejected", "housekeep"):
            rdrained = drain(plan, rejected, lambda b: b["rejected"])
        if args.command in ("reset-if-empty", "housekeep"):
            deleted = reset_if_empty(plan)
    except (UnicodeDecodeError, NotADirectoryError, IsADirectoryError, PermissionError) as e:
        # Fail CLOSED, cleanly: a plan we cannot read (non-UTF-8 bytes, a file passed
        # as --root, permissions) must never be rewritten or deleted — swallowing to
        # "no blocks" would let housekeep destroy state it could not even parse.
        sys.stderr.write(f"lifecycle: cannot read {plan} ({e.__class__.__name__}: {e}); "
                         "nothing was modified\n")
        return 2

    if not args.quiet and args.json:
        report = {"command": args.command}
        if args.command in ("drain-completed", "housekeep"):
            report["compacted"] = compacted
        if args.command in ("drain-rejected", "housekeep"):
            report["rejected_drained"] = rdrained
        if args.command in ("reset-if-empty", "housekeep"):
            report["plan_deleted"] = deleted
        print(json.dumps(report))
    elif not args.quiet:
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
