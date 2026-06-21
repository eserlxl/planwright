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
| `branch` | string | `status` | Current git branch name (`""` on a detached HEAD or when git is unavailable — the dashboard then hides the branch line rather than labelling a detached checkout as a branch). |
| `counts` | object | `status` | `{pending, completed, rejected, carried}` integer counts. `carried` = verified-but-cut dossier candidates recorded in the planning digest's carried section (0 when absent) — the backlog a bare `pending: 0` can hide. |
| `pending_modes` | object | `status` | `{mode: count}` breakdown of pending items, canonical order. |
| `pending` | array | `state.py` | Full pending item bodies — see **Item shape**. |
| `completed` | array | `state.py` | Completed items: `{title, mode, commit}`. `commit` = the `Commit: <short-sha>` provenance stamp the execute path appends on pass (`""` for history that predates the stamp). |
| `rejected` | array | `status` | Rejected items: `{title, reason}` (reason `""` when absent). |
| `final_point` | object\|null | `status` | Recorded final point (`{sha, date, deepest_tier, stale, scope, scope_match, valid, invent_seed, invent_framing, budget, fixpoint}`) or `null`. `valid` = `final.md` passes lint-final's contract; `scope` = the recorded component scope (`"path:<X>"`/`"lib:<X>"`) or `null` for whole-repo; `scope_match` = `null` when this query requested no scope (whole-repo), else `true` iff the recorded point's `scope` matches the requested focus (the scoped-convergence check); `invent_seed`/`invent_framing` = the seeded-invent replay record or `null` when unseeded; `budget`/`fixpoint` = the additive fixpoint-strength fields (the cycle budget string `{ requested: N, used: i }` and the one-line dryness reason) or `null` when an older / pre-fixpoint final.md omits them. |
| `graph` | object\|null | `status` | Graph summary (`{built_at_sha, node_count, dirty_node_count, stale, frontier}`) or `null`. `stale` = the build sha lags `HEAD` (the same sha-lag predicate as `final_point.stale`); `frontier` = the builder's audit-backlog counts (`{never_audited, stale}`) or `null` on a pre-frontier graph. |
| `repo` | object\|null | `status` | codshard's shard enumeration (`{tracked_files, shardable_dirs, folded_dirs, large}`) or `null` when git is unavailable. The same git-tracked rule `commands/codshard.md` applies (top-level dirs holding ≥3 tracked files shard, smaller ones fold, dot-dirs excluded) — surfaced so the dashboard's Shards view renders the partition a sweep would walk instead of approximating it from graph node paths. |
| `activity` | object\|null | `state.py` | The run-activity beacon (`{command, detail, started, age_seconds, stale}`) or `null` when no command flow has stamped `.planwright/activity.json` (or the file is malformed). `command` = the running flow's name (`codmaster`, `codshard`, `codcycle`, `plan`, `execute`, `cycle`); `detail` = its free-text progress line or `null`; `started` = the run's first stamp (UTC ISO-8601) or `null`; `age_seconds` = seconds since the last (re-)stamp, from the file mtime; `stale` = the beacon outlived `PW_ACTIVITY_TTL` (default 3600 s) without a re-stamp — an interrupted run leaves the file behind, so a stale beacon must not be read as live. Distinct from the pending-work verdict: "IN PROGRESS" means items exist; `activity` means a run is executing right now. |
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
  (plus git HEAD via `status.py`) and writes nothing but its own output artifact. The
  one exception is the `state.py activity start|stop` subcommand, which the command
  flows use to stamp/clear the `.planwright/activity.json` beacon the `activity`
  field reads.
- **Determinism.** The snapshot itself carries no timestamp, so two runs over an
  unchanged tree produce byte-identical output — except while a run-activity beacon
  is present: `activity.age_seconds` counts wall-clock seconds since the last stamp
  (and `stale` flips past the TTL), which is exactly the freshness signal the
  dashboard needs about a live run. With no beacon (the steady state between runs)
  the byte-identical guarantee holds unchanged.

## status --json

`scripts/status.py --root . --json` is the *other* machine contract — the summary a CI
wrapper consumes (it composes with `--exit-code`, which keys on the same `converged`
boolean). Its top-level fields:

| Field | Type | Meaning |
|-------|------|---------|
| `root` | string | Absolute path of the inspected repo. |
| `head` | string | Current git HEAD sha (`""` when git is unavailable). |
| `pending` | int | Count of pending (`- [ ]`) items in `plan.md`. |
| `pending_titles` | array | Pending item titles, in plan order. |
| `pending_modes` | object | `{mode: count}` breakdown of pending items, canonical order. |
| `completed` | int | Count of completed (`- [x]`) items in `completed.md`. |
| `completed_modes` | object | `{mode: count}` breakdown of completed items. |
| `last_landed` | object\|null | The newest completed item: `{title, commit}` (`commit` = its `Commit:` provenance stamp, `""` for pre-stamp history); `null` when nothing has landed. |
| `rejected` | int | Rejected item count (always equals `len(rejected_items)`). |
| `rejected_items` | array | Rejected items: `{title, reason}` (reason `""` when absent). |
| `carried` | int | Carried dossier candidates in the planning digest (0 when absent). |
| `final_point` | object\|null | Same shape as state.json's `final_point` above. |
| `graph` | object\|null | Same shape as state.json's `graph` above. |
| `converged` | bool | Current, valid, whole-repo final point with nothing pending — the `--exit-code` verdict. |

Deliberate divergences from `state.json`: `status` reports **flat integer counts plus
`pending_titles`** where `state.json` nests them under `counts` and ships full item
bodies in `pending`/`completed`; and the rejected list is named **`rejected_items`**
here but `rejected` there. Consumers of one contract must not assume the other's field
names.

## verify-manifest

`scripts/state.py --root . --verify-manifest` is a third read-only machine contract — the
pending plan's **Verification commands** as a consumable, runnable artifact (planwright's
"every item carries a runnable verification" promise made external). It writes no
`state.json`; it prints to stdout and is byte-stable on an unchanged plan (the same
determinism guarantee `state.json` itself holds). The commands are **deduped in plan
order** — a command shared by several items appears once, paired with all their titles.

Two output forms, selected by `--as`:

- **`--as json` (default)** — a JSON array of `{command, titles}` objects, in plan order:

  | Field | Type | Meaning |
  |-------|------|---------|
  | `command` | string | A pending item's `Verification:` command (whitespace-trimmed). |
  | `titles` | array | The titles of the pending items that share this command, in plan order. |

  Items with an empty `Verification:` are skipped (they carry no runnable command).

- **`--as sh`** — a runnable shell script: a `#!/usr/bin/env bash` shebang, `set -euo
  pipefail`, then each unique command once, each preceded by its titles as `#` comments.
  An external CI step or AGENTS.md-aware agent can run it directly to re-verify the plan.
