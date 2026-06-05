# Architecture

`planwright` is an AI-agent skill/workflow designed with two distinct paths: **Plan** and **Execute**.
The core idea is to physically separate the auditing and generation of work from the actual
implementation and editing of the source code. The active AI coding agent runs every stage directly;
there are no external binaries and no separate model calls required.

## The Planning Pipeline

When invoked via `planwright` (or the host equivalent such as `/planwright`), the workflow executes a multi-stage pipeline. The entire planning phase is **read-only**: it never edits your application source. It only writes the generated plan items to `<repo>/.planwright/plan.md`.

The pipeline consists of 11 numbered stages plus a mechanical graph-building pass (Stage 1.5):

### Stage 0: Lifecycle Housekeeping
Maintains the `.planwright/` directory.
- Drains completed items (`- [x]`) into `completed.md`.
- Drains rejected items into `rejected.md`.
- Both lists are capped at a FIFO limit of 100 items.
- If all remaining items are completed, the active plan is archived into `plans/` and a fresh run starts.

### Stage 1: Scan
Collects ground-truth data from the project to ensure plan items are actionable and exact:
- **Project File Paths**: Real source, header, and configuration files.
- **Implementation Signals**: Actual non-comment symbols (functions, types, test names).
- **Test Targets**: Exact test targets (e.g., from `ctest` or your project's test runner).
- Loads previously rejected/completed items to avoid re-proposing them.

### Stage 1.5: Build Code Graph
Builds a structural model of the repo (`.planwright/graph.json`) to **route audit attention** toward high-blast-radius code instead of spreading effort uniformly. Computed entirely in the context-mode sandbox, surfacing only a capped ranked node list:
- **Import edges** extracted with `rg` per language family (bash/python/js/c/rust/go/markdown), best-effort. (Go intra-module imports resolve via the root `go.mod` module path — the module prefix is stripped and the remainder mapped to the package directory's `.go` files; stdlib, external, and nested-sub-module imports drop.)
- **Change-coupling edges** from `git log` co-commit history — hidden dependencies a reader cannot see.
- **PageRank** (centrality) and **articulation points** (fragile chokepoints) over the import graph.
- A `ranked` node list later stages use to prioritize what to read. See `docs/graph-memory-schema.md` for the full schema. This stage always runs (lifecycle-level, like Stages 0 and 1) and falls back gracefully when `git`/`rg` are unavailable.

#### Design note — function-granular routing (`branch_at`)

Stage 2b selects *functions* to deep-read, but centrality (`pagerank`) and the original complexity
proxy (`branch_count`) are **per file** — they rank files, not the functions inside them. To let Stage
2b rank and jump to functions *within* a centrality-ranked file, each node also carries a `branch_at`
map (symbol → branch count attributed to that symbol).

**Decision:** attribute branch complexity to a symbol by its *definition span* — the region from the
symbol's definition line (already known from `defines_at`) to the next symbol's definition line (or
EOF) — rather than parsing real function bodies.

**Why, and the alternative rejected:** a true per-language body parser (C/C++ brace matching, Python
indentation blocks, bash `if/fi` nesting) is brittle, high-maintenance, and language-specific — the
kind of silent mis-routing risk a "don't miss things" tool can least afford. The def-span heuristic is
deterministic, reuses `iter_defines`, degrades gracefully (it over/under-counts at boundaries but never
crashes or mis-attributes catastrophically), and matches the best-effort precision of the rest of the
builder. It leaves file-level centrality ranking (`ranked`, coupling fallback) untouched and layers
function granularity on top — the minimal-risk path. **Non-goals:** it is not an AST; only branching
(not centrality, which functions don't carry in this import-graph model) is attributed per symbol.

#### Design note — lang-aware Stage 2b ranking (SHIPPED; historical record) <!-- 2026-06-03 -->

> **Status (since shipped):** `ranked_code` is now implemented in `build-graph.py`, emitted in
> `graph.json`, consumed by SKILL.md Stage 2b, and covered by `tests/run.sh`. The note below is kept as
> the **historical design rationale**; the "deferred"/"for a later implementation item" wording records
> the decision as it was made on 2026-06-03, not the current state.

**Problem.** `imports_of` ingests markdown `[..](..)` links as import edges, so doc files join the
same import graph as code; `pagerank` and `sort_key` then rank every node by that combined centrality
with no code/doc distinction. On a documentation-heavy repo, dense cross-links inflate doc PageRank,
so the `ranked` surface can place prose files (which carry `branch_count == 0` and no `defines`) above
the engine code. Stage 2b is meant to route correctness tracing to the highest-blast-radius **code**,
yet its "top-N functions by `branch_at`" finds no functions in those top-ranked doc files — the
`centrality ∩ complexity` intersection is intended but not expressed in the surfaced ordering.

**Decision (for a later implementation item).** Keep `pagerank`, `sort_key`, and the general-purpose
`ranked` list untouched (they correctly answer "what is structurally central?"), and add a *separate*
code-aware view for Stage 2b's correctness routing: emit a `ranked_code` list = nodes with
`branch_count > 0`, ordered by the same centrality/coupling signal. Stage 2b consumes `ranked_code`
when present and falls back to `ranked` otherwise. This makes the existing `centrality ∩ complexity`
rule concrete instead of implicit, mirrors the `branch_at` note's philosophy (layer on top, never
perturb the file-level ranking), and reuses the already-computed `branch_count` field.

**Why this over the alternatives.** Re-weighting markdown edges down inside `pagerank` would distort
the structural model every other consumer reads; building a code-only subgraph duplicates the import
graph. A derived, additive `ranked_code` view is deterministic, schema-additive, and minimal-risk.
**Deferred implementation seam:** `build()` ranking block (`scripts/build-graph.py:530`–`534`,
`sort_key`/`ranked`) plus a one-line schema addition in `docs/graph-memory-schema.md`; **not**
implemented in this note.

#### Design note — test→source coverage routing (implemented) <!-- 2026-06-03 -->

**Problem.** The coverage rung (Stage 2a "missing focused tests") is routed almost entirely by the
active agent's judgement: it reads PROJECT TEST TARGETS and decides which source files lack a covering
test. The graph
carries no signal for *which source node a test reaches*, even though the information is already in it —
a gtest file `#include`s the header under test, a JS spec `import`s its module, so those edges exist in
the import graph; co-changing test/source pairs show up as `coupling_edges`. Nothing surfaces "this
code node has no test reaching it" as a routing hint, so the lowest rung that *should* drain
mechanically still leans on per-run judgement.

**Decision (for a later implementation item).** Classify each node as *test* vs *non-test* by a path
heuristic (`tests?/` dir, `_test`/`.test`/`.spec`/`Test` stem, gtest `TEST*` groups already in
`defines`), then emit an additive, **routing-only** per-node `covered_by_test: bool` = "some
test-classified node reaches this code node via an import **or** a strong coupling edge". The Stage 2a
coverage lens reads a `false` value as a *candidate* "missing focused tests" finding to investigate —
**never** as proof: Stage 10 still requires the written item to name the specific absent test, exactly
as today. Keep `ranked`/`ranked_code`/`pagerank` untouched; this is one more best-effort field beside
`imports`/`defines`.

**Why this over the alternatives.** Reuse the edges the graph already computes rather than parse
coverage reports (tool-specific, out of scope per MISSION non-goals) or shell out to a coverage runner
(planning is read-only). Making it explicitly recall-over-precision and routing-only matches the
`imports` contract: a wrong classification only fails to route, it can never manufacture a false
finding — the one failure mode a "don't miss things" planner can tolerate, and the false-confidence
trap ("file X is tested") it must avoid. **Caveat the implementation must respect:** exec-based
harnesses (planwright's own `tests/run.sh` *runs* the scripts rather than importing them) have no
import edge, so coverage there must fall back to coupling, and absence must stay a hint, not a verdict.
**Implementation:** `is_test_node()` classifier + `is_test`/`covered_by_test` node fields in
`scripts/build-graph.py` (`build()` node loop and the post-coupling coverage pass), documented in
`docs/graph-memory-schema.md` and consumed by SKILL.md Stage 2a. On planwright's own repo this
correctly marks the scripts `covered_by_test` via `tests/run.sh`'s **coupling** edges (the exec
harness imports nothing), exactly the caveat above.

### Stage 2: Audit
Derives audit findings such as oversized modules, missing tests, risky refactors, and correctness gaps. Each finding must point to concrete file paths or implementation signals.

### Stages 3–7: Cumulative Planning Dossier
Five reasoning passes build a cumulative dossier of candidates, risks, and verification targets:
- **Architecture**: Evaluates module boundaries, API surfaces, and dependency directions.
- **Quality & Tests**: Looks for weak or missing focused tests and exact test anchors.
- **Behavior & Features**: Identifies missing runtime behavior, workflows, or integrations.
- **Operations & Reliability**: Checks configuration, sensitive data handling, and observability.
- **Prioritization Review**: Drops low-value candidates and resolves dependencies between items (e.g., forcing a design item before an implementation item).

### Stage 8: Draft
Converts the refined dossier into draft checkbox items following the exact output format, selecting the highest-value items up to the requested capacity.

### Stage 9: Finalize
Validates the draft against the real project context. It corrects vague titles, verifies test targets, and removes items that hallucinate symbols or assume files exist when they don't.

### Stage 10: Strict Quality Gate
A final check that acts as a hard gate. Items must be proven by non-comment signals. It blocks unsafe extraction (e.g., `constexpr` into `.cpp`), destructive file operations, and missing test anchors. Items failing this gate are replaced or dropped. Its *structural* subset — required fields, valid mode, real `Surfaces:`, absent `New Surfaces:`, no graph-memory in `Evidence`, non-empty `Verification:` — is mechanized by the canonical, test-covered `scripts/lint-plan.py`, so those invariants are enforced deterministically rather than re-checked by hand (mirroring how `scripts/build-graph.py` canonicalizes Stage 1.5).

### Stage 11: Write
Appends the surviving items into `.planwright/plan.md`, then runs `scripts/lint-plan.py` on the written plan and fixes any reported violation before finishing. (If `--dry-run` is active, it lints the would-be items the same way and only prints the plan to chat.) The execute and cycle paths re-run the same linter as a precondition, so a structurally invalid plan never reaches the mutating loop.

## The Execution Path

When invoked via `planwright execute` (or the host equivalent such as `/planwright execute`), the workflow enters the **Execute** path. This is the only path that modifies the source code.

1. **Preconditions**: It ensures a clean git working tree so that per-item commits don't entangle with uncommitted work.
2. **Implement**: Implements the item by editing the surfaces declared in the plan item.
3. **Verify**: Runs the exact `Verification:` command for the item.
4. **Commit / Reject**:
   - On pass: Commits the change, marks the item complete, and moves it to `completed.md`.
   - On fail: Makes up to 2 repair attempts. If it still fails, the item's edits are reverted, a rejection reason is appended, and it moves to `rejected.md`.
5. **Broad Final Verification**: After running through items, a final project-wide build/test ensures that nothing broke on a macro level.

## The Cycle Path

When invoked via `planwright cycle N` (or the host equivalent such as `/planwright cycle N`), the workflow automates both phases by running sequential plan→execute rounds. It is ideal for unattended autonomous development. A negative `N` value (e.g., `-1`) runs the cycle continuously until it reaches a recorded final point.

### The Maturity Ladder & the Final Point

A purely defect-driven auditor idles the moment the bugs are fixed and coverage exists — a *false* fixed point. planwright instead proposes along a four-rung **maturity ladder**, lowest first:

1. **repair** — confirmed defects (`repair`).
2. **coverage** — behaviour-preserving quality and tests (`improve`/`reorganize`).
3. **opportunity** — net-new value grounded in a real surface and the project's mission (`develop`/`docs`).
4. **vision** — roadmap-level, design-first initiatives (`develop`, preceded by a design item).

Rungs 1–2 are **change-gated** (scoped by the Stage 1.5 dirty set — they look only where code changed). Rungs 3–4 are **maturity-gated**: when the lower rungs are dry they are surveyed across the **whole project**, even when the dirty set is empty. That is what keeps a clean, fully-audited tree producing valuable work instead of idling.

Creativity is bounded by a **convergence guard** so it still terminates: every item must clear the Stage 10 gate *and* a rung-appropriate **value bar** that rises with the rung; sub-bar ideas are dropped, and rejected ones do not return unless their reason resolves. The **final point** is reached only when all four rungs are dry — at which point the planning round writes `.planwright/final.md` (HEAD sha + why each rung is dry) and the cycle stops. A later run re-opens the ladder only if the project changed, the mission changed, or the user raises ambition — including a deeper escalation flag than the recorded point: a fresh `invent` run never short-circuits (its tier must generate, so a `deepest_tier: invent` marker is informational only), and `explore` re-surveys over a plain final point (Stage 1's escalation-reach rule).
