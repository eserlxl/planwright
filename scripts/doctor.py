#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Eser KUBALI
# SPDX-License-Identifier: GPL-3.0-or-later
#
# planwright preflight ("doctor") — a deterministic, test-covered check of the host
# environment so a run's degradations are reported up front instead of surfacing as
# silent fallbacks mid-pipeline. It inspects two seams:
#
#   1. Host tools — python3 (the bundled-script runtime), git (graph enumeration +
#      change-coupling + execute commits), rg/fd (fast scanning in Stage 1). Each is
#      reported present/absent with the version and exactly what degrades when absent.
#   2. Bundled-script resolution — the sibling scripts under this file's directory
#      (build-graph.py, lint-plan.py, lifecycle.py). This is the `<scripts>` seam the
#      SKILL.md resolves per "Procedure → Bundled scripts"; doctor confirms it from the
#      script's own location so a broken install is caught before Stage 1.5.
#
# It also reports whether the --root target is a git work tree (graph build needs one).
# Nothing is mutated. Exit status is 1 when any required check FAILs (missing git or a
# missing bundled script), else 0; WARN-level findings (missing rg/fd, non-repo target)
# never fail the exit code on their own.
#
#   python3 scripts/doctor.py --root .
#   python3 scripts/doctor.py --root . --json
#
# Severity: ok (no impact) · warn (degraded, run still works) · fail (a core capability
# is unavailable). The runtime that executes this file is, by definition, a working
# python3 — so that check always passes; it is reported for completeness.

import argparse
import json
import os
import shutil
import subprocess
import sys

# Bundled scripts that the SKILL.md resolves via the <scripts> seam. Each must sit
# next to this file; a missing one means a broken/partial install.
BUNDLED = [
    ("build-graph.py", "Stage 1.5 code-graph build (centrality, cycles, scope)"),
    ("lint-plan.py", "Stage 11 / Execute structural plan lint"),
    ("lifecycle.py", "Stage 0 lifecycle housekeeping (drain / FIFO / reset)"),
]


def _tool_version(exe):
    """Best-effort one-line version string for an executable, or '' if it cannot run."""
    for flag in ("--version", "version", "-V"):
        try:
            out = subprocess.run([exe, flag], capture_output=True, text=True, timeout=5)
        except (OSError, subprocess.SubprocessError):
            continue
        text = (out.stdout or out.stderr).strip()
        if text:
            return text.splitlines()[0].strip()
    return ""


def check_tools():
    """Return records for python3 / git / rg / fd. python3 is the running interpreter."""
    recs = []

    # python3 — the bundled-script runtime. We are running under it, so it is present;
    # report the interpreter actually in use (not whatever `python3` resolves to on PATH).
    pyver = "Python %d.%d.%d" % sys.version_info[:3]
    recs.append({
        "name": "python3", "status": "ok", "detail": pyver,
        "degrades": "bundled scripts (build-graph/lint-plan/lifecycle) fall back to the "
                    "by-hand SKILL.md specs",
    })

    git = shutil.which("git")
    recs.append({
        "name": "git",
        "status": "ok" if git else "fail",
        "detail": _tool_version("git") if git else "not found on PATH",
        "degrades": "no graph file enumeration, no change-coupling edges, and Execute "
                    "cannot commit per item",
    })

    rg = shutil.which("rg")
    recs.append({
        "name": "rg (ripgrep)",
        "status": "ok" if rg else "warn",
        "detail": _tool_version("rg") if rg else "not found on PATH",
        "degrades": "Stage 1 scanning falls back to slower grep/find (build-graph.py "
                    "reads files itself and is unaffected)",
    })

    fd = shutil.which("fd") or shutil.which("fdfind")
    recs.append({
        "name": "fd",
        "status": "ok" if fd else "warn",
        "detail": _tool_version(fd) if fd else "not found on PATH (optional)",
        "degrades": "file enumeration falls back to git ls-files / find (no functional loss)",
    })
    return recs


def check_scripts():
    """Return one record per bundled script, resolved from THIS file's directory — the
    same <scripts> seam the SKILL.md uses."""
    here = os.path.dirname(os.path.abspath(__file__))
    recs = []
    for name, purpose in BUNDLED:
        path = os.path.join(here, name)
        present = os.path.isfile(path)
        recs.append({
            "name": "<scripts>/" + name,
            "status": "ok" if present else "fail",
            "detail": path if present else "missing at " + path,
            "degrades": purpose + " unavailable (a broken install)",
        })
    return recs


def check_target(root):
    """Report whether --root is inside a git work tree (the graph build needs one)."""
    is_repo = False
    if shutil.which("git"):
        try:
            out = subprocess.run(
                ["git", "-C", root, "rev-parse", "--is-inside-work-tree"],
                capture_output=True, text=True, timeout=5,
            )
            is_repo = out.returncode == 0 and out.stdout.strip() == "true"
        except (OSError, subprocess.SubprocessError):
            is_repo = False
    return [{
        "name": "target is a git repo",
        "status": "ok" if is_repo else "warn",
        "detail": os.path.abspath(root) + (" (git work tree)" if is_repo
                                           else " (not a git work tree)"),
        "degrades": "graph build cannot enumerate tracked files; planning runs without "
                    "graph-aware ranking",
    }]


GLYPH = {"ok": "ok  ", "warn": "WARN", "fail": "FAIL"}


def report(records, quiet):
    """Print the human-readable report and return the process exit code."""
    fails = sum(1 for r in records if r["status"] == "fail")
    warns = sum(1 for r in records if r["status"] == "warn")
    if not quiet:
        print("planwright doctor — preflight")
        for r in records:
            print("  [%s] %s — %s" % (GLYPH[r["status"]], r["name"], r["detail"]))
            if r["status"] != "ok":
                print("         degrades: %s" % r["degrades"])
        verdict = "FAIL" if fails else ("WARN" if warns else "OK")
        print("doctor: %s (%d fail, %d warn, %d total)"
              % (verdict, fails, warns, len(records)))
    return 1 if fails else 0


def main():
    ap = argparse.ArgumentParser(description="planwright environment preflight (doctor).")
    ap.add_argument("--root", default=".",
                    help="the target repo to plan (default: current directory)")
    ap.add_argument("--json", action="store_true",
                    help="emit the findings as JSON instead of the readable report")
    ap.add_argument("--quiet", action="store_true",
                    help="suppress the readable report (exit code only)")
    args = ap.parse_args()

    records = check_tools() + check_scripts() + check_target(args.root)
    fails = sum(1 for r in records if r["status"] == "fail")

    if args.json:
        warns = sum(1 for r in records if r["status"] == "warn")
        payload = {
            "ok": fails == 0,
            "fail": fails,
            "warn": warns,
            "total": len(records),
            "checks": records,
        }
        print(json.dumps(payload, indent=2))
        return 1 if fails else 0

    return report(records, args.quiet)


if __name__ == "__main__":
    sys.exit(main())
