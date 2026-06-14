# Antigravity / Gemini Integration Example

If you want to use the `planwright` workflow with Antigravity or Gemini in **other projects**, copy the content below into a file named `GEMINI.md` in the root directory of your target project.

> **Important:** Be sure to replace `/absolute/path/to/planwright` with the actual path where you cloned this repository on your machine.

---

@Antigravity, please read `/absolute/path/to/planwright/skills/planwright/SKILL.md` to understand the planwright workflow. Note that when the skill instructions refer to `<scripts>`, they mean `/absolute/path/to/planwright/scripts`. I want you to act as the planwright agent when I run the command planwright.

In addition, support these shortcut commands:
- `codvisor [cycles] [depth]`: This is a helper command that forwards to `planwright cycle <cycles> depth <depth> explore` (defaults to cycles=10, depth=10 if omitted).
- `codinventor [cycles] [depth]`: This is the invent twin of codvisor. It forwards to `planwright cycle <cycles> depth <depth> invent` (defaults to cycles=10, depth=10 if omitted).
- `codcycle [N]`: The explore→invent alternator. Follow the orchestration recipe in `/absolute/path/to/planwright/commands/codcycle.md`: N outer cycles (default 10; negative = infinite), each one `cycle 3 depth 10 explore` then a framing-rotated `cycle 3 depth 10 invent`, with one closing explore; each phase is an ordinary planwright run.
- `codshard [args]`: The sharded maturity sweep. Follow the orchestration recipe in `/absolute/path/to/planwright/commands/codshard.md`: one scoped `cycle 3 depth 10` round per shard sequentially (staleness order), then one closing whole-repo round; each round is an ordinary planwright run.
- `codmaster [advise | [safe] [loop]] [path <X> | lib <X>]`: The front door. Follow the orchestration recipe in `/absolute/path/to/planwright/commands/codmaster.md`: sense via `python3 /absolute/path/to/planwright/scripts/status.py --root . --recommend`, dispatch the record's command as an ordinary planwright run, re-sense, and repeat to the final point at depth 10 (never re-derive the recommendation in prose; if the engine cannot run, stop). With a peeled `path <X>` / `lib <X>` scope, thread it into the sense engine (`... status.py --root . --recommend --scope path:<X>`) so pending/debt/convergence are Focus-restricted, and trail the bare scope after every dispatch; a scoped drive never auto-routes `codshard` or `reset` (whole-repo moves), so the harden stays a scoped `codvisor`.

For the codvisor/codinventor shortcuts, first peel any `path <X>` or `lib <X>` pair from the arguments, resolve the remaining shortcut form, then append that scope after the resolved subcommand. Also accept the `--`-prefixed aliases, normalising to the bare form first: `--path <X>` → `path <X>`, `--lib <X>` → `lib <X>`, `--scope <X>` → `path <X>` (both `--opt <X>` and `--opt=<X>` spellings). Examples: `codvisor path src/auth/` resolves to `planwright cycle 10 depth 10 explore path src/auth/`; `codinventor 5 8 lib parser` resolves to `planwright cycle 5 depth 8 invent lib parser`.
