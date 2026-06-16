---
description: Shorthand for the planwright skill. Forwards its arguments to planwright; with no arguments it runs the flagship advisor sweep (cycle 10 depth 10 explore). Use it for grounded codebase planning, execute, and cycle/explore runs without typing the full skill name.
argument-hint: "[planwright args] | <N> [D] | (empty = cycle 10 depth 10 explore)"
---

You are dispatching the **planwright** skill on behalf of the `/codvisor` helper command.
Do **not** re-implement any planwright logic here — resolve the arguments below, then invoke
the planwright skill with the resolved argument string, and let the skill do everything else
(it owns all planning/execute/cycle behaviour, the maturity ladder, and the explore escalation).
On Claude Code, that hand-off is the Skill tool invocation `planwright:planwright`; on other hosts,
load `skills/planwright/SKILL.md` or use the host's native skill invocation with the same resolved
argument string.

Raw arguments: `$ARGUMENTS`

Resolve them in this order:

0. **Peel the scope first.** If `$ARGUMENTS` contains a `path <X>` or `lib <X>` scope (the keyword
   plus its single following token, appearing anywhere — leading or trailing), lift that pair out as
   `<scope>` and let `<rest>` be the remaining tokens. Otherwise `<scope>` is empty and `<rest>` is all
   of `$ARGUMENTS`. Classify `<rest>` with the cases below to build a base command, then **append
   `<scope>`** to it (after a space) so the subcommand (`cycle` / `execute` / …) stays the first token
   planwright dispatches on — never let `path`/`lib` lead. With no scope this is exactly today's
   behaviour; omit the trailing `<scope>` wherever it is empty. Also recognise the `--`-prefixed
   aliases when peeling, normalising to the bare form first: `--path <X>` → `path <X>`, `--lib <X>` →
   `lib <X>`, `--scope <X>` → `path <X>` (both `--opt <X>` and `--opt=<X>` spellings).

0a. **Peel `parallel`** (optionally a backend qualifier `agent` or `external`, then an integer
   `J >= 1`) from `<rest>` as `<parallel>`: a read-only **recon prefetch** for this single run. Recon
   lives in the base skill — **append `<parallel>` (after `<scope>`) to the planwright invocation**
   built below, and planwright's **Stage 1.6** runs the prefetch over this run's Focus before its
   audit; it changes nothing else. Peel `parallel`, its qualifier, and `J` out of `<rest>` before
   classifying the remainder. Bare `parallel`/`parallel agent` select the native subagent backend;
   `parallel external` is the explicit opt-in to the **entirely optional** external-agents CLI backend
   (which planwright never requires and **never auto-engages** — only `parallel external` reaches a
   third-party provider). A token after `parallel` that is neither `agent` nor `external` is not a
   qualifier — it stays in `<rest>` (so `parallel execute` still forwards `execute`).

1. **`<rest>` empty**: the flagship "advisor" run. First print exactly one
   cost-banner line so the heavy run is never silent:
   `codvisor: max-intensity advisor run — up to 10 plan→execute rounds at depth 10 with the explore cold-frontier sweep.`
   Then invoke planwright with: `cycle 10 depth 10 explore <scope>` (e.g. `cycle 10 depth 10 explore`
   with no scope, or `cycle 10 depth 10 explore path src/auth/` when a scope was peeled).

2. **`<rest>` is one or two integers** (whitespace-separated, nothing else): the advisor workflow with
   a custom cycle count `N`; **depth defaults to 10** (the explore flagship runs deep). First print
   exactly one cost-banner line so this heavy run is never silent (case 2 is still a depth-10-class
   flagship sweep), naming the resolved cycle count and depth:
   `codvisor: max-intensity advisor run — up to <N> plan→execute rounds at depth <D> with the explore cold-frontier sweep.`
   - `N` (one integer, e.g. `15`): invoke planwright with `cycle <N> depth 10 explore <scope>`.
   - `N D` (two integers, e.g. `5 8` → 5 cycles, depth 8): invoke planwright with
     `cycle <N> depth <D> explore <scope>`. First number = cycles, second = depth.

3. **`<rest>` is anything else**: a verbatim passthrough — invoke planwright with `<rest> <scope>`
   (the non-scope remainder, then the peeled scope appended), so `help`, `version`, `execute`,
   `cycle 3`, `depth 9`, `add OAuth login`, etc. all behave exactly as they would under `/planwright`,
   with any scope riding along after the subcommand.

**Parallel recon (opt-in, forwarded to planwright).** codvisor does **not** run recon itself: when
`parallel` was peeled it is appended to the planwright invocation, and the base skill's **Stage 1.6**
runs the read-only prefetch over the run's Focus (the full backend ladder, the read-only contract, the
external-agents discovery, the egress disclosure, and the degrade-to-no-recon fallback all live in
`skills/planwright/SKILL.md`). The leads stay **routing-only** re-verification seeds, **never
Evidence**, re-proven inside planwright's single-agent cycle. `parallel external` is the explicit,
**entirely optional** external-agent CLI backend; it is never auto-engaged.

After resolving, invoke the planwright skill once with the resolved arguments — **appending
`<parallel>` (after `<scope>`) when `parallel` was peeled**, so planwright's Stage 1.6 runs the recon.
Print nothing of your own except the cost banner in cases 1 and 2.
