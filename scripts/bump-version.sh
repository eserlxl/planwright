#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Eser KUBALI
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Bump the plugin version in lockstep across Claude/Codex manifests,
# skill frontmatter, CHANGELOG.md, and the root README.md shields.io version badge.
#
# This script updates version numbers and the changelog — it does NOT create a
# git tag or GitHub release. Tags should only be created at release milestones:
# every 25-50 commits or when a meaningful feature ships (new subcommand, major
# behaviour change). Run bump-version.sh freely during development; tag and
# push the release manually when the milestone is reached.
#
# Usage:
#   scripts/bump-version.sh <major|minor|patch|X.Y.Z> [-m "changelog note"]
#
# Examples:
#   scripts/bump-version.sh patch
#   scripts/bump-version.sh minor -m "Add foo option"
#   scripts/bump-version.sh 2.0.0 -m "Rewrite the pipeline"
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PLUGIN_JSON="$ROOT/.claude-plugin/plugin.json"
CODEX_PLUGIN_JSON="$ROOT/.codex-plugin/plugin.json"
# A generated plugin (make-plugin.sh) also ships a .claude-plugin/marketplace.json whose
# metadata.version + plugins[].version must track plugin.json; this repo ships none, so the
# bump step below is a conditional no-op here and a real lockstep bump inside a scaffolded plugin.
MARKETPLACE_JSON="$ROOT/.claude-plugin/marketplace.json"
CHANGELOG="$ROOT/CHANGELOG.md"
README_FILE="$ROOT/README.md"
PLUGIN_YAML="$ROOT/plugin.yaml"

# Portable repo-relative path. GNU realpath's relative mode is unavailable on
# stock macOS without Homebrew; python3 is already required by this script.
relpath() { python3 -c 'import os,sys; print(os.path.relpath(sys.argv[1], sys.argv[2]))' "$1" "$ROOT"; }

usage() {
  echo "Usage: $(basename "$0") <major|minor|patch|X.Y.Z> [-m \"changelog note\"] [--dry-run]" >&2
  exit 1
}

[ $# -ge 1 ] || usage
[ "$1" = "-h" ] || [ "$1" = "--help" ] && { echo "Usage: $(basename "$0") <major|minor|patch|X.Y.Z> [-m \"changelog note\"] [--dry-run]"; exit 0; }
BUMP="$1"; shift
NOTE=""
DRY_RUN=""
while [ $# -gt 0 ]; do
  case "$1" in
    -m|--message)
      [ $# -ge 2 ] || { echo "Option $1 requires a value" >&2; usage; }
      NOTE="$2"; shift 2 ;;
    --dry-run)    DRY_RUN=1; shift ;;
    -h|--help) echo "Usage: $(basename "$0") <major|minor|patch|X.Y.Z> [-m \"changelog note\"] [--dry-run]"; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage ;;
  esac
done

for f in "$PLUGIN_JSON" "$CHANGELOG"; do
  [ -f "$f" ] || { echo "Missing required file: $f" >&2; exit 1; }
done

# All-or-nothing preflight: the JSON manifests are rewritten BEFORE the strict-UTF-8
# reads of SKILL.md/CHANGELOG.md below, so one bad byte there used to abort mid-run
# with the manifests already bumped — exactly the version drift the lockstep contract
# (and statics-scaffold Test 9) forbids. Decode-check every text file we will read
# before any write; a failure aborts with the tree untouched.
python3 - "$ROOT" "$CHANGELOG" <<'PY' || exit 1
import glob, os, sys
root, changelog = sys.argv[1], sys.argv[2]
for path in [changelog] + sorted(glob.glob(os.path.join(root, "skills", "*", "SKILL.md"))):
    try:
        with open(path, encoding="utf-8") as fh:
            fh.read()
    except UnicodeDecodeError:
        rel = os.path.relpath(path, root)
        sys.stderr.write(f"bump-version: {rel} is not valid UTF-8; aborting before any edits\n")
        sys.exit(1)
PY

# Refuse to mutate a dirty tree so the bump's edits stay isolated and revertible.
# Skipped when not inside a git work tree (e.g. the test harness) or ALLOW_DIRTY=1.
if [ "${ALLOW_DIRTY:-0}" != "1" ] && git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  if [ -n "$(git -C "$ROOT" status --porcelain)" ]; then
    echo "Working tree not clean; commit or stash first, or set ALLOW_DIRTY=1." >&2
    exit 1
  fi
fi

CURRENT="$(python3 - "$PLUGIN_JSON" <<'PY'
import json, sys
print(json.load(open(sys.argv[1]))["version"])
PY
)"

NEW="$(python3 - "$CURRENT" "$BUMP" <<'PY'
import re, sys
cur, bump = sys.argv[1], sys.argv[2]
# Accept an explicit target version: strict X.Y.Z, optionally with a SemVer
# pre-release (-rc1) and/or build (+meta) suffix, so a pre-release can be cut.
if re.fullmatch(r"\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?", bump):
    print(bump); raise SystemExit
# A relative bump operates on the release core: strip any SemVer pre-release
# (-rc.1) / build (+meta) suffix from the current version first, so a bump from
# a pinned pre-release (e.g. 2.6.0-rc.1+build.5) increments cleanly instead of
# crashing on cur.split(".").
core = re.match(r"(\d+)\.(\d+)\.(\d+)(?:[-+].*)?$", cur)
if not core:
    sys.stderr.write(f"Current version '{cur}' is not X.Y.Z\n"); raise SystemExit(1)
major, minor, patch = (int(g) for g in core.groups())
if bump == "major":   major, minor, patch = major + 1, 0, 0
elif bump == "minor": minor, patch = minor + 1, 0
elif bump == "patch": patch += 1
else:
    sys.stderr.write("bump must be one of: major | minor | patch | X.Y.Z\n"); raise SystemExit(1)
print(f"{major}.{minor}.{patch}")
PY
)"

DATE="$(date -u +%Y-%m-%d)"

# --- Transactional guard ---------------------------------------------------
# The JSON manifests, skill frontmatter, and CHANGELOG are rewritten as separate
# steps below; an interruption or a failed step between them would otherwise leave
# version drift across files (the lockstep contract forbids this). Back up every
# target up front and restore them ALL if any step fails or the run is interrupted,
# so a partial bump is impossible — the bump is all-or-nothing. (Skipped on
# --dry-run, which writes nothing.)
if [ -z "$DRY_RUN" ]; then
  _bump_targets=("$PLUGIN_JSON" "$CHANGELOG")
  [ -f "$CODEX_PLUGIN_JSON" ] && _bump_targets+=("$CODEX_PLUGIN_JSON")
  [ -f "$MARKETPLACE_JSON" ] && _bump_targets+=("$MARKETPLACE_JSON")
  [ -f "$README_FILE" ] && _bump_targets+=("$README_FILE")
  [ -f "$PLUGIN_YAML" ] && _bump_targets+=("$PLUGIN_YAML")
  for _skill in "$ROOT"/skills/*/SKILL.md; do
    [ -f "$_skill" ] && _bump_targets+=("$_skill")
  done
  BUMP_BACKUP="$(mktemp -d)"
  for _i in "${!_bump_targets[@]}"; do
    cp -p "${_bump_targets[$_i]}" "$BUMP_BACKUP/$_i"
  done
  _bump_restore() {
    local _i
    for _i in "${!_bump_targets[@]}"; do
      [ -f "$BUMP_BACKUP/$_i" ] && cp -p "$BUMP_BACKUP/$_i" "${_bump_targets[$_i]}" 2>/dev/null || true
    done
    echo "bump-version: a step failed or was interrupted; restored all files to their pre-bump state." >&2
  }
  trap '_bump_restore' ERR INT TERM
fi

# --- Update JSON manifests -------------------------------------------------
if [ -z "$DRY_RUN" ]; then
python3 - "$PLUGIN_JSON" "$CODEX_PLUGIN_JSON" "$NEW" <<'PY'
import json, os, sys, tempfile
plugin_path, codex_plugin_path, new = sys.argv[1:4]

def atomic_write(path, data):
    # Same-directory temp + os.replace, mirroring scripts/lifecycle.py's write() and
    # scripts/state.py's _write_activity(). A plain open(path, "w") truncates the file
    # before the new bytes land, so a crash/OOM/power-loss between the truncate and the
    # completed write (the one window the ERR/INT/TERM backup-restore trap cannot catch)
    # would leave a partial/truncated manifest. The temp keeps the rename on one
    # filesystem (atomic); on any failure it is removed and the error re-raised, leaving
    # the original target untouched.
    d = os.path.dirname(path) or "."
    fd, tmp = tempfile.mkstemp(dir=d, prefix=".bump-", suffix=".tmp")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            fh.write(data)
        os.replace(tmp, path)
    except BaseException:
        try:
            os.remove(tmp)
        except OSError:
            pass
        raise

with open(plugin_path) as f:
    plugin = json.load(f)
plugin["version"] = new
atomic_write(plugin_path, json.dumps(plugin, indent=2) + "\n")

try:
    with open(codex_plugin_path) as f:
        codex_plugin = json.load(f)
except FileNotFoundError:
    codex_plugin = None
if codex_plugin is not None:
    codex_plugin["version"] = new
    atomic_write(codex_plugin_path, json.dumps(codex_plugin, indent=2) + "\n")
PY
fi

# --- Update YAML manifest --------------------------------------------------
if [ -z "$DRY_RUN" ] && [ -f "$PLUGIN_YAML" ]; then
python3 - "$PLUGIN_YAML" "$NEW" <<'PY'
import os, re, sys, tempfile
path, new = sys.argv[1:3]

def atomic_write(path, data):
    d = os.path.dirname(path) or "."
    fd, tmp = tempfile.mkstemp(dir=d, prefix=".bump-", suffix=".tmp")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            fh.write(data)
        os.replace(tmp, path)
    except BaseException:
        try:
            os.remove(tmp)
        except OSError:
            pass
        raise

with open(path) as f:
    text = f.read()
text, n = re.subn(r'(?m)^version:\s*.*', f'version: {new}', text, count=1)
if n:
    atomic_write(path, text)
PY
fi

# --- Update the generated marketplace.json (if present) --------------------
# A scaffolded plugin (make-plugin.sh) ships .claude-plugin/marketplace.json with
# metadata.version and a plugins[] array whose entries carry their own version; both must
# track plugin.json so the marketplace listing never advertises a stale version. This repo
# ships no marketplace.json, so the step is a no-op here; inside a generated plugin it keeps
# marketplace.json in the lockstep set with the manifests/SKILL/CHANGELOG.
if [ -z "$DRY_RUN" ] && [ -f "$MARKETPLACE_JSON" ]; then
python3 - "$MARKETPLACE_JSON" "$NEW" <<'PY'
import json, os, sys, tempfile
path, new = sys.argv[1:3]

def atomic_write(path, data):
    d = os.path.dirname(path) or "."
    fd, tmp = tempfile.mkstemp(dir=d, prefix=".bump-", suffix=".tmp")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            fh.write(data)
        os.replace(tmp, path)
    except BaseException:
        try:
            os.remove(tmp)
        except OSError:
            pass
        raise

with open(path) as f:
    m = json.load(f)
if isinstance(m.get("metadata"), dict):
    m["metadata"]["version"] = new
for entry in (m.get("plugins") or []):
    if isinstance(entry, dict):
        entry["version"] = new
atomic_write(path, json.dumps(m, indent=2) + "\n")
PY
fi

# --- Sync skill frontmatter versions --------------------------------------
SKILLS_SYNCED=""
for skill in "$ROOT"/skills/*/SKILL.md; do
  [ -f "$skill" ] || continue
  rel="$(relpath "$skill")"
  if [ -n "$DRY_RUN" ]; then
    # Probe with the SAME quoted-form pattern the real rewrite below uses, so --dry-run and
    # the real run classify a SKILL.md identically (an unquoted scalar is skipped by both).
    has_ver="$(python3 -c "import re,sys;t=open(sys.argv[1]).read();print('1' if re.search(r'\n  version:\s*\"[^\"]*\"', t) else '0')" "$skill")"
    if [ "$has_ver" = "1" ]; then SKILLS_SYNCED="$SKILLS_SYNCED $rel"; else echo "warning: no metadata 'version:' line in $rel; skipped" >&2; fi
  else
    changed="$(python3 - "$skill" "$NEW" <<'PY'
import os, re, sys, tempfile
path, new = sys.argv[1], sys.argv[2]

def atomic_write(path, data):
    # Same-directory temp + os.replace (see the JSON-manifest step above): never
    # truncate-then-write, so an interruption cannot leave a half-written SKILL.md.
    d = os.path.dirname(path) or "."
    fd, tmp = tempfile.mkstemp(dir=d, prefix=".bump-", suffix=".tmp")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            fh.write(data)
        os.replace(tmp, path)
    except BaseException:
        try:
            os.remove(tmp)
        except OSError:
            pass
        raise

with open(path) as f:
    text = f.read()
# Rewrite the metadata version line in the YAML frontmatter (2-space indent).
text, n = re.subn(r'(\n  version:\s*)"[^"]*"', rf'\g<1>"{new}"', text, count=1)
if n:
    atomic_write(path, text)
print(n)
PY
)"
    if [ "$changed" = "0" ]; then
      echo "warning: no metadata 'version:' line in $rel; skipped" >&2
    else
      SKILLS_SYNCED="$SKILLS_SYNCED $rel"
    fi
  fi
done

# --- Rewrite the root README shields.io version badge ----------------------
# The version badge lives in README prose, outside the manifest/SKILL.md
# frontmatter lockstep, so without this step the published badge would silently
# drift behind the real version. Best-effort and non-fatal, mirroring the
# SKILL.md sync: a missing README, or a README with no version badge, warns and
# is skipped so the bump still succeeds. The python handles its own dry-run
# (prints "would" and writes nothing) so --dry-run reports accurately.
README_STATUS=""
if [ -f "$README_FILE" ]; then
  README_STATUS="$(python3 - "$README_FILE" "$NEW" "${DRY_RUN:-0}" <<'PY'
import os, re, sys, tempfile
path, new, dry = sys.argv[1], sys.argv[2], sys.argv[3]

def atomic_write(path, data):
    # Same-directory temp + os.replace (see the JSON-manifest step above): never
    # truncate-then-write, so an interruption cannot leave a half-written README.
    d = os.path.dirname(path) or "."
    fd, tmp = tempfile.mkstemp(dir=d, prefix=".bump-", suffix=".tmp")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            fh.write(data)
        os.replace(tmp, path)
    except BaseException:
        try:
            os.remove(tmp)
        except OSError:
            pass
        raise

# shields.io escapes '-' as '--' and '_' as '__' inside the message field; a
# plain X.Y.Z version is unaffected, but a pre-release like 1.0.0-rc1 is not.
message = new.replace("-", "--").replace("_", "__")
with open(path, encoding="utf-8") as f:
    text = f.read()
# label 'version', then the message (non-greedy), then a 6-hex color + closing paren.
pat = re.compile(r"(https://img\.shields\.io/badge/version-).+?(-[0-9A-Fa-f]{6}\))")
# A function replacement avoids re.sub interpreting backslashes in `message`.
new_text, n = pat.subn(lambda m: m.group(1) + message + m.group(2), text)
if n == 0:
    print("nobadge"); raise SystemExit
if new_text == text:
    print("same"); raise SystemExit
if dry != "0":
    print("would"); raise SystemExit
atomic_write(path, new_text)
print("changed")
PY
)"
  case "$README_STATUS" in
    nobadge) echo "warning: no shields.io version badge in $(relpath "$README_FILE"); skipped" >&2 ;;
    "") echo "warning: README badge sync produced no result; skipped" >&2 ;;
  esac
fi

# --- Prepend a CHANGELOG entry --------------------------------------------
if [ -z "$DRY_RUN" ]; then
python3 - "$CHANGELOG" "$NEW" "$DATE" "$NOTE" <<'PY'
import os, sys, tempfile
path, new, date, note = sys.argv[1:5]

def atomic_write(path, data):
    # Same-directory temp + os.replace (see the JSON-manifest step above): never
    # truncate-then-write, so an interruption cannot leave a half-written CHANGELOG.
    d = os.path.dirname(path) or "."
    fd, tmp = tempfile.mkstemp(dir=d, prefix=".bump-", suffix=".tmp")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            fh.write(data)
        os.replace(tmp, path)
    except BaseException:
        try:
            os.remove(tmp)
        except OSError:
            pass
        raise

note = note or "Version bump."
block = f"## [{new}] - {date}\n\n### Changed\n- {note}\n\n"
with open(path) as f:
    lines = f.readlines()
# Insert above the first existing version section; warn and append if none exists.
idx = next((i for i, ln in enumerate(lines) if ln.startswith("## [")), None)
if idx is None:
    sys.stderr.write("warning: no '## [' version section in changelog; appending entry at end\n")
    idx = len(lines)
lines[idx:idx] = [block]
atomic_write(path, "".join(lines))
PY
fi

# All writes succeeded — commit the transaction: drop the restore trap and clean up.
if [ -z "$DRY_RUN" ]; then
  trap - ERR INT TERM
  rm -rf "$BUMP_BACKUP"
fi

if [ -n "$DRY_RUN" ]; then
  echo "dry-run: $CURRENT -> $NEW (files not modified)"
  echo
  echo "Would add to CHANGELOG.md:"
  echo "## [$NEW] - $DATE"
  echo
  echo "### Changed"
  echo "- ${NOTE:-Version bump.}"
  # if/fi (not `[ ] && echo`): as the branch's LAST statement under set -e, a false `[ -n ]`
  # test would otherwise become the script's exit status, making --dry-run exit 1 whenever no
  # skill is syncable — while the real run exits 0. Keep the probe's exit code trustworthy.
  if [ -n "$SKILLS_SYNCED" ]; then echo "  would sync$SKILLS_SYNCED"; fi
  # Same if/fi rule: a false `[ = ]` here as the branch's last statement would leak exit 1.
  if [ "$README_STATUS" = "would" ]; then echo "  would update $(relpath "$README_FILE") version badge -> $NEW"; fi
  if [ -f "$PLUGIN_YAML" ]; then echo "  would update $(relpath "$PLUGIN_YAML") -> $NEW"; fi
else
  echo "Bumped: $CURRENT -> $NEW"
  echo "  updated $(relpath "$PLUGIN_JSON")"
  [ -f "$CODEX_PLUGIN_JSON" ] && echo "  updated $(relpath "$CODEX_PLUGIN_JSON")"
  [ -f "$PLUGIN_YAML" ] && echo "  updated $(relpath "$PLUGIN_YAML")"
  [ -n "$SKILLS_SYNCED" ] && echo "  updated$SKILLS_SYNCED"
  [ "$README_STATUS" = "changed" ] && echo "  updated $(relpath "$README_FILE") (version badge)"
  echo "  changelog entry added ($DATE)"
  echo
  echo "Next: review the diff, commit, then refresh/reinstall in the host you are testing."
fi
