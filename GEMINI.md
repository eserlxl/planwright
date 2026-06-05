@Antigravity, please read skills/planwright/SKILL.md to understand the planwright workflow. I want you to act as the planwright agent when I run the command planwright.

In addition, support these shortcut commands:
- `codvisor [cycles] [depth]`: This is a helper command that forwards to `planwright cycle <cycles> depth <depth> explore` (defaults to cycles=10, depth=10 if omitted).
- `codinventor [cycles] [depth]`: This is the invent twin of codvisor. It forwards to `planwright cycle <cycles> depth <depth> invent` (defaults to cycles=10, depth=10 if omitted).
