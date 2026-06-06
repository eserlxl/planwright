# Changelog

All notable changes to planwright are documented here.
The format follows [Keep a Changelog](https://keepachangelog.com/).

## Highlights

The dated entries below are fine-grained (many are incremental polish). For the load-bearing
milestones, read these:

- **Grounded checkbox plans** — the 8-field item format with `file:line` Evidence and a runnable
  `Verification`, gated by `scripts/lint-plan.py` (the Stage 10 structural gate).
- **Code graph routing** (`scripts/build-graph.py`) — PageRank + articulation points + change-coupling,
  incremental dirty-set invalidation, `ranked_code` for correctness routing, and import-cycle detection.
- **Maturity ladder** — repair → coverage → opportunity → vision, so a clean tree keeps producing
  valuable work instead of idling at a false fixed point; the recorded **final point** (`final.md`).
- **Escalation ladder** (`explore` / `invent`) — cold-frontier sweep → expand → net-new invent, with the
  novelty dial, the grounding floor / structural ceiling, and the dwell-gated mission amendment.
- **Component scope** (`path` / `lib`) — Focus/Context node sets so a run can mature one component.
- **Agent-neutral host adapters** — one canonical argument grammar across Claude Code / Cursor / Codex /
  Antigravity, with the `codvisor` / `codinventor` helpers.

## [1.39.3] - 2026-06-06

### Changed
- Council-audit fixes: symlink-safe Surface validation, lifecycle --root traversal guard and exists/open TOCTOU fix, git-log commit-boundary fix, corrupt-graph warning, portable bump-version, non-default tsconfig aliases, timeout-vs-failure messages; CI shellchecks tests/cases; new engine unit suite.

## [1.39.2] - 2026-06-05

### Changed
- scripts: use context managers for all file I/O (deterministic close; +encoding on prior-graph read)

## [1.39.1] - 2026-06-05

### Changed
- build-graph: bound git subprocess timeout and cap bulk-commit coupling (avoids hangs and O(F^2) git-log blowup)

## [1.39.0] - 2026-06-05

### Added
- **`lint-plan.py --fix`:** opt-in auto-correction of the two mechanical, filesystem-verifiable violations, applied in place before the normal lint runs — a `CMakeLists` Surface respelled `CMakeLists.txt`, and an already-existing `New Surface` moved into `Surfaces` (it cannot be a *new* file, so the move is always correct). Every judgement-dependent violation (missing fields, invalid `Mode`, placeholder `Verification`, a non-existent Surface, graph-memory `Evidence`) is still only reported, never rewritten; the reverse swap (a non-existent Surface → `New Surfaces`) is deliberately *not* auto-applied, since it may be a typo rather than a new file. Edits are surgical (only the `Surfaces`/`New Surfaces` lines change — wrapped prose, titles, and blanks stay byte-identical), idempotent, and skip completed/rejected items unless `--all` is passed. `--fix --json` adds a `fixes_applied` array; `--dry-run` callers must not combine it with `--fix`, which writes. SKILL.md Stage 11 and `docs/architecture.md` note the option.

### Changed
- Test suite **200 → 203** (Tests 12f/12g for `--fix`).

## [1.38.0] - 2026-06-05

### Added
- **`planwright doctor` preflight:** a new read-only command (`scripts/doctor.py`) that reports which capabilities would silently degrade *before* a run starts, instead of surfacing them as fallbacks mid-pipeline. It checks two seams — host tools (`python3`/`git`/`rg`/`fd`, each with its version and exactly what degrades when absent) and bundled-script resolution (`build-graph.py`/`lint-plan.py`/`lifecycle.py` resolving beside `doctor.py`, the `<scripts>` seam) — plus whether the `--root` target is a git work tree. Readable and `--json` output; exits non-zero on a core miss (`git` or a bundled script), while missing `rg`/`fd` or a non-repo target are warn-only. Wired into SKILL.md dispatch / Usage / a new **Doctor** section (with a by-hand fallback for the no-`python3` case), README, and `docs/usage.md`.
- **C/C++ angle-include resolution:** `build-graph.py` now resolves `#include <project/foo.h>` against the repo's `-I` include roots (the unique tracked file whose path ends in that sub-path), not just quoted `#include "x"`. Resolution is strict — no bare-basename fallback — so a system header like `<sys/types.h>` cannot forge a false edge to an unrelated repo `types.h`, and extensionless system headers (`<vector>`, `<map>`) are skipped entirely.

### Changed
- Test suite **193 → 200** (`tests/cases/doctor.sh` + Test 11r for angle includes).

## [1.37.0] - 2026-06-05

### Added
- **TypeScript/JS path aliases:** `build-graph.py` now resolves `tsconfig`/`jsconfig` `compilerOptions.paths` aliases (with `baseUrl` and a `*` wildcard), so an import like `@app/util` maps to its real repo file instead of dropping as node_modules. The config is parsed JSONC-tolerantly via a string-aware comment stripper (a regex would mistake the `/*` inside an alias pattern like `"@app/*"` for a comment).
- **Nested Go modules:** import resolution now reads every `go.mod` and resolves each `.go` file against its nearest enclosing module (Go monorepos), with the package path taken relative to that module's directory. Cross-module imports drop.

### Changed
- **Import-edge precision:** comments and Python docstrings are stripped before import extraction (`strip_comments`), so a commented-out or string-embedded import no longer creates a false graph edge. Used only for edge extraction; metrics still see the original text.
- Disambiguated the three `Procedure` heading slugs in SKILL.md (the planning Procedure keeps `#procedure`; the maintenance ones become `Procedure (upgrade)` / `Procedure (version)`).

Test suite **190 → 193**.

## [1.36.0] - 2026-06-05

### Added
- `scripts/lifecycle.py` mechanizes Stage 0 lifecycle housekeeping (`drain-completed` / `drain-rejected` / `reset-if-empty` / `housekeep`) with the FIFO-100 cap, so the most error-prone bookkeeping has deterministic, test-covered backing instead of being done by hand. SKILL.md Stage 0 now invokes it (the by-hand fallback is kept).
- A large multi-language **integration test** (`tests/cases/integration-scale.sh`): a generated 129-file repo with import stars across Python/JS/C/Rust/Go, asserting build-graph routing at scale (schema, per-language edge resolution, centrality ranking, clusters + articulation points) within a time bound.

### Changed
- **Stage 0 step 3 behavior:** an empty plan (no pending items) is now **deleted** instead of archived to `plans/` — completed and rejected items are already preserved in their own files, so backing up an empty plan was only clutter. Pending items are left untouched so the next run merges its new items into them.
- Split the SKILL.md invent-semantics prose **drift-guards** into `tests/cases/skill-guards.sh`, leaving the structural/wiring/behavioral contracts in `skill-contract.sh`. Test suite **182 → 190**.

## [1.35.0] - 2026-06-05

### Security
- `lint-plan.py` now rejects plan `Surfaces`/`New Surfaces` that are absolute paths or escape the repo via `..` *before* the existence check — `os.path.join(root, "/etc/hosts")` previously discarded the root, so an item could name a file outside the project, and execute treats declared Surfaces as its edit boundary.

### Added
- `build-graph.py` resolves **Go intra-module imports** via the root `go.mod` module path (Go previously yielded no import edges, falling back to change-coupling); Go repos now route by import centrality. Go joins the language fixtures.
- `build-graph.py --debug` writes a human-readable routing digest (ranking signal, top `ranked`/`ranked_code`/`ranked_cold` nodes with pagerank/churn/articulation, dirty set, import cycles) to stderr while stdout stays clean JSON.
- A **zero-item diagnostic** in the Stage 11 report explains why a run wrote 0 items (`capacity` / `already-at-final-point` / `all-rungs-dry`) and names the closest miss.
- End-to-end **golden-plan + language-routing fixtures** for C++, Rust, JS, and Go.
- A `docs/usage.md` troubleshooting guide, a CHANGELOG Highlights section, and a SKILL.md table of contents.

### Changed
- SKILL.md: condensed the Stage 5 invent block (full rationale moved to `docs/invent-exploration-design.md`) and de-duplicated the Cycle escalation restatement — net smaller despite the new TOC, with every rule kept inline.
- `tests/run.sh` split into a shared `tests/lib.sh` harness + topic case files under `tests/cases/` (smoke entrypoint unchanged). Test suite **166 → 182**.
- `lib <X>` documented as agent-resolved in Stage 1 (the builder's `--scope` takes paths/globs only).
- Reconciled stale status blocks in the invent-exploration / escalation / architecture design docs.

### Fixed
- `lint-plan.py` no longer recomputes findings in `--json` mode.
- `bump-version.sh` reads the current version via `argv`; `make-plugin.sh` emits YAML-safe SKILL.md frontmatter so a quote/colon/newline in the author or description can no longer break it.

## [1.34.1] - 2026-06-05

### Changed
- Correct Codex install instructions for personal plugins and direct skills.

## [1.34.0] - 2026-06-05

### Changed
- Generalize planwright for AI coding agents and add Codex packaging.

## [1.33.1] - 2026-06-05

### Changed
- Execute no longer prefixes per-item commit subjects with `planwright:`. Commits now describe the change itself (typically the item title) and read as normal repo commits, instead of restating the tool name on every commit.

## [1.33.0] - 2026-06-04

### Changed
- invent runs now suggest /codvisor to harden the net-new code (suggestion only, never auto-run)

## [1.32.0] - 2026-06-04

### Changed
- Invent resilience: an invent 'empty' is now earned, not asserted. (#1) Framing auto-rotation — an empty invent survey re-runs under every framing in the catalog (deterministic, bounded, empty-triggered) before it may conclude dry, recorded as invent_framings_tried. (#2) Per-seam justification gate — a deepest_tier: invent is written only after a per-seam audit justifies every candidate seam against floor/ceiling; value-bar/mission/unjustified-trivial are invalid empty-reasons (must-generate emits instead), recorded as invent_seams_examined.

## [1.31.2] - 2026-06-04

### Changed
- Fix: a fresh `invent` run no longer short-circuits on a recorded final point (Stage 1 escalation-reach rule). A deepest_tier: invent marker is now informational only, so re-invoking /codinventor at the same HEAD re-surveys and lands the next groundable net-new item instead of freezing; explore likewise re-surveys over a plain/hot-core point.

## [1.31.1] - 2026-06-04

### Changed
- Repair: mission-amendment feature now targets MISSION.md (the file Stage 1 reads and make-plugin generates), not the non-existent MISSION.yaml; renamed across SKILL.md, codinventor, README, docs, and the Test 10f assertions.

## [1.31.0] - 2026-06-04

### Changed
- invent may now make rare, dwell-gated edits to MISSION.yaml: after 3 consecutive invent bursts that could only stretch the mission (mission_pressure in final.md), invent earns one small, committed mission amendment, applied as its own docs-mode item and consumed only on the NEXT cycle (no same-run self-justification). It can relax a preference like 'small, dependency-light' but never the structural hard ceiling (no new subsystem/domain/redesign), and never touches protected paths (.git/, .planwright/ internals, LICENSE, secrets). Always-on under explicit invent with an up-front awareness notice; explore/default never edit the mission.

## [1.30.0] - 2026-06-04

### Changed
- invent now "must generate": an explicit `invent` run always proposes >=1 net-new item rather than declaring itself dry when the only remaining work would extend a deliberately minimal project. The grounding floor (real seam + runnable verification) and structural hard ceiling (no new subsystem/domain/redesign) are never relaxed; the value bar and mission conservatism are, with below-bar/mission-stretching items flagged in their Rationale. Scoped to explicit invent only (explore/default still declare an honest final point). Consequence: the invent tier no longer self-terminates, so `cycle -1 invent` runs to its budget N (stopping early only at plan capacity or a true no-seam empty).

## [1.29.0] - 2026-06-04

### Changed
- Add seeded invent framing: opt-in `cycle N invent seed S` focuses the invent generative survey through one recorded vantage (power-user/integration/onboarding/reliability/automation), so repeated invent runs explore new angles instead of re-deriving the same ideas. Scopes which net-new ideas are surveyed, never the grounding bar; unseeded invent is unchanged. Recorded as invent_seed/invent_framing in final.md.

## [1.28.2] - 2026-06-04

### Changed
- codvisor/codinventor now fold a `path <X>` / `lib <X>` scope into every resolution form: the scope is peeled from $ARGUMENTS first and appended after the resolved subcommand, so a scoped flagship run (e.g. /codvisor path src/auth/ -> cycle 10 depth 10 explore path src/auth/) is reachable and cycle/execute always stays the first token planwright dispatches on.

## [1.28.1] - 2026-06-04

### Changed
- lint-plan.py --scope now mechanizes the Stage 10 Surfaces-in-Focus gate for scoped runs: it reads the builder's focus/context sets and fails an out-of-Focus existing Surface (a repair Surface one hop upstream in Context is a non-failing advisory; New Surfaces stay Claude's judgement). No-op without --scope or on a whole-repo graph; wired into the Stage 11 and Execute linter invocations.

## [1.28.0] - 2026-06-04

### Changed
- Add component scoping (`path <X>` / `lib <X>`): aim a plan/execute/cycle run at one subtree or logical library instead of the whole repo. build-graph.py --scope emits the focus/context node sets (Focus = where items land, Context = Focus + 1-hop blast radius), and the SKILL.md pipeline wires it in — Stage 1 scope resolution with a hard no-match error, Focus-wide maturity rungs, Context-routed reads, a Stage 10 Surfaces-in-Focus gate with an upstream root-cause escape, and a scope-tagged final.md that never suppresses a whole-repo run.

## [1.27.1] - 2026-06-03

### Changed
- README: describe explore's full cold-frontier → expand escalation (the intro bullet still described the pre-v1.27.0 single-sweep model).

## [1.27.0] - 2026-06-03

### Changed
- Add the explore/invent escalation ladder (cold-frontier → expand → bounded net-new invent burst) with a fixed grounding floor + hard ceiling and a novelty dial; read README/roadmap as PROJECT DIRECTION for the generative rungs; add a toolchain-conditional warnings-clean gate to the broad final verification; add the /codinventor helper command.

## [1.26.2] - 2026-06-03

### Changed
- lint-plan.py: flag all-dots '...' Verification placeholder

## [1.26.1] - 2026-06-03

### Changed
- Pre-submission polish: clearer plugin-browser description and a tighter README first screen. No behavior change.

## [1.26.0] - 2026-06-03

### Changed
- Add the `/codvisor` helper command: a thin slash-command alias that forwards its arguments to the planwright skill; with no arguments it runs the flagship advisor sweep (`cycle 10 depth 10 explore`) after printing a cost banner, accepts `N` (cycles; depth defaults to 10) or `N M` for `cycle N depth M explore`, and otherwise passes arguments through verbatim.

## [1.25.0] - 2026-06-03

### Changed
- Add opt-in `explore` flag: at the final point, a cycle escalates to a bounded cold-frontier sweep (via the new `ranked_cold` graph signal) instead of stopping, recording a stronger 'explored' final point when the frontier is also dry; composes with `depth`. Recognize Rust and Go source (lang/defines/branch, Rust mod/use imports). Reject placeholder Verification values in lint-plan.py.

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
