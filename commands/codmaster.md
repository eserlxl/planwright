---
description: The front door. An autonomous driver over planwright's whole capability set — it senses the repo's planning state with the read-only coach engine (status.py --recommend, the same truth table the dashboard's Commands view renders), then runs the required commands consecutively — dispatch, re-sense, dispatch — until the repo reaches a recorded final point, using whatever the state calls for (execute, codvisor, codshard explore, codinventor, the cold-start reset) at maximum depth (10). Growth is enforced whenever `safe` is off — at every converged terminal codmaster takes one invent burst (`codinventor`) regardless of the engine's per-state recommendation, at most once per run (the banner discloses invent's rare, dwell-gated committed MISSION.md edits); after the growth burst the harden is sharded (`codshard explore`, when the repo is shardable) so each lap deep-hardens its freshly-grown code per-component, in every drive — not only under `loop`. The loop stops at convergence, on any hard blocker or failed broad verify, on no progress, or at the 12-step-per-lap safety cap. `advise` prints the recommendation and stops; `safe` runs the same loop without invention capability — it stops at the first convergence and prints the growth command to paste; `loop` makes the drive infinite — each converged terminal triggers the cold-start reset itself (keeps rejected.md) and begins a new lap with the growth burst re-armed, until interrupted, a hard stop, or a fully-dry lap (the final convergence point, decided only at the lap boundary after the post-growth codshard — never at an intermediate step; `safe loop` composes) — each lap's post-growth harden is sharded by the same general rule above. `parallel` forwards codshard's read-only recon prefetch: a step that dispatches `codshard` gets `parallel` appended to its args (Claude-Code-only, routing-only, never Evidence — degrades to sequential elsewhere), while any step that does not route to codshard prints a one-line nudge to run `/codshard parallel` directly. `parallel` never changes which command the engine chooses — only how a `codshard` dispatch runs (composes with `safe`/`loop`).
argument-hint: "advise | safe | loop | parallel [J] | (empty = sense → dispatch → re-sense, consecutively until the final point)"
---

You are dispatching on behalf of the `/codmaster` helper command. Like `/codcycle` and
`/codshard`, this is an **orchestration** command — the master driver over planwright's whole
capability set. It owns **no per-state coach-table logic and no planning logic**: the per-state
recommendation — *which command does this state need?* — lives in the tested engine
`status.py --recommend` (the same coach truth table the dashboard renders, cross-pinned via
`tests/fixtures/coach-table.json`), and all planning/execute/cycle behaviour belongs to planwright.
Do **not** re-implement either: never re-derive the recommendation in prose, and never improvise
when the engine is unavailable. What codmaster **does** own is the **lap orchestration** layered
over the engine's per-step answers: the loop shape, the at-most-once growth bound, the
reset-and-relap, and the **post-growth sharded harden** (step 4 — after every growth burst, in any lap, when the repo is shardable). codmaster
senses, relays, applies those orchestration
rules, dispatches consecutively, and reports.

Raw arguments: `$ARGUMENTS`

Resolve them in this order:

1. **`help` / `--help` / `-h` / `?`**: print
   `Usage: /codmaster [advise | [safe] [loop] [parallel [J]]]   (empty = sense the repo and run the required commands consecutively, at depth 10, until a recorded final point; advise = print the recommendation only, dispatch nothing; safe = the same loop without invention capability — it stops at the first convergence and prints the growth command to paste; loop = infinite — each converged terminal triggers the cold-start reset and begins a new lap, with its post-growth harden sharded (codshard) when the repo is shardable; parallel = forward codshard's read-only recon prefetch to any step that dispatches codshard, else print a nudge to run /codshard parallel directly — it never changes which command the engine chooses; safe loop parallel compose).`
   and STOP — do not run anything.
2. **`advise`** (alone, or alongside `parallel`): run SENSE below, print the full recommendation
   report (command + args, why, the evidence chips, every note, every blocker verbatim, the
   invent-class notice when set, the reset nudge when present, and — when the engine's converged
   recommendation is a non-growth invent-dry move (`reset`/`codvisor` at `deepest_tier: invent`) —
   the enforcement notice that a default (non-`safe`) drive would instead take an enforced
   `codinventor` burst here), and STOP — dispatch nothing.
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
`codmaster: autonomous drive to the final point — sense → dispatch → re-sense, at depth 10, until convergence (max 12 steps); the converged terminal always earns one enforced invent burst (codinventor) unless run with safe, after which the harden is sharded (codshard explore) when the repo is shardable. Note: invent may make rare, small committed edits to repo files, including MISSION.md.`
In `loop` mode print this first clause instead:
`codmaster: infinite drive — laps of sense → dispatch → re-sense at depth 10; each lap hardens → grows (codinventor) → deep-hardens the grown code per-component (codshard, when the repo is shardable) → resets (cold-start, keeps rejected.md) into the next, until interrupted, a hard stop, or a fully-dry lap (final convergence) — termination is decided only at the lap boundary, never mid-lap (max 12 steps per lap).`
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
   - when `safe` is off AND the growth step was not yet taken this lap: take the **enforced
     at-most-once growth burst** — dispatch `codinventor` as this step and mark growth taken,
     **regardless of the engine's `invent_class`** (so a converged `deepest_tier: invent` point
     the engine would route to reset/codvisor grows anyway — planwright's `invent` has a
     must-generate mandate, so re-surveying a "dry" point lands the next groundable net-new item
     rather than freezing). Running codmaster without `safe` is the **consent to grow**, so every
     converged terminal earns one invent burst per lap; the engine's `invent_class` and its
     invent-dry routing are **advisory only** here — surfaced in the why, never withholding the
     burst. Only `safe` withholds it. One burst per lap keeps each lap convergent: invent's
     must-generate mandate means repeated growth never self-terminates, so unbounded rhythm stays
     `/codcycle`'s job. The following steps harden the new work back to convergence — and that
     post-growth harden is **sharded** (`codshard explore`, when `repo.shardable`; see step 4), so
     each lap deep-hardens its freshly-grown code per-component.
   - otherwise, in `safe` mode, when the record's `command` is `reset` or `codvisor` with
     `invent_class: false` — relay the engine's **invent-dry routing**: a converged
     `deepest_tier: invent` point the engine deliberately routes (per its `_reset_necessity`
     rule) to a cold-start `reset`, a seed re-survey, or a `codvisor` harden of an undrained
     frontier, **not** a growth burst — dispatch **that** command (the reset decision section
     below for `reset`, the step-4 relay for `codvisor`). `safe` never invents, so when the
     engine itself withholds growth codmaster relays that non-destructive move. Outside `safe`
     the enforced burst above pre-empts this routing — it is the `safe` path that honours the
     engine's invent-dry choice (a bare or `loop` drive grows instead).
   - otherwise, in `loop` mode: the converged terminal continues instead of stopping — **but the
     termination decision is taken here, at the lap boundary, after the post-growth codshard
     harden, never at an intermediate step**: if the whole lap advanced HEAD zero times (every
     `commits_i` of this lap was 0, the growth burst included; the lap-opening `reset` moves
     nothing in git — it only clears gitignored `.planwright/` tool-state — so it never masks a
     dry lap), the project has reached its **final convergence point** — STOP and report `no progress` (a fully-dry lap is the only
     honest "done" for an infinite drive: invent's must-generate mandate means a lap that grew
     and still moved nothing has nothing groundable left). Otherwise the lap made progress, so
     relap: print the next lap's header `=== codmaster lap L ===`, dispatch planwright with
     `reset` as this step (typing `loop` is the consent for repeated cold starts; `reset` keeps
     `rejected.md`, so rejected work stays suppressed across laps), restart the step counter,
     re-arm the growth burst, and continue — the next SENSE reads first contact and routes to a
     fresh harden sweep. The infinite drive ends only on interruption or a hard stop (a blocker,
     a hard blocker, or a broad-verify failure — these stop it immediately at any step), or, at
     this lap boundary, a fully-dry lap (the final convergence point); the soft no-progress guard
     never stops a lap mid-flight.
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
   — a pre-growth harden, or a non-shardable repo's harden, so `parallel` has no codshard dispatch
   to attach to (the post-growth harden on a shardable repo shards instead — see step 4) —
   print one nudge line under the step header — `note: parallel only affects codshard dispatches;
   this step routed to codvisor. Run /codshard parallel directly for a sharded recon sweep.` —
   shown at most once per lap; the flag never changes which command is dispatched. On other hosts, load
   `skills/planwright/SKILL.md` with the same argument string (and the codshard recipe from its
   host-adapter paragraph). Wait for the dispatched run to finish, and record its verified-commit
   count as `commits_i`.

   **Post-growth sharded harden (the master's one command-shaping rule).** Once the growth burst
   has been taken this lap — and a bare run is itself one lap, so this fires in **every** drive,
   not only under `loop` — the master shapes the harden that follows it:
   when the engine's record `command` is `codvisor` (the per-state harden) AND the record's
   `repo.shardable` is true, dispatch `codshard explore` **instead** — follow `commands/codshard.md`
   with `explore` (so `parallel` appends to *that*: `codshard parallel explore`), deep-hardening
   the freshly-grown code per-component, with a closing whole-repo round.
   This is the one place codmaster shapes the command rather than relaying it, so it is an
   **explained divergence**: print under the step header `note: post-growth — sharding the
   harden of the just-grown code (engine: codvisor; repo.shardable)`, and the parallel-codvisor
   nudge above does not fire (this step is now a `codshard` dispatch, so `parallel` has its
   target). The override is narrow: it fires **only** after the growth
   burst, **only** when the record command is `codvisor`, and **only** when `repo.shardable` is
   true — when the repo is not shardable (fewer than `SHARD_MIN_DIRS` partitionable dirs) it does
   not fire and the harden stays `codvisor`. Before the growth burst, or for any
   other record command (`execute`/`reset`/`codshard`/`codinventor`), codmaster relays the
   engine's command unchanged. (The per-state choice is still the engine's; the master only
   decides to *shard* the harden it already chose, once, after growing — in any lap, bare or
   looped.)
5. **Honour the dispatched run's own stops.** A **hard blocker** or a **failing broad final
   verification** STOPs the whole loop immediately — relay the stop reason verbatim and suppress
   any next-step suggestion except the remediation for that stop.
6. **No-progress guard.** If the step ended with HEAD unchanged AND the fresh SENSE yields the
   identical recommendation (same command and args): **outside `loop`**, STOP and report
   `no progress` — an honest stall report beats spinning on the same dispatch. **In `loop` mode
   this guard does not stop the lap mid-flight** — a 0-commit harden must be allowed to advance to
   the guaranteed-to-generate growth burst rather than be misread as "done"; the 12-step cap is
   the mid-lap runaway backstop, and the no-progress verdict is instead evaluated once at the lap
   boundary (the terminal check above), where a lap that moved HEAD zero times across all its
   steps — through the post-growth codshard harden — is the final convergence point.

**The reset decision — only when really necessary** (shown, not assumed; the engine's
`_reset_necessity` rule). This engine-`reset` relay is reached only under `safe` — outside `safe`
the enforced growth burst pre-empts the engine's invent-dry routing, so a bare or `loop` drive
grows here instead of relaying a `reset`. The record says `reset` only when the invent-dry point is unseeded
AND the cold frontier is shown drained; a seed-scoped point routes to a re-survey and an
undrained (or unknown) frontier routes to a harden sweep instead, so audit memory is never
wiped while a non-destructive move remains. When the record's `command` IS `reset`, dispatch
planwright with `reset` (the cold-start wipe keeps `rejected.md`), then dispatch the record's
`follow_up` command as the fresh harden sweep — and when `parallel` is active and that `follow_up`
is `codshard`, it gets `parallel` appended to its args exactly as a step-4 codshard dispatch does,
so `safe loop parallel` accelerates the harden sweep that dominates each lap restart. This pair is one
composite dispatch — one step — and its header announces both halves up front.

**Invention capability.** Whether codmaster grows is decided by the `safe` flag, **not** by the
engine's `invent_class`:
- **default (case 4)**: invention is **enforced** — at every converged terminal the at-most-once
  growth burst dispatches `codinventor` regardless of the engine's `invent_class` (its invent-dry
  routing is advisory only). codmaster has growing authority by default; the cost banner's notice
  is the disclosure.
- **`safe` (case 3)**: do NOT dispatch the growth burst. `safe` means without invention
  capability — everything else (execute, codvisor, codshard, reset, and the engine's invent-dry
  routing) still dispatches; the growth recommendation is printed to paste instead.

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
`step cap`, or — in `loop` mode — `interrupted`; in `loop`, `no progress` is reached only at a
lap boundary — a fully-dry lap — never mid-lap). In `loop` mode also print this summary at the
end of every lap (just before its reset step), and a final overall line when the drive ends:
laps completed, total steps, total verified commits. On a clean converged stop, also print the engine's steady-state recommendation as
the suggested next step in both spellings (e.g. `next: /codinventor — <why>` and
`or just run /codmaster again`), plus the `reset_nudge` when present.

Print nothing of your own except the Usage line (cases 1 and 3), the advise report (case 2), the
cost banner (including the parallel disclosure clause), the per-step headers and one-line whys,
the safe-mode growth recommendation, the parallel nudge line, and the cumulative report; each
dispatched command prints its own output, which stands as-is.
