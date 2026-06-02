# Architecture

`planwright` is a Claude Code plugin designed with two distinct paths: **Plan** and **Execute**. The core idea is to physically separate the auditing and generation of work from the actual implementation and editing of the source code. Claude runs every stage directly; there are no external binaries and no separate model calls required.

## The Planning Pipeline

When invoked via `/planwright`, the plugin executes a multi-stage pipeline. The entire planning phase is **read-only**: it never edits your application source. It only writes the generated plan items to `<repo>/.planwright/plan.md`.

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
- **Import edges** extracted with `rg` per language family (bash/python/js/c/markdown), best-effort.
- **Change-coupling edges** from `git log` co-commit history — hidden dependencies a reader cannot see.
- **PageRank** (centrality) and **articulation points** (fragile chokepoints) over the import graph.
- A `ranked` node list later stages use to prioritize what to read. See `docs/graph-memory-schema.md` for the full schema. This stage always runs (lifecycle-level, like Stages 0 and 1) and falls back gracefully when `git`/`rg` are unavailable.

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
A final check that acts as a hard gate. Items must be proven by non-comment signals. It blocks unsafe extraction (e.g., `constexpr` into `.cpp`), destructive file operations, and missing test anchors. Items failing this gate are replaced or dropped.

### Stage 11: Write
Appends the surviving items into `.planwright/plan.md`. (If `--dry-run` is active, it only prints the plan to chat).

## The Execution Path

When invoked via `/planwright execute`, the plugin enters the **Execute** path. This is the only path that modifies the source code.

1. **Preconditions**: It ensures a clean git working tree so that per-item commits don't entangle with uncommitted work.
2. **Implement**: Implements the item by editing the surfaces declared in the plan item.
3. **Verify**: Runs the exact `Verification:` command for the item.
4. **Commit / Reject**:
   - On pass: Commits the change, marks the item complete, and moves it to `completed.md`.
   - On fail: Makes up to 2 repair attempts. If it still fails, the item's edits are reverted, a rejection reason is appended, and it moves to `rejected.md`.
5. **Broad Final Verification**: After running through items, a final project-wide build/test ensures that nothing broke on a macro level.

## The Cycle Path

When invoked via `/planwright cycle N`, the plugin automates both phases by running sequential plan→execute rounds. It is ideal for unattended autonomous development. A negative `N` value (e.g., `-1`) runs the cycle continuously until it reaches a recorded final point.

### The Maturity Ladder & the Final Point

A purely defect-driven auditor idles the moment the bugs are fixed and coverage exists — a *false* fixed point. planwright instead proposes along a four-rung **maturity ladder**, lowest first:

1. **repair** — confirmed defects (`repair`).
2. **coverage** — behaviour-preserving quality and tests (`improve`/`reorganize`).
3. **opportunity** — net-new value grounded in a real surface and the project's mission (`develop`/`docs`).
4. **vision** — roadmap-level, design-first initiatives (`develop`, preceded by a design item).

Rungs 1–2 are **change-gated** (scoped by the Stage 1.5 dirty set — they look only where code changed). Rungs 3–4 are **maturity-gated**: when the lower rungs are dry they are surveyed across the **whole project**, even when the dirty set is empty. That is what keeps a clean, fully-audited tree producing valuable work instead of idling.

Creativity is bounded by a **convergence guard** so it still terminates: every item must clear the Stage 10 gate *and* a rung-appropriate **value bar** that rises with the rung; sub-bar ideas are dropped, and rejected ones do not return unless their reason resolves. The **final point** is reached only when all four rungs are dry — at which point the planning round writes `.planwright/final.md` (HEAD sha + why each rung is dry) and the cycle stops. A later run re-opens the ladder only if the project changed, the mission changed, or the user raises ambition.
