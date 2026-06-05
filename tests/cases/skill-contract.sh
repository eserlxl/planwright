# SPDX-FileCopyrightText: 2026 Eser KUBALI
# SPDX-License-Identifier: GPL-3.0-or-later
#
# SKILL.md + README structural / wiring / behavioral contract tests.
# Sourced by tests/run.sh after tests/lib.sh — NOT standalone (uses ROOT/TMP/ok/bad/ver).
#
# These checks either RUN the implementation (build-graph.py --debug, foreign-cwd script
# invocation) or cross-check SKILL.md against build-graph.py (scope/seed wiring), plus the
# structural lint (stages/sections/fields present) and the README schema example. The pure
# "SKILL.md documents invent rule X" prose drift-guards live in the sibling skill-guards.sh.

# --- Test 9b: README plan-item example matches the real schema -------------
if python3 - "$ROOT/README.md" <<'PY' 2>/dev/null
import re, sys
t = open(sys.argv[1]).read()
m = re.search(r"## Example Plan Item.*?```md\n(.*?)\n```", t, re.S)
if not m:
    raise SystemExit(1)
example = m.group(1)
required = ["Mode:", "Rationale:", "Evidence:", "Surfaces:",
            "Development:", "Acceptance:", "Verification:"]
legacy = ["ID:", "Title:", "Risk:", "Change:", "Files:", "Status:"]
missing = [f for f in required if not re.search(r"(?m)^\s+" + re.escape(f), example)]
stale = [f for f in legacy if re.search(r"(?m)^\s*(?:- \[ \]\s*)?" + re.escape(f), example)]
if not example.startswith("- [ ] ") or example.startswith("- [ ] ID:"):
    missing.append("checkbox-title")
sys.exit(1 if missing or stale else 0)
PY
then ok "README example plan item matches the real schema"; else bad "README example plan item drifted from the real schema"; fi

# --- Test 10: SKILL.md structural lint -------------------------------------
if python3 - "$ROOT/skills/planwright/SKILL.md" <<'PY' 2>/dev/null
import re, sys
t = open(sys.argv[1]).read()
missing = []
if not re.search(r'\n  version:\s*"\d+\.\d+\.\d+"', t): missing.append("version-frontmatter")
for h in ["### Stage 0", "### Stage 1 ", "### Stage 1.5", "### Stage 2 ", "### Stages 3", "### Stage 8", "### Stage 9", "### Stage 10", "### Stage 11"]:
    if h not in t: missing.append("heading:" + h)
for s in ["## Inputs", "## Maturity ladder", "## OUTPUT FORMAT", "## Hard rules"]:
    if s not in t: missing.append("section:" + s)
for f in ["Mode:", "Rationale:", "Evidence:", "Surfaces:", "New Surfaces:", "Development:", "Acceptance:", "Verification:"]:
    if f not in t: missing.append("field:" + f)
sys.exit(1 if missing else 0)
PY
then ok "SKILL.md structural lint passes (stages, sections, item fields present)"; else bad "SKILL.md structural lint failed (missing stage/section/field)"; fi

# --- Test 10b: bundled scripts are invoked via the skill base dir, not cwd ---
# Regression guard for v1.21.1: SKILL.md must not invoke a bundled script as a
# bare `python3 scripts/<name>.py` command — for an installed user the cwd is
# the target repo, which has no planwright scripts/ dir, so a bare path fails.
# The required form is the base-dir-relative `<scripts>/<name>.py`. (The prose
# file-name mention of `scripts/lint-plan.py` is not a command and must not trip
# this — the pattern below matches only `python3[ ]scripts/...` invocations.)
if grep -nE 'python3[[:space:]]+scripts/(build-graph|lint-plan)\.py' "$ROOT/skills/planwright/SKILL.md" >/dev/null 2>&1; then
  bad "SKILL.md invokes a bundled script via a bare scripts/ path (use <scripts>/ from the skill base dir)"
else
  ok "SKILL.md invokes bundled scripts via the skill base dir, not a bare scripts/ path"
fi

# --- Test 10c: SKILL.md wires path/lib scoping to the focus/context graph keys ---
# Contract between the SKILL.md procedure and build-graph.py: the scope feature must
# be documented (path + lib options) AND ride on the --scope flag / focus+context
# node sets the builder actually emits — so the prose can't describe a feature the
# script doesn't back (the drift class this guards).
scope_ok=1
python3 - "$ROOT/skills/planwright/SKILL.md" <<'PY' 2>/dev/null || scope_ok=0
import re, sys
t = open(sys.argv[1]).read()
need = []
if not re.search(r'(?m)^/planwright path <X>', t): need.append("usage:path")
if not re.search(r'(?m)^/planwright lib <X>', t): need.append("usage:lib")
if "`path <X>`" not in t: need.append("option:path")
if "`lib <X>`" not in t: need.append("option:lib")
if "--scope" not in t: need.append("ref:--scope")
if "Surfaces-in-Focus" not in t: need.append("gate:Surfaces-in-Focus")
if "scope_focus_sha" not in t: need.append("final:scope_focus_sha")
sys.exit(1 if need else 0)
PY
# the builder must actually back the documented flag + emitted keys
grep -q 'add_argument("--scope"' "$ROOT/scripts/build-graph.py" || scope_ok=0
grep -q '"focus"' "$ROOT/scripts/build-graph.py" || scope_ok=0
grep -q '"context"' "$ROOT/scripts/build-graph.py" || scope_ok=0
if [ "$scope_ok" = 1 ]; then ok "SKILL.md documents path/lib scoping and build-graph.py backs --scope/focus/context"; else bad "scope wiring incomplete: SKILL.md docs or build-graph.py --scope/keys missing"; fi

# --- Test 10c2: build-graph.py --debug digests routing to stderr, stdout stays JSON ---
# The routing digest (ranking signal, top ranked/code/cold nodes, dirty-set, cycles) is
# an observability aid; it MUST go to stderr so `--debug > graph.json` still produces a
# clean JSON document (same stdout-purity contract as lint-plan.py --json).
dbg_err="$TMP/graph_debug.err"
dbg_out="$(python3 "$ROOT/scripts/build-graph.py" --root "$ROOT" --debug 2>"$dbg_err")"
dbg_json_ok=1
printf '%s' "$dbg_out" | python3 -c 'import sys,json; json.load(sys.stdin)' 2>/dev/null || dbg_json_ok=0
if [ "$dbg_json_ok" = 1 ] \
   && grep -q "build-graph debug" "$dbg_err" \
   && grep -q "ranking_signal=" "$dbg_err" \
   && grep -q "ranked_code" "$dbg_err"; then
  ok "build-graph.py --debug writes a routing digest to stderr and keeps stdout clean JSON"
else
  bad "build-graph.py --debug polluted stdout or omitted the routing digest"
fi

# --- Test 10d: SKILL.md wires the seeded invent framing to the builder catalog ---
# Contract between SKILL.md and build-graph.py for lever 2 (seeded framing): the prose
# must document the seed option, ride on --seed/explore_framing, record invent_framing,
# AND every framing key in the builder's EXPLORE_FRAMINGS catalog must appear in SKILL.md
# (no drift between the catalog the script emits and the vantage map the lens reasons under).
seed_ok=1
python3 - "$ROOT/skills/planwright/SKILL.md" "$ROOT/scripts/build-graph.py" <<'PY' 2>/dev/null || seed_ok=0
import re, sys
skill = open(sys.argv[1]).read()
builder = open(sys.argv[2]).read()
need = []
if not re.search(r'(?m)^\| `seed <S>`', skill): need.append("option:seed")
if "--seed" not in skill: need.append("ref:--seed")
if "explore_framing" not in skill: need.append("consume:explore_framing")
if "invent_framing" not in skill: need.append("final:invent_framing")
# the catalog the builder emits must match the vantage map in the prose
m = re.search(r"EXPLORE_FRAMINGS\s*=\s*\[(.*?)\]", builder, re.S)
if not m: need.append("builder:EXPLORE_FRAMINGS")
else:
    keys = re.findall(r'"([a-z-]+)"', m.group(1))
    assert len(keys) >= 3, keys
    for k in keys:
        if k not in skill: need.append("map:" + k)
sys.exit(1 if need else 0)
PY
# the builder must actually back the documented flag + emitted key
grep -q 'add_argument("--seed"' "$ROOT/scripts/build-graph.py" || seed_ok=0
grep -q 'graph\["explore_framing"\]' "$ROOT/scripts/build-graph.py" || seed_ok=0
if [ "$seed_ok" = 1 ]; then ok "SKILL.md wires seeded invent framing and matches build-graph.py EXPLORE_FRAMINGS catalog"; else bad "seed/framing wiring incomplete: SKILL.md docs, --seed/explore_framing, or catalog drift"; fi

# (b) the bundled scripts themselves are cwd-independent: invoked by absolute
# path with --root from a foreign cwd (NOT the repo root), they still succeed.
# lint-plan checks Surfaces existence against --root, so README.md resolves to
# the repo even though cwd is elsewhere — proving the path handling is correct.
FOREIGN="$TMP/foreign_cwd"
mkdir -p "$FOREIGN"
cat > "$FOREIGN/mini_plan.md" <<'PLAN'
# planwright Plan — .
- [ ] Foreign-cwd probe item
      Mode: docs
      Rationale: exercise lint-plan from a non-repo cwd.
      Evidence: README.md exists in the repo root.
      Surfaces: README.md
      Development: no-op probe of the README.md surface.
      Acceptance: lint passes; nothing changes.
      Verification: true
PLAN
if ( cd "$FOREIGN" \
     && python3 "$ROOT/scripts/build-graph.py" --root "$ROOT" >/dev/null 2>&1 \
     && python3 "$ROOT/scripts/lint-plan.py" --root "$ROOT" --plan "$FOREIGN/mini_plan.md" --quiet ); then
  ok "bundled scripts run from a foreign cwd via absolute path + --root"
else
  bad "bundled scripts failed when invoked from a cwd other than the repo root"
fi

