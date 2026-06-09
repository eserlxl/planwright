# SPDX-FileCopyrightText: 2026 Eser KUBALI
# SPDX-License-Identifier: GPL-3.0-or-later
# shellcheck shell=bash
#
# scripts/lint-final.py — validate a recorded final point (.planwright/final.md).
# Sourced by tests/run.sh after tests/lib.sh — NOT standalone (uses ROOT/TMP/ok/bad).

LF="$ROOT/scripts/lint-final.py"

# --- Test LF0: lint-final.py parses (no syntax error) -----------------------------
if python3 -c "import ast,sys; ast.parse(open(sys.argv[1]).read())" "$LF" 2>/dev/null; then
  ok "lint-final.py parses (no syntax error)"
else
  bad "lint-final.py has a syntax error"
fi

# A well-formed final.md: sha + four dry rungs-with-reasons + a valid deepest_tier.
_wellformed() {
  printf 'sha: 73186114f528631c7070eb6ef9504ffb0294a17e\n'
  printf 'date: 2026-06-09\n'
  printf 'deepest_tier: expand\n'
  printf 'repair: dry — no confirmed defects in the dirty set\n'
  printf 'coverage: dry — focused tests present for all changed paths\n'
  printf 'opportunity: dry — no above-bar enhancement against the mission\n'
  printf 'vision: dry — no mission-aligned design bet remains\n'
}

# --- Test LF1: a well-formed final.md is OK (exit 0, ok:true) ----------------------
WF="$TMP/lf-wellformed"; mkdir -p "$WF/.planwright"
_wellformed > "$WF/.planwright/final.md"
rc=0; out="$(python3 "$LF" --root "$WF" --json)" || rc=$?
if [ "$rc" = 0 ] && printf '%s' "$out" | grep -q '"ok": true'; then
  ok "lint-final.py accepts a well-formed final.md (exit 0)"
else
  bad "lint-final.py rejected a well-formed final.md (rc=$rc): $out"
fi

# --- Test LF2: an ABSENT final.md is valid (exit 0) -------------------------------
# No final point is a legitimate state — the ladder is open. Must not fail.
AB="$TMP/lf-absent"; mkdir -p "$AB/.planwright"
rc=0; out="$(python3 "$LF" --root "$AB" --json)" || rc=$?
if [ "$rc" = 0 ] && printf '%s' "$out" | grep -q '"present": false'; then
  ok "lint-final.py treats an absent final.md as a valid (open-ladder) state (exit 0)"
else
  bad "lint-final.py failed on an absent final.md (rc=$rc): $out"
fi

# --- Test LF3: a missing rung justification FAILs (exit 1) ------------------------
MR="$TMP/lf-missing-rung"; mkdir -p "$MR/.planwright"
_wellformed | grep -v '^vision:' > "$MR/.planwright/final.md"   # drop the vision rung
rc=0; out="$(python3 "$LF" --root "$MR" 2>&1)" || rc=$?
if [ "$rc" = 1 ] && printf '%s' "$out" | grep -q "rung 'vision'"; then
  ok "lint-final.py fails a final.md missing a rung dry-reason (names the rung)"
else
  bad "lint-final.py did not fail a missing-rung final.md (rc=$rc): $out"
fi

# --- Test LF4: an out-of-vocabulary deepest_tier FAILs (exit 1) -------------------
# A typo like `exapnd` would silently mis-route the escalation-reach short-circuit.
BT="$TMP/lf-bad-tier"; mkdir -p "$BT/.planwright"
_wellformed | sed 's/^deepest_tier: expand/deepest_tier: exapnd/' > "$BT/.planwright/final.md"
rc=0; out="$(python3 "$LF" --root "$BT" 2>&1)" || rc=$?
if [ "$rc" = 1 ] && printf '%s' "$out" | grep -q "deepest_tier 'exapnd'"; then
  ok "lint-final.py fails a final.md with an out-of-vocabulary deepest_tier"
else
  bad "lint-final.py accepted an out-of-vocabulary deepest_tier (rc=$rc): $out"
fi

# --- Test LF5: a missing sha FAILs (exit 1) ---------------------------------------
NS="$TMP/lf-no-sha"; mkdir -p "$NS/.planwright"
_wellformed | grep -v '^sha:' > "$NS/.planwright/final.md"
rc=0; out="$(python3 "$LF" --root "$NS" 2>&1)" || rc=$?
if [ "$rc" = 1 ] && printf '%s' "$out" | grep -q 'sha:'; then
  ok "lint-final.py fails a final.md with no sha"
else
  bad "lint-final.py accepted a final.md with no sha (rc=$rc): $out"
fi

# --- Test LF6: a paired field without its partner FAILs (exit 1) ------------------
# `scope:` asserts a scoped final point; `scope_focus_sha:` makes it replayable.
PF="$TMP/lf-paired"; mkdir -p "$PF/.planwright"
{ _wellformed; printf 'scope: path:scripts/\n'; } > "$PF/.planwright/final.md"  # no scope_focus_sha
rc=0; out="$(python3 "$LF" --root "$PF" 2>&1)" || rc=$?
if [ "$rc" = 1 ] && printf '%s' "$out" | grep -q 'scope_focus_sha'; then
  ok "lint-final.py fails a final.md with scope: but no scope_focus_sha:"
else
  bad "lint-final.py accepted an unpaired scope field (rc=$rc): $out"
fi

# --- Test LF7: duplicate key uses LAST value (agrees with status._parse_final) -----
# status._parse_final keeps the LAST `sha:` line; lint-final must too, or it validates
# different bytes than the consumer acts on. A trailing blank `sha:` must therefore fail.
DK="$TMP/lf-dupkey"; mkdir -p "$DK/.planwright"
{ _wellformed; printf 'sha:\n'; } > "$DK/.planwright/final.md"   # trailing blank duplicate sha
rc=0; out="$(python3 "$LF" --root "$DK" 2>&1)" || rc=$?
if [ "$rc" = 1 ] && printf '%s' "$out" | grep -q 'sha:'; then
  ok "lint-final.py uses the last duplicate key value (trailing blank sha: fails, matching status)"
else
  bad "lint-final.py did not honor last-wins on a duplicate sha key (rc=$rc): $out"
fi

# --- Test LF8: paired fields are symmetric — the partner-only direction also fails --
# scope_focus_sha: without scope: (and invent_framing: without invent_seed:) is a
# half-recorded point: replayable bytes with nothing they anchor to. Both must fail.
RP1="$TMP/lf-revpair-scope"; mkdir -p "$RP1/.planwright"
{ _wellformed; printf 'scope_focus_sha: deadbeef\n'; } > "$RP1/.planwright/final.md"   # no scope:
rc=0; out="$(python3 "$LF" --root "$RP1" 2>&1)" || rc=$?
RP2="$TMP/lf-revpair-seed"; mkdir -p "$RP2/.planwright"
{ _wellformed; printf 'invent_framing: power-user\n'; } > "$RP2/.planwright/final.md"   # no invent_seed:
rc2=0; out2="$(python3 "$LF" --root "$RP2" 2>&1)" || rc2=$?
if [ "$rc" = 1 ] && printf '%s' "$out" | grep -q 'scope:' \
   && [ "$rc2" = 1 ] && printf '%s' "$out2" | grep -q 'invent_seed:'; then
  ok "lint-final.py paired-field check is symmetric (partner-only also fails, naming the missing field)"
else
  bad "lint-final.py missed a reverse-direction unpaired field (scope rc=$rc seed rc=$rc2)"
fi

# --- Test LF9: a non-UTF-8 final.md is treated as absent, not a crash --------------
# collect() reads UTF-8; a corrupt (non-UTF-8) final.md raises UnicodeDecodeError (a
# ValueError subclass) — it must degrade to the absent/valid state (exit 0), not traceback,
# so status._final_valid (which calls collect) stays crash-free on the convergence path.
NU="$TMP/lf-nonutf8"; mkdir -p "$NU/.planwright"
printf '\377\376garbage\n' > "$NU/.planwright/final.md"
rc=0; out="$(python3 "$LF" --root "$NU" --json 2>&1)" || rc=$?
if [ "$rc" = 0 ] && printf '%s' "$out" | grep -q '"present": false'; then
  ok "lint-final.py treats a non-UTF-8 final.md as absent (exit 0, no traceback)"
else
  bad "lint-final.py crashed on a non-UTF-8 final.md (rc=$rc): $out"
fi

# --- Test LF10: the whole-repo sentinel `scope: (whole-repo)` needs no scope_focus_sha --
# SKILL.md Stage 11 blesses `scope: (whole-repo)` for a whole-repo final point (no Focus
# list -> no focus sha), so the pairing check must NOT flag it — else a legitimate whole-repo
# final point reads INVALID and status._converged wrongly reports non-converged.
WR="$TMP/lf-wholerepo"; mkdir -p "$WR/.planwright"
{ _wellformed; printf 'scope: (whole-repo)\n'; } > "$WR/.planwright/final.md"   # no scope_focus_sha
rc=0; out="$(python3 "$LF" --root "$WR" --json 2>&1)" || rc=$?
if [ "$rc" = 0 ] && printf '%s' "$out" | grep -q '"ok": true'; then
  ok "lint-final.py accepts the whole-repo sentinel scope: (whole-repo) without scope_focus_sha"
else
  bad "lint-final.py wrongly flagged scope: (whole-repo) (rc=$rc): $out"
fi
