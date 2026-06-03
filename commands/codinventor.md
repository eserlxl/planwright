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

1. **Empty** (`$ARGUMENTS` is blank): the flagship "inventor" run. First print exactly one
   cost-banner line so the heavy run is never silent:
   `codinventor: max-intensity inventor run — up to 10 plan→execute rounds at depth 10 with the invent escalation ladder (cold-frontier → expand → net-new invent burst).`
   Then invoke planwright with: `cycle 10 depth 10 invent`.

2. **One or two integers** (whitespace-separated, nothing else): the inventor workflow with a
   custom cycle count `N`; **depth defaults to 10** (the invent flagship runs deep).
   - `N` (one integer, e.g. `15`): invoke planwright with `cycle <N> depth 10 invent`.
   - `N D` (two integers, e.g. `5 8` → 5 cycles, depth 8): invoke planwright with
     `cycle <N> depth <D> invent`. First number = cycles, second = depth.

3. **Anything else**: a verbatim passthrough — invoke planwright with `$ARGUMENTS` exactly as
   given, so `help`, `version`, `execute`, `cycle 3`, `depth 9`, `add OAuth login`, etc. all
   behave exactly as they would under `/planwright`.

After resolving, invoke the planwright skill once with the resolved arguments. Print nothing
of your own except the cost banner in case 1.
