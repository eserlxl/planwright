---
description: Shorthand for the planwright skill. Forwards its arguments to planwright; with no arguments it runs the flagship advisor sweep (cycle 10 depth 10 explore). Use it for grounded codebase planning, execute, and cycle/explore runs without typing the full skill name.
argument-hint: "[planwright args] | <N> [M] | (empty = cycle 10 depth 10 explore)"
---

You are dispatching the **planwright** skill on behalf of the `/codvisor` helper command.
Do **not** re-implement any planwright logic here — resolve the arguments below, then invoke
the planwright skill (via the Skill tool, skill `planwright:planwright`) with the resolved
argument string, and let the skill do everything else (it owns all planning/execute/cycle
behaviour, the maturity ladder, and the explore escalation).

Raw arguments: `$ARGUMENTS`

Resolve them in this order:

1. **Empty** (`$ARGUMENTS` is blank): the flagship "advisor" run. First print exactly one
   cost-banner line so the heavy run is never silent:
   `codvisor: max-intensity advisor run — up to 10 plan→execute rounds at depth 10 with the explore cold-frontier sweep.`
   Then invoke planwright with: `cycle 10 depth 10 explore`.

2. **One or two integers** (whitespace-separated, nothing else): the advisor workflow with a
   custom cycle count `N`; **depth defaults to 10** (the explore flagship runs deep).
   - `N` (one integer, e.g. `15`): invoke planwright with `cycle <N> depth 10 explore`.
   - `N M` (two integers, e.g. `5 8` → 5 cycles, depth 8): invoke planwright with
     `cycle <N> depth <M> explore`. First number = cycles, second = depth.

3. **Anything else**: a verbatim passthrough — invoke planwright with `$ARGUMENTS` exactly as
   given, so `help`, `version`, `execute`, `cycle 3`, `depth 9`, `add OAuth login`, etc. all
   behave exactly as they would under `/planwright`.

After resolving, invoke the planwright skill once with the resolved arguments. Print nothing
of your own except the cost banner in case 1.
