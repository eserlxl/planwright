## Dashboard

Reached via `planwright dashboard` (or the host equivalent such as `/planwright dashboard`), or the
dedicated **`/planwright:dashboard`** command, which launches it in the background and opens the
browser for you (`commands/dashboard.md`). A
read-only **live web view** of the planning state, so you can *watch* the explore→invent process
evolve in a browser instead of re-running `status`. Like Status, it reads only the gitignored
`.planwright/` tool-state directory — it is a **mirror, never a remote control**: it launches no
agent, edits nothing, and exposes no action buttons.

**Canonical server.** Prefer the bundled, test-covered `<scripts>/dashboard.py` (resolve `<scripts>`
per **Procedure → Bundled scripts**, beside `status.py`/`state.py`): run
`python3 <scripts>/dashboard.py --root <target>` — it binds `127.0.0.1` on an ephemeral port (or
`--port <N>`), prints the URL (add `--open` to also launch a browser), and serves until interrupted.
Stdlib only (no Flask/websocket libs, no build step). It exposes:

1. **`/state.json`** — the current snapshot built on demand by `<scripts>/state.py`
   (`state.collect()`): full pending item bodies, the completed/rejected lists, the recorded final
   point, the graph summary, and `converged`. See `docs/state-schema.md`.
2. **`/graph.json`** — a passthrough of `.planwright/graph.json` (per-node centrality/coverage/churn,
   coupling edges, clusters, import cycles) for the Graph (Coupling Web) and Insights views.
3. **`/doctor.json`** — the read-only environment preflight (`doctor.collect()`: tool availability,
   bundled-script presence, git work tree, `.planwright/` gitignored, commit identity) for the Doctor
   view. It only probes — it never reaches doctor's `--fix` write path.
4. **`/recommend.json`** — the dispatcher decision record (`status.recommend`: the same engine
   `codmaster` and `planwright advise` consume), fetched by the Commands view's codmaster
   front-door panel.
5. **`/events`** — a one-directional Server-Sent Events stream that mtime-polls `.planwright/` ~every
   second and pushes a `change` event whenever a file changes, so the browser re-fetches `/state.json`.
6. **`/` and static assets** — the vanilla `scripts/dashboard/` UI shell (no npm/build toolchain): a
   reactive console with eight views — **Console** (convergence reactor with a three-state resting
   verdict, the expanded health vitals row — coverage, hotspots, coupling, audit frontier, files,
   articulation, tests, cycles — cadence with a mode legend, session trend, dirty pulse),
   **Commands** (the codmaster front-door panel — the exact dispatch `/codmaster` would run next,
   from `/recommend.json` — above the coach's recommended next sweep for the current state —
   codvisor / codinventor / codcycle — plus copy-only codmaster and codshard cards the coach's
   own card rows never auto-recommend: the front door dispatches this coach's picks, and sharding
   is a repo-size call — with a cold-start reset nudge once converged), **Plan**,
   **Timeline** (a cumulative Decision timeline graph by mode above the accepted/killed lists),
   **Graph** (3D coupling globe), **Insights** (risk ledger, hotspot constellation,
   coverage, priorities, the explore escalation's cold-frontier sweep order, import cycles),
   **Shards** (codshard's live shard map: the shardable top-level directories, per-shard
   staleness, the order a sweep would walk, and copyable single-shard invocations), and
   **Doctor** — plus a command palette, light/dark themes, and full keyboard navigation.

The view is **read-only and informational**, like Status: it is never valid Evidence, and it never
mutates the tree. Stop it with Ctrl-C.

**By-hand fallback** (no `python3`): there is no server — use `status` (or read `.planwright/` directly)
for a one-shot summary instead.

STOP after starting the server. Run directly it stays in the foreground until interrupted (Ctrl-C);
the `/planwright:dashboard` command instead launches it in the background, reports the bound URL, and
returns — the dashboard keeps serving on its own.
