# SPDX-FileCopyrightText: 2026 Eser KUBALI
# SPDX-License-Identifier: GPL-3.0-or-later
# shellcheck shell=bash
#
# SKILL.md <-> graph.json field contract. Sourced by tests/run.sh after tests/lib.sh —
# NOT standalone (uses ROOT/TMP/ok/bad).
#
# SKILL.md documents graph.json field names (the `dirty` block in Stage 1.5, plus the
# top-level and per-node fields Stages 1.5/2b/11 route on). Nothing else verified that
# those names still match what build-graph.py actually emits, so a SKILL.md reference to
# a field the builder no longer produces would drift silently. These checks build a real
# graph from a fixture and assert every field SKILL.md names is present in the output.

# Build a tiny git fixture and emit a real graph.json from it.
SGC="$TMP/skill-graph-contract"
mkdir -p "$SGC/pkg"
(
  cd "$SGC" || exit
  git init -q
  git config user.email t@example.com
  git config user.name t
  printf 'import pkg.b\n\n\ndef a():\n    if a:\n        return 1\n    return 0\n' > pkg/a.py
  printf 'def b():\n    try:\n        return 2\n    except Exception:\n        pass\n' > pkg/b.py
  git add -A
  git commit -qm init
) >/dev/null 2>&1
( cd "$SGC" && python3 "$ROOT/scripts/build-graph.py" ) > "$SGC/graph.json" 2>/dev/null

# --- Test SGC1: every `dirty`-block field SKILL.md names is emitted -----------------
if python3 - "$ROOT/skills/planwright/SKILL.md" "$SGC/graph.json" 2>"$SGC/sgc1.err" <<'PY'
import json, re, sys
skill = open(sys.argv[1]).read()
graph = json.load(open(sys.argv[2]))
m = re.search(r"emitted `graph\.json` `dirty` block\*\* \((.*?)\)", skill, re.S)
assert m, "the `dirty` block field list was not found in SKILL.md (Stage 1.5)"
documented = set(re.findall(r"`([a-z_]+)`", m.group(1)))
assert documented, "no `dirty` fields parsed from SKILL.md's documented list"
emitted = set(graph.get("dirty", {}).keys())
missing = sorted(documented - emitted)
assert not missing, "SKILL.md names dirty field(s) build-graph.py does not emit: %s" % missing
PY
then ok "SKILL.md \`dirty\`-block fields all emitted by build-graph.py"
else bad "SKILL.md <-> graph.json dirty-block contract drifted: $(cat "$SGC/sgc1.err")"; fi

# --- Test SGC2: documented top-level + per-node fields are emitted ------------------
if python3 - "$ROOT/skills/planwright/SKILL.md" "$SGC/graph.json" 2>"$SGC/sgc2.err" <<'PY'
import json, sys
skill = open(sys.argv[1]).read()
graph = json.load(open(sys.argv[2]))
# Field names SKILL.md presents as graph.json fields (Stages 1.5 / 2b / 11, Escalation
# ladder). Each must be (a) still documented in SKILL.md and (b) actually emitted — so a
# rename in either place fails this gate instead of drifting silently.
top = ["version", "nodes", "clusters", "coupling_edges", "import_cycles", "ranked",
       "ranked_code", "ranked_cold", "frontier", "graph_built_at_sha", "dirty"]
node = ["last_audited_sha", "is_articulation", "covered_by_test", "branch_count",
        "branch_at", "swallow_at", "defines_at", "audit_age_commits"]
assert graph.get("nodes"), "fixture graph emitted no nodes"
sample = next(iter(graph["nodes"].values()))
for f in top:
    assert ("`%s`" % f) in skill, "top-level field `%s` is no longer documented in SKILL.md" % f
    assert f in graph, "SKILL.md documents top-level `%s` but build-graph.py does not emit it" % f
for f in node:
    assert ("`%s`" % f) in skill, "node field `%s` is no longer documented in SKILL.md" % f
    assert f in sample, "SKILL.md documents node field `%s` but build-graph.py does not emit it" % f
PY
then ok "SKILL.md-documented top-level + per-node graph.json fields all emitted"
else bad "SKILL.md <-> graph.json field contract drifted: $(cat "$SGC/sgc2.err")"; fi
