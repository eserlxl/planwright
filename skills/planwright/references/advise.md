## Advise

Reached only via `planwright advise` (or the host equivalent such as `/planwright advise`). A
read-only **recommendation of the next command** — the dashboard Commands-view coach, as a CLI
surface — so anyone (especially a new user) can ask "what should I run now?" without learning the
whole command family first. It reads only the gitignored `.planwright/` tool-state directory plus
mechanical git metadata (tracked-file counts, dirty paths); it mutates nothing, never plans, and
never dispatches anything.

**Canonical engine.** Prefer the deterministic, test-covered `<scripts>/status.py` (resolve
`<scripts>` per **Procedure → Bundled scripts**): run
`python3 <scripts>/status.py --root <target> --recommend` in the sandbox and render its JSON
record as a short human report:

1. **The recommendation** — `command` + `args` (the exact invocation), `why` (one sentence), and
   the `evidence` chips (the numbers behind it). When `notes` is non-empty (e.g. the repo-size
   override routing harden work to `codshard`, or the drain-first rule shadowing the coach's
   `codcycle` row), print each note so a divergence from the dashboard coach is explained, never
   silent.
2. **Blockers** — print each `blockers` entry verbatim (dirty tree, doctor failures, a missing
   commit identity ahead of a mutating run). A blocked recommendation is still shown; the user
   decides how to clear it.
3. **The forks** — when `invent_class` is true, say so: the recommended command may create net-new
   capability and (rarely, dwell-gated) edit `MISSION.md`. When `reset_nudge` is present, print it
   as the alternative (a cold-start re-audit re-surfaces work the dirty-set gating skipped;
   `reset` keeps `rejected.md`).

The engine is the **same truth table the dashboard coach renders** (cross-pinned via
`tests/fixtures/coach-table.json`), extended with the dispatcher-only rows (first contact,
drain-first, carried backlog, repo-size, the invent-dry reset). Its output is routing/status
only — **never** valid Evidence, exactly like `status` and the graph.

**By-hand fallback** (no `python3`): run the Status procedure's by-hand summary, then apply the
table in plain words — pending items → `execute`; structural debt or a stale/invalid final point →
`codvisor` (a large repo shards instead via `codshard`); a clean, converged tree → `codinventor`;
converged at `deepest_tier: invent` → `reset` then a fresh harden sweep — and recommend the result
without running it.

STOP after reporting. Advise never dispatches; dispatching is `/codmaster`'s job (Claude Code) or
the user's.
