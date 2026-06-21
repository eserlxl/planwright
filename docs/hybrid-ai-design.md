# planwright hybrid-ai — opt-in dossier-survey delegation (design)

Status: **PROPOSED.** Design only. Wires an opt-in `hybrid-ai` flag that delegates the
**dossier survey (Stages 3–7)** to the *same* optional external-agent CLI backend that
`parallel external` already uses for Stage 1.6 recon — as **never-Evidence** leads, additive only,
**off by default**. This doc locks the contract the `SKILL.md`/command/docs/test surfaces implement;
flip the Status line to **IMPLEMENTED** only once those surfaces are wired and pinned. Clones the
host-neutral recon backend (Stage 1.6); **Stage 1.6 is not renamed** and its recon path is unchanged.

## The gap

The token sink in a planning run is the **dossier survey** (Stages 3–7), not `execute`. A user who
wants to cut the active agent's (e.g. Claude's) token spend on that survey-heavy stretch has no
opt-in lever today: `parallel external` already delegates *Stage 1.6 recon* to an external CLI as
routing-only leads, but the much larger dossier passes still run entirely on the host agent.

`hybrid-ai` closes that gap by extending the **same** opt-in, never-Evidence delegation from recon
to the dossier survey — and nothing more. It is a small, additive, reversible flag, not a new
subsystem: the savings are **modest** and the grounding guarantee is untouched.

## The model: delegate the survey, keep the grounding

`hybrid-ai` is the dossier-survey analogue of `parallel external`. When it is **on**:

- The Stages 3–7 dossier survey is **delegated** to the external-agent CLI backend via
  `run-agent.sh --agent all --read-only --target <T>`, with `<T>` the **smallest directory
  enclosing the run's Focus** — identical resolution, preflight (`--check`), and harvest to the
  Stage 1.6 external backend.
- The backend returns **candidate findings** the host folds into the planning dossier.

When it is **off** (the default) the run is **byte-identical** to today: the host agent runs the
full dossier itself.

Two invariants make this safe and keep it consistent with planwright's promises:

1. **never-Evidence.** Every delegated dossier finding is a **routing-only re-verification seed**.
   It must be **re-proven from a code re-read inside the host's single-agent dossier, or dropped** —
   it may order the reading but **never becomes an item's `Evidence:`**. This is the identical
   ceiling Stage 1.6 already enforces on recon leads (`SKILL.md` Stage 1.6, Stage 10 gate). The
   pipeline stays single-agent: delegation buys token savings, never a second source of truth.
2. **off==skipped state identity.** When `hybrid-ai` is absent, the run **writes no new
   `.planwright/` state** and the produced dossier/plan/digest/graph are **unchanged** from the
   baseline. Off is the baseline; the flag is purely additive on the on-path.

### Why this does not contradict the "no separate model calls" promise

planwright's charter promise — *the active AI coding agent runs every stage; planwright needs no
external binary and spends no separate model calls* (`MISSION.md`, `docs/architecture.md`,
`skills/planwright/SKILL.md`, `.claude-plugin/plugin.json`) — describes the **default** path, which
`hybrid-ai` leaves untouched (`off==skipped`). `hybrid-ai` is an **explicit, opt-in** exception the
user chooses, exactly as `parallel external` already is: the promise holds unless the operator
deliberately opts into the optional external backend. The committed user docs frame it that way, so
the promise and the flag never contradict.

## Egress policy

Identical to the Stage 1.6 external backend, and never wider:

- **public-repo egress** only — the backend ships the targeted tree to a third-party provider
  (agy/codex are external services), so it must **never** target a tree holding private IP.
- **git-tracked-only** — the delegation prompt carries the git-tracked-only restriction; the agent
  reads only `git ls-files`/`git grep`/`rg`/`fd` (default ignore mode) and skips gitignored paths
  (`node_modules/`, build output, vendored deps, `.env`).
- **Focus-enclosing target** — `<T>` is the **smallest directory enclosing the run's Focus**, so a
  scoped run never egresses more of the tree than its Focus's enclosing directory.
- **never auto-engaged** — `hybrid-ai` is the explicit opt-in; planwright never selects the external
  backend on its own.

## no-hard-dependency (degrade-to-skip)

planwright **never requires** the external-agents plugin or any agy/codex/claude CLI (no
OpenAI/Google subscription is needed). When the external CLI is **unavailable** — no `run-agent.sh`
resolves, `run-agent.sh --check` shows none usable, the run times out, or it returns empty output —
planwright **prints a skip note and runs the dossier unchanged** (never errors, never blocks),
mirroring the recon backend's degrade-to-skip. The skip is silent toward correctness: the host
simply runs the full dossier itself, exactly as on the off-path.

## Surfaces (what 5.2–5.4 touch)

- **`skills/planwright/SKILL.md`** — the `hybrid-ai` flag row in the Options table, the usage line,
  the summary lines; the dossier-section (Stages 3–7) clauses for on-path delegation, the
  never-Evidence ceiling, the egress bound, the `off==skipped` state identity, and degrade-to-skip.
  It is **ignored under `invent` and on `execute`** (the generative tier / mutating path do not take
  a survey-delegation lever), mirroring Stage 1.6.
- **Commands** — `commands/codvisor.md`, `commands/codcycle.md`, `commands/codshard.md` (and
  `codmaster` if applicable) **peel and forward** `hybrid-ai` to the base SKILL, mirroring the
  `parallel` forwarding pattern; commands never re-implement the delegation logic.
- **Host examples** — `AGENTS.example.md`, `GEMINI.example.md`, `GEMINI.example_context-mode.md`
  (and the codex plugin manifest as applicable) carry the identical `hybrid-ai` vocabulary, mirroring
  how `parallel` / `parallel external` is presented.
- **User docs** — `docs/usage.md` (alongside `parallel`) and the `README.md` flag list document the
  flag as an opt-in optional delegation, consistent with the no-separate-model-calls promise.
- **Scripts** — **none.** Like Stage 1.6's external backend, the delegation is host-prose the active
  agent follows; `run-agent.sh` already exists in the external-agents plugin. planwright's own
  scripts need **zero changes**.

## Test pins (lockstep with the contract)

- A fails-on-drift contract assertion (in `tests/cases/skill-contract.sh`) that this doc exists and
  carries its load-bearing clauses verbatim: **opt-in**, **never-Evidence**, **off==skipped**,
  **no-hard-dependency**, **public-repo egress**.
- A `hybrid-ai` flag-row assertion over `SKILL.md`, plus the on-path delegation clause naming
  `--read-only` and the Focus-enclosing `--target` (fails if egress widens).
- An off-path **state-identity** test (`tests/cases/hybrid-ai.sh`): the planning path run normally
  and run with `hybrid-ai` explicitly off produce identical `.planwright/` state.
- A **flag-recognition / ignore-context** test: the flag is recognized and ignored under
  `execute`/`invent` where the design forbids it.
- A **host-parity / docs-contract** test: identical `hybrid-ai` vocabulary across `SKILL.md`, the
  forwarding commands, the host example files, and the user docs.
- A **security** assertion (`tests/cases/security.sh`) that fails if the egress widens past
  read-only / git-tracked-only / Focus-enclosing, or if a secret could be written.

## Open questions

1. **Granularity** — delegate the whole Stages 3–7 sweep, or only the broadest lenses (5–6)? Start
   whole-sweep; the never-Evidence re-proof bounds the blast radius either way.
2. **Cost accounting** — surface the external token spend back to the operator, or leave it to the
   CLI's own reporting? Defer; the CLIs report their own usage.
3. **Backend selection** — reuse `--agent all` (agy + codex) as-is, or let `hybrid-ai <agent>`
   narrow it? Start with the recon backend's `--agent all` default; a qualifier can follow later.
