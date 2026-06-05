# Antigravity / Gemini Integration Example

If you want to use the `planwright` workflow with Antigravity or Gemini in **other projects**, copy the content below into a file named `GEMINI.md` in the root directory of your target project.

> **Important:** Be sure to replace `/absolute/path/to/planwright` with the actual path where you cloned this repository on your machine.

---

Please read /absolute/path/to/planwright/skills/planwright/SKILL.md to understand the planwright workflow. Act as the planwright agent when I run the command `planwright`.

In addition, support these shortcut commands:
- `codvisor [cycles] [depth]`: This is a helper command that forwards to `planwright cycle <cycles> depth <depth> explore` (defaults to cycles=10, depth=10 if omitted).
- `codinventor [cycles] [depth]`: This is the invent twin of codvisor. It forwards to `planwright cycle <cycles> depth <depth> invent` (defaults to cycles=10, depth=10 if omitted).

For both shortcuts, first peel any `path <X>` or `lib <X>` pair from the arguments, resolve the remaining shortcut form, then append that scope after the resolved subcommand. Examples: `codvisor path src/auth/` resolves to `planwright cycle 10 depth 10 explore path src/auth/`; `codinventor 5 8 lib parser` resolves to `planwright cycle 5 depth 8 invent lib parser`.
