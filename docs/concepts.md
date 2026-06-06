# Concepts

This page explains *how planwright thinks* — the ideas behind the `cycle`, `explore`,
`invent`, `seed`, and `path`/`lib` controls. The [README](../README.md) gives the short
version; this is the full reference in plain language. For the exact CLI grammar, see
[Usage](usage.md); for the design rationale behind each mechanism, see
[Escalation design](escalation-design.md), [Invent exploration](invent-exploration-design.md),
and [Scope design](scope-design.md).

## The three paths

Planwright operates using three distinct, partitioned paths:

- **Plan** — scans and audits the codebase, then runs a multi-stage pipeline to emit concrete,
  verified plan items into `.planwright/plan.md`. A valid plan item must cite real file/line
  evidence and include a runnable verification command. Read-only: the plan path writes only the
  plan file, never your source.
- **Execute** — implements the pending plan items, verifies each, commits the ones that pass, and
  records the rest. This is the only path that edits source.
- **Cycle** — runs N plan→execute rounds unattended. See below.

## Cycle and the maturity ladder

`cycle N` runs N plan→execute rounds unattended, climbing a maturity ladder
(repair → coverage → opportunity → vision) so a clean tree keeps producing valuable work, and
stopping at a recorded *final point* when every rung is dry (pass `-N` to run until then).

Think of the ladder as four ambitions, tried in order:

1. **repair** — fix what's broken.
2. **coverage** — close gaps (tests, error handling, edge cases).
3. **opportunity** — improvements that are clearly worth doing.
4. **vision** — larger work aligned with the project's charter.

When every rung produces no actionable work, the run records a **final point** and stops.

## explore — sweeping the cold frontier

The opt-in **`explore`** flag turns that final point into an escalation instead of a stop: it
sweeps the *cold frontier* — code the default routing under-examines — and then climbs into the
**expand** tier (completing and generalizing latent capability), spending the rest of the requested
cycle budget before recording a deeper final point, all without ever lowering the grounding bar.

In short: instead of stopping when the obvious work is done, `explore` looks harder at the corners
the normal audit skips, then tries to *finish and generalize* capabilities the code already gestures
at.

## invent — bounded, net-new features

**`invent`** is the superset that adds a bounded net-new, seam-bound burst once expand is dry — and
because typing `invent` is permission to create, it **must propose a net-new item** rather than
declare itself done on a near-complete project (the grounding floor and structural hard ceiling
never relax; below-bar/mission-stretching items are flagged).

In plain terms:

- `invent` does everything `explore` does, and then proposes genuinely *new* features — but only
  ones that attach to existing seams in the code.
- Because you asked it to invent, an empty result isn't acceptable: it must put forward at least one
  net-new idea.
- The safety rails never loosen. Every item still needs real `file:line` evidence (the **grounding
  floor**), and items can't exceed the project's structural limits (the **hard ceiling**). Anything
  that's below the bar or stretches the mission is **flagged**, not silently accepted.

### seed — exploring different angles

Add an opt-in **`seed <S>`** to focus the burst through one of several recorded *framings* so
successive runs explore different angles instead of converging. New seeds explore new angles; the
chosen framing is recorded so a run is reproducible.

### MISSION.md edits under invent

When invent is *repeatedly* blocked by the project's own charter, it may make a rare, dwell-gated,
committed edit to **`MISSION.md`** so the charter can grow with the project (announced up front).

This is intentional: the charter is allowed to evolve, but only after the run has been blocked by it
enough times to earn the change ("dwell-gated"), and the run always announces the edit before making
it. Protected paths (`.git/`, `.planwright/` internals, `LICENSE`, secrets) are never touched.

## Scope — aiming a run at one component

**Scope** is a modifier for any path above. Add **`path <X>`** or **`lib <X>`** to aim a run at one
component (a subtree or a logical library) instead of the whole repo. Plan items land in that
**Focus**, while analysis still reads its 1-hop blast radius (**Context**) so root cause and impact
stay visible — a scoped run matures just that component without walling off its dependencies.

- **Focus** — where new plan items are allowed to land (the subtree or library you named).
- **Context** — the directly-connected code (one hop away) that analysis still reads, so it
  understands cause and effect even though it won't plan changes there.

See [Scope design](scope-design.md) for the full model.

## The grounding guarantee

"Grounded" means every planned change must point back to concrete repository evidence, such as
`file:line` references. No control above ever relaxes this — `explore` and `invent` raise ambition,
not the freedom to invent evidence.

Planning never edits your application source. Only `execute` and `cycle` do — and even then, your AI
coding agent's normal permission prompts for edits and commits still apply. Under `invent`
specifically, those edits can — rarely, and only after the dwell gate trips — include `MISSION.md`
itself; the run announces this up front, and protected paths (`.git/`, `.planwright/` internals,
`LICENSE`, secrets) are never touched.
