# planwright

**Grounded codebase planning for AI coding agents (Claude Code, Codex, Cursor, Antigravity, and Gemini).**

> Invoke it with your host's `planwright` trigger — for example `/planwright` on Claude Code,
> `@planwright` on Cursor, or `planwright` in Codex/Antigravity/Gemini project instructions. The
> `codvisor` shortcut resolves to `cycle 10 depth 10 explore`; `codinventor` resolves to
> `cycle 10 depth 10 invent`.

Planwright is a planning-first skill/workflow for codebase work. It audits a project, writes grounded implementation items to `.planwright/plan.md`, and can optionally execute verified items one by one.

"Grounded" means every planned change must point back to concrete repository evidence, such as `file:line` references.

It operates using three distinct, partitioned paths:

- **Plan** — scans and audits the codebase, then runs a multi-stage pipeline to emit concrete, verified plan items into `.planwright/plan.md`. A valid plan item must cite real file/line evidence and include a runnable verification command. Read-only: the plan path writes only the plan file, never your source.
- **Execute** — implements the pending plan items, verifies each, commits the ones that pass, and records the rest. This is the only path that edits source.
- **Cycle** — runs N plan→execute rounds unattended, climbing a maturity ladder (repair → coverage → opportunity → vision) so a clean tree keeps producing valuable work, and stopping at a recorded *final point* when every rung is dry (pass `-N` to run until then). The opt-in **`explore`** flag turns that final point into an escalation instead of a stop: it sweeps the *cold frontier* — code the default routing under-examines — and then climbs into the **expand** tier (completing and generalizing latent capability), spending the rest of the requested cycle budget before recording a deeper final point, all without ever lowering the grounding bar. **`invent`** is the superset that adds a bounded net-new, seam-bound burst once expand is dry — and because typing `invent` is permission to create, it **must propose a net-new item** rather than declare itself done on a near-complete project (the grounding floor and structural hard ceiling never relax; below-bar/mission-stretching items are flagged). Add an opt-in **`seed <S>`** to focus the burst through one of several recorded *framings* so successive runs explore different angles instead of converging; and when invent is *repeatedly* blocked by the project's own charter, it may make a rare, dwell-gated, committed edit to **`MISSION.md`** so the charter can grow with the project (announced up front). (See [Usage](docs/usage.md) for the full `cycle`/`explore`/`invent`/`seed` reference.)
- **Scope** *(modifier for any path above)* — add **`path <X>`** or **`lib <X>`** to aim a run at one component (a subtree or a logical library) instead of the whole repo. Plan items land in that **Focus**, while analysis still reads its 1-hop blast radius (**Context**) so root cause and impact stay visible — a scoped run matures just that component without walling off its dependencies. (See [Scope design](docs/scope-design.md).)

```mermaid
flowchart LR
    User -->|planwright| Plan[Plan Pipeline] --> Doc[.planwright/plan.md]

    User -->|planwright execute| Exec[Implement & Verify]
    Exec -- Pass --> Commit[Commit]
    Exec -- Fail --> Revert[Revert]

    User -->|planwright cycle N| Cycle[Plan → Execute × N]
    Cycle -->|repeat| Cycle
    Cycle -->|nothing left| Done[Done]
```

Your AI coding agent runs every stage through the skill, so planwright needs no external binary and
makes no separate API/model calls beyond the active session.

To keep large-codebase audits efficient, the plan path builds a **graph memory** (`.planwright/graph.json`) — import and change-coupling edges, PageRank, and articulation points — that routes audit attention toward code where changes can affect many other files and lets repeat runs re-audit only the changed subgraph. A companion `.planwright/digest.md` carries routing-only summaries that are never cited as Evidence. Both live under the gitignored `.planwright/`. See [Graph memory](docs/graph-memory-schema.md) for the schema and stages.

> **Note**: Planning never edits your application source. Only `execute` and `cycle` do — and even then, your AI coding agent's normal permission prompts for edits and commits still apply. Under `invent` specifically, those edits can — rarely, and only after the dwell gate trips — include `MISSION.md` itself; the run announces this up front, and protected paths (`.git/`, `.planwright/` internals, `LICENSE`, secrets) are never touched.

## How planwright differs from `/plan` and `/ultraplan`

Claude Code already ships built-in planning: **`/plan`** enters *plan mode* — Claude proposes a plan, blocks edits until you approve, then executes in the same session.

**`/ultraplan`** is currently a research-preview Claude Code feature, so its behavior may change. It refines a plan with a heavier, cloud-backed remote session.

Both are general-purpose, session-scoped plans. planwright is a different shape of tool: it produces a **grounded, verifiable, persistent plan artifact** for codebase work.

| | `/plan` (built-in mode) | `/ultraplan` (built-in, cloud) | **planwright** |
|---|---|---|---|
| Nature | Session *mode* | Cloud plan *refinement* | Pipeline that emits a plan *file* |
| Plan lives | Ephemeral (approval modal) | Remote session | Persistent `.planwright/plan.md` (+ completed/rejected/graph) |
| Grounding | Model judgment | Model judgment (stronger) | Every item cites real `file:line` evidence; mechanically gated by `lint-plan.py` |
| Output | Free-form prose | Free-form prose | Exact 8-field checkbox items, each with a runnable `Verification:` |
| Execution | Exit mode → implement now | Same | Separate `execute` path: implements, **runs each item's verification, commits per item**, records pass/fail |
| Iteration | One-shot | One-shot refine | `cycle N` climbs a maturity ladder to a recorded **final point** |
| Runs | Local | Cloud (web auth) | Runs inside the active AI coding agent — no extra binary, daemon, server, or separate API/model integration |

**Rules of thumb:** reach for **`/plan`** to think through any task you'll execute right away; **`/ultraplan`** when you want cloud-grade refinement on a hard problem; **planwright** when you want a grounded, verifiable plan of *codebase* work — especially unattended multi-round progress (`cycle`) with per-item verification and commits. They compose, too: design with `/plan`, then let planwright drive the verified execution.

## Example Plan Item

A plan item has this 8-field shape:

```md
- [ ] ID: PW-001
  Title: Add missing validation for config loading
  Evidence: `src/config.ts:42`
  Risk: Low
  Change: Validate required keys before use.
  Verification: `npm test -- config`
  Files: `src/config.ts`, `tests/config.test.ts`
  Status: pending
```

## Documentation

For deep dives into how `planwright` operates, refer to the documentation:

- [Mission](MISSION.md): Purpose, scope, and non-goals — the charter the maturity ladder aligns to.
- [Usage](docs/usage.md): Detailed CLI reference, options, and execute modes.
- [Architecture](docs/architecture.md): Explanation of the 11-stage planning pipeline and execute loop.
- [Development](docs/development.md): How to develop this plugin and use the provided helper scripts.
- [Graph memory](docs/graph-memory-schema.md): The `.planwright/graph.json` / `digest.md` schema and how Stage 1.5 routes audit attention.
- [Scope design](docs/scope-design.md): The `path`/`lib` component-scoping model — Focus vs. Context and how a scoped run stays grounded.

## Install

Planwright runs inside an AI coding assistant — no external binary. Install the skill for the host in use.

### Command adapters

The workflow has one argument grammar: `planwright <args>`. Each host only changes the trigger token:

| Host | Use this trigger | Shortcut spelling |
|------|------------------|-------------------|
| Claude Code | `/planwright <args>` | `/codvisor`, `/codinventor` |
| Codex | `planwright <args>` after installing/loading the skill | `codvisor`, `codinventor` |
| Cursor | `@planwright <args>` or `planwright <args>` | `@codvisor`/`codvisor`, `@codinventor`/`codinventor` |
| Antigravity / Gemini | `planwright <args>` from the `GEMINI.md` project instruction | `codvisor`, `codinventor` |

### Claude Code

The plugin install path is recommended; manual skill copy is only for users not using the plugin system.

```bash
/plugin marketplace add eserlxl/planwright
/plugin install planwright@eserlxl
```

Or add a local clone as a marketplace:

```bash
/plugin marketplace add <PLANWRIGHT_FOLDER>
/plugin install planwright@eserlxl
```

To use it without the plugin system, copy `skills/planwright/` into `~/.claude/skills/`.

Then invoke with `/planwright`, `/codvisor`, or `/codinventor`. Upgrade with `/planwright upgrade`.

### Cursor

Planwright runs as a Cursor Agent Skill — the same agent-neutral `SKILL.md` workflow, without a plugin marketplace. See [`AGENTS.example.md`](AGENTS.example.md) for the full setup guide.

**Recommended (once per machine):** symlink the skill so bundled scripts resolve correctly:

```bash
mkdir -p ~/.cursor/skills
ln -s <PLANWRIGHT_FOLDER>/skills/planwright ~/.cursor/skills/planwright
```

For `codvisor` / `codinventor` shortcuts, use the `AGENTS.md` block in [`AGENTS.example.md`](AGENTS.example.md) or add thin dispatcher skills (see that file for details).

**Lightweight alternative:** copy the `AGENTS.md` block from [`AGENTS.example.md`](AGENTS.example.md) into the root of each target project.

Then invoke in chat with `@planwright`, natural-language `planwright …` arguments, or the `codvisor` / `codinventor` shortcuts. Cursor's normal edit and terminal approval prompts apply on the execute and cycle paths. Upgrade by `git pull` in the planwright clone (there is no `/plugin upgrade` on Cursor).

### Codex

Planwright works best on Codex as a local plugin, because the plugin keeps this repository's
`skills/planwright` and `scripts/` layout together. Codex also supports direct user skills under
`~/.agents/skills`.

**Recommended: local plugin marketplace**

Keep this repository as the plugin root, or symlink/copy it to the personal plugin area:

```bash
mkdir -p ~/plugins ~/.agents/plugins
ln -s <PLANWRIGHT_FOLDER> ~/plugins/planwright
```

Create or update `~/.agents/plugins/marketplace.json`:

```json
{
  "name": "personal",
  "interface": {
    "displayName": "Personal"
  },
  "plugins": [
    {
      "name": "planwright",
      "source": {
        "source": "local",
        "path": "./plugins/planwright"
      },
      "policy": {
        "installation": "AVAILABLE",
        "authentication": "ON_INSTALL"
      },
      "category": "Productivity"
    }
  ]
}
```

Then install from the personal marketplace and start a new Codex thread:

```bash
codex plugin add planwright@personal
```

The `./plugins/planwright` path is resolved relative to the personal marketplace root (`~`), not
relative to `~/.agents/plugins/`.

**Direct skill install (simple):**

```bash
mkdir -p ~/.agents/skills
ln -s <PLANWRIGHT_FOLDER>/skills/planwright ~/.agents/skills/planwright
```

Codex follows symlinked skill folders, which is important here because Planwright resolves helper
scripts from `../../scripts/` relative to `skills/planwright`. If you copy instead of symlink, keep
that layout intact or use the plugin path above.

Invoke in chat with `planwright`, for example `planwright depth 8`, `planwright execute`, or
`planwright cycle 3`. You can also explicitly mention the skill as `$planwright`. Use `codvisor` /
`codinventor` as natural-language shortcuts or add a small dispatcher skill that reads
`commands/codvisor.md` / `commands/codinventor.md` and then loads `skills/planwright/SKILL.md` with
the resolved argument string.

### Antigravity / Gemini

Planwright can be run directly via Antigravity or Gemini project instructions. Copy the contents of [`GEMINI.example.md`](GEMINI.example.md) into a `GEMINI.md` file in the root of each target project, and update the absolute path to point to the planwright clone.

Then ask the assistant to run `planwright` or use the `codvisor` and `codinventor` shortcut commands.

## Optional: context-mode

On large repos or at higher planning depths, the plan path's mechanical stages (especially Stage 1 scan and Stage 1.5 graph build) can emit bulky `rg`/`git` output. The skill can route that through [context-mode](https://github.com/mksglu/context-mode) (`ctx_execute` / `ctx_batch_execute`) so only summarized results enter the session. context-mode is optional on every host; without it, planwright falls back to capped Shell output or the by-hand fallbacks in the skill.

## Quick Start

Examples below use Claude Code slash-command spelling. On Codex, Cursor, Antigravity, or Gemini, use
the equivalent trigger from the command adapter table and keep the arguments the same.

```bash
# Generate a plan for your project
/planwright

# Break a specific request into plan items
/planwright "add OAuth login"

# Tune analysis depth 1..10 (intensity + audit thoroughness; default 6)
/planwright depth 9          # exhaustive audit
/planwright depth 2          # quick cosmetic pass

# Execute the pending plan items automatically
/planwright execute

# Run plan→execute in a loop
/planwright cycle 3            # exactly 3 rounds
/planwright cycle 3 depth 8    # 3 rounds, deep planning each round
/planwright cycle -1           # repeat until every maturity rung produces no actionable work
/planwright cycle 10 depth 10 explore  # at the final point, escalate: cold-frontier sweep → expand (complete latent capability)
/planwright cycle 10 depth 10 invent   # …and, with permission, a net-new seam-bound invent burst after expand is dry
/planwright cycle 10 invent seed 7     # focus the invent burst through one seeded framing; new seeds explore new angles

# Aim a run at one component instead of the whole repo (composes with execute/cycle)
/planwright path src/auth/      # plan only the auth subtree (Focus); still reads its 1-hop deps (Context)
/planwright lib parser cycle 5  # mature just the 'parser' component (cluster/build-target/dir) over 5 cycles

# /codvisor — a short helper command that forwards to planwright
/codvisor                  # flagship advisor run: cycle 10 depth 10 explore (prints the cost first)
/codvisor 15               # cycle 15 depth 10 explore (one number = cycles; depth defaults to 10)
/codvisor 5 8              # cycle 5 depth 8 explore (cycles, depth)
/codvisor help             # passthrough: same as /planwright help (any planwright args work)

# /codinventor — the invent twin of /codvisor (permits net-new, seam-bound features)
/codinventor               # flagship inventor run: cycle 10 depth 10 invent (prints the cost first)
/codinventor 15            # cycle 15 depth 10 invent (one number = cycles; depth defaults to 10)
/codinventor 5 8           # cycle 5 depth 8 invent (cycles, depth)

# Maintenance
/planwright version    # show current and latest available version
/planwright upgrade    # update planwright itself to the latest version (alias: update)
```

## Development & Releasing

```bash
# Run the test suite
bash tests/run.sh

# Bump the version in manifests + CHANGELOG (does NOT tag or release)
scripts/bump-version.sh patch -m "what changed"

# Preview a bump without modifying files
scripts/bump-version.sh --dry-run patch

# Show usage for the helper scripts
scripts/bump-version.sh --help
scripts/make-plugin.sh --help

# Create a tagged release — only at milestones (every 25-50 commits or a
# meaningful feature: new subcommand, major behavior change, etc.)
git tag vX.Y.Z <release-commit-sha>
git push origin vX.Y.Z
```

**Release policy:** `bump-version.sh` is for keeping version numbers current during development. Git tags and GitHub releases are reserved for milestones — not every small fix. Tagging too frequently fragments the changelog and dilutes the signal of what a "release" means.

## License

GPL-3.0-or-later. See [LICENSE](LICENSE).
