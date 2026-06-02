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

# --- Test 0: shellcheck main repo scripts ----------------------------------
if command -v shellcheck >/dev/null 2>&1; then
  if shellcheck "$ROOT/scripts/bump-version.sh" "$ROOT/scripts/make-plugin.sh" "$ROOT/tests/run.sh" >/dev/null 2>&1; then ok "main repo scripts pass shellcheck"; else bad "main repo scripts fail shellcheck"; fi
else
  ok "main scripts shellcheck skipped (shellcheck not installed)"
fi

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
if grep -q "smoke-test bump" "$WORK/CHANGELOG.md"; then ok "changelog -m note appears in entry"; else bad "changelog -m note missing from entry"; fi
sv="$(grep -m1 '  version:' "$WORK/skills/planwright/SKILL.md" | sed -E 's/.*"([^"]+)".*/\1/')"
if [ "$sv" = "$pj" ]; then ok "skill frontmatter in lockstep ($sv)"; else bad "skill version drift: skill=$sv manifest=$pj"; fi

# --- Test 2: make-plugin.sh scaffolds a valid plugin ----------------------
GEN="$TMP/gen"
NO_GIT=1 PLUGIN_DESC="Smoke test plugin." "$ROOT/scripts/make-plugin.sh" demo "$GEN" >/dev/null
if python3 -c "import json;json.load(open('$GEN/.claude-plugin/plugin.json'))" 2>/dev/null; then ok "generated plugin.json parses"; else bad "generated plugin.json invalid"; fi
if python3 -c "import json;json.load(open('$GEN/.claude-plugin/marketplace.json'))" 2>/dev/null; then ok "generated marketplace.json parses"; else bad "generated marketplace.json invalid"; fi
if python3 -c "import json,sys;d=json.load(open('$GEN/.claude-plugin/plugin.json'));sys.exit(0 if 'Smoke test plugin.' in str(d) else 1)" 2>/dev/null; then ok "PLUGIN_DESC appears in generated plugin.json"; else bad "PLUGIN_DESC missing from generated plugin.json"; fi
if python3 -c "import json,sys;m=json.load(open('$GEN/.claude-plugin/marketplace.json'));sys.exit(0 if any('Smoke test plugin.' in str(p.get('description','')) for p in m.get('plugins',[])) else 1)" 2>/dev/null; then ok "PLUGIN_DESC appears in generated marketplace.json plugin entry"; else bad "PLUGIN_DESC missing from generated marketplace.json plugin entry"; fi
if [ -f "$GEN/skills/demo/SKILL.md" ]; then ok "generated skills/demo/SKILL.md exists"; else bad "generated SKILL.md missing"; fi
if grep -q "Smoke test plugin." "$GEN/skills/demo/SKILL.md" 2>/dev/null; then ok "PLUGIN_DESC appears in generated SKILL.md description"; else bad "PLUGIN_DESC missing from generated SKILL.md description"; fi
if [ -f "$GEN/LICENSE" ]; then ok "generated LICENSE exists"; else bad "generated LICENSE missing"; fi
if [ -f "$GEN/.github/workflows/ci.yml" ]; then ok "generated ci.yml exists"; else bad "generated ci.yml missing"; fi
if grep -q "shellcheck" "$GEN/.github/workflows/ci.yml" 2>/dev/null; then ok "generated ci.yml includes shellcheck step"; else bad "generated ci.yml missing shellcheck step"; fi
if grep -q "bash tests/run.sh" "$GEN/.github/workflows/ci.yml" 2>/dev/null; then ok "generated ci.yml includes smoke-test step"; else bad "generated ci.yml missing smoke-test step"; fi
if [ -f "$GEN/.gitignore" ]; then ok "generated .gitignore exists"; else bad "generated .gitignore missing"; fi
if bash "$GEN/tests/run.sh" >/dev/null 2>&1; then ok "generated tests/run.sh runs"; else bad "generated tests/run.sh failed"; fi
if command -v shellcheck >/dev/null 2>&1; then
  if shellcheck "$GEN"/scripts/*.sh "$GEN"/tests/*.sh >/dev/null 2>&1; then ok "generated scripts pass shellcheck"; else bad "generated scripts fail shellcheck"; fi
else
  ok "generated scripts shellcheck skipped (shellcheck not installed)"
fi
if [ -f "$GEN/scripts/bump-version.sh" ]; then ok "generated scripts/bump-version.sh exists"; else bad "generated scripts/bump-version.sh missing"; fi
if bash -n "$GEN/scripts/bump-version.sh" 2>/dev/null; then ok "generated scripts/bump-version.sh parses as bash"; else bad "generated scripts/bump-version.sh has bash syntax error"; fi
if grep -q "## \[0\.1\.0\]" "$GEN/CHANGELOG.md" 2>/dev/null; then ok "generated CHANGELOG.md has initial [0.1.0] section"; else bad "generated CHANGELOG.md missing [0.1.0] section"; fi
if grep -q "^# demo$" "$GEN/README.md" 2>/dev/null; then ok "generated README.md contains plugin name as heading"; else bad "generated README.md missing plugin name heading"; fi

# --- Test 2b: make-plugin.sh rejects invalid plugin name ------------------
if NO_GIT=1 "$ROOT/scripts/make-plugin.sh" "MyPlugin" "$TMP/invalid-name" >/dev/null 2>&1; then bad "make-plugin accepted invalid name"; else ok "make-plugin rejects invalid name (uppercase)"; fi

# --- Test 2c: make-plugin.sh rejects pre-existing destination --------------
GEN2="$TMP/gen2"
NO_GIT=1 "$ROOT/scripts/make-plugin.sh" demo "$GEN2" >/dev/null
if NO_GIT=1 "$ROOT/scripts/make-plugin.sh" demo "$GEN2" >/dev/null 2>&1; then bad "make-plugin accepted duplicate destination"; else ok "make-plugin rejects duplicate destination"; fi

# --- Test 2d: make-plugin.sh injects AUTHOR_NAME into generated LICENSE -----
GEN_AUTH="$TMP/gen_auth"
AUTHOR_NAME="Test Author" NO_GIT=1 "$ROOT/scripts/make-plugin.sh" demo "$GEN_AUTH" >/dev/null
if grep -q "Test Author" "$GEN_AUTH/LICENSE" 2>/dev/null; then ok "AUTHOR_NAME appears in generated LICENSE"; else bad "AUTHOR_NAME missing from generated LICENSE"; fi

# --- Test 2e: bump-version.sh rejects unknown arguments --------------------
if "$ROOT/scripts/bump-version.sh" patch --garbage >/dev/null 2>&1; then bad "bump-version accepted unknown argument --garbage"; else ok "bump-version rejects unknown argument (--garbage)"; fi
if "$ROOT/scripts/bump-version.sh" --help >/dev/null 2>/dev/null; then ok "bump-version --help exits 0"; else bad "bump-version --help exits non-zero"; fi

# --- Test 2f: make-plugin.sh git init path creates an initial commit -------
GEN_GIT="$TMP/gen_git"
if AUTHOR_NAME="Test Author" AUTHOR_EMAIL="test@test.com" "$ROOT/scripts/make-plugin.sh" demo "$GEN_GIT" >/dev/null 2>&1; then
  if git -C "$GEN_GIT" log --oneline 2>/dev/null | grep -q "Initial scaffold"; then ok "make-plugin.sh git path creates initial commit"; else bad "make-plugin.sh git path: initial commit message missing"; fi
  if git -C "$GEN_GIT" log --format="%ae" -1 2>/dev/null | grep -q "test@test.com"; then ok "AUTHOR_EMAIL set as git commit author"; else bad "AUTHOR_EMAIL not recorded in git commit author"; fi
else
  bad "make-plugin.sh git path: scaffolding failed"
fi

# --- Test 3: bump-version.sh refuses a dirty git tree ---------------------
GREPO="$TMP/gitrepo"
mkdir -p "$GREPO"
( cd "$ROOT" && tar --exclude=.git --exclude=.planwright -cf - . ) | ( cd "$GREPO" && tar -xf - )
git -C "$GREPO" init -q
git -C "$GREPO" add -A
git -C "$GREPO" -c user.name=test -c user.email=test@example.com commit -qm init
echo "dirt" >> "$GREPO/README.md"
if "$GREPO/scripts/bump-version.sh" patch -m x >/dev/null 2>&1; then bad "guard did not abort on dirty tree"; else ok "guard aborts on dirty git tree"; fi
if ALLOW_DIRTY=1 "$GREPO/scripts/bump-version.sh" patch -m x >/dev/null 2>&1; then ok "ALLOW_DIRTY=1 bypasses dirty-tree guard"; else bad "ALLOW_DIRTY=1 did not bypass dirty-tree guard"; fi

# --- Test 4: skill-sync warns and skips when no version: line matches ------
WREPO="$TMP/warnrepo"
mkdir -p "$WREPO"
( cd "$ROOT" && tar --exclude=.git --exclude=.planwright -cf - . ) | ( cd "$WREPO" && tar -xf - )
# Make the frontmatter version line unmatchable (unquoted) so the regex skips it.
sed -i -E 's/^(  version:).*/\1 9.9.9/' "$WREPO/skills/planwright/SKILL.md"
warn_err="$("$WREPO/scripts/bump-version.sh" patch -m "warn-path test" 2>&1 >/dev/null)"; warn_rc=$?
if [ "$warn_rc" -eq 0 ]; then ok "bump still succeeds when a skill has no version: line"; else bad "bump failed (rc=$warn_rc) on unmatchable skill version"; fi
if printf '%s' "$warn_err" | grep -q "no metadata 'version:' line"; then ok "skill-sync warns on unmatchable version line"; else bad "expected skip warning not emitted"; fi

# --- Test 5: bump-version.sh appends when CHANGELOG has no ## [ section -----
NCSEC="$TMP/ncsec"
mkdir -p "$NCSEC"
( cd "$ROOT" && tar --exclude=.git --exclude=.planwright -cf - . ) | ( cd "$NCSEC" && tar -xf - )
printf "# Changelog\n" > "$NCSEC/CHANGELOG.md"
nc_rc=0; "$NCSEC/scripts/bump-version.sh" patch >/dev/null 2>/dev/null || nc_rc=$?
if [ "$nc_rc" -eq 0 ]; then ok "bump exits 0 when changelog has no prior version section"; else bad "bump failed on changelog with no version section (rc=$nc_rc)"; fi
ncpj="$(python3 -c "import json;print(json.load(open('$NCSEC/.claude-plugin/plugin.json'))['version'])")"
if grep -q "## \[$ncpj\]" "$NCSEC/CHANGELOG.md"; then ok "version entry present in changelog with no prior sections"; else bad "version entry missing from changelog with no prior sections"; fi

# --- Test 6: bump-version.sh minor increment resets patch to 0 -------------
MINRR="$TMP/minrr"
mkdir -p "$MINRR"
( cd "$ROOT" && tar --exclude=.git --exclude=.planwright -cf - . ) | ( cd "$MINRR" && tar -xf - )
"$MINRR/scripts/bump-version.sh" minor >/dev/null
minpj="$(python3 -c "import json;print(json.load(open('$MINRR/.claude-plugin/plugin.json'))['version'])")"
if python3 -c "v='$minpj'; exit(0 if v.split('.')[2]=='0' else 1)"; then ok "minor increment resets patch to 0 ($minpj)"; else bad "minor increment did not reset patch to 0: $minpj"; fi
minmm="$(python3 -c "import json;print(json.load(open('$MINRR/.claude-plugin/marketplace.json'))['metadata']['version'])")"
if [ "$minpj" = "$minmm" ]; then ok "minor increment synced across manifests ($minpj)"; else bad "minor increment not synced: plugin=$minpj market=$minmm"; fi

# --- Test 7: bump-version.sh major increment resets minor and patch to 0 ----
MAJRR="$TMP/majrr"
mkdir -p "$MAJRR"
( cd "$ROOT" && tar --exclude=.git --exclude=.planwright -cf - . ) | ( cd "$MAJRR" && tar -xf - )
"$MAJRR/scripts/bump-version.sh" major >/dev/null
majpj="$(python3 -c "import json;print(json.load(open('$MAJRR/.claude-plugin/plugin.json'))['version'])")"
if python3 -c "v='$majpj'; parts=v.split('.'); exit(0 if parts[1]=='0' and parts[2]=='0' else 1)"; then ok "major increment resets minor and patch to 0 ($majpj)"; else bad "major increment did not reset minor/patch to 0: $majpj"; fi
majmm="$(python3 -c "import json;print(json.load(open('$MAJRR/.claude-plugin/marketplace.json'))['metadata']['version'])")"
if [ "$majpj" = "$majmm" ]; then ok "major increment synced across manifests ($majpj)"; else bad "major increment not synced: plugin=$majpj market=$majmm"; fi

# --- Test 7b: bump-version.sh accepts explicit X.Y.Z version pinning -------
PINRR="$TMP/pinrr"
mkdir -p "$PINRR"
( cd "$ROOT" && tar --exclude=.git --exclude=.planwright -cf - . ) | ( cd "$PINRR" && tar -xf - )
"$PINRR/scripts/bump-version.sh" 2.5.0 >/dev/null
pinpj="$(python3 -c "import json;print(json.load(open('$PINRR/.claude-plugin/plugin.json'))['version'])")"
if [ "$pinpj" = "2.5.0" ]; then ok "X.Y.Z explicit pin sets version to 2.5.0"; else bad "X.Y.Z explicit pin failed: got $pinpj"; fi
pinmm="$(python3 -c "import json;print(json.load(open('$PINRR/.claude-plugin/marketplace.json'))['metadata']['version'])")"
if [ "$pinpj" = "$pinmm" ]; then ok "X.Y.Z explicit pin synced across manifests"; else bad "X.Y.Z pin not synced: plugin=$pinpj market=$pinmm"; fi

# --- Test 7c: bump-version.sh exits non-zero when a required file is missing -
MISRR="$TMP/misrr"
mkdir -p "$MISRR"
( cd "$ROOT" && tar --exclude=.git --exclude=.planwright -cf - . ) | ( cd "$MISRR" && tar -xf - )
rm "$MISRR/.claude-plugin/plugin.json"
if "$MISRR/scripts/bump-version.sh" patch >/dev/null 2>&1; then bad "bump-version did not exit on missing plugin.json"; else ok "bump-version exits non-zero when required file is missing"; fi

# --- Test 8: bump-version.sh --dry-run does not modify files ---------------
DRYR="$TMP/dryr"
mkdir -p "$DRYR"
( cd "$ROOT" && tar --exclude=.git --exclude=.planwright -cf - . ) | ( cd "$DRYR" && tar -xf - )
dr_before="$(python3 -c "import json;print(json.load(open('$DRYR/.claude-plugin/plugin.json'))['version'])")"
dr_market_before="$(python3 -c "import json;print(json.load(open('$DRYR/.claude-plugin/marketplace.json'))['metadata']['version'])")"
dr_cl_before="$(wc -l < "$DRYR/CHANGELOG.md")"
dr_out="$("$DRYR/scripts/bump-version.sh" patch --dry-run 2>/dev/null)"
dr_after="$(python3 -c "import json;print(json.load(open('$DRYR/.claude-plugin/plugin.json'))['version'])")"
dr_market_after="$(python3 -c "import json;print(json.load(open('$DRYR/.claude-plugin/marketplace.json'))['metadata']['version'])")"
dr_cl_after="$(wc -l < "$DRYR/CHANGELOG.md")"
if [ "$dr_before" = "$dr_after" ]; then ok "--dry-run did not modify plugin.json"; else bad "--dry-run modified plugin.json ($dr_before -> $dr_after)"; fi
if [ "$dr_market_before" = "$dr_market_after" ]; then ok "--dry-run did not modify marketplace.json"; else bad "--dry-run modified marketplace.json ($dr_market_before -> $dr_market_after)"; fi
if [ "$dr_cl_before" = "$dr_cl_after" ]; then ok "--dry-run did not modify CHANGELOG.md"; else bad "--dry-run modified CHANGELOG.md (lines: $dr_cl_before -> $dr_cl_after)"; fi
if printf '%s' "$dr_out" | grep -q "dry-run:"; then ok "--dry-run output shows version info"; else bad "--dry-run output missing version info"; fi

echo
echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ]
