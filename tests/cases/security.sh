# SPDX-FileCopyrightText: 2026 Eser KUBALI
# SPDX-License-Identifier: GPL-3.0-or-later
# shellcheck shell=bash
#
# Read-only planning write-boundary invariant tests. Sourced by tests/run.sh after
# tests/lib.sh — NOT standalone (uses ROOT/TMP/ok/bad).

# --- Test SEC1: planning entry points write only under .planwright/ -----------------
# status.py / build-graph.py / lint-plan.py are the read-only planning entry points.
# SKILL.md pins "writes only the plan file, never application source." Run all three
# over a committed git fixture and assert nothing OUTSIDE .planwright/ is created or
# modified — a whole-tree snapshot the per-file --fix byte checks (lint-plan.sh) miss.
SEC="$TMP/sec_wb"; mkdir -p "$SEC/.planwright" "$SEC/src"
printf 'def a():\n    return 1\n' > "$SEC/src/a.py"
printf '# readme\n[x](src/a.py)\n' > "$SEC/README.md"
git -C "$SEC" init -q
git -C "$SEC" add -A
git -C "$SEC" -c user.name=t -c user.email=t@e.com commit -qm init
cat > "$SEC/.planwright/plan.md" <<'PLAN'
# planwright Plan — .

- [ ] Probe item with a mechanically fixable Surface
      Mode: improve
      Rationale: exercise lint-plan --fix so the write path actually runs.
      Evidence: src/a.py:1 defines a().
      Surfaces: src/a.py
      Development: no-op probe.
      Acceptance: nothing outside .planwright/ changes.
      Verification: bash tests/run.sh
PLAN
# Snapshot every tracked-and-untracked path OUTSIDE .planwright/ (name + checksum).
sec_snap() { ( cd "$SEC" && find . -type f -not -path './.git/*' -not -path './.planwright/*' \
                 | LC_ALL=C sort | while read -r f; do printf '%s ' "$f"; cksum "$f"; done ); }
sec_before="$(sec_snap)"
python3 "$ROOT/scripts/build-graph.py" --root "$SEC" >/dev/null 2>&1 || true
python3 "$ROOT/scripts/status.py" --recommend --root "$SEC" >/dev/null 2>&1 || true
python3 "$ROOT/scripts/lint-plan.py" --root "$SEC" --plan "$SEC/.planwright/plan.md" --fix --quiet >/dev/null 2>&1 || true
sec_after="$(sec_snap)"
if [ "$sec_before" = "$sec_after" ]; then
  ok "planning entry points (status/build-graph/lint-plan) write nothing outside .planwright/"
else
  bad "a planning entry point created or modified a file outside .planwright/ (before/after tree differ)"
fi
