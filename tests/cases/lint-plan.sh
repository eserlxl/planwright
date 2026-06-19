# SPDX-FileCopyrightText: 2026 Eser KUBALI
# SPDX-License-Identifier: GPL-3.0-or-later
# shellcheck shell=bash
#
# lint-plan.py (Stage 10 structural gate) behavior.
# Sourced by tests/run.sh after tests/lib.sh — NOT standalone (uses ROOT/TMP/ok/bad/ver).

# --- Test 12: lint-plan.py enforces the Stage 10 structural gate -----------
# The OUTPUT FORMAT + Stage 10 + Hard rules were enforced only by the active agent reading
# prose; lint-plan.py mechanizes their machine-checkable subset. A well-formed plan
# (real Surfaces, absent New Surface) passes; a malformed one fails per-violation.
GOOD_PLAN="$TMP/good_plan.md"
cat > "$GOOD_PLAN" <<'EOF'
# planwright Plan — .
<!-- Session: x -->

- [ ] A well-formed item
      Mode: improve
      Rationale: a real reason.
      Evidence: scripts/build-graph.py:1 does X.
      Surfaces: scripts/build-graph.py, tests/run.sh
      New Surfaces: scripts/brand_new_helper.py
      Development: edit build() at the node loop.
      Acceptance: the suite stays green.
      Verification: bash tests/run.sh
EOF
if python3 "$ROOT/scripts/lint-plan.py" --root "$ROOT" --plan "$GOOD_PLAN" --quiet; then ok "lint-plan.py passes a well-formed plan"; else bad "lint-plan.py rejected a well-formed plan"; fi

# Real items wrap fields (Surfaces/Development/Evidence) across physical lines; a
# linter that false-failed on that would be worse than none. Lock the join.
WRAP_PLAN="$TMP/wrap_plan.md"
cat > "$WRAP_PLAN" <<'EOF'
# planwright Plan — .

- [ ] Item with wrapped fields
      Mode: develop
      Rationale: a reason spanning
      more than one physical line.
      Evidence: scripts/build-graph.py:69 returns names;
      docs/graph-memory-schema.md:47 documents it.
      Surfaces: scripts/build-graph.py,
      tests/run.sh
      Development: add a helper near build-graph.py:69
      and wire it into build().
      Acceptance: suite green.
      Verification: bash tests/run.sh
EOF
if python3 "$ROOT/scripts/lint-plan.py" --root "$ROOT" --plan "$WRAP_PLAN" --quiet; then ok "lint-plan.py joins wrapped multi-line fields (no false failure)"; else bad "lint-plan.py false-failed on wrapped fields"; fi

BAD_PLAN="$TMP/bad_plan.md"
cat > "$BAD_PLAN" <<'EOF'
# planwright Plan — .

- [ ] Malformed item
      Mode: frobnicate
      Evidence: see .planwright/graph.json ranked list
      Surfaces: scripts/does_not_exist.py, src/CMakeLists
      New Surfaces: tests/run.sh
      Verification:
EOF
bp_rc=0
bp_out="$(python3 "$ROOT/scripts/lint-plan.py" --root "$ROOT" --plan "$BAD_PLAN" 2>&1)" || bp_rc=$?
if [ "$bp_rc" -ne 0 ]; then ok "lint-plan.py exits non-zero on a malformed plan"; else bad "lint-plan.py accepted a malformed plan"; fi
miss=""
for needle in "missing required field 'Rationale:'" "empty field 'Verification:'" "invalid Mode 'frobnicate'" "Evidence cites graph memory" "does not exist under root" "must be spelled CMakeLists.txt" "already exists"; do
  printf '%s' "$bp_out" | grep -qF "$needle" || miss="$miss [$needle]"
done
if [ -z "$miss" ]; then ok "lint-plan.py reports every Stage 10 violation class"; else bad "lint-plan.py missed violations:$miss"; fi

# --- Test 12b: repair Evidence needs a file:line anchor; .planwright/ is not a Surface
# Two Stage 10 rules lint-plan.py mechanizes: a `repair` item must cite the wrong
# call site as file:line (bare "X is absent" is insufficient for a confirmed defect),
# and no plan item may declare a tool-owned .planwright/ path as a Surface.
REPAIR_BAD="$TMP/repair_bad_plan.md"
cat > "$REPAIR_BAD" <<'EOF'
# planwright Plan — .

- [ ] Repair without a line anchor
      Mode: repair
      Rationale: something is wrong.
      Evidence: build-graph.py swallows the error and returns the wrong value.
      Surfaces: scripts/build-graph.py, .planwright/graph.json
      Development: fix the return.
      Acceptance: correct value returned.
      Verification: bash tests/run.sh
EOF
rb_rc=0
rb_out="$(python3 "$ROOT/scripts/lint-plan.py" --root "$ROOT" --plan "$REPAIR_BAD" 2>&1)" || rb_rc=$?
miss2=""
for needle in "repair Evidence lacks a file:line anchor" "tool-owned planwright state"; do
  printf '%s' "$rb_out" | grep -qF "$needle" || miss2="$miss2 [$needle]"
done
if [ "$rb_rc" -ne 0 ] && [ -z "$miss2" ]; then ok "lint-plan.py flags anchorless repair Evidence and a .planwright/ Surface"; else bad "lint-plan.py missed repair-anchor or tool-owned-Surface violation:$miss2"; fi

# A repair item WITH a file:line anchor and clean Surfaces must pass (improve/docs
# stay exempt from the anchor rule — see GOOD_PLAN above, mode improve, no anchor needed).
REPAIR_OK="$TMP/repair_ok_plan.md"
cat > "$REPAIR_OK" <<'EOF'
# planwright Plan — .

- [ ] Repair with a proper anchor
      Mode: repair
      Rationale: wrong value on the error path.
      Evidence: scripts/build-graph.py:116 returns the keyword instead of skipping it.
      Surfaces: scripts/build-graph.py
      Development: filter the keyword at that line.
      Acceptance: keyword no longer treated as a definition.
      Verification: bash tests/run.sh
EOF
if python3 "$ROOT/scripts/lint-plan.py" --root "$ROOT" --plan "$REPAIR_OK" --quiet; then ok "lint-plan.py passes a repair item with a file:line anchor"; else bad "lint-plan.py false-failed a well-anchored repair item"; fi
# Test 11c: the gate checks ALL FIVE modes, not just develop/improve/repair. A `docs`
# item and a `reorganize` item with structural-absence Evidence (no file:line anchor)
# must pass — only `repair` requires the anchor (Stage 10 / VALID_MODES). Regression for
# qb-exported plans, which legitimately carry docs/reorganize items.
ALLMODES="$TMP/all_modes_plan.md"
cat > "$ALLMODES" <<'EOF'
# planwright Plan — .

- [ ] Document the plan export hand-off
      Mode: docs
      Rationale: the hand-off step is undocumented.
      Evidence: docs/usage.md has no section describing the plan export hand-off.
      Surfaces: docs/usage.md
      Development: add a hand-off subsection.
      Acceptance: the hand-off is documented.
      Verification: bash tests/run.sh

- [ ] Split parsing from metrics in build-graph
      Mode: reorganize
      Rationale: parsing and metric computation live in one module.
      Evidence: scripts/build-graph.py combines import parsing and metric computation in one file.
      Surfaces: scripts/build-graph.py
      Development: group the metric helpers into their own section.
      Acceptance: behavior preserved, layout clearer.
      Verification: bash tests/run.sh
EOF
if python3 "$ROOT/scripts/lint-plan.py" --root "$ROOT" --plan "$ALLMODES" --quiet; then ok "lint-plan.py accepts docs + reorganize items with structural-absence Evidence (anchor is repair-only; gate checks all five modes)"; else bad "lint-plan.py false-failed a valid docs/reorganize item (gate must check all five modes)"; fi
# A pending item with all eight fields and no path issues must pass; the same item
# completed (- [x]) is skipped by default and only checked under --all.
DONE_PLAN="$TMP/done_plan.md"
sed 's/- \[ \]/- [x]/' "$BAD_PLAN" > "$DONE_PLAN"
if python3 "$ROOT/scripts/lint-plan.py" --root "$ROOT" --plan "$DONE_PLAN" --quiet; then ok "lint-plan.py skips completed items by default"; else bad "lint-plan.py linted a completed item without --all"; fi
if python3 "$ROOT/scripts/lint-plan.py" --root "$ROOT" --plan "$DONE_PLAN" --all --quiet; then bad "lint-plan.py --all ignored a completed item"; else ok "lint-plan.py --all also lints completed items"; fi
# An absent plan file is not an error (nothing to lint).
if python3 "$ROOT/scripts/lint-plan.py" --root "$ROOT" --plan "$TMP/nope.md" --quiet; then ok "lint-plan.py treats an absent plan as clean"; else bad "lint-plan.py errored on an absent plan file"; fi

# --- Test 12b: --root resolves the DEFAULT plan path under root, not the caller's cwd
# Regression: an adapter run from a foreign cwd with only --root must lint THAT root's
# plan. The old default '.planwright/plan.md' was cwd-relative, so a missing-here plan
# exited clean (0) and silently bypassed the gate while the target plan was invalid.
FR="$TMP/foreign-root"; mkdir -p "$FR/.planwright"
cat > "$FR/.planwright/plan.md" <<'EOF'
# planwright Plan — foreign

- [ ] An item missing its Verification field
      Mode: improve
      Rationale: a real reason.
      Evidence: scripts/build-graph.py exists.
      Surfaces: scripts/build-graph.py
      Development: edit build().
      Acceptance: stays green.
EOF
CWD_NOPLAN="$TMP/cwd-without-plan"; mkdir -p "$CWD_NOPLAN"
fr_rc=0
( cd "$CWD_NOPLAN" && python3 "$ROOT/scripts/lint-plan.py" --root "$FR" --quiet ) || fr_rc=$?
if [ "$fr_rc" -ne 0 ]; then ok "lint-plan.py --root resolves the default plan under root from a foreign cwd"; else bad "lint-plan.py --root linted nothing from a foreign cwd (default plan not resolved under root)"; fi

# --- Test 12d: unsafe_surface containment is filesystem-root-safe ------------------
# Regression: the check used `full.startswith(rootn + os.sep)`, so when root resolves to
# "/" (a repo cloned at a filesystem/drive root) every "/x" path failed containment
# (startswith("//")) and the gate rejected valid in-repo Surfaces. commonpath fixes it.
if python3 - "$ROOT/scripts/lint-plan.py" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("lp", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
# A relative surface under a filesystem-root repo is contained (None), not rejected.
assert m.unsafe_surface("scripts/x.py", "/") is None, "filesystem-root containment rejected a valid surface"
# Sanity: normal containment passes; absolute / traversal are still rejected.
assert m.unsafe_surface("scripts/x.py", "/repo") is None
assert m.unsafe_surface("/etc/hosts", "/repo") is not None
assert m.unsafe_surface("../outside", "/repo") is not None
PY
then ok "lint-plan.py unsafe_surface containment is safe at a filesystem root"
else bad "lint-plan.py unsafe_surface mishandles a filesystem-root repo"; fi

# --- Test 12e: lint-plan.py --fix is idempotent on a double-violation item ----------
# An item carrying BOTH mechanical violations (a 'CMakeLists' Surface to respell AND an
# existing New Surface to move) must reach a fixed point: a second --fix is a no-op and
# the result lints clean. Guards against one auto-correction reintroducing the other.
FX="$TMP/fix-idem"; mkdir -p "$FX"
: > "$FX/CMakeLists.txt"
: > "$FX/existing.py"
FXP="$FX/plan.md"
cat > "$FXP" <<'EOF'
# planwright Plan — fix-idem

- [ ] Double-violation item
      Mode: improve
      Rationale: a real reason.
      Evidence: CMakeLists.txt configures the build.
      Surfaces: CMakeLists
      New Surfaces: existing.py
      Development: edit the build wiring.
      Acceptance: stays green.
      Verification: bash tests/run.sh
EOF
python3 "$ROOT/scripts/lint-plan.py" --root "$FX" --plan "$FXP" --fix --quiet >/dev/null 2>&1 || true
after1="$(cat "$FXP")"
fx2_out="$(python3 "$ROOT/scripts/lint-plan.py" --root "$FX" --plan "$FXP" --fix 2>&1)" || true
after2="$(cat "$FXP")"
if [ "$after1" = "$after2" ] \
   && printf '%s' "$after1" | grep -q 'Surfaces: CMakeLists.txt, existing.py' \
   && ! printf '%s' "$after1" | grep -q 'New Surfaces:' \
   && ! printf '%s' "$fx2_out" | grep -qi 'applied' \
   && ! find "$FX" -name '.lint-plan-*.tmp' 2>/dev/null | grep -q . \
   && python3 "$ROOT/scripts/lint-plan.py" --root "$FX" --plan "$FXP" --quiet; then
  ok "lint-plan.py --fix is idempotent on a double-violation item (second pass is a no-op)"
else
  bad "lint-plan.py --fix not idempotent on a double-violation item: $fx2_out"
fi

# --- Test 12f: --fix recognizes the `Surfaces :` (space-before-colon) field spelling -
# field_spans() (the --fix path) must mirror parse_items() exactly. The parser tolerates a
# space before the colon (plan_parse._FIELD_RE strips it); the fixer's FIELD_RE must too, or
# --fix prints "no auto-fixable violations" and rewrites nothing on a plan the linter flags.
FXS="$TMP/fix-spaced-colon"; mkdir -p "$FXS"
: > "$FXS/CMakeLists.txt"
: > "$FXS/existing.py"
FXSP="$FXS/plan.md"
cat > "$FXSP" <<'EOF'
# planwright Plan — fix-spaced-colon

- [ ] Spaced-colon double-violation item
      Mode : improve
      Rationale : a real reason.
      Evidence : CMakeLists.txt configures the build.
      Surfaces : CMakeLists
      New Surfaces : existing.py
      Development : edit the build wiring.
      Acceptance : stays green.
      Verification : bash tests/run.sh
EOF
python3 "$ROOT/scripts/lint-plan.py" --root "$FXS" --plan "$FXSP" --fix --quiet >/dev/null 2>&1 || true
fxs_after="$(cat "$FXSP")"
# The fixer recognizes the spaced spelling on input but normalizes the rewritten field to
# canonical `Surfaces:` (lint-plan.py:460), respelling CMakeLists.txt and folding the moved
# New Surface in. Before the FIELD_RE fix, field_spans saw no fields, --fix was a no-op, and
# this plan still lint-failed (CMakeLists/.txt + existing New Surface).
if printf '%s' "$fxs_after" | grep -q 'Surfaces: CMakeLists.txt, existing.py' \
   && ! printf '%s' "$fxs_after" | grep -q 'New Surfaces' \
   && python3 "$ROOT/scripts/lint-plan.py" --root "$FXS" --plan "$FXSP" --quiet; then
  ok "lint-plan.py --fix recognizes the 'Surfaces :' space-before-colon spelling (mirrors the parser)"
else
  bad "lint-plan.py --fix did not auto-fix a space-before-colon plan: $fxs_after"
fi

# --- Test 12c: lint-plan.py rejects a placeholder Verification value ---------
# Verification must be a runnable command; a bare "TODO"/"manual"/"n/a" passes the
# non-empty check but is unverifiable, so lint-plan flags it before execute wastes a
# cycle. A real command that merely contains such a word must NOT be flagged.
PH_PLAN="$TMP/placeholder_plan.md"
cat > "$PH_PLAN" <<'EOF'
# planwright Plan — .

- [ ] Item with a placeholder verification
      Mode: improve
      Rationale: r.
      Evidence: scripts/lint-plan.py exists.
      Surfaces: scripts/lint-plan.py
      Development: edit lint_item().
      Acceptance: green.
      Verification: TODO
EOF
ph_rc=0
ph_out="$(python3 "$ROOT/scripts/lint-plan.py" --root "$ROOT" --plan "$PH_PLAN" 2>&1)" || ph_rc=$?
if [ "$ph_rc" -ne 0 ] && printf '%s' "$ph_out" | grep -qF "is a placeholder"; then ok "lint-plan.py rejects a placeholder Verification (TODO)"; else bad "lint-plan.py accepted a placeholder Verification"; fi
PH_OK="$TMP/placeholder_ok_plan.md"
cat > "$PH_OK" <<'EOF'
# planwright Plan — .

- [ ] Item with a real verification that mentions manual
      Mode: improve
      Rationale: r.
      Evidence: scripts/lint-plan.py exists.
      Surfaces: scripts/lint-plan.py
      Development: edit lint_item().
      Acceptance: green.
      Verification: manual smoke test then bash tests/run.sh
EOF
if python3 "$ROOT/scripts/lint-plan.py" --root "$ROOT" --plan "$PH_OK" --quiet; then ok "lint-plan.py allows a real command that contains a placeholder word"; else bad "lint-plan.py false-flagged a real Verification command"; fi

# --- Test 12d: an all-dots "..." Verification is a placeholder, not a command ----
# rstrip(".") collapses "..." to "", so a naive `norm in PLACEHOLDER_VERIFICATION`
# test silently passed the documented "..." placeholder; an empty normalization must
# also count as a placeholder.
PH_DOTS="$TMP/placeholder_dots_plan.md"
cat > "$PH_DOTS" <<'EOF'
# planwright Plan — .

- [ ] Item with an ellipsis verification
      Mode: improve
      Rationale: r.
      Evidence: scripts/lint-plan.py exists.
      Surfaces: scripts/lint-plan.py
      Development: edit lint_item().
      Acceptance: green.
      Verification: ...
EOF
pd_rc=0
pd_out="$(python3 "$ROOT/scripts/lint-plan.py" --root "$ROOT" --plan "$PH_DOTS" 2>&1)" || pd_rc=$?
if [ "$pd_rc" -ne 0 ] && printf '%s' "$pd_out" | grep -qF "is a placeholder"; then ok "lint-plan.py rejects an all-dots '...' Verification placeholder"; else bad "lint-plan.py accepted an all-dots '...' Verification"; fi

# --- Test 12h: prose Verification (no command signal, unknown first token) -------
# Beyond the fixed PLACEHOLDER_VERIFICATION set, is_prose_verification() flags a
# multi-word value that carries no command-signal char AND whose first token is not a
# known runner — "verify the output manually" is just as unrunnable as "TODO". The
# guard must fire in BOTH directions: flag prose, but never a real two-word command
# whose first token is a known runner (e.g. "make test" has no signal char yet is real).
PH_PROSE="$TMP/prose_plan.md"
cat > "$PH_PROSE" <<'EOF'
# planwright Plan — .

- [ ] Item with a prose verification
      Mode: improve
      Rationale: r.
      Evidence: scripts/lint-plan.py exists.
      Surfaces: scripts/lint-plan.py
      Development: edit lint_item().
      Acceptance: green.
      Verification: verify the output manually
EOF
pp_rc=0
pp_out="$(python3 "$ROOT/scripts/lint-plan.py" --root "$ROOT" --plan "$PH_PROSE" 2>&1)" || pp_rc=$?
if [ "$pp_rc" -ne 0 ] && printf '%s' "$pp_out" | grep -qF "reads as prose"; then ok "lint-plan.py rejects a prose Verification (no runnable command)"; else bad "lint-plan.py accepted a prose Verification"; fi
PH_MAKE="$TMP/make_test_plan.md"
cat > "$PH_MAKE" <<'EOF'
# planwright Plan — .

- [ ] Item with a real two-word command verification
      Mode: improve
      Rationale: r.
      Evidence: scripts/lint-plan.py exists.
      Surfaces: scripts/lint-plan.py
      Development: edit lint_item().
      Acceptance: green.
      Verification: make test
EOF
if python3 "$ROOT/scripts/lint-plan.py" --root "$ROOT" --plan "$PH_MAKE" --quiet; then ok "lint-plan.py allows a real two-word command (known runner, no signal char)"; else bad "lint-plan.py false-flagged 'make test' as prose"; fi

# --- Test 12e: a Surface must be a safe repo-relative path -----------------------
# os.path.join(root, p) discards root for an absolute p, so `/etc/hosts` would pass a
# bare existence check; `../foo` can also resolve to a real file outside the repo.
# Since execute treats Surfaces as its edit boundary, both must be rejected before the
# existence check — for Surfaces AND New Surfaces. A normal in-repo relative path that
# happens not to exist must still fall through to the ordinary "does not exist" message
# (the new gate must not swallow the existing one).
SAFE_DIR="$TMP/safesub"
mkdir -p "$SAFE_DIR/.planwright"
# A real file in the repo PARENT, reachable only via traversal, to prove `..` escape is
# blocked structurally rather than by the file merely being absent.
echo "x" > "$TMP/outside.txt"
US_PLAN="$SAFE_DIR/.planwright/plan.md"
cat > "$US_PLAN" <<'EOF'
# planwright Plan — .

- [ ] Absolute Surface escapes the repo
      Mode: repair
      Rationale: r.
      Evidence: wrong value at /etc/hosts:1.
      Surfaces: /etc/hosts
      Development: edit it.
      Acceptance: green.
      Verification: bash tests/run.sh

- [ ] Parent-traversal Surface escapes the repo
      Mode: improve
      Rationale: r.
      Evidence: gap.
      Surfaces: ../outside.txt
      Development: edit it.
      Acceptance: green.
      Verification: bash tests/run.sh

- [ ] Absolute New Surface escapes the repo
      Mode: develop
      Rationale: r.
      Evidence: signal foo().
      Surfaces: .planwright/plan.md
      New Surfaces: /tmp/pw-evil.txt
      Development: edit it.
      Acceptance: green.
      Verification: bash tests/run.sh
EOF
us_rc=0
us_out="$(python3 "$ROOT/scripts/lint-plan.py" --root "$SAFE_DIR" --plan "$US_PLAN" 2>&1)" || us_rc=$?
if [ "$us_rc" -ne 0 ] \
   && printf '%s' "$us_out" | grep -qF "Surface '/etc/hosts' is not a safe repo-relative path: absolute path" \
   && printf '%s' "$us_out" | grep -qF "Surface '../outside.txt' is not a safe repo-relative path: parent-directory traversal" \
   && printf '%s' "$us_out" | grep -qF "New Surface '/tmp/pw-evil.txt' is not a safe repo-relative path: absolute path"; then
  ok "lint-plan.py rejects absolute / parent-traversal Surfaces and New Surfaces"
else
  bad "lint-plan.py did not reject an out-of-repo Surface/New Surface"
fi
# Regression guard: a normal in-repo relative path that is simply missing must still get
# the ordinary existence error, not be swallowed or mislabeled by the safety gate.
US_REL="$SAFE_DIR/.planwright/rel.md"
cat > "$US_REL" <<'EOF'
# planwright Plan — .

- [ ] In-repo relative Surface that does not exist
      Mode: improve
      Rationale: r.
      Evidence: gap.
      Surfaces: src/nope.py
      Development: edit it.
      Acceptance: green.
      Verification: bash tests/run.sh
EOF
ur_out="$(python3 "$ROOT/scripts/lint-plan.py" --root "$SAFE_DIR" --plan "$US_REL" 2>&1)" || true
if printf '%s' "$ur_out" | grep -qF "Surface 'src/nope.py' does not exist under root" \
   && ! printf '%s' "$ur_out" | grep -qF "not a safe repo-relative path"; then
  ok "lint-plan.py still reports a plain missing in-repo Surface as non-existent (gate is additive)"
else
  bad "lint-plan.py mislabeled a normal missing relative Surface"
fi

# Symlink-escape guard: unsafe_surface uses realpath (not normpath) so a Surface
# reachable only through an in-repo symlink that points outside the root is rejected.
# normpath would leave the symlink unresolved and let `link/secret` pass the containment
# check, so this pins the realpath choice specifically.
SLREPO="$TMP/sl_repo"; mkdir -p "$SLREPO/.planwright"
SLOUT="$TMP/sl_outside"; mkdir -p "$SLOUT"; echo "secret" > "$SLOUT/secret"
ln -sf "$SLOUT" "$SLREPO/link"   # in-repo symlink escaping the root
SL_PLAN="$SLREPO/.planwright/plan.md"
cat > "$SL_PLAN" <<'EOF'
# planwright Plan — .

- [ ] Surface escapes the root through an in-repo symlink
      Mode: improve
      Rationale: r.
      Evidence: gap.
      Surfaces: link/secret
      Development: edit it.
      Acceptance: green.
      Verification: bash tests/run.sh
EOF
sl_rc=0
sl_out="$(python3 "$ROOT/scripts/lint-plan.py" --root "$SLREPO" --plan "$SL_PLAN" 2>&1)" || sl_rc=$?
if [ "$sl_rc" -ne 0 ] && printf '%s' "$sl_out" | grep -qF "resolves outside the repo root"; then
  ok "lint-plan.py rejects a Surface that escapes the root via an in-repo symlink"
else
  bad "lint-plan.py accepted a symlink-escaping Surface (rc=$sl_rc)"
fi

# Convergence guards: a repeated pending title and a Surfaces/New-Surfaces overlap
# are always violations (hard fail). The lifecycle dir holds the advisory sources.
LDIR="$TMP/lintdir"
mkdir -p "$LDIR"
printf '# completed\n\n- [x] A finished thing\n' > "$LDIR/completed.md"
printf '# rejected\n\n- [x] A doomed thing\n      Rejection: nope\n' > "$LDIR/rejected.md"
cat > "$LDIR/plan.md" <<EOF
# planwright Plan — .

- [ ] A finished thing
      Mode: improve
      Rationale: r.
      Evidence: $ROOT/scripts/lint-plan.py exists.
      Surfaces: scripts/lint-plan.py
      New Surfaces: scripts/lint-plan.py
      Development: edit main().
      Acceptance: green.
      Verification: bash tests/run.sh

- [ ] A finished thing
      Mode: improve
      Rationale: r.
      Evidence: build-graph exists.
      Surfaces: scripts/build-graph.py
      Development: edit build().
      Acceptance: green.
      Verification: bash tests/run.sh

- [ ] A doomed thing
      Mode: improve
      Rationale: r.
      Evidence: tests exist.
      Surfaces: tests/run.sh
      Development: edit it.
      Acceptance: green.
      Verification: bash tests/run.sh
EOF
ld_rc=0
ld_out="$(python3 "$ROOT/scripts/lint-plan.py" --root "$ROOT" --plan "$LDIR/plan.md" 2>&1)" || ld_rc=$?
if [ "$ld_rc" -ne 0 ]; then ok "lint-plan.py fails on convergence violations"; else bad "lint-plan.py passed a plan with dup title + Surfaces overlap"; fi
if printf '%s' "$ld_out" | grep -qF "duplicate pending title: 'A finished thing'"; then ok "lint-plan.py flags a duplicate pending title"; else bad "lint-plan.py missed a duplicate pending title"; fi
if printf '%s' "$ld_out" | grep -qF "both Surfaces and New Surfaces"; then ok "lint-plan.py flags a Surfaces/New-Surfaces overlap"; else bad "lint-plan.py missed a Surfaces/New-Surfaces overlap"; fi

# Regression: --all widens `items` to include completed history, but the dup-title
# guard must scan PENDING items only. Two completed twins (or a pending/completed
# overlap) are legitimate history and must NOT be reported as a "duplicate pending
# title"; only genuinely repeated PENDING titles hard-fail.
ADIR="$TMP/lintall"
mkdir -p "$ADIR"
cat > "$ADIR/plan.md" <<EOF
# planwright Plan — .

- [x] Twin completed
      Mode: improve
      Rationale: r.
      Evidence: scripts/lint-plan.py exists.
      Surfaces: scripts/lint-plan.py
      Development: edit main().
      Acceptance: green.
      Verification: bash tests/run.sh

- [x] Twin completed
      Mode: improve
      Rationale: r.
      Evidence: scripts/build-graph.py exists.
      Surfaces: scripts/build-graph.py
      Development: edit build().
      Acceptance: green.
      Verification: bash tests/run.sh
EOF
la_out="$(python3 "$ROOT/scripts/lint-plan.py" --root "$ROOT" --plan "$ADIR/plan.md" --all 2>&1)" || true
if printf '%s' "$la_out" | grep -qF "duplicate pending title"; then bad "lint-plan.py --all mislabels two completed twins as a duplicate pending title"; else ok "lint-plan.py --all does not flag completed twins as a duplicate pending title"; fi

cat > "$ADIR/plan2.md" <<EOF
# planwright Plan — .

- [ ] Pending twin
      Mode: improve
      Rationale: r.
      Evidence: scripts/lint-plan.py exists.
      Surfaces: scripts/lint-plan.py
      Development: edit main().
      Acceptance: green.
      Verification: bash tests/run.sh

- [ ] Pending twin
      Mode: improve
      Rationale: r.
      Evidence: scripts/build-graph.py exists.
      Surfaces: scripts/build-graph.py
      Development: edit build().
      Acceptance: green.
      Verification: bash tests/run.sh
EOF
lp_rc=0
lp_out="$(python3 "$ROOT/scripts/lint-plan.py" --root "$ROOT" --plan "$ADIR/plan2.md" --all 2>&1)" || lp_rc=$?
if [ "$lp_rc" -ne 0 ] && printf '%s' "$lp_out" | grep -qF "duplicate pending title: 'Pending twin'"; then ok "lint-plan.py --all still flags two genuinely pending duplicate titles"; else bad "lint-plan.py --all missed a real pending duplicate under --all"; fi

# --- Test 12d-strict: --strict promotes a re-proposal advisory to a failure -------
# A well-formed plan whose only issue is a pending title matching a completed item is
# an advisory (does NOT fail by default), so a CI gate cannot catch an accidental
# re-proposal. --strict promotes such advisories to failures (exit 1) to enforce the
# monotonic-drain guarantee; without it the same plan stays clean (exit 0).
SDIR="$TMP/strictdir"; mkdir -p "$SDIR"
printf '# completed\n\n- [x] Reuse me\n' > "$SDIR/completed.md"
cat > "$SDIR/plan.md" <<EOF
# planwright Plan — .

- [ ] Reuse me
      Mode: improve
      Rationale: r.
      Evidence: scripts/lint-plan.py exists.
      Surfaces: scripts/lint-plan.py
      Development: edit main().
      Acceptance: green.
      Verification: bash tests/run.sh
EOF
st_def=0; python3 "$ROOT/scripts/lint-plan.py" --root "$ROOT" --plan "$SDIR/plan.md" --quiet || st_def=$?
st_strict=0; python3 "$ROOT/scripts/lint-plan.py" --root "$ROOT" --plan "$SDIR/plan.md" --strict --quiet || st_strict=$?
if [ "$st_def" = 0 ] && [ "$st_strict" = 1 ]; then
  ok "lint-plan.py --strict promotes a re-proposal advisory to a failure (default stays clean)"
else
  bad "lint-plan.py --strict wrong (default=$st_def strict=$st_strict)"
fi

# --- Test 12d-strict-rej: --strict also promotes a *rejected*-match advisory --------
# 12d-strict covers a completed-match; the monotonic-drain guard also advises when a
# pending title matches a rejected.md entry. A clean pending item matching a rejected
# title must be an advisory by default (exit 0) and a failure under --strict (exit 1).
SDIRR="$TMP/strictdir_rej"; mkdir -p "$SDIRR"
printf '# rejected\n\n- [x] Doomed twice\n      Rejection: value-gate: no consumer\n' > "$SDIRR/rejected.md"
cat > "$SDIRR/plan.md" <<EOF
# planwright Plan — .

- [ ] Doomed twice
      Mode: improve
      Rationale: r.
      Evidence: scripts/lint-plan.py exists.
      Surfaces: scripts/lint-plan.py
      Development: edit main().
      Acceptance: green.
      Verification: bash tests/run.sh
EOF
sr_def=0; python3 "$ROOT/scripts/lint-plan.py" --root "$ROOT" --plan "$SDIRR/plan.md" --quiet || sr_def=$?
sr_strict=0; python3 "$ROOT/scripts/lint-plan.py" --root "$ROOT" --plan "$SDIRR/plan.md" --strict --quiet || sr_strict=$?
if [ "$sr_def" = 0 ] && [ "$sr_strict" = 1 ]; then
  ok "lint-plan.py --strict promotes a rejected-match advisory to a failure (default stays clean)"
else
  bad "lint-plan.py --strict rejected-match wrong (default=$sr_def strict=$sr_strict)"
fi

# --- Test 12d-strict-anchor: --strict promotes a NON-repair ghost/out-of-range anchor -
# The Mode-keyed Evidence-anchor severity split (lint-plan.py lint_item) makes a ghost or
# out-of-range anchor a FAILING violation only on a `repair` item (Test 12b pins that leg);
# on every other Mode it is a non-failing advisory. This pins the NON-repair leg: a
# `develop` item citing a non-existent path AND an out-of-range line on a real file stays
# clean by default (exit 0) and fails under --strict (exit 1, advisory promoted).
SDIRA="$TMP/strictdir_anchor"; mkdir -p "$SDIRA"
cat > "$SDIRA/plan.md" <<EOF
# planwright Plan — .

- [ ] Develop citing a ghost and an out-of-range anchor
      Mode: develop
      Rationale: r.
      Evidence: scripts/ghost_does_not_exist.py:99999 and scripts/lint-plan.py:99999 are cited but unresolvable.
      Surfaces: scripts/lint-plan.py
      Development: edit main().
      Acceptance: green.
      Verification: bash tests/run.sh
EOF
sa_def=0; python3 "$ROOT/scripts/lint-plan.py" --root "$ROOT" --plan "$SDIRA/plan.md" --quiet || sa_def=$?
sa_strict=0; python3 "$ROOT/scripts/lint-plan.py" --root "$ROOT" --plan "$SDIRA/plan.md" --strict --quiet || sa_strict=$?
if [ "$sa_def" = 0 ] && [ "$sa_strict" = 1 ]; then
  ok "lint-plan.py --strict promotes a non-repair ghost/out-of-range Evidence anchor to a failure (default stays clean)"
else
  bad "lint-plan.py --strict non-repair anchor wrong (default=$sa_def strict=$sa_strict)"
fi

# --- Test 12e: lint-plan.py --scope mechanizes the Stage 10 Surfaces-in-Focus gate
# Reads the builder's focus/context sets: a Surface in Focus passes; an out-of-Focus
# existing Surface fails (a non-repair in Context, or anything outside Context); a
# repair Surface one hop upstream (Context) is a non-failing advisory. No-op without
# --scope or when the graph's focus is empty (a whole-repo build).
SCG="$TMP/scope_focus.json"
printf '{"focus": ["scripts/lint-plan.py"], "context": ["scripts/lint-plan.py", "scripts/build-graph.py"]}\n' > "$SCG"
SCG_WHOLE="$TMP/scope_whole.json"
printf '{"focus": [], "context": []}\n' > "$SCG_WHOLE"

# Plan A: an in-Focus item + an upstream repair (Context) => exit 0 with an advisory
SCP_OK="$TMP/scope_ok_plan.md"
cat > "$SCP_OK" <<'EOF'
# planwright Plan — .

- [ ] An in-focus item
      Mode: improve
      Rationale: r.
      Evidence: scripts/lint-plan.py exists.
      Surfaces: scripts/lint-plan.py
      Development: edit main().
      Acceptance: green.
      Verification: bash tests/run.sh

- [ ] An upstream root-cause repair
      Mode: repair
      Rationale: r.
      Evidence: scripts/lint-plan.py:1 mis-handles a value build-graph returns at scripts/build-graph.py:1.
      Surfaces: scripts/build-graph.py
      Development: fix the caller.
      Acceptance: green.
      Verification: bash tests/run.sh
EOF
sco_rc=0
sco_out="$(python3 "$ROOT/scripts/lint-plan.py" --root "$ROOT" --plan "$SCP_OK" --scope "$SCG" 2>&1)" || sco_rc=$?
if [ "$sco_rc" -eq 0 ] && printf '%s' "$sco_out" | grep -qF "upstream of Focus (Context)"; then ok "lint-plan.py --scope passes in-Focus + advises an upstream repair (non-failing)"; else bad "lint-plan.py --scope mishandled in-Focus/upstream-repair (rc=$sco_rc)"; fi

# The same upstream-of-Focus (Context) advisory is a non-failing note by default (above),
# but --strict promotes it to a failure (exit 1) so a CI scope gate catches it.
sco_strict=0
python3 "$ROOT/scripts/lint-plan.py" --root "$ROOT" --plan "$SCP_OK" --scope "$SCG" --strict --quiet || sco_strict=$?
if [ "$sco_strict" -eq 1 ]; then ok "lint-plan.py --strict promotes the --scope upstream-repair advisory to a failure"; else bad "lint-plan.py --scope --strict did not promote the upstream advisory (rc=$sco_strict)"; fi

# Plan C: an in-Focus Surface written non-canonically (./ prefix) must pass --scope just
# like the bare path — focus is a canonical git-ls-files set, so scope_check normalizes the
# Surface before membership (lint_item already accepts ./scripts/lint-plan.py).
SCP_NC="$TMP/scope_noncanon_plan.md"
cat > "$SCP_NC" <<'EOF'
# planwright Plan — .

- [ ] A non-canonically-spelled in-focus item
      Mode: improve
      Rationale: r.
      Evidence: scripts/lint-plan.py exists.
      Surfaces: ./scripts/lint-plan.py
      Development: edit main().
      Acceptance: green.
      Verification: bash tests/run.sh
EOF
scnc_rc=0
scnc_out="$(python3 "$ROOT/scripts/lint-plan.py" --root "$ROOT" --plan "$SCP_NC" --scope "$SCG" 2>&1)" || scnc_rc=$?
if [ "$scnc_rc" -eq 0 ] && ! printf '%s' "$scnc_out" | grep -qF "outside the scoped component"; then ok "lint-plan.py --scope accepts a non-canonical in-Focus Surface (./x) like the bare path"; else bad "lint-plan.py --scope false-failed a non-canonical in-Focus Surface (rc=$scnc_rc): $scnc_out"; fi

# Plan B: a non-repair Context Surface + an out-of-scope Surface => two violations
SCP_BAD="$TMP/scope_bad_plan.md"
cat > "$SCP_BAD" <<'EOF'
# planwright Plan — .

- [ ] A non-repair touching Context
      Mode: improve
      Rationale: r.
      Evidence: scripts/build-graph.py exists.
      Surfaces: scripts/build-graph.py
      Development: edit build().
      Acceptance: green.
      Verification: bash tests/run.sh

- [ ] An out-of-scope item
      Mode: improve
      Rationale: r.
      Evidence: tests/run.sh exists.
      Surfaces: tests/run.sh
      Development: edit it.
      Acceptance: green.
      Verification: bash tests/run.sh
EOF
scb_rc=0
scb_out="$(python3 "$ROOT/scripts/lint-plan.py" --root "$ROOT" --plan "$SCP_BAD" --scope "$SCG" 2>&1)" || scb_rc=$?
scb_miss=""
printf '%s' "$scb_out" | grep -qF "in Context but not Focus" || scb_miss="$scb_miss context-nonrepair"
printf '%s' "$scb_out" | grep -qF "outside the scoped component" || scb_miss="$scb_miss outside-scope"
if [ "$scb_rc" -ne 0 ] && [ -z "$scb_miss" ]; then ok "lint-plan.py --scope fails a non-repair Context Surface and an out-of-scope Surface"; else bad "lint-plan.py --scope missed scope violations:$scb_miss (rc=$scb_rc)"; fi

# No-op guarantees: same plan passes without --scope, and with a whole-repo (empty-focus) graph
if python3 "$ROOT/scripts/lint-plan.py" --root "$ROOT" --plan "$SCP_BAD" --quiet; then ok "lint-plan.py without --scope ignores Focus (default lint unchanged)"; else bad "lint-plan.py false-failed the scope plan without --scope"; fi
if python3 "$ROOT/scripts/lint-plan.py" --root "$ROOT" --plan "$SCP_BAD" --scope "$SCG_WHOLE" --quiet; then ok "lint-plan.py --scope is a no-op on a whole-repo (empty-focus) graph"; else bad "lint-plan.py --scope wrongly enforced on an empty-focus graph"; fi
# A corrupt (non-object / wrong-shape) --scope graph must no-op (no scope active), not crash:
# the same SCP_BAD plan (clean without scope) still passes, and the linter exits cleanly.
scp_corrupt_ok=1
for sg in '[]' '42' '{"focus": 5}'; do
  SCG_BAD="$TMP/scope_corrupt.json"; printf '%s\n' "$sg" > "$SCG_BAD"
  python3 "$ROOT/scripts/lint-plan.py" --root "$ROOT" --plan "$SCP_BAD" --scope "$SCG_BAD" --quiet || scp_corrupt_ok=0
done
if [ "$scp_corrupt_ok" -eq 1 ]; then ok "lint-plan.py --scope no-ops on a corrupt scope graph (not a crash)"; else bad "lint-plan.py --scope crashed or enforced on a corrupt scope graph"; fi
if printf '%s' "$ld_out" | grep -qF "matches a completed item"; then ok "lint-plan.py notes a re-proposed completed item (advisory)"; else bad "lint-plan.py missed the completed-item advisory"; fi
if printf '%s' "$ld_out" | grep -qF "matches a rejected item"; then ok "lint-plan.py notes a re-proposed rejected item (advisory)"; else bad "lint-plan.py missed the rejected-item advisory"; fi
# Advisory matches alone (no structural violation) must NOT fail the gate.
ADV="$TMP/advdir"
mkdir -p "$ADV"
printf '# completed\n\n- [x] Legit regression refix\n' > "$ADV/completed.md"
cat > "$ADV/plan.md" <<'EOF'
# planwright Plan — .

- [ ] Legit regression refix
      Mode: repair
      Rationale: a regression returned.
      Evidence: scripts/build-graph.py:1 now returns the wrong value.
      Surfaces: scripts/build-graph.py
      Development: fix build().
      Acceptance: green.
      Verification: bash tests/run.sh
EOF
adv_rc=0
adv_out="$(python3 "$ROOT/scripts/lint-plan.py" --root "$ROOT" --plan "$ADV/plan.md" 2>&1)" || adv_rc=$?
if [ "$adv_rc" -eq 0 ] && printf '%s' "$adv_out" | grep -qF "matches a completed item"; then ok "lint-plan.py advisory note alone does not fail the gate"; else bad "lint-plan.py advisory wrongly failed the gate (or note missing)"; fi

# --- Test 12f: lint-plan.py --json emits one clean JSON doc with accurate counts --
# --json must print a single parseable JSON document (no leading text-mode note/
# violation lines), and total_advisories must equal the advisories actually listed
# in items[] — including under --quiet, where the count must not silently drop to 0.
# Reuses $ADV/plan.md (a clean item whose title matches an $ADV completed.md entry,
# i.e. exactly one advisory).
for jflag in "" "--quiet"; do
  if python3 "$ROOT/scripts/lint-plan.py" --root "$ROOT" --plan "$ADV/plan.md" --json $jflag \
     | python3 -c '
import json, sys
d = json.load(sys.stdin)                       # raises if stdout is not pure JSON
listed = sum(len(i["advisories"]) for i in d["items"])
assert d["total_advisories"] == listed, (d["total_advisories"], listed)
assert d["total_advisories"] >= 1              # the completed-title match
' 2>/dev/null
  then ok "lint-plan.py --json $jflag is parseable and total_advisories matches items[]"
  else bad "lint-plan.py --json $jflag emitted non-JSON or a mismatched advisory count"; fi
done

# --- Test 12f: lint-plan.py --fix auto-corrects the two mechanical violations ---
# --fix rewrites IN PLACE only the unambiguous, filesystem-verifiable violations:
# a CMakeLists surface is respelled CMakeLists.txt, and a New Surface that already
# exists is moved to Surfaces (it cannot be a *new* file). Everything else is left for
# the agent. Untouched items must stay byte-identical and the fix must be idempotent.
FIXROOT="$TMP/fixroot"; mkdir -p "$FIXROOT/.planwright" "$FIXROOT/src" "$FIXROOT/include"
: > "$FIXROOT/src/foo.c"; : > "$FIXROOT/include/bar.h"; : > "$FIXROOT/CMakeLists.txt"
FIXPLAN="$FIXROOT/.planwright/plan.md"
cat > "$FIXPLAN" <<'EOF'
# planwright Plan — .
<!-- Session: x -->

- [ ] Wire the build target
      Mode: develop
      Rationale: the target is unbuilt.
      Evidence: src/foo.c:1 lacks a build rule
      Surfaces: src/foo.c, CMakeLists
      New Surfaces: include/bar.h, brandnew.c
      Development: add the target
      Acceptance: it builds
      Verification: bash tests/run.sh

- [ ] Untouched clean item
      Mode: docs
      Rationale: doc gap
      Evidence: README has no usage
      Surfaces: src/foo.c
      Development: add usage
      Acceptance: documented
      Verification: bash tests/run.sh
EOF
# Capture the second (clean) item verbatim to prove --fix leaves it byte-identical.
untouched_before="$(sed -n '/^- \[ \] Untouched clean item/,$p' "$FIXPLAN")"
fix_rc=0
python3 "$ROOT/scripts/lint-plan.py" --fix --root "$FIXROOT" --plan "$FIXPLAN" --quiet || fix_rc=$?
untouched_after="$(sed -n '/^- \[ \] Untouched clean item/,$p' "$FIXPLAN")"
if [ "$fix_rc" = "0" ] \
   && grep -q '^      Surfaces: src/foo.c, CMakeLists.txt, include/bar.h$' "$FIXPLAN" \
   && grep -q '^      New Surfaces: brandnew.c$' "$FIXPLAN" \
   && ! grep -q 'CMakeLists,' "$FIXPLAN" \
   && [ "$untouched_before" = "$untouched_after" ]; then
  ok "lint-plan.py --fix respells CMakeLists.txt, moves existing New Surfaces, leaves clean items intact"
else
  bad "lint-plan.py --fix mis-corrected (rc=$fix_rc) or disturbed an untouched item"
fi

# Idempotency: a second --fix finds nothing to change and the file is byte-stable.
sha1="$(python3 - "$FIXPLAN" <<'PY'
import hashlib,sys;print(hashlib.sha256(open(sys.argv[1],'rb').read()).hexdigest())
PY
)"
fix2="$(python3 "$ROOT/scripts/lint-plan.py" --fix --root "$FIXROOT" --plan "$FIXPLAN")"
sha2="$(python3 - "$FIXPLAN" <<'PY'
import hashlib,sys;print(hashlib.sha256(open(sys.argv[1],'rb').read()).hexdigest())
PY
)"
if printf '%s' "$fix2" | grep -q 'no auto-fixable violations' && [ "$sha1" = "$sha2" ]; then
  ok "lint-plan.py --fix is idempotent (second run is a no-op, file byte-stable)"
else
  bad "lint-plan.py --fix is not idempotent (re-applied a fix or changed bytes)"
fi

# --- Test 12f-crlf: --fix preserves a CRLF plan's line terminators -----------------
# splitlines()+"\n".join() would silently LF-convert EVERY line of a CRLF plan, not just
# the one Surfaces field it respells — corrupting an editor's/git-autocrlf checkout. Build
# a CRLF plan with a CMakeLists Surface (forces a respell) plus an untouched item, --fix
# it, and assert the respell landed while every line kept its \r\n terminator.
CRROOT="$TMP/fixroot-crlf"; mkdir -p "$CRROOT/.planwright" "$CRROOT/src"
: > "$CRROOT/src/foo.c"; : > "$CRROOT/CMakeLists.txt"
CRPLAN="$CRROOT/.planwright/plan.md"
printf '# planwright Plan — .\r\n\r\n- [ ] Wire it\r\n      Mode: develop\r\n      Rationale: r.\r\n      Evidence: src/foo.c:1 lacks a rule\r\n      Surfaces: src/foo.c, CMakeLists\r\n      Development: add it\r\n      Acceptance: builds\r\n      Verification: bash tests/run.sh\r\n\r\n- [ ] Untouched item\r\n      Mode: docs\r\n      Rationale: r.\r\n      Evidence: README gap\r\n      Surfaces: src/foo.c\r\n      Development: doc it\r\n      Acceptance: done\r\n      Verification: bash tests/run.sh\r\n' > "$CRPLAN"
cr_before="$(grep -c $'\r' "$CRPLAN" || true)"
python3 "$ROOT/scripts/lint-plan.py" --fix --root "$CRROOT" --plan "$CRPLAN" --quiet >/dev/null 2>&1 || true
cr_after="$(grep -c $'\r' "$CRPLAN" || true)"
if grep -q $'^      Surfaces: src/foo.c, CMakeLists.txt\r$' "$CRPLAN" \
   && [ "$cr_before" -gt 0 ] && [ "$cr_before" = "$cr_after" ]; then
  ok "lint-plan.py --fix preserves CRLF terminators (untouched lines stay CRLF, respell landed)"
else
  bad "lint-plan.py --fix corrupted CRLF terminators (before=$cr_before after=$cr_after)"
fi

# --- Test 12g: --fix never touches a non-existent Surface or a completed item ----
# A Surface that does not exist is NOT auto-moved to New Surfaces (it may be a typo, not
# a new file) — only the agent decides that. Completed items are off-limits without --all.
SAFEROOT="$TMP/fixsafe"; mkdir -p "$SAFEROOT/.planwright"; : > "$SAFEROOT/real.c"
SAFEPLAN="$SAFEROOT/.planwright/plan.md"
cat > "$SAFEPLAN" <<'EOF'
# planwright Plan — .

- [ ] Pending with a typo'd Surface
      Mode: develop
      Rationale: r
      Evidence: real.c:1 wrong
      Surfaces: real.c, srcc/typo.c
      Development: d
      Acceptance: a
      Verification: bash tests/run.sh

- [x] Completed with bad spelling
      Mode: develop
      Surfaces: CMakeLists
      Verification: true
EOF
before_safe="$(cat "$SAFEPLAN")"
python3 "$ROOT/scripts/lint-plan.py" --fix --root "$SAFEROOT" --plan "$SAFEPLAN" --quiet || true
# The pending typo'd Surface stays in Surfaces (not moved); the completed CMakeLists is
# untouched (no --all). The whole file must be byte-identical.
if [ "$before_safe" = "$(cat "$SAFEPLAN")" ]; then
  ok "lint-plan.py --fix leaves a non-existent Surface and a completed item untouched"
else
  bad "lint-plan.py --fix wrongly rewrote a typo'd Surface or a completed item"
fi


# --- Test: a directory Surface is rejected; an equivalent file Surface passes -------
# OUTPUT FORMAT: Surfaces are existing *files* that change. A directory passes the bare
# existence check but is not an editable boundary, so lint_item must flag it. A real file
# at the same root must still pass (the guard fires only on directories).
DIRPLAN="$TMP/dir_surface_plan.md"
cat > "$DIRPLAN" <<'EOP'
# planwright Plan — .

- [ ] Item naming a directory as a Surface
      Mode: improve
      Rationale: r.
      Evidence: scripts/ exists.
      Surfaces: scripts
      Development: edit something under scripts/.
      Acceptance: green.
      Verification: bash tests/run.sh
EOP
dir_rc=0
dir_out="$(python3 "$ROOT/scripts/lint-plan.py" --root "$ROOT" --plan "$DIRPLAN" 2>&1)" || dir_rc=$?
if [ "$dir_rc" -ne 0 ] && printf '%s' "$dir_out" | grep -qF "is a directory"; then
  ok "lint-plan.py rejects a directory Surface (must name specific files)"
else
  bad "lint-plan.py accepted a directory Surface (rc=$dir_rc): $dir_out"
fi
FILEPLAN="$TMP/file_surface_plan.md"
cat > "$FILEPLAN" <<'EOP'
# planwright Plan — .

- [ ] Item naming a file as a Surface
      Mode: improve
      Rationale: r.
      Evidence: scripts/lint-plan.py exists.
      Surfaces: scripts/lint-plan.py
      Development: edit lint_item().
      Acceptance: green.
      Verification: bash tests/run.sh
EOP
file_rc=0
python3 "$ROOT/scripts/lint-plan.py" --root "$ROOT" --plan "$FILEPLAN" --quiet || file_rc=$?
if [ "$file_rc" -eq 0 ]; then
  ok "lint-plan.py accepts a file Surface (directory guard does not over-fire)"
else
  bad "lint-plan.py wrongly rejected a valid file Surface (rc=$file_rc)"
fi

# --- Test 12f: a Verification running a missing repo script is a (non-failing) advisory
# A well-formed item whose Verification invokes `bash <script>` for a script that does
# not exist will be rejected as unverifiable at execute; lint-plan flags it early as an
# advisory (exit 0 by default, promoted to a failure under --strict). A Verification
# that runs an existing script, or a non-interpreter runner (ctest/make), is never flagged.
VPDIR="$TMP/verifpath"; mkdir -p "$VPDIR"
mk_vp() { # $1 = Verification command
  cat > "$VPDIR/plan.md" <<EOF
# planwright Plan — .

- [ ] An item with a checkable verification
      Mode: improve
      Rationale: r.
      Evidence: scripts/lint-plan.py exists.
      Surfaces: scripts/lint-plan.py
      Development: edit main().
      Acceptance: green.
      Verification: $1
EOF
}
# missing script -> advisory (default exit 0), --strict exit 1
mk_vp "bash tests/this-script-does-not-exist.sh"
vp_def=0; vp_out="$(python3 "$ROOT/scripts/lint-plan.py" --root "$ROOT" --plan "$VPDIR/plan.md" 2>&1)" || vp_def=$?
vp_strict=0; python3 "$ROOT/scripts/lint-plan.py" --root "$ROOT" --plan "$VPDIR/plan.md" --strict --quiet || vp_strict=$?
# existing script -> no advisory; non-interpreter runner -> no advisory
mk_vp "bash tests/run.sh"
vp_ok=0; python3 "$ROOT/scripts/lint-plan.py" --root "$ROOT" --plan "$VPDIR/plan.md" --strict --quiet || vp_ok=$?
mk_vp "ctest --test-dir build -R foo"
vp_ctest=0; python3 "$ROOT/scripts/lint-plan.py" --root "$ROOT" --plan "$VPDIR/plan.md" --strict --quiet || vp_ctest=$?
if [ "$vp_def" = 0 ] && [ "$vp_strict" = 1 ] && [ "$vp_ok" = 0 ] && [ "$vp_ctest" = 0 ] \
   && printf '%s' "$vp_out" | grep -qF "which does not exist"; then
  ok "lint-plan.py flags a Verification that runs a missing repo script (advisory; --strict fails)"
else
  bad "lint-plan.py verification-path advisory wrong (def=$vp_def strict=$vp_strict ok=$vp_ok ctest=$vp_ctest)"
fi

# --- Test 12g: an Evidence file:line anchor naming a nonexistent file is a (non-failing) advisory
# Evidence is planwright's grounding signal; a fabricated or stale repo-relative path:N anchor is
# flagged as an advisory (exit 0 by default, promoted under --strict). A real anchor, a bare
# filename, a prose mention without a line ref, and a version string are never flagged.
EVDIR="$TMP/evanchor"; mkdir -p "$EVDIR"
mk_ev() { # $1 = Evidence string
  cat > "$EVDIR/plan.md" <<EOF
# planwright Plan — .

- [ ] An item with some evidence
      Mode: improve
      Rationale: r.
      Evidence: $1
      Surfaces: scripts/lint-plan.py
      Development: edit main().
      Acceptance: green.
      Verification: bash tests/run.sh
EOF
}
# fabricated repo-relative anchor -> advisory (default 0), --strict 1
mk_ev "scripts/nope_missing.py:42 shows the bug"
ev_def=0; ev_out="$(python3 "$ROOT/scripts/lint-plan.py" --root "$ROOT" --plan "$EVDIR/plan.md" 2>&1)" || ev_def=$?
ev_strict=0; python3 "$ROOT/scripts/lint-plan.py" --root "$ROOT" --plan "$EVDIR/plan.md" --strict --quiet || ev_strict=$?
# real anchor -> no advisory; bare filename + version string -> no false flag
mk_ev "scripts/lint-plan.py:461 defines main()"
ev_real=0; python3 "$ROOT/scripts/lint-plan.py" --root "$ROOT" --plan "$EVDIR/plan.md" --strict --quiet || ev_real=$?
mk_ev "tested on python 3.10 and seen in build-graph.py behavior"
ev_prose=0; python3 "$ROOT/scripts/lint-plan.py" --root "$ROOT" --plan "$EVDIR/plan.md" --strict --quiet || ev_prose=$?
if [ "$ev_def" = 0 ] && [ "$ev_strict" = 1 ] && [ "$ev_real" = 0 ] && [ "$ev_prose" = 0 ] \
   && printf '%s' "$ev_out" | grep -qF "Evidence cites 'scripts/nope_missing.py'"; then
  ok "lint-plan.py flags an Evidence anchor that names a nonexistent file (advisory; --strict fails)"
else
  bad "lint-plan.py evidence-anchor advisory wrong (def=$ev_def strict=$ev_strict real=$ev_real prose=$ev_prose)"
fi
# 12g regressions: a glued abbreviation prefix must NOT absorb a real path (no false positive),
# and a leading ./ anchor IS still checked.
mk_ev "see e.g.scripts/lint-plan.py:461 for the swallowed-prefix case"   # scripts/lint-plan.py exists
ev_glue=0; python3 "$ROOT/scripts/lint-plan.py" --root "$ROOT" --plan "$EVDIR/plan.md" --strict --quiet || ev_glue=$?
mk_ev "the dot-slash form ./scripts/nope_missing.py:7 should still be flagged"
ev_ds=0; ev_ds_out="$(python3 "$ROOT/scripts/lint-plan.py" --root "$ROOT" --plan "$EVDIR/plan.md" 2>&1)" || ev_ds=$?
if [ "$ev_glue" = 0 ] && [ "$ev_ds" = 0 ] && printf '%s' "$ev_ds_out" | grep -qF "Evidence cites './scripts/nope_missing.py'"; then
  ok "lint-plan.py evidence-anchor: glued 'e.g.path' is no false positive; './path' is checked"
else
  bad "lint-plan.py evidence-anchor regression (glue=$ev_glue dotslash=$ev_ds)"
fi

# 12h: a ROOT-LEVEL anchor (no directory segment) is checked too — a stale/fabricated root file
# is as important a grounding miss as a nested one. A fabricated root anchor is flagged; an
# existing root file (README.md, present at $ROOT) is not; a version string with a trailing :N
# ("3.10:5") still never matches (the extension must be letter-led).
mk_ev "the root file NOPE_missing.md:50 no longer exists"
ev_root=0; ev_root_out="$(python3 "$ROOT/scripts/lint-plan.py" --root "$ROOT" --plan "$EVDIR/plan.md" 2>&1)" || ev_root=$?
ev_root_strict=0; python3 "$ROOT/scripts/lint-plan.py" --root "$ROOT" --plan "$EVDIR/plan.md" --strict --quiet || ev_root_strict=$?
mk_ev "see README.md:1 at the repo root"
ev_root_real=0; python3 "$ROOT/scripts/lint-plan.py" --root "$ROOT" --plan "$EVDIR/plan.md" --strict --quiet || ev_root_real=$?
mk_ev "pinned at 3.10:5 in the changelog"
ev_ver=0; python3 "$ROOT/scripts/lint-plan.py" --root "$ROOT" --plan "$EVDIR/plan.md" --strict --quiet || ev_ver=$?
if [ "$ev_root" = 0 ] && [ "$ev_root_strict" = 1 ] && [ "$ev_root_real" = 0 ] && [ "$ev_ver" = 0 ] \
   && printf '%s' "$ev_root_out" | grep -qF "Evidence cites 'NOPE_missing.md'"; then
  ok "lint-plan.py evidence-anchor: a stale root-level anchor is flagged; an existing root file and a version string are not"
else
  bad "lint-plan.py root-level evidence-anchor regression (root=$ev_root strict=$ev_root_strict real=$ev_root_real ver=$ev_ver)"
fi

# --- Test 12i: a repair item's ghost Evidence anchor FAILS; out-of-range lines are advisories
# repair means "confirmed defect, cite the wrong call site" — a ghost call site is as fatal
# as a ghost Surface, so it is a violation (exit 1) on repair items while every other mode
# keeps the advisory posture (12g above pins that). A line number past the end of the cited
# file is a hallucinated anchor in any mode: a non-failing advisory naming the cited line
# and the file's real length. Multiple offending anchors are all reported, not just the first.
mk_ev_mode() { # $1 = Mode, $2 = Evidence string
  cat > "$EVDIR/plan.md" <<EOF
# planwright Plan — .

- [ ] An item with some evidence
      Mode: $1
      Rationale: r.
      Evidence: $2
      Surfaces: scripts/lint-plan.py
      Development: edit main().
      Acceptance: green.
      Verification: bash tests/run.sh
EOF
}
mk_ev_mode repair "scripts/nope_missing.py:42 returns the wrong default"
ev_rg=0; ev_rg_out="$(python3 "$ROOT/scripts/lint-plan.py" --root "$ROOT" --plan "$EVDIR/plan.md" 2>&1)" || ev_rg=$?
mk_ev_mode improve "scripts/lint-plan.py:99999 lacks a guard"
ev_oor=0; ev_oor_out="$(python3 "$ROOT/scripts/lint-plan.py" --root "$ROOT" --plan "$EVDIR/plan.md" 2>&1)" || ev_oor=$?
ev_oor_strict=0; python3 "$ROOT/scripts/lint-plan.py" --root "$ROOT" --plan "$EVDIR/plan.md" --strict --quiet || ev_oor_strict=$?
mk_ev_mode improve "scripts/lint-plan.py (line 99999) lacks a guard"   # the (line N) form is range-checked too
ev_oor2=0; ev_oor2_out="$(python3 "$ROOT/scripts/lint-plan.py" --root "$ROOT" --plan "$EVDIR/plan.md" 2>&1)" || ev_oor2=$?
mk_ev_mode improve "scripts/nope_a.py:1 and scripts/nope_b.py:2 are both wrong"
ev_multi_out="$(python3 "$ROOT/scripts/lint-plan.py" --root "$ROOT" --plan "$EVDIR/plan.md" 2>&1)" || true
if [ "$ev_rg" = 1 ] \
   && printf '%s' "$ev_rg_out" | grep -qF "repair Evidence cites 'scripts/nope_missing.py', which does not exist" \
   && [ "$ev_oor" = 0 ] && [ "$ev_oor_strict" = 1 ] \
   && printf '%s' "$ev_oor_out" | grep -qE "cites line 99999, but the file has [0-9]+ lines" \
   && [ "$ev_oor2" = 0 ] && printf '%s' "$ev_oor2_out" | grep -qF "cites line 99999" \
   && printf '%s' "$ev_multi_out" | grep -qF "scripts/nope_a.py" \
   && printf '%s' "$ev_multi_out" | grep -qF "scripts/nope_b.py"; then
  ok "lint-plan.py fails a repair ghost anchor, advises on out-of-range lines, and reports every offending anchor"
else
  bad "lint-plan.py repair-ghost/out-of-range anchor handling wrong (rg=$ev_rg oor=$ev_oor strict=$ev_oor_strict oor2=$ev_oor2)"
fi

# --- Test 12n: lint-plan.py accepts modern tooling in a Verification ---------
# A real Verification like `docker run my_test_container` is multi-word and carries
# no command-signal char, so before docker/bazel/php joined _KNOWN_EXEC it was
# rejected as prose, blocking otherwise-correct plan items. It must now pass.
MOD_PLAN="$TMP/modern_exec_plan.md"
cat > "$MOD_PLAN" <<'EOF'
# planwright Plan — .
<!-- Session: x -->

- [ ] An item verified by a container run
      Mode: improve
      Rationale: a real reason.
      Evidence: scripts/build-graph.py:1 does X.
      Surfaces: scripts/build-graph.py
      Development: edit build() at the node loop.
      Acceptance: the suite stays green.
      Verification: docker run my_test_container

- [ ] An item verified by a bazel target
      Mode: improve
      Rationale: a real reason.
      Evidence: scripts/lint-plan.py:1 does Y.
      Surfaces: scripts/lint-plan.py
      Development: edit the runner whitelist.
      Acceptance: the suite stays green.
      Verification: bazel test //pkg:all
EOF
me_out="$(python3 "$ROOT/scripts/lint-plan.py" --root "$ROOT" --plan "$MOD_PLAN" 2>&1)"; me_rc=$?
if [ "$me_rc" = 0 ] && ! printf '%s' "$me_out" | grep -qi 'reads as prose'; then
  ok "lint-plan.py accepts docker/bazel Verifications (not flagged as prose)"
else
  bad "lint-plan.py wrongly rejected a docker/bazel Verification: $me_out"
fi


# --- Test 12r: repair anchors on extension-less files are legal --------------
# _EVIDENCE_ANCHOR_RE required a dotted, letter-led extension, so the canonical
# file:line citation on a Makefile/Dockerfile/dotfile surface ("Makefile:2 ...")
# hard-failed the mandatory repair-anchor gate — a false failure the file header
# forbids. The filename alternation now admits well-known extension-less build
# files and >=3-char dotfiles, while version strings keep failing. The anchors
# run against a fixture root with REAL files: a repair ghost anchor is now a
# failing violation (Test 12i), so the admission test must cite files that exist.
EXTROOT="$TMP/extless_root"; mkdir -p "$EXTROOT/scripts"
printf 'release:\n\tcc -O0 main.c\n' > "$EXTROOT/Makefile"
printf 'build/\nbuild/\n*.o\n' > "$EXTROOT/.gitignore"
printf '# surface stub\n' > "$EXTROOT/scripts/lint-plan.py"
EXTLESS="$TMP/extless_plan.md"
cat > "$EXTLESS" <<'EOF'
# planwright Plan — .

- [ ] Fix the release recipe flags
      Mode: repair
      Rationale: wrong optimization level in the release recipe.
      Evidence: Makefile:2 passes -O0 in the release recipe; expected -O2.
      Surfaces: scripts/lint-plan.py
      Development: change the flag at that line.
      Acceptance: release builds use -O2.
      Verification: bash tests/run.sh
EOF
exl_rc=0
python3 "$ROOT/scripts/lint-plan.py" --root "$EXTROOT" --plan "$EXTLESS" --quiet || exl_rc=$?
# dotfile anchor also satisfies the gate; a version string still does not
DOTFILE="$TMP/dotfile_plan.md"
sed 's|Makefile:2 passes -O0 in the release recipe; expected -O2|.gitignore:3 ignores build/ twice; expected one rule|' "$EXTLESS" > "$DOTFILE"
dot_rc=0
python3 "$ROOT/scripts/lint-plan.py" --root "$EXTROOT" --plan "$DOTFILE" --quiet || dot_rc=$?
VERSTR="$TMP/verstr_plan.md"
sed 's|Makefile:2 passes -O0 in the release recipe; expected -O2|python 3.10:5 mishandles the flag|' "$EXTLESS" > "$VERSTR"
ver_rc=0
ver_out="$(python3 "$ROOT/scripts/lint-plan.py" --root "$EXTROOT" --plan "$VERSTR" 2>&1)" || ver_rc=$?
if [ "$exl_rc" -eq 0 ] && [ "$dot_rc" -eq 0 ] && [ "$ver_rc" -ne 0 ] \
   && printf '%s' "$ver_out" | grep -qF "repair Evidence lacks a file:line anchor"; then
  ok "lint-plan.py accepts extension-less/dotfile repair anchors; version strings still fail"
else
  bad "lint-plan.py extension-less anchor gate wrong (extless=$exl_rc dotfile=$dot_rc verstr=$ver_rc)"
fi


# --- Test 12s: a standalone trailing "." argument is a command, not prose ----
# Normalization rstrip(".")-ed the whole value before the prose scan, so
# "ruff check ." lost its only command-signal character and was misflagged as
# prose. Only a GLUED sentence-final period is stripped now; dot-only tokens
# survive, and common linters lead a Verification legally.
PROSEDOT="$TMP/prosedot_plan.md"
mk_verif_plan() {
  cat > "$PROSEDOT" <<EOF
# planwright Plan — .

- [ ] Verification normalization probe
      Mode: improve
      Rationale: probe.
      Evidence: probing the verification normalizer.
      Surfaces: scripts/lint-plan.py
      Development: none needed for the probe.
      Acceptance: lint outcome matches the contract.
      Verification: $1
EOF
}
vd_fail=""
for good in "ruff check ." "mypy scripts"; do
  mk_verif_plan "$good"
  python3 "$ROOT/scripts/lint-plan.py" --root "$ROOT" --plan "$PROSEDOT" --quiet || vd_fail="$vd_fail [pass:$good]"
done
for bad_v in "verify manually" "verify manually." "checks pending approval" "..."; do
  mk_verif_plan "$bad_v"
  if python3 "$ROOT/scripts/lint-plan.py" --root "$ROOT" --plan "$PROSEDOT" --quiet 2>/dev/null; then
    vd_fail="$vd_fail [fail:$bad_v]"
  fi
done
if [ -z "$vd_fail" ]; then
  ok "lint-plan.py keeps a standalone trailing '.' argument (ruff check .) while prose/placeholders still fail"
else
  bad "lint-plan.py verification normalization wrong:$vd_fail"
fi


# --- Test 12t: a string-valued focus in the scope graph degrades to no-scope ------
# set() over a JSON string raises nothing — it yields the set of its CHARACTERS, so
# {"focus": "scripts/foo.py"} silently activated scope mode with a garbage Focus
# that failed every Surface. load_focus now requires list-shaped focus/context.
SCG_STR="$TMP/scope_string.json"
printf '{"focus": "scripts/foo.py", "context": []}' > "$SCG_STR"
STRPLAN="$TMP/scope_string_plan.md"
cat > "$STRPLAN" <<'EOF'
# planwright Plan — .

- [ ] Scope shape probe
      Mode: improve
      Rationale: probe.
      Evidence: probing load_focus shape validation.
      Surfaces: scripts/lint-plan.py
      Development: none for the probe.
      Acceptance: lints clean with the malformed scope graph.
      Verification: bash tests/run.sh
EOF
if python3 "$ROOT/scripts/lint-plan.py" --root "$ROOT" --plan "$STRPLAN" --scope "$SCG_STR" --quiet; then
  ok "lint-plan.py --scope degrades a string-valued focus to no-scope (no false Surface failures)"
else
  bad "lint-plan.py --scope treated a string-valued focus as an active character-set scope"
fi


# --- Test 12u: a non-UTF-8 plan fails closed cleanly (structured, no traceback) ----
# The one .planwright reader the degrade-not-crash series missed: a stray byte in
# plan.md crashed the gate with a raw UnicodeDecodeError and --json emitted nothing.
# It must exit 1 with a single clean violation; --json stdout must parse; --fix must
# not rewrite bytes it cannot decode.
NUP="$TMP/nonutf8_plan/.planwright"; mkdir -p "$NUP"
printf -- '- [ ] T\xff\xfe\n      Mode: repair\n' > "$NUP/plan.md"
nup_rc=0
nup_out="$(python3 "$ROOT/scripts/lint-plan.py" --root "$TMP/nonutf8_plan" 2>&1)" || nup_rc=$?
nupj_rc=0
nupj_out="$(python3 "$ROOT/scripts/lint-plan.py" --root "$TMP/nonutf8_plan" --json 2>/dev/null)" || nupj_rc=$?
nupf_rc=0
python3 "$ROOT/scripts/lint-plan.py" --root "$TMP/nonutf8_plan" --fix --quiet 2>/dev/null || nupf_rc=$?
if [ "$nup_rc" = 1 ] && [ "$nupj_rc" = 1 ] && [ "$nupf_rc" = 1 ] \
   && ! printf '%s' "$nup_out" | grep -q 'Traceback' \
   && printf '%s' "$nup_out" | grep -q 'not valid UTF-8' \
   && printf '%s' "$nupj_out" | python3 -c 'import json,sys;d=json.load(sys.stdin);assert d["general_violations"]' \
   && grep -q $'\xff' "$NUP/plan.md"; then
  ok "lint-plan.py fails closed on a non-UTF-8 plan (clean message, parseable --json, --fix untouched)"
else
  bad "lint-plan.py mishandled a non-UTF-8 plan (text=$nup_rc json=$nupj_rc fix=$nupf_rc): $nup_out"
fi


# --- Test 12v: a standalone trailing ellipsis cannot ride the '.' command signal --
# The "ruff check ." fix preserved any dot-only last token, so prose ending in " ..."
# kept a '.' command-signal character and evaded the prose gate. A 3+-dot token is an
# ellipsis, never a path — it is dropped before the scan; '.' and '..' stay.
ell_fail=""
for bad_v in "Inspect the dashboard manually ..." "verify by hand ...."; do
  mk_verif_plan "$bad_v"
  if python3 "$ROOT/scripts/lint-plan.py" --root "$ROOT" --plan "$PROSEDOT" --quiet 2>/dev/null; then
    ell_fail="$ell_fail [passed:$bad_v]"
  fi
done
for good in "ruff check ." "git add .."; do
  mk_verif_plan "$good"
  python3 "$ROOT/scripts/lint-plan.py" --root "$ROOT" --plan "$PROSEDOT" --quiet || ell_fail="$ell_fail [failed:$good]"
done
if [ -z "$ell_fail" ]; then
  ok "lint-plan.py flags prose ending in an ellipsis while '.'/'..' arguments still pass"
else
  bad "lint-plan.py ellipsis handling wrong:$ell_fail"
fi


# --- Test 12w: --json emits the canonical empty document when no plan exists -------
# The absent-plan branch printed a prose line even under --json, breaking the
# single-clean-JSON-document contract for machine consumers.
NOPLAN="$TMP/lint-noplan"; mkdir -p "$NOPLAN"
np_rc=0
np_out="$(python3 "$ROOT/scripts/lint-plan.py" --root "$NOPLAN" --json)" || np_rc=$?
npq_out="$(python3 "$ROOT/scripts/lint-plan.py" --root "$NOPLAN" --json --quiet)"
npt_out="$(python3 "$ROOT/scripts/lint-plan.py" --root "$NOPLAN")"
if [ "$np_rc" = 0 ] \
   && printf '%s' "$np_out" | python3 -c 'import json,sys;d=json.load(sys.stdin);assert d["total_items"]==0 and d["items"]==[]' \
   && [ -z "$npq_out" ] \
   && printf '%s' "$npt_out" | grep -q 'no plan file at'; then
  ok "lint-plan.py --json emits the canonical empty document on a missing plan (text/quiet unchanged)"
else
  bad "lint-plan.py absent-plan --json contract wrong (rc=$np_rc): $np_out"
fi
