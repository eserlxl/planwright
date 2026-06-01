---
name: planwright
description: >
  Replicate ai-developer's plan mode: scan + audit a codebase and produce a grounded,
  verification-ready checkbox plan in .ai-developer/plan.md using the exact 8-field item
  format (Mode/Rationale/Evidence/Surfaces/New Surfaces/Development/Acceptance/Verification).
  Runs the same multi-stage dossier → draft → finalize → quality-gate pipeline that the
  ai-developer binary's `plan` command runs, but with Claude doing the reasoning directly
  instead of issuing separate LLM calls.
  Trigger when the user asks to "plan", "run plan mode", "generate a plan", "refresh the plan",
  "propose plan items", or mentions .ai-developer/plan.md. Run `/planwright help` for usage and options.
  Supports options: propose <N>, max <N>, no-compact, dry-run, help.
metadata:
  author: ai-developer-lab
  version: "1.0.0"
  source: src/workflow/planning_pipeline.cpp, src/workflow/detail/planning_stage_executor.cpp
---

# planwright

This skill makes Claude act as the planner that the `ai-developer plan` command implements.
It produces the **same artifact** (`.ai-developer/plan.md`) in the **same format**, following the
**same multi-stage reasoning and quality gates** — but without spending separate model calls,
because Claude itself runs every stage.

Do not edit application source to "plan". The output of this skill is **only** the plan file.

## Invocation & help

Before doing anything else, inspect the argument the skill was invoked with:

- If it is `help`, `--help`, `-h`, `?`, or empty-with-an-explicit-help-request, **print the Usage
  reference below verbatim and STOP.** Do not scan, audit, plan, or write any file.
- Otherwise treat the argument as either an **instruction** (free text to break down) and/or inline
  **option overrides** (see Options), then run the Procedure.

### Usage

```
/planwright                      Plan from audit + mission (propose 5, default settings)
/planwright <instruction>        Break a specific request into plan items
/planwright propose <N>          Override items proposed this run (1..max)
/planwright max <N>              Override the pending-item cap for this run
/planwright no-compact           Skip lifecycle housekeeping (no archive/drain this run)
/planwright dry-run              Do all stages but print the plan instead of writing the file
/planwright help                 Show this help and stop
```

Options may be combined with an instruction, e.g.
`/planwright add OAuth login propose 3 dry-run`.

### Options

| Option | Default | Effect |
|--------|---------|--------|
| `<instruction>` | none | free-text request to decompose into items |
| `propose <N>` | `5` | items to propose this run (clamped to `1..max`) |
| `max <N>` | `20` | cap on pending unchecked items in the plan |
| `no-compact` | off | skip Stage 0 housekeeping for this run |
| `dry-run` | off | run everything but print the plan, write nothing |
| `help` | — | print Usage and stop |

Precedence: **inline option > built-in default.** There is no settings file; options are per-run only.

## Inputs

- **Target**: the repo to plan for. Default `.` (current working directory).
- **Instruction** (optional): a user request to break down. If absent, plan from audit + mission.
- **Capacity**: propose at most `5` new items per run (`plan_feature_count`), and never let the
  active plan's *pending* items exceed `20` (`max_plan_feature_count`).
  `propose_count = min(5, 20 − pending_unchecked_items)`. If `propose_count == 0`, stop and report
  "Plan is at capacity"; do not invent filler items.

## Procedure

Run these stages in order. Stages 0–2 are mechanical (use tools). Stages 3–10 are reasoning passes
you perform yourself — treat each as a distinct lens and carry forward a cumulative dossier.

### Stage 0 — Lifecycle housekeeping (mechanical)

If `no-compact` was passed, skip this entire stage (still read pending items in step 4).
Operate on `<target>/.ai-developer/`:

1. If `plan.md` exists, move every completed item (`- [x] ...` and its indented continuation lines)
   into `completed.md` (append). Keep at most the configured tail in `plan.md`; archive the rest.
2. Drain any item carrying a `Status:Rejected` / `Status: Rejected` continuation line into
   `rejected.md` (append), removing it from `plan.md`.
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
- **PROJECT TEST TARGETS** — exact CTest target names (e.g. from `add_test`/`gtest_discover_tests`
  / `ctest -N`). Verification commands must use these verbatim.

Also read `MISSION.yaml` (PROJECT MISSION) if present.

### Stage 2 — Audit (mechanical + reasoning)

Derive AUDIT FINDINGS: oversized modules, missing focused tests (only when genuinely absent from
PROJECT TEST TARGETS), risky refactors lacking coverage, correctness/safety gaps, structural
defects, missing runtime behavior. Each finding must point at concrete paths/signals.

### Stages 3–7 — Cumulative planning dossier (reasoning passes)

Build one growing `PLANNING DOSSIER` with sections **Findings, Candidate Work, Risks, Verification
Targets, Rejected Ideas**. Do *not* emit checkbox items yet. Each pass preserves prior useful
findings and adds/corrects for its lens:

3. **Architecture** — module boundaries, oversized units, public API surfaces, dependency
   direction, source/header/test clusters, C++ header-only/template constraints.
4. **Quality & tests** — weak/missing focused tests, wrong verification targets, refactors needing
   coverage, exact CTest anchors. For any test split/consolidation candidate, enumerate **every**
   `TEST`/`TEST_F` group in the file and flag compile-time-sensitive tests (preprocessor-manipulating,
   include-order-sensitive, distinct-translation-unit-dependent) that must stay isolated.
5. **Behavior & features** — work that adds/integrates runtime behavior, user workflows,
   automation, external integrations, data flow, recovery paths, public APIs → classify as `develop`.
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

Convert the dossier into draft checkbox items in the exact OUTPUT FORMAT below. Resolve conflicts
between candidates first. Select the highest-value `propose_count` items.

### Stage 9 — Finalize

Re-check every draft item against PROJECT FILE PATHS, PROJECT TEST TARGETS, mode rules, mission, and
recently completed work. Fix: vague titles, wrong modes, missing source/test surfaces, weak
Development, generic Acceptance, non-existent Verification targets; stale missing-file/missing-test
claims; unsafe C++ template-header moves; `constexpr`-to-`.cpp` extractions; invented symbol/fixture
names (replace with verbatim names from signals or drop); singleton/global-API assumptions (rewrite
to the real instance API or split); coverage-preservation claims without measurable before/after.
Use exact CTest target names.

### Stage 10 — Strict quality gate (final)

Treat every item as suspect until it passes all of these; otherwise replace it with a safer,
better-verified item or drop it:

- Evidence cites a real AUDIT FINDING or non-comment SIGNAL proving the gap (not "related code exists").
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

### Stage 11 — Write the plan

If `dry-run` was passed, print the surviving items to the chat and STOP — write no file.
Otherwise append the surviving items (separated by a blank line) to `<target>/.ai-developer/plan.md`
below any existing pending items, preserving them. If the file was archived/fresh, create it with the
header:

```
# AI Developer Plan — <target-or-".">
<!-- Session: <UTC ISO-8601 timestamp> -->
```

Print a short summary: counts proposed/written, pending total, and any capacity stop.

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
- Do not default everything to `improve`; use `develop` when the item adds/integrates runtime behavior.
- Repair/correctness items come before feature items when the audit demands them.
- Do not claim files/tests/config are missing when they're listed in FILE PATHS / TEST TARGETS.
- Development must name ≥1 concrete function/method/call site inside the declared Surfaces.
- Do not re-propose existing pending items; do not re-propose recently completed items unless the
  audit shows regression; do not re-propose previously rejected items unless the rejection reason is
  resolved (and Development must state what changed).
- Output **only** the plan file. No code, no edit bundles.
