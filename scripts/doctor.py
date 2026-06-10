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
#      (build-graph.py, lint-plan.py, lifecycle.py, status.py, check-links.py,
#      plan_parse.py, state.py, lint-final.py — the full BUNDLED set below). This is the `<scripts>`
#      seam the SKILL.md resolves per "Procedure → Bundled scripts"; doctor confirms it
#      from the script's own location so a broken install is caught before Stage 1.5.
#
# It also reports whether the --root target is a git work tree (graph build needs one),
# whether that tree gitignores .planwright/ — the directory MISSION.md keeps all tool
# state (plan, graph memory, digest, final point) under; a repo that forgets to ignore
# it commits that state as noise — and whether a git commit identity is configured (the
# Execute/Cycle paths commit per item, so an unset user.name/user.email fails mid-run).
# Nothing is mutated. Exit status is 1 when any required check FAILs (missing git or a
# missing bundled script), else 0; WARN-level findings (missing rg/fd, non-repo target,
# un-ignored .planwright/, unset commit identity) never fail the exit code on their own.
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
    ("status.py", "the `status` read-only planning-state summary"),
    ("check-links.py", "the intra-repo Markdown link-check verification command"),
    ("plan_parse.py", "the canonical plan.md parser (status.py / lint-plan.py import it)"),
    ("state.py", "the dashboard /state.json snapshot source (state.collect)"),
    ("lint-final.py", "the Stage 11 final.md / final-point validator"),
    # Dispatched through the same <scripts> seam by their commands — a partial
    # install missing either previously passed doctor clean and failed at launch.
    ("dashboard.py", "the read-only live dashboard server (`planwright dashboard`)"),
    # The server resolves its whole UI from <scripts>/dashboard/; without the asset
    # tree it launches, prints a healthy URL, and serves 404s — a SILENT partial
    # install the dashboard.py check alone cannot catch. index.html loads every asset
    # below by hard path, so a guard that checks only the shell still misses a tree
    # that 404s every script/style — list each load-bearing asset index.html requires.
    ("dashboard/index.html", "the dashboard static UI shell (served by dashboard.py)"),
    ("dashboard/style.css", "the dashboard stylesheet (index.html loads it; absent = unstyled UI)"),
    ("dashboard/app.js", "the dashboard SPA bootstrap (absent = blank app, every view dead)"),
    ("dashboard/vendor/derive.js", "the shared state-derivation logic (every view consumes it)"),
    ("dashboard/vendor/graph.js", "the 3D coupling-graph renderer (Graph view)"),
    ("dashboard/views/console.js", "the Console (convergence reactor) view"),
    ("dashboard/views/plan.js", "the Plan view"),
    ("dashboard/views/timeline.js", "the Timeline view"),
    ("dashboard/views/graph.js", "the Graph (coupling globe) view"),
    ("dashboard/views/insights.js", "the Insights (risk/hotspot/frontier) view"),
    ("dashboard/views/commands.js", "the Commands (recommended next sweep) view"),
    ("dashboard/views/doctor.js", "the Doctor (environment preflight) view"),
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


def check_gitignore(root):
    """Report whether the target gitignores .planwright/ — the tool-state directory
    MISSION.md keeps plan/graph/digest/final-point under. WARN (never FAIL) when the
    work tree does NOT ignore it (the run still works, but tool state would be
    committed as noise); ok when it is ignored, or n/a when there is no git work tree
    to judge against (the target check already warns on that)."""
    ignored = None  # tri-state: True ignored, False not ignored, None undeterminable
    if shutil.which("git"):
        try:
            inside = subprocess.run(
                ["git", "-C", root, "rev-parse", "--is-inside-work-tree"],
                capture_output=True, text=True, timeout=5,
            )
            if inside.returncode == 0 and inside.stdout.strip() == "true":
                # Probe a representative path UNDER .planwright/ rather than the bare
                # directory: a `.planwright/` ignore rule is directory-only, so git will
                # not match the non-existent bare path `.planwright`, but it does match the
                # prefix of `.planwright/plan.md` whether or not anything exists yet.
                # git check-ignore: exit 0 = path is ignored, 1 = not ignored, 128 = error.
                chk = subprocess.run(
                    ["git", "-C", root, "check-ignore", "-q", ".planwright/plan.md"],
                    capture_output=True, text=True, timeout=5,
                )
                if chk.returncode in (0, 1):
                    ignored = chk.returncode == 0
        except (OSError, subprocess.SubprocessError):
            ignored = None
    if ignored is True:
        status, detail = "ok", ".planwright/ is gitignored"
    elif ignored is False:
        status, detail = "warn", ".planwright/ is NOT gitignored in " + os.path.abspath(root)
    else:
        status, detail = "ok", "n/a (no git work tree to check)"
    return [{
        "name": ".planwright/ is gitignored",
        "status": status,
        "detail": detail,
        "degrades": "planwright's plan, graph memory, and digest under .planwright/ would be "
                    "committed as repo noise; add `.planwright/` to .gitignore",
    }]


def check_git_identity(root):
    """Report whether a git commit identity is configured. The Execute and Cycle paths
    commit every passing item, so an unset user.name/user.email makes each per-item
    `git commit` fail mid-run with a confusing error. WARN (never FAIL — planning does
    not commit) when either is unset; ok when both resolve; n/a when there is no git."""
    name = email = None
    if shutil.which("git"):
        def cfg(key):
            try:
                out = subprocess.run(["git", "-C", root, "config", key],
                                     capture_output=True, text=True, timeout=5)
                return out.stdout.strip() if out.returncode == 0 else ""
            except (OSError, subprocess.SubprocessError):
                return None
        name, email = cfg("user.name"), cfg("user.email")
    if name is None or email is None:
        status, detail = "ok", "n/a (git unavailable)"
    elif name and email:
        status, detail = "ok", "user.name and user.email are set"
    else:
        missing = " and ".join(k for k, v in (("user.name", name), ("user.email", email)) if not v)
        status, detail = "warn", "git %s is unset" % missing
    return [{
        "name": "git commit identity",
        "status": status,
        "detail": detail,
        "degrades": "Execute/Cycle per-item `git commit` will fail until git user.name "
                    "and user.email are configured (git config --global user.name/.email)",
    }]


GLYPH = {"ok": "ok  ", "warn": "WARN", "fail": "FAIL"}


def report(records, quiet, strict=False):
    """Print the human-readable report and return the process exit code. By default
    only a `fail` sets a non-zero code; --strict also fails on any `warn` so a CI
    preflight can require a pristine (not merely runnable) environment."""
    fails = sum(1 for r in records if r["status"] == "fail")
    warns = sum(1 for r in records if r["status"] == "warn")
    if not quiet:
        print("planwright doctor — preflight")
        for r in records:
            print("  [%s] %s — %s" % (GLYPH[r["status"]], r["name"], r["detail"]))
            if r["status"] != "ok":
                print("         degrades: %s" % r["degrades"])
        verdict = "FAIL" if fails else ("WARN" if warns else "OK")
        strict_note = " [--strict: warn → fail]" if (strict and warns and not fails) else ""
        print("doctor: %s (%d fail, %d warn, %d total)%s"
              % (verdict, fails, warns, len(records), strict_note))
    return 1 if (fails or (strict and warns)) else 0


def apply_gitignore_fix(root):
    """Auto-remediate the one fixable warn: if the work tree does not ignore .planwright/,
    append a `.planwright/` rule to <root>/.gitignore (creating it if absent) and return
    the gitignore path; else None. The other warns are deliberately not auto-fixed — an
    unset git identity needs the user's name/email and a missing rg/fd cannot be installed
    from here. Mirrors lint-plan --fix: an opt-in, narrow, reviewable write."""
    if check_gitignore(root)[0]["status"] != "warn":
        return None
    gi = os.path.join(root, ".gitignore")
    try:
        # errors="replace": the read only feeds the line-membership check and the
        # trailing-newline probe, both safe under replacement chars — a non-UTF-8
        # byte elsewhere in the file must not abort the whole preflight (the append
        # below writes pure ASCII regardless).
        with open(gi, encoding="utf-8", errors="replace") as fh:
            existing = fh.read()
    except OSError:
        existing = ""
    if ".planwright/" in [ln.strip() for ln in existing.splitlines()]:
        return None
    try:
        with open(gi, "a", encoding="utf-8") as fh:
            if existing and not existing.endswith("\n"):
                fh.write("\n")
            fh.write(".planwright/\n")
    except OSError:
        return None
    return gi


def collect(root: str) -> dict:
    """Build the full preflight payload (READ-ONLY): every check record plus the
    fail/warn/total tally and an overall `ok` flag. This is the single source the
    `--json` CLI path and the dashboard's read-only /doctor.json endpoint both render.
    It never writes — the one remediating write lives in apply_gitignore_fix(), reached
    only via `--fix`, never from here."""
    records = (check_tools() + check_scripts() + check_target(root)
               + check_gitignore(root) + check_git_identity(root))
    fails = sum(1 for r in records if r["status"] == "fail")
    warns = sum(1 for r in records if r["status"] == "warn")
    return {"ok": fails == 0, "fail": fails, "warn": warns,
            "total": len(records), "checks": records}


def main():
    ap = argparse.ArgumentParser(description="planwright environment preflight (doctor).")
    ap.add_argument("--root", default=".",
                    help="the target repo to plan (default: current directory)")
    ap.add_argument("--json", action="store_true",
                    help="emit the findings as JSON instead of the readable report")
    ap.add_argument("--quiet", action="store_true",
                    help="suppress the readable report (exit code only)")
    ap.add_argument("--strict", action="store_true",
                    help="also exit non-zero on any warn (un-ignored .planwright/, unset "
                         "git identity, missing rg/fd), so CI can require a pristine env")
    ap.add_argument("--fix", action="store_true",
                    help="auto-remediate the one fixable warn by adding `.planwright/` to "
                         ".gitignore (the other warns need the user); then re-check")
    args = ap.parse_args()

    fixed = apply_gitignore_fix(args.root) if args.fix else None

    payload = collect(args.root)
    records = payload["checks"]
    fails = payload["fail"]

    if args.json:
        if args.fix:
            payload["fixed"] = fixed
        print(json.dumps(payload, indent=2))
        return 1 if (fails or (args.strict and payload["warn"])) else 0

    if fixed and not args.quiet:
        print("doctor: fixed — added `.planwright/` to " + fixed)
    return report(records, args.quiet, args.strict)


if __name__ == "__main__":
    sys.exit(main())
