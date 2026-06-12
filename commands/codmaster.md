---
description: The front door. Senses the repo's planning state with the read-only coach engine (status.py --recommend — the same truth table the dashboard's Commands view renders), then dispatches exactly ONE recommended command at maximum depth (10) and reports — re-deciding from fresh state on every invocation instead of precomputing a chain. By default codmaster has full autonomy, growing included — when the tree is converged it dispatches codinventor (the banner discloses invent's rare, dwell-gated committed MISSION.md edits), and at the invent-dry point (deepest_tier invent — nothing groundable left to invent) it decides the cold-start reset itself, but only when really necessary — the point must be unseeded and the cold frontier shown drained; otherwise it re-surveys or hardens instead — and follows with a fresh harden sweep. `advise` prints the recommendation and stops; `safe` runs the same loop without invention capability (invent-class work is printed to paste, never dispatched).
argument-hint: "advise | safe | (empty = sense, decide, dispatch the one right command)"
---

You are dispatching on behalf of the `/codmaster` helper command. Like `/codcycle` and
`/codshard`, this is an **orchestration** command — but the thinnest one: it owns **no decision
logic and no planning logic**. The decision table lives in the tested engine
`status.py --recommend` (the same coach truth table the dashboard renders, cross-pinned via
`tests/fixtures/coach-table.json`), and all planning/execute/cycle behaviour belongs to planwright.
Do **not** re-implement either: never re-derive the recommendation in prose, and never improvise
when the engine is unavailable. codmaster only senses, relays, dispatches, and reports.

Raw arguments: `$ARGUMENTS`

Resolve them in this order:

1. **`help` / `--help` / `-h` / `?`**: print
   `Usage: /codmaster [advise|safe]   (empty = sense the repo and dispatch the one right command at depth 10; advise = print the recommendation only, dispatch nothing; safe = same loop without invention capability — invent-class work is printed to paste, never dispatched). One dispatch per invocation; run it again to take the next step.`
   and STOP — do not run anything.
2. **`advise`**: run SENSE below, print the full recommendation report (command + args, why, the
   evidence chips, every note, every blocker verbatim, the invent-class notice when set, and the
   reset nudge when present), and STOP — dispatch nothing.
3. **`safe`**: run the main flow below with **invention capability off** — identical in every way
   except step 5's invent-class handling.
4. **empty**: run the main flow below.
5. **Anything else**: print that same `Usage:` line and STOP.

**SENSE (read-only).** Resolve `<scripts>` per planwright's **Procedure → Bundled scripts** rule
(the skill base directory's `../../scripts/`). Run
`python3 <scripts>/status.py --root . --recommend` in the ctx sandbox when available and parse its
JSON record. If the engine cannot run (no `python3`, missing script), print
`codmaster: recommendation engine unavailable — run planwright status and pick a direct dial (see README).`
and STOP — never substitute a prose decision table.

**Main flow** (cases 3 and 4):

1. **Blockers are mechanical.** If the record's `blockers` array is non-empty, print each entry
   verbatim and STOP — no judgment call, no severity triage. (Doctor findings are read-only
   sensing — codmaster never runs `doctor --fix`; its report may *suggest* `planwright doctor --fix`.)
2. **Print exactly one banner** before any dispatch:
   `codmaster: dispatching <command> <args> — <why> (coach: <base.key>) [evidence: <chips>]`
   appending each `notes` entry on its own line (e.g. the repo-size override routing harden work to
   codshard, or the drain-first rule shadowing the coach's codcycle row — a divergence from the
   dashboard coach is always explained, never silent). When the dispatch is `execute`, the banner
   also names the current branch and the pending item titles. When the dispatch is invent-class
   (`codinventor`), the banner MUST include the awareness notice verbatim:
   `Note: invent may make rare, small committed edits to repo files, including MISSION.md.`
3. **Invent-class handling.** When the record says `invent_class: true`:
   - **default (case 4)**: dispatch it — codmaster has growing authority by default; the banner
     notice above is the disclosure.
   - **`safe` (case 3)**: do NOT dispatch. Print the recommendation, the exact line to paste
     (`/planwright:codinventor`, or the `/codinventor` alias), and the `reset_nudge` alternative
     when present, then STOP. `safe` means without invention capability — everything else
     (execute, codvisor, codshard, reset) still dispatches.
4. **The reset decision — only when really necessary** (shown, not assumed; the engine's
   `_reset_necessity` rule). The record says `reset` only when the invent-dry point is unseeded
   AND the cold frontier is shown drained; a seed-scoped point routes to a re-survey and an
   undrained (or unknown) frontier routes to a harden sweep instead, so audit memory is never
   wiped while a non-destructive move remains. When the record's `command` IS `reset`, dispatch
   planwright with `reset` (the cold-start wipe keeps `rejected.md`), then dispatch the record's
   `follow_up` command as the fresh harden sweep. This pair is the one composite dispatch — the
   banner announces both halves up front.
5. **Dispatch exactly one command** (the composite reset pair counts as one), then wait for it to
   finish. On Claude Code, `planwright`/`execute`/`codvisor`/`codinventor`/`reset` dispatches are
   the Skill tool invocation `planwright:planwright` with the record's `args` string
   (codvisor/codinventor resolve to their flagship `cycle 10 depth 10 explore` / `invent` forms);
   a `codshard` dispatch follows `commands/codshard.md` with the record's `args` (default
   `explore`). Every dispatch runs at maximum depth — depth 10 — by construction of those argument
   strings; codmaster takes no depth knob. On other hosts, load `skills/planwright/SKILL.md` with
   the same argument string (and the codshard recipe from its host-adapter paragraph).
6. **One dispatch per invocation is absolute.** Never chain a second planning command — state
   changes under every dispatch, so the honest next decision needs fresh sensing. Run `/codmaster`
   again for the next step.

**REPORT** (after the dispatch finishes):

- Relay the dispatched command's own summary and stop reason **verbatim** — `completed`,
  `final point reached`, `deep final point reached`, `hard blocker`, `broad-verify failed`, plan
  capacity, or a dirty-tree stop. Never soften or reinterpret it.
- On any non-clean stop (hard blocker, broad-verify failed, dirty tree), suppress the
  suggested-next entirely except the remediation for that stop.
- On a clean finish, re-run SENSE once and print the fresh recommendation as the suggested next
  step, in both spellings: the concrete direct dial (e.g. `next: /codvisor — <why>`) and
  `or just run /codmaster again`. This re-sense is advisory only — it never triggers a second
  dispatch.

Print nothing of your own except the Usage line (case 1/5), the advise report (case 2), the
banner, the safe-mode recommendation (step 3), and the final report; the dispatched command prints
its own output, which stands as-is.
