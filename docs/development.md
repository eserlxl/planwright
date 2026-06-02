# Development

Helper scripts for developing `planwright` live in the `scripts/` directory.

## Typical Development Loop

When modifying the plugin, the standard workflow is:

1. Edit the core skill code (e.g., `skills/planwright/SKILL.md`).
2. Run the bump script to patch the version and document your change:
   ```bash
   scripts/bump-version.sh patch -m "Your commit message or change note"
   ```
3. Commit the changes.
4. Update the plugin locally to test:
   ```bash
   /plugin marketplace update planwright
   ```

## Helper Scripts

### `bump-version.sh`

```bash
scripts/bump-version.sh <major|minor|patch|X.Y.Z> [-m "note"]
```

This script bumps the version globally across the plugin files. It updates:
- `plugin.json`
- `marketplace.json`
- Every `skills/*/SKILL.md` frontmatter
- `CHANGELOG.md`

By default, it refuses to run if your git tree is dirty, ensuring that your version bumps are clean commits. If you deliberately want to bump versions alongside other changes, you can override this by passing `ALLOW_DIRTY=1` as an environment variable.

Additional flags:

```bash
# Preview a bump without modifying any files
scripts/bump-version.sh --dry-run patch

# Show usage
scripts/bump-version.sh --help
```

### `make-plugin.sh`

```bash
scripts/make-plugin.sh <plugin-name> [dest-dir]
```

Scaffolds a fresh, self-hosting Claude Code plugin. It creates:
- Manifest files (`plugin.json`, `marketplace.json`)
- A starter skill
- `README.md`, `CHANGELOG.md`, `.gitignore`, `LICENSE`
- A basic `tests/run.sh` smoke test
- A CI workflow
- Initializes a Git repository

It also bundles `bump-version.sh` into the new plugin.

It honors several environment variables if set: `AUTHOR_NAME`, `AUTHOR_EMAIL`, `PLUGIN_DESC`, `NO_GIT=1`.

```bash
# Show usage and available env vars
scripts/make-plugin.sh --help
```
