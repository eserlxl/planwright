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
# A pending item with all eight fields and no path issues must pass; the same item
# completed (- [x]) is skipped by default and only checked under --all.
DONE_PLAN="$TMP/done_plan.md"
sed 's/- \[ \]/- [x]/' "$BAD_PLAN" > "$DONE_PLAN"
if python3 "$ROOT/scripts/lint-plan.py" --root "$ROOT" --plan "$DONE_PLAN" --quiet; then ok "lint-plan.py skips completed items by default"; else bad "lint-plan.py linted a completed item without --all"; fi
if python3 "$ROOT/scripts/lint-plan.py" --root "$ROOT" --plan "$DONE_PLAN" --all --quiet; then bad "lint-plan.py --all ignored a completed item"; else ok "lint-plan.py --all also lints completed items"; fi
# An absent plan file is not an error (nothing to lint).
if python3 "$ROOT/scripts/lint-plan.py" --root "$ROOT" --plan "$TMP/nope.md" --quiet; then ok "lint-plan.py treats an absent plan as clean"; else bad "lint-plan.py errored on an absent plan file"; fi

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
