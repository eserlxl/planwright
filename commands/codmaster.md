---
description: The front door. An autonomous driver over planwright's whole capability set — it senses the repo's planning state with the read-only coach engine (status.py --recommend, the same truth table the dashboard's Commands view renders), then runs the required commands consecutively — dispatch, re-sense, dispatch — until the repo reaches a recorded final point, using whatever the state calls for (execute, codvisor, codshard explore, codinventor, the cold-start reset) at maximum depth (10). Growth is enforced whenever `safe` is off — at every converged terminal codmaster takes one invent burst (`codinventor`) regardless of the engine's per-state recommendation, at most once per run (the banner discloses invent's rare, dwell-gated committed MISSION.md edits); after the growth burst the harden is sharded (`codshard explore`, when the repo is shardable) so each lap deep-hardens its freshly-grown code per-component, in every drive — not only under `loop`. Once that post-growth harden re-converges, codmaster runs one **qb intent-replan** — `/qb-plan auto` (when qb is installed) — merging its pending items into the plan (deduped against completed/rejected, re-validated) and executing them, the top rung of the escalation ladder (execute → codvisor → codinventor → qb → execute); `safe` never runs qb. The loop stops at convergence, on any hard blocker or failed broad verify, on no progress, or at the 12-step-per-lap safety cap. `advise` prints the recommendation and stops; `safe` runs the same loop without invention capability — it stops at the first convergence and prints the growth command to paste; `loop` makes the drive infinite — each converged terminal triggers the cold-start reset itself (keeps rejected.md) and begins a new lap with the growth burst re-armed, until interrupted, a hard stop, or a lap whose qb intent-replan itself comes up dry (the final convergence point, decided only at the lap boundary after the post-growth codshard and qb replan — never at an intermediate step; `safe loop` composes) — each lap's post-growth harden is sharded by the same general rule above. `parallel` forwards codshard's read-only recon prefetch: a step that dispatches `codshard` gets `parallel` appended to its args (routing-only, never Evidence; recon runs on the host's native subagent — sequential where the host has none — and codmaster never auto-engages the optional external-agent CLI backend, which is an explicit `/codshard parallel external` opt-in that contacts external providers), while any step that does not route to codshard prints a one-line nudge to run `/codshard parallel` directly. `parallel` never changes which command the engine chooses — only how a `codshard` dispatch runs (composes with `safe`/`loop`).
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

0. **Peel the scope first.** If `$ARGUMENTS` contains a `path <X>` or `lib <X>` scope (the keyword
   plus its single following token, appearing anywhere), lift that pair out as `<scope>` (the bare
   `path <X>` / `lib <X>` form) and let `<rest>` be the remaining tokens; also derive `<scope-spec>`,
   the colon form `path:<X>` / `lib:<X>` the sense engine takes. Otherwise `<scope>` and
   `<scope-spec>` are empty and `<rest>` is all of `$ARGUMENTS`. A scope aims the **whole drive** at
   one component: `<scope-spec>` is threaded into SENSE (`status.py --recommend --scope <scope-spec>`)
   so pending, debt, and convergence are Focus-restricted, and `<scope>` is appended **after** each
   dispatched command's args so the subcommand (`cycle`/`execute`/`reset`) stays the **first token**
   planwright dispatches on — never let `path`/`lib` lead. Omit the trailing `<scope>` when empty.
   Also recognise the `--`-prefixed aliases when peeling, normalising to the bare form first:
   `--path <X>` → `path <X>`, `--lib <X>` → `lib <X>`, `--scope <X>` → `path <X>` (both `--opt <X>`
   and `--opt=<X>` spellings).
   Under a scope codmaster never auto-routes the two **whole-repo** moves — `codshard` (a sharded
   whole-repo sweep with a whole-repo closing round) and `reset` (a whole-repo `.planwright` wipe
   that would erase sibling components' audit memory) — and the **post-growth harden is not sharded**
   (step 4): the scope already focuses one component, so every harden stays a scoped `codvisor`. The
   engine enforces this in the record it returns under `--scope`; codmaster relays it (a scoped
   record never carries `codshard`/`reset`), so this is not a second decision layer.
1. **`help` / `--help` / `-h` / `?`**: print
   `Usage: /codmaster [advise | [safe] [loop] [parallel [J]]] [path <X> | lib <X>]   (empty = sense the repo and run the required commands consecutively, at depth 10, until a recorded final point; advise = print the recommendation only, dispatch nothing; safe = the same loop without invention capability — it stops at the first convergence and prints the growth command to paste; loop = infinite — each converged terminal triggers the cold-start reset and begins a new lap, with its post-growth harden sharded (codshard) when the repo is shardable; parallel = forward codshard's read-only recon prefetch to any step that dispatches codshard, else print a nudge to run /codshard parallel directly — it never changes which command the engine chooses; a path/lib scope aims the whole drive at one component — SENSE, every dispatch, and convergence are Focus-restricted, and codshard/reset (whole-repo moves) never auto-route under a scope, so the harden stays a scoped codvisor; safe loop parallel scope compose).`
   and STOP — do not run anything.
2. **`advise`** (alone, or alongside `parallel`, and composing with a peeled scope): run SENSE
   below (scoped to `<scope-spec>` when a scope was peeled — the report then describes the scoped
   component's state, including the scope notes the engine emits), print the full recommendation
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

**SENSE (read-only).** Resolve `<scripts>` the same way `/dashboard` does — prefer the host-exported
`${CLAUDE_PLUGIN_ROOT}/scripts`, else this command file's sibling `../scripts/` (never a bare
`scripts/`, which resolves against the target repo). Run
`python3 <scripts>/status.py --root . --recommend` — appending ` --scope <scope-spec>` when a scope
was peeled in step 0 — in the ctx sandbox when available and parse its JSON record. Under `--scope`
the engine restricts pending and debt to the component's Focus, certifies convergence only from a
final point that names that scope, and (a `path` that matched no files) returns a `scope-no-match`
blocker the mechanical-blockers step relays verbatim. If the engine cannot run (no `python3`,
missing script), print
`codmaster: recommendation engine unavailable — run planwright status and pick a direct dial (see README).`
and STOP — never substitute a prose decision table.

**Main loop** (cases 3 and 4). First print exactly one cost banner:
`codmaster: autonomous drive to the final point — sense → dispatch → re-sense, at depth 10, until convergence (max 12 steps); the converged terminal always earns one enforced invent burst (codinventor) unless run with safe, after which the harden is sharded (codshard explore) when the repo is shardable; then, once converged after growth, codmaster runs one qb intent-replan (/qb-plan auto) and executes its merged items before stopping. Note: invent may make rare, small committed edits to repo files, including MISSION.md.`
In `loop` mode print this first clause instead:
`codmaster: infinite drive — laps of sense → dispatch → re-sense at depth 10; each lap hardens → grows (codinventor) → deep-hardens the grown code per-component (codshard, when the repo is shardable) → on re-convergence runs a qb intent-replan (/qb-plan auto) and executes its merged items → resets (cold-start, keeps rejected.md) into the next; the drive ends only when interrupted, on a hard stop, or on a lap whose qb replan itself comes up dry (final convergence) — termination is decided only at the lap boundary, never mid-lap (max 12 steps per lap).`
In `safe` mode, do **not** strike-edit either growth banner above — print a dedicated safe banner instead (safe runs neither invention nor qb, so no growth/qb disclosure and no qb-dependent termination clause appear at all):
- `safe` without `loop`: `codmaster: drive to the final point — sense → dispatch → re-sense, at depth 10, until convergence (max 12 steps). safe: invention capability off — the loop stops at the first convergence; qb intent-replan does not run — to replan manually, run /qb-plan auto, then merge .qb/plan.md pending items into .planwright/plan.md and execute.`
- `safe loop`: `codmaster: infinite drive — laps of sense → dispatch → re-sense at depth 10; each lap runs harden-only (no growth, no qb) then resets (cold-start, keeps rejected.md) into the next, until interrupted, a hard stop, or a fully-dry lap (final convergence) — termination is decided only at the lap boundary, never mid-lap (max 12 steps per lap). safe: invention capability off — qb intent-replan does not run — to replan manually, run /qb-plan auto, then merge .qb/plan.md pending items into .planwright/plan.md and execute.`
In `parallel` mode (any banner), append this clause to the printed banner:
`parallel: each codshard dispatch fans out read-only recon readers (J at a time, else host-capped) — extra model calls bought for wall-clock; routing-only, never Evidence; on the host's native subagent (sequential where there is none). codmaster never auto-engages the optional external-agent CLI backend (it ships code to external providers) — opt into it explicitly with /codshard parallel external.`
In **scope** mode (any banner), append this clause to the printed banner:
`scope <X>: the whole drive — SENSE, every dispatch, and convergence — aims at one component; codshard and reset (whole-repo moves) never auto-route, so the harden stays a scoped codvisor and the post-growth harden is not sharded. (With parallel: it has no codshard dispatch to attach to, so it stays inert — run /codshard parallel directly for a sharded sweep.)`

Then stamp the run-activity beacon so the dashboard's reactor names this run: run
`python3 <scripts>/state.py activity start codmaster --root .` in the ctx sandbox when available
(same `<scripts>` as SENSE). The beacon is best-effort telemetry — if the script cannot run, skip
it and proceed; never block on it.

Also record the **lap-start ref** here — `git rev-parse HEAD` (best-effort) — the HEAD this lap
opens at. It is the `--since` anchor for the lap-close reconciliation in REPORT; in `loop` mode
re-record it at each new lap (the relap step below), and because the lap-opening `reset` moves
nothing in git the ref is stable across it.

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
     harden, never at an intermediate step, and (when `safe` is off) only after the qb intent-replan closing step (the named block below, at-most-once per lap — its flag bars re-running it on the re-convergence after its own `execute`) has run at this same boundary**: if the whole lap advanced HEAD zero times (every
     `commits_i` of this lap was 0, the growth burst and the qb replan's execute included; the lap-opening `reset` moves
     nothing in git — it only clears gitignored `.planwright/` tool-state — so it never masks a
     dry lap), the project has reached its **final convergence point** — STOP and report `no progress` (a fully-dry lap is the only
     honest "done" for an infinite drive: invent's must-generate mandate means a lap that grew
     and still moved nothing has nothing groundable left, and the lap's qb intent-replan came up dry too — qb's dryness, not codinventor's, now defines this final "done"; when that closing qb rung ran non-independently the drive still STOPs here, but the REPORT marks even this terminal unverified per the qb-rung downgrade below, since a non-independent dry may be a false zero). Otherwise the lap made progress (the growth burst, or qb's merged-and-executed seeds, moved HEAD), so
     relap: print the next lap's header `=== codmaster lap L ===`, dispatch planwright with
     `reset` as this step (typing `loop` is the consent for repeated cold starts; `reset` keeps
     `rejected.md`, so rejected work stays suppressed across laps), restart the step counter,
     re-arm the growth burst and the qb intent-replan, reset the qb audit-independence flag to
     independent, re-record the lap-start ref
     (`git rev-parse HEAD`), and continue — the next SENSE reads first contact and routes to a
     fresh harden sweep. **Under a scope, the lap-boundary relap does not reset** — `reset` is a
     whole-repo `.planwright` wipe the scope forbids (step 0, where codmaster never auto-routes the
     whole-repo moves), so a scoped `loop` drive instead re-senses the scoped component directly at
     the lap boundary (re-arm the growth burst and the qb intent-replan, reset the per-lap qb audit-independence flag to independent (the sticky drive-level marker does not re-arm), restart the step counter, re-record the lap-start ref, **no `reset` dispatch**),
     keeping sibling components' audit memory intact; only an **unscoped** loop relap dispatches
     `reset`. The infinite drive ends only on interruption or a hard stop (a blocker,
     a hard blocker, or a broad-verify failure — these stop it immediately at any step), or, at
     this lap boundary, a fully-dry lap (the final convergence point); the soft no-progress guard
     never stops a lap mid-flight.
   - otherwise, in `safe` mode or with the growth step already taken — the post-growth terminal.
     **When `safe` is off AND the qb intent-replan has not yet run this lap, run the qb closing step
     here first** (the named block below: guard → run `/qb-plan auto` → merge → execute → re-sense):
     if qb merged net-new items, executing them un-converges the plan, so the next SENSE resumes the
     main loop (still under the 12-step cap) rather than stopping; only when qb comes up dry (error /
     absent / zero net-new) is there nothing left to execute, so STOP the loop — the recorded final
     point is the terminal state. When the qb intent-replan **has already run this lap** — the
     re-convergence after its own `execute` — its at-most-once flag bars a second run, so this
     terminal is a plain STOP **— and if this lap's qb closing rung ran non-independently
     (`qb_audit_independent=false`), the REPORT downgrades this convergence exactly as it does the
     qb-dry terminal, since the same non-independent rung closed the lap either way**. In `safe` mode qb never runs — its gate is "codinventor already ran", which `safe`
     never satisfies — so STOP at once and print the growth recommendation and the exact line to
     paste (`/planwright:codinventor`, or the `/codinventor` alias), plus the qb hand-off line
     `safe: run /qb-plan auto, then merge .qb/plan.md pending items into .planwright/plan.md and
     execute.`, and the `reset_nudge` alternative when present.
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
   appended to its `args`, so it becomes e.g. `codshard parallel explore`. When a scope was peeled
   (step 0), append `<scope>` (the bare `path <X>` / `lib <X>` form) **after** the record's `args`
   for every dispatch, so `cycle`/`execute` stays the first token planwright dispatches on (e.g.
   `cycle 10 depth 10 explore path src/auth/`, `execute path src/auth/`,
   `cycle 10 depth 10 invent path src/auth/`); a scoped record never carries `codshard` or `reset`
   (the engine suppresses both whole-repo moves under `--scope`), so those dispatches never arise
   while scoped. Every dispatch runs
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
   `repo.shardable` is true **AND no scope was peeled in step 0** (a scoped drive never shards —
   codshard is a whole-repo move, so the post-growth harden stays a scoped `codvisor`),
   dispatch `codshard explore` **instead** — follow `commands/codshard.md`
   with `explore` (so `parallel` appends to *that*: `codshard parallel explore`), deep-hardening
   the freshly-grown code per-component, with a closing whole-repo round.
   This is the one place codmaster shapes the command rather than relaying it, so it is an
   **explained divergence**: print under the step header `note: post-growth — sharding the
   harden of the just-grown code (engine: codvisor; repo.shardable)`, and the parallel-codvisor
   nudge above does not fire (this step is now a `codshard` dispatch, so `parallel` has its
   target). The override is narrow: it fires **only** after the growth
   burst, **only** when the record command is `codvisor`, and **only** when `repo.shardable` is
   true, **and** only when the drive is unscoped — when the repo is not shardable (fewer than
   `SHARD_MIN_DIRS` partitionable dirs), or a `path`/`lib` scope is active, it does
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
   `no progress` — an honest stall report beats spinning on the same dispatch — **unless the fresh
   SENSE is *converged*, `safe` is off, and the qb intent-replan has not yet run this lap: then this
   guard does *not* stop the drive here, because the next terminal check (step 3) routes that
   growth-taken converged terminal to the qb intent-replan. The qb intent-replan must run once per lap
   before any convergence stop** (in a non-`safe` drive — the qb closing rung is the top of the
   escalation ladder, so it is spent before any non-`loop` convergence stop, exactly as the converged
   terminal already requires). The case this catches: a **0-commit growth burst** — an
   already-converged re-run where the enforced `codinventor` burst comes up dry and the fresh SENSE
   re-recommends `codinventor` (identical to the just-dispatched growth burst) — which must be allowed
   to advance to the qb intent-replan rather than be misread as "done". The guard fires at a converged
   repo *only* after a `codinventor` dispatch (SENSE is `codinventor` at convergence), so growth is
   always already taken when this exemption applies. **A genuine *non-converged* stall — the fresh
   SENSE still names a harden the 0-commit dispatch could not advance — is a real dead-end and stops
   normally even before qb; the deferral is only for the *converged* terminal that qb owns.** Once the
   qb intent-replan has run this lap (it came up dry, or its merged items were executed under the
   at-most-once flag), a subsequent no-progress match stops the bare drive normally; in `safe` (which
   never runs qb) the guard stops as before. **In a non-`safe` `loop` drive
   this guard does not stop the lap mid-flight** — a 0-commit harden must be allowed to advance to
   the guaranteed-to-generate growth burst rather than be misread as "done"; the 12-step cap is
   the mid-lap runaway backstop, and the no-progress verdict is instead evaluated once at the lap
   boundary (the terminal check above), where a lap that moved HEAD zero times across all its
   steps — through the post-growth codshard harden and the qb intent-replan's execute — is the
   final convergence point. **Under `safe loop`, where invention is disabled so no growth burst
   follows a 0-commit harden, the mid-flight suppression does not apply** — the guard stays active
   and stops a no-progress step normally (as outside `loop`), rather than spinning the same harden
   up to the 12-step cap before the lap boundary can end it.

**No discretionary stop — the stop set is closed.** codmaster has **no authority to end, pause, or
abort the drive on its own judgment**, in any mode; the stop reasons named above are the *whole* set,
and codmaster never adds one of its own. A stop is legitimate **only when some named mechanism
produced it** — a signal codmaster **receives**, never a verdict it **decides**: the engine record's
`blockers` array (the mechanical blocker stop); the dispatched run's own hard blocker or broad-verify
failure (its own stops, relayed verbatim); the no-progress predicate — HEAD unchanged **AND** the
fresh SENSE yields the identical recommendation — which stops only a **bare** (non-`loop`) run, and
in a non-`safe` drive never fires **at a converged terminal** while the qb intent-replan rung is still
pending (the rung must run once per lap before any convergence stop; a non-converged stall still
stops normally); the
**12-step-per-lap** runaway cap; the **converged terminal** (`converged at the final point`), which a
non-`loop` drive takes once the post-growth harden re-converges and the qb intent-replan rung is spent
for the lap (dry, or its net-new already merged-and-executed under the at-most-once flag), and which
in `safe` is the first convergence (safe runs neither growth nor qb); a genuine external
**interruption**; or — in `loop` — the **lap-boundary fully-dry lap** (every `commits_i` of the lap,
the growth burst and the qb replan's `execute` included, was 0), decided at the boundary *after* the
post-growth `codshard` harden and the qb intent-replan have both run. "The engine returned a blocker /
the dispatched run hard-stopped / the predicate matched / the plan converged with qb dry / the lap
came up fully dry" is an allowed stop; **"I judged it not worth continuing" is a forbidden one** —
asserting it is a spec violation, not a verdict. So codmaster never stops, and never aborts an
in-flight dispatch, for **cost**, token/compute budget, effort, or wall-clock; for **"marginal
value"**, **"diminishing returns"**, or **"low ROI"**; for a **"clean / natural / honest boundary"**
or a self-declared **"judgment checkpoint"**; for a tree that **"looks mature / already-hardened /
effectively converged"** (a *recorded* converged final point is the allowed stop, an *eyeballed* one
is not); for **"leads that stopped reproducing"**; or for any asserted **"nothing groundable left"**
that is not a *recorded* convergence or a *completed* fully-dry lap — none of these is in the set, and
a pause that does not relap **is** a stop. A maturing or "dry-looking" tree is **exactly** what the
enforced growth burst (`codinventor`'s must-generate mandate) and the qb intent-replan exist to push
past — so maturity is a reason to **finish** the lap, never to end it: **re-survey, do not quit.**

An **interruption counts only when it arrives from outside the drive** — an actual user message or
host cancellation (Ctrl-C) that codmaster *receives*; codmaster never *declares* an interruption on
its own, never pauses **"to check in"** or to **"await confirmation"**, and a self-narrated mid-lap
pause ("a clean place to stop", "awaiting your go-ahead") is a forbidden discretionary stop, not an
interruption. Absent a genuine external signal it can point to (not one it infers), codmaster may
stop only when one of the **named mechanisms above** fires — never at a self-chosen mid-lap point, and
never by treating a lap boundary as an interruption point.

**A dispatched sub-run runs to its own completion or its own hard stop.** Once a `codshard` sweep is
dispatched it must finish **all** shards **and** its closing whole-repo round before the next SENSE —
and the same holds for any dispatched `execute`/`cycle`. While such a sub-run is in flight — e.g. at
"Shard 2/3" — codmaster waits it out; it may stop the sub-run early **only** because that run itself
surfaced a hard blocker or a failing broad verify (a signal from *inside* the run), **never because
the orchestrator decided from the outside** that the remaining shards weren't worth it.

**At least one full lap must complete before codmaster stops of its own accord.** Because the stop set
is mechanical, no drive ends because codmaster *chose* to end it — and a healthy drive cannot close
before its lap does: in a default or `loop` drive that means through the post-growth `codshard` harden
and the qb intent-replan; in `safe`, through the harden to its first convergence (safe runs neither
growth nor qb). A mechanism may end a drive earlier — a hard stop (a `blockers` entry, a hard blocker,
or a broad-verify failure), the bare-run no-progress predicate, the 12-step cap, or a genuine external
interruption — but codmaster never manufactures one, and never ends a lap mid-flight on judgment.
There is no "stop early because it looks done."

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
composite dispatch — one step — and its header announces both halves up front. **Under a `path`/`lib`
scope this section never applies:** `reset` is a whole-repo `.planwright` wipe, so the engine never
emits it under `--scope` (a scoped invent-dry-drained point routes to a scoped `codvisor` re-survey
instead), and codmaster has no reset to relay.

**Invention capability.** Whether codmaster grows is decided by the `safe` flag, **not** by the
engine's `invent_class`:
- **default (case 4)**: invention is **enforced** — at every converged terminal the at-most-once
  growth burst dispatches `codinventor` regardless of the engine's `invent_class` (its invent-dry
  routing is advisory only). codmaster has growing authority by default; the cost banner's notice
  is the disclosure.
- **`safe` (case 3)**: do NOT dispatch the growth burst. `safe` means without invention
  capability — everything else (execute, codvisor, codshard, reset, and the engine's invent-dry
  routing) still dispatches; the growth recommendation is printed to paste instead.

**The qb intent-replan — the closing escalation rung.** Once the growth burst has been taken this
lap **and** the post-growth harden has re-converged — so this is a converged terminal reached with
the growth step already done, never the first pre-growth convergence — and **only when `safe` is
off**, codmaster runs one **qb intent-replan** as the top rung of the escalation ladder
(`execute → codvisor → codinventor → qb intent-replan → execute → done`). It is **at-most-once per
lap**, enforced exactly like the growth burst by an explicit "qb-replan taken this lap" flag (set
the moment this step runs, reset on relap), and gated on **"codinventor already ran this lap AND the
qb intent-replan was not yet taken this lap"**. The first conjunct makes `safe`, which never grows,
unable to ever reach it — the gate enforces the `safe` rule for free; the second bars a post-`execute`
re-convergence from re-running qb within the same lap (without it, the OK→execute→re-sense path of
step 5 would loop back into this terminal and dispatch `/qb-plan auto` again). The step:
1. **Availability guard.** Confirm qb is installed — i.e. the `/qb-plan auto` command is available
   to dispatch (its run-contract is to emit the single machine-detectable result line
   `QB_PLAN_AUTO_OK:` / `QB_PLAN_AUTO_ERROR:`, **matched by prefix** — a line *starting with*
   `QB_PLAN_AUTO_OK` or `QB_PLAN_AUTO_ERROR`, the trailing colon and any following detail tolerated,
   the same prefix rule as the `QB_PLAN_AUTO_WARN:` scan below — so the bare `QB_PLAN_AUTO_OK` /
   `QB_PLAN_AUTO_ERROR` references in the steps below all match this identical token). Judge
   availability **before** running, by whether the
   command exists — **not by whether a given run emits a line**. If qb is **absent** (the command is
   not installed at all), **skip qb** and fall through to today's terminal behavior (no qb step, no
   error). A qb that *is* installed, launches, but then produces no parseable line is **not** "absent":
   it ran and died, and is handled as the fail-closed no-result-line crash case in step 3 (downgraded),
   never as a clean skip.
2. **Run `/qb-plan auto`** under a step header `=== codmaster step i/12: qb-plan auto ===`, marking
   the qb-replan taken this lap (it writes only under `.qb/`, never source); wait for it to finish,
   and parse its single final result line. **Also scan qb's output for any line carrying the
   `QB_PLAN_AUTO_WARN:` prefix — the host-neutral, machine-detectable marker that qb's Step 3 audit
   ran in-session instead of via an independent subagent. Match the `QB_PLAN_AUTO_WARN:` *prefix*,
   never an exact full-line suffix: the wording after the colon is host-specific (Claude Code's
   `in-session fallback — audit not independently delegated` vs the subagent-isolation wording Cursor
   and Codex emit, e.g. `in-session audit — not subagent-isolated on this host`), so a literal
   full-line match would silently miss the WARN on exactly the hosts — Cursor and Codex — where
   in-session is the **every-run** norm, not a rare fallback, and trusting `audit=PASS` is most
   dangerous. The moment such a line is present, set this lap's `qb_audit_independent` flag `false`
   (it defaults to **independent** at lap start and re-arms with the other per-lap flags on relap) —
   set it here, on the WARN itself, **regardless of whether the result line is `QB_PLAN_AUTO_OK` or
   `QB_PLAN_AUTO_ERROR`**, so the downgrade also covers a WARN followed by an error (the in-session
   audit ran, then the export/validate failed); the flag governs how far to trust the result in
   step 3 and how the convergence is rendered in the REPORT. **Also raise the sticky drive-level
   marker `qb_audit_independent_drive` to non-independent here — unlike the per-lap flag it
   **never re-arms on relap** (only a fresh `/codmaster` invocation clears it), so a WARN-tainted
   *progress-making* lap whose merged growth moves HEAD and relaps instead of stopping still leaves a
   drive-level mark the final REPORT must disclose; it cannot be laundered into a clean drive-end
   "done" by a later independent lap. (This sticky marker matters in a `loop` drive, where relap
   resets the per-lap flag; in a bare single-lap drive the per-lap flag already covers the lone
   terminal, so the sticky raise is a harmless no-op there.) **Fail closed on observation.** The WARN
   scan is the *sole* trigger of this whole downgrade, so codmaster must read qb's **complete** output
   to run it. If it cannot reliably observe qb's full output — truncated, routed to a file or a
   context-mode sandbox, or otherwise unparsed — it **must treat the run as non-independent** (set
   both flags) rather than default to trust: an *unconfirmed-independent* qb run is downgraded exactly
   like an observed WARN. Only output codmaster actually saw, in full, and found WARN-free counts as
   an independent rung. This conservative default governs only the REPORT's **trust label** — never a
   stop or a dispatch decision (those stay signal-driven, per the closed stop-set's receive-don't-
   decide rule); an unconfirmable observation is just the **absence of a confirmed-independent
   signal**, so the honest default is to disclose non-independence, not to assert a clean done.
   **Why label-only and not a termination gate:** a non-independent qb *dryness* may be a false zero,
   but codmaster **cannot manufacture an independent qb verdict in-session** (the Task tool is
   unavailable — that is what the WARN means) and the closed stop-set forbids spinning, so refusing to
   stop would loop forever on the same false dry. Disclose-and-stop is therefore the honest floor: the
   irreducible residual coverage risk is handed to the operator via the recommend-independent-re-run
   nudge (run on a host where the Task tool works), not papered over by a gate codmaster has no
   independent means to satisfy. The independent per-lap codvisor/codinventor/codshard passes still
   re-survey the tree each lap, so only qb-unique intent coverage is exposed — exactly what the nudge
   asks the operator to confirm.**
3. On **`QB_PLAN_AUTO_OK`**, **merge** `.qb/plan.md`'s pending items into `.planwright/plan.md`:
   take its pending items, **dedup** against existing pending + `completed.md` + `rejected.md`
   (rejected persists across `reset`, so rejected intent items stay suppressed across laps — the
   linchpin that keeps an infinite drive honest), tag the merged items with qb provenance, and
   **re-validate** the merged `.planwright/plan.md` with planwright's own current validator
   (`lint-plan.py --strict`, whose `--strict` promotes the re-proposed-completed/rejected
   advisories to failures — exactly the dedup the merge needs), not qb's vendored copy.
   **The WARN downgrade distrusts qb's *dryness*, not its `audit=` verdict.**
   codmaster never gates the merge on qb's audit status at all: every merged item is independently
   re-validated above and verified per-item in step 4 **whatever qb reported** — `audit=PASS`,
   `PASS_WITH_WARNINGS`, or even `BLOCKED` (`QB_PLAN_AUTO_OK` only attests that the export validated,
   not that the audit passed) — so a non-independent audit verdict has no merge-gate to short-circuit
   and **must never be allowed one**. What a `QB_PLAN_AUTO_WARN` actually threatens is qb's
   **coverage**: a non-independent in-session audit by the plan's own author is exactly how a real
   gap is rubber-stamped — as a false "0 items" (a false dry) *or* as a non-empty result that is
   silently missing items it should have caught. The items qb did surface are independently re-gated
   above, but **the convergence they eventually reach is itself unverified**: the
   `qb_audit_independent=false` flag set in step 2 (whenever the WARN fired) taints **whichever convergence
   closes the lap**, the qb-dry STOP *and* the post-merge re-convergence alike — and the REPORT
   downgrades that converged stop accordingly (never rendered a clean done; it carries a
   recommend-an-independent-re-run nudge). (Do **not** re-run `/qb-plan auto` to chase independence —
   the WARN means the Task tool (or the qb-* subagents) was genuinely unavailable in that run, so a
   retry would only reproduce the same non-independent audit; the correct response is to downgrade
   trust, not an **in-lap** retry. This bars only re-dispatching qb *within this lap* to chase a
   cleaner verdict; the normal `loop` re-arm that re-runs `/qb-plan auto` on the **next** lap is a
   fresh attempt (independence re-evaluated from scratch), not the forbidden retry — and the sticky
   drive marker keeps any earlier non-independent lap honest regardless. (That next-lap re-arm is
   reachable only for a WARN-on-**progress** lap, which relaps; a WARN-on-**dry** lap is fully dry and
   STOPs at the boundary, so for it the response is purely downgrade-and-disclose — there is no next
   lap, and the operator nudge is the only remaining path to an independent re-check.)
4. **Run `execute`** on the merged seeds (implement + verify each), and **record its verified-commit
   count as this step's `commits_i`**, exactly as the main dispatch does (step 4 above, "record its
   verified-commit count as `commits_i`") — so a lap whose only progress is qb's merged-and-executed
   seeds is counted by the lap-boundary no-progress check (which already includes "the qb replan's
   execute") rather than misread as a fully-dry lap and falsely terminated. Merging pending items
   un-converges the plan, so the next SENSE would route to `execute` anyway; making it an explicit
   step guarantees it rather than leaving it emergent.
5. **Re-sense** and continue under the normal main loop.
On `QB_PLAN_AUTO_ERROR`, qb absent, **zero net-new items after dedup**, or qb leaving **no parseable
result line** (it ran — perhaps even printed the WARN — then crashed or was cut off before any
`QB_PLAN_AUTO_*` line), treat it as **qb dry**: nothing to execute, fall through to the existing
terminal/stop path — so a fully-dry lap is one whose qb replan itself came up dry. **The
no-result-line case is itself fail-closed:** a crashed or cut-off qb yields no confirmed, complete
result, so set `qb_audit_independent` false for it (even with no observed WARN) — a hard qb failure
must never be laundered into a clean "frontier exhausted" done; its dryness is unverified. (A clean
`qb absent` is different — there qb never ran, so there is no audit to distrust and the flag stays
independent.) That terminal/stop path is unchanged here: a bare
drive STOPs at the converged terminal, and in `loop` a WARN-on-dry qb is still only a 0-commit step
that ends the drive solely at a lap boundary whose **whole** lap was fully dry — it never stops a
progress-making lap mid-flight. What the WARN adds is not a new stop but a **downgrade of the
resulting convergence**: when the WARN fired (`qb_audit_independent=false`, set in step 2 — including
the WARN+`QB_PLAN_AUTO_ERROR` case, where the in-session audit ran before the export/validate failed,
and excluding a clean `qb absent` where no audit ran at all), the REPORT renders that
converged stop non-independent / unverified rather than a clean done (a non-independent audit is
exactly how a real gap is rubber-stamped as "0 items", so this "dry" may be a false zero, not true
frontier exhaustion), while codmaster still **must not spin** — it has no independent way to mine
more through a qb whose Task tool is unavailable. The qb run and its follow-on `execute` each count
against the 12-step/lap cap, and qb re-arms on relap alongside the growth burst.

**REPORT** (after the loop ends — terminal, cap, or early stop; in `loop` mode also at the end of
every lap, just before its reset step). First **reconcile the lap's commits** — the mechanical
safety net behind SKILL.md's completion-accounting invariant: a step that committed a fix inline
without landing it (a `codshard`/`codinventor`/`execute` commit not recorded) would otherwise
silently miss `completed.md`, the only file the dashboard reads. Run
`python3 <scripts>/lifecycle.py reconcile-sweep --since <lap-start ref> --mode repair --root .planwright`
(same `<scripts>` as SENSE) — it records every non-merge, non-release commit since this lap's
lap-start ref that `completed.md` does not already carry, idempotently and git-verified. This is
best-effort bookkeeping that runs at **every** lap close (in `loop` before each lap's reset,
otherwise at the drive's end) — **never block on it, and it is not a stop or a judgment** (it
records, it never decides); per-item `land` stays the primary path, the sweep only catches drift.
Then remove the run-activity
beacon: `python3 <scripts>/state.py activity stop --root .` (best-effort, never block — this
applies to every way the loop ends, including hard stops). Then print a short cumulative
summary: steps taken (out of 12 for the lap), the per-step commands and verified-commit counts in
order (e.g. `codvisor 3 → execute 2 → codinventor 1 → codshard 0 → qb-plan 1 → execute 2` ), whether the growth burst
ran, whether the qb intent-replan ran (and whether it merged net-new items, **and whether qb's audit was independent — surface the `QB_PLAN_AUTO_WARN` trust downgrade when it fired**), whether `parallel` was active and whether a `codshard` dispatch consumed it (if `parallel`
was active but codshard was never dispatched, append `parallel had no effect this run — use
/codshard parallel directly`), the final-point state from the last SENSE relayed verbatim, and
the stop reason (`converged
at the final point`, `hard blocker`, `broad-verify failed`, `blockers`, `no progress`,
`step cap`, or — in `loop` mode — `interrupted`; in `loop`, `no progress` is reached only at a
lap boundary — a fully-dry lap — never mid-lap). In `loop` mode also print this summary at the
end of every lap (just before its reset step), and a final overall line when the drive ends:
laps completed, total steps, total verified commits, **and — when the sticky
`qb_audit_independent_drive` is non-independent — a drive-level disclosure that one or more laps
closed a non-independent qb replan whose merged growth is now baked into the converged tree, its
coverage unverified (a non-independent audit can silently miss items, and planwright's per-item
verify cannot check items it was never handed); recommend an independent `/qb-plan auto` re-run
before trusting the drive's "done". This sticky marker never re-arms on relap, so a WARN-tainted
progress-making lap cannot be laundered into a clean drive-end done by a later independent lap.**
**A done terminal — any stop that would otherwise print the clean-done steady-state recommendation —
counts as *clean* only when this lap's qb closing rung was independent.** That set is every
`converged at the final point` (the bare drive's terminal and the post-merge re-convergence) and
every `no progress` stall: both `loop`'s fully-dry-lap final point **and a bare drive's post-qb
stall** (the merged items committed nothing, so HEAD is unchanged and re-sense repeats the
recommendation). (In `safe`, no qb rung runs at all, so the flag stays at its independent default and
every `safe` terminal is clean — there is no audit to distrust.) On a clean such stop, also print the engine's steady-state recommendation as
the suggested next step in both spellings (e.g. `next: /codinventor — <why>` and
`or just run /codmaster again`), plus the `reset_nudge` when present. **When instead
`qb_audit_independent=false` (a `QB_PLAN_AUTO_WARN` closed the lap), that 'done' is not clean. The
downgrade follows the *flag*, not a stop-reason string — so it fires at every done terminal in that
set, whether the reason printed is `converged at the final point` or `no progress`, loop or bare.
Keep the emitted stop reason unchanged (codmaster adds no stop reason of its own) but qualify it
`(qb closing audit non-independent — unverified)`, and in place of the clean-done steady-state
recommendation print a one-line nudge to confirm with an independent `/qb-plan auto` re-run on a
host/session where the Task tool (and the qb-* subagents) are available before trusting "done". A
stop that already signals incompleteness and prints **no** steady-state recommendation — `step cap`,
or a hard `blockers`/`hard blocker`/`broad-verify failed` — claims no 'done', so it takes no
qualifier; the always-printed summary line above ('whether qb's audit was independent') still carries
the `QB_PLAN_AUTO_WARN` fact.**

Print nothing of your own except the Usage line (cases 1 and 3), the advise report (case 2), the
cost banner (including the parallel disclosure clause), the per-step headers and one-line whys,
the safe-mode growth recommendation, the parallel nudge line, and the cumulative report; each
dispatched command prints its own output, which stands as-is.
