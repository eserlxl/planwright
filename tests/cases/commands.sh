# SPDX-FileCopyrightText: 2026 Eser KUBALI
# SPDX-License-Identifier: GPL-3.0-or-later
# shellcheck shell=bash
#
# commands/ helper commands + host instruction templates.
# Sourced by tests/run.sh after tests/lib.sh — NOT standalone (uses ROOT/TMP/ok/bad/ver).

# --- Test 13: commands/codvisor.md is a well-formed planwright helper command ---
# /codvisor is a thin alias that forwards to the planwright skill; guard its delegation
# contract so an edit can't silently drop the planwright reference or the no-arg default.
CMD="$ROOT/commands/codvisor.md"
if [ -f "$CMD" ]; then ok "commands/codvisor.md exists"; else bad "commands/codvisor.md missing"; fi
if python3 - "$CMD" <<'PY' 2>/dev/null
import re, sys
t = open(sys.argv[1], encoding="utf-8").read()
m = re.match(r"^---\n(.*?)\n---\n", t, re.S)
assert m, "no YAML frontmatter"
fm = m.group(1)
assert re.search(r"(?m)^description:\s*\S", fm), "missing description"
assert re.search(r"(?m)^argument-hint:\s*\S", fm), "missing argument-hint"
body = t[m.end():]
# the command must delegate to the planwright skill, not reimplement it
assert "planwright:planwright" in body, "body does not invoke the planwright skill"
# the no-arg flagship default must stay the advisor sweep
assert "cycle 10 depth 10 explore" in body, "no-arg advisor default not preserved"
PY
then ok "commands/codvisor.md has valid frontmatter and forwards to planwright (advisor default intact)"; else bad "commands/codvisor.md malformed or lost its planwright delegation/advisor default"; fi

# --- Test 14: commands/codinventor.md is a well-formed planwright helper command ---
# /codinventor is the invent twin of /codvisor; guard its delegation contract so an edit
# can't silently drop the planwright reference or the no-arg invent default.
CMD="$ROOT/commands/codinventor.md"
if [ -f "$CMD" ]; then ok "commands/codinventor.md exists"; else bad "commands/codinventor.md missing"; fi
if python3 - "$CMD" <<'PY' 2>/dev/null
import re, sys
t = open(sys.argv[1], encoding="utf-8").read()
m = re.match(r"^---\n(.*?)\n---\n", t, re.S)
assert m, "no YAML frontmatter"
fm = m.group(1)
assert re.search(r"(?m)^description:\s*\S", fm), "missing description"
assert re.search(r"(?m)^argument-hint:\s*\S", fm), "missing argument-hint"
body = t[m.end():]
# the command must delegate to the planwright skill, not reimplement it
assert "planwright:planwright" in body, "body does not invoke the planwright skill"
# the no-arg flagship default must stay the inventor sweep (invent flag)
assert "cycle 10 depth 10 invent" in body, "no-arg inventor default not preserved"
PY
then ok "commands/codinventor.md has valid frontmatter and forwards to planwright (inventor default intact)"; else bad "commands/codinventor.md malformed or lost its planwright delegation/inventor default"; fi

# --- Test 13c: codvisor/codinventor fold a path/lib scope into every form -------
# The helpers must peel a path/lib scope before classifying $ARGUMENTS and append it
# AFTER the subcommand, so a scoped flagship run (/codvisor path src/auth/) is
# reachable and cycle/execute stays the first token planwright dispatches on.
sc_cmd_ok=1
for cmd in codvisor codinventor; do
  if [ "$cmd" = codvisor ]; then flag=explore; else flag=invent; fi
  cf="$ROOT/commands/$cmd.md"
  python3 - "$cf" "$flag" <<'PY' 2>/dev/null || sc_cmd_ok=0
import sys
t = open(sys.argv[1]).read(); flag = sys.argv[2]
need = []
if "Peel the scope" not in t: need.append("peel-step")
if "path <X>" not in t or "lib <X>" not in t: need.append("path/lib-doc")
if "<rest>" not in t or "<scope>" not in t: need.append("rest/scope-vars")
if "first token" not in t: need.append("first-token-order")
# the flagship default is preserved and now carries the appended scope
if f"cycle 10 depth 10 {flag} <scope>" not in t: need.append("flagship+scope")
sys.exit(1 if need else 0)
PY
done
if [ "$sc_cmd_ok" = 1 ]; then ok "codvisor/codinventor peel a path/lib scope and append it after the subcommand"; else bad "codvisor/codinventor scope-aware resolution missing or malformed"; fi

# --- Test 13d: host instruction templates preserve scoped shortcut resolution ---
# Non-Claude hosts often use AGENTS.md/GEMINI.md text instead of command files, so
# those copyable adapters must carry the same path/lib peel-and-append rule.
sc_host_ok=1
for hf in AGENTS.example.md GEMINI.example_context-mode.md GEMINI.example.md; do
  python3 - "$ROOT/$hf" <<'PY' 2>/dev/null || sc_host_ok=0
import sys
t = open(sys.argv[1]).read()
need = []
for tok in ["path <X>", "lib <X>", "peel", "append"]:
    if tok not in t:
        need.append(tok)
for resolved in ["cycle 10 depth 10 explore path", "cycle 5 depth 8 invent lib"]:
    if resolved not in t:
        need.append(resolved)
sys.exit(1 if need else 0)
PY
done
if [ "$sc_host_ok" = 1 ]; then ok "host instruction templates preserve scoped codvisor/codinventor resolution"; else bad "host instruction templates lost scoped codvisor/codinventor resolution"; fi

# --- Test 15: commands/codcycle.md is a well-formed planwright orchestration command ---
# /codcycle drives planwright across an explore→invent→explore triad per outer cycle; guard
# its contract so an edit can't drop the planwright delegation, the three fixed phases, the
# 10-outer-cycle default, or the negative=infinite rule.
CMD="$ROOT/commands/codcycle.md"
if [ -f "$CMD" ]; then ok "commands/codcycle.md exists"; else bad "commands/codcycle.md missing"; fi
if python3 - "$CMD" <<'PY' 2>/dev/null
import re, sys
t = open(sys.argv[1], encoding="utf-8").read()
m = re.match(r"^---\n(.*?)\n---\n", t, re.S)
assert m, "no YAML frontmatter"
fm = m.group(1)
assert re.search(r"(?m)^description:\s*\S", fm), "missing description"
assert re.search(r"(?m)^argument-hint:\s*\S", fm), "missing argument-hint"
body = t[m.end():]
# the command must delegate to the planwright skill, not reimplement it
assert "planwright:planwright" in body, "body does not invoke the planwright skill"
# the three fixed phases of one outer cycle (explore -> invent -> explore)
assert "cycle 3 depth 10 explore" in body, "explore phase missing"
assert "cycle 3 depth 10 invent" in body, "invent phase missing"
# the explore phase must appear on BOTH sides of the invent phase (harden -> grow -> harden)
ei = body.index("cycle 3 depth 10 invent")
assert "cycle 3 depth 10 explore" in body[:ei], "no explore phase before invent"
assert "cycle 3 depth 10 explore" in body[ei:], "no explore phase after invent"
# the no-arg default (10 outer cycles) and the negative=infinite rule
assert "10 outer cycles" in body, "no-arg default of 10 outer cycles not stated"
assert "negative" in body.lower(), "negative=infinite rule not stated"
# the heavy-run cost banner — doubles as the invent-may-edit-MISSION.md awareness notice
assert "codcycle: max-intensity alternating sweep" in body, "cost-banner / invent awareness notice missing"
assert "MISSION.md" in body, "invent-may-edit-MISSION.md awareness clause missing"
# the help/usage line so /codcycle help (and bad args) stays documented
assert "Usage: /codcycle" in body, "help Usage line missing"
# scope-peeling parity with codvisor/codinventor (Test 13c): a path/lib scope must be
# peeled and appended AFTER each phase mode so "cycle" stays planwright's first token
assert "Peel the scope" in body, "scope peel-step missing"
assert "path <X>" in body and "lib <X>" in body, "path/lib scope doc missing"
assert "first token" in body, "first-token-order rule missing"
assert "cycle 3 depth 10 explore <scope>" in body, "scoped explore phase string missing"
assert "cycle 3 depth 10 invent <scope>" in body, "scoped invent phase string missing"
PY
then ok "commands/codcycle.md has valid frontmatter and orchestrates the explore→invent→explore triad"; else bad "commands/codcycle.md malformed or lost its triad/delegation/default contract"; fi
