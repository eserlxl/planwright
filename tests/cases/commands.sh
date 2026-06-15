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
            "--path <X>", "--lib <X>", "--scope <X>", "--opt=<X>",
            # the orchestrators must stay discoverable on non-Claude hosts:
            # each template names all three, the codcycle/codshard recipe files, and
            # the codmaster sense engine (never a prose decision table)
            "codcycle", "codshard", "codmaster",
            "commands/codcycle.md", "commands/codshard.md", "status.py"]:
    if tok not in t:
        need.append(tok)
for resolved in ["cycle 10 depth 10 explore path", "cycle 5 depth 8 invent lib"]:
    if resolved not in t:
        need.append(resolved)
sys.exit(1 if need else 0)
PY
done
if [ "$sc_host_ok" = 1 ]; then ok "host instruction templates carry the six-helper family with scoped codvisor/codinventor resolution"; else bad "host instruction templates lost a helper (codcycle/codshard/codmaster) or the scoped resolution rules"; fi

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
for cmd in codvisor codinventor codcycle codshard codmaster; do
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
if [ "$al_cmd_ok" = 1 ]; then ok "codvisor/codinventor/codcycle/codshard/codmaster document the --path/--lib/--scope alias normalization"; else bad "a scope-aware command file lost its --path/--lib/--scope alias-normalization contract"; fi

# --- Test 15d: commands/codmaster.md peels a path/lib scope into BOTH sense and dispatch ----
# codmaster is the only scope-aware orchestrator that also SENSES (status.py --recommend): a scope
# must thread into the engine (--scope <scope-spec>) so pending/debt/convergence are Focus-restricted,
# AND trail every dispatch (cycle/execute stays the first token), AND suppress the two whole-repo
# moves the scope excludes — codshard auto-route + reset + the post-growth sharded harden. Test 15c
# guards only the alias sentence; this guards the load-bearing sense/dispatch/suppression wiring.
CMD="$ROOT/commands/codmaster.md"
if python3 - "$CMD" <<'PY' 2>/dev/null
import sys
t = open(sys.argv[1], encoding="utf-8").read()
need = []
# step 0 peel contract (mirrors Test 15b)
if "Peel the scope first" not in t: need.append("peel-step")
if "path <X>" not in t or "lib <X>" not in t: need.append("path/lib-doc")
if "<rest>" not in t or "<scope>" not in t: need.append("rest/scope-vars")
if "<scope-spec>" not in t: need.append("scope-spec-var")
if "first token" not in t: need.append("first-token-order")
# the SENSE engine is threaded the colon form so the recommendation itself is Focus-restricted
if "--scope <scope-spec>" not in t: need.append("sense-scope-thread")
# the bare scope trails the record's args (scope AFTER the subcommand, never leading)
if "append `<scope>`" not in t: need.append("dispatch-scope-append")
# the two whole-repo moves never auto-route under a scope (codshard/reset), and the post-growth
# sharded harden override is suppressed when scoped
if "auto-route" not in t: need.append("whole-repo-suppress")
if "no scope was peeled in step 0" not in t: need.append("post-growth-shard-guard")
sys.exit(1 if need else 0)
PY
then ok "commands/codmaster.md threads a path/lib scope into SENSE (--scope) and every dispatch, suppressing codshard/reset under scope"; else bad "commands/codmaster.md scope wiring missing (sense thread / dispatch append / whole-repo-move suppression)"; fi

# --- Test 15e: commands/codmaster.md gates the loop-mode lap-boundary relap under a scope ------
# Test 15d guards the step-0 / post-growth whole-repo-move suppression, but NOT the loop terminal
# check's relap. Before the gate a scoped `loop` drive fell through to an unconditional `reset` (a
# whole-repo .planwright wipe erasing sibling components' audit memory — the exact harm step 0
# forbids). Guard that the loop relap stays scope-gated so it cannot silently regress.
CMD="$ROOT/commands/codmaster.md"
if python3 - "$CMD" <<'PY' 2>/dev/null
import sys
t = open(sys.argv[1], encoding="utf-8").read()
need = []
# the positive gate clause must be present
if "lap-boundary relap does not reset" not in t: need.append("loop-relap-scope-gate")
# and the unscoped path must still reset (so the gate is a scope carve-out, not a blanket removal)
if "unscoped" not in t or "loop relap dispatches" not in t: need.append("unscoped-relap-carveout")
sys.exit(1 if need else 0)
PY
then ok "commands/codmaster.md gates the loop-mode lap-boundary relap under a scope"; else bad "commands/codmaster.md lost the loop-mode relap scope gate (a scoped loop drive could fire a whole-repo reset)"; fi

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

# --- Test 16d: codshard wires the run-close reconcile-sweep (completion-accounting net) ---
# A shard or closing round that commits a fix inline without landing it would silently miss
# completed.md (the only file the dashboard reads). codshard must capture a run-start ref and run
# lifecycle.py reconcile-sweep --since <ref> at run-end so those drifted commits are recorded.
CMD="$ROOT/commands/codshard.md"
if python3 - "$CMD" <<'PY' 2>/dev/null
import sys
t = open(sys.argv[1], encoding="utf-8").read()
need = []
if "run-start ref" not in t: need.append("run-start-ref-capture")
if "lifecycle.py reconcile-sweep --since" not in t: need.append("reconcile-sweep-call")
if "completion-accounting" not in t: need.append("invariant-framing")
if "${CLAUDE_PLUGIN_ROOT}/scripts" not in t: need.append("scripts-resolution")
sys.exit(1 if need else 0)
PY
then ok "commands/codshard.md wires a run-close reconcile-sweep over the run's commits (completion-accounting net)"; else bad "commands/codshard.md lost the run-close reconcile-sweep wiring (run-start ref / --since / invariant framing)"; fi

# --- Test 17: commands/codmaster.md is the autonomous front-door driver ---
# codmaster owns NO decision logic: the table lives in status.py --recommend (cross-pinned
# against the dashboard coach via tests/fixtures/coach-table.json), and codmaster senses,
# relays, dispatches CONSECUTIVELY until a recorded final point, and reports. Guard: the
# engine invocation and the no-prose-table polarity (an unavailable engine STOPs, never
# improvises), the three-word grammar, advise's dispatch-nothing rule, safe's no-invention
# contract (stops at the first convergence), the default growing authority WITH the verbatim
# MISSION.md disclosure and the at-most-once growth bound (invent's must-generate mandate
# never self-terminates), the composite reset decision (necessity shown, not assumed), the
# mechanical blocker stop, doctor read-only (never --fix), depth always 10, the per-step
# re-sense (never a precomputed chain), the no-progress stall guard, the 12-step safety cap,
# and the stop-relay honesty (verbatim relay; next-step suggestion suppressed on a broken stop).
CMD="$ROOT/commands/codmaster.md"
if [ -f "$CMD" ]; then ok "commands/codmaster.md exists"; else bad "commands/codmaster.md missing"; fi
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
# the dumb-dispatcher delegation: the brain is the tested engine, never command prose
assert "status.py --root . --recommend" in body, "engine invocation missing"
assert "no per-state coach-table logic and no planning logic" in body, "coach-table-delegation rule missing"
assert "lap orchestration" in body, "lap-orchestration ownership framing missing"
assert "never re-derive the recommendation in prose" in body, "no-prose-table rule missing"
assert "recommendation engine unavailable" in body, "engine-unavailable stop missing"
assert "never substitute a prose decision table" in body, "engine-unavailable polarity missing"
assert "coach-table.json" in body, "cross-pin fixture not named"
assert "planwright:planwright" in body, "skill dispatch missing"
# grammar (advise stands alone; safe/loop/parallel compose), advise tells only
assert "Usage: /codmaster [advise | [safe] [loop] [parallel [J]]]" in body, "Usage line missing or the grammar grew"
assert "STOP" in body, "no STOP rule"
assert "STOP — dispatch nothing" in body, "advise dispatch-nothing rule missing"
# advise discloses the enforce overlay (added 791a00f, was unpinned): at a converged invent-dry
# recommendation the default (non-safe) drive grows anyway, so advise must say so even though it
# dispatches nothing -- the read-only relay still tells the truth about what a real drive would do
assert "non-growth invent-dry move" in body, "advise enforcement-notice trigger (converged invent-dry) missing"
assert "a default (non-`safe`) drive would instead take an enforced `codinventor` burst" in body, "advise enforcement notice missing (default drive grows where engine routes invent-dry)"
# safe = without invention capability; default = growing authority + verbatim disclosure
assert "without invention capability" in body, "safe-mode contract missing"
assert "do NOT dispatch" in body, "safe-mode no-dispatch polarity missing"
assert "growing authority by default" in body, "default grow authority missing"
assert "Note: invent may make rare, small committed edits to repo files, including MISSION.md." in body, "MISSION.md disclosure not verbatim"
# the reset decision is a single composite dispatch, keeps rejected.md, and fires only
# when really necessary (shown, not assumed) — never while a non-destructive move remains
assert "keeps `rejected.md`" in body, "reset rejected.md retention missing"
assert "follow_up" in body, "reset follow-up sweep missing"
assert "one composite dispatch" in body, "composite-dispatch rule missing"
assert "only when really necessary" in body, "reset necessity rule missing"
assert "shown, not assumed" in body, "reset necessity polarity missing"
assert "never wiped while a non-destructive move remains" in body, "reset non-destructive-first rule missing"
# mechanical gates and dispatch discipline
assert "no judgment call" in body, "mechanical blocker rule missing"
assert "never runs `doctor --fix`" in body, "doctor read-only rule missing"
assert "maximum depth — depth 10" in body, "depth-10 rule missing"
assert "dispatch codcycle" not in body, "codcycle entered the dispatch vocabulary"
# parallel: an opt-in host capability forwarded to codshard dispatches, a print-only nudge
# otherwise — parallel itself never overrides the engine's command choice (it only shapes HOW a
# codshard dispatch runs; the loop post-growth sharded harden, below, is the one command-shaping rule)
assert "forward codshard's read-only recon prefetch" in body, "parallel flag definition missing"
assert "never changes which command the engine chooses" in body, "parallel no-override polarity missing"
assert "codshard parallel explore" in body, "parallel pass-through example missing"
assert "parallel only affects codshard" in body, "parallel non-codshard nudge missing"
assert "/codshard parallel directly" in body, "parallel /codshard suggestion missing"
assert "parallel had no effect this run" in body, "parallel no-effect report note missing"
assert "accelerates the harden sweep that dominates each lap restart" in body, "parallel not forwarded to the reset follow-up codshard sweep (loop parallel)"
# the loop contract: consecutive dispatch to the final point, fresh sensing between steps,
# the at-most-once growth bound, the stall guard, and the runaway cap
assert "run the required commands consecutively" in body, "consecutive-drive contract missing"
assert "until a recorded final point" in body, "final-point terminal missing"
assert "re-decides between steps" in body, "per-step re-sense rule missing"
assert "never precomputes a chain" in body, "no-precomputed-chain polarity missing"
assert "at-most-once growth burst" in body, "growth bound missing"
assert "never self-terminates" in body, "growth-bound rationale missing"
assert "stops at the first convergence" in body, "safe-mode terminal missing"
assert "in `safe` mode or with the growth step already taken" in body, "converged terminal check not anchored at the step site"
assert "the post-growth terminal" in body, "bare terminal not re-anchored on the post-growth (qb) step"
# growth is ENFORCED whenever `safe` is off: at a converged terminal codmaster takes one invent
# burst REGARDLESS of the engine's invent_class — the engine's invent-dry routing is advisory and
# is relayed only under `safe`. Only `safe` withholds the burst.
assert "regardless of the engine's `invent_class`" in body, "growth burst not enforced when safe is off"
assert "consent to grow" in body, "non-safe enforce-growth consent rule missing"
assert "invent-dry routing" in body, "converged invent-dry routing (relayed under safe) missing from the terminal check"
assert "advisory only" in body, "engine invent-dry routing not marked advisory in the enforce path"
# loop mode: the converged terminal CONTINUES via a user-consented cold-start reset, laps
# re-arm growth and the step counter, rejected.md survives across laps, and only an
# interruption or a hard stop ends the infinite drive
assert "converged terminal continues instead of stopping" in body, "loop continuation missing"
assert "consent for repeated cold starts" in body, "loop reset-consent rationale missing"
assert "rejected work stays suppressed across laps" in body, "cross-lap rejected.md retention missing"
assert "re-arm the growth burst" in body, "per-lap growth re-arm missing"
assert "restart the step counter" in body, "per-lap step-counter restart missing"
assert "ends only on interruption or a hard stop" in body, "infinite-drive stop set missing"
# loop termination is decided at the lap boundary (after the post-growth codshard), never at an
# intermediate step: a hard failure stops immediately, but the soft no-progress guard is deferred
# and only a whole-lap fully-dry result is the final convergence point that ends the infinite drive
assert "termination decision is taken here, at the lap boundary" in body, "loop termination not deferred to the lap boundary"
assert "does not stop the lap mid-flight" in body, "loop no-progress mid-lap deferral missing"
assert "fully-dry lap" in body, "loop final-convergence (fully-dry lap) criterion missing"
# post-growth sharded harden: the master's one command-shaping rule — in ANY lap (a bare run is
# itself one lap, not only loop), once growth is taken, a codvisor harden on a shardable repo
# becomes `codshard explore` (an explained divergence), gated on the engine's repo.shardable fact;
# before growth / non-codvisor it relays unchanged, and a non-shardable repo keeps codvisor
assert "Post-growth sharded harden" in body, "post-growth codshard rule missing"
assert "not only under `loop`" in body, "post-growth shard must fire in every lap (bare or loop), not only loop"
assert "repo.shardable" in body, "post-growth codshard shardability gate missing"
assert "dispatch `codshard explore` **instead**" in body, "post-growth codshard override (codvisor->codshard) missing"
assert "the harden stays `codvisor`" in body, "post-growth codshard not-shardable fallback missing"
assert "explained divergence" in body, "post-growth codshard divergence disclosure missing"
assert "=== codmaster lap L ===" in body, "lap header missing"
assert "=== codmaster step i/12:" in body, "per-step header missing"
assert "never exceeding 12 steps" in body, "12-step safety cap missing"
assert "HEAD unchanged" in body, "no-progress HEAD predicate missing"
assert "identical recommendation" in body, "no-progress recommendation predicate missing"
assert "no progress" in body, "no-progress stop reason missing"
assert "step cap" in body, "step-cap stop reason missing"
# qb intent-replan — codmaster's top escalation rung (above codinventor): fires only at a
# post-growth converged terminal (growth already taken this lap), at-most-once per lap, behind an
# availability guard (skipped when qb is not installed); runs `/qb-plan auto`, parses the deterministic QB_PLAN_AUTO_* line,
# merges its pending items (deduped vs completed/rejected, re-validated by planwright's OWN
# validator) and executes them. `safe` can never reach qb (gated on "codinventor already ran"), and
# qb's dryness — not codinventor's — now defines the loop's final convergence point.
assert "qb intent-replan" in body, "qb closing-step (top escalation rung) missing"
assert "closing escalation rung" in body, "qb closing-rung framing missing"
assert "top rung of the escalation ladder" in body, "qb escalation-ladder position missing"
assert "Availability guard" in body, "qb availability guard missing"
assert "/qb-plan auto" in body, "qb auto-mode invocation missing"
assert "QB_PLAN_AUTO_OK" in body, "qb success result-line parse missing"
assert "QB_PLAN_AUTO_ERROR" in body, "qb error result-line parse missing"
assert "Confirm qb is installed" in body, "qb availability (presence) check missing"
assert "skip qb" in body, "qb-absent skip path missing"
assert "rejected intent items stay suppressed across laps" in body, "qb dedup-vs-rejected (cross-lap suppression) missing"
assert "not qb's vendored copy" in body, "qb merge re-validation by planwright's own validator missing"
assert "zero net-new items after dedup" in body, "qb zero-net-new dry criterion missing"
assert "qb dry" in body, "qb-dry fall-through label missing"
assert "the gate enforces the `safe` rule for free" in body, "qb safe-gate (codinventor-already-ran) free-enforcement missing"
assert "qb run and its follow-on" in body, "qb step-accounting (counts against the 12-step cap) missing"
# qb at-most-once-per-lap must be ENFORCED, not merely asserted: an explicit per-lap flag (mirroring
# the growth burst's flag) + a gate conjunct that bars a post-execute re-convergence re-running qb.
assert "qb-replan taken this lap" in body, "qb at-most-once flag (mirroring the growth flag) missing — re-run on the OK->execute->re-converge path"
assert "qb intent-replan was not yet taken this lap" in body, "qb at-most-once gate conjunct missing (gate must be codinventor-ran AND qb-not-yet-taken)"
assert "run /qb-plan auto, then merge .qb/plan.md pending items into .planwright/plan.md and execute" in body, "safe qb hand-off paste line missing"
# safe prints a DEDICATED banner (not a fragile strike-edit of the growth/loop banner), so the
# safe-loop banner carries a harden-only termination model with NO qb-dependent termination clause
# that would contradict "qb intent-replan does not run".
assert "print a dedicated safe banner" in body, "safe dedicated-banner structure missing (regressed to strike-editing the growth banner)"
assert "each lap runs harden-only (no growth, no qb)" in body, "safe-loop harden-only termination model missing/contradicts the qb-does-not-run notice"
assert "run the qb closing step here first" in body, "bare terminal qb-before-STOP wiring missing"
assert "qb replan's execute included" in body, "loop fully-dry criterion not extended to include qb's execute"
assert "qb's dryness, not codinventor's" in body, "loop final-point redefinition (qb dryness defines done) missing"
assert "qb's merged-and-executed seeds" in body, "loop relap-on-qb-net-new path missing"
# report honesty
assert "verbatim" in body, "stop-relay verbatim rule missing"
assert "suppress any next-step suggestion" in body, "broken-stop suggestion suppression missing"
# the closed stop set: codmaster owns NO discretionary stop — it never ends/pauses/aborts the drive
# on its own judgment (cost, "marginal value", a "judgment checkpoint", an "already-mature tree", or
# leads that stopped reproducing are NOT stop reasons). A dispatched sub-run (esp. codshard) runs to
# completion; an interruption counts only when it arrives from OUTSIDE (never self-declared); and at
# least one full lap must complete before codmaster stops of its own accord. (Regression: a real loop
# run paused mid-codshard at "Shard 2/3" citing a self-declared "judgment checkpoint" / "marginal value".)
assert "No discretionary stop — the stop set is closed." in body, "closed-stop-set rule missing"
assert "\"I judged it not worth continuing\" is a forbidden one" in body, "discretionary-stop prohibition missing"
assert "A dispatched sub-run runs to its own completion or its own hard stop." in body, "dispatched-sub-run-to-completion rule missing (codshard must finish all shards + closing round)"
assert "never because the orchestrator decided from the outside" in body, "outside-the-run sub-run abort guard missing"
assert "At least one full lap must complete" in body, "one-full-lap floor missing (must not stop before a lap closes)"
assert "re-survey, do not quit" in body, "maturity-is-a-reason-to-finish rule missing"
assert "interruption counts only when it arrives from outside the drive" in body, "external-only interruption rule missing (closes the self-declared-interruption escape hatch)"
assert "codmaster never *declares* an interruption on its own" in body, "self-attributed interruption prohibition missing"
assert "never by treating a lap boundary as an interruption point" in body, "lap-boundary-is-not-an-interruption-point guard missing (closes the boundary seam: a model could relabel a self-chosen boundary stop an 'anticipated interruption')"
assert "Print nothing of your own" in body, "print-nothing-else rule missing"
PY
then ok "commands/codmaster.md relays the tested coach table and owns its lap orchestration (engine-delegation, safe word, post-growth sharded harden in every lap, qb intent-replan closing rung, verbatim relay, no prose table)"; else bad "commands/codmaster.md malformed or lost its coach-table-delegation/safe/post-growth-codshard/qb-closing-rung/disclosure contract"; fi

# --- Test 17b: codmaster wires the lap-close reconcile-sweep (completion-accounting net) ---
# A step that commits a fix inline without landing it (codshard/codinventor/execute) would silently
# miss completed.md, the only file the dashboard reads. codmaster must capture a lap-start ref (and
# re-record it on relap) and run lifecycle.py reconcile-sweep --since <ref> at every lap close — as
# best-effort bookkeeping, explicitly NOT a stop or a judgment (the stop set is closed; a new stop
# would violate the no-discretionary-stop rule).
CMD="$ROOT/commands/codmaster.md"
if python3 - "$CMD" <<'PY' 2>/dev/null
import sys
t = open(sys.argv[1], encoding="utf-8").read()
need = []
if "lap-start ref" not in t: need.append("lap-start-ref-capture")
if "re-record the lap-start ref" not in t: need.append("relap-ref-rerecord")
if "lifecycle.py reconcile-sweep --since" not in t: need.append("reconcile-sweep-call")
if "completion-accounting" not in t: need.append("invariant-framing")
# framed as bookkeeping, never a stop — the closed stop-set rule forbids a new stop reason
if "not a stop or a judgment" not in t: need.append("not-a-stop-framing")
if "${CLAUDE_PLUGIN_ROOT}/scripts" not in t: need.append("scripts-resolution")
sys.exit(1 if need else 0)
PY
then ok "commands/codmaster.md wires a lap-close reconcile-sweep as best-effort bookkeeping (not a stop), capturing and re-recording the lap-start ref"; else bad "commands/codmaster.md lost the lap-close reconcile-sweep wiring (lap-start ref / relap re-record / --since / not-a-stop framing)"; fi

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

# --- Test 18: the run-activity beacon wiring (orchestrators stamp, skill flows guard) ---
# The dashboard reactor's "which command is running" line reads .planwright/activity.json,
# stamped via `state.py activity`. The nesting rule keeps it truthful: the three
# orchestrators (codmaster/codshard/codcycle) stamp their own names unconditionally at
# start, re-stamp --detail at their step/shard/cycle headers, and stop at the end; the
# skill's inner plan/execute/cycle flows stamp only `--if-absent` (never clobbering the
# orchestrator that dispatched them) and stop only the beacon they own (`stop <name>`).
# Every call site must stay best-effort ("never block") — the beacon is telemetry, not a
# gate. dashboard.md stays read-only and must never stamp.
if python3 - "$ROOT" <<'PY' 2>/dev/null
import os, re, sys
root = sys.argv[1]
def body(rel):
    t = open(os.path.join(root, rel), encoding="utf-8").read()
    m = re.match(r"^---\n(.*?)\n---\n", t, re.S)
    return t[m.end():] if m else t
def flat(s):
    return " ".join(s.split())
for name in ("codmaster", "codshard", "codcycle"):
    b = flat(body("commands/%s.md" % name))
    assert "state.py activity start %s" % name in b, "%s: no unconditional start stamp" % name
    assert "--if-absent" not in b.split("state.py activity start %s" % name)[1][:40], \
        "%s: the orchestrator stamp must be unconditional" % name
    assert 'activity start %s --detail' % name in b, "%s: no --detail re-stamp at step headers" % name
    assert "state.py activity stop --root ." in b, "%s: no beacon removal at the end" % name
    assert "never block" in b, "%s: beacon not marked best-effort/never-block" % name
skill = flat(open(os.path.join(root, "skills/planwright/SKILL.md"), encoding="utf-8").read())
for flow in ("plan", "execute", "cycle"):
    assert "activity start %s --if-absent" % flow in skill, \
        "SKILL.md %s flow: start must be --if-absent (inner flows never clobber)" % flow
    assert "activity stop %s" % flow in skill, \
        "SKILL.md %s flow: stop must be owner-guarded (stop %s)" % (flow, flow)
assert "never block" in skill, "SKILL.md: beacon not marked best-effort"
dash = flat(body("commands/dashboard.md"))
assert "activity start" not in dash, "dashboard.md must stay read-only (no beacon stamp)"
PY
then ok "run-activity beacon wiring: orchestrators stamp/re-stamp/stop, skill flows use --if-absent and owner-guarded stop, dashboard.md never stamps"; else bad "run-activity beacon wiring drifted (unconditional orchestrator stamp, --if-absent inner stamp, owner-guarded stop, or never-block clause missing)"; fi


# --- Test 19: the dashboard view enumerations track index.html's tab order ----------
# commands/dashboard.md sat stale at "seven views" while the Shards tab shipped (and
# references/dashboard.md likewise) because nothing pinned the prose enumerations to
# the UI shell. Derive the canonical view list from index.html's data-view ids — the
# same attribute the app routes on — and require every prose surface to carry it:
# commands/dashboard.md the exact " / "-joined list in tab order, the skill reference
# and docs/usage.md every bolded view name plus the number-word count phrase.
if python3 - "$ROOT" <<'PY' 2>/dev/null
import os, re, sys
root = sys.argv[1]
html = open(os.path.join(root, "scripts/dashboard/index.html"), encoding="utf-8").read()
views = re.findall(r'data-view="([a-z]+)"', html)
assert len(views) >= 8 and len(views) == len(set(views)), "index.html tab list malformed"
titled = [v.capitalize() for v in views]
words = {5: "five", 6: "six", 7: "seven", 8: "eight", 9: "nine",
         10: "ten", 11: "eleven", 12: "twelve"}
assert len(views) in words, "tab count %d outside the number-word map — extend Test 19" % len(views)
phrase = "%s views" % words[len(views)]
cmd = open(os.path.join(root, "commands/dashboard.md"), encoding="utf-8").read()
assert " / ".join(titled) in cmd, "commands/dashboard.md view list != index.html tab order"
assert phrase in cmd, "commands/dashboard.md lost the '%s' count phrase" % phrase
for rel in ("skills/planwright/references/dashboard.md", "docs/usage.md"):
    t = open(os.path.join(root, rel), encoding="utf-8").read()
    for name in titled:
        assert "**%s**" % name in t, "%s does not name the %s view" % (rel, name)
    assert phrase in t, "%s lost the '%s' count phrase" % (rel, phrase)
for rel in ("commands/dashboard.md", "skills/planwright/references/dashboard.md", "docs/usage.md"):
    t = open(os.path.join(root, rel), encoding="utf-8").read()
    assert "seven views" not in t, "%s regressed to the stale 'seven views' claim" % rel
PY
then ok "dashboard view enumerations track index.html's tab order (commands/dashboard.md exact list; reference + usage carry every view and the count)"; else bad "a dashboard view enumeration drifted from index.html's data-view tabs"; fi
