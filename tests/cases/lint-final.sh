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

# --- Test LF5b: `HEAD:` is accepted as an alias for `sha:` -------------------------
# An agent-written final.md may spell the recorded sha as `HEAD:` (SKILL.md Stage 11 calls
# it "the HEAD sha"). status._parse_final and lint-final both tolerate it, so a natural
# variant does not read as an unanchored, never-converging point (the bug that left rls-core
# stuck on codvisor). LF5 above still fails when NEITHER sha: nor HEAD: is present.
HA="$TMP/lf-head-alias"; mkdir -p "$HA/.planwright"
_wellformed | sed 's/^sha:/HEAD:/' > "$HA/.planwright/final.md"   # sha: -> HEAD:
rc=0; out="$(python3 "$LF" --root "$HA" --json)" || rc=$?
if [ "$rc" = 0 ] && printf '%s' "$out" | grep -q '"ok": true'; then
  ok "lint-final.py accepts a HEAD: alias for the sha line"
else
  bad "lint-final.py rejected a HEAD: alias final.md (rc=$rc): $out"
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

# --- Test LF9: a non-UTF-8 final.md fails closed, not a crash and not silently absent ----
# collect() reads UTF-8; a corrupt (non-UTF-8) final.md raises UnicodeDecodeError (a
# ValueError subclass). It must NOT traceback, and — per the fail-open hardening — must NOT
# masquerade as the absent/valid state: a present-but-unreadable marker fails closed
# (present:true, ok:false, exit 1) so status --exit-code refuses on a corrupt environment.
NU="$TMP/lf-nonutf8"; mkdir -p "$NU/.planwright"
printf '\377\376garbage\n' > "$NU/.planwright/final.md"
rc=0; out="$(python3 "$LF" --root "$NU" --json 2>/dev/null)" || rc=$?
if [ "$rc" != 0 ] && printf '%s' "$out" | grep -q '"present": true' \
   && printf '%s' "$out" | grep -q '"ok": false'; then
  ok "lint-final.py fails closed on a non-UTF-8 final.md (present, not ok, exit non-zero, no traceback)"
else
  bad "lint-final.py did not fail closed on a non-UTF-8 final.md (rc=$rc): $out"
fi

# --- Test LF9b: a present-but-undecodable final.md WARNS on stderr (visible degrade) -
# LF9 pins the fail-closed verdict (present:true, ok:false, exit 1); this pins that the failure
# is not SILENT. A corrupt convergence marker that exists must surface a warning, not be
# swallowed as if absent (the fail-open hardening) — while a genuinely-absent final.md stays silent.
NUW="$TMP/lf-nonutf8-warn"; mkdir -p "$NUW/.planwright"
printf '\377\376garbage\n' > "$NUW/.planwright/final.md"
rc=0; err="$(python3 "$LF" --root "$NUW" --json 2>&1 >/dev/null)" || rc=$?
if [ "$rc" != 0 ] && printf '%s' "$err" | grep -q "could not be read"; then
  ok "lint-final.py warns on a present-but-undecodable final.md (visible degrade)"
else
  bad "lint-final.py did not warn on a present-but-undecodable final.md (rc=$rc): $err"
fi
ABS="$TMP/lf-absent-silent"; mkdir -p "$ABS/.planwright"
rc=0; err="$(python3 "$LF" --root "$ABS" --json 2>&1 >/dev/null)" || rc=$?
if [ "$rc" = 0 ] && [ -z "$err" ]; then
  ok "lint-final.py stays silent on a genuinely-absent final.md"
else
  bad "lint-final.py emitted a warning for a genuinely-absent final.md (rc=$rc): $err"
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

# --- Test LF10b: a whole-repo sentinel carrying a stray scope_focus_sha must name the
# stray field, not `scope:` (which is present and correct). The generic "must co-occur"
# branch would misdirect a maintainer to fix the one good line on the convergence marker.
WRX="$TMP/lf-wholerepo-stray"; mkdir -p "$WRX/.planwright"
{ _wellformed; printf 'scope: (whole-repo)\nscope_focus_sha: deadbeef\n'; } > "$WRX/.planwright/final.md"
rc=0; out="$(python3 "$LF" --root "$WRX" --json 2>&1)" || rc=$?
if [ "$rc" = 1 ] && printf '%s' "$out" | grep -q 'scope_focus_sha' \
   && ! printf '%s' "$out" | grep -q 'must co-occur'; then
  ok "lint-final.py names scope_focus_sha (not scope) on a whole-repo point with a stray focus sha"
else
  bad "lint-final.py misdirected the stray scope_focus_sha message (rc=$rc): $out"
fi


# --- Test LF-INVENT: deepest_tier invent requires the earned-empty audits ----------
# SKILL.md Stage 11 makes invent_framings_tried (earned by breadth) and
# invent_seams_examined (earned by rigor) unconditional on a `deepest_tier: invent`.
# lint-final accepted a bare invent point, letting an ASSERTED empty certify the
# system's strongest convergence claim.
LFI="$TMP/lf-invent/.planwright"; mkdir -p "$LFI"
_lfi_base() {
  printf 'sha: abc1234567\ndate: 2026-06-09\ndeepest_tier: invent\nrepair: dry\ncoverage: dry\nopportunity: dry\nvision: dry\n'
}
# bare invent point -> both audits flagged by name
_lfi_base > "$LFI/final.md"
lfi_rc=0
lfi_out="$(python3 "$ROOT/scripts/lint-final.py" --root "$TMP/lf-invent" 2>&1)" || lfi_rc=$?
# audits present (framings inline; seams as an indented block) -> OK
{ _lfi_base
  printf 'invent_framings_tried: [comprehensive, power-user, integration, onboarding, reliability, automation]\n'
  printf 'invent_seams_examined:\n  - scripts/status.py --json — ceiling: every extension is a new subsystem\n'
} > "$LFI/final.md"
lfo_rc=0
python3 "$ROOT/scripts/lint-final.py" --root "$TMP/lf-invent" --quiet || lfo_rc=$?
# a non-invent tier never requires the audits
_lfi_base | sed 's/deepest_tier: invent/deepest_tier: expand/' > "$LFI/final.md"
lfe_rc=0
python3 "$ROOT/scripts/lint-final.py" --root "$TMP/lf-invent" --quiet || lfe_rc=$?
if [ "$lfi_rc" = 1 ] && [ "$lfo_rc" = 0 ] && [ "$lfe_rc" = 0 ] \
   && printf '%s' "$lfi_out" | grep -q 'invent_framings_tried' \
   && printf '%s' "$lfi_out" | grep -q 'invent_seams_examined'; then
  ok "lint-final requires the earned-empty audits on a deepest_tier invent point"
else
  bad "lint-final invent earned-empty gate wrong (bare=$lfi_rc with=$lfo_rc expand=$lfe_rc)"
fi

# --- Test LF11: a PRESENT but wholly-blank / whitespace-only final.md FAILs (exit 1) -
# A final.md that EXISTS but is empty (or only whitespace) is present:true but records no
# sha and no rungs. It must fail closed (ok:false, exit 1) so status --exit-code refuses to
# certify convergence on a corrupt-empty marker — distinct from LF2 (genuinely ABSENT, exit 0)
# and from LF7 (a trailing blank sha: on an otherwise-full file). The output is tiny, so the
# printf|grep here cannot SIGPIPE under pipefail.
BL="$TMP/lf-blank"; mkdir -p "$BL/.planwright"
: > "$BL/.planwright/final.md"                                  # an empty (zero-byte) present file
rc=0; out="$(python3 "$LF" --root "$BL" --json 2>&1)" || rc=$?
WS="$TMP/lf-whitespace"; mkdir -p "$WS/.planwright"
printf '   \n\t\n  \n' > "$WS/.planwright/final.md"             # whitespace-only present file
rc2=0; out2="$(python3 "$LF" --root "$WS" --json 2>&1)" || rc2=$?
if [ "$rc" = 1 ] && printf '%s' "$out" | grep -q '"present": true' \
   && printf '%s' "$out" | grep -q '"ok": false' \
   && [ "$rc2" = 1 ] && printf '%s' "$out2" | grep -q '"present": true' \
   && printf '%s' "$out2" | grep -q '"ok": false'; then
  ok "lint-final.py fails a present-but-blank/whitespace final.md (present, not ok, exit 1)"
else
  bad "lint-final.py mishandled a present-but-blank final.md (blank rc=$rc ws rc=$rc2)"
fi
