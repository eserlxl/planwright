# SPDX-FileCopyrightText: 2026 Eser KUBALI
# SPDX-License-Identifier: GPL-3.0-or-later
# shellcheck shell=bash
#
# scripts/status.py — read-only planning-state summary.
# Sourced by tests/run.sh after tests/lib.sh — NOT standalone (uses ROOT/TMP/ok/bad).

STAT="$ROOT/scripts/status.py"

# --- Test STS1: real repo --json is exit 0 and carries the state keys -------------
# Read-only: status never fails, so exit 0 even on an empty/partial .planwright.
rc=0; out="$(python3 "$STAT" --root "$ROOT" --json)" || rc=$?
if [ "$rc" = "0" ] \
   && printf '%s' "$out" | grep -q '"pending":' \
   && printf '%s' "$out" | grep -q '"completed":' \
   && printf '%s' "$out" | grep -q '"rejected":' \
   && printf '%s' "$out" | grep -q '"final_point":' \
   && printf '%s' "$out" | grep -q '"graph":'; then
  ok "status.py --json is exit 0 and carries pending/completed/rejected/final_point/graph"
else
  bad "status.py --json missing a state key or non-zero exit (rc=$rc)"
fi

# --- Test STS2: readable report header + count lines ------------------------------
rep="$(python3 "$STAT" --root "$ROOT")"
if printf '%s' "$rep" | grep -q '^planwright status — ' \
   && printf '%s' "$rep" | grep -qE '^  pending:   [0-9]+' \
   && printf '%s' "$rep" | grep -qE '^  completed: [0-9]+' \
   && printf '%s' "$rep" | grep -qE '^  rejected:  [0-9]+'; then
  ok "status.py readable report has the header and pending/completed/rejected lines"
else
  bad "status.py readable report is missing its header or count lines"
fi

# --- Test STS3: isolated fixture counts pending/completed/rejected exactly --------
FIX="$TMP/status-fix"; mkdir -p "$FIX/.planwright"
printf -- '- [ ] one\n- [ ] two\n' > "$FIX/.planwright/plan.md"
printf -- '- [x] done\n' > "$FIX/.planwright/completed.md"
printf -- '- [ ] nope\n      Status: Rejected\n' > "$FIX/.planwright/rejected.md"
fx="$(python3 "$STAT" --root "$FIX" --json)"
if printf '%s' "$fx" | grep -q '"pending": 2' \
   && printf '%s' "$fx" | grep -q '"completed": 1' \
   && printf '%s' "$fx" | grep -q '"rejected": 1'; then
  ok "status.py counts pending=2 / completed=1 / rejected=1 from a fixture .planwright"
else
  bad "status.py miscounted the fixture .planwright items"
fi

# --- Test STS4: final-point staleness is HEAD-relative in a git fixture -----------
# A final.md whose sha != HEAD is STALE; rewriting it to the real HEAD clears it.
GFIX="$TMP/status-git"; mkdir -p "$GFIX/.planwright"
( cd "$GFIX" && git init -q && git config user.email t@t && git config user.name t \
    && git commit -q --allow-empty -m init ) 2>/dev/null
head="$(git -C "$GFIX" rev-parse HEAD 2>/dev/null)"
if [ -n "$head" ]; then
  printf 'sha: 0000000000000000000000000000000000000000\ndeepest_tier: expand\n' \
    > "$GFIX/.planwright/final.md"
  stale="$(python3 "$STAT" --root "$GFIX" --json)"
  printf 'sha: %s\ndeepest_tier: expand\n' "$head" > "$GFIX/.planwright/final.md"
  fresh="$(python3 "$STAT" --root "$GFIX" --json)"
  if printf '%s' "$stale" | grep -q '"stale": true' \
     && printf '%s' "$fresh" | grep -q '"stale": false'; then
    ok "status.py marks a final point STALE off HEAD and current at HEAD"
  else
    bad "status.py staleness is not HEAD-relative"
  fi
else
  ok "status.py staleness check skipped (git unavailable)"
fi
