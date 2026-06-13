# planwright component scoping — `path` / `lib` (design)

Status: **IMPLEMENTED (core).** The `build-graph.py --scope` Focus/Context computation and the SKILL.md
procedure wiring (Usage/Options/Inputs, Stage 1 scope resolution with a loud no-match, Focus-wide
maturity rungs, Context-routed reads, the Stage 10 Surfaces-in-Focus gate with the upstream-repair
escape, and the scope-tagged `final.md`) are wired in, with a build-graph fixture test and a SKILL.md↔
builder contract test in `tests/run.sh`. The `lint-plan.py --scope` mechanization of the
Surfaces-in-Focus check is now **IMPLEMENTED** too — it reads the builder's `focus`/`context` sets and
fails an out-of-Focus existing Surface (a `repair` Surface one hop upstream is a non-failing advisory;
`New Surfaces` stay the active agent's judgement, since a not-yet-created file is not a graph node).
This specifies an opt-in way to aim a planwright run at one *component* of the target repo (a subtree or
a logical library) instead of the whole codebase, without weakening grounding, root-cause analysis, or
blast-radius awareness.

planwright is **language-agnostic** — nothing here is C++- or any-stack-specific. `lib` resolution
leans on whatever build/module system the repo already uses (CMake, Cargo, npm, Python packages, Go),
discovered the same best-effort way `build-graph.py` already discovers imports.

## The gap

planwright today plans for the **whole** target. The change-gated rungs (repair/coverage) already
narrow to the dirty set, and the maturity-gated rungs (opportunity/vision) deliberately run
project-wide. There is no way to say *"work on `src/auth/` only"* or *"plan the `parser` library."* On
a large tree that makes a focused pass (own one service, harden one risky module, run depth-10 on a
single library) impossible without wading through the rest of the repo's noise.

The naive fix — "only read and only touch files under X" — is wrong for planwright specifically,
because a hard wall breaks the two properties that make its output trustworthy:

- **Root cause** — a defect that *surfaces* in `src/auth/` often *originates* upstream (in
  `src/crypto/`). A wall forces planwright to patch the symptom in scope instead of the cause.
- **Blast radius** — a change to `auth`'s API affects every downstream importer. A wall hides who the
  change would break, so the verification and Acceptance lose their teeth.

## The model: a *focus set*, not a *filter*

Split the scope into two node sets the graph machinery already knows how to compute, and reuse them:

| Set | What it is | Role |
|---|---|---|
| **Focus** | the files the scope names (X) | where plan items are **proposed and land** |
| **Context** | Focus **+ its 1-hop blast radius** along import **and** coupling edges | what the audit **reads** for grounding, root cause, and impact |

This is exactly the dirty-set blast-radius computation already in `build-graph.py::compute_dirty` (the
`adj` map over import + coupling adjacency). The scope reuses it: **items land in Focus; Evidence and
impact may cite Context.** The graph itself is still built **whole** — you need the full graph to
compute a blast radius — the scope is a partition applied *on top of* it, never a smaller graph.

## Two entry forms, one machinery

Both are **options** (like `depth <D>`), not subcommands, so they compose with `cycle`, `execute`,
`explore`, `depth`, etc. (`planwright lib parser cycle 5 depth 8`, `planwright path src/auth/ execute`).
Both resolve to the same Focus set, so everything downstream is identical.

- **`path <dir|glob>`** — the literal primitive: `path src/auth/`, `path 'src/**/parser*'`. A path that
  matches nothing is an **error** (print it and stop) — never a silent fall-through to a whole-repo run.
- **`lib <name>`** — the convenience resolver. Map a *logical* component name to a path set,
  best-effort, in order: (1) an exact graph **cluster label** (`graph.json` already labels clusters);
  (2) a **build target** — CMake `add_library(<name>)`, a Cargo crate / workspace member, an npm
  workspace, a Python package `<name>/__init__.py`, a Go package dir; (3) a **directory named `<name>`**
  anywhere in the tree; else **fail and print the candidate matches** rather than guessing.

Multiple targets union into one Focus set (`path src/auth/ src/api/`).

## How it threads the pipeline (reuses what exists; no new subsystem)

1. **Stage 1 (scan)** — resolve the scope to the **Focus** node set; derive **Context** = Focus + 1-hop
   blast radius. Record both. PROJECT DIRECTION is still read whole, but the generative rungs now align
   to the component's role within it (a component-level `README`/charter, if present, is preferred).
2. **Stage 1.5 (graph)** — built **whole**, unchanged. The scope intersects its outputs; it never
   shrinks the graph.
3. **Change-gated rungs (repair/coverage)** → scope to `dirty.clusters ∩ Focus`: look only where code
   changed **and** is in Focus.
4. **Maturity-gated rungs (opportunity/vision)** → run **component-wide over Focus** (not project-wide).
   This is the useful emergent behavior: *"mature this one component toward its stated role,"* even
   where nothing changed.
5. **Stage 2b routing** — walk `ranked_code` **restricted to Context**, so the function bodies read are
   the in-scope high-blast-radius ones (still including any articulation point inside Context).
6. **Stage 10 gate — one new rule**: every item's `Surfaces` must lie in **Focus**, with one deliberate
   escape hatch — a `repair` item may name a **Context** (upstream) surface **iff** its Evidence proves
   the in-Focus symptom traces there. That is what stops the scope from forcing symptom-patching.
7. **Verification** — prefer the component's own discovered test targets when scoped (narrower, faster),
   falling back to the full suite.
8. **Stamping (Stage 11)** — only restamp `last_audited_sha` for **in-Focus audited** nodes; leave the
   rest untouched (already the model for skipped nodes).

## The one correctness gotcha: scoped final points

A scoped run that goes dry must **not** convince a later *whole-repo* run that the whole tree is done.
So `final.md` gains a `scope:` field, and the Stage 1 "already at final point" short-circuit must
require the scope to **match** (same Focus signature **and** same HEAD) before it suppresses a run. A
`path src/auth/` final point is a statement about auth and nothing else. The same applies to
`explore`'s `deepest_tier` under a scope — it is a *scoped* deep final point.

```
scope: path:src/auth/            # or  lib:parser  ;  absent = whole-repo (today's behavior)
scope_focus_sha: <sha256 of the newline-joined sorted Focus path list>   # canonical derivation, so a later run (any host) recomputes the same value and knows the scope matches
```

## `SKILL.md` changes required (when approved)

1. **Usage block + Options table** — add `path <X>` and `lib <X>` rows; note they compose with every
   path (plan / `execute` / `cycle`) and are orthogonal to `depth`/`explore`/`invent`.
2. **Inputs** — add **Scope**: how `path`/`lib` resolve to Focus, and Context = Focus + 1-hop radius.
3. **Stage 1** — resolve scope; fail loudly on a no-match; prefer a component-level charter for the
   generative rungs.
4. **Maturity ladder** — state that under a scope the maturity-gated rungs survey **Focus-wide**, not
   project-wide.
5. **Stages 2b / 3–7** — restrict routing/lenses to Context (read) and Focus (propose).
6. **Stage 10** — add the Surfaces-in-Focus rule plus the upstream root-cause escape hatch.
7. **Stage 11 step 3** — write the `scope:` / `scope_focus_sha:` fields; the match rule in Stage 1.
8. **Cycle / Execute** — note that a scoped `cycle` climbs the ladder **within Focus**; a scoped
   `execute` acts only on items whose Surfaces fall in Focus.
9. **Tests** — `tests/run.sh` cases: `path` with a no-match errors; a Focus set + its Context radius are
   computed correctly from a fixture graph; the gate rejects an out-of-Focus item but accepts an
   upstream `repair` with proven in-Focus impact; a scoped `final.md` does **not** short-circuit a
   whole-repo run.

`lint-plan.py --scope <graph.json>` mechanizes the Surfaces-in-Focus check: it reads the builder's
`focus`/`context` sets and fails any pending item whose existing `Surfaces` fall outside Focus — a
`repair` Surface one hop upstream (in Context) is a non-failing advisory to confirm, and `New Surfaces`
stay the active agent's judgement (a not-yet-created file is not a graph node). It is a no-op when the graph's
`focus` is empty (a whole-repo build), so the default lint is unchanged.

## Open questions (decide before building)

1. **Strict wall vs. root-cause escape.** Recommend the escape hatch above — it preserves grounding and
   keeps root-cause analysis honest. A hard wall is simpler but traps the loop into symptom-patching.
2. **Context hop count.** Recommend **1-hop** (matches the dirty set's blast radius). Configurable depth
   is over-engineering for v1.
3. **`lib` resolution ambiguity.** When a name matches both a cluster label and a build target,
   recommend: build target wins (it is the author's declared boundary), and always print what was
   resolved so the user can correct with an explicit `path`.
4. **Validate before building.** Dogfood `path <subdir>` on a real multi-component repo and confirm the
   Focus/Context split actually sharpens the plan (fewer, more on-target items) before mechanizing the
   gate — the same don't-build-on-a-hunch discipline the mission requires.

## Recommendation

Ship `path <X>` first — it is the unambiguous primitive and exercises the whole Focus/Context +
scoped-final-point machinery. Add `lib <X>` as a thin resolver on top once `path` is proven, since `lib`
is *only* a name→path-set mapping that feeds the identical pipeline. This is a partition layered onto the
existing graph + dirty-set + gate machinery — explicitly **not** a new subsystem, so it stays under
planwright's own hard ceiling.
