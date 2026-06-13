## Status

Reached only via `planwright status` (or the host equivalent such as `/planwright status`). A
read-only **summary of the current planning state** — what planwright thinks the project is at —
so a maintainer can see it at a glance without running a plan or cycle. It reads only the gitignored
`.planwright/` tool-state directory; it mutates nothing and never plans.

**Canonical check.** Prefer the deterministic, test-covered `<scripts>/status.py` (resolve
`<scripts>` per **Procedure → Bundled scripts**): run `python3 <scripts>/status.py --root <target>`
in the sandbox and relay its report (`--json` for machine output, `--quiet` for exit-code-only,
`--exit-code` to gate on convergence — see below). It reads `<target>/.planwright/` and reports:

1. **Item counts** — pending (`- [ ]` in `plan.md`), completed (`- [x]` in `completed.md`), and
   rejected (`rejected.md`). Beneath the completed count, the report names the newest landing:
   `last landed: <title> (<sha>)` — the final `completed.md` block with its `Commit:` provenance
   stamp (bare title for history predating the stamp; no line when nothing has landed). Carried
   in `--json` as `last_landed` (`{title, commit}` or `null`).
2. **Final point** — from `final.md`: its `sha`, `date`, and `deepest_tier`, plus whether it is
   **STALE** — its sha is not the current `git rev-parse HEAD`, so the tree has moved on since the
   ladder was last exhausted and a fresh run would re-open it (see **Maturity ladder & the final
   point**). Reports "none recorded" when there is no final point.
3. **Graph memory** — from `graph.json`: the sha it was built at, its node count, and how many nodes
   the last build marked dirty.
4. **Run activity** — from `activity.json`: the run-activity beacon, when one is stamped. A live
   beacon reads `activity: <command> — <detail> (run live — stamped <N>s ago)`; one that outlived
   `PW_ACTIVITY_TTL` (default 3600 s) without a re-stamp reads **STALE** with the cleanup hint
   (`state.py activity stop` clears an interrupted run's leftover). No line when no beacon exists.
   The same `{command, detail, started, age_seconds, stale}` object the dashboard shows, carried
   in `--json` as `activity` (or `null`).

By default the exit code is always `0` — status is informational, and "no plan / no final point" is a
valid state, not an error (unlike Doctor, which fails on a broken environment). The opt-in
`--exit-code` flag is the one exception: it exits `0` only when the project is at a *current,*
*valid*, **whole-repo** final point (a valid final point is recorded — `final.md` passes lint-final's
contract — its sha is HEAD, no component `scope:` is recorded, and nothing is pending; a scoped point
asserts dryness only for its component) and `1` otherwise, so a
wrapper or CI gate can check convergence machine-readably (it composes with `--json`/`--quiet`). The
report itself is **never** valid Evidence (it summarizes routing/status state, like the graph and
final-point markers).

**By-hand fallback** (no `python3`): read `<target>/.planwright/` directly — count the `- [ ]` /
`- [x]` lines in `plan.md`/`completed.md`, the items in `rejected.md`, the `sha`/`deepest_tier` in
`final.md` (compare its sha to `git rev-parse HEAD` for staleness), and `graph_built_at_sha` plus the
node/`dirty` counts in `graph.json` — and relay the same summary by hand.

STOP after reporting.

