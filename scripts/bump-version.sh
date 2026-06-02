#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Eser KUBALI
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Bump the plugin version in lockstep across plugin.json, marketplace.json,
# and CHANGELOG.md.
#
# This script updates version numbers and the changelog — it does NOT create a
# git tag or GitHub release. Tags should only be created at release milestones:
# every 25-50 commits or when a meaningful feature ships (new subcommand, major
# behaviour change). Run bump-version.sh freely during development; tag and
# push the release manually when the milestone is reached.
#
# Usage:
#   scripts/bump-version.sh <major|minor|patch|X.Y.Z> [-m "changelog note"]
#
# Examples:
#   scripts/bump-version.sh patch
#   scripts/bump-version.sh minor -m "Add foo option"
#   scripts/bump-version.sh 2.0.0 -m "Rewrite the pipeline"
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PLUGIN_JSON="$ROOT/.claude-plugin/plugin.json"
MARKET_JSON="$ROOT/.claude-plugin/marketplace.json"
CHANGELOG="$ROOT/CHANGELOG.md"

usage() {
  echo "Usage: $(basename "$0") <major|minor|patch|X.Y.Z> [-m \"changelog note\"]" >&2
  exit 1
}

[ $# -ge 1 ] || usage
[ "$1" = "-h" ] || [ "$1" = "--help" ] && { echo "Usage: $(basename "$0") <major|minor|patch|X.Y.Z> [-m \"changelog note\"]"; exit 0; }
BUMP="$1"; shift
NOTE=""
DRY_RUN=""
while [ $# -gt 0 ]; do
  case "$1" in
    -m|--message) NOTE="${2:-}"; shift 2 ;;
    --dry-run)    DRY_RUN=1; shift ;;
    -h|--help) echo "Usage: $(basename "$0") <major|minor|patch|X.Y.Z> [-m \"changelog note\"]"; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage ;;
  esac
done

for f in "$PLUGIN_JSON" "$MARKET_JSON" "$CHANGELOG"; do
  [ -f "$f" ] || { echo "Missing required file: $f" >&2; exit 1; }
done

# Refuse to mutate a dirty tree so the bump's edits stay isolated and revertible.
# Skipped when not inside a git work tree (e.g. the test harness) or ALLOW_DIRTY=1.
if [ "${ALLOW_DIRTY:-0}" != "1" ] && git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  if [ -n "$(git -C "$ROOT" status --porcelain)" ]; then
    echo "Working tree not clean; commit or stash first, or set ALLOW_DIRTY=1." >&2
    exit 1
  fi
fi

CURRENT="$(python3 -c "import json;print(json.load(open('$PLUGIN_JSON'))['version'])")"

NEW="$(python3 - "$CURRENT" "$BUMP" <<'PY'
import re, sys
cur, bump = sys.argv[1], sys.argv[2]
if re.fullmatch(r"\d+\.\d+\.\d+", bump):
    print(bump); raise SystemExit
try:
    major, minor, patch = (int(x) for x in cur.split("."))
except ValueError:
    sys.stderr.write(f"Current version '{cur}' is not X.Y.Z\n"); raise SystemExit(1)
if bump == "major":   major, minor, patch = major + 1, 0, 0
elif bump == "minor": minor, patch = minor + 1, 0
elif bump == "patch": patch += 1
else:
    sys.stderr.write("bump must be one of: major | minor | patch | X.Y.Z\n"); raise SystemExit(1)
print(f"{major}.{minor}.{patch}")
PY
)"

DATE="$(date -u +%Y-%m-%d)"

# --- Update both JSON manifests -------------------------------------------
if [ -z "$DRY_RUN" ]; then
python3 - "$PLUGIN_JSON" "$MARKET_JSON" "$NEW" <<'PY'
import json, sys
plugin_path, market_path, new = sys.argv[1:4]

with open(plugin_path) as f:
    plugin = json.load(f)
name = plugin.get("name")
plugin["version"] = new
with open(plugin_path, "w") as f:
    json.dump(plugin, f, indent=2); f.write("\n")

with open(market_path) as f:
    market = json.load(f)
market.setdefault("metadata", {})["version"] = new
for entry in market.get("plugins", []):
    if entry.get("name") == name:
        entry["version"] = new
with open(market_path, "w") as f:
    json.dump(market, f, indent=2); f.write("\n")
PY
fi

# --- Sync skill frontmatter versions --------------------------------------
SKILLS_SYNCED=""
if [ -z "$DRY_RUN" ]; then
for skill in "$ROOT"/skills/*/SKILL.md; do
  [ -f "$skill" ] || continue
  rel="$(realpath --relative-to="$ROOT" "$skill")"
  changed="$(python3 - "$skill" "$NEW" <<'PY'
import re, sys
path, new = sys.argv[1], sys.argv[2]
with open(path) as f:
    text = f.read()
# Rewrite the metadata version line in the YAML frontmatter (2-space indent).
text, n = re.subn(r'(\n  version:\s*)"[^"]*"', rf'\g<1>"{new}"', text, count=1)
if n:
    with open(path, "w") as f:
        f.write(text)
print(n)
PY
)"
  if [ "$changed" = "0" ]; then
    echo "warning: no metadata 'version:' line in $rel; skipped" >&2
  else
    SKILLS_SYNCED="$SKILLS_SYNCED $rel"
  fi
done
fi

# --- Prepend a CHANGELOG entry --------------------------------------------
if [ -z "$DRY_RUN" ]; then
python3 - "$CHANGELOG" "$NEW" "$DATE" "$NOTE" <<'PY'
import sys
path, new, date, note = sys.argv[1:5]
note = note or "Version bump."
block = f"## [{new}] - {date}\n\n### Changed\n- {note}\n\n"
with open(path) as f:
    lines = f.readlines()
# Insert above the first existing version section; warn and append if none exists.
idx = next((i for i, ln in enumerate(lines) if ln.startswith("## [")), None)
if idx is None:
    sys.stderr.write("warning: no '## [' version section in changelog; appending entry at end\n")
    idx = len(lines)
lines[idx:idx] = [block]
with open(path, "w") as f:
    f.writelines(lines)
PY
fi

if [ -n "$DRY_RUN" ]; then
  echo "dry-run: $CURRENT -> $NEW (files not modified)"
  echo
  echo "Would add to CHANGELOG.md:"
  echo "## [$NEW] - $DATE"
  echo
  echo "### Changed"
  echo "- ${NOTE:-Version bump.}"
else
  echo "Bumped: $CURRENT -> $NEW"
  echo "  updated $(realpath --relative-to="$ROOT" "$PLUGIN_JSON")"
  echo "  updated $(realpath --relative-to="$ROOT" "$MARKET_JSON")"
  [ -n "$SKILLS_SYNCED" ] && echo "  updated$SKILLS_SYNCED"
  echo "  changelog entry added ($DATE)"
  echo
  echo "Next: review the diff, commit, then run /plugin marketplace update <name>"
fi
