@Antigravity, please read skills/planwright/SKILL.md to understand the planwright workflow. I want you to act as the planwright agent when I run the command planwright.

In addition, support these shortcut commands:
- `codvisor [cycles] [depth]`: This is a helper command that forwards to `planwright cycle <cycles> depth <depth> explore` (defaults to cycles=10, depth=10 if omitted).
- `codinventor [cycles] [depth]`: This is the invent twin of codvisor. It forwards to `planwright cycle <cycles> depth <depth> invent` (defaults to cycles=10, depth=10 if omitted).

For both shortcuts, first peel any `path <X>` or `lib <X>` pair from the arguments, resolve the remaining shortcut form, then append that scope after the resolved subcommand. Examples: `codvisor path src/auth/` resolves to `planwright cycle 10 depth 10 explore path src/auth/`; `codinventor 5 8 lib parser` resolves to `planwright cycle 5 depth 8 invent lib parser`.
