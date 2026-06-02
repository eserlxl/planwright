# Changelog

All notable changes to planwright are documented here.
The format follows [Keep a Changelog](https://keepachangelog.com/).

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
