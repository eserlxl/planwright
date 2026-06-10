# Upgrade (update planwright itself)

Reached only via `planwright upgrade` (or the host equivalent such as `/planwright upgrade`). Updates
the installed planwright distribution. This path does **not** plan or edit your project; it only
refreshes planwright itself.

## Procedure (upgrade)

1. **Resolve the planwright root.** Prefer the skill base path (`skills/planwright`) and walk two
   directories up. If the host exposes an installed plugin source path, use that when it is more exact.
2. **Detect the host/package surface.**
   - Claude Code plugin: if `~/.claude/plugins/known_marketplaces.json` contains the `eserlxl`
     marketplace, read the installed version from `~/.claude/plugins/installed_plugins.json`
     (`planwright@eserlxl`) and the latest version from the marketplace source's
     `.claude-plugin/plugin.json`.
   - Codex plugin: if the planwright root contains `.codex-plugin/plugin.json`, read that manifest
     version and treat the current install as Codex-managed. If a local marketplace entry is known to
     the host, report it; otherwise report the local root path and do not guess a marketplace name.
   - Cursor, Antigravity/Gemini, or manual skill copy/symlink: read this file's frontmatter
     `metadata.version` and the local root's manifests when present.
3. **Refresh a local git source when possible.** If the resolved root is a git repo, run
   `git -C <planwright-root> pull --ff-only`. If that tree is dirty or the pull is not fast-forward,
   STOP and report; do not force it. If the install is a copied skill with no git root, report that the
   user must update the source clone and re-copy or re-link the skill.
4. **Report versions and host handoff.** Print current → latest when both are known; otherwise print
   current and the exact local root that was inspected. Then give only the handoff steps for the detected
   host:
   - Claude Code: `/plugin marketplace update eserlxl`, then `/plugin install planwright@eserlxl` only
     if needed, then `/reload-plugins`.
   - Codex: reinstall the local plugin from the marketplace that points at this root, or start a new
     thread after updating a direct `~/.agents/skills/planwright` symlink/copy.
   - Cursor: restart/reload Cursor's agent context after updating the clone or re-copying the skill.
   - Antigravity/Gemini: keep `GEMINI.md` pointing at the updated clone; no plugin reload is required
     unless the host caches project instructions.

Report: detected host/package surface, root path, old → new version when known, whether a local pull
ran, and the host-specific handoff steps.

