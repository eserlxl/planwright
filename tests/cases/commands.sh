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
for tok in ["path <X>", "lib <X>", "peel", "append",
            # the CLI-habit flag aliases the command adapters tolerate must resolve
            # identically on AGENTS.md/Gemini hosts (commands/*.md step-0 parity)
            "--path <X>", "--lib <X>", "--scope <X>", "--opt=<X>"]:
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
# /codcycle drives planwright across an explore→invent rhythm per outer cycle (both phases fixed at
# cycle 3 depth 10; the invent phase rotates its generative framing via a per-outer-cycle seed), then
# closes the whole run with a single final explore; guard its contract so an edit can't drop the
# planwright delegation, the two per-cycle phases, the framing rotation (seed), the full-rotation
# meta-final-point, the closing explore, the 10-outer-cycle default, or the negative=infinite rule.
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
# the two fixed phases of one outer cycle (explore -> invent) plus a closing explore
assert "cycle 3 depth 10 explore" in body, "explore phase missing"
assert "cycle 3 depth 10 invent" in body, "invent phase missing"
# the per-cycle explore must precede the invent (harden -> grow), and a final closing
# explore must come AFTER the invent (the single explore that ends the whole run)
ei = body.index("cycle 3 depth 10 invent")
assert "cycle 3 depth 10 explore" in body[:ei], "no explore phase before invent (harden->grow)"
assert "cycle 3 depth 10 explore" in body[ei:], "no closing explore phase after invent"
# the closing explore must be explicitly framed as the final phase of the whole run
assert "final explore" in body.lower(), "no final/closing explore phase stated"
# the invent phase rotates its generative framing via a per-outer-cycle seed (the lever is
# framing rotation, NOT an adaptive cycle count — the cycle count is fixed at 3)
assert "seed <i>" in body, "invent phase does not pass the per-outer-cycle framing seed"
assert "framing rotation" in body.lower(), "framing rotation not described as the rotation lever"
# the fixed catalog the rotation sweeps, in order
for vantage in ("power-user", "integration", "onboarding", "reliability", "automation"):
    assert vantage in body, f"framing catalog vantage '{vantage}' missing"
# the meta-final-point is breadth-earned: a full framing rotation must come up dry (not one cycle)
assert "full framing rotation" in body.lower(), "meta-final-point not gated on a full framing rotation"
assert "dry_streak" in body or "dry streak" in body.lower(), "no consecutive-dry-cycle rotation counter"
# the old adaptive cycle-count knob must be gone (cycle count is fixed, not ramped to a 12 cap)
assert "cycle 12 depth 10 invent" not in body, "stale adaptive 4x invent cap still present"
# the no-arg default (10 outer cycles) and the negative=infinite rule
assert "10 outer cycles" in body, "no-arg default of 10 outer cycles not stated"
assert "negative" in body.lower(), "negative=infinite rule not stated"
PY
then ok "commands/codcycle.md orchestrates the explore→invent rhythm with a rotating invent framing and a closing explore"; else bad "commands/codcycle.md malformed or lost its rhythm/framing-rotation/closing-explore/delegation/default contract"; fi

# --- Test 15b: commands/codcycle.md peels a path/lib scope and trails it after the seed ---
# Test 13c guards the path/lib scope-peel for codvisor/codinventor but iterates ONLY those two
# (it excludes codcycle), and Test 15 asserts codcycle's phases/seed/framing but never the scope.
# codcycle.md step 0 carries the same peel contract, and its Phase B has a load-bearing token order:
# `<scope>` must trail `seed <i>` so `cycle` stays the FIRST token planwright dispatches on. Guard
# that step 0 can't be dropped and that the seed/scope order can't be flipped.
CMD="$ROOT/commands/codcycle.md"
if python3 - "$CMD" <<'PY' 2>/dev/null
import sys
t = open(sys.argv[1], encoding="utf-8").read()
need = []
# step 0 peel contract (mirrors Test 13c's peel-step / path-lib-doc / first-token assertions)
if "Peel the scope first" not in t: need.append("peel-step")
if "path <X>" not in t or "lib <X>" not in t: need.append("path/lib-doc")
if "<rest>" not in t or "<scope>" not in t: need.append("rest/scope-vars")
if "first token" not in t: need.append("first-token-order")
# Phase A (harden) and the final closing explore both carry the trailing scope, scope AFTER the mode
if "cycle 3 depth 10 explore <scope>" not in t: need.append("explore+scope")
# Phase B (grow): `<scope>` MUST trail `seed <i>` so `cycle` leads — the load-bearing order. The
# reordered form (scope ahead of the seed) must NOT be accepted.
if "cycle 3 depth 10 invent seed <i> <scope>" not in t: need.append("invent-seed-scope-order")
if "cycle 3 depth 10 invent <scope> seed <i>" in t: need.append("scope-ahead-of-seed")
sys.exit(1 if need else 0)
PY
then ok "commands/codcycle.md peels a path/lib scope and trails it after seed <i> (cycle stays first token)"; else bad "commands/codcycle.md scope-peel missing or its seed/scope order is wrong"; fi

# --- Test 15c: the --path/--lib/--scope alias-normalization contract is documented everywhere ---
# All scope-aware command files (and SKILL.md) promise to accept the CLI-habit `--`-prefixed flag
# forms, normalising `--path <X>`→`path <X>`, `--lib <X>`→`lib <X>`, `--scope <X>`→`path <X>`.
# Test 13c checks only the bare `path <X>`/`lib <X>` tokens, never the `--`-aliases, so deleting the
# alias sentence from any one file leaves the suite green. Guard the leniency contract in every file.
al_cmd_ok=1
for cmd in codvisor codinventor codcycle codshard; do
  cf="$ROOT/commands/$cmd.md"
  python3 - "$cf" <<'PY' 2>/dev/null || al_cmd_ok=0
import sys
t = open(sys.argv[1], encoding="utf-8").read()
need = []
# the three documented aliases must all be present...
for alias in ("--path <X>", "--lib <X>", "--scope <X>"):
    if alias not in t: need.append(alias)
# ...together with a normalise/equivalence cue tying alias to the bare form (the command files use →)
if "→" not in t and "≡" not in t: need.append("normalise-cue")
# both the spaced and = spellings of an --opt are accepted
if "--opt <X>" not in t or "--opt=<X>" not in t: need.append("opt-spellings")
sys.exit(1 if need else 0)
PY
done
if [ "$al_cmd_ok" = 1 ]; then ok "codvisor/codinventor/codcycle/codshard document the --path/--lib/--scope alias normalization"; else bad "a scope-aware command file lost its --path/--lib/--scope alias-normalization contract"; fi

# The canonical statement of the same rule lives in SKILL.md (uses ≡); guard it too. Anchor on the
# "Flag aliases." paragraph itself (not the whole file) — `--scope` also appears far away in the
# SCOPE→FOCUS section, so a file-wide substring check would survive gutting this paragraph.
SK="$ROOT/skills/planwright/SKILL.md"
if python3 - "$SK" <<'PY' 2>/dev/null
import re, sys
t = open(sys.argv[1], encoding="utf-8").read()
m = re.search(r"\*\*Flag aliases\.\*\*.*?(?=\n\n|\n#)", t, re.S)
assert m, "no '**Flag aliases.**' paragraph"
para = m.group(0)
need = []
for alias in ("--path <X>", "--lib <X>", "--scope <X>"):
    if alias not in para: need.append(alias)
# normalise/equivalence cue tying alias to the bare form (SKILL.md uses ≡)
if "≡" not in para and "→" not in para: need.append("normalise-cue")
# both --opt spellings are accepted
if "--opt <X>" not in para or "--opt=<X>" not in para: need.append("opt-spellings")
sys.exit(1 if need else 0)
PY
then ok "SKILL.md states the canonical --path/--lib/--scope alias-normalization rule"; else bad "SKILL.md lost its canonical --path/--lib/--scope alias-normalization rule"; fi

# --- Test 16: commands/codshard.md is a well-formed sharded-sweep orchestration command ---
# /codshard partitions whole-repo maturity work into per-shard scoped cycles plus one closing
# whole-repo round; guard the planwright delegation, the per-shard invocation form, the
# sequential-rounds rule, the unscoped closing round (the only round that may declare the global
# final point), the deterministic staleness/lexicographic shard order, the auto-enumeration rule,
# the no-arg defaults, the Usage/STOP contract, the closing-round-only explore escalation, and
# the invent/seed exclusion.
CMD="$ROOT/commands/codshard.md"
if [ -f "$CMD" ]; then ok "commands/codshard.md exists"; else bad "commands/codshard.md missing"; fi
if python3 - "$CMD" <<'PY' 2>/dev/null
import re, sys
t = open(sys.argv[1], encoding="utf-8").read()
m = re.match(r"^---\n(.*?)\n---\n", t, re.S)
assert m, "no YAML frontmatter"
fm = m.group(1)
assert re.search(r"(?m)^description:\s*\S", fm), "missing description"
assert re.search(r"(?m)^argument-hint:\s*\S", fm), "missing argument-hint"
# normalize whitespace so a legitimate paragraph rewrap can neither break nor save an assertion
body = " ".join(t[m.end():].split())
# the command must delegate to the planwright skill, not reimplement it (polarity pinned —
# a "feel free to re-implement" rewrite must fail, not pass)
assert "planwright:planwright" in body, "body does not invoke the planwright skill"
assert "not** re-implement" in body, "do-not-reimplement rule missing or inverted"
# the per-shard invocation, anchored to the invocation site (the Usage line and banner echo the
# same token, so a site-only reorder would otherwise stay green), plus the codcycle-style
# negative guard: `cycle` must stay the first token, the shard scope must trail
assert "Invoke planwright with `cycle <M> depth <D> path <shard>`" in body, "per-shard invocation site missing or reworded"
assert "path <shard> cycle" not in body, "shard scope ahead of cycle in an invocation"
# the closing round is unscoped and comes AFTER the shard loop (header order, Test 15 style)
assert "cycle <M> depth <D>` (unscoped)" in body, "closing round is not the unscoped invocation"
si = body.index("=== codshard shard i/K")
ci = body.index("=== codshard closing whole-repo round ===")
assert si < ci, "closing round does not follow the shard loop"
assert "global final point" in body, "global-final-point ownership not stated"
assert "scoped final point" in body, "per-shard scoped final point not stated"
# rounds are sequential — anchored to the shard loop so the clause can't be reattached to recon
assert "shard loop** — always sequential" in body, "sequential-rounds rule missing or reattached"
assert "never the rounds" in body, "recon-parallelises-reading-only clause missing"
# stop conditions: a hard blocker / broken tree halts the loop AND withholds the closing round
# (the Usage-line STOP must not alias these — they are asserted by their own vocabulary)
assert "hard blocker" in body, "hard-blocker stop rule missing"
assert "broken tree" in body, "broken-tree stop rule missing"
assert "or the closing round" in body, "closing round not withheld on a broken tree"
# deterministic shard order: staleness primary and descending, lexicographic fallback/tiebreak,
# graph routing-only
assert "order shards by staleness" in body, "staleness ordering missing or demoted"
assert "descending count" in body, "staleness direction inverted or unpinned"
assert "never-audited" in body, "never-audited predicate missing"
assert "lexicographic" in body, "lexicographic fallback/tiebreak missing"
# the three edge-contract clauses are executor behavior — deleting any must fail, not pass:
# a present-but-unparseable graph falls back to lexicographic (not executor improvisation)
assert "exists and parses" in body, "staleness precondition lost its parse requirement"
assert "cannot be parsed" in body, "malformed-graph lexicographic fallback missing"
# scope/escalation keywords as shards entries are a malformed list caught upfront
assert "`path`, `lib`, `seed`, `explore`, `invent`" in body, "extended keyword-entry guard missing"
# a sub-1 integer after parallel never binds to J — it falls through to the invalid-M Usage stop
assert "does **not** bind" in body, "sub-1 parallel-J no-bind rule missing"
assert "falls through to step 4" in body, "sub-1 parallel-J fall-through destination missing"
# auto-enumeration and its edge rules (behavioral contract, not flavor)
assert "top-level directories" in body, "top-level directory enumeration missing"
assert "ls-files" in body, "git-tracked enumeration source missing"
assert "fewer than 3 tracked files" in body, "small-directory fold rule missing"
assert "folded" in body, "fold reporting missing"
assert "K = 0" in body, "flat-repo (K = 0) rule missing"
# the operative defaults in the classification step (the Usage echo alone must not satisfy this)
assert "`M = 3`" in body, "operative default M missing from the classification step"
assert "depth defaults to 10" in body, "operative default depth missing"
assert "cycle 3 depth 10" in body, "no-arg default (cycle 3 depth 10 per shard) not stated"
# help and malformed args print Usage and stop
assert "Usage:" in body, "no Usage line"
assert "STOP" in body, "no STOP rule for help/malformed args"
# explicit shard list option
assert "shards <a,b,c>" in body, "explicit shards <a,b,c> list option missing"
# invent/seed are excluded with the printed note (pinned verbatim — not silently swallowed),
# and no invocation token may quietly gain them: all invocations share the `depth <D> ...`
# shape, while the legitimate text only ever uses bare `invent`/`seed <S>`
assert "codshard: invent/seed are not composable" in body, "invent/seed-exclusion note missing"
assert "<D> invent" not in body, "an invocation gained invent"
assert "<D> seed" not in body, "an invocation gained seed"
# explore composes with the CLOSING round only. Pin: the peel step itself (deleting it kills
# the feature while the Usage echo stays green), the escalated invocation at the closing-round
# site AND gated on the peeled flag (position alone survives an opt-out polarity swap), the
# shard-loop polarity (no per-shard invocation gains explore — path or lib, either token
# order, plus a whole-section sweep from the loop intro to the closing header), the Usage-line
# flag, the banner swap pinned to the closing round's parenthetical in both variants, and the
# summary's escalation-report field
assert "Peel `explore`** from `<rest>`" in body, "explore peel step missing"
assert "closing round only" in body, "explore closing-round-only rule missing"
assert "never escalated" in body, "shard-loop-never-escalated polarity missing"
ei = body.index("`cycle <M> depth <D> explore` (unscoped)")
assert ci < ei, "escalated closing invocation not at the closing-round site"
assert "`cycle <M> depth <D> explore` (unscoped) when the `explore` flag was peeled" in body, "escalated closing invocation not gated on the peeled flag"
assert "explore path <shard>" not in body, "a per-shard invocation gained explore (leading)"
assert "path <shard> explore" not in body, "a per-shard invocation gained explore (trailing)"
assert "explore lib <shard>" not in body, "a per-shard lib invocation gained explore (leading)"
assert "lib <shard> explore" not in body, "a per-shard lib invocation gained explore (trailing)"
li = body.index("Then run the **shard loop")
assert "explore" not in body[li:ci], "explore leaked into the shard-loop section"
assert "[explore]" in body, "Usage line lost the explore flag"
assert "explore escalates the closing round only" in body, "Usage explore clause missing"
assert "swapping the closing round's parenthetical to `(cycle <M> depth <D> explore)`" in body, "banner explore swap not pinned to the closing round"
assert "(in both banner variants)" in body, "explore banner swap lost the K = 0 variant"
assert "escalated with `explore`" in body, "summary lost the explore-escalation field"
# the cost banner (both variants) and the cumulative summary are load-bearing output
assert "codshard: sharded maturity sweep" in body, "cost banner missing"
assert "no shardable top-level directory" in body, "K = 0 banner variant missing"
assert "cumulative summary" in body, "final cumulative summary missing"
assert "stop reason" in body, "stop-reason reporting missing"
PY
then ok "commands/codshard.md orchestrates per-shard scoped cycles with an unscoped closing round (sequential, ordered, stop-guarded, delegation intact)"; else bad "commands/codshard.md malformed or lost its shard-loop/closing-round/ordering/stop-rule/delegation contract"; fi

# --- Test 16b: codshard's parallel recon contract (Claude-Code-only, routing-only, read-only) ---
# The opt-in `parallel` flag may spawn subagents ONLY for read-only recon whose leads are
# re-verification seeds — never Evidence — with a stated serial fallback on hosts without a
# subagent primitive, and no state files of its own. Guard every clause: dropping any one of
# them silently converts recon from a routing prefetch into a second source of truth (or breaks
# the non-Claude hosts the skill promises to support).
CMD="$ROOT/commands/codshard.md"
if python3 - "$CMD" <<'PY' 2>/dev/null
import sys
# normalize whitespace so a legitimate rewrap can neither break nor save an assertion
t = " ".join(open(sys.argv[1], encoding="utf-8").read().split())
need = []
# the flag and its J binding rule (J must not be mistaken for M or D)
if "parallel [J]" not in t: need.append("parallel-flag")
if "binds to it" not in t: need.append("J-binding-rule")
# anchor every recon clause INSIDE the recon paragraph — 'never Evidence' and 'routing-only'
# also appear in the graph-ordering paragraph, so a file-wide match would let the recon
# clauses be inverted (leads promoted to Evidence) while the suite stays green
a = t.find("**Parallel recon")
b = t.find("Then run the **shard loop")
if a < 0 or b < 0 or b <= a:
    need.append("recon-paragraph-bounds")
    para = ""
else:
    para = t[a:b]
for tok, tag in (
    ("read-only", "read-only"),
    ("MUST state verbatim", "prompt-must-state"),
    ("no file edits, no writes, no state, no mutating commands", "no-mutation-clause"),
    ("at most 8 candidate leads", "lead-cap"),
    ("routing-only", "routing-only"),
    ("re-verification seeds", "reverification-seeds"),
    ("never Evidence", "never-evidence"),
    ("re-proven", "re-proven"),
    ("writes no files of its own", "no-state-files"),
    ("single-agent", "single-agent-charter"),
    ("nothing is appended to the planwright argument string", "no-arg-injection"),
    ("lib` shards get no recon", "lib-recon-skip"),
    ("parallel recon unavailable on this host", "fallback-note"),
    ("continuing sequential without recon", "fallback-continues"),
):
    if tok not in para: need.append(tag)
sys.exit(1 if need else 0)
PY
then ok "commands/codshard.md keeps parallel recon read-only, routing-only, stateless, and host-degradable (clauses anchored in the recon paragraph)"; else bad "commands/codshard.md lost a parallel-recon guard (read-only/routing-only/never-Evidence/fallback/stateless)"; fi

# --- Test 16c: codshard peels a path/lib scope into a single-entry shard list ---
# Tests 13c/15b guard the scope-peel for the other commands, where the scope is appended after
# the subcommand; codshard's contract differs — a peeled scope BECOMES the shard list — so guard
# its own form: the peel step exists, the scope-to-shard-list rule is stated, and `cycle` stays
# the first token of every planwright invocation.
CMD="$ROOT/commands/codshard.md"
if python3 - "$CMD" <<'PY' 2>/dev/null
import sys
# normalize whitespace so a legitimate rewrap can neither break nor save an assertion
t = " ".join(open(sys.argv[1], encoding="utf-8").read().split())
need = []
if "Peel the scope first" not in t: need.append("peel-step")
if "path <X>" not in t or "lib <X>" not in t: need.append("path/lib-doc")
if "<rest>" not in t: need.append("rest-var")
if "single-entry shard list" not in t: need.append("scope-becomes-shard-list")
if "first token" not in t: need.append("first-token-order")
sys.exit(1 if need else 0)
PY
then ok "commands/codshard.md peels a path/lib scope into a single-entry shard list (cycle stays first token)"; else bad "commands/codshard.md scope-peel missing or its scope-to-shard-list rule was dropped"; fi

# --- commands/dashboard.md launches the bundled read-only dashboard server ---
# /dashboard wraps `dashboard.py --open`; guard that it resolves the bundled <scripts>
# path, launches non-blocking (background) so the turn does not hang, opens the browser,
# and keeps the read-only contract (it must NOT reimplement or mutate anything).
CMD="$ROOT/commands/dashboard.md"
if [ -f "$CMD" ]; then ok "commands/dashboard.md exists"; else bad "commands/dashboard.md missing"; fi
if python3 - "$CMD" <<'PY' 2>/dev/null
import re, sys
t = open(sys.argv[1], encoding="utf-8").read()
m = re.match(r"^---\n(.*?)\n---\n", t, re.S)
assert m, "no YAML frontmatter"
fm = m.group(1)
assert re.search(r"(?m)^description:\s*\S", fm), "missing description"
assert re.search(r"(?m)^argument-hint:\s*\S", fm), "missing argument-hint"
body = t[m.end():]
assert "<scripts>/dashboard.py" in body, "does not invoke the bundled dashboard.py"
assert "${CLAUDE_PLUGIN_ROOT}/scripts" in body, "scripts path not resolved like the other commands"
assert "--open" in body, "does not open the browser"
assert "background" in body.lower(), "does not launch in the background (would block the turn)"
assert "read-only" in body.lower(), "read-only contract not stated"
PY
then ok "commands/dashboard.md launches the bundled read-only dashboard (resolved <scripts>, --open, non-blocking)"; else bad "commands/dashboard.md malformed or lost its dashboard-launch contract"; fi
