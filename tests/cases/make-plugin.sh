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
