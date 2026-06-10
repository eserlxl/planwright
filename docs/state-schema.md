<!--
SPDX-FileCopyrightText: 2026 Eser KUBALI
SPDX-License-Identifier: GPL-3.0-or-later
-->

# `state.json` schema (`version 1`)

`scripts/state.py` emits a single machine-readable snapshot of the planning state to
`.planwright/state.json`. It is the **one stable data contract** the read-only
`planwright dashboard` consumes, so the dashboard never has to scrape the human-facing
markdown (`plan.md` / `completed.md` / `rejected.md`) itself. The markdown remains the
source of truth; `state.json` is a rendered view of it, derived on demand.

It builds on `scripts/status.py` (`status.collect()`): the summary fields below come
straight from `status`, and `state.py` adds the full pending/completed item bodies.

## Top-level shape

| Field | Type | Source | Meaning |
|-------|------|--------|---------|
| `schema_version` | int | `state.py` | Schema version (`1`). Bump on any breaking change. |
| `root` | string | `status` | Absolute path of the inspected repo. |
| `head` | string | `status` | Current git HEAD sha (`""` when git is unavailable). |
| `counts` | object | `status` | `{pending, completed, rejected, carried}` integer counts. `carried` = verified-but-cut dossier candidates recorded in the planning digest's carried section (0 when absent) — the backlog a bare `pending: 0` can hide. |
| `pending_modes` | object | `status` | `{mode: count}` breakdown of pending items, canonical order. |
| `pending` | array | `state.py` | Full pending item bodies — see **Item shape**. |
| `completed` | array | `state.py` | Completed items: `{title, mode}`. |
| `rejected` | array | `status` | Rejected items: `{title, reason}` (reason `""` when absent). |
| `final_point` | object\|null | `status` | Recorded final point (`{sha, date, deepest_tier, stale, scope, valid, invent_seed, invent_framing}`) or `null`. `valid` = `final.md` passes lint-final's contract; `scope` = the recorded component scope (`"path:<X>"`/`"lib:<X>"`) or `null` for whole-repo; `invent_seed`/`invent_framing` = the seeded-invent replay record or `null` when unseeded. |
| `graph` | object\|null | `status` | Graph summary (`{built_at_sha, node_count, dirty_node_count, stale, frontier}`) or `null`. `stale` = the build sha lags `HEAD` (the same sha-lag predicate as `final_point.stale`); `frontier` = the builder's audit-backlog counts (`{never_audited, stale}`) or `null` on a pre-frontier graph. |
| `converged` | bool | `status` | True at a current, **valid**, **whole-repo** final point with nothing pending (an invalid `final.md` never converges; a component-scoped point asserts dryness only for its component). |

## Item shape (`pending[]`)

Each pending item carries all eight plan fields, with the `Surfaces`/`New Surfaces`
comma-separated values parsed into arrays:

| Key | Type | Plan field |
|-----|------|------------|
| `title` | string | the `- [ ] <title>` line |
| `mode` | string | `Mode:` |
| `rationale` | string | `Rationale:` |
| `evidence` | string | `Evidence:` |
| `surfaces` | array | `Surfaces:` |
| `new_surfaces` | array | `New Surfaces:` |
| `development` | string | `Development:` |
| `acceptance` | string | `Acceptance:` |
| `verification` | string | `Verification:` |

A missing string field defaults to `""`; a missing list field defaults to `[]`.

## Notes

- **Read-only / derived.** `state.py` reads only the gitignored `.planwright/` tree
  (plus git HEAD via `status.py`) and writes nothing but its own output artifact.
- **Determinism.** The snapshot carries no timestamp, so two runs over an unchanged
  tree produce byte-identical output; freshness is the dashboard's concern (it re-fetches
  on each SSE event).
