# Cursor / Codex Integration Example

To use the `planwright` workflow with Cursor or Codex in **other projects**, choose one of the setup paths below. Cursor works best as a host skill. Codex works best as a local plugin, with direct skill install as a simple alternative. The `AGENTS.md` pointer is a lightweight fallback when a project-local hint is enough.

> **Any AGENTS.md-aware agent works the same way.** Planwright is one agent-neutral `SKILL.md` plus stdlib-only helper scripts; each host integration is just a thin pointer to it. So the `AGENTS.md` block below is not Cursor/Codex-specific — it also drives **Windsurf, Cline, Roo Code, Amp, and Zed** (and any other agent that reads a project `AGENTS.md`) with no new adapter. Full graph-backed grounding requires the host to run the bundled Python helpers; agents that cannot execute scripts get the planning prose but not the file:line evidence.

> **Important:** Replace `/absolute/path/to/planwright` with the actual path where this repository is cloned on the machine (for example `/opt/lxl/claude/planwright`).

---

## Cursor: install as a host skill

Install planwright once on the machine so every project can invoke it without per-repo wiring.

1. Clone this repository to a fixed location, e.g. `/absolute/path/to/planwright`.
2. Copy or symlink the skill directory:

   ```bash
   mkdir -p ~/.cursor/skills
   ln -s /absolute/path/to/planwright/skills/planwright ~/.cursor/skills/planwright
   ```

   For a project-local skill shared via git instead:

   ```bash
   mkdir -p .cursor/skills
   ln -s /absolute/path/to/planwright/skills/planwright .cursor/skills/planwright
   ```

   The symlink must preserve the layout `skills/planwright/SKILL.md` with `scripts/` two levels up (`../../scripts/`), because the skill resolves `build-graph.py` and `lint-plan.py` from that path.

## Codex: install as a local plugin

The Codex plugin path is recommended because it preserves the repository layout that Planwright uses
to find `scripts/build-graph.py` and `scripts/lint-plan.py`.

1. Keep the clone at `/absolute/path/to/planwright`, or symlink/copy it into the personal plugin area:

   ```bash
   mkdir -p ~/plugins ~/.agents/plugins
   ln -s /absolute/path/to/planwright ~/plugins/planwright
   ```

2. Create or update `~/.agents/plugins/marketplace.json`:

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

   The `./plugins/planwright` path is resolved relative to the personal marketplace root (`~`), not
   relative to `~/.agents/plugins/`.

3. Install from the personal marketplace:

   ```bash
   codex plugin add planwright@personal
   ```

4. Start a new Codex thread after installing or reinstalling the plugin.

## Codex: direct skill alternative

Codex reads direct user skills from `~/.agents/skills` and follows symlinked skill folders. Symlinking
is preferred here because Planwright resolves bundled scripts from `../../scripts/` relative to
`skills/planwright`.

   ```bash
   mkdir -p ~/.agents/skills
   ln -s /absolute/path/to/planwright/skills/planwright ~/.agents/skills/planwright
   ```

*(Optional)* For `cod*` shortcuts without an `AGENTS.md` block, add small dispatcher skills under the host's skill directory that read the matching `commands/<name>.md` for argument resolution, then load `skills/planwright/SKILL.md` with the resolved planwright argument string. The bundled command files include the Claude Code `planwright:planwright` hand-off as one adapter; on Cursor or Codex, read the planwright `SKILL.md` directly or use the host's native skill invocation.

**Invoke in chat:**

- Cursor: `@planwright` — or type `planwright` with arguments, e.g. `planwright cycle 3`, `planwright execute`, `planwright depth 9 add OAuth login`
- Codex: `planwright cycle 3`, `planwright execute`, or `planwright depth 9 add OAuth login`
- `@codvisor` / `codvisor` — flagship advisor run (`cycle 10 depth 10 explore`)
- `@codinventor` / `codinventor` — flagship inventor run (`cycle 10 depth 10 invent`)
- `@codcycle` / `codcycle` — explore→invent alternation: each outer cycle runs one `cycle 3 depth 10 explore` then a framing-rotated `cycle 3 depth 10 invent`, with one closing explore (recipe in `commands/codcycle.md`)
- `@codshard` / `codshard` — sharded maturity sweep: one scoped `cycle 3 depth 10` round per shard in staleness order, then one closing whole-repo round (recipe in `commands/codshard.md`)
- `@codmaster` / `codmaster` — the front door: sense the planning state via `scripts/status.py --recommend`, then run the required commands consecutively to the final point at depth 10 (`advise` = tell only; `safe` = no invention; `loop` = infinite; recipe in `commands/codmaster.md`)
- `@codpr` / `codpr` — PR ingest: turn the current branch's open PR (unresolved review threads + failing CI) into grounded plan items; `codpr handoff` prints the local push-back recipe (recipe in `commands/codpr.md`). planwright stays read-only toward GitHub

Run `planwright help` (or `@planwright help`) for the full option reference.

**Upgrade:** `git pull` in the planwright clone (or re-copy/re-link the skill). There is no Cursor plugin marketplace equivalent to Claude Code's `/plugin upgrade`; for Codex plugin packaging, reinstall the local plugin or start a new thread after updating a direct skill symlink/copy.

---

## Alternative: project `AGENTS.md` pointer

If a machine-wide skill install is not desired, copy the block below into a file named `AGENTS.md` in the **root of the target project** (the repo being planned, not the planwright clone). This is also the supported path for **Windsurf, Cline, Roo Code, Amp, Zed**, and any other agent that reads a project `AGENTS.md` — they all dispatch `planwright`, `codvisor`, `codinventor`, `codcycle`, `codshard`, `codmaster`, and `codpr` through the same shared skill.

```markdown
## planwright

When the user invokes **planwright**, **codvisor**, **codinventor**, **codcycle**, **codshard**, **codmaster**, or **codpr** (with or without a leading `@`), act as the planwright agent:

1. Read `/absolute/path/to/planwright/skills/planwright/SKILL.md` and follow it exactly for the resolved arguments.
2. Do not re-implement planwright logic inline — the skill owns all planning, execute, and cycle behaviour.

**Argument resolution for shortcuts** (mirror the bundled command stubs):

- `codvisor` with no args → `cycle 10 depth 10 explore` (print the cost banner from `commands/codvisor.md` first)
- `codvisor N` → `cycle N depth 10 explore`
- `codvisor N D` → `cycle N depth D explore`
- `codinventor` with no args → `cycle 10 depth 10 invent` (print the cost banner from `commands/codinventor.md` first)
- `codinventor N` → `cycle N depth 10 invent`
- `codinventor N D` → `cycle N depth D invent`
- If a `codvisor` / `codinventor` invocation includes `path <X>` or `lib <X>`, peel that scope pair first, resolve the remaining shortcut form, then append the scope after the resolved subcommand (`codvisor path src/auth/` → `cycle 10 depth 10 explore path src/auth/`; `codinventor 5 8 lib parser` → `cycle 5 depth 8 invent lib parser`). Also accept the `--`-prefixed aliases, normalising to the bare form first: `--path <X>` → `path <X>`, `--lib <X>` → `lib <X>`, `--scope <X>` → `path <X>` (both `--opt <X>` and `--opt=<X>` spellings)
- Any other `codvisor` / `codinventor` remainder → verbatim passthrough to planwright (same arguments as `planwright <args>`)
- `codcycle [N]` → follow the orchestration recipe in `commands/codcycle.md`: N outer cycles (default 10; negative = infinite), each an explore phase (`cycle 3 depth 10 explore`) then a framing-rotated invent phase (`cycle 3 depth 10 invent`), with one closing explore — each phase is an ordinary run of SKILL.md
- `codshard [args]` → follow the orchestration recipe in `commands/codshard.md`: partition the repo into shards, run one scoped `cycle 3 depth 10` round per shard sequentially (staleness order), then one closing whole-repo round (`explore` escalates only that closing round; `shards <a,b,c>` lists shards explicitly) — each round is an ordinary run of SKILL.md. An opt-in `parallel` prefetches read-only recon leads per shard via the host's native subagent backend, routing-only and never Evidence (rounds stay sequential); an explicit `parallel external` opts into the **optional external-agents** CLIs (agy/codex) for host-neutral recon off Claude Code — planwright never requires them, and they ship the shard tree to external providers (opt-in, never private IP)
- `codmaster [advise | [safe] [loop]] [path <X> | lib <X>]` → follow the orchestration recipe in `commands/codmaster.md`: sense via `scripts/status.py --root . --recommend`, dispatch the record's command as an ordinary SKILL.md run, re-sense, and repeat to the final point at depth 10 (never re-derive the recommendation in prose; if the engine cannot run, stop). With a peeled `path <X>` / `lib <X>` scope, thread it into the sense engine (`scripts/status.py --root . --recommend --scope path:<X>`) so pending/debt/convergence are Focus-restricted, and trail the bare scope after every dispatch (`execute path <X>`); a scoped drive never auto-routes `codshard` or `reset` (whole-repo moves), so the harden stays a scoped `codvisor`
- `codpr [handoff | <N>]` → the planwright `pr` subcommand; every form prefixes `pr` (empty → `pr`, `handoff` → `pr handoff`, `123` → `pr 123`). Ingest the current branch's open PR (unresolved review threads + failing CI) as plan items, re-grounding every anchor against the live tree; `pr handoff` prints the local push-back recipe. Read-only toward GitHub — planwright never pushes, comments, resolves, or merges (the operator does that by hand)
- `planwright <args>` → pass `<args>` to the skill dispatcher described in SKILL.md

**Scripts:** resolve `build-graph.py` and `lint-plan.py` from `/absolute/path/to/planwright/scripts/` (not from the target repo's working directory).

**Artifacts:** planwright writes only under `<target>/.planwright/` in the project being planned. The plan path is read-only for application source; only `execute` and `cycle` edit source (with the host's normal approval prompts).
```

Replace `/absolute/path/to/planwright` in that block before saving `AGENTS.md`.
