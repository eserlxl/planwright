#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Eser KUBALI
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Scaffold a new, self-hosting Claude Code plugin (one skill) ready to install
# via /plugin. Produces the same layout as this repo.
#
# Usage:
#   scripts/make-plugin.sh <plugin-name> [dest-dir]
#
# Options via environment:
#   AUTHOR_NAME, AUTHOR_EMAIL   default to your git config
#   PLUGIN_DESC                 one-line description
#   NO_GIT=1                    skip git init / first commit
#
# Example:
#   scripts/make-plugin.sh code-mapper ~/plugins/code-mapper
set -euo pipefail

NAME="${1:-}"
DEST="${2:-./$NAME}"

[ "$NAME" = "--help" ] || [ "$NAME" = "-h" ] && { echo "Usage: $(basename "$0") <plugin-name> [dest-dir]"; echo "Env: AUTHOR_NAME, AUTHOR_EMAIL, PLUGIN_DESC, NO_GIT=1"; exit 0; }
[ -n "$NAME" ] || { echo "Usage: $(basename "$0") <plugin-name> [dest-dir]" >&2; exit 1; }
echo "$NAME" | grep -Eq '^[a-z][a-z0-9-]*$' \
  || { echo "Plugin name must be lowercase kebab-case (e.g. my-plugin)" >&2; exit 1; }
[ -e "$DEST" ] && { echo "Destination already exists: $DEST" >&2; exit 1; }

AUTHOR_NAME="${AUTHOR_NAME:-$(git config user.name 2>/dev/null || echo "Your Name")}"
AUTHOR_EMAIL="${AUTHOR_EMAIL:-$(git config user.email 2>/dev/null || echo "you@example.com")}"
PLUGIN_DESC="${PLUGIN_DESC:-A Claude Code plugin.}"
DATE="$(date -u +%Y-%m-%d)"

# JSON-escape the free-text values before interpolating them into the manifests,
# so quotes/backslashes in PLUGIN_DESC/AUTHOR_NAME/AUTHOR_EMAIL cannot produce
# invalid JSON. json.dumps emits the surrounding quotes, so these expand bare.
# (NAME is already validated kebab-case above and is always JSON-safe.)
json_escape() { python3 -c 'import json,sys;print(json.dumps(sys.argv[1]))' "$1"; }
AUTHOR_NAME_JSON="$(json_escape "$AUTHOR_NAME")"
AUTHOR_EMAIL_JSON="$(json_escape "$AUTHOR_EMAIL")"
PLUGIN_DESC_JSON="$(json_escape "$PLUGIN_DESC")"

mkdir -p "$DEST/.claude-plugin" "$DEST/skills/$NAME" "$DEST/scripts"

# --- plugin.json -----------------------------------------------------------
cat > "$DEST/.claude-plugin/plugin.json" <<EOF
{
  "name": "$NAME",
  "version": "0.1.0",
  "description": $PLUGIN_DESC_JSON,
  "author": {
    "name": $AUTHOR_NAME_JSON,
    "email": $AUTHOR_EMAIL_JSON
  },
  "license": "GPL-3.0-or-later",
  "keywords": ["skill"]
}
EOF

# --- marketplace.json ------------------------------------------------------
cat > "$DEST/.claude-plugin/marketplace.json" <<EOF
{
  "name": "$NAME",
  "owner": {
    "name": $AUTHOR_NAME_JSON,
    "email": $AUTHOR_EMAIL_JSON
  },
  "metadata": {
    "description": "Marketplace hosting the $NAME plugin for Claude Code.",
    "version": "0.1.0"
  },
  "plugins": [
    {
      "name": "$NAME",
      "source": "./",
      "description": $PLUGIN_DESC_JSON,
      "version": "0.1.0",
      "license": "GPL-3.0-or-later",
      "keywords": ["skill"]
    }
  ]
}
EOF

# --- skills/<name>/SKILL.md -----------------------------------------------
cat > "$DEST/skills/$NAME/SKILL.md" <<EOF
---
name: $NAME
description: >
  $PLUGIN_DESC
  Trigger when the user asks to ... . Run \`/$NAME help\` for usage.
license: GPL-3.0-or-later
metadata:
  author: $AUTHOR_NAME
  version: "0.1.0"
---

# $NAME

Describe what this skill does and the artifact it produces.

## Invocation & help

If invoked with \`help\`, \`--help\`, \`-h\`, or \`?\`, print the Usage block and STOP.
Otherwise run the Procedure.

### Usage

\`\`\`
/$NAME            Run with defaults
/$NAME help       Show this help and stop
\`\`\`

## Procedure

1. Step one.
2. Step two.
3. Step three.
EOF

# --- README.md -------------------------------------------------------------
cat > "$DEST/README.md" <<EOF
# $NAME

$PLUGIN_DESC

## Install

\`\`\`
/plugin marketplace add $DEST
/plugin install $NAME@$NAME
\`\`\`

## Usage

\`\`\`
/$NAME            Run with defaults
/$NAME help       Show usage and stop
\`\`\`

## License

GPL-3.0-or-later. See [LICENSE](LICENSE).
EOF

# --- MISSION.md ------------------------------------------------------------
# A charter stub so the generated plugin's planwright opportunity/vision rungs
# (and Stage 1, which reads a mission/charter file) have something to align to.
cat > "$DEST/MISSION.md" <<EOF
# $NAME — Mission

## Purpose

$PLUGIN_DESC

## Scope

Describe what this plugin does — and the boundaries it will not cross — so planwright's
opportunity and vision rungs (and Stage 1) have a concrete charter to align proposals to.

## Non-goals

List what this plugin deliberately will not do, so the maturity ladder does not drift into it.
EOF

# --- CHANGELOG.md ----------------------------------------------------------
cat > "$DEST/CHANGELOG.md" <<EOF
# Changelog

All notable changes to $NAME are documented here.
The format follows [Keep a Changelog](https://keepachangelog.com/).

## [0.1.0] - $DATE

### Added
- Initial scaffold.
EOF

# --- .gitignore ------------------------------------------------------------
cat > "$DEST/.gitignore" <<EOF
.DS_Store
*.swp
*~
__pycache__/
*.pyc
.claude/settings.local.json
EOF

# --- tests/ + CI -----------------------------------------------------------
# Give every generated plugin the same verification baseline this repo uses.
mkdir -p "$DEST/tests" "$DEST/.github/workflows"

cat > "$DEST/tests/run.sh" <<'EOF'
#!/usr/bin/env bash
# Smoke test for this plugin: manifests parse as JSON and bundled shell scripts
# are syntactically valid (bash -n needs no shellcheck, so it runs everywhere).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
python3 - "$ROOT" <<'PY'
import glob, json, sys
for f in glob.glob(sys.argv[1] + "/.claude-plugin/*.json"):
    json.load(open(f))
print("ok - manifests parse")
PY
for s in "$ROOT"/scripts/*.sh "$ROOT"/tests/*.sh; do
  [ -e "$s" ] || continue
  bash -n "$s" || { echo "FAIL - $s has a bash syntax error"; exit 1; }
done
echo "ok - bundled scripts parse"
EOF
chmod +x "$DEST/tests/run.sh"

cat > "$DEST/.github/workflows/ci.yml" <<'EOF'
name: CI

on:
  push:
  pull_request:

jobs:
  check:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Shellcheck
        run: shellcheck scripts/*.sh tests/*.sh
      - name: Validate manifests
        run: python3 -c "import json,glob;[json.load(open(f)) for f in glob.glob('.claude-plugin/*.json')]"
      - name: Smoke tests
        run: bash tests/run.sh
EOF

# --- bundled bump-version helper ------------------------------------------
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "$SELF_DIR/bump-version.sh" ]; then
  cp "$SELF_DIR/bump-version.sh" "$DEST/scripts/bump-version.sh"
  chmod +x "$DEST/scripts/bump-version.sh"
fi

chmod +x "$DEST/scripts/"*.sh 2>/dev/null || true

# --- LICENSE ---------------------------------------------------------------
# Write a self-contained GPL-3.0-or-later notice naming THIS plugin, consistent
# with the "license" field in the manifests. (Copying a bundled LICENSE verbatim
# would carry the source project's name in the GPL appendix.)
cat > "$DEST/LICENSE" <<EOF
$NAME
Copyright (C) $(date -u +%Y) $AUTHOR_NAME

This program is free software: you can redistribute it and/or modify it under
the terms of the GNU General Public License as published by the Free Software
Foundation, either version 3 of the License, or (at your option) any later
version.

This program is distributed WITHOUT ANY WARRANTY; without even the implied
warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU
General Public License for more details: <https://www.gnu.org/licenses/>.

SPDX-License-Identifier: GPL-3.0-or-later
EOF

if [ "${NO_GIT:-0}" != "1" ]; then
  git -C "$DEST" init -q
  git -C "$DEST" add -A
  git -C "$DEST" -c user.name="$AUTHOR_NAME" -c user.email="$AUTHOR_EMAIL" \
    commit -q -m "Initial scaffold: $NAME Claude Code plugin (v0.1.0)"
fi

echo "Created plugin '$NAME' at: $DEST (LICENSE: GPL-3.0-or-later)"
echo
echo "Try it:"
echo "  /plugin marketplace add $DEST"
echo "  /plugin install $NAME@$NAME"
