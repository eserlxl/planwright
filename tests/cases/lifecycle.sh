# SPDX-FileCopyrightText: 2026 Eser KUBALI
# SPDX-License-Identifier: GPL-3.0-or-later
# shellcheck shell=bash
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

# --- Test L5: non-indented interstitial text is preserved and not counted pending -
# parse()/render() keep a non-indented note between checkbox blocks as an `interstitial`
# block (commit 20d0c3f), and reset_if_empty must NOT count it as a pending item.
# (a) the note survives a drain-triggered rewrite verbatim; (b) reset-if-empty deletes a
# plan whose only non-checked block is interstitial (the not-interstitial guard).
LCI="$TMP/lc5/.planwright"; mkdir -p "$LCI"
cat > "$LCI/plan.md" <<'EOF'
# planwright Plan — .

- [x] A finished item
      Mode: improve
      Verification: true

## A human note between blocks

- [ ] A surviving pending item
      Mode: docs
      Surfaces: README.md
      Verification: true
EOF
python3 "$LC" housekeep --root "$LCI" >/dev/null
ipend="$(grep -c '^- \[ \]' "$LCI/plan.md" 2>/dev/null || true)"
if [ -f "$LCI/plan.md" ] && [ "$ipend" = "1" ] \
   && grep -qF '## A human note between blocks' "$LCI/plan.md" \
   && grep -q '^- \[x\] A finished item' "$LCI/completed.md"; then
  ok "lifecycle.py preserves non-indented interstitial text across a drain-rewrite"
else
  bad "lifecycle.py dropped or mishandled interstitial text (pending=$ipend)"
fi
LCN="$TMP/lc5b/.planwright"; mkdir -p "$LCN"
cat > "$LCN/plan.md" <<'EOF'
# planwright Plan — .

- [x] A done item
      Mode: docs
      Verification: true

## A leftover interstitial note, no pending item
EOF
python3 "$LC" reset-if-empty --root "$LCN" >/dev/null
if [ ! -f "$LCN/plan.md" ]; then
  ok "lifecycle.py reset-if-empty deletes a plan whose only non-checked block is interstitial"
else
  bad "lifecycle.py kept a plan with no pending item (interstitial miscounted as pending)"
fi

# --- Test L6: lifecycle.py rejects a --root carrying parent-directory traversal ----
# main() guards its os.remove deletion boundary by rejecting a --root with a `..`
# component (commit 1dfbac4), exiting non-zero with a diagnostic before touching disk.
SENTINEL="$TMP/lc6_sentinel.txt"; printf 'keep\n' > "$SENTINEL"
trav_rc=0
trav_out="$(python3 "$LC" housekeep --root "../escape" 2>&1)" || trav_rc=$?
if [ "$trav_rc" -ne 0 ] && printf '%s' "$trav_out" | grep -qF "parent-directory traversal" \
   && [ -f "$SENTINEL" ]; then
  ok "lifecycle.py rejects a --root containing parent-directory traversal"
else
  bad "lifecycle.py accepted a traversal --root (rc=$trav_rc)"
fi

# --- Test L7: housekeep --json emits a structured report (parity with the siblings) -
# A CI/wrapper consumes {command,compacted,rejected_drained,plan_deleted} instead of
# parsing the "lifecycle: ..." text line. One completed + one rejected + one pending ->
# compacted 1, rejected_drained 1, plan_deleted false. --quiet still wins (no output).
LCJ="$TMP/lc7/.planwright"; mkdir -p "$LCJ"
cat > "$LCJ/plan.md" <<'EOF'
# planwright Plan — .

- [x] done
      Mode: improve
      Verification: true

- [ ] keep
      Mode: docs
      Surfaces: README.md
      Verification: true

- [ ] drop
      Mode: repair
      Status: Rejected
      Rejection: verification planwright_x failed: boom
      Verification: true
EOF
jout="$(python3 "$LC" housekeep --root "$LCJ" --json)"
if printf '%s' "$jout" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["command"]=="housekeep" and d["compacted"]==1 and d["rejected_drained"]==1 and d["plan_deleted"] is False' 2>/dev/null; then
  ok "lifecycle.py housekeep --json emits a structured compacted/rejected_drained/plan_deleted report"
else
  bad "lifecycle.py housekeep --json wrong (out='$jout')"
fi
qjout="$(python3 "$LC" reset-if-empty --root "$LCJ" --json --quiet)"
if [ -z "$qjout" ]; then
  ok "lifecycle.py --quiet suppresses output even with --json"
else
  bad "lifecycle.py --quiet did not suppress --json output (out='$qjout')"
fi

# --- Test L8: writes are atomic — content is correct and no temp file is left ------
# lifecycle.write() renders to a same-dir temp then os.replace()s it, so an interrupted
# housekeep can never truncate plan/completed/rejected. The observable signatures: the
# drained content is correct AND no leftover .lifecycle-*.tmp remains in the dir.
LCA="$TMP/lc8/.planwright"; mkdir -p "$LCA"
cat > "$LCA/plan.md" <<'EOF'
# planwright Plan — .

- [x] done one
      Mode: docs
      Surfaces: README.md
      Verification: true

- [ ] still pending
      Mode: docs
      Surfaces: README.md
      Verification: true
EOF
python3 "$LC" housekeep --root "$LCA" >/dev/null
tmpleft="$(find "$LCA" -name '.lifecycle-*.tmp' 2>/dev/null | wc -l | tr -d ' ')"
comp_done="$(grep -c '^- \[x\] done one' "$LCA/completed.md" 2>/dev/null || echo 0)"
plan_pending="$(grep -c '^- \[ \] still pending' "$LCA/plan.md" 2>/dev/null || echo 0)"
if [ "$tmpleft" = "0" ] && [ "$comp_done" = "1" ] && [ "$plan_pending" = "1" ]; then
  ok "lifecycle.py write is atomic: correct drained content and no leftover temp file"
else
  bad "lifecycle.py atomic write wrong (tmpleft=$tmpleft comp_done=$comp_done plan_pending=$plan_pending)"
fi

# --- Test L9: reset clears .planwright for a cold start but KEEPS rejected.md -----------
# `lifecycle.py reset` (aka fresh/clean) removes graph/plan/final/completed/digest/state so
# the next run rebuilds from scratch, but preserves rejected.md in place — the rejection
# feedback memory (not in git, does not regenerate) keeps the cold-start run from
# re-proposing already-rejected work. No backup is made (nothing to accumulate).
LCR="$TMP/lc9/.planwright"; mkdir -p "$LCR/sub"
printf 'plan\n' > "$LCR/plan.md"; printf '{}\n' > "$LCR/graph.json"; printf 'fp\n' > "$LCR/final.md"
printf 'comp\n' > "$LCR/completed.md"; printf 'n\n' > "$LCR/sub/nested.txt"
printf -- '- [ ] a bad idea\n      Rejection: value-gate: no consumer\n' > "$LCR/rejected.md"
rout="$(python3 "$LC" reset --root "$LCR")"
if [ ! -e "$LCR/plan.md" ] && [ ! -e "$LCR/graph.json" ] && [ ! -e "$LCR/final.md" ] \
   && [ ! -e "$LCR/completed.md" ] && [ ! -e "$LCR/sub" ] && [ ! -e "$LCR/.backups" ] \
   && [ -f "$LCR/rejected.md" ] && grep -q 'a bad idea' "$LCR/rejected.md" \
   && printf '%s' "$rout" | grep -q 'kept rejected.md'; then
  ok "lifecycle.py reset clears .planwright for a cold start but keeps rejected.md in place"
else
  bad "lifecycle.py reset did not clear+keep correctly (out='$rout')"
fi
# a dir holding only the kept rejected.md (nothing left to clear) is a clean no-op
nrout="$(python3 "$LC" reset --root "$LCR")"
if printf '%s' "$nrout" | grep -q 'nothing to reset'; then
  ok "lifecycle.py reset is a clean no-op when only rejected.md remains"
else
  bad "lifecycle.py reset did not no-op when only the kept file remains (out='$nrout')"
fi
# --json reports cleared + rejected_kept; with no rejected.md present, rejected_kept is false
LCR2="$TMP/lc9b/.planwright"; mkdir -p "$LCR2"
printf 'plan\n' > "$LCR2/plan.md"; printf '{}\n' > "$LCR2/graph.json"
jrout="$(python3 "$LC" reset --root "$LCR2" --json)"
if [ ! -e "$LCR2/plan.md" ] && [ ! -e "$LCR2/graph.json" ] \
   && printf '%s' "$jrout" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["command"]=="reset" and d["cleared"]==2 and d["rejected_kept"] is False' 2>/dev/null; then
  ok "lifecycle.py reset --json reports cleared count and rejected_kept=false when no rejected.md"
else
  bad "lifecycle.py reset --json wrong (out='$jrout')"
fi
# reset is destructive, so it must honour main()'s parent-traversal guard
rt_rc=0
python3 "$LC" reset --root "../escape" >/dev/null 2>&1 || rt_rc=$?
if [ "$rt_rc" -ne 0 ]; then
  ok "lifecycle.py reset rejects a --root containing parent-directory traversal"
else
  bad "lifecycle.py reset accepted a traversal --root (destructive command unguarded)"
fi
# the `fresh` and `clean` aliases route to the same reset (canonical command name in --json)
LCR3="$TMP/lc9c/.planwright"; mkdir -p "$LCR3"
printf 'p\n' > "$LCR3/plan.md"
fout="$(python3 "$LC" fresh --root "$LCR3" --json)"
printf 'p\n' > "$LCR3/plan.md"
cout="$(python3 "$LC" clean --root "$LCR3" --json)"
if printf '%s' "$fout" | python3 -c 'import json,sys; assert json.load(sys.stdin)["command"]=="reset"' 2>/dev/null \
   && printf '%s' "$cout" | python3 -c 'import json,sys; assert json.load(sys.stdin)["command"]=="reset"' 2>/dev/null; then
  ok "lifecycle.py accepts the fresh/clean aliases (both route to reset)"
else
  bad "lifecycle.py fresh/clean aliases did not route to reset (fresh='$fout' clean='$cout')"
fi
