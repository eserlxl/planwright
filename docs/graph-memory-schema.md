# planwright graph memory — Stage 1.5 spec & schema

Status: **Phase 1 + Phase 2 invalidation wired**. This document specifies the structural memory artifact
(`.planwright/graph.json`) and the mechanical stage that builds it. The graph **routes
attention**; it is never cited as evidence for a plan item (see [Guardrails](#guardrails)).

The canonical, deterministic builder is **`scripts/build-graph.py`** — it implements the procedure
below and emits schema-conforming JSON to stdout (Stage 1.5 writes that to `.planwright/graph.json`
with the native Write tool). Its conformance to this schema is verified by `tests/run.sh`
("build-graph.py output conforms to graph-memory schema"); the prose steps here are the spec it
implements, also usable as a by-hand fallback.

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
  "ranking_signal": "centrality",     // "centrality" (pagerank) or "coupling" (degenerate-graph fallback)
  "params": {
    "coupling_window_commits": 200,   // git history depth for change-coupling
    "coupling_min_cooccurrence": 3,   // min co-commits to record a coupling edge
    "ranked_surface_limit": 20        // how many top nodes Stage 1.5 prints to context
  },
  "nodes": {
    "<repo-relative-path>": {
      "sha256": "<hex of file bytes>",      // invalidation key (Phase 2)
      "loc": 123,
      "branch_count": 9,                     // file-level branch tokens (cross-file complexity)
      "branch_at": { "funcA": 6, "funcB": 1 }, // branches per symbol by def-span (within-file Stage 2b rank)
      "lang": "bash|markdown|python|c|js|...|unknown",
      "git_churn": 17,                       // commit count touching this file
      "defines": ["funcA", "funcB"],         // best-effort symbol defs (routing hint)
      "defines_at": { "funcA": 12, "funcB": 40 }, // symbol -> 1-based def line (Stage 2b jump hint)
      "imports": ["<repo-relative-path>"],   // resolved structural edges, best-effort
      "is_test": false,                      // test file (by path convention) — coverage routing
      "covered_by_test": true,               // a test node reaches this one (import/coupling); routing-only
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
  "ranked": ["fileA", "fileB", "..."],       // nodes by descending audit priority
  "ranked_code": ["fileA", "..."],           // `ranked` restricted to branch_count>0 nodes — Stage 2b uses this
  "dirty": {                                  // Phase 2 dirty set (computed vs --prior)
    "is_first_run": false,                    // true when no prior graph existed
    "whole_graph": false,                     // true => re-audit every node
    "reason": "incremental",                  // "first-run" | "incremental" | "build-config changed: <f>" | "HEAD diverged …"
    "changed": ["fileX"],                     // nodes whose sha256 != prior sha256
    "nodes": ["fileX", "fileY"],              // dirty set: changed + 1-hop blast radius
    "clusters": [0, 2]                        // cluster ids the dirty set touches
  }
}
```

### Field notes

- **`imports`** are *recall-over-precision* hints. A miss never causes a wrong finding —
  it only fails to route attention. Unresolved imports are dropped, not guessed.
- **`defines`** are best-effort symbol names per language (bash/python functions; C/C++
  functions, methods, `class`/`struct`/`enum`, and `TEST`/`TEST_F`/`TEST_P`/`TYPED_TEST`
  group names; JS functions, classes, and named arrow/function expressions). They feed
  Stage 2b's "walk `ranked`, take its top functions" selection and the test-reorg lens;
  like `imports`, they only route attention and are never cited as Evidence.
- **`is_test`** / **`covered_by_test`** route the coverage rung (Stage 2a "missing focused
  tests"). `is_test` flags a node as a test file by path convention (test dir, `_test`/`test_`/
  `.spec.`/`_unittest` stem, camelCase `FooTest`); it leans toward precision so a source file is
  not mislabeled a test. `covered_by_test` is true when some `is_test` node reaches this one via an
  `imports` edge **or** a (strong, already-filtered) `coupling_edges` link — the coupling path is
  what links an exec-based harness (e.g. a runner that *runs* rather than imports its targets) to the
  code it exercises. A `false` on a non-test code node is a **candidate** missing-test finding to
  investigate, never proof; like `imports`/`defines` these fields only route attention.
- **`ranked_code`** is `ranked` filtered to nodes with `branch_count > 0`, in the same
  priority order. Stage 2b's function-selection walk reads `ranked_code` when present
  (falling back to `ranked`) so doc/data nodes that link-centrality floats to the top of
  `ranked` do not displace the engine code Stage 2b is meant to deep-read. Routing only.
- **`coupling_edges`** capture files that co-commit without importing each other — the
  hidden dependencies a reader cannot see. `weight = cooccur / min(churn_a, churn_b)`.
- **`is_articulation`** marks cut vertices of the import graph: a defect there has wide
  blast radius, so Stage 2b auto-promotes them regardless of depth.
- **`last_audited_sha`** stays `null` until a node is first deep-audited (then Stage 11 stamps it).
- **`dirty`** is the deterministic Phase 2 dirty set, computed by the builder when `--prior` is
  given (the prior `graph.json`). `changed` = nodes whose `sha256` differs from the prior; `nodes` =
  `changed` plus their 1-hop blast radius along import + coupling edges; `clusters` = the cluster ids
  that set touches. `whole_graph` is set (and `nodes` = every node) when a build-config/lockfile file
  changed, HEAD diverged from the prior `graph_built_at_sha` beyond `coupling_window_commits`, or that
  sha is unreachable. With no `--prior`, `is_first_run` is `true` and the whole tree is dirty. Stages
  3–7 consume this block directly instead of re-deriving the dirty set by hand; it routes attention
  and is **never** cited as Evidence.
- **`ranking_signal`** records which signal drove the `ranked` list: `centrality` (PageRank over the
  import graph) normally, or `coupling` when the import graph is degenerate (too few edges, or PageRank
  barely discriminates — common in docs/scripts repos), in which case nodes rank by **weighted
  change-coupling degree** (sum of incident `coupling_edges` weights, churn-normalized so a
  high-churn ledger file does not dominate by raw volume) instead. Both are boosted by
  `is_articulation` and tiebroken by `git_churn`.

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
7. **Compute the dirty set** (when a `--prior` graph is given): emit the `dirty` block — changed
   nodes, their 1-hop blast radius, touched clusters, and any whole-graph trigger. The builder owns
   this so it is deterministic and test-covered rather than hand-computed each run.
8. **Write** `graph.json` (native Write — sandbox FS is discarded). **Surface** only the
   top `ranked_surface_limit` nodes as a compact list into context.

## Phase 2 — incremental invalidation

The full Phase 2 loop is wired into the pipeline: `build-graph.py` step 7 computes the dirty
set into `graph.json`'s `dirty` block, Stages 3–7 restrict scope to it, and Stage 11 restamps
`last_audited_sha` and refreshes `digest.md`.

- **Dirty set** = nodes whose current `sha256` ≠ recorded `sha256`, **plus their 1-hop
  blast radius** along import + coupling edges — emitted as the `dirty` block by the builder.
  *(build-graph.py step 7)*
- Stages 3–7 spin up lenses only for clusters intersecting the dirty set; unchanged
  clusters carry forward their prior dossier findings. *(Stages 3–7 "Incremental scope")*
- **First run / unavailable graph** = no baseline ⇒ every node is dirty, full tree audited.
- **Whole-graph invalidation** (re-audit everything) when any of: lockfile/build-config
  changed, `version` bumped, or HEAD diverged from `graph_built_at_sha` beyond a threshold.
- **Stage 11** rewrites `last_audited_sha` for audited nodes and refreshes `digest.md`
  (blocks marked `UNVERIFIED — routing only`). *(Stage 11 "persist the baseline")*

## Guardrails

1. A plan item's `Evidence:` field may **never** cite `graph.json` or `digest.md`. The
   graph says *where to look*; evidence must come from real code re-read this run.
2. Import/call edges are hints (recall over precision); hard routing leans on import +
   coupling edges, not inferred call edges.
3. The graph build must cost less than it saves — hence in-sandbox compute and a capped
   surfaced node list.
