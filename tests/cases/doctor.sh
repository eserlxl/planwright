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
   && printf '%s' "$out" | grep -q '"<scripts>/lifecycle.py"' \
   && printf '%s' "$out" | grep -q '"<scripts>/status.py"' \
   && printf '%s' "$out" | grep -q '"<scripts>/check-links.py"'; then
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
# __file__, so all five bundled scripts are missing -> 5 fails -> ok=false, exit 1.
ISO="$TMP/doctor-iso"; mkdir -p "$ISO"
cp "$DOC" "$ISO/doctor.py"
rc=0; out="$(python3 "$ISO/doctor.py" --root "$ROOT" --json)" || rc=$?
if [ "$rc" = "1" ] \
   && printf '%s' "$out" | grep -q '"ok": false' \
   && printf '%s' "$out" | grep -q '"fail": 5' \
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

# --- Test DR7: the .planwright/ gitignore check — warn when un-ignored, ok once ignored
# A fresh git work tree with no .gitignore does NOT ignore .planwright/ -> WARN, but the
# check is warn-only so exit stays 0; adding the ignore rule flips it to ok.
GI="$TMP/doctor-gitignore"; mkdir -p "$GI"
git -C "$GI" init -q
rc=0; out="$(python3 "$DOC" --root "$GI" --json)" || rc=$?
warn_ok=0
printf '%s' "$out" | python3 -c '
import json,sys
d=json.load(sys.stdin)
c={r["name"]:r["status"] for r in d["checks"]}
sys.exit(0 if c.get(".planwright/ is gitignored")=="warn" else 1)
' && warn_ok=1
printf '.planwright/\n' > "$GI/.gitignore"
ig_ok=0
out2="$(python3 "$DOC" --root "$GI" --json)"
printf '%s' "$out2" | python3 -c '
import json,sys
d=json.load(sys.stdin)
c={r["name"]:r["status"] for r in d["checks"]}
sys.exit(0 if c.get(".planwright/ is gitignored")=="ok" else 1)
' && ig_ok=1
if [ "$rc" = "0" ] && [ "$warn_ok" = "1" ] && [ "$ig_ok" = "1" ]; then
  ok "doctor.py WARNs when .planwright/ is not gitignored and is ok once ignored (warn-only, exit 0)"
else
  bad "doctor.py mis-graded the .planwright/ gitignore check (rc=$rc warn=$warn_ok ig=$ig_ok)"
fi

# --- Test DR8: git commit-identity check — warn when unset, ok once configured -----
# Isolate config (GIT_CONFIG_GLOBAL/SYSTEM -> /dev/null) so a fresh repo with no local
# identity resolves to none -> warn (warn-only, exit 0); setting a local identity -> ok.
ID="$TMP/doctor-identity"; mkdir -p "$ID"
git -C "$ID" init -q
rc=0
out="$(GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null python3 "$DOC" --root "$ID" --json)" || rc=$?
id_warn=0
printf '%s' "$out" | python3 -c '
import json,sys
d=json.load(sys.stdin)
c={r["name"]:r["status"] for r in d["checks"]}
sys.exit(0 if c.get("git commit identity")=="warn" else 1)
' && id_warn=1
git -C "$ID" config user.name "Test"; git -C "$ID" config user.email "t@e.x"
out2="$(GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null python3 "$DOC" --root "$ID" --json)"
id_ok=0
printf '%s' "$out2" | python3 -c '
import json,sys
d=json.load(sys.stdin)
c={r["name"]:r["status"] for r in d["checks"]}
sys.exit(0 if c.get("git commit identity")=="ok" else 1)
' && id_ok=1
if [ "$rc" = "0" ] && [ "$id_warn" = "1" ] && [ "$id_ok" = "1" ]; then
  ok "doctor.py WARNs when git commit identity is unset and is ok once set (warn-only, exit 0)"
else
  bad "doctor.py mis-graded the git commit-identity check (rc=$rc warn=$id_warn ok=$id_ok)"
fi

# --- Test DR9: --strict promotes warns to failures (pristine-env gate) ------------
# A fresh git work tree with no .gitignore has at least one warn (.planwright/ not
# ignored) and no fail: doctor exits 0 by default but 1 under --strict, so a CI
# preflight can require a pristine (not merely runnable) env. Default is unchanged.
STR="$TMP/doctor-strict"; mkdir -p "$STR"
git -C "$STR" init -q
ds_def=0; python3 "$DOC" --root "$STR" --quiet || ds_def=$?
ds_strict=0; python3 "$DOC" --root "$STR" --strict --quiet || ds_strict=$?
ds_env=0
python3 "$DOC" --root "$STR" --json | python3 -c '
import json,sys
d=json.load(sys.stdin)
sys.exit(0 if d["fail"]==0 and d["warn"]>0 else 1)
' && ds_env=1
if [ "$ds_env" = 1 ]; then
  if [ "$ds_def" = 0 ] && [ "$ds_strict" = 1 ]; then
    ok "doctor.py --strict promotes warns to failures (default stays exit 0)"
  else
    bad "doctor.py --strict wrong (default=$ds_def strict=$ds_strict)"
  fi
else
  ok "doctor.py --strict check skipped (env has a fail or no warn)"
fi

# --- Test DR10: --fix auto-remediates the .planwright/ gitignore warn --------------
# A fresh git work tree with no .gitignore warns on .planwright/; `doctor --fix` appends
# a `.planwright/` rule and the re-check reports ok. Idempotent: a second --fix is a
# no-op, and the other warns are never auto-fixed.
FIXR="$TMP/doctor-fix"; mkdir -p "$FIXR"
git -C "$FIXR" init -q
fx_warn=0
python3 "$DOC" --root "$FIXR" --json | python3 -c '
import json,sys
d=json.load(sys.stdin)
c={r["name"]:r["status"] for r in d["checks"]}
sys.exit(0 if c.get(".planwright/ is gitignored")=="warn" else 1)
' && fx_warn=1
fx_out="$(python3 "$DOC" --root "$FIXR" --fix --json)"
fx_now_ok=0
printf '%s' "$fx_out" | python3 -c '
import json,sys
d=json.load(sys.stdin)
c={r["name"]:r["status"] for r in d["checks"]}
sys.exit(0 if c.get(".planwright/ is gitignored")=="ok" and d.get("fixed") else 1)
' && fx_now_ok=1
# the rule is actually in .gitignore, and a second --fix is a no-op (fixed: null)
fx_rule=0; grep -qx '.planwright/' "$FIXR/.gitignore" && fx_rule=1
fx_idem=0
python3 "$DOC" --root "$FIXR" --fix --json | python3 -c '
import json,sys
sys.exit(0 if json.load(sys.stdin).get("fixed") is None else 1)
' && fx_idem=1
if [ "$fx_warn" = 1 ] && [ "$fx_now_ok" = 1 ] && [ "$fx_rule" = 1 ] && [ "$fx_idem" = 1 ]; then
  ok "doctor.py --fix adds .planwright/ to .gitignore, flips the warn to ok, and is idempotent"
else
  bad "doctor.py --fix wrong (warn=$fx_warn nowok=$fx_now_ok rule=$fx_rule idem=$fx_idem)"
fi
