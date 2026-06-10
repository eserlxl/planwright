# Version (show current and latest)

Reached via `planwright version` (or `--version`, `-V`; `/planwright version` on Claude Code).
Read-only — it neither plans nor edits.

## Procedure (version)

1. **Current** — the installed/running version. Prefer the detected host install metadata:
   `~/.claude/plugins/installed_plugins.json` for Claude Code, `.codex-plugin/plugin.json` for a Codex
   plugin root, or this file's frontmatter `metadata.version` for direct skill installs.
2. **Latest** — read the version from the resolved planwright root's manifest, preferring
   `.codex-plugin/plugin.json` on Codex, `.claude-plugin/plugin.json` on Claude Code, and this file's
   frontmatter as a fallback. If the source is remote-only or cannot be resolved locally, report latest
   as `unknown (run planwright upgrade from the host that installed it)`.
3. **Report** one line: `planwright <current> (latest <latest>)`. If latest > current, add
   `→ upgrade available: run planwright upgrade`; if equal, add `→ up to date`.

STOP after reporting.

