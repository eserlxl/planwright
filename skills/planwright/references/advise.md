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
table in plain words — pending items → `execute`; a converged tree (a current, valid, whole-repo
final point, nothing pending) → `codinventor`, even when static graph signals such as articulation
look like debt (the declaring round surveyed them dry at this HEAD; new debt would stale the
point); structural debt without convergence, or a stale/invalid final point →
`codvisor` (a large repo shards instead via `codshard`);
converged at `deepest_tier: invent` → the reset-necessity ladder, never a blanket reset: a
**seeded** point (an `invent_seed` is recorded) → re-survey via `codinventor` (a different framing
may still find groundable invention); a cold frontier **undrained or unknown** (`never_audited` > 0,
or no readable count) → a harden sweep (`codvisor`, or `codshard` on a large repo), which re-reads
the frontier without wiping audit memory; only **unseeded AND the frontier shown drained**
(`never_audited` == 0) → `reset` then a fresh harden sweep, because nothing non-destructive
remains — and recommend the result without running it.

STOP after reporting. Advise never dispatches; dispatching is `/codmaster`'s job (Claude Code) or
the user's.
