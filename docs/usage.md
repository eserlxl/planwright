# Usage

`planwright` provides commands for planning your work (read-only) and executing it (mutating).

## Quick Start

```bash
# Propose a plan based on the current codebase
/planwright

# Execute the pending plan items automatically
/planwright execute
```

## Plan Commands (Read-only)

The `/planwright` command scans the codebase and generates plan items in `.planwright/plan.md`.

```bash
/planwright                      Plan from audit (propose 5, default settings)
/planwright <instruction>        Break a specific request into plan items
/planwright propose <N>          Override items proposed this run (1..max)
/planwright max <N>              Override the pending-item cap for this run
/planwright no-compact           Skip lifecycle housekeeping (no archive/drain this run)
/planwright dry-run              Do all stages but print the plan instead of writing the file
/planwright help                 Show the help and stop
```

You can combine options and instructions. For example:
```bash
/planwright add OAuth login propose 3 dry-run
```

### Options Explained

| Option | Default | Effect |
|--------|---------|--------|
| `<instruction>` | none | A free-text request to break down into plan items. |
| `propose <N>` | `5` | Number of items to propose this run (clamped to `1..max`). |
| `max <N>` | `20` | Cap on pending, unchecked items in the active plan. |
| `no-compact` | off | Skip the lifecycle housekeeping stage (no archiving or draining). |
| `dry-run` | off | Run the whole pipeline but only print the items, writing nothing. |

## Execute Commands (Edits Source)

The `execute` subcommand implements the pending items in the `.planwright/plan.md` file. It requires a clean git working tree before starting.

```bash
/planwright execute              Auto: implement every pending item, commit each that passes
/planwright execute --interactive  Prompt per item: approve, show diff, verify, confirm commit
/planwright execute N            Implement only pending item number N
```

### Execute Modes

- **Auto Mode** (`/planwright execute`): Runs through all pending items in order, implements them, verifies them, and automatically commits the successful ones. Pauses only if there is a hard blocker or a failing final verification. Note: Claude Code's standard permission prompts for edits and commits still apply.
- **Interactive Mode** (`--interactive`): Halts on every item to let you approve the implementation, show the diff, run the verification, and explicitly confirm the commit.
- **Targeted Mode** (`N`): Executes only the `N`th pending item.

## Output Format

Items are generated in a precise 8-field checkbox format within `.planwright/plan.md`. This format is strict so that it can be parsed and executed cleanly.

```markdown
- [ ] <Feature or fix title>
      Mode: <develop|improve|repair|docs|reorganize>
      Rationale: <one concise sentence grounded in audit findings or non-comment code evidence>
      Evidence: <specific audit finding or project implementation signal that proves the gap>
      Surfaces: <comma-separated existing repo-relative files that already exist and will change>
      New Surfaces: <comma-separated repo-relative files to create; omit this line if none>
      Development: <concrete implementation advice naming the first seam/call site/tests to update>
      Acceptance: <observable completion criteria or preserved behavior>
      Verification: <exact command, prefer: ctest --test-dir build -R "<target>" --output-on-failure>
```

### Modes

- `develop`: new runtime behavior, user-visible automation, new APIs, feature integration
- `improve`: behavior-preserving refactor, test coverage, consistency, performance
- `repair`: build failures, correctness bugs, test failures
- `docs`: documentation gaps, README updates
- `reorganize`: file layout, header/source misalignment

## Rejection Schema

If an item fails execution (after retry attempts), it is reverted to prevent a dirty tree, and is appended with rejection details before moving to `.planwright/rejected.md`. The format adds two lines to the item:

```markdown
      Status: Rejected
      Rejection: <one concise reason: what failed and why>
```

These rejected reasons are fed back into the next planning run to prevent planwright from proposing the same doomed work again.
