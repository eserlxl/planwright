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
for p in [".planwright/", ".git/", ".qb/", "LICENSE"]:
    if p not in skill: need.append("denylist:" + p)
# launch-time awareness in both the cycle announce and the codinventor banner
if "on notice" not in skill: need.append("announce:on-notice")
if "MISSION.md" not in banner: need.append("banner:MISSION.md")
sys.exit(1 if need else 0)
PY
if [ "$mission_ok" = 1 ]; then ok "SKILL.md documents dwell-gated MISSION amendment (pressure=3, next-cycle gap, ceiling-hold, denylist, announced)"; else bad "MISSION-amendment rule, dwell gate, denylist, or awareness notice missing/incomplete"; fi

# --- Test 10f2: SKILL.md "Editable surfaces" denylist agrees with the linter's enforced set --
# The SKILL.md denylist prose and lint-plan.py's protected-path enforcement can drift; a
# one-sided edit (a token added to the linter but not the spec, or removed from the spec
# while still enforced) would silently desync the documented and enforced denylists. Pin
# three-way agreement: the linter's enforced token set equals the canonical set, every
# token appears in the SKILL.md "Editable surfaces" bullet, and every token is actually
# flagged by the linter (documented AND enforced, not merely either).
if python3 - "$ROOT/skills/planwright/SKILL.md" "$ROOT/scripts/lint-plan.py" <<'PY' 2>/dev/null
import importlib.util, re, sys
skill = open(sys.argv[1]).read()
spec = importlib.util.spec_from_file_location("lp", sys.argv[2])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
problems = []
# (1) enforced set (derived from the linter's constants + the two special-cased trees:
#     .planwright/ has its own dedicated message; .env is a basename rule) == canonical.
enforced = (set(m.PROTECTED_DIR_PREFIXES) | {".planwright/"} | set(m.PROTECTED_EXACT)
            | set(m.PROTECTED_SECRET_BASENAMES)
            | {"*" + s for s in m.PROTECTED_SECRET_SUFFIXES})
EXPECTED = {".git/", ".qb/", ".planwright/", "LICENSE", ".env", "*.pem", "*.key"}
if enforced != EXPECTED:
    problems.append("enforced!=expected sym-diff=" + str(sorted(enforced ^ EXPECTED)))
# (2) every canonical token appears in the isolated "Editable surfaces" bullet.
mo = re.search(r"\*\*Editable surfaces\.\*\*.*?(?=\n- |\n#)", skill, re.S)
bullet = mo.group(0) if mo else ""
for tok in EXPECTED:
    if tok not in bullet:
        problems.append("SKILL.md Editable-surfaces bullet missing: " + tok)
# (3) every canonical token is actually FLAGGED by the linter (documented AND enforced).
samples = {".git/": ".git/config", ".qb/": ".qb/x.md", ".planwright/": ".planwright/plan.md",
           "LICENSE": "LICENSE", ".env": "cfg/.env", "*.pem": "k/x.pem", "*.key": "k/x.key"}
for tok, p in samples.items():
    flagged = p.startswith(".planwright/") or bool(m.protected_surface(p))
    if not flagged:
        problems.append("token enforced-but-not-flagged: " + tok)
sys.exit(1 if problems else 0)
PY
then ok "SKILL.md Editable-surfaces denylist agrees with lint-plan.py's enforced set (documented AND enforced, in lockstep)"; else bad "SKILL.md denylist prose and the linter's enforced set have drifted"; fi

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

# --- Test 10m: SKILL.md codmaster summary documents ENFORCED growth (791a00f) ----------
# The front-door summary must describe the post-791a00f gating: a converged terminal earns
# an enforced codinventor burst whenever `safe` is off (regardless of the engine's
# invent_class), with the engine's invent-dry reset/codvisor routing relayed only under
# `safe`. Guards against the pre-reversal "by default may dispatch / invent-dry -> reset"
# default-path wording drifting back (it once silently contradicted commands/codmaster.md).
if python3 - "$ROOT/skills/planwright/SKILL.md" <<'PY' 2>/dev/null
import sys
t = open(sys.argv[1]).read()
need = []
# the enforced-growth contract must be stated
if "an **enforced** at-most-once `codinventor` burst whenever `safe` is off" not in t:
    need.append("enforce:summary-clause")
if "regardless of the engine's `invent_class`" not in t:
    need.append("enforce:invent_class-override")
if "Only `safe` withholds the burst" not in t:
    need.append("enforce:safe-only-invent-dry-routing")
# the stale pre-reversal default-path wording must stay gone
if "by default codmaster may dispatch it" in t:
    need.append("regression:may-dispatch-default-growth")
sys.exit(1 if need else 0)
PY
then ok "SKILL.md codmaster summary documents enforced growth (safe-off burst regardless of invent_class; invent-dry routing relayed only under safe)"; else bad "codmaster enforced-growth summary missing/regressed in SKILL.md (pre-791a00f may-dispatch/invent-dry-reset wording may have drifted back)"; fi

# --- Test 10n: SKILL.md Stage 1.6 names the secret (.env) exclusion and the private-IP egress bar ---
# The optional external-agent recon backend ships the targeted tree to a third-party provider, so the
# egress boundary is SECURITY-load-bearing: the recon scan excludes gitignored secrets (`.env`) and the
# external backend must never target a tree holding private IP. These two tokens are NOT covered by
# Test 10d/10e — dropping either silently widens what could be egressed — so pin them inside Stage 1.6.
if python3 - "$ROOT/skills/planwright/SKILL.md" <<'PY' 2>/dev/null
import sys
t = " ".join(open(sys.argv[1], encoding="utf-8").read().split())
a = t.find("### Stage 1.6 — Parallel recon")
b = t.find("### Stage 2 — Audit")
need = []
if a < 0 or b < 0 or b <= a:
    need.append("stage-1.6-bounds"); para = ""
else:
    para = t[a:b]
if ".env" not in para: need.append("env-secret-exclusion")
if "never target a tree holding private IP" not in para: need.append("private-ip-egress-bar")
sys.exit(1 if need else 0)
PY
then ok "SKILL.md Stage 1.6 names the .env secret exclusion and the private-IP egress bar (external-backend boundary)"; else bad "SKILL.md Stage 1.6 lost the .env/private-IP egress-exclusion security boundary"; fi

# --- Test 10o: SKILL.md (agent-neutral) documents the qb QB_PLAN_AUTO_WARN trust-downgrade -
# The WARN downgrade — codmaster distrusts a NON-INDEPENDENT qb audit: re-validate+verify every
# merged item regardless of qb's verdict, treat the WARN-tagged convergence as UNVERIFIED, and
# recommend an INDEPENDENT RE-RUN rather than asserting a clean done — is pinned only against the
# Claude-host commands/codmaster.md (commands.sh). Every NON-Claude host reads SKILL.md, where the
# contract was unguarded — a silent deletion there loses the safety behavior off-Claude. Pin the
# full contract (not just the bare token) so a weakening fails.
if python3 - "$ROOT/skills/planwright/SKILL.md" <<'PY' 2>/dev/null
import sys
t = open(sys.argv[1]).read()
need = []
if "QB_PLAN_AUTO_WARN" not in t: need.append("token:QB_PLAN_AUTO_WARN")
if "non-independent" not in t: need.append("semantics:non-independent")
if "downgrades trust" not in t and "downgrade trust" not in t: need.append("semantics:downgrade")
if "unverified" not in t: need.append("semantics:unverified-convergence")
if "independent re-run" not in t: need.append("semantics:recommend-independent-rerun")
sys.exit(1 if need else 0)
PY
then ok "SKILL.md (agent-neutral) documents the qb QB_PLAN_AUTO_WARN trust-downgrade contract (off-Claude hosts guarded)"; else bad "SKILL.md qb WARN-downgrade contract missing/incomplete (off-Claude hosts unguarded)"; fi

# --- Test 10p: SKILL.md states `safe` mode excludes the qb rung (distinct from 10o) -------
# `safe` must NEVER run qb (it withholds the growth burst AND the qb intent-replan), instead
# printing the qb hand-off for the operator to paste. This safety invariant is documented in
# SKILL.md but unpinned. Assert both halves — the exclusion and the hand-off disclosure — so a
# drift that lets `safe` reach qb (or drops the hand-off) fails. Distinct from the 10o WARN pin.
if python3 - "$ROOT/skills/planwright/SKILL.md" <<'PY' 2>/dev/null
import sys
t = open(sys.argv[1]).read()
need = []
if "never runs qb" not in t: need.append("safe-excludes-qb")
if "qb hand-off to paste" not in t: need.append("safe-prints-qb-handoff")
sys.exit(1 if need else 0)
PY
then ok "SKILL.md states safe mode never runs qb and prints the qb hand-off to paste"; else bad "SKILL.md safe-mode qb-exclusion (or its hand-off disclosure) missing/regressed"; fi

# --- Test 10q: SKILL.md pins the apply-time value-gate four-check definition -----------
# Execute's per-item value gate (keep/kill before applying) is defined by four named checks:
# (a) named failure, (b) removal test, (c) real consumer, (d) not self-justifying. This is the
# quality bar that stops padded items; it is documented in SKILL.md but unpinned (the existing
# value-gate test hits are reason-string round-trip bookkeeping). Assert all four are named, so
# silently dropping or renaming a check fails the suite.
if python3 - "$ROOT/skills/planwright/SKILL.md" <<'PY' 2>/dev/null
import re, sys
t = open(sys.argv[1]).read()
need = []
for label, pat in [("a:named-failure", r"\(a\)[^\n]*named failure"),
                   ("b:removal-test", r"\(b\)[^\n]*removal test"),
                   ("c:real-consumer", r"\(c\)[^\n]*real consumer"),
                   ("d:not-self-justifying", r"\(d\)[^\n]*not self-justifying")]:
    if not re.search(pat, t):
        need.append(label)
sys.exit(1 if need else 0)
PY
then ok "SKILL.md pins the value-gate four-check definition (named failure / removal test / real consumer / not self-justifying)"; else bad "a value-gate keep/kill check is missing or renamed in SKILL.md"; fi

# --- Test 10r: SKILL.md pins the value-gate false-green clause (the discriminator) -------
# The linchpin of value-gate check (a): "a test that merely asserts a string/section still
# exists in a doc or instruction file is NOT a named failure" — the rule that rejects false-green
# doc-string pins. Test 10q pins the four check LABELS; this pins the discriminating clause within
# (a), whose silent deletion (keeping the label) would re-admit the padded-doc-test class the gate
# exists to reject. Assert each half of the clause (bold markers stripped for the "not" check).
if python3 - "$ROOT/skills/planwright/SKILL.md" <<'PY' 2>/dev/null
import sys
t = open(sys.argv[1]).read()
need = []
if "merely asserts a string" not in t: need.append("clause:merely-asserts-a-string")
if "not a named failure" not in t.replace("**", ""): need.append("clause:not-a-named-failure")
if "instruction file" not in t: need.append("clause:doc-or-instruction-file")
sys.exit(1 if need else 0)
PY
then ok "SKILL.md pins the value-gate false-green clause (a doc/instruction string-existence test is not a named failure)"; else bad "SKILL.md value-gate false-green discriminator clause missing/regressed"; fi
