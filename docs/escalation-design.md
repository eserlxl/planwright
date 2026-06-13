# planwright escalation — `explore` / `invent` (design)

Status: **IMPLEMENTED (core).** The full `explore`/`invent` escalation ladder (tiers ① cold-frontier,
② expand, ③ invent), the novelty dial, the budget-as-reach rule, the deep final point, and the
`/codinventor` companion command are wired into `SKILL.md` + `commands/` (with a test in `tests/run.sh`).
The **warnings-clean broad verify** described below is now also **SHIPPED** — it is the warnings-clean
gate in `SKILL.md`'s Execute and Cycle broad-final-verification steps. Still **PROPOSED** — design only:
the semantic-freeze taper, plus the optional standalone `expand` posture (Open question 1). This supersedes
the earlier `innovate-escalation-design.md`.

> **Addendum (2026-06-04) — invent semantics have since evolved (see `docs/invent-exploration-design.md`
> and the changelog).** The Tier ③ description below ("records the deep final point / then stops") is the
> *original* invent behavior and is **superseded for `invent`** by two later changes:
> - **`invent` must generate** (v1.30.0): typing `invent` is permission to create, so the tier **must
>   propose ≥1 net-new item** rather than declare itself dry — it relaxes the value bar / mission
>   conservatism (below-bar/stretch items flagged), but never the grounding floor or structural hard
>   ceiling. Consequence: an `invent` run normally does **not** reach a deep final point; it runs to its
>   budget `N` (so `cycle -1 invent` keeps inventing), stopping early only at plan capacity or the rare
>   genuine no-seam empty. The Tier ③ cap ("a few cycles") survives as a per-trigger burst rate limit.
> - **Dwell-gated MISSION amendment** (v1.31.0): after **3 consecutive** mission-bound bursts
>   (`mission_pressure` in `final.md`), invent may make one small, committed edit to `MISSION.md`
>   (applied as a `docs`-mode item, consumed only on the *next* cycle), so the charter grows with the
>   project. Seeded **framings** (v1.29.0, `seed <S>`) focus the burst so successive runs diverge.
> The `explore` tiers (① cold-frontier, ② expand) and the deep-final-point semantics below are
> **unchanged** — only `invent`'s stopping behavior moved.

planwright is **language-agnostic** — it plans any repo (COBOL to Rust to a docs tree). Nothing in
this design is C++-specific. Where this doc was seeded by a concrete C++ feature-expansion prompt, the
project-specific parts of that prompt (a C++23/26 reviewer role, snake_case/PascalCase naming rules,
`cmake`/`ctest`/ASAN/UBSAN invocations, fixed `-j8`, tool-specific doc paths) are **deliberately kept
out** — they belong in a per-project prompt, not the generic skill. planwright already reads each
repo's own conventions and toolchain from PROJECT DIRECTION + the build/test targets it discovers.

## The gap

planwright already turns the audit into features: the opportunity/vision rungs run project-wide against
PROJECT DIRECTION (mission/charter + README + roadmap) even when the dirty set is empty. And `explore`
already escalates **once**, spatially, at the final point (a cold-frontier sweep). What's missing is a
way to **keep escalating while the user's requested cycle budget remains** — and a way to *permit
net-new invention* deliberately, without ever drifting into work an automated tool shouldn't do
unattended.

## The model: fixed floor + fixed ceiling, one novelty dial

Two limits never move; a single dial slides between them.

- **Grounding floor (every tier, never relaxed)** — the Stage 10 gate: each item cites a real
  attachment **seam** (`Surfaces:`; net-new files in `New Surfaces:` but `Development:` still names a
  real seam) and carries a **runnable** `Verification:`. Nothing ungrounded ever ships.
- **Hard ceiling (every tier, never relaxed)** — **no new subsystems, no unrelated domains, no
  architecture redesign from scratch, no speculative "nice-to-haves," no performance work without a
  correctness justification.** Truly identity-changing work is simply out of scope for the automated
  loop, at *every* tier. (This is the antigravity prompt's `MUST NOT`, generalized.)
- **The dial = how *novel* a proposal may be**, controlled by which flag is on:

| Command | Novelty permitted | Escalates at the final point through… |
|---|---|---|
| *(none)* | maturity-ladder items only | nothing — stop at the recorded final point |
| **`explore`** | **latent only** — complete/generalize what is already implied or half-built | ① cold-frontier → ② **expand** |
| **`invent`** | **net-new** — create capability that wasn't there, *if* it bolts to a real seam and serves PROJECT DIRECTION (still under the hard ceiling) | ① cold-frontier → ② expand → ③ **invent** |

`explore` = "finish what's started." `invent` = "explore **and** you have my permission to create new
things." Typing `invent` *is* the permission — deliberate, never accidental — which is why no extra
interactive gate is needed: the hard ceiling already bars the only genuinely drift-prone work (new
subsystems/domains), so `invent` only relaxes the "must already be latent" rule, nothing more.

`expand` and `invent` name both an escalation **tier** and the dial position that authorizes reaching
it. `expand` may also be offered as a standalone whole-run posture (lead generative-first from cycle 1)
— see Open questions.

## The cycle count is an ambition budget

The decisive idea: **`N` in `cycle N` is the escalation budget, not just a loop cap.** When a planning
round would declare the final point *before* the budget is spent (final point at cycle `i`, with
`i < N`), the user has explicitly authorized `N − i` more cycles of effort — so instead of stopping,
the active flag spends that remaining budget climbing the risk-ordered ladder:

```
normal cycle:  repair → coverage → opportunity → vision
   │  final point declared at cycle i, budget remains (i < N)
   ▼  the active flag escalates, spending the remaining budget:
 ① cold-frontier sweep   spatial; in-round (free), same value bar         [explore + invent]
 ② expand                complete/generalize LATENT capability            [explore + invent]
 ③ invent                net-new, seam-bound capability (a few cycles)    [invent only]
   ▼  the active flag's tiers are all dry, OR budget exhausted
 STOP — deep final point (record the deepest tier reached)
```

- Each tier runs **until it is dry** before the next engages, so **grounded completion always precedes
  invention.** You cannot reach `invent` until `expand` has nothing left.
- The **cold-frontier sweep stays in-round** (cheap, same value bar) — it costs no budget cycle, so a
  `cycle 1 explore` still gets it exactly as today. `expand` and `invent` are postures that shape
  subsequent cycles, so they **consume budget cycles**.
- `invent`, the riskiest tier, carries its own small **cap ("a few cycles")** on top of the budget, so
  even an unlimited `cycle -1 invent` cannot run away inventing — it does a bounded burst, then stops.

Small `N` is conservative (stop at the first final point). Large `N` says "keep making this better,
escalate as far as the ladder allows."

## Tier ② `expand` — the latent-capability lens

When `expand` is active, lenses 5–6 re-survey project-wide with one sharpened question (generalized
from the antigravity prompt's rule of thumb): *"what feature is a **natural completion or
generalization** of what already exists here?"* Concretely, audit for:

- **capabilities under-exposed or incomplete** — already implemented internally but not surfaced;
- **functionality logically implied by the current design** but not yet present;
- **API usability gaps and misuse risks** — overloads/parameters/modes that remove a hard-coded limit;
- **repeated logic** that a small, justified helper abstraction would consolidate;
- **missing tests that block safe expansion** — pin the behavior before extending it;
- **areas that must remain unchanged** (recorded with reasoning, so the loop respects them).

Every candidate still clears the floor and the ceiling: it attaches to a named existing surface, it is
not a new subsystem/domain, and it carries a runnable verification. This tier never invents a concept
that isn't already latent in the code.

## Tier ③ `invent` — net-new, still bounded

`invent` lifts only the "must already be latent" restriction. A proposal may introduce a genuinely
new capability/API **iff** it (a) attaches to a real existing seam, (b) serves PROJECT DIRECTION, and
(c) respects the hard ceiling (not a new subsystem, not an unrelated domain, not a redesign). The
natural limiter is structural: you can only invent where there's a real seam to hang it on. Runs in a
bounded burst (the "few cycles" cap), then records the deep final point.

## Bounded-run discipline (from antigravity, generalized)

Two more portable rules make a *bounded* run end clean rather than mid-feature:

- **Semantic-freeze taper** — in a budgeted run, the **final budgeted cycle introduces no new
  behavior**: only bug fixes, test fixes, and warning cleanup. (Generalizes antigravity's "iteration 3
  = no new features.") This guarantees the run terminates in a stable, tested state.
- **Warnings-clean broad verify** — treat toolchain warnings the project's own build/lint/type-check
  emits as **must-fix** during the broad final verification; if one cannot be fixed cleanly, suppress
  at the narrowest scope and record the justification. Language-agnostic: it applies wherever the
  discovered toolchain emits warnings, and is a no-op where it doesn't.

## `final.md` schema additions

Extend the existing block so the fixpoint strength is explicit and machine-readable:

```
deepest_tier: maturity | cold-frontier | expand | invent   # furthest the run reached before drying
budget: { requested: N, used: i }
fixpoint: <one-line why every reachable tier was dry>
```

Report string, e.g.: `Cycle i/N: deep final point — expand exhausted, budget spent; no seam-bound
invention remains.` A later round re-opens the ladder on the existing triggers (tree changed, PROJECT
DIRECTION changed, higher depth) or a deeper escalation flag than the recorded point. Per the **Stage 1
escalation-reach rule**, a fresh `invent` invocation **never** short-circuits — a recorded
`deepest_tier: invent` is informational only, and re-invoking `invent` re-asserts the must-generate
mandate and re-surveys the net-new tier (so repeated `/codinventor` runs keep landing work instead of
freezing at the first invent-dry point); `explore` likewise re-surveys over a plain/`hot-core` point.

## `SKILL.md` changes required (when approved)

1. **Usage block + Options table** — add `explore` (extend its description to "cold-frontier → expand")
   and `invent` rows.
2. **Rename/rework the "Explore escalation" section → "Escalation ladder"** — document the floor,
   ceiling, novelty dial, the budget-as-reach rule, and the three tiers with their per-tier rules.
3. **Stage 5 (generative lens)** — note the active-flag tier (expand vs invent) and its bar; add the
   `expand` audit lenses above.
4. **Cycle → Per-cycle loop step 3** — replace the explore-only branch with the laddered escalation,
   consuming budget, in the documented tier order.
5. **Cycle → Stop conditions / After all cycles** — add the *deep final point* stop reason and the
   semantic-freeze taper.
6. **Execute → broad final verification** — add the warnings-clean gate (toolchain-conditional).
7. **Stage 11 step 3** — write the extended `final.md` fields.
8. No new scripts; the item format is unchanged, so `lint-plan.py` is unaffected. Add a `tests/run.sh`
   case asserting an escalation never lowers the Stage 10 structural gate (an ungrounded `expand`/
   `invent` item is still rejected) and that the hard ceiling rejects a "new subsystem" item.

## Companion command — `/codinventor` (mirrors `/codvisor`)

`codvisor` is the flagship `explore` shortcut (empty → `cycle 10 depth 10 explore`). `codinventor` is
its `invent` twin — same structure, same passthrough, only the default flag differs:

- **Empty** → cost banner, then planwright `cycle 10 depth 10 invent`.
- **`N`** → `cycle <N> depth 10 invent`; **`N D`** → `cycle <N> depth <D> invent`.
- **Anything else** → verbatim passthrough to planwright.

It must be created **only after** `invent` is implemented in `SKILL.md` — a command that forwards an
unrecognized flag would silently drop it. (`codinventor` reads as "code inventor"; the rejected
alternative `codexpert` doesn't tie to the `invent` flag.)

## Open questions (decide before building)

1. **`expand` as a standalone posture?** Besides being an escalation tier under `explore`, should
   `expand` also be its own flag that biases the *whole* run generative-first from cycle 1 (the
   antigravity "this is a feature-expansion run" posture)? Recommend: ship it as the escalation tier
   first; add the standalone posture only if wanted.
2. **`invent` cap size.** How many cycles is "a few"? Recommend a small fixed cap (e.g. 3) independent
   of `N`, so even `-1` invents only in bounded bursts.
3. **Validate before building.** This is still speculative until observed. Recommend dogfooding a real
   `cycle -1 explore` and confirming the vision/expand frontier actually converges while groundable
   work remains, *before* implementing `invent` — building on a hunch is the exact unverified-feature
   trap the mission warns against.

## Recommendation

The cheap input change (README/roadmap → PROJECT DIRECTION) is already shipped. For the rest: implement
the **`explore` → `expand`** escalation first (grounded, low-risk, directly useful), dogfood it, and add
**`invent` + `/codinventor`** once `expand` proves the ladder converges as designed.
