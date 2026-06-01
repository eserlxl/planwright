#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Eser KUBALI
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Smoke tests for the helper scripts. Exits 0 when both scripts behave, non-zero
# otherwise. Operates entirely in temp dirs — never touches the real working tree.
#
# Usage: bash tests/run.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0
FAIL=0
ok()  { echo "ok   - $1"; PASS=$((PASS + 1)); }
bad() { echo "FAIL - $1"; FAIL=$((FAIL + 1)); }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

ver() { python3 -c "import json,sys;print(json.load(open(sys.argv[1]))$2)" "$1"; }

# --- Test 1: bump-version.sh syncs version across all three files ----------
WORK="$TMP/repo"
mkdir -p "$WORK"
# Copy the repo without VCS state or scratch so the copy is not a git work tree.
( cd "$ROOT" && tar --exclude=.git --exclude=.planwright -cf - . ) | ( cd "$WORK" && tar -xf - )

before="$(ver "$WORK/.claude-plugin/plugin.json" "['version']")"
"$WORK/scripts/bump-version.sh" patch -m "smoke-test bump" >/dev/null
pj="$(ver "$WORK/.claude-plugin/plugin.json" "['version']")"
mm="$(ver "$WORK/.claude-plugin/marketplace.json" "['metadata']['version']")"
me="$(ver "$WORK/.claude-plugin/marketplace.json" "['plugins'][0]['version']")"

if [ "$pj" != "$before" ]; then ok "bump-version changed version ($before -> $pj)"; else bad "version unchanged"; fi
if [ "$pj" = "$mm" ] && [ "$pj" = "$me" ]; then ok "manifests in lockstep ($pj)"; else bad "out of sync: plugin=$pj meta=$mm entry=$me"; fi
if grep -q "## \[$pj\]" "$WORK/CHANGELOG.md"; then ok "changelog gained [$pj] section"; else bad "changelog missing [$pj]"; fi
sv="$(grep -m1 '  version:' "$WORK/skills/planwright/SKILL.md" | sed -E 's/.*"([^"]+)".*/\1/')"
if [ "$sv" = "$pj" ]; then ok "skill frontmatter in lockstep ($sv)"; else bad "skill version drift: skill=$sv manifest=$pj"; fi

# --- Test 2: make-plugin.sh scaffolds a valid plugin ----------------------
GEN="$TMP/gen"
NO_GIT=1 PLUGIN_DESC="Smoke test plugin." "$ROOT/scripts/make-plugin.sh" demo "$GEN" >/dev/null
if python3 -c "import json;json.load(open('$GEN/.claude-plugin/plugin.json'))" 2>/dev/null; then ok "generated plugin.json parses"; else bad "generated plugin.json invalid"; fi
if python3 -c "import json;json.load(open('$GEN/.claude-plugin/marketplace.json'))" 2>/dev/null; then ok "generated marketplace.json parses"; else bad "generated marketplace.json invalid"; fi
if [ -f "$GEN/skills/demo/SKILL.md" ]; then ok "generated skills/demo/SKILL.md exists"; else bad "generated SKILL.md missing"; fi
if [ -f "$GEN/LICENSE" ]; then ok "generated LICENSE exists"; else bad "generated LICENSE missing"; fi

# --- Test 3: bump-version.sh refuses a dirty git tree ---------------------
GREPO="$TMP/gitrepo"
mkdir -p "$GREPO"
( cd "$ROOT" && tar --exclude=.git --exclude=.planwright -cf - . ) | ( cd "$GREPO" && tar -xf - )
git -C "$GREPO" init -q
git -C "$GREPO" add -A
git -C "$GREPO" -c user.name=test -c user.email=test@example.com commit -qm init
echo "dirt" >> "$GREPO/README.md"
if "$GREPO/scripts/bump-version.sh" patch -m x >/dev/null 2>&1; then bad "guard did not abort on dirty tree"; else ok "guard aborts on dirty git tree"; fi

echo
echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ]
