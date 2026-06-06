# SPDX-FileCopyrightText: 2026 Eser KUBALI
# SPDX-License-Identifier: GPL-3.0-or-later
# shellcheck shell=bash
#
# scripts/doctor.py — environment preflight.
# Sourced by tests/run.sh after tests/lib.sh — NOT standalone (uses ROOT/TMP/ok/bad).

DOC="$ROOT/scripts/doctor.py"
PY="$(command -v python3)"

# --- Test DR1: healthy env reports ok=true, exit 0, all bundled scripts found ----
# Run against the real scripts/ dir (this repo) where every sibling exists and the
# target is a git work tree.
rc=0; out="$(python3 "$DOC" --root "$ROOT" --json)" || rc=$?
if [ "$rc" = "0" ] \
   && printf '%s' "$out" | grep -q '"ok": true' \
   && printf '%s' "$out" | grep -q '"fail": 0' \
   && printf '%s' "$out" | grep -q '"<scripts>/build-graph.py"' \
   && printf '%s' "$out" | grep -q '"<scripts>/lint-plan.py"' \
   && printf '%s' "$out" | grep -q '"<scripts>/lifecycle.py"'; then
  ok "doctor.py reports ok=true (exit 0) in a healthy env with all bundled scripts"
else
  bad "doctor.py did not pass in a healthy env (rc=$rc)"
fi

# --- Test DR2: readable report carries the verdict line + degrades for non-ok ----
rep="$(python3 "$DOC" --root "$ROOT")"
if printf '%s' "$rep" | grep -q '^planwright doctor — preflight' \
   && printf '%s' "$rep" | grep -qE '^doctor: (OK|WARN|FAIL) \([0-9]+ fail, [0-9]+ warn, [0-9]+ total\)' \
   && printf '%s' "$rep" | grep -q 'python3 — Python'; then
  ok "doctor.py readable report has the header, per-check lines, and verdict summary"
else
  bad "doctor.py readable report is missing its header or verdict line"
fi

# --- Test DR3: a broken install (no sibling scripts) FAILs with exit 1 -----------
# Copy doctor.py ALONE into an isolated dir; check_scripts resolves siblings from
# __file__, so all three bundled scripts are missing -> 3 fails -> ok=false, exit 1.
ISO="$TMP/doctor-iso"; mkdir -p "$ISO"
cp "$DOC" "$ISO/doctor.py"
rc=0; out="$(python3 "$ISO/doctor.py" --root "$ROOT" --json)" || rc=$?
if [ "$rc" = "1" ] \
   && printf '%s' "$out" | grep -q '"ok": false' \
   && printf '%s' "$out" | grep -q '"fail": 3' \
   && printf '%s' "$out" | grep -q '"status": "fail"'; then
  ok "doctor.py FAILs (exit 1) when the bundled scripts cannot be resolved beside it"
else
  bad "doctor.py did not fail on a broken install (rc=$rc)"
fi

# --- Test DR4: missing git degrades to FAIL (exit 1); rg/fd absence is WARN-only --
# Run with a PATH that resolves no tools so shutil.which(git/rg/fd) all return None.
# git is required -> fail -> exit 1; rg and fd are warn-only. The bundled-script check
# uses __file__ (absolute), so it is unaffected and still passes.
rc=0; out="$(PATH=/nonexistent-doctor-test "$PY" "$DOC" --root "$ROOT" --json)" || rc=$?
if [ "$rc" = "1" ] \
   && printf '%s' "$out" | grep -q '"ok": false' \
   && printf '%s' "$out" | python3 -c '
import json,sys
d=json.load(sys.stdin)
c={r["name"]:r["status"] for r in d["checks"]}
ok = (c.get("git")=="fail"
      and c.get("rg (ripgrep)")=="warn"
      and c.get("fd")=="warn"
      and c.get("<scripts>/build-graph.py")=="ok")
sys.exit(0 if ok else 1)
'; then
  ok "doctor.py FAILs on missing git, WARNs on missing rg/fd, scripts still resolve"
else
  bad "doctor.py mis-graded a missing-tool environment (rc=$rc)"
fi

# --- Test DR5: a non-git target is WARN-only (does not fail the exit code) --------
# A plain directory (not a git work tree) -> target check is warn; with all tools and
# scripts present there are no fails, so exit stays 0.
NOREPO="$TMP/doctor-norepo"; mkdir -p "$NOREPO"
rc=0; out="$(python3 "$DOC" --root "$NOREPO" --json)" || rc=$?
if [ "$rc" = "0" ] \
   && printf '%s' "$out" | grep -q '"ok": true' \
   && printf '%s' "$out" | python3 -c '
import json,sys
d=json.load(sys.stdin)
c={r["name"]:r["status"] for r in d["checks"]}
sys.exit(0 if c.get("target is a git repo")=="warn" else 1)
'; then
  ok "doctor.py treats a non-git target as WARN only (exit stays 0)"
else
  bad "doctor.py mis-graded a non-git target (rc=$rc)"
fi

# --- Test DR6: SKILL.md wires `doctor` into dispatch + Usage ----------------------
# Contract: doctor must be reachable — listed in the Usage block and dispatched in the
# Invocation section, and the bundled script referenced via the <scripts> seam.
if python3 - "$ROOT/skills/planwright/SKILL.md" <<'PY' 2>/dev/null
import sys
t = open(sys.argv[1], encoding="utf-8").read()
need = []
if "doctor" not in t: need.append("no-mention")
if "/planwright doctor" not in t: need.append("usage-line")
if "<scripts>/doctor.py" not in t: need.append("script-wire")
sys.exit(1 if need else 0)
PY
then ok "SKILL.md exposes doctor (Usage line + <scripts>/doctor.py wiring)"; else bad "SKILL.md does not wire the doctor command"; fi
