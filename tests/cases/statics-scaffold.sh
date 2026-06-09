# SPDX-FileCopyrightText: 2026 Eser KUBALI
# SPDX-License-Identifier: GPL-3.0-or-later
# shellcheck shell=bash
#
# Static analysis + bump-version.sh / make-plugin.sh scaffolding.
# Sourced by tests/run.sh after tests/lib.sh — NOT standalone (uses ROOT/TMP/ok/bad/ver).

# --- Test 0: shellcheck the repo's shell scripts ---------------------------
# Gate exactly the set ci.yml lints (scripts/*.sh tests/*.sh tests/cases/*.sh), so a lint
# regression in any of them fails `bash tests/run.sh` locally instead of only in CI. The
# tests/cases/*.sh fragments reference the harness's ROOT/TMP/ok/bad yet lint cleanly on
# their own (each carries a shell=bash directive), which is why CI already checks them.
if command -v shellcheck >/dev/null 2>&1; then
  if shellcheck "$ROOT"/scripts/*.sh "$ROOT"/tests/*.sh "$ROOT"/tests/cases/*.sh >/dev/null 2>&1; then ok "all repo shell scripts pass shellcheck (CI parity)"; else bad "repo shell scripts fail shellcheck"; fi
else
  ok "shellcheck skipped (shellcheck not installed)"
fi

# --- Test 0b: the Python scripts pass static analysis ----------------------
# Gate every scripts/*.py, matching ci.yml's `pyflakes scripts/*.py`. ast.parse checks
# syntax per file without writing __pycache__ into the real tree; pyflakes runs once over
# the whole glob (skip-if-absent).
for py in "$ROOT"/scripts/*.py; do
  if python3 -c "import ast,sys;ast.parse(open(sys.argv[1]).read())" "$py" 2>/dev/null; then ok "$(basename "$py") parses (no syntax error)"; else bad "$(basename "$py") has a syntax error"; fi
done
if command -v pyflakes >/dev/null 2>&1; then
  if pyflakes "$ROOT"/scripts/*.py >/dev/null 2>&1; then ok "scripts/*.py pass pyflakes (CI parity)"; else bad "scripts/*.py fail pyflakes"; fi
else
  ok "scripts/*.py pyflakes skipped (pyflakes not installed)"
fi

# --- Test 0c: the dashboard's JS assets are syntactically valid ------------
# The dashboard ships vanilla JS with no build step; dashboard.sh only checks each file
# is served and registers its view, never that it parses. node --check gives the whole
# JS layer a syntax gate, gated on node and skipped cleanly when absent (CI installs no
# JS runtime), matching the skip-if-absent gates above.
if command -v node >/dev/null 2>&1; then
  js_bad=""
  for js in "$ROOT"/scripts/dashboard/*.js "$ROOT"/scripts/dashboard/views/*.js "$ROOT"/scripts/dashboard/vendor/*.js; do
    [ -e "$js" ] || continue
    node --check "$js" 2>/dev/null || js_bad="$js_bad ${js#"$ROOT"/}"
  done
  if [ -z "$js_bad" ]; then ok "dashboard JS assets are syntactically valid (node --check)"; else bad "dashboard JS syntax errors:$js_bad"; fi
else
  ok "dashboard JS syntax check skipped (node not installed)"
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
cj="$(ver "$WORK/.codex-plugin/plugin.json" "['version']")"

if printf '%s' "$bs_out" | grep -q "Bumped:"; then ok "bump-version prints Bumped: summary on success"; else bad "bump-version missing Bumped: summary on success"; fi
if printf '%s' "$bs_out" | grep -q "updated skills/"; then ok "bump-version reports updated skill files on success"; else bad "bump-version missing skill file update report"; fi
if [ "$pj" != "$before" ]; then ok "bump-version changed version ($before -> $pj)"; else bad "version unchanged"; fi
if [ "$pj" = "$mm" ] && [ "$pj" = "$me" ] && [ "$pj" = "$cj" ]; then ok "manifests in lockstep ($pj)"; else bad "out of sync: plugin=$pj meta=$mm entry=$me codex=$cj"; fi
if grep -q "## \[$pj\]" "$WORK/CHANGELOG.md"; then ok "changelog gained [$pj] section"; else bad "changelog missing [$pj]"; fi
if grep -q "### Changed" "$WORK/CHANGELOG.md"; then ok "changelog entry has ### Changed section"; else bad "changelog entry missing ### Changed section"; fi
if grep -q "smoke-test bump" "$WORK/CHANGELOG.md"; then ok "changelog -m note appears in entry"; else bad "changelog -m note missing from entry"; fi
sv="$(grep -m1 '  version:' "$WORK/skills/planwright/SKILL.md" | sed -E 's/.*"([^"]+)".*/\1/')"
if [ "$sv" = "$pj" ]; then ok "skill frontmatter in lockstep ($sv)"; else bad "skill version drift: skill=$sv manifest=$pj"; fi

# --- Test 1b: --dry-run agrees with the real run on an unquoted skill version ----------
# The preview must predict the real run. The real rewrite only touches a QUOTED metadata
# version, so an unquoted (YAML-legal) `  version: X` is skipped — and --dry-run must report
# it skipped too, not falsely "would sync" (regression: a looser dry-run probe regex).
sed -i -E '0,/^  version:/ s/^(  version:)[[:space:]]*"[^"]*"/\1 9.9.9/' "$WORK/skills/planwright/SKILL.md"
dry_out="$("$WORK/scripts/bump-version.sh" patch --dry-run 2>&1 || true)"
dry_rc=0; "$WORK/scripts/bump-version.sh" patch --dry-run >/dev/null 2>&1 || dry_rc=$?
real_out="$("$WORK/scripts/bump-version.sh" patch 2>&1 || true)"
if printf '%s' "$dry_out" | grep -q 'skipped' \
   && ! printf '%s' "$dry_out" | grep -q 'would sync skills/planwright/SKILL.md' \
   && [ "$dry_rc" = 0 ] \
   && printf '%s' "$real_out" | grep -q 'skipped'; then
  ok "bump-version --dry-run agrees with the real run on an unquoted skill version (both skip, dry-run exit 0)"
else
  bad "bump-version --dry-run disagrees with the real run on an unquoted version (dry_rc=$dry_rc dry=[$dry_out])"
fi

# --- Test 2: make-plugin.sh scaffolds a valid plugin ----------------------
GEN="$TMP/gen"
NO_GIT=1 PLUGIN_DESC="Smoke test plugin." "$ROOT/scripts/make-plugin.sh" demo "$GEN" >/dev/null
if python3 -c "import json;json.load(open('$GEN/.claude-plugin/plugin.json'))" 2>/dev/null; then ok "generated plugin.json parses"; else bad "generated plugin.json invalid"; fi
if python3 -c "import json,sys;d=json.load(open('$GEN/.claude-plugin/plugin.json'));sys.exit(0 if d.get('license')=='GPL-3.0-or-later' else 1)" 2>/dev/null; then ok "generated plugin.json license is GPL-3.0-or-later"; else bad "generated plugin.json license wrong or missing"; fi
if python3 -c "import json;json.load(open('$GEN/.claude-plugin/marketplace.json'))" 2>/dev/null; then ok "generated marketplace.json parses"; else bad "generated marketplace.json invalid"; fi
if python3 -c "import json,sys;m=json.load(open('$GEN/.claude-plugin/marketplace.json'));sys.exit(0 if m['plugins'][0].get('license')=='GPL-3.0-or-later' else 1)" 2>/dev/null; then ok "generated marketplace.json plugins license is GPL-3.0-or-later"; else bad "generated marketplace.json plugins license wrong or missing"; fi
if python3 -c "import json,sys;m=json.load(open('$GEN/.claude-plugin/marketplace.json'));sys.exit(0 if m['metadata']['version']==m['plugins'][0]['version'] else 1)" 2>/dev/null; then ok "generated marketplace.json metadata.version matches plugins entry version"; else bad "generated marketplace.json version fields out of sync"; fi
if python3 -c "import json;json.load(open('$GEN/.codex-plugin/plugin.json'))" 2>/dev/null; then ok "generated codex plugin.json parses"; else bad "generated codex plugin.json invalid"; fi
if python3 -c "import json,sys;d=json.load(open('$GEN/.codex-plugin/plugin.json'));sys.exit(0 if d.get('license')=='GPL-3.0-or-later' and d.get('skills')=='./skills/' else 1)" 2>/dev/null; then ok "generated codex plugin.json has license and skills path"; else bad "generated codex plugin.json license/skills wrong or missing"; fi
if python3 -c "import json,sys;d=json.load(open('$GEN/.claude-plugin/plugin.json'));sys.exit(0 if 'Smoke test plugin.' in str(d) else 1)" 2>/dev/null; then ok "PLUGIN_DESC appears in generated plugin.json"; else bad "PLUGIN_DESC missing from generated plugin.json"; fi
if python3 -c "import json,sys;m=json.load(open('$GEN/.claude-plugin/marketplace.json'));sys.exit(0 if any('Smoke test plugin.' in str(p.get('description','')) for p in m.get('plugins',[])) else 1)" 2>/dev/null; then ok "PLUGIN_DESC appears in generated marketplace.json plugin entry"; else bad "PLUGIN_DESC missing from generated marketplace.json plugin entry"; fi
if python3 -c "import json,sys;d=json.load(open('$GEN/.codex-plugin/plugin.json'));sys.exit(0 if 'Smoke test plugin.' in str(d) else 1)" 2>/dev/null; then ok "PLUGIN_DESC appears in generated codex plugin.json"; else bad "PLUGIN_DESC missing from generated codex plugin.json"; fi
if python3 -c "import json,sys;d=json.load(open('$GEN/.claude-plugin/plugin.json'));sys.exit(0 if d.get('name')=='demo' else 1)" 2>/dev/null; then ok "generated plugin.json name matches plugin name"; else bad "generated plugin.json name wrong or missing"; fi
if python3 -c "import json,sys;m=json.load(open('$GEN/.claude-plugin/marketplace.json'));sys.exit(0 if m.get('name')=='demo' else 1)" 2>/dev/null; then ok "generated marketplace.json name matches plugin name"; else bad "generated marketplace.json name wrong or missing"; fi
if python3 -c "import json,sys;m=json.load(open('$GEN/.claude-plugin/marketplace.json'));sys.exit(0 if m['plugins'][0].get('name')=='demo' else 1)" 2>/dev/null; then ok "generated marketplace.json plugins[0].name matches plugin name"; else bad "generated marketplace.json plugins[0].name wrong or missing"; fi
if python3 -c "import json,sys;m=json.load(open('$GEN/.claude-plugin/marketplace.json'));sys.exit(0 if m['plugins'][0].get('source')=='./' else 1)" 2>/dev/null; then ok "generated marketplace.json plugins[0].source is ./"; else bad "generated marketplace.json plugins[0].source wrong or missing"; fi
if python3 -c "import json,sys;d=json.load(open('$GEN/.codex-plugin/plugin.json'));sys.exit(0 if d.get('name')=='demo' and d.get('version')=='0.1.0' else 1)" 2>/dev/null; then ok "generated codex plugin.json name/version match plugin"; else bad "generated codex plugin.json name/version wrong or missing"; fi
if [ -f "$GEN/skills/demo/SKILL.md" ]; then ok "generated skills/demo/SKILL.md exists"; else bad "generated SKILL.md missing"; fi
if grep -q "Smoke test plugin." "$GEN/skills/demo/SKILL.md" 2>/dev/null; then ok "PLUGIN_DESC appears in generated SKILL.md description"; else bad "PLUGIN_DESC missing from generated SKILL.md description"; fi
if grep -q "^name: demo$" "$GEN/skills/demo/SKILL.md" 2>/dev/null; then ok "generated SKILL.md name field matches plugin name"; else bad "generated SKILL.md name field wrong or missing"; fi
if grep -q '^  version: "0.1.0"$' "$GEN/skills/demo/SKILL.md" 2>/dev/null; then ok "generated SKILL.md has metadata version field"; else bad "generated SKILL.md missing or malformed metadata version field"; fi
if [ -f "$GEN/LICENSE" ]; then ok "generated LICENSE exists"; else bad "generated LICENSE missing"; fi
if [ -f "$GEN/.github/workflows/ci.yml" ]; then ok "generated ci.yml exists"; else bad "generated ci.yml missing"; fi
if grep -q "shellcheck" "$GEN/.github/workflows/ci.yml" 2>/dev/null; then ok "generated ci.yml includes shellcheck step"; else bad "generated ci.yml missing shellcheck step"; fi
if grep -q "bash tests/run.sh" "$GEN/.github/workflows/ci.yml" 2>/dev/null; then ok "generated ci.yml includes smoke-test step"; else bad "generated ci.yml missing smoke-test step"; fi
if [ -f "$GEN/.gitignore" ]; then ok "generated .gitignore exists"; else bad "generated .gitignore missing"; fi
# A generated plugin must ignore .planwright/ so its tool state is never committed as
# noise (else doctor immediately warns on the fresh plugin).
if grep -qx '.planwright/' "$GEN/.gitignore"; then ok "generated .gitignore ignores .planwright/"; else bad "generated .gitignore omits .planwright/ (doctor would warn)"; fi
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
# The arg-count guard fires before any mkdir, so no fixture cleanup is needed.
if NO_GIT=1 "$ROOT/scripts/make-plugin.sh" a b c >/dev/null 2>&1; then bad "make-plugin accepted too many positional arguments"; else ok "make-plugin rejects too many positional arguments"; fi
mp_too_err="$(NO_GIT=1 "$ROOT/scripts/make-plugin.sh" a b c 2>&1 >/dev/null)" || true
if printf '%s' "$mp_too_err" | grep -q "Too many positional"; then ok "make-plugin too-many-args prints 'Too many positional' diagnostic"; else bad "make-plugin too-many-args missing diagnostic"; fi

# --- Test 2c2: make-plugin.sh honors the `--` end-of-options sentinel ------
# Post-`--` tokens must be consumed as the NAME/DEST positionals; breaking the `--` branch
# (not collecting trailing tokens) leaves NAME empty and the scaffold never happens.
GEN_DD="$TMP/gen_dd"
NO_GIT=1 "$ROOT/scripts/make-plugin.sh" -- demo "$GEN_DD" >/dev/null 2>&1 || true
if [ -f "$GEN_DD/.claude-plugin/plugin.json" ]; then ok "make-plugin honors -- end-of-options sentinel (scaffolds from trailing positionals)"; else bad "make-plugin -- sentinel did not scaffold from trailing positionals"; fi

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
if python3 -c "import json;json.load(open('$GEN_ESC/.codex-plugin/plugin.json'))" 2>/dev/null; then ok "codex plugin.json stays valid JSON when author/desc have quotes"; else bad "codex plugin.json invalid when author/desc have quotes"; fi
if EXP="$ESC_DESC" python3 -c "import json,os,sys;d=json.load(open('$GEN_ESC/.claude-plugin/plugin.json'));sys.exit(0 if d['description']==os.environ['EXP'] else 1)" 2>/dev/null; then ok "plugin.json description round-trips special chars intact"; else bad "plugin.json description garbled special chars"; fi
if EXP="$ESC_AUTH" python3 -c "import json,os,sys;m=json.load(open('$GEN_ESC/.claude-plugin/marketplace.json'));sys.exit(0 if m['owner']['name']==os.environ['EXP'] else 1)" 2>/dev/null; then ok "marketplace.json owner.name round-trips special chars intact"; else bad "marketplace.json owner.name garbled special chars"; fi
if EXP="$ESC_DESC" python3 -c "import json,os,sys;d=json.load(open('$GEN_ESC/.codex-plugin/plugin.json'));sys.exit(0 if d['description']==os.environ['EXP'] else 1)" 2>/dev/null; then ok "codex plugin.json description round-trips special chars intact"; else bad "codex plugin.json description garbled special chars"; fi
if EXP="$ESC_AUTH" python3 -c "import json,os,sys;d=json.load(open('$GEN_ESC/.codex-plugin/plugin.json'));sys.exit(0 if d['author']['name']==os.environ['EXP'] else 1)" 2>/dev/null; then ok "codex plugin.json author.name round-trips special chars intact"; else bad "codex plugin.json author.name garbled special chars"; fi

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
if "$ROOT/scripts/make-plugin.sh" --help 2>/dev/null | grep -q -- '--no-gpg-sign'; then ok "make-plugin --help mentions --no-gpg-sign"; else bad "make-plugin --help missing --no-gpg-sign"; fi

# --- Test 2f: make-plugin.sh git init path creates an initial commit -------
GEN_GIT="$TMP/gen_git"
if AUTHOR_NAME="Test Author" AUTHOR_EMAIL="test@test.com" "$ROOT/scripts/make-plugin.sh" --no-gpg-sign demo "$GEN_GIT" >/dev/null 2>&1; then
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
# The script's FOCUS invariant: it edits version files but must NOT tag, commit, or publish.
# Snapshot the commit count before bumping; ALLOW_DIRTY=1 lets the bump run on this work tree.
g_commits_before="$(git -C "$GREPO" rev-list --count HEAD)"
if ALLOW_DIRTY=1 "$GREPO/scripts/bump-version.sh" patch -m x >/dev/null 2>&1; then ok "ALLOW_DIRTY=1 bypasses dirty-tree guard"; else bad "ALLOW_DIRTY=1 did not bypass dirty-tree guard"; fi
if [ -z "$(git -C "$GREPO" tag)" ]; then ok "bump-version creates no git tag (no-tag/publish contract)"; else bad "bump-version created a git tag"; fi
g_commits_after="$(git -C "$GREPO" rev-list --count HEAD)"
if [ "$g_commits_before" = "$g_commits_after" ]; then ok "bump-version creates no new commit ($g_commits_after unchanged)"; else bad "bump-version created a commit ($g_commits_before -> $g_commits_after)"; fi

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

# --- Test 5b: a relative bump from a pinned pre-release increments the core --------
# Regression: after pinning a SemVer pre-release/build (e.g. 2.6.0-rc.1+build.5) a later
# relative bump parsed cur.split('.') as three ints and crashed ("not X.Y.Z"); the bump
# must instead operate on the release core and yield a clean X.Y.Z.
PRE="$TMP/prerelease"
mkdir -p "$PRE"
( cd "$ROOT" && tar --exclude=.git --exclude=.planwright -cf - . ) | ( cd "$PRE" && tar -xf - )
"$PRE/scripts/bump-version.sh" 2.6.0-rc.1+build.5 >/dev/null 2>&1
pre_set="$(python3 -c "import json;print(json.load(open('$PRE/.claude-plugin/plugin.json'))['version'])")"
pre_rc=0; pre_out="$("$PRE/scripts/bump-version.sh" patch -m "post-prerelease bump" 2>&1)" || pre_rc=$?
pre_new="$(python3 -c "import json;print(json.load(open('$PRE/.claude-plugin/plugin.json'))['version'])")"
if [ "$pre_set" = "2.6.0-rc.1+build.5" ] && [ "$pre_rc" -eq 0 ] && [ "$pre_new" = "2.6.1" ]; then
  ok "bump-version relative-bumps from a pinned pre-release ($pre_set -> $pre_new)"
else
  bad "bump-version failed to bump from a pinned pre-release (set=$pre_set rc=$pre_rc new=$pre_new out=$pre_out)"
fi

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

# --- Test 7b2: explicit pin accepts a SemVer pre-release / build suffix -----
# bump-version.sh's version-arg regex accepts an optional -pre and +build suffix
# (commit 9b2c20c) so a pre-release can be cut; pin one and assert it round-trips
# verbatim into the manifests (a regression narrowing the regex would drop it).
PRERR="$TMP/prerr"
mkdir -p "$PRERR"
( cd "$ROOT" && tar --exclude=.git --exclude=.planwright -cf - . ) | ( cd "$PRERR" && tar -xf - )
"$PRERR/scripts/bump-version.sh" 2.6.0-rc.1+build.5 >/dev/null
prepj="$(python3 -c "import json;print(json.load(open('$PRERR/.claude-plugin/plugin.json'))['version'])")"
if [ "$prepj" = "2.6.0-rc.1+build.5" ]; then ok "explicit pin accepts a pre-release/build suffix (round-trips verbatim)"; else bad "pre-release pin failed: got $prepj"; fi
premm="$(python3 -c "import json;print(json.load(open('$PRERR/.claude-plugin/marketplace.json'))['metadata']['version'])")"
if [ "$prepj" = "$premm" ]; then ok "pre-release pin synced across manifests"; else bad "pre-release pin not synced: plugin=$prepj market=$premm"; fi

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
dr_codex_before="$(python3 -c "import json;print(json.load(open('$DRYR/.codex-plugin/plugin.json'))['version'])")"
dr_cl_before="$(wc -l < "$DRYR/CHANGELOG.md")"
dr_out="$("$DRYR/scripts/bump-version.sh" patch --dry-run 2>/dev/null)"
dr_after="$(python3 -c "import json;print(json.load(open('$DRYR/.claude-plugin/plugin.json'))['version'])")"
dr_market_after="$(python3 -c "import json;print(json.load(open('$DRYR/.claude-plugin/marketplace.json'))['metadata']['version'])")"
dr_codex_after="$(python3 -c "import json;print(json.load(open('$DRYR/.codex-plugin/plugin.json'))['version'])")"
dr_cl_after="$(wc -l < "$DRYR/CHANGELOG.md")"
if [ "$dr_before" = "$dr_after" ]; then ok "--dry-run did not modify plugin.json"; else bad "--dry-run modified plugin.json ($dr_before -> $dr_after)"; fi
if [ "$dr_market_before" = "$dr_market_after" ]; then ok "--dry-run did not modify marketplace.json"; else bad "--dry-run modified marketplace.json ($dr_market_before -> $dr_market_after)"; fi
if [ "$dr_codex_before" = "$dr_codex_after" ]; then ok "--dry-run did not modify codex plugin.json"; else bad "--dry-run modified codex plugin.json ($dr_codex_before -> $dr_codex_after)"; fi
if [ "$dr_cl_before" = "$dr_cl_after" ]; then ok "--dry-run did not modify CHANGELOG.md"; else bad "--dry-run modified CHANGELOG.md (lines: $dr_cl_before -> $dr_cl_after)"; fi
if printf '%s' "$dr_out" | grep -q "dry-run:"; then ok "--dry-run output shows version info"; else bad "--dry-run output missing version info"; fi
if printf '%s' "$dr_out" | grep -q "would sync"; then ok "--dry-run shows which skills would be synced"; else bad "--dry-run missing skill sync preview"; fi
dr_note_out="$("$DRYR/scripts/bump-version.sh" patch --dry-run -m "dry note" 2>/dev/null)"
if printf '%s' "$dr_note_out" | grep -q "dry note"; then ok "--dry-run -m flag shows note in CHANGELOG preview"; else bad "--dry-run -m flag: note missing from CHANGELOG preview"; fi

# --- Test 9: the repo's own version sources agree at rest ------------------
rv="$(ver "$ROOT/.claude-plugin/plugin.json" "['version']")"
rmeta="$(ver "$ROOT/.claude-plugin/marketplace.json" "['metadata']['version']")"
rentry="$(ver "$ROOT/.claude-plugin/marketplace.json" "['plugins'][0]['version']")"
rcodex="$(ver "$ROOT/.codex-plugin/plugin.json" "['version']")"
rskill="$(grep -m1 '  version:' "$ROOT/skills/planwright/SKILL.md" | sed -E 's/.*"([^"]+)".*/\1/')"
if [ "$rv" = "$rmeta" ] && [ "$rv" = "$rentry" ] && [ "$rv" = "$rcodex" ] && [ "$rv" = "$rskill" ]; then ok "repo version sources agree at rest ($rv)"; else bad "repo version drift: plugin=$rv meta=$rmeta entry=$rentry codex=$rcodex skill=$rskill"; fi
if grep -q "## \[$rv\]" "$ROOT/CHANGELOG.md"; then ok "CHANGELOG.md has a section for the current version [$rv]"; else bad "CHANGELOG.md missing a section for the current version [$rv]"; fi



# --- Test 1d: bump-version aborts BEFORE any write on a non-UTF-8 CHANGELOG/SKILL ----
# The JSON manifests were rewritten before the strict-UTF-8 reads of SKILL.md and
# CHANGELOG.md, so one bad byte there aborted mid-run with the manifests already
# bumped — the exact drift Test 9 forbids — and --dry-run died with the same
# traceback. The preflight must abort all-or-nothing with a clean diagnostic.
for nu_target in CHANGELOG.md skills/planwright/SKILL.md; do
  NUWORK="$TMP/repo-nonutf8-$(basename "$nu_target" .md)"
  mkdir -p "$NUWORK"
  ( cd "$ROOT" && tar --exclude=.git --exclude=.planwright -cf - . ) | ( cd "$NUWORK" && tar -xf - )
  printf '\n<!-- caf\xe9 -->\n' >> "$NUWORK/$nu_target"
  nu_before="$(ver "$NUWORK/.claude-plugin/plugin.json" "['version']")"
  nu_rc=0
  nu_out="$("$NUWORK/scripts/bump-version.sh" patch 2>&1)" || nu_rc=$?
  nud_rc=0
  nud_out="$("$NUWORK/scripts/bump-version.sh" patch --dry-run 2>&1)" || nud_rc=$?
  nu_after="$(ver "$NUWORK/.claude-plugin/plugin.json" "['version']")"
  if [ "$nu_rc" -ne 0 ] && [ "$nud_rc" -ne 0 ] && [ "$nu_after" = "$nu_before" ] \
     && printf '%s' "$nu_out" | grep -q 'is not valid UTF-8; aborting before any edits' \
     && ! printf '%s%s' "$nu_out" "$nud_out" | grep -q 'Traceback'; then
    ok "bump-version aborts cleanly before any edit on a non-UTF-8 $nu_target"
  else
    bad "bump-version half-bumped or crashed on a non-UTF-8 $nu_target (rc=$nu_rc dry=$nud_rc before=$nu_before after=$nu_after)"
  fi
done


# --- Test 2c: a leading/trailing-whitespace PLUGIN_DESC scaffolds parseable YAML ----
# PLUGIN_DESC_ONELINE only translated \r\n\t to spaces and never trimmed, so a leading
# space produced a 3-space content line under the 2-space `description: >` folded
# block — frontmatter no YAML parser accepts, while the scaffold exited 0.
GEN_WS="$TMP/gen-ws"
NO_GIT=1 PLUGIN_DESC=' leading space desc ' "$ROOT/scripts/make-plugin.sh" demo "$GEN_WS" >/dev/null
ws_skill="$GEN_WS/skills/demo/SKILL.md"
if grep -q '^  leading space desc$' "$ws_skill" \
   && python3 - "$ws_skill" <<'PY' 2>/dev/null
import sys
text = open(sys.argv[1], encoding="utf-8").read()
assert text.startswith("---\n"), "no frontmatter"
fm = text.split("---\n")[1]
# structural YAML check without a yaml dependency: every non-key line in the folded
# description block must indent exactly two spaces (a deeper first line is the defect)
lines = fm.splitlines()
i = next(n for n, ln in enumerate(lines) if ln.startswith("description:"))
block = []
for ln in lines[i + 1:]:
    if ln and not ln.startswith(" "):
        break
    if ln.strip():
        block.append(ln)
assert block, "empty description block"
assert all(len(ln) - len(ln.lstrip(" ")) == 2 for ln in block), block
print("WSDESC-OK")
PY
then ok "make-plugin trims PLUGIN_DESC so the folded description block stays 2-space indented"; else bad "make-plugin emitted a misindented description block for a whitespace-padded PLUGIN_DESC"; fi
