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
   && printf '%s' "$out" | grep -q '"activity":' \
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
assert s["counts"] == {"pending": 0, "completed": 0, "rejected": 0, "carried": 0}, s["counts"]
'; then
  ok "state.py degrades to empty arrays on an empty .planwright (valid state, exit 0)"
else
  bad "state.py did not degrade cleanly on an empty .planwright"
fi

# --- Test ST5b: counts.carried rides state.json from the planning digest ----------
# status._carried_count tallies the digest's "## Carried dossier candidates" entries;
# state.collect must pass it through counts so the dashboard's one data contract can
# surface the verified-but-cut backlog a bare pending: 0 would hide.
CDX="$TMP/state-carried"; mkdir -p "$CDX/.planwright"
cat > "$CDX/.planwright/digest.md" <<'DIGEST'
# digest — UNVERIFIED, routing only

## Carried dossier candidates

[coverage sev2, CUT — capacity] a.py:1 — one; fix: f
[repair sev1, DEFERRED — env] b.py:2 — two; fix: g
DIGEST
if python3 "$STATE" --root "$CDX" --out - | python3 -c '
import json, sys
s = json.load(sys.stdin)
assert s["counts"]["carried"] == 2, s["counts"]
'; then
  ok "state.py surfaces counts.carried from the planning digest"
else
  bad "state.py counts.carried wrong"
fi

# --- Test ST7: the state.json artifact is written atomically (no temp residue) -----
# main() renders to a same-directory .state-*.tmp then os.replace()s it (mirroring
# lifecycle.write), so an interrupted write can never leave a torn state.json. The
# observable contract on a successful run: the artifact parses AND no temp residue
# remains beside it.
ATM="$TMP/state-atomic"; mkdir -p "$ATM/.planwright"
printf -- '- [ ] solo\n      Mode: improve\n' > "$ATM/.planwright/plan.md"
python3 "$STATE" --root "$ATM" >/dev/null 2>&1
if python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$ATM/.planwright/state.json" 2>/dev/null \
   && ! ls "$ATM/.planwright"/.state-*.tmp >/dev/null 2>&1; then
  ok "state.py writes state.json atomically (parseable artifact, no .state-*.tmp residue)"
else
  bad "state.py atomic write wrong (residue: $(find "$ATM/.planwright" -mindepth 1 2>/dev/null | tr '\n' ' '))"
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

# --- Test ST9: the run-activity beacon round-trip (start -> state.json -> stop) -----
# `state.py activity` is the writer the command flows use to tell the dashboard WHICH
# command is running; collect() shapes it into state.activity. Pin the whole loop:
# stamp, snapshot, clear, and the no-beacon null.
ABX="$TMP/state-activity"; mkdir -p "$ABX/.planwright"
if python3 "$STATE" activity start codmaster --detail "step 3/12: execute" --root "$ABX" >/dev/null \
   && python3 "$STATE" --root "$ABX" --out - | python3 -c '
import json, sys
a = json.load(sys.stdin)["activity"]
assert a is not None, "activity block missing while a beacon is stamped"
assert a["command"] == "codmaster", a
assert a["detail"] == "step 3/12: execute", a
assert isinstance(a["started"], str) and a["started"].endswith("Z"), a
assert a["stale"] is False and a["age_seconds"] >= 0, a
' \
   && python3 "$STATE" activity stop --root "$ABX" >/dev/null \
   && python3 "$STATE" --root "$ABX" --out - | python3 -c '
import json, sys
assert json.load(sys.stdin)["activity"] is None, "activity must be null after stop"
'; then
  ok "state.py activity start/stop round-trips through state.activity (command, detail, started, stale)"
else
  bad "state.py activity beacon round-trip wrong"
fi

# --- Test ST9b: re-stamp preserves started; --if-absent guards the orchestrator ----
# An orchestrator updating --detail between steps keeps one run clock (started is
# preserved on a same-command re-stamp); an inner flow's `start --if-absent` must
# never clobber another command's live beacon, while the same command writes through.
AB2="$TMP/state-activity-nest"; mkdir -p "$AB2/.planwright"
python3 "$STATE" activity start codshard --root "$AB2" >/dev/null
ab2_started="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["started"])' "$AB2/.planwright/activity.json")"
python3 "$STATE" activity start codshard --detail "shard 2/5: docs/" --root "$AB2" >/dev/null
ab2_kept="$(python3 "$STATE" activity start plan --if-absent --root "$AB2")"
ab2_refresh="$(python3 "$STATE" activity start codshard --if-absent --detail "shard 3/5: tests/" --root "$AB2")"
if python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
assert d["command"] == "codshard", d
assert d["started"] == sys.argv[2], (d["started"], sys.argv[2])
assert d["detail"] == "shard 3/5: tests/", d
' "$AB2/.planwright/activity.json" "$ab2_started" \
   && printf '%s' "$ab2_kept" | grep -q "kept codshard" \
   && printf '%s' "$ab2_refresh" | grep -q "started codshard"; then
  ok "state.py activity re-stamp keeps started; --if-absent keeps another live beacon but lets the owner refresh"
else
  bad "state.py activity nesting semantics wrong (kept='$ab2_kept' refresh='$ab2_refresh')"
fi

# --- Test ST9c: a guarded stop never erases the orchestrator's beacon ---------------
# SKILL.md's inner flows run `activity stop <name>`: it removes only a beacon that
# command owns, so a plan flow finishing under codmaster leaves codmaster's beacon up.
ab3_kept="$(python3 "$STATE" activity stop plan --root "$AB2")"
ab3_kept_file=0; [ -f "$AB2/.planwright/activity.json" ] && ab3_kept_file=1
ab3_gone="$(python3 "$STATE" activity stop codshard --root "$AB2")"
ab3_none="$(python3 "$STATE" activity stop --root "$AB2")"
if printf '%s' "$ab3_kept" | grep -q "kept codshard" \
   && [ "$ab3_kept_file" = "1" ] \
   && printf '%s' "$ab3_gone" | grep -q "stopped codshard" \
   && [ ! -f "$AB2/.planwright/activity.json" ] \
   && printf '%s' "$ab3_none" | grep -q "none"; then
  ok "state.py activity stop is owner-guarded with a name, unconditional bare, idempotent when absent"
else
  bad "state.py activity stop guard wrong (kept='$ab3_kept' gone='$ab3_gone' none='$ab3_none')"
fi

# --- Test ST9d: staleness — TTL from mtime, PW_ACTIVITY_TTL override, stale takeover ---
# An interrupted run leaves activity.json behind with no process to clean it up; the
# mtime is the one signal a leftover cannot keep current. Past the TTL the block reads
# stale, and `start --if-absent` treats it as absent (the next run takes the beacon over).
AB4="$TMP/state-activity-stale"; mkdir -p "$AB4/.planwright"
python3 "$STATE" activity start codcycle --root "$AB4" >/dev/null
touch -d '2 hours ago' "$AB4/.planwright/activity.json" 2>/dev/null || touch -t 202601010000 "$AB4/.planwright/activity.json"
ab4_stale="$(python3 "$STATE" --root "$AB4" --out - | python3 -c 'import json,sys; print(json.load(sys.stdin)["activity"]["stale"])')"
ab4_fresh="$(PW_ACTIVITY_TTL=999999 python3 "$STATE" --root "$AB4" --out - | python3 -c 'import json,sys; print(json.load(sys.stdin)["activity"]["stale"])')"
ab4_takeover="$(python3 "$STATE" activity start plan --if-absent --root "$AB4")"
if [ "$ab4_stale" = "True" ] && [ "$ab4_fresh" = "False" ] \
   && printf '%s' "$ab4_takeover" | grep -q "started plan"; then
  ok "state.py activity stale flips past the TTL (PW_ACTIVITY_TTL overrides) and --if-absent takes a stale beacon over"
else
  bad "state.py activity staleness wrong (stale=$ab4_stale fresh=$ab4_fresh takeover='$ab4_takeover')"
fi

# --- Test ST9d2: a same-name re-stamp over a STALE leftover resets started ----------
# started-preservation exists so an orchestrator's --detail re-stamps keep one run
# clock — within a LIVE run. A stale same-name leftover is a dead run; the next run
# wearing the same name must get a fresh clock, never the dead run's `since` stamp.
AB4B="$TMP/state-activity-stale-samename"; mkdir -p "$AB4B/.planwright"
python3 "$STATE" activity start codmaster --root "$AB4B" >/dev/null
python3 - "$AB4B/.planwright/activity.json" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p)); d["started"] = "2026-06-11T03:00:00Z"
json.dump(d, open(p, "w"))
PY
touch -d '2 hours ago' "$AB4B/.planwright/activity.json" 2>/dev/null || touch -t 202601010000 "$AB4B/.planwright/activity.json"
python3 "$STATE" activity start codmaster --root "$AB4B" >/dev/null
ab4b_started="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["started"])' "$AB4B/.planwright/activity.json")"
if [ "$ab4b_started" != "2026-06-11T03:00:00Z" ]; then
  ok "state.py activity same-name re-stamp over a stale leftover resets started (no dead run's clock)"
else
  bad "state.py activity inherited a dead run's started across the TTL ($ab4b_started)"
fi

# --- Test ST9e: degradation + hygiene — malformed beacon, atomic write, bad name ----
# A torn/hand-edited beacon must read as "no beacon" in the snapshot (the dashboard
# survives corrupt input), a bare stop self-heals it, the writer leaves no temp
# residue, and a shell-fragment command name is refused (exit 2) before it can become
# the dashboard's headline.
AB5="$TMP/state-activity-bad"; mkdir -p "$AB5/.planwright"
printf '{broken' > "$AB5/.planwright/activity.json"
ab5_null="$(python3 "$STATE" --root "$AB5" --out - | python3 -c 'import json,sys; print(json.load(sys.stdin)["activity"])')"
ab5_heal="$(python3 "$STATE" activity stop --root "$AB5")"
python3 "$STATE" activity start execute --root "$AB5" >/dev/null
ab5_badname_rc=0; python3 "$STATE" activity start 'BAD NAME!' --root "$AB5" >/dev/null 2>&1 || ab5_badname_rc=$?
if [ "$ab5_null" = "None" ] \
   && printf '%s' "$ab5_heal" | grep -q "cleared malformed" \
   && ! ls "$AB5/.planwright"/.activity-*.tmp >/dev/null 2>&1 \
   && [ "$ab5_badname_rc" = "2" ] \
   && python3 -c 'import json,sys; assert json.load(open(sys.argv[1]))["command"]=="execute"' "$AB5/.planwright/activity.json"; then
  ok "state.py activity degrades a malformed beacon to null, self-heals on stop, writes atomically, refuses a bad name (exit 2)"
else
  bad "state.py activity degradation/hygiene wrong (null='$ab5_null' heal='$ab5_heal' badname_rc=$ab5_badname_rc)"
fi
