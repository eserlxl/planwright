<!--
SPDX-FileCopyrightText: 2026 Eser KUBALI
SPDX-License-Identifier: GPL-3.0-or-later
-->

# Dashboard client-JS coverage map

The dashboard client modules under [`scripts/dashboard/views/`](../scripts/dashboard/views)
are the recurring untested hotspot: a renamed engine field, a null-deref on a graph-less
snapshot, or an unshimmed DOM call can ship green because a `node --check` and an
HTTP/grep match never *run* a view's `render()`. This document inventories every view
module, its render branches/functions, and how each is exercised by the node-gated harness
in [`tests/cases/dashboard.sh`](../tests/cases/dashboard.sh) (the `DASH-VIEWS-FN` and
`DASH-INSIGHTS-RENDER` blocks, which now share the bootstrap in
[`tests/cases/lib/dashboard-vm.js`](../tests/cases/lib/dashboard-vm.js)).

Keep this map truthful to the harness — when a new behavioral assertion lands, reclassify
the branch it pins.

## Coverage classes

- **behavior-asserted** — `render()` is executed against a fixture and its DOM/text output
  is asserted (a regression in the branch fails CI).
- **smoke** — `render()` is executed (no-throw, non-empty DOM) but its output is not
  asserted branch-by-branch.
- **HTTP/grep-matched** — only matched as a served+registered module or by a source grep;
  `render()` is never executed.
- **unasserted** — `render()` is never executed by any test.

Every module also passes a `node --check` syntax pass (`DASH-FN` / Test 0c), which is
necessary but never sufficient — it proves the file parses, not that it renders.

## Per-module map

### [console.js](../scripts/dashboard/views/console.js) — Convergence Reactor + Health Vitals
- `render()` — **behavior-asserted** (the deepest-covered view).
  - Reactor verdict: IN PROGRESS / CONVERGED / STALE / IDLE — all four resting states asserted.
  - Run-activity beacon: live / stale (`stale?`) / null branches asserted.
  - Satellites incl. the `counts.carried` satellite (present only when non-zero) asserted.
  - Health Vitals: files / articulation / tests counts and the cadence legend asserted; the
    audit-frontier vital is asserted present on a frontier-bearing snapshot and absent on a
    pre-frontier (null) graph.
  - Compact Recent-contributions card (`pw-section-mini`, no commit hash / sub-line / foot) asserted.
  - Degraded (bare ctx, null metrics/graph): rendered no-throw via the shared VIEWS loop (**smoke**).

### [plan.js](../scripts/dashboard/views/plan.js) — Plan view
- `render()` — **behavior-asserted**: default render seeds `PW_UI.planMode='all'` (load-order
  regression) and lists pending cards; degraded bare ctx via the VIEWS loop (**smoke**).
- `crossLinks()` — **behavior-asserted**: one chip + `in graph` key for an in-graph surface,
  none for an out-of-graph surface, none (no throw) without metrics.

### [commands.js](../scripts/dashboard/views/commands.js) — codmaster front door
- `render()` — **behavior-asserted**: front-door panel absent synchronously / on a wrong-shaped
  `/recommend.json`, present on a usable record; beacon-aware kicker (next-dispatch vs
  run-in-progress vs stale); enforce-overlay disclosure on a converged invent-dry record;
  contributions list carries the `Commit` stamp and accepted/rejected sub-line.
- `recUsable()` — **behavior-asserted** indirectly (a wrong-shaped body is rejected, a usable
  one paints).
- `dispatchInvocation()` — **behavior-asserted** indirectly (the panel maps `codshard`+`explore`
  to its helper command).
- `paintFrontDoor()` — **behavior-asserted** via the panel render above.

### [insights.js](../scripts/dashboard/views/insights.js) — Risk Ledger + Coverage
- `render()` — **behavior-asserted** (`DASH-INSIGHTS-RENDER`): the uncovered articulation
  hotspot surfaces in the Risk Ledger, the by-language Coverage panel renders, the uncovered
  flag shows; degraded bare ctx renders no-throw.
- `paint()` (interactive path-filter) — **behavior-asserted** (`DASH-INSIGHTS-RENDER`): the filter
  predicate narrows `metrics.hotspots` and the `(filtered)` affordance shows (`showing 1 of 2
  (filtered)`), with every row restored and the affordance dropped on an empty query.

### [shards.js](../scripts/dashboard/views/shards.js) — codshard map
- `render()` — **behavior-asserted**: shard cards from `state.repo` in sweep order, basis chip
  (staleness with a graph, lexicographic without), folded-dirs note, closing whole-repo round,
  large-repo chip, the three copyable invocations, and the no-enumeration empty state.

### [timeline.js](../scripts/dashboard/views/timeline.js) — Decision timeline / burn-up
- `render()` — **behavior-asserted**: the decision-timeline header.
- `timelineGraph()` — **behavior-asserted**: per-mode cumulative line count, accepted-rate text,
  per-mode legend, and the none-accepted empty branch.

### [graph.js](../scripts/dashboard/views/graph.js) — coupling graph
- `render()` — **behavior-asserted** (`DASH-VIEWS-FN`): a graph-less ctx renders the `NO_GRAPH`
  empty state (`pw-empty`), and a populated ctx drives `PW_GRAPH.renderCoupling` (the `pw-web-svg`
  coupling web, no empty state).

### [fleet.js](../scripts/dashboard/views/fleet.js) — multi-project grid
- `render()` — **behavior-asserted** (`DASH-VIEWS-FN`): driven via `window.PW_PROJECTS`, the
  multi-project grid renders one card per project plus the project-count note; a single project
  uses the singular note; zero projects falls back to the no-projects empty state.

### [doctor.js](../scripts/dashboard/views/doctor.js) — environment preflight
- `render()` — **behavior-asserted** (loaded explicitly outside the VIEWS loop): the sync
  placeholder paints immediately.
- `paint()` — **behavior-asserted**: once the stubbed `/doctor.json` promise flushes, the
  `Environment preflight` rows render.

## Known gaps (as of this map)

The gaps this map previously tracked are closed: fleet.js, graph.js, and insights.js paint() are now behavior-asserted (see the per-module map above). What remains is shim-bounded, not a render-coverage hole:

- Click-handler *bodies* (e.g. the Fleet card's `PW_SWITCH_PROJECT` switch, the Shards/Commands
  copy buttons) are not invoked — the node-gated shim stores listeners but only an explicit
  `.click()` dispatches them, and most blocks render without clicking.
- A few degraded (bare-ctx) paths are **smoke** only (console/plan via the VIEWS loop): rendered
  no-throw, output not asserted branch-by-branch.
