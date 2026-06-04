# planwright invent exploration — seeded, recorded stochasticity (design draft)

Status: **PARTIALLY IMPLEMENTED.** Lever 1's builder substrate — `build-graph.py --seed` emitting
`explore_seed` + `ranked_explore`, with tests — is shipped. The SKILL.md invent-lens wiring is **still
PROPOSED and now gated**: a two-seed comparison (Open question 1, below) showed reordering is a **no-op
unless the survey is truncation-bound** (above-bar candidate pool > `propose_count`), so the lens must
consume `ranked_explore` only in that case. Levers 2–4 remain design-only. It addresses a real
observation — repeated `invent` runs tend to re-derive the **same** candidate features — without the
collateral damage of the first instinct (randomizing the graph). The fix injects *seeded, recorded*
stochasticity at the **ideation/selection layer** (where creativity lives) and keeps the graph the
accurate, deterministic **map** the other three rungs depend on.

planwright is **language-agnostic**; nothing here is stack-specific.

## The observation, and why the graph is the wrong lever

The instinct: *"a deterministic graph tree doesn't allow creativity, even in `invent` mode — generate a
random graph each run."* The observation (invent converges to the same ideas) is real; the proposed lever
is not, for three reasons:

- **The graph is routing only, never ideation.** It orders *what Claude looks at*; it never proposes
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
`invent_framing: <name>`. A later run reproduces the exploration by re-passing the same seed.

## `SKILL.md` changes required (when approved)

1. **Options / Usage** — an opt-in `seed <N>` (cycle-only, invent-relevant; if omitted in `invent`, either
   stay deterministic or derive a recorded seed from the date/HEAD — Open question 2).
2. **Stage 1.5** — pass `--seed` to `build-graph.py`; consume `ranked_explore`.
3. **Stage 5 invent lens** — when a seed is active, walk the generative survey in `ranked_explore` order;
   note that the seed widens *which* candidates surface first, never the bar.
4. **Stage 11 / Escalation ladder** — write `invent_seed` into `final.md`; a deep final point under a seed
   is *seed-scoped* (a different seed may still find groundable invention), so record it as such.
5. **Tests** — `ranked_explore` is deterministic per seed, varies across seeds, and is absent without
   `--seed`; an escalation under a seed still clears the Stage 10 gate (no lowered bar).

## Open questions (decide before building)

1. **Does reordering the survey actually change the proposals?** **ANSWERED (conditionally) — 2026-06-04.**
   A two-seed comparison on planwright's own repo (seeds 7 vs 99, different lead surfaces) found the
   proposed invent set **identical** (100% overlap). Reason — a counting argument, not a hunch: the
   generative lenses survey **project-wide**, so every surface is seen regardless of order; order can only
   change proposals when the survey is **truncated** before finishing. Here the above-bar candidate pool
   (≈3, generously ≤7) is **smaller than `propose_count` (8)**, so nothing is gated out and both orders
   yield the full pool. **Conclusion: seeded ordering changes proposals iff the above-bar pool exceeds a
   run's survey/propose capacity (large, idea-rich repos); on a small repo it is a provable no-op.**
   Implication for the wiring (lever 1 → SKILL.md): **gate the invent lens on `ranked_explore` to the
   truncation case** — only walk the seeded order when the candidate pool would otherwise overflow
   `propose_count`; for small repos, stay deterministic (the seed buys nothing). Validate again on a
   genuinely large repo before trusting the truncated-slice behaviour. (Original hypothesis text, kept for
   provenance: run `invent` twice with different seeds on a real, idea-rich repo and confirm the proposed
   sets genuinely differ *and* both stay above the value bar before wiring deep.)
2. **Default seed in `invent`.** Stay fully deterministic unless `seed <N>` is given, or auto-derive a
   recorded seed (e.g. from HEAD+date) so unattended `cycle -1 invent` naturally explores? Recommend:
   deterministic by default; opt-in seed first; revisit auto-seed after lever 1 is validated.
3. **Interaction with `ranked_cold`.** Should the seeded order bias toward the cold frontier (explore
   *neglected* code stochastically) or span all code? Recommend: start spanning all branch>0 code; add a
   cold bias only if validation shows the hot core dominating.
4. **Anti-repetition vs. reproducibility.** Theme memory (lever 3) makes successive runs diverge by
   design — keep it *advisory* (recorded, biasing) rather than a hard exclusion, so a genuinely best idea
   can still recur.

## Recommendation

Lever 1's builder substrate is shipped (`--seed` → `explore_seed` + `ranked_explore`, tested). The
two-seed validation (Open question 1) then **narrowed the wiring**: reordering only changes proposals when
the survey is truncation-bound, so **do not wire the invent lens to `ranked_explore` unconditionally** —
gate it on `above-bar pool > propose_count`, and stay deterministic on small repos (like planwright's own,
where it is a proven no-op). Re-validate on a genuinely large repo before trusting the truncated-slice
behaviour, then add levers 2–4 (all reasoning-layer prose) if the variation proves real and above-bar.
Keep the graph the accurate, deterministic map throughout.
