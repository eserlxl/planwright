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
/planwright                      Plan from audit (depth 6, propose 5, default settings)
/planwright <instruction>        Break a specific request into plan items
/planwright depth <D>            Set analysis depth 1..10 (intensity + audit thoroughness; default 6)
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
| `depth <D>` | `6` | Analysis depth `1..10`. Scales reasoning intensity (low→ultra), Stage 2 audit sub-passes, function bodies read, Stages 3–7 lenses, and the default propose count. `1` = cosmetic pass, `10` = exhaustive audit. |
| `propose <N>` | from depth (`5` at depth 6) | Number of items to propose this run (clamped to `1..max`). |
| `max <N>` | `20` | Cap on pending, unchecked items in the active plan. |
| `no-compact` | off | Skip the lifecycle housekeeping stage (no archiving or draining). |
| `dry-run` | off | Run the whole pipeline but only print the items, writing nothing. |

## Execute Commands (Edits Source)

The `execute` subcommand implements the pending items in the `.planwright/plan.md` file. It requires a clean git working tree before starting.

```bash
/planwright execute              Auto: implement every pending item, commit each that passes
/planwright execute --interactive  Prompt per item: approve, show diff, verify, confirm commit
/planwright execute N            Implement only pending item number N
/planwright cycle N              Run N plan→execute rounds (1..100 for exact count, -N for unlimited)
/planwright cycle N depth D      Run the cycle with planning depth D (1..10) on every round
/planwright cycle N explore      At the final point, escalate: cold-frontier sweep → expand (latent capability)
/planwright cycle N invent       Like explore, plus permission to add net-new, seam-bound capability
```

### Execute Modes

- **Auto Mode** (`/planwright execute`): Runs through all pending items in order, implements them, verifies them, and automatically commits the successful ones. Pauses only if there is a hard blocker or a failing final verification. Note: Claude Code's standard permission prompts for edits and commits still apply.
- **Interactive Mode** (`--interactive`): Halts on every item to let you approve the implementation, show the diff, run the verification, and explicitly confirm the commit.
- **Targeted Mode** (`N`): Executes only the `N`th pending item.
- **Cycle Mode** (`cycle N`): Automates the workflow by running a planning phase followed by an execute phase, repeated `N` times, climbing a maturity ladder (repair → coverage → opportunity → vision) so a clean tree keeps producing valuable work. Positive N must be in the range 1–100; use a negative number (e.g., `-1`) to run unlimited rounds until it reaches a recorded final point (all rungs dry, recorded in `.planwright/final.md`). Append `depth D` to plan at depth `D` (1–10) on every round, e.g. `/planwright cycle 3 depth 8`.
- **Explore** (`cycle N explore`): Opt-in, cycle-only. By default a cycle stops as soon as it reaches the final point; with `explore`, reaching the final point instead **escalates through a ladder** rather than stopping, spending the remaining cycle budget (the `N` you asked for becomes an escalation budget): **① a cold-frontier sweep** of the code the default hot-core routing neglects (never-audited nodes and uncovered paths, via the graph's `ranked_cold` list), then **② the expand tier** — surveying the whole project for a *natural completion or generalization of what already exists* (capabilities implemented but not exposed, functionality the design implies but lacks, options that remove a hard-coded limit, helpers that consolidate repeated logic, and the tests that must precede such work). Each tier runs until dry before the next; if any tier finds grounded, above-bar work it does it and the cycle continues. When the hot core, cold frontier, **and** expand are all dry it records a stronger *deep* final point and stops. Two limits never move: the **grounding floor** (every item still cites a real seam and a runnable verification) and the **hard ceiling** (no new subsystems, unrelated domains, redesign, or speculation) — `explore` only *completes and generalizes* what exists, it never invents a new concept. Valid with any non-zero N (including `-1`); **orthogonal to `depth`** (every tier, including the cold-frontier sweep, runs at the cycle's depth — so `/planwright cycle 10 depth 10 explore` reads the frontier at full intensity).
- **Invent** (`cycle N invent`): Opt-in, cycle-only; a **superset of `explore`** (if both are given, `invent` wins). It climbs the same ladder and then, once the expand tier is also dry, adds **③ a bounded invent burst** (at most 3 cycles, independent of `N`) under a raised *novelty dial*: it may now propose **genuinely net-new** capability — a concept not present today — **provided** each item still bolts to a real existing seam, serves the project's stated direction (PROJECT DIRECTION: mission/charter + README + roadmap), and stays under the same hard ceiling (still no new subsystems/domains/redesign). Typing `invent` *is* your permission to create; it relaxes only the "must already be latent" rule, never the floor or ceiling. When the cold frontier, expand, **and** an invent burst are all dry it records the deepest final point and stops.

### Broad Final Verification (warnings gate)

After the targeted items, both `execute` and `cycle` run a **broad final verification** — the project's
full build + test suite (not just per-item focused tests), plus a **warnings-clean gate**: where the
project's own build / lint / type-check emits warnings, any **new** warning this run introduced is
must-fix (a one-line, narrowest-scope suppression with justification is the only escape hatch). It is a
no-op for toolchains that emit no warnings, and it never blocks on a project's pre-existing warning
baseline the run did not touch. A green per-item verify that breaks the overall build — or introduces a
new warning — fails this gate.

## Helper Commands

Two thin shortcuts forward to the planwright skill; any planwright arguments pass through verbatim.

```bash
/codvisor                  Flagship advisor run: cycle 10 depth 10 explore (prints a cost banner first)
/codvisor 15               cycle 15 depth 10 explore (one number = cycles; depth defaults to 10)
/codvisor 5 8              cycle 5 depth 8 explore (cycles, depth)
/codinventor               Flagship inventor run: cycle 10 depth 10 invent (reaches the net-new invent tier)
/codinventor 15            cycle 15 depth 10 invent
/codinventor 5 8           cycle 5 depth 8 invent (cycles, depth)
```

## Maintenance

```bash
/planwright version              Show the current and latest available version
/planwright upgrade              Update planwright itself to the latest version (alias: update)
```

`version` is read-only: it reports the installed version (from
`~/.claude/plugins/installed_plugins.json`) against the latest at the marketplace source, e.g.
`planwright 1.7.0 (latest 1.7.0) → up to date`. `/planwright help` also prints the running version
in its header.

`upgrade` (or `update`) neither plans nor edits your project — it refreshes the planwright plugin. It locates the
`eserlxl` marketplace source, fast-forwards it if it is a local git clone, reports the installed
version versus the latest, then hands you the interactive steps it cannot run itself:

```bash
/plugin marketplace update eserlxl
/reload-plugins
```

(Run `/plugin install planwright@eserlxl` between those two only if the version did not advance.)

## Graph Memory (audit routing)

To keep audits affordable on large codebases, the plan path builds a structural **graph memory** before auditing (Stage 1.5) and persists it under the gitignored `.planwright/`:

- **`.planwright/graph.json`** — every tracked file as a node with its content hash, plus **import edges** (extracted per language) and **change-coupling edges** (files that co-commit in git history). Over that graph planwright computes **PageRank** (centrality) and **articulation points** (fragile chokepoints), then a ranked node list.
- **What it changes:** the audit reads the highest-blast-radius code first instead of sweeping uniformly, and on repeat runs it re-audits only the **dirty subgraph** — files whose hash changed since they were last audited, plus their 1-hop blast radius along import and coupling edges. A first run, a config/version change, or an unavailable graph falls back to auditing everything.
- **`.planwright/digest.md`** — one routing-only summary block per cluster, carried forward between runs. It is marked `UNVERIFIED — routing only` and **can never be cited as Evidence**; the graph routes attention, but every plan item's proof must come from code re-read that run.

See [Graph memory](graph-memory-schema.md) for the full `graph.json` schema and the per-stage build procedure.

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
