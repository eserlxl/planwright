# Cursor Integration Example

To use the `planwright` workflow with Cursor in **other projects**, choose one of the setup paths below. The skill install path is recommended; the `AGENTS.md` pointer is a lightweight alternative when a project-local hint is enough.

> **Important:** Replace `/absolute/path/to/planwright` with the actual path where this repository is cloned on the machine (for example `/opt/lxl/claude/planwright`).

---

## Recommended: install as a Cursor skill

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

3. *(Optional)* For `codvisor` / `codinventor` shortcuts without an `AGENTS.md` block, add small dispatcher skills under `~/.cursor/skills/` that read `commands/codvisor.md` or `commands/codinventor.md` for argument resolution, then load `skills/planwright/SKILL.md` with the resolved planwright argument string. The bundled command files target Claude Code's Skill tool; adapt the final hand-off to Cursor's skill loading (read the planwright `SKILL.md` directly rather than invoking `planwright:planwright`).

**Invoke in Cursor chat:**

- `@planwright` — or type `planwright` with arguments, e.g. `planwright cycle 3`, `planwright execute`, `planwright depth 9 add OAuth login`
- `@codvisor` / `codvisor` — flagship advisor run (`cycle 10 depth 10 explore`)
- `@codinventor` / `codinventor` — flagship inventor run (`cycle 10 depth 10 invent`)

Run `planwright help` (or `@planwright help`) for the full option reference.

**Upgrade:** `git pull` in the planwright clone (or re-copy the skill). There is no Cursor plugin marketplace equivalent to Claude Code's `/plugin upgrade`.

---

## Alternative: project `AGENTS.md` pointer

If a machine-wide skill install is not desired, copy the block below into a file named `AGENTS.md` in the **root of the target project** (the repo being planned, not the planwright clone).

```markdown
## planwright

When the user invokes **planwright**, **codvisor**, or **codinventor** (with or without a leading `@`), act as the planwright agent:

1. Read `/absolute/path/to/planwright/skills/planwright/SKILL.md` and follow it exactly for the resolved arguments.
2. Do not re-implement planwright logic inline — the skill owns all planning, execute, and cycle behaviour.

**Argument resolution for shortcuts** (mirror the bundled command stubs):

- `codvisor` with no args → `cycle 10 depth 10 explore` (print the cost banner from `commands/codvisor.md` first)
- `codvisor N` → `cycle N depth 10 explore`
- `codvisor N D` → `cycle N depth D explore`
- `codinventor` with no args → `cycle 10 depth 10 invent` (print the cost banner from `commands/codinventor.md` first)
- `codinventor N` → `cycle N depth 10 invent`
- `codinventor N D` → `cycle N depth D invent`
- Any other `codvisor` / `codinventor` remainder → verbatim passthrough to planwright (same as `/planwright` in Claude Code)
- `planwright <args>` → pass `<args>` to the skill dispatcher described in SKILL.md

**Scripts:** resolve `build-graph.py` and `lint-plan.py` from `/absolute/path/to/planwright/scripts/` (not from the target repo's working directory).

**Artifacts:** planwright writes only under `<target>/.planwright/` in the project being planned. The plan path is read-only for application source; only `execute` and `cycle` edit source (with the user's normal Cursor approval prompts).
```

Replace `/absolute/path/to/planwright` in that block before saving `AGENTS.md`.
