# Releasing planwright

This runbook lets a second maintainer cut a release end to end. Every gate below is the same one
[CI](.github/workflows/ci.yml) runs, reproduced locally first, so a release never ships code CI would
reject. The version bump is **transactional** (all-or-nothing), so a failed bump leaves the tree
untouched — there is nothing to revert. See also [Development](docs/development.md).

## 1. Pre-release gates (all must pass on a clean tree)

Run the same gates CI runs, locally, in this order. A red gate blocks the release — fix it, never tag
past it.

| Gate | Local command | CI step |
|------|---------------|---------|
| **smoke** | `bash tests/run.sh` | `Smoke tests` |
| **link-check** | `python3 scripts/check-links.py --root .` | `Doc link integrity` |
| **coverage** | `bash scripts/coverage-gate.sh` (engine `coverage report --fail-under=90`) | `Coverage gate` |
| **JS coverage** | `python3 scripts/js-coverage-report.py "$PWD/.jscov" --root . --fail-under 73` | `JS coverage (dashboard)` |
| **lint / type** | `bash scripts/lint-gate.sh` | `Shellcheck scripts`, `Lint Python engine scripts` |
| **manifests** | JSON-parse `.claude-plugin/` / `.codex-plugin/` | `Validate plugin manifests` |

The `scripts/coverage-gate.sh` and `scripts/lint-gate.sh` helpers reproduce the CI gate ordering
exactly, so "green locally" means "green in CI".

## 2. Bump the version (transactional)

`scripts/bump-version.sh` updates the version literal in every manifest **atomically** — a mid-run
failure restores every file, so the tree never half-bumps — and appends the changelog note:

```
scripts/bump-version.sh <major|minor|patch|X.Y.Z> -m "<changelog note>"
```

**Rehearse first** with `--dry-run` (it prints what would change and writes nothing):

```
scripts/bump-version.sh minor -m "Add the hybrid-ai flag" --dry-run
```

Then run it for real. Choose the level by impact: `patch` for fixes, `minor` for a new
subcommand/option, `major` for a breaking change.

## 3. Tag and push

Commit the bump (the script stages the manifests + the changelog note), then tag and push:

```
git tag v<X.Y.Z>
git push && git push --tags
```

## 4. Update the marketplace

Publish the new version to the plugin marketplace registry (bump the version in the marketplace
entry and push it) so `/plugin marketplace update` installs pick up the release.

## Reverting

The bump is transactional, so a *failed* bump needs no revert. To pull a *pushed* release, revert the
bump commit and delete the tag (`git tag -d v<X.Y.Z>` and `git push --delete origin v<X.Y.Z>`), then
re-run the Section 1 gates before re-releasing.
