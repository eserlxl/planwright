# planwright invent resilience — earned empties, not lazy ones (design)

Status: **IMPLEMENTED (SKILL.md Stage 5 + Stage 11; Tests 10h/10i).** Two in-mission features make the
invent tier's "nothing to invent" outcome *rare and earned* rather than a wall: **(#1) framing
auto-rotation on an empty survey** and **(#2) a per-seam justification gate before `deepest_tier: invent`
may be written**. Both are reasoning-layer + `final.md`-schema changes only — no `build-graph.py` change
was required (they reuse the existing `EXPLORE_FRAMINGS` catalog and the SKILL.md key→vantage map from
lever 2; see [invent-exploration-design.md](invent-exploration-design.md)). The sections below are the
spec they were built to; contract tests 10h (#1) and 10i (#2) guard them against drift.

## Motivation

Two signals converged:

1. **A real incident (rls-core, 2026-06-04).** An `invent` run recorded `deepest_tier: invent`
   (genuine empty) while *naming a groundable candidate in the same breath* — confidence-level
   (`alpha`) overloads on `predictInterval`/`parameterConfidenceIntervals`, backed by a dependency-free
   probit. It misjudged a non-trivial numerical approximation as a "trivial wrapper." That is a
   **reasoning lapse against the existing `must-generate` rule**, not a missing rule. v1.31.2 made the
   lapse *recoverable* (a `deepest_tier: invent` marker is now informational only and never freezes the
   next invocation — the **escalation-reach rule**), but did nothing to make the lapse *less likely*.
2. **An explicit product stance from the author:** invent should essentially never come back with
   "there is nothing to invent." Idea-supply augmentation (a second LLM prompt, a web search) was
   considered and rejected — it conflicts with the mission's *no network dependence* and *grounded over
   generative* pillars and with run determinism, and it does not address the real cause of an empty
   (below).

### The reframe these features rest on

**An invent empty is a *no-seam* state, not a *no-idea* state.** The grounding floor binds every item
to a **real existing attachment point** (a `Surfaces:`/`Development:` seam) plus a runnable
`Verification:`. So invent's bottleneck is almost never the supply of ideas — it is the presence of a
seam to carry one. More idea sources cannot manufacture a seam, so they cannot fix a genuine empty; and
in the common case (rls-core) a seam *did* exist and the run was simply lazy. The two features below
therefore attack the two ways an empty can be wrongly declared: **insufficient breadth** of survey
(#1) and **insufficient rigor** in the conclusion (#2).

---

## Feature #1 — Framing auto-rotation on an empty survey

**Today.** A fresh generative vantage requires an explicit `seed <S>` (lever 2). An unseeded `invent`
survey runs one "comprehensive" pass. On a large, multi-domain repo that comprehensive pass is a
*bounded sample* of an idea space far larger than `propose_count`, so it can miss whole regions — and an
empty *sample* is then mistaken for a genuine empty. (On a small repo where comprehensive generation is
genuinely exhaustive, this does not arise; see lever-2 validation, Open question 5.)

**Proposed.** Before any invent survey may declare itself dry, it must have surveyed under **every
framing in the catalog** and found all empty. Concretely, in Stage 5's invent lens:

1. Run the survey under the current vantage (the seed's framing if `seed` was given, else the
   comprehensive pass).
2. If it yields ≥1 groundable candidate → emit per `must-generate`; **rotation does not trigger** (it is
   an empty-only mechanism). Done.
3. If it is empty → **advance to the next framing** in the fixed `EXPLORE_FRAMINGS` order
   (`power-user → integration → onboarding → reliability → automation`, wrapping; skip already-tried)
   and re-survey *from that vantage*. Repeat until a framing yields a candidate (emit it) **or** all
   framings have been tried and all are empty.
4. Only when the comprehensive pass **and** all five framings are empty may the round proceed toward
   `deepest_tier: invent` (and then only if Feature #2's per-seam gate also passes).

**Properties.**
- **Bounded & terminating.** The catalog is fixed (5) + the comprehensive pass = **≤6 surveys**, in a
  fixed order. Rotation always terminates.
- **Deterministic.** Order is the catalog order; no RNG, no seed required. Two identical runs rotate
  identically.
- **Cost is paid only on the path to an empty** — i.e. rarely, and exactly when "try harder before
  giving up" is wanted. A non-empty first pass costs nothing extra.
- **Within a single planning round** (Stage 5), *not* across burst cycles — rotation does not consume
  the ≤3-cycle invent-burst budget; it makes each round's empty thorough.
- **Unseeded behavior change (document it):** unseeded `invent` is unchanged when the comprehensive pass
  is non-empty; it changes *only* on the empty path (now comprehensive + up to 5 framings before
  concluding). Seeded behavior is unchanged on a hit; on an empty it now continues rotating from the
  seed's framing instead of concluding immediately.

**Out of scope (note for later):** rotating framings across *successful* cycles for cross-run idea
diversity. That is a separate enhancement; #1 is strictly empty-triggered.

---

## Feature #2 — Earned-empty: a per-seam justification gate

**Today.** A run may write `deepest_tier: invent` with a single one-line reason. That one line is where
the rls-core lapse hid ("no non-trivial seam remains").

**Proposed.** A `deepest_tier: invent` may be written **only** after the run enumerates **each candidate
seam it considered** and records, per seam, why no extension of it clears the two never-relaxed gates.
The empty must be *shown*, not asserted.

**What counts as a seam.** A real existing attachment point the invent lens weighed — a public
function/method/type/mode/API surface present in PROJECT IMPLEMENTATION SIGNALS that a net-new
capability could bolt to. (Not every symbol — the candidate set a thorough survey would actually
consider.)

**The valid/invalid reason taxonomy (this is the teeth).** Per seam, the *only* reasons that justify
"no groundable extension" are:
- **(ceiling)** every coherent extension is a new subsystem / unrelated domain / from-scratch redesign;
  or
- **(floor)** no extension can carry a runnable verification or attaches to no real surface (degenerate);
  or
- **(genuinely trivial)** the only extension is trivial *with a concrete justification* — e.g. "a
  one-line alias adding no new logic." Bare "trivial wrapper" is **not** acceptable; a numerical
  approximation, a new overload with conversion logic, a new mode, or a new exposed capability is **not**
  trivial.

Reasons that are **invalid** (they mean `must-generate` *emits* that seam's best candidate, flagged in
Rationale, rather than declaring empty):
- "below the value bar";
- "stretches the mission" (e.g. a "small / dependency-light" preference);
- unjustified "trivial".

If *any* seam's recorded reason is invalid, the empty is **rejected** and the run emits that seam's best
grounded candidate instead. This mechanizes `must-generate` as a checklist: you cannot reach an empty
without writing a floor/ceiling-class justification for every seam, which is exactly the step the
rls-core run skipped.

---

## How #1 and #2 compose

They cover orthogonal failure modes and are both required for a valid empty:
- **#1 guarantees breadth** — the survey was run under every vantage (no region silently missed).
- **#2 guarantees rigor** — the conclusion is justified seam-by-seam against floor/ceiling only.

A `deepest_tier: invent` is legitimate **iff** the comprehensive pass + all five framings are empty
**and** every candidate seam has a valid floor/ceiling/justified-trivial reason. On any real,
non-trivial codebase this will essentially never hold — which is the point: the genuine empty becomes a
rare, trustworthy signal ("this minimal project is fully extended"), not a wall.

## `final.md` schema additions (under `invent`)

Written only on the (now rare) path to a `deepest_tier: invent`:

```
invent_framings_tried: [comprehensive, power-user, integration, onboarding, reliability, automation]
invent_seams_examined:
  - <seam symbol/surface> — <ceiling|floor|trivial:concrete reason>
  - ...
```

Both are status/record only — **never** Evidence (Stage 10 bars citing `final.md`), consistent with the
existing `deepest_tier`/`invent_seed`/`invent_framing`/`mission_pressure` fields.

## `SKILL.md` changes required (when approved)

- **Stage 5 invent lens** — add the rotation loop (#1) and the per-seam gate + reason taxonomy (#2)
  ahead of any invent-dry conclusion.
- **Escalation ladder, Tier ③ / deep final point** — a `deepest_tier: invent` is reachable only after
  rotation is exhausted *and* the per-seam gate passes; restate the valid/invalid taxonomy.
- **Cycle step 3/4** — the deep-final-point stop under `invent` fires only on this earned empty.
- **Stage 11 step 3** — persist `invent_framings_tried` and `invent_seams_examined`.

## Test plan (contract tests, tests/run.sh)

- **#1:** SKILL.md documents framing auto-rotation on an empty survey (rotation named; "before … dry";
  exhausts the catalog; references the `EXPLORE_FRAMINGS` order — extend the existing Test 10d drift
  guard so the rotation order is the catalog order).
- **#2:** SKILL.md documents the per-seam gate and the valid/invalid reason taxonomy (value-bar /
  mission / unjustified-trivial are invalid empty-reasons; floor / ceiling / justified-trivial are
  valid). Optionally a `lint-plan.py` advisory: `deepest_tier: invent` recorded with `invent_seams_examined`
  shorter than a small floor on a repo with many public surfaces is a smell (advisory, non-failing).

## Open questions / risks

1. **Gaming #2 by listing few seams.** The audit is a forcing function, not a hard proof; a
   suspiciously short seam list on a non-trivial repo is itself a smell. Mitigation: the optional lint
   advisory above; otherwise rely on the survey's actual candidate set grounding the list.
2. **Cost on the empty path.** ≤6 surveys + a per-seam write. Acceptable because it is empty-only and
   bounded, and it is precisely the "work harder before concluding" the design wants.
3. **Interaction with `seed`.** A seeded run starts rotation at its framing and continues through the
   rest; the recorded `deepest_tier: invent` stays *seed-scoped* (already the rule) — a different seed
   could still find invention. After #1, an unseeded empty is strictly stronger evidence than a seeded
   one (it tried all vantages).

## Recommendation

Implement both, #1 then #2 (breadth before rigor). They are squarely in the mission — no network, no
ungrounded brainstorm, fully deterministic — and together they make `must-generate` actually hold in
practice instead of depending on per-run judgement. The rejected network/external-LLM path is recorded
here for completeness: it does not address the no-seam cause of an empty and trades away determinism and
the grounding pillar, so it is **not pursued**.
