# SPDX-FileCopyrightText: 2026 Eser KUBALI
# SPDX-License-Identifier: GPL-3.0-or-later
# shellcheck shell=bash
#
# scripts/make-plugin.sh — new-plugin scaffolder. Sourced by tests/run.sh after
# tests/lib.sh — NOT standalone (uses ROOT/TMP/ok/bad).
#
# make-plugin.sh emits JSON manifests (.claude-plugin/{plugin,marketplace}.json,
# .codex-plugin/plugin.json) and a YAML-frontmatter SKILL.md from free-text inputs.
# Its json_escape / PLUGIN_DESC_ONELINE logic is load-bearing: the script's own
# comments warn that a bad escape makes a manifest or the folded `description: >`
# frontmatter unparseable WHILE THE SCAFFOLD STILL EXITS 0 — a silent failure that
# ships a broken plugin. Nothing exercised it. These checks scaffold a plugin (with
# NO_GIT, so the run is hermetic) and assert every artifact parses, including under a
# hostile description that stresses exactly the escaping the script guards against.

MP="$ROOT/scripts/make-plugin.sh"

# --- Test MP1: a clean scaffold produces valid manifests + a framed SKILL.md --------
MPD="$TMP/mkplugin"; mkdir -p "$MPD"
if NO_GIT=1 AUTHOR_NAME="Test Dev" AUTHOR_EMAIL="t@example.com" PLUGIN_DESC="A test plugin." \
   bash "$MP" my-plugin "$MPD/my-plugin" >"$TMP/mp1.out" 2>"$TMP/mp1.err" \
   && python3 - "$MPD/my-plugin" 2>"$TMP/mp1.parse" <<'PY'
import json, os, sys
root = sys.argv[1]
for rel in (".claude-plugin/plugin.json", ".claude-plugin/marketplace.json", ".codex-plugin/plugin.json"):
    p = os.path.join(root, rel)
    assert os.path.exists(p), "missing manifest: " + rel
    json.load(open(p))                       # raises on invalid JSON
for rel in ("AGENTS.md", "GEMINI.md"):
    p = os.path.join(root, rel)
    assert os.path.exists(p), "missing integration file: " + rel
pj = json.load(open(os.path.join(root, ".claude-plugin/plugin.json")))
assert pj["name"] == "my-plugin", pj
assert pj["version"] == "0.1.0", pj
skill = open(os.path.join(root, "skills/my-plugin/SKILL.md")).read()
assert skill.startswith("---\n"), "SKILL.md missing frontmatter open"
assert len(skill.split("---\n")) >= 3, "SKILL.md missing frontmatter close fence"
PY
then ok "make-plugin.sh scaffolds valid JSON manifests + a framed SKILL.md (NO_GIT)"
else bad "make-plugin.sh clean scaffold failed: $(cat "$TMP/mp1.err" "$TMP/mp1.parse" 2>/dev/null)"; fi

# --- Test MP2: a hostile description stays JSON- and YAML-safe (the escaping seam) ---
# A description carrying double quotes, a backslash, a colon-space (a YAML scalar trap),
# and a newline must break neither the JSON manifests (json_escape) nor the folded
# `description: >` frontmatter (PLUGIN_DESC_ONELINE collapses the newline to a space).
# A leaked newline would push the tail to column 0 and make the frontmatter unparseable.
MPH="$TMP/mkplugin-hostile"; mkdir -p "$MPH"
if NO_GIT=1 AUTHOR_NAME='O"Brien \ Dev' AUTHOR_EMAIL="t@example.com" \
   PLUGIN_DESC=$'He said "hi": a\\b\nsecond line' \
   bash "$MP" edge-plugin "$MPH/edge-plugin" >"$TMP/mp2.out" 2>"$TMP/mp2.err" \
   && python3 - "$MPH/edge-plugin" 2>"$TMP/mp2.parse" <<'PY'
import json, os, sys
root = sys.argv[1]
for rel in (".claude-plugin/plugin.json", ".claude-plugin/marketplace.json", ".codex-plugin/plugin.json"):
    json.load(open(os.path.join(root, rel)))  # raises if the hostile desc broke the JSON
skill = open(os.path.join(root, "skills/edge-plugin/SKILL.md")).read()
fm = skill.split("---\n", 2)[1]               # the frontmatter block
for ln in fm.splitlines():
    assert not ln.startswith("second line"), "description newline leaked into frontmatter: %r" % ln
PY
then ok "make-plugin.sh keeps manifests + frontmatter parseable under a hostile description (escaping)"
else bad "make-plugin.sh escaping regressed on a hostile description: $(cat "$TMP/mp2.err" "$TMP/mp2.parse" 2>/dev/null)"; fi

# --- Test MP3: input validation — a non-kebab-case name is refused ------------------
if NO_GIT=1 bash "$MP" "Bad_Name" "$TMP/mp-bad" >/dev/null 2>&1; then
  bad "make-plugin.sh accepted an invalid (non-kebab-case) plugin name"
else
  ok "make-plugin.sh rejects a non-kebab-case plugin name (exit != 0)"
fi

# --- Test MP4: the generated ci.yml manifest-validation step rejects a corrupt manifest ----------
# make-plugin ships a ci.yml whose "Validate manifests" step json.loads every manifest. Run that EXACT
# shipped command: a clean scaffold passes, and a corrupt .claude-plugin/plugin.json makes it exit non-zero.
MP4="$TMP/mp4"; mkdir -p "$MP4"
NO_GIT=1 PLUGIN_DESC="probe" bash "$MP" demo "$MP4/demo" >/dev/null 2>&1
mp4_cmd="$(grep -A1 'Validate manifests' "$MP4/demo/.github/workflows/ci.yml" | grep 'run:' | sed 's/^[[:space:]]*run:[[:space:]]*//')"
mp4_clean=1; ( cd "$MP4/demo" && eval "$mp4_cmd" ) >/dev/null 2>&1 && mp4_clean=0
printf 'not json{' > "$MP4/demo/.claude-plugin/plugin.json"
mp4_corrupt=0; ( cd "$MP4/demo" && eval "$mp4_cmd" ) >/dev/null 2>&1 || mp4_corrupt=$?
if [ -n "$mp4_cmd" ] && [ "$mp4_clean" = 0 ] && [ "$mp4_corrupt" != 0 ]; then
  ok "the generated ci.yml manifest-validation step passes a clean scaffold and rejects a corrupt manifest"
else
  bad "generated ci.yml manifest-validation wrong (clean=$mp4_clean corrupt=$mp4_corrupt cmd='$mp4_cmd')"
fi

# --- Test MP5: a real lockstep bump inside the generated plugin advances all version surfaces ------
# make-plugin copies bump-version.sh into the generated tree; running it must advance the generated
# .claude-plugin/plugin.json, .codex-plugin/plugin.json, and SKILL.md frontmatter to the SAME new version.
MP5="$TMP/mp5"; mkdir -p "$MP5"
NO_GIT=1 PLUGIN_DESC="probe" bash "$MP" demo "$MP5/demo" >/dev/null 2>&1
mp5_before="$(ver "$MP5/demo/.claude-plugin/plugin.json" '["version"]')"
( cd "$MP5/demo" && ALLOW_DIRTY=1 bash scripts/bump-version.sh minor ) >/dev/null 2>&1
mp5_pj="$(ver "$MP5/demo/.claude-plugin/plugin.json" '["version"]')"
mp5_cj="$(ver "$MP5/demo/.codex-plugin/plugin.json" '["version"]')"
mp5_sk="$(grep -m1 '  version:' "$MP5/demo/skills/demo/SKILL.md" | sed -E 's/.*"([^"]+)".*/\1/')"
if [ "$mp5_pj" != "$mp5_before" ] && [ "$mp5_pj" = "$mp5_cj" ] && [ "$mp5_pj" = "$mp5_sk" ]; then
  ok "the copied bump-version.sh advances all three version surfaces in the generated plugin in lockstep"
else
  bad "generated-plugin lockstep bump drift (before=$mp5_before plugin=$mp5_pj codex=$mp5_cj skill=$mp5_sk)"
fi

# --- Test MP6: the generated integration pointers name skills/<name>/SKILL.md ---------------------
# make-plugin generates AGENTS.md/GEMINI.md that must point at the SCAFFOLDED skill path (not a hardcoded
# name). Scaffold under a distinct name and assert both pointers reference skills/<name>/SKILL.md.
MP6="$TMP/mp6"; mkdir -p "$MP6"
NO_GIT=1 PLUGIN_DESC="probe" bash "$MP" widget "$MP6/widget" >/dev/null 2>&1
if grep -qF 'skills/widget/SKILL.md' "$MP6/widget/AGENTS.md" \
   && grep -qF 'skills/widget/SKILL.md' "$MP6/widget/GEMINI.md"; then
  ok "the generated AGENTS.md and GEMINI.md both reference skills/<name>/SKILL.md for the scaffolded name"
else
  bad "a generated integration pointer (AGENTS.md/GEMINI.md) does not reference skills/widget/SKILL.md"
fi
