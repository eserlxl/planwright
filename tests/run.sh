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

# --- Test 0b: the Python helper scripts pass static analysis ---------------
# build-graph.py (Stage 1.5 graph) and lint-plan.py (Stage 10 plan gate) are the
# only non-shell scripts; gate both. ast.parse checks syntax without writing
# __pycache__ into the real tree.
for py in build-graph.py lint-plan.py; do
  if python3 -c "import ast,sys;ast.parse(open(sys.argv[1]).read())" "$ROOT/scripts/$py" 2>/dev/null; then ok "$py parses (no syntax error)"; else bad "$py has a syntax error"; fi
  if command -v pyflakes >/dev/null 2>&1; then
    if pyflakes "$ROOT/scripts/$py" >/dev/null 2>&1; then ok "$py passes pyflakes"; else bad "$py fails pyflakes"; fi
  else
    ok "$py pyflakes skipped (pyflakes not installed)"
  fi
done

# --- Test 1: bump-version.sh syncs version across all three files ----------
WORK="$TMP/repo"
mkdir -p "$WORK"
# Copy the repo without VCS state or scratch so the copy is not a git work tree.
( cd "$ROOT" && tar --exclude=.git --exclude=.planwright -cf - . ) | ( cd "$WORK" && tar -xf - )

before="$(ver "$WORK/.claude-plugin/plugin.json" "['version']")"
bs_out="$("$WORK/scripts/bump-version.sh" patch -m "smoke-test bump")"
pj="$(ver "$WORK/.claude-plugin/plugin.json" "['version']")"
mm="$(ver "$WORK/.claude-plugin/marketplace.json" "['metadata']['version']")"
me="$(ver "$WORK/.claude-plugin/marketplace.json" "['plugins'][0]['version']")"

if printf '%s' "$bs_out" | grep -q "Bumped:"; then ok "bump-version prints Bumped: summary on success"; else bad "bump-version missing Bumped: summary on success"; fi
if printf '%s' "$bs_out" | grep -q "updated skills/"; then ok "bump-version reports updated skill files on success"; else bad "bump-version missing skill file update report"; fi
if [ "$pj" != "$before" ]; then ok "bump-version changed version ($before -> $pj)"; else bad "version unchanged"; fi
if [ "$pj" = "$mm" ] && [ "$pj" = "$me" ]; then ok "manifests in lockstep ($pj)"; else bad "out of sync: plugin=$pj meta=$mm entry=$me"; fi
if grep -q "## \[$pj\]" "$WORK/CHANGELOG.md"; then ok "changelog gained [$pj] section"; else bad "changelog missing [$pj]"; fi
if grep -q "### Changed" "$WORK/CHANGELOG.md"; then ok "changelog entry has ### Changed section"; else bad "changelog entry missing ### Changed section"; fi
if grep -q "smoke-test bump" "$WORK/CHANGELOG.md"; then ok "changelog -m note appears in entry"; else bad "changelog -m note missing from entry"; fi
sv="$(grep -m1 '  version:' "$WORK/skills/planwright/SKILL.md" | sed -E 's/.*"([^"]+)".*/\1/')"
if [ "$sv" = "$pj" ]; then ok "skill frontmatter in lockstep ($sv)"; else bad "skill version drift: skill=$sv manifest=$pj"; fi

# --- Test 2: make-plugin.sh scaffolds a valid plugin ----------------------
GEN="$TMP/gen"
NO_GIT=1 PLUGIN_DESC="Smoke test plugin." "$ROOT/scripts/make-plugin.sh" demo "$GEN" >/dev/null
if python3 -c "import json;json.load(open('$GEN/.claude-plugin/plugin.json'))" 2>/dev/null; then ok "generated plugin.json parses"; else bad "generated plugin.json invalid"; fi
if python3 -c "import json,sys;d=json.load(open('$GEN/.claude-plugin/plugin.json'));sys.exit(0 if d.get('license')=='GPL-3.0-or-later' else 1)" 2>/dev/null; then ok "generated plugin.json license is GPL-3.0-or-later"; else bad "generated plugin.json license wrong or missing"; fi
if python3 -c "import json;json.load(open('$GEN/.claude-plugin/marketplace.json'))" 2>/dev/null; then ok "generated marketplace.json parses"; else bad "generated marketplace.json invalid"; fi
if python3 -c "import json,sys;m=json.load(open('$GEN/.claude-plugin/marketplace.json'));sys.exit(0 if m['plugins'][0].get('license')=='GPL-3.0-or-later' else 1)" 2>/dev/null; then ok "generated marketplace.json plugins license is GPL-3.0-or-later"; else bad "generated marketplace.json plugins license wrong or missing"; fi
if python3 -c "import json,sys;m=json.load(open('$GEN/.claude-plugin/marketplace.json'));sys.exit(0 if m['metadata']['version']==m['plugins'][0]['version'] else 1)" 2>/dev/null; then ok "generated marketplace.json metadata.version matches plugins entry version"; else bad "generated marketplace.json version fields out of sync"; fi
if python3 -c "import json,sys;d=json.load(open('$GEN/.claude-plugin/plugin.json'));sys.exit(0 if 'Smoke test plugin.' in str(d) else 1)" 2>/dev/null; then ok "PLUGIN_DESC appears in generated plugin.json"; else bad "PLUGIN_DESC missing from generated plugin.json"; fi
if python3 -c "import json,sys;m=json.load(open('$GEN/.claude-plugin/marketplace.json'));sys.exit(0 if any('Smoke test plugin.' in str(p.get('description','')) for p in m.get('plugins',[])) else 1)" 2>/dev/null; then ok "PLUGIN_DESC appears in generated marketplace.json plugin entry"; else bad "PLUGIN_DESC missing from generated marketplace.json plugin entry"; fi
if python3 -c "import json,sys;d=json.load(open('$GEN/.claude-plugin/plugin.json'));sys.exit(0 if d.get('name')=='demo' else 1)" 2>/dev/null; then ok "generated plugin.json name matches plugin name"; else bad "generated plugin.json name wrong or missing"; fi
if python3 -c "import json,sys;m=json.load(open('$GEN/.claude-plugin/marketplace.json'));sys.exit(0 if m.get('name')=='demo' else 1)" 2>/dev/null; then ok "generated marketplace.json name matches plugin name"; else bad "generated marketplace.json name wrong or missing"; fi
if python3 -c "import json,sys;m=json.load(open('$GEN/.claude-plugin/marketplace.json'));sys.exit(0 if m['plugins'][0].get('name')=='demo' else 1)" 2>/dev/null; then ok "generated marketplace.json plugins[0].name matches plugin name"; else bad "generated marketplace.json plugins[0].name wrong or missing"; fi
if python3 -c "import json,sys;m=json.load(open('$GEN/.claude-plugin/marketplace.json'));sys.exit(0 if m['plugins'][0].get('source')=='./' else 1)" 2>/dev/null; then ok "generated marketplace.json plugins[0].source is ./"; else bad "generated marketplace.json plugins[0].source wrong or missing"; fi
if [ -f "$GEN/skills/demo/SKILL.md" ]; then ok "generated skills/demo/SKILL.md exists"; else bad "generated SKILL.md missing"; fi
if grep -q "Smoke test plugin." "$GEN/skills/demo/SKILL.md" 2>/dev/null; then ok "PLUGIN_DESC appears in generated SKILL.md description"; else bad "PLUGIN_DESC missing from generated SKILL.md description"; fi
if grep -q "^name: demo$" "$GEN/skills/demo/SKILL.md" 2>/dev/null; then ok "generated SKILL.md name field matches plugin name"; else bad "generated SKILL.md name field wrong or missing"; fi
if grep -q '^  version: "0.1.0"$' "$GEN/skills/demo/SKILL.md" 2>/dev/null; then ok "generated SKILL.md has metadata version field"; else bad "generated SKILL.md missing or malformed metadata version field"; fi
if [ -f "$GEN/LICENSE" ]; then ok "generated LICENSE exists"; else bad "generated LICENSE missing"; fi
if [ -f "$GEN/.github/workflows/ci.yml" ]; then ok "generated ci.yml exists"; else bad "generated ci.yml missing"; fi
if grep -q "shellcheck" "$GEN/.github/workflows/ci.yml" 2>/dev/null; then ok "generated ci.yml includes shellcheck step"; else bad "generated ci.yml missing shellcheck step"; fi
if grep -q "bash tests/run.sh" "$GEN/.github/workflows/ci.yml" 2>/dev/null; then ok "generated ci.yml includes smoke-test step"; else bad "generated ci.yml missing smoke-test step"; fi
if [ -f "$GEN/.gitignore" ]; then ok "generated .gitignore exists"; else bad "generated .gitignore missing"; fi
if bash "$GEN/tests/run.sh" >/dev/null 2>&1; then ok "generated tests/run.sh runs"; else bad "generated tests/run.sh failed"; fi
# The generated suite must also catch a syntactically broken bundled script
# locally (not just in CI shellcheck) — corrupt a copy and expect a non-zero exit.
GEN_BROKE="$TMP/gen_broke"
NO_GIT=1 "$ROOT/scripts/make-plugin.sh" demo "$GEN_BROKE" >/dev/null
printf '\nif then fi\n' >> "$GEN_BROKE/scripts/bump-version.sh"   # invalid bash syntax
if bash "$GEN_BROKE/tests/run.sh" >/dev/null 2>&1; then bad "generated tests/run.sh missed a broken bundled script"; else ok "generated tests/run.sh catches a syntactically broken bundled script"; fi
if command -v shellcheck >/dev/null 2>&1; then
  if shellcheck "$GEN"/scripts/*.sh "$GEN"/tests/*.sh >/dev/null 2>&1; then ok "generated scripts pass shellcheck"; else bad "generated scripts fail shellcheck"; fi
else
  ok "generated scripts shellcheck skipped (shellcheck not installed)"
fi
if [ -f "$GEN/scripts/bump-version.sh" ]; then ok "generated scripts/bump-version.sh exists"; else bad "generated scripts/bump-version.sh missing"; fi
if bash -n "$GEN/scripts/bump-version.sh" 2>/dev/null; then ok "generated scripts/bump-version.sh parses as bash"; else bad "generated scripts/bump-version.sh has bash syntax error"; fi
if grep -q "## \[0\.1\.0\]" "$GEN/CHANGELOG.md" 2>/dev/null; then ok "generated CHANGELOG.md has initial [0.1.0] section"; else bad "generated CHANGELOG.md missing [0.1.0] section"; fi
if grep -q "^# demo$" "$GEN/README.md" 2>/dev/null; then ok "generated README.md contains plugin name as heading"; else bad "generated README.md missing plugin name heading"; fi
if [ -f "$GEN/MISSION.md" ] && grep -q "demo" "$GEN/MISSION.md" 2>/dev/null && grep -q "Non-goals" "$GEN/MISSION.md" 2>/dev/null; then ok "generated MISSION.md exists, names the plugin, and has Non-goals"; else bad "generated MISSION.md missing or malformed"; fi

# --- Test 2b: make-plugin.sh rejects invalid plugin name ------------------
if NO_GIT=1 "$ROOT/scripts/make-plugin.sh" "MyPlugin" "$TMP/invalid-name" >/dev/null 2>&1; then bad "make-plugin accepted invalid name"; else ok "make-plugin rejects invalid name (uppercase)"; fi
if NO_GIT=1 "$ROOT/scripts/make-plugin.sh" "1plugin" "$TMP/gen_1p" >/dev/null 2>&1; then bad "make-plugin accepted name starting with digit"; else ok "make-plugin rejects name starting with digit"; fi

# --- Test 2c: make-plugin.sh rejects pre-existing destination --------------
GEN2="$TMP/gen2"
NO_GIT=1 "$ROOT/scripts/make-plugin.sh" demo "$GEN2" >/dev/null
if NO_GIT=1 "$ROOT/scripts/make-plugin.sh" demo "$GEN2" >/dev/null 2>&1; then bad "make-plugin accepted duplicate destination"; else ok "make-plugin rejects duplicate destination"; fi
if "$ROOT/scripts/make-plugin.sh" >/dev/null 2>&1; then bad "make-plugin accepted no arguments"; else ok "make-plugin exits non-zero with no arguments"; fi

# --- Test 2d: make-plugin.sh injects AUTHOR_NAME into generated LICENSE -----
GEN_AUTH="$TMP/gen_auth"
AUTHOR_NAME="Test Author" NO_GIT=1 "$ROOT/scripts/make-plugin.sh" demo "$GEN_AUTH" >/dev/null
if grep -q "Test Author" "$GEN_AUTH/LICENSE" 2>/dev/null; then ok "AUTHOR_NAME appears in generated LICENSE"; else bad "AUTHOR_NAME missing from generated LICENSE"; fi
if python3 -c "import json,sys;m=json.load(open('$GEN_AUTH/.claude-plugin/marketplace.json'));sys.exit(0 if m.get('owner',{}).get('name')=='Test Author' else 1)" 2>/dev/null; then ok "AUTHOR_NAME in generated marketplace.json owner.name"; else bad "AUTHOR_NAME missing from generated marketplace.json owner.name"; fi

# --- Test 2g: make-plugin.sh JSON-escapes special chars in manifests --------
GEN_ESC="$TMP/gen_esc"
ESC_DESC='Has "quotes" and a \backslash'
ESC_AUTH='Ada "Lovelace"'
NO_GIT=1 PLUGIN_DESC="$ESC_DESC" AUTHOR_NAME="$ESC_AUTH" "$ROOT/scripts/make-plugin.sh" demo "$GEN_ESC" >/dev/null 2>&1
if python3 -c "import json;json.load(open('$GEN_ESC/.claude-plugin/plugin.json'))" 2>/dev/null; then ok "plugin.json stays valid JSON when desc has quotes/backslash"; else bad "plugin.json invalid when desc has quotes/backslash"; fi
if python3 -c "import json;json.load(open('$GEN_ESC/.claude-plugin/marketplace.json'))" 2>/dev/null; then ok "marketplace.json stays valid JSON when author/desc have quotes"; else bad "marketplace.json invalid when author/desc have quotes"; fi
if EXP="$ESC_DESC" python3 -c "import json,os,sys;d=json.load(open('$GEN_ESC/.claude-plugin/plugin.json'));sys.exit(0 if d['description']==os.environ['EXP'] else 1)" 2>/dev/null; then ok "plugin.json description round-trips special chars intact"; else bad "plugin.json description garbled special chars"; fi
if EXP="$ESC_AUTH" python3 -c "import json,os,sys;m=json.load(open('$GEN_ESC/.claude-plugin/marketplace.json'));sys.exit(0 if m['owner']['name']==os.environ['EXP'] else 1)" 2>/dev/null; then ok "marketplace.json owner.name round-trips special chars intact"; else bad "marketplace.json owner.name garbled special chars"; fi

# --- Test 2e: bump-version.sh rejects unknown arguments --------------------
if "$ROOT/scripts/bump-version.sh" patch --garbage >/dev/null 2>&1; then bad "bump-version accepted unknown argument --garbage"; else ok "bump-version rejects unknown argument (--garbage)"; fi
mvrc=0; mverr="$("$ROOT/scripts/bump-version.sh" patch -m 2>&1 >/dev/null)" || mvrc=$?
if [ "$mvrc" -ne 0 ]; then ok "bump-version rejects -m with no value (non-zero exit)"; else bad "bump-version accepted -m with no value"; fi
if printf '%s' "$mverr" | grep -q "requires a value"; then ok "bump-version -m no-value prints 'requires a value' diagnostic"; else bad "bump-version -m no-value missing diagnostic"; fi
if "$ROOT/scripts/bump-version.sh" >/dev/null 2>&1; then bad "bump-version accepted no arguments"; else ok "bump-version exits non-zero with no arguments"; fi
if "$ROOT/scripts/bump-version.sh" 1.a.b >/dev/null 2>&1; then bad "bump-version accepted invalid X.Y.Z format (1.a.b)"; else ok "bump-version rejects invalid bump format (1.a.b)"; fi
if "$ROOT/scripts/bump-version.sh" --help >/dev/null 2>/dev/null; then ok "bump-version --help exits 0"; else bad "bump-version --help exits non-zero"; fi
if "$ROOT/scripts/bump-version.sh" --help 2>/dev/null | grep -q -- '--dry-run'; then ok "bump-version --help mentions --dry-run"; else bad "bump-version --help missing --dry-run"; fi
if "$ROOT/scripts/make-plugin.sh" --help >/dev/null 2>/dev/null; then ok "make-plugin --help exits 0"; else bad "make-plugin --help exits non-zero"; fi

# --- Test 2f: make-plugin.sh git init path creates an initial commit -------
GEN_GIT="$TMP/gen_git"
if AUTHOR_NAME="Test Author" AUTHOR_EMAIL="test@test.com" "$ROOT/scripts/make-plugin.sh" demo "$GEN_GIT" >/dev/null 2>&1; then
  if git -C "$GEN_GIT" log --oneline 2>/dev/null | grep -q "Initial scaffold"; then ok "make-plugin.sh git path creates initial commit"; else bad "make-plugin.sh git path: initial commit message missing"; fi
  if git -C "$GEN_GIT" log --format="%ae" -1 2>/dev/null | grep -q "test@test.com"; then ok "AUTHOR_EMAIL set as git commit author"; else bad "AUTHOR_EMAIL not recorded in git commit author"; fi
  if python3 -c "import json,sys;m=json.load(open('$GEN_GIT/.claude-plugin/marketplace.json'));sys.exit(0 if m.get('owner',{}).get('email')=='test@test.com' else 1)" 2>/dev/null; then ok "AUTHOR_EMAIL in generated marketplace.json owner.email"; else bad "AUTHOR_EMAIL missing from generated marketplace.json owner.email"; fi
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

# --- Test 7d: bump-version.sh exits non-zero on malformed current version --
BADVER="$TMP/badver"
mkdir -p "$BADVER"
( cd "$ROOT" && tar --exclude=.git --exclude=.planwright -cf - . ) | ( cd "$BADVER" && tar -xf - )
python3 -c "import json; d=json.load(open('$BADVER/.claude-plugin/plugin.json')); d['version']='1.0'; open('$BADVER/.claude-plugin/plugin.json','w').write(json.dumps(d,indent=2)+'\n')"
if "$BADVER/scripts/bump-version.sh" patch >/dev/null 2>&1; then bad "bump-version accepted malformed current version (1.0)"; else ok "bump-version exits non-zero on malformed current version (1.0)"; fi

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
if printf '%s' "$dr_out" | grep -q "would sync"; then ok "--dry-run shows which skills would be synced"; else bad "--dry-run missing skill sync preview"; fi
dr_note_out="$("$DRYR/scripts/bump-version.sh" patch --dry-run -m "dry note" 2>/dev/null)"
if printf '%s' "$dr_note_out" | grep -q "dry note"; then ok "--dry-run -m flag shows note in CHANGELOG preview"; else bad "--dry-run -m flag: note missing from CHANGELOG preview"; fi

# --- Test 9: the repo's own version sources agree at rest ------------------
rv="$(ver "$ROOT/.claude-plugin/plugin.json" "['version']")"
rmeta="$(ver "$ROOT/.claude-plugin/marketplace.json" "['metadata']['version']")"
rentry="$(ver "$ROOT/.claude-plugin/marketplace.json" "['plugins'][0]['version']")"
rskill="$(grep -m1 '  version:' "$ROOT/skills/planwright/SKILL.md" | sed -E 's/.*"([^"]+)".*/\1/')"
if [ "$rv" = "$rmeta" ] && [ "$rv" = "$rentry" ] && [ "$rv" = "$rskill" ]; then ok "repo version sources agree at rest ($rv)"; else bad "repo version drift: plugin=$rv meta=$rmeta entry=$rentry skill=$rskill"; fi
if grep -q "## \[$rv\]" "$ROOT/CHANGELOG.md"; then ok "CHANGELOG.md has a section for the current version [$rv]"; else bad "CHANGELOG.md missing a section for the current version [$rv]"; fi

# --- Test 10: SKILL.md structural lint -------------------------------------
if python3 - "$ROOT/skills/planwright/SKILL.md" <<'PY' 2>/dev/null
import re, sys
t = open(sys.argv[1]).read()
missing = []
if not re.search(r'\n  version:\s*"\d+\.\d+\.\d+"', t): missing.append("version-frontmatter")
for h in ["### Stage 0", "### Stage 1 ", "### Stage 1.5", "### Stage 2 ", "### Stages 3", "### Stage 8", "### Stage 9", "### Stage 10", "### Stage 11"]:
    if h not in t: missing.append("heading:" + h)
for s in ["## Inputs", "## Maturity ladder", "## OUTPUT FORMAT", "## Hard rules"]:
    if s not in t: missing.append("section:" + s)
for f in ["Mode:", "Rationale:", "Evidence:", "Surfaces:", "New Surfaces:", "Development:", "Acceptance:", "Verification:"]:
    if f not in t: missing.append("field:" + f)
sys.exit(1 if missing else 0)
PY
then ok "SKILL.md structural lint passes (stages, sections, item fields present)"; else bad "SKILL.md structural lint failed (missing stage/section/field)"; fi

# --- Test 10b: bundled scripts are invoked via the skill base dir, not cwd ---
# Regression guard for v1.21.1: SKILL.md must not invoke a bundled script as a
# bare `python3 scripts/<name>.py` command — for an installed user the cwd is
# the target repo, which has no planwright scripts/ dir, so a bare path fails.
# The required form is the base-dir-relative `<scripts>/<name>.py`. (The prose
# file-name mention of `scripts/lint-plan.py` is not a command and must not trip
# this — the pattern below matches only `python3[ ]scripts/...` invocations.)
if grep -nE 'python3[[:space:]]+scripts/(build-graph|lint-plan)\.py' "$ROOT/skills/planwright/SKILL.md" >/dev/null 2>&1; then
  bad "SKILL.md invokes a bundled script via a bare scripts/ path (use <scripts>/ from the skill base dir)"
else
  ok "SKILL.md invokes bundled scripts via the skill base dir, not a bare scripts/ path"
fi

# (b) the bundled scripts themselves are cwd-independent: invoked by absolute
# path with --root from a foreign cwd (NOT the repo root), they still succeed.
# lint-plan checks Surfaces existence against --root, so README.md resolves to
# the repo even though cwd is elsewhere — proving the path handling is correct.
FOREIGN="$TMP/foreign_cwd"
mkdir -p "$FOREIGN"
cat > "$FOREIGN/mini_plan.md" <<'PLAN'
# planwright Plan — .
- [ ] Foreign-cwd probe item
      Mode: docs
      Rationale: exercise lint-plan from a non-repo cwd.
      Evidence: README.md exists in the repo root.
      Surfaces: README.md
      Development: no-op probe of the README.md surface.
      Acceptance: lint passes; nothing changes.
      Verification: true
PLAN
if ( cd "$FOREIGN" \
     && python3 "$ROOT/scripts/build-graph.py" --root "$ROOT" >/dev/null 2>&1 \
     && python3 "$ROOT/scripts/lint-plan.py" --root "$ROOT" --plan "$FOREIGN/mini_plan.md" --quiet ); then
  ok "bundled scripts run from a foreign cwd via absolute path + --root"
else
  bad "bundled scripts failed when invoked from a cwd other than the repo root"
fi

# --- Test 11: scripts/build-graph.py builds a schema-conforming graph -------
gj_file="$TMP/build_graph_out.json"
python3 "$ROOT/scripts/build-graph.py" --root "$ROOT" > "$gj_file" 2>/dev/null
if python3 - "$gj_file" <<'PY' 2>/dev/null
import json, re, sys
g = json.load(open(sys.argv[1]))
assert g["version"] == 1
assert re.fullmatch(r"[0-9a-f]{40}", g["graph_built_at_sha"])
assert g["ranking_signal"] in ("centrality", "coupling")
assert {"coupling_window_commits", "coupling_min_cooccurrence", "ranked_surface_limit"} <= set(g["params"])
assert g["nodes"], "no nodes"
need = {"sha256", "loc", "branch_count", "branch_at", "lang", "git_churn", "defines", "defines_at", "imports", "is_test", "covered_by_test", "pagerank", "is_articulation", "last_audited_sha"}
for f, n in g["nodes"].items():
    assert need <= set(n), f
    assert isinstance(n["is_test"], bool) and isinstance(n["covered_by_test"], bool), f
    assert isinstance(n["defines_at"], dict), f
    assert all(isinstance(v, int) and v >= 1 for v in n["defines_at"].values()), f
    assert isinstance(n["branch_count"], int) and n["branch_count"] >= 0, f
    assert isinstance(n["branch_at"], dict), f
    assert all(isinstance(v, int) and v >= 0 for v in n["branch_at"].values()), f
    # branch_at keys are a subset of the file's defined symbols
    assert set(n["branch_at"]) <= set(n["defines"]), f
assert isinstance(g["ranked"], list) and all(x in g["nodes"] for x in g["ranked"])
# ranked_code: a list of branch_count>0 nodes only, in the same priority order as ranked
assert isinstance(g["ranked_code"], list)
assert all(x in g["nodes"] and g["nodes"][x]["branch_count"] > 0 for x in g["ranked_code"]), g["ranked_code"]
# code nodes keep their relative ranked order in ranked_code
code_in_ranked = [x for x in g["ranked"] if g["nodes"][x]["branch_count"] > 0]
assert g["ranked_code"][:len(code_in_ranked)] == code_in_ranked, (g["ranked_code"], code_in_ranked)
# ranked_cold: the explore frontier — also branch_count>0 code nodes only
assert isinstance(g["ranked_cold"], list)
assert all(x in g["nodes"] and g["nodes"][x]["branch_count"] > 0 for x in g["ranked_cold"]), g["ranked_cold"]
# import_cycles: a list of >=2-member groups of real nodes (directed SCCs)
assert isinstance(g["import_cycles"], list)
for cyc in g["import_cycles"]:
    assert isinstance(cyc, list) and len(cyc) >= 2 and all(x in g["nodes"] for x in cyc), cyc
for c in g["clusters"]:
    assert isinstance(c["id"], int) and isinstance(c["members"], list)
for e in g["coupling_edges"]:
    assert {"a", "b", "cooccur", "weight"} <= set(e)
d = g["dirty"]
assert {"is_first_run", "whole_graph", "reason", "changed", "nodes", "clusters"} <= set(d), d
# no prior was passed, so this is a first run: every node is dirty, all clusters touched
assert d["is_first_run"] is True and d["whole_graph"] is True and d["reason"] == "first-run", d
assert set(d["nodes"]) == set(g["nodes"]) and d["changed"] == [], d
assert set(d["clusters"]) == {c["id"] for c in g["clusters"]}, d
PY
then ok "build-graph.py output conforms to graph-memory schema"; else bad "build-graph.py output missing or non-conforming"; fi

# --- Test 11b: build-graph.py --prior preserves last_audited_sha -----------
# Stage 11's incremental-audit skipping depends on last_audited_sha surviving
# rebuilds; without --prior preservation every run re-audits the whole tree.
prior_file="$TMP/prior_graph.json"
python3 - "$gj_file" "$prior_file" <<'PY' 2>/dev/null
import json, sys
g = json.load(open(sys.argv[1]))
for n in g["nodes"].values():
    n["last_audited_sha"] = g["graph_built_at_sha"]
json.dump(g, open(sys.argv[2], "w"))
PY
new_graph="$TMP/new_graph.json"
python3 "$ROOT/scripts/build-graph.py" --root "$ROOT" --prior "$prior_file" > "$new_graph" 2>/dev/null
if python3 - "$prior_file" "$new_graph" <<'PY' 2>/dev/null
import json, sys
prior = json.load(open(sys.argv[1]))
new = json.load(open(sys.argv[2]))
sha = prior["graph_built_at_sha"]
carried = [f for f in new["nodes"] if f in prior["nodes"]]
assert carried, "no carried-over nodes"
assert all(new["nodes"][f]["last_audited_sha"] == sha for f in carried), "last_audited_sha not preserved"
PY
then ok "build-graph.py --prior preserves last_audited_sha across a rebuild"; else bad "build-graph.py --prior dropped last_audited_sha"; fi

# --- Test 11c: build-graph.py coupling fallback ranks a degenerate graph ----
# A repo whose files do not import each other (n_import_edges below threshold)
# must fall back from PageRank to change-coupling ranking. This path never runs
# on planwright's own tree (it ranks by centrality), so exercise it explicitly.
COUPREPO="$TMP/couprepo"
mkdir -p "$COUPREPO"
git -C "$COUPREPO" init -q
for f in alpha beta gamma delta; do echo "# $f" > "$COUPREPO/$f.md"; done
git -C "$COUPREPO" add -A
git -C "$COUPREPO" -c user.name=t -c user.email=t@e.com commit -qm init
# Co-commit alpha+beta three more times so their pair clears coupling_min_cooccurrence (3).
for i in 1 2 3; do
  echo "edit $i" >> "$COUPREPO/alpha.md"
  echo "edit $i" >> "$COUPREPO/beta.md"
  git -C "$COUPREPO" add -A
  git -C "$COUPREPO" -c user.name=t -c user.email=t@e.com commit -qm "co $i"
done
coup_out="$TMP/coup_graph.json"
python3 "$ROOT/scripts/build-graph.py" --root "$COUPREPO" > "$coup_out" 2>/dev/null
if python3 - "$coup_out" <<'PY' 2>/dev/null
import json, sys
g = json.load(open(sys.argv[1]))
assert g["ranking_signal"] == "coupling", g["ranking_signal"]
edge = [e for e in g["coupling_edges"] if {e["a"], e["b"]} == {"alpha.md", "beta.md"}]
assert edge and edge[0]["cooccur"] >= 3, "alpha/beta coupling edge missing"
assert set(g["ranked"][:2]) == {"alpha.md", "beta.md"}, g["ranked"][:2]
PY
then ok "build-graph.py coupling fallback ranks the coupled pair first"; else bad "build-graph.py coupling fallback ranking wrong"; fi

# --- Test 11c2: ranked_code excludes zero-branch nodes Stage 2b cannot read ----
# A doc/data node carries branch_count 0 and no functions; link-centrality can
# float it to the top of `ranked`, but ranked_code must hold only code nodes so
# Stage 2b's function walk is not led to a file with nothing to read.
RCREPO="$TMP/rankedcoderepo"
mkdir -p "$RCREPO"
git -C "$RCREPO" init -q
printf '#!/usr/bin/env bash\nf() { if true; then for x in a b; do echo hi; done; fi; }\n' > "$RCREPO/lib.sh"
printf '# Doc\n[lib](lib.sh) and more text linking [lib](lib.sh).\n' > "$RCREPO/doc.md"
git -C "$RCREPO" add -A
git -C "$RCREPO" -c user.name=t -c user.email=t@e.com commit -qm init
rc_out="$TMP/rc_graph.json"
python3 "$ROOT/scripts/build-graph.py" --root "$RCREPO" > "$rc_out" 2>/dev/null
if python3 - "$rc_out" <<'PY' 2>/dev/null
import json, sys
g = json.load(open(sys.argv[1]))
assert "lib.sh" in g["ranked_code"], g["ranked_code"]
assert "doc.md" not in g["ranked_code"], g["ranked_code"]
assert g["nodes"]["doc.md"]["branch_count"] == 0 and g["nodes"]["lib.sh"]["branch_count"] > 0
# every ranked_code member is a branch>0 node
assert all(g["nodes"][f]["branch_count"] > 0 for f in g["ranked_code"]), g["ranked_code"]
PY
then ok "ranked_code holds only code nodes, excluding zero-branch docs"; else bad "ranked_code leaked a zero-branch node or dropped a code node"; fi

# --- Test 11c2b: ranked_cold surfaces the explore frontier (uncovered first) ----
# ranked_cold is the inverse of ranked_code for the opt-in `explore` escalation: it
# leads with the code the default hot-core routing neglects. On a fresh build both
# code nodes are never-audited (a tie on the primary key), so the covered_by_test
# key decides — the uncovered orphan must rank ahead of the test-covered core.
CLDREPO="$TMP/coldrepo"
mkdir -p "$CLDREPO"
git -C "$CLDREPO" init -q
printf '#!/usr/bin/env bash\ncore() { if true; then echo hi; fi; }\n' > "$CLDREPO/core.sh"
printf '#!/usr/bin/env bash\norphan() { if true; then echo bye; fi; }\n' > "$CLDREPO/orphan.sh"
printf '#!/usr/bin/env bash\nsource core.sh\ncore_test() { core; }\n' > "$CLDREPO/core_test.sh"
git -C "$CLDREPO" add -A
git -C "$CLDREPO" -c user.name=t -c user.email=t@e.com commit -qm init
cld_out="$TMP/cold_graph.json"
python3 "$ROOT/scripts/build-graph.py" --root "$CLDREPO" > "$cld_out" 2>/dev/null
if python3 - "$cld_out" <<'PY' 2>/dev/null
import json, sys
g = json.load(open(sys.argv[1]))
rc = g["ranked_cold"]
# a test sources core.sh => core.sh is covered; orphan.sh is reached by nothing
assert g["nodes"]["core.sh"]["covered_by_test"] is True, g["nodes"]["core.sh"]
assert g["nodes"]["orphan.sh"]["covered_by_test"] is False, g["nodes"]["orphan.sh"]
# both are branch>0 code nodes on the frontier list; the no-branch test file is not
assert "orphan.sh" in rc and "core.sh" in rc, rc
assert "core_test.sh" not in rc, rc
# the uncovered orphan leads the covered core on the cold frontier (the inversion)
assert rc.index("orphan.sh") < rc.index("core.sh"), rc
PY
then ok "ranked_cold leads the explore frontier with uncovered code (inverse of ranked_code)"; else bad "ranked_cold did not surface the uncovered frontier node first"; fi

# --- Test 11c2c: ranked_cold's never-audited primary key outranks the covered key
# cold_key's FIRST element is `last_audited_sha is None` (never-audited first). Test
# 11c2b ties on it (fresh repo => both null), so isolate it here: two uncovered code
# files, one stamped audited via a prior graph and one never-audited. The never-audited
# file must lead even though both are uncovered, so only the primary key can decide.
NAREPO="$TMP/narepo"
mkdir -p "$NAREPO"
git -C "$NAREPO" init -q
printf '#!/usr/bin/env bash\na() { if true; then echo a; fi; }\n' > "$NAREPO/a.sh"
printf '#!/usr/bin/env bash\nb() { if true; then echo b; fi; }\n' > "$NAREPO/b.sh"
git -C "$NAREPO" add -A
git -C "$NAREPO" -c user.name=t -c user.email=t@e.com commit -qm init
na_prior="$TMP/na_prior.json"
python3 "$ROOT/scripts/build-graph.py" --root "$NAREPO" > "$na_prior" 2>/dev/null
# mark a.sh as already audited; b.sh stays never-audited (last_audited_sha null)
python3 - "$na_prior" <<'PY'
import json, sys
p = sys.argv[1]; g = json.load(open(p))
g["nodes"]["a.sh"]["last_audited_sha"] = g["graph_built_at_sha"]
json.dump(g, open(p, "w"))
PY
na_new="$TMP/na_new.json"
python3 "$ROOT/scripts/build-graph.py" --root "$NAREPO" --prior "$na_prior" > "$na_new" 2>/dev/null
if python3 - "$na_new" <<'PY' 2>/dev/null
import json, sys
g = json.load(open(sys.argv[1])); n = g["nodes"]; rc = g["ranked_cold"]
# the prior stamp survived for a.sh; b.sh remains never-audited
assert n["a.sh"]["last_audited_sha"] is not None, n["a.sh"]
assert n["b.sh"]["last_audited_sha"] is None, n["b.sh"]
# both uncovered => the covered_by_test secondary key ties, so it cannot decide order
assert n["a.sh"]["covered_by_test"] is False and n["b.sh"]["covered_by_test"] is False
# never-audited b.sh must lead audited a.sh on the cold frontier (primary key decides)
assert "a.sh" in rc and "b.sh" in rc, rc
assert rc.index("b.sh") < rc.index("a.sh"), rc
PY
then ok "ranked_cold's never-audited primary key outranks an audited node (covered key tied)"; else bad "ranked_cold ignored the never-audited primary key"; fi

# --- Test 11c3: is_test classification + covered_by_test coverage routing -----
# A test file that imports a source marks it covered_by_test; an unimported
# non-test source stays false. Routing-only: a false is a candidate, not proof.
COVREPO="$TMP/covrepo"
mkdir -p "$COVREPO"
git -C "$COVREPO" init -q
printf 'def helper(x):\n    return x + 1\n' > "$COVREPO/lib.py"
printf 'import lib\n\ndef test_helper():\n    assert lib.helper(1) == 2\n' > "$COVREPO/test_lib.py"
printf 'def orphan():\n    return 0\n' > "$COVREPO/orphan.py"
git -C "$COVREPO" add -A
git -C "$COVREPO" -c user.name=t -c user.email=t@e.com commit -qm init
cov_out="$TMP/cov_graph.json"
python3 "$ROOT/scripts/build-graph.py" --root "$COVREPO" > "$cov_out" 2>/dev/null
if python3 - "$cov_out" <<'PY' 2>/dev/null
import json, sys
n = json.load(open(sys.argv[1]))["nodes"]
assert n["test_lib.py"]["is_test"] is True, n["test_lib.py"]
assert n["lib.py"]["is_test"] is False and n["orphan.py"]["is_test"] is False
assert n["lib.py"]["covered_by_test"] is True, "a test imports lib.py -> covered"
assert n["orphan.py"]["covered_by_test"] is False, "no test reaches orphan.py"
PY
then ok "is_test + covered_by_test route the coverage rung (import-reached source is covered)"; else bad "covered_by_test routing wrong (classification or reach)"; fi

# is_test_node classifies conventional layouts/names without mislabeling sources.
if python3 -B - "$ROOT/scripts/build-graph.py" <<'PY' 2>/dev/null
import importlib.util, sys
spec = importlib.util.spec_from_file_location("bg", sys.argv[1])
bg = importlib.util.module_from_spec(spec); spec.loader.exec_module(bg)
for p in ("tests/run.sh", "src/foo_test.cc", "test_foo.py", "a/b.spec.ts",
          "x/widget_unittest.cc", "pkg/WidgetTest.java", "spec/thing.rb", "Test.java"):
    assert bg.is_test_node(p), p
for p in ("scripts/build-graph.py", "src/latest.js", "docs/attestation.md", "lib/contest.py"):
    assert not bg.is_test_node(p), p
PY
then ok "is_test_node classifies test paths without mislabeling sources"; else bad "is_test_node misclassified a path"; fi

# --- Test 11c4: import_cycles detects circular imports for the Stage 3 lens ----
# A directed import cycle (a imports b, b imports a) is a strongly-connected
# group the architecture lens should flag; an acyclic importer is not in any.
CYCREPO="$TMP/cycrepo"
mkdir -p "$CYCREPO"
git -C "$CYCREPO" init -q
printf 'import b\n' > "$CYCREPO/a.py"
printf 'import a\n' > "$CYCREPO/b.py"
printf 'import a\n' > "$CYCREPO/c.py"
git -C "$CYCREPO" add -A
git -C "$CYCREPO" -c user.name=t -c user.email=t@e.com commit -qm init
cyc_out="$TMP/cyc_graph.json"
python3 "$ROOT/scripts/build-graph.py" --root "$CYCREPO" > "$cyc_out" 2>/dev/null
if python3 - "$cyc_out" <<'PY' 2>/dev/null
import json, sys
g = json.load(open(sys.argv[1]))
cycles = [set(c) for c in g["import_cycles"]]
assert {"a.py", "b.py"} in cycles, g["import_cycles"]
# c.py imports a but nothing imports c -> not in any cycle
assert not any("c.py" in c for c in cycles), g["import_cycles"]
PY
then ok "import_cycles flags a circular import and excludes an acyclic importer"; else bad "import_cycles missed a cycle or over-flagged"; fi

# --- Test 11d: defines_of routes C/C++ + JS symbols (Stage 2b function hints) -
# The `defines` field feeds Stage 2b's "walk ranked, take its top functions".
# C/C++ is planwright's primary target language (constexpr/TEST_F/header rules),
# so empty C/C++ defines would blind Stage 2b on exactly that language.
if python3 -B - "$ROOT/scripts/build-graph.py" <<'PY' 2>/dev/null
import importlib.util, sys
spec = importlib.util.spec_from_file_location("bg", sys.argv[1])
bg = importlib.util.module_from_spec(spec); spec.loader.exec_module(bg)

cpp = (
    '#include "foo.h"\n'
    "class Widget {\n public:\n"
    "  int compute(int n) {\n    if (n > 0) { return n + 1; }\n    return 0;\n  }\n};\n"
    "constexpr int add(int a, int b) { return a + b; }\n"
    "void Widget::reset() { state_ = 0; }\n"
    "int prototype_only(int x);\n"
    "TEST_F(WidgetTest, Computes) {\n  EXPECT_EQ(add(1, 2), 3);\n}\n"
)
d = bg.defines_of("c", cpp)
for want in ("Widget", "compute", "add", "reset", "WidgetTest"):
    assert want in d, (want, d)
# calls, control-flow, and prototypes must not masquerade as definitions
assert "EXPECT_EQ" not in d and "if" not in d and "prototype_only" not in d, d

js = (
    "export function handle(req) {}\n"
    "class Server {}\n"
    "export const route = (req, res) => {};\n"
    "const helper = x => x + 1;\n"
)
dj = bg.defines_of("js", js)
for want in ("handle", "Server", "route", "helper"):
    assert want in dj, (want, dj)

# defines_at maps each symbol to its 1-based definition line (Stage 2b jump hint)
dat = bg.defines_at_of("c", cpp)
assert dat["Widget"] == 2, dat       # "class Widget {" is line 2
assert dat["compute"] == 3, dat      # method match anchors at its leading line
assert dat["add"] == 9, dat          # "constexpr int add(...)" is line 9
PY
then ok "defines_of extracts C/C++ + JS symbols (functions, classes, gtest groups)"; else bad "defines_of missing C/C++ or JS symbols, or leaking non-definitions"; fi

# --- Test 11d2: EXT_LANG recognizes alternate C/C++ + JS/TS extensions --------
# The extra c/c++ extensions (.cc/.cxx/.hh/...) are planwright's primary target,
# and .jsx/.tsx/.mjs/.cjs already appear in JS_EXTS as resolvable import targets;
# an unrecognized source extension routes as lang "unknown" and contributes no
# defines/imports/branch_count, blinding Stage 2b on those files.
if python3 -B - "$ROOT/scripts/build-graph.py" <<'PY' 2>/dev/null
import importlib.util, sys
spec = importlib.util.spec_from_file_location("bg", sys.argv[1])
bg = importlib.util.module_from_spec(spec); spec.loader.exec_module(bg)
for ext in ("cc", "cxx", "c++", "hh", "hxx", "tpp"):
    assert bg.lang_of("x." + ext, b"int f(){}") == "c", ext
for ext in ("jsx", "tsx", "mjs", "cjs"):
    assert bg.lang_of("x." + ext, b"export const f = () => 1") == "js", ext
# previously-recognized extensions are unchanged
for ext, want in (("c", "c"), ("h", "c"), ("cpp", "c"), ("hpp", "c"),
                  ("js", "js"), ("ts", "js"), ("py", "python"), ("sh", "bash")):
    assert bg.lang_of("x." + ext, b"") == want, (ext, want)
# every JS_EXTS target extension is now also a recognized source language
for e in bg.JS_EXTS:
    assert bg.lang_of("x" + e, b"") == "js", e
# a .cc file yields extracted defines + branch_count; a .tsx file is js
cc = "int compute(int n) {\n  if (n > 0) return n;\n  return 0;\n}\n"
assert "compute" in bg.defines_of("c", cc), bg.defines_of("c", cc)
assert bg.branch_count_of("c", cc) >= 1
assert bg.lang_of("Widget.tsx", b"export const W = () => 1") == "js"
PY
then ok "EXT_LANG recognizes alternate C/C++ and JS/TS extensions"; else bad "EXT_LANG missing alternate extensions or changed a known one"; fi

# --- Test 11d3: Rust source support (lang, defines, branch_count, mod/use edge) -
# A .rs file must route as lang "rust" with extracted defines + branch_count and a
# resolved mod/use import edge, so a Rust repo gets centrality routing + Stage 2b
# function hints instead of degrading to the coupling-only fallback ("unknown").
RSREPO="$TMP/rsrepo"
mkdir -p "$RSREPO/src"
git -C "$RSREPO" init -q
rsgc() { git -C "$RSREPO" -c user.name=t -c user.email=t@e.com commit -q "$@"; }
printf 'mod util;\nuse crate::util::helper;\n\nfn main() {\n    if true { helper(); }\n}\n' > "$RSREPO/src/main.rs"
printf 'pub fn helper() -> i32 {\n    for _ in 0..3 {}\n    1\n}\npub struct Thing;\n' > "$RSREPO/src/util.rs"
git -C "$RSREPO" add -A; rsgc -m init
rs_out="$TMP/rs_graph.json"
python3 "$ROOT/scripts/build-graph.py" --root "$RSREPO" > "$rs_out" 2>/dev/null
if python3 - "$rs_out" "$ROOT/scripts/build-graph.py" <<'PY' 2>/dev/null
import importlib.util, json, sys
g = json.load(open(sys.argv[1]))
n = g["nodes"]
spec = importlib.util.spec_from_file_location("bg", sys.argv[2])
bg = importlib.util.module_from_spec(spec); spec.loader.exec_module(bg)
assert bg.lang_of("x.rs", b"") == "rust", "extension .rs must map to rust"
# both files route as rust (not the coupling-fallback "unknown")
assert n["src/main.rs"]["lang"] == "rust" and n["src/util.rs"]["lang"] == "rust", n
# defines: the entry fn, the helper fn, and the struct type
assert "main" in n["src/main.rs"]["defines"], n["src/main.rs"]["defines"]
for want in ("helper", "Thing"):
    assert want in n["src/util.rs"]["defines"], (want, n["src/util.rs"]["defines"])
# branch_count picks up rust control flow (if in main, for in util)
assert n["src/main.rs"]["branch_count"] > 0 and n["src/util.rs"]["branch_count"] > 0, n
# `mod util;` / `use crate::util::helper` resolve to the sibling module file
assert "src/util.rs" in n["src/main.rs"]["imports"], n["src/main.rs"]["imports"]
PY
then ok "build-graph.py routes Rust source (lang, defines, branch_count, mod/use edge)"; else bad "build-graph.py failed to route Rust source"; fi

# --- Test 11d4: Go source support (lang, defines func/method/type, branch_count) -
# A .go file must route as lang "go" with extracted funcs/methods/types and a
# branch_count, so Stage 2b can walk Go functions instead of seeing opaque nodes.
# (Go imports are absolute module paths, so import edges are intentionally absent.)
GOREPO="$TMP/gorepo"
mkdir -p "$GOREPO"
git -C "$GOREPO" init -q
gogc() { git -C "$GOREPO" -c user.name=t -c user.email=t@e.com commit -q "$@"; }
printf 'package main\n\ntype Server struct {\n\tport int\n}\n\nfunc (s *Server) Handle(n int) int {\n\tif n > 0 {\n\t\tfor i := 0; i < n; i++ {\n\t\t}\n\t}\n\treturn 0\n}\n\nfunc main() {\n\tswitch 1 {\n\tcase 1:\n\t}\n}\n' > "$GOREPO/main.go"
git -C "$GOREPO" add -A; gogc -m init
go_out="$TMP/go_graph.json"
python3 "$ROOT/scripts/build-graph.py" --root "$GOREPO" > "$go_out" 2>/dev/null
if python3 - "$go_out" "$ROOT/scripts/build-graph.py" <<'PY' 2>/dev/null
import importlib.util, json, sys
g = json.load(open(sys.argv[1])); n = g["nodes"]["main.go"]
spec = importlib.util.spec_from_file_location("bg", sys.argv[2])
bg = importlib.util.module_from_spec(spec); spec.loader.exec_module(bg)
assert bg.lang_of("x.go", b"") == "go", "extension .go must map to go"
assert n["lang"] == "go", n
# a method (Handle), a top-level func (main), and a struct type (Server)
for want in ("Handle", "main", "Server"):
    assert want in n["defines"], (want, n["defines"])
# go control flow (if/for/switch/case) feeds branch_count for Stage 2b complexity
assert n["branch_count"] > 0, n
PY
then ok "build-graph.py routes Go source (lang, defines func/method/type, branch_count)"; else bad "build-graph.py failed to route Go source"; fi

# --- Test 11e: coupling fallback ranks by churn-normalized weight, not raw co --
# Two pairs with equal raw cooccur (3): a/b also churn alone (churn 5, weight
# 0.6), c/d only co-change (churn 3, weight 1.0). A raw-cooccur ranking would
# tiebreak on churn and surface a/b; the spec'd weighted degree surfaces c/d.
WREPO="$TMP/wcouprepo"
mkdir -p "$WREPO"
git -C "$WREPO" init -q
wgc() { git -C "$WREPO" -c user.name=t -c user.email=t@e.com commit -q "$@"; }
for f in a b c d; do echo "# $f" > "$WREPO/$f.md"; done
git -C "$WREPO" add -A; wgc -m init
for i in 1 2; do echo "x$i" >> "$WREPO/a.md"; echo "x$i" >> "$WREPO/b.md"; git -C "$WREPO" add -A; wgc -m "ab$i"; done
for i in 1 2; do echo "y$i" >> "$WREPO/c.md"; echo "y$i" >> "$WREPO/d.md"; git -C "$WREPO" add -A; wgc -m "cd$i"; done
for i in 1 2; do echo "s$i" >> "$WREPO/a.md"; git -C "$WREPO" add -A; wgc -m "a$i"; done
for i in 1 2; do echo "s$i" >> "$WREPO/b.md"; git -C "$WREPO" add -A; wgc -m "b$i"; done
wcoup_out="$TMP/wcoup_graph.json"
python3 "$ROOT/scripts/build-graph.py" --root "$WREPO" > "$wcoup_out" 2>/dev/null
if python3 - "$wcoup_out" <<'PY' 2>/dev/null
import json, sys
g = json.load(open(sys.argv[1]))
assert g["ranking_signal"] == "coupling", g["ranking_signal"]
w = {tuple(sorted((e["a"], e["b"]))): e["weight"] for e in g["coupling_edges"]}
# tightly-coupled pair must carry the heavier weight despite equal raw cooccur
assert w[("c.md", "d.md")] > w[("a.md", "b.md")], w
# and therefore rank first under the weighted-degree fallback
assert set(g["ranked"][:2]) == {"c.md", "d.md"}, g["ranked"][:2]
PY
then ok "coupling fallback ranks by weighted degree (not raw cooccur)"; else bad "coupling fallback used raw cooccur instead of weight"; fi

# --- Test 11f: build-graph.py incremental dirty set = changed + 1-hop blast --
# Stage 1.5 step 7: a node is dirty when its sha256 changed, PLUS its 1-hop blast
# radius along import/coupling edges. A changed leaf must drag in its importer but
# leave unrelated files clean — this is what lets Stages 3-7 skip unchanged work.
DREPO="$TMP/dirtyrepo"
mkdir -p "$DREPO"
git -C "$DREPO" init -q
dgc() { git -C "$DREPO" -c user.name=t -c user.email=t@e.com commit -q "$@"; }
printf '# a\n[to b](b.md)\n' > "$DREPO/a.md"   # a.md imports b.md (markdown link)
printf '# b\n' > "$DREPO/b.md"
printf '# c\n' > "$DREPO/c.md"                  # c.md unrelated
printf '# d\n' > "$DREPO/d.md"                  # d.md unrelated
git -C "$DREPO" add -A; dgc -m init
dprior="$TMP/dirty_prior.json"
python3 "$ROOT/scripts/build-graph.py" --root "$DREPO" > "$dprior" 2>/dev/null
printf '# b\nmore\n' > "$DREPO/b.md"            # change only b.md
git -C "$DREPO" add -A; dgc -m "edit b"
dnew="$TMP/dirty_new.json"
python3 "$ROOT/scripts/build-graph.py" --root "$DREPO" --prior "$dprior" > "$dnew" 2>/dev/null
if python3 - "$dnew" <<'PY' 2>/dev/null
import json, sys
d = json.load(open(sys.argv[1]))["dirty"]
assert d["is_first_run"] is False and d["whole_graph"] is False, d
assert d["changed"] == ["b.md"], d                      # only b.md's bytes changed
assert set(d["nodes"]) == {"a.md", "b.md"}, d           # b.md + its importer a.md
assert "c.md" not in d["nodes"] and "d.md" not in d["nodes"], d  # unrelated stay clean
PY
then ok "build-graph.py incremental dirty set is changed node + 1-hop blast radius"; else bad "build-graph.py incremental dirty set wrong (blast radius or scoping)"; fi

# --- Test 11g: build-graph.py whole-graph invalidation on build-config change -
# A changed lockfile/build-config can alter how everything builds, so a localized
# dirty set would under-audit. SKILL.md Stage 1.5 step 7 forces a whole-graph
# re-audit in that case — verify CMakeLists.txt edits flip whole_graph on.
WGREPO="$TMP/wholegraphrepo"
mkdir -p "$WGREPO"
git -C "$WGREPO" init -q
wggc() { git -C "$WGREPO" -c user.name=t -c user.email=t@e.com commit -q "$@"; }
printf 'cmake_minimum_required(VERSION 3.10)\n' > "$WGREPO/CMakeLists.txt"
printf '# a\n' > "$WGREPO/a.md"
printf '# b\n' > "$WGREPO/b.md"
git -C "$WGREPO" add -A; wggc -m init
wgprior="$TMP/wg_prior.json"
python3 "$ROOT/scripts/build-graph.py" --root "$WGREPO" > "$wgprior" 2>/dev/null
printf 'cmake_minimum_required(VERSION 3.20)\n' > "$WGREPO/CMakeLists.txt"  # bump config only
git -C "$WGREPO" add -A; wggc -m "bump cmake"
wgnew="$TMP/wg_new.json"
python3 "$ROOT/scripts/build-graph.py" --root "$WGREPO" --prior "$wgprior" > "$wgnew" 2>/dev/null
if python3 - "$wgnew" <<'PY' 2>/dev/null
import json, sys
g = json.load(open(sys.argv[1]))
d = g["dirty"]
assert d["is_first_run"] is False and d["whole_graph"] is True, d
assert "build-config" in d["reason"] and "CMakeLists.txt" in d["reason"], d
assert set(d["nodes"]) == set(g["nodes"]), d            # every node re-audited
PY
then ok "build-graph.py forces whole-graph re-audit when build-config changes"; else bad "build-graph.py did not invalidate whole graph on build-config change"; fi

# --- Test 11h: articulation_points flags a cut vertex (is_articulation True) -
# articulation_points (iterative DFS lowlink) is the function Stage 2b "always
# includes", but planwright's own import graph is disconnected so its True branch
# never runs here. Chain a.md->b.md->c.md so the undirected import graph is the
# path a-b-c with b.md the cut vertex, and assert only b.md is flagged.
APREPO="$TMP/aprepo"
mkdir -p "$APREPO"
git -C "$APREPO" init -q
agc() { git -C "$APREPO" -c user.name=t -c user.email=t@e.com commit -q "$@"; }
printf '# a\n[to b](b.md)\n' > "$APREPO/a.md"   # a.md imports b.md
printf '# b\n[to c](c.md)\n' > "$APREPO/b.md"   # b.md imports c.md  => b is a cut vertex
printf '# c\n' > "$APREPO/c.md"
git -C "$APREPO" add -A; agc -m init
ap_out="$TMP/ap_graph.json"
python3 "$ROOT/scripts/build-graph.py" --root "$APREPO" > "$ap_out" 2>/dev/null
if python3 - "$ap_out" <<'PY' 2>/dev/null
import json, sys
n = json.load(open(sys.argv[1]))["nodes"]
assert n["b.md"]["is_articulation"] is True, "b.md should be a cut vertex"
assert n["a.md"]["is_articulation"] is False and n["c.md"]["is_articulation"] is False, "leaves are not cut vertices"
PY
then ok "articulation_points flags the cut vertex (is_articulation True)"; else bad "articulation_points missed the cut vertex or over-flagged a leaf"; fi

# --- Test 11i: remaining whole-graph invalidation triggers -----------------
# compute_dirty forces whole_graph beyond the build-config-CHANGED path: when the
# prior graph_built_at_sha is unreachable (commits_since -> None) and when a
# build-config file present in the prior is DELETED. Both ship untested; cover them.
WGX="$TMP/wgx"
mkdir -p "$WGX"
git -C "$WGX" init -q
xgc() { git -C "$WGX" -c user.name=t -c user.email=t@e.com commit -q "$@"; }
printf '# a\n' > "$WGX/a.md"
printf 'cmake_minimum_required(VERSION 3.10)\n' > "$WGX/CMakeLists.txt"
git -C "$WGX" add -A; xgc -m init
wgx_prior="$TMP/wgx_prior.json"
python3 "$ROOT/scripts/build-graph.py" --root "$WGX" > "$wgx_prior" 2>/dev/null
# (a) unreachable prior sha: rewrite graph_built_at_sha to a bogus 40-hex value.
wgx_bogus="$TMP/wgx_bogus.json"
python3 - "$wgx_prior" "$wgx_bogus" <<'PY'
import json, sys
g = json.load(open(sys.argv[1])); g["graph_built_at_sha"] = "0" * 40
json.dump(g, open(sys.argv[2], "w"))
PY
wgx_unreach="$TMP/wgx_unreach.json"
python3 "$ROOT/scripts/build-graph.py" --root "$WGX" --prior "$wgx_bogus" > "$wgx_unreach" 2>/dev/null
if python3 - "$wgx_unreach" <<'PY' 2>/dev/null
import json, sys
d = json.load(open(sys.argv[1]))["dirty"]
assert d["whole_graph"] is True and "unreachable" in d["reason"], d
PY
then ok "whole-graph invalidation when prior graph_built_at_sha is unreachable"; else bad "unreachable prior sha did not force whole-graph re-audit"; fi
# (b) deleted build-config: drop CMakeLists.txt, commit, rebuild against real prior.
git -C "$WGX" rm -q CMakeLists.txt; xgc -m "drop cmake"
wgx_del="$TMP/wgx_del.json"
python3 "$ROOT/scripts/build-graph.py" --root "$WGX" --prior "$wgx_prior" > "$wgx_del" 2>/dev/null
if python3 - "$wgx_del" <<'PY' 2>/dev/null
import json, sys
d = json.load(open(sys.argv[1]))["dirty"]
assert d["whole_graph"] is True and "build-config" in d["reason"] and "CMakeLists.txt" in d["reason"], d
PY
then ok "whole-graph invalidation when a build-config file is deleted"; else bad "deleted build-config did not force whole-graph re-audit"; fi

# --- Test 11i2: whole-graph invalidation when HEAD diverges beyond the window -
# The third whole-graph trigger (build-graph.py compute_dirty): re-audit everything
# when HEAD has moved more than COUPLING_WINDOW_COMMITS commits past the prior
# graph's sha. Drive it in-process with a lowered window so 2 commits cross it.
DVREPO="$TMP/dvrepo"
mkdir -p "$DVREPO"
git -C "$DVREPO" init -q
dvgc() { git -C "$DVREPO" -c user.name=t -c user.email=t@e.com commit -q "$@"; }
printf '# a\n' > "$DVREPO/a.md"
printf '# b\n' > "$DVREPO/b.md"
git -C "$DVREPO" add -A; dvgc -m init
dv_prior="$TMP/dv_prior.json"
python3 "$ROOT/scripts/build-graph.py" --root "$DVREPO" > "$dv_prior" 2>/dev/null
echo x >> "$DVREPO/a.md"; git -C "$DVREPO" add -A; dvgc -m c1   # 1 commit past prior
echo y >> "$DVREPO/b.md"; git -C "$DVREPO" add -A; dvgc -m c2   # 2 commits past prior
if python3 -B - "$ROOT/scripts/build-graph.py" "$DVREPO" "$dv_prior" <<'PY' 2>/dev/null
import importlib.util, sys
spec = importlib.util.spec_from_file_location("bg", sys.argv[1])
bg = importlib.util.module_from_spec(spec); spec.loader.exec_module(bg)
bg.COUPLING_WINDOW_COMMITS = 1                    # 2 commits diverged > 1 => whole-graph
g = bg.build(sys.argv[2], sys.argv[3])
d = g["dirty"]
assert d["whole_graph"] is True, d
assert "diverged" in d["reason"], d["reason"]
assert d["is_first_run"] is False, d
assert set(d["nodes"]) == set(g["nodes"]), d      # every node re-audited
PY
then ok "whole-graph invalidation when HEAD diverges beyond the coupling window"; else bad "HEAD divergence beyond window did not force whole-graph re-audit"; fi

# --- Test 11k: lang_of shebang sniffing + resolve markdown anchor stripping --
# Two best-effort routing branches untested on planwright's own tree (all files
# have extensions and links carry no #anchor): extensionless files take their lang
# from a shebang, and link targets get their #anchor/?query stripped before resolve.
if python3 -B - "$ROOT/scripts/build-graph.py" <<'PY' 2>/dev/null
import importlib.util, sys
spec = importlib.util.spec_from_file_location("bg", sys.argv[1])
bg = importlib.util.module_from_spec(spec); spec.loader.exec_module(bg)
assert bg.lang_of("hook", b"#!/usr/bin/env bash\n") == "bash", "shebang bash"
assert bg.lang_of("gen", b"#!/usr/bin/env python3\nx=1\n") == "python", "shebang python"
assert bg.lang_of("notes", b"plain text\n") == "unknown", "no ext, no shebang"
fs = {"a.md", "b.md"}
assert bg.resolve("b.md#section", "a.md", fs) == "b.md", "anchor strip"
assert bg.resolve("b.md?v=1", "a.md", fs) == "b.md", "query strip"
# branch_count: the "branching" half of Stage 2b's complexity tiebreak
assert bg.branch_count_of("python", "if x:\n    pass\nfor i in y:\n    while z and w:\n        pass\n") == 4, "py branches"
assert bg.branch_count_of("bash", "if a; then b; fi\nfor i in 1; do :; done\n[ x ] && y || z\n") == 4, "bash branches"
assert bg.branch_count_of("markdown", "# title\nif this were code\n") == 0, "markup has no branches"
# branch_at attributes branching per symbol by def-span: a simple function gets 0,
# a branchy one carries its own branches (function-granular Stage 2b routing)
pyfns = ("def simple():\n    return 1\n"
         "def branchy():\n    if a:\n        for x in y:\n            while z and w:\n                pass\n")
assert bg.branch_at_of("python", pyfns) == {"simple": 0, "branchy": 4}, "py branch_at by span"
shfns = ("setup() {\n  echo hi\n}\n"
         "run() {\n  if a; then b; fi\n  for i in 1; do :; done\n  [ x ] && y || z\n}\n")
assert bg.branch_at_of("bash", shfns) == {"setup": 0, "run": 4}, "bash branch_at by span"
assert bg.branch_at_of("markdown", "# t\nif words\n") == {}, "markup has no symbols/branches"
PY
then ok "lang_of shebang detection and resolve anchor/query stripping work"; else bad "shebang lang detection or link anchor stripping broke"; fi

# --- Test 11l: bash source-by-basename resolution fallback (gated to bash) ---
# resolve(..., allow_basename=True) maps a bare `source common.sh` to a unique
# lib/common.sh; an ambiguous basename (two matches) stays unresolved, and the
# fallback is bash-only (markdown link targets must not gain spurious edges).
if python3 -B - "$ROOT/scripts/build-graph.py" <<'PY' 2>/dev/null
import importlib.util, sys
spec = importlib.util.spec_from_file_location("bg", sys.argv[1])
bg = importlib.util.module_from_spec(spec); spec.loader.exec_module(bg)
fs = {"scripts/main.sh", "lib/common.sh"}
# bash: bare-name source resolves to the unique basename match
assert bg.imports_of("bash", "source common.sh\n", "scripts/main.sh", fs) == ["lib/common.sh"], "bash bare-name source"
# ambiguity: two files share the basename => no resolution
fs2 = {"scripts/main.sh", "a/common.sh", "b/common.sh"}
assert bg.imports_of("bash", "source common.sh\n", "scripts/main.sh", fs2) == [], "ambiguous basename stays unresolved"
# gating: markdown must NOT use the basename fallback
assert bg.resolve("common.sh", "x.md", fs) is None, "non-bash gets no basename fallback"
assert bg.resolve("common.sh", "x.sh", fs, allow_basename=True) == "lib/common.sh", "explicit allow_basename"
PY
then ok "bash source-by-basename fallback resolves uniquely and stays bash-gated"; else bad "bash basename fallback wrong (ambiguity, gating, or resolution)"; fi

# --- Test 11n: python dotted/relative import resolution ---------------------
# Dotted module names are not paths, so the generic resolver dropped EVERY python
# import edge — leaving the import graph empty and PageRank routing blind on a
# primary target language. Resolve pkg.mod -> pkg/mod.py, package edges, relatives.
if python3 -B - "$ROOT/scripts/build-graph.py" <<'PY' 2>/dev/null
import importlib.util, sys
spec = importlib.util.spec_from_file_location("bg", sys.argv[1])
bg = importlib.util.module_from_spec(spec); spec.loader.exec_module(bg)
fs = {"main.py", "pkg/__init__.py", "pkg/mod.py", "pkg/sub/__init__.py", "pkg/sub/deep.py"}
imp = lambda src, frm: bg.imports_of("python", src, frm, fs)
assert imp("import pkg.mod\n", "main.py") == ["pkg/mod.py"], "absolute dotted module"
assert imp("from pkg.mod import x\n", "main.py") == ["pkg/mod.py"], "from dotted module"
assert imp("from pkg import mod\n", "main.py") == ["pkg/__init__.py"], "from-import resolves to package"
assert imp("from .mod import x\n", "pkg/a.py") == ["pkg/mod.py"], "single-dot relative"
assert imp("from .sub.deep import q\n", "pkg/a.py") == ["pkg/sub/deep.py"], "relative into subpackage"
assert imp("from ..mod import x\n", "pkg/sub/inner.py") == ["pkg/mod.py"], "two-dot relative goes up a package"
assert imp("import os\nimport sys\n", "main.py") == [], "stdlib imports drop (not in fileset)"
PY
then ok "python dotted + relative imports resolve to repo files"; else bad "python import resolution broke (dotted, relative, or stdlib drop)"; fi

# --- Test 11o: js extension/index + C include-root resolution ---------------
# JS specifiers omit the extension and use directory index files; C reaches a
# header through an -I include root, not a path relative to the source. Both
# dropped under the generic resolver. Resolve them (C via unique-basename fallback).
if python3 -B - "$ROOT/scripts/build-graph.py" <<'PY' 2>/dev/null
import importlib.util, sys
spec = importlib.util.spec_from_file_location("bg", sys.argv[1])
bg = importlib.util.module_from_spec(spec); spec.loader.exec_module(bg)
js = {"src/app.js", "src/util.js", "src/lib/index.js", "src/api.ts"}
ji = lambda src, frm: bg.imports_of("js", src, frm, js)
assert ji('import x from "./util"\n', "src/app.js") == ["src/util.js"], "js extension omitted"
assert ji('import {a} from "./lib"\n', "src/app.js") == ["src/lib/index.js"], "js directory index"
assert ji('import y from "./api"\n', "src/app.js") == ["src/api.ts"], "js .ts extension"
assert ji('import z from "./util.js"\n', "src/app.js") == ["src/util.js"], "js explicit extension still works"
assert ji('import React from "react"\n', "src/app.js") == [], "bare specifier (node_modules) drops"
c = {"src/main.c", "src/util.h", "include/common.h"}
ci = lambda src, frm: bg.imports_of("c", src, frm, c)
assert ci('#include "util.h"\n', "src/main.c") == ["src/util.h"], "C same-dir include"
assert ci('#include "common.h"\n', "src/main.c") == ["include/common.h"], "C include via basename fallback"
# ambiguous basename stays unresolved (avoid spurious edges)
c2 = {"src/main.c", "a/dup.h", "b/dup.h"}
assert bg.imports_of("c", '#include "dup.h"\n', "src/main.c", c2) == [], "ambiguous C basename drops"
PY
then ok "js extension/index and C include-root imports resolve"; else bad "js or C import resolution broke (extension, index, basename, or ambiguity)"; fi

# --- Test 11j: build-graph.py is deterministic (same tree => same graph) -----
# The builder's header calls it "deterministic" and incremental skipping trusts
# that identical inputs yield identical sha256/ranking. built_at (date -u) is the
# only field allowed to vary; everything else must be byte-stable across runs.
det1="$TMP/det1.json"; det2="$TMP/det2.json"
python3 "$ROOT/scripts/build-graph.py" --root "$ROOT" > "$det1" 2>/dev/null
python3 "$ROOT/scripts/build-graph.py" --root "$ROOT" > "$det2" 2>/dev/null
if python3 - "$det1" "$det2" <<'PY' 2>/dev/null
import json, sys
a = json.load(open(sys.argv[1])); b = json.load(open(sys.argv[2]))
a.pop("built_at", None); b.pop("built_at", None)
assert a == b, "build-graph.py output is not deterministic modulo built_at"
PY
then ok "build-graph.py is deterministic across runs (modulo built_at)"; else bad "build-graph.py output varies between runs on the same tree"; fi

# --- Test 11m: articulation_points on a cycle + connected-component clustering -
# Test 11h proved the positive (path) case; a CYCLE is the negative case that
# exercises the back-edge low-update branch and must yield zero cut vertices (a
# buggy lowlink over-flags here). Also assert a connected set shares one cluster.
CYREPO="$TMP/cyrepo"
mkdir -p "$CYREPO"
git -C "$CYREPO" init -q
cgc() { git -C "$CYREPO" -c user.name=t -c user.email=t@e.com commit -q "$@"; }
printf '# a\n[b](b.md)\n' > "$CYREPO/a.md"   # a->b->c->a forms a 3-cycle
printf '# b\n[c](c.md)\n' > "$CYREPO/b.md"
printf '# c\n[a](a.md)\n' > "$CYREPO/c.md"
printf '# d\n' > "$CYREPO/d.md"               # isolated singleton
git -C "$CYREPO" add -A; cgc -m init
cy_out="$TMP/cy_graph.json"
python3 "$ROOT/scripts/build-graph.py" --root "$CYREPO" > "$cy_out" 2>/dev/null
if python3 - "$cy_out" <<'PY' 2>/dev/null
import json, sys
g = json.load(open(sys.argv[1]))
n = g["nodes"]
assert all(n[f]["is_articulation"] is False for f in ("a.md", "b.md", "c.md")), "a cycle has no cut vertex"
cid = {m: c["id"] for c in g["clusters"] for m in c["members"]}
assert cid["a.md"] == cid["b.md"] == cid["c.md"], "the connected cycle must share one cluster"
assert cid["d.md"] != cid["a.md"], "the isolated file must be its own cluster"
PY
then ok "articulation_points yields no cut vertex on a cycle; component clusters together"; else bad "articulation over-flagged a cycle or clustering grouped wrong"; fi

# --- Test 11m2: cluster_label single-dir + multi-dir tiebreak ---------------
# cluster_label sets the routing label every digest cluster shows. A component
# confined to one directory is labeled by that lone dir; a component spanning
# >1 top-level dir is labeled by the MOST-COMMON top dir (the tiebreak that runs
# in production on this repo's README+docs component). Neither path was asserted.
CLREPO="$TMP/clrepo"
mkdir -p "$CLREPO/docs" "$CLREPO/src"
git -C "$CLREPO" init -q
clgc() { git -C "$CLREPO" -c user.name=t -c user.email=t@e.com commit -q "$@"; }
printf '# readme\n[a](docs/a.md)\n[b](docs/b.md)\n' > "$CLREPO/README.md"  # root + 2 docs => multi-dir
printf '# a\n' > "$CLREPO/docs/a.md"
printf '# b\n' > "$CLREPO/docs/b.md"
printf '# x\n[y](y.md)\n' > "$CLREPO/src/x.md"                              # single-dir component
printf '# y\n' > "$CLREPO/src/y.md"
git -C "$CLREPO" add -A; clgc -m init
cl_out="$TMP/cl_graph.json"
python3 "$ROOT/scripts/build-graph.py" --root "$CLREPO" > "$cl_out" 2>/dev/null
if python3 - "$cl_out" <<'PY' 2>/dev/null
import json, sys
g = json.load(open(sys.argv[1]))
lbl = {c["id"]: c["label"] for c in g["clusters"]}
cid = {m: c["id"] for c in g["clusters"] for m in c["members"]}
# multi-dir component (README at root + docs/a + docs/b) -> most-common top dir "docs"
assert lbl[cid["README.md"]] == "docs", (lbl, cid)
assert cid["README.md"] == cid["docs/a.md"] == cid["docs/b.md"], cid
# single-dir component (src/x + src/y) -> its lone directory "src"
assert lbl[cid["src/x.md"]] == "src", (lbl, cid)
assert cid["src/x.md"] == cid["src/y.md"], cid
PY
then ok "cluster_label labels a single-dir component by its dir and a multi-dir one by the most-common top dir"; else bad "cluster_label mislabeled a single-dir or multi-dir component"; fi

# --- Test 11m3: pagerank conserves mass and redistributes dangling-node rank --
# pagerank redistributes the rank of dangling (no-out-link) nodes across all
# nodes every build (build-graph.py lines 299-301). Most real nodes dangle, so a
# regression there would skew the central ranking signal silently. Pin both the
# mass-conservation invariant (scores sum to ~1.0) and that targeted nodes outrank
# an isolated dangling node.
if python3 -B - "$ROOT/scripts/build-graph.py" <<'PY' 2>/dev/null
import importlib.util, sys
spec = importlib.util.spec_from_file_location("bg", sys.argv[1])
bg = importlib.util.module_from_spec(spec); spec.loader.exec_module(bg)
nodes = ["a", "b", "c", "d"]
edges = {"a": ["b", "c"]}      # b, c, d all dangle; d is also isolated (no incoming)
pr = bg.pagerank(nodes, edges)
# the dangling-redistribution loop keeps total rank mass at 1.0
assert abs(sum(pr.values()) - 1.0) < 1e-6, sum(pr.values())
# nodes that receive an edge from a outrank the isolated node d
assert pr["b"] > pr["d"] and pr["c"] > pr["d"], pr
# an empty graph degrades gracefully to an empty ranking
assert bg.pagerank([], {}) == {}, "empty pagerank must be {}"
PY
then ok "pagerank conserves mass (sum~1.0) and redistributes dangling-node rank"; else bad "pagerank lost mass or mis-redistributed dangling rank"; fi

# --- Test 12: lint-plan.py enforces the Stage 10 structural gate -----------
# The OUTPUT FORMAT + Stage 10 + Hard rules were enforced only by Claude reading
# prose; lint-plan.py mechanizes their machine-checkable subset. A well-formed plan
# (real Surfaces, absent New Surface) passes; a malformed one fails per-violation.
GOOD_PLAN="$TMP/good_plan.md"
cat > "$GOOD_PLAN" <<'EOF'
# planwright Plan — .
<!-- Session: x -->

- [ ] A well-formed item
      Mode: improve
      Rationale: a real reason.
      Evidence: scripts/build-graph.py:1 does X.
      Surfaces: scripts/build-graph.py, tests/run.sh
      New Surfaces: scripts/brand_new_helper.py
      Development: edit build() at the node loop.
      Acceptance: the suite stays green.
      Verification: bash tests/run.sh
EOF
if python3 "$ROOT/scripts/lint-plan.py" --root "$ROOT" --plan "$GOOD_PLAN" --quiet; then ok "lint-plan.py passes a well-formed plan"; else bad "lint-plan.py rejected a well-formed plan"; fi

# Real items wrap fields (Surfaces/Development/Evidence) across physical lines; a
# linter that false-failed on that would be worse than none. Lock the join.
WRAP_PLAN="$TMP/wrap_plan.md"
cat > "$WRAP_PLAN" <<'EOF'
# planwright Plan — .

- [ ] Item with wrapped fields
      Mode: develop
      Rationale: a reason spanning
      more than one physical line.
      Evidence: scripts/build-graph.py:69 returns names;
      docs/graph-memory-schema.md:47 documents it.
      Surfaces: scripts/build-graph.py,
      tests/run.sh
      Development: add a helper near build-graph.py:69
      and wire it into build().
      Acceptance: suite green.
      Verification: bash tests/run.sh
EOF
if python3 "$ROOT/scripts/lint-plan.py" --root "$ROOT" --plan "$WRAP_PLAN" --quiet; then ok "lint-plan.py joins wrapped multi-line fields (no false failure)"; else bad "lint-plan.py false-failed on wrapped fields"; fi

BAD_PLAN="$TMP/bad_plan.md"
cat > "$BAD_PLAN" <<'EOF'
# planwright Plan — .

- [ ] Malformed item
      Mode: frobnicate
      Evidence: see .planwright/graph.json ranked list
      Surfaces: scripts/does_not_exist.py, src/CMakeLists
      New Surfaces: tests/run.sh
      Verification:
EOF
bp_rc=0
bp_out="$(python3 "$ROOT/scripts/lint-plan.py" --root "$ROOT" --plan "$BAD_PLAN" 2>&1)" || bp_rc=$?
if [ "$bp_rc" -ne 0 ]; then ok "lint-plan.py exits non-zero on a malformed plan"; else bad "lint-plan.py accepted a malformed plan"; fi
miss=""
for needle in "missing required field 'Rationale:'" "empty field 'Verification:'" "invalid Mode 'frobnicate'" "Evidence cites graph memory" "does not exist under root" "must be spelled CMakeLists.txt" "already exists"; do
  printf '%s' "$bp_out" | grep -qF "$needle" || miss="$miss [$needle]"
done
if [ -z "$miss" ]; then ok "lint-plan.py reports every Stage 10 violation class"; else bad "lint-plan.py missed violations:$miss"; fi

# --- Test 12b: repair Evidence needs a file:line anchor; .planwright/ is not a Surface
# Two Stage 10 rules lint-plan.py mechanizes: a `repair` item must cite the wrong
# call site as file:line (bare "X is absent" is insufficient for a confirmed defect),
# and no plan item may declare a tool-owned .planwright/ path as a Surface.
REPAIR_BAD="$TMP/repair_bad_plan.md"
cat > "$REPAIR_BAD" <<'EOF'
# planwright Plan — .

- [ ] Repair without a line anchor
      Mode: repair
      Rationale: something is wrong.
      Evidence: build-graph.py swallows the error and returns the wrong value.
      Surfaces: scripts/build-graph.py, .planwright/graph.json
      Development: fix the return.
      Acceptance: correct value returned.
      Verification: bash tests/run.sh
EOF
rb_rc=0
rb_out="$(python3 "$ROOT/scripts/lint-plan.py" --root "$ROOT" --plan "$REPAIR_BAD" 2>&1)" || rb_rc=$?
miss2=""
for needle in "repair Evidence lacks a file:line anchor" "tool-owned planwright state"; do
  printf '%s' "$rb_out" | grep -qF "$needle" || miss2="$miss2 [$needle]"
done
if [ "$rb_rc" -ne 0 ] && [ -z "$miss2" ]; then ok "lint-plan.py flags anchorless repair Evidence and a .planwright/ Surface"; else bad "lint-plan.py missed repair-anchor or tool-owned-Surface violation:$miss2"; fi

# A repair item WITH a file:line anchor and clean Surfaces must pass (improve/docs
# stay exempt from the anchor rule — see GOOD_PLAN above, mode improve, no anchor needed).
REPAIR_OK="$TMP/repair_ok_plan.md"
cat > "$REPAIR_OK" <<'EOF'
# planwright Plan — .

- [ ] Repair with a proper anchor
      Mode: repair
      Rationale: wrong value on the error path.
      Evidence: scripts/build-graph.py:116 returns the keyword instead of skipping it.
      Surfaces: scripts/build-graph.py
      Development: filter the keyword at that line.
      Acceptance: keyword no longer treated as a definition.
      Verification: bash tests/run.sh
EOF
if python3 "$ROOT/scripts/lint-plan.py" --root "$ROOT" --plan "$REPAIR_OK" --quiet; then ok "lint-plan.py passes a repair item with a file:line anchor"; else bad "lint-plan.py false-failed a well-anchored repair item"; fi
# A pending item with all eight fields and no path issues must pass; the same item
# completed (- [x]) is skipped by default and only checked under --all.
DONE_PLAN="$TMP/done_plan.md"
sed 's/- \[ \]/- [x]/' "$BAD_PLAN" > "$DONE_PLAN"
if python3 "$ROOT/scripts/lint-plan.py" --root "$ROOT" --plan "$DONE_PLAN" --quiet; then ok "lint-plan.py skips completed items by default"; else bad "lint-plan.py linted a completed item without --all"; fi
if python3 "$ROOT/scripts/lint-plan.py" --root "$ROOT" --plan "$DONE_PLAN" --all --quiet; then bad "lint-plan.py --all ignored a completed item"; else ok "lint-plan.py --all also lints completed items"; fi
# An absent plan file is not an error (nothing to lint).
if python3 "$ROOT/scripts/lint-plan.py" --root "$ROOT" --plan "$TMP/nope.md" --quiet; then ok "lint-plan.py treats an absent plan as clean"; else bad "lint-plan.py errored on an absent plan file"; fi

# --- Test 12c: lint-plan.py rejects a placeholder Verification value ---------
# Verification must be a runnable command; a bare "TODO"/"manual"/"n/a" passes the
# non-empty check but is unverifiable, so lint-plan flags it before execute wastes a
# cycle. A real command that merely contains such a word must NOT be flagged.
PH_PLAN="$TMP/placeholder_plan.md"
cat > "$PH_PLAN" <<'EOF'
# planwright Plan — .

- [ ] Item with a placeholder verification
      Mode: improve
      Rationale: r.
      Evidence: scripts/lint-plan.py exists.
      Surfaces: scripts/lint-plan.py
      Development: edit lint_item().
      Acceptance: green.
      Verification: TODO
EOF
ph_rc=0
ph_out="$(python3 "$ROOT/scripts/lint-plan.py" --root "$ROOT" --plan "$PH_PLAN" 2>&1)" || ph_rc=$?
if [ "$ph_rc" -ne 0 ] && printf '%s' "$ph_out" | grep -qF "is a placeholder"; then ok "lint-plan.py rejects a placeholder Verification (TODO)"; else bad "lint-plan.py accepted a placeholder Verification"; fi
PH_OK="$TMP/placeholder_ok_plan.md"
cat > "$PH_OK" <<'EOF'
# planwright Plan — .

- [ ] Item with a real verification that mentions manual
      Mode: improve
      Rationale: r.
      Evidence: scripts/lint-plan.py exists.
      Surfaces: scripts/lint-plan.py
      Development: edit lint_item().
      Acceptance: green.
      Verification: manual smoke test then bash tests/run.sh
EOF
if python3 "$ROOT/scripts/lint-plan.py" --root "$ROOT" --plan "$PH_OK" --quiet; then ok "lint-plan.py allows a real command that contains a placeholder word"; else bad "lint-plan.py false-flagged a real Verification command"; fi

# --- Test 12d: an all-dots "..." Verification is a placeholder, not a command ----
# rstrip(".") collapses "..." to "", so a naive `norm in PLACEHOLDER_VERIFICATION`
# test silently passed the documented "..." placeholder; an empty normalization must
# also count as a placeholder.
PH_DOTS="$TMP/placeholder_dots_plan.md"
cat > "$PH_DOTS" <<'EOF'
# planwright Plan — .

- [ ] Item with an ellipsis verification
      Mode: improve
      Rationale: r.
      Evidence: scripts/lint-plan.py exists.
      Surfaces: scripts/lint-plan.py
      Development: edit lint_item().
      Acceptance: green.
      Verification: ...
EOF
pd_rc=0
pd_out="$(python3 "$ROOT/scripts/lint-plan.py" --root "$ROOT" --plan "$PH_DOTS" 2>&1)" || pd_rc=$?
if [ "$pd_rc" -ne 0 ] && printf '%s' "$pd_out" | grep -qF "is a placeholder"; then ok "lint-plan.py rejects an all-dots '...' Verification placeholder"; else bad "lint-plan.py accepted an all-dots '...' Verification"; fi

# Convergence guards: a repeated pending title and a Surfaces/New-Surfaces overlap
# are always violations (hard fail). The lifecycle dir holds the advisory sources.
LDIR="$TMP/lintdir"
mkdir -p "$LDIR"
printf '# completed\n\n- [x] A finished thing\n' > "$LDIR/completed.md"
printf '# rejected\n\n- [x] A doomed thing\n      Rejection: nope\n' > "$LDIR/rejected.md"
cat > "$LDIR/plan.md" <<EOF
# planwright Plan — .

- [ ] A finished thing
      Mode: improve
      Rationale: r.
      Evidence: $ROOT/scripts/lint-plan.py exists.
      Surfaces: scripts/lint-plan.py
      New Surfaces: scripts/lint-plan.py
      Development: edit main().
      Acceptance: green.
      Verification: bash tests/run.sh

- [ ] A finished thing
      Mode: improve
      Rationale: r.
      Evidence: build-graph exists.
      Surfaces: scripts/build-graph.py
      Development: edit build().
      Acceptance: green.
      Verification: bash tests/run.sh

- [ ] A doomed thing
      Mode: improve
      Rationale: r.
      Evidence: tests exist.
      Surfaces: tests/run.sh
      Development: edit it.
      Acceptance: green.
      Verification: bash tests/run.sh
EOF
ld_rc=0
ld_out="$(python3 "$ROOT/scripts/lint-plan.py" --root "$ROOT" --plan "$LDIR/plan.md" 2>&1)" || ld_rc=$?
if [ "$ld_rc" -ne 0 ]; then ok "lint-plan.py fails on convergence violations"; else bad "lint-plan.py passed a plan with dup title + Surfaces overlap"; fi
if printf '%s' "$ld_out" | grep -qF "duplicate pending title: 'A finished thing'"; then ok "lint-plan.py flags a duplicate pending title"; else bad "lint-plan.py missed a duplicate pending title"; fi
if printf '%s' "$ld_out" | grep -qF "both Surfaces and New Surfaces"; then ok "lint-plan.py flags a Surfaces/New-Surfaces overlap"; else bad "lint-plan.py missed a Surfaces/New-Surfaces overlap"; fi
if printf '%s' "$ld_out" | grep -qF "matches a completed item"; then ok "lint-plan.py notes a re-proposed completed item (advisory)"; else bad "lint-plan.py missed the completed-item advisory"; fi
if printf '%s' "$ld_out" | grep -qF "matches a rejected item"; then ok "lint-plan.py notes a re-proposed rejected item (advisory)"; else bad "lint-plan.py missed the rejected-item advisory"; fi
# Advisory matches alone (no structural violation) must NOT fail the gate.
ADV="$TMP/advdir"
mkdir -p "$ADV"
printf '# completed\n\n- [x] Legit regression refix\n' > "$ADV/completed.md"
cat > "$ADV/plan.md" <<'EOF'
# planwright Plan — .

- [ ] Legit regression refix
      Mode: repair
      Rationale: a regression returned.
      Evidence: scripts/build-graph.py:1 now returns the wrong value.
      Surfaces: scripts/build-graph.py
      Development: fix build().
      Acceptance: green.
      Verification: bash tests/run.sh
EOF
adv_rc=0
adv_out="$(python3 "$ROOT/scripts/lint-plan.py" --root "$ROOT" --plan "$ADV/plan.md" 2>&1)" || adv_rc=$?
if [ "$adv_rc" -eq 0 ] && printf '%s' "$adv_out" | grep -qF "matches a completed item"; then ok "lint-plan.py advisory note alone does not fail the gate"; else bad "lint-plan.py advisory wrongly failed the gate (or note missing)"; fi

# --- Test 13: commands/codvisor.md is a well-formed planwright helper command ---
# /codvisor is a thin alias that forwards to the planwright skill; guard its delegation
# contract so an edit can't silently drop the planwright reference or the no-arg default.
CMD="$ROOT/commands/codvisor.md"
if [ -f "$CMD" ]; then ok "commands/codvisor.md exists"; else bad "commands/codvisor.md missing"; fi
if python3 - "$CMD" <<'PY' 2>/dev/null
import re, sys
t = open(sys.argv[1], encoding="utf-8").read()
m = re.match(r"^---\n(.*?)\n---\n", t, re.S)
assert m, "no YAML frontmatter"
fm = m.group(1)
assert re.search(r"(?m)^description:\s*\S", fm), "missing description"
assert re.search(r"(?m)^argument-hint:\s*\S", fm), "missing argument-hint"
body = t[m.end():]
# the command must delegate to the planwright skill, not reimplement it
assert "planwright:planwright" in body, "body does not invoke the planwright skill"
# the no-arg flagship default must stay the advisor sweep
assert "cycle 10 depth 10 explore" in body, "no-arg advisor default not preserved"
PY
then ok "commands/codvisor.md has valid frontmatter and forwards to planwright (advisor default intact)"; else bad "commands/codvisor.md malformed or lost its planwright delegation/advisor default"; fi

echo
echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ]
