# planwright graph memory — Stage 1.5 spec & schema (draft)

Status: **draft / Phase 1**. This document specifies the structural memory artifact
(`.planwright/graph.json`) and the mechanical stage that builds it. The graph **routes
attention**; it is never cited as evidence for a plan item (see [Guardrails](#guardrails)).

## Why

Re-auditing a whole repo every run is the dominant token cost. The graph lets an audit
(1) target the highest-blast-radius code first (Phase 1) and (2) skip clusters whose
content is unchanged since they were last audited (Phase 2). It is computed entirely in
the ctx sandbox; only a ~20-line ranked node list surfaces into context.

## Two layers

| Artifact | Trust | Built by | Contents |
|----------|-------|----------|----------|
| `.planwright/graph.json` | structural, safe to trust | Stage 1.5 (mechanical) | hashes, edges, metrics |
| `.planwright/digest.md` | `UNVERIFIED — routing only` | Stage 11 (Phase 2) | per-cluster prose summary |

## `graph.json` schema (v1)

```jsonc
{
  "version": 1,
  "graph_built_at_sha": "<git HEAD sha when this graph was built>",
  "built_at": "<UTC ISO-8601>",
  "target": ".",
  "params": {
    "coupling_window_commits": 200,   // git history depth for change-coupling
    "coupling_min_cooccurrence": 3,   // min co-commits to record a coupling edge
    "ranked_surface_limit": 20        // how many top nodes Stage 1.5 prints to context
  },
  "nodes": {
    "<repo-relative-path>": {
      "sha256": "<hex of file bytes>",      // invalidation key (Phase 2)
      "loc": 123,
      "lang": "bash|markdown|python|c|js|...|unknown",
      "git_churn": 17,                       // commit count touching this file
      "defines": ["funcA", "funcB"],         // best-effort symbol defs (routing hint)
      "imports": ["<repo-relative-path>"],   // resolved structural edges, best-effort
      "pagerank": 0.0123,                    // centrality over the import graph
      "is_articulation": false,              // cut vertex => fragile chokepoint
      "last_audited_sha": null               // Phase 2: HEAD sha when last deep-audited
    }
  },
  "coupling_edges": [
    { "a": "fileX", "b": "fileY", "cooccur": 8, "weight": 0.42 }  // change-coupling
  ],
  "clusters": [
    { "id": 0, "label": "skill-core", "members": ["skills/planwright/SKILL.md"] }
  ],
  "ranked": ["fileA", "fileB", "..."]        // nodes by descending audit priority
}
```

### Field notes

- **`imports`** are *recall-over-precision* hints. A miss never causes a wrong finding —
  it only fails to route attention. Unresolved imports are dropped, not guessed.
- **`coupling_edges`** capture files that co-commit without importing each other — the
  hidden dependencies a reader cannot see. `weight = cooccur / min(churn_a, churn_b)`.
- **`is_articulation`** marks cut vertices of the import graph: a defect there has wide
  blast radius, so Stage 2b auto-promotes them regardless of depth.
- **`last_audited_sha`** stays `null` in Phase 1 (graph built, nothing skipped yet).

## Stage 1.5 build procedure (mechanical, in-sandbox)

Runs after Stage 1 (Scan), before Stage 2 (Audit). All steps execute in the ctx sandbox;
raw output never enters context.

1. **Enumerate** tracked files via `git ls-files`. For each: `sha256`, `loc`, `lang`
   (by extension/shebang).
2. **Extract import edges** with ripgrep, per language family (best-effort regex):
   | Family | Pattern source |
   |--------|----------------|
   | bash | `source X`, `. X` |
   | python | `import X`, `from X import` |
   | js/ts | `import … from "X"`, `require("X")` |
   | c/c++ | `#include "X"` |
   | markdown | relative `[..](X)` links |
   Resolve targets to repo-relative paths; drop unresolved.
3. **Extract change-coupling** from `git log --name-only --format=%H -n <window>` in the
   sandbox: count file pairs per commit, keep pairs with `cooccur >= coupling_min_cooccurrence`.
4. **Compute metrics** on the import graph: PageRank (centrality) and articulation points.
5. **Cluster** via connected components / community detection; assign a short label.
6. **Rank** nodes: primary by `pagerank`, boosted if `is_articulation`, tiebreak `git_churn`.
7. **Write** `graph.json` (native Write — sandbox FS is discarded). **Surface** only the
   top `ranked_surface_limit` nodes as a compact list into context.

## Phase 2 — incremental invalidation (added after the graph is trusted)

- **Dirty set** = nodes whose current `sha256` ≠ recorded `sha256`, **plus their 1-hop
  blast radius** along import + coupling edges.
- Stages 3–7 spin up lenses only for clusters intersecting the dirty set.
- **Stage 11** rewrites `last_audited_sha = graph HEAD` for audited nodes and refreshes
  `digest.md`.
- **Whole-graph invalidation** (rebuild from scratch) when any of: lockfile/build-config
  changed, `version` bumped, or HEAD diverged from `graph_built_at_sha` beyond a threshold.

## Guardrails

1. A plan item's `Evidence:` field may **never** cite `graph.json` or `digest.md`. The
   graph says *where to look*; evidence must come from real code re-read this run.
2. Import/call edges are hints (recall over precision); hard routing leans on import +
   coupling edges, not inferred call edges.
3. The graph build must cost less than it saves — hence in-sandbox compute and a capped
   surfaced node list.
