---
name: planwright
description: >
  Grounded codebase planning. Scans + audits a repository and produces a verification-ready
  checkbox plan in .planwright/plan.md using the exact 8-field item format
  (Mode/Rationale/Evidence/Surfaces/New Surfaces/Development/Acceptance/Verification).
  Runs a multi-stage dossier -> draft -> finalize -> quality-gate pipeline with Claude doing
  every stage directly. The `execute` subcommand then implements the plan items, verifies each,
  and records completed/rejected items.
  Trigger when the user asks to "plan", "run plan mode", "generate a plan", "refresh the plan",
  "propose plan items", "execute the plan", "implement the plan", "cycle", "dogfood", or mentions
  .planwright/plan.md. Run `/planwright help` for usage and options.
  Supports: execute [--interactive] [N], cycle <N>, update, version, upgrade, depth <N>, propose <N>, max <N>, no-compact, dry-run, help.
license: GPL-3.0-or-later
metadata:
  author: Eser KUBALI
  version: "1.15.0"
---

# planwright

This skill has three clearly partitioned paths:

- **Plan** (`/planwright`, default) — scans and audits the codebase, then runs a multi-stage
  *dossier → draft → finalize → quality-gate* pipeline to emit concrete plan items in
  `.planwright/plan.md`. **Read-only: it writes only the plan file, never application source.**
- **Execute** (`/planwright execute`) — implements the pending plan items, verifies each, commits
  the ones that pass, and records the rest. **This is the only path that edits source.**
- **Cycle** (`/planwright cycle N`) — runs N sequential plan→execute rounds unattended: proposes
  items, implements them all, verifies, then repeats. It climbs a **maturity ladder** (repair →
  coverage → opportunity → vision) so a clean tree keeps producing valuable work, and stops early only
  when it reaches a **recorded final point** (all four rungs dry — see **Maturity ladder & the final
  point**).

Claude itself runs every stage, so it needs no external binary and spends no separate model calls.

When planning, do not edit application source. The output of the plan path is **only** the plan file.

## Invocation & help

Before doing anything else, inspect the argument the skill was invoked with:

- If it is `help`, `--help`, `-h`, `?`, or empty-with-an-explicit-help-request, **print a header line
  `planwright v<version>` (read `<version>` from this file's frontmatter `metadata.version`), then the
  Usage reference below verbatim, and STOP.** Do not scan, audit, plan, or write any file.
- If the first token is `version`, `--version`, or `-V`, dispatch to the **Version** section at the end
  of this file and follow that procedure instead of the planning Procedure.
- If the first token is `execute`, dispatch to the **Execute** section near the end of this file and
  follow that procedure instead of the planning Procedure. Remaining tokens are execute options
  (`--interactive`, an item index `N`).
- If the first token is `cycle`, dispatch to the **Cycle** section near the end of this file and
  follow that procedure instead of the planning Procedure. The next token is the repeat count `N`; a
  trailing `depth <N>` (and other plan options) applies to every planning round in the cycle.
- If the first token is `upgrade` or `update`, dispatch to the **Upgrade** section at the end of
  this file and follow that procedure instead of the planning Procedure.
- Otherwise treat the argument as either an **instruction** (free text to break down) and/or inline
  **option overrides** (see Options), then run the planning Procedure.

### Usage

```
PLAN (read-only)
/planwright                      Plan from audit (depth 6, propose 5, default settings)
/planwright <instruction>        Break a specific request into plan items
/planwright depth <N>            Set analysis depth 1..10 (intensity + audit thoroughness; default 6)
/planwright propose <N>          Override items proposed this run (1..max)
/planwright max <N>              Override the pending-item cap for this run
/planwright no-compact           Skip lifecycle housekeeping (no archive/drain this run)
/planwright dry-run              Do all stages but print the plan instead of writing the file

EXECUTE (edits source)
/planwright execute              Auto: implement every pending item, commit each that passes
/planwright execute --interactive  Prompt per item: approve, show diff, verify, confirm commit
/planwright execute N            Implement only pending item number N

CYCLE (automated plan → execute loops)
/planwright cycle <N>            Plan then execute, repeated N times (1..100)
/planwright cycle <-N>           Plan then execute until nothing remains (unlimited, negative N)
/planwright cycle <N> depth <M>  Run the cycle with planning depth M (1..10) every round

MAINTENANCE
/planwright version              Show the current and latest available version
/planwright upgrade              Update planwright itself to the latest version
/planwright update               Alias for upgrade
/planwright help                 Show this help (with version) and stop
```

Plan options may be combined with an instruction, e.g.
`/planwright add OAuth login propose 3 dry-run`.

### Options

| Option | Default | Effect |
|--------|---------|--------|
| `<instruction>` | none | free-text request to decompose into items |
| `depth <N>` | `6` | analysis depth `1..10` — scales reasoning intensity + audit thoroughness (see **Depth**) |
| `propose <N>` | from depth (`5` at depth 6) | items to propose this run (clamped to `1..max`) |
| `max <N>` | `20` | cap on pending unchecked items in the plan |
| `no-compact` | off | skip Stage 0 housekeeping for this run |
| `dry-run` | off | run everything but print the plan, write nothing |
| `help` | — | print Usage and stop |

Precedence: **inline option > built-in default.** There is no settings file; options are per-run only.

### Depth

`depth <N>` (1–10, default **6**) is a single dial that scales the whole planning pipeline: how hard
you reason, how many audit sub-passes run, how many function bodies you read, how many dossier lenses
you apply, and how many items you propose by default. Read it as the analysis-intensity knob —
**1 = cosmetic pass** (typos, formatting, trivial one-line fixes), **10 = exhaustive whole-project
audit**. Non-integer or out-of-range values are clamped to `1..10`; report the clamp.

Resolve the run's depth first, then apply this table for the rest of the Procedure:

| Depth | Reasoning intensity | Stage 2 audit sub-passes | Stage 2b functions to read | Stages 3–7 lenses | Default `propose` | Character |
|------:|------------------|--------------------------|---------------------------:|-------------------|------------------:|-----------|
| 1  | low    | 2a only          | 0  | one quick combined pass | 1 | cosmetic: typos, formatting, trivial fixes |
| 2  | low    | 2a only          | 1  | one quick combined pass | 2 | small, low-risk fixes |
| 3  | low    | 2a, 2b           | 2  | 3, 4, 7                 | 3 | shallow audit |
| 4  | medium | 2a, 2b           | 3  | 3, 4, 7                 | 4 | moderate audit |
| 5  | medium | 2a–2d (all four) | 4  | all (3–7)               | 5 | standard depth |
| 6  | medium | 2a–2d (all four) | 5  | all (3–7)               | 5 | **default** — full standard pipeline |
| 7  | high   | 2a–2d (all four) | 6  | all (3–7)               | 6 | thorough |
| 8  | high   | 2a–2d (all four) | 8  | all (3–7) + adversarial re-review | 7 | exhaustive |
| 9  | high   | 2a–2d (all four) | 10 | all (3–7) + adversarial re-review | 8 | exhaustive |
| 10 | ultra  | 2a–2d (all four) | 12 | all (3–7) + adversarial re-review + second-opinion cross-check | 8 | maximum |

How to read it:

- **Reasoning intensity** uses the familiar low / medium / high / ultra scale. **Before Stage 0**,
  resolve depth→tier and **self-apply that reasoning intensity for the rest of the run**, reasoning at
  that tier throughout the pipeline. planwright does not read or change the session's `/effort` level —
  that setting is the user's to adjust if they want; planwright never prompts about it and never blocks
  on it. Just run at the mapped intensity.
- **Stage 2 audit sub-passes** — only the listed sub-passes run; the rest are skipped entirely at that
  depth. Low depth is deliberately structural-only; correctness/invariant/behavioral tracing is reserved
  for depth ≥ 5.
- **Stage 2b functions to read** — the top-N function bodies to open and trace, selected by centrality
  ∩ complexity from the Stage 1.5 graph (articulation points always included), falling back to most-complex
  when no graph is available. `0` skips body-level correctness tracing at that depth.
- **Stages 3–7 lenses** — which dossier passes to run. `one quick combined pass` collapses Stages 3–7
  into a single shallow sweep; otherwise run exactly the listed stage numbers.
- **Adversarial re-review** (depth ≥ 8) — after Stage 7, re-read every surviving candidate as a hostile
  reviewer and try to break it (false premise, stale claim, undeclared dependency) before it reaches
  Draft. **Second-opinion cross-check** (depth 10) — additionally re-derive each item's Evidence from
  signals independently and drop any that does not reproduce.
- **Default `propose`** — used only when `propose <N>` is *not* given. An explicit `propose <N>` always
  overrides it, and the `1..max` / `min(…, max − pending)` capacity clamps still apply on top.

Stages 0, 1, 1.5, and 8–11 always run regardless of depth — depth never skips lifecycle housekeeping,
scanning, graph building, drafting, finalizing, the quality gate, or writing. It scales how much analysis feeds the
draft, never whether the output stays grounded and verified.

## Maturity ladder & the final point

A purely defect-driven auditor reaches a *false* fixed point: once the bugs are fixed and coverage
exists, the dirty set empties and it idles — "no defects I can prove" is mistaken for "as good as it
should be." planwright instead proposes along a four-rung **maturity ladder**, lowest first:

1. **repair** — confirmed defects: wrong output, swallowed error, violated invariant (mode `repair`).
2. **coverage** — behaviour-preserving quality: missing focused tests, weak verification, consistency,
   maintainability (mode `improve`/`reorganize`).
3. **opportunity** — net-new value grounded in a real surface *and* the project's mission: features,
   DX, ergonomics, robustness, observability, teaching docs (mode `develop`/`docs`).
4. **vision** — roadmap-level, design-first initiatives: a stated design decision precedes
   implementation; larger multi-step bets (mode `develop`, often with a preceding design item).

Each run proposes from the **lowest non-empty rung**, and may seed a few items from the next rung up to
keep forward motion. The decisive rule that prevents premature idling:

- **Rungs 1–2 are change-gated** — the Stage 1.5 dirty set scopes them; they look only where code
  changed. An empty dirty set means rungs 1–2 are dry, *not* that there is no work.
- **Rungs 3–4 are maturity-gated, not change-gated** — when rungs 1–2 are dry they run over the
  **whole project** against its mission/charter, **even when the dirty set is empty**. This is what
  lets a clean, fully-audited tree keep producing valuable work instead of stopping.

**Convergence guard (so creativity still terminates):**

- Every item must clear the strict Stage 10 gate **and** a rung-appropriate **value bar** that *rises*
  with the rung: an opportunity item must name a concrete user/maintainer payoff; a vision item must
  name a concrete, mission-aligned outcome — not a vague nicety. Marginal "could-do" ideas fail the bar.
- Ideas that fail the bar/gate are dropped; if proposed and later rejected they land in `rejected.md`
  and are not re-proposed unless their reason resolves (the existing feedback loop). This makes each
  rung monotonically drain.
- A rung is **dry** when, surveyed at full intensity, it yields no item above its value bar that is not
  already pending, completed, or rejected.

**The final point** is reached only when **all four rungs are dry**. When a planning round determines
that, it writes `.planwright/final.md` — one block recording the HEAD sha, the rungs surveyed, and why
each is dry — and reports "final point reached". This is a *justified* terminal state, distinct from an
empty-dirty-set idle. A later run re-opens the ladder only if the project changed (non-empty dirty
set), the mission/charter changed, or the user raises ambition (an explicit instruction, or higher
depth). Any planning round that writes ≥1 item deletes a stale `final.md`.

## Inputs

- **Target**: the repo to plan for. Default `.` (current working directory).
- **Instruction** (optional): a user request to break down. If absent, plan from the audit.
- **Capacity**: propose at most the resolved propose count — the depth-derived default (see **Depth**;
  depth 6 → `5`) or the explicit `propose <N>` when given — and never let the active plan's *pending*
  items exceed `20`. `propose_count = min(<resolved propose>, 20 − pending_unchecked_items)`. If
  `propose_count == 0`, stop and report "Plan is at capacity"; do not invent filler items.

## Procedure

Run these stages in order. Stages 0–2 are mechanical (use tools). Stages 3–10 are reasoning passes
you perform yourself — treat each as a distinct lens and carry forward a cumulative dossier.

### Stage 0 — Lifecycle housekeeping (mechanical)

If `no-compact` was passed, skip this entire stage (still read pending items in step 4).
Create `<target>/.planwright/` if it does not exist, then operate on it:

1. If `plan.md` exists, move every completed item (`- [x] ...` and its indented continuation lines)
   into `completed.md` (append). Then enforce the **FIFO cap of 100**: if `completed.md` holds more
   than 100 items, drop the oldest (top of file) until 100 remain.
2. Drain any item carrying a `Status:Rejected` / `Status: Rejected` continuation line into
   `rejected.md` (append, preserving its `Rejection:` reason line), removing it from `plan.md`. Then
   enforce the **FIFO cap of 100** on `rejected.md` the same way.
3. If, after that, **all** remaining items are completed (or the file is empty of pending items),
   archive the whole file to `plans/plan_<UTC-timestamp>.md` and start fresh.
4. Read the remaining **pending** (`- [ ]`) items — these are the existing plan you must not duplicate.

Report counts: compacted, rejected-drained, archived (yes/no).

### Stage 1 — Scan (mechanical)

Build three context sets the later stages MUST be grounded in. Prefer `rg`/`fd`; for large output,
route through context-mode (`ctx_batch_execute`) so raw bytes stay out of context.

- **PROJECT FILE PATHS** — repo-relative paths of real source/header/test/config files.
- **PROJECT IMPLEMENTATION SIGNALS** — actual non-comment symbols: function/method/type names,
  `constexpr` declarations, `TEST`/`TEST_F` group names, public API signatures. This is your
  ground truth for what exists.
- **PROJECT TEST TARGETS** — exact test target names (e.g. from `add_test`/`gtest_discover_tests`
  / `ctest -N`, or the project's test runner). Verification commands must use these verbatim.

Also read any project mission/charter file if present and treat it as a constraint.

Then load the planning memory so this run learns from prior ones:

- **PREVIOUSLY REJECTED** — read `.planwright/rejected.md` (titles + `Rejection:` reasons). Carry
  these into every dossier pass as a constraint: do **not** re-propose a rejected item unless its
  specific rejection reason is now resolved, and if you do, the Development line must state what
  changed. Use the recurring reasons to steer away from whole classes of doomed work.
- **RECENTLY COMPLETED** — read `.planwright/completed.md` so you do not re-propose finished work
  (unless the audit shows a regression).

### Stage 1.5 — Build code graph (mechanical)

Build a structural model of the repo that **routes audit attention** to the highest-blast-radius
code. This stage always runs (lifecycle-level, like Stages 0 and 1; depth never skips it). Run the
whole build in the ctx sandbox (`ctx_batch_execute` / `ctx_execute`) so raw bytes stay out of
context — surface only the capped ranked node list. Write the result to `.planwright/graph.json`
with the native Write tool, conforming field-for-field to `docs/graph-memory-schema.md` (`version: 1`).

1. **Enumerate** tracked files via `git ls-files`. For each node record `sha256`, `loc`, and `lang`
   (by extension/shebang).
2. **Import edges** — extract with `rg` per language family (best-effort, recall over precision):
   bash `source X` / `. X`; python `import X` / `from X import`; js/ts `import … from "X"` /
   `require("X")`; c/c++ `#include "X"`; markdown relative `[..](X)` links. Resolve targets to
   repo-relative paths; drop unresolved (a miss only fails to route — it never produces a finding).
3. **Change-coupling edges** — from `git log --name-only --format=%H -n <coupling_window_commits>`,
   count file pairs that co-commit; keep pairs with `cooccur ≥ coupling_min_cooccurrence`. These
   capture hidden dependencies a reader cannot see by reading code.
4. **Metrics** — over the import graph compute `pagerank` (centrality) and `is_articulation` (cut
   vertices = fragile chokepoints with wide blast radius).
5. **Cluster** — partition by connected components / community detection; give each cluster a short
   label.
6. **Rank** nodes by descending audit priority: primary `pagerank`, boosted when `is_articulation`,
   tiebreak `git_churn`. Emit the top `ranked_surface_limit` (~20) into the `ranked` list and surface
   only that list to context.
   - **Degenerate-import-graph fallback** — when the import graph barely discriminates (PageRank spread
     across nodes is below a small threshold, or there are too few import edges to rank — common in
     docs/scripts repos where files rarely import each other), PageRank is noise. In that case rank by
     **change-coupling** instead: a node's coupling degree/weight (sum of its `coupling_edges` weights)
     becomes the primary signal, still boosted by `is_articulation` and tiebroken by `git_churn`. Record
     in the surfaced summary which signal drove the ranking (`centrality` vs `coupling`).
7. **Incremental invalidation (only when a prior `.planwright/graph.json` exists)** — compute the
   **dirty set** so unchanged code can be skipped downstream. A node is *dirty* when its freshly
   computed `sha256` differs from the value recorded in the prior graph. The dirty set is those
   changed nodes **plus their 1-hop blast radius** along import + coupling edges. Map the dirty set to
   the clusters it touches and carry both forward — Stages 3–7 gate on it. Preserve each surviving
   node's prior `last_audited_sha` (Stage 11 restamps audited nodes).
   - **Whole-graph invalidation** — treat **every** node as dirty (re-audit everything) when any of:
     a lockfile or build-config file changed, the planwright `version` advanced, or HEAD has diverged
     from the prior graph's `graph_built_at_sha` beyond a sane threshold (e.g. the coupling window).
   - **First run** — when no prior graph exists, there is no baseline: every node is dirty and the
     full tree is audited. `last_audited_sha` is `null` until Stage 11 records it.

If the build cannot run (no `git`/`rg`, or a tooling error), record the failure, skip graph-aware
routing **and incremental skipping** for this run, and fall back to depth's default selection over the
whole tree — never block planning, and never skip audit work when the graph is unavailable.

### Stage 2 — Audit (mechanical + reasoning)

Run the named sub-passes **enabled by the run's depth** (see the Depth table) in order — 2a alone at
depth 1–2, 2a–2b at depth 3–4, all four at depth ≥ 5. Each must emit findings with **file:line anchors** —
category labels alone are not findings. Carry all findings forward into the dossier.

**2a. Structural** — inventory: oversized modules (>300 lines), missing focused tests (only when
genuinely absent from PROJECT TEST TARGETS), risky refactors lacking coverage, signal/surface
mismatches. Each finding: path, size or gap, why it matters.

**2b. Correctness** — open and read the bodies of the top-N functions, where **N is the Depth table's
"Stage 2b functions to read"** for this run. Select those N by **centrality ∩ complexity**: walk the
Stage 1.5 `graph.json` `ranked` list (PageRank-ordered, so high-blast-radius code first) and take its
top functions, **always including every `is_articulation` node regardless of depth** (a defect in a
cut vertex breaks many modules), then break ties by complexity (line count or branching). When the
graph used the **coupling fallback** (degenerate import graph, see Stage 1.5 step 6), `ranked` is
already coupling-ordered — walk it the same way; centrality and coupling feed the same `ranked` list.
If `graph.json` is absent or graph-aware routing was skipped this run, **fall back** to the original rule:
the top-N most complex functions by line count or branching. For each selected function, trace every
non-trivial path: look for silent failures (error return ignored, wrong default returned, exit 0 on
bad state), unchecked preconditions, and off-by-one or boundary errors. Findings must cite file:line,
the specific path, and the defect.

**2c. Invariants** — enumerate data contracts that the code *assumes* but never enforces: value
ranges, non-empty inputs, sorted order, clean-tree state, valid format strings, unique names. For
each assumed-but-unenforced invariant, note the assumption site (file:line) and the enforcement gap.

**2d. Behavioral coverage** — for each public entry point, identify inputs that produce untested or
unspecified output: boundary values, empty collections, concurrent calls, failure return from a
dependency. Findings must name the entry point (file:line) and the uncovered input class.

### Stages 3–7 — Cumulative planning dossier (reasoning passes)

Build one growing `PLANNING DOSSIER` with sections **Findings, Candidate Work, Risks, Verification
Targets, Rejected Ideas**. Do *not* emit checkbox items yet. Run only the lenses the run's **depth**
enables (see the Depth table): at depth 1–2 collapse all of 3–7 into one quick combined sweep; at
depth 3–4 run lenses 3, 4, and 7; at depth ≥ 5 run all five. Each pass preserves prior useful findings
and adds/corrects for its lens.

**Incremental scope** — the dirty-set restriction applies only to the **change-gated rungs** (repair,
coverage — lenses 3, 4, and the correctness sub-lens). For those, when Stage 1.5 produced a dirty set
(a prior graph existed and this was not a whole-graph invalidation), restrict the lens to the
**clusters intersecting the dirty set**, and carry forward unchanged clusters' prior dossier findings
instead of re-deriving them. On a first run, a whole-graph invalidation, or when the graph is
unavailable, every cluster is in scope. Never skip a cluster a dirty node reaches via its 1-hop blast
radius.

The **maturity-gated rungs** (opportunity, vision — lenses 5 and 6) are **not** change-gated: when the
change-gated rungs are dry (e.g. an empty dirty set), run lenses 5–6 over the **whole project** against
its mission/charter regardless of the dirty set, bounded by the convergence guard (see **Maturity
ladder & the final point**). This is the mechanism that keeps a clean tree climbing instead of idling.

3. **Architecture** — module boundaries, oversized units, public API surfaces, dependency
   direction, source/header/test clusters, language-specific header-only/template constraints.
4. **Quality & tests** — weak/missing focused tests, wrong verification targets, refactors needing
   coverage, exact test anchors. For any test split/consolidation candidate, enumerate **every**
   `TEST`/`TEST_F` group in the file and flag compile-time-sensitive tests (preprocessor-manipulating,
   include-order-sensitive, distinct-translation-unit-dependent) that must stay isolated.
   **Correctness of existing behavior** — for each Stage 2b/2c/2d finding, trace the call from
   entry point to the defect site; confirm whether the output is provably wrong (wrong value returned,
   error silently swallowed, invariant violated at runtime) or merely unspecified (no test covers it).
   Classify as `repair` only when a specific wrong output is confirmed; classify as `improve` when
   the behavior is unspecified and coverage is the gap. Do not conflate "untested" with "incorrect".
5. **Behavior & features (opportunity + vision — generative)** — this is the creative lens; run it
   project-wide whenever the change-gated rungs are dry, not only over the dirty set. Ask *"what would
   make this project genuinely better for its users and maintainers?"* and propose net-new value:
   runtime behavior, user workflows, automation, external integrations, data flow, recovery paths,
   public APIs (mode `develop`), and teaching docs (mode `docs`). Two sub-tiers:
   - **opportunity** — concrete enhancements tied to a real surface and the mission; each must name a
     concrete user/maintainer payoff to clear the value bar.
   - **vision** — roadmap-level, design-first bets; state the design decision explicitly and require a
     preceding design item (Stage 7 rule b). A vision item must name a concrete, mission-aligned
     outcome, not a vague nicety — speculative niceties fail the value bar and are dropped.
   Stay grounded: every proposal still cites real surfaces and a runnable verification, and still
   passes Stage 10. Creativity widens *what* is proposed; it never lowers the grounding bar.
6. **Operations & reliability** — config seams, sensitive-data handling, persistence, retry,
   observability, maintenance — with concrete surfaces.
7. **Prioritization review** — rank, drop low-value/duplicate items, ensure mode diversity, confirm
   every survivor has exact surfaces + focused verification. Additionally flag and split/correct:
   (a) items calling named functions/static methods/global registries not in signals → split into
   prerequisite API-design item + integration item; (b) items depending on an unresolved design
   decision (ownership, API contract, retry policy, abstraction boundary) → require a preceding
   design item; (c) test-reorg without full group inventory or isolation accounting; (d)
   improve/reorganize claiming coverage/redundancy gains without a measurable baseline; (e) any
   function/method/type name in Evidence/Development absent from signals → correct to a verbatim
   name or remove; (f) extracting a `constexpr` helper to `.cpp` → unsafe, require a confirmed
   runtime-only helper first.

### Stage 8 — Draft

If the run's **depth ≥ 8**, first run the *adversarial re-review* over the dossier candidates: re-read
each as a hostile reviewer and drop any with a false premise, stale claim, or undeclared dependency. At
**depth 10**, also run the *second-opinion cross-check* — independently re-derive each candidate's
Evidence from signals and drop any that does not reproduce.

Convert the surviving dossier into draft checkbox items in the exact OUTPUT FORMAT below. Resolve
conflicts between candidates first. Select the highest-value `propose_count` items (`propose_count` is
the resolved propose count from **Inputs/Depth**).

### Stage 9 — Finalize

Re-check every draft item against PROJECT FILE PATHS, PROJECT TEST TARGETS, mode rules, and recently
completed work. Fix: vague titles, wrong modes, missing source/test surfaces, weak Development,
generic Acceptance, non-existent Verification targets; stale missing-file/missing-test claims; unsafe
template-header moves; `constexpr`-to-`.cpp` extractions; invented symbol/fixture names (replace with
verbatim names from signals or drop); singleton/global-API assumptions (rewrite to the real instance
API or split); coverage-preservation claims without measurable before/after. Use exact test target
names.

### Stage 10 — Strict quality gate (final)

Treat every item as suspect until it passes all of these; otherwise replace it with a safer,
better-verified item or drop it:

- Evidence cites a real AUDIT FINDING or non-comment SIGNAL proving the gap (not "related code exists").
- Evidence must never cite `.planwright/graph.json` or `.planwright/digest.md`; the graph routes
  attention only — proof must come from code re-read this run. An item whose Evidence references graph
  memory fails the gate.
- For `repair` items, Evidence must name a specific execution path or return value that is wrong —
  "X is absent" is insufficient; cite the call site (file:line), the incorrect output, and the
  expected output. For `improve` and `docs` items, structural absence Evidence remains acceptable.
- No behavioral claim inferred from filenames/comments/type names alone.
- No stale file/test-creation claims when the path/target already exists.
- No header-only template impl moved into `.cpp` unless instantiations are explicitly preserved.
- No `constexpr` helper extracted to `.cpp`.
- Every function/method/type/`TEST`/`TEST_F` name appears **verbatim** in signals for its surface.
- `CMakeLists` without `.txt` is invalid; correct to an exact path.
- No duplication of behavior already implemented; no false-premise claims.
- No destructive workspace/VCS/cleanup item that could discard unrelated user work (tool-owned/
  checkpointed files or explicit opt-in only).
- `Surfaces:` holds only existing paths; new files go under `New Surfaces:`.
- Mode correct: `develop` = new runtime/security behavior, `improve` = behavior-preserving quality,
  `repair` = confirmed defect only.
- Development tells the engineer *where and how*; Acceptance describes observable + preserved behavior;
  Verification covers every declared surface using exact PROJECT TEST TARGETS.
- No item depends on an unresolved design decision unless the design item precedes it or the decision
  is stated explicitly in Development.
- **Value bar (maturity rungs):** an `opportunity` item must name a concrete user/maintainer payoff; a
  `vision` item must name a concrete, mission-aligned outcome. A proposal that amounts to a vague
  nicety ("could be cleaner", "might be nice") fails the bar — drop it. Better to declare the final
  point honestly than to pad the plan with sub-bar items.

### Stage 11 — Write the plan

If `dry-run` was passed, print the surviving items to the chat and STOP — write no file.
Otherwise append the surviving items (separated by a blank line) to `<target>/.planwright/plan.md`
below any existing pending items, preserving them. If the file was archived/fresh, create it with the
header:

```
# planwright Plan — <target-or-".">
<!-- Session: <UTC ISO-8601 timestamp> -->
```

If `dry-run` was passed, stop here (no graph-memory state is persisted on a dry run). Otherwise,
**persist the incremental-audit baseline** so the next run's Stage 1.5 dirty-set comparison has
something to diff against:

1. **Stamp `last_audited_sha`** — in `.planwright/graph.json`, set `last_audited_sha = graph_built_at_sha`
   for every node that was in scope this run (the dirty set on an incremental run, or all nodes on a
   first/whole-graph-invalidation run). Leave skipped nodes' prior `last_audited_sha` untouched. Write
   with the native Write tool. Without this stamp every future run looks like a first run and re-audits
   everything, so this step is what actually activates incremental skipping.
2. **Refresh `digest.md`** — write `.planwright/digest.md` with one short block per cluster (id, label,
   member count, a one-line routing summary), each block prefixed `UNVERIFIED — routing only`. This is
   the carried-forward dossier Stages 3–7 resume from; it is **never** valid Evidence (Stage 10 bars
   citing it). Refresh only audited clusters; leave untouched clusters' prior blocks in place.
3. **Maintain `final.md`** — if this round wrote **≥1 item**, delete any stale `.planwright/final.md`
   (the ladder is live again). If this round wrote **0 items because all four maturity rungs were dry**
   (not merely an empty dirty set — the maturity-gated rungs were surveyed project-wide and produced
   nothing above their value bar), write `.planwright/final.md` with one block: the HEAD sha, the date,
   each rung (repair/coverage/opportunity/vision) marked dry, and a one-line reason per rung. This is
   the recorded **final point**; it is routing/status only and is **never** valid Evidence.

Print a short summary: counts proposed/written, pending total, nodes restamped, clusters digested,
rungs surveyed (lowest non-empty / final-point), and any capacity stop.

## OUTPUT FORMAT (exact)

Each item is one checkbox line plus 6-space-indented continuation lines. Emit nothing else — no
preamble, headings, code, or commentary in the plan file.

```
- [ ] <Feature or fix title>
      Mode: <develop|improve|repair|docs|reorganize>
      Rationale: <one concise sentence grounded in audit findings or non-comment code evidence>
      Evidence: <specific audit finding or PROJECT IMPLEMENTATION SIGNAL that proves the gap>
      Surfaces: <comma-separated existing repo-relative files that already exist and will change>
      New Surfaces: <comma-separated repo-relative files to create; omit this line if none>
      Development: <concrete implementation advice naming the first seam/call site/tests to update>
      Acceptance: <observable completion criteria or preserved behavior>
      Verification: <exact command, prefer: ctest --test-dir build -R "<target>" --output-on-failure>
```

### Mode assignment

| Mode | Use for |
|------|---------|
| `develop` | new runtime behavior, user-visible automation, new APIs/modules, feature integration |
| `improve` | behavior-preserving refactor, test coverage, consistency, performance, maintainability |
| `repair` | build failures, sanitizer errors, correctness bugs, test failures |
| `docs` | documentation gaps, README updates, API docs |
| `reorganize` | file layout, header/source misalignment, structural defects |

## Hard rules (do not violate)

- Every item is actionable, non-trivial, and grounded in AUDIT FINDINGS or non-comment SIGNALS.
- Evidence must never cite `.planwright/graph.json` or `.planwright/digest.md`; graph memory routes
  attention, it never serves as proof.
- Do not default everything to `improve`; use `develop` when the item adds/integrates runtime behavior.
- Repair/correctness items come before feature items when the audit demands them.
- Do not claim files/tests/config are missing when they're listed in FILE PATHS / TEST TARGETS.
- Development must name ≥1 concrete function/method/call site inside the declared Surfaces.
- Do not re-propose existing pending items; do not re-propose recently completed items unless the
  audit shows regression; do not re-propose previously rejected items unless the rejection reason is
  resolved (and Development must state what changed).
- Climb the maturity ladder before idling: when the change-gated rungs are dry, survey the
  opportunity and vision rungs project-wide. Declare the final point (write `.planwright/final.md`)
  only when all four rungs are genuinely dry — never pad the plan with sub-value-bar filler to avoid
  stopping, and never stop merely because the dirty set is empty.
- Output **only** the plan file. No code, no edit bundles.

# Execute (implement the plan)

Reached only via `/planwright execute`. This is the mutating path: it edits source, runs
verification, and commits. Everything below replaces the planning Procedure.

## Preconditions (check first, in order)

1. **Plan exists** — `.planwright/plan.md` has at least one pending `- [ ]` item. If none, report
   "No pending items to execute" and STOP.
2. **Clean working tree** — run `git status --porcelain`. If it reports anything, STOP and report the
   dirty tree (do not entangle the user's uncommitted work with per-item commits). Exception: ignored
   paths such as `.planwright/` do not count.
3. **Announce the branch** — print the current branch (`git branch --show-current`); per-item commits
   land here. There is no safety branch by design.

## Modes and scope

- **Auto (default)** — implement every pending item in plan order without asking item-by-item.
- **`--interactive`** — for each item: show it, wait for approval, implement, show the diff, run
  verification, and confirm before committing. Skipped items stay pending.
- **`execute N`** — act on pending item number `N` only (1-based over pending items).

In both modes, Claude Code's normal tool permission prompts for edits and commits still apply — auto
only suppresses planwright's *own* item-by-item questions, never the permission system.

## Per-item loop

For each targeted pending item, in plan order:

1. **Implement** the `Development:` line. Edit only the declared `Surfaces:` (and create the declared
   `New Surfaces:`). If the work would require touching files outside those surfaces, treat the item
   as **blocked** (see below) rather than expanding scope silently.
2. **Verify** — run the item's `Verification:` command exactly.
   - If the item has no `Verification:` line, or the command cannot be run (missing target, unknown
     tool), do **not** mark it done — reject it with reason `unverifiable: <detail>`.
3. **On PASS** — flip `- [ ]` to `- [x]` in `plan.md`, then commit on the current branch with message
   `planwright: <item title>` (use the Haiku commit convention if configured). Move the completed item
   to `completed.md` and enforce the FIFO cap of 100.
4. **On FAIL** — make up to **2 repair attempts** (re-read the error, adjust, re-verify). If it still
   fails, **reject**: revert this item's edits (`git restore` / `git checkout --` the touched paths so
   no partial change is committed), append a `Status:Rejected` and `Rejection: <one-line reason>` to
   the item, move it to `rejected.md` (FIFO cap 100), and continue.
5. **Blocked** — if the item depends on an unresolved design decision, or needs surfaces it does not
   declare, leave it pending, record why, and treat it as a **hard blocker**: in auto mode STOP here.

## After all targeted items — broad final verification

Run the project's full build + test (not just per-item focused tests). If it fails, STOP and report:
the per-item commits stand, but the batch is **not** clean — do not claim success. A green per-item
verify that breaks the overall build is exactly what this step catches.

## Stop conditions (auto mode)

Keep going across items, sending failures to `rejected.md`. Pause/STOP only on a **hard blocker**:
a blocked item (design decision / undeclared surfaces) or a failing broad final verification.

## Rejection schema (must be machine-readable for the feedback loop)

A rejected item keeps its original lines and gains:

```
      Status: Rejected
      Rejection: <one concise reason: what failed and why; e.g. "verification planwright_foo_tests failed: <symptom>">
```

The next plan run reads these reasons (Stage 1 → PREVIOUSLY REJECTED) to avoid re-proposing doomed
work, which is how rejections trend down over time.

## Final report

Print: items completed (with commit short-SHAs), items rejected (with reasons), items left pending or
blocked, and the broad final-verify result.

# Cycle (plan → execute, repeated)

Reached only via `/planwright cycle N`. Runs N sequential plan→execute rounds on the current branch
without interruption. Each round proposes new items, implements them all, verifies, and feeds the
results into the next round's audit, **climbing the maturity ladder** (repair → coverage → opportunity
→ vision) as lower rungs run dry. Useful for unattended dogfooding or bulk progress on a feature. It
stops only at a hard blocker, a failed broad verify, or a **recorded final point** (all rungs dry).

## Preconditions

1. **N is valid** — N must be a non-zero integer. Positive values (1–100) run exactly N cycles.
   **Negative values run unlimited cycles** — the loop continues until a stop condition fires (no
   more work, hard blocker, or failed broad verify). Zero is invalid.
   If missing or non-integer, print `Usage: /planwright cycle <N>  (N ≠ 0; negative = unlimited)`
   and STOP.
2. **Clean working tree** — run `git status --porcelain`. If it reports anything (excluding
   `.planwright/`), STOP and report the dirty paths. Do not mix uncommitted work with per-item commits.
3. **Announce** — print the current branch (`git branch --show-current`), the cycle mode
   (`N cycles` or `unlimited`), and the planning depth (`depth <M>`, default 6) before starting any work.

## Per-cycle loop (repeat up to N times, or indefinitely when N < 0)

For each cycle i (starting at 1, bounded by N when N > 0, unbounded when N < 0):

1. **Print header** — `=== Cycle i/N ===` (or `=== Cycle i/∞ ===` for unlimited) so progress is
   visible in long runs.
2. **Plan** — run the full planning Procedure (Stages 0–11) at the cycle's depth (the `depth <N>`
   passed to `cycle`, else default **6**) with otherwise-default settings: depth-derived `propose`,
   no instruction, no `no-compact`, no `dry-run`. The same depth applies to every round. Record the
   number of new items Stage 11 wrote.
3. **Check for work** — Stage 11 writing **0 new items** with **0 pending items** is **not** by itself
   a stop: it only means the change-gated rungs are dry. The planning round must have climbed the
   **maturity ladder** (surveyed the opportunity and vision rungs project-wide; see **Maturity ladder &
   the final point**) before idling. Stop early **only when the planning round declared the final
   point** — i.e. it wrote `.planwright/final.md` because all four rungs were dry. Then print
   `Cycle i/N: final point reached — <one-line why>.` and STOP. If items are pending or were written,
   proceed to Execute as normal.
4. **Execute** — run the full per-item execute loop over every pending item (same as
   `/planwright execute` auto mode). Collect per-cycle stats: items completed, items rejected.
5. **Broad final verification** — run the project's full build + test suite (not just per-item
   focused tests). If it fails, STOP and report; per-item commits from this cycle stand but the
   batch is not clean — do not start the next cycle.
6. **Cycle summary** — print: cycle number, items proposed / completed / rejected this cycle, broad
   verify result (`PASS` or `FAIL`).

## After all cycles (or early stop)

Print a cumulative summary:
- Total cycles completed (out of N requested, or `∞` for unlimited mode)
- Total items implemented (with all commit short-SHAs)
- Total items rejected (titles + one-line reasons)
- Stop reason if stopped before N: `hard blocker`, `broad-verify failed`, or `final point reached`
  (all four maturity rungs dry — see `.planwright/final.md`)

## Stop conditions

Stop and do **not** start the next cycle on any of:

- A **hard blocker** during execute (item needs undeclared surfaces or an unresolved design decision).
- A **failing broad final verification** after execute.
- **Final point**: the planning round declared all four maturity rungs dry and wrote
  `.planwright/final.md` (step 3 above). An empty dirty set / empty backlog alone is **not** a stop —
  the maturity-gated rungs must have been surveyed and come up empty first.

Individual item rejections are **not** a stop condition — the cycle continues and the next planning
round's audit will learn from the rejection reasons in `rejected.md`.

# Upgrade (update planwright itself)

Reached only via `/planwright upgrade`. Updates the installed planwright plugin to the latest version.
This path does **not** plan or edit your project; it only refreshes planwright.

## Procedure

1. **Locate the marketplace source.** Read `~/.claude/plugins/known_marketplaces.json` and find the
   `planwright` entry. Note its `source` (a `github` repo, or a local `directory`/`git` path) and the
   installed version from `~/.claude/plugins/installed_plugins.json` (`planwright@planwright`).
2. **Refresh the source when it is a local git clone.** If the source is a `directory`/`git` path that
   is a git repo, run `git -C <path> pull --ff-only` to fetch the latest. If that tree is dirty or the
   pull is not fast-forward, STOP and report — do not force it. For a `github` source, skip this step
   (the marketplace update fetches directly).
3. **Report versions.** Print installed version → latest available `version` from the source's
   `.claude-plugin/plugin.json`. If they already match, say "already up to date" and skip step 4.
4. **Hand off the two interactive steps.** The skill cannot run `/plugin` or `/reload-plugins` itself
   (they are user UI commands). Tell the user to run, in order:
   - `/plugin marketplace update planwright`
   - `/plugin install planwright@planwright` (only if the version did not advance after the update)
   - `/reload-plugins`
5. **Confirm.** After the user reloads, the new version is active; suggest `/planwright help` to verify.

Report: source type, old → new version, whether a local pull ran, and the handoff steps.

# Version (show current and latest)

Reached via `/planwright version` (or `--version`, `-V`). Read-only — it neither plans nor edits.

## Procedure

1. **Current** — the installed/running version: read `~/.claude/plugins/installed_plugins.json`
   (`planwright@planwright`). If that is unavailable (e.g. running from `~/.claude/skills/` without the
   plugin), fall back to this file's frontmatter `metadata.version`.
2. **Latest** — read the `version` from the marketplace source's `.claude-plugin/plugin.json` (resolve
   the source path from `~/.claude/plugins/known_marketplaces.json`). For a `github` source whose clone
   is not local, report latest as "unknown (run /planwright upgrade to fetch)".
3. **Report** one line: `planwright <current> (latest <latest>)`. If latest > current, add
   "→ upgrade available: run /planwright upgrade"; if equal, add "→ up to date".

STOP after reporting.
