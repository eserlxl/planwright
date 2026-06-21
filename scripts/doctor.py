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
# Finally, when a final point is recorded it validates .planwright/final.md against
# lint-final's contract (WARN on a corrupt marker): status/the coach otherwise absorb a
# malformed point silently into a harden recommendation, so the preflight is the one place
# that surfaces it. Nothing is mutated. Exit status is 1 when any required check FAILs
# (missing git or a missing bundled script), else 0; WARN-level findings (missing rg/fd,
# non-repo target, un-ignored .planwright/, unset commit identity, corrupt final point)
# never fail the exit code on their own.
#
#   python3 scripts/doctor.py --root .
#   python3 scripts/doctor.py --root . --json
#
# Severity: ok (no impact) · warn (degraded, run still works) · fail (a core capability
# is unavailable). The runtime that executes this file is, by definition, a working
# python3 — so that check always passes; it is reported for completeness.

import argparse
import contextlib
import importlib.util
import io
import json
import os
import shutil
import socket
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
    ("registry.py", "the cross-repo dashboard project registry (dashboard.py imports it at module load; state.py registers running repos through it)"),
    ("lint-final.py", "the Stage 11 final.md / final-point validator"),
    # Dispatched through the same <scripts> seam by their commands — a partial
    # install missing any of these previously passed doctor clean and failed at launch.
    ("pr.py", "the `pr` PR-fixer ingest (open-PR review threads + failing CI become plan items)"),
    ("dashboard.py", "the read-only live dashboard server (`planwright dashboard`)"),
    # The server resolves its whole UI from <scripts>/dashboard/; without the asset
    # tree it launches, prints a healthy URL, and serves 404s — a SILENT partial
    # install the dashboard.py check alone cannot catch. index.html loads every asset
    # below by hard path, so a guard that checks only the shell still misses a tree
    # that 404s every script/style — list each load-bearing asset index.html requires.
    ("dashboard/index.html", "the dashboard static UI shell (served by dashboard.py)"),
    ("dashboard/style.css", "the dashboard stylesheet (index.html loads it; absent = unstyled UI)"),
    ("dashboard/app.js", "the dashboard SPA bootstrap (absent = blank app, every view dead)"),
    ("dashboard/ui.js", "shared UI fragments (PW_UI.contribCard; Console + Commands consume it)"),
    ("dashboard/vendor/derive.js", "the shared state-derivation logic (every view consumes it)"),
    ("dashboard/vendor/graph.js", "the 3D coupling-graph renderer (Graph view)"),
    ("dashboard/views/console.js", "the Console (convergence reactor) view"),
    ("dashboard/views/plan.js", "the Plan view"),
    ("dashboard/views/timeline.js", "the Timeline view"),
    ("dashboard/views/graph.js", "the Graph (coupling globe) view"),
    ("dashboard/views/insights.js", "the Insights (risk/hotspot/frontier) view"),
    ("dashboard/views/commands.js", "the Commands (recommended next sweep) view"),
    ("dashboard/views/shards.js", "the Shards (per-component maturity) view"),
    ("dashboard/views/fleet.js", "the Fleet (multi-project portfolio) view"),
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
        "degrades": "Stage 1 scanning falls back to git grep / git ls-files (still "
                    "gitignore-respecting; build-graph.py reads files itself and is unaffected)",
    })

    fd = shutil.which("fd") or shutil.which("fdfind")
    recs.append({
        "name": "fd",
        "status": "ok" if fd else "warn",
        "detail": _tool_version(fd) if fd else "not found on PATH (optional)",
        "degrades": "file enumeration falls back to git ls-files (gitignore-respecting; no functional loss)",
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
    """Report whether --root is inside a git work tree (the graph build needs one).
    A work tree with no commits yet (an unborn HEAD — a fresh `git init`) is reported
    as WARN, not ok: the Stage 1.5 graph build (build-graph.py) degrades *gracefully* on
    an unborn HEAD — it detects the empty `git rev-parse --verify --quiet HEAD` and builds
    a minimal graph rather than crashing — but the history-derived signals (change-coupling,
    git churn, the incremental dirty set) are absent until there is at least one commit.
    One commit up front unlocks them, so the WARN is a quality hint, not a blocker."""
    is_repo = False
    born = False
    if shutil.which("git"):
        try:
            out = subprocess.run(
                ["git", "-C", root, "rev-parse", "--is-inside-work-tree"],
                capture_output=True, text=True, timeout=5,
            )
            is_repo = out.returncode == 0 and out.stdout.strip() == "true"
            if is_repo:
                # An unborn HEAD rev-parses non-zero here; build-graph.py handles that
                # gracefully (empty/minimal graph), but a first commit unlocks the
                # history-derived signals. --quiet --verify keeps this probe silent.
                head = subprocess.run(
                    ["git", "-C", root, "rev-parse", "--quiet", "--verify", "HEAD"],
                    capture_output=True, text=True, timeout=5,
                )
                born = head.returncode == 0
        except (OSError, subprocess.SubprocessError):
            is_repo = born = False
    if is_repo and not born:
        return [{
            "name": "target is a git repo",
            "status": "warn",
            "detail": os.path.abspath(root) + " (git work tree, but no commits yet)",
            "degrades": "the Stage 1.5 graph build degrades gracefully on an unborn HEAD "
                        "(a minimal graph with no history-derived signals — change-coupling, "
                        "churn, the dirty set); make at least one commit "
                        "(`git add -A && git commit`) to unlock them",
        }]
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


def check_final_point(root):
    """Report whether a recorded final point (.planwright/final.md), when present, passes
    lint-final's structural contract. This is the one preflight surface for a corrupt final
    point: status.py absorbs a malformed final.md into fp_flag and the coach silently routes
    to a harden sweep, so an autonomous codmaster loop mis-drives with no diagnostic. WARN
    (never FAIL — a corrupt point degrades the recommendation but does not break a run) when
    it is present and invalid; ok when valid or absent (no final point is a legitimate
    open-ladder state). lint-final.py is loaded the same way status.py does (its hyphenated
    name is not a plain import); a load failure degrades to ok here — the BUNDLED check above
    already FAILs a missing/broken validator, so this must not double-report it."""
    here = os.path.dirname(os.path.abspath(__file__))
    lf = os.path.join(here, "lint-final.py")
    name = ".planwright/final.md is well-formed"
    degrades = ("a corrupt final point is silently absorbed by status / the coach (routes to "
                "a harden sweep with no diagnostic); run `python3 scripts/lint-final.py "
                "--root .` to see the contract violations")
    try:
        spec = importlib.util.spec_from_file_location("planwright_lint_final_doctor", lf)
        if spec is None or spec.loader is None:
            raise ImportError("no import spec")
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        # lint-final.collect() fails closed by printing the read/decode failure to stderr
        # (lint-final.py:70); doctor --quiet is an exit-code-only contract, so capture it —
        # the WARN status below is built from res, not from that stream.
        with contextlib.redirect_stderr(io.StringIO()):
            res = mod.collect(root)
    except Exception:
        return [{"name": name, "status": "ok",
                 "detail": "n/a (lint-final.py unavailable — see the bundled-script check above)",
                 "degrades": degrades}]
    if not res.get("present"):
        status, detail = "ok", "n/a (no final point recorded)"
    elif res.get("ok"):
        status, detail = "ok", "final.md passes the lint-final contract"
    else:
        viols = res.get("violations") or []
        extra = "" if len(viols) <= 1 else " (+%d more)" % (len(viols) - 1)
        status = "warn"
        detail = "final.md is malformed: %s%s" % (viols[0] if viols else "unknown", extra)
    return [{"name": name, "status": status, "detail": detail, "degrades": degrades}]


def check_dashboard_port(root):
    """Report whether the dashboard's stable default port (127.0.0.1:DEFAULT_PORT) is
    bindable. WARN (never FAIL — the dashboard reuses a running instance or falls back to an
    ephemeral port, so a busy home port never breaks a launch) when it is in use; ok when
    free. DEFAULT_PORT is read from dashboard.py via a GUARDED lazy import so this never
    crashes when dashboard.py is absent (the BUNDLED check above already FAILs that) or
    honors PW_DASH_PORT. Loopback-only, non-mutating: binds with SO_REUSEADDR and closes."""
    port = 8765
    try:
        import dashboard  # deferred: dashboard.py does `import doctor`, so a module-scope
        port = int(dashboard.DEFAULT_PORT)  # import here would be circular and crash an
    except Exception:                        # isolated single-file run.
        port = 8765
    name = "dashboard default port (127.0.0.1:%d) is bindable" % port
    degrades = ("`planwright dashboard` with no --port reuses a running instance or falls "
                "back to an ephemeral port, so a busy home port is benign; pass --port N "
                "or set PW_DASH_PORT to pin a known-free port")
    sock = None
    try:
        sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        sock.bind(("127.0.0.1", port))
        status, detail = "ok", "127.0.0.1:%d is free" % port
    except OSError:
        status, detail = "warn", "127.0.0.1:%d is in use (likely a running dashboard)" % port
    finally:
        if sock is not None:
            with contextlib.suppress(OSError):
                sock.close()
    return [{"name": name, "status": status, "detail": detail, "degrades": degrades}]


def check_node(root):
    """Informational: report whether `node` is on PATH. The dashboard client JS is exercised
    by a Node-gated harness and `node --check` validates view loadability; without Node those
    skip. Pure diagnostic — ALWAYS ok or warn, NEVER fail, even under --strict."""
    node = shutil.which("node")
    return [{
        "name": "node (dashboard client-JS preflight)",
        "status": "ok" if node else "warn",
        "detail": _tool_version("node") if node else "not found on PATH (optional)",
        "degrades": "the Node-gated dashboard client-JS checks (`node --check`, the view "
                    "render harness) are skipped; dashboard runtime is unaffected",
    }]


def check_dashboard_js(root):
    """Validate that the bundled dashboard client JS is syntactically loadable, not merely
    present. check_scripts above confirms each view/asset FILE exists; this confirms each
    actually parses, so a corrupt or truncated install (a half-written app.js, a broken view)
    is caught here instead of surfacing as a blank dashboard that 404s or throws in the
    browser. The .js inventory is derived from BUNDLED (the same install-completeness list),
    so a newly bundled view is covered automatically. Uses `node --check` per file when Node
    is on PATH; without Node the loadability check cannot run, so it degrades to ok (presence
    is already covered by the bundled-script check above). FAIL — a real broken install — only
    when Node is present and a present file fails to parse; a missing file is left to
    check_scripts so it is never double-reported."""
    here = os.path.dirname(os.path.abspath(__file__))
    js = [name for name, _ in BUNDLED if name.endswith(".js")]
    name = "dashboard client JS is loadable"
    degrades = ("a syntactically broken bundled view/asset script loads in the browser as a "
                "blank or throwing dashboard; reinstall planwright to restore the asset tree")
    node = shutil.which("node")
    if not node:
        return [{
            "name": name, "status": "ok",
            "detail": "n/a (node not on PATH; file presence is covered by the bundled-script check)",
            "degrades": degrades,
        }]
    broken, checked = [], 0
    for rel in js:
        path = os.path.join(here, rel)
        if not os.path.isfile(path):
            continue  # a missing file is already a FAIL in check_scripts — do not double-report
        checked += 1
        try:
            out = subprocess.run([node, "--check", path],
                                 capture_output=True, text=True, timeout=10)
        except (OSError, subprocess.SubprocessError):
            continue  # node could not run this file — unverifiable, not proof of breakage
        if out.returncode != 0:
            broken.append(rel)
    if broken:
        status = "fail"
        detail = "%d of %d client JS file(s) failed node --check: %s" % (
            len(broken), checked, ", ".join(broken))
    else:
        status = "ok"
        detail = "%d bundled client JS file(s) pass node --check" % checked
    return [{"name": name, "status": status, "detail": detail, "degrades": degrades}]


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
               + check_gitignore(root) + check_git_identity(root)
               + check_final_point(root) + check_dashboard_port(root)
               + check_node(root) + check_dashboard_js(root))
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
