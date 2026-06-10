# SPDX-FileCopyrightText: 2026 Eser KUBALI
# SPDX-License-Identifier: GPL-3.0-or-later
# shellcheck shell=bash
#
# SKILL.md invent-semantics DRIFT GUARDS (grep-contract).
# Sourced by tests/run.sh after tests/lib.sh — NOT standalone (uses ROOT/TMP/ok/bad).
#
# These tests assert that SKILL.md *documents* the invent-tier rules (a phrase/clause
# is present), catching accidental deletion of a hard-won rule. They are deliberately
# distinct from the behavioral / wiring contracts in skill-contract.sh, which RUN the
# implementation or cross-check SKILL.md against build-graph.py. Pure prose guards:
# they prove the spec still says X, not that the system behaves like X.

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

# --- Test 10k: read-honest Stage 11 stamping (audit-tier guard) -----------------------
# Stage 11 must stamp last_audited_sha only for nodes the run actually examined, carve
# out capacity-cut findings (their nodes keep the prior stamp so the finding re-surfaces),
# and must NOT claim stamps drive incremental skipping (compute_dirty never reads them —
# stamping unread nodes only launders them off the audit frontier). Guards against the
# over-stamping semantics drifting back in.
if python3 - "$ROOT/skills/planwright/SKILL.md" <<'PY' 2>/dev/null
import sys
t = open(sys.argv[1]).read()
need = []
if "actually **examined**" not in t: need.append("rule:examined-only")
if "cut at the Stage 8 capacity gate" not in t: need.append("carve-out:capacity-cut")
if "leave its prior stamp untouched" not in t: need.append("carve-out:keep-prior-stamp")
if "launders" not in t: need.append("rationale:laundering-named")
# the old over-stamping clause and its false rationale must stay gone
if "for every node that was in scope this run" in t: need.append("regression:scope-stamping-back")
if "Without this stamp every future run looks like a first run" in t: need.append("regression:false-rationale-back")
sys.exit(1 if need else 0)
PY
then ok "SKILL.md stamps last_audited_sha only for examined nodes, keeps capacity-cut stamps, drops the false skip rationale"; else bad "read-honest Stage 11 stamping clause missing/regressed in SKILL.md"; fi

# --- Test 10l: carried candidates + frontier-judged dryness (audit-tier guards) -------
# (a) Capacity-cut/deferred findings persist as a capped, self-draining digest section
# the next run must re-verify (else a real defect found-then-cut is silently lost), and
# (b) cold-frontier dryness is judged against the graph's frontier counts with the stale
# residual recorded in the final point, and the cold walk is staleness-graded.
if python3 - "$ROOT/skills/planwright/SKILL.md" <<'PY' 2>/dev/null
import sys
t = open(sys.argv[1]).read()
need = []
# (a) the carried-candidates contract
if t.count("## Carried dossier candidates") < 2: need.append("carried:section-in-stage11-and-stage1")
if "Hard cap **10**" not in t: need.append("carried:cap-10")
if "mandatory re-verification seed" not in t: need.append("carried:mandatory-reverify")
if "CUT|DEFERRED" not in t: need.append("carried:reason-vocabulary")
if "the next run drains it" not in t: need.append("carried:self-draining")
# (b) frontier-judged dryness + staleness-graded cold walk
if "judged against the graph's `frontier` counts" not in t: need.append("frontier:dryness-judged-on-counts")
if "frontier.never_audited > 0" not in t: need.append("frontier:never-audited-gate")
if "*recorded*, not denied" not in t: need.append("frontier:residual-recorded")
if "audit_age_commits" not in t: need.append("frontier:staleness-signal-named")
if "stalest-audited" not in t: need.append("frontier:stalest-ordering-named")
sys.exit(1 if need else 0)
PY
then ok "SKILL.md specifies carried dossier candidates (capped, re-verified, never Evidence) and frontier-judged staleness-graded dryness"; else bad "carried-candidates block or frontier-dryness contract missing/incomplete in SKILL.md"; fi
