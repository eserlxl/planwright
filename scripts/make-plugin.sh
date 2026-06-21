#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Eser KUBALI
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Scaffold a new, self-hosting plugin (one skill) ready to install in Claude Code
# or Codex. Produces the same manifest layout as this repo.
#
# Usage:
#   scripts/make-plugin.sh [--no-gpg-sign] <plugin-name> [dest-dir]
#
# Options:
#   --no-gpg-sign               disable GPG signing for the initial scaffold commit
#   --disable-gpg-signing       alias for --no-gpg-sign
#
# Options via environment:
#   AUTHOR_NAME, AUTHOR_EMAIL   default to your git config
#   PLUGIN_DESC                 one-line description
#   NO_GIT=1                    skip git init / first commit
#
# Example:
#   scripts/make-plugin.sh code-mapper ~/plugins/code-mapper
set -euo pipefail

usage() {
  echo "Usage: $(basename "$0") [--no-gpg-sign] <plugin-name> [dest-dir]"
  echo "Options: --no-gpg-sign, --disable-gpg-signing"
  echo "Env: AUTHOR_NAME, AUTHOR_EMAIL, PLUGIN_DESC, NO_GIT=1"
}

DISABLE_GPG_SIGNING=0
POSITIONAL=()
while [ $# -gt 0 ]; do
  case "$1" in
    --no-gpg-sign|--disable-gpg-signing)
      DISABLE_GPG_SIGNING=1
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    --)
      shift
      while [ $# -gt 0 ]; do POSITIONAL+=("$1"); shift; done
      ;;
    -*)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
    *)
      POSITIONAL+=("$1")
      shift
      ;;
  esac
done

[ "${#POSITIONAL[@]}" -le 2 ] || { echo "Too many positional arguments" >&2; usage >&2; exit 1; }
NAME="${POSITIONAL[0]:-}"
DEST="${POSITIONAL[1]:-./$NAME}"

[ -n "$NAME" ] || { usage >&2; exit 1; }
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

# The manifests above are JSON, but skills/<name>/SKILL.md carries a YAML frontmatter,
# where the same raw values are structurally significant: `author:` is a plain scalar
# (a leading quote or an embedded ": " would misparse) and the folded `description: >`
# block breaks if the value spans lines. A JSON string is a valid YAML double-quoted
# scalar, so reuse the JSON escaping for `author:`; collapse the description to one line
# AND trim outer whitespace — a leading space would change the folded block's measured
# indentation (3 spaces under a 2-space block) and make the frontmatter unparseable
# while the scaffold still exits 0.
AUTHOR_NAME_YAML="$AUTHOR_NAME_JSON"
PLUGIN_DESC_ONELINE="$(printf '%s' "$PLUGIN_DESC" | tr '\r\n\t' '   ' | sed -E 's/^ +//; s/ +$//')"

mkdir -p "$DEST/.claude-plugin" "$DEST/.codex-plugin" "$DEST/skills/$NAME" "$DEST/scripts"

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

# --- .codex-plugin/plugin.json --------------------------------------------
cat > "$DEST/.codex-plugin/plugin.json" <<EOF
{
  "name": "$NAME",
  "version": "0.1.0",
  "description": $PLUGIN_DESC_JSON,
  "author": {
    "name": $AUTHOR_NAME_JSON,
    "email": $AUTHOR_EMAIL_JSON
  },
  "license": "GPL-3.0-or-later",
  "keywords": ["skill"],
  "skills": "./skills/",
  "interface": {
    "displayName": "$NAME",
    "shortDescription": $PLUGIN_DESC_JSON,
    "developerName": $AUTHOR_NAME_JSON,
    "category": "Productivity",
    "defaultPrompt": [
      "Run $NAME",
      "Run $NAME help"
    ]
  }
}
EOF

# --- skills/<name>/SKILL.md -----------------------------------------------
cat > "$DEST/skills/$NAME/SKILL.md" <<EOF
---
name: $NAME
description: >
  $PLUGIN_DESC_ONELINE
  Trigger when the user asks to ... . Run \`/$NAME help\` for usage.
license: GPL-3.0-or-later
metadata:
  author: $AUTHOR_NAME_YAML
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

# --- AGENTS.md -------------------------------------------------------------
cat > "$DEST/AGENTS.md" <<EOF
## $NAME

When the user invokes **$NAME**, act as the $NAME agent:

1. Read \`skills/$NAME/SKILL.md\` and follow it exactly for the resolved arguments.
2. Do not re-implement $NAME logic inline — the skill owns all behaviour.

**Scripts:** resolve any bundled scripts from \`scripts/\` relative to the workspace root.
EOF

# --- GEMINI.md -------------------------------------------------------------
cat > "$DEST/GEMINI.md" <<EOF
# Antigravity / Gemini Integration

@Antigravity, please read \`skills/$NAME/SKILL.md\` to understand the $NAME workflow.
I want you to act as the $NAME agent when I run the command $NAME.
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
.planwright/
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
for d in (".claude-plugin", ".codex-plugin"):
  for f in glob.glob(sys.argv[1] + "/" + d + "/*.json"):
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
        run: |
          shopt -s nullglob
          files=(scripts/*.sh tests/*.sh)
          if [ ${#files[@]} -gt 0 ]; then shellcheck "${files[@]}"; else echo "no shell scripts to check"; fi
      - name: Validate manifests
        run: python3 -c "import json,glob;[json.load(open(f)) for d in ('.claude-plugin','.codex-plugin') for f in glob.glob(d+'/*.json')]"
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
  if [ "$DISABLE_GPG_SIGNING" = "1" ]; then
    git -C "$DEST" -c user.name="$AUTHOR_NAME" -c user.email="$AUTHOR_EMAIL" -c commit.gpgsign=false \
      commit -q -m "Initial scaffold: $NAME Claude Code plugin (v0.1.0)"
  else
    git -C "$DEST" -c user.name="$AUTHOR_NAME" -c user.email="$AUTHOR_EMAIL" \
      commit -q -m "Initial scaffold: $NAME Claude Code plugin (v0.1.0)"
  fi
fi

echo "Created plugin '$NAME' at: $DEST (LICENSE: GPL-3.0-or-later)"
echo
echo "Try it:"
echo "  /plugin marketplace add $DEST"
echo "  /plugin install $NAME@$NAME"
