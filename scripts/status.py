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
import time

# status.py lives in scripts/; when run as a script (or imported by state.py) that
# directory is sys.path[0], so the canonical plan parser imports directly.
import plan_parse


def _load_lint_final():
    """Load the sibling lint-final.py validator (its hyphenated name is not a plain import).
    Returns (module_or_None, status) where status is 'ok', 'absent', or 'broken'.

    A *genuinely absent* validator degrades silently (a valid state — 'absent'). A validator
    that is present but fails to load (a syntax/import error in lint-final.py) is a different
    beast ('broken'): swallowing it silently would disable the convergence gate without a
    trace, so warn to stderr AND refuse to certify convergence (see _final_valid) — a broken
    validator must fail the gate loudly, never pass it blind."""
    import importlib.util
    path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "lint-final.py")
    if not os.path.exists(path):
        return None, "absent"
    try:
        spec = importlib.util.spec_from_file_location("planwright_lint_final", path)
        if spec is None or spec.loader is None:
            print("planwright status: lint-final.py present but unloadable (no import spec); "
                  "convergence gate cannot certify and --exit-code will fail", file=sys.stderr)
            return None, "broken"
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        return mod, "ok"
    except Exception as exc:  # present but broken (syntax/import error) — never silent
        print("planwright status: lint-final.py present but failed to load (%s: %s); "
              "convergence gate cannot certify and --exit-code will fail"
              % (type(exc).__name__, exc), file=sys.stderr)
        return None, "broken"


_LINT_FINAL, _LINT_FINAL_STATUS = _load_lint_final()


def _final_valid(root):
    """True when the recorded final.md passes lint-final's structural contract (a non-empty
    sha, all four rungs marked dry with a reason, a valid deepest_tier). A *genuinely absent*
    validator falls back to True, so a missing validator never makes convergence stricter than
    the historical sha+pending check. A *present-but-broken* validator instead returns False:
    convergence must not be certified when the contract validator could not run, so --exit-code
    refuses (exit 1) rather than passing a CI gate blind. The same fail-closed rule applies when a
    loaded validator raises at *runtime* (collect() throws) — a verdict that could not be produced
    must never read as 'converged'."""
    if _LINT_FINAL is None:
        return _LINT_FINAL_STATUS != "broken"
    try:
        return bool(_LINT_FINAL.collect(root)["ok"])
    except Exception as exc:
        # A validator that loaded but raises mid-run cannot produce a trustworthy verdict.
        # Fail closed (return False) rather than certifying convergence blind — mirrors the
        # present-but-broken load-time branch above, and keeps --exit-code honest under a
        # future validator regression or a transient runtime fault.
        print("planwright status: lint-final validator raised at runtime (%s: %s); "
              "convergence gate cannot certify and --exit-code will fail"
              % (type(exc).__name__, exc), file=sys.stderr)
        return False


def _parse(path):
    """Parse a plan-style file through the one canonical parser, or [] when absent."""
    try:
        with open(path, encoding="utf-8") as fh:
            return plan_parse.parse_items(fh.read())
    except (OSError, ValueError):  # also degrade (not crash) on a non-UTF-8/undecodable file
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
    except (OSError, ValueError):  # also degrade (not crash) on a non-UTF-8/undecodable file
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


def _completed_modes(path):
    """Tally completed (`- [x]`/`- [X]`) items by their `Mode:` continuation line — same
    shape as _pending_modes (ordered by _MODE_ORDER, then "other"), so the counts sum to
    the completed total and the breakdown always reconciles. A missing file yields {}.
    Lets a maintainer see what *kind* of work actually landed, not just how much."""
    raw = {}
    for it in _parse(path):
        if not it["checked"]:
            continue
        mode = it["fields"].get("Mode", "").strip().lower()
        key = mode if mode in _MODE_ORDER else "other"
        raw[key] = raw.get(key, 0) + 1
    ordered = {m: raw[m] for m in _MODE_ORDER if raw.get(m)}
    if raw.get("other"):
        ordered["other"] = raw["other"]
    return ordered


def _last_landed(path):
    """The most recent completed block as {"title", "commit"} — the file is
    append-ordered (FIFO), so the last checked item is the newest landing. `commit`
    is the `Commit:` provenance stamp the execute path appends on pass ("" for
    history that predates the stamp). Returns None when completed.md is missing,
    unreadable, or holds no checked item."""
    last = None
    for it in _parse(path):
        if it["checked"]:
            last = it
    if last is None:
        return None
    return {"title": last["title"],
            "commit": last["fields"].get("Commit", "").strip()}


def _completed_ledger(path):
    """Every completed (`- [x]`) item as {"title", "mode", "commit"} in file (append/FIFO,
    i.e. chronological) order — the per-landing provenance ledger. `commit` is the `Commit:`
    stamp the execute path appends on pass ("" for history predating the stamp, like
    _last_landed). Reuses _parse + the same field reads _completed_modes/_last_landed already
    do, so it adds no new parsing surface. Returns [] when completed.md is missing/unreadable
    or holds no checked item."""
    out = []
    for it in _parse(path):
        if not it["checked"]:
            continue
        out.append({"title": it["title"],
                    "mode": it["fields"].get("Mode", "").strip().lower(),
                    "commit": it["fields"].get("Commit", "").strip()})
    return out


def _rejected_items(path):
    """Return rejected items as {"title","reason"} dicts, in file order. Each rejected
    entry is a `- [ ] <title>` (or `- [x]`) line followed by indented continuation lines;
    its reason is taken from the item's `Rejection:` continuation line ("" when absent, as
    a freshly value-gated reject may carry only `Status: Rejected`). A missing file yields
    an empty list — an absent rejected log is a valid state."""
    return [{"title": it["title"], "reason": it["fields"].get("Rejection", "")}
            for it in _parse(path)]


_CARRIED_HEADING = "## Carried dossier candidates"


def _carried_count(path):
    """Count the carried dossier candidates in the planning digest — the findings a
    prior run verified but cut at capacity (or deferred as unverifiable), which Stage 11
    records under a '## Carried dossier candidates' heading, one
    '[<rung> sev<k>, CUT|DEFERRED — …]' line each (hard cap 10). A converged-looking
    "0 pending" can silently sit on this backlog, so status surfaces the count.
    Entry lines are recognised by their leading '[' (after an optional '- ' bullet);
    the UNVERIFIED banner and prose never match. The section ends at the next '## '
    heading. A missing/undecodable file or absent section degrades to 0 — the same
    posture as the sibling readers. Routing/status only — never Evidence."""
    try:
        with open(path, encoding="utf-8") as fh:
            lines = fh.read().splitlines()
    except (OSError, ValueError):
        return 0
    count, in_section = 0, False
    for line in lines:
        if line.startswith("## "):
            in_section = line.strip() == _CARRIED_HEADING
            continue
        if not in_section or not line.strip():
            continue
        entry = line.strip()
        if entry.startswith("- "):
            entry = entry[2:].lstrip()
        if entry.startswith("["):
            count += 1
    return count


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
    deepest_tier/scope/invent_seed/invent_framing (each '' when absent) or None when
    there is no final-point file. `scope` matters: a component-scoped final point
    asserts dryness only for that component (SKILL.md Stage 11), so consumers must
    see it to avoid certifying whole-repo convergence from it; the invent pair is
    the seeded-run replay record."""
    try:
        with open(path, encoding="utf-8") as fh:
            text = fh.read()
    except (OSError, ValueError):  # also degrade (not crash) on a non-UTF-8/undecodable file
        return None
    fields = {"sha": "", "date": "", "deepest_tier": "", "scope": "",
              "invent_seed": "", "invent_framing": ""}
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


# ---- run-activity beacon (read side) -----------------------------------------------------
# The beacon is a deliberately tiny contract: one JSON object {command, started,
# updated[, detail]} in .planwright/activity.json. Freshness comes from the file
# MTIME, not the recorded fields — an interrupted agent run leaves the file behind
# with no process to clean it up, and the mtime is the one signal a leftover cannot
# keep current. A beacon that has not been (re-)stamped within PW_ACTIVITY_TTL
# seconds reads as stale. The read side lives HERE (not state.py) so this no-browser
# status surface can report a live or interrupted run without inverting the import
# direction: state.py imports status, never the reverse. The write path
# (state.py activity start|stop) delegates to these readers.

_ACTIVITY_TTL_DEFAULT = 3600.0


def _activity_ttl() -> float:
    """Stale cutoff in seconds (PW_ACTIVITY_TTL, positive float, silent fallback to
    3600 — the same read-validate-fallback shape as dashboard._env_float)."""
    raw = os.environ.get("PW_ACTIVITY_TTL")
    if raw:
        try:
            value = float(raw)
            if value > 0:
                return value
        except ValueError:
            pass
    return _ACTIVITY_TTL_DEFAULT


def _activity_path(root):
    return os.path.join(root, ".planwright", "activity.json")


def _read_activity(path):
    """The raw beacon dict plus its mtime, or (None, None) when absent, unreadable,
    malformed, or missing a usable command — every degradation reads as 'no beacon'
    because the dashboard surface must survive a torn or hand-edited file."""
    try:
        with open(path, encoding="utf-8") as fh:
            data = json.load(fh)
        mtime = os.stat(path).st_mtime
    except (OSError, ValueError):
        return None, None
    if not isinstance(data, dict):
        return None, None
    command = data.get("command")
    if not isinstance(command, str) or not command.strip():
        return None, None
    return data, mtime


def _activity_block(root):
    """Shape the beacon for state.json / status --json: {command, detail, started,
    age_seconds, stale} or None. age_seconds counts from the last stamp (file mtime);
    `stale` flips past the TTL so a reader can stop asserting a long-dead run is live."""
    data, mtime = _read_activity(_activity_path(root))
    if data is None or mtime is None:
        return None
    age = max(0, int(time.time() - mtime))
    detail = data.get("detail")
    started = data.get("started")
    return {
        "command": data["command"].strip(),
        "detail": detail.strip() if isinstance(detail, str) and detail.strip() else None,
        "started": started if isinstance(started, str) else None,
        "age_seconds": age,
        "stale": age > _activity_ttl(),
    }


def collect(root: str) -> dict:
    """Build the read-only state record from <root>/.planwright/."""
    pw = os.path.join(root, ".planwright")
    pending_titles = _pending_titles(os.path.join(pw, "plan.md"))
    pending = len(pending_titles)
    pending_modes = _pending_modes(os.path.join(pw, "plan.md"))
    completed = _count_checkbox(os.path.join(pw, "completed.md"), "- [x]")
    completed_modes = _completed_modes(os.path.join(pw, "completed.md"))
    last_landed = _last_landed(os.path.join(pw, "completed.md"))
    rejected_items = _rejected_items(os.path.join(pw, "rejected.md"))
    # Derive the count from the canonical parser (same source as rejected_items) rather than
    # the loose `- [` prefix scan, so counts.rejected can never disagree with the rejected[]
    # array it accompanies on a non-canonical marker line (e.g. `- [-]`).
    rejected = len(rejected_items)
    carried = _carried_count(os.path.join(pw, "digest.md"))
    head = _head_sha(root)

    final = _parse_final(os.path.join(pw, "final.md"))
    final_rec = None
    if final is not None:
        # An unconfirmable HEAD (git unavailable / not a work tree, so head == "") means
        # the recorded sha cannot be shown to equal HEAD — treat the point as stale rather
        # than silently "fresh", so _converged / --exit-code never claim a convergence they
        # cannot actually verify (the north-star contract _converged documents).
        stale = (not head) or not _shas_match(final["sha"], head)
        # "(whole-repo)" is the explicit whole-repo sentinel; absent means whole-repo
        # too. Case-insensitive to match lint-final's deliberate leniency — the
        # validator and the convergence gate must agree on the same final.md bytes.
        scope = (final["scope"]
                 if final["scope"].strip().lower() not in ("", "(whole-repo)") else None)
        final_rec = {
            "sha": final["sha"],
            "date": final["date"],
            "deepest_tier": final["deepest_tier"],
            "stale": stale,
            # A component-scoped final point asserts dryness ONLY for that component —
            # surfaced so _converged never certifies whole-repo convergence from it.
            "scope": scope,
            # The seeded-invent replay record (SKILL.md Stage 11; lint-final validates
            # the pairing): surfaced so the run is replayable from the status surface,
            # not just the raw file. None when unseeded/non-invent.
            "invent_seed": final["invent_seed"] or None,
            "invent_framing": final["invent_framing"] or None,
            # A recorded final point that fails lint-final's contract (blank/typo'd/rungless)
            # is not a trustworthy terminal state — surface it so _converged can refuse to
            # certify it (the north star: a final-point claim must mean it).
            "valid": _final_valid(root),
        }

    graph_rec = None
    try:
        with open(os.path.join(pw, "graph.json"), encoding="utf-8") as fh:
            graph = json.load(fh)
        nodes = graph.get("nodes", {})
        dirty = graph.get("dirty", {}) or {}
        built = graph.get("graph_built_at_sha", "")
        built_str = built if isinstance(built, str) else ""
        graph_rec = {
            # Coerce to str: report() slices built_at_sha ([:10]), so a corrupt graph with a
            # numeric graph_built_at_sha would otherwise crash the human report despite the
            # shape guard below (which only protects collect()'s own .get()/len() calls).
            "built_at_sha": built_str,
            "node_count": len(nodes),
            "dirty_node_count": len(dirty.get("nodes", []) or []),
            # Same sha-lag predicate as the final point: a graph built before HEAD is
            # routing memory that predates the tree (an unverifiable HEAD reads stale,
            # never silently fresh). This is the CANONICAL verdict — the dashboard's
            # buildCtx consumes it from state.json rather than re-deriving it.
            "stale": (not head) or not _shas_match(built_str, head),
            # Audit backlog the capped ranked lists hide (absent on pre-frontier graphs).
            # Keep int counts only: report() formats these with %d, so a corrupt graph
            # with a string count would otherwise crash the human report (the same
            # failure class as the built_at_sha coercion above).
            "frontier": ({k: v for k, v in graph.get("frontier").items()
                          if isinstance(v, int) and not isinstance(v, bool)}
                         if isinstance(graph.get("frontier"), dict) else None),
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
        "completed_modes": completed_modes,
        "last_landed": last_landed,
        "rejected": rejected,
        "rejected_items": rejected_items,
        "carried": carried,
        "final_point": final_rec,
        "graph": graph_rec,
        # The run-activity beacon ({command, detail, started, age_seconds, stale}, or
        # None when no command flow has stamped one) — the same object the dashboard
        # reads via state.collect(), so the no-browser surface can see a live or
        # interrupted run.
        "activity": _activity_block(root),
    }


# ---- the coach, mechanized (the codmaster / `planwright advise` decision surface) ----------
#
# The dashboard's Commands-view coach (scripts/dashboard/vendor/derive.js coachSignals /
# coachRecommend) is browser JS, so the command layer cannot call it. This block is the
# stdlib Python port of the SAME truth table, cross-pinned against the JS via the shared
# fixture tests/fixtures/coach-table.json (iterated by BOTH tests/unit/test_status.py and
# tests/cases/derive.sh) so the two brains cannot drift. recommend() wraps the shared base
# with the dispatcher-only overlay rows (first contact, drain-first, carried backlog,
# repo-size override, invent gating) that the dashboard deliberately does not make.
# Read-only throughout: the command layer consumes this JSON verbatim and never re-derives
# the table in prose.

# Named constants — boundary-pinned by tests/unit/test_status.py.
LARGE_REPO_TRACKED_FILES = 120  # depth 10 reads 12 Stage-2b bodies/round, so one flagship
                                # codvisor (cycle 10 depth 10) deep-reads <=120 files: a repo
                                # bigger than that cannot be deep-read by one whole-repo run
SHARD_MIN_DIRS = 2              # sharding fewer than 2 dirs is just a scoped run
HOT_UNCOVERED_DEBT = 3          # coach debt threshold (matches derive.js coachRecommend)


def _pct_rank(sorted_asc, v):
    """Port of derive.js pctRank: strictly-less count / (n-1); n<=1 -> 0."""
    n = len(sorted_asc)
    if n <= 1:
        return 0.0
    lo = 0
    while lo < n and sorted_asc[lo] < v:
        lo += 1
    return lo / (n - 1)


def _graph_signals(root):
    """Port of derive.js metrics()'s coach-facing subset — byte-identical tie semantics
    (stable risk-desc sort over node insertion order, hot set = max(1, ceil(n/3)) by risk
    RANK), stdlib only. None when no readable graph (callers must not read absence as
    cleanliness — that is the first-contact row's job)."""
    try:
        with open(os.path.join(root, ".planwright", "graph.json"), encoding="utf-8") as fh:
            g = json.load(fh)
        nodes = g.get("nodes")
        if not isinstance(nodes, dict) or not nodes:
            return None
        arr = []
        for _path, n in nodes.items():  # insertion order == derive.js Object.keys order
            n = n if isinstance(n, dict) else {}
            arr.append({
                "churn": float(n.get("git_churn") or 0),
                "pagerank": float(n.get("pagerank") or 0),
                "covered": bool(n.get("covered_by_test")),
                "is_test": bool(n.get("is_test")),
                "articulation": bool(n.get("is_articulation")),
            })
        churns = sorted(a["churn"] for a in arr)
        prs = sorted(a["pagerank"] for a in arr)
        for a in arr:
            a["risk"] = _pct_rank(churns, a["churn"]) * _pct_rank(prs, a["pagerank"])
        hotspots = sorted(arr, key=lambda a: -a["risk"])  # stable: ties keep node order
        hot_count = max(1, -(-len(hotspots) // 3))  # ceil(n/3), like derive.js
        hot_uncovered = sum(1 for a in hotspots[:hot_count]
                            if not a["covered"] and not a["is_test"])
        covered = sum(1 for a in arr if a["covered"])
        # JS Math.round (half away from zero), not Python banker's rounding
        coverage_pct = int(covered / len(arr) * 100 + 0.5) if arr else None
        return {
            "import_cycles": len(g.get("import_cycles") or []),
            "articulation": sum(1 for a in arr if a["articulation"]),
            "hot_uncovered": hot_uncovered,
            "coverage_pct": coverage_pct,
        }
    except (OSError, ValueError, AttributeError, TypeError):
        return None


def _is_large(tracked_files, shardable_count):
    """The mechanical repo-size call (never an LLM judgment): big enough that one flagship
    whole-repo run cannot deep-read the code surface once, AND partitionable into at least
    SHARD_MIN_DIRS real shards."""
    return tracked_files >= LARGE_REPO_TRACKED_FILES and shardable_count >= SHARD_MIN_DIRS


def _repo_block(root):
    """codshard's shard enumeration, mechanized with the same rule as commands/codshard.md:
    top-level directories holding >=3 tracked files are shardable, smaller ones fold, dot-dirs
    and .planwright/ are excluded, root-level loose files are not a shard. None when git is
    unavailable."""
    try:
        out = subprocess.run(["git", "-C", root, "ls-files"],
                             capture_output=True, text=True, check=True,
                             timeout=5).stdout
    except (OSError, subprocess.SubprocessError):  # TimeoutExpired is not CalledProcessError
        return None
    counts = {}
    tracked = 0
    for line in out.splitlines():
        if not line:
            continue
        tracked += 1
        if "/" not in line:
            continue
        seg = line.split("/", 1)[0]
        if seg.startswith("."):
            continue
        counts[seg] = counts.get(seg, 0) + 1
    shardable = sorted(d for d, c in counts.items() if c >= 3)
    return {
        "tracked_files": tracked,
        "shardable_dirs": shardable,
        "folded_dirs": sorted(d for d, c in counts.items() if c < 3),
        "large": _is_large(tracked, len(shardable)),
        # `large` (size AND shardable) gates the whole-repo harden route; `shardable`
        # (>= SHARD_MIN_DIRS partitionable dirs, INDEPENDENT of total size) is the weaker
        # fact codmaster's loop reads to route its post-growth harden to codshard even on a
        # not-"large" repo. A fact, not a policy: the routing decision stays in codmaster.
        "shardable": len(shardable) >= SHARD_MIN_DIRS,
    }


def _dirty_paths(root):
    """Uncommitted paths (git status --porcelain), excluding the tool-owned .planwright/ —
    the same exception planwright's own execute/cycle preconditions carve out.

    --no-optional-locks keeps the probe genuinely read-only: a plain `git status`
    opportunistically refreshes the index under .git/index.lock, and this function sits
    on the dashboard's /recommend.json hot path (SSE-driven refetches) — exactly when a
    live execute run is issuing per-item commits that would flake on a held lock."""
    try:
        out = subprocess.run(["git", "--no-optional-locks", "-C", root,
                              "status", "--porcelain"],
                             capture_output=True, text=True, check=True,
                             timeout=5).stdout
    except (OSError, subprocess.SubprocessError):  # TimeoutExpired is not CalledProcessError
        return []
    dirty = []
    for line in out.splitlines():
        path = line[3:] if len(line) > 3 else ""
        if path.startswith(".planwright/") or path == ".planwright" or not line.strip():
            continue
        dirty.append(line.strip())
    return dirty


def _final_flag(fp):
    """Port of derive.js finalFlag — precedence stale > invalid > scoped > ''."""
    if not fp:
        return ""
    if fp.get("stale"):
        return "stale"
    if not fp.get("valid", True):
        return "invalid"
    if fp.get("scope"):
        return "scoped"
    return ""


def coach_signals(state, gsig):
    """Port of derive.js coachSignals over the collect() record plus _graph_signals()."""
    pm = state.get("pending_modes") or {}
    return {
        "has_graph": gsig is not None,
        "pending": state["pending"],
        "pend_repair_improve": int(pm.get("repair", 0)) + int(pm.get("improve", 0)),
        "completed": state["completed"],
        "rejected": state["rejected"],
        "carried": state.get("carried", 0),
        "converged": bool(state.get("converged")),
        "fp_flag": _final_flag(state.get("final_point")),
        "cycles": gsig["import_cycles"] if gsig else 0,
        "hot_uncovered": gsig["hot_uncovered"] if gsig else 0,
        "articulation": gsig["articulation"] if gsig else 0,
        "coverage_pct": gsig["coverage_pct"] if gsig else None,
    }


def coach_recommend(s):
    """The SHARED coach base — a row-for-row port of derive.js coachRecommend, cross-pinned
    via tests/fixtures/coach-table.json. Do not add rows here without adding them to the
    fixture (both test harnesses iterate it, so a one-sided edit fails a suite)."""
    has_debt = (s["cycles"] > 0 or s["hot_uncovered"] >= HOT_UNCOVERED_DEBT
                or s["articulation"] > 0 or s["pend_repair_improve"] > 0)
    if has_debt:
        return {"key": "codvisor",
                "why": "There's structural debt to harden before growing — clear it first."}
    if s["fp_flag"] in ("stale", "invalid"):
        return {"key": "codvisor",
                "why": "The recorded final point no longer holds (%s) — re-audit before "
                       "growing net-new." % s["fp_flag"]}
    if s["pending"] == 0:
        return {"key": "codinventor",
                "why": "Nothing's queued and the tree is clean — latent capability looks "
                       "complete, so grow net-new."}
    return {"key": "codcycle",
            "why": "A healthy mix — planned work to finish and room to grow. Keep the "
                   "harden→grow rhythm."}


def _doctor_blockers(root, mutating):
    """Mechanical dispatch gate from the sibling doctor.py: any FAIL always blocks; the
    git-commit-identity WARN blocks only a mutating dispatch (per-item commits need an
    identity). Degrades to [] when doctor.py is unavailable — planwright's own
    preconditions still apply downstream."""
    import importlib.util
    path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "doctor.py")
    if not os.path.exists(path):
        return []
    try:
        spec = importlib.util.spec_from_file_location("planwright_doctor", path)
        if spec is None or spec.loader is None:
            return []
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        payload = mod.collect(root)
    except Exception:
        return []
    blockers = []
    for c in payload.get("checks", []):
        name = str(c.get("name", "?"))
        if c.get("status") == "fail":
            blockers.append({"kind": "doctor-fail",
                             "detail": "%s — %s" % (name, c.get("detail", ""))})
        elif (mutating and c.get("status") == "warn"
              and "identity" in name):
            blockers.append({"kind": "doctor-warn-identity",
                             "detail": "%s — %s (commits need an identity; blocks only "
                                       "mutating dispatch)" % (name, c.get("detail", ""))})
    return blockers


def _evidence(command, s):
    """Port of derive.js coachEvidence — the numbers shown beneath the recommendation."""
    if not s["has_graph"]:
        return ["%d pending" % s["pending"], "%d accepted" % s["completed"],
                "%d rejected" % s["rejected"]]
    if command in ("codvisor", "codshard"):
        return ["%d import cycles" % s["cycles"],
                "%d untested hotspots" % s["hot_uncovered"],
                "%d articulation risks" % s["articulation"],
                "%d repair/improve pending" % s["pend_repair_improve"]]
    if command == "codinventor":
        return ["%d pending" % s["pending"], "%d cycles" % s["cycles"],
                "converged" if s["converged"] else "no open debt"]
    return ["%d pending" % s["pending"], "%d accepted so far" % s["completed"]]


def _reset_necessity(fp, frontier):
    """The reset decision fires only when REALLY necessary — shown, not assumed. A seeded
    invent-dry point is seed-scoped (SKILL.md: a different framing may still find groundable
    invention), so the non-destructive move is to re-survey -> 'reinvent'. An undrained (or
    unknown) cold frontier means an ordinary harden sweep can still re-read code without
    wiping audit memory -> 'harden'. Only an UNSEEDED invent-dry point with the frontier
    shown drained (never_audited == 0) leaves nothing non-destructive -> 'reset'."""
    if fp.get("invent_seed"):
        return "reinvent"
    never = (frontier or {}).get("never_audited")
    if never is None or never > 0:
        return "harden"
    return "reset"


def recommend(root):
    """The full decision record: shared coach base + the dispatcher overlay. The overlay is
    codmaster's lifecycle ladder, ordered: first contact -> full harden sweep (codvisor, or
    codshard on a mechanically large repo); pending -> execute (drain first); carried
    backlog -> codvisor|codshard (a converged-looking tree with cut/deferred findings still
    drains); converged -> codinventor (grow — marked invent_class so the command layer's
    `safe` word can stop instead), or at deepest_tier invent (the rare earned empty)
    _reset_necessity decides: reset + a fresh harden sweep only when really necessary
    (unseeded AND frontier drained), else the non-destructive re-survey or harden sweep;
    debt / stale point -> codvisor|codshard; clean but no current whole-repo final point ->
    codvisor|codshard (earn convergence before growing). Convergence deliberately outranks
    the base's re-derived debt heuristics: a current, valid, whole-repo final point is the
    proof those signals were surveyed and found dry at this exact HEAD (new debt needs a new
    commit, which stales the point), and the articulation signal is intrinsic and
    undrainable on any documented repo — without this precedence the converged row is
    unreachable and the record recommends a provable no-op harden forever. Blockers (dirty
    tree, doctor) are emitted alongside, mechanical and judgment-free."""
    state = collect(root)
    state["converged"] = _converged(state)
    gsig = _graph_signals(root)
    repo = _repo_block(root)
    s = coach_signals(state, gsig)
    base = coach_recommend(s)
    large = bool(repo and repo["large"])
    # codmaster always dispatches at maximum depth (10): codvisor/codinventor are the
    # depth-10 flagships, and codshard runs depth 10 per shard with the closing round
    # escalated (`explore`).
    harden = ({"command": "codshard", "args": "explore"} if large
              else {"command": "codvisor", "args": "cycle 10 depth 10 explore"})
    notes = []
    if large:
        notes.append("repo large (%d tracked files, %d shardable dirs) — harden work routes "
                     "to codshard so every shard gets the full depth budget"
                     % (repo["tracked_files"], len(repo["shardable_dirs"])))

    fp = state.get("final_point") or {}
    if not s["has_graph"] and s["completed"] == 0:
        rec = dict(harden, mutating=True, invent_class=False,
                   why="first contact — never audited; a full harden sweep builds the graph "
                       "memory and earns the first final point")
    elif s["pending"] > 0:
        rec = {"command": "execute", "args": "execute", "mutating": True,
               "invent_class": False,
               "why": "%d pending item(s) — drain the plan before planning more"
                      % s["pending"]}
        if base["key"] == "codcycle":
            notes.append("coach: codcycle — codmaster drains via execute first, then "
                         "re-decides; codcycle stays a direct dial")
    elif s["carried"] > 0:
        rec = dict(harden, mutating=True, invent_class=False,
                   why="cut/deferred dossier backlog (carried %d) — drain it before growing"
                       % s["carried"])
    elif s["converged"] and (fp.get("deepest_tier") or "") == "invent":
        necessity = _reset_necessity(fp, (state.get("graph") or {}).get("frontier"))
        if necessity == "reinvent":
            rec = {"command": "codinventor", "args": "cycle 10 depth 10 invent",
                   "mutating": True, "invent_class": True,
                   "why": "converged at a SEED-SCOPED invent-dry point (seed %s) — a "
                          "different framing may still find groundable invention; "
                          "re-survey before any reset" % fp.get("invent_seed")}
        elif necessity == "harden":
            rec = dict(harden, mutating=True, invent_class=False,
                       why="converged at the invent-dry point, but the cold frontier is "
                           "not shown drained — a harden sweep re-reads it without wiping "
                           "audit memory; reset only when really necessary")
        else:
            rec = {"command": "reset", "args": "reset", "mutating": True,
                   "invent_class": False, "follow_up": harden,
                   "why": "reset is really necessary: the invent-dry point is unseeded "
                          "(comprehensive) AND the cold frontier is drained — nothing "
                          "non-destructive is left, so a cold-start re-audit (reset keeps "
                          "rejected.md, then a fresh harden sweep) is the one remaining "
                          "move"}
    elif s["converged"]:
        why = (base["why"] if base["key"] == "codinventor"
               else "converged at a current final point — that round surveyed the remaining "
                    "debt signals dry, so grow net-new")
        rec = {"command": "codinventor", "args": "cycle 10 depth 10 invent",
               "mutating": True, "invent_class": True, "why": why}
        if base["key"] == "codvisor":
            notes.append("coach: codvisor (static debt signals) — a current final point "
                         "outranks re-derived debt: the declaring round surveyed those "
                         "signals dry at this HEAD, and new debt would stale the point")
    elif base["key"] == "codvisor":
        rec = dict(harden, mutating=True, invent_class=False, why=base["why"])
    else:
        rec = dict(harden, mutating=True, invent_class=False,
                   why="clean tree but no current whole-repo final point — earn convergence "
                       "before growing")

    blockers = []
    dirty = _dirty_paths(root)
    if dirty and rec["mutating"]:
        blockers.append({"kind": "dirty-tree",
                         "detail": "uncommitted paths — planwright will not entangle them "
                                   "with per-item commits: " + ", ".join(dirty[:8])})
    blockers += _doctor_blockers(root, rec["mutating"])

    reset_nudge = None
    if s["converged"] and rec["command"] != "reset":
        reset_nudge = {"command": "reset",
                       "why": "the recorded final point is incremental — a cold-start "
                              "re-audit (reset, then a fresh round) can re-surface work "
                              "the dirty-set gating skipped"}

    return {
        "base": base,
        "command": rec["command"], "args": rec["args"], "why": rec["why"],
        "mutating": rec["mutating"], "invent_class": rec["invent_class"],
        "follow_up": rec.get("follow_up"),
        "notes": notes, "blockers": blockers,
        "evidence": _evidence(rec["command"], s),
        "reset_nudge": reset_nudge,
        "signals": s, "repo": repo,
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
    cmodes = state.get("completed_modes") or {}
    cbreak = "  (%s)" % ", ".join("%s %d" % (m, c) for m, c in cmodes.items()) if cmodes else ""
    print("  completed: %d%s" % (state["completed"], cbreak))
    # The newest landing, with its Commit provenance stamp when one exists (history
    # predating the stamp shows the bare title). Omitted entirely when nothing landed.
    last = state.get("last_landed")
    if last:
        suffix = " (%s)" % last["commit"] if last["commit"] else ""
        print("  last landed: %s%s" % (last["title"], suffix))
    print("  rejected:  %d" % state["rejected"])
    for item in state["rejected_items"]:
        suffix = " — " + item["reason"] if item["reason"] else ""
        print("    - " + item["title"] + suffix)
    # Only when non-zero, so the common empty case adds no noise: a backlog of
    # verified-but-cut findings is exactly what "0 pending" must not hide.
    if state.get("carried"):
        print("  carried:   %d (cut/deferred dossier candidates — routing only, see digest.md)"
              % state["carried"])

    # Only when a beacon exists, mirroring the carried counter's zero-silence: the
    # steady state between runs adds no line. A stale beacon is an interrupted run's
    # leftover — say so instead of asserting a long-dead run is live.
    act = state.get("activity")
    if act:
        age = act.get("age_seconds") or 0
        if act.get("stale"):
            print("  activity:  STALE beacon '%s' — stamped %ds ago and not refreshed "
                  "within its TTL; an interrupted run leaves it behind "
                  "(state.py activity stop clears it)" % (act["command"], age))
        else:
            label = act["command"] + (" — " + act["detail"] if act.get("detail") else "")
            print("  activity:  %s (run live — stamped %ds ago)" % (label, age))

    fp = state["final_point"]
    if fp is None:
        print("  final point: none recorded (the ladder is open)")
    else:
        tier = fp["deepest_tier"] or "(unrecorded tier)"
        if fp["stale"]:
            flag = "STALE — HEAD has moved; a fresh run re-opens the ladder"
        elif not fp.get("valid", True):
            flag = "INVALID — final.md fails lint-final's contract (not a trusted final point)"
        elif fp.get("scope"):
            flag = ("current, scoped to %s — asserts dryness only for that component"
                    % fp["scope"])
        else:
            flag = "current"
        seedbit = ""
        if fp.get("invent_seed") and fp.get("invent_framing"):
            seedbit = " (framing %s, seed %s)" % (fp["invent_framing"], fp["invent_seed"])
        print("  final point: %s (%s) deepest_tier=%s%s — %s"
              % (fp["sha"] or "?", fp["date"] or "?", tier, seedbit, flag))

    g = state["graph"]
    if g is None:
        print("  graph: none (run a plan to build .planwright/graph.json)")
    else:
        gflag = " (STALE — HEAD has moved since the build)" if g.get("stale") else ""
        fr = g.get("frontier") or {}
        frbit = ""
        if fr.get("never_audited") or fr.get("stale"):
            frbit = (", audit frontier: %d never-audited, %d stale"
                     % (fr.get("never_audited") or 0, fr.get("stale") or 0))
        print("  graph: %d nodes, %d dirty, built at %s%s%s"
              % (g["node_count"], g["dirty_node_count"], (g["built_at_sha"] or "?")[:10],
                 frbit, gflag))
    return 0


def _converged(state):
    """True when the project is at a *current, valid* final point with no pending work: a
    final point is recorded, it is not stale (its sha is HEAD), it passes lint-final's
    structural contract (so a blank/typo'd/rungless marker cannot certify convergence), and
    nothing is pending. This is the machine-checkable form of the north star — "when
    planwright says final point, it means it" — that the opt-in --exit-code flag maps to a
    0/1 exit status."""
    fp = state["final_point"]
    # A component-scoped final point asserts dryness only for its component — it can
    # never certify whole-repo convergence (SKILL.md: "never suppresses a
    # differently-scoped or whole-repo run").
    return (bool(fp) and not fp["stale"] and fp.get("valid", True)
            and not fp.get("scope") and state["pending"] == 0)


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
    ap.add_argument("--recommend", action="store_true",
                    help="emit the coach recommendation as JSON (read-only; the canonical "
                         "decision surface for `planwright advise` and /codmaster — the "
                         "command layer never re-derives this table in prose)")
    ap.add_argument("--ledger", action="store_true",
                    help="emit the completed-work provenance ledger as JSON — every landed item "
                         "as {title, mode, commit} in chronological order (read-only; turns the "
                         "recorded Commit: stamps into a queryable record of what shipped)")
    args = ap.parse_args()

    if args.recommend:
        print(json.dumps(recommend(args.root), indent=2))
        return 0

    if args.ledger:
        print(json.dumps(_completed_ledger(
            os.path.join(args.root, ".planwright", "completed.md")), indent=2))
        return 0

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
