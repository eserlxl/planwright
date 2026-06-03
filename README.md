# planwright

**Grounded codebase planning for Claude Code.**

Planwright is a planning-first Claude Code skill that analyzes software projects, generates implementation plans, and optionally executes approved development tasks.

It operates using three distinct, partitioned paths:

- **Plan** — scans and audits the codebase, then runs a multi-stage pipeline to emit concrete, verified plan items into `.planwright/plan.md`. Read-only: the plan path writes only the plan file, never your source.
- **Execute** — implements the pending plan items, verifies each, commits the ones that pass, and records the rest. This is the only path that edits source.
- **Cycle** — runs N sequential plan→execute rounds unattended, climbing a maturity ladder (repair → coverage → opportunity → vision) so a clean tree keeps producing valuable work. Pass a positive number for a fixed count, or a negative number to run until it reaches a recorded final point (all rungs dry).

```mermaid
flowchart LR
    User -->|/planwright| Plan[Plan Pipeline] --> Doc[.planwright/plan.md]

    User -->|/planwright execute| Exec[Implement & Verify]
    Exec -- Pass --> Commit[Commit]
    Exec -- Fail --> Revert[Revert]

    User -->|/planwright cycle N| Cycle[Plan → Execute × N]
    Cycle -->|repeat| Cycle
    Cycle -->|nothing left| Done[Done]
```

Claude runs every stage directly, so it costs no separate model calls and needs no external binary.

To keep large-codebase audits affordable, the plan path builds a **graph memory** (`.planwright/graph.json`) — import and change-coupling edges, PageRank, and articulation points — that routes audit attention toward high-blast-radius code and lets repeat runs re-audit only the changed subgraph. A companion `.planwright/digest.md` carries routing-only summaries that are never cited as Evidence. Both live under the gitignored `.planwright/`. See [Graph memory](docs/graph-memory-schema.md) for the schema and stages.

> **Note**: Planning never edits your application source. Only `/planwright execute` and `/planwright cycle` do — and even then, Claude Code's normal permission prompts for edits and commits still apply.

## How planwright differs from `/plan` and `/ultraplan`

Claude Code already ships built-in planning: **`/plan`** enters *plan mode* — Claude proposes a plan, blocks edits until you approve, then executes in the same session — and **`/ultraplan`** refines a plan with a heavier, cloud-backed remote session. Both are general-purpose, model-judgment plans that live for the session. planwright is a different shape of tool: it produces a **grounded, verifiable, persistent plan artifact** for codebase work.

| | `/plan` (built-in mode) | `/ultraplan` (built-in, cloud) | **planwright** |
|---|---|---|---|
| Nature | Session *mode* | Cloud plan *refinement* | Pipeline that emits a plan *file* |
| Plan lives | Ephemeral (approval modal) | Remote session | Persistent `.planwright/plan.md` (+ completed/rejected/graph) |
| Grounding | Model judgment | Model judgment (stronger) | Every item cites real `file:line` evidence; mechanically gated by `lint-plan.py` |
| Output | Free-form prose | Free-form prose | Exact 8-field checkbox items, each with a runnable `Verification:` |
| Execution | Exit mode → implement now | Same | Separate `execute` path: implements, **runs each item's verification, commits per item**, records pass/fail |
| Iteration | One-shot | One-shot refine | `cycle N` climbs a maturity ladder to a recorded **final point** |
| Runs | Local | Cloud (web auth) | Fully local — no external binary, no separate model call |

**Rules of thumb:** reach for **`/plan`** to think through any task you'll execute right away; **`/ultraplan`** when you want cloud-grade refinement on a hard problem; **planwright** when you want a grounded, verifiable plan of *codebase* work — especially unattended multi-round progress (`cycle`) with per-item verification and commits. They compose, too: design with `/plan`, then let planwright drive the verified execution.

## Documentation

For deep dives into how `planwright` operates, refer to the documentation:

- [Mission](MISSION.md): Purpose, scope, and non-goals — the charter the maturity ladder aligns to.
- [Usage](docs/usage.md): Detailed CLI reference, options, and execute modes.
- [Architecture](docs/architecture.md): Explanation of the 11-stage planning pipeline and execute loop.
- [Development](docs/development.md): How to develop this plugin and use the provided helper scripts.
- [Graph memory](docs/graph-memory-schema.md): The `.planwright/graph.json` / `digest.md` schema and how Stage 1.5 routes audit attention.

## Install

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

## Quick Start

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
/planwright cycle -1           # unlimited rounds until a recorded final point (all rungs dry)

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
# meaningful feature: new subcommand, major behaviour change, etc.)
git tag vX.Y.Z <release-commit-sha>
git push origin vX.Y.Z
```

**Release policy:** `bump-version.sh` is for keeping version numbers current during development. Git tags and GitHub releases are reserved for milestones — not every small fix. Tagging too frequently fragments the changelog and dilutes the signal of what a "release" means.

## License

GPL-3.0-or-later. See [LICENSE](LICENSE).
