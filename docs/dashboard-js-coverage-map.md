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
  - Degraded fallbacks: the empty-dirty-pulse ("nothing changed since last build") and the
    completed-empty recent-contributions branches are **behavior-asserted**
    (`DASH-CONSOLE-DEGRADED`); the remaining bare-ctx render is no-throw **smoke** via the VIEWS loop.

### [plan.js](../scripts/dashboard/views/plan.js) — Plan view
- `render()` — **behavior-asserted**: default render seeds `PW_UI.planMode='all'` (load-order
  regression) and lists pending cards; the empty pending/completed/rejected and mode-filtered
  fallbacks are **behavior-asserted** (`DASH-PLAN-DEGRADED`).
- `crossLinks()` — **behavior-asserted**: one chip + `in graph` key for an in-graph surface,
  none for an out-of-graph surface, none (no throw) without metrics.

### [commands.js](../scripts/dashboard/views/commands.js) — codmaster front door
- `render()` — **behavior-asserted**: front-door panel absent synchronously / on a wrong-shaped
  `/recommend.json`, present on a usable record; beacon-aware kicker (next-dispatch vs
  run-in-progress vs stale); enforce-overlay disclosure on a converged invent-dry record;
  contributions list carries the `Commit` stamp and accepted/rejected sub-line.
- base coach hero (`pw-coach-pick` / `pw-coach-evidence`) — **behavior-asserted** (`DASH-CMD-HERO`):
  the browser-coach pick equals `PW_DERIVE.coach.recommend(signals).key` and the evidence chips
  render, independent of the optional server `/recommend.json` overlay.
- command grid (`pw-cmd-card` per `ORDER` entry) — **behavior-asserted** (`DASH-CMD-HERO`): one
  card per ORDER key (codmaster/codvisor/codinventor/codcycle/codshard); the `pw-coach-pulse-chip`
  warn-classing and the coverage-chip omission at null metrics are pinned by `DASH-CMD-PULSE`.
- `recUsable()` — **behavior-asserted** indirectly (a wrong-shaped body is rejected, a usable
  one paints).
- `dispatchInvocation()` — **behavior-asserted** indirectly (the panel maps `codshard`+`explore`
  to its helper command).
- `paintFrontDoor()` — **behavior-asserted** via the panel render above.

### [insights.js](../scripts/dashboard/views/insights.js) — Risk Ledger + Coverage
- `render()` — **behavior-asserted** (`DASH-INSIGHTS-RENDER`): the uncovered articulation
  hotspot surfaces in the Risk Ledger, the by-language Coverage panel renders, the uncovered
  flag shows; the bare-ctx (null-metrics) branch renders the specific "No graph has been built
  yet" empty-state (not a half-built grid).
- `paint()` (interactive path-filter) — **behavior-asserted** (`DASH-INSIGHTS-RENDER`): the filter
  predicate narrows `metrics.hotspots` and the `(filtered)` affordance shows (`showing 1 of 2
  (filtered)`), with every row restored and the affordance dropped on an empty query.
- `priorities()` (Next up panel) — **behavior-asserted** (`DASH-INSIGHTS-RENDER`): the
  "No ranked surfaces recorded yet." empty-state, the hot/uncovered/articulation/in-cycle priority
  flags, and the top-N surfaces rendered in `rankedCode` (centrality) order.
- `coldFrontier()` (Cold frontier panel) — **behavior-asserted** (`DASH-INSIGHTS-RENDER`): the
  seeded `Invent framing: <vantage> (seed N)` chip and the `Backlog: N never-audited, M stale`
  sub-line from `metrics.frontier`, the "No cold-frontier list recorded yet." empty branch, and the
  uncovered/test flags on cold rows.
- `cycles()` (Import cycles panel) — **behavior-asserted** (`DASH-INSIGHTS-RENDER`): one
  `pw-cycle-card` per import cycle with a `pw-cycle-chip` per member file (paths pinned), and the
  "No import cycles … acyclic" empty branch.

### [shards.js](../scripts/dashboard/views/shards.js) — codshard map
- `render()` — **behavior-asserted**: shard cards from `state.repo` in sweep order, basis chip
  (staleness with a graph, lexicographic without), folded-dirs note, closing whole-repo round,
  large-repo chip, the three copyable invocations, and the no-enumeration empty state.
- copy button — **behavior-asserted** (`DASH-SHARDS-COPY`): a shard card's copy click writes its
  single-shard `codshard` invocation via `navigator.clipboard.writeText` (no-op without a clipboard).

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
- card click handler — **behavior-asserted** (`DASH-FLEET-CLICK`): a card click calls
  `window.PW_SWITCH_PROJECT(p.id)` for that card, and no-ops when the bridge is absent.

### [doctor.js](../scripts/dashboard/views/doctor.js) — environment preflight
- `render()` — **behavior-asserted** (loaded explicitly outside the VIEWS loop): the sync
  placeholder paints immediately.
- `paint()` — **behavior-asserted**: once the stubbed `/doctor.json` promise flushes, the
  `Environment preflight` rows render.

## Known gaps (as of this map)

The gaps this map previously tracked are closed: fleet.js, graph.js, and insights.js paint() are now behavior-asserted (see the per-module map above). The click-handler bodies are now covered too:

- Click-handler *bodies* are now **behavior-asserted** by dedicated blocks that locally upgrade
  the shim to dispatch listeners: the Fleet card switch (`DASH-FLEET-CLICK`), the Shards copy
  button (`DASH-SHARDS-COPY`), and the Commands copy button (`DASH-CMD-COPY`).
- A few degraded (bare-ctx) branches remain **smoke** only — rendered no-throw via the VIEWS
  loop, output not asserted branch-by-branch — but the highest-value console/plan degraded
  fallbacks are now pinned (`DASH-CONSOLE-DEGRADED`, `DASH-PLAN-DEGRADED`).
