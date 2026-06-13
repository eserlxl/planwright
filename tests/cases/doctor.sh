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
   && printf '%s' "$out" | grep -q '"<scripts>/check-links.py"' \
   && printf '%s' "$out" | grep -q '"<scripts>/lint-final.py"' \
   && printf '%s' "$out" | grep -q '"<scripts>/dashboard.py"' \
   && printf '%s' "$out" | grep -q '"<scripts>/dashboard/index.html"'; then
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
# __file__, so EVERY bundled entry is missing -> all fail -> ok=false, exit 1. The
# expected fail count is derived from BUNDLED itself (not hard-coded) so the guard
# can grow its asset list — e.g. the load-bearing dashboard assets — without this
# test going stale.
ISO="$TMP/doctor-iso"; mkdir -p "$ISO"
cp "$DOC" "$ISO/doctor.py"
nbundled="$(python3 -c "import importlib.util,sys; s=importlib.util.spec_from_file_location('d',sys.argv[1]); m=importlib.util.module_from_spec(s); s.loader.exec_module(m); print(len(m.BUNDLED))" "$DOC")"
rc=0; out="$(python3 "$ISO/doctor.py" --root "$ROOT" --json)" || rc=$?
if [ "$rc" = "1" ] \
   && printf '%s' "$out" | grep -q '"ok": false' \
   && printf '%s' "$out" | grep -q "\"fail\": $nbundled" \
   && printf '%s' "$out" | grep -q '"<scripts>/dashboard/app.js"' \
   && printf '%s' "$out" | grep -q '"status": "fail"'; then
  ok "doctor.py FAILs (exit 1) when the bundled scripts cannot be resolved beside it"
else
  bad "doctor.py did not fail on a broken install (rc=$rc, expected fail=$nbundled)"
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

# --- Test DR4b: doctor's BUNDLED dashboard views match index.html's referenced views ---
# BUNDLED's stated contract is to "list each load-bearing asset index.html requires"; a view
# index.html loads but BUNDLED omits is a silent partial-install blind spot (a missing
# shards.js once 404'd while doctor still reported a healthy install). Derive the view set
# from index.html's <script src="/views/*.js"> tags and assert every one appears in BUNDLED,
# so a future view added to the shell without a matching doctor entry turns this red.
if "$PY" - "$DOC" "$ROOT/scripts/dashboard/index.html" <<'PY'
import importlib.util, re, sys
doc, index = sys.argv[1], sys.argv[2]
spec = importlib.util.spec_from_file_location("d", doc)
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
bundled = {p for p, _ in m.BUNDLED}
with open(index, encoding="utf-8") as fh:
    html = fh.read()
views = set(re.findall(r'src="/(views/[A-Za-z0-9_-]+\.js)"', html))
assert views, "no /views/*.js tags found in index.html"
missing = {v for v in views if ("dashboard/" + v) not in bundled}
assert not missing, "index.html views missing from doctor BUNDLED: %s" % sorted(missing)
PY
then
  ok "doctor.py BUNDLED lists every dashboard view index.html references (no silent partial-install gap)"
else
  bad "doctor.py BUNDLED omits a dashboard view that index.html loads"
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

# --- Test DR5b: a git work tree with no commits yet (unborn HEAD) is WARN, not ok --
# A fresh `git init` with an uncommitted file passes every other check, yet the Stage 1.5
# graph build's first op (`git rev-parse HEAD` in build-graph.py) fatals on an unborn HEAD.
# doctor must WARN (not green-light "ok") so the first planning run is not a bare git-128
# crash. WARN keeps the exit code 0 (a non-repo is already warn), so it stays exit-neutral.
if command -v git >/dev/null 2>&1; then
  UNBORN="$TMP/doctor-unborn"; mkdir -p "$UNBORN"
  git -C "$UNBORN" init -q
  printf 'x = 1\n' > "$UNBORN/a.py"
  rc=0; out="$(python3 "$DOC" --root "$UNBORN" --json)" || rc=$?
  if [ "$rc" = "0" ] \
     && printf '%s' "$out" | python3 -c '
import json,sys
d=json.load(sys.stdin)
t={r["name"]:r for r in d["checks"]}.get("target is a git repo",{})
sys.exit(0 if t.get("status")=="warn" and "no commits yet" in t.get("detail","") else 1)
'; then
    ok "doctor.py WARNs on a git work tree with no commits yet (unborn HEAD; exit stays 0)"
  else
    bad "doctor.py mis-graded an unborn-HEAD work tree (rc=$rc)"
  fi
else
  ok "doctor.py unborn-HEAD WARN check skipped (no git)"
fi

# --- Test DR6: doctor is wired via progressive disclosure -------------------------
# Contract: doctor must be reachable — listed in the Usage block and dispatched in the
# Invocation section of SKILL.md to references/doctor.md, whose procedure references the
# bundled script via the <scripts> seam. (The procedure moved out of SKILL.md into the
# on-demand reference file; SKILL.md keeps the usage line + dispatch pointer.)
if python3 - "$ROOT/skills/planwright/SKILL.md" "$ROOT/skills/planwright/references/doctor.md" <<'PY' 2>/dev/null
import sys
skill = open(sys.argv[1], encoding="utf-8").read()
ref = open(sys.argv[2], encoding="utf-8").read()
need = []
if "doctor" not in skill: need.append("no-mention")
if "/planwright doctor" not in skill: need.append("usage-line")
if "references/doctor.md" not in skill: need.append("dispatch-pointer")
if "<scripts>/doctor.py" not in ref: need.append("script-wire")
sys.exit(1 if need else 0)
PY
then ok "doctor exposed: SKILL.md usage + dispatch pointer, references/doctor.md wires <scripts>/doctor.py"; else bad "doctor command wiring missing across SKILL.md / references/doctor.md"; fi

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

# --- Test DR8b: a PARTIAL identity (only name OR only email) warns, naming the unset field
# DR8 covered both-unset and both-set; the in-between branch (doctor.py:206) names exactly
# the missing key. Set only user.name and assert the warning names user.email, not user.name.
IDP="$TMP/doctor-id-partial"; mkdir -p "$IDP"
git -C "$IDP" init -q
git -C "$IDP" config user.name "Only Name"   # user.email deliberately left unset
pout="$(GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null python3 "$DOC" --root "$IDP" --json)"
if printf '%s' "$pout" | python3 -c '
import json, sys
d = json.load(sys.stdin)
r = next(x for x in d["checks"] if x["name"] == "git commit identity")
assert r["status"] == "warn", r
assert "user.email" in r["detail"] and "user.name" not in r["detail"], r["detail"]
'; then
  ok "doctor.py names exactly the unset identity field (user.email) on a partial identity"
else
  bad "doctor.py mis-named the partial git-identity warning"
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

# collect() is the read-only payload builder the dashboard's /doctor.json endpoint reuses;
# it must carry the same shape as --json and never report a write (no `fixed`).
col_ok=0
ROOT="$ROOT" python3 -c '
import os, sys
sys.path.insert(0, os.path.join(os.environ["ROOT"], "scripts"))
import doctor
p = doctor.collect(os.environ["ROOT"])
assert set(p) >= {"ok", "fail", "warn", "total", "checks"}, p
assert isinstance(p["checks"], list) and p["checks"], p
assert p["total"] == len(p["checks"]), p
assert all({"name", "status", "detail", "degrades"} <= set(c) for c in p["checks"]), p
assert "fixed" not in p, "collect() must not write or report a fix"
' && col_ok=1
if [ "$col_ok" = 1 ]; then
  ok "doctor.collect() returns the read-only {ok,fail,warn,total,checks} payload (dashboard data source)"
else
  bad "doctor.collect() payload shape wrong"
fi


# --- Test DR11: --fix degrades on a non-UTF-8 .gitignore (appends, no traceback) ----
# apply_gitignore_fix read .gitignore with strict UTF-8 catching only OSError, so a
# latin-1 byte made the whole preflight abort with a UnicodeDecodeError traceback
# before any report — and the requested fix was never applied. The read only feeds
# the membership/trailing-newline checks, so it now decodes with errors="replace"
# and the ASCII append proceeds.
DRNU="$TMP/doctor-nonutf8"; mkdir -p "$DRNU"
git -C "$DRNU" init -q
printf 'node_modules/\n# caf\xe9 comment\n' > "$DRNU/.gitignore"
dnu_rc=0
dnu_out="$(python3 "$ROOT/scripts/doctor.py" --root "$DRNU" --fix 2>&1)" || dnu_rc=$?
if ! printf '%s' "$dnu_out" | grep -q 'Traceback' \
   && grep -q '^\.planwright/$' "$DRNU/.gitignore" \
   && grep -q 'caf' "$DRNU/.gitignore"; then
  ok "doctor.py --fix appends to a non-UTF-8 .gitignore without a traceback"
else
  bad "doctor.py --fix crashed or skipped a non-UTF-8 .gitignore (rc=$dnu_rc): $(printf '%s' "$dnu_out" | tail -2)"
fi


# --- Test DR12: final-point validity check (corrupt final.md -> WARN, never FAIL) ----
# doctor validates a recorded .planwright/final.md against lint-final's contract so a
# corrupt point is surfaced in the preflight instead of being silently absorbed by the
# coach (which routes a malformed point to a harden sweep with no diagnostic). Absent or
# valid -> ok; malformed -> warn with the exit code unchanged.
DRFP="$TMP/doctor-finalpoint"; mkdir -p "$DRFP/.planwright"

# (a) recorded final point absent -> ok (a legitimate open-ladder state)
fp_absent="$(python3 "$ROOT/scripts/doctor.py" --root "$DRFP" --json)"
# (b) a valid final.md (lint-final's key: value contract) -> ok
cat > "$DRFP/.planwright/final.md" <<'EOF'
sha: deadbeef
repair: dry
coverage: dry
opportunity: dry
vision: dry
EOF
fp_valid="$(python3 "$ROOT/scripts/doctor.py" --root "$DRFP" --json)"
# (c) a corrupt final.md (markdown-bullet form lint-final/status cannot parse) -> warn,
#     and the exit code stays 0 (a corrupt point must never FAIL the preflight)
cat > "$DRFP/.planwright/final.md" <<'EOF'
- sha: deadbeef
- repair: dry
EOF
fp_rc=0
fp_corrupt="$(python3 "$ROOT/scripts/doctor.py" --root "$DRFP" --json)" || fp_rc=$?

fp_check=0
NAME='.planwright/final.md is well-formed' A="$fp_absent" V="$fp_valid" C="$fp_corrupt" RC="$fp_rc" \
python3 -c '
import json, os
name = os.environ["NAME"]
def stat(blob):
    for c in json.loads(blob)["checks"]:
        if c["name"] == name:
            return c["status"]
    return None
assert stat(os.environ["A"]) == "ok", ("absent", stat(os.environ["A"]))
assert stat(os.environ["V"]) == "ok", ("valid", stat(os.environ["V"]))
assert stat(os.environ["C"]) == "warn", ("corrupt", stat(os.environ["C"]))
assert os.environ["RC"] == "0", ("corrupt must warn, not fail the exit code", os.environ["RC"])
' && fp_check=1
if [ "$fp_check" = 1 ]; then
  ok "doctor.py validates .planwright/final.md (absent/valid -> ok, corrupt -> WARN, exit 0)"
else
  bad "doctor.py final-point check wrong (absent/valid should be ok, corrupt should warn without failing)"
fi

# --- Test DR12b: --quiet stays exit-code-only on a non-UTF-8 final.md --------------
# doctor --quiet is an exit-code-only contract. A non-UTF-8 (corrupt) final.md makes
# lint-final.collect() fail closed by printing the decode failure to stderr (lint-final.py:70);
# check_final_point must capture that stream so the quiet contract holds in exactly the
# corrupt-marker path the check exists for. doctor's own git probes already capture_output,
# so any stderr here is the lint-final leak. (Regression for doctor.py:297.)
DRNU2="$TMP/doctor-finalpoint-nonutf8"; mkdir -p "$DRNU2/.planwright"
printf '\xff\xfe sha: x\n' > "$DRNU2/.planwright/final.md"
dq_err="$(python3 "$ROOT/scripts/doctor.py" --root "$DRNU2" --quiet 2>&1 1>/dev/null)"
if [ -z "$dq_err" ]; then
  ok "doctor --quiet keeps stderr clean on a non-UTF-8 final.md (no lint-final leak)"
else
  bad "doctor --quiet leaked stderr on a non-UTF-8 final.md: $dq_err"
fi
