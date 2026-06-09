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
