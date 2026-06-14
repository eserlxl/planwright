---
name: planwright
description: >
  Grounded codebase planning. Scans + audits a repository and produces a verification-ready
  checkbox plan in .planwright/plan.md using the exact 8-field item format
  (Mode/Rationale/Evidence/Surfaces/New Surfaces/Development/Acceptance/Verification).
  Runs a multi-stage dossier to draft to finalize to quality-gate pipeline with the active
  AI coding agent doing every stage directly. The `execute` subcommand then implements the
  plan items, verifies each, and records completed/rejected items.
  Trigger when the user asks to "plan", "run plan mode", "generate a plan", "refresh the plan",
  "propose plan items", "execute the plan", "implement the plan", "cycle", "dogfood", or mentions
  .planwright/plan.md. Run `planwright help` (or the host command equivalent) for usage and options.
  Supports: execute, interactive execute, targeted execute, cycle N, explore, invent, seed S, update, version, upgrade, depth D, propose N, max N, no-compact, dry-run, help.
license: GPL-3.0-or-later
metadata:
  author: Eser KUBALI
  version: "1.57.0"
---

# planwright

This skill has three clearly partitioned paths:

- **Plan** (`planwright`, default) — scans and audits the codebase, then runs a multi-stage
  *dossier → draft → finalize → quality-gate* pipeline to emit concrete plan items in
  `.planwright/plan.md`. **Read-only: it writes only the plan file, never application source.**
- **Execute** (`planwright execute`) — implements the pending plan items, verifies each, commits
  the ones that pass, and records the rest. **This is the only path that edits source.**
- **Cycle** (`planwright cycle N`) — runs N sequential plan→execute rounds unattended: proposes
  items, implements them all, verifies, then repeats. It climbs a **maturity ladder** (repair →
  coverage → opportunity → vision) so a clean tree keeps producing valuable work, and stops early only
  when it reaches a **recorded final point** (all four rungs dry — see **Maturity ladder & the final
  point**).

The active AI coding agent runs every stage, so planwright needs no external binary and spends no
separate model calls.

When planning, do not edit application source. The output of the plan path is **only** the plan file.

## Contents

This file is the full specification *and* the runtime instructions. Read top-to-bottom on first use;
thereafter jump to the path you are running.

- **Dispatch & options** — [Host command adapter](#host-command-adapter) ·
  [Invocation & help](#invocation--help) · [Usage](#usage) · [Options](#options) · [Depth](#depth)
- **Planning model** — [Maturity ladder & the final point](#maturity-ladder--the-final-point) ·
  [Escalation ladder](#escalation-ladder) · [Inputs](#inputs)
- **Plan path (read-only)** — [Procedure](#procedure): Stage 0 → 11
  ([0 Lifecycle](#stage-0--lifecycle-housekeeping-mechanical) ·
  [1 Scan](#stage-1--scan-mechanical) · [1.5 Graph](#stage-15--build-code-graph-mechanical) ·
  [2 Audit](#stage-2--audit-mechanical--reasoning) ·
  [3–7 Dossier](#stages-37--cumulative-planning-dossier-reasoning-passes) ·
  [8 Draft](#stage-8--draft) · [9 Finalize](#stage-9--finalize) ·
  [10 Quality gate](#stage-10--strict-quality-gate-final) · [11 Write](#stage-11--write-the-plan)) ·
  [Output format](#output-format-exact) · [Hard rules](#hard-rules-do-not-violate)
- **Execute path (edits source)** — [Execute](#execute-implement-the-plan):
  [Preconditions](#preconditions-check-first-in-order) · [Per-item loop](#per-item-loop) ·
  [Broad final verification](#after-all-targeted-items--broad-final-verification) ·
  [Rejection schema](#rejection-schema-must-be-machine-readable-for-the-feedback-loop)
- **Cycle path (automated loops)** — [Cycle](#cycle-plan--execute-repeated):
  [Per-cycle loop](#per-cycle-loop-repeat-up-to-n-times-or-indefinitely-when-n--0) ·
  [Stop conditions](#stop-conditions)
- **Maintenance** (loaded on demand from `references/`) — [Doctor](references/doctor.md) ·
  [Status](references/status.md) · [Advise](references/advise.md) ·
  [Dashboard](references/dashboard.md) ·
  [Reset](references/reset.md) · [Upgrade](references/upgrade.md) · [Version](references/version.md)

## Host command adapter

planwright has one canonical argument grammar: `planwright <args>`. Hosts only differ in how they
load the skill and what command token they expose. Before dispatching below, strip the host trigger and
classify the remaining tokens as the canonical argument string.

| Host | User-facing trigger | Canonical arguments passed to this skill |
|------|---------------------|------------------------------------------|
| Claude Code plugin | `/planwright <args>` | `<args>` |
| Cursor skill | `@planwright <args>` or `planwright <args>` | `<args>` |
| Codex skill/plugin | `planwright <args>` in chat, or the Codex skill invocation carrying `<args>` | `<args>` |
| Antigravity / Gemini | `planwright <args>` after the `GEMINI.md`/project instruction loads this file | `<args>` |

The helper names `codvisor` and `codinventor` are also host adapters: they resolve to
`cycle 10 depth 10 explore` and `cycle 10 depth 10 invent` respectively unless the user supplied
arguments. On hosts without slash commands, use the bare names (`codvisor`, `codinventor`) or dispatcher
skills/instructions that load this `SKILL.md` with the resolved canonical argument string. In the Usage
block, `/planwright`, `/codvisor`, and `/codinventor` are the Claude Code spellings; substitute the
host trigger above while keeping the arguments unchanged.

`codcycle` is a different kind of adapter — an **orchestration** command, not a single-invocation alias.
Per *outer cycle* it drives this skill through two back-to-back phases — `cycle 3 depth 10 explore`,
then `cycle 3 depth 10 invent seed <i>` (a harden → grow rhythm) — and closes the whole run with a
single final `cycle 3 depth 10 explore` phase, defaulting to 10 outer cycles (a negative count runs
forever). Both phases use a fixed cycle count; what rotates across outer cycles is the invent **framing**
— the per-cycle `seed <i>` sweeps the fixed vantage catalog (power-user → integration → onboarding →
reliability → automation) so each cycle focuses a different region, and the meta-final-point is declared
only when a full framing rotation comes up dry. Each phase is an ordinary cycle run of this `SKILL.md`;
`codcycle` only sequences them.

`codshard` is the other orchestration command. It partitions the repo into component shards
(top-level directories holding tracked files by default, or an explicit `shards <a,b,c>` list of
paths/lib names), runs one ordinary **scoped** round of this skill per shard — `cycle <M> depth <D>
path <shard>`, defaulting to `cycle 3 depth 10`, sequentially, in staleness order (most never-audited
graph nodes first; lexicographic without a graph) — then closes with a single **unscoped**
`cycle <M> depth <D>` round for cross-shard seams, root-level files, and global concerns; only that
closing round may declare the global final point (per-shard scoped final points never aggregate into
one). An opt-in `explore` flag escalates **only that closing round** (`cycle <M> depth <D> explore`)
— per-shard rounds never escalate, and `invent`/`seed` do not compose with sharding at all. The
point is depth, not speed: a scoped round concentrates the whole depth budget on one
component, and each shard's findings drain through execute before the next shard starts. Its opt-in
`parallel` flag prefetches read-only recon leads via subagents on hosts that have a subagent
primitive (Claude Code); the leads are routing-only re-verification seeds — never Evidence — the
rounds themselves stay sequential, and every other host runs identically without recon. Each round
is an ordinary run of this `SKILL.md`; `codshard` only sequences them.

`codmaster` is the front door — for anyone who does not want to choose among the commands above. It
runs the read-only `advise` engine (`status.py --recommend`, the same truth table the dashboard
coach renders) and then **runs the required commands consecutively** — dispatch, re-sense,
dispatch — until the repo reaches a recorded final point, at maximum depth (10), re-deciding from
fresh state between steps instead of precomputing a chain (growth is taken at most once per lap;
a no-progress stall or the 12-step-per-lap safety cap also stop the loop): pending items →
`execute`; structural debt, a stale point, or a carried backlog → `codvisor` (`codshard explore` on
a mechanically large repo); a clean tree without a current whole-repo final point → the same harden
sweep; a converged tree → an **enforced** at-most-once `codinventor` burst whenever `safe` is off —
at every converged terminal (any tier, including `deepest_tier: invent`) codmaster grows
**regardless of the engine's `invent_class`** (its invent-dry routing is advisory here), the banner
disclosing invent's rare dwell-gated `MISSION.md` edits. Only `safe` withholds the burst and instead
relays the engine's invent-dry routing → `reset` plus a fresh harden sweep, but **only when really
necessary** — the point must be unseeded and the cold frontier shown drained; a seed-scoped point
re-surveys and an undrained frontier hardens instead. Its `advise` word prints the recommendation
(plus, at an invent-dry terminal, the notice that a non-`safe` drive would grow there instead) and
stops; its `safe` word runs the same loop but never invents — it withholds the growth burst (printing
the `codinventor` line to paste) while still dispatching every non-invent move, including the engine's
invent-dry `reset`/`codvisor`; its `loop` word makes the drive infinite — each lap grows, deep-hardens
the grown code, then resets (cold-start, keeps `rejected.md`) into the next with growth re-armed, until
interrupted, a hard stop, or a fully-dry lap (the final convergence point, decided at the lap boundary
after the post-growth harden, never mid-lap) (`safe loop` composes). A `path <X>` / `lib <X>` scope aims
the whole drive at one component — it threads into the engine (`status.py --recommend --scope`) so
pending, debt, and convergence are Focus-restricted, and the two whole-repo moves (`codshard`, `reset`)
never auto-route under it, so the harden stays a scoped `codvisor`. The decision table lives in the
tested Python engine, never in command prose; `codmaster` only relays and dispatches.

## Invocation & help

Before doing anything else, inspect the argument the skill was invoked with:

- If it is `help`, `--help`, `-h`, `?`, or empty-with-an-explicit-help-request, **print a header line
  `planwright v<version>` (read `<version>` from this file's frontmatter `metadata.version`), then the
  Usage reference below verbatim, and STOP.** Do not scan, audit, plan, or write any file.
- If the first token is `version`, `--version`, or `-V`, read `skills/planwright/references/version.md`
  and follow that procedure instead of the planning Procedure.
- If the first token is `execute`, dispatch to the **Execute** section near the end of this file and
  follow that procedure instead of the planning Procedure. Remaining tokens are execute options
  (`--interactive`, an item index `N`).
- If the first token is `cycle`, dispatch to the **Cycle** section near the end of this file and
  follow that procedure instead of the planning Procedure. The next token is the repeat count `N`; a
  trailing `depth <D>` (and other plan options) applies to every planning round in the cycle.
- If the first token is `upgrade` or `update`, read `skills/planwright/references/upgrade.md`
  and follow that procedure instead of the planning Procedure.
- If the first token is `doctor`, read `skills/planwright/references/doctor.md` (resolve `<scripts>`
  per **Procedure → Bundled scripts**) and follow that preflight procedure instead of the planning Procedure.
- If the first token is `status`, read `skills/planwright/references/status.md` (resolve `<scripts>`
  per **Procedure → Bundled scripts**) and follow that read-only summary procedure instead of the planning Procedure.
- If the first token is `advise`, read `skills/planwright/references/advise.md` (resolve `<scripts>`
  per **Procedure → Bundled scripts**) and follow that read-only recommendation procedure instead of the planning Procedure.
- If the first token is `dashboard`, read `skills/planwright/references/dashboard.md` (resolve `<scripts>`
  per **Procedure → Bundled scripts**) and follow that read-only server procedure instead of the planning Procedure.
- If the first token is `reset` (or the aliases `fresh` / `clean`), read `skills/planwright/references/reset.md`
  (resolve `<scripts>` per **Procedure → Bundled scripts**) and follow that cold-start wipe procedure instead of the planning Procedure.
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
/planwright doctor               Preflight: check git/rg/python3 + bundled-script resolution
/planwright status               Read-only: summarize plan/final-point/graph state (--json)
/planwright advise               Read-only: recommend the next command (the coach as a CLI; never dispatches)
/planwright dashboard            Read-only: serve a live local web view of the planning state
/planwright reset                Cold start: clear .planwright/ but keep rejected.md (fresh/clean aliases)
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
| `lib <X>` | whole repo | **scope**: like `path`, but planwright first resolves a logical component name (cluster / build target / package / dir) to its paths in Stage 1, then scopes to that Focus set — the builder's `--scope` itself takes paths/globs only (see **Scope**) |
| `explore` | off | **cycle only**: at the final point, escalate instead of stopping — cold-frontier sweep, then the **expand** tier (complete latent capability), spending the remaining cycle budget (see **Escalation ladder**) |
| `invent` | off | **cycle only**: superset of `explore` — additionally permits net-new, seam-bound capability (the **invent** tier, a bounded ≤3-cycle burst) after the expand tier is dry (see **Escalation ladder**) |
| `seed <S>` | none (deterministic) | **`invent` only**: focus the invent generative survey through one seeded **framing** (a recorded vantage from a fixed catalog). *Scopes* which net-new ideas a single run surveys — comprehensiveness is recovered across the seed sequence (cross-run), so successive seeds explore different regions instead of re-deriving the same ideas. No effect without `invent`; an unseeded `invent` stays comprehensive and deterministic. Integer. Recorded in `final.md` as `invent_seed`/`invent_framing` (see **Escalation ladder**, Stage 5) |
| `help` | — | print Usage and stop |

Precedence: **inline option > built-in default.** There is no settings file; options are per-run only.

**Flag aliases.** The bare keywords above are the canonical form (the skill/command layer parses
natural-language `$ARGUMENTS`, not a CLI). But tolerate the `--`-prefixed equivalents a user may type
out of shell-CLI habit, normalising them before parsing: `--path <X>` ≡ `path <X>`, `--lib <X>` ≡
`lib <X>`, and `--scope <X>` ≡ `path <X>` (the underlying `build-graph.py --scope` takes paths/globs,
so the `--scope` alias maps to the path primitive). Both `--opt <X>` and `--opt=<X>` spellings are
accepted. This is input leniency only — emit the canonical bare form in any echo/report.

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
that, it writes `.planwright/final.md` — one block recording the HEAD sha (as a `sha:` line — the
canonical key the parser and lint-final read; a `HEAD:` line is tolerated as an alias), the rungs
surveyed, and why each is dry — and reports "final point reached". This is a *justified* terminal state, distinct from an
empty-dirty-set idle. A later run re-opens the ladder only if the project changed (non-empty dirty
set), the mission/charter changed, or the user raises ambition — an explicit instruction, higher
depth, or a **deeper escalation flag than the recorded point** (re-invoking `explore` over a plain
point, or `invent` over anything, always re-surveys; see Stage 1's **escalation-reach rule**). Any
planning round that writes ≥1 item deletes a stale `final.md`.

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
ladder is dry, re-run Stages 2–10 **once per planning round** with routing overridden to the graph's
**`ranked_cold`** list
(never-audited first, then stalest-audited — most commits since the stamp, via `audit_age_commits` —
then uncovered, then least-central — see `docs/graph-memory-schema.md`): Stage 2b reads `ranked_cold`
bodies, Stages 5–6 survey the cold clusters project-wide, articulation points always included. This is
part of the planning round, so
it costs no extra cycle. If it writes ≥1 item the ladder is live again; continue normally. **Dryness is
judged against the graph's `frontier` counts, never the capped 20-entry slice:** while
`frontier.never_audited > 0` the frontier is not dry — the next round re-enters this sweep instead of
declaring dryness (Stage 11 stamps what each sweep actually read, the next round's Stage 1.5 rebuild
re-derives the counts, and the count drains across rounds — not strictly per round: a node whose only
finding was capacity-cut deliberately keeps its prior stamp, and a capacity stop is never a dry
verdict). A sweep that writes 0 items once `never_audited` is 0 is dry;
the residual `frontier.stale` backlog is then *recorded*, not denied (see **Deep final point**) — it
re-ages continuously on an active repo, so it quantifies the claim rather than blocking it. **Under a
Scope** the `frontier` counts stay whole-repo (the builder never restricts them): judge a scoped
sweep's dryness on the never-audited code nodes **within Context** — the only set it may read and
stamp — and record the whole-repo residuals without chasing them.

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
  `confirmed deep — cold-frontier and expand tiers both dry`, with the graph's residual `frontier`
  counts appended to the note (e.g. `frontier: 0 never-audited, 15 stale`) so the convergence record
  quantifies what the sweep did **not** read instead of over-claiming;
- under `invent`, **only** in the rare genuine empty — no net-new candidate clears even the grounding
  floor + structural hard ceiling (no seam left to extend), **and** that empty is *earned by breadth*
  (Framing auto-rotation exhausted every vantage) **and** *earned by rigor* (the per-seam gate justified
  every seam) — see Stage 5 → `deepest_tier: invent`,
  `confirmed deep — no groundable net-new seam remains`. Because `invent` **must generate** otherwise
  (above), an `invent` run normally does **not** reach this fixpoint; it runs to its cycle budget `N`
  (so `cycle -1 invent` keeps inventing), stopping early only at plan capacity.
This multi-tier fixpoint is a far more honest "stable" than a single hot-core survey.

**Termination.** Under **`explore`** the ladder is safe for any non-zero N (including `-1`): each tier is
finite and drains monotonically — swept cold nodes are stamped when actually read (`last_audited_sha =
HEAD`, Stage 11) and fall to the back of the staleness queue (the never-audited bin drains as nodes are
read — a capacity-cut node keeps its stamp only until its carried finding is promoted, dropped, or
rejected via the digest's per-run drain, so it cannot recirculate forever;
re-aging merely reorders the stamped queue and never blocks the item-driven dry verdict); expand
candidates are implemented (advancing state) or dropped/rejected (recorded,
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
`lint-plan.py`) ship **inside the planwright distribution**, not in the repo you are planning. Resolve
them from the **"Base directory for this skill"** path the host prints or exposes when this skill loads:
that base ends in `skills/planwright`, and the scripts live two directories up under `scripts/` — i.e.
`<skill-base>/../../scripts/`. Compute that **absolute** path once at the start of the run and write it
as `<scripts>` wherever a script is invoked below (so `<scripts>/build-graph.py`,
`<scripts>/lint-plan.py`). **Never invoke a bundled script as a bare `scripts/…`** — the current working
directory is the *target* repo being planned (the user's project), which has no planwright `scripts/`
directory, so a bare path fails for every user except when planning planwright's own repo. If the
absolute script cannot be located or executed, fall back to the documented by-hand procedure for that
stage (Stage 1.5 for the graph; do the Stage 10 structural checks by hand for the linter) — never block.

**Run-activity beacon (mechanical).** At the start of the run — before Stage 0, and even when
`no-compact` skips that stage — stamp the beacon the dashboard's reactor reads:
`python3 <scripts>/state.py activity start plan --if-absent --root <target>` (resolve `<scripts>` per
**Procedure → Bundled scripts**), appending `--detail "<the run's argument string>"` when one was
given. `--if-absent` keeps the beacon of an orchestrator that dispatched this run (codmaster,
codshard, and codcycle stamp their own names; a stale leftover counts as absent). The beacon is
best-effort telemetry — if the script cannot run, skip it and proceed; never block on it.

### Stage 0 — Lifecycle housekeeping (mechanical)

If `no-compact` was passed, skip this entire stage (still read pending items in step 4).
Create `<target>/.planwright/` if it does not exist, then operate on it.

**Canonical script.** Prefer `<scripts>/lifecycle.py housekeep --root <target>/.planwright` (resolve
`<scripts>` per **Procedure → Bundled scripts**) — it performs steps 1–3 deterministically
(test-covered by `tests/run.sh`) and prints the report. Then do step 4 (read the pending items)
yourself. The numbered steps below are the **specification** it implements; follow them by hand only
as a fallback when the script cannot run.

1. If `plan.md` exists, move every completed item (`- [x] ...` and its indented continuation lines)
   into `completed.md` (append). Then enforce the **FIFO cap of 100**: if `completed.md` holds more
   than 100 items, drop the oldest (top of file) until 100 remain.
2. Drain any item carrying a `Status:Rejected` / `Status: Rejected` continuation line into
   `rejected.md` (append, preserving its `Rejection:` reason line), removing it from `plan.md`. Then
   enforce the **FIFO cap of 100** on `rejected.md` the same way.
3. If, after that, **no pending (`- [ ]`) items remain**, **delete `plan.md`** to start fresh — an
   empty plan is deleted, never archived (backing up an empty plan is only clutter). When pending
   items remain, leave `plan.md` untouched so this run merges its new items into them (Stage 11).
4. Read the remaining **pending** (`- [ ]`) items — these are the existing plan you must not duplicate.

Report counts: compacted, rejected-drained, plan kept/deleted.

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
  anyway; pass `--scope` so it also emits the `focus` and `context` node lists). **Division of labour:**
  `build-graph.py --scope` resolves **paths and globs only** (see `resolve_scope`); the **logical-name
  resolution for `lib <X>` is performed by you, here in Stage 1**, *before* the builder runs — `lib` is an
  agent-resolved convenience, not a builder feature. Resolve
  the logical name to a path set first — in order: an exact graph **cluster label**, then a **build
  target** (CMake `add_library`, a Cargo crate / workspace member, an npm workspace, a Python package
  `<X>/__init__.py`, a Go package dir), then a **directory named `<X>`** — and pass the resolved path(s)
  to `--scope` (so the builder always receives concrete paths, never the logical name). **Focus** (the
  emitted `focus`) is where items may be proposed; **Context** (the emitted
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
- **CARRIED CANDIDATES** — read the `## Carried dossier candidates` section of `.planwright/digest.md`
  if present (findings a prior run verified but cut at the Stage 8 capacity gate, or deferred as
  unverifiable — see Stage 11 step 2). Each entry is a **mandatory re-verification seed** for this
  run's Stage 2: re-read the cited anchor, then either promote the finding into the dossier (it
  competes at Stage 8 again), drop it with a one-line reason, or carry it again if still blocked;
  delete any entry whose anchor no longer verifies. The cap (10) plus this per-run drain keeps the
  block self-cleaning; like the rest of the digest it is routing only, never Evidence.
- **FINAL POINT** — read `.planwright/final.md` if present. Once Stage 1.5 has computed the dirty set,
  if `final.md`'s recorded sha equals the current HEAD **and** the dirty set is empty **and** no new
  instruction or higher depth was given this run **and** the run's scope matches the recorded one (the
  `scope:`/`scope_focus_sha:` fields equal this run's — a *whole-repo* run only short-circuits on a
  *whole-repo* final point, and a `path <X>` run only on the matching scoped one) **and** this run's
  **escalation reach** is not deeper than the recorded point, the project is
  unchanged since the ladder was last exhausted *for that scope*: report `already at final point
  (<sha>)` and treat all four maturity rungs as dry (the run writes 0 items, and Stage 11 leaves the
  existing `final.md` in place). Otherwise treat `final.md` as stale and proceed normally — Stage 11
  step 3 deletes it once ≥1 item is written. (A scoped final point never suppresses a differently-scoped
  or whole-repo run.)
  - **Escalation-reach rule (so a more ambitious re-invocation is never frozen).** Reach is ordered
    *default < `explore` < `invent`*. The short-circuit fires only when the recorded `deepest_tier` is
    **at least as deep as this run can reach**:
    - a **default**/plain run honors any recorded final point (it cannot reach deeper);
    - an **`explore`** run honors only a `deepest_tier: expand` (or `invent`) point — a plain or
      `deepest_tier: hot-core` point is **stale** to it, because `explore` still reaches the
      cold-frontier and expand tiers that point never surveyed, so it proceeds and re-surveys;
    - an explicit **`invent`** run **never** short-circuits. The invent tier **must generate** (see
      **Escalation ladder**), so a recorded `deepest_tier: invent` is **informational only** — it
      records *why one prior burst came up empty*, but a fresh `invent` invocation re-asserts the
      must-generate mandate and **re-surveys** the net-new tier. This is what lets repeated
      `codinventor` (or `cycle … invent`) runs keep landing net-new work instead of freezing at the
      first recorded invent-dry point. (Re-surveying a *genuine* empty simply re-writes the same
      `deepest_tier: invent` and the cycle's own deep-final-point stop ends that run — see **Cycle**
      step 3 — so the bound still holds; what changes is only that the marker no longer blocks the
      *next* invocation.)

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

The builder also exposes read-only **inspection/interop** flags that are *not* part of the plan build:
`--dot` emits the graph as GraphViz DOT (solid = imports, dashed = change-coupling, bold boxes =
articulation points; honors `--scope` for a one-component subgraph), `--select EXPR` prints the paths of
nodes matching one signal predicate (e.g. `is_articulation`, `no-covered_by_test`, `lang=NAME`), and
`--debug` writes a routing digest to stderr. These are for a human/power user inspecting the graph (see
`docs/usage.md`); they never feed Evidence.

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
   `require("X")` (with `tsconfig`/`jsconfig` `compilerOptions.paths` aliases resolved); c/c++
   `#include "X"` (quoted) and `#include <project/foo.h>` (angle includes resolve against the
   repo's -I include roots — a unique file ending in that sub-path; extensionless and unmatched
   system headers like `<vector>`/`<sys/types.h>` drop); rust `mod X;` / `use a::b`; go `import "<module>/pkg"`
   (intra-module imports resolve via each file's nearest enclosing `go.mod`, root or nested
   sub-module; stdlib/external and cross-module imports drop); markdown relative `[..](X)` links.
   Resolve targets to
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
symbol by its definition span) — most-branchy first, but **promote any function with `swallow_at` > 0**
(a mechanically detected error-swallowing site: empty handler, ignored error return, silenced stderr)
ahead of its swallow-free peers — that is exactly the silent-failure candidate this sub-pass hunts, and
branchiness alone ranks it last. Swallow sites are candidates to read, never findings. Use `defines_at`
(symbol → 1-based line) to
jump straight to each body rather than re-scanning. This is the function-granular half of
**centrality ∩ complexity**: centrality picks the files, `branch_at` picks the functions inside them.
When the
graph used the **coupling fallback** (degenerate import graph, see Stage 1.5 step 6), `ranked` is
already coupling-ordered — walk it the same way; centrality and coupling feed the same `ranked` list.
If `graph.json` is absent or graph-aware routing was skipped this run, **fall back** to the original rule:
the top-N most complex functions by line count or branching. **During an `explore` cold-frontier sweep**
(see **Escalation ladder**), route Stage 2b by the graph's **`ranked_cold`** list instead of
`ranked_code` — same walk, but it leads with the audit/coverage frontier (never-audited, then
stalest-audited by `audit_age_commits`, then uncovered, then least-central) so the sweep reads exactly
the code the hot-core pass skipped or has not re-read for the longest stretch of commits. **Under a Scope**
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

   **Invent lens** (active during an `invent` burst — see Escalation ladder). Like the expand lens, but the
   "must already be latent" restriction is lifted: a **genuinely new** capability, API, or mode may be
   proposed if it bolts to a real existing seam, serves PROJECT DIRECTION, and stays under the hard ceiling
   (no new subsystem, domain, or redesign). Net-new items take mode `develop` (a preceding design item when
   they rest on an unresolved decision — Stage 7 rule b). The grounding floor is unchanged.
   *Full rationale for everything below: `docs/invent-exploration-design.md` → "Invent tier — full
   normative mechanics".*

   **`invent` must generate (explicit-`invent`-only).** Typing `invent` is permission to create, so the
   invent tier **must propose at least one net-new item** rather than declare itself dry. Two gates never
   relax: the **grounding floor** (real seam, exact Surfaces, runnable Verification) and the **structural
   hard ceiling** (no new subsystem/domain/redesign — one implementable change). What relaxes under explicit
   `invent` is the *value bar* and *mission conservatism*: rank every candidate clearing both gates and emit
   the highest-value one even if it sits **below the value bar** or **stretches the mission** — flag that in
   its Rationale. So an ordinary `invent` run never records an invent-dry final point (`cycle -1 invent`
   runs to budget); the only genuine empty is when no candidate clears floor + ceiling, and it must be
   **earned by breadth** (auto-rotation, below) **and earned by rigor** (per-seam gate, below). Subject to
   plan capacity ("Plan is at capacity"); `explore`/default never pad (see Hard rules).

   **Earned empty — per-seam justification gate (earned by rigor).** A `deepest_tier: invent` may be written
   **only** after enumerating each candidate seam and recording, per seam, why no extension clears the two
   gates — **shown, not asserted**. Valid reasons only: **(ceiling)** every extension is a new
   subsystem/domain/redesign; **(floor)** no extension carries a runnable verification or attaches to a real
   surface; **(trivial)** the only extension is trivial *with concrete justification* (e.g. a one-line
   alias). Invalid — each forces `must-generate` to emit that seam's best candidate, not an empty: "below
   the value bar", "stretches the mission", and bare/**unjustified "trivial"** (a new overload, mode, or
   newly-exposed capability is **not** trivial). Record `invent_seams_examined` (Stage 11).

   **Mission amendment (rare, dwell-gated, explicit-`invent`-only).** When invent is repeatedly forced to
   stretch the mission it may make one **rare, small** edit to `MISSION.md`. Track `mission_pressure` in
   `final.md` (default 0): increment after a burst whose only above-floor output was mission-stretching;
   reset to 0 when a burst lands an in-mission net-new item. Only when it **reaches 3** (three consecutive
   mission-bound bursts) does that cycle propose a **single** mission-amendment item and nothing else
   (`Mode: docs`, `Surfaces: MISSION.md`, Development naming the one constraint relaxed, Verification a
   `grep -q "<new clause>" MISSION.md` check), then reset to 0. It commits as its own change; the **next
   cycle** re-reads PROJECT DIRECTION under the amended mission and only then proposes the unlocked features
   (no same-run self-justification). **Never weaken the structural hard ceiling via the mission** — only a
   preference may relax. Always-on under explicit `invent`, announced up front so whoever runs it is **on
   notice**; `explore`/default never edit the mission, and the protected-path denylist (`.git/`,
   `.planwright/`, `LICENSE`, secrets) is never editable regardless.

   **Seeded framing + auto-rotation.** Without a seed the invent survey is comprehensive and deterministic;
   with a `seed`, Stage 1.5 emits `explore_framing` and the survey **focuses** through that one vantage
   (scopes generation, not re-ranking — comprehensiveness recovered across the seed sequence). Map
   `explore_framing` → vantage question: `power-user` ("what would an expert/power user want that the design
   makes hard?"), `integration` ("what external integration/interoperability is missing?"), `onboarding`
   ("what makes first-run trivial?"), `reliability` ("what failure/recovery path is unhandled?"),
   `automation` ("what manual workflow could be automated end-to-end?"). **Auto-rotation (empty-only, earned
   by breadth):** a survey that comes up empty does not conclude dry on one vantage — advance to the **next
   framing in catalog order** (`power-user → integration → onboarding → reliability → automation`, wrapping,
   skipping tried) and re-survey until a framing yields a candidate or **all framings are exhausted**.
   **Bounded** (≤6 surveys), deterministic (catalog order), triggered only **on an empty survey** (a
   non-empty pass never rotates). Record `invent_framings_tried` (Stage 11). Creativity widens *what* is
   proposed; it never lowers the grounding bar — every proposal still cites a real surface and a runnable
   Verification and passes Stage 10.
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
`Evidence`, a `file:line` anchor in a `repair` item's `Evidence` — whose cited file must also exist
(a ghost anchor fails a `repair` item; a ghost anchor in any other mode, or a line number past the
end of the cited file in any mode, is a non-failing advisory), a `.txt` on any `CMakeLists`, and
a non-empty `Verification:`). It also enforces the ladder's **monotonic-drain** guard — no two pending
items share a title — and prints non-failing **advisories** when a pending title matches a
`completed.md`/`rejected.md` item, so you confirm it is a genuine regression or a resolved rejection
(not an accidental re-proposal). The linter never replaces Stage 10's judgement passes — it catches the
structural mistakes those passes are not meant to re-verify by hand. **When a Scope is active, append
`--scope .planwright/graph.json`** so the linter also mechanizes the Stage 10 **Surfaces-in-Focus** gate
(an existing Surface outside Focus fails; a `repair` Surface one hop upstream in Context is a non-failing
advisory you confirm; `New Surfaces` stay your judgement) — it is a no-op on a whole-repo graph. Fix every
violation it reports in `plan.md` and resolve each advisory, then re-run it until it exits clean before
reporting done. For the two purely mechanical, filesystem-verifiable violations you may pass **`--fix`**
(it respells a `CMakeLists` Surface as `CMakeLists.txt` and moves an already-existing `New Surface` into
`Surfaces`, in place, then lints the result); every other violation still needs your judgement. (On
`dry-run`, run the linter against the would-be items the same way before printing them; write no file —
and do not pass `--fix`, which writes.) The opt-in `--strict` flag promotes the non-failing advisories
(re-proposed completed/rejected titles; upstream-of-Focus surfaces) to failures, so an unattended CI
gate can enforce the monotonic-drain guard without a human to confirm each note.

Then, unless `dry-run` was passed (no graph-memory state is persisted on a dry run),
**persist the incremental-audit baseline** so the next run's Stage 1.5 dirty-set comparison has
something to diff against:

1. **Stamp `last_audited_sha`** — in `.planwright/graph.json`, set `last_audited_sha = graph_built_at_sha`
   only for nodes this run actually **examined**: every node whose function bodies Stage 2b read
   (articulation auto-includes and cold-frontier sweep reads included), and every node a Stage 2
   sub-pass or dossier lens emitted a finding or an explicit dismissal for — **except** a node whose
   only finding was cut at the Stage 8 capacity gate: leave its prior stamp untouched, so the node
   re-enters the frontier and its finding re-surfaces next run (the claim itself is also carried in
   the digest — step 2). The carve-out overrides the read-stamp trigger: a node Stage 2b read but
   whose only finding was capacity-cut stays unstamped. Leave every other node's prior `last_audited_sha` untouched. Write with the
   native Write tool. The stamp drives the cold/stale frontier ordering (`ranked_cold`,
   `audit_age_commits`, the `frontier` counts) — incremental skipping itself is keyed on the prior
   graph's existence and sha256 diffing (`compute_dirty`), never on stamps — so stamping a node the
   run never read speeds nothing up; it only launders that node off the audit frontier.
2. **Refresh `digest.md`** — write `.planwright/digest.md` with one short block per cluster (id, label,
   member count, a one-line routing summary), each block prefixed `UNVERIFIED — routing only`. This is
   the carried-forward dossier Stages 3–7 resume from; it is **never** valid Evidence (Stage 10 bars
   citing it). Refresh only audited clusters; leave untouched clusters' prior blocks in place.
   After the cluster blocks, write a **`## Carried dossier candidates`** section — one line per finding
   that survived this run's review but was **cut by `propose`/pending capacity** at Stage 8, or
   **deferred as unverifiable in this environment**, in the format
   `[<rung> sev<k>, CUT|DEFERRED — <reason>] <file:line> — <one-line claim>; fix: <one-line>`.
   Hard cap **10** entries, highest value first; overflow is dropped (it was the lowest-value cut by
   construction). The section sits under the same `UNVERIFIED — routing only` banner and is never
   valid Evidence; the next run drains it (see Stage 1 → CARRIED CANDIDATES). Omit the section when
   nothing was cut or deferred.
3. **Maintain `final.md`** — if this round wrote **≥1 item**, delete any stale `.planwright/final.md`
   (the ladder is live again). If this round wrote **0 items because all four maturity rungs were dry**
   (not merely an empty dirty set — the maturity-gated rungs were surveyed project-wide and produced
   nothing above their value bar), write `.planwright/final.md` with one block: the HEAD sha (a `sha:`
   line — the canonical key; a `HEAD:` line is also accepted), the date,
   each rung (repair/coverage/opportunity/vision) marked dry, and a one-line reason per rung.
   **Each field is a bare `key: value` line that *starts* with the key — never a markdown bullet
   (`- sha:`):** both `status.py::_parse_final` and `lint-final.py` match only lines beginning
   `key:`, so a leading `- ` makes every field parse empty, and an unreadable `sha:` can never
   equal HEAD — which silently pins `converged` false forever (the point reads stale/invalid, so a
   `/codmaster` drive can never recognize it to grow). One field per line; last occurrence wins.
   For example:
   ```
   sha: 869d212
   date: 2026-06-14
   deepest_tier: expand
   repair: dry — no provably-wrong path remains after the cold-frontier sweep
   coverage: dry — every confirmed gap has a focused test
   opportunity: dry — the documented latent completions are implemented
   vision: dry — no roadmap-level initiative remains within the explore ceiling
   ```
   Under `explore`/`invent`, also record `deepest_tier:` (`hot-core` | `cold-frontier` | `expand` | `invent`)
   — the furthest tier surveyed before drying; `deepest_tier: expand` (under `explore`) denotes the
   stronger **deep final point** (cold frontier + expand both dry). `deepest_tier: invent` is written
   **only** in the rare genuine empty where no net-new candidate clears the grounding floor + structural
   hard ceiling (no seam left to extend) — and **only** once that empty is *earned by breadth* (Framing
   auto-rotation exhausted all vantages) **and** *earned by rigor* (the per-seam gate justified every
   seam) — see Stage 5. Because `invent` **must generate** otherwise (see **Escalation
   ladder**), an ordinary `invent` run writes **no** `final.md` and instead runs to its cycle budget.
   This is the recorded **final point**; it is routing/status only and is **never** valid Evidence.
   **Under a Scope**, also record `scope:` (`path:<X>` / `lib:<X>`) and `scope_focus_sha:` (the sha256
   hex digest of the newline-joined, lexicographically sorted Focus path list — canonical, so any host
   recomputes an identical value) so the Stage 1 short-circuit only fires for a matching scope; a whole-repo
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
   **When a `deepest_tier: invent` is recorded, also persist the two earned-empty audits** (Stage 5):
   `invent_framings_tried:` (the ordered vantage list the rotation exhausted, e.g.
   `[comprehensive, power-user, integration, onboarding, reliability, automation]`) and
   `invent_seams_examined:` (one `<seam> — <ceiling|floor|trivial:reason>` line per candidate seam, each
   a *valid* floor/ceiling/justified-trivial reason). Both are status/record only — **never** Evidence —
   and exist so a future run (or reviewer) can see the empty was earned, not asserted.

First remove the run-activity beacon this flow may own:
`python3 <scripts>/state.py activity stop plan --root <target>` (a beacon owned by a different
command — the orchestrator that dispatched this run — is left untouched for its owner; best-effort,
never block). Then print a short summary: counts proposed/written, pending total, nodes restamped,
clusters digested, rungs surveyed (lowest non-empty / final-point), and any capacity stop.

**Zero-item diagnostic.** When a run writes **0 items**, a bare "Plan is at capacity" / "final point
reached" is opaque — the user cannot tell a justified stop from a missed survey. So whenever
`written == 0`, append a one-block diagnosis naming, in order: (a) **why** — `capacity` (pending already
at `max`), `already-at-final-point` (Stage 1 short-circuit, cite the sha), or `all-rungs-dry` (each rung
surveyed, nothing above its value bar); (b) the **rungs surveyed** and, for each, whether it was
change-gated-dry (empty dirty set) or maturity-gated-dry (surveyed project-wide and empty); and (c) the
**closest miss** — the single highest-value candidate that was considered and dropped, with the one
gate/bar it failed (e.g. "raised-X proposal dropped: vision value-bar — outcome not mission-concrete").
This turns a silent 0 into an auditable decision, and is a no-op on any run that writes ≥1 item.

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
  under `invent`'s dwell-gated mission amendment (Stage 5) — `MISSION.md`. They may **never** name a
  protected path: `.git/`, `.planwright/` internals (planwright's own memory — items edit it via Stage 11,
  never as a surface), `LICENSE`, or any secret/credential file (`.env`, `*.pem`, key/credential stores).
  Editing those is harmful or corrupts planwright itself, regardless of mode or operator awareness.
- Output **only** the plan file. No code, no edit bundles.

# Execute (implement the plan)

Reached only via `planwright execute` (or the host equivalent such as `/planwright execute`). This is
the mutating path: it edits source, runs verification, and commits. Everything below replaces the
planning Procedure.

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
4. **Git identity configured** — run `git config user.name` and `git config user.email`. If either is
   empty or unset, STOP **before any mutation** and report that per-item commits would otherwise fail
   (the first `git commit` exits 128, crashing the run mid-execution), pointing the user at `git config
   --global user.name "<name>"` and `git config --global user.email "<email>"`. doctor.py only WARNs on
   this (planning never commits), so the mutating Execute path must enforce identity itself rather than
   discover it at the first per-item commit.
5. **Announce the branch** — print the current branch (`git branch --show-current`); per-item commits
   land here. There is no safety branch by design. Then stamp the run-activity beacon:
   `python3 <scripts>/state.py activity start execute --if-absent --root <target>` (`--if-absent`
   keeps a dispatching orchestrator's beacon; best-effort, never block).

## Modes and scope

- **Auto (default)** — implement every pending item in plan order without asking item-by-item.
- **`--interactive`** — for each item: show it, wait for approval, implement, show the diff, run
  verification, and confirm before committing. Skipped items stay pending.
- **`execute N`** — act on pending item number `N` only (1-based over pending items).
- **`execute` with a Scope** (`path <X>` / `lib <X>`) — act only on pending items whose `Surfaces` fall
  in the resolved Focus, leaving out-of-scope items pending. Useful to implement just one component's
  items from a whole-repo plan.

In both modes, the host agent's normal permission prompts for file edits, shell commands, and commits
still apply — auto only suppresses planwright's *own* item-by-item questions, never the host permission
system.

## Per-item loop

For each targeted pending item, in plan order:

1. **Value gate (challenge before applying).** Before writing any code, re-judge the item against four
   keep/kill checks — this is a second, *apply-time* filter independent of the planning value bar
   (Stage 10), so a marginal item that slipped through planning is caught here instead of padding the
   tree:
   - **(a) named failure** — the item must state the concrete bug/regression it prevents or the
     capability it adds. A test that merely asserts a string/section still exists in a doc or
     instruction file is **not** a named failure.
   - **(b) removal test** — if the item did not exist, something must break that *nothing else already
     catches*. If nothing would break, kill it.
   - **(c) real consumer** — a user or maintainer who actually hits it. "Someone might script it" /
     "might be nice" is not a consumer.
   - **(d) not self-justifying** — an item whose only effect is to test code written **this same run**
     counts only if it pins externally-observable behaviour, never internals.

   If the item fails **any** check, do **not** implement it: leave `- [ ]` unflipped, append a
   `Status:Rejected` with `Rejection: value-gate: <which check failed>`, move it to `rejected.md` (FIFO
   cap 100), and continue. The machine-readable `value-gate:` reason feeds the next plan's PREVIOUSLY
   REJECTED set (Stage 1), so the whole class is not re-proposed. A value-gate rejection is **not** a
   hard blocker — keep going. (Prefer three real commits to seven padded ones.)
2. **Implement** the `Development:` line. Edit only the declared `Surfaces:` (and create the declared
   `New Surfaces:`). If the work would require touching files outside those surfaces, treat the item
   as **blocked** (see below) rather than expanding scope silently.
3. **Verify** — run the item's `Verification:` command exactly.
   - If the item has no `Verification:` line, or the command cannot be run (missing target, unknown
     tool), do **not** mark it done — reject it with reason `unverifiable: <detail>`.
4. **On PASS** — flip `- [ ]` to `- [x]` in `plan.md`, then commit on the current branch with a message
   that describes the change itself — typically the `<item title>` as the subject (use the Haiku commit
   convention if configured). Do **not** prefix the subject with `planwright:` or otherwise name the
   tool; the commit should read as a normal change to the repo. Then stamp provenance: append a
   `Commit: <short-sha>` continuation line (the landing commit's `git rev-parse --short HEAD`) to the
   item, so its completed record traces back to the exact change without git-log archaeology
   (`Commit` is a recognised lifecycle field in `plan_parse.py`'s KNOWN_FIELDS, like
   `Status`/`Rejection`). Move the stamped item to `completed.md` and enforce the FIFO cap of 100.
   **Canonical script:** prefer `python3 <scripts>/lifecycle.py land <N> --commit $(git rev-parse
   --short HEAD) --root <target>/.planwright` (N = the item's 1-based pending number) — it flips,
   stamps, drains, and FIFO-caps in one deterministic, test-covered step; the prose above is the
   by-hand fallback when the script cannot run.
5. **On FAIL** — make up to **2 repair attempts** (re-read the error, adjust, re-verify). If it still
   fails, **reject**: revert this item's edits (`git restore` / `git checkout --` the touched paths so
   no partial change is committed), append a `Status:Rejected` and `Rejection: <one-line reason>` to
   the item, move it to `rejected.md` (FIFO cap 100), and continue. **Canonical script:** prefer
   `python3 <scripts>/lifecycle.py reject <N> --reason "<one-line reason>" --root <target>/.planwright`
   — it appends the canonical Status/Rejection lines (the exact spelling the drain and the next plan's
   PREVIOUSLY REJECTED reader key on) and drains the block in one deterministic, test-covered step;
   it applies equally to a step-1 value-gate rejection, and the prose remains the by-hand fallback.
6. **Blocked** — if the item depends on an unresolved design decision, or needs surfaces it does not
   declare, leave it pending, record why, and treat it as a **hard blocker**: in auto mode STOP here.

**Completion accounting (mandatory invariant).** Every fix you implement **and commit** in this run
MUST be recorded as a completed item in `.planwright/completed.md` — there is no such thing as a
committed fix with no completed record. `completed.md` is the only record the dashboard's
Plan/Timeline/Console history reads, and `.planwright/` is gitignored, so an unrecorded commit
silently vanishes from the planning history (git keeps the commit; nothing keeps the plan record).
Two paths, one invariant:

- **From a plan item** — the On-PASS step above (`<scripts>/lifecycle.py land <N>`) lands the pending
  `plan.md` item into `completed.md`. This is the normal path, already covered by step 4.
- **A direct commit (no pending plan item)** — when work was audited and committed inline without a
  `plan.md` item to land (e.g. a `cycle` / `codshard` / `codvisor` fix applied directly), record it
  **before the run ends** with `python3 <scripts>/lifecycle.py reconcile --commit <sha> --mode <mode>
  --root <target>/.planwright` — it resolves the commit's short sha + subject, is idempotent by short
  sha (re-running is a no-op), git-verifies the ref so it can never record a fake commit, and appends
  the canonical `- [x]` / `Mode:` / `Commit:` block.

A run that commits a fix but leaves `completed.md` without its record is a **contract violation — treat
it as a hard error**: reconcile the missing commits before reporting the run complete.

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

First remove the run-activity beacon this flow may own:
`python3 <scripts>/state.py activity stop execute --root <target>` (an orchestrator's beacon is left
untouched; best-effort, never block). Then print: items completed (with commit short-SHAs), items
rejected (with reasons), items left pending or blocked, and the broad final-verify result.

# Cycle (plan → execute, repeated)

Reached only via `planwright cycle N` (or the host equivalent such as `/planwright cycle N`). Runs N
sequential plan→execute rounds on the current branch
without interruption. Each round proposes new items, implements them all, verifies, and feeds the
results into the next round's audit, **climbing the maturity ladder** (repair → coverage → opportunity
→ vision) as lower rungs run dry. Useful for unattended dogfooding or bulk progress on a feature. It
stops only at a hard blocker, a failed broad verify, or a **recorded final point** (all rungs dry).

## Preconditions

1. **N is valid** — N must be a non-zero integer. Positive values (1–100) run exactly N cycles.
   **Negative values run unlimited cycles** — the loop continues until a stop condition fires (no
   more work, hard blocker, or failed broad verify). Zero is invalid.
   If missing or non-integer, print `Usage: planwright cycle <N>  (N != 0; negative = unlimited)`
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
   the seeded framing (Stage 5); when absent, invent stays comprehensive and deterministic (and, on an
   empty survey, auto-rotates the framings before it may conclude dry — Stage 5).
4. **Announce** — print the current branch (`git branch --show-current`), the cycle mode
   (`N cycles` or `unlimited`), the planning depth (`depth <D>`, default 6), and which escalation flag is
   on (`explore`, `invent`, or none) before starting any work; if a seed is active, also print
   `seed <S> (framing: <key>)`. **Under `invent`, also warn up front** that invent may make rare, small,
   committed edits to repo files **including `MISSION.md`** (dwell-gated — see Stage 5's mission
   amendment), so whoever runs `invent` is on notice that the charter itself can change. Then stamp
   the run-activity beacon: `python3 <scripts>/state.py activity start cycle --if-absent --root <target>`
   (`--if-absent` keeps a dispatching orchestrator's beacon; best-effort, never block). Each cycle
   header (per-cycle loop step 1) may refresh its detail the same way —
   `activity start cycle --if-absent --detail "cycle i/N"` — which writes through only when this
   flow owns the beacon.

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
   a stop: it only means the change-gated rungs are dry. The round must have surveyed the opportunity and
   vision rungs project-wide first (see **Maturity ladder & the final point**) before idling.
   - **Without `explore`/`invent`** (default): stop early **only when the round declared the final point**
     — it wrote `.planwright/final.md` because all four rungs were dry. Print
     `Cycle i/N: final point reached — <one-line why>.` and STOP.
   - **With `explore` or `invent`**: when the round *would* declare the final point, **escalate through the
     ladder** instead of stopping — **full tier mechanics in the Escalation ladder section** — spending the
     remaining cycle budget: cold-frontier sweep (in-round) → **expand** (latent completion, persists across
     cycles) → under `invent` a **bounded invent burst** (≤3 cycles; `must-generate` so it emits ≥1
     groundable net-new item while a seam remains; a seeded survey focuses through the framing and
     auto-rotates on an empty pass). Each tier that writes ≥1 item deletes the stale `final.md` and proceeds
     to Execute. Stop at the **deep final point**: under `explore` when cold-frontier + expand are both dry
     (`deepest_tier: expand`); under `invent` only in the rare earned empty (no seam clears floor + ceiling,
     earned by breadth + rigor — `deepest_tier: invent`, recording `invent_framings_tried` +
     `invent_seams_examined`). Print `Cycle i/N: deep final point reached — <tiers> all dry.` and STOP;
     otherwise `invent` runs to budget `N` (so `cycle -1 invent` does not self-terminate).

   If items are pending or were written, proceed to Execute as normal.
4. **Execute** — run the full per-item execute loop over every pending item (same as
   `planwright execute` auto mode). Collect per-cycle stats: items completed, items rejected.
5. **Broad final verification** — run the project's full build + test suite (not just per-item
   focused tests), including the **warnings-clean gate** (Execute → broad final verification: where the
   toolchain emits warnings, any new warning this cycle introduced is must-fix). If it fails, STOP and
   report; per-item commits from this cycle stand but the batch is not clean — do not start the next
   cycle.
6. **Cycle summary** — print: cycle number, items proposed / completed / rejected this cycle, broad
   verify result (`PASS` or `FAIL`).

## After all cycles (or early stop)

First remove the run-activity beacon this flow may own:
`python3 <scripts>/state.py activity stop cycle --root <target>` (an orchestrator's beacon is left
untouched; best-effort, never block). Then print a cumulative summary:
- Total cycles completed (out of N requested, or `∞` for unlimited mode)
- Total items implemented (with all commit short-SHAs)
- Total items rejected (titles + one-line reasons)
- Stop reason if stopped before N: `hard blocker`, `broad-verify failed`, `final point reached`
  (all four maturity rungs dry — see `.planwright/final.md`), or — under `explore` — `deep final point
  reached` (cold frontier + expand both dry). Under `invent`, `must-generate` means there is normally no
  deep final point — the run reaches N (or `plan at capacity`, or the rare `no groundable seam remains`)

**Hardening suggestion (after an `invent` run only).** When the completed run was an `invent` run,
end the cumulative summary with **one** line suggesting the user run **`/codvisor`** or the host's
`codvisor` equivalent (the flagship explore sweep, `cycle 10 depth 10 explore`) to harden this run's
net-new code. The invent tier
relaxes the value bar and mission conservatism to land fresh, seam-bound capability — and the
**final** invent burst lands in the last cycle, so it never gets a *subsequent* planning round's deep
repair/coverage audit; `codvisor` re-enters the maturity ladder at the bottom and adds the
cold-frontier sweep + expand tier, hardening every invented surface before the next growth burst.
This is a **suggestion only** — never auto-dispatch the explore run; the user decides when (which
preserves their beat to inspect or revert flagged invent-tier items first). It is a no-op for
`explore` and default cycle runs (no invent items were produced).

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

