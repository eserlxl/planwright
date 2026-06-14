# SPDX-FileCopyrightText: 2026 Eser KUBALI
# SPDX-License-Identifier: GPL-3.0-or-later
# shellcheck shell=bash
#
# scripts/bump-version.sh — lockstep release version bumper. Sourced by tests/run.sh
# after tests/lib.sh — NOT standalone (uses ROOT/TMP/ok/bad/ver).
#
# bump-version.sh rewrites the version in lockstep across .claude-plugin/plugin.json,
# .claude-plugin/marketplace.json, .codex-plugin/plugin.json and every skills/*/SKILL.md
# frontmatter, prepends a CHANGELOG entry, and is transactional (restore-on-failure). A
# regression in its SemVer computation or its lockstep sync would ship drifted versions
# silently — exactly what the lockstep contract forbids — yet nothing exercised it. These
# checks build a hermetic temp repo, copy the script in (so its BASH_SOURCE/.. ROOT resolves
# to the fixture, never the real tree), and assert the version math, the lockstep sync, and
# the --dry-run no-write contract. ALLOW_DIRTY=1 skips the git clean-tree guard in the fixture.

BV="$ROOT/scripts/bump-version.sh"

# Build a fixture repo at $1 with plugin name "demo" pinned at version $2.
_bv_fixture() {
  local d="$1" ver="$2"
  mkdir -p "$d/.claude-plugin" "$d/.codex-plugin" "$d/scripts" "$d/skills/demo"
  printf '{\n  "name": "demo",\n  "version": "%s"\n}\n' "$ver" > "$d/.claude-plugin/plugin.json"
  printf '{\n  "metadata": {\n    "version": "%s"\n  },\n  "plugins": [\n    {\n      "name": "demo",\n      "version": "%s"\n    }\n  ]\n}\n' "$ver" "$ver" > "$d/.claude-plugin/marketplace.json"
  printf '{\n  "name": "demo",\n  "version": "%s"\n}\n' "$ver" > "$d/.codex-plugin/plugin.json"
  printf -- '# Changelog\n\n## [%s] - 2026-01-01\n\n### Changed\n- seed\n' "$ver" > "$d/CHANGELOG.md"
  printf -- '---\nname: demo\nmetadata:\n  version: "%s"\n---\n\n# demo\n' "$ver" > "$d/skills/demo/SKILL.md"
  cp "$BV" "$d/scripts/bump-version.sh"
}

# --- Test BV1: a relative `minor` bump syncs every file in lockstep -----------------
BV1="$TMP/bv-minor"; _bv_fixture "$BV1" "1.2.3"
if ALLOW_DIRTY=1 bash "$BV1/scripts/bump-version.sh" minor -m "Add a thing" >"$TMP/bv1.out" 2>"$TMP/bv1.err" \
   && python3 - "$BV1" <<'PY'
import json, re, sys
d = sys.argv[1]; new = "1.3.0"
assert json.load(open(d + "/.claude-plugin/plugin.json"))["version"] == new, "plugin.json"
m = json.load(open(d + "/.claude-plugin/marketplace.json"))
assert m["metadata"]["version"] == new, "marketplace metadata"
assert all(e["version"] == new for e in m["plugins"] if e.get("name") == "demo"), "marketplace entry"
assert json.load(open(d + "/.codex-plugin/plugin.json"))["version"] == new, "codex plugin.json"
assert re.search(r'\n  version:\s*"' + re.escape(new) + '"', open(d + "/skills/demo/SKILL.md").read()), "SKILL frontmatter"
cl = open(d + "/CHANGELOG.md").read()
assert ("## [" + new + "]") in cl and "Add a thing" in cl, "changelog entry"
PY
then ok "bump-version.sh minor bump syncs all manifests + frontmatter + changelog in lockstep"
else bad "bump-version.sh minor bump failed: $(cat "$TMP/bv1.err" 2>/dev/null)"; fi

# --- Test BV2: an explicit X.Y.Z target is honored ----------------------------------
BV2="$TMP/bv-explicit"; _bv_fixture "$BV2" "1.2.3"
if ALLOW_DIRTY=1 bash "$BV2/scripts/bump-version.sh" 2.0.0 >"$TMP/bv2.out" 2>"$TMP/bv2.err" \
   && [ "$(ver "$BV2/.claude-plugin/plugin.json" '["version"]')" = "2.0.0" ]; then
  ok "bump-version.sh honors an explicit X.Y.Z target version"
else bad "bump-version.sh explicit target failed: $(cat "$TMP/bv2.err" 2>/dev/null)"; fi

# --- Test BV3: a patch bump from a pre-release-suffixed current increments the core --
BV3="$TMP/bv-prerelease"; _bv_fixture "$BV3" "2.6.0-rc.1+build.5"
if ALLOW_DIRTY=1 bash "$BV3/scripts/bump-version.sh" patch >"$TMP/bv3.out" 2>"$TMP/bv3.err" \
   && [ "$(ver "$BV3/.claude-plugin/plugin.json" '["version"]')" = "2.6.1" ]; then
  ok "bump-version.sh patch bump strips a pre-release suffix and increments the release core"
else bad "bump-version.sh pre-release patch failed (got $(ver "$BV3/.claude-plugin/plugin.json" '["version"]' 2>/dev/null)): $(cat "$TMP/bv3.err" 2>/dev/null)"; fi

# --- Test BV4: --dry-run reports the transition and writes nothing -------------------
BV4="$TMP/bv-dry"; _bv_fixture "$BV4" "1.2.3"
_bv_before="$(cat "$BV4/.claude-plugin/plugin.json" "$BV4/CHANGELOG.md")"
if ALLOW_DIRTY=1 bash "$BV4/scripts/bump-version.sh" major --dry-run >"$TMP/bv4.out" 2>"$TMP/bv4.err" \
   && [ "$(cat "$BV4/.claude-plugin/plugin.json" "$BV4/CHANGELOG.md")" = "$_bv_before" ] \
   && grep -q "1.2.3 -> 2.0.0" "$TMP/bv4.out"; then
  ok "bump-version.sh --dry-run reports the transition and writes nothing"
else bad "bump-version.sh --dry-run mutated files or misreported: $(cat "$TMP/bv4.err" 2>/dev/null)"; fi
