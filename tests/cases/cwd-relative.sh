# SPDX-FileCopyrightText: 2026 Eser KUBALI
# SPDX-License-Identifier: GPL-3.0-or-later
# shellcheck shell=bash
#
# Cross-cwd / relative-root resolution for the plan-state scripts (status.py,
# lifecycle.py). The rest of the suite always invokes these via an absolute
# "$ROOT/scripts/..." path with an absolute --root while cwd stays at the planwright
# repo, so the documented cwd-relative defaults (`--root .` / `--root .planwright`,
# status.py's --root default=".") are never exercised from a FOREIGN cwd — the exact
# path-resolution class an installed user hits in their own project (the self-dogfooding
# blind spot). This case builds a synthetic target repo OUTSIDE the planwright tree and
# drives the scripts from a different cwd to pin that resolution.
# Sourced by tests/run.sh after tests/lib.sh — NOT standalone (uses ROOT/TMP/ok/bad).

STAT="$ROOT/scripts/status.py"
LC="$ROOT/scripts/lifecycle.py"

# A target "repo" that is NOT the planwright repo, plus a sibling cwd to run from.
CWDT="$TMP/cwd-target"; CWDS="$TMP/cwd-sibling"
mkdir -p "$CWDT/.planwright" "$CWDS"
printf -- '- [ ] one\n- [ ] two\n' > "$CWDT/.planwright/plan.md"
printf -- '- [x] done\n'           > "$CWDT/.planwright/completed.md"
printf -- '- [ ] nope\n      Status: Rejected\n' > "$CWDT/.planwright/rejected.md"

# Just the three count lines, sorted, so the two invocations can be compared directly.
_counts() { grep -oE '"(pending|completed|rejected)": [0-9]+' | sort; }
_want="$(printf '"completed": 1\n"pending": 2\n"rejected": 1\n')"

# --- Test CR1: status --root . resolves .planwright relative to a FOREIGN cwd -------
rel="$( cd "$CWDT" && python3 "$STAT" --root . --json 2>/dev/null | _counts )" || rel=""
if [ "$rel" = "$_want" ]; then
  ok "status.py --root . counts pending=2/completed=1/rejected=1 from cwd==target"
else
  bad "status.py --root . mis-resolved a relative root from a foreign cwd (got: $rel)"
fi

# --- Test CR2: a foreign-cwd absolute --root agrees with the relative control -------
abs="$( cd "$CWDS" && python3 "$STAT" --root "$CWDT" --json 2>/dev/null | _counts )" || abs=""
if [ "$abs" = "$_want" ] && [ "$abs" = "$rel" ]; then
  ok "status.py --root <abs> from a sibling cwd agrees with the --root . control"
else
  bad "status.py absolute-root from a foreign cwd disagreed with the relative control (got: $abs)"
fi

# --- Test CR3: lifecycle housekeep --root .planwright drains from cwd==target -------
HKT="$TMP/cwd-housekeep"; mkdir -p "$HKT/.planwright"
cat > "$HKT/.planwright/plan.md" <<'EOF'
# planwright Plan — .

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
      Rejection: boom
      Verification: true
EOF
( cd "$HKT" && python3 "$LC" housekeep --root .planwright ) >/dev/null
pend="$(grep -c '^- \[ \]' "$HKT/.planwright/plan.md" 2>/dev/null || true)"
done_in_plan="$(grep -c '^- \[x\]' "$HKT/.planwright/plan.md" 2>/dev/null || true)"
if [ "$pend" = "1" ] && [ "$done_in_plan" = "0" ] \
   && grep -q '^- \[x\] A finished item' "$HKT/.planwright/completed.md" \
   && grep -q '^- \[ \] A rejected item' "$HKT/.planwright/rejected.md" \
   && ! grep -q 'A rejected item' "$HKT/.planwright/plan.md"; then
  ok "lifecycle.py housekeep --root .planwright drains+keeps pending from cwd==target"
else
  bad "lifecycle.py housekeep mis-drained from a foreign cwd (pending=$pend, done_in_plan=$done_in_plan)"
fi
