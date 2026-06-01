#!/usr/bin/env bash
# Bump the plugin version in lockstep across plugin.json, marketplace.json,
# and CHANGELOG.md.
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
BUMP="$1"; shift
NOTE=""
while [ $# -gt 0 ]; do
  case "$1" in
    -m|--message) NOTE="${2:-}"; shift 2 ;;
    -h|--help) usage ;;
    *) echo "Unknown argument: $1" >&2; usage ;;
  esac
done

for f in "$PLUGIN_JSON" "$MARKET_JSON" "$CHANGELOG"; do
  [ -f "$f" ] || { echo "Missing required file: $f" >&2; exit 1; }
done

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

# --- Prepend a CHANGELOG entry --------------------------------------------
python3 - "$CHANGELOG" "$NEW" "$DATE" "$NOTE" <<'PY'
import sys
path, new, date, note = sys.argv[1:5]
note = note or "Version bump."
block = f"## [{new}] - {date}\n\n### Changed\n- {note}\n\n"
with open(path) as f:
    lines = f.readlines()
# Insert above the first existing version section, else append.
idx = next((i for i, ln in enumerate(lines) if ln.startswith("## [")), len(lines))
lines[idx:idx] = [block]
with open(path, "w") as f:
    f.writelines(lines)
PY

echo "Bumped: $CURRENT -> $NEW"
echo "  updated $(realpath --relative-to="$ROOT" "$PLUGIN_JSON")"
echo "  updated $(realpath --relative-to="$ROOT" "$MARKET_JSON")"
echo "  changelog entry added ($DATE)"
echo
echo "Next: review the diff, commit, then run /plugin marketplace update <name>"
