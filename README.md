# planwright

**Grounded codebase planning for Claude Code.**

`planwright` is a Claude Code plugin that turns a repository into a verification-ready
work plan. It scans and audits the codebase, then runs an 8-stage
*dossier → draft → finalize → quality-gate* pipeline to emit concrete plan items in
`.planwright/plan.md`.

Claude runs every stage directly, so it costs no separate model calls and needs no external
binary.

> The plugin only ever writes the plan file. It never edits your application source to "plan".

## What it produces

Items in an exact 8-field checkbox format, grounded in real audit findings and non-comment
code signals:

```
- [ ] <Feature or fix title>
      Mode: <develop|improve|repair|docs|reorganize>
      Rationale: <one concise sentence grounded in evidence>
      Evidence: <audit finding or implementation signal that proves the gap>
      Surfaces: <existing repo-relative files that will change>
      New Surfaces: <repo-relative files to create; omitted when none>
      Development: <concrete implementation advice naming the first seam/call site>
      Acceptance: <observable completion criteria or preserved behavior>
      Verification: <exact command, e.g. ctest --test-dir build -R "<target>" --output-on-failure>
```

Files live under `<repo>/.planwright/`:

| File | Purpose |
|------|---------|
| `plan.md` | active plan (pending + completed items) |
| `completed.md` | archived `[x]` items |
| `rejected.md` | drained `Status:Rejected` items |
| `plans/` | full-plan snapshots when a plan is archived |

## Install

```
/plugin marketplace add eserlxl/planwright
/plugin install planwright@planwright
```

Or add a local clone as a marketplace:

```
/plugin marketplace add /opt/lxl/claude/planwright
/plugin install planwright@planwright
```

To use it without the plugin system, copy `skills/planwright/` into `~/.claude/skills/`.

## Usage

```
/planwright                   Plan from audit (propose 5, defaults)
/planwright <instruction>     Break a specific request into plan items
/planwright propose <N>       Override items proposed this run (1..max)
/planwright max <N>           Override the pending-item cap for this run
/planwright no-compact        Skip lifecycle housekeeping this run
/planwright dry-run           Run all stages but print the plan, write nothing
/planwright help              Show usage and stop
```

Options may be combined with an instruction, e.g.
`/planwright add OAuth login propose 3 dry-run`.

### Defaults

| Setting | Default | Meaning |
|---------|---------|---------|
| target | `.` | repo being planned (current working dir) |
| `propose` | 5 | new items proposed per run |
| `max` | 20 | cap on pending unchecked items |
| compaction | on | archive `[x]` and drain rejected items each run |

Overrides are per-run and parsed from the invocation; precedence is **inline option > default**.
There is no settings file.

## How it works

1. **Lifecycle** — archive completed items, drain rejected ones, snapshot finished plans.
2. **Scan** — collect file paths, non-comment implementation signals, and exact test targets.
3. **Audit** — derive grounded findings (oversized modules, missing tests, risks, gaps).
4. **Dossier (5 passes)** — architecture, quality/tests, behavior, operations, prioritization.
5. **Draft → Finalize → Quality gate** — convert the dossier into items, correct them, then
   reject anything stale, unsafe, duplicated, hallucinated, or under-verified.
6. **Write** — append survivors to `.planwright/plan.md`.

## Development

Helper scripts live in `scripts/`:

```
scripts/bump-version.sh <major|minor|patch|X.Y.Z> [-m "note"]
    Bump the version in plugin.json, marketplace.json, and CHANGELOG.md in one shot.

scripts/make-plugin.sh <plugin-name> [dest-dir]
    Scaffold a fresh self-hosting Claude Code plugin (manifests, a starter skill,
    README, CHANGELOG, .gitignore, git init) and bundle bump-version.sh into it.
    Honors AUTHOR_NAME, AUTHOR_EMAIL, PLUGIN_DESC, NO_GIT=1.
```

Typical loop: edit the skill → `scripts/bump-version.sh patch -m "..."` → commit →
`/plugin marketplace update planwright`.

## License

GPL-3.0-or-later. See [LICENSE](LICENSE).
