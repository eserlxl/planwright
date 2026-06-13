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
# It also mechanizes the execute path's per-item "On PASS" bookkeeping (SKILL.md
# Execute step 4, NOT part of Stage 0):
#   land <N> --commit <short-sha> — flip pending item N (1-based over the pending,
#      non-rejected blocks in plan order — the same numbering `execute N` uses) to
#      checked, append the `Commit: <short-sha>` provenance stamp, and drain exactly
#      that block to completed.md (FIFO cap 100), leaving every other block
#      byte-identical. One tested step instead of four hand-rolled ones.
#   reject <N> --reason "<one-line>" — append the canonical `Status: Rejected` and
#      `Rejection: <reason>` continuation lines to pending item N (same numbering)
#      and drain exactly that block to rejected.md (FIFO cap 100). The exact
#      Status: Rejected spelling is what the drain and the next plan's PREVIOUSLY
#      REJECTED reader key on — mechanizing it keeps the feedback loop machine-readable.
#   reconcile --commit <sha> --mode <mode> [--title T] — record an ALREADY-committed fix
#      as a completed item when the work landed in git WITHOUT a plan.md item to land
#      (an inline codshard/codvisor/execute fix that was committed directly). Resolves
#      <sha> to its short sha + commit subject (in the repo that is the parent of --root,
#      or --repo) and appends a canonical `- [x] <title>` / `Mode:` / `Commit:` block to
#      completed.md (FIFO cap 100). Idempotent by short sha, and git-verified so it can
#      never record a fix that is not a real commit. This is the escape hatch that keeps
#      the "a committed fix is ALWAYS recorded as completed" contract satisfiable for work
#      that did not flow through plan.md -> land.
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
#   python3 scripts/lifecycle.py land <N> --commit <short-sha> --root DIR
#   python3 scripts/lifecycle.py reject <N> --reason "<one-line>" --root DIR
#   python3 scripts/lifecycle.py reconcile --commit <sha> --mode <mode> --root DIR
#   python3 scripts/lifecycle.py reset --root .planwright   (keeps rejected.md)

import argparse
import contextlib
import json
import os
import shutil
import subprocess
import sys
import tempfile

try:
    import fcntl  # POSIX-only; absent on non-POSIX, where the state lock degrades to a no-op.
except ImportError:  # pragma: no cover - only reached on non-POSIX platforms
    fcntl = None

# plan_parse.py sits beside this script and owns the plan format (the single
# recognizer lint-plan/state/status already route through).
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from plan_parse import parse_items  # noqa: E402

FIFO_CAP = 100
LOCK_NAME = ".lifecycle.lock"
# The plan modes lint-plan/SKILL.md recognise; reconcile records one onto a completed item.
VALID_MODES = ("develop", "improve", "repair", "docs", "reorganize")


@contextlib.contextmanager
def _state_lock(root):
    """Serialize a whole multi-step state transaction against other planwright processes on
    the same .planwright/ directory. Holds an exclusive fcntl.flock on <root>/.lifecycle.lock
    for the duration of the `with` block, so two concurrent sessions cannot interleave the
    read/append/write steps of drain/land/reject/reset_if_empty: each individual write() is
    already atomic (mkstemp + os.replace), but the *transaction* spanning two files is not,
    and an interleave could lose or duplicate an item. Held once per CLI invocation in main(),
    so a housekeep's drain->drain->reset chain is one critical section rather than three.

    Degrades to a no-op — never raising — when fcntl is unavailable (non-POSIX) or the lock
    file cannot be created (e.g. <root> does not exist yet): there is then nothing to serialize
    against, and a best-effort advisory lock must never turn a working single-process run into a
    crash. flock is associated with the open file description, so callers must NOT nest two
    _state_lock blocks on the same root in one process (the second would deadlock)."""
    if fcntl is None:
        yield
        return
    try:
        fh = open(os.path.join(root, LOCK_NAME), "a+")
    except OSError:
        # <root> missing or not writable — nothing to lock against; proceed unguarded.
        yield
        return
    try:
        fcntl.flock(fh.fileno(), fcntl.LOCK_EX)
        try:
            yield
        finally:
            fcntl.flock(fh.fileno(), fcntl.LOCK_UN)
    finally:
        fh.close()


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


def _take_pending(plan_path, index):
    """Locate pending item `index` — 1-based over the pending (unchecked, non-rejected,
    non-interstitial) blocks in plan order, the same numbering `execute N` uses.
    Returns (preamble, blocks, block). Raises LookupError when no pending item `index`
    exists (including a missing plan.md, which has zero pending items)."""
    pre, blocks = read_blocks(plan_path)
    pending = [b for b in blocks
               if not b.get("interstitial") and not b["checked"] and not b["rejected"]]
    if index < 1 or index > len(pending):
        raise LookupError(
            f"no pending item {index} (plan has {len(pending)} pending item(s))")
    return pre, blocks, pending[index - 1]


def land(plan_path, target_path, index, commit):
    """The execute path's "On PASS" bookkeeping (SKILL.md Execute step 4) for ONE item,
    in one tested step: flip pending item `index`'s checkbox, append the
    `Commit: <commit>` provenance stamp as its last continuation line, and drain
    exactly that block to completed.md (FIFO-capped), leaving every other block
    byte-identical. Returns the landed item's title."""
    pre, blocks, block = _take_pending(plan_path, index)
    block["lines"][0] = block["lines"][0].replace("- [ ]", "- [x]", 1)
    block["checked"] = True
    block["lines"].append(f"      Commit: {commit}")
    append_capped(target_path, [block])
    write(plan_path, pre, [b for b in blocks if b is not block])
    return block["lines"][0].split("]", 1)[1].strip()


def reject(plan_path, target_path, index, reason):
    """The execute path's "On FAIL" / value-gate bookkeeping (SKILL.md Execute steps 1
    and 5) for ONE item, in one tested step: append the canonical `Status: Rejected`
    and `Rejection: <reason>` continuation lines to pending item `index` and drain
    exactly that block to rejected.md (FIFO-capped), leaving every other block
    byte-identical. The exact `Status: Rejected` spelling is what drain_rejected and
    the Stage 1 PREVIOUSLY REJECTED reader key on — mechanizing the append is what
    keeps the rejection feedback loop machine-readable. Returns the item's title."""
    pre, blocks, block = _take_pending(plan_path, index)
    block["lines"].append("      Status: Rejected")
    block["lines"].append(f"      Rejection: {reason}")
    block["rejected"] = True
    append_capped(target_path, [block])
    write(plan_path, pre, [b for b in blocks if b is not block])
    return block["lines"][0].split("]", 1)[1].strip()


def _git_commit_meta(repo, ref):
    """Resolve <ref> to (short_sha, subject) in the git repo <repo>. Raises LookupError
    when <ref> is not a commit there, or git is unavailable — reconcile must never record
    a fix that is not a real commit (that would be fabricated completed history)."""
    spec = ref + "^{commit}"
    try:
        subprocess.run(["git", "-C", repo, "rev-parse", "--verify", "--quiet", spec],
                       check=True, capture_output=True, text=True)
        short = subprocess.run(["git", "-C", repo, "rev-parse", "--short", spec],
                               check=True, capture_output=True, text=True).stdout.strip()
        subject = subprocess.run(["git", "-C", repo, "show", "-s", "--format=%s", spec],
                                 check=True, capture_output=True, text=True).stdout.strip()
    except (subprocess.CalledProcessError, FileNotFoundError) as e:
        raise LookupError(f"'{ref}' is not a commit in {repo}") from e
    if not short:
        raise LookupError(f"'{ref}' is not a commit in {repo}")
    return short, subject


def _already_recorded(completed_path, short_sha):
    """True when completed.md already carries a `Commit: <short_sha>` block, so reconcile
    is idempotent — re-recording the same commit is a no-op, never a duplicate."""
    _pre, blocks = read_blocks(completed_path)
    for b in blocks:
        for ln in b["lines"]:
            s = ln.strip()
            if s.startswith("Commit:") and s.split(":", 1)[1].strip() == short_sha:
                return True
    return False


def reconcile(completed_path, repo, ref, mode, title=None):
    """Record an already-committed fix as a completed item — for work that landed in git
    WITHOUT a plan.md item to land (an inline codshard/codvisor/execute fix committed
    directly). Resolves <ref> to its short sha + subject in <repo>, then appends a
    canonical `- [x] <title>` / `Mode: <mode>` / `Commit: <short-sha>` block to
    completed.md (FIFO-capped) so the dashboard's completed history reflects the fix.
    Idempotent: a commit already recorded (matched by short sha) is skipped. Returns
    (short_sha, title, recorded); recorded is False when it was already present."""
    short, subject = _git_commit_meta(repo, ref)
    item_title = (title or subject or short).strip()
    if _already_recorded(completed_path, short):
        return short, item_title, False
    block = {"checked": True, "rejected": False,
             "lines": [f"- [x] {item_title}",
                       f"      Mode: {mode}",
                       f"      Commit: {short}"]}
    append_capped(completed_path, [block])
    return short, item_title, True


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
                             "land", "reject", "reconcile", "reset", "fresh", "clean"])
    ap.add_argument("index", nargs="?", type=int, default=None,
                    help="pending item number, 1-based in plan order (land/reject only)")
    ap.add_argument("--root", default=".planwright",
                    help="the .planwright/ directory to operate on (default: .planwright)")
    ap.add_argument("--commit", default=None, metavar="SHA",
                    help="the landing commit's short sha to stamp on the item (land only)")
    ap.add_argument("--reason", default=None, metavar="TEXT",
                    help="the one-line Rejection: reason to record on the item (reject only)")
    ap.add_argument("--mode", default=None, metavar="MODE",
                    help="the plan mode to record on a reconciled item (reconcile only; one of "
                         "develop/improve/repair/docs/reorganize)")
    ap.add_argument("--title", default=None, metavar="TEXT",
                    help="override the recorded title (reconcile only; defaults to the commit subject)")
    ap.add_argument("--repo", default=None, metavar="DIR",
                    help="the git repo to resolve --commit against (reconcile only; defaults to "
                         "the parent of --root)")
    ap.add_argument("--quiet", action="store_true", help="suppress the report line")
    ap.add_argument("--json", action="store_true",
                    help="emit the report as a JSON object (command/compacted/rejected_drained/"
                         "plan_deleted for housekeep; command/cleared/rejected_kept for reset; "
                         "command/commit/title/mode/recorded for reconcile) for CI "
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
    # Reject NUL bytes and control characters too: the path feeds os.remove on
    # <root>/plan.md, and an exotic component should be refused at the edge rather than
    # reaching the filesystem (a NUL would raise mid-operation; a control char is never a
    # legitimate .planwright path).
    if any(ord(ch) < 0x20 or ch == "\x7f" for ch in args.root):
        sys.stderr.write(
            f"lifecycle: --root {args.root!r} contains a NUL or control character\n")
        return 2
    root = args.root

    # reconcile: record an already-committed fix into completed.md (no plan.md item to
    # land). Handled before the land/reject option guards because it legitimately uses
    # --commit. This is the contract escape hatch for work committed directly.
    if args.command == "reconcile":
        if args.index is not None or args.reason is not None:
            sys.stderr.write("lifecycle: reconcile takes --commit/--mode/--title/--repo, "
                             "not an item index or --reason\n")
            return 2
        commit = (args.commit or "").strip()
        # --commit is a git ref that also lands verbatim on a `Commit:` line: no whitespace/control.
        bad_commit = (not commit
                      or any(ch.isspace() or ord(ch) < 0x20 or ch == "\x7f" for ch in commit))
        mode = (args.mode or "").strip()
        if bad_commit or mode not in VALID_MODES:
            sys.stderr.write(
                "Usage: lifecycle.py reconcile --commit <sha> "
                "--mode <develop|improve|repair|docs|reorganize> "
                "[--title TEXT] [--repo DIR] [--root DIR]\n")
            return 2
        title = args.title
        if title is not None:
            title = title.strip()
            # the title lands on the `- [x] <title>` line, so it stays one clean line
            if not title or any(ord(ch) < 0x20 or ch == "\x7f" for ch in title):
                sys.stderr.write("lifecycle: --title must be a non-empty single line\n")
                return 2
        repo = args.repo or os.path.dirname(os.path.abspath(root))
        if not os.path.isdir(root):
            if os.path.exists(root):
                sys.stderr.write(f"lifecycle: --root {root!r} is not a directory; "
                                 "nothing was modified\n")
                return 2
            os.makedirs(root, exist_ok=True)
        try:
            with _state_lock(root):
                short, item_title, recorded = reconcile(
                    os.path.join(root, "completed.md"), repo, commit, mode, title)
        except LookupError as e:
            sys.stderr.write(f"lifecycle: {e}; nothing was modified\n")
            return 2
        except (UnicodeDecodeError, NotADirectoryError, IsADirectoryError, PermissionError) as e:
            sys.stderr.write(f"lifecycle: cannot read completed.md "
                             f"({e.__class__.__name__}: {e}); nothing was modified\n")
            return 2
        if not args.quiet and args.json:
            print(json.dumps({"command": "reconcile", "commit": short, "title": item_title,
                              "mode": mode, "recorded": recorded}))
        elif not args.quiet:
            if recorded:
                print(f"lifecycle: recorded commit {short} '{item_title}' "
                      f"(Mode: {mode}) -> completed.md")
            else:
                print(f"lifecycle: commit {short} already recorded -> completed.md (no change)")
        return 0

    # --mode/--title/--repo belong to reconcile alone; a stray one elsewhere is a mistype.
    if args.mode is not None or args.title is not None or args.repo is not None:
        sys.stderr.write("lifecycle: --mode, --title, and --repo are valid only with the "
                         "reconcile subcommand\n")
        return 2

    # The index positional, --commit, and --reason belong to land/reject alone; a
    # stray one on any other subcommand is a mis-typed invocation, not something to
    # silently ignore — as is the wrong option for the pair (land takes --commit,
    # reject takes --reason, never the other way around).
    if args.command not in ("land", "reject") and (
            args.index is not None or args.commit is not None or args.reason is not None):
        sys.stderr.write("lifecycle: <N>, --commit, and --reason are valid only with "
                         "the land/reject subcommands\n")
        return 2
    if (args.command == "land" and args.reason is not None) or (
            args.command == "reject" and args.commit is not None):
        sys.stderr.write("lifecycle: land takes --commit and reject takes --reason — "
                         "not the other way around\n")
        return 2

    if args.command in ("land", "reject"):
        if args.command == "land":
            usage = "Usage: lifecycle.py land <N> --commit <short-sha> [--root DIR]"
            value = (args.commit or "").strip()
            # The stamp lands verbatim on a `Commit:` continuation line, so a value
            # with whitespace or control characters would corrupt the block.
            bad_value = (not value
                         or any(ch.isspace() or ord(ch) < 0x20 or ch == "\x7f" for ch in value))
        else:
            usage = 'Usage: lifecycle.py reject <N> --reason "<one-line>" [--root DIR]'
            value = (args.reason or "").strip()
            # The reason is prose (spaces are fine) but stays one line: a newline or
            # control character would break the machine-readable Rejection: contract.
            bad_value = (not value
                         or any(ord(ch) < 0x20 or ch == "\x7f" for ch in value))
        if args.index is None or bad_value:
            sys.stderr.write(usage + "\n")
            return 2
        plan_path = os.path.join(root, "plan.md")
        try:
            with _state_lock(root):
                if args.command == "land":
                    title = land(plan_path, os.path.join(root, "completed.md"),
                                 args.index, value)
                else:
                    title = reject(plan_path, os.path.join(root, "rejected.md"),
                                   args.index, value)
        except LookupError as e:
            sys.stderr.write(f"lifecycle: {e}; nothing was modified\n")
            return 2
        except (UnicodeDecodeError, NotADirectoryError, IsADirectoryError, PermissionError) as e:
            # Fail CLOSED like the drains below: never rewrite state that cannot be read.
            sys.stderr.write(f"lifecycle: cannot read {plan_path} "
                             f"({e.__class__.__name__}: {e}); nothing was modified\n")
            return 2
        if not args.quiet and args.json:
            rec = {"command": args.command, "index": args.index, "title": title}
            rec["commit" if args.command == "land" else "reason"] = value
            print(json.dumps(rec))
        elif not args.quiet:
            if args.command == "land":
                print(f"lifecycle: landed item {args.index} '{title}' "
                      f"(Commit: {value}) -> completed.md")
            else:
                print(f"lifecycle: rejected item {args.index} '{title}' -> rejected.md")
        return 0

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
        with _state_lock(root):
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
