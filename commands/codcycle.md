---
description: Run planwright in an alternating explore → invent rhythm. Each outer cycle runs two planwright phases back-to-back (cycle 3 depth 10 explore, then cycle 3 depth 10 invent under a rotating framing seed), and a single final explore phase closes the whole run. Successive outer cycles rotate the invent framing through the fixed catalog (power-user → integration → onboarding → reliability → automation) so each cycle surveys a genuinely different region instead of re-deriving the same comprehensive ranking; the meta-final-point is declared only when a full framing rotation comes up dry. With no arguments it runs 10 outer cycles, and a negative count runs forever. Use it to harden the tree then grow net-new, seam-bound capability (the invent phase) on repeat, with one closing explore to harden whatever the last invent landed.
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
`explore` phases (per-cycle and final) are fixed at `cycle 3 depth 10`, and the `invent` phase is fixed
at `cycle 3 depth 10` too; what changes across outer cycles is the invent survey's **framing** — the
generative vantage it reasons under, rotated through a fixed catalog (see **Framing rotation** below).
Each round is at maximum analysis depth (`depth 10`), so one outer cycle is ≈6 planwright cycles plus the
final explore's 3.

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
   `Usage: /codcycle [N]   (N != 0; negative = infinite; default 10). Each outer cycle = explore (cycle 3 depth 10) → invent (cycle 3 depth 10) under a rotating framing seed; the meta-final-point needs a full framing rotation to come up dry; one final explore closes the whole run.`
   and STOP — do not run anything.
4. **Anything else** (including `N == 0` or a non-integer): print that same `Usage:` line and STOP.

For cases 1 and 2, **first print exactly one cost-banner line** so this heavy run is never silent (it
also doubles as the `invent` awareness notice — the invent phase may make rare, small, committed edits
to repo files, including `MISSION.md`):
`codcycle: max-intensity framing-rotated sweep — <N or ∞> outer cycle(s), each running explore (cycle 3 depth 10) → invent (cycle 3 depth 10) under a rotating framing seed that sweeps the vantage catalog (power-user → integration → onboarding → reliability → automation), then one final explore phase to close the run. Note: the invent phase may make rare, small committed edits to repo files, including MISSION.md.`

Then run the loop. For each outer cycle `i` (from 1 to `N`, or unbounded when `N` is negative):

- Print a header line `=== codcycle i/N ===` (use `i/∞` when `N` is negative).
- **Phase A (harden):** invoke planwright with `cycle 3 depth 10 explore <scope>`. Wait for it to finish.
- **Phase B (grow):** invoke planwright with `cycle 3 depth 10 invent seed <i> <scope>` — a fixed 3-cycle
  invent burst under the **framing seed `<i>`** (the outer-cycle index), which rotates the invent
  survey's vantage (see **Framing rotation** below). Wait for it to finish.
- Record `commits_i` = the number of **verified (committed) items** produced this outer cycle across
  Phase A + Phase B (planwright reports the committed SHAs per phase; count them). This drives the
  meta-final-point's dry-rotation counter.

**Framing rotation.** The `invent` phase's cycle *count* is **not** adaptive — cycle count is the wrong
lever, because invent is **seam-bound**: re-running it more times only re-surveys the same seam set, so a
drying project gains nothing from extra cycles. What rotates instead is the invent survey's **framing** —
the generative vantage it reasons under. Outer cycle `i` passes `seed <i>` to its invent phase;
planwright's builder maps that seed to one key in the fixed catalog by a clean modulo rotation, so
successive outer cycles sweep every vantage in order with no repeat or gap before wrapping:

`power-user → integration → onboarding → reliability → automation` (then wraps to power-user).

Why rotate the framing rather than the cycle count: a **seeded** invent phase deliberately *focuses* one
vantage and does **not** self-rotate. (An *unseeded* invent already auto-rotates the catalog internally,
but only reactively — on an empty survey — and a productive comprehensive pass that finds any candidate
never rotates at all, so one high-value vantage can starve the others.) Driving the rotation from
codcycle forces each outer cycle into a genuinely different region, so the run surveys all vantages with
per-vantage depth instead of re-deriving the same comprehensive ranking every cycle. Each round still
runs at maximum depth (`depth 10`); the framing only scopes *which* net-new candidates are generated,
never the grounding bar — every item still clears planwright's Stage 10 gate and carries a runnable
verification. The catalog (5 vantages, fixed order) is the only rotation knob; depth, the explore counts,
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
- A single **dry outer cycle** (0 new committed items across both phases) is **not** convergence — under
  a focused framing it only means *that vantage* is dry. Keep rotating. Declare the stable
  **meta-final-point** only when a **full framing rotation comes up dry** — i.e. `5` (the catalog length)
  **consecutive** outer cycles each produce 0 committed items, so every vantage surveyed in the last
  sweep is dry. Track a `dry_streak`: increment it on a 0-commit outer cycle, reset it to 0 on any
  committed item; when it reaches 5, STOP the outer loop and report the meta-final-point (this is the
  honest, breadth-earned convergence point of the rhythm). The tree is healthy, so the **final explore
  still runs once** afterward as the closing harden. (On a finite `N` shorter than a full rotation the
  loop may end first; that is an `N`-budget stop, not a meta-final-point.)

After the loop and the final explore (or an early stop), print a short cumulative summary: outer cycles
completed (out of `N`, or `∞`), whether the final explore ran, total items implemented across all phases,
the **per-cycle verified-commit counts and the framing each cycle surveyed** (e.g.
`commits 2 → 0 → 0 across framings power-user → integration → onboarding`), and the stop reason
(`meta-final-point — full framing rotation dry`, `N-budget`, `hard blocker`, or `broad-verify failed`).

Print nothing of your own except the cost banner (cases 1–2), the per-outer-cycle headers, the final
explore header, and the final summary; each planwright phase prints its own per-cycle output, which
stands as-is.
