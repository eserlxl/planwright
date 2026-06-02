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

EXT_LANG = {
    "sh": "bash", "bash": "bash", "py": "python", "md": "markdown",
    "json": "json", "yml": "yaml", "yaml": "yaml", "js": "js", "ts": "js",
    "c": "c", "h": "c", "cpp": "c", "hpp": "c",
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


def defines_of(lang, text):
    out = []
    if lang == "bash":
        for m in re.finditer(r"(?m)^\s*(?:function\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*\(\)\s*\{?", text):
            out.append(m.group(1))
    elif lang == "python":
        for m in re.finditer(r"(?m)^\s*(?:def|class)\s+([A-Za-z_][A-Za-z0-9_]*)", text):
            out.append(m.group(1))
    elif lang == "js":
        for m in re.finditer(r"(?m)^\s*(?:export\s+)?(?:async\s+)?function\s+([A-Za-z_$][\w$]*)", text):
            out.append(m.group(1))
    # de-dup, preserve order
    seen, uniq = set(), []
    for d in out:
        if d not in seen:
            seen.add(d)
            uniq.append(d)
    return uniq


def resolve(target, from_path, fileset):
    """Resolve a raw import target to a repo-relative path, or None."""
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
    # bash often sources without extension or via $ROOT; try basename match as a last resort
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
    for t in raw:
        r = resolve(t, from_path, fileset)
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


def build(root, prior_path):
    head = sh(["git", "rev-parse", "HEAD"], root).strip()
    files = [f for f in sh(["git", "ls-files"], root).split("\n") if f]
    fileset = set(files)

    prior = {}
    if prior_path and os.path.exists(prior_path):
        try:
            prior = json.load(open(prior_path)).get("nodes", {})
        except (ValueError, OSError):
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
            "lang": lang,
            "git_churn": churn.get(f, 0),
            "defines": defines_of(lang, text),
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
    coupling_deg = {f: 0 for f in files}
    for (a, b), co in sorted(pair_co.items()):
        if co >= COUPLING_MIN_COOCCURRENCE:
            denom = min(churn.get(a, 1), churn.get(b, 1)) or 1
            coupling_edges.append({"a": a, "b": b, "cooccur": co, "weight": round(co / denom, 4)})
            coupling_deg[a] += co
            coupling_deg[b] += co

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
