# planwright

**Grounded codebase planning for Claude Code.**

Planwright is a planning-first Claude Code skill that analyzes software projects, generates implementation plans, and optionally executes approved development tasks.

It operates using two distinct, partitioned paths:

- **Plan** — scans and audits the codebase, then runs a multi-stage pipeline to emit concrete, verified plan items into `.planwright/plan.md`. Read-only: the plan path writes only the plan file, never your source.
- **Execute** — implements the pending plan items, verifies each, commits the ones that pass, and records the rest. This is the only path that edits source.

```mermaid
flowchart LR
    User -->|/planwright| Plan[Plan Pipeline] --> Doc[.planwright/plan.md]
    
    User -->|/planwright execute| Exec[Implement & Verify]
    Exec -- Pass --> Commit[Commit]
    Exec -- Fail --> Revert[Revert]
```

Claude runs every stage directly, so it costs no separate model calls and needs no external binary.

> **Note**: Planning never edits your application source. Only `/planwright execute` does — and even then, Claude Code's normal permission prompts for edits and commits still apply.

## Documentation

For deep dives into how `planwright` operates, refer to the documentation:

- [Usage](docs/usage.md): Detailed CLI reference, options, and execute modes.
- [Architecture](docs/architecture.md): Explanation of the 11-stage planning pipeline and execute loop.
- [Development](docs/development.md): How to develop this plugin and use the provided helper scripts.

## Install

```bash
/plugin marketplace add eserlxl/planwright
/plugin install planwright@planwright
```

Or add a local clone as a marketplace:

```bash
/plugin marketplace add <PLANWRIGHT_FOLDER>
/plugin install planwright@planwright
```

To use it without the plugin system, copy `skills/planwright/` into `~/.claude/skills/`.

## Quick Start

```bash
# Generate a plan for your project
/planwright

# Break a specific request into plan items
/planwright "add OAuth login"

# Execute the pending plan items automatically
/planwright execute

# Maintenance
/planwright version    # show current and latest available version
/planwright upgrade    # update planwright itself to the latest version
```

## License

GPL-3.0-or-later. See [LICENSE](LICENSE).
