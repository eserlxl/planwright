# Usage

`planwright` provides commands for planning your work (read-only) and executing it (mutating).
It has one canonical argument grammar, `planwright <args>`; each host only changes the trigger token
(`/planwright` on Claude Code, `@planwright` on Cursor, and usually `planwright` in Codex,
Antigravity, or Gemini project instructions).

## Quick Start

```bash
# Propose a plan based on the current codebase
/planwright

# Execute the pending plan items automatically
/planwright execute
```

## Plan Commands (Read-only)

The `planwright` command (or host equivalent such as `/planwright`) scans the codebase and generates
plan items in `.planwright/plan.md`.

```bash
/planwright                      Plan from audit (depth 6, propose 5, default settings)
/planwright <instruction>        Break a specific request into plan items
/planwright depth <D>            Set analysis depth 1..10 (intensity + audit thoroughness; default 6)
/planwright propose <N>          Override items proposed this run (1..max)
/planwright max <N>              Override the pending-item cap for this run
/planwright no-compact           Skip lifecycle housekeeping (no archive/drain this run)
/planwright dry-run              Do all stages but print the plan instead of writing the file
/planwright path <X>             Scope the run to a subtree/glob (composes with execute/cycle)
/planwright lib <X>              Scope to a logical component (cluster / build target / package / dir)
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
| `path <X>` | whole repo | Scope the run to a subtree/glob: items land in that **Focus**; analysis still reads its 1-hop blast radius (**Context**). Composes with execute/cycle; orthogonal to `depth`. See **Component Scope** below. |
| `lib <X>` | whole repo | Like `path`, but resolve a logical component name (graph cluster / build target / package / directory) to the Focus set. |

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
/planwright cycle N invent seed S  Focus the invent burst through one seeded framing (invent-only)
```

### Execute Modes

- **Auto Mode** (`planwright execute`, `/planwright execute` on Claude Code): Runs through all pending items in order, implements them, verifies them, and automatically commits the successful ones. Pauses only if there is a hard blocker or a failing final verification. The host agent's standard permission prompts for edits, shell commands, and commits still apply.
- **Interactive Mode** (`--interactive`): Halts on every item to let you approve the implementation, show the diff, run the verification, and explicitly confirm the commit.
- **Targeted Mode** (`N`): Executes only the `N`th pending item.
- **Cycle Mode** (`cycle N`): Automates the workflow by running a planning phase followed by an execute phase, repeated `N` times, climbing a maturity ladder (repair → coverage → opportunity → vision) so a clean tree keeps producing valuable work. Positive N must be in the range 1–100; use a negative number (e.g., `-1`) to run unlimited rounds until it reaches a recorded final point (all rungs dry, recorded in `.planwright/final.md`). Append `depth D` to plan at depth `D` (1–10) on every round, e.g. `/planwright cycle 3 depth 8`.
- **Explore** (`cycle N explore`): Opt-in, cycle-only. By default a cycle stops as soon as it reaches the final point; with `explore`, reaching the final point instead **escalates through a ladder** rather than stopping, spending the remaining cycle budget (the `N` you asked for becomes an escalation budget): **① a cold-frontier sweep** of the code the default hot-core routing neglects (never-audited nodes and uncovered paths, via the graph's `ranked_cold` list), then **② the expand tier** — surveying the whole project for a *natural completion or generalization of what already exists* (capabilities implemented but not exposed, functionality the design implies but lacks, options that remove a hard-coded limit, helpers that consolidate repeated logic, and the tests that must precede such work). Each tier runs until dry before the next; if any tier finds grounded, above-bar work it does it and the cycle continues. When the hot core, cold frontier, **and** expand are all dry it records a stronger *deep* final point and stops. Two limits never move: the **grounding floor** (every item still cites a real seam and a runnable verification) and the **hard ceiling** (no new subsystems, unrelated domains, redesign, or speculation) — `explore` only *completes and generalizes* what exists, it never invents a new concept. Valid with any non-zero N (including `-1`); **orthogonal to `depth`** (every tier, including the cold-frontier sweep, runs at the cycle's depth — so `/planwright cycle 10 depth 10 explore` reads the frontier at full intensity).
- **Invent** (`cycle N invent`): Opt-in, cycle-only; a **superset of `explore`** (if both are given, `invent` wins). It climbs the same ladder and then, once the expand tier is also dry, adds **③ a bounded invent burst** (at most 3 cycles, independent of `N`) under a raised *novelty dial*: it may now propose **genuinely net-new** capability — a concept not present today — **provided** each item still bolts to a real existing seam, serves the project's stated direction (PROJECT DIRECTION: mission/charter + README + roadmap), and stays under the same hard ceiling (still no new subsystems/domains/redesign). Typing `invent` *is* your permission to create — so the invent tier **must propose at least one net-new item** rather than ever return nothing: it does not get to declare itself dry just because the only remaining work would *extend* a deliberately minimal project. It ranks every net-new candidate that clears two never-relaxed gates — the **grounding floor** (a real seam, exact surfaces, a runnable verification) and the **structural hard ceiling** (no new subsystem/domain/redesign; one implementable change) — and emits the best one **even if it sits below the normal value bar or stretches a "small / dependency-light" mission preference**, flagging that in the item's Rationale so the plan stays honest. Consequence: under `invent` the tier (almost) never goes dry, so `cycle -1 invent` runs to its budget `N` rather than self-terminating; it stops only at plan capacity (20 pending items) or in the rare genuine empty where *no* candidate clears even the floor + structural ceiling (no seam left to extend), which it then reports with the reason. (This `must-generate` relaxation of the value bar/mission applies to **explicit `invent` only** — `explore` and the default still declare an honest final point rather than pad.) Because the tier must generate, a fresh `invent` run **never short-circuits** on a recorded final point: a `deepest_tier: invent` marker is informational only, so re-invoking `/codinventor` (or `cycle … invent`) at the same HEAD **re-surveys** and lands the next groundable net-new item instead of freezing at the first invent-dry point (Stage 1's escalation-reach rule). And an invent "empty" is now **earned, not asserted**: before it may conclude dry, a survey that comes up empty **auto-rotates through all five framings** (so an empty means every vantage was tried — *earned by breadth*), and a `deepest_tier: invent` may be written only after a **per-seam audit** justifies, for every candidate seam, why no extension clears the floor/ceiling — "below the value bar", "stretches the mission", and unjustified "trivial" are **not** valid empty-reasons (they make invent emit that seam's candidate instead) (*earned by rigor*). The audits are recorded in `.planwright/final.md` as `invent_framings_tried` and `invent_seams_examined`.
- **Mission amendment** (`invent` only, rare, dwell-gated): as a project grows, its charter can fall behind it. When invent is forced to stretch `MISSION.md` for **3 consecutive** bursts (it tracks `mission_pressure` in `.planwright/final.md`), it earns **one** small, committed edit to the mission: that cycle proposes a single `docs`-mode amendment item (one constraint relaxed or clause added, with the features it unlocks), and the **next** cycle plans under the amended mission — so invent never invents against a mission it loosened in the same run. The edit is its own revertible commit; the run **announces up front** that invent may edit repo files including `MISSION.md`. It can relax a *preference* (e.g. "small, dependency-light") but never authorize a new subsystem/domain/redesign (the structural hard ceiling holds), and never touches protected paths (`.git/`, `.planwright/` internals, `LICENSE`, secrets). `explore` and the default never edit the mission.
- **Seeded framing** (`cycle N invent seed S`): Opt-in, **`invent`-only** (ignored otherwise). By default the invent burst surveys *comprehensively* and deterministically — but on a large, multi-domain codebase that means repeated runs re-derive the same few obvious ideas. A `seed` *focuses* the invent survey through one recorded **framing** — a vantage from a fixed catalog (`power-user`, `integration`, `onboarding`, `reliability`, `automation`) — so a single run explores net-new ideas *from that angle*, and successive seeds explore different angles. It changes *which* candidates are surveyed (never the grounding floor or structural ceiling): every proposal still cites a real seam and a runnable verification. Combined with `invent`'s must-generate rule, a seed steers *which* net-new feature the run lands on, so successive seeds explore different angles. The leverage **scales with the codebase's idea space** — on a large multi-domain repo each seed lands a materially different feature; on a small one it mostly varies the angle of the (still required) net-new item across runs. The seed and chosen framing are recorded in `.planwright/final.md` (`invent_seed`/`invent_framing`) so a run is replayable.

### Component Scope (`path` / `lib`)

Both are opt-in **options** (not subcommands), so they compose with any path — plan, `execute`, or
`cycle` — and are **orthogonal to `depth`**: `/planwright path src/auth/ cycle 5 depth 8`,
`/planwright lib parser execute`.

- **`path <X>`** scopes to a literal subtree or glob (`path src/auth/`, `path 'src/**/parser*'`).
- **`lib <X>`** resolves a *logical* component name to the same kind of file set, best-effort and in
  order: an exact graph **cluster label**, then a **build target** (CMake `add_library`, a Cargo
  crate/workspace member, an npm workspace, a Python package, a Go package), then a **directory** named
  `<X>`.

A scope resolves into two sets (see [Scope design](scope-design.md)):

- **Focus** — the scoped files. Plan items are *proposed and land* only here (Stage 10 enforces it).
- **Context** — Focus **plus its 1-hop import/coupling blast radius**. This is what analysis *reads*, so
  an upstream root cause and downstream impact stay visible instead of being walled off. One exception
  lets a `repair` item touch a Context (upstream) file when its evidence proves the in-Focus symptom
  traces there.

Under a scope the maturity ladder is unchanged but its reach narrows: change-gated rungs scope to
`dirty ∩ Focus`, and the opportunity/vision rungs survey **Focus-wide** — so a scoped `cycle` matures
just that component and records a **scoped** final point that never suppresses a later whole-repo run. A
pathspec that matches nothing is a hard error (never a silent whole-repo fallback).

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
Use slash spelling on Claude Code and the bare names (`codvisor`, `codinventor`) or host dispatcher
skills/instructions elsewhere.

```bash
/codvisor                  Flagship advisor run: cycle 10 depth 10 explore (prints a cost banner first)
/codvisor 15               cycle 15 depth 10 explore (one number = cycles; depth defaults to 10)
/codvisor 5 8              cycle 5 depth 8 explore (cycles, depth)
/codinventor               Flagship inventor run: cycle 10 depth 10 invent (reaches the net-new invent tier)
/codinventor 15            cycle 15 depth 10 invent
/codinventor 5 8           cycle 5 depth 8 invent (cycles, depth)
```

`/codcycle` is a Claude Code orchestration command (not a single-invocation alias): per *outer cycle*
it drives the planwright skill through three phases back-to-back — `cycle 3 depth 10 explore`, then
`cycle 3 depth 10 invent`, then `cycle 3 depth 10 explore` — a **harden → grow → harden** rhythm. With
no argument it runs 10 outer cycles; one integer sets the outer-cycle count, and a negative count runs
forever. It stops early on a hard blocker, a failing broad verify, or a full outer cycle that produces
no new committed work (a stable meta-final-point). Because every outer cycle includes an `invent` phase,
that phase may make rare, small committed edits to repo files, including `MISSION.md`.

```bash
/codcycle                  10 outer cycles (explore → invent → explore, cycle 3 depth 10 each)
/codcycle 3                3 outer cycles
/codcycle -1               run the explore → invent → explore rhythm until stopped (negative = infinite)
```

After any `invent` run finishes, planwright closes its report with a one-line suggestion to run
`/codvisor` or the host's `codvisor` equivalent (the flagship `cycle 10 depth 10 explore` sweep) to
harden the net-new code — the invent tier's final burst never gets a later planning round's deep
repair/coverage audit, and `codvisor` provides it. It is a **suggestion only**: planwright never auto-runs it, so you keep the beat to
inspect or revert flagged invent-tier items before hardening them.

## Maintenance

```bash
/planwright doctor               Preflight: check git/rg/python3 + bundled-script resolution
/planwright version              Show the current and latest available version
/planwright upgrade              Update planwright itself to the latest version (alias: update)
```

`doctor` is read-only: it reports which host tools (`git`, `rg`, `fd`) and bundled scripts
(`build-graph.py`, `lint-plan.py`, `lifecycle.py`) are available, what degrades when one is missing,
and whether the target is a git work tree — a preflight so a run's fallbacks surface up front rather
than mid-pipeline. It exits non-zero when a core capability (`git` or a bundled script) is unavailable.

`version` is read-only: it reports the installed version from the detected host metadata when
available (`~/.claude/plugins/installed_plugins.json` for Claude Code, `.codex-plugin/plugin.json` for
Codex packaging, or the skill frontmatter for direct skill installs) against the latest local source it
can resolve. `/planwright help` on Claude Code, or `planwright help` elsewhere, also prints the running
version in its header.

`upgrade` (or `update`) neither plans nor edits your project — it refreshes the planwright
distribution. It resolves the local planwright root, fast-forwards it if it is a clean git clone,
reports the installed version versus the latest, then gives the host-specific handoff:

```bash
# Claude Code plugin installs
/plugin marketplace update eserlxl
/reload-plugins
```

Run `/plugin install planwright@eserlxl` between those two only if the version did not advance. For
Codex, reinstall the local plugin from the marketplace that points at this repo, or start a new thread
after updating a direct `~/.codex/skills/planwright` symlink/copy. For Cursor, Antigravity, and Gemini,
update the clone or copied skill and reload the host context if it caches instructions.

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

## Troubleshooting & interpreting output

planwright tells you *what* it did but not always *why* at a glance. This section maps the common
"why did it do that?" moments to the state files under `.planwright/`.

### "It wrote 0 items" — is that a problem?

A run that writes no items is usually **correct**, not stuck. The summary now appends a **zero-item
diagnostic** naming which of three reasons applies:

- **`capacity`** — the plan already holds `max` (default 20) pending items. Execute or prune them, then
  re-plan. Not a defect.
- **`already-at-final-point`** — Stage 1 short-circuited because `.planwright/final.md` records this exact
  HEAD sha with an empty dirty set and all rungs dry. The project genuinely has no groundable work at this
  ambition. Raise ambition to re-open it (see below).
- **`all-rungs-dry`** — all four maturity rungs (repair → coverage → opportunity → vision) were surveyed
  (the upper two project-wide) and nothing cleared its value bar. The diagnostic names the **closest
  miss** — the highest-value candidate dropped and the one gate it failed.

To re-open work after a final point: give an explicit instruction (`/planwright add <X>`), raise `depth`,
or escalate (`/planwright cycle -1 explore`, or `invent`) — a deeper escalation flag than the recorded
`deepest_tier` always re-surveys. Any run that changes code (non-empty dirty set) also re-opens it.

### Reading `.planwright/final.md`

A **final point** is a *justified* stop, not an idle. The block records the HEAD sha, each rung marked
dry with a one-line reason, and — under `explore`/`invent` — a `deepest_tier:` (`hot-core` →
`cold-frontier` → `expand` → `invent`). `deepest_tier: expand` is the strong "deep final point" (cold
frontier and expand both dry). An `invent` run normally writes **no** `final.md` (it must keep generating
groundable net-new work) and instead runs to its cycle budget.

### "STOP: working tree not clean"

`execute` and `cycle` refuse to run on a dirty tree so per-item commits never entangle your uncommitted
work. Commit or stash your changes first. `.planwright/` itself is ignored and does **not** count as dirty.

### "scope '<X>' matched no files"

A `path`/`lib` scope that resolves to an empty Focus is a **hard error** by design — planwright never
silently falls back to a whole-repo run. Check the path/glob, or for `lib <X>` confirm the cluster /
build-target / package / directory name actually exists (planwright resolves the logical name to paths in
Stage 1; see **Component Scope**).

### "The audit looked at the wrong files"

Routing is driven by the Stage 1.5 code graph. To see *why* a file ranked where it did — PageRank,
articulation flags, churn, and the centrality-vs-coupling signal — run the builder with `--debug`:

```bash
python3 <scripts>/build-graph.py --debug > .planwright/graph.json
```

The digest goes to **stderr** (stdout stays clean JSON), and shows `ranked` (all node types — docs can
float up via link-centrality), `ranked_code` (the `branch_count > 0` list Stage 2b actually traces), and
`ranked_cold` (the explore cold-frontier order). If docs outrank code in `ranked`, that is expected;
Stage 2b uses `ranked_code`.

### Where state lives (tool-owned — never edit by hand as a plan Surface)

- `.planwright/plan.md` — pending + completed items.
- `.planwright/completed.md` / `rejected.md` — drained history (FIFO-capped at 100); rejected reasons feed
  the next run.
- `.planwright/graph.json` / `digest.md` — audit routing memory. **Routing only — never valid Evidence.**
- `.planwright/final.md` — the recorded final point.
- `.planwright/plans/` — archived past plans.
