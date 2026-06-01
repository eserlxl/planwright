# Changelog

All notable changes to planwright are documented here.
The format follows [Keep a Changelog](https://keepachangelog.com/).

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
