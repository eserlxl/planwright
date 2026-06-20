# SPDX-FileCopyrightText: 2026 Eser KUBALI
# SPDX-License-Identifier: GPL-3.0-or-later
# shellcheck shell=bash
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

# --- Test 10d: SKILL.md owns the canonical parallel-recon contract (Stage 1.6) ---
# Recon moved from the command layer into the base skill (commands now just FORWARD `parallel`).
# Stage 1.6 must keep the full read-only / routing-only / never-Evidence ceiling, the two-backend
# ladder (native subagent + the OPTIONAL, never-auto external-agent CLI), the run-agent.sh contract,
# egress disclosure, and the degrade-to-no-recon fallback — anchored INSIDE the Stage 1.6 section so a
# clause can't be satisfied from elsewhere, and the external rung stays explicit + optional (no forced
# OpenAI/Google subscription).
if python3 - "$ROOT/skills/planwright/SKILL.md" <<'PY' 2>/dev/null
import sys
# normalize whitespace so a legitimate rewrap can neither break nor save an assertion
t = " ".join(open(sys.argv[1], encoding="utf-8").read().split())
need = []
if "### Stage 1.6 — Parallel recon" not in t: need.append("stage-1.6-heading")
a = t.find("### Stage 1.6 — Parallel recon")
b = t.find("### Stage 2 — Audit")
if a < 0 or b < 0 or b <= a:
    need.append("recon-section-bounds"); para = ""
else:
    para = t[a:b]
for tok, tag in (
    ("read-only", "read-only"),
    ("git-tracked files", "recon-tracked-only"),
    ("no file edits, no writes, no state, no mutating commands", "no-mutation-clause"),
    ("at most 8 candidate leads", "lead-cap"),
    ("routing-only re-verification seeds", "routing-only"),
    ("never Evidence", "never-evidence"),
    ("re-proven", "re-proven"),
    ("writes no files of its own", "no-state-files"),
    ("no matter which backend", "never-evidence-all-backends"),
    ("single-agent", "single-agent-charter"),
    ("Native subagent backend", "native-backend"),
    ("External-agent CLI backend", "external-cli-backend"),
    ("never auto-selected", "ea-explicit-only"),
    ("entirely optional", "ea-optional"),
    ("never requires", "ea-not-required"),
    ("delegated to external agents", "ea-delegation"),
    ("host-neutral", "host-neutral"),
    ("run-agent.sh --check", "ea-availability-probe"),
    ("--agent all --read-only", "ea-readonly-invocation"),
    ("external providers", "ea-egress-disclosure"),
    ("best-effort", "agy-best-effort"),
    ("sets fan-out", "j-defined"),
    ("ignored under `invent`", "invent-skip"),
    ("planwright: parallel recon unavailable — continuing without recon.", "fallback-message"),
    ("and run the audit unchanged", "audit-unchanged"),
):
    if tok not in para: need.append(tag)
sys.exit(1 if need else 0)
PY
then ok "SKILL.md Stage 1.6 owns the parallel-recon contract (read-only, routing-only, never-Evidence, native + optional/never-auto external backend, run-agent.sh, egress, degrade)"; else bad "SKILL.md Stage 1.6 parallel-recon contract lost a guard (read-only/routing-only/never-Evidence/backend/optional-external/fallback)"; fi

# --- Test 10e: SKILL.md Stage 1 mandates a git-tracked-only scan (never gitignored) ---
# planwright must never scan gitignored files. Stage 1's scan instruction must state the
# tracked-only invariant and name the gitignore-blind tools it forbids, anchored INSIDE the
# Stage 1 section so the rule cannot be satisfied from unrelated prose elsewhere.
if python3 - "$ROOT/skills/planwright/SKILL.md" <<'PY' 2>/dev/null
import sys
t = " ".join(open(sys.argv[1], encoding="utf-8").read().split())
a = t.find("### Stage 1 — Scan")
b = t.find("### Stage 1.5")
need = []
if a < 0 or b < 0 or b <= a:
    need.append("stage-1-bounds"); para = ""
else:
    para = t[a:b]
for tok, tag in (
    ("Scan only git-tracked files", "tracked-only-mandate"),
    ("never read a gitignored path", "no-gitignored-read"),
    ("git ls-files", "git-ls-files-enum"),
    ("grep -r", "forbids-grep-r"),
    ("--no-ignore", "forbids-no-ignore"),
):
    if tok not in para: need.append(tag)
sys.exit(1 if need else 0)
PY
then ok "SKILL.md Stage 1 mandates a git-tracked-only scan and forbids gitignore-blind tools"; else bad "SKILL.md Stage 1 lost the git-tracked-only scan invariant (gitignore exclusion regressed)"; fi

# --- Test 10a2: Execute Preconditions hard-block on unconfigured git identity ---
# The mutating Execute path commits every passing item, so an unset git user.name/user.email
# makes the first per-item `git commit` fail (exit 128) and crash the run mid-execution.
# doctor.py only WARNs on this (planning never commits), so Execute must enforce identity in
# its own Preconditions block and STOP before any mutation. Scope the check to the Execute
# Preconditions section (not just anywhere in SKILL.md) and require user.name + user.email +
# a STOP directive, so the hard-block cannot silently regress to a warning or vanish.
if python3 - "$ROOT/skills/planwright/SKILL.md" <<'PY' 2>/dev/null
import re, sys
t = open(sys.argv[1]).read()
m = re.search(r"## Preconditions \(check first, in order\)(.*?)\n## Modes and scope", t, re.S)
if not m:
    raise SystemExit(1)
block = m.group(1)
ok = ("user.name" in block and "user.email" in block
      and re.search(r"(?i)\bstop\b", block) is not None)
sys.exit(0 if ok else 1)
PY
then ok "Execute Preconditions hard-block on unconfigured git identity (user.name/user.email)"; else bad "Execute Preconditions lack a git-identity hard-block (execute would crash mid-run on unset identity)"; fi

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

# --- Test 10c: the version-bearing manifests bump-version syncs stay in agreement ---
# bump-version.sh updates .claude-plugin/plugin.json, .codex-plugin/plugin.json, and
# skills/*/SKILL.md frontmatter in lockstep; nothing else guards that a hand-edit /
# partial bump did not drift them, which would make version/upgrade report a wrong
# version. Assert all three agree. (This repo is plugin-only — it ships no
# marketplace.json; it is published via the external eserlxl/claude-marketplace aggregator.)
if python3 - "$ROOT" <<'PY' 2>/dev/null
import json, os, re, sys
root = sys.argv[1]
vers = {}
vers["claude-plugin"] = json.load(open(os.path.join(root, ".claude-plugin/plugin.json")))["version"]
vers["codex-plugin"] = json.load(open(os.path.join(root, ".codex-plugin/plugin.json")))["version"]
t = open(os.path.join(root, "skills/planwright/SKILL.md")).read()
m = re.search(r'\n  version:\s*"([^"]+)"', t)
vers["skill-frontmatter"] = m.group(1) if m else None
sys.exit(0 if len(set(vers.values())) == 1 and None not in vers.values() else 1)
PY
then ok "version is in agreement across the three manifests bump-version syncs"; else bad "version drift across plugin/codex/SKILL manifests"; fi

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

# Contract between SKILL.md Stage 2b and build-graph.py for the silent-failure signal:
# the prose promotion rule must name `swallow_at`, and the builder must actually emit
# the key (SWALLOW_KW table + node fields) — so the spec can't promote on a signal the
# script doesn't compute, and the signal can't lose its consumer silently.
swallow_ok=1
grep -q 'swallow_at' "$ROOT/skills/planwright/SKILL.md" || swallow_ok=0
grep -q 'SWALLOW_KW' "$ROOT/scripts/build-graph.py" || swallow_ok=0
grep -q '"swallow_at"' "$ROOT/scripts/build-graph.py" || swallow_ok=0
grep -q '"swallow_count"' "$ROOT/scripts/build-graph.py" || swallow_ok=0
if [ "$swallow_ok" = 1 ]; then ok "SKILL.md's swallow_at promotion rides keys build-graph.py emits (SWALLOW_KW wiring)"; else bad "swallow signal wiring incomplete: SKILL.md mention or build-graph.py SWALLOW_KW/keys missing"; fi

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

# --- Test 10f: SKILL.md OUTPUT FORMAT field set agrees with lint-plan REQUIRED/KNOWN_FIELDS ---
# The eight-field item contract must stay consistent across SKILL.md (the OUTPUT FORMAT block)
# and the linter constants (REQUIRED_FIELDS / KNOWN_FIELDS): neither artifact may rename, drop,
# or add a field unilaterally. Import the linter constants directly (importlib, since the script
# name is hyphenated) and compare against the labels parsed from the OUTPUT FORMAT fenced block.
if python3 - "$ROOT" <<'PY' 2>/dev/null
import importlib.util, os, re, sys
root = sys.argv[1]
spec = importlib.util.spec_from_file_location(
    "lint_plan_fields", os.path.join(root, "scripts", "lint-plan.py"))
lp = importlib.util.module_from_spec(spec)
spec.loader.exec_module(lp)
t = open(os.path.join(root, "skills/planwright/SKILL.md")).read()
m = re.search(r"## OUTPUT FORMAT.*?```\n(- \[ \].*?)\n```", t, re.S)
if not m:
    raise SystemExit(1)
labels = re.findall(r"(?m)^\s+([A-Z][A-Za-z ]*?):\s*<", m.group(1))
required = [l for l in labels if l != "New Surfaces"]
good = (set(required) == set(lp.REQUIRED_FIELDS)
        and "New Surfaces" in lp.KNOWN_FIELDS
        and set(labels) <= lp.KNOWN_FIELDS)
sys.exit(0 if good else 1)
PY
then ok "SKILL.md OUTPUT FORMAT field set agrees with lint-plan REQUIRED_FIELDS/KNOWN_FIELDS"; else bad "SKILL.md item field set drifted from lint-plan REQUIRED_FIELDS/KNOWN_FIELDS"; fi

# --- Test 10g: SKILL.md Mode table agrees with lint-plan VALID_MODES ---
# The five-Mode set must stay consistent across SKILL.md's Mode-assignment table and the
# linter's VALID_MODES: a Mode cannot be added or renamed in one without the other.
if python3 - "$ROOT" <<'PY' 2>/dev/null
import importlib.util, os, re, sys
root = sys.argv[1]
spec = importlib.util.spec_from_file_location(
    "lint_plan_modes", os.path.join(root, "scripts", "lint-plan.py"))
lp = importlib.util.module_from_spec(spec)
spec.loader.exec_module(lp)
t = open(os.path.join(root, "skills/planwright/SKILL.md")).read()
i = t.find("### Mode assignment")
if i < 0:
    raise SystemExit(1)
j = t.find("\n## ", i)
table = t[i:j if j > i else len(t)]
modes = set(re.findall(r"(?m)^\|\s*`([a-z]+)`\s*\|", table))
sys.exit(0 if modes == lp.VALID_MODES else 1)
PY
then ok "SKILL.md Mode table agrees with lint-plan VALID_MODES"; else bad "SKILL.md Mode set drifted from lint-plan VALID_MODES"; fi

