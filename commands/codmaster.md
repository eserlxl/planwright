---
description: The front door. An autonomous driver over planwright's whole capability set — it senses the repo's planning state with the read-only coach engine (status.py --recommend, the same truth table the dashboard's Commands view renders), then runs the required commands consecutively — dispatch, re-sense, dispatch — until the repo reaches a recorded final point, using whatever the state calls for (execute, codvisor, codshard explore, codinventor, the cold-start reset) at maximum depth (10). Growth is default-on and taken at most once per run (the banner discloses invent's rare, dwell-gated committed MISSION.md edits); the loop stops at convergence, on any hard blocker or failed broad verify, on no progress, or at the 12-step-per-lap safety cap. `advise` prints the recommendation and stops; `safe` runs the same loop without invention capability — it stops at the first convergence and prints the growth command to paste; `loop` makes the drive infinite — each converged terminal triggers the cold-start reset itself (keeps rejected.md) and begins a new lap with the growth burst re-armed, until interrupted or a hard stop (`safe loop` composes). `parallel` forwards codshard's read-only recon prefetch: a step that dispatches `codshard` gets `parallel` appended to its args (Claude-Code-only, routing-only, never Evidence — degrades to sequential elsewhere), while any step that does not route to codshard prints a one-line nudge to run `/codshard parallel` directly. `parallel` never changes which command the engine chooses — only how a `codshard` dispatch runs (composes with `safe`/`loop`).
argument-hint: "advise | safe | loop | parallel [J] | (empty = sense → dispatch → re-sense, consecutively until the final point)"
---

You are dispatching on behalf of the `/codmaster` helper command. Like `/codcycle` and
`/codshard`, this is an **orchestration** command — but the thinnest one: it owns **no decision
logic and no planning logic**. The decision table lives in the tested engine
`status.py --recommend` (the same coach truth table the dashboard renders, cross-pinned via
`tests/fixtures/coach-table.json`), and all planning/execute/cycle behaviour belongs to planwright.
Do **not** re-implement either: never re-derive the recommendation in prose, and never improvise
when the engine is unavailable. codmaster senses, relays, dispatches consecutively, and reports.

Raw arguments: `$ARGUMENTS`

Resolve them in this order:

1. **`help` / `--help` / `-h` / `?`**: print
   `Usage: /codmaster [advise | [safe] [loop] [parallel [J]]]   (empty = sense the repo and run the required commands consecutively, at depth 10, until a recorded final point; advise = print the recommendation only, dispatch nothing; safe = the same loop without invention capability — it stops at the first convergence and prints the growth command to paste; loop = infinite — each converged terminal triggers the cold-start reset and begins a new lap; parallel = forward codshard's read-only recon prefetch to any step that dispatches codshard, else print a nudge to run /codshard parallel directly — it never changes which command the engine chooses; safe loop parallel compose).`
   and STOP — do not run anything.
2. **`advise`** (alone, or alongside `parallel`): run SENSE below, print the full recommendation
   report (command + args, why, the evidence chips, every note, every blocker verbatim, the
   invent-class notice when set, and the reset nudge when present), and STOP — dispatch nothing.
   When `parallel` is also present and the recommended `command` is `codvisor` (harden routed to
   codvisor — the repo is not large enough to shard), append one line: `parallel only affects
   codshard — run /codshard parallel directly for a sharded recon sweep.`
3. **Peel the mode flags** from the remaining tokens, in any order — they compose:
   - **`safe`**: invention capability off — identical in every way except the growth step's
     handling.
   - **`loop`**: infinite mode — the converged terminal does not stop the run; it triggers the
     cold-start reset and begins a new lap (see the terminal check below).
   - **`parallel`** (optionally followed by an integer `J >= 1`, which binds to it): forward
     codshard's read-only recon prefetch. It changes only how a `codshard` dispatch runs — it
     never changes which command the engine chooses. Peel `J` with it so it is never mistaken
     for a leftover token; an integer below 1 does not bind and falls through as an invalid
     leftover.
   Any other leftover token: print that same `Usage:` line and STOP.
4. **Then run the main loop below** under the peeled flags (empty = neither flag).

**SENSE (read-only).** Resolve `<scripts>` per planwright's **Procedure → Bundled scripts** rule
(the skill base directory's `../../scripts/`). Run
`python3 <scripts>/status.py --root . --recommend` in the ctx sandbox when available and parse its
JSON record. If the engine cannot run (no `python3`, missing script), print
`codmaster: recommendation engine unavailable — run planwright status and pick a direct dial (see README).`
and STOP — never substitute a prose decision table.

**Main loop** (cases 3 and 4). First print exactly one cost banner:
`codmaster: autonomous drive to the final point — sense → dispatch → re-sense, at depth 10, until convergence (max 12 steps). Note: invent may make rare, small committed edits to repo files, including MISSION.md.`
In `loop` mode print this first clause instead:
`codmaster: infinite drive — laps of sense → dispatch → re-sense at depth 10; each converged terminal triggers the cold-start reset (keeps rejected.md) and begins a new lap, until interrupted or a hard stop (max 12 steps per lap).`
In `safe` mode (either banner), the trailing invent notice is replaced by:
`safe: invention capability off — the loop stops at the first convergence.`
(in `safe loop`, by: `safe: invention capability off — each lap runs harden-only.`)
In `parallel` mode (any banner), append this clause to the printed banner:
`parallel: each codshard dispatch fans out read-only recon subagents (J at a time, else host-capped) — extra model calls bought for wall-clock; routing-only, never Evidence, Claude-Code-only (sequential elsewhere).`

Then stamp the run-activity beacon so the dashboard's reactor names this run: run
`python3 <scripts>/state.py activity start codmaster --root .` in the ctx sandbox when available
(same `<scripts>` as SENSE). The beacon is best-effort telemetry — if the script cannot run, skip
it and proceed; never block on it.

Then repeat, for each step `i` (from 1, **never exceeding 12 steps** per lap — the runaway
safety cap; a bare run is a single lap, and in `loop` mode the counter restarts each lap):

1. **SENSE fresh.** Every step re-runs the engine on current state — the loop re-decides between
   steps; it never precomputes a chain of commands.
2. **Blockers are mechanical.** If the record's `blockers` array is non-empty, print each entry
   verbatim and STOP the whole loop — no judgment call, no severity triage. (Doctor findings are
   read-only sensing — codmaster never runs `doctor --fix`; its report may *suggest*
   `planwright doctor --fix`.)
3. **Terminal check.** If the record's `signals.converged` is true:
   - when the growth step was not yet taken this lap (and `safe` is off): take the
     **at-most-once growth burst** — dispatch `codinventor` as this step and mark growth taken.
     One burst per lap keeps each lap convergent: invent's must-generate mandate means repeated
     growth never self-terminates, so unbounded rhythm stays `/codcycle`'s job. The following
     steps harden the new work back to convergence.
   - otherwise, in `loop` mode: the converged terminal continues instead of stopping — print the
     next lap's header `=== codmaster lap L ===`, dispatch planwright with `reset` as this step
     (typing `loop` is the consent for repeated cold starts; `reset` keeps `rejected.md`, so
     rejected work stays suppressed across laps), restart the step counter, re-arm the growth
     burst, and continue — the next SENSE reads first contact and routes to a fresh harden
     sweep. The infinite drive ends only on interruption or a hard stop (blockers, a hard
     blocker, a broad-verify failure, or no progress).
   - otherwise, in `safe` mode or with the growth step already taken: STOP the loop — the
     recorded final point is the terminal state. (In `safe` mode print the growth recommendation
     and the exact line to paste — `/planwright:codinventor`, or the `/codinventor` alias — plus
     the `reset_nudge` alternative when present.)
4. **Dispatch the record's command** under a step header
   `=== codmaster step i/12: <command> <args> ===`. Before the dispatch, re-stamp the beacon
   with the step as its detail —
   `python3 <scripts>/state.py activity start codmaster --detail "step i/12: <command> <args>" --root .`
   (best-effort, never block) — then print the header with a one-line why
   (`<why> (coach: <base.key>)`, appending each `notes` entry — a divergence from the dashboard
   coach is always explained, never silent; for `execute` also name the current branch and the
   pending item titles). On Claude Code, `planwright`/`execute`/`codvisor`/`codinventor`/`reset`
   dispatches are the Skill tool invocation `planwright:planwright` with the record's `args`
   string (codvisor/codinventor resolve to their flagship `cycle 10 depth 10 explore` / `invent`
   forms); a `codshard` dispatch follows `commands/codshard.md` with the record's `args` (default
   `explore`) — and when `parallel` is active that dispatch gets `parallel` (or `parallel J`)
   appended to its `args`, so it becomes e.g. `codshard parallel explore`. Every dispatch runs
   at maximum depth — depth 10 — by construction of those argument strings; codmaster takes no
   depth knob. When `parallel` is active and this step dispatches `codvisor` as the harden action
   — the repo is not large enough to shard, so `parallel` has no codshard dispatch to attach to —
   print one nudge line under the step header — `note: parallel only affects codshard dispatches;
   this step routed to codvisor. Run /codshard parallel directly for a sharded recon sweep.` —
   shown at most once per lap; the flag never changes which command is dispatched. On other hosts, load
   `skills/planwright/SKILL.md` with the same argument string (and the codshard recipe from its
   host-adapter paragraph). Wait for the dispatched run to finish, and record its verified-commit
   count as `commits_i`.
5. **Honour the dispatched run's own stops.** A **hard blocker** or a **failing broad final
   verification** STOPs the whole loop immediately — relay the stop reason verbatim and suppress
   any next-step suggestion except the remediation for that stop.
6. **No-progress guard.** If the step ended with HEAD unchanged AND the fresh SENSE yields the
   identical recommendation (same command and args), STOP and report `no progress` — an honest
   stall report beats spinning on the same dispatch.

**The reset decision — only when really necessary** (shown, not assumed; the engine's
`_reset_necessity` rule). The record says `reset` only when the invent-dry point is unseeded
AND the cold frontier is shown drained; a seed-scoped point routes to a re-survey and an
undrained (or unknown) frontier routes to a harden sweep instead, so audit memory is never
wiped while a non-destructive move remains. When the record's `command` IS `reset`, dispatch
planwright with `reset` (the cold-start wipe keeps `rejected.md`), then dispatch the record's
`follow_up` command as the fresh harden sweep — and when `parallel` is active and that `follow_up`
is `codshard`, it gets `parallel` appended to its args exactly as a step-4 codshard dispatch does,
so `loop parallel` accelerates the harden sweep that dominates each lap restart. This pair is one
composite dispatch — one step — and its header announces both halves up front.

**Invention capability.** When the record says `invent_class: true`:
- **default (case 4)**: dispatch it (subject to the at-most-once growth rule above) — codmaster
  has growing authority by default; the cost banner's notice is the disclosure.
- **`safe` (case 3)**: do NOT dispatch. `safe` means without invention capability — everything
  else (execute, codvisor, codshard, reset) still dispatches; the growth recommendation is
  printed to paste instead.

**REPORT** (after the loop ends — terminal, cap, or early stop). First remove the run-activity
beacon: `python3 <scripts>/state.py activity stop --root .` (best-effort, never block — this
applies to every way the loop ends, including hard stops). Then print a short cumulative
summary: steps taken (out of 12 for the lap), the per-step commands and verified-commit counts in
order (e.g. `codvisor 3 → execute 2 → codinventor 1 → codvisor 0` ), whether the growth burst
ran, whether `parallel` was active and whether a `codshard` dispatch consumed it (if `parallel`
was active but codshard was never dispatched, append `parallel had no effect this run — use
/codshard parallel directly`), the final-point state from the last SENSE relayed verbatim, and
the stop reason (`converged
at the final point`, `hard blocker`, `broad-verify failed`, `blockers`, `no progress`,
`step cap`, or — in `loop` mode — `interrupted`). In `loop` mode also print this summary at the
end of every lap (just before its reset step), and a final overall line when the drive ends:
laps completed, total steps, total verified commits. On a clean converged stop, also print the engine's steady-state recommendation as
the suggested next step in both spellings (e.g. `next: /codinventor — <why>` and
`or just run /codmaster again`), plus the `reset_nudge` when present.

Print nothing of your own except the Usage line (cases 1 and 3), the advise report (case 2), the
cost banner (including the parallel disclosure clause), the per-step headers and one-line whys,
the safe-mode growth recommendation, the parallel nudge line, and the cumulative report; each
dispatched command prints its own output, which stands as-is.
