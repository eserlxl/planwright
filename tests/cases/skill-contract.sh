# SPDX-FileCopyrightText: 2026 Eser KUBALI
# SPDX-License-Identifier: GPL-3.0-or-later
#
# SKILL.md + README contract tests (the prose-vs-implementation drift guards).
# Sourced by tests/run.sh after tests/lib.sh — NOT standalone (uses ROOT/TMP/ok/bad/ver).

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

# --- Test 10e: SKILL.md documents the invent-must-generate rule + its guards ---
# Explicit invent must propose >=1 net-new item (the value bar / mission conservatism
# are relaxed), but the two hard gates that keep plans executable must remain, and the
# relaxation must be scoped to invent (explore/default still never pad). This guards the
# rule and its invariants against silent drift.
if python3 - "$ROOT/skills/planwright/SKILL.md" <<'PY' 2>/dev/null
import re, sys
t = open(sys.argv[1]).read()
need = []
# the rule itself must be present and named
if "must-generate" not in t and "must generate" not in t: need.append("rule:must-generate")
if not re.search(r"invent tier .{0,40}must .{0,40}propose", t) and "must propose at least one net-new" not in t and "must emit ≥1 net-new" not in t and "must** propose ≥1" not in t:
    need.append("rule:must-propose-one")
# the two never-relaxed gates must be reaffirmed near the rule
if "grounding floor" not in t: need.append("gate:grounding-floor")
if "structural hard ceiling" not in t: need.append("gate:structural-ceiling")
# the relaxation must be scoped to explicit invent (not explore/default)
if "explicit `invent`" not in t: need.append("scope:explicit-invent")
sys.exit(1 if need else 0)
PY
then ok "SKILL.md documents invent-must-generate with grounding-floor + structural-ceiling guards, scoped to invent"; else bad "invent-must-generate rule or its guards/scope missing from SKILL.md"; fi

# --- Test 10f: dwell-gated MISSION amendment + its safety invariants ----------
# invent may rarely edit MISSION.md, but only via the dwell gate (mission_pressure
# reaches 3), as its own committed item, taking effect the NEXT cycle (no same-run
# self-justification), never relaxing the structural ceiling, and never touching
# protected paths. The run must announce it up front. Guards the whole contract.
mission_ok=1
python3 - "$ROOT/skills/planwright/SKILL.md" "$ROOT/commands/codinventor.md" <<'PY' 2>/dev/null || mission_ok=0
import sys
skill = open(sys.argv[1]).read()
banner = open(sys.argv[2]).read()
need = []
if "mission_pressure" not in skill: need.append("counter:mission_pressure")
if "MISSION.md" not in skill: need.append("target:MISSION.md")
# the dwell threshold must be stated as 3 (consecutive)
if "reaches **3**" not in skill and "reach **3**" not in skill and "3 consecutive" not in skill and "3** (three" not in skill:
    need.append("dwell:3")
# one-beat gap: amendment takes effect the *next* cycle, not same run
if "next** cycle" not in skill and "next cycle" not in skill: need.append("gap:next-cycle")
# structural ceiling never relaxed via the mission
if "structural hard ceiling" not in skill: need.append("ceiling-hold")
# protected paths denylist present
for p in [".planwright/", ".git/", "LICENSE"]:
    if p not in skill: need.append("denylist:" + p)
# launch-time awareness in both the cycle announce and the codinventor banner
if "on notice" not in skill: need.append("announce:on-notice")
if "MISSION.md" not in banner: need.append("banner:MISSION.md")
sys.exit(1 if need else 0)
PY
if [ "$mission_ok" = 1 ]; then ok "SKILL.md documents dwell-gated MISSION amendment (pressure=3, next-cycle gap, ceiling-hold, denylist, announced)"; else bad "MISSION-amendment rule, dwell gate, denylist, or awareness notice missing/incomplete"; fi

# --- Test 10g: Stage 1 escalation-reach rule (a deeper re-invocation is not frozen) -
# The "already at final point" short-circuit must NOT freeze a more ambitious re-run:
# a fresh `invent` run never short-circuits (must-generate -> a deepest_tier: invent
# marker is informational only and re-invoking invent re-surveys), and `explore`
# re-surveys over a plain/hot-core point. Guards the fix against silent regression.
if python3 - "$ROOT/skills/planwright/SKILL.md" <<'PY' 2>/dev/null
import re, sys
t = open(sys.argv[1]).read()
need = []
# the rule must be present and named
if "escalation-reach" not in t and "escalation reach" not in t: need.append("rule:escalation-reach")
# an explicit invent run never short-circuits
if not re.search(r"invent`?\*?\*? run \*?\*?never\*?\*? short-circuit", t) and "**never** short-circuit" not in t:
    need.append("invent:never-short-circuit")
# a deepest_tier: invent marker is informational only (does not block the next run)
if "informational only" not in t: need.append("marker:informational-only")
# re-invoking invent re-surveys / re-asserts the must-generate mandate
if "re-surveys" not in t and "re-survey" not in t: need.append("invent:re-survey")
# explore is stale over a plain / hot-core point (reach ordering)
if "hot-core" not in t and "hot core" not in t: need.append("explore:plain-stale")
sys.exit(1 if need else 0)
PY
then ok "SKILL.md documents the Stage 1 escalation-reach rule (invent never short-circuits; explore re-surveys a plain point)"; else bad "escalation-reach rule missing from SKILL.md (invent could freeze at a recorded invent-dry point)"; fi

# --- Test 10h: invent framing auto-rotation on an empty survey (earned by breadth) --
# Before an invent survey may be declared dry it must re-run under EVERY framing in the
# fixed catalog and find all empty (empty-triggered, deterministic catalog order,
# bounded, within-round). The vantages tried are recorded as invent_framings_tried.
# AND the rotation must walk the same catalog build-graph.py emits (no order drift).
if python3 - "$ROOT/skills/planwright/SKILL.md" "$ROOT/scripts/build-graph.py" <<'PY' 2>/dev/null
import re, sys
t = open(sys.argv[1]).read()
builder = open(sys.argv[2]).read()
need = []
if "auto-rotat" not in t: need.append("rule:auto-rotation")
# empty-triggered only
if "empty-only" not in t and "empty-triggered" not in t and "on an empty survey" not in t:
    need.append("trigger:empty-only")
# must exhaust every framing before concluding dry
if "every** framing" not in t and "every framing" not in t and "all framings are exhausted" not in t:
    need.append("exhaust:all-framings")
# bounded + deterministic catalog order
if "catalog order" not in t: need.append("order:catalog")
if "bounded" not in t: need.append("bound:bounded")
# records the audit field
if "invent_framings_tried" not in t: need.append("field:invent_framings_tried")
# the rotation order names the same catalog keys build-graph.py emits (no drift)
m = re.search(r"EXPLORE_FRAMINGS\s*=\s*\[(.*?)\]", builder, re.S)
keys = re.findall(r'"([a-z-]+)"', m.group(1)) if m else []
assert len(keys) >= 3, keys
for k in keys:
    if k not in t: need.append("rotorder:" + k)
sys.exit(1 if need else 0)
PY
then ok "SKILL.md documents invent framing auto-rotation (empty-only, exhausts the catalog, records invent_framings_tried)"; else bad "framing auto-rotation rule missing/incomplete in SKILL.md (an empty could be declared from one vantage)"; fi

# --- Test 10i: invent earned-empty per-seam justification gate (earned by rigor) -----
# A deepest_tier: invent may be written only after a per-seam audit: each candidate
# seam gets a VALID reason (floor / ceiling / justified-trivial). Value-bar, mission,
# and unjustified-"trivial" are INVALID empty-reasons -> must-generate emits instead.
# The audit is recorded as invent_seams_examined.
if python3 - "$ROOT/skills/planwright/SKILL.md" <<'PY' 2>/dev/null
import sys
t = open(sys.argv[1]).read()
need = []
if "per-seam" not in t: need.append("rule:per-seam")
# the empty must be shown, not asserted / earned by rigor
if "shown, not\nasserted" not in t and "shown, not asserted" not in t and "earned by rigor" not in t:
    need.append("rule:shown-not-asserted")
# valid reasons reaffirmed
for tok in ["(ceiling)", "(floor)", "trivial"]:
    if tok not in t: need.append("valid:" + tok)
# invalid reasons named (value bar / mission / unjustified trivial -> emit, not empty)
if "below the value bar" not in t: need.append("invalid:value-bar")
if "stretches the mission" not in t: need.append("invalid:mission")
if 'unjustified "trivial"' not in t and "unjustified \"trivial\"" not in t and "unjustified" not in t:
    need.append("invalid:unjustified-trivial")
# the audit field
if "invent_seams_examined" not in t: need.append("field:invent_seams_examined")
sys.exit(1 if need else 0)
PY
then ok "SKILL.md documents the invent earned-empty per-seam gate (valid floor/ceiling/trivial; value-bar/mission/unjustified-trivial are invalid; records invent_seams_examined)"; else bad "per-seam earned-empty gate missing/incomplete in SKILL.md (an empty could be asserted, not shown)"; fi

# --- Test 10j: invent run ends by SUGGESTING /codvisor to harden the net-new code -----
# After any invent run, planwright's cumulative summary closes with one line suggesting
# the user run /codvisor (the explore sweep) to harden the final invent burst. It is a
# suggestion only (never auto-dispatched) and scoped to invent runs (no-op otherwise).
if python3 - "$ROOT/skills/planwright/SKILL.md" <<'PY' 2>/dev/null
import sys
t = open(sys.argv[1]).read()
# the rule must live in the Cycle "After all cycles" report section
after = t.split("## After all cycles", 1)
assert len(after) == 2, "no 'After all cycles' section"
sec = after[1].split("## Stop conditions", 1)[0]
need = []
if "Hardening suggestion" not in sec: need.append("rule:hardening-suggestion")
if "/codvisor" not in sec: need.append("target:/codvisor")
# scoped to invent runs only
if "invent` run only" not in sec and "after an `invent` run" not in sec:
    need.append("scope:invent-only")
# suggestion only — never auto-run
if "suggestion only" not in sec: need.append("rule:suggestion-only")
if "never auto-dispatch" not in sec and "never auto-run" not in sec:
    need.append("rule:no-auto-dispatch")
sys.exit(1 if need else 0)
PY
then ok "SKILL.md: an invent run ends by suggesting /codvisor to harden the net-new code (suggestion only, never auto-dispatched)"; else bad "invent->/codvisor hardening suggestion missing/incomplete in SKILL.md (After all cycles section)"; fi

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

