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
  Supports: execute [--interactive] [N], cycle <N>, update, version, upgrade, propose <N>, max <N>, no-compact, dry-run, help.
license: GPL-3.0-or-later
metadata:
  author: Eser KUBALI
  version: "1.10.0"
---

# planwright

This skill has three clearly partitioned paths:

- **Plan** (`/planwright`, default) — scans and audits the codebase, then runs a multi-stage
  *dossier → draft → finalize → quality-gate* pipeline to emit concrete plan items in
  `.planwright/plan.md`. **Read-only: it writes only the plan file, never application source.**
- **Execute** (`/planwright execute`) — implements the pending plan items, verifies each, commits
  the ones that pass, and records the rest. **This is the only path that edits source.**
- **Cycle** (`/planwright cycle N`) — runs N sequential plan→execute rounds unattended: proposes
  items, implements them all, verifies, then repeats. Stops early when there is nothing left to do.

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
  follow that procedure instead of the planning Procedure. The remaining token is the repeat count `N`.
- If the first token is `upgrade` or `update`, dispatch to the **Upgrade** section at the end of
  this file and follow that procedure instead of the planning Procedure.
- Otherwise treat the argument as either an **instruction** (free text to break down) and/or inline
  **option overrides** (see Options), then run the planning Procedure.

### Usage

```
PLAN (read-only)
/planwright                      Plan from audit (propose 5, default settings)
/planwright <instruction>        Break a specific request into plan items
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
| `propose <N>` | `5` | items to propose this run (clamped to `1..max`) |
| `max <N>` | `20` | cap on pending unchecked items in the plan |
| `no-compact` | off | skip Stage 0 housekeeping for this run |
| `dry-run` | off | run everything but print the plan, write nothing |
| `help` | — | print Usage and stop |

Precedence: **inline option > built-in default.** There is no settings file; options are per-run only.

## Inputs

- **Target**: the repo to plan for. Default `.` (current working directory).
- **Instruction** (optional): a user request to break down. If absent, plan from the audit.
- **Capacity**: propose at most `5` new items per run, and never let the active plan's *pending*
  items exceed `20`. `propose_count = min(5, 20 − pending_unchecked_items)`. If `propose_count == 0`,
  stop and report "Plan is at capacity"; do not invent filler items.

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

### Stage 2 — Audit (mechanical + reasoning)

Run four named sub-passes in order. Each must emit findings with **file:line anchors** — category
labels alone are not findings. Carry all findings forward into the dossier.

**2a. Structural** — inventory: oversized modules (>300 lines), missing focused tests (only when
genuinely absent from PROJECT TEST TARGETS), risky refactors lacking coverage, signal/surface
mismatches. Each finding: path, size or gap, why it matters.

**2b. Correctness** — open and read the bodies of the top-N most complex functions (rank by line
count or branching). For each, trace every non-trivial path: look for silent failures (error return
ignored, wrong default returned, exit 0 on bad state), unchecked preconditions, and off-by-one or
boundary errors. Findings must cite file:line, the specific path, and the defect.

**2c. Invariants** — enumerate data contracts that the code *assumes* but never enforces: value
ranges, non-empty inputs, sorted order, clean-tree state, valid format strings, unique names. For
each assumed-but-unenforced invariant, note the assumption site (file:line) and the enforcement gap.

**2d. Behavioral coverage** — for each public entry point, identify inputs that produce untested or
unspecified output: boundary values, empty collections, concurrent calls, failure return from a
dependency. Findings must name the entry point (file:line) and the uncovered input class.

### Stages 3–7 — Cumulative planning dossier (reasoning passes)

Build one growing `PLANNING DOSSIER` with sections **Findings, Candidate Work, Risks, Verification
Targets, Rejected Ideas**. Do *not* emit checkbox items yet. Each pass preserves prior useful
findings and adds/corrects for its lens:

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

### Stage 11 — Write the plan

If `dry-run` was passed, print the surviving items to the chat and STOP — write no file.
Otherwise append the surviving items (separated by a blank line) to `<target>/.planwright/plan.md`
below any existing pending items, preserving them. If the file was archived/fresh, create it with the
header:

```
# planwright Plan — <target-or-".">
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
results into the next round's audit. Useful for unattended dogfooding or bulk progress on a feature.

## Preconditions

1. **N is valid** — N must be a non-zero integer. Positive values (1–100) run exactly N cycles.
   **Negative values run unlimited cycles** — the loop continues until a stop condition fires (no
   more work, hard blocker, or failed broad verify). Zero is invalid.
   If missing or non-integer, print `Usage: /planwright cycle <N>  (N ≠ 0; negative = unlimited)`
   and STOP.
2. **Clean working tree** — run `git status --porcelain`. If it reports anything (excluding
   `.planwright/`), STOP and report the dirty paths. Do not mix uncommitted work with per-item commits.
3. **Announce** — print the current branch (`git branch --show-current`) and the cycle mode
   (`N cycles` or `unlimited`) before starting any work.

## Per-cycle loop (repeat up to N times, or indefinitely when N < 0)

For each cycle i (starting at 1, bounded by N when N > 0, unbounded when N < 0):

1. **Print header** — `=== Cycle i/N ===` (or `=== Cycle i/∞ ===` for unlimited) so progress is
   visible in long runs.
2. **Plan** — run the full planning Procedure (Stages 0–11) with default settings: `propose 5`,
   no instruction, no `no-compact`, no `dry-run`. Record the number of new items Stage 11 wrote.
3. **Check for work** — count pending `- [ ]` items in `.planwright/plan.md`.
   - If Stage 11 wrote **0 new items** AND there are **0 pending items**: print
     `Cycle i/N: nothing to do — stopping early.` and STOP. This is the natural-completion signal:
     the audit found no further gaps and the backlog is empty.
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
- Stop reason if stopped before N: `hard blocker`, `broad-verify failed`, or `no more work`

## Stop conditions

Stop and do **not** start the next cycle on any of:

- A **hard blocker** during execute (item needs undeclared surfaces or an unresolved design decision).
- A **failing broad final verification** after execute.
- **No progress**: Stage 11 proposed 0 new items AND plan has 0 pending items (step 3 above).

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
