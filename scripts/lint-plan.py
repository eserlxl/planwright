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
#   * a `repair` item's Evidence carries a file:line anchor (`:N` / `line N`)
#     whose cited file exists, not bare structural absence — improve/docs are
#     exempt;
#   * Surfaces are existing repo files; New Surfaces do not already exist;
#     no path appears in both Surfaces and New Surfaces; no Surface is under the
#     tool-owned .planwright/ tree;
#   * a CMakeLists surface is spelled with its .txt extension;
#   * Verification is present, non-empty, and not a bare placeholder
#     (TODO / tbd / manual / n-a / ... — never a runnable command);
#   * no two pending items share a title (the maturity ladder's monotonic-drain
#     guard). As a non-failing advisory it also notes pending titles that match a
#     completed.md / rejected.md item, for the active agent to confirm a regression or a
#     resolved rejection rather than blocking it, notes a Verification that runs a
#     repo script which does not exist (the item would be unverifiable at execute), and
#     notes an Evidence `path:N` anchor whose file does not exist on a NON-repair item
#     (on a `repair` item the same ghost anchor is a failing violation, per the bullet
#     above), or whose cited line number exceeds the file's length in any mode (a
#     fabricated or stale grounding citation — the plan's single most important signal).
#
# Semantic checks that need code understanding (is the Evidence a *real* defect?
# does Development name a real call site?) stay the active agent's job — this linter is
# deliberately precise over clever so it never raises a false failure.
#
# It only reads the plan + the working tree; it prints findings and exits non-zero
# when any pending item violates a rule (0 when the plan is clean or empty).
#
# With --fix it first auto-corrects the two mechanical, filesystem-verifiable violations
# in place — a `CMakeLists` surface respelled `CMakeLists.txt`, and an already-existing
# New Surface moved into Surfaces (it cannot be a *new* file) — then lints the result.
# Every other violation needs the agent's judgement and is only reported, never rewritten.
#
#   python3 scripts/lint-plan.py [--root DIR] [--plan PATH] [--all] [--fix] [--quiet] [--scope GRAPH]
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
import tempfile

# lint-plan.py lives in scripts/ beside the shared canonical parser. Add its own
# directory to sys.path so `import plan_parse` resolves both when run as a script and
# when loaded by file path (importlib) from a foreign cwd (the suite does the latter).
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from plan_parse import parse_items  # noqa: E402  (after the sys.path bootstrap above)

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

# A Verification can also dodge the set above with unlisted prose ("verify manually",
# "checks pending approval") that is just as unrunnable. Flag a *multi-word* value that
# carries no runnable-command signal — no path/operator character and a first token that
# is not a known runner. A single token (possibly a custom binary) or any value with a
# command signal is never flagged, so a real command that merely contains a placeholder
# word ("manual smoke test then bash tests/run.sh") still passes.
_CMD_SIGNAL = set("/|&;<>$(){}=*\"'`-.")
_KNOWN_EXEC = {
    "python", "python3", "py", "bash", "sh", "zsh", "ctest", "cmake", "make",
    "pytest", "unittest", "npm", "npx", "yarn", "pnpm", "cargo", "go", "node",
    "grep", "rg", "git", "ninja", "gradle", "mvn", "dotnet", "ruby", "rake",
    "tox", "deno", "bun", "test", "./",
    # Containers / orchestration / IaC.
    "docker", "docker-compose", "podman", "kubectl", "helm", "terraform",
    # Build systems / task runners beyond the originals.
    "bazel", "buck", "just", "task", "sbt", "meson", "scons",
    # PHP, Perl, JVM, and other common language toolchains a Verification may use.
    "php", "composer", "phpunit", "perl", "java", "javac", "scala", "mix",
    "swift", "dart", "flutter", "clang", "clang++", "gcc", "g++", "cc", "c++",
    # Linters/type-checkers a Verification commonly leads with ("mypy scripts",
    # "ruff check ." — real commands, not prose).
    "mypy", "ruff", "flake8", "pylint", "black", "isort", "shellcheck",
    "eslint", "tsc", "prettier",
}


def is_prose_verification(norm):
    """True when a normalized Verification value reads as prose, not a command:
    two or more words, no command-signal character, and a first token that is not a
    known executable. Conservative by design — single tokens and anything carrying a
    path, flag, shell operator, or dotted target are left alone (see _CMD_SIGNAL)."""
    tokens = norm.split()
    if len(tokens) < 2:
        return False
    if any(ch in _CMD_SIGNAL for ch in norm):
        return False
    return tokens[0] not in _KNOWN_EXEC


def split_paths(value):
    out = []
    for p in value.split(","):
        p = p.strip().strip("`")
        if p and p.lower() != "none":
            out.append(p)
    return out


def unsafe_surface(p, root):
    """Return a reason string if surface path `p` is not a safe repo-relative path
    under `root`, else None. Stage 10 says Surfaces are existing *repo-relative*
    paths, but a bare os.path.exists(os.path.join(root, p)) check is not enough:
    os.path.join discards `root` for an absolute `p` (so `/etc/hosts` would satisfy
    "exists"), and `../foo` can resolve to a real file outside the repo. Because
    execute mode treats declared Surfaces as its edit boundary, either would let an
    item name a file outside the project. Reject absolute paths (POSIX `/...` or a
    Windows drive), parent-directory traversal (`..`), and any path whose normalized
    join escapes `root` — before the existence check runs."""
    np = p.replace("\\", "/")
    if np.startswith("/") or (len(np) >= 2 and np[1] == ":"):
        return "absolute path (Surfaces must be repo-relative)"
    if ".." in np.split("/"):
        return "parent-directory traversal '..' (Surfaces must stay within the repo)"
    # realpath (not normpath) so a path reachable only through an in-repo symlink
    # that escapes the root is caught — normpath leaves symlinks unresolved, which
    # would let `link/secret` (link -> outside) pass the containment check below.
    full = os.path.realpath(os.path.join(root, np))
    rootn = os.path.realpath(root)
    # commonpath is filesystem-root-safe: when root resolves to "/" (or a drive root),
    # `rootn + os.sep` is "//" and every "/x" path fails startswith — wrongly rejecting a
    # repo cloned at a filesystem root. commonpath([full, rootn]) == rootn avoids that.
    try:
        contained = full == rootn or os.path.commonpath([full, rootn]) == rootn
    except ValueError:
        contained = False  # different drive / uncomparable -> not contained
    if not contained:
        return "resolves outside the repo root"
    return None


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
    # Require a real path-anchored citation (_EVIDENCE_ANCHOR_RE: `file.ext:N` or
    # `file.ext (line N)`) or an explicit `line(s) N`; a bare `:N` is not enough, so a
    # version/time/ratio token ("python 3.10:5", "30:00") no longer satisfies the gate.
    # improve/docs may use structural-absence Evidence and are exempt.
    if mode == "repair" and ev and not (
            _EVIDENCE_ANCHOR_RE.search(ev) or re.search(r"\blines?\s+\d+", ev, re.IGNORECASE)):
        v.append("repair Evidence lacks a file:line anchor "
                 "(Stage 10: cite the wrong call site, not just structural absence)")

    # Verification must be a runnable command, not a bare placeholder. The
    # REQUIRED_FIELDS loop already rejects an empty value; this rejects the
    # equally-unverifiable "TODO"/"manual"/"n/a" class before execute wastes a
    # cycle discovering the item cannot be verified.
    verif = f.get("Verification", "")
    if verif:
        base = verif.strip().strip("`").strip().lower()
        norm = base.rstrip(".").strip()
        # A value that normalizes to empty was all dots/backticks/whitespace
        # (e.g. the "..." ellipsis placeholder, which rstrip(".") collapses to ""):
        # never a runnable command, so it is a placeholder too.
        if norm in PLACEHOLDER_VERIFICATION or norm == "":
            v.append(f"Verification '{verif}' is a placeholder, not a runnable command")
        else:
            # The prose scan must not run on the rstrip(".") value: a STANDALONE
            # trailing "." token is the command's argument ("ruff check ."), and
            # rstrip would eat the very command-signal character the scan looks
            # for. Strip only a glued sentence-final period ("manually." ->
            # "manually"). Dot-only tokens: "." and ".." are path arguments and
            # stay; a 3+-dot token is an ellipsis, never a path — drop it so
            # "inspect the dashboard manually ..." cannot ride the "." command
            # signal past the gate.
            tokens = base.split()
            if tokens and any(c != "." for c in tokens[-1]):
                tokens[-1] = tokens[-1].rstrip(".")
            elif tokens and len(tokens[-1]) >= 3:
                tokens.pop()
            if is_prose_verification(" ".join(t for t in tokens if t)):
                v.append(f"Verification '{verif}' reads as prose, not a runnable command")

    surfaces = split_paths(f.get("Surfaces", ""))
    new_surfaces = split_paths(f.get("New Surfaces", ""))
    if not surfaces and not new_surfaces:
        v.append("no Surfaces and no New Surfaces (item changes nothing)")
    for p in surfaces:
        if os.path.basename(p) == "CMakeLists":
            v.append(f"Surface '{p}' must be spelled CMakeLists.txt")
            continue
        reason = unsafe_surface(p, root)
        if reason:
            v.append(f"Surface '{p}' is not a safe repo-relative path: {reason}")
        elif not os.path.exists(os.path.join(root, p)):
            v.append(f"Surface '{p}' does not exist under root")
        elif os.path.isdir(os.path.join(root, p)):
            # OUTPUT FORMAT: Surfaces are existing *files* that will change. A directory
            # passes os.path.exists but is not an editable boundary the execute path can
            # honor, so name the specific file(s) instead.
            v.append(f"Surface '{p}' is a directory; name the specific file(s) that change")
    for p in new_surfaces:
        if os.path.basename(p) == "CMakeLists":
            v.append(f"New Surface '{p}' must be spelled CMakeLists.txt")
            continue
        reason = unsafe_surface(p, root)
        if reason:
            v.append(f"New Surface '{p}' is not a safe repo-relative path: {reason}")
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
        with open(scope_path, encoding="utf-8") as fh:
            g = json.load(fh)
        focus, context = g.get("focus"), g.get("context")
        # Explicit shape checks: set() over a JSON *string* raises nothing — it
        # yields the set of its characters, silently activating scope mode with a
        # garbage Focus that fails every Surface. Only list-shaped sets count.
        if not isinstance(focus, list) or not isinstance(context, (list, type(None))):
            return set(), set()
        return set(focus), set(context or [])
    except (ValueError, OSError, AttributeError, TypeError):
        # Unreadable, not JSON, or valid JSON of the wrong shape (not an object) —
        # e.g. a truncated or hand-edited scope graph. Treat as 'no scope active'
        # so the gate no-ops rather than crashing the linter.
        return set(), set()


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
        # focus/context are canonical git-ls-files node ids (no leading `./`, no doubled
        # separators); normalize the Surface the same way before the membership test so a
        # non-canonical spelling that lint_item already accepts (./x, x//y) is not
        # false-failed as out-of-scope. The original spelling stays in any message.
        key = os.path.normpath(p).replace("\\", "/")
        if key in focus:
            continue
        if key in context:
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
    with open(path, encoding="utf-8") as fh:
        return {it["title"] for it in parse_items(fh.read(), KNOWN_FIELDS) if it["title"]}


# --- Auto-fix (--fix) --------------------------------------------------------
# Only the two mechanically-unambiguous, filesystem-verifiable violations are auto-fixed;
# everything else needs the agent's judgement and is left for the normal lint to report.
HEAD_RE = re.compile(r"^- \[([ xX])\]\s*(.*)$")
FIELD_RE = re.compile(r"^(\s+)([A-Z][A-Za-z ]*?):\s*(.*)$")


def _tool_owned(p):
    np = p.replace("\\", "/")
    return np == ".planwright" or np.startswith(".planwright/")


def field_spans(lines):
    """Locate, per item, the line span of each known field so the fixer can rewrite a
    field surgically — leaving every other line (titles, wrapped Development/Acceptance
    prose, blanks, comments) byte-identical. Returns a list of items, each
    {checked, line, fields:{name: (start, end, indent, joined_value)}}, where the span is
    [start, end) over the field's header line plus its indented continuation lines. Field
    detection mirrors parse_items() exactly so the fixer and the linter agree on structure."""
    items = []
    cur = None
    pend = None  # [name, start, indent, [value_parts], end_exclusive]

    def close():
        nonlocal pend
        if pend and cur is not None:
            name, start, indent, parts, end = pend
            cur["fields"][name] = (start, end, indent, " ".join(parts).strip())
        pend = None

    for i, raw in enumerate(lines):
        h = HEAD_RE.match(raw)
        if h:
            close()
            cur = {"checked": h.group(1).lower() == "x", "line": i + 1, "fields": {}}
            items.append(cur)
            continue
        if cur is None:
            continue
        m = FIELD_RE.match(raw)
        if m and m.group(2) in KNOWN_FIELDS:
            close()
            val = m.group(3).strip()
            pend = [m.group(2), i, m.group(1), [val] if val else [], i + 1]
        elif pend and raw.strip():
            pend[3].append(raw.strip())
            pend[4] = i + 1
        elif not raw.strip():
            close()
    close()
    return items


def fix_text(text, root, include_checked=False):
    """Apply the two safe auto-fixes to plan text and return (new_text, changes).

    1. A `CMakeLists` Surface/New-Surface is respelled `CMakeLists.txt`.
    2. A New Surface that already exists on disk is moved into Surfaces — it cannot be
       a *new* file, so the move is always correct. (The reverse — a non-existent
       Surface — is deliberately NOT auto-moved: it may be a typo, not a new file.)

    Edits are surgical (only the Surfaces / New Surfaces field lines are rewritten) and
    applied bottom-up so line indices stay valid. Re-emitting a touched field normalizes
    it to a single comma-joined line; untouched items are left exactly as written."""
    # Preserve the file's dominant line terminator: splitlines() drops it, and a hardcoded
    # "\n" rejoin would silently rewrite a CRLF plan's untouched lines to LF, breaking the
    # "untouched items left exactly as written" promise (real for a Windows / git autocrlf
    # checkout). Pick the majority terminator and rejoin with it.
    crlf = text.count("\r\n")
    nl = "\r\n" if crlf > text.count("\n") - crlf else "\n"
    had_nl = text.endswith("\n")
    lines = text.splitlines()
    items = field_spans(lines)
    edits = []  # (start, end, [replacement_lines])
    changes = []

    for it in items:
        if it["checked"] and not include_checked:
            continue
        where = f"item at line {it['line']}"
        s_span = it["fields"].get("Surfaces")
        n_span = it["fields"].get("New Surfaces")
        surfaces = split_paths(s_span[3]) if s_span else []
        new_surf = split_paths(n_span[3]) if n_span else []
        orig_surf, orig_new = list(surfaces), list(new_surf)

        def respell(paths):
            out = []
            for p in paths:
                if os.path.basename(p) == "CMakeLists":
                    fixed = p + ".txt"
                    out.append(fixed)
                    changes.append(f"{where}: respelled '{p}' -> '{fixed}'")
                else:
                    out.append(p)
            return out

        surfaces = respell(surfaces)
        new_surf = respell(new_surf)

        # Move New Surfaces that already exist (and are safe, non-tool-owned) to Surfaces.
        kept_new = []
        for p in new_surf:
            safe = unsafe_surface(p, root) is None and not _tool_owned(p)
            if safe and os.path.exists(os.path.join(root, p)):
                if p not in surfaces:
                    surfaces.append(p)
                changes.append(f"{where}: moved existing '{p}' from New Surfaces to Surfaces")
            else:
                kept_new.append(p)
        new_surf = kept_new

        if s_span and surfaces != orig_surf:
            edits.append((s_span[0], s_span[1], [f"{s_span[2]}Surfaces: {', '.join(surfaces)}"]))
        if n_span and (new_surf != orig_new or (not s_span and surfaces != orig_surf)):
            repl = []
            if not s_span and surfaces:
                # No Surfaces field existed; create it (using the New Surfaces indent) so
                # the moved file lands in a real Surfaces field rather than being dropped.
                repl.append(f"{n_span[2]}Surfaces: {', '.join(surfaces)}")
            if new_surf:
                repl.append(f"{n_span[2]}New Surfaces: {', '.join(new_surf)}")
            edits.append((n_span[0], n_span[1], repl))

    for start, end, repl in sorted(edits, key=lambda e: e[0], reverse=True):
        lines[start:end] = repl

    new_text = nl.join(lines)
    if had_nl and not new_text.endswith(nl):
        new_text += nl
    return new_text, changes


# Interpreters a Verification command may invoke a repo script through. Used only to
# decide whether the first argument is a script path worth an existence check.
VERIF_INTERPRETERS = {"bash", "sh", "zsh", "python", "python3", "py"}


def verification_missing_script(verif, root):
    """If a Verification runs a known interpreter on a repo-relative script that does
    not exist, return that script path; else None. Deliberately conservative — only the
    first non-flag argument after a recognized interpreter is checked, so non-interpreter
    runners (ctest, make, …), inline `-c` snippets, and absolute/URL targets are never
    flagged. This is an advisory (non-failing), so a stray false negative is harmless and
    a false positive is avoided by construction."""
    if not verif:
        return None
    toks = verif.split()
    if not toks or toks[0] not in VERIF_INTERPRETERS:
        return None
    for t in toks[1:]:
        if t.startswith("-"):
            continue
        cand = t.strip('"').strip("'")
        path_like = ("/" in cand or cand.endswith((".sh", ".py")))
        if path_like and not cand.startswith("/") and "://" not in cand:
            return cand if not os.path.exists(os.path.join(root, cand)) else None
        return None  # first real arg is not a repo path (e.g. -c snippet) — stay quiet
    return None


# An Evidence file:line anchor: a repo-relative path (zero or more "/"-separated directory
# segments then a filename) followed by a line reference (":N", ":N-M", or " (line N)"). Zero dir
# segments lets a ROOT-level file (README.md:50, MISSION.md:50) match, so a stale/fabricated root
# citation is caught too; directory segments are DOTLESS so a glued abbreviation prefix
# ("e.g.scripts/x.py") cannot be absorbed into the path; an optional "./"/"../" prefix and a single
# leading-dot dir (".github") are allowed. The filename is one of: a dotted name with a LETTER-LED
# extension (so a version string "3.10:5" or a time "30:00" never matches); a well-known
# extension-less build file (Makefile:12, Dockerfile:7 — the canonical repair surface of
# Make/Docker repos, which the dotted rule alone would false-fail); or a dotfile with >=3 chars
# after the dot (.gitignore:3 — but never a bare extension mention like ".py:3" in prose). The
# line ref stays mandatory. Because the path can only start with a "./"/"../" prefix or an
# alphanumeric/'.' char (never a bare "/" and never containing "://"), an absolute or URL target
# cannot match — no explicit guard is needed.
_EVIDENCE_ANCHOR_RE = re.compile(
    r"(?<![\w./-])"
    r"((?:\.{1,2}/)?"                          # optional ./ or ../ prefix
    r"(?:\.?[A-Za-z0-9_][A-Za-z0-9_-]*/)*"     # >=0 dotless dir segments (root file ok; leading-dot dir ok)
    r"(?:[A-Za-z0-9_][A-Za-z0-9_.-]*\.[A-Za-z][A-Za-z0-9]*"  # filename with a letter-led extension
    r"|(?:GNUmakefile|[Mm]akefile|Dockerfile|Containerfile|Jenkinsfile|Justfile"
    r"|Vagrantfile|Gemfile|Rakefile|Procfile|Kconfig|BUILD|WORKSPACE)"  # well-known extension-less files
    r"|\.[A-Za-z][A-Za-z0-9_.-]{2,}))"         # root dotfile (.gitignore, .env) — >=3 chars after the dot
    r"(?::(\d+)(?:-\d+)?|\s*\(line\s+(\d+)\))")  # the start line is captured (groups 2/3) for range checks


def evidence_anchor_issues(ev, root):
    """Verify every repo-relative `path:N` (or `path (line N)`) anchor the Evidence cites — the
    single most important grounding signal. Returns a list of (path, kind, detail) issues:
    kind "missing" when the cited file does not exist under root (a fabricated or stale citation),
    kind "out-of-range" when the file exists but the cited start line exceeds its line count (a
    hallucinated line number; detail carries the cited line and the file's actual length).
    Deliberately conservative on what counts as an anchor — only a token that is clearly a path AND
    carries a line reference (_EVIDENCE_ANCHOR_RE), so a prose sentence, a bare filename, a glued
    abbreviation ("e.g.scripts/x.py"), or a version string never false-flags. ALL offending anchors
    are reported, not just the first. An unreadable file skips the range check (degrade, never
    crash); severity (violation vs advisory) is the caller's call, keyed on the item's Mode."""
    issues = []
    if not ev:
        return issues
    seen = set()
    for m in _EVIDENCE_ANCHOR_RE.finditer(ev):
        cand = m.group(1)
        full = os.path.join(root, cand)
        if not os.path.exists(full):
            if (cand, "missing") not in seen:
                seen.add((cand, "missing"))
                issues.append((cand, "missing", ""))
            continue
        line_s = m.group(2) or m.group(3)
        if not os.path.isfile(full):
            continue
        try:
            with open(full, "rb") as fh:
                n_lines = sum(1 for _ in fh)
        except OSError:
            continue
        cited = int(line_s)
        if cited > n_lines and (cand, cited) not in seen:
            seen.add((cand, cited))
            issues.append((cand, "out-of-range",
                           f"cites line {cited}, but the file has {n_lines} lines"))
    return issues


def main():
    ap = argparse.ArgumentParser(description="Lint planwright plan items against the Stage 10 structural gate.")
    ap.add_argument("--root", default=".", help="repo root for Surfaces existence checks (default: cwd)")
    ap.add_argument("--plan", default=None,
                    help="plan file to lint (default: <root>/.planwright/plan.md)")
    ap.add_argument("--all", action="store_true", help="lint completed (- [x]) items too, not just pending")
    ap.add_argument("--quiet", action="store_true", help="print nothing; only set the exit code")
    ap.add_argument("--json", action="store_true", help="output structured JSON instead of plain text")
    ap.add_argument("--fix", action="store_true",
                    help="auto-correct the two mechanical violations (CMakeLists.txt spelling; "
                         "move an already-existing New Surface to Surfaces) in place, then lint "
                         "the result; review the change with git diff")
    ap.add_argument("--scope", default=None,
                    help="a graph.json (built with --scope) whose focus/context node sets gate "
                         "Surfaces-in-Focus for a scoped run; no-op when its focus is empty")
    ap.add_argument("--strict", action="store_true",
                    help="promote advisories (re-proposing completed/rejected work; upstream-of-"
                         "Focus surfaces) to failures, so a CI gate can enforce monotonic-drain")
    args = ap.parse_args()
    root = os.path.abspath(args.root)
    # Resolve the default plan path UNDER --root, not the caller's cwd: an adapter
    # invoking the linter from a foreign cwd with only --root must lint that root's
    # plan, not a (possibly absent) plan beside wherever it was launched — otherwise a
    # missing-here plan exits clean and silently bypasses the Stage 10 gate.
    if args.plan is None:
        args.plan = os.path.join(root, ".planwright", "plan.md")

    focus, context = (set(), set())
    if args.scope:
        focus, context = load_focus(args.scope)
    scope_active = bool(focus)  # an empty focus (whole-repo graph) means no scope to enforce

    if not os.path.exists(args.plan):
        if args.json and not args.quiet:
            # --json must keep stdout one parseable JSON document on EVERY path —
            # the absent-plan prose line broke that contract for JSON consumers.
            print(json.dumps({
                "total_items": 0, "total_violations": 0, "total_advisories": 0,
                "items": [], "general_violations": [],
            }, indent=2))
        elif not args.quiet:
            print(f"lint-plan: no plan file at {args.plan} (nothing to lint)")
        return 0
    try:
        with open(args.plan, encoding="utf-8") as fh:
            text = fh.read()
    except UnicodeDecodeError:
        # The gate fails closed on an undecodable plan, but cleanly: one structured
        # violation (a --json caller still gets parseable JSON), no traceback, and
        # --fix is skipped entirely — never rewrite bytes we cannot decode.
        msg = f"lint-plan: {args.plan} is not valid UTF-8 (cannot lint)"
        if args.json:
            print(json.dumps({
                "total_items": 0, "total_violations": 1, "total_advisories": 0,
                "items": [], "general_violations": [msg],
            }, indent=2))
        elif not args.quiet:
            print(msg)
        return 1

    fixes = []
    if args.fix:
        # Read raw (newline-preserving) so fix_text keeps the file's CRLF/LF terminators on
        # its surgical rewrite — the default universal-newline read above already collapsed
        # \r\n to \n, which a write-back would then make permanent. The lint parse below
        # stays on the normalized `text`.
        with open(args.plan, encoding="utf-8", newline="") as fh:
            raw = fh.read()
        fixed, fixes = fix_text(raw, root, args.all)
        if fixes:
            # Atomic write (mirrors lifecycle.write): a plain open(plan, "w") truncates
            # the ACTIVE PLAN before the fixed bytes land, so an interruption between
            # truncate and flush silently loses pending items — the exact failure
            # lifecycle's tempfile+os.replace pattern exists to prevent on this file.
            # newline="" preserves fix_text's CRLF handling byte-for-byte.
            d = os.path.dirname(os.path.abspath(args.plan)) or "."
            fd, tmp = tempfile.mkstemp(dir=d, prefix=".lint-plan-", suffix=".tmp")
            try:
                with os.fdopen(fd, "w", encoding="utf-8", newline="") as fh:
                    fh.write(fixed)
                os.replace(tmp, args.plan)
            except BaseException:
                try:
                    os.remove(tmp)
                except OSError:
                    pass
                raise
            text = fixed.replace("\r\n", "\n").replace("\r", "\n")
        if not args.quiet and not args.json:
            if fixes:
                print(f"lint-plan --fix: applied {len(fixes)} fix(es):")
                for c in fixes:
                    print(f"  - {c}")
            else:
                print("lint-plan --fix: no auto-fixable violations")

    items = [it for it in parse_items(text, KNOWN_FIELDS) if args.all or not it["checked"]]

    # Human-readable lines go to stdout only in text mode: --quiet suppresses them,
    # and --json must keep stdout a single clean JSON document (any leading text would
    # make the output unparseable), so it suppresses the text rendering too. Counters
    # (total, scope_notes, notes) are still accumulated unconditionally so the JSON
    # summary fields are correct regardless of --quiet.
    text = not args.quiet and not args.json
    total, scope_notes = 0, 0
    # Compute each item's findings ONCE here; both the text render below and the JSON
    # block reuse `records` so lint_item()/scope_check() never run twice per item.
    records = []
    for idx, item in enumerate(items, 1):
        violations = lint_item(item, root)
        advisories = []
        if scope_active:
            sv, advisories = scope_check(item, focus, context)
            violations += sv
        # Advisory: a Verification that runs a repo script which does not exist will be
        # rejected as unverifiable at execute — flag it now (non-failing; --strict
        # promotes it) so an unattended cycle does not waste a plan->execute round.
        missing = verification_missing_script(item["fields"].get("Verification", ""), root)
        if missing:
            advisories = list(advisories) + [
                f"Verification runs '{missing}', which does not exist (item will be unverifiable)"]
        # An Evidence file:line anchor pointing at a file that does not exist is a fabricated
        # or stale grounding citation. On a `repair` item that is a FAILING violation — repair
        # means "confirmed defect, cite the wrong call site", so a ghost call site is as fatal
        # as a ghost Surface. Everything else (a non-repair ghost, an out-of-range line number
        # in any mode) stays a non-failing advisory (--strict promotes), keeping the
        # conservative posture where structural absence is legitimate Evidence.
        for path, kind, detail in evidence_anchor_issues(
                item["fields"].get("Evidence", ""), root):
            if kind == "missing" and item["fields"].get("Mode", "") == "repair":
                violations = list(violations) + [
                    f"repair Evidence cites '{path}', which does not exist"]
            elif kind == "missing":
                advisories = list(advisories) + [
                    f"Evidence cites '{path}', which does not exist (re-read the cited surface)"]
            else:
                advisories = list(advisories) + [
                    f"Evidence anchor '{path}' {detail} (re-read the cited surface)"]
        records.append({"idx": idx, "item": item, "violations": violations,
                        "advisories": list(advisories)})
        if violations:
            total += len(violations)
            if text:
                print(f"item {idx} (line {item['line']}): {item['title'] or '<untitled>'}")
                for msg in violations:
                    print(f"  - {msg}")
        for msg in advisories:
            scope_notes += 1
            if text:
                print(f"note: item {idx} '{item['title'] or '<untitled>'}': {msg}")

    # Cross-item: a title repeated among pending items is always a violation
    # (you cannot have two identical pending items). Reported once per dup title.
    # Scan ONLY pending items: --all widens `items` to include completed history,
    # where repeated titles are legitimate (and a pending/completed overlap is
    # surfaced separately as a non-failing advisory below) — counting those here
    # would falsely hard-fail a clean history and mislabel completed titles as
    # "pending".
    seen, dups = set(), []
    for it in items:
        if it["checked"]:
            continue
        t = it["title"]
        if t and t in seen and t not in dups:
            dups.append(t)
        seen.add(t)
    for t in dups:
        total += 1
        if text:
            print(f"duplicate pending title: '{t}'")

    # Advisory (does NOT fail the gate): re-proposing completed/rejected work is a
    # Hard-rule concern but legitimate for a regression or a resolved rejection, so
    # surface it for Claude to confirm rather than block it.
    completed = past_titles(args.plan, "completed.md")
    rejected = past_titles(args.plan, "rejected.md")
    notes = 0
    for rec in records:
        it = rec["item"]
        if it["title"] in completed:
            notes += 1
            rec.setdefault("past_advs", []).append(
                "matches a completed item — confirm this is a regression")
            if text:
                print(f"note: '{it['title']}' matches a completed item — confirm this is a regression")
        if it["title"] in rejected:
            notes += 1
            rec.setdefault("past_advs", []).append(
                "matches a rejected item — confirm the rejection reason is resolved")
            if text:
                print(f"note: '{it['title']}' matches a rejected item — confirm the rejection reason is resolved")

    note_total = notes + scope_notes
    # --strict promotes advisories to failures so automation can enforce monotonic-drain;
    # by default advisories never affect the exit code (Claude confirms them by hand).
    fail = bool(total) or (args.strict and bool(note_total))
    if args.json:
        out_json = {
            "total_items": len(items),
            "total_violations": total,
            "total_advisories": note_total,
            "items": [],
            "general_violations": [],
        }
        if args.fix:
            out_json["fixes_applied"] = fixes
        for t in dups:
            out_json["general_violations"].append(f"duplicate pending title: '{t}'")
        for rec in records:
            item = rec["item"]
            item_out = {
                "index": rec["idx"],
                "line": item["line"],
                "title": item["title"] or "<untitled>",
                "violations": rec["violations"],
                "advisories": rec["advisories"] + rec.get("past_advs", []),
            }
            if item_out["violations"] or item_out["advisories"]:
                out_json["items"].append(item_out)
        print(json.dumps(out_json, indent=2))
        return 1 if fail else 0

    if not args.quiet:
        n = len(items)
        suffix = f" ({note_total} advisory note(s))" if note_total else ""
        if total == 0 and not (args.strict and note_total):
            print(f"lint-plan: {n} item(s) OK{suffix}")
        elif total == 0:
            print(f"lint-plan: {note_total} advisory note(s) failed --strict across {n} item(s)")
        else:
            print(f"lint-plan: {total} violation(s) across {n} item(s){suffix}")
    return 1 if fail else 0


if __name__ == "__main__":
    sys.exit(main())
