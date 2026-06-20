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

# --- Test CR4: state.py activity --root . writes the beacon under the target's .planwright (foreign cwd)
# The run-activity beacon (read by the dashboard reactor) must land in the TARGET repo's .planwright/,
# resolved from cwd via `--root .`, not the planwright install tree — the same dogfood blind spot CR1
# pins for status. Positive arm: from cwd==target the beacon is written under the target's .planwright/.
CWB="$TMP/cwd-beacon"; mkdir -p "$CWB/.planwright"
STATE="$ROOT/scripts/state.py"
( cd "$CWB" && python3 "$STATE" activity start cycle --root . ) >/dev/null 2>&1
if [ -f "$CWB/.planwright/activity.json" ] && grep -q '"command"' "$CWB/.planwright/activity.json"; then
  ok "state.py activity start --root . writes the beacon under the target repo's .planwright/ from a foreign cwd"
else
  bad "state.py activity start --root . did not write the beacon to the target's .planwright/"
fi
( cd "$CWB" && python3 "$STATE" activity stop cycle --root . ) >/dev/null 2>&1

# --- Test CR5: reconcile-sweep via --root .planwright (cwd==target) agrees with an absolute --root ---
# The completion-accounting safety net resolves --root relative to the target repo. A relative run from
# cwd==target and an absolute run from a sibling cwd must record the SAME fix into the SAME target ledger.
SWT="$TMP/cwd-sweep"; mkdir -p "$SWT/.planwright"
(
  cd "$SWT" || exit
  git init -q; git config user.email t@e.com; git config user.name t; git config commit.gpgsign false
  printf '0\n' > f.txt; git add -A; git commit -qm init
  printf '1\n' >> f.txt; git add -A; git commit -qm "Fix the thing"
) >/dev/null 2>&1
sw_base="$(git -C "$SWT" rev-parse HEAD~1)"
( cd "$SWT" && python3 "$LC" reconcile-sweep --since "$sw_base" --mode repair --root .planwright ) >/dev/null 2>&1
rel_done="$(grep -c '^- \[x\]' "$SWT/.planwright/completed.md" 2>/dev/null || echo 0)"
rm -f "$SWT/.planwright/completed.md"
( cd "$CWDS" && python3 "$LC" reconcile-sweep --since "$sw_base" --mode repair --root "$SWT/.planwright" --repo "$SWT" ) >/dev/null 2>&1
abs_done="$(grep -c '^- \[x\]' "$SWT/.planwright/completed.md" 2>/dev/null || echo 0)"
if [ "$rel_done" = "1" ] && [ "$abs_done" = "1" ] \
   && grep -q '^- \[x\] Fix the thing' "$SWT/.planwright/completed.md"; then
  ok "lifecycle.py reconcile-sweep records the same fix via --root .planwright (cwd==target) and an absolute --root"
else
  bad "lifecycle.py reconcile-sweep relative/absolute disagreed (rel=$rel_done abs=$abs_done)"
fi

# --- Test CR6: a foreign-cwd relative-root run never falls back to the planwright dev tree -----------
# Negative arm of CR4/CR5: a relative root (`--root .planwright`) from a foreign cwd must resolve to the
# TARGET, never the planwright install tree. A wrong default would record the target's fixes into the
# planwright repo's own ledger. Use a UNIQUE sentinel fix and assert it lands in the TARGET ledger and
# NEVER in the dev tree's completed.md.
PWPW="$ROOT/.planwright"
NEGT="$TMP/cwd-neg"; mkdir -p "$NEGT/.planwright"
(
  cd "$NEGT" || exit
  git init -q; git config user.email t@e.com; git config user.name t; git config commit.gpgsign false
  printf '0\n' > f.txt; git add -A; git commit -qm init
  printf '1\n' >> f.txt; git add -A; git commit -qm "Foreign cwd sentinel fix"
  python3 "$ROOT/scripts/lifecycle.py" reconcile-sweep --since HEAD~1 --mode improve --root .planwright >/dev/null 2>&1
) >/dev/null 2>&1
neg_recorded=0; grep -q 'Foreign cwd sentinel fix' "$NEGT/.planwright/completed.md" 2>/dev/null && neg_recorded=1
neg_leak=0;     grep -q 'Foreign cwd sentinel fix' "$PWPW/completed.md" 2>/dev/null && neg_leak=1
if [ "$neg_recorded" = 1 ] && [ "$neg_leak" = 0 ]; then
  ok "a foreign-cwd relative-root reconcile-sweep records into the TARGET ledger, never the planwright dev tree"
else
  bad "a foreign-cwd relative-root run leaked into the planwright dev tree (recorded=$neg_recorded leak=$neg_leak)"
fi
