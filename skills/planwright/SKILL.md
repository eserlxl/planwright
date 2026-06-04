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
  Supports: execute [--interactive] [N], cycle <N>, explore, invent, seed <S>, update, version, upgrade, depth <D>, propose <N>, max <N>, no-compact, dry-run, help.
argument-hint: "[instruction] | execute [N] | cycle <N> [depth <D>] [explore|invent [seed <S>]] | depth <D> | version | upgrade | help"
license: GPL-3.0-or-later
metadata:
  author: Eser KUBALI
  version: "1.31.0"
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
  trailing `depth <D>` (and other plan options) applies to every planning round in the cycle.
- If the first token is `upgrade` or `update`, dispatch to the **Upgrade** section at the end of
  this file and follow that procedure instead of the planning Procedure.
- Otherwise treat the argument as either an **instruction** (free text to break down) and/or inline
  **option overrides** (see Options), then run the planning Procedure.

### Usage

```
PLAN (read-only)
/planwright                      Plan from audit (depth 6, propose 5, default settings)
/planwright <instruction>        Break a specific request into plan items
/planwright depth <D>            Set analysis depth 1..10 (intensity + audit thoroughness; default 6)
/planwright propose <N>          Override items proposed this run (1..max)
/planwright max <N>              Override the pending-item cap for this run
/planwright no-compact           Skip lifecycle housekeeping (no archive/drain this run)
/planwright dry-run              Do all stages but print the plan instead of writing the file

SCOPE (aim a run at one component; composes with plan / execute / cycle)
/planwright path <X>             Restrict to a subtree/glob: plan items land in that Focus,
                                 analysis still reads its 1-hop blast radius (Context)
/planwright lib <X>              Same, but resolve a logical component name (cluster /
                                 build target / package / dir) to the Focus set

EXECUTE (edits source)
/planwright execute              Auto: implement every pending item, commit each that passes
/planwright execute --interactive  Prompt per item: approve, show diff, verify, confirm commit
/planwright execute N            Implement only pending item number N

CYCLE (automated plan → execute loops)
/planwright cycle <N>            Plan then execute, repeated N times (1..100)
/planwright cycle <-N>           Plan then execute until a recorded final point (unlimited, negative N)
/planwright cycle <N> depth <D>  Run the cycle with planning depth D (1..10) every round
/planwright cycle <N> explore    Opt-in: at the final point, escalate instead of stopping —
                                 cold-frontier sweep, then the expand tier (complete latent
                                 capability), spending the remaining cycle budget (see Escalation ladder)
/planwright cycle <N> invent     Superset of explore + permission to add net-new, seam-bound
                                 capability (the invent tier, a bounded burst, after expand is dry)
/planwright cycle <N> invent seed <S>   Opt-in: focus the invent tier through one seeded generative
                                 framing (a recorded vantage). Scopes which net-new ideas a run
                                 surveys; successive seeds explore different regions (see Escalation
                                 ladder). No-op without invent. Default invent stays comprehensive
/planwright cycle <N> depth <D> explore   Combine: every round (and the escalation) runs at depth D

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
| `depth <D>` | `6` | analysis depth `1..10` — scales reasoning intensity + audit thoroughness (see **Depth**) |
| `propose <N>` | from depth (`5` at depth 6) | items to propose this run (clamped to `1..max`) |
| `max <N>` | `20` | cap on pending unchecked items in the plan |
| `no-compact` | off | skip Stage 0 housekeeping for this run |
| `dry-run` | off | run everything but print the plan, write nothing |
| `path <X>` | whole repo | **scope**: aim the run at a subtree/glob — items land in that **Focus**; analysis still reads its 1-hop blast radius (**Context**). Composable, depth-orthogonal (see **Scope**) |
| `lib <X>` | whole repo | **scope**: like `path`, but resolve a logical component name (cluster / build target / package / dir) to the Focus set (see **Scope**) |
| `explore` | off | **cycle only**: at the final point, escalate instead of stopping — cold-frontier sweep, then the **expand** tier (complete latent capability), spending the remaining cycle budget (see **Escalation ladder**) |
| `invent` | off | **cycle only**: superset of `explore` — additionally permits net-new, seam-bound capability (the **invent** tier, a bounded ≤3-cycle burst) after the expand tier is dry (see **Escalation ladder**) |
| `seed <S>` | none (deterministic) | **`invent` only**: focus the invent generative survey through one seeded **framing** (a recorded vantage from a fixed catalog). *Scopes* which net-new ideas a single run surveys — comprehensiveness is recovered across the seed sequence (cross-run), so successive seeds explore different regions instead of re-deriving the same ideas. No effect without `invent`; an unseeded `invent` stays comprehensive and deterministic. Integer. Recorded in `final.md` as `invent_seed`/`invent_framing` (see **Escalation ladder**, Stage 5) |
| `help` | — | print Usage and stop |

Precedence: **inline option > built-in default.** There is no settings file; options are per-run only.

### Depth

`depth <D>` (1–10, default **6**) is a single dial that scales the whole planning pipeline: how hard
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
3. **opportunity** — net-new value grounded in a real surface *and* the project's stated direction
   (PROJECT DIRECTION: mission/charter + README + roadmap, see Stage 1): features, DX, ergonomics,
   robustness, observability, teaching docs (mode `develop`/`docs`).
4. **vision** — roadmap-level, design-first initiatives: a stated design decision precedes
   implementation; larger multi-step bets (mode `develop`, often with a preceding design item).

Each run proposes from the **lowest non-empty rung**, and may seed a few items from the next rung up to
keep forward motion. The decisive rule that prevents premature idling:

- **Rungs 1–2 are change-gated** — the Stage 1.5 dirty set scopes them; they look only where code
  changed. An empty dirty set means rungs 1–2 are dry, *not* that there is no work.
- **Rungs 3–4 are maturity-gated, not change-gated** — when rungs 1–2 are dry they run over the
  **whole project** against PROJECT DIRECTION (mission/charter + README + roadmap, see Stage 1),
  **even when the dirty set is empty**. This is what
  lets a clean, fully-audited tree keep producing valuable work instead of stopping.
- **Under a Scope** (`path <X>` / `lib <X>`, see **Inputs**) the gating is unchanged but the *reach*
  narrows: rungs 1–2 scope to `dirty ∩ Focus`, and rungs 3–4 survey **Focus-wide** (the scoped
  component) instead of project-wide — so a scoped run matures just that component toward its stated
  role. Items still land only in Focus (Stage 10), while analysis may read the wider Context.

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

## Escalation ladder

`explore` and `invent` (the opt-in `cycle … explore` / `cycle … invent` flags) are **not** different
planning modes and they **never lower the grounding bar** — every item they yield still clears Stage 10
and a rung value bar, cites a real surface, and carries a runnable verification. They change only *how
far the survey reaches* once the normal ladder would otherwise stop, bounded by two limits that never
move, plus a **novelty dial** the flag sets:

- **Grounding floor (every tier, every flag)** — the Stage 10 gate: a real attachment surface
  (`Surfaces:`; net-new files go in `New Surfaces:`, but `Development:` still names a real seam) and a
  runnable `Verification:`.
- **Hard ceiling (every tier, every flag)** — **no new subsystems, no unrelated domains, no architecture
  redesign from scratch, no speculative niceties.** Truly identity-changing work is out of scope for the
  loop no matter which flag is on.
- **Novelty dial (set by the flag)** — between floor and ceiling, the flag chooses how *novel* a
  proposal may be: `explore` permits **latent only** (complete/generalize what already exists, never a
  new concept); `invent` additionally permits **net-new** capability — a concept not previously present —
  *provided* it still bolts to a real existing seam and serves PROJECT DIRECTION. Typing `invent` **is**
  the permission to create; it relaxes only the "must already be latent" rule, never the floor or ceiling.

The flag escalates through ordered tiers — each a slightly larger reach than the last — **only at the
moment the normal ladder would declare a final point**, and only while the requested **cycle budget**
remains. The `N` in `cycle N` doubles as that budget: a final point reached at cycle `i < N` means you
authorised `N − i` more cycles, so the flag spends them climbing the ladder instead of stopping early.
`explore` climbs tiers ①→②; `invent` is a **superset** that climbs ①→②→③ (so `invent` does everything
`explore` does, and reaches the net-new tier only after the latent tier is itself dry — grounded
completion always precedes invention). Both are **orthogonal to `depth`** — every tier runs at the
cycle's depth.

**Tier ① — cold-frontier sweep (in-round; costs no budget cycle).** Default routing leads with the
**hot core** (high-blast-radius `ranked_code`: PageRank + articulation ∩ the dirty set); its blind spot
is the **cold frontier** — code the audit never reached and paths nothing exercises. When the hot-core
ladder is dry, re-run Stages 2–10 **once** with routing overridden to the graph's **`ranked_cold`** list
(never-audited first, then uncovered, then least-central — see `docs/graph-memory-schema.md`): Stage 2b
reads `ranked_cold` bodies, Stages 5–6 survey the cold clusters project-wide, articulation points always
included. This is part of the planning round, so it costs no extra cycle. If it writes ≥1 item the ladder
is live again; continue normally.

**Tier ② — expand (latent-capability completion; spends budget cycles).** If the cold frontier is also
dry and the cycle budget still allows, `explore` does **not** stop — it switches into the **expand**
posture and keeps cycling (up to `N`), surveying lenses 5–6 project-wide for work that is a **natural
completion or generalization of what already exists** (see Stage 5's expand lens): capabilities
implemented internally but not exposed, functionality the current design plainly implies but lacks,
overloads/parameters/modes that remove a hard-coded limit, a small helper that consolidates repeated
logic, and the focused tests that must precede such extension. Each candidate still clears the floor and
the ceiling — it attaches to a named existing surface and is never a new subsystem. Once active, the
expand posture persists across subsequent cycles until it too goes dry.

**Tier ③ — invent (net-new, seam-bound; `invent` flag only, bounded burst).** Reached only under
`invent`, and only once the cold frontier **and** the expand tier are both dry. It lifts the "must
already be latent" rule: lenses 5–6 may now propose a **genuinely new** capability, API, or mode — a
concept not present today — provided each candidate (a) bolts to a **real existing seam** (named in
`Surfaces:` / `Development:`; net-new files in `New Surfaces:`), (b) serves **PROJECT DIRECTION**, and
(c) stays under the hard ceiling (not a new subsystem, unrelated domain, or redesign). To keep the
riskiest tier from running away, `invent` runs as a **bounded burst** — at most a small fixed number of
cycles (**3**) per trigger, *independent of `N`* — before re-checking the fixpoint. If the burst writes
≥1 item, execute and continue; the natural limiter is structural — you can only invent where a real seam
exists to carry it. **`invent` must generate:** typing `invent` is permission to create, so the tier
**must emit ≥1 net-new item** whenever any candidate clears the floor + structural ceiling — it may emit
a below-value-bar or mission-stretching item (flagged in Rationale), and does **not** declare itself dry
merely because the project is deliberately minimal. The two hard gates (grounding floor, structural
ceiling) and plan capacity are never relaxed; the value bar / mission conservatism are (explicit-`invent`
only — see Stage 5's invent lens and Hard rules).

**Deep final point.** The run stops at the deepest fixpoint its flag can reach, recorded in
`.planwright/final.md` (marked with `deepest_tier:` and a one-line note), even if budget remains —
nothing groundable is left:
- under `explore`, when the hot core, cold frontier, **and** expand are all dry → `deepest_tier: expand`,
  `confirmed deep — cold-frontier and expand tiers both dry`;
- under `invent`, **only** in the rare genuine empty — no net-new candidate clears even the grounding
  floor + structural hard ceiling (no seam left to extend) → `deepest_tier: invent`,
  `confirmed deep — no groundable net-new seam remains`. Because `invent` **must generate** otherwise
  (above), an `invent` run normally does **not** reach this fixpoint; it runs to its cycle budget `N`
  (so `cycle -1 invent` keeps inventing), stopping early only at plan capacity.
This multi-tier fixpoint is a far more honest "stable" than a single hot-core survey.

**Termination.** Under **`explore`** the ladder is safe for any non-zero N (including `-1`): each tier is
finite and drains monotonically — swept cold nodes are restamped (`last_audited_sha = HEAD`, Stage 11)
and leave the frontier; expand candidates are implemented (advancing state) or dropped/rejected (recorded,
not re-proposed) — so the escalation is a bounded sequence that always ends in a recorded final point.
Under **`invent`** termination is deliberately different: the **invent-must-generate** rule means the
tier keeps producing groundable net-new work as long as any seam remains to extend, so an `invent` run
does **not** self-terminate at a fixpoint — it runs to its cycle budget `N` and `cycle -1 invent` runs
until you stop it (or plan capacity / a true no-seam empty halts it). Bounding still holds where it
matters: the invent burst is hard-capped at 3 cycles per trigger, and the two hard gates (grounding
floor, structural hard ceiling) plus the 20-item pending cap never move. The relaxation is scoped and
explicit: under `explore`/default the flag widens *reach* and **never pads** (a cold, latent, or
net-new-but-seamless surface is not automatically worth an item — it surfaces *candidates*); under
`invent` the value bar / mission conservatism are relaxed so the tier always lands a (possibly
flagged-as-stretch) net-new item. Both flags are a no-op outside the cycle path.

## Inputs

- **Target**: the repo to plan for. Default `.` (current working directory).
- **Instruction** (optional): a user request to break down. If absent, plan from the audit.
- **Capacity**: propose at most the resolved propose count — the depth-derived default (see **Depth**;
  depth 6 → `5`) or the explicit `propose <N>` when given — and never let the active plan's *pending*
  items exceed `20`. `propose_count = min(<resolved propose>, 20 − pending_unchecked_items)`. If
  `propose_count == 0`, stop and report "Plan is at capacity"; do not invent filler items.
- **Scope** (optional, from `path <X>` / `lib <X>`): aim the run at one component instead of the whole
  target. Resolved in Stage 1 into two node sets (see `docs/scope-design.md`): the **Focus** set (the
  scoped files — where plan items are proposed and land) and the **Context** set (Focus + its 1-hop
  import/coupling blast radius — what analysis *reads* so root cause and impact stay visible). Absent =
  whole repo (today's behaviour). Composable with every path and **orthogonal to `depth`**.
- **Seed** (optional, from `seed <S>`, **`invent` only**): an integer that focuses the invent tier
  through one recorded **framing** (a vantage from a fixed catalog; see Stage 5's invent lens). Passed to
  the Stage 1.5 builder as `--seed <S>`, which emits `explore_framing`. A single seeded run is an
  intentionally *focused* invent survey; comprehensiveness is recovered across the seed sequence. Absent,
  or without `invent`, = today's comprehensive, deterministic invent. Recorded in `final.md` as
  `invent_seed` / `invent_framing`. Orthogonal to `depth` and `scope`.

## Procedure

Run these stages in order. Stages 0–2 are mechanical (use tools). Stages 3–10 are reasoning passes
you perform yourself — treat each as a distinct lens and carry forward a cumulative dossier.

**Bundled scripts — resolve their path first.** planwright's canonical scripts (`build-graph.py`,
`lint-plan.py`) ship **inside the plugin**, not in the repo you are planning. Resolve them from the
**"Base directory for this skill"** path the harness prints when this skill loads: that base ends in
`skills/planwright`, and the scripts live two directories up under `scripts/` — i.e.
`<skill-base>/../../scripts/`. Compute that **absolute** path once at the start of the run and write it
as `<scripts>` wherever a script is invoked below (so `<scripts>/build-graph.py`,
`<scripts>/lint-plan.py`). **Never invoke a bundled script as a bare `scripts/…`** — the current working
directory is the *target* repo being planned (the user's project), which has no planwright `scripts/`
directory, so a bare path fails for every user except when planning planwright's own repo. If the
absolute script cannot be located or executed, fall back to the documented by-hand procedure for that
stage (Stage 1.5 for the graph; do the Stage 10 structural checks by hand for the linter) — never block.

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

Also read the project's **stated direction** — it is both a constraint on every item and the
anchor the generative rungs (lenses 5–6) propose *toward*:

- **PROJECT DIRECTION** — the mission/charter file if present (`MISSION.md`, `CHARTER.md`, …)
  **plus the README and any roadmap/vision docs** (`README*`, `ROADMAP*`, `docs/roadmap*`,
  `VISION*`). Treat mission/charter as the binding constraint; treat README and roadmap as the
  stated user-facing goals and intended direction. Together they are the ground truth for *what
  this project is trying to become* — the opportunity and vision rungs (Stages 5–6, the value
  bar, and "mission-aligned" throughout this file) are measured against this whole set, not the
  charter alone. If none exist, note that and let the generative rungs anchor on the observed
  public surfaces alone.

If a **Scope** was given (`path <X>` / `lib <X>`), resolve it here, before the rungs use it:

- **SCOPE → FOCUS / CONTEXT** — run `<scripts>/build-graph.py --scope <X>` (Stage 1.5 builds the graph
  anyway; pass `--scope` so it also emits the `focus` and `context` node lists). For `lib <X>`, resolve
  the logical name to a path set first — in order: an exact graph **cluster label**, then a **build
  target** (CMake `add_library`, a Cargo crate / workspace member, an npm workspace, a Python package
  `<X>/__init__.py`, a Go package dir), then a **directory named `<X>`** — and pass the resolved path(s)
  as `--scope`. **Focus** (the emitted `focus`) is where items may be proposed; **Context** (the emitted
  `context` = Focus + 1-hop blast radius) is what later stages may *read*. **A no-match is a hard error:**
  if `focus` is empty, report `scope '<X>' matched no files` and STOP — never silently fall back to a
  whole-repo run. When a component-level charter/README exists inside Focus, prefer it as the generative
  rungs' PROJECT DIRECTION anchor (still under the whole-repo mission as the binding constraint).

Then load the planning memory so this run learns from prior ones:

- **PREVIOUSLY REJECTED** — read `.planwright/rejected.md` (titles + `Rejection:` reasons). Carry
  these into every dossier pass as a constraint: do **not** re-propose a rejected item unless its
  specific rejection reason is now resolved, and if you do, the Development line must state what
  changed. Use the recurring reasons to steer away from whole classes of doomed work.
- **RECENTLY COMPLETED** — read `.planwright/completed.md` so you do not re-propose finished work
  (unless the audit shows a regression).
- **FINAL POINT** — read `.planwright/final.md` if present. Once Stage 1.5 has computed the dirty set,
  if `final.md`'s recorded sha equals the current HEAD **and** the dirty set is empty **and** no new
  instruction or higher depth was given this run **and** the run's scope matches the recorded one (the
  `scope:`/`scope_focus_sha:` fields equal this run's — a *whole-repo* run only short-circuits on a
  *whole-repo* final point, and a `path <X>` run only on the matching scoped one), the project is
  unchanged since the ladder was last exhausted *for that scope*: report `already at final point
  (<sha>)` and treat all four maturity rungs as dry (the run writes 0 items, and Stage 11 leaves the
  existing `final.md` in place). Otherwise treat `final.md` as stale and proceed normally — Stage 11
  step 3 deletes it once ≥1 item is written. (A scoped final point never suppresses a differently-scoped
  or whole-repo run.)

### Stage 1.5 — Build code graph (mechanical)

Build a structural model of the repo that **routes audit attention** to the highest-blast-radius
code. This stage always runs (lifecycle-level, like Stages 0 and 1; depth never skips it). Run the
whole build in the ctx sandbox (`ctx_batch_execute` / `ctx_execute`) so raw bytes stay out of
context — surface only the capped ranked node list. Write the result to `.planwright/graph.json`
with the native Write tool, conforming field-for-field to `docs/graph-memory-schema.md` (`version: 1`).

**Canonical builder.** Prefer the deterministic, test-covered `<scripts>/build-graph.py` (resolve
`<scripts>` per **Procedure → Bundled scripts**) over improvising the build: run
`python3 <scripts>/build-graph.py --prior .planwright/graph.json` in the sandbox and write
its stdout to `.planwright/graph.json` with the native Write tool (`--prior` preserves each surviving
node's `last_audited_sha` **and computes the incremental `dirty` block** — step 7 below — by diffing the
prior graph). Its output is schema-conforming by construction and verified by the suite (`tests/run.sh`,
"build-graph.py output conforms to graph-memory schema"). When the script ran, **read the dirty set from
the emitted `graph.json` `dirty` block** (`is_first_run`, `whole_graph`, `reason`, `changed`, `nodes`,
`clusters`) rather than recomputing it; Stages 3–7 gate on `dirty.nodes` / `dirty.clusters`. The numbered
steps below are the **specification** the script implements — follow them by hand only as a fallback when
the script cannot run (no `python3`, etc.).

**Seeded invent framing** — when this run is an `invent` run **and** a `seed <S>` was given (Inputs),
also append `--seed <S>`: the builder then emits `explore_seed`, `ranked_explore`, and `explore_framing`
(a vantage key from a fixed catalog). Consume **only `explore_framing`** — it focuses Stage 5's invent
survey (see the invent lens). Deliberately **ignore `ranked_explore`**: validation found surface
*ordering* inert (the invent survey is value-ranked, not order-ranked), so it stays routing-only and
unconsumed. All three fields are absent without `--seed`, so a default/unseeded build is byte-for-byte
unchanged and behaves exactly as before. These are routing/record only — never Evidence (Stage 10).

1. **Enumerate** tracked files via `git ls-files`. For each node record `sha256`, `loc`, and `lang`
   (by extension/shebang).
2. **Import edges** — extract with `rg` per language family (best-effort, recall over precision):
   bash `source X` / `. X`; python `import X` / `from X import`; js/ts `import … from "X"` /
   `require("X")`; c/c++ `#include "X"`; rust `mod X;` / `use a::b`; markdown relative `[..](X)`
   links (Go is recognized for defines/branch only — its absolute module-path imports need
   `go.mod` to resolve, so it yields no edges). Resolve targets to
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
   only that list to context. Also emit `ranked_code` — the same priority order restricted to nodes
   with `branch_count > 0` — so Stage 2b's function walk reads code, not the doc/data nodes that
   link-centrality can float to the top of `ranked`.
   - **Degenerate-import-graph fallback** — when the import graph barely discriminates (PageRank spread
     across nodes is below a small threshold, or there are too few import edges to rank — common in
     docs/scripts repos where files rarely import each other), PageRank is noise. In that case rank by
     **change-coupling** instead: a node's coupling degree/weight (sum of its `coupling_edges` weights)
     becomes the primary signal, still boosted by `is_articulation` and tiebroken by `git_churn`. Record
     in the surfaced summary which signal drove the ranking (`centrality` vs `coupling`).
7. **Incremental invalidation (only when a prior `.planwright/graph.json` exists)** — compute the
   **dirty set** so unchanged code can be skipped downstream. The canonical builder emits this as the
   `dirty` block when run with `--prior`; consume it directly. A node is *dirty* when its freshly
   computed `sha256` differs from the value recorded in the prior graph. The dirty set is those
   changed nodes **plus their 1-hop blast radius** along import + coupling edges. Map the dirty set to
   the clusters it touches and carry both forward — Stages 3–7 gate on it. Preserve each surviving
   node's prior `last_audited_sha` (Stage 11 restamps audited nodes).
   - **Whole-graph invalidation** — treat **every** node as dirty (re-audit everything) when any of:
     a lockfile or build-config file changed, the planwright `version` advanced, or HEAD has diverged
     from the prior graph's `graph_built_at_sha` beyond a sane threshold (e.g. the coupling window).
     The canonical builder already sets `dirty.whole_graph` for the build-config and HEAD-divergence
     triggers; only treat the **version-advanced** case as an extra hand check (OR it in) when planning
     planwright's own repo and its `version` changed since the prior graph.
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
mismatches. Each finding: path, size or gap, why it matters. For "missing focused tests", let the
graph's `covered_by_test` route attention: a non-test code node (`is_test` false, `branch_count > 0`)
with `covered_by_test` false is a **candidate** to investigate — not a finding. Confirm by reading
PROJECT TEST TARGETS and the code before proposing, since `covered_by_test` is a best-effort routing
hint (recall-over-precision), never proof; the written item must still name the specific absent test.

**2b. Correctness** — open and read the bodies of the top-N functions, where **N is the Depth table's
"Stage 2b functions to read"** for this run. Select those N by **centrality ∩ complexity**: walk the
Stage 1.5 `graph.json` **`ranked_code` list when present** (it is `ranked` already restricted to
nodes that carry code — `branch_count > 0` — so doc/data nodes that link-centrality floats to the top
of `ranked` do not displace the engine code; fall back to `ranked` when `ranked_code` is absent or
empty). It is PageRank-ordered, so high-blast-radius code first; take its
top files, **always including every `is_articulation` node regardless of depth** (a defect in a
cut vertex breaks many modules), breaking ties between *files* by their `loc` and `branch_count`. Then,
**within** each selected file, rank the functions to read by `branch_at` (branches attributed to each
symbol by its definition span) — most-branchy first — and use `defines_at` (symbol → 1-based line) to
jump straight to each body rather than re-scanning. This is the function-granular half of
**centrality ∩ complexity**: centrality picks the files, `branch_at` picks the functions inside them.
When the
graph used the **coupling fallback** (degenerate import graph, see Stage 1.5 step 6), `ranked` is
already coupling-ordered — walk it the same way; centrality and coupling feed the same `ranked` list.
If `graph.json` is absent or graph-aware routing was skipped this run, **fall back** to the original rule:
the top-N most complex functions by line count or branching. **During an `explore` cold-frontier sweep**
(see **Escalation ladder**), route Stage 2b by the graph's **`ranked_cold`** list instead of
`ranked_code` — same walk, but it leads with the audit/coverage frontier (never-audited, then uncovered,
then least-central) so the sweep reads exactly the code the hot-core pass skipped. **Under a Scope**
(`path`/`lib`, see **Inputs**), walk the same ranked list but **restricted to the Context node set** —
the function bodies read are the in-scope ones plus their 1-hop blast radius (articulation points inside
Context still always included), so root cause upstream of Focus stays readable. For each selected function, trace every non-trivial path: look for silent
failures (error return ignored, wrong default returned, exit 0 on bad state), unchecked preconditions,
and off-by-one or boundary errors. Findings must cite file:line, the specific path, and the defect.

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
PROJECT DIRECTION (mission/charter + README + roadmap) regardless of the dirty set, bounded by the
convergence guard (see **Maturity
ladder & the final point**). This is the mechanism that keeps a clean tree climbing instead of idling.

**Scope restriction** — when a **Scope** is active (`path`/`lib`, see **Inputs**), all lenses read over
the **Context** set but may only propose items whose surfaces fall in **Focus**: change-gated lenses
restrict to `dirty ∩ Focus`, and the maturity-gated lenses 5–6 survey **Focus-wide** (the scoped
component) rather than project-wide. Reading the wider Context keeps grounding and root cause intact;
Stage 10 enforces that what lands stays in Focus (with the upstream-repair exception).

3. **Architecture** — module boundaries, oversized units, public API surfaces, dependency
   direction, source/header/test clusters, language-specific header-only/template constraints. Use the
   graph's `import_cycles` (strongly-connected import groups) as a concrete circular-dependency signal —
   routing only; confirm by reading the imports before proposing a break (e.g. dependency inversion).
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
   project-wide whenever the change-gated rungs are dry, not only over the dirty set. Read it against
   **PROJECT DIRECTION** (mission/charter + README + roadmap, see Stage 1): ask *"what would move this
   project toward its stated direction, and make it genuinely better for its users and maintainers?"*
   and propose net-new value: runtime behavior, user workflows, automation, external integrations,
   data flow, recovery paths, public APIs (mode `develop`), and teaching docs (mode `docs`). A feature
   the README or roadmap names but the code does not yet have is a first-class opportunity/vision
   candidate (still grounded: it must attach to a real seam and carry a runnable verification). Two
   sub-tiers:
   - **opportunity** — concrete enhancements tied to a real surface and PROJECT DIRECTION; each must
     name a concrete user/maintainer payoff to clear the value bar.
   - **vision** — roadmap-level, design-first bets; state the design decision explicitly and require a
     preceding design item (Stage 7 rule b). A vision item must name a concrete, mission-aligned
     outcome, not a vague nicety — speculative niceties fail the value bar and are dropped.

   **Expand lens (active during an `explore` expand escalation — see Escalation ladder).** When the
   round runs under the expand posture, sharpen this survey to *a natural completion or generalization
   of what already exists*, auditing specifically for: (a) capabilities implemented internally but not
   exposed; (b) functionality the current design plainly implies but lacks; (c) API usability gaps or
   misuse risks an overload, parameter, or mode would close; (d) repeated logic a small justified helper
   would consolidate; (e) missing focused tests that block safe extension; and (f) areas that must
   remain unchanged (record them, with reasoning, so the loop respects them). Every expand candidate
   still attaches to a named existing surface, stays under the hard ceiling (no new subsystem, domain,
   or redesign), and carries a runnable verification.

   **Invent lens (active during an `invent` invent burst — see Escalation ladder).** Same survey as the
   expand lens, but the "must already be latent" restriction is lifted: a **genuinely new** capability,
   API, or mode may be proposed if it bolts to a real existing seam, serves PROJECT DIRECTION, and stays
   under the hard ceiling (no new subsystem, domain, or redesign). Net-new items take mode `develop`,
   and when they rest on an unresolved design decision they carry a preceding design item (Stage 7
   rule b). The grounding floor is unchanged — a net-new idea with no real seam to attach to is dropped.

   **`invent` must generate (explicit-`invent`-only rule).** Typing `invent` is explicit permission to
   create, so the invent tier **must propose at least one net-new item** rather than declare itself dry —
   it does **not** get to return nothing because the work would only *extend* a deliberately minimal
   project. Two gates still hold absolutely (they keep the plan executable, not merely tidy): the
   **grounding floor** (a real existing seam, exact Surfaces, and a runnable Verification) and the
   **structural hard ceiling** (no new subsystem, domain, or redesign — it must be one implementable
   change). What is **relaxed under explicit `invent`** is the *value bar* and *mission conservatism*:
   rank every net-new candidate that clears those two gates and emit the **highest-value** one even if it
   sits below the normal value bar or stretches a mission preference (e.g. a "small / minimal /
   dependency-light" mandate). When the emitted item is below the normal bar or stretches the mission,
   **say so in its Rationale** (e.g. "invent-tier: emitted under invent-must-generate; stretches MISSION
   'small', or below the usual value bar") so the plan stays honest about why it is there. Consequences,
   by design: the invent tier therefore (almost) never records an *invent-dry* deep final point — there is
   always a next groundable feature — so `cycle -1 invent` runs to its budget rather than self-terminating;
   the only genuine empty is when **no** candidate clears the grounding floor + structural ceiling (no seam
   left to extend at all), and that must be reported with its reason. This rule is **subject to plan
   capacity** (the 20-item pending cap / `propose_count == 0` still stops with "Plan is at capacity") and
   applies **only** to an explicit `invent`; `explore` and the default never pad (see Hard rules).

   **Mission amendment (rare, dwell-gated; explicit-`invent`-only).** As a project grows, the charter may
   genuinely fall behind it — so when invent is *repeatedly* forced to stretch the mission, it may make a
   **rare, small** edit to `MISSION.yaml`, never a casual one. Mechanism — a **dwell gate** so it cannot
   touch the mission on a whim:
   - Track `mission_pressure` in `.planwright/final.md` (default 0). After an invent burst whose only
     above-floor output was **mission-stretching** items (every in-mission net-new candidate was dry),
     **increment** it; after any burst that lands a genuinely in-mission net-new item, **reset to 0**.
   - Only when `mission_pressure` reaches **3** (three *consecutive* mission-bound bursts) does invent earn
     **one** mission edit. When it triggers, that cycle proposes a **single** item and nothing else: a
     mission-amendment item — `Mode: docs`, `Surfaces: MISSION.yaml`, Rationale citing the sustained
     pressure and the concrete features it unlocks, Development naming the one constraint relaxed or clause
     added (keep it **minimal** — one constraint/clause), Verification a content check
     (`grep -q "<new clause>" MISSION.yaml`). Then **reset `mission_pressure` to 0**.
   - The amendment executes and commits as its **own** change; the **next** cycle re-reads PROJECT
     DIRECTION (Stage 1) under the amended mission and only *then* proposes the unlocked features. This
     one-beat gap means invent never invents against a mission it loosened **in the same run** (no
     self-justifying loop). The edit is small, isolated, and revertible.
   - **Never weaken the structural hard ceiling via the mission** — an amendment may relax a *preference*
     (e.g. "small / dependency-light") but may not authorize a new subsystem, unrelated domain, or
     redesign; those stay barred regardless of mission text.
   This is **always-on under explicit `invent`** (the run announces it up front — see Cycle preconditions
   / the `/codinventor` banner — so whoever runs `invent` is on notice); `explore` and the default never
   edit the mission.

   **Seeded framing (active only when Stage 1.5 emitted `explore_framing` — an `invent` run with a
   `seed`).** Without a seed, the invent survey is **comprehensive** (survey every module against PROJECT
   DIRECTION) and deterministic — unchanged behavior. With a seed, *focus* the generative survey through
   the one recorded vantage below: survey for net-new capability **from that angle**, letting it dominate
   what this run proposes. This **scopes generation** (which ideas are surveyed), not mere re-ranking — a
   single seeded run is intentionally a *focused* survey, and comprehensiveness is recovered **across the
   seed sequence** (successive seeds pick different framings and explore different regions, so repeated
   `invent` runs stop re-deriving the same few ideas — the convergence this addresses is a cross-run
   problem). Map `explore_framing` → vantage question:
   - `power-user` — "what would an expert/power user want that the current design makes hard?"
   - `integration` — "what external integration or interoperability is missing?"
   - `onboarding` — "what would make first-run / onboarding trivial for a new user?"
   - `reliability` — "what failure mode or recovery path is unhandled?"
   - `automation` — "what manual workflow could be automated end-to-end?"

   The framing's leverage **scales with the repo's idea space**: on a large, multi-domain repo (where a
   single run cannot survey the whole net-new space anyway) it materially changes what is proposed; on a
   small repo it mostly shifts coverage across runs. It never lowers the bar or lifts the hard ceiling —
   every framing still demands a real seam, a concrete payoff, and a runnable verification, and a framing
   that surfaces nothing above the value bar declares the tier dry exactly as an unfocused survey would
   (a focused survey is not a license to invent filler).

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
better-verified item or drop it. The *structural* subset of this gate (fields present, valid mode,
real `Surfaces:`, absent `New Surfaces:`, no graph-memory in `Evidence`, a `file:line` anchor in a
`repair` item's `Evidence`, no `.planwright/` tool-owned path in `Surfaces:`, `CMakeLists.txt`,
non-empty `Verification:`) is mechanized by `scripts/lint-plan.py`, which Stage 11 runs on the written plan; the
checks below that need judgement (is the Evidence a *real* defect? does it cite a *true* signal?) stay
yours:

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
- **Surfaces-in-Focus (only when a Scope is active):** every item's `Surfaces`/`New Surfaces` must lie
  in the **Focus** set — an item proposing work outside the scoped component is dropped. **One escape
  hatch:** a `repair` item may name a **Context** (upstream-of-Focus) surface *iff* its Evidence proves
  the in-Focus symptom traces to that site (cite the in-Focus call path and the upstream defect). This
  keeps a scoped run from patching a symptom in Focus when the real cause is one hop upstream. (No-op
  when no scope is active — the whole repo is Focus.)
- Mode correct: `develop` = new runtime/security behavior, `improve` = behavior-preserving quality,
  `repair` = confirmed defect only.
- Development tells the engineer *where and how*; Acceptance describes observable + preserved behavior;
  Verification covers every declared surface using exact PROJECT TEST TARGETS.
- No item depends on an unresolved design decision unless the design item precedes it or the decision
  is stated explicitly in Development.
- **Value bar (maturity rungs):** an `opportunity` item must name a concrete user/maintainer payoff; a
  `vision` item must name a concrete, mission-aligned outcome. A proposal that amounts to a vague
  nicety ("could be cleaner", "might be nice") fails the bar — drop it. Better to declare the final
  point honestly than to pad the plan with sub-bar items. **(Exception: under an explicit `invent`, the
  invent tier must still emit its best grounded, structurally-valid net-new candidate even if below this
  bar — flagged in Rationale — rather than declare invent-dry; the grounding floor and structural hard
  ceiling are never relaxed. See Stage 5's invent lens and Hard rules.)**

### Stage 11 — Write the plan

If `dry-run` was passed, print the surviving items to the chat and STOP — write no file.
Otherwise append the surviving items (separated by a blank line) to `<target>/.planwright/plan.md`
below any existing pending items, preserving them. If the file was archived/fresh, create it with the
header:

```
# planwright Plan — <target-or-".">
<!-- Session: <UTC ISO-8601 timestamp> -->
```

**Mechanically lint the written plan.** Run `python3 <scripts>/lint-plan.py --root <target>` (resolve
`<scripts>` per **Procedure → Bundled scripts**) — the
canonical, test-covered linter for the *machine-checkable subset* of the OUTPUT FORMAT and the Stage 10
gate (every pending item has all eight fields, a valid `Mode`, `Surfaces:` that exist, `New Surfaces:`
that do not, no path in both, no `.planwright/` tool-owned path in either, no graph-memory citation in
`Evidence`, a `file:line` anchor in a `repair` item's `Evidence`, a `.txt` on any `CMakeLists`, and
a non-empty `Verification:`). It also enforces the ladder's **monotonic-drain** guard — no two pending
items share a title — and prints non-failing **advisories** when a pending title matches a
`completed.md`/`rejected.md` item, so you confirm it is a genuine regression or a resolved rejection
(not an accidental re-proposal). The linter never replaces Stage 10's judgement passes — it catches the
structural mistakes those passes are not meant to re-verify by hand. **When a Scope is active, append
`--scope .planwright/graph.json`** so the linter also mechanizes the Stage 10 **Surfaces-in-Focus** gate
(an existing Surface outside Focus fails; a `repair` Surface one hop upstream in Context is a non-failing
advisory you confirm; `New Surfaces` stay your judgement) — it is a no-op on a whole-repo graph. Fix every
violation it reports in `plan.md` and resolve each advisory, then re-run it until it exits clean before
reporting done. (On `dry-run`, run the linter against the would-be items the same way before printing
them; write no file.)

Then, unless `dry-run` was passed (no graph-memory state is persisted on a dry run),
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
   each rung (repair/coverage/opportunity/vision) marked dry, and a one-line reason per rung. Under
   `explore`/`invent`, also record `deepest_tier:` (`hot-core` | `cold-frontier` | `expand` | `invent`)
   — the furthest tier surveyed before drying; `deepest_tier: expand` (under `explore`) denotes the
   stronger **deep final point** (cold frontier + expand both dry). `deepest_tier: invent` is written
   **only** in the rare genuine empty where no net-new candidate clears the grounding floor + structural
   hard ceiling (no seam left to extend) — because `invent` **must generate** otherwise (see **Escalation
   ladder**), so an ordinary `invent` run writes **no** `final.md` and instead runs to its cycle budget.
   This is the recorded **final point**; it is routing/status only and is **never** valid Evidence.
   **Under a Scope**, also record `scope:` (`path:<X>` / `lib:<X>`) and `scope_focus_sha:` (a hash of
   the sorted Focus path list) so the Stage 1 short-circuit only fires for a matching scope; a whole-repo
   run records no `scope:` line (or `scope: (whole-repo)`). A scoped final point asserts dryness **only**
   for that component — it never suppresses a differently-scoped or whole-repo run.
   **Under a seeded `invent` run** (a `seed` was given, Inputs), also record `invent_seed: <S>` and
   `invent_framing: <key>` so the run is replayable. A `deepest_tier: invent` declared under a seed is
   **seed-scoped**: it asserts only that *this framing's* survey came up dry — a different seed/framing
   may still find groundable invention, so it never suppresses a differently-seeded or unseeded invent
   run. An unseeded invent run records neither field (its dryness is comprehensive).
   **Under `invent`, also persist `mission_pressure: <n>`** (default 0) — the count of consecutive
   mission-bound invent bursts that drives the dwell-gated mission amendment (Stage 5). Increment it when a
   burst's only above-floor output was mission-stretching; reset to 0 when a burst lands an in-mission
   net-new item or when a mission amendment is committed. It is status/routing only — never Evidence.

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
  **Exception — explicit `invent`:** under an explicit `invent` the invent tier **must** propose ≥1
  net-new item rather than declare itself dry (it may emit a below-value-bar or mission-stretching item,
  flagged in its Rationale), because typing `invent` is permission to create. The **grounding floor** and
  **structural hard ceiling** still hold absolutely, and plan capacity still stops it; the relaxation is
  the value bar / mission conservatism, and it applies to **no other mode** (see Stage 5's invent lens).
- **Editable surfaces.** An item's `Surfaces`/`New Surfaces` may name source, tests, docs, configs, and —
  under `invent`'s dwell-gated mission amendment (Stage 5) — `MISSION.yaml`. They may **never** name a
  protected path: `.git/`, `.planwright/` internals (planwright's own memory — items edit it via Stage 11,
  never as a surface), `LICENSE`, or any secret/credential file (`.env`, `*.pem`, key/credential stores).
  Editing those is harmful or corrupts planwright itself, regardless of mode or operator awareness.
- Output **only** the plan file. No code, no edit bundles.

# Execute (implement the plan)

Reached only via `/planwright execute`. This is the mutating path: it edits source, runs
verification, and commits. Everything below replaces the planning Procedure.

## Preconditions (check first, in order)

1. **Plan exists** — `.planwright/plan.md` has at least one pending `- [ ]` item. If none, report
   "No pending items to execute" and STOP.
2. **Plan is structurally valid** — run `python3 <scripts>/lint-plan.py --root <target>` (resolve
   `<scripts>` per **Procedure → Bundled scripts**; append `--scope .planwright/graph.json` when a Scope
   is active, to also gate Surfaces-in-Focus). If it reports
   violations, STOP and surface them: a missing `Verification:`, a non-existent `Surfaces:` path, or an
   invalid `Mode` makes an item unimplementable, so executing it would only churn the tree. Fix the
   plan (or re-plan) before executing. This is the same gate Stage 11 applies when the plan is written.
3. **Clean working tree** — run `git status --porcelain`. If it reports anything, STOP and report the
   dirty tree (do not entangle the user's uncommitted work with per-item commits). Exception: ignored
   paths such as `.planwright/` do not count.
4. **Announce the branch** — print the current branch (`git branch --show-current`); per-item commits
   land here. There is no safety branch by design.

## Modes and scope

- **Auto (default)** — implement every pending item in plan order without asking item-by-item.
- **`--interactive`** — for each item: show it, wait for approval, implement, show the diff, run
  verification, and confirm before committing. Skipped items stay pending.
- **`execute N`** — act on pending item number `N` only (1-based over pending items).
- **`execute` with a Scope** (`path <X>` / `lib <X>`) — act only on pending items whose `Surfaces` fall
  in the resolved Focus, leaving out-of-scope items pending. Useful to implement just one component's
  items from a whole-repo plan.

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

**Warnings-clean gate (toolchain-conditional).** Where the project's own build / lint / type-check
emits warnings, treat any **new** warning this run introduced as **must-fix** — the broad verify is not
clean until it is resolved. If one genuinely cannot be fixed cleanly, suppress it at the **narrowest**
scope and record a one-line justification (in the item's commit body or the run report). This is a
**no-op** for toolchains that emit no warnings — never fabricate a warnings step a project does not
have — and it is scoped to *new* warnings: do **not** block on a project's pre-existing warning
baseline that this run did not touch.

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
3. **Resolve `explore` / `invent`** — both are opt-in and **cycle-only**; `invent` is a superset of
   `explore` (if both are given, `invent` wins). Each is valid with **any** non-zero N (positive or
   unlimited `-1`). Under `explore` the escalation is a bounded, self-terminating ladder (cold-frontier
   sweep → expand) that always ends in a recorded final point. Under `invent` the **must-generate** rule
   means the tier keeps landing groundable net-new work, so the run does **not** self-terminate — it runs
   to its cycle budget `N` (and `cycle -1 invent` runs until you stop it or it hits plan capacity / a true
   no-seam empty); the invent burst is still hard-capped at 3 cycles per trigger (see **Escalation
   ladder**). The cycle count `N` doubles as the **escalation budget** — a final point reached before
   cycle N is spent climbing the ladder instead of
   stopping early. (Outside the cycle path — plain plan, `execute`, `version` — both are ignored.)
   **Resolve `seed <S>`** here too: valid **only with `invent`** (ignore it, with a one-line note, under
   `explore` or no flag). When present, Stage 1.5 passes `--seed <S>` and the invent tier surveys through
   the seeded framing (Stage 5); when absent, invent stays comprehensive and deterministic.
4. **Announce** — print the current branch (`git branch --show-current`), the cycle mode
   (`N cycles` or `unlimited`), the planning depth (`depth <D>`, default 6), and which escalation flag is
   on (`explore`, `invent`, or none) before starting any work; if a seed is active, also print
   `seed <S> (framing: <key>)`. **Under `invent`, also warn up front** that invent may make rare, small,
   committed edits to repo files **including `MISSION.yaml`** (dwell-gated — see Stage 5's mission
   amendment), so whoever runs `invent` is on notice that the charter itself can change.

## Per-cycle loop (repeat up to N times, or indefinitely when N < 0)

For each cycle i (starting at 1, bounded by N when N > 0, unbounded when N < 0):

1. **Print header** — `=== Cycle i/N ===` (or `=== Cycle i/∞ ===` for unlimited) so progress is
   visible in long runs.
2. **Plan** — run the full planning Procedure (Stages 0–11) at the cycle's depth (the `depth <D>`
   passed to `cycle`, else default **6**) with otherwise-default settings: depth-derived `propose`,
   no instruction, no `no-compact`, no `dry-run`. The same depth applies to every round. A **Scope**
   (`path <X>` / `lib <X>`) passed to `cycle` likewise applies to every round, and the ladder climbs
   **within Focus** — a scoped cycle matures just that component and stops at its scoped final point.
   Record the number of new items Stage 11 wrote.
3. **Check for work** — Stage 11 writing **0 new items** with **0 pending items** is **not** by itself
   a stop: it only means the change-gated rungs are dry. The planning round must have climbed the
   **maturity ladder** (surveyed the opportunity and vision rungs project-wide; see **Maturity ladder &
   the final point**) before idling.
   - **Without `explore`** (default): stop early **only when the planning round declared the final
     point** — i.e. it wrote `.planwright/final.md` because all four rungs were dry. Then print
     `Cycle i/N: final point reached — <one-line why>.` and STOP.
   - **With `explore` or `invent`**: when the round *would* declare the final point, **escalate through
     the ladder** instead of stopping (see **Escalation ladder**), spending the remaining cycle budget:
     1. **Cold-frontier sweep** (in-round) — re-run Stages 2–10 routed by the graph's `ranked_cold`
        list. If it writes ≥1 item, delete the stale `final.md` and proceed to Execute (ladder live).
     2. **Expand** — if the cold frontier is also dry and the budget still allows (this is not the last
        cycle), switch into the **expand** posture: survey lenses 5–6 project-wide for latent-capability
        completion (Stage 5's expand lens). If it writes ≥1 item, delete the stale `final.md`, proceed
        to Execute, and keep the expand posture for subsequent cycles (their generative survey stays in
        the expand posture until expand itself goes dry).
     3. **Invent** (`invent` only) — if the cold frontier **and** expand are both dry and the budget
        still allows, run a **bounded invent burst** (≤3 cycles, independent of `N`): survey lenses 5–6
        under the invent lens (net-new, seam-bound — Stage 5). Per Stage 5's **invent-must-generate**
        rule the burst **emits ≥1 item** whenever any candidate clears the grounding floor + structural
        hard ceiling (it may be below the value bar / mission-stretching, flagged) — so the invent tier
        effectively does not go *invent-dry* while a seam remains to extend. When a `seed` is active, that
        survey is *focused through the seeded framing* (Stage 5's seeded-framing rule) and the burst is
        seed-scoped; without a seed it is comprehensive. Delete the stale `final.md`, proceed to Execute,
        and continue (re-checking the fixpoint after the burst).
     4. **Deep final point** — for `explore`, when the cold frontier **and** expand are both dry, write
        `final.md` (`deepest_tier: expand`). Under **`invent`** a deep final point is reached **only** in
        the rare genuine empty — *no* net-new candidate clears even the grounding floor + structural hard
        ceiling (no seam left to extend); then write `final.md` (`deepest_tier: invent`, with the reason
        for the empty). Print `Cycle i/N: deep final point reached — <tiers> all dry.` and STOP (even if
        cycles remain). Otherwise the invent burst keeps producing groundable work and the cycle runs to
        its budget `N` (so `cycle -1 invent` does not self-terminate — that is the point of `invent`).

   If items are pending or were written, proceed to Execute as normal.
4. **Execute** — run the full per-item execute loop over every pending item (same as
   `/planwright execute` auto mode). Collect per-cycle stats: items completed, items rejected.
5. **Broad final verification** — run the project's full build + test suite (not just per-item
   focused tests), including the **warnings-clean gate** (Execute → broad final verification: where the
   toolchain emits warnings, any new warning this cycle introduced is must-fix). If it fails, STOP and
   report; per-item commits from this cycle stand but the batch is not clean — do not start the next
   cycle.
6. **Cycle summary** — print: cycle number, items proposed / completed / rejected this cycle, broad
   verify result (`PASS` or `FAIL`).

## After all cycles (or early stop)

Print a cumulative summary:
- Total cycles completed (out of N requested, or `∞` for unlimited mode)
- Total items implemented (with all commit short-SHAs)
- Total items rejected (titles + one-line reasons)
- Stop reason if stopped before N: `hard blocker`, `broad-verify failed`, `final point reached`
  (all four maturity rungs dry — see `.planwright/final.md`), or — under `explore` — `deep final point
  reached` (cold frontier + expand both dry). Under `invent`, `must-generate` means there is normally no
  deep final point — the run reaches N (or `plan at capacity`, or the rare `no groundable seam remains`)

## Stop conditions

Stop and do **not** start the next cycle on any of:

- A **hard blocker** during execute (item needs undeclared surfaces or an unresolved design decision).
- A **failing broad final verification** after execute.
- **Final point**: the planning round declared all four maturity rungs dry and wrote
  `.planwright/final.md` (step 3 above). An empty dirty set / empty backlog alone is **not** a stop —
  the maturity-gated rungs must have been surveyed and come up empty first. **Under `explore`/`invent`**,
  the hot-core final point is **not** a stop on its own — it escalates through the ladder (cold-frontier
  sweep → expand, and under `invent` → a hard-capped invent burst). Under `explore` the run stops at the
  **deep final point** (cold frontier + expand dry). Under `invent` the **must-generate** rule keeps the
  invent tier producing groundable net-new work, so the run does **not** stop at a fixpoint — it runs to
  N, stopping early only at plan capacity or the rare genuine empty (no net-new candidate clears the
  grounding floor + structural hard ceiling).

Individual item rejections are **not** a stop condition — the cycle continues and the next planning
round's audit will learn from the rejection reasons in `rejected.md`.

# Upgrade (update planwright itself)

Reached only via `/planwright upgrade`. Updates the installed planwright plugin to the latest version.
This path does **not** plan or edit your project; it only refreshes planwright.

## Procedure

1. **Locate the marketplace source.** Read `~/.claude/plugins/known_marketplaces.json` and find the
   `eserlxl` entry. Note its `source` (a `github` repo, or a local `directory`/`git` path) and the
   installed version from `~/.claude/plugins/installed_plugins.json` (`planwright@eserlxl`).
2. **Refresh the source when it is a local git clone.** If the source is a `directory`/`git` path that
   is a git repo, run `git -C <path> pull --ff-only` to fetch the latest. If that tree is dirty or the
   pull is not fast-forward, STOP and report — do not force it. For a `github` source, skip this step
   (the marketplace update fetches directly).
3. **Report versions.** Print installed version → latest available `version` from the source's
   `.claude-plugin/plugin.json`. If they already match, say "already up to date" and skip step 4.
4. **Hand off the two interactive steps.** The skill cannot run `/plugin` or `/reload-plugins` itself
   (they are user UI commands). Tell the user to run, in order:
   - `/plugin marketplace update eserlxl`
   - `/plugin install planwright@eserlxl` (only if the version did not advance after the update)
   - `/reload-plugins`
5. **Confirm.** After the user reloads, the new version is active; suggest `/planwright help` to verify.

Report: source type, old → new version, whether a local pull ran, and the handoff steps.

# Version (show current and latest)

Reached via `/planwright version` (or `--version`, `-V`). Read-only — it neither plans nor edits.

## Procedure

1. **Current** — the installed/running version: read `~/.claude/plugins/installed_plugins.json`
   (`planwright@eserlxl`). If that is unavailable (e.g. running from `~/.claude/skills/` without the
   plugin), fall back to this file's frontmatter `metadata.version`.
2. **Latest** — read the `version` from the marketplace source's `.claude-plugin/plugin.json` (resolve
   the source path from `~/.claude/plugins/known_marketplaces.json`). For a `github` source whose clone
   is not local, report latest as "unknown (run /planwright upgrade to fetch)".
3. **Report** one line: `planwright <current> (latest <latest>)`. If latest > current, add
   "→ upgrade available: run /planwright upgrade"; if equal, add "→ up to date".

STOP after reporting.
