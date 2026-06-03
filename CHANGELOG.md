# Changelog

All notable changes to planwright are documented here.
The format follows [Keep a Changelog](https://keepachangelog.com/).

## [1.24.2] - 2026-06-03

### Changed
- Added an `argument-hint` to the `planwright` skill frontmatter (`[instruction] | execute [N] | cycle <N> [depth <M>] | depth <N> | version | upgrade | help`) so `/planwright` can surface its subcommands as Tab-completable hints, the way a slash command does. `argument-hint` is documented as a *command* field, but commands and skills load identically, so this should also render for the skill; if a given Claude Code build ignores it for skills the field is inert and harmless. Keeps a single canonical `/planwright` (no rename, no separate command, no name collision).

## [1.24.1] - 2026-06-03

### Changed
- Renamed the marketplace from `planwright` to `eserlxl` (owner-scoped, the idiomatic convention — a marketplace is a container that can host multiple plugins). The plugin and skill keep the name `planwright`, so `/planwright` is unchanged; only the install id becomes `planwright@eserlxl`. README, docs, and the SKILL.md upgrade/version procedures updated to match.
- **Breaking for existing installs:** the install id changed, so re-add the marketplace — `/plugin marketplace remove planwright`, re-add the source, then `/plugin install planwright@eserlxl`.

## [1.24.0] - 2026-06-03

### Added
- Import-cycle detection for the Stage 3 architecture lens. `build-graph.py` gains an `import_cycles` field — the strongly-connected components (size ≥ 2) of the *directed* import graph, i.e. circular-import groups (`a → b → a`, python circular imports, C `#include` cycles), computed with iterative Tarjan (no recursion-depth risk on large repos, mirroring `articulation_points`) and capped at `ranked_surface_limit`. The architecture lens now has a concrete "dependency direction" signal instead of eyeballing the edges; like `imports` it is routing-only, so the written item must still cite the real imports before proposing a break. Documented in `docs/graph-memory-schema.md` and SKILL.md Stage 3.

### Tested
- A behavioral test (a directed cycle is flagged, an acyclic importer is not) and the new field in the schema-conformance check. 122 → 123 assertions.

## [1.23.0] - 2026-06-03

### Added
- Test→source coverage routing for the coverage rung. `build-graph.py` gains an `is_test_node()` path classifier (test dirs, `_test`/`test_`/`.spec.`/`_unittest` stems, camelCase `FooTest`) and two additive, routing-only node fields: `is_test`, and `covered_by_test` (true when a test-classified node reaches the node via an `imports` edge **or** a strong `coupling_edges` link — the coupling path links an exec-based harness that runs rather than imports its targets to the code it exercises). SKILL.md Stage 2a now treats `covered_by_test == false` on a non-test code node as a *candidate* "missing focused tests" finding to investigate — never proof; the written item must still name the specific absent test. Documented in `docs/graph-memory-schema.md` and the `docs/architecture.md` design note (now implemented).

### Tested
- Coverage for the classifier (conventional test layouts/names, without mislabeling sources) and the routing (an import-reached source is `covered_by_test`, an orphan source is not), plus the two new fields in the schema-conformance check. 120 → 122 assertions.

## [1.22.0] - 2026-06-03

### Added
- `scripts/lint-plan.py` now mechanizes two more Stage 10 rules that were previously prose-only: a `repair` item's `Evidence` must carry a `file:line` anchor (`:N` / `line N`) rather than bare structural absence (`improve`/`docs` stay exempt), and no plan item may declare a tool-owned `.planwright/` path (plan, graph memory, digest, final point) in `Surfaces:`/`New Surfaces:`. The anchor check only ever *requires* an anchor, so it can never false-fail a well-formed item. SKILL.md Stage 10/11 and the linter docstring document both.
- `docs/architecture.md` design note "test→source coverage routing (deferred)": records the decision to add an additive, routing-only `covered_by_test` node flag (derived from the import/coupling edges the graph already computes) so the coverage rung's "missing focused tests" routing stops being judgement-only — recall-over-precision, absence is a candidate to investigate and never proof.

### Tested
- Added a regression guard that fails if SKILL.md invokes a bundled script via a bare `scripts/…` path (the v1.21.1 fix), plus a foreign-cwd run of both scripts; and coverage for the two new lint-plan gate rules (negative + positive cases). 116 → 120 assertions.

## [1.21.1] - 2026-06-03

### Fixed
- SKILL.md invoked the bundled scripts (`build-graph.py`, `lint-plan.py`) as a bare `scripts/…` path, which only resolves when planwright is run on its own repo. For any installed user running `/planwright` inside another project, the current working directory has no planwright `scripts/` directory, so the canonical builder and the plan linter failed to launch. SKILL.md now resolves bundled scripts as an absolute path under the announced "Base directory for this skill" (`<skill-base>/../../scripts/`) and never uses a bare `scripts/…`. No script behavior changed; the test harness was already path-correct.

## [1.21.0] - 2026-06-03

### Added
- `ranked_code`: a new `graph.json` field — the `ranked` priority list restricted to nodes that carry code (`branch_count > 0`), in the same order. Stage 2b's function-selection walk now reads `ranked_code` (falling back to `ranked`), so doc/data nodes that link-centrality floats to the top of `ranked` no longer displace the engine code Stage 2b is meant to deep-read. Documented in `docs/architecture.md` (design note), `docs/graph-memory-schema.md`, and SKILL.md Stage 1.5/Stage 2b.

### Changed
- `EXT_LANG` now recognizes the common alternate extensions of languages planwright already supports: `.cc`/`.cxx`/`.c++`/`.hh`/`.hxx`/`.tpp` for C/C++ (the primary target) and `.jsx`/`.tsx`/`.mjs`/`.cjs` for JS/TS (already resolvable `JS_EXTS` import targets). Those source files previously routed as `lang="unknown"` and contributed no `defines`/`imports`/`branch_count`.

### Tested
- Added coverage for the new `ranked_code` field (schema conformance + a behavioral test that zero-branch docs are excluded while branchy code is kept) and for the alternate C/C++ and JS/TS extensions (114 → 116 assertions).

## [1.20.0] - 2026-06-03

### Added
- `scripts/lint-plan.py`: a canonical, test-covered linter for the machine-checkable subset of the OUTPUT FORMAT + Stage 10 gate (all eight fields, valid mode, existing `Surfaces:`, absent `New Surfaces:`, no path in both, no graph-memory in `Evidence`, `CMakeLists.txt`, non-empty `Verification:`) plus the maturity-ladder convergence guard (no duplicate pending titles; advisory notes for re-proposed completed/rejected items). Stage 11 self-checks the written plan with it and the execute/cycle paths gate on it.
- Function-granular Stage 2b routing: per-node `defines_at` (symbol → 1-based definition line, a jump hint) and `branch_at` (branches attributed to each symbol by its definition span), plus per-file `branch_count` for the cross-file complexity tiebreak.
- Generated plugins now syntax-check their bundled shell scripts locally (`bash -n`) in `tests/run.sh`, not only in CI shellcheck.

### Changed
- Import resolution now works across all five languages so PageRank centrality routing is no longer blind: bash `source`-by-basename, python dotted/relative modules (`pkg.mod`, `from .mod import x`), js extension/`index` specifiers (`./util` → `util.js`/`util/index.js`), and C `#include` via `-I` include-root basename (with a unique-match guard).
- SKILL.md Stage 2b, Stage 10, and Stage 11 document the new routing fields and the mechanical lint gate; `docs/architecture.md` and `docs/graph-memory-schema.md` updated to match.

### Tested
- Added coverage for articulation points (cut-vertex and cycle cases), whole-graph invalidation triggers, component clustering, builder determinism, shebang/anchor parsing, and every new resolver and plan-lint rule (89 → 114 assertions).

## [1.19.0] - 2026-06-03

### Changed
- Compute the Stage 1.5 dirty set (changed nodes + 1-hop blast radius, whole-graph invalidation triggers) deterministically in build-graph.py via a new `dirty` block, instead of hand-deriving it each run.

## [1.18.1] - 2026-06-03

### Changed
- Coupling-fallback ranking uses churn-normalized weighted degree (per SKILL.md spec), so high-churn ledger files no longer dominate audit routing by raw volume

## [1.18.0] - 2026-06-03

### Changed
- build-graph.py extracts C/C++ functions/classes/gtest groups + richer JS symbols, sharpening Stage 2b audit routing on its primary target language

## [1.17.2] - 2026-06-03

### Changed
- Test the build-graph coupling-fallback ranking branch; statically lint build-graph.py in tests + CI

## [1.17.1] - 2026-06-03

### Changed
- Fix stale stage count in plugin.json; cover build-graph --prior + ranking_signal in tests

## [1.17.0] - 2026-06-02

### Changed
- Canonical Stage 1.5 graph builder (scripts/build-graph.py); SKILL.md structural lint + graph-schema conformance tests

## [1.16.0] - 2026-06-02

### Changed
- Maturity ladder (repair->coverage->opportunity->vision) with a recorded final point; cycles climb instead of idling on a clean tree

## [1.15.0] - 2026-06-02

### Changed
- Depth now maps to a reasoning-**intensity** tier (low→ultra) that planwright self-applies for the run; removed the interactive effort prompt — a skill cannot change `/effort`, which stays the user's to set. Renamed "Reasoning effort" → "Reasoning intensity" across SKILL.md, docs, and README.

## [1.14.0] - 2026-06-02

### Changed
- Depth now maps to a reasoning-intensity tier (low→ultra)

## [1.13.0] - 2026-06-02

### Changed
- Add graph-memory routing: Stage 1.5 code graph (import + change-coupling edges, PageRank, articulation points), centrality-based Stage 2b selection, graph-evidence quality gate, and Phase 2 incremental invalidation with digest.md

## [1.12.1] - 2026-06-02

### Changed
- depth: reserve ultra for N=10; effort bands 1-3 low, 4-6 medium, 7-9 high

## [1.12.0] - 2026-06-02

### Changed
- Add depth <N> option (1..10, default 6): scales reasoning effort + audit thoroughness; usable with cycle

## [1.11.0] - 2026-06-02

### Changed
- Depth audit: Stage 2 sub-passes (Structural/Correctness/Invariants/Behavioral), Stage 4 Correctness lens, Stage 10 repair path-trace gate

## [1.10.0] - 2026-06-02

### Changed
- dry-run for bump-version, --help for scripts, cycle cap 10→100, version/upgrade in Supports, 38+ tests, shellcheck CI

## [1.9.0] - 2026-06-02

### Changed
- Dogfooding cycle: 5 new tests (38 total), update alias in Supports line

## [1.8.1] - 2026-06-02

### Changed
- Add 'update' alias for upgrade subcommand

## [1.8.0] - 2026-06-02

### Changed
- Add cycle command: automated plan→execute loops with bounded (N) and unlimited (-N) modes

## [1.7.0] - 2026-06-02

### Changed
- Show running version in /planwright help; add /planwright version (current vs latest).

## [1.6.0] - 2026-06-01

### Changed
- Add /planwright upgrade subcommand to update the installed plugin.

## [1.5.0] - 2026-06-01

### Changed
- Cover scaffolded tests/CI in smoke suite; document scaffolded tests/CI; warn when skill-version sync finds no version line; add docs/ and README workflow diagram.

## [1.4.0] - 2026-06-01

### Changed
- Sync skill version on bump; expand test coverage; scaffold tests+CI and per-plugin LICENSE in make-plugin.sh; document version-sync and clean-tree rules.

## [1.3.0] - 2026-06-01

### Changed
- Add helper-script test suite, CI workflow, generated-plugin LICENSE, and a dirty-tree/changelog guard in bump-version.sh.

## [1.2.0] - 2026-06-01

### Changed
- Add execute subcommand: implement plan items, verify, commit; FIFO-capped completed.md/rejected.md; rejection-reason feedback into planning.

## [1.1.1] - 2026-06-01

### Changed
- Add SPDX license headers to scripts and SKILL.md; generated plugins inherit them.

## [1.1.0] - 2026-06-01

### Changed
- Add bump-version.sh and make-plugin.sh helper scripts.

## [1.0.0] - 2026-06-01

### Added
- Initial release as a Claude Code plugin.
- `planwright` skill: scan + audit + 8-stage dossier -> draft -> finalize -> quality-gate
  planning pipeline that emits a checkbox plan to `.planwright/plan.md`.
- Exact 8-field item format (Mode/Rationale/Evidence/Surfaces/New Surfaces/Development/
  Acceptance/Verification) with strict grounding and quality-gate rules.
- Invocation help (`/planwright help`) and per-run options: `propose <N>`, `max <N>`,
  `no-compact`, `dry-run`.
- Self-hosting marketplace manifest so the repo is installable via `/plugin`.
