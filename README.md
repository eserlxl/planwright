# planwright

**Grounded codebase planning for Claude Code.**

`planwright` is a Claude Code plugin with two partitioned paths:

- **Plan** — scans and audits the codebase, then runs an 8-stage
  *dossier → draft → finalize → quality-gate* pipeline to emit concrete plan items in
  `.planwright/plan.md`. Read-only: the plan path writes only the plan file, never your source.
- **Execute** — implements the pending plan items, verifies each, commits the ones that pass, and
  records the rest. This is the only path that edits source.

Claude runs every stage directly, so it costs no separate model calls and needs no external
binary.

> Planning never edits your application source. Only `/planwright execute` does — and even then,
> Claude Code's normal permission prompts for edits and commits still apply.

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
| `completed.md` | items that passed verification — FIFO capped at 100 |
| `rejected.md` | items that failed, with a `Rejection:` reason — FIFO capped at 100 |
| `plans/` | full-plan snapshots when a plan is archived |

A failed item is marked in `plan.md` with a `Status:Rejected` line plus a `Rejection:` reason; the
next plan run **drains** every `Status:Rejected` item from `plan.md` into `rejected.md` during its
lifecycle housekeeping. Those rejection reasons then feed back into planning, so planwright avoids
re-proposing work that has already failed — rejections trend down over time.

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
PLAN (read-only)
/planwright                   Plan from audit (propose 5, defaults)
/planwright <instruction>     Break a specific request into plan items
/planwright propose <N>       Override items proposed this run (1..max)
/planwright max <N>           Override the pending-item cap for this run
/planwright no-compact        Skip lifecycle housekeeping this run
/planwright dry-run           Run all stages but print the plan, write nothing

EXECUTE (edits source)
/planwright execute               Auto: implement every pending item, commit each that passes
/planwright execute --interactive Prompt per item: approve, show diff, verify, confirm commit
/planwright execute N             Implement only pending item number N

/planwright help              Show usage and stop
```

Plan options may be combined with an instruction, e.g.
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

## Execute

`/planwright execute` implements the plan. It first requires a **clean git working tree** (so its
per-item commits never entangle your uncommitted work) and announces the branch it will commit to.
Then, for each pending item in order:

1. **Implement** the `Development:` step, editing only the item's declared surfaces.
2. **Verify** by running the item's `Verification:` command. An item with no runnable verification
   cannot be marked done.
3. **On pass** — mark `[x]`, commit (`planwright: <title>`), move to `completed.md`.
4. **On fail** — retry up to twice, then revert the item's edits and move it to `rejected.md` with a
   `Rejection:` reason.

After all items it runs a **broad final build + test** to catch fixes that pass in isolation but
break the whole. Auto mode runs the entire plan, pausing only on a hard blocker (an item that needs
an unresolved design decision, or a failing final verification). `--interactive` adds an
approve/diff/confirm step per item.

`execute` refuses to start on a dirty working tree so its per-item commits stay isolated from your
uncommitted work — commit or stash first. (`bump-version.sh` enforces the same clean-tree rule and
accepts `ALLOW_DIRTY=1` to override it when you deliberately want to bump alongside other changes.)

## Development

Helper scripts live in `scripts/`:

```
scripts/bump-version.sh <major|minor|patch|X.Y.Z> [-m "note"]
    Bump the version in plugin.json, marketplace.json, every skills/*/SKILL.md
    frontmatter, and CHANGELOG.md in one shot. Refuses a dirty tree (ALLOW_DIRTY=1 overrides).

scripts/make-plugin.sh <plugin-name> [dest-dir]
    Scaffold a fresh self-hosting Claude Code plugin (manifests, a starter skill,
    README, CHANGELOG, .gitignore, git init) and bundle bump-version.sh into it.
    Honors AUTHOR_NAME, AUTHOR_EMAIL, PLUGIN_DESC, NO_GIT=1.
```

Typical loop: edit the skill → `scripts/bump-version.sh patch -m "..."` → commit →
`/plugin marketplace update planwright`.

## License

GPL-3.0-or-later. See [LICENSE](LICENSE).
