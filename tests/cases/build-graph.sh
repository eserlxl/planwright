# SPDX-FileCopyrightText: 2026 Eser KUBALI
# SPDX-License-Identifier: GPL-3.0-or-later
#
# build-graph.py (Stage 1.5 code graph) behavior.
# Sourced by tests/run.sh after tests/lib.sh — NOT standalone (uses ROOT/TMP/ok/bad/ver).

# --- Test 11: scripts/build-graph.py builds a schema-conforming graph -------
gj_file="$TMP/build_graph_out.json"
python3 "$ROOT/scripts/build-graph.py" --root "$ROOT" > "$gj_file" 2>/dev/null
if python3 - "$gj_file" <<'PY' 2>/dev/null
import json, re, sys
g = json.load(open(sys.argv[1]))
assert g["version"] == 1
assert re.fullmatch(r"[0-9a-f]{40}", g["graph_built_at_sha"])
assert g["ranking_signal"] in ("centrality", "coupling")
assert {"coupling_window_commits", "coupling_min_cooccurrence", "ranked_surface_limit"} <= set(g["params"])
assert g["nodes"], "no nodes"
need = {"sha256", "loc", "branch_count", "branch_at", "lang", "git_churn", "defines", "defines_at", "imports", "is_test", "covered_by_test", "pagerank", "is_articulation", "last_audited_sha"}
for f, n in g["nodes"].items():
    assert need <= set(n), f
    assert isinstance(n["is_test"], bool) and isinstance(n["covered_by_test"], bool), f
    assert isinstance(n["defines_at"], dict), f
    assert all(isinstance(v, int) and v >= 1 for v in n["defines_at"].values()), f
    assert isinstance(n["branch_count"], int) and n["branch_count"] >= 0, f
    assert isinstance(n["branch_at"], dict), f
    assert all(isinstance(v, int) and v >= 0 for v in n["branch_at"].values()), f
    # branch_at keys are a subset of the file's defined symbols
    assert set(n["branch_at"]) <= set(n["defines"]), f
assert isinstance(g["ranked"], list) and all(x in g["nodes"] for x in g["ranked"])
# ranked_code: a list of branch_count>0 nodes only, in the same priority order as ranked
assert isinstance(g["ranked_code"], list)
assert all(x in g["nodes"] and g["nodes"][x]["branch_count"] > 0 for x in g["ranked_code"]), g["ranked_code"]
# code nodes keep their relative ranked order in ranked_code
code_in_ranked = [x for x in g["ranked"] if g["nodes"][x]["branch_count"] > 0]
assert g["ranked_code"][:len(code_in_ranked)] == code_in_ranked, (g["ranked_code"], code_in_ranked)
# ranked_cold: the explore frontier — also branch_count>0 code nodes only
assert isinstance(g["ranked_cold"], list)
assert all(x in g["nodes"] and g["nodes"][x]["branch_count"] > 0 for x in g["ranked_cold"]), g["ranked_cold"]
# import_cycles: a list of >=2-member groups of real nodes (directed SCCs)
assert isinstance(g["import_cycles"], list)
for cyc in g["import_cycles"]:
    assert isinstance(cyc, list) and len(cyc) >= 2 and all(x in g["nodes"] for x in cyc), cyc
for c in g["clusters"]:
    assert isinstance(c["id"], int) and isinstance(c["members"], list)
for e in g["coupling_edges"]:
    assert {"a", "b", "cooccur", "weight"} <= set(e)
d = g["dirty"]
assert {"is_first_run", "whole_graph", "reason", "changed", "nodes", "clusters"} <= set(d), d
# no prior was passed, so this is a first run: every node is dirty, all clusters touched
assert d["is_first_run"] is True and d["whole_graph"] is True and d["reason"] == "first-run", d
assert set(d["nodes"]) == set(g["nodes"]) and d["changed"] == [], d
assert set(d["clusters"]) == {c["id"] for c in g["clusters"]}, d
PY
then ok "build-graph.py output conforms to graph-memory schema"; else bad "build-graph.py output missing or non-conforming"; fi

# --- Test 11b: build-graph.py --prior preserves last_audited_sha -----------
# Stage 11's incremental-audit skipping depends on last_audited_sha surviving
# rebuilds; without --prior preservation every run re-audits the whole tree.
prior_file="$TMP/prior_graph.json"
python3 - "$gj_file" "$prior_file" <<'PY' 2>/dev/null
import json, sys
g = json.load(open(sys.argv[1]))
for n in g["nodes"].values():
    n["last_audited_sha"] = g["graph_built_at_sha"]
json.dump(g, open(sys.argv[2], "w"))
PY
new_graph="$TMP/new_graph.json"
python3 "$ROOT/scripts/build-graph.py" --root "$ROOT" --prior "$prior_file" > "$new_graph" 2>/dev/null
if python3 - "$prior_file" "$new_graph" <<'PY' 2>/dev/null
import json, sys
prior = json.load(open(sys.argv[1]))
new = json.load(open(sys.argv[2]))
sha = prior["graph_built_at_sha"]
carried = [f for f in new["nodes"] if f in prior["nodes"]]
assert carried, "no carried-over nodes"
assert all(new["nodes"][f]["last_audited_sha"] == sha for f in carried), "last_audited_sha not preserved"
PY
then ok "build-graph.py --prior preserves last_audited_sha across a rebuild"; else bad "build-graph.py --prior dropped last_audited_sha"; fi

# --- Test 11c: build-graph.py coupling fallback ranks a degenerate graph ----
# A repo whose files do not import each other (n_import_edges below threshold)
# must fall back from PageRank to change-coupling ranking. This path never runs
# on planwright's own tree (it ranks by centrality), so exercise it explicitly.
COUPREPO="$TMP/couprepo"
mkdir -p "$COUPREPO"
git -C "$COUPREPO" init -q
for f in alpha beta gamma delta; do echo "# $f" > "$COUPREPO/$f.md"; done
git -C "$COUPREPO" add -A
git -C "$COUPREPO" -c user.name=t -c user.email=t@e.com commit -qm init
# Co-commit alpha+beta three more times so their pair clears coupling_min_cooccurrence (3).
for i in 1 2 3; do
  echo "edit $i" >> "$COUPREPO/alpha.md"
  echo "edit $i" >> "$COUPREPO/beta.md"
  git -C "$COUPREPO" add -A
  git -C "$COUPREPO" -c user.name=t -c user.email=t@e.com commit -qm "co $i"
done
coup_out="$TMP/coup_graph.json"
python3 "$ROOT/scripts/build-graph.py" --root "$COUPREPO" > "$coup_out" 2>/dev/null
if python3 - "$coup_out" <<'PY' 2>/dev/null
import json, sys
g = json.load(open(sys.argv[1]))
assert g["ranking_signal"] == "coupling", g["ranking_signal"]
edge = [e for e in g["coupling_edges"] if {e["a"], e["b"]} == {"alpha.md", "beta.md"}]
assert edge and edge[0]["cooccur"] >= 3, "alpha/beta coupling edge missing"
assert set(g["ranked"][:2]) == {"alpha.md", "beta.md"}, g["ranked"][:2]
PY
then ok "build-graph.py coupling fallback ranks the coupled pair first"; else bad "build-graph.py coupling fallback ranking wrong"; fi

# --- Test 11c2: ranked_code excludes zero-branch nodes Stage 2b cannot read ----
# A doc/data node carries branch_count 0 and no functions; link-centrality can
# float it to the top of `ranked`, but ranked_code must hold only code nodes so
# Stage 2b's function walk is not led to a file with nothing to read.
RCREPO="$TMP/rankedcoderepo"
mkdir -p "$RCREPO"
git -C "$RCREPO" init -q
printf '#!/usr/bin/env bash\nf() { if true; then for x in a b; do echo hi; done; fi; }\n' > "$RCREPO/lib.sh"
printf '# Doc\n[lib](lib.sh) and more text linking [lib](lib.sh).\n' > "$RCREPO/doc.md"
git -C "$RCREPO" add -A
git -C "$RCREPO" -c user.name=t -c user.email=t@e.com commit -qm init
rc_out="$TMP/rc_graph.json"
python3 "$ROOT/scripts/build-graph.py" --root "$RCREPO" > "$rc_out" 2>/dev/null
if python3 - "$rc_out" <<'PY' 2>/dev/null
import json, sys
g = json.load(open(sys.argv[1]))
assert "lib.sh" in g["ranked_code"], g["ranked_code"]
assert "doc.md" not in g["ranked_code"], g["ranked_code"]
assert g["nodes"]["doc.md"]["branch_count"] == 0 and g["nodes"]["lib.sh"]["branch_count"] > 0
# every ranked_code member is a branch>0 node
assert all(g["nodes"][f]["branch_count"] > 0 for f in g["ranked_code"]), g["ranked_code"]
PY
then ok "ranked_code holds only code nodes, excluding zero-branch docs"; else bad "ranked_code leaked a zero-branch node or dropped a code node"; fi

# --- Test 11c2b: ranked_cold surfaces the explore frontier (uncovered first) ----
# ranked_cold is the inverse of ranked_code for the opt-in `explore` escalation: it
# leads with the code the default hot-core routing neglects. On a fresh build both
# code nodes are never-audited (a tie on the primary key), so the covered_by_test
# key decides — the uncovered orphan must rank ahead of the test-covered core.
CLDREPO="$TMP/coldrepo"
mkdir -p "$CLDREPO"
git -C "$CLDREPO" init -q
printf '#!/usr/bin/env bash\ncore() { if true; then echo hi; fi; }\n' > "$CLDREPO/core.sh"
printf '#!/usr/bin/env bash\norphan() { if true; then echo bye; fi; }\n' > "$CLDREPO/orphan.sh"
printf '#!/usr/bin/env bash\nsource core.sh\ncore_test() { core; }\n' > "$CLDREPO/core_test.sh"
git -C "$CLDREPO" add -A
git -C "$CLDREPO" -c user.name=t -c user.email=t@e.com commit -qm init
cld_out="$TMP/cold_graph.json"
python3 "$ROOT/scripts/build-graph.py" --root "$CLDREPO" > "$cld_out" 2>/dev/null
if python3 - "$cld_out" <<'PY' 2>/dev/null
import json, sys
g = json.load(open(sys.argv[1]))
rc = g["ranked_cold"]
# a test sources core.sh => core.sh is covered; orphan.sh is reached by nothing
assert g["nodes"]["core.sh"]["covered_by_test"] is True, g["nodes"]["core.sh"]
assert g["nodes"]["orphan.sh"]["covered_by_test"] is False, g["nodes"]["orphan.sh"]
# both are branch>0 code nodes on the frontier list; the no-branch test file is not
assert "orphan.sh" in rc and "core.sh" in rc, rc
assert "core_test.sh" not in rc, rc
# the uncovered orphan leads the covered core on the cold frontier (the inversion)
assert rc.index("orphan.sh") < rc.index("core.sh"), rc
PY
then ok "ranked_cold leads the explore frontier with uncovered code (inverse of ranked_code)"; else bad "ranked_cold did not surface the uncovered frontier node first"; fi

# --- Test 11c2c: ranked_cold's never-audited primary key outranks the covered key
# cold_key's FIRST element is `last_audited_sha is None` (never-audited first). Test
# 11c2b ties on it (fresh repo => both null), so isolate it here: two uncovered code
# files, one stamped audited via a prior graph and one never-audited. The never-audited
# file must lead even though both are uncovered, so only the primary key can decide.
NAREPO="$TMP/narepo"
mkdir -p "$NAREPO"
git -C "$NAREPO" init -q
printf '#!/usr/bin/env bash\na() { if true; then echo a; fi; }\n' > "$NAREPO/a.sh"
printf '#!/usr/bin/env bash\nb() { if true; then echo b; fi; }\n' > "$NAREPO/b.sh"
git -C "$NAREPO" add -A
git -C "$NAREPO" -c user.name=t -c user.email=t@e.com commit -qm init
na_prior="$TMP/na_prior.json"
python3 "$ROOT/scripts/build-graph.py" --root "$NAREPO" > "$na_prior" 2>/dev/null
# mark a.sh as already audited; b.sh stays never-audited (last_audited_sha null)
python3 - "$na_prior" <<'PY'
import json, sys
p = sys.argv[1]; g = json.load(open(p))
g["nodes"]["a.sh"]["last_audited_sha"] = g["graph_built_at_sha"]
json.dump(g, open(p, "w"))
PY
na_new="$TMP/na_new.json"
python3 "$ROOT/scripts/build-graph.py" --root "$NAREPO" --prior "$na_prior" > "$na_new" 2>/dev/null
if python3 - "$na_new" <<'PY' 2>/dev/null
import json, sys
g = json.load(open(sys.argv[1])); n = g["nodes"]; rc = g["ranked_cold"]
# the prior stamp survived for a.sh; b.sh remains never-audited
assert n["a.sh"]["last_audited_sha"] is not None, n["a.sh"]
assert n["b.sh"]["last_audited_sha"] is None, n["b.sh"]
# both uncovered => the covered_by_test secondary key ties, so it cannot decide order
assert n["a.sh"]["covered_by_test"] is False and n["b.sh"]["covered_by_test"] is False
# never-audited b.sh must lead audited a.sh on the cold frontier (primary key decides)
assert "a.sh" in rc and "b.sh" in rc, rc
assert rc.index("b.sh") < rc.index("a.sh"), rc
PY
then ok "ranked_cold's never-audited primary key outranks an audited node (covered key tied)"; else bad "ranked_cold ignored the never-audited primary key"; fi

# --- Test 11c2d: --scope emits focus + context (Focus + 1-hop blast radius) ----
# Component scoping (docs/scope-design.md): --scope picks a Focus set; Context is
# Focus + its 1-hop import/coupling blast radius, so an upstream dependency of a
# scoped file is pulled into Context (root cause stays visible) without entering
# Focus (where items land). Fixture: api -> auth -> crypto; scope to src/.
SCREPO="$TMP/scoperepo"
mkdir -p "$SCREPO/src" "$SCREPO/lib"
git -C "$SCREPO" init -q
printf '#!/usr/bin/env bash\nsource ../lib/crypto.sh\nauth() { if true; then echo a; fi; }\n' > "$SCREPO/src/auth.sh"
printf '#!/usr/bin/env bash\nsource auth.sh\napi() { if true; then echo p; fi; }\n' > "$SCREPO/src/api.sh"
printf '#!/usr/bin/env bash\ncrypto() { if true; then echo c; fi; }\n' > "$SCREPO/lib/crypto.sh"
git -C "$SCREPO" add -A
git -C "$SCREPO" -c user.name=t -c user.email=t@e.com commit -qm init
sc_out="$TMP/scope_graph.json"
python3 "$ROOT/scripts/build-graph.py" --root "$SCREPO" --scope src/ > "$sc_out" 2>/dev/null
if python3 - "$sc_out" <<'PY' 2>/dev/null
import json, sys
g = json.load(open(sys.argv[1]))
focus, context = g["focus"], g["context"]
# Focus = exactly the scoped subtree
assert focus == ["src/api.sh", "src/auth.sh"], focus
# Context = Focus + 1-hop blast radius => pulls in the upstream lib/crypto.sh
assert "lib/crypto.sh" in context, context
# the upstream dep is Context-only, never Focus (items don't land there)
assert "lib/crypto.sh" not in focus, focus
# Focus is always a subset of Context
assert set(focus) <= set(context), (focus, context)
PY
then ok "--scope emits Focus + Context (Context pulls in the 1-hop upstream dep)"; else bad "--scope focus/context blast radius wrong"; fi

# --- Test 11c2e: --scope invariants (no-match empty; keys absent without --scope)
# A no-match pathspec yields an empty Focus (SKILL.md Stage 1 turns that into the
# user-facing error); and a default whole-repo build omits both keys entirely, so
# scoping never perturbs an unscoped graph.
sc_none="$TMP/scope_none.json"; sc_un="$TMP/scope_un.json"
python3 "$ROOT/scripts/build-graph.py" --root "$SCREPO" --scope does/not/exist > "$sc_none" 2>/dev/null
python3 "$ROOT/scripts/build-graph.py" --root "$SCREPO" > "$sc_un" 2>/dev/null
if python3 - "$sc_none" "$sc_un" <<'PY' 2>/dev/null
import json, sys
none = json.load(open(sys.argv[1]))
un = json.load(open(sys.argv[2]))
# no-match => empty Focus and Context (a real no-match, not a whole-repo fallback)
assert none["focus"] == [] and none["context"] == [], (none["focus"], none["context"])
# without --scope the keys are absent entirely (byte-for-byte unchanged contract)
assert "focus" not in un and "context" not in un, list(un.keys())
PY
then ok "--scope no-match is empty Focus; unscoped build omits focus/context"; else bad "--scope invariants violated"; fi

# --- Test 11c2f: --seed emits a reproducible-yet-varied ranked_explore + framing -
# Invent exploration (docs/invent-exploration-design.md): lever 1 is a seeded ordering
# of the branch>0 code nodes; lever 2 is a seeded explore_framing (a vantage key from
# the fixed catalog). The same seed reproduces both (replayable); a different seed
# reorders the SAME members and picks a (here different) framing; without --seed all
# three keys are absent (a default build is byte-for-byte unchanged).
SDREPO="$TMP/seedrepo"
mkdir -p "$SDREPO"
git -C "$SDREPO" init -q
for nm in alpha bravo charlie delta echo_; do
  printf '#!/usr/bin/env bash\n%s() { if true; then echo %s; fi; }\n' "$nm" "$nm" > "$SDREPO/$nm.sh"
done
git -C "$SDREPO" add -A
git -C "$SDREPO" -c user.name=t -c user.email=t@e.com commit -qm init
sd_a="$TMP/seed_a.json"; sd_b="$TMP/seed_b.json"; sd_c="$TMP/seed_c.json"; sd_none="$TMP/seed_none.json"
python3 "$ROOT/scripts/build-graph.py" --root "$SDREPO" --seed 1337 > "$sd_a" 2>/dev/null
python3 "$ROOT/scripts/build-graph.py" --root "$SDREPO" --seed 1337 > "$sd_b" 2>/dev/null
python3 "$ROOT/scripts/build-graph.py" --root "$SDREPO" --seed 42 > "$sd_c" 2>/dev/null
python3 "$ROOT/scripts/build-graph.py" --root "$SDREPO" > "$sd_none" 2>/dev/null
if python3 - "$sd_a" "$sd_b" "$sd_c" "$sd_none" <<'PY' 2>/dev/null
import json, sys
a, b, c, none = (json.load(open(p)) for p in sys.argv[1:5])
# the seed is recorded, and ranked_explore holds exactly the branch>0 code nodes
assert a["explore_seed"] == 1337, a.get("explore_seed")
assert all(a["nodes"][f]["branch_count"] > 0 for f in a["ranked_explore"]), a["ranked_explore"]
assert sorted(a["ranked_explore"]) == sorted(f for f in a["nodes"] if a["nodes"][f]["branch_count"] > 0)
# same seed => identical order (reproducible); different seed => reordered, same members
assert a["ranked_explore"] == b["ranked_explore"], "same seed not reproducible"
assert a["ranked_explore"] != c["ranked_explore"], "different seed did not reorder"
assert sorted(a["ranked_explore"]) == sorted(c["ranked_explore"]), "seed changed membership, not just order"
# lever 2: explore_framing is a catalog key, deterministic per seed, varies across seeds
CATALOG = {"power-user", "integration", "onboarding", "reliability", "automation"}
assert a["explore_framing"] in CATALOG, a.get("explore_framing")
assert a["explore_framing"] == b["explore_framing"], "same seed not reproducible (framing)"
assert a["explore_framing"] != c["explore_framing"], "different seed did not change framing"
# absent without --seed (byte-for-byte-unchanged contract)
assert "explore_seed" not in none and "ranked_explore" not in none, list(none.keys())
assert "explore_framing" not in none, list(none.keys())
PY
then ok "--seed emits a reproducible ranked_explore + framing that a different seed varies (same members)"; else bad "--seed ordering/framing not reproducible/varied or leaked without --seed"; fi

# --- Test 11c3: is_test classification + covered_by_test coverage routing -----
# A test file that imports a source marks it covered_by_test; an unimported
# non-test source stays false. Routing-only: a false is a candidate, not proof.
COVREPO="$TMP/covrepo"
mkdir -p "$COVREPO"
git -C "$COVREPO" init -q
printf 'def helper(x):\n    return x + 1\n' > "$COVREPO/lib.py"
printf 'import lib\n\ndef test_helper():\n    assert lib.helper(1) == 2\n' > "$COVREPO/test_lib.py"
printf 'def orphan():\n    return 0\n' > "$COVREPO/orphan.py"
git -C "$COVREPO" add -A
git -C "$COVREPO" -c user.name=t -c user.email=t@e.com commit -qm init
cov_out="$TMP/cov_graph.json"
python3 "$ROOT/scripts/build-graph.py" --root "$COVREPO" > "$cov_out" 2>/dev/null
if python3 - "$cov_out" <<'PY' 2>/dev/null
import json, sys
n = json.load(open(sys.argv[1]))["nodes"]
assert n["test_lib.py"]["is_test"] is True, n["test_lib.py"]
assert n["lib.py"]["is_test"] is False and n["orphan.py"]["is_test"] is False
assert n["lib.py"]["covered_by_test"] is True, "a test imports lib.py -> covered"
assert n["orphan.py"]["covered_by_test"] is False, "no test reaches orphan.py"
PY
then ok "is_test + covered_by_test route the coverage rung (import-reached source is covered)"; else bad "covered_by_test routing wrong (classification or reach)"; fi

# is_test_node classifies conventional layouts/names without mislabeling sources.
if python3 -B - "$ROOT/scripts/build-graph.py" <<'PY' 2>/dev/null
import importlib.util, sys
spec = importlib.util.spec_from_file_location("bg", sys.argv[1])
bg = importlib.util.module_from_spec(spec); spec.loader.exec_module(bg)
for p in ("tests/run.sh", "src/foo_test.cc", "test_foo.py", "a/b.spec.ts",
          "x/widget_unittest.cc", "pkg/WidgetTest.java", "spec/thing.rb", "Test.java"):
    assert bg.is_test_node(p), p
for p in ("scripts/build-graph.py", "src/latest.js", "docs/attestation.md", "lib/contest.py"):
    assert not bg.is_test_node(p), p
PY
then ok "is_test_node classifies test paths without mislabeling sources"; else bad "is_test_node misclassified a path"; fi

# --- Test 11c4: import_cycles detects circular imports for the Stage 3 lens ----
# A directed import cycle (a imports b, b imports a) is a strongly-connected
# group the architecture lens should flag; an acyclic importer is not in any.
CYCREPO="$TMP/cycrepo"
mkdir -p "$CYCREPO"
git -C "$CYCREPO" init -q
printf 'import b\n' > "$CYCREPO/a.py"
printf 'import a\n' > "$CYCREPO/b.py"
printf 'import a\n' > "$CYCREPO/c.py"
git -C "$CYCREPO" add -A
git -C "$CYCREPO" -c user.name=t -c user.email=t@e.com commit -qm init
cyc_out="$TMP/cyc_graph.json"
python3 "$ROOT/scripts/build-graph.py" --root "$CYCREPO" > "$cyc_out" 2>/dev/null
if python3 - "$cyc_out" <<'PY' 2>/dev/null
import json, sys
g = json.load(open(sys.argv[1]))
cycles = [set(c) for c in g["import_cycles"]]
assert {"a.py", "b.py"} in cycles, g["import_cycles"]
# c.py imports a but nothing imports c -> not in any cycle
assert not any("c.py" in c for c in cycles), g["import_cycles"]
PY
then ok "import_cycles flags a circular import and excludes an acyclic importer"; else bad "import_cycles missed a cycle or over-flagged"; fi

# --- Test 11d: defines_of routes C/C++ + JS symbols (Stage 2b function hints) -
# The `defines` field feeds Stage 2b's "walk ranked, take its top functions".
# C/C++ is planwright's primary target language (constexpr/TEST_F/header rules),
# so empty C/C++ defines would blind Stage 2b on exactly that language.
if python3 -B - "$ROOT/scripts/build-graph.py" <<'PY' 2>/dev/null
import importlib.util, sys
spec = importlib.util.spec_from_file_location("bg", sys.argv[1])
bg = importlib.util.module_from_spec(spec); spec.loader.exec_module(bg)

cpp = (
    '#include "foo.h"\n'
    "class Widget {\n public:\n"
    "  int compute(int n) {\n    if (n > 0) { return n + 1; }\n    return 0;\n  }\n};\n"
    "constexpr int add(int a, int b) { return a + b; }\n"
    "void Widget::reset() { state_ = 0; }\n"
    "int prototype_only(int x);\n"
    "TEST_F(WidgetTest, Computes) {\n  EXPECT_EQ(add(1, 2), 3);\n}\n"
)
d = bg.defines_of("c", cpp)
for want in ("Widget", "compute", "add", "reset", "WidgetTest"):
    assert want in d, (want, d)
# calls, control-flow, and prototypes must not masquerade as definitions
assert "EXPECT_EQ" not in d and "if" not in d and "prototype_only" not in d, d

js = (
    "export function handle(req) {}\n"
    "class Server {}\n"
    "export const route = (req, res) => {};\n"
    "const helper = x => x + 1;\n"
)
dj = bg.defines_of("js", js)
for want in ("handle", "Server", "route", "helper"):
    assert want in dj, (want, dj)

# defines_at maps each symbol to its 1-based definition line (Stage 2b jump hint)
dat = bg.defines_at_of("c", cpp)
assert dat["Widget"] == 2, dat       # "class Widget {" is line 2
assert dat["compute"] == 3, dat      # method match anchors at its leading line
assert dat["add"] == 9, dat          # "constexpr int add(...)" is line 9
PY
then ok "defines_of extracts C/C++ + JS symbols (functions, classes, gtest groups)"; else bad "defines_of missing C/C++ or JS symbols, or leaking non-definitions"; fi

# --- Test 11d2: EXT_LANG recognizes alternate C/C++ + JS/TS extensions --------
# The extra c/c++ extensions (.cc/.cxx/.hh/...) are planwright's primary target,
# and .jsx/.tsx/.mjs/.cjs already appear in JS_EXTS as resolvable import targets;
# an unrecognized source extension routes as lang "unknown" and contributes no
# defines/imports/branch_count, blinding Stage 2b on those files.
if python3 -B - "$ROOT/scripts/build-graph.py" <<'PY' 2>/dev/null
import importlib.util, sys
spec = importlib.util.spec_from_file_location("bg", sys.argv[1])
bg = importlib.util.module_from_spec(spec); spec.loader.exec_module(bg)
for ext in ("cc", "cxx", "c++", "hh", "hxx", "tpp"):
    assert bg.lang_of("x." + ext, b"int f(){}") == "c", ext
for ext in ("jsx", "tsx", "mjs", "cjs"):
    assert bg.lang_of("x." + ext, b"export const f = () => 1") == "js", ext
# previously-recognized extensions are unchanged
for ext, want in (("c", "c"), ("h", "c"), ("cpp", "c"), ("hpp", "c"),
                  ("js", "js"), ("ts", "js"), ("py", "python"), ("sh", "bash")):
    assert bg.lang_of("x." + ext, b"") == want, (ext, want)
# every JS_EXTS target extension is now also a recognized source language
for e in bg.JS_EXTS:
    assert bg.lang_of("x" + e, b"") == "js", e
# a .cc file yields extracted defines + branch_count; a .tsx file is js
cc = "int compute(int n) {\n  if (n > 0) return n;\n  return 0;\n}\n"
assert "compute" in bg.defines_of("c", cc), bg.defines_of("c", cc)
assert bg.branch_count_of("c", cc) >= 1
assert bg.lang_of("Widget.tsx", b"export const W = () => 1") == "js"
PY
then ok "EXT_LANG recognizes alternate C/C++ and JS/TS extensions"; else bad "EXT_LANG missing alternate extensions or changed a known one"; fi

# --- Test 11d3: Rust source support (lang, defines, branch_count, mod/use edge) -
# A .rs file must route as lang "rust" with extracted defines + branch_count and a
# resolved mod/use import edge, so a Rust repo gets centrality routing + Stage 2b
# function hints instead of degrading to the coupling-only fallback ("unknown").
RSREPO="$TMP/rsrepo"
mkdir -p "$RSREPO/src"
git -C "$RSREPO" init -q
rsgc() { git -C "$RSREPO" -c user.name=t -c user.email=t@e.com commit -q "$@"; }
printf 'mod util;\nuse crate::util::helper;\n\nfn main() {\n    if true { helper(); }\n}\n' > "$RSREPO/src/main.rs"
printf 'pub fn helper() -> i32 {\n    for _ in 0..3 {}\n    1\n}\npub struct Thing;\n' > "$RSREPO/src/util.rs"
git -C "$RSREPO" add -A; rsgc -m init
rs_out="$TMP/rs_graph.json"
python3 "$ROOT/scripts/build-graph.py" --root "$RSREPO" > "$rs_out" 2>/dev/null
if python3 - "$rs_out" "$ROOT/scripts/build-graph.py" <<'PY' 2>/dev/null
import importlib.util, json, sys
g = json.load(open(sys.argv[1]))
n = g["nodes"]
spec = importlib.util.spec_from_file_location("bg", sys.argv[2])
bg = importlib.util.module_from_spec(spec); spec.loader.exec_module(bg)
assert bg.lang_of("x.rs", b"") == "rust", "extension .rs must map to rust"
# both files route as rust (not the coupling-fallback "unknown")
assert n["src/main.rs"]["lang"] == "rust" and n["src/util.rs"]["lang"] == "rust", n
# defines: the entry fn, the helper fn, and the struct type
assert "main" in n["src/main.rs"]["defines"], n["src/main.rs"]["defines"]
for want in ("helper", "Thing"):
    assert want in n["src/util.rs"]["defines"], (want, n["src/util.rs"]["defines"])
# branch_count picks up rust control flow (if in main, for in util)
assert n["src/main.rs"]["branch_count"] > 0 and n["src/util.rs"]["branch_count"] > 0, n
# `mod util;` / `use crate::util::helper` resolve to the sibling module file
assert "src/util.rs" in n["src/main.rs"]["imports"], n["src/main.rs"]["imports"]
PY
then ok "build-graph.py routes Rust source (lang, defines, branch_count, mod/use edge)"; else bad "build-graph.py failed to route Rust source"; fi

# --- Test 11d4: Go source support (lang, defines func/method/type, branch_count) -
# A .go file must route as lang "go" with extracted funcs/methods/types and a
# branch_count, so Stage 2b can walk Go functions instead of seeing opaque nodes.
# (Intra-module import edges are covered by Test 11d5 / the go golden fixture; this
# single-file repo has no go.mod, so it has nothing to import.)
GOREPO="$TMP/gorepo"
mkdir -p "$GOREPO"
git -C "$GOREPO" init -q
gogc() { git -C "$GOREPO" -c user.name=t -c user.email=t@e.com commit -q "$@"; }
printf 'package main\n\ntype Server struct {\n\tport int\n}\n\nfunc (s *Server) Handle(n int) int {\n\tif n > 0 {\n\t\tfor i := 0; i < n; i++ {\n\t\t}\n\t}\n\treturn 0\n}\n\nfunc main() {\n\tswitch 1 {\n\tcase 1:\n\t}\n}\n' > "$GOREPO/main.go"
git -C "$GOREPO" add -A; gogc -m init
go_out="$TMP/go_graph.json"
python3 "$ROOT/scripts/build-graph.py" --root "$GOREPO" > "$go_out" 2>/dev/null
if python3 - "$go_out" "$ROOT/scripts/build-graph.py" <<'PY' 2>/dev/null
import importlib.util, json, sys
g = json.load(open(sys.argv[1])); n = g["nodes"]["main.go"]
spec = importlib.util.spec_from_file_location("bg", sys.argv[2])
bg = importlib.util.module_from_spec(spec); spec.loader.exec_module(bg)
assert bg.lang_of("x.go", b"") == "go", "extension .go must map to go"
assert n["lang"] == "go", n
# a method (Handle), a top-level func (main), and a struct type (Server)
for want in ("Handle", "main", "Server"):
    assert want in n["defines"], (want, n["defines"])
# go control flow (if/for/switch/case) feeds branch_count for Stage 2b complexity
assert n["branch_count"] > 0, n
PY
then ok "build-graph.py routes Go source (lang, defines func/method/type, branch_count)"; else bad "build-graph.py failed to route Go source"; fi

# --- Test 11d5: Go intra-module import resolution via the root go.mod ----------
# resolve_go_import maps a Go import path to the .go files of the imported package,
# but ONLY for the repo's own module (stdlib + external packages are not repo files
# and must drop). Both single-line and grouped `import ( ... )` forms are extracted,
# and the module path comes from the root go.mod.
if python3 - "$ROOT/scripts/build-graph.py" <<'PY' 2>/dev/null
import importlib.util, sys
spec = importlib.util.spec_from_file_location("bg", sys.argv[1])
bg = importlib.util.module_from_spec(spec); spec.loader.exec_module(bg)
fs = {"go.mod", "main.go", "math/math.go", "math/util.go", "internal/db/db.go"}
mod = "mycalc"
# an intra-module import resolves to EVERY .go file in the imported package dir
assert bg.resolve_go_import("mycalc/math", mod, fs) == ["math/math.go", "math/util.go"], \
    bg.resolve_go_import("mycalc/math", mod, fs)
assert bg.resolve_go_import("mycalc/internal/db", mod, fs) == ["internal/db/db.go"], "nested pkg"
# stdlib and external modules are not repo files -> no edge
assert bg.resolve_go_import("fmt", mod, fs) == [], "stdlib drops"
assert bg.resolve_go_import("github.com/x/y", mod, fs) == [], "external drops"
# no module path known (no go.mod) -> never resolves
assert bg.resolve_go_import("mycalc/math", None, fs) == [], "no go.mod -> no edge"
# end-to-end through imports_of: grouped import block, stdlib dropped, intra-module kept
src = 'package main\nimport (\n\t"fmt"\n\t"mycalc/math"\n)\n'
got = bg.imports_of("go", src, "main.go", fs, mod)
assert got == ["math/math.go", "math/util.go"], got
# single-line aliased import form is also extracted
src2 = 'package main\nimport m "mycalc/math"\n'
assert bg.imports_of("go", src2, "main.go", fs, mod) == ["math/math.go", "math/util.go"], "single-line"
PY
then ok "build-graph.py resolves Go intra-module imports (package dir files; stdlib/external drop; needs go.mod)"; else bad "build-graph.py Go import resolution wrong (resolve_go_import / go.mod module parsing)"; fi

# --- Test 11e: coupling fallback ranks by churn-normalized weight, not raw co --
# Two pairs with equal raw cooccur (3): a/b also churn alone (churn 5, weight
# 0.6), c/d only co-change (churn 3, weight 1.0). A raw-cooccur ranking would
# tiebreak on churn and surface a/b; the spec'd weighted degree surfaces c/d.
WREPO="$TMP/wcouprepo"
mkdir -p "$WREPO"
git -C "$WREPO" init -q
wgc() { git -C "$WREPO" -c user.name=t -c user.email=t@e.com commit -q "$@"; }
for f in a b c d; do echo "# $f" > "$WREPO/$f.md"; done
git -C "$WREPO" add -A; wgc -m init
for i in 1 2; do echo "x$i" >> "$WREPO/a.md"; echo "x$i" >> "$WREPO/b.md"; git -C "$WREPO" add -A; wgc -m "ab$i"; done
for i in 1 2; do echo "y$i" >> "$WREPO/c.md"; echo "y$i" >> "$WREPO/d.md"; git -C "$WREPO" add -A; wgc -m "cd$i"; done
for i in 1 2; do echo "s$i" >> "$WREPO/a.md"; git -C "$WREPO" add -A; wgc -m "a$i"; done
for i in 1 2; do echo "s$i" >> "$WREPO/b.md"; git -C "$WREPO" add -A; wgc -m "b$i"; done
wcoup_out="$TMP/wcoup_graph.json"
python3 "$ROOT/scripts/build-graph.py" --root "$WREPO" > "$wcoup_out" 2>/dev/null
if python3 - "$wcoup_out" <<'PY' 2>/dev/null
import json, sys
g = json.load(open(sys.argv[1]))
assert g["ranking_signal"] == "coupling", g["ranking_signal"]
w = {tuple(sorted((e["a"], e["b"]))): e["weight"] for e in g["coupling_edges"]}
# tightly-coupled pair must carry the heavier weight despite equal raw cooccur
assert w[("c.md", "d.md")] > w[("a.md", "b.md")], w
# and therefore rank first under the weighted-degree fallback
assert set(g["ranked"][:2]) == {"c.md", "d.md"}, g["ranked"][:2]
PY
then ok "coupling fallback ranks by weighted degree (not raw cooccur)"; else bad "coupling fallback used raw cooccur instead of weight"; fi

# --- Test 11f: build-graph.py incremental dirty set = changed + 1-hop blast --
# Stage 1.5 step 7: a node is dirty when its sha256 changed, PLUS its 1-hop blast
# radius along import/coupling edges. A changed leaf must drag in its importer but
# leave unrelated files clean — this is what lets Stages 3-7 skip unchanged work.
DREPO="$TMP/dirtyrepo"
mkdir -p "$DREPO"
git -C "$DREPO" init -q
dgc() { git -C "$DREPO" -c user.name=t -c user.email=t@e.com commit -q "$@"; }
printf '# a\n[to b](b.md)\n' > "$DREPO/a.md"   # a.md imports b.md (markdown link)
printf '# b\n' > "$DREPO/b.md"
printf '# c\n' > "$DREPO/c.md"                  # c.md unrelated
printf '# d\n' > "$DREPO/d.md"                  # d.md unrelated
git -C "$DREPO" add -A; dgc -m init
dprior="$TMP/dirty_prior.json"
python3 "$ROOT/scripts/build-graph.py" --root "$DREPO" > "$dprior" 2>/dev/null
printf '# b\nmore\n' > "$DREPO/b.md"            # change only b.md
git -C "$DREPO" add -A; dgc -m "edit b"
dnew="$TMP/dirty_new.json"
python3 "$ROOT/scripts/build-graph.py" --root "$DREPO" --prior "$dprior" > "$dnew" 2>/dev/null
if python3 - "$dnew" <<'PY' 2>/dev/null
import json, sys
d = json.load(open(sys.argv[1]))["dirty"]
assert d["is_first_run"] is False and d["whole_graph"] is False, d
assert d["changed"] == ["b.md"], d                      # only b.md's bytes changed
assert set(d["nodes"]) == {"a.md", "b.md"}, d           # b.md + its importer a.md
assert "c.md" not in d["nodes"] and "d.md" not in d["nodes"], d  # unrelated stay clean
PY
then ok "build-graph.py incremental dirty set is changed node + 1-hop blast radius"; else bad "build-graph.py incremental dirty set wrong (blast radius or scoping)"; fi

# --- Test 11g: build-graph.py whole-graph invalidation on build-config change -
# A changed lockfile/build-config can alter how everything builds, so a localized
# dirty set would under-audit. SKILL.md Stage 1.5 step 7 forces a whole-graph
# re-audit in that case — verify CMakeLists.txt edits flip whole_graph on.
WGREPO="$TMP/wholegraphrepo"
mkdir -p "$WGREPO"
git -C "$WGREPO" init -q
wggc() { git -C "$WGREPO" -c user.name=t -c user.email=t@e.com commit -q "$@"; }
printf 'cmake_minimum_required(VERSION 3.10)\n' > "$WGREPO/CMakeLists.txt"
printf '# a\n' > "$WGREPO/a.md"
printf '# b\n' > "$WGREPO/b.md"
git -C "$WGREPO" add -A; wggc -m init
wgprior="$TMP/wg_prior.json"
python3 "$ROOT/scripts/build-graph.py" --root "$WGREPO" > "$wgprior" 2>/dev/null
printf 'cmake_minimum_required(VERSION 3.20)\n' > "$WGREPO/CMakeLists.txt"  # bump config only
git -C "$WGREPO" add -A; wggc -m "bump cmake"
wgnew="$TMP/wg_new.json"
python3 "$ROOT/scripts/build-graph.py" --root "$WGREPO" --prior "$wgprior" > "$wgnew" 2>/dev/null
if python3 - "$wgnew" <<'PY' 2>/dev/null
import json, sys
g = json.load(open(sys.argv[1]))
d = g["dirty"]
assert d["is_first_run"] is False and d["whole_graph"] is True, d
assert "build-config" in d["reason"] and "CMakeLists.txt" in d["reason"], d
assert set(d["nodes"]) == set(g["nodes"]), d            # every node re-audited
PY
then ok "build-graph.py forces whole-graph re-audit when build-config changes"; else bad "build-graph.py did not invalidate whole graph on build-config change"; fi

# --- Test 11h: articulation_points flags a cut vertex (is_articulation True) -
# articulation_points (iterative DFS lowlink) is the function Stage 2b "always
# includes", but planwright's own import graph is disconnected so its True branch
# never runs here. Chain a.md->b.md->c.md so the undirected import graph is the
# path a-b-c with b.md the cut vertex, and assert only b.md is flagged.
APREPO="$TMP/aprepo"
mkdir -p "$APREPO"
git -C "$APREPO" init -q
agc() { git -C "$APREPO" -c user.name=t -c user.email=t@e.com commit -q "$@"; }
printf '# a\n[to b](b.md)\n' > "$APREPO/a.md"   # a.md imports b.md
printf '# b\n[to c](c.md)\n' > "$APREPO/b.md"   # b.md imports c.md  => b is a cut vertex
printf '# c\n' > "$APREPO/c.md"
git -C "$APREPO" add -A; agc -m init
ap_out="$TMP/ap_graph.json"
python3 "$ROOT/scripts/build-graph.py" --root "$APREPO" > "$ap_out" 2>/dev/null
if python3 - "$ap_out" <<'PY' 2>/dev/null
import json, sys
n = json.load(open(sys.argv[1]))["nodes"]
assert n["b.md"]["is_articulation"] is True, "b.md should be a cut vertex"
assert n["a.md"]["is_articulation"] is False and n["c.md"]["is_articulation"] is False, "leaves are not cut vertices"
PY
then ok "articulation_points flags the cut vertex (is_articulation True)"; else bad "articulation_points missed the cut vertex or over-flagged a leaf"; fi

# --- Test 11i: remaining whole-graph invalidation triggers -----------------
# compute_dirty forces whole_graph beyond the build-config-CHANGED path: when the
# prior graph_built_at_sha is unreachable (commits_since -> None) and when a
# build-config file present in the prior is DELETED. Both ship untested; cover them.
WGX="$TMP/wgx"
mkdir -p "$WGX"
git -C "$WGX" init -q
xgc() { git -C "$WGX" -c user.name=t -c user.email=t@e.com commit -q "$@"; }
printf '# a\n' > "$WGX/a.md"
printf 'cmake_minimum_required(VERSION 3.10)\n' > "$WGX/CMakeLists.txt"
git -C "$WGX" add -A; xgc -m init
wgx_prior="$TMP/wgx_prior.json"
python3 "$ROOT/scripts/build-graph.py" --root "$WGX" > "$wgx_prior" 2>/dev/null
# (a) unreachable prior sha: rewrite graph_built_at_sha to a bogus 40-hex value.
wgx_bogus="$TMP/wgx_bogus.json"
python3 - "$wgx_prior" "$wgx_bogus" <<'PY'
import json, sys
g = json.load(open(sys.argv[1])); g["graph_built_at_sha"] = "0" * 40
json.dump(g, open(sys.argv[2], "w"))
PY
wgx_unreach="$TMP/wgx_unreach.json"
python3 "$ROOT/scripts/build-graph.py" --root "$WGX" --prior "$wgx_bogus" > "$wgx_unreach" 2>/dev/null
if python3 - "$wgx_unreach" <<'PY' 2>/dev/null
import json, sys
d = json.load(open(sys.argv[1]))["dirty"]
assert d["whole_graph"] is True and "unreachable" in d["reason"], d
PY
then ok "whole-graph invalidation when prior graph_built_at_sha is unreachable"; else bad "unreachable prior sha did not force whole-graph re-audit"; fi
# (b) deleted build-config: drop CMakeLists.txt, commit, rebuild against real prior.
git -C "$WGX" rm -q CMakeLists.txt; xgc -m "drop cmake"
wgx_del="$TMP/wgx_del.json"
python3 "$ROOT/scripts/build-graph.py" --root "$WGX" --prior "$wgx_prior" > "$wgx_del" 2>/dev/null
if python3 - "$wgx_del" <<'PY' 2>/dev/null
import json, sys
d = json.load(open(sys.argv[1]))["dirty"]
assert d["whole_graph"] is True and "build-config" in d["reason"] and "CMakeLists.txt" in d["reason"], d
PY
then ok "whole-graph invalidation when a build-config file is deleted"; else bad "deleted build-config did not force whole-graph re-audit"; fi

# --- Test 11i2: whole-graph invalidation when HEAD diverges beyond the window -
# The third whole-graph trigger (build-graph.py compute_dirty): re-audit everything
# when HEAD has moved more than COUPLING_WINDOW_COMMITS commits past the prior
# graph's sha. Drive it in-process with a lowered window so 2 commits cross it.
DVREPO="$TMP/dvrepo"
mkdir -p "$DVREPO"
git -C "$DVREPO" init -q
dvgc() { git -C "$DVREPO" -c user.name=t -c user.email=t@e.com commit -q "$@"; }
printf '# a\n' > "$DVREPO/a.md"
printf '# b\n' > "$DVREPO/b.md"
git -C "$DVREPO" add -A; dvgc -m init
dv_prior="$TMP/dv_prior.json"
python3 "$ROOT/scripts/build-graph.py" --root "$DVREPO" > "$dv_prior" 2>/dev/null
echo x >> "$DVREPO/a.md"; git -C "$DVREPO" add -A; dvgc -m c1   # 1 commit past prior
echo y >> "$DVREPO/b.md"; git -C "$DVREPO" add -A; dvgc -m c2   # 2 commits past prior
if python3 -B - "$ROOT/scripts/build-graph.py" "$DVREPO" "$dv_prior" <<'PY' 2>/dev/null
import importlib.util, sys
spec = importlib.util.spec_from_file_location("bg", sys.argv[1])
bg = importlib.util.module_from_spec(spec); spec.loader.exec_module(bg)
bg.COUPLING_WINDOW_COMMITS = 1                    # 2 commits diverged > 1 => whole-graph
g = bg.build(sys.argv[2], sys.argv[3])
d = g["dirty"]
assert d["whole_graph"] is True, d
assert "diverged" in d["reason"], d["reason"]
assert d["is_first_run"] is False, d
assert set(d["nodes"]) == set(g["nodes"]), d      # every node re-audited
PY
then ok "whole-graph invalidation when HEAD diverges beyond the coupling window"; else bad "HEAD divergence beyond window did not force whole-graph re-audit"; fi

# --- Test 11k: lang_of shebang sniffing + resolve markdown anchor stripping --
# Two best-effort routing branches untested on planwright's own tree (all files
# have extensions and links carry no #anchor): extensionless files take their lang
# from a shebang, and link targets get their #anchor/?query stripped before resolve.
if python3 -B - "$ROOT/scripts/build-graph.py" <<'PY' 2>/dev/null
import importlib.util, sys
spec = importlib.util.spec_from_file_location("bg", sys.argv[1])
bg = importlib.util.module_from_spec(spec); spec.loader.exec_module(bg)
assert bg.lang_of("hook", b"#!/usr/bin/env bash\n") == "bash", "shebang bash"
assert bg.lang_of("gen", b"#!/usr/bin/env python3\nx=1\n") == "python", "shebang python"
assert bg.lang_of("notes", b"plain text\n") == "unknown", "no ext, no shebang"
fs = {"a.md", "b.md"}
assert bg.resolve("b.md#section", "a.md", fs) == "b.md", "anchor strip"
assert bg.resolve("b.md?v=1", "a.md", fs) == "b.md", "query strip"
# branch_count: the "branching" half of Stage 2b's complexity tiebreak
assert bg.branch_count_of("python", "if x:\n    pass\nfor i in y:\n    while z and w:\n        pass\n") == 4, "py branches"
assert bg.branch_count_of("bash", "if a; then b; fi\nfor i in 1; do :; done\n[ x ] && y || z\n") == 4, "bash branches"
assert bg.branch_count_of("markdown", "# title\nif this were code\n") == 0, "markup has no branches"
# branch_at attributes branching per symbol by def-span: a simple function gets 0,
# a branchy one carries its own branches (function-granular Stage 2b routing)
pyfns = ("def simple():\n    return 1\n"
         "def branchy():\n    if a:\n        for x in y:\n            while z and w:\n                pass\n")
assert bg.branch_at_of("python", pyfns) == {"simple": 0, "branchy": 4}, "py branch_at by span"
shfns = ("setup() {\n  echo hi\n}\n"
         "run() {\n  if a; then b; fi\n  for i in 1; do :; done\n  [ x ] && y || z\n}\n")
assert bg.branch_at_of("bash", shfns) == {"setup": 0, "run": 4}, "bash branch_at by span"
assert bg.branch_at_of("markdown", "# t\nif words\n") == {}, "markup has no symbols/branches"
PY
then ok "lang_of shebang detection and resolve anchor/query stripping work"; else bad "shebang lang detection or link anchor stripping broke"; fi

# --- Test 11l: bash source-by-basename resolution fallback (gated to bash) ---
# resolve(..., allow_basename=True) maps a bare `source common.sh` to a unique
# lib/common.sh; an ambiguous basename (two matches) stays unresolved, and the
# fallback is bash-only (markdown link targets must not gain spurious edges).
if python3 -B - "$ROOT/scripts/build-graph.py" <<'PY' 2>/dev/null
import importlib.util, sys
spec = importlib.util.spec_from_file_location("bg", sys.argv[1])
bg = importlib.util.module_from_spec(spec); spec.loader.exec_module(bg)
fs = {"scripts/main.sh", "lib/common.sh"}
# bash: bare-name source resolves to the unique basename match
assert bg.imports_of("bash", "source common.sh\n", "scripts/main.sh", fs) == ["lib/common.sh"], "bash bare-name source"
# ambiguity: two files share the basename => no resolution
fs2 = {"scripts/main.sh", "a/common.sh", "b/common.sh"}
assert bg.imports_of("bash", "source common.sh\n", "scripts/main.sh", fs2) == [], "ambiguous basename stays unresolved"
# gating: markdown must NOT use the basename fallback
assert bg.resolve("common.sh", "x.md", fs) is None, "non-bash gets no basename fallback"
assert bg.resolve("common.sh", "x.sh", fs, allow_basename=True) == "lib/common.sh", "explicit allow_basename"
PY
then ok "bash source-by-basename fallback resolves uniquely and stays bash-gated"; else bad "bash basename fallback wrong (ambiguity, gating, or resolution)"; fi

# --- Test 11n: python dotted/relative import resolution ---------------------
# Dotted module names are not paths, so the generic resolver dropped EVERY python
# import edge — leaving the import graph empty and PageRank routing blind on a
# primary target language. Resolve pkg.mod -> pkg/mod.py, package edges, relatives.
if python3 -B - "$ROOT/scripts/build-graph.py" <<'PY' 2>/dev/null
import importlib.util, sys
spec = importlib.util.spec_from_file_location("bg", sys.argv[1])
bg = importlib.util.module_from_spec(spec); spec.loader.exec_module(bg)
fs = {"main.py", "pkg/__init__.py", "pkg/mod.py", "pkg/sub/__init__.py", "pkg/sub/deep.py"}
imp = lambda src, frm: bg.imports_of("python", src, frm, fs)
assert imp("import pkg.mod\n", "main.py") == ["pkg/mod.py"], "absolute dotted module"
assert imp("from pkg.mod import x\n", "main.py") == ["pkg/mod.py"], "from dotted module"
assert imp("from pkg import mod\n", "main.py") == ["pkg/__init__.py"], "from-import resolves to package"
assert imp("from .mod import x\n", "pkg/a.py") == ["pkg/mod.py"], "single-dot relative"
assert imp("from .sub.deep import q\n", "pkg/a.py") == ["pkg/sub/deep.py"], "relative into subpackage"
assert imp("from ..mod import x\n", "pkg/sub/inner.py") == ["pkg/mod.py"], "two-dot relative goes up a package"
assert imp("import os\nimport sys\n", "main.py") == [], "stdlib imports drop (not in fileset)"
PY
then ok "python dotted + relative imports resolve to repo files"; else bad "python import resolution broke (dotted, relative, or stdlib drop)"; fi

# --- Test 11o: js extension/index + C include-root resolution ---------------
# JS specifiers omit the extension and use directory index files; C reaches a
# header through an -I include root, not a path relative to the source. Both
# dropped under the generic resolver. Resolve them (C via unique-basename fallback).
if python3 -B - "$ROOT/scripts/build-graph.py" <<'PY' 2>/dev/null
import importlib.util, sys
spec = importlib.util.spec_from_file_location("bg", sys.argv[1])
bg = importlib.util.module_from_spec(spec); spec.loader.exec_module(bg)
js = {"src/app.js", "src/util.js", "src/lib/index.js", "src/api.ts"}
ji = lambda src, frm: bg.imports_of("js", src, frm, js)
assert ji('import x from "./util"\n', "src/app.js") == ["src/util.js"], "js extension omitted"
assert ji('import {a} from "./lib"\n', "src/app.js") == ["src/lib/index.js"], "js directory index"
assert ji('import y from "./api"\n', "src/app.js") == ["src/api.ts"], "js .ts extension"
assert ji('import z from "./util.js"\n', "src/app.js") == ["src/util.js"], "js explicit extension still works"
assert ji('import React from "react"\n', "src/app.js") == [], "bare specifier (node_modules) drops"
c = {"src/main.c", "src/util.h", "include/common.h"}
ci = lambda src, frm: bg.imports_of("c", src, frm, c)
assert ci('#include "util.h"\n', "src/main.c") == ["src/util.h"], "C same-dir include"
assert ci('#include "common.h"\n', "src/main.c") == ["include/common.h"], "C include via basename fallback"
# ambiguous basename stays unresolved (avoid spurious edges)
c2 = {"src/main.c", "a/dup.h", "b/dup.h"}
assert bg.imports_of("c", '#include "dup.h"\n', "src/main.c", c2) == [], "ambiguous C basename drops"
PY
then ok "js extension/index and C include-root imports resolve"; else bad "js or C import resolution broke (extension, index, basename, or ambiguity)"; fi

# --- Test 11p: import-looking lines inside comments/strings do NOT create edges -
# strip_comments() removes block/line comments and Python docstrings before the import
# regexes run, so a commented-out or string-embedded import no longer mis-routes the
# graph. The REAL import on the next line must still resolve (recall preserved).
if python3 -B - "$ROOT/scripts/build-graph.py" <<'PY' 2>/dev/null
import importlib.util, sys
spec = importlib.util.spec_from_file_location("bg", sys.argv[1])
bg = importlib.util.module_from_spec(spec); spec.loader.exec_module(bg)
# C: an #include inside a /* */ block is ignored; the real one resolves.
c = {"src/main.c", "src/real.h", "src/fake.h"}
src = '/*\n#include "fake.h"\n*/\n#include "real.h"\n'
assert bg.imports_of("c", src, "src/main.c", c) == ["src/real.h"], \
    bg.imports_of("c", src, "src/main.c", c)
# JS: require() in a // line comment and a /* */ block comment are ignored.
js = {"src/app.js", "src/real.js", "src/fake.js"}
src = '// const f = require("./fake")\n/* require("./fake") */\nconst r = require("./real")\n'
assert bg.imports_of("js", src, "src/app.js", js) == ["src/real.js"], \
    bg.imports_of("js", src, "src/app.js", js)
# Python: an `import` inside a triple-quoted docstring is ignored; the real one resolves.
py = {"pkg/__init__.py", "pkg/real.py", "pkg/fake.py"}
src = '"""\nimport pkg.fake\n"""\nimport pkg.real\n'
assert bg.imports_of("python", src, "pkg/__init__.py", py) == ["pkg/real.py"], \
    bg.imports_of("python", src, "pkg/__init__.py", py)
# Go: an import inside a /* */ block is ignored; the real grouped import resolves.
go = {"go.mod", "main.go", "real/real.go", "fake/fake.go"}
src = '/*\nimport "m/fake"\n*/\nimport (\n\t"m/real"\n)\n'
assert bg.imports_of("go", src, "main.go", go, "m") == ["real/real.go"], \
    bg.imports_of("go", src, "main.go", go, "m")
PY
then ok "build-graph.py strips comments/docstrings so commented-out imports do not create edges"; else bad "comment/docstring stripping wrong (a false edge survived or a real edge was lost)"; fi

# --- Test 11j: build-graph.py is deterministic (same tree => same graph) -----
# The builder's header calls it "deterministic" and incremental skipping trusts
# that identical inputs yield identical sha256/ranking. built_at (date -u) is the
# only field allowed to vary; everything else must be byte-stable across runs.
det1="$TMP/det1.json"; det2="$TMP/det2.json"
python3 "$ROOT/scripts/build-graph.py" --root "$ROOT" > "$det1" 2>/dev/null
python3 "$ROOT/scripts/build-graph.py" --root "$ROOT" > "$det2" 2>/dev/null
if python3 - "$det1" "$det2" <<'PY' 2>/dev/null
import json, sys
a = json.load(open(sys.argv[1])); b = json.load(open(sys.argv[2]))
a.pop("built_at", None); b.pop("built_at", None)
assert a == b, "build-graph.py output is not deterministic modulo built_at"
PY
then ok "build-graph.py is deterministic across runs (modulo built_at)"; else bad "build-graph.py output varies between runs on the same tree"; fi

# --- Test 11m: articulation_points on a cycle + connected-component clustering -
# Test 11h proved the positive (path) case; a CYCLE is the negative case that
# exercises the back-edge low-update branch and must yield zero cut vertices (a
# buggy lowlink over-flags here). Also assert a connected set shares one cluster.
CYREPO="$TMP/cyrepo"
mkdir -p "$CYREPO"
git -C "$CYREPO" init -q
cgc() { git -C "$CYREPO" -c user.name=t -c user.email=t@e.com commit -q "$@"; }
printf '# a\n[b](b.md)\n' > "$CYREPO/a.md"   # a->b->c->a forms a 3-cycle
printf '# b\n[c](c.md)\n' > "$CYREPO/b.md"
printf '# c\n[a](a.md)\n' > "$CYREPO/c.md"
printf '# d\n' > "$CYREPO/d.md"               # isolated singleton
git -C "$CYREPO" add -A; cgc -m init
cy_out="$TMP/cy_graph.json"
python3 "$ROOT/scripts/build-graph.py" --root "$CYREPO" > "$cy_out" 2>/dev/null
if python3 - "$cy_out" <<'PY' 2>/dev/null
import json, sys
g = json.load(open(sys.argv[1]))
n = g["nodes"]
assert all(n[f]["is_articulation"] is False for f in ("a.md", "b.md", "c.md")), "a cycle has no cut vertex"
cid = {m: c["id"] for c in g["clusters"] for m in c["members"]}
assert cid["a.md"] == cid["b.md"] == cid["c.md"], "the connected cycle must share one cluster"
assert cid["d.md"] != cid["a.md"], "the isolated file must be its own cluster"
PY
then ok "articulation_points yields no cut vertex on a cycle; component clusters together"; else bad "articulation over-flagged a cycle or clustering grouped wrong"; fi

# --- Test 11m2: cluster_label single-dir + multi-dir tiebreak ---------------
# cluster_label sets the routing label every digest cluster shows. A component
# confined to one directory is labeled by that lone dir; a component spanning
# >1 top-level dir is labeled by the MOST-COMMON top dir (the tiebreak that runs
# in production on this repo's README+docs component). Neither path was asserted.
CLREPO="$TMP/clrepo"
mkdir -p "$CLREPO/docs" "$CLREPO/src"
git -C "$CLREPO" init -q
clgc() { git -C "$CLREPO" -c user.name=t -c user.email=t@e.com commit -q "$@"; }
printf '# readme\n[a](docs/a.md)\n[b](docs/b.md)\n' > "$CLREPO/README.md"  # root + 2 docs => multi-dir
printf '# a\n' > "$CLREPO/docs/a.md"
printf '# b\n' > "$CLREPO/docs/b.md"
printf '# x\n[y](y.md)\n' > "$CLREPO/src/x.md"                              # single-dir component
printf '# y\n' > "$CLREPO/src/y.md"
git -C "$CLREPO" add -A; clgc -m init
cl_out="$TMP/cl_graph.json"
python3 "$ROOT/scripts/build-graph.py" --root "$CLREPO" > "$cl_out" 2>/dev/null
if python3 - "$cl_out" <<'PY' 2>/dev/null
import json, sys
g = json.load(open(sys.argv[1]))
lbl = {c["id"]: c["label"] for c in g["clusters"]}
cid = {m: c["id"] for c in g["clusters"] for m in c["members"]}
# multi-dir component (README at root + docs/a + docs/b) -> most-common top dir "docs"
assert lbl[cid["README.md"]] == "docs", (lbl, cid)
assert cid["README.md"] == cid["docs/a.md"] == cid["docs/b.md"], cid
# single-dir component (src/x + src/y) -> its lone directory "src"
assert lbl[cid["src/x.md"]] == "src", (lbl, cid)
assert cid["src/x.md"] == cid["src/y.md"], cid
PY
then ok "cluster_label labels a single-dir component by its dir and a multi-dir one by the most-common top dir"; else bad "cluster_label mislabeled a single-dir or multi-dir component"; fi

# --- Test 11m3: pagerank conserves mass and redistributes dangling-node rank --
# pagerank redistributes the rank of dangling (no-out-link) nodes across all
# nodes every build (build-graph.py lines 299-301). Most real nodes dangle, so a
# regression there would skew the central ranking signal silently. Pin both the
# mass-conservation invariant (scores sum to ~1.0) and that targeted nodes outrank
# an isolated dangling node.
if python3 -B - "$ROOT/scripts/build-graph.py" <<'PY' 2>/dev/null
import importlib.util, sys
spec = importlib.util.spec_from_file_location("bg", sys.argv[1])
bg = importlib.util.module_from_spec(spec); spec.loader.exec_module(bg)
nodes = ["a", "b", "c", "d"]
edges = {"a": ["b", "c"]}      # b, c, d all dangle; d is also isolated (no incoming)
pr = bg.pagerank(nodes, edges)
# the dangling-redistribution loop keeps total rank mass at 1.0
assert abs(sum(pr.values()) - 1.0) < 1e-6, sum(pr.values())
# nodes that receive an edge from a outrank the isolated node d
assert pr["b"] > pr["d"] and pr["c"] > pr["d"], pr
# an empty graph degrades gracefully to an empty ranking
assert bg.pagerank([], {}) == {}, "empty pagerank must be {}"
PY
then ok "pagerank conserves mass (sum~1.0) and redistributes dangling-node rank"; else bad "pagerank lost mass or mis-redistributed dangling rank"; fi

