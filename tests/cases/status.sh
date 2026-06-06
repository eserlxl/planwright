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

# --- Test STS6: pending titles are surfaced in the report and the JSON -----------
rep2="$(python3 "$STAT" --root "$FIX")"
if printf '%s' "$rep2" | grep -q '^    - one$' \
   && printf '%s' "$rep2" | grep -q '^    - two$' \
   && printf '%s' "$fx" | grep -q '"pending_titles"' \
   && printf '%s' "$fx" | grep -q '"two"'; then
  ok "status.py lists pending item titles in the readable report and --json"
else
  bad "status.py did not surface pending item titles"
fi

# --- Test STS7: graph block + final-point rendering from a fixture ----------------
# Feed a known graph (3 nodes, 2 dirty) and a final point; pin the counts and the
# report lines so a collect()/report() refactor cannot silently corrupt them.
GFX="$TMP/status-graph"; mkdir -p "$GFX/.planwright"
printf '{"graph_built_at_sha":"abc1234567","nodes":{"a":{},"b":{},"c":{}},"dirty":{"nodes":["a","b"]}}\n' \
  > "$GFX/.planwright/graph.json"
printf 'sha: abc1234567\ndate: 2026-06-07\ndeepest_tier: expand\n' > "$GFX/.planwright/final.md"
gj="$(python3 "$STAT" --root "$GFX" --json)"
grep_rep="$(python3 "$STAT" --root "$GFX")"
if printf '%s' "$gj" | grep -q '"node_count": 3' \
   && printf '%s' "$gj" | grep -q '"dirty_node_count": 2' \
   && printf '%s' "$grep_rep" | grep -qE '^  graph: 3 nodes, 2 dirty' \
   && printf '%s' "$grep_rep" | grep -q 'deepest_tier=expand'; then
  ok "status.py renders graph node/dirty counts and the final-point line from a fixture"
else
  bad "status.py graph block or final-point rendering is wrong"
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

# --- Test STS8: --exit-code maps convergence to a 0/1 exit status -----------------
# Opt-in exit code: 0 only at a *current* final point (sha == HEAD) with 0 pending;
# 1 when work is pending or the final point is stale/absent. The default (no flag)
# stays exit 0 always, so existing callers are unaffected.
ECX="$TMP/status-exitcode"; mkdir -p "$ECX/.planwright"
( cd "$ECX" && git init -q && git config user.email t@t && git config user.name t \
    && git commit -q --allow-empty -m init ) 2>/dev/null
echead="$(git -C "$ECX" rev-parse HEAD 2>/dev/null)"
if [ -n "$echead" ]; then
  # converged: current final point, no plan.md (0 pending) -> rc 0
  printf 'sha: %s\ndeepest_tier: expand\n' "$echead" > "$ECX/.planwright/final.md"
  rc_conv=0; python3 "$STAT" --root "$ECX" --exit-code --quiet || rc_conv=$?
  # default (no flag) still exits 0 even with a pending item present
  printf -- '- [ ] some pending item\n' > "$ECX/.planwright/plan.md"
  rc_default=0; python3 "$STAT" --root "$ECX" --quiet || rc_default=$?
  # pending work -> --exit-code rc 1
  rc_pending=0; python3 "$STAT" --root "$ECX" --exit-code --quiet || rc_pending=$?
  rm -f "$ECX/.planwright/plan.md"
  # stale final point (sha != HEAD), 0 pending -> --exit-code rc 1
  printf 'sha: 0000000000000000000000000000000000000000\ndeepest_tier: expand\n' \
    > "$ECX/.planwright/final.md"
  rc_stale=0; python3 "$STAT" --root "$ECX" --exit-code --quiet || rc_stale=$?
  if [ "$rc_conv" = 0 ] && [ "$rc_default" = 0 ] && [ "$rc_pending" = 1 ] \
     && [ "$rc_stale" = 1 ]; then
    ok "status.py --exit-code is 0 at a current final point, 1 when pending/stale; default stays 0"
  else
    bad "status.py --exit-code wrong (conv=$rc_conv default=$rc_default pending=$rc_pending stale=$rc_stale)"
  fi
else
  ok "status.py --exit-code check skipped (git unavailable)"
fi
# --- Test STS9: --json exposes a canonical `converged` boolean ---------------------
# The convergence verdict is surfaced as state["converged"] so a JSON consumer reads
# one boolean instead of re-deriving it; it must agree with the --exit-code result.
CVX="$TMP/status-converged"; mkdir -p "$CVX/.planwright"
( cd "$CVX" && git init -q && git config user.email t@t && git config user.name t \
    && git commit -q --allow-empty -m init ) 2>/dev/null
cvhead="$(git -C "$CVX" rev-parse HEAD 2>/dev/null)"
if [ -n "$cvhead" ]; then
  printf 'sha: %s\ndeepest_tier: expand\n' "$cvhead" > "$CVX/.planwright/final.md"
  conv_true="$(python3 "$STAT" --root "$CVX" --json)"
  printf -- '- [ ] pending\n' > "$CVX/.planwright/plan.md"
  conv_false="$(python3 "$STAT" --root "$CVX" --json)"
  if printf '%s' "$conv_true" | grep -q '"converged": true' \
     && printf '%s' "$conv_false" | grep -q '"converged": false'; then
    ok "status.py --json exposes a converged boolean that tracks the convergence state"
  else
    bad "status.py --json converged field missing or wrong"
  fi
else
  ok "status.py converged-field check skipped (git unavailable)"
fi
