---
description: Run planwright in an alternating explore → invent → explore rhythm. Each outer cycle runs three planwright phases back-to-back (cycle 3 depth 10 explore, then cycle 3 depth 10 invent, then cycle 3 depth 10 explore); with no arguments it runs 10 outer cycles, and a negative count runs forever. Use it to grow net-new, seam-bound capability (the invent phase) and immediately harden it (the explore phases) on repeat.
argument-hint: "[N] | <N> (negative = infinite) | (empty = 10 outer cycles)"
---

You are dispatching the **planwright** skill on behalf of the `/codcycle` helper command.
Unlike `/codvisor` and `/codinventor` — thin aliases that invoke planwright **once** — `/codcycle`
**orchestrates** planwright across several invocations: per *outer cycle* it runs three planwright
phases back-to-back. Do **not** re-implement any planwright logic here — each phase is an ordinary
planwright cycle run, and planwright owns all planning/execute/cycle behaviour, the maturity ladder,
and the explore/invent escalation ladder. On Claude Code, each phase is the Skill tool invocation
`planwright:planwright` with the phase's argument string; on other hosts, load
`skills/planwright/SKILL.md` (or use the host's native skill invocation) once per phase with the same
argument string.

The rhythm is **harden → grow → harden**: an `explore` phase first (cold-frontier sweep + expand over
the current tree), then an `invent` phase (propose net-new, seam-bound capability), then an `explore`
phase again (immediately harden whatever invent just landed). One pass through those three phases is a
single **codcycle**. Each phase is fixed at `cycle 3 depth 10` (three planwright rounds at maximum
analysis depth), so one outer cycle is ≈9 planwright cycles.

Raw arguments: `$ARGUMENTS`

Resolve them in this order:

0. **Peel the scope first.** If `$ARGUMENTS` contains a `path <X>` or `lib <X>` scope (the keyword
   plus its single following token, appearing anywhere), lift that pair out as `<scope>` and let
   `<rest>` be the remaining tokens. Otherwise `<scope>` is empty and `<rest>` is all of `$ARGUMENTS`.
   `<scope>` is appended **after** each phase's mode so the subcommand (`cycle`) stays the first token
   planwright dispatches on — never let `path`/`lib` lead. Omit the trailing `<scope>` when empty.

1. **`<rest>` empty**: run **10 outer cycles** (the default).
2. **`<rest>` is a single integer `N`** (nothing else): run `N` outer cycles. `N` may be **negative**,
   which runs **forever** (until a stop condition fires or the user interrupts). `N` must be non-zero.
3. **`<rest>` is `help` / `--help` / `-h` / `?`**: print
   `Usage: /codcycle [N]   (N != 0; negative = infinite; default 10). Each outer cycle = explore→invent→explore, cycle 3 depth 10 each.`
   and STOP — do not run anything.
4. **Anything else** (including `N == 0` or a non-integer): print that same `Usage:` line and STOP.

For cases 1 and 2, **first print exactly one cost-banner line** so this heavy run is never silent (it
also doubles as the `invent` awareness notice — the invent phase may make rare, small, committed edits
to repo files, including `MISSION.md`):
`codcycle: max-intensity alternating sweep — <N or ∞> outer cycle(s), each running explore → invent → explore as three back-to-back planwright runs (cycle 3 depth 10 each, ≈9 planwright cycles per outer cycle). Note: the invent phase may make rare, small committed edits to repo files, including MISSION.md.`

Then run the loop. For each outer cycle `i` (from 1 to `N`, or unbounded when `N` is negative):

- Print a header line `=== codcycle i/N ===` (use `i/∞` when `N` is negative).
- **Phase A (harden):** invoke planwright with `cycle 3 depth 10 explore <scope>`. Wait for it to finish.
- **Phase B (grow):** invoke planwright with `cycle 3 depth 10 invent <scope>`. Wait for it to finish.
- **Phase C (harden):** invoke planwright with `cycle 3 depth 10 explore <scope>`. Wait for it to finish.

Between and after phases, honour planwright's own stop conditions — do not paper over them:

- If any phase stops on a **hard blocker** (an item needing an unresolved design decision or undeclared
  surfaces) or a **failing broad final verification**, STOP the whole codcycle loop immediately and
  report — do not start the next phase or outer cycle on a broken tree.
- If a **full outer cycle produces no new committed items across all three phases** (explore dry, invent
  reached a genuine no-groundable-seam empty, explore dry), the project is at a stable meta-final-point —
  STOP and report it rather than spinning further (this is the honest convergence point of the rhythm).

After the loop (or an early stop), print a short cumulative summary: outer cycles completed (out of `N`,
or `∞`), total items implemented across all phases, and the stop reason.

Print nothing of your own except the cost banner (cases 1–2), the per-outer-cycle headers, and the
final summary; each planwright phase prints its own per-cycle output, which stands as-is.
