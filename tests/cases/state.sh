# SPDX-FileCopyrightText: 2026 Eser KUBALI
# SPDX-License-Identifier: GPL-3.0-or-later
# shellcheck shell=bash
#
# scripts/state.py — machine-readable state.json emitter for the dashboard.
# Sourced by tests/run.sh after tests/lib.sh — NOT standalone (uses ROOT/TMP/ok/bad).

STATE="$ROOT/scripts/state.py"

# --- Test ST1: real repo --out - emits JSON carrying every top-level key ----------
rc=0; out="$(python3 "$STATE" --root "$ROOT" --out -)" || rc=$?
if [ "$rc" = "0" ] \
   && printf '%s' "$out" | grep -q '"schema_version": 1' \
   && printf '%s' "$out" | grep -q '"pending":' \
   && printf '%s' "$out" | grep -q '"completed":' \
   && printf '%s' "$out" | grep -q '"rejected":' \
   && printf '%s' "$out" | grep -q '"final_point":' \
   && printf '%s' "$out" | grep -q '"graph":' \
   && printf '%s' "$out" | grep -q '"counts":'; then
  ok "state.py --out - is exit 0 and carries schema_version + all top-level keys"
else
  bad "state.py --out - missing a top-level key or non-zero exit (rc=$rc)"
fi

# --- Test ST2: pending items carry the full 8-field body, surfaces as arrays -------
# A dashboard needs each pending item's whole body, not just the title; Surfaces/New
# Surfaces must be parsed from the comma-separated value into JSON arrays.
SFX="$TMP/state-fix"; mkdir -p "$SFX/.planwright"
printf -- '- [ ] do a thing\n      Mode: develop\n      Rationale: because reasons\n      Evidence: scripts/x.py:1 foo\n      Surfaces: a.py, b.py\n      New Surfaces: c.py\n      Development: edit foo()\n      Acceptance: it works\n      Verification: bash tests/run.sh\n' \
  > "$SFX/.planwright/plan.md"
python3 "$STATE" --root "$SFX" --out -  >/dev/null   # smoke: must not crash
if python3 "$STATE" --root "$SFX" --out - | python3 -c '
import json, sys
s = json.load(sys.stdin)
assert len(s["pending"]) == 1, s["pending"]
p = s["pending"][0]
assert p["title"] == "do a thing", p
assert p["mode"] == "develop", p
assert p["surfaces"] == ["a.py", "b.py"], p
assert p["new_surfaces"] == ["c.py"], p
assert p["verification"] == "bash tests/run.sh", p
assert s["counts"]["pending"] == 1, s["counts"]
'; then
  ok "state.py parses a pending item's full 8-field body and splits surfaces into arrays"
else
  bad "state.py mis-parsed the pending item body"
fi

# --- Test ST3: completed items are listed; rejected carry their reason -------------
CFX="$TMP/state-completed"; mkdir -p "$CFX/.planwright"
printf -- '- [x] shipped it\n      Mode: develop\n' > "$CFX/.planwright/completed.md"
printf -- '- [ ] bad idea\n      Status: Rejected\n      Rejection: value-gate: no consumer\n' \
  > "$CFX/.planwright/rejected.md"
if python3 "$STATE" --root "$CFX" --out - | python3 -c '
import json, sys
s = json.load(sys.stdin)
assert [c["title"] for c in s["completed"]] == ["shipped it"], s["completed"]
assert s["completed"][0]["mode"] == "develop", s["completed"]
assert s["rejected"][0]["title"] == "bad idea", s["rejected"]
assert "value-gate" in s["rejected"][0]["reason"], s["rejected"]
assert s["counts"]["completed"] == 1 and s["counts"]["rejected"] == 1, s["counts"]
'; then
  ok "state.py lists completed items with mode and rejected items with reason"
else
  bad "state.py mis-listed completed/rejected items"
fi

# --- Test ST3b: rejected count reconciles with the rejected[] array on a bad marker ----
# counts.rejected must equal len(rejected[]) even when rejected.md carries a non-canonical
# marker (e.g. `- [-]`): the count is derived from the same canonical parser as the array,
# not a loose `- [` prefix scan that would over-count the malformed line.
RCX="$TMP/state-reject-recon"; mkdir -p "$RCX/.planwright"
printf -- '- [-] partial reject\n      Rejection: nope\n- [ ] valid reject\n      Rejection: yes\n' \
  > "$RCX/.planwright/rejected.md"
if python3 "$STATE" --root "$RCX" --out - | python3 -c '
import json, sys
s = json.load(sys.stdin)
assert s["counts"]["rejected"] == len(s["rejected"]), (s["counts"]["rejected"], len(s["rejected"]))
assert s["counts"]["rejected"] == 1, s["counts"]["rejected"]
'; then
  ok "state.py rejected count reconciles with the rejected[] array on a non-canonical marker"
else
  bad "state.py rejected count disagrees with the rejected[] array"
fi

# --- Test ST4: --out writes .planwright/state.json by default ---------------------
OFX="$TMP/state-out"; mkdir -p "$OFX/.planwright"
printf -- '- [ ] one\n      Mode: improve\n' > "$OFX/.planwright/plan.md"
python3 "$STATE" --root "$OFX" >/dev/null
if [ -f "$OFX/.planwright/state.json" ] \
   && python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$OFX/.planwright/state.json"; then
  ok "state.py writes valid JSON to .planwright/state.json by default"
else
  bad "state.py did not write a valid default .planwright/state.json"
fi

# --- Test ST5: an empty .planwright degrades to empty arrays, exit 0 --------------
EFX="$TMP/state-empty"; mkdir -p "$EFX/.planwright"
if python3 "$STATE" --root "$EFX" --out - | python3 -c '
import json, sys
s = json.load(sys.stdin)
assert s["pending"] == [] and s["completed"] == [] and s["rejected"] == [], s
assert s["counts"] == {"pending": 0, "completed": 0, "rejected": 0}, s["counts"]
'; then
  ok "state.py degrades to empty arrays on an empty .planwright (valid state, exit 0)"
else
  bad "state.py did not degrade cleanly on an empty .planwright"
fi

# --- Test ST6: checked (done-but-undrained) items never leak into the pending array
# During `execute` an item is flipped to `- [x]` in plan.md before lifecycle drains it
# to completed.md. The `pending` list must mirror counts.pending (which counts only
# `- [ ]`), so a transient checked line must not appear in `pending`.
MFX="$TMP/state-mixed"; mkdir -p "$MFX/.planwright"
printf -- '- [ ] first pending\n      Mode: improve\n- [x] done not drained\n      Mode: repair\n- [ ] second pending\n      Mode: develop\n' \
  > "$MFX/.planwright/plan.md"
if python3 "$STATE" --root "$MFX" --out - | python3 -c '
import json, sys
s = json.load(sys.stdin)
titles = [p["title"] for p in s["pending"]]
assert titles == ["first pending", "second pending"], titles
assert len(s["pending"]) == s["counts"]["pending"] == 2, (s["pending"], s["counts"])
assert "done not drained" not in titles, titles
'; then
  ok "state.py keeps checked plan.md items out of pending (pending length reconciles with counts.pending)"
else
  bad "state.py leaked a checked item into the pending array"
fi

# --- Test ST-nonutf8: state.py degrades on a non-UTF-8 plan.md (mirrors status.py) -----
# state.py._parse_items reads UTF-8; a non-UTF-8 plan.md/completed.md raises
# UnicodeDecodeError (a ValueError subclass) and must degrade to [] (exit 0) like status.py's
# readers, not crash the dashboard's machine-state emitter.
NUS="$TMP/state-nonutf8"; mkdir -p "$NUS/.planwright"
printf '\377\376garbage\n' > "$NUS/.planwright/plan.md"
nus_rc=0; nus="$(python3 "$STATE" --root "$NUS" --out - 2>/dev/null)" || nus_rc=$?
if [ "$nus_rc" = 0 ] && printf '%s' "$nus" | python3 -c 'import json,sys; s=json.load(sys.stdin); assert s["counts"]["pending"]==0 and s["pending"]==[], s'; then
  ok "state.py degrades (exit 0) on a non-UTF-8 plan.md instead of crashing"
else
  bad "state.py crashed or mis-rendered on a non-UTF-8 plan.md (rc=$nus_rc)"
fi

# --- Test ST7: converged + final_point validity/scope passthrough (dashboard's verdict) --
# state.py is the snapshot the read-only dashboard consumes: console.js reads
# state.converged; derive.js reads final_point.valid / final_point.scope. status.sh pins
# all of this for status.py, but the dashboard reads the state.py snapshot — so a regression
# dropping `converged`, mis-deriving it, or dropping final_point.valid/scope would pass the
# whole suite while corrupting the dashboard's central CONVERGED verdict. Mirror status.sh
# STS9/STS9b/STS11 at the state.py surface. A lint-final-clean body ($1 = sha) so the
# converged case is not refused by the final.md-validity check.
_st_final() { printf 'sha: %s\ndate: 2026-06-09\ndeepest_tier: expand\nrepair: dry\ncoverage: dry\nopportunity: dry\nvision: dry\n' "$1"; }
SVX="$TMP/state-converged"; mkdir -p "$SVX/.planwright"
if ( cd "$SVX" && git init -q && git config user.email t@t && git config user.name t \
      && git commit -q --allow-empty -m init ) 2>/dev/null; then
  svhead="$(git -C "$SVX" rev-parse HEAD)"
  # (a) current, VALID final point, 0 pending -> converged:true, final_point.valid:true
  _st_final "$svhead" > "$SVX/.planwright/final.md"
  ok_json="$(python3 "$STATE" --root "$SVX" --out -)"
  # (b) HEAD-matching but rungless (malformed) -> converged:false, final_point.valid:false
  printf 'sha: %s\ndeepest_tier: expand\n' "$svhead" > "$SVX/.planwright/final.md"
  bad_json="$(python3 "$STATE" --root "$SVX" --out -)"
  # (c) component-scoped point -> final_point.scope surfaced, converged:false
  { _st_final "$svhead"; printf 'scope: path:src/auth\nscope_focus_sha: abc123def456\n'; } \
    > "$SVX/.planwright/final.md"
  scoped_json="$(python3 "$STATE" --root "$SVX" --out -)"
  if printf '%s' "$ok_json" | python3 -c '
import json, sys
s = json.load(sys.stdin)
assert s["converged"] is True, s["converged"]
assert s["final_point"]["valid"] is True, s["final_point"]
' \
     && printf '%s' "$bad_json" | python3 -c '
import json, sys
s = json.load(sys.stdin)
assert s["converged"] is False, s["converged"]
assert s["final_point"]["valid"] is False, s["final_point"]
' \
     && printf '%s' "$scoped_json" | python3 -c '
import json, sys
s = json.load(sys.stdin)
assert s["final_point"]["scope"] == "path:src/auth", s["final_point"]
assert s["converged"] is False, s["converged"]
'; then
    ok "state.py emits converged + final_point.valid/scope the dashboard reads (clean/malformed/scoped)"
  else
    bad "state.py converged or final_point validity/scope passthrough is wrong"
  fi
else
  ok "state.py converged/final_point check skipped (git unavailable)"
fi

# --- Test ST8: state.py forwards the graph-block content (the dashboard graph view reads it) ---
# state.py forwards status.collect's graph summary (node_count, dirty_node_count, stale,
# frontier) verbatim; the dashboard's graph view + staleness banner consume it. ST1 only
# checks the bare "graph" key, so pin the CONTENT here, plus the corrupt-graph -> null
# degradation (status.sh STS7/STS15 pin this for status.py, not the state.py snapshot).
GBX="$TMP/state-graph"; mkdir -p "$GBX/.planwright"
cat > "$GBX/.planwright/graph.json" <<'JSON'
{
  "version": 1,
  "graph_built_at_sha": "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef",
  "nodes": { "a.py": {}, "b.py": {}, "c.py": {} },
  "dirty": { "nodes": ["a.py", "b.py"] },
  "frontier": { "never_audited": 4, "stale": 6 }
}
JSON
if python3 "$STATE" --root "$GBX" --out - | python3 -c '
import json, sys
g = json.load(sys.stdin)["graph"]
assert g is not None, "graph block dropped"
assert g["node_count"] == 3, g
assert g["dirty_node_count"] == 2, g
assert g["frontier"] == {"never_audited": 4, "stale": 6}, g
'; then
  ok "state.py forwards the graph block content (node_count, dirty_node_count, frontier) from a fixture"
else
  bad "state.py graph-block content passthrough wrong"
fi
# a corrupt (valid JSON, wrong shape) graph.json -> the graph block degrades to null, exit 0
printf '[]' > "$GBX/.planwright/graph.json"
gc_rc=0; gc_out="$(python3 "$STATE" --root "$GBX" --out -)" || gc_rc=$?
if [ "$gc_rc" = 0 ] && printf '%s' "$gc_out" | python3 -c 'import json,sys; assert json.load(sys.stdin)["graph"] is None'; then
  ok "state.py degrades a corrupt (non-object) graph.json to a null graph block (exit 0)"
else
  bad "state.py did not degrade a corrupt graph.json to null (rc=$gc_rc)"
fi
