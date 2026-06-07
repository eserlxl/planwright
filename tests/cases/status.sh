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

# --- Test STS6b: pending items are broken down by Mode (power-user composition) ----
# A power user judging plan maturity needs the repair/improve/develop mix, not just a
# flat count: the readable report appends a (mode N, ...) breakdown in canonical order
# and --json carries pending_modes; the counts reconcile with the pending total.
MFX="$TMP/status-modes"; mkdir -p "$MFX/.planwright"
printf -- '- [ ] a\n      Mode: repair\n- [ ] b\n      Mode: repair\n- [ ] c\n      Mode: improve\n- [ ] d\n      Mode: develop\n' > "$MFX/.planwright/plan.md"
mrep="$(python3 "$STAT" --root "$MFX")"
mjson="$(python3 "$STAT" --root "$MFX" --json)"
if printf '%s' "$mrep" | grep -qE '^  pending:   4  \(repair 2, improve 1, develop 1\)$' \
   && printf '%s' "$mjson" | python3 -c 'import json,sys; assert json.load(sys.stdin)["pending_modes"]=={"repair":2,"improve":1,"develop":1}'; then
  ok "status.py breaks pending items down by mode in canonical order (report + JSON)"
else
  bad "status.py pending-mode breakdown wrong: $mrep"
fi
EFX="$TMP/status-empty"; mkdir -p "$EFX/.planwright"
if python3 "$STAT" --root "$EFX" | grep -qE '^  pending:   0$'; then
  ok "status.py shows no mode breakdown when no items are pending"
else
  bad "status.py emitted a spurious mode breakdown on an empty plan"
fi

# --- Test STS6c: the "other" bucket — absent + unrecognized Mode lines --------------
# Items with no Mode line or an unrecognized Mode are tallied under "other" (placed
# last) so the per-mode counts always reconcile with the pending total. Exercise all
# three "other" branches at once: an unrecognized mode (b), a no-Mode item followed by
# another item (c), and a trailing no-Mode item (d).
OFX="$TMP/status-modes-other"; mkdir -p "$OFX/.planwright"
printf -- '- [ ] a\n      Mode: repair\n- [ ] b\n      Mode: bogus\n- [ ] c\n- [ ] d\n' > "$OFX/.planwright/plan.md"
orep="$(python3 "$STAT" --root "$OFX")"
ojson="$(python3 "$STAT" --root "$OFX" --json)"
if printf '%s' "$orep" | grep -qE '^  pending:   4  \(repair 1, other 3\)$' \
   && printf '%s' "$ojson" | python3 -c 'import json,sys; m=json.load(sys.stdin)["pending_modes"]; assert m=={"repair":1,"other":3}, m; assert sum(m.values())==4, m; assert list(m)[-1]=="other", m'; then
  ok "status.py tallies absent/unrecognized modes under \"other\" (last) and reconciles with pending"
else
  bad "status.py \"other\" mode bucket wrong: $orep"
fi

# --- Test STS11: rejected items surface their titles + Rejection reasons ----------
# status lists pending titles; for the feedback loop a power user also needs to see
# what was rejected and why without cat'ing rejected.md. The readable report lists the
# rejected title; --json carries a rejected_items array of {title, reason}. A rejected
# entry with only `Status: Rejected` (no Rejection: line) yields an empty reason.
RJX="$TMP/status-rejected"; mkdir -p "$RJX/.planwright"
printf -- '- [ ] flaky idea\n      Status: Rejected\n      Rejection: value-gate: real consumer — emits noise not signal\n- [ ] bare reject\n      Status: Rejected\n' \
  > "$RJX/.planwright/rejected.md"
rjj="$(python3 "$STAT" --root "$RJX" --json)"
rjr="$(python3 "$STAT" --root "$RJX")"
if printf '%s' "$rjj" | grep -q '"rejected_items"' \
   && printf '%s' "$rjj" | grep -q '"title": "flaky idea"' \
   && printf '%s' "$rjj" | grep -q 'value-gate: real consumer' \
   && printf '%s' "$rjj" | grep -q '"reason": ""' \
   && printf '%s' "$rjr" | grep -q '^    - flaky idea — value-gate: real consumer' \
   && printf '%s' "$rjr" | grep -q '^    - bare reject$'; then
  ok "status.py surfaces rejected titles + Rejection reasons (report + --json; empty reason ok)"
else
  bad "status.py did not surface rejected item titles/reasons"
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

# --- Test STS10: completed count is case-insensitive on the x marker --------------
# lifecycle.py / lint-plan.py accept an uppercase `- [X]` completed item; status must
# count it too, else progress is undercounted relative to what those tools recognize.
UCX="$TMP/status-upper"; mkdir -p "$UCX/.planwright"
printf -- '- [x] lower done\n- [X] upper done\n' > "$UCX/.planwright/completed.md"
ucx="$(python3 "$STAT" --root "$UCX" --json)"
if printf '%s' "$ucx" | grep -q '"completed": 2'; then
  ok "status.py counts an uppercase '- [X]' completed item (matches lifecycle/lint-plan)"
else
  bad "status.py undercounted an uppercase '- [X]' completed item"
fi
