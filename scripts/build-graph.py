#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Eser KUBALI
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Canonical, deterministic builder for planwright's Stage 1.5 graph memory
# (.planwright/graph.json). Conforms to docs/graph-memory-schema.md (version 1).
#
# It only reads the repo (git + file bytes) and prints the graph JSON to stdout;
# it never writes — Stage 1.5 captures stdout and writes the file with the native
# Write tool (the sandbox FS is discarded). Run from inside the target git repo:
#
#   python3 scripts/build-graph.py [--root DIR] [--prior .planwright/graph.json]
#
# --prior, when given, preserves each surviving node's last_audited_sha.
import argparse
import hashlib
import json
import os
import re
import subprocess
import sys

COUPLING_WINDOW_COMMITS = 200
COUPLING_MIN_COOCCURRENCE = 3
RANKED_SURFACE_LIMIT = 20

# Basenames whose change forces a whole-graph re-audit: build/lockfile edits can
# alter how every other file compiles, links, or resolves, so a localized dirty
# set would under-audit. Matched case-insensitively (SKILL.md Stage 1.5 step 7,
# "Whole-graph invalidation").
BUILD_CONFIG_BASENAMES = {
    "cmakelists.txt", "makefile", "package.json", "package-lock.json",
    "yarn.lock", "pnpm-lock.yaml", "cargo.toml", "cargo.lock", "go.mod",
    "go.sum", "pyproject.toml", "poetry.lock", "pipfile", "pipfile.lock",
    "requirements.txt", "gemfile", "gemfile.lock", "composer.json",
    "composer.lock", "build.gradle", "pom.xml", "meson.build",
}

EXT_LANG = {
    "sh": "bash", "bash": "bash", "py": "python", "md": "markdown",
    "json": "json", "yml": "yaml", "yaml": "yaml",
    # js/ts family — the extra extensions also appear in JS_EXTS as resolvable
    # import targets, so they must be recognized as source languages too.
    "js": "js", "ts": "js", "jsx": "js", "tsx": "js", "mjs": "js", "cjs": "js",
    # c/c++ family (planwright's primary target) — common alternate extensions.
    "c": "c", "h": "c", "cpp": "c", "hpp": "c",
    "cc": "c", "cxx": "c", "c++": "c", "hh": "c", "hxx": "c", "tpp": "c",
}


def sh(args, root):
    return subprocess.check_output(args, cwd=root, text=True)


def lang_of(path, blob):
    ext = path.rsplit(".", 1)[-1].lower() if "." in os.path.basename(path) else ""
    if ext in EXT_LANG:
        return EXT_LANG[ext]
    if blob[:2] == b"#!":
        first = blob.split(b"\n", 1)[0]
        if b"bash" in first or b"sh" in first:
            return "bash"
        if b"python" in first:
            return "python"
    return "unknown"


def loc_of(blob):
    if not blob:
        return 0
    return blob.count(b"\n") + (0 if blob.endswith(b"\n") else 1)


# Per-language branch-token patterns for a best-effort complexity proxy. Stage 2b
# tiebreaks function selection "by complexity (line count or branching)"; loc gives
# the line count, branch_count gives the branching. Comment/string hits are tolerated
# (consistent with the rest of this best-effort extractor).
BRANCH_KW = {
    "bash": r"\b(?:if|elif|for|while|case|until)\b|&&|\|\|",
    "python": r"\b(?:if|elif|for|while|except)\b|\band\b|\bor\b",
    "js": r"\b(?:if|for|while|case|catch)\b|&&|\|\||\?",
    "c": r"\b(?:if|for|while|case|catch)\b|&&|\|\||\?",
}


def branch_count_of(lang, text):
    """Best-effort count of branch points — the 'branching' half of Stage 2b's
    complexity tiebreak. 0 for data/markup languages with no control flow."""
    pat = BRANCH_KW.get(lang)
    return len(re.findall(pat, text)) if pat else 0


def iter_defines(lang, text):
    """Yield (symbol_name, start_offset) for every definition match, in source
    order. Shared by defines_of (names) and defines_at_of (name -> line)."""
    if lang == "bash":
        for m in re.finditer(r"(?m)^\s*(?:function\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*\(\)\s*\{?", text):
            yield m.group(1), m.start()
    elif lang == "python":
        for m in re.finditer(r"(?m)^\s*(?:def|class)\s+([A-Za-z_][A-Za-z0-9_]*)", text):
            yield m.group(1), m.start()
    elif lang == "js":
        for m in re.finditer(r"(?m)^\s*(?:export\s+)?(?:default\s+)?(?:async\s+)?function\s*\*?\s+([A-Za-z_$][\w$]*)", text):
            yield m.group(1), m.start()
        for m in re.finditer(r"(?m)^\s*(?:export\s+)?(?:default\s+)?class\s+([A-Za-z_$][\w$]*)", text):
            yield m.group(1), m.start()
        # arrow/function expressions bound to a name: `export const f = (x) => ...`
        for m in re.finditer(r"(?m)^\s*(?:export\s+)?(?:const|let|var)\s+([A-Za-z_$][\w$]*)\s*=\s*(?:async\s+)?(?:\([^)]*\)|[A-Za-z_$][\w$]*)\s*=>", text):
            yield m.group(1), m.start()
    elif lang == "c":
        # gtest group/fixture names — SKILL.md routing tracks TEST/TEST_F groups.
        for m in re.finditer(r"(?m)\b(?:TEST|TEST_F|TEST_P|TYPED_TEST)\s*\(\s*([A-Za-z_]\w*)", text):
            yield m.group(1), m.start()
        # class / struct / enum type names.
        for m in re.finditer(r"(?m)\b(?:class|struct|enum)\s+([A-Za-z_]\w*)", text):
            yield m.group(1), m.start()
        # function / method definitions: the `(...)` is followed by a `{` body, not
        # a `;` prototype; params hold no `;`/`{` so a match stays on one definition,
        # and control-flow keywords (which also read as `name (...) {`) are filtered.
        kw = {"if", "for", "while", "switch", "return", "else", "do", "catch", "sizeof"}
        for m in re.finditer(r"(?m)^\s*[A-Za-z_][\w\s:\*&<>,~]*?\b([A-Za-z_]\w*)\s*\([^;{}]*\)\s*(?:const\s*)?(?:noexcept\s*)?\{", text):
            if m.group(1) not in kw:
                yield m.group(1), m.start()


def defines_of(lang, text):
    # de-dup, preserve source order
    seen, uniq = set(), []
    for name, _ in iter_defines(lang, text):
        if name not in seen:
            seen.add(name)
            uniq.append(name)
    return uniq


def defines_at_of(lang, text):
    """Map each defined symbol to the 1-based line of its first definition, so
    Stage 2b can jump straight to a function body instead of re-scanning the file."""
    at = {}
    for name, pos in iter_defines(lang, text):
        if name not in at:
            at[name] = text.count("\n", 0, pos) + 1
    return at


def branch_at_of(lang, text):
    """Attribute branching to each symbol by its DEFINITION SPAN — the region from
    a symbol's definition to the next symbol's definition (or EOF). A best-effort,
    parser-free proxy for per-function complexity that lets Stage 2b rank functions
    *within* a centrality-ranked file (see docs/architecture.md design note). First
    definition of a repeated name wins, mirroring defines_of/defines_at_of."""
    pat = BRANCH_KW.get(lang)
    if not pat:
        return {}
    defs = sorted(iter_defines(lang, text), key=lambda np: np[1])
    out = {}
    for i, (name, start) in enumerate(defs):
        end = defs[i + 1][1] if i + 1 < len(defs) else len(text)
        if name not in out:
            out[name] = len(re.findall(pat, text[start:end]))
    return out


def resolve(target, from_path, fileset, allow_basename=False):
    """Resolve a raw import target to a repo-relative path, or None.

    With allow_basename (bash `source`, C `#include`), fall back to a *unique*
    basename match when relative resolution misses: bash sources a lib by bare name
    or via an unresolved `$DIR/lib.sh`, and C reaches a header through an -I include
    root rather than a path relative to the file. The single-match guard avoids
    ambiguous edges."""
    if not target or target.startswith(("http://", "https://", "#", "mailto:")):
        return None
    target = target.split("#", 1)[0].split("?", 1)[0].strip()
    if not target:
        return None
    base = os.path.dirname(from_path)
    cand = os.path.normpath(os.path.join(base, target)) if not target.startswith("/") else target.lstrip("/")
    cand = cand.replace("\\", "/")
    if cand in fileset:
        return cand
    if allow_basename:
        bn = os.path.basename(target)
        matches = [f for f in fileset if os.path.basename(f) == bn] if bn else []
        if len(matches) == 1:
            return matches[0]
    return None


def resolve_python_import(target, from_path, fileset):
    """Resolve a python import target (a dotted module, possibly relative) to a repo
    file. Dotted names are not paths, so the generic resolver always misses them and
    every python import edge is dropped. Absolute `pkg.mod` tries `pkg/mod.py` and
    `pkg/mod/__init__.py` from the repo root; a leading-dot relative import resolves
    against the importer's package, one level up per extra dot."""
    dots = len(target) - len(target.lstrip("."))
    parts = [p for p in target[dots:].split(".") if p]
    if dots:
        base = os.path.dirname(from_path).split("/") if os.path.dirname(from_path) else []
        up = dots - 1
        if up > len(base):
            return None
        segs = base[:len(base) - up] + parts
    else:
        segs = parts
    if not segs:
        return None
    stem = "/".join(segs)
    for cand in (stem + ".py", stem + "/__init__.py"):
        if cand in fileset:
            return cand
    return None


JS_EXTS = (".js", ".ts", ".jsx", ".tsx", ".mjs", ".cjs")


def resolve_js_import(target, from_path, fileset):
    """Resolve a js/ts import target to a repo file. JS specifiers routinely omit
    the extension and use directory `index` files, so the generic resolver (exact
    path only) drops the common case. Probe `<stem>.<ext>` then `<stem>/index.<ext>`.
    Bare specifiers (`react`) are node_modules — not repo files — so they drop."""
    if not target.startswith((".", "/")):
        return None
    base = os.path.dirname(from_path)
    stem = os.path.normpath(os.path.join(base, target)) if not target.startswith("/") else target.lstrip("/")
    stem = stem.replace("\\", "/")
    if stem in fileset:
        return stem
    for ext in JS_EXTS:
        if stem + ext in fileset:
            return stem + ext
    for ext in JS_EXTS:
        if stem + "/index" + ext in fileset:
            return stem + "/index" + ext
    return None


def imports_of(lang, text, from_path, fileset):
    raw = []
    if lang == "bash":
        raw += re.findall(r"(?m)^\s*(?:source|\.)\s+([^\s;]+)", text)
    elif lang == "python":
        raw += re.findall(r"(?m)^\s*(?:from|import)\s+([.\w/]+)", text)
    elif lang == "js":
        raw += re.findall(r"""import\s+.*?from\s+['"]([^'"]+)['"]""", text)
        raw += re.findall(r"""require\(\s*['"]([^'"]+)['"]\s*\)""", text)
    elif lang == "c":
        raw += re.findall(r'(?m)^\s*#\s*include\s+"([^"]+)"', text)
    elif lang == "markdown":
        raw += re.findall(r"\[[^\]]*\]\(([^)]+)\)", text)
    out = []
    # bash sources and C includes both reach files by bare name (a sourced lib, an
    # -I include root), so both fall back to a unique basename match.
    allow_basename = lang in ("bash", "c")
    for t in raw:
        if lang == "python":
            r = resolve_python_import(t, from_path, fileset)
        elif lang == "js":
            r = resolve_js_import(t, from_path, fileset)
        else:
            r = resolve(t, from_path, fileset, allow_basename)
        if r and r != from_path and r not in out:
            out.append(r)
    return out


def pagerank(nodes, edges, damping=0.85, iters=50):
    n = len(nodes)
    if n == 0:
        return {}
    idx = {f: i for i, f in enumerate(nodes)}
    out_links = {f: [t for t in edges.get(f, []) if t in idx] for f in nodes}
    pr = {f: 1.0 / n for f in nodes}
    for _ in range(iters):
        nxt = {f: (1.0 - damping) / n for f in nodes}
        dangling = sum(pr[f] for f in nodes if not out_links[f])
        for f in nodes:
            nxt[f] += damping * dangling / n
        for f in nodes:
            outs = out_links[f]
            if outs:
                share = damping * pr[f] / len(outs)
                for t in outs:
                    nxt[t] += share
        pr = nxt
    return pr


def articulation_points(nodes, undirected):
    """Standard DFS lowlink articulation-point detection."""
    visited, disc, low, parent, aps = set(), {}, {}, {}, set()
    timer = [0]

    def dfs(u):
        stack = [(u, iter(undirected.get(u, [])))]
        visited.add(u)
        disc[u] = low[u] = timer[0]
        timer[0] += 1
        children = {u: 0}
        while stack:
            node, it = stack[-1]
            advanced = False
            for w in it:
                if w not in visited:
                    parent[w] = node
                    children[node] = children.get(node, 0) + 1
                    visited.add(w)
                    disc[w] = low[w] = timer[0]
                    timer[0] += 1
                    children[w] = 0
                    stack.append((w, iter(undirected.get(w, []))))
                    advanced = True
                    break
                elif parent.get(node) != w:
                    low[node] = min(low[node], disc[w])
            if not advanced:
                stack.pop()
                if stack:
                    p = stack[-1][0]
                    low[p] = min(low[p], low[node])
                    if parent.get(p) is not None and low[node] >= disc[p]:
                        aps.add(p)
        if children.get(u, 0) > 1:
            aps.add(u)

    for s in nodes:
        if s not in visited:
            parent[s] = None
            dfs(s)
    return aps


def connected_components(nodes, undirected):
    seen, comps = set(), []
    for s in nodes:
        if s in seen:
            continue
        stack, comp = [s], []
        seen.add(s)
        while stack:
            u = stack.pop()
            comp.append(u)
            for w in undirected.get(u, []):
                if w not in seen:
                    seen.add(w)
                    stack.append(w)
        comps.append(sorted(comp))
    return comps


def cluster_label(members):
    dirs = {os.path.dirname(m) or "(root)" for m in members}
    if len(dirs) == 1:
        return next(iter(dirs))
    # most common top-level dir
    tops = {}
    for m in members:
        top = m.split("/", 1)[0] if "/" in m else "(root)"
        tops[top] = tops.get(top, 0) + 1
    return max(sorted(tops), key=lambda k: tops[k])


def commits_since(prior_sha, head, root):
    """Number of commits on HEAD not reachable from prior_sha, or None if it
    cannot be computed (rewritten history, unknown sha)."""
    if not prior_sha or prior_sha == head:
        return 0
    try:
        out = sh(["git", "rev-list", "--count", f"{prior_sha}..HEAD"], root).strip()
    except subprocess.CalledProcessError:
        return None
    return int(out) if out.isdigit() else None


def compute_dirty(files, nodes, prior, prior_graph, head, undirected, coupling_edges, clusters, root):
    """Deterministic Stage 1.5 step 7 dirty set. Returns the `dirty` block:
    which nodes changed since the prior graph, their 1-hop blast radius along
    import + coupling edges, the clusters they touch, and whether a whole-graph
    re-audit is forced. Leaving this to hand-computation each run is the most
    error-prone part of incremental skipping, so the canonical builder owns it."""
    all_files = sorted(files)
    all_clusters = sorted(c["id"] for c in clusters)

    # First run: no baseline to diff against — every node is dirty.
    if not prior:
        return {
            "is_first_run": True, "whole_graph": True, "reason": "first-run",
            "changed": [], "nodes": all_files, "clusters": all_clusters,
        }

    changed = sorted(
        f for f in files if prior.get(f, {}).get("sha256") != nodes[f]["sha256"]
    )
    # A build-config edit (or deletion) can change how everything builds.
    def is_build_config(p):
        return os.path.basename(p).lower() in BUILD_CONFIG_BASENAMES
    config_hits = [f for f in changed if is_build_config(f)]
    config_hits += [f for f in (set(prior) - set(files)) if is_build_config(f)]

    diverged = commits_since(prior_graph.get("graph_built_at_sha"), head, root)

    whole_graph, reason = False, "incremental"
    if config_hits:
        whole_graph, reason = True, f"build-config changed: {sorted(config_hits)[0]}"
    elif diverged is not None and diverged > COUPLING_WINDOW_COMMITS:
        whole_graph = True
        reason = f"HEAD diverged {diverged} commits (> {COUPLING_WINDOW_COMMITS})"
    elif diverged is None:
        whole_graph, reason = True, "prior graph_built_at_sha unreachable"

    if whole_graph:
        dirty_nodes = all_files
    else:
        # 1-hop blast radius along import + coupling adjacency.
        adj = {f: set(undirected.get(f, [])) for f in files}
        for e in coupling_edges:
            a, b = e["a"], e["b"]
            if a in adj and b in adj:
                adj[a].add(b)
                adj[b].add(a)
        ds = set(changed)
        for f in changed:
            ds.update(adj.get(f, ()))
        dirty_nodes = sorted(ds & set(files))

    touched = sorted({c["id"] for c in clusters if set(c["members"]) & set(dirty_nodes)})
    return {
        "is_first_run": False, "whole_graph": whole_graph, "reason": reason,
        "changed": changed, "nodes": dirty_nodes, "clusters": touched,
    }


def build(root, prior_path):
    head = sh(["git", "rev-parse", "HEAD"], root).strip()
    files = [f for f in sh(["git", "ls-files"], root).split("\n") if f]
    fileset = set(files)

    prior_graph = {}
    if prior_path and os.path.exists(prior_path):
        try:
            loaded = json.load(open(prior_path))
            prior_graph = loaded if isinstance(loaded, dict) else {}
        except (ValueError, OSError):
            prior_graph = {}
    prior = prior_graph.get("nodes", {})
    if not isinstance(prior, dict):
        prior = {}

    # churn + change-coupling
    log = sh(["git", "log", "--name-only", "--format=%H", "-n", str(COUPLING_WINDOW_COMMITS)], root)
    churn, commits, cur = {}, [], None
    for ln in log.split("\n"):
        ln = ln.strip()
        if not ln:
            continue
        if len(ln) == 40 and all(c in "0123456789abcdef" for c in ln):
            cur = set()
            commits.append(cur)
        elif cur is not None and ln in fileset:
            cur.add(ln)
            churn[ln] = churn.get(ln, 0) + 1

    pair_co = {}
    for cset in commits:
        fs = sorted(cset)
        for i in range(len(fs)):
            for j in range(i + 1, len(fs)):
                k = (fs[i], fs[j])
                pair_co[k] = pair_co.get(k, 0) + 1

    nodes, import_edges = {}, {}
    for f in files:
        blob = open(os.path.join(root, f), "rb").read()
        lang = lang_of(f, blob)
        text = blob.decode("utf-8", "replace")
        imps = imports_of(lang, text, f, fileset)
        import_edges[f] = imps
        nodes[f] = {
            "sha256": hashlib.sha256(blob).hexdigest(),
            "loc": loc_of(blob),
            "branch_count": branch_count_of(lang, text),
            "branch_at": branch_at_of(lang, text),
            "lang": lang,
            "git_churn": churn.get(f, 0),
            "defines": defines_of(lang, text),
            "defines_at": defines_at_of(lang, text),
            "imports": imps,
            "pagerank": 0.0,
            "is_articulation": False,
            "last_audited_sha": prior.get(f, {}).get("last_audited_sha"),
        }

    undirected = {f: set() for f in files}
    for f, outs in import_edges.items():
        for t in outs:
            undirected[f].add(t)
            undirected[t].add(f)
    undirected = {f: sorted(s) for f, s in undirected.items()}

    pr = pagerank(files, import_edges)
    aps = articulation_points(files, undirected)
    for f in files:
        nodes[f]["pagerank"] = round(pr.get(f, 0.0), 6)
        nodes[f]["is_articulation"] = f in aps

    coupling_edges = []
    # Weighted coupling degree: sum of incident edge weights, where
    # weight = cooccur / min(churn) normalizes away raw volume so a high-churn
    # ledger file (CHANGELOG, manifests) does not dominate purely by appearing in
    # many commits. SKILL.md Stage 1.5 step 6 specifies this "sum of coupling_edges
    # weights" as the degenerate-fallback ranking signal.
    coupling_deg = {f: 0.0 for f in files}
    for (a, b), co in sorted(pair_co.items()):
        if co >= COUPLING_MIN_COOCCURRENCE:
            denom = min(churn.get(a, 1), churn.get(b, 1)) or 1
            w = round(co / denom, 4)
            coupling_edges.append({"a": a, "b": b, "cooccur": co, "weight": w})
            coupling_deg[a] += w
            coupling_deg[b] += w

    comps = connected_components(files, undirected)
    clusters = []
    for i, members in enumerate(sorted(comps, key=lambda m: (-len(m), m[0]))):
        clusters.append({"id": i, "label": cluster_label(members), "members": members})

    # ranking: pagerank-driven, but fall back to change-coupling when the import
    # graph is degenerate (too few edges, or pagerank barely discriminates).
    pr_values = [pr.get(f, 0.0) for f in files]
    pr_spread = (max(pr_values) - min(pr_values)) if pr_values else 0.0
    n_import_edges = sum(len(v) for v in import_edges.values())
    degenerate = n_import_edges < max(3, len(files) // 4) or pr_spread < 1e-4
    signal = "coupling" if degenerate else "centrality"

    def sort_key(f):
        primary = coupling_deg[f] if degenerate else pr.get(f, 0.0)
        return (primary, 1 if nodes[f]["is_articulation"] else 0, churn.get(f, 0), )

    ranked = sorted(files, key=sort_key, reverse=True)[:RANKED_SURFACE_LIMIT]

    dirty = compute_dirty(files, nodes, prior, prior_graph, head, undirected,
                          coupling_edges, clusters, root)

    return {
        "version": 1,
        "graph_built_at_sha": head,
        "built_at": sh(["date", "-u", "+%Y-%m-%dT%H:%M:%SZ"], root).strip(),
        "target": ".",
        "ranking_signal": signal,
        "params": {
            "coupling_window_commits": COUPLING_WINDOW_COMMITS,
            "coupling_min_cooccurrence": COUPLING_MIN_COOCCURRENCE,
            "ranked_surface_limit": RANKED_SURFACE_LIMIT,
        },
        "nodes": nodes,
        "coupling_edges": coupling_edges,
        "clusters": clusters,
        "ranked": ranked,
        "dirty": dirty,
    }


def main():
    ap = argparse.ArgumentParser(description="Build planwright Stage 1.5 graph.json (prints to stdout).")
    ap.add_argument("--root", default=".", help="repo root (default: cwd)")
    ap.add_argument("--prior", default=None, help="prior graph.json to preserve last_audited_sha from")
    args = ap.parse_args()
    root = os.path.abspath(args.root)
    try:
        graph = build(root, args.prior)
    except subprocess.CalledProcessError as e:
        sys.stderr.write(f"build-graph: git command failed ({e})\n")
        return 2
    json.dump(graph, sys.stdout, indent=2)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
