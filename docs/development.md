# Development

Helper scripts for developing `planwright` live in the `scripts/` directory.

## Typical Development Loop

When modifying the distribution, the standard workflow is:

1. Edit the core skill code (e.g., `skills/planwright/SKILL.md`).
2. Commit your change. `bump-version.sh` refuses to run on a dirty tree (see
   [`bump-version.sh`](#bump-versionsh) below), so the edit must be committed first.
3. Run the bump script on the now-clean tree to patch the version and document the change:
   ```bash
   scripts/bump-version.sh patch -m "Your change note"
   ```
4. Commit the version bump.
5. Update the host package locally to test. For Claude Code:
   ```bash
   /plugin marketplace update eserlxl
   ```
   For Codex plugin packaging, reinstall the local plugin from the marketplace entry that points at
   this repo, or start a new thread after updating a direct `~/.agents/skills/planwright` symlink/copy.

If you deliberately want to bump alongside uncommitted edits (collapsing steps 1–4 into a
single commit), pass `ALLOW_DIRTY=1` to skip the guard:

```bash
ALLOW_DIRTY=1 scripts/bump-version.sh patch -m "Your change note"
```

## Tests

The whole suite runs in one process via `bash tests/run.sh`, which sources `tests/lib.sh` and
then each topic fragment under `tests/cases/`. The suite is intentionally Python + Bash only (the
CI matrix installs neither Node nor a browser), so any check that needs another toolchain is
**gated on its tool and skips cleanly when absent** — exactly how `statics-scaffold.sh` gates its
`shellcheck` checks.

The one JS check follows this rule: `tests/cases/derive.sh` exercises the dashboard's pure-metrics
engine (`scripts/dashboard/vendor/derive.js`) under `node`. It shims `window`, runs the file, and
asserts `PW_DERIVE.pctRank`/`quantile`/`metrics` behave as documented. Where `node` is present it
really executes the engine; where it is absent (e.g. CI) it reports a clean skip, so the suite
stays green everywhere.

## Helper Scripts

### `bump-version.sh`

```bash
scripts/bump-version.sh <major|minor|patch|X.Y.Z> [-m "note"]
```

This script bumps the version globally across the plugin files. It updates:
- `.claude-plugin/plugin.json`
- `.claude-plugin/marketplace.json`
- `.codex-plugin/plugin.json` when present
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
scripts/make-plugin.sh [--no-gpg-sign] <plugin-name> [dest-dir]
```

Scaffolds a fresh, self-hosting Claude Code plugin. It creates:
- Manifest files (`plugin.json`, `marketplace.json`)
- A starter skill
- `README.md`, `CHANGELOG.md`, `.gitignore`, `LICENSE`
- A basic `tests/run.sh` smoke test
- A CI workflow
- Initializes a Git repository

It also bundles `bump-version.sh` into the new plugin.

By default, the initial scaffold commit respects your normal git signing configuration. Pass
`--no-gpg-sign` (alias: `--disable-gpg-signing`) to disable GPG signing for that initial commit, which
is useful in CI or sandboxed environments without a writable GPG home.

It honors several environment variables if set: `AUTHOR_NAME`, `AUTHOR_EMAIL`, `PLUGIN_DESC`, `NO_GIT=1`.

```bash
# Show usage and available env vars
scripts/make-plugin.sh --help
```

### `check-links.py`

Verifies that every intra-repo Markdown link and `#anchor` resolves, so a broken docs link
(e.g. a README pointer to a missing page) is caught instead of shipping. It is also run as part of
`bash tests/run.sh`, so the suite fails on a broken link.

```bash
# Check the whole repo's markdown (exit 0 when every link/anchor resolves)
python3 scripts/check-links.py

# Exit-code only, no output
python3 scripts/check-links.py --quiet
```
