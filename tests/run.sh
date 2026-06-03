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

# --- Test 0b: build-graph.py passes static analysis ------------------------
# The canonical Stage 1.5 builder is the only non-shell script; gate it too.
# ast.parse checks syntax without writing __pycache__ into the real tree.
if python3 -c "import ast,sys;ast.parse(open(sys.argv[1]).read())" "$ROOT/scripts/build-graph.py" 2>/dev/null; then ok "build-graph.py parses (no syntax error)"; else bad "build-graph.py has a syntax error"; fi
if command -v pyflakes >/dev/null 2>&1; then
  if pyflakes "$ROOT/scripts/build-graph.py" >/dev/null 2>&1; then ok "build-graph.py passes pyflakes"; else bad "build-graph.py fails pyflakes"; fi
else
  ok "build-graph.py pyflakes skipped (pyflakes not installed)"
fi

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
need = {"sha256", "loc", "lang", "git_churn", "defines", "defines_at", "imports", "pagerank", "is_articulation", "last_audited_sha"}
for f, n in g["nodes"].items():
    assert need <= set(n), f
    assert isinstance(n["defines_at"], dict), f
    assert all(isinstance(v, int) and v >= 1 for v in n["defines_at"].values()), f
assert isinstance(g["ranked"], list) and all(x in g["nodes"] for x in g["ranked"])
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

echo
echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ]
