---
description: Shorthand for the planwright skill with the invent escalation. Forwards its arguments to planwright; with no arguments it runs the flagship inventor sweep (cycle 10 depth 10 invent). Use it when you want planwright to not only complete latent capability but also propose net-new, seam-bound features once the expand tier is dry.
argument-hint: "[planwright args] | <N> [D] | (empty = cycle 10 depth 10 invent)"
---

You are dispatching the **planwright** skill on behalf of the `/codinventor` helper command.
Do **not** re-implement any planwright logic here — resolve the arguments below, then invoke
the planwright skill (via the Skill tool, skill `planwright:planwright`) with the resolved
argument string, and let the skill do everything else (it owns all planning/execute/cycle
behaviour, the maturity ladder, and the explore/invent escalation ladder).

`codinventor` is the `invent` twin of `/codvisor`: same structure, same passthrough — it only
defaults to the **invent** flag instead of **explore**, so the escalation ladder is permitted to
reach the net-new, seam-bound **invent** tier (a bounded burst) after the expand tier is dry.

Raw arguments: `$ARGUMENTS`

Resolve them in this order:

0. **Peel the scope first.** If `$ARGUMENTS` contains a `path <X>` or `lib <X>` scope (the keyword
   plus its single following token, appearing anywhere — leading or trailing), lift that pair out as
   `<scope>` and let `<rest>` be the remaining tokens. Otherwise `<scope>` is empty and `<rest>` is all
   of `$ARGUMENTS`. Classify `<rest>` with the cases below to build a base command, then **append
   `<scope>`** to it (after a space) so the subcommand (`cycle` / `execute` / …) stays the first token
   planwright dispatches on — never let `path`/`lib` lead. With no scope this is exactly today's
   behaviour; omit the trailing `<scope>` wherever it is empty.

1. **`<rest>` empty**: the flagship "inventor" run. First print exactly one
   cost-banner line so the heavy run is never silent (it also doubles as the `invent` awareness notice —
   invent may make rare, small, committed edits to repo files, including `MISSION.yaml`):
   `codinventor: max-intensity inventor run — up to 10 plan→execute rounds at depth 10 with the invent escalation ladder (cold-frontier → expand → net-new invent burst). Note: invent may make rare, small committed edits to repo files, including MISSION.yaml.`
   Then invoke planwright with: `cycle 10 depth 10 invent <scope>` (e.g. `cycle 10 depth 10 invent`
   with no scope, or `cycle 10 depth 10 invent lib parser` when a scope was peeled).

2. **`<rest>` is one or two integers** (whitespace-separated, nothing else): the inventor workflow with
   a custom cycle count `N`; **depth defaults to 10** (the invent flagship runs deep).
   - `N` (one integer, e.g. `15`): invoke planwright with `cycle <N> depth 10 invent <scope>`.
   - `N D` (two integers, e.g. `5 8` → 5 cycles, depth 8): invoke planwright with
     `cycle <N> depth <D> invent <scope>`. First number = cycles, second = depth.

3. **`<rest>` is anything else**: a verbatim passthrough — invoke planwright with `<rest> <scope>`
   (the non-scope remainder, then the peeled scope appended), so `help`, `version`, `execute`,
   `cycle 3`, `depth 9`, `add OAuth login`, etc. all behave exactly as they would under `/planwright`,
   with any scope riding along after the subcommand.

After resolving, invoke the planwright skill once with the resolved arguments. Print nothing
of your own except the cost banner in case 1.
