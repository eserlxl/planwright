## Reset

Reached only via `planwright reset` (or the aliases `planwright fresh` / `planwright clean`, or the
host equivalent such as `/planwright reset`). A deliberate **cold-start clear** of the `.planwright/`
tool-state directory: it removes the plan, graph memory, digest, final-point marker, completed history,
and state snapshot so the **next** run rebuilds everything from scratch — re-auditing the whole tree
with no incremental shortcuts. This is the antidote to a *stale* convergence: an incremental final point
only asserts dryness relative to what changed since the last graph, so periodically resetting and
re-running (`reset`, then `/codvisor`) re-surfaces groundable work the dirty-set gating would otherwise
skip. Unlike `status`/`dashboard` (read-only), this **mutates** `.planwright/` — but it never touches
application source.

**It deliberately keeps `rejected.md`.** Almost everything in `.planwright/` is either regenerable —
the graph, digest, plan, final point, and state snapshot all rebuild on the next run — or already
recorded in git (the completed-item history). The one exception is the **rejection feedback memory**
(`rejected.md`, read by Stage 1 as PREVIOUSLY REJECTED): it is not in git and does not regenerate, and
keeping it across the reset stops the cold-start run from wasting cycles re-proposing work that was
already tried and rejected. So `reset` clears everything *except* that one file — no backup machinery is
needed, because nothing else of value is lost.

**Canonical script.** Prefer the deterministic, test-covered `<scripts>/lifecycle.py` (resolve
`<scripts>` per **Procedure → Bundled scripts**): run
`python3 <scripts>/lifecycle.py reset --root <target>/.planwright` (note `--root` points **at** the
`.planwright/` directory, as for the other lifecycle commands). It removes every entry under that
directory except `rejected.md`, so the next plan/cycle run sees no prior graph (first run → whole-tree
dirty) and no `final.md` (the ladder re-opens) and audits cold, while retaining the rejection memory.
**`--json`** emits `{command, cleared, rejected_kept}` and **`--quiet`** suppresses the report (parity
with the sibling scripts). A `--root` with no `.planwright/`, or one holding nothing but the kept
`rejected.md`, is a clean no-op.

The `..`-traversal guard (shared with `housekeep`) rejects a `--root` containing a parent-directory
component before touching disk, since `reset` is destructive. It only ever clears under `--root`; it
never edits application source or anything outside `.planwright/`. (To discard the rejection memory too
— a *total* cold start that re-evaluates even previously-rejected ideas — delete `rejected.md` yourself
after the reset.)

**By-hand fallback** (no `python3`): delete `<target>/.planwright/`'s contents *except* `rejected.md`
yourself, then re-run planwright for the cold start.

STOP after reporting.

