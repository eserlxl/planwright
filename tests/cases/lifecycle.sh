# SPDX-FileCopyrightText: 2026 Eser KUBALI
# SPDX-License-Identifier: GPL-3.0-or-later
#
# scripts/lifecycle.py — Stage 0 lifecycle housekeeping.
# Sourced by tests/run.sh after tests/lib.sh — NOT standalone (uses ROOT/TMP/ok/bad).

LC="$ROOT/scripts/lifecycle.py"

# --- Test L1: housekeep drains completed + rejected, keeps pending --------------
LCD="$TMP/lc1/.planwright"; mkdir -p "$LCD"
cat > "$LCD/plan.md" <<'EOF'
# planwright Plan — .
<!-- Session: 2026-06-05T00:00:00Z -->

- [x] A finished item
      Mode: improve
      Verification: true

- [ ] A pending item
      Mode: docs
      Surfaces: README.md
      Verification: true

- [ ] A rejected item
      Mode: repair
      Status: Rejected
      Rejection: verification planwright_x failed: boom
      Verification: true
EOF
python3 "$LC" housekeep --root "$LCD" >/dev/null
# grep -c already prints the count (0 when none) and exits 1 on zero matches; `|| true`
# swallows the exit code under set -e WITHOUT the double-print an `|| echo 0` would add.
pend="$(grep -c '^- \[ \]' "$LCD/plan.md" 2>/dev/null || true)"
done_in_plan="$(grep -c '^- \[x\]' "$LCD/plan.md" 2>/dev/null || true)"
if [ "$pend" = "1" ] && [ "$done_in_plan" = "0" ] \
   && grep -q '^- \[x\] A finished item' "$LCD/completed.md" \
   && grep -q '^- \[ \] A rejected item' "$LCD/rejected.md" \
   && grep -q 'Rejection: verification planwright_x failed' "$LCD/rejected.md" \
   && ! grep -q 'A rejected item' "$LCD/plan.md"; then
  ok "lifecycle.py housekeep drains completed+rejected and keeps the pending item"
else
  bad "lifecycle.py housekeep mis-drained (pending=$pend, done_in_plan=$done_in_plan)"
fi

# --- Test L2: an empty plan (no pending) is DELETED, never archived ------------
# Mark the surviving pending item done, housekeep again -> no pending remains ->
# plan.md is deleted and no plans/ archive directory is created (the user's rule:
# an empty plan is clutter, overwrite fresh).
sed -i 's/^- \[ \] A pending item/- [x] A pending item/' "$LCD/plan.md"
out="$(python3 "$LC" housekeep --root "$LCD")"
if [ ! -f "$LCD/plan.md" ] && [ ! -d "$LCD/plans" ] \
   && printf '%s' "$out" | grep -q 'plan deleted (empty)'; then
  ok "lifecycle.py deletes an empty plan (no pending) and never archives it"
else
  bad "lifecycle.py did not delete the empty plan (or created an archive)"
fi

# --- Test L3: a plan that still has pending items is kept untouched ------------
LCK="$TMP/lc3/.planwright"; mkdir -p "$LCK"
cat > "$LCK/plan.md" <<'EOF'
# planwright Plan — .

- [ ] Keep me
      Mode: docs
      Surfaces: README.md
      Verification: true
EOF
before="$(cat "$LCK/plan.md")"
python3 "$LC" housekeep --root "$LCK" >/dev/null
if [ -f "$LCK/plan.md" ] && [ "$(cat "$LCK/plan.md")" = "$before" ]; then
  ok "lifecycle.py keeps a plan that still has pending items (byte-identical)"
else
  bad "lifecycle.py altered or deleted a plan that still had pending items"
fi

# --- Test L4: completed.md is FIFO-capped at 100 (oldest dropped) --------------
# Seed completed.md with 100 items (c001..c100), then drain 3 fresh completed items.
# Result must be exactly 100, with the 3 oldest (c001..c003) dropped and the newest
# kept (FIFO: drop from the top).
LCF="$TMP/lc4/.planwright"; mkdir -p "$LCF"
{ for i in $(seq -w 1 100); do
    printf -- '- [x] c%s\n      Mode: improve\n      Verification: true\n\n' "$i"
  done; } > "$LCF/completed.md"
{ printf '# planwright Plan — .\n\n'
  for i in 101 102 103; do
    printf -- '- [x] c%s\n      Mode: improve\n      Verification: true\n\n' "$i"
  done; } > "$LCF/plan.md"
python3 "$LC" drain-completed --root "$LCF" >/dev/null
total="$(grep -c '^- \[x\]' "$LCF/completed.md")"
if [ "$total" = "100" ] \
   && ! grep -q '^- \[x\] c001$' "$LCF/completed.md" \
   && ! grep -q '^- \[x\] c003$' "$LCF/completed.md" \
   && grep -q '^- \[x\] c004$' "$LCF/completed.md" \
   && grep -q '^- \[x\] c103$' "$LCF/completed.md"; then
  ok "lifecycle.py FIFO-caps completed.md at 100 (drops the 3 oldest, keeps the newest)"
else
  bad "lifecycle.py FIFO cap wrong (total=$total)"
fi

# --- Test L5: SKILL.md Stage 0 wires lifecycle.py and deletes (not archives) ----
# Contract: the procedure must invoke the script and document the delete-when-empty
# rule, with NO leftover plans/ archive instruction in Stage 0.
if python3 - "$ROOT/skills/planwright/SKILL.md" <<'PY' 2>/dev/null
import re, sys
t = open(sys.argv[1]).read()
m = re.search(r"### Stage 0.*?(?=\n### Stage 1 )", t, re.S)
stage0 = m.group(0) if m else ""
need = []
if "lifecycle.py" not in stage0: need.append("wire:lifecycle.py")
if "delete" not in stage0.lower(): need.append("rule:delete-empty")
if "plans/plan_" in stage0 or "archive the whole file" in stage0:
    need.append("stale:archive-instruction")
sys.exit(1 if need else 0)
PY
then ok "SKILL.md Stage 0 wires lifecycle.py and deletes an empty plan (no stale archive step)"; else bad "SKILL.md Stage 0 missing lifecycle.py wiring or still archives an empty plan"; fi
