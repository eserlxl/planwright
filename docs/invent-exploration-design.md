# planwright invent exploration — seeded, recorded stochasticity (design draft)

Status: **PARTIALLY IMPLEMENTED.** Lever 1's builder substrate — `build-graph.py --seed` emitting
`explore_seed` + `ranked_explore`, with tests — is shipped. The SKILL.md invent-lens wiring is **still
PROPOSED and, on the evidence, not worth wiring for normal repos**: two-seed comparisons (Open question 1,
below) on a small repo *and* on a larger one (rls-core, where `pool > propose_count`) both found the
proposal set **unchanged** — reordering is inert whenever the candidate survey can complete and selection
is value-ranked, which holds far beyond typical repo sizes. The seed bites only under genuine **survey
truncation** (hundreds–thousands of files), and even then its honest value is cross-run *coverage*, not
single-run creativity. **Lever 2 (rotating generative framings) is now the chosen direction**: its builder
substrate — `build-graph.py --seed` also emitting `explore_framing` (a seeded vantage key from a fixed
catalog), with tests — is shipped. Two-framing A/Bs (Open question 5, below) settle it: on **rls-core**
(small) a **near-no-op** (framings change the *surveyed* set, but a real unseeded `codinventor` dogfood
confirmed the candidates are sub-bar under that repo's "small, dependency-light" mission ceiling — a
framing cannot lower the bar); on **lxl** (large, 9-domain, ~510 C++ files) a **clean pass** with nearly
disjoint, genuinely groundable proposed sets. The unifying axis is the *feasibility of comprehensive invent generation*
(truncation — the same axis lever 1 turned on): where comprehensive generation is infeasible (large
multi-domain repos), the framing is the generative prior that makes the survey tractable and **determines
the output**, single-run and cross-run. So lever 2's value **scales with repo idea-space size** and is
**strongest exactly where invent would otherwise converge** — a genuine advance over lever 1. SKILL.md
wiring is now **DONE** (opt-in `seed <S>`, `invent`-only): Stage 1.5 passes `--seed`, Stage 5's invent
lens *scopes* its generative survey through the seeded framing (comprehensiveness recovered across the
seed sequence), and Stage 11 records `invent_seed`/`invent_framing`; an unseeded `invent` stays
comprehensive and deterministic. A SKILL.md↔builder catalog-drift contract test guards it (Test 10d).
Levers 3–4 remain design-only. It addresses a real
observation — repeated `invent` runs tend to re-derive the **same** candidate features — without the
collateral damage of the first instinct (randomizing the graph). The fix injects *seeded, recorded*
stochasticity at the **ideation/selection layer** (where creativity lives) and keeps the graph the
accurate, deterministic **map** the other three rungs depend on.

planwright is **language-agnostic**; nothing here is stack-specific.

## The observation, and why the graph is the wrong lever

The instinct: *"a deterministic graph tree doesn't allow creativity, even in `invent` mode — generate a
random graph each run."* The observation (invent converges to the same ideas) is real; the proposed lever
is not, for three reasons:

- **The graph is routing only, never ideation.** It orders *what the active agent looks at*; it never proposes
  anything and is barred from being Evidence (Stage 10 rejects any item citing graph memory). Invent's
  creativity comes from the **generative lenses (Stage 5–6)**, which in the maturity/invent rungs survey
  **project-wide against PROJECT DIRECTION**, not along graph edges. What *bounds* invention is the **hard
  ceiling** (no new subsystems/domains/redesign) and the **value bar** — not the graph. Because the
  generative lenses are project-wide, graph order influences *invention the least* of all four rungs: it
  is the wrong lever for the exact mode being targeted.
- **A random graph breaks the rungs that do depend on accuracy.** The dirty set / incremental skipping
  (computed by diffing the prior graph), the 1-hop blast radius (`Context` scoping, articulation points),
  and Stage 2b correctness routing all assume *true* edges. Random edges make `repair` chase phantom root
  causes and make Stage 2b read trivia instead of chokepoints.
- **It destroys reproducibility.** `ranked_cold` is deliberately "fully deterministic (no RNG), so
  `explore` stays reproducible." The mission's north star is *trust that what lands is worth doing*;
  unrecorded randomness means you cannot answer "why did it propose this?" — a real auditability cost.

There is already a principled, deterministic answer to "don't just stare at the hot core": **`ranked_cold`
/ the cold-frontier sweep**, which *inverts* the centrality ordering to surface neglected code. The lever
below is its stochastic sibling — targeted variation, still recorded.

## The model: seeded + recorded, at the ideation layer

One rule: **any stochasticity is seeded and written to the run record, so a run stays replayable.** An
unseeded random run is never allowed — it would trade the mission's auditability for novelty. With a
recorded seed, two `invent` runs explore *different* regions of the design space, yet either run can be
reproduced exactly from its seed. The graph stays the accurate, deterministic map; only the **generative
survey's starting vantage and candidate selection** vary.

## The levers (lowest-risk first)

1. **Seeded exploration ordering (the groundable core).** When an `invent` run is given a seed, the
   generative survey walks the project's code surfaces in a **seeded deterministic order** instead of the
   default ranking, so which surfaces are *most salient first* varies per seed (and the most-salient
   dominate what gets proposed). Mechanized in the builder (see schema additions) as `ranked_explore` — a
   seeded permutation of the `branch_count > 0` code nodes, ordered by `sha256(f"{seed}:{path}")` so it is
   **deterministic per seed and stable across Python versions** (no RNG-stream dependence), varies across
   seeds, and is absent (graph byte-for-byte unchanged) when no seed is given.
2. **Rotating generative framings.** Run lenses 5–6 under different vantage prompts across runs ("what
   would a power user want?" / "what integration is missing?" / "what makes onboarding trivial?"). Widens
   the idea space at the reasoning layer; the chosen framing is recorded.
3. **Theme anti-repetition memory.** Extend the existing completed/rejected memory: record the *theme* of
   recently invented features in `.planwright/` and bias the next `invent` run *away* from them, so
   successive runs explore new directions **monotonically** (targeted novelty, not noise). This also makes
   the invent tier drain (a convergence property the escalation ladder already values).
4. **Wider candidate pool + selection temperature.** In `invent`, carry more dossier candidates into
   Stage 8 and pick a more *diverse* top-N rather than the strict highest-ranked.

All four preserve the grounding floor and hard ceiling unchanged — they widen *which* groundable ideas are
surfaced, never lower the bar. (This is the same principle as the escalation ladder: reach widens, proof
does not.)

## `graph.json` schema additions (lever 1)

Emitted **only** under `--seed <N>` (a default build stays byte-for-byte unchanged, exactly like
`--scope`'s `focus`/`context`):

```
"explore_seed": 1337,                         // the recorded seed (reproduce the run from this)
"ranked_explore": ["src/p.py", "lib/q.py"]    // branch_count>0 code nodes in seeded sha256 order
```

Both are **routing only** — never Evidence (Stage 10 bars graph memory), like every other ranked list.

## `final.md` / run-record additions

Record the seed (and chosen framing) so the run is replayable: `invent_seed: <N>` and, if lever 2 ships,
`invent_framing: <name>`. A later run reproduces the exploration by re-passing the same seed. (The
invent-resilience follow-on adds two more on a `deepest_tier: invent`: `invent_framings_tried` and
`invent_seams_examined` — the earned-empty audits; see
[invent-resilience-design.md](invent-resilience-design.md).)

## `SKILL.md` changes — IMPLEMENTED (lever 2, seeded framing)

Wired as below. Note the **departure from the original plan**: validation killed lever 1 (ordering), so
SKILL.md consumes **`explore_framing`**, **not** `ranked_explore` (the latter stays emitted but
unconsumed — routing only). The seed therefore drives *framing scoping*, not survey ordering.

1. **Options / Usage** — opt-in `seed <S>`, **`invent`-only** (ignored under `explore`/no flag). Omitted
   in `invent` → comprehensive deterministic survey (Open question 2's recommendation: deterministic by
   default, opt-in seed first; auto-seed deferred).
2. **Stage 1.5** — when `invent` + a seed, append `--seed <S>` to `build-graph.py`; consume
   `explore_framing`. `ranked_explore` is deliberately ignored (validated inert).
3. **Stage 5 invent lens** — when `explore_framing` is present, *scope* the generative survey through the
   mapped vantage question (the catalog key → question map lives in the lens). Scopes which candidates are
   generated (not a re-rank); never lowers the bar or lifts the hard ceiling; a focused survey that finds
   nothing above bar still declares dry.
4. **Stage 11 / Escalation ladder** — write `invent_seed`/`invent_framing` into `final.md`; a
   `deepest_tier: invent` declared under a seed is *seed-scoped* (a different framing may still find
   groundable invention), so it never suppresses a differently-seeded or unseeded run.
5. **Tests** — `explore_framing` is a catalog key, deterministic per seed, varies across seeds, absent
   without `--seed` (Test 11c2f); a SKILL.md↔builder contract guards that the prose's vantage map matches
   the builder's `EXPLORE_FRAMINGS` catalog with no drift (Test 10d).

## Lever 2 — rotating generative framings (the chosen direction)

**Why this lever, after lever 1 came back inert.** The validation's deepest finding (Open question 1)
is that convergence is a **generation-layer** phenomenon, not an ordering one: the invent lens surveys
project-wide and exhaustively, so *reordering* what it sees first cannot change the candidate set, and
value-ranked selection can't be moved by order. Lever 2 acts on the generation layer directly — it
changes the **vantage question** the lens reasons under (Stage 5's invent lens currently runs under a
*single fixed* prompt, "what would move this project toward its stated direction…", which is precisely
why repeated runs re-derive the same top-of-mind ideas). A framing is a **prior over which candidates
get generated at all**, not an ordering of a fixed pool, so the lever-1 counting argument does **not**
apply: different framings populate the pool with *different members*, so the proposed set's tail
reliably differs and its head may too. This is the honest distinction that gives lever 2 a real shot at
non-inertness where lever 1 had none.

**Substrate (shipped).** `build-graph.py --seed` now also emits `explore_framing`: a seeded pick from a
fixed, append-only catalog of vantage *keys* — `power-user`, `integration`, `onboarding`, `reliability`,
`automation` — chosen by `sha256("<seed>:framing") % len(catalog)`. Deterministic per seed, stable
across Python versions, varies across seeds, absent without `--seed` (default build byte-for-byte
unchanged). The builder owns only the *selection* (deterministic + tested); **SKILL.md owns the
semantics** (key → vantage question), keeping English prompt text out of the structural builder. Routing
only — never Evidence (Stage 10 bars graph memory), exactly like every other ranked/seeded field.

**SKILL.md wiring (validation-gated — Open question 5).** When approved: (1) Stage 5's invent lens, when
`explore_framing` is present, runs its project-wide generative survey *additionally* under the mapped
vantage question — widening *which* groundable net-new ideas are surfaced, never lowering the bar (the
hard ceiling and grounding floor are unchanged; every proposal still cites real surfaces + a runnable
verification and still passes Stage 10). (2) Stage 11 records `invent_framing: <key>` in `final.md`
alongside `invent_seed`, so a seed-scoped deep final point notes that a *different framing* may still
find groundable invention. The key → vantage-question map lives in the invent-lens prose.

**Why wiring is deferred until validated.** Same discipline that kept lever 1 from shipping inert: build
the cheap, tested, recorded substrate first; confirm the behavior changes before wiring it into the
reasoning path. Lever 2's prior is favorable (it changes pool membership), but "favorable prior" is not
"measured" — Open question 5 is the test.

## Open questions (decide before building)

1. **Does reordering the survey actually change the proposals?** **ANSWERED (conditionally) — 2026-06-04.**
   A two-seed comparison on planwright's own repo (seeds 7 vs 99, different lead surfaces) found the
   proposed invent set **identical** (100% overlap). Reason — a counting argument, not a hunch: the
   generative lenses survey **project-wide**, so every surface is seen regardless of order; order can only
   change proposals when the survey is **truncated** before finishing. Here the above-bar candidate pool
   (≈3, generously ≤7) is **smaller than `propose_count` (8)**, so nothing is gated out and both orders
   yield the full pool.

   **Second comparison — rls-core (C++23 RLS library, 18 code nodes), 2026-06-04.** A larger repo whose
   two seeds produced *genuinely divergent* orderings (top-half overlap only 5/9) **and** an above-bar
   invent pool of ~10 (so `pool > propose_count = 8`). This isolates the variable — and the seed was
   **still inert**: 18 files is **fully surveyable** by an exhaustive depth-10 run (lenses 5–6 are
   project-wide and reach every surface regardless of order, so the whole pool is *generated* either way),
   and Stage 8 selects the **highest-value** items — **value-ranked, not survey-order-ranked**. Reordering
   which surface is seen first does not change which candidates are most valuable.

   **Corrected conclusion: `pool > propose_count` is necessary but NOT sufficient.** The seed changes
   proposals only when the **candidate survey cannot complete** — repos large enough (hundreds–thousands of
   files) that even an exhaustive run can't generate the full pool, forcing the seed to pick the slice.
   rls-core overflows the *propose* cap but not the *survey*, so it stays a no-op.

   **Deeper consequence (this partly deflates lever 1):** under value-ranked selection, even in the
   truncation regime the principled fix is *raise survey/propose capacity*, not *randomize the slice*. The
   seed's only honest remaining value is **cross-run coverage** (successive runs cover different slices over
   time), **not single-run creativity**. Wiring implication: **do not wire the invent lens to
   `ranked_explore` for normal repos** — it is provably inert until the survey itself truncates; if pursued,
   frame it as a *multi-run coverage* feature on very large repos, gated on detected survey truncation, and
   re-validate there. (Original hypothesis, kept for provenance: run `invent` twice with different seeds on
   a real, idea-rich repo and confirm the proposed sets genuinely differ and both stay above the value bar
   before wiring deep.)
2. **Default seed in `invent`.** Stay fully deterministic unless `seed <N>` is given, or auto-derive a
   recorded seed (e.g. from HEAD+date) so unattended `cycle -1 invent` naturally explores? Recommend:
   deterministic by default; opt-in seed first; revisit auto-seed after lever 1 is validated.
3. **Interaction with `ranked_cold`.** Should the seeded order bias toward the cold frontier (explore
   *neglected* code stochastically) or span all code? Recommend: start spanning all branch>0 code; add a
   cold bias only if validation shows the hot core dominating.
4. **Anti-repetition vs. reproducibility.** Theme memory (lever 3) makes successive runs diverge by
   design — keep it *advisory* (recorded, biasing) rather than a hard exclusion, so a genuinely best idea
   can still recur.
5. **Does a rotating framing actually change the proposed set? (lever 2 — OPEN, the gate on wiring.)**
   The validation method that exposed lever 1 must be re-run for lever 2, but it tests a *different*
   variable. Procedure: on an idea-rich repo, run the invent generative survey twice under two **different
   framing keys** (e.g. `integration` vs `onboarding`) with the rest of the run held fixed, and compare
   the proposed sets. The lever-1 no-op argument should **not** carry: framings change which candidates
   are *generated*, so expect the pool members — hence at least the proposed set's tail — to differ, with
   both sets still clearing the Stage 10 value bar. Pass condition: ≥1 proposed item under framing A that
   does not appear under framing B (and vice versa), both grounded. Fail condition (treat like lever 1):
   value-ranked selection collapses both framings to the same top-N → the framings are cosmetic and
   should not be wired. Wire the SKILL.md invent lens **only** on a pass.

   **ANSWERED (conditionally) — 2026-06-04, rls-core (28 nodes, small dependency-light C++23 RLS lib).**
   I ran the invent generative lens twice, holding everything fixed except the framing vantage:
   - **`integration`** ("what interoperability is missing?") surfaced, grounded and seam-bound: an
     `extern "C"` FFI shim over create/update/predict/destroy (callable from Python/C pipelines); an
     `std::istream` CSV streaming adaptor driving `RlsAnalyzer::update`; a portable text/CSV
     coefficient+covariance export (serialization.h is binary-only today).
   - **`onboarding`** ("what makes first-run trivial?") surfaced: a `quickFit(xs,ys)` / `withDefaults(n)`
     zero-config facade over the large `RlsModelConfig` surface; a `RlsAnalyzer::summary(std::ostream&)`
     human-readable config+metrics introspection.

   The cores are clearly framing-specific (the FFI shim does **not** arise under `onboarding`; the
   quickFit facade does **not** arise under `integration`), so the literal pass condition is met: ≥1
   grounded, above-bar item unique to each set.

   **CORRECTION (2026-06-04, from a real unseeded `codinventor` dogfood on rls-core).** A live
   `cycle 10 depth 10 invent` run (comprehensive path) re-swept rls-core and declared a **deep final
   point with 0 items**, judging every net-new candidate — explicitly including FFI-shim / stream-loader /
   format-versioned-serialization classes — **blocked by `MISSION.md`'s "small, dependency-light"
   mandate** (and the escalation hard ceiling). That is a *stricter* read of the same mission than my A/B
   applied, and it is the correct one: the framing-specific items above were surfaced as *candidates* but
   most do **not clear rls-core's mission ceiling**, so they are sub-bar there. Honest reclassification:
   on rls-core the framing changed the **surveyed** set but **not the bar-clearing** set (≈ empty either
   way) — so rls-core is better read as a *near-no-op* (matching the unseeded run), not a pass. Key lesson:
   **a framing changes which ideas are surveyed; it cannot lower the value bar or the mission ceiling**,
   so it never manufactures groundable work where the mission forbids it. This *strengthens* the unifying
   conclusion below (lever 2's value tracks genuine idea-space, and a small tightly-bounded repo has
   little regardless of framing); the robust pass is **lxl**, where the groundable multi-domain work is
   real.

   **The honest crux (why this is a *conditional* pass, not a clean win).** rls-core's total groundable
   net-new pool is ≈6–8 items and `propose_count` is 8. By the **exact lever-1 argument**, a
   *comprehensive* invent run would generate the **union** and propose it all regardless of framing →
   identical sets → no-op. So the pass holds **only if the invent lens scopes *generation* to the
   framing's slice** (a per-run vantage) rather than generating comprehensively and merely re-ranking.
   That is a genuine fork from lever 1 (a framing changes *which candidates are materialized*, not their
   order), but it is **not** single-run pool expansion: on a small repo a framing-scoped run proposes a
   *narrower, vantage-focused* set, not a bigger one.

   **Corrected conclusion — lever 2 is a cross-run anti-convergence mechanism, and a real one.** The
   user's original complaint ("repeated `invent` runs re-derive the same ideas") is inherently a
   **cross-run** problem, and that is exactly where lever 2 bites — *more sharply than lever 1 ever
   could*. Lever 1's cross-run "coverage" was illusory off the truncation regime: reordering the **same**
   pool, value-ranked selection re-proposes the **same** top-N every run. Lever 2's cross-run coverage is
   **real even without truncation**: each seeded run materializes a *different* pool (integration-run →
   FFI+streaming; onboarding-run → quickFit+summary), so successive runs genuinely cover different
   regions of the design space while each stays grounded and within bar. **Wiring requirement:** the
   framing must **scope the invent generative survey** (a recorded per-run vantage), accepting that a
   single seeded run is an intentionally *focused* survey and comprehensiveness is recovered across the
   seed/framing sequence — not within one run. Evidence type caveat: this was a *reasoned* A/B (I ran the
   lens), softer than lever 1's mechanical `ranked_explore` diff; re-confirm on a second idea-rich repo
   before treating the wiring as settled.

   **Second comparison — lxl (592 nodes, ~510 C++ files, 9-domain C++26 utility library), 2026-06-04.
   CLEAN PASS — and it settles the rls-core ambiguity.** Same method, framings held the only variable:
   - **`integration`** surfaced (all seam-bound, isolation-principle-aligned): a zstd/LZ4 backend behind
     `compression/compressor.h`; a Prometheus/StatsD exporter over `utils/metrics.h`; an OTLP span
     exporter over `utils/tracing.h`; a Redis-streams publisher on the existing redis context; a
     CSV→typed-schema interop bridging `utils/csv_parser.h` + `utils/load.h`.
   - **`onboarding`** surfaced: a `lxl::selfTest()` runtime capability probe (which optional
     integrations/codecs are built in); `describe()`/`summary()` introspection for `nn/core/network.h`
     and control systems; config-validation-with-reasons over `nn/config.h`; preset factory builders; a
     per-module `examples/` tree (none exists today).

   The proposed **top-8 sets are nearly disjoint** — a far sharper divergence than rls-core. The reason
   is the variable rls-core could not isolate: on a 9-domain, ~510-file library the groundable net-new
   idea space is **dozens** of items, **vastly larger than a single depth-10 run can materialize-and-rank**
   (`propose_count = 8`). Comprehensive generation is therefore **infeasible** — there is *no realizable
   "global pool" to re-rank* — so the "scope vs re-rank" fork that made rls-core only *conditional*
   **collapses**: with comprehensive generation impossible, the framing **necessarily** scopes which slice
   is materialized, and the proposed set follows the framing. Lever 2 is unambiguously **non-inert** here,
   single-run **and** cross-run.

   **Unifying conclusion across all three validations — the axis is the *feasibility of comprehensive
   invent generation*, i.e. truncation, the same axis lever 1 turned on.**
   - **Lever 1 (ordering):** inert unless the *surface survey* truncates; even then value-ranked selection
     makes "more capacity" the real fix, so its only value is weak cross-run coverage. Don't wire for
     normal repos.
   - **Lever 2 (framing) on a small repo (rls-core):** comprehensive invent generation is *feasible*
     (`pool ≤ propose_count`), so framing is cosmetic-to-cross-run — a conditional pass.
   - **Lever 2 (framing) on a large repo (lxl):** comprehensive invent generation is *infeasible* (idea
     space ≫ `propose_count`), so the framing is the generative prior that makes the survey tractable and
     **determines the output** — a clean pass, single-run and cross-run.

   So lever 2's value **scales with the repo's idea-space size**, and — unlike lever 1 — it is *strongest*
   exactly where planning is hardest (large, multi-domain repos where invent would otherwise converge on
   the same few obvious ideas). This is a genuine advance over lever 1 and a defensible reason to wire it.

## Recommendation

Lever 1's builder substrate is shipped and tested (`--seed` → `explore_seed` + `ranked_explore`), and it
was worth building if only to *test* the hypothesis cheaply. But the two validations (small repo + the
larger rls-core, `pool > propose_count`) both came back **no-op**, and isolated the real condition: the
seed changes proposals only under genuine **survey truncation**, and even then value-ranked selection means
the principled fix is *more capacity*, not a random slice. **Recommendation: do not wire the invent lens to
`ranked_explore` for normal repos** — leave the substrate in place as routing-only, and revisit *only* if a
real need appears for **cross-run coverage on very large, survey-truncated repos** (re-validate there
first). Levers 2–4 (rotating framings, theme anti-repetition memory, wider pool/temperature) act at the
generation layer rather than the ordering layer and are the more promising direction if invent-convergence
turns out to be a real problem in practice. Keep the graph the accurate, deterministic map throughout.

**Update — lever 2 chosen and substrate shipped.** `build-graph.py --seed` now also emits
`explore_framing` (a seeded vantage key from a fixed catalog), tested and documented, routing-only. This
is the generation-layer lever the validation pointed to, and — crucially — it does **not** inherit
lever 1's no-op argument: a framing changes *which candidates are generated*, not merely their order, so
the exhaustive-survey counting argument cannot flatten it. Two A/Bs (Open question 5) confirm it: rls-core
(small) **conditionally passed** (value is cross-run there), and **lxl (large, 9-domain) cleanly passed**
with nearly disjoint proposed sets — because comprehensive invent generation is infeasible on a ~510-file
multi-domain repo, so the framing necessarily scopes which slice is materialized. The lever's value
**scales with idea-space size** and is strongest exactly where invent would otherwise converge. Wiring the
SKILL.md invent lens is therefore warranted — under one precise requirement: **the framing must scope the
invent generative survey** (an intentionally focused per-run vantage, comprehensiveness recovered across
the seed sequence), not just re-rank a comprehensive survey. Levers 3–4 remain the next candidates if
framings prove insufficient.
