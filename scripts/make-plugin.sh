#!/usr/bin/env bash
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

[ -n "$NAME" ] || { echo "Usage: $(basename "$0") <plugin-name> [dest-dir]" >&2; exit 1; }
echo "$NAME" | grep -Eq '^[a-z][a-z0-9-]*$' \
  || { echo "Plugin name must be lowercase kebab-case (e.g. my-plugin)" >&2; exit 1; }
[ -e "$DEST" ] && { echo "Destination already exists: $DEST" >&2; exit 1; }

AUTHOR_NAME="${AUTHOR_NAME:-$(git config user.name 2>/dev/null || echo "Your Name")}"
AUTHOR_EMAIL="${AUTHOR_EMAIL:-$(git config user.email 2>/dev/null || echo "you@example.com")}"
PLUGIN_DESC="${PLUGIN_DESC:-A Claude Code plugin.}"
DATE="$(date -u +%Y-%m-%d)"

mkdir -p "$DEST/.claude-plugin" "$DEST/skills/$NAME" "$DEST/scripts"

# --- plugin.json -----------------------------------------------------------
cat > "$DEST/.claude-plugin/plugin.json" <<EOF
{
  "name": "$NAME",
  "version": "0.1.0",
  "description": "$PLUGIN_DESC",
  "author": {
    "name": "$AUTHOR_NAME",
    "email": "$AUTHOR_EMAIL"
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
    "name": "$AUTHOR_NAME",
    "email": "$AUTHOR_EMAIL"
  },
  "metadata": {
    "description": "Marketplace hosting the $NAME plugin for Claude Code.",
    "version": "0.1.0"
  },
  "plugins": [
    {
      "name": "$NAME",
      "source": "./",
      "description": "$PLUGIN_DESC",
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
.claude/settings.local.json
EOF

# --- bundled bump-version helper ------------------------------------------
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "$SELF_DIR/bump-version.sh" ]; then
  cp "$SELF_DIR/bump-version.sh" "$DEST/scripts/bump-version.sh"
  chmod +x "$DEST/scripts/bump-version.sh"
fi

chmod +x "$DEST/scripts/"*.sh 2>/dev/null || true

if [ "${NO_GIT:-0}" != "1" ]; then
  git -C "$DEST" init -q
  git -C "$DEST" add -A
  git -C "$DEST" -c user.name="$AUTHOR_NAME" -c user.email="$AUTHOR_EMAIL" \
    commit -q -m "Initial scaffold: $NAME Claude Code plugin (v0.1.0)"
fi

echo "Created plugin '$NAME' at: $DEST"
echo "Remember to add a LICENSE file (GPL-3.0-or-later) before publishing."
echo
echo "Try it:"
echo "  /plugin marketplace add $DEST"
echo "  /plugin install $NAME@$NAME"
