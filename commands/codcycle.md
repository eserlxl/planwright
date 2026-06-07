---
description: Run planwright in an alternating explore → invent rhythm. Each outer cycle runs two planwright phases back-to-back (cycle 3 depth 10 explore, then an adaptive cycle 3..12 depth 10 invent), and a single final explore phase closes the whole run. The invent phase's cycle count is adaptive — it ramps from the base 3 up to 4x (12) when the verified-commit count declines between outer cycles, and relaxes back toward the base as commits recover. With no arguments it runs 10 outer cycles, and a negative count runs forever. Use it to harden the tree then grow net-new, seam-bound capability (the invent phase) on repeat, with one closing explore to harden whatever the last invent landed.
argument-hint: "[N] | <N> (negative = infinite) | (empty = 10 outer cycles)"
---

You are dispatching the **planwright** skill on behalf of the `/codcycle` helper command.
Unlike `/codvisor` and `/codinventor` — thin aliases that invoke planwright **once** — `/codcycle`
**orchestrates** planwright across several invocations: per *outer cycle* it runs two planwright
phases back-to-back, and closes the whole run with a single final explore phase. Do **not** re-implement
any planwright logic here — each phase is an ordinary planwright cycle run, and planwright owns all
planning/execute/cycle behaviour, the maturity ladder, and the explore/invent escalation ladder. On
Claude Code, each phase is the Skill tool invocation `planwright:planwright` with the phase's argument
string; on other hosts, load `skills/planwright/SKILL.md` (or use the host's native skill invocation)
once per phase with the same argument string.

The rhythm is **harden → grow** per outer cycle: an `explore` phase first (cold-frontier sweep + expand
over the current tree), then an `invent` phase (propose net-new, seam-bound capability). One pass through
those two phases is a single **codcycle**. After the outer loop ends, a **single final `explore` phase**
closes the whole run — hardening whatever the last invent landed and re-converging the tree. The two
`explore` phases (per-cycle and final) are fixed at `cycle 3 depth 10`; the `invent` phase's cycle count
is **adaptive** between `cycle 3` and `cycle 12 depth 10` (see **Adaptive invent cycle count** below).
Each round is at maximum analysis depth (`depth 10`), so one outer cycle is ≈`3 + invent_n` planwright
cycles (≈6 at the base invent count, up to ≈15 at the 4× cap) plus the final explore's 3.

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
   `Usage: /codcycle [N]   (N != 0; negative = infinite; default 10). Each outer cycle = explore (cycle 3 depth 10) → invent (adaptive cycle 3..12 depth 10); one final explore closes the whole run.`
   and STOP — do not run anything.
4. **Anything else** (including `N == 0` or a non-integer): print that same `Usage:` line and STOP.

For cases 1 and 2, **first print exactly one cost-banner line** so this heavy run is never silent (it
also doubles as the `invent` awareness notice — the invent phase may make rare, small, committed edits
to repo files, including `MISSION.md`):
`codcycle: max-intensity adaptive sweep — <N or ∞> outer cycle(s), each running explore (cycle 3 depth 10) → invent (adaptive cycle 3..12 depth 10, ramping up as verified commits decline between cycles), then one final explore phase to close the run. Note: the invent phase may make rare, small committed edits to repo files, including MISSION.md.`

Then run the loop. For each outer cycle `i` (from 1 to `N`, or unbounded when `N` is negative):

- Print a header line `=== codcycle i/N ===` (use `i/∞` when `N` is negative).
- **Phase A (harden):** invoke planwright with `cycle 3 depth 10 explore <scope>`. Wait for it to finish.
- **Phase B (grow):** invoke planwright with `cycle <invent_n> depth 10 invent <scope>`, where `invent_n`
  is the **adaptive** invent cycle count (see **Adaptive invent cycle count** below; the first outer cycle
  uses the base, so Phase B of cycle 1 is `cycle 3 depth 10 invent`). Wait for it to finish.
- Record `commits_i` = the number of **verified (committed) items** produced this outer cycle across
  Phase A + Phase B (planwright reports the committed SHAs per phase; count them). This feeds the next
  cycle's `invent_n`.

**Adaptive invent cycle count.** The `explore` phases stay fixed at `cycle 3 depth 10`, but the `invent`
phase's cycle count **adapts** to how much net-new work the run is still landing — a drying project gets
more invent effort before it converges, and a productive one is not over-spent. Keep an `invent_n`
initialised to the base **3** and capped at **4× the base = 12**. The adjustment is made **after** each
outer cycle completes (once `commits_i` is known) and applied to the **next** cycle's Phase B — you
cannot know a cycle's commit count before running it, so the controller always steers off the most recent
*completed* cycle:

- **Growth declining** — `commits_i < commits_{i-1}` (this cycle landed fewer verified commits than the
  previous one): the well is drying, so dig harder next time — `invent_n = min(12, invent_n + 3)` (the
  ramp 3 → 6 → 9 → 12, i.e. 1× → 4× of the base).
- **Growth acceptable / recovered** — `commits_i ≥ commits_{i-1}` (the commit count held or rose to an
  acceptable level): relax back toward the baseline — `invent_n = max(3, invent_n − 3)`.
- Cycles **1 and 2 run at the base** `invent_n = 3` (cycle 1 has no prior, and after cycle 1 only one
  commit count exists — a trend needs two). The first ramp can therefore land on **cycle 3** at the
  earliest, once `commits_2` and `commits_1` can be compared.

So a sustained decline ramps Phase B from `cycle 3 depth 10 invent` up to `cycle 12 depth 10 invent` (the
4× cap, never beyond), and a recovery walks it back down to the base. The base (3), cap (12 = 4×), and
step (3) are fixed; only `invent_n` moves. This is the only adaptive knob — depth, the explore counts,
and the final explore are unaffected.

After the outer loop ends — whether it completed `N` cycles, was interrupted, or stopped at the stable
meta-final-point (but **not** when it stopped on a broken tree, see below) — run the closing phase
**exactly once**:

- Print a header line `=== codcycle final explore ===`.
- **Final phase (closing harden):** invoke planwright with `cycle 3 depth 10 explore <scope>`. Wait for
  it to finish. This is the single final explore that ends the whole run; it hardens whatever the last
  invent landed (and, when the loop already converged, simply confirms the stable meta-final-point).

Between and after phases, honour planwright's own stop conditions — do not paper over them:

- If any phase stops on a **hard blocker** (an item needing an unresolved design decision or undeclared
  surfaces) or a **failing broad final verification**, STOP the whole codcycle loop immediately and
  report — do not start the next phase, the next outer cycle, **or the final explore** on a broken tree.
- If a **full outer cycle produces no new committed items across both phases** (explore dry, and invent
  reached a genuine no-groundable-seam empty), the project is at a stable meta-final-point — STOP the
  outer loop and report it rather than spinning further (this is the honest convergence point of the
  rhythm). The tree is healthy, so the **final explore still runs once** afterward as the closing harden.

After the loop and the final explore (or an early stop), print a short cumulative summary: outer cycles
completed (out of `N`, or `∞`), whether the final explore ran, total items implemented across all phases,
the **per-cycle verified-commit counts and the `invent_n` trajectory** they drove (e.g.
`commits 4 → 2 → 3` drove `invent_n 3 → 6 → 3`), and the stop reason.

Print nothing of your own except the cost banner (cases 1–2), the per-outer-cycle headers, the final
explore header, and the final summary; each planwright phase prints its own per-cycle output, which
stands as-is.
