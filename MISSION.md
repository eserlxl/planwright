# planwright — Mission

## Purpose

planwright turns a real codebase into a **grounded, verification-ready plan** and, on request,
implements that plan one verified commit at a time. Every claim it makes is anchored in code re-read
this run; every item it proposes carries an exact verification command. The goal is *trustworthy*
forward progress — never plausible-sounding work that wasn't checked.

## How it works (in one breath)

The active AI coding agent runs every stage directly — there is no external binary and no separate
model call. A multi-stage pipeline (scan → graph → audit → dossier → draft → finalize → strict quality
gate → write) emits checkbox items into `.planwright/plan.md`; the execute path implements, verifies,
and commits them; the cycle path repeats the two, climbing a maturity ladder until a recorded final
point.

## Scope

- **Plan is read-only.** The planning path writes only `.planwright/` (the plan, graph memory, digest,
  final-point marker). It never edits application source.
- **Execute is the only mutating path.** It edits the surfaces a plan item declares, runs the item's
  verification verbatim, and commits only what passes — reverting and recording what doesn't.
- **Grounded over generative.** Creativity (the opportunity/vision rungs) widens *what* is proposed; it
  never lowers the grounding bar. An item that cannot cite a real surface and a runnable verification
  does not ship.
- **Converges deliberately.** Work is proposed along a maturity ladder (repair → coverage →
  opportunity → vision). A clean tree keeps producing value via the maturity-gated rungs, and the loop
  stops only at a *recorded* final point — never an accidental idle.

## Non-goals

- Not a code generator that writes unverified code, and not a chat assistant — it produces plans and
  verified commits, nothing in between.
- Not a CI system, release manager, or deploy tool. `bump-version.sh` deliberately does **not** tag or
  publish; tagging and releasing stay manual.
- No hidden state or network dependence: everything it relies on lives in the repo and the gitignored
  `.planwright/` directory.
- It will not pad a plan with sub-value-bar filler to look busy; an empty rung is reported honestly.

## North star

A maintainer can run `/planwright cycle -1` on a project and trust that what lands is real, verified,
and worth doing — and that when planwright says it has reached the final point, it means it.
