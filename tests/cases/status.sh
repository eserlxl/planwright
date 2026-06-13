# SPDX-FileCopyrightText: 2026 Eser KUBALI
# SPDX-License-Identifier: GPL-3.0-or-later
# shellcheck shell=bash
#
# scripts/status.py — read-only planning-state summary.
# Sourced by tests/run.sh after tests/lib.sh — NOT standalone (uses ROOT/TMP/ok/bad).

STAT="$ROOT/scripts/status.py"

# A lint-final-clean final.md body (sha + four dry rung reasons + a valid deepest_tier), so a
# fixture asserting convergence is not refused by status' final.md-validity check; $1 = sha.
_wf_final() { printf 'sha: %s\ndate: 2026-06-09\ndeepest_tier: expand\nrepair: dry\ncoverage: dry\nopportunity: dry\nvision: dry\n' "$1"; }

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

# --- Test STS6d: completed items are broken down by Mode (what kind of work landed) ----
# Symmetric to STS6b: report() appends a (mode N, ...) breakdown to the completed: line and
# --json carries completed_modes, reconciling with the completed total. An uppercase `- [X]`
# item is counted too (matches the case-insensitive completed count, STS10).
CMX="$TMP/status-cmodes"; mkdir -p "$CMX/.planwright"
printf -- '- [x] a\n      Mode: repair\n- [x] b\n      Mode: repair\n- [x] c\n      Mode: develop\n- [X] d\n      Mode: docs\n' > "$CMX/.planwright/completed.md"
crep="$(python3 "$STAT" --root "$CMX")"
cjson="$(python3 "$STAT" --root "$CMX" --json)"
if printf '%s' "$crep" | grep -qE '^  completed: 4  \(repair 2, develop 1, docs 1\)$' \
   && printf '%s' "$cjson" | python3 -c 'import json,sys; m=json.load(sys.stdin); cm=m["completed_modes"]; assert cm=={"repair":2,"develop":1,"docs":1}, cm; assert sum(cm.values())==m["completed"]==4, (cm,m["completed"])'; then
  ok "status.py breaks completed items down by mode (report + JSON, reconciles with total, case-insensitive)"
else
  bad "status.py completed-mode breakdown wrong: $crep"
fi
ECM="$TMP/status-cmodes-empty"; mkdir -p "$ECM/.planwright"
ecrep="$(python3 "$STAT" --root "$ECM")"
if printf '%s' "$ecrep" | grep -qE '^  completed: 0$'; then
  ok "status.py shows no completed-mode breakdown when nothing is completed"
else
  bad "status.py emitted a spurious completed-mode breakdown on an empty completed log"
fi

# --- Test STS6e: the newest landing surfaces with its Commit provenance stamp ------
# completed.md is append-ordered, so the LAST checked block is the most recent landing;
# the report names it (with the Commit: stamp's sha when present) and --json carries
# last_landed {title, commit}. Pre-stamp history degrades to a bare title (commit "");
# the empty fixture above must yield null and NO report line.
LLX="$TMP/status-lastland"; mkdir -p "$LLX/.planwright"
printf -- '- [x] old work\n      Mode: docs\n- [x] newest work\n      Mode: develop\n      Commit: abc1234\n' \
  > "$LLX/.planwright/completed.md"
llrep="$(python3 "$STAT" --root "$LLX")"
lljson="$(python3 "$STAT" --root "$LLX" --json)"
if printf '%s' "$llrep" | grep -qE '^  last landed: newest work \(abc1234\)$' \
   && printf '%s' "$lljson" | python3 -c 'import json,sys; m=json.load(sys.stdin); ll=m["last_landed"]; assert ll=={"title":"newest work","commit":"abc1234"}, ll' \
   && printf '%s' "$ecrep" | { ! grep -q 'last landed'; } \
   && python3 "$STAT" --root "$ECM" --json | python3 -c 'import json,sys; assert json.load(sys.stdin)["last_landed"] is None'; then
  ok "status.py surfaces the newest landing with its Commit stamp (report + JSON, null when empty)"
else
  bad "status.py last-landed surface wrong: $llrep"
fi

# --- Test STS6f: --ledger emits the full completed-work provenance ledger -----------
# Symmetric to STS6e's single last-landed: --ledger emits EVERY landed item as
# {title, mode, commit} in chronological (file) order, turning the Commit: stamps into a
# queryable record. Pre-stamp history yields commit ""; an empty completed.md yields [].
# The default report stays byte-additive (the flag short-circuits, like --recommend).
LGX="$TMP/status-ledger"; mkdir -p "$LGX/.planwright"
printf -- '- [x] old work\n      Mode: docs\n- [x] mid work\n      Mode: repair\n      Commit: abc1234\n- [x] new work\n      Mode: develop\n      Commit: def5678\n' \
  > "$LGX/.planwright/completed.md"
LGE="$TMP/status-ledger-empty"; mkdir -p "$LGE/.planwright"
lgout="$(python3 "$STAT" --root "$LGX" --ledger)"
if printf '%s' "$lgout" | python3 -c '
import json, sys
m = json.load(sys.stdin)
assert m == [
  {"title": "old work", "mode": "docs", "commit": ""},
  {"title": "mid work", "mode": "repair", "commit": "abc1234"},
  {"title": "new work", "mode": "develop", "commit": "def5678"},
], m
' \
   && [ "$(python3 "$STAT" --root "$LGE" --ledger)" = "[]" ] \
   && python3 "$STAT" --root "$LGX" | grep -q '^  completed:'; then
  ok "status.py --ledger emits the chronological {title,mode,commit} ledger (commit empty pre-stamp; [] when empty; report unchanged)"
else
  bad "status.py --ledger wrong: $lgout"
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

# --- Test STS7c: none-recorded final point + whitespace-only final.md fallbacks ----
# An empty .planwright must render the none-recorded final-point line and the graph-none
# line; a whitespace-only final.md (all fields blank) exercises report()'s ?/(?)/
# (unrecorded tier) empty-field fallbacks. Both were unpinned (STS7 only fed a full final.md).
EFX="$TMP/status-empty"; mkdir -p "$EFX/.planwright"
erep="$(python3 "$STAT" --root "$EFX")"
WFX="$TMP/status-wsfinal"; mkdir -p "$WFX/.planwright"
printf '   \n\n' > "$WFX/.planwright/final.md"
wrep="$(python3 "$STAT" --root "$WFX")"
if printf '%s' "$erep" | grep -qF 'final point: none recorded (the ladder is open)' \
   && printf '%s' "$erep" | grep -qF 'graph: none (run a plan to build .planwright/graph.json)' \
   && printf '%s' "$wrep" | grep -qE '^  final point: \? \(\?\) deepest_tier=\(unrecorded tier\)'; then
  ok "status.py renders the none-recorded final point and the empty-field fallbacks"
else
  bad "status.py empty/whitespace final-point rendering wrong (empty=[$erep] ws=[$wrep])"
fi

# --- Test STS7b: a corrupt (non-object / wrong-shape) graph file degrades, not crashes ---
# A graph file that is valid JSON but not an object (truncated or hand-edited write) must
# not crash status — the read-only command a wrapper/CI calls to check convergence. Each
# malformed shape should render "graph: none" and exit 0.
for bad_graph in '[]' '42' '{"nodes": 5}' '{"nodes": {}, "dirty": [1, 2]}'; do
  CGX="$TMP/status-corrupt"; mkdir -p "$CGX/.planwright"
  printf '%s\n' "$bad_graph" > "$CGX/.planwright/graph.json"
  if creport="$(python3 "$STAT" --root "$CGX" 2>/dev/null)" \
     && printf '%s' "$creport" | grep -q '^  graph: none' \
     && python3 "$STAT" --root "$CGX" --json >/dev/null 2>&1; then
    ok "status.py tolerates a corrupt graph file ($bad_graph) -> graph: none"
  else
    bad "status.py crashed or mis-rendered on a corrupt graph file: $bad_graph"
  fi
  rm -rf "$CGX"
done
# A dict graph with a numeric (non-str) graph_built_at_sha must not crash report()'s sha slice:
# the sha degrades to "?" while the node/dirty counts still render (the shape guard only protects
# collect()'s own .get()/len(), so the value is coerced to str in collect()).
NGX="$TMP/status-numsha"; mkdir -p "$NGX/.planwright"
printf '{"graph_built_at_sha": 42, "nodes": {"a":{},"b":{}}, "dirty": {"nodes":["a"]}}\n' > "$NGX/.planwright/graph.json"
if nrep="$(python3 "$STAT" --root "$NGX" 2>/dev/null)" \
   && printf '%s' "$nrep" | grep -qE '^  graph: 2 nodes, 1 dirty, built at \? \(STALE — HEAD has moved since the build\)$' \
   && python3 "$STAT" --root "$NGX" --json >/dev/null 2>&1; then
  ok "status.py tolerates a numeric graph_built_at_sha (sha -> '?', flagged stale, counts still render)"
else
  bad "status.py crashed or mis-rendered on a numeric graph_built_at_sha: $nrep"
fi

# --- Test STS7d: a non-UTF-8 (corrupt) plan-state file degrades, not crashes -------
# status is read-only and "never errors" — a non-UTF-8 final.md/plan.md (raises
# UnicodeDecodeError, a ValueError subclass, not OSError) must degrade like a corrupt
# graph.json (STS7b), not traceback. final.md -> none-recorded; plan.md -> 0 pending.
UFX="$TMP/status-nonutf8"; mkdir -p "$UFX/.planwright"
printf '\377\376bad bytes\n' > "$UFX/.planwright/final.md"
printf '\377\376bad bytes\n' > "$UFX/.planwright/plan.md"
urc=0; urep="$(python3 "$STAT" --root "$UFX" 2>/dev/null)" || urc=$?
ujrc=0; python3 "$STAT" --root "$UFX" --json >/dev/null 2>&1 || ujrc=$?
if [ "$urc" = 0 ] && [ "$ujrc" = 0 ] \
   && printf '%s' "$urep" | grep -qF 'final point: none recorded' \
   && printf '%s' "$urep" | grep -qE '^  pending:   0'; then
  ok "status.py degrades (exit 0) on a non-UTF-8 final.md/plan.md instead of tracebacking"
else
  bad "status.py crashed or mis-rendered on a non-UTF-8 plan-state file (rc=$urc json_rc=$ujrc)"
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
  # converged: current, VALID final point, no plan.md (0 pending) -> rc 0
  _wf_final "$echead" > "$ECX/.planwright/final.md"
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
  _wf_final "$cvhead" > "$CVX/.planwright/final.md"
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

# --- Test STS9b: a HEAD-matching but MALFORMED final.md does not certify convergence ----
# _converged now also requires the final.md to pass lint-final's contract, so a final.md
# whose sha matches HEAD with 0 pending but which is rungless (a lint-final violation) is
# reported converged:false / --exit-code rc 1, and the report flags it INVALID. This closes
# the hole where a blank/typo'd marker certified the north star on a bare sha match.
IVX="$TMP/status-invalid-final"; mkdir -p "$IVX/.planwright"
( cd "$IVX" && git init -q && git config user.email t@t && git config user.name t \
    && git commit -q --allow-empty -m init ) 2>/dev/null
ivhead="$(git -C "$IVX" rev-parse HEAD 2>/dev/null)"
if [ -n "$ivhead" ]; then
  # sha matches HEAD (not stale) but no rung reasons -> lint-final rejects it
  printf 'sha: %s\ndeepest_tier: expand\n' "$ivhead" > "$IVX/.planwright/final.md"
  iv_json="$(python3 "$STAT" --root "$IVX" --json)"
  iv_rep="$(python3 "$STAT" --root "$IVX")"
  iv_rc=0; python3 "$STAT" --root "$IVX" --exit-code --quiet || iv_rc=$?
  if printf '%s' "$iv_json" | grep -q '"converged": false' \
     && printf '%s' "$iv_json" | grep -q '"valid": false' \
     && [ "$iv_rc" = 1 ] \
     && printf '%s' "$iv_rep" | grep -q 'INVALID'; then
    ok "status.py refuses convergence for a HEAD-matching but malformed (rungless) final.md"
  else
    bad "status.py certified a malformed final.md (rc=$iv_rc json=$iv_json)"
  fi
else
  ok "status.py malformed-final-point check skipped (git unavailable)"
fi

# --- Test STS8b: a final point is NOT converged when HEAD is unconfirmable ----------
# When git is unavailable (or the target is not a work tree) _head_sha returns "", so the
# recorded sha cannot be shown to equal HEAD. status must then NOT report the point
# converged/current: --json carries converged:false / stale:true and --exit-code returns
# 1. Regression: a `bool(head) and ...` guard previously coerced an unconfirmable point to
# fresh, so a non-repo target falsely reported convergence (rc 0).
NGT="$TMP/status-nogit"; mkdir -p "$NGT/.planwright"
printf 'sha: abc1234567\ndeepest_tier: expand\n' > "$NGT/.planwright/final.md"
STUB="$TMP/nogit-bin"; mkdir -p "$STUB"
printf '#!/bin/sh\nexit 127\n' > "$STUB/git"; chmod +x "$STUB/git"
ngj="$(PATH="$STUB:$PATH" python3 "$STAT" --root "$NGT" --json)"
rc_ng=0; PATH="$STUB:$PATH" python3 "$STAT" --root "$NGT" --exit-code --quiet || rc_ng=$?
if printf '%s' "$ngj" | grep -q '"converged": false' \
   && printf '%s' "$ngj" | grep -q '"stale": true' \
   && [ "$rc_ng" = 1 ]; then
  ok "status.py is not converged when HEAD is unconfirmable (git off): converged:false, rc 1"
else
  bad "status.py wrongly reported convergence with git unavailable (rc=$rc_ng json=$ngj)"
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

# --- Test STS-CONSOLIDATE: status + state agree via the one canonical parser ----
# All plan-format parsing now routes through plan_parse, so the two JSON consumers
# (status.py summary, state.py snapshot) must agree on the same plan — including a
# WRAPPED field, which the old separate parsers handled differently (state.py did
# not join continuation lines). This pins the consolidation against future drift.
CONS="$TMP/consolidate-fix"; mkdir -p "$CONS/.planwright"
printf -- '- [ ] alpha\n      Mode: repair\n      Evidence: scripts/x.py:1\n        wrapped continuation\n- [ ] beta\n      Mode: improve\n' > "$CONS/.planwright/plan.md"
if python3 - "$STAT" "$ROOT/scripts/state.py" "$CONS" <<'PY'
import json, subprocess, sys
stat, statepy, root = sys.argv[1], sys.argv[2], sys.argv[3]
st = json.loads(subprocess.check_output(["python3", stat, "--root", root, "--json"]))
sv = json.loads(subprocess.check_output(["python3", statepy, "--root", root, "--out", "-"]))
assert st["pending"] == 2, st["pending"]
assert st["pending_modes"] == {"repair": 1, "improve": 1}, st["pending_modes"]
# state.py's pending titles + modes must match status's view of the same plan
assert st["pending_titles"] == [p["title"] for p in sv["pending"]], (st["pending_titles"], sv["pending"])
assert [p["mode"] for p in sv["pending"]] == ["repair", "improve"], sv["pending"]
# the wrapped Evidence is joined by the shared parser (old state.py dropped it)
ev = sv["pending"][0]["evidence"]
assert ev == "scripts/x.py:1 wrapped continuation", repr(ev)
print("CONSOLIDATE-OK")
PY
then ok "status.py + state.py agree on one plan via the shared canonical parser (incl. wrapped fields)"
else bad "status.py/state.py disagree — the consolidated parser drifted"; fi


# --- Test STS11: a component-scoped final point never certifies whole-repo convergence
# SKILL.md Stage 11: a scoped final point asserts dryness ONLY for that component.
# status dropped the scope: field on parse, so --exit-code certified the whole repo
# converged from a `scope: path:src/auth` point. The scope must be surfaced in --json,
# flagged in the report, and excluded from convergence; a whole-repo point still converges.
SCX="$TMP/status-scoped"; mkdir -p "$SCX/.planwright"
if ( cd "$SCX" && git init -q && git config user.email t@t && git config user.name t \
    && git commit -q --allow-empty -m init ) 2>/dev/null; then
  scx_sha="$(git -C "$SCX" rev-parse HEAD)"
  { _wf_final "$scx_sha"; printf 'scope: path:src/auth\nscope_focus_sha: abc123def456\n'; } \
    > "$SCX/.planwright/final.md"
  scx_json="$(python3 "$STAT" --root "$SCX" --json)"
  scx_rc=0; python3 "$STAT" --root "$SCX" --exit-code --quiet || scx_rc=$?
  scx_rep="$(python3 "$STAT" --root "$SCX")"
  # whole-repo control: same point without the scope lines must converge
  _wf_final "$scx_sha" > "$SCX/.planwright/final.md"
  scw_rc=0; python3 "$STAT" --root "$SCX" --exit-code --quiet || scw_rc=$?
  if printf '%s' "$scx_json" | python3 -c '
import json, sys
s = json.load(sys.stdin)
fp = s["final_point"]
assert fp["scope"] == "path:src/auth", fp
assert s["converged"] is False, s["converged"]
' && [ "$scx_rc" = 1 ] && [ "$scw_rc" = 0 ] \
     && printf '%s' "$scx_rep" | grep -q 'scoped to path:src/auth'; then
    ok "status.py surfaces a scoped final point and refuses whole-repo convergence on it"
  else
    bad "status.py scoped final point wrong (scoped_rc=$scx_rc whole_rc=$scw_rc)"
  fi
else
  ok "status.py scoped-final-point check skipped (git unavailable)"
fi


# --- Test STS12: the whole-repo sentinel is case-insensitive, matching lint-final ---
# lint-final lowercases before the sentinel test, so `scope: (Whole-Repo)` is a
# blessed whole-repo point — but status compared case-sensitively and treated it as
# a component scope, reporting a validator-clean point permanently unconverged.
SCS="$TMP/status-sentinel"; mkdir -p "$SCS/.planwright"
if ( cd "$SCS" && git init -q && git config user.email t@t && git config user.name t \
    && git commit -q --allow-empty -m init ) 2>/dev/null; then
  scs_sha="$(git -C "$SCS" rev-parse HEAD)"
  { _wf_final "$scs_sha"; printf 'scope: (Whole-Repo)\n'; } > "$SCS/.planwright/final.md"
  scs_rc=0; python3 "$STAT" --root "$SCS" --exit-code --quiet || scs_rc=$?
  scs_scope="$(python3 "$STAT" --root "$SCS" --json | python3 -c 'import json,sys;print(json.load(sys.stdin)["final_point"]["scope"])')"
  if [ "$scs_rc" = 0 ] && [ "$scs_scope" = "None" ]; then
    ok "status.py treats a case-variant (Whole-Repo) sentinel as whole-repo (converged, scope null)"
  else
    bad "status.py sentinel case handling diverges from lint-final (rc=$scs_rc scope=$scs_scope)"
  fi
else
  ok "status.py sentinel-case check skipped (git unavailable)"
fi


# --- Test STS13: the seeded-invent replay record reaches the status surface ---------
# final.md records invent_seed/invent_framing "so the run is replayable" and
# lint-final validates the pairing, but _parse_final dropped both — the
# replayability promise terminated at the raw file.
SIV="$TMP/status-inventseed"; mkdir -p "$SIV/.planwright"
if ( cd "$SIV" && git init -q && git config user.email t@t && git config user.name t \
    && git commit -q --allow-empty -m init ) 2>/dev/null; then
  siv_sha="$(git -C "$SIV" rev-parse HEAD)"
  { _wf_final "$siv_sha"; printf 'invent_seed: 7\ninvent_framing: integration\n'; } \
    > "$SIV/.planwright/final.md"
  siv_json="$(python3 "$STAT" --root "$SIV" --json)"
  siv_rep="$(python3 "$STAT" --root "$SIV")"
  if printf '%s' "$siv_json" | python3 -c '
import json, sys
fp = json.load(sys.stdin)["final_point"]
assert fp["invent_seed"] == "7", fp
assert fp["invent_framing"] == "integration", fp
' && printf '%s' "$siv_rep" | grep -q '(framing integration, seed 7)'; then
    ok "status.py surfaces invent_seed/invent_framing in --json and the report line"
  else
    bad "status.py dropped the seeded-invent replay record"
  fi
  # unseeded final points carry null, and the report omits the framing bit
  _wf_final "$siv_sha" > "$SIV/.planwright/final.md"
  if python3 "$STAT" --root "$SIV" --json | python3 -c '
import json, sys
fp = json.load(sys.stdin)["final_point"]
assert fp["invent_seed"] is None and fp["invent_framing"] is None, fp
'; then
    ok "status.py reports null invent_seed/invent_framing on an unseeded final point"
  else
    bad "status.py unseeded final point carries a non-null seed/framing"
  fi
else
  ok "status.py invent-seed check skipped (git unavailable)"
fi


# --- Test STS14: graph staleness surfaces on the status graph line ------------------
# status computed sha-lag staleness for the final point but hid the same signal for
# the graph — a maintainer could not see that the audit memory predates HEAD, the one
# staleness the dashboard already renders.
SGS="$TMP/status-graphstale"; mkdir -p "$SGS/.planwright"
if ( cd "$SGS" && git init -q && git config user.email t@t && git config user.name t \
    && git commit -q --allow-empty -m init ) 2>/dev/null; then
  sgs_sha="$(git -C "$SGS" rev-parse HEAD)"
  printf '{"graph_built_at_sha": "%s", "nodes": {"a.py": {}}, "dirty": {"nodes": []}}' "$sgs_sha" \
    > "$SGS/.planwright/graph.json"
  fresh_json="$(python3 "$STAT" --root "$SGS" --json)"
  ( cd "$SGS" && git commit -q --allow-empty -m move ) 2>/dev/null
  stale_json="$(python3 "$STAT" --root "$SGS" --json)"
  stale_rep="$(python3 "$STAT" --root "$SGS")"
  if printf '%s' "$fresh_json" | python3 -c 'import json,sys;assert json.load(sys.stdin)["graph"]["stale"] is False' \
     && printf '%s' "$stale_json" | python3 -c 'import json,sys;assert json.load(sys.stdin)["graph"]["stale"] is True' \
     && printf '%s' "$stale_rep" | grep -q 'STALE — HEAD has moved since the build'; then
    ok "status.py surfaces graph staleness in --json and flags it on the report line"
  else
    bad "status.py graph staleness wrong"
  fi
else
  ok "status.py graph-staleness check skipped (git unavailable)"
fi

# --- Test STS15: the audit frontier counts surface on the status graph line ---------
# build-graph.py emits frontier.never_audited/stale (the backlog the capped ranked
# lists hide); status must relay nonzero counts on the graph line and pass the block
# through --json, and a pre-frontier graph (no key) must render the line unchanged.
SFR="$TMP/status-frontier"; mkdir -p "$SFR/.planwright"
printf '{"graph_built_at_sha": "x", "nodes": {"a.py": {}}, "dirty": {"nodes": []}, "frontier": {"never_audited": 7, "stale": 43}}' \
  > "$SFR/.planwright/graph.json"
fr_rep="$(python3 "$STAT" --root "$SFR")"
fr_json="$(python3 "$STAT" --root "$SFR" --json)"
printf '{"graph_built_at_sha": "x", "nodes": {"a.py": {}}, "dirty": {"nodes": []}}' \
  > "$SFR/.planwright/graph.json"
fr_rep_old="$(python3 "$STAT" --root "$SFR")"
# corrupt counts (string instead of int) must be dropped at collect(), not crash report()'s %d
printf '{"graph_built_at_sha": "x", "nodes": {"a.py": {}}, "dirty": {"nodes": []}, "frontier": {"never_audited": "7", "stale": 0}}' \
  > "$SFR/.planwright/graph.json"
fr_rep_bad="$(python3 "$STAT" --root "$SFR" 2>/dev/null)"; fr_bad_rc=$?
if printf '%s' "$fr_rep" | grep -q 'audit frontier: 7 never-audited, 43 stale' \
   && printf '%s' "$fr_json" | python3 -c 'import json,sys;assert json.load(sys.stdin)["graph"]["frontier"] == {"never_audited": 7, "stale": 43}' \
   && printf '%s' "$fr_rep_old" | grep -q '^  graph: 1 nodes, 0 dirty' \
   && ! printf '%s' "$fr_rep_old" | grep -q 'audit frontier' \
   && [ "$fr_bad_rc" = 0 ] && ! printf '%s' "$fr_rep_bad" | grep -q 'audit frontier'; then
  ok "status.py surfaces audit frontier counts on the graph line and in --json (absent/corrupt keys degrade)"
else
  bad "status.py audit frontier counts wrong (bad_rc=$fr_bad_rc)"
fi

# --- Test STS-CARRIED: the carried-candidate backlog count from the planning digest --
# Stage 11 carries capacity-cut/deferred dossier findings under a "## Carried dossier
# candidates" heading; a converged-looking "0 pending" must not hide that backlog. The
# count tallies entry lines (a leading "[", optional "- " bullet) inside the section
# only — the UNVERIFIED banner, prose, and later sections never count. Absent digest =>
# carried 0 and NO carried line in the report (the common case stays noise-free).
CAR="$TMP/status-carried"; mkdir -p "$CAR/.planwright"
cat > "$CAR/.planwright/digest.md" <<'DIGEST'
# planwright digest — UNVERIFIED, routing only (never Evidence)

UNVERIFIED — routing only. Cluster summaries:

- 0 core (3): engine scripts, all clean.

## Carried dossier candidates

[coverage sev2, CUT — capacity] scripts/a.py:10 — claim one; fix: add test
- [repair sev1, DEFERRED — env] scripts/b.py:20 — claim two; fix: guard call

## Some later section

[not an entry — different section]
DIGEST
car_json="$(python3 "$STAT" --root "$CAR" --json)"
car_rep="$(python3 "$STAT" --root "$CAR")"
NOC="$TMP/status-nocarried"; mkdir -p "$NOC/.planwright"
noc_json="$(python3 "$STAT" --root "$NOC" --json)"
noc_rep="$(python3 "$STAT" --root "$NOC")"
if printf '%s' "$car_json" | grep -q '"carried": 2' \
   && printf '%s' "$car_rep" | grep -q '^  carried:   2 (cut/deferred dossier candidates' \
   && printf '%s' "$noc_json" | grep -q '"carried": 0' \
   && ! printf '%s' "$noc_rep" | grep -q 'carried:'; then
  ok "status.py counts carried dossier candidates (section-scoped) and stays silent at zero"
else
  bad "status.py carried-count wrong (car=[$(printf '%s' "$car_json" | grep -o '"carried": [0-9]*')] rep=[$car_rep])"
fi

# --- Test STS-BROKEN-VALIDATOR: a present-but-broken lint-final.py WARNS, not silent --
# status._load_lint_final degrades to the sha+pending convergence check when its sibling
# validator cannot load. A genuinely-absent validator degrades silently, but one that is
# PRESENT but broken (syntax/import error) must warn on stderr rather than silently disable
# the convergence gate (the fail-open hardening). status stays read-only (exit 0).
SBV="$TMP/status-broken-validator"; mkdir -p "$SBV/.planwright"
cp "$ROOT/scripts/status.py" "$ROOT/scripts/plan_parse.py" "$SBV/"
printf 'def collect(root):\n    this is a syntax error\n' > "$SBV/lint-final.py"
sbv_rc=0; sbv_err="$(python3 "$SBV/status.py" --root "$SBV" 2>&1 >/dev/null)" || sbv_rc=$?
if [ "$sbv_rc" = 0 ] && printf '%s' "$sbv_err" | grep -q "failed to load"; then
  ok "status.py warns when the sibling lint-final.py is present but broken (gate not silently disabled)"
else
  bad "status.py did not warn on a present-but-broken sibling lint-final.py (rc=$sbv_rc): $sbv_err"
fi

# --- Test STS17: the advise reference's by-hand fallback mirrors _reset_necessity ----
# references/advise.md carries a no-python3 fallback of the recommend() table in prose.
# Its invent-dry row must state the engine's reset-necessity ladder (_reset_necessity:
# seeded -> re-survey; undrained/unknown frontier -> harden; only unseeded AND drained ->
# reset) — a blanket "invent-dry -> reset" recommends a destructive move where the engine
# would not, the exact failure the "only when really necessary" design guards against.
ADV="$ROOT/skills/planwright/references/advise.md"
if python3 - "$ADV" <<'PY' 2>/dev/null
import sys
body = " ".join(open(sys.argv[1], encoding="utf-8").read().split())
assert "reset-necessity ladder, never a blanket reset" in body, "necessity ladder missing"
assert "re-survey via `codinventor`" in body, "seeded re-survey row missing"
assert "without wiping audit memory" in body, "undrained-frontier harden row missing"
assert "unseeded AND the frontier shown drained" in body, "reset precondition missing"
assert "`never_audited` == 0" in body, "drained-frontier predicate missing"
assert "nothing non-destructive remains" in body, "necessity polarity missing"
PY
then ok "advise.md by-hand fallback states the reset-necessity ladder (mirrors status.py _reset_necessity)"; else bad "advise.md by-hand fallback lost the reset-necessity ladder (blanket invent-dry reset)"; fi

# --- Test STS16: --recommend emits the full coach record end-to-end (CLI smoke) ------
# The canonical decision surface for `planwright advise` and /codmaster: the flag must
# emit parseable JSON carrying every record key, with the command inside the known
# dispatch vocabulary; a pending plan must route to execute (the drain-first row),
# exercising collect() through the CLI rather than the imported module.
REC="$TMP/status-recommend"; mkdir -p "$REC/.planwright"
PEN="$TMP/status-recommend-pending"; mkdir -p "$PEN/.planwright"
printf -- '- [ ] Drain me\n      Mode: develop\n      Verification: true\n' > "$PEN/.planwright/plan.md"
# One completed item exits the first-contact row (no graph + 0 completed deliberately
# shadows drain-first: a never-audited repo audits before executing hand-seeded items),
# so the pending fixture reaches the drain-first row it is pinning.
printf -- '- [x] Done thing\n      Mode: develop\n' > "$PEN/.planwright/completed.md"
rec_rc=0
python3 "$STAT" --root "$REC" --recommend >"$TMP/rec.json" 2>"$TMP/rec.err" || rec_rc=$?
python3 "$STAT" --root "$PEN" --recommend >"$TMP/rec-pending.json" 2>/dev/null || rec_rc=$?
if [ "$rec_rc" = 0 ] && python3 - "$TMP/rec.json" "$TMP/rec-pending.json" <<'PY' 2>/dev/null
import json, sys
r = json.load(open(sys.argv[1], encoding="utf-8"))
keys = {"base", "command", "args", "why", "mutating", "invent_class", "follow_up",
        "notes", "blockers", "evidence", "reset_nudge", "signals", "repo"}
missing = keys - set(r)
assert not missing, "missing record keys: %s" % sorted(missing)
known = {"execute", "codvisor", "codshard", "codinventor", "reset"}
assert r["command"] in known, "unknown dispatch: %r" % r["command"]
assert isinstance(r["mutating"], bool) and isinstance(r["invent_class"], bool)
assert isinstance(r["evidence"], list) and r["evidence"], "evidence chips empty"
pen = json.load(open(sys.argv[2], encoding="utf-8"))
assert pen["command"] == "execute", "drain-first row misrouted: %r" % pen["command"]
PY
then
  ok "status.py --recommend emits the full coach record (keys, known dispatch, drain-first row) via the CLI"
else
  bad "status.py --recommend CLI smoke failed (rc=$rec_rc): $(cat "$TMP/rec.err" 2>/dev/null)"
fi

# --- Test STS18: the run-activity beacon surfaces in the report and --json ----------
# Live: the report gains an `activity:` line naming the command/detail; --json carries
# the block. Stale (mtime pushed past the TTL): the line reads STALE with the cleanup
# hint. Absent: no line (the carried counter's zero-silence precedent), --json null.
AB="$TMP/status-activity"
mkdir -p "$AB/.planwright"
python3 "$ROOT/scripts/state.py" activity start codshard --detail "shard 3/5: scripts/" --root "$AB" >/dev/null
live_rep="$(python3 "$STAT" --root "$AB")"
live_cmd="$(python3 "$STAT" --root "$AB" --json | python3 -c 'import json,sys; a=json.load(sys.stdin)["activity"]; print(a["command"], a["stale"])')"
python3 - "$AB/.planwright/activity.json" <<'PY'
import os, sys, time
old = time.time() - 7200  # two hours back: past the default 3600 s TTL
os.utime(sys.argv[1], (old, old))
PY
stale_rep="$(python3 "$STAT" --root "$AB")"
python3 "$ROOT/scripts/state.py" activity stop --root "$AB" >/dev/null
gone_rep="$(python3 "$STAT" --root "$AB")"
gone_json="$(python3 "$STAT" --root "$AB" --json | python3 -c 'import json,sys; print(json.load(sys.stdin)["activity"])')"
if printf '%s' "$live_rep" | grep -q 'activity:  codshard — shard 3/5: scripts/ (run live — stamped' \
   && [ "$live_cmd" = "codshard False" ] \
   && printf '%s' "$stale_rep" | grep -q "activity:  STALE beacon 'codshard'" \
   && printf '%s' "$stale_rep" | grep -q 'state.py activity stop clears it' \
   && ! printf '%s' "$gone_rep" | grep -q 'activity:' \
   && [ "$gone_json" = "None" ]; then
  ok "status.py surfaces the run-activity beacon (live line, STALE past TTL, silent when absent)"
else
  bad "status.py beacon surfacing wrong (live=[$(printf '%s' "$live_rep" | grep 'activity:' || true)] stale=[$(printf '%s' "$stale_rep" | grep 'activity:' || true)])"
fi
