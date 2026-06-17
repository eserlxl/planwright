# SPDX-FileCopyrightText: 2026 Eser KUBALI
# SPDX-License-Identifier: GPL-3.0-or-later
# shellcheck shell=bash
#
# scripts/bump-version.sh — lockstep release version bumper. Sourced by tests/run.sh
# after tests/lib.sh — NOT standalone (uses ROOT/TMP/ok/bad/ver).
#
# bump-version.sh rewrites the version in lockstep across .claude-plugin/plugin.json,
# .codex-plugin/plugin.json, every skills/*/SKILL.md frontmatter and the root
# README.md shields.io version badge, prepends a CHANGELOG entry, and is
# transactional (restore-on-failure). A
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
  printf '{\n  "name": "demo",\n  "version": "%s"\n}\n' "$ver" > "$d/.codex-plugin/plugin.json"
  printf -- '# Changelog\n\n## [%s] - 2026-01-01\n\n### Changed\n- seed\n' "$ver" > "$d/CHANGELOG.md"
  printf -- '---\nname: demo\nmetadata:\n  version: "%s"\n---\n\n# demo\n' "$ver" > "$d/skills/demo/SKILL.md"
  # A README carrying a shields.io version badge pinned at a sentinel (0.0.0), so a
  # successful bump must rewrite the message to the new version. The seed message is
  # deliberately NOT $ver: the assertions then prove the rewrite happened rather than
  # accidentally matching a pre-existing value.
  printf -- '# demo\n\n[![version](https://img.shields.io/badge/version-0.0.0-2563EB)](CHANGELOG.md)\n[![license](https://img.shields.io/badge/license-GPL--3.0-16A34A)](LICENSE)\n' > "$d/README.md"
  cp "$BV" "$d/scripts/bump-version.sh"
}

# --- Test BV1: a relative `minor` bump syncs every file in lockstep -----------------
BV1="$TMP/bv-minor"; _bv_fixture "$BV1" "1.2.3"
if ALLOW_DIRTY=1 bash "$BV1/scripts/bump-version.sh" minor -m "Add a thing" >"$TMP/bv1.out" 2>"$TMP/bv1.err" \
   && python3 - "$BV1" <<'PY'
import json, re, sys
d = sys.argv[1]; new = "1.3.0"
assert json.load(open(d + "/.claude-plugin/plugin.json"))["version"] == new, "plugin.json"
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
_bv_before="$(cat "$BV4/.claude-plugin/plugin.json" "$BV4/CHANGELOG.md" "$BV4/README.md")"
if ALLOW_DIRTY=1 bash "$BV4/scripts/bump-version.sh" major --dry-run >"$TMP/bv4.out" 2>"$TMP/bv4.err" \
   && [ "$(cat "$BV4/.claude-plugin/plugin.json" "$BV4/CHANGELOG.md" "$BV4/README.md")" = "$_bv_before" ] \
   && grep -q "1.2.3 -> 2.0.0" "$TMP/bv4.out" \
   && grep -q "would update.*version badge -> 2.0.0" "$TMP/bv4.out"; then
  ok "bump-version.sh --dry-run reports the transition (incl. README badge) and writes nothing"
else bad "bump-version.sh --dry-run mutated files or misreported: $(cat "$TMP/bv4.err" 2>/dev/null)"; fi

# --- Test BV5: a real bump rewrites the README shields.io version badge in lockstep --
BV5="$TMP/bv-readme"; _bv_fixture "$BV5" "1.2.3"
if ALLOW_DIRTY=1 bash "$BV5/scripts/bump-version.sh" minor >"$TMP/bv5.out" 2>"$TMP/bv5.err" \
   && grep -q "img.shields.io/badge/version-1.3.0-2563EB" "$BV5/README.md" \
   && ! grep -q "version-0.0.0-" "$BV5/README.md" \
   && [ "$(ver "$BV5/.claude-plugin/plugin.json" '["version"]')" = "1.3.0" ]; then
  ok "bump-version.sh rewrites the README shields.io version badge in lockstep with the manifests"
else bad "bump-version.sh README badge sync failed: $(cat "$TMP/bv5.err" 2>/dev/null)"; fi

# --- Test BV6: a missing README is non-fatal — the bump still succeeds ---------------
# The README badge step is documented as best-effort; a regression making it fatal must
# fail this case. BV6 removes the fixture's README entirely and asserts the bump still
# completes (exit 0) and the manifest version still advanced.
BV6="$TMP/bv-noreadme"; _bv_fixture "$BV6" "1.2.3"; rm -f "$BV6/README.md"
if ALLOW_DIRTY=1 bash "$BV6/scripts/bump-version.sh" minor >"$TMP/bv6.out" 2>"$TMP/bv6.err" \
   && [ "$(ver "$BV6/.claude-plugin/plugin.json" '["version"]')" = "1.3.0" ]; then
  ok "bump-version.sh still bumps (exit 0) when no README.md is present — badge sync is non-fatal"
else bad "bump-version.sh aborted on a missing README (should be non-fatal): $(cat "$TMP/bv6.err" 2>/dev/null)"; fi

# --- Test BV7: a README with no version badge warns and is skipped (non-fatal) -------
# The other half of the best-effort contract: a README that exists but carries no
# shields.io version badge must warn-and-skip, not abort. Assert exit 0, the version
# still bumped, and the exact skip warning on stderr.
BV7="$TMP/bv-nobadge"; _bv_fixture "$BV7" "1.2.3"
printf -- '# demo\n\nNo version badge in this README.\n' > "$BV7/README.md"
if ALLOW_DIRTY=1 bash "$BV7/scripts/bump-version.sh" minor >"$TMP/bv7.out" 2>"$TMP/bv7.err" \
   && [ "$(ver "$BV7/.claude-plugin/plugin.json" '["version"]')" = "1.3.0" ] \
   && grep -q "no shields.io version badge in README.md; skipped" "$TMP/bv7.err"; then
  ok "bump-version.sh bumps and warns (non-fatal) when README.md has no version badge"
else bad "bump-version.sh mishandled a badge-less README: $(cat "$TMP/bv7.err" 2>/dev/null)"; fi

# --- Test BV8: the live README version badge agrees with the manifest at rest ----------
# bump-version.sh rewrites the README shields.io version badge (BV5 proves the SCRIPT does so
# on a fixture), but nothing pins that the COMMITTED README badge currently matches the
# manifest — a hand-edit or a skipped bump would silently ship a stale front-page version.
# statics Test 9 pins the manifests/SKILL/CHANGELOG at rest but NOT the README badge; close
# that one unguarded version surface here against the live tree.
rmv="$(ver "$ROOT/.claude-plugin/plugin.json" '["version"]')"
if grep -qF "img.shields.io/badge/version-$rmv-2563EB" "$ROOT/README.md"; then
  ok "live README version badge agrees with the manifest at rest ($rmv)"
else
  bad "README version badge drifted from the manifest ($rmv): $(grep -oE 'badge/version-[0-9][^)]*' "$ROOT/README.md" | head -1)"
fi

# --- Test BV9: the newest CHANGELOG heading agrees with the manifest at rest ------------
# statics Test 9 asserts the current manifest version has SOME ## [X.Y.Z] section, but not
# that it is the NEWEST — so a CHANGELOG raced ahead of the manifest (a new heading added
# before the bump) or a current-version section buried below a staler head slips through.
# Pin the HEAD heading == manifest at rest, catching a manifest bumped without a CHANGELOG
# entry, or a CHANGELOG bumped without the manifest. The grep skips a leading non-numeric
# [Unreleased] heading and takes the first numeric version heading (the newest release).
clv="$(ver "$ROOT/.claude-plugin/plugin.json" '["version"]')"
clhead="$(grep -m1 -oE '^## \[[0-9]+\.[0-9]+\.[0-9]+' "$ROOT/CHANGELOG.md" | sed -E 's/^## \[//')"
if [ "$clhead" = "$clv" ]; then
  ok "newest CHANGELOG heading agrees with the manifest at rest ($clv)"
else
  bad "CHANGELOG head/manifest drift: newest CHANGELOG heading is [$clhead] but the manifest is $clv"
fi
