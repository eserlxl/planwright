# Changelog

All notable changes to planwright are documented here.
The format follows [Keep a Changelog](https://keepachangelog.com/).

## [1.0.0] - 2026-06-01

### Added
- Initial release as a Claude Code plugin.
- `planwright` skill: scan + audit + 8-stage dossier -> draft -> finalize -> quality-gate
  planning pipeline that emits a checkbox plan to `.ai-developer/plan.md`.
- Exact 8-field item format (Mode/Rationale/Evidence/Surfaces/New Surfaces/Development/
  Acceptance/Verification) with strict grounding and quality-gate rules.
- Invocation help (`/planwright help`) and per-run options: `propose <N>`, `max <N>`,
  `no-compact`, `dry-run`.
- Self-hosting marketplace manifest so the repo is installable via `/plugin`.
