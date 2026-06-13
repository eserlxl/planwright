# SPDX-FileCopyrightText: 2026 Eser KUBALI
# SPDX-License-Identifier: GPL-3.0-or-later
# shellcheck shell=bash
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
assert set(g["params"]) == {"coupling_window_commits", "coupling_min_cooccurrence", "ranked_surface_limit", "git_timeout_seconds"}, "params keyset must match the documented schema exactly (docs/graph-memory-schema.md)"
assert g["nodes"], "no nodes"
need = {"sha256", "loc", "branch_count", "branch_at", "lang", "git_churn", "defines", "defines_at", "imports", "is_test", "covered_by_test", "pagerank", "is_articulation", "last_audited_sha", "audit_age_commits", "swallow_count", "swallow_at"}
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
    # swallow_count/swallow_at mirror the branch invariants (silent-failure signal)
    assert isinstance(n["swallow_count"], int) and n["swallow_count"] >= 0, f
    assert isinstance(n["swallow_at"], dict), f
    assert all(isinstance(v, int) and v >= 0 for v in n["swallow_at"].values()), f
    assert set(n["swallow_at"]) <= set(n["defines"]), f
    # audit_age_commits: None (never audited / unreachable stamp) or int >= 0,
    # and always None when there is no stamp to age
    a = n["audit_age_commits"]
    assert a is None or (isinstance(a, int) and a >= 0), f
    if n["last_audited_sha"] is None:
        assert a is None, f
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
# frontier: on a first run nothing is stamped, so the whole non-test code surface
# is the never-audited frontier and nothing can be stale yet
code = [f for f, n in g["nodes"].items() if not n["is_test"] and n["branch_count"] > 0]
assert g["frontier"] == {"never_audited": len(code), "stale": 0}, g["frontier"]
PY
then ok "build-graph.py output conforms to graph-memory schema"; else bad "build-graph.py output missing or non-conforming"; fi

# --- Test 11a: PW_COUPLING_MAX_FILES overrides the coupling bulk-skip threshold
# The git timeout is runtime-overridable (PW_GIT_TIMEOUT_SECONDS); its sibling
# bulk-skip threshold COUPLING_MAX_FILES_PER_COMMIT must be too, so a large-commit
# monorepo can tune it instead of silently dropping the coupling signal.
if python3 - "$ROOT/scripts/build-graph.py" <<'PY' 2>/dev/null
import importlib.util, os, sys
def load():
    spec = importlib.util.spec_from_file_location("bg", sys.argv[1])
    m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m); return m
os.environ.pop("PW_COUPLING_MAX_FILES", None)
assert load().COUPLING_MAX_FILES_PER_COMMIT == 100, "default"
os.environ["PW_COUPLING_MAX_FILES"] = "7"
assert load().COUPLING_MAX_FILES_PER_COMMIT == 7, "override"
os.environ["PW_COUPLING_MAX_FILES"] = "0"
assert load().COUPLING_MAX_FILES_PER_COMMIT == 100, "non-positive falls back"
os.environ["PW_COUPLING_MAX_FILES"] = "x"
assert load().COUPLING_MAX_FILES_PER_COMMIT == 100, "non-integer falls back"
PY
then ok "PW_COUPLING_MAX_FILES overrides the coupling bulk-skip threshold (invalid falls back to 100)"; else bad "PW_COUPLING_MAX_FILES override/fallback wrong"; fi

# --- Test 11a2: bash `source $(dirname $0)/lib` couples via the recovered basename
# The old [^\s;]+ capture truncated at the space inside the command substitution and
# dropped the edge; the balanced-token capture + basename fallback now recovers it.
if python3 - "$ROOT/scripts/build-graph.py" <<'PY' 2>/dev/null
import importlib.util, sys
spec = importlib.util.spec_from_file_location("bg", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
fs = {"a.sh", "helper.sh"}
assert m.imports_of("bash", "source $(dirname $0)/helper.sh", "a.sh", fs) == ["helper.sh"], "dynamic-prefix source dropped"
assert m.imports_of("bash", 'source "${LIB}/helper.sh"', "a.sh", fs) == ["helper.sh"], "brace-var source regressed"
assert m.imports_of("bash", "source helper.sh", "a.sh", fs) == ["helper.sh"], "static source regressed"
PY
then ok "bash source with a command-substitution prefix still couples (basename recovered)"; else bad "bash dynamic-prefix source coupling wrong"; fi

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

# --- Test 11h: build-graph.py parses commit boundaries in SHA-256 repos ------
# A SHA-256 repo produces 64-char hashes (a 71-char `commit:<hash>` line); the
# commit-boundary gate must accept that length, else change-coupling/churn silently
# break. Without the fix the boundary is never matched and no coupling edge appears.
S256="$TMP/sha256repo"; mkdir -p "$S256"
if git -C "$S256" init -q --object-format=sha256 2>/dev/null; then
  for f in alpha beta; do echo "# $f" > "$S256/$f.md"; done
  git -C "$S256" add -A
  git -C "$S256" -c user.name=t -c user.email=t@e.com commit -qm init
  for i in 1 2 3; do
    echo "e$i" >> "$S256/alpha.md"; echo "e$i" >> "$S256/beta.md"
    git -C "$S256" add -A
    git -C "$S256" -c user.name=t -c user.email=t@e.com commit -qm "co $i"
  done
  s256_out="$TMP/sha256_graph.json"
  python3 "$ROOT/scripts/build-graph.py" --root "$S256" > "$s256_out" 2>/dev/null
  if python3 - "$s256_out" <<'PY' 2>/dev/null
import json, sys
g = json.load(open(sys.argv[1]))
edge = [e for e in g["coupling_edges"] if {e["a"], e["b"]} == {"alpha.md", "beta.md"}]
assert edge and edge[0]["cooccur"] >= 3, "no alpha/beta coupling edge in a SHA-256 repo"
PY
  then ok "build-graph.py parses commit boundaries in a SHA-256 repo (coupling edge present)"; else bad "build-graph.py missed coupling in a SHA-256 repo (commit boundary not parsed)"; fi
else
  ok "build-graph.py SHA-256 check skipped (git lacks --object-format=sha256)"
fi

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

# --- Test 11c-md: markdown link titles + angle-bracketed destinations resolve -----
# A CommonMark destination with a "title" — [x](./b.md "T") — or angle-wrapped —
# [x](<c.md>) — used to reach resolve() verbatim and silently drop the import edge.
# Both must now resolve like a plain link, while a plain link and an external/# link
# are unchanged.
MDREPO="$TMP/md_link_repo"; mkdir -p "$MDREPO"
git -C "$MDREPO" init -q
printf '# a\n[t](./b.md "Title here")\n[u](<c.md>)\n[v](./d.md)\n[ext](https://x/y)\n[frag](b.md#sec)\n' > "$MDREPO/a.md"
for n in b c d; do printf '# %s\n' "$n" > "$MDREPO/$n.md"; done
git -C "$MDREPO" add -A
git -C "$MDREPO" -c user.name=t -c user.email=t@e.com commit -qm init
md_out="$TMP/md_link_graph.json"
python3 "$ROOT/scripts/build-graph.py" --root "$MDREPO" > "$md_out" 2>/dev/null
if python3 - "$md_out" <<'PY' 2>/dev/null
import json, sys
g = json.load(open(sys.argv[1]))
imp = set(g["nodes"]["a.md"]["imports"])
assert {"b.md", "c.md", "d.md"} <= imp, imp        # titled, angle-wrapped, plain all resolve
assert not any(i.startswith("http") for i in imp), imp   # external dropped
PY
then ok "build-graph.py resolves markdown link titles and angle-bracketed destinations"; else bad "build-graph.py dropped a titled/angle-bracketed markdown import edge"; fi

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


# --- Test 11k: build-graph.py streams + skips parsing an oversized file ------
# A tracked file above MAX_FILE_BYTES (5MB) must be hashed and line-counted by
# streaming but never decoded/parsed, so its symbol/branch fields stay empty
# even though it is full of `def` — proving the whole blob never loads. A normal
# file in the same repo is still parsed, so the skip is scoped to the big one.
BIGREPO="$TMP/bigrepo"
mkdir -p "$BIGREPO"
git -C "$BIGREPO" init -q
echo "def small(): pass" > "$BIGREPO/small.py"
python3 -c "open('$BIGREPO/big.py','w').write('def g(): return 1\n'*450000)"  # ~8MB
git -C "$BIGREPO" add -A
git -C "$BIGREPO" -c user.name=t -c user.email=t@e.com commit -qm init
big_out="$TMP/big_graph.json"
python3 "$ROOT/scripts/build-graph.py" --root "$BIGREPO" > "$big_out" 2>/dev/null
if python3 - "$big_out" "$BIGREPO/big.py" <<'PY' 2>/dev/null
import json, sys, hashlib, os
g = json.load(open(sys.argv[1]))
big = g["nodes"]["big.py"]
small = g["nodes"]["small.py"]
assert os.path.getsize(sys.argv[2]) > 5 * 1024 * 1024, "fixture not oversized"
# present and correctly hashed (streamed), but symbol/import parsing was skipped
assert big["sha256"] == hashlib.sha256(open(sys.argv[2], "rb").read()).hexdigest(), "sha mismatch"
assert big["defines"] == [] and big["defines_at"] == {}, big
assert big["branch_count"] == 0 and big["branch_at"] == {}, big
assert big["imports"] == [], big
assert big["loc"] == 450000, big["loc"]
# a normal file in the same repo is still parsed
assert "small" in small["defines"], small
PY
then ok "build-graph.py streams + skips parsing an oversized file"; else bad "build-graph.py did not skip the oversized file"; fi

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

# --- Test 11c2c2: graded staleness — audit_age_commits orders ranked_cold, frontier counts the residual
# cold_key's staleness band: within the stamped nodes, the stalest stamp (most commits since,
# via audit_age_commits) leads, so an incremental explore sweep drains the audited-but-aging
# backlog a cold start would expose. Also the first cold-vs-incremental regression pin: the
# exact residual the incremental dirty set will NOT touch is an asserted frontier quantity.
# Fixture: five code files; b.sh stamped at an old commit (stale — alphabetically AFTER
# the fresh a.sh, so the path tiebreak OPPOSES the asserted order and only the staleness
# key can produce it), a.sh restamped at HEAD (fresh), c.sh never stamped, d.sh stamped
# with a garbage sha (unreachable -> cold bin), f.sh stamped old but ALSO dirtied (pins
# that the stale count excludes the dirty set: an aged node the run re-audits anyway is
# not residual backlog).
STREPO="$TMP/strepo"
mkdir -p "$STREPO"
git -C "$STREPO" init -q
for fn in a b c d f; do
  printf '#!/usr/bin/env bash\n%s() { if true; then echo %s; fi; }\n' "$fn" "$fn" > "$STREPO/$fn.sh"
done
git -C "$STREPO" add -A
git -C "$STREPO" -c user.name=t -c user.email=t@e.com commit -qm init
st_old_sha=$(git -C "$STREPO" rev-parse HEAD)
st_prior="$TMP/st_prior.json"
python3 "$ROOT/scripts/build-graph.py" --root "$STREPO" > "$st_prior" 2>/dev/null
# two more commits: note1 also dirties f.sh; the other .sh nodes stay out of the dirty set
echo note1 > "$STREPO/e.txt"; echo '# drift' >> "$STREPO/f.sh"; git -C "$STREPO" add -A
git -C "$STREPO" -c user.name=t -c user.email=t@e.com commit -qm note1
echo note2 >> "$STREPO/e.txt"; git -C "$STREPO" add -A
git -C "$STREPO" -c user.name=t -c user.email=t@e.com commit -qm note2
st_head_sha=$(git -C "$STREPO" rev-parse HEAD)
st_age=$(git -C "$STREPO" rev-list --count "$st_old_sha..HEAD")
python3 - "$st_prior" "$st_old_sha" "$st_head_sha" <<'PY'
import json, sys
p, old, head = sys.argv[1], sys.argv[2], sys.argv[3]
g = json.load(open(p))
g["nodes"]["b.sh"]["last_audited_sha"] = old      # stale: stamped two commits ago
g["nodes"]["a.sh"]["last_audited_sha"] = head     # fresh: restamped at current HEAD
g["nodes"]["d.sh"]["last_audited_sha"] = "d" * 40 # unreachable stamp -> cold bin
g["nodes"]["f.sh"]["last_audited_sha"] = old      # stale AND dirty (modified post-stamp)
json.dump(g, open(p, "w"))
PY
st_new="$TMP/st_new.json"
python3 "$ROOT/scripts/build-graph.py" --root "$STREPO" --prior "$st_prior" > "$st_new" 2>/dev/null
if python3 - "$st_new" "$st_age" <<'PY' 2>/dev/null
import json, sys
g = json.load(open(sys.argv[1])); n = g["nodes"]; rc = g["ranked_cold"]
expected_age = int(sys.argv[2])
# ages match `git rev-list --count <stamp>..HEAD`; no stamp / garbage stamp degrade to None
assert n["b.sh"]["audit_age_commits"] == expected_age, n["b.sh"]
assert n["f.sh"]["audit_age_commits"] == expected_age, n["f.sh"]
assert n["a.sh"]["audit_age_commits"] == 0, n["a.sh"]
assert n["c.sh"]["audit_age_commits"] is None, n["c.sh"]
assert n["d.sh"]["audit_age_commits"] is None, n["d.sh"]
# frontier band order: never/unreachable (c, d) < stale (b) < fresh (a). The path
# tiebreak alone would put a.sh before b.sh, so only the staleness key passes this.
for f in ("a.sh", "b.sh", "c.sh", "d.sh"):
    assert f in rc, (f, rc)
assert rc.index("c.sh") < rc.index("b.sh") and rc.index("d.sh") < rc.index("b.sh"), rc
assert rc.index("b.sh") < rc.index("a.sh"), rc
# the cold-vs-incremental pin: b.sh is OUTSIDE the incremental dirty set, so the
# frontier counts it as the stale residual the run will not touch; f.sh is aged the
# same but IN the dirty set, so it must not be counted (else stale would be 2)
d = g["dirty"]
assert d["is_first_run"] is False, d
assert "f.sh" in d["nodes"] and "b.sh" not in d["nodes"] and "a.sh" not in d["nodes"], d
assert g["frontier"] == {"never_audited": 2, "stale": 1}, g["frontier"]
PY
then ok "audit_age_commits grades ranked_cold's staleness band and frontier pins the incremental residual"; else bad "graded staleness ordering or frontier accounting broke (see Test 11c2c2)"; fi

# --- Test 11c2c3: a corrupt prior last_audited_sha degrades to never-audited, not a crash
# Stage 11 has the agent rewrite graph.json by hand (native Write tool), so a malformed
# stamp (int, list) is realistic corruption. The stamp sanitizer must coerce it to None
# (= never audited) before the audit_age_commits batch sorts/hashes the stamp set.
cs_prior="$TMP/cs_prior.json"
python3 - "$st_prior" "$cs_prior" "$st_old_sha" <<'PY'
import json, sys
g = json.load(open(sys.argv[1]))
g["nodes"]["a.sh"]["last_audited_sha"] = 12345          # int stamp
g["nodes"]["b.sh"]["last_audited_sha"] = ["not", "a"]   # list stamp
g["nodes"]["c.sh"]["last_audited_sha"] = sys.argv[3]    # a real one survives beside them
json.dump(g, open(sys.argv[2], "w"))
PY
cs_new="$TMP/cs_new.json"
if python3 "$ROOT/scripts/build-graph.py" --root "$STREPO" --prior "$cs_prior" > "$cs_new" 2>/dev/null \
   && python3 - "$cs_new" <<'PY' 2>/dev/null
import json, sys
n = json.load(open(sys.argv[1]))["nodes"]
assert n["a.sh"]["last_audited_sha"] is None and n["a.sh"]["audit_age_commits"] is None, n["a.sh"]
assert n["b.sh"]["last_audited_sha"] is None and n["b.sh"]["audit_age_commits"] is None, n["b.sh"]
assert isinstance(n["c.sh"]["last_audited_sha"], str) and n["c.sh"]["audit_age_commits"] >= 0, n["c.sh"]
PY
then ok "build-graph.py coerces corrupt prior stamps to never-audited instead of crashing"; else bad "build-graph.py crashed or kept a corrupt prior last_audited_sha"; fi

# --- Test 11c2c4: swallow_count/swallow_at surface error-swallowing sites per node and symbol
# Stage 2b's silent-failure hunt promotes swallow_at > 0 functions; the builder must
# attribute a python except-pass to the function that contains it (not its clean sibling),
# count a bash `|| true`, and report 0 on a no-arm language (markdown).
SWREPO="$TMP/swrepo"
mkdir -p "$SWREPO"
git -C "$SWREPO" init -q
cat > "$SWREPO/quiet.py" <<'EOF'
def swallower():
    try:
        risky()
    except Exception:
        pass

def clean():
    return risky()
EOF
printf '#!/usr/bin/env bash\nrun() { rm -f lock || true; }\n' > "$SWREPO/noisy.sh"
printf '# notes\nexcept: pass\n' > "$SWREPO/notes.md"
git -C "$SWREPO" add -A
git -C "$SWREPO" -c user.name=t -c user.email=t@e.com commit -qm init
sw_out="$TMP/sw_graph.json"
python3 "$ROOT/scripts/build-graph.py" --root "$SWREPO" > "$sw_out" 2>/dev/null
if python3 - "$sw_out" <<'PY' 2>/dev/null
import json, sys
n = json.load(open(sys.argv[1]))["nodes"]
assert n["quiet.py"]["swallow_count"] == 1, n["quiet.py"]
assert n["quiet.py"]["swallow_at"] == {"swallower": 1, "clean": 0}, n["quiet.py"]["swallow_at"]
assert n["noisy.sh"]["swallow_count"] == 1, n["noisy.sh"]
assert n["notes.md"]["swallow_count"] == 0 and n["notes.md"]["swallow_at"] == {}, n["notes.md"]
PY
then ok "build-graph.py attributes swallow_count/swallow_at to the swallowing symbol (no-arm langs report 0)"; else bad "swallow_count/swallow_at extraction wrong (see Test 11c2c4)"; fi

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
python3 "$ROOT/scripts/build-graph.py" --root "$SDREPO" --seed 43 > "$sd_c" 2>/dev/null
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

# --- Test 11c2g: contiguous seeds sweep the framing catalog in order (codcycle rotation)
# explore_framing is a clean modulo rotation — seed N selects the Nth framing (1-indexed) —
# so /codcycle driving seeds 1, 2, 3, … sweeps every vantage with no repeat/gap before
# wrapping. This is the contract codcycle's "rotate framings, stop when all dry" relies on.
for s in 1 2 3 4 5 6; do
  python3 "$ROOT/scripts/build-graph.py" --root "$SDREPO" --seed "$s" > "$TMP/seed_rot_$s.json" 2>/dev/null
done
if python3 - "$TMP/seed_rot_1.json" "$TMP/seed_rot_2.json" "$TMP/seed_rot_3.json" "$TMP/seed_rot_4.json" "$TMP/seed_rot_5.json" "$TMP/seed_rot_6.json" <<'PY' 2>/dev/null
import json, sys
fr = [json.load(open(p))["explore_framing"] for p in sys.argv[1:7]]
CATALOG = ["power-user", "integration", "onboarding", "reliability", "automation"]
assert fr[:5] == CATALOG, fr[:5]            # seeds 1..5 cover all five vantages in order
assert fr[5] == CATALOG[0], fr[5]           # seed 6 wraps to the first framing
PY
then ok "build-graph contiguous seeds 1..N sweep the framing catalog in order (the rotation /codcycle drives)"; else bad "seed->framing is not a clean catalog rotation (codcycle's framing sweep would repeat or skip vantages)"; fi

# --- Test 11c2h: --dot exports the import graph as GraphViz DOT (interop) ----------
# build-graph emits JSON by default; --dot serializes the same import graph as DOT
# (a node line per file, a directed edge per resolved import) for visualization/interop,
# and must leave the default JSON output untouched.
DOTREPO="$TMP/dotrepo"; mkdir -p "$DOTREPO"
printf '#!/usr/bin/env bash\nsource b.sh\na() { if true; then echo a; fi; }\n' > "$DOTREPO/a.sh"
printf '#!/usr/bin/env bash\nb() { if true; then echo b; fi; }\n' > "$DOTREPO/b.sh"
git -C "$DOTREPO" init -q && git -C "$DOTREPO" add -A
git -C "$DOTREPO" -c user.name=t -c user.email=t@e.com commit -qm init
dot_out="$(python3 "$ROOT/scripts/build-graph.py" --root "$DOTREPO" --dot 2>/dev/null)"
json_out="$(python3 "$ROOT/scripts/build-graph.py" --root "$DOTREPO" 2>/dev/null)"
if printf '%s' "$dot_out" | head -1 | grep -q '^digraph planwright {' \
   && printf '%s' "$dot_out" | grep -q '"a.sh";' \
   && printf '%s' "$dot_out" | grep -q '"a.sh" -> "b.sh";' \
   && printf '%s' "$dot_out" | tail -1 | grep -q '^}' \
   && ! printf '%s' "$dot_out" | grep -q '"nodes"' \
   && printf '%s' "$json_out" | grep -q '"nodes"' \
   && ! printf '%s' "$json_out" | grep -q 'digraph'; then
  ok "build-graph --dot emits GraphViz DOT (nodes + import edge); default stays JSON"
else
  bad "build-graph --dot did not emit a correct DOT import graph or altered the default JSON output"
fi

# --- Test 11c2h2: --dot also renders change-coupling edges (hidden-dependency view) -
# build-graph computes change-coupling pairs (files that co-change in history) but they were
# invisible in the import-only DOT export; --dot now emits each coupling pair as a dashed,
# arrowless (dir=none) edge — distinct from the solid directed import edges — while leaving
# the default JSON output free of any DOT styling.
CDOTREPO="$TMP/cdotrepo"; mkdir -p "$CDOTREPO"
git -C "$CDOTREPO" init -q
printf 'x\n' > "$CDOTREPO/cup_a.md"; printf 'y\n' > "$CDOTREPO/cup_b.md"
git -C "$CDOTREPO" add -A && git -C "$CDOTREPO" -c user.name=t -c user.email=t@e.com commit -qm c0
# Co-commit the pair three more times so their cooccur clears coupling_min_cooccurrence (3).
for i in 1 2 3; do
  printf 'x%s\n' "$i" >> "$CDOTREPO/cup_a.md"; printf 'y%s\n' "$i" >> "$CDOTREPO/cup_b.md"
  git -C "$CDOTREPO" add -A && git -C "$CDOTREPO" -c user.name=t -c user.email=t@e.com commit -qm "c$i"
done
cdot_out="$(python3 "$ROOT/scripts/build-graph.py" --root "$CDOTREPO" --dot 2>/dev/null)"
cjson_out="$(python3 "$ROOT/scripts/build-graph.py" --root "$CDOTREPO" 2>/dev/null)"
if printf '%s' "$cdot_out" | grep -qE '"cup_a.md" -> "cup_b.md" \[style=dashed, dir=none\];' \
   && printf '%s' "$cjson_out" | grep -q '"coupling_edges"' \
   && ! printf '%s' "$cjson_out" | grep -q 'style=dashed'; then
  ok "build-graph --dot renders change-coupling edges (dashed, dir=none); default stays JSON"
else
  bad "build-graph --dot did not render the change-coupling edge: $cdot_out"
fi

# --- Test 11c2h3: --dot honors --scope (render only the Focus+Context subgraph) -----
# A power user visualizing a real repo wants one component's subgraph, not the whole tree.
# When built with --scope, --dot restricts the render to the Context set (Focus + 1-hop);
# a 2-hop node and an unrelated orphan must NOT appear, while an unscoped --dot renders all.
# Fixture: src/api -> src/auth -> lib/crypto -> lib/deep, plus an orphan; scope to src/.
SDOTREPO="$TMP/sdotrepo"; mkdir -p "$SDOTREPO/src" "$SDOTREPO/lib" "$SDOTREPO/other"
git -C "$SDOTREPO" init -q
printf '#!/usr/bin/env bash\nsource auth.sh\napi() { echo p; }\n' > "$SDOTREPO/src/api.sh"
printf '#!/usr/bin/env bash\nsource ../lib/crypto.sh\nauth() { echo a; }\n' > "$SDOTREPO/src/auth.sh"
printf '#!/usr/bin/env bash\nsource deep.sh\ncrypto() { echo c; }\n' > "$SDOTREPO/lib/crypto.sh"
printf '#!/usr/bin/env bash\ndeep() { echo d; }\n' > "$SDOTREPO/lib/deep.sh"
printf '#!/usr/bin/env bash\norphan() { echo o; }\n' > "$SDOTREPO/other/orphan.sh"
git -C "$SDOTREPO" add -A && git -C "$SDOTREPO" -c user.name=t -c user.email=t@e.com commit -qm init
sdot_scoped="$(python3 "$ROOT/scripts/build-graph.py" --root "$SDOTREPO" --scope src/ --dot 2>/dev/null)"
sdot_full="$(python3 "$ROOT/scripts/build-graph.py" --root "$SDOTREPO" --dot 2>/dev/null)"
if printf '%s' "$sdot_scoped" | grep -q '"src/api.sh" -> "src/auth.sh";' \
   && printf '%s' "$sdot_scoped" | grep -q '"src/auth.sh" -> "lib/crypto.sh";' \
   && printf '%s' "$sdot_scoped" | grep -qE '^  "lib/crypto.sh"( \[|;)' \
   && ! printf '%s' "$sdot_scoped" | grep -q 'lib/deep.sh' \
   && ! printf '%s' "$sdot_scoped" | grep -q 'other/orphan.sh' \
   && printf '%s' "$sdot_full" | grep -q '"lib/deep.sh";' \
   && printf '%s' "$sdot_full" | grep -q '"other/orphan.sh";'; then
  ok "build-graph --dot honors --scope (renders Focus+Context only; unscoped renders all)"
else
  bad "build-graph --dot did not scope the render: $sdot_scoped"
fi

# --- Test 11c2h4: --dot marks articulation points (the fragile chokepoints) ---------
# build-graph computes is_articulation (cut-vertices whose removal disconnects the graph
# = wide-blast-radius chokepoints); --dot now renders those nodes as bold boxes so an
# expert can spot the structural risks visually, leaving leaf nodes as plain ellipses.
# Fixture: a chain mid -> leaf with a second importer of mid, making mid a cut vertex.
ARTREPO="$TMP/artrepo"; mkdir -p "$ARTREPO"
git -C "$ARTREPO" init -q
printf '#!/usr/bin/env bash\nsource mid.sh\nleft() { echo l; }\n' > "$ARTREPO/left.sh"
printf '#!/usr/bin/env bash\nsource mid.sh\nright() { echo r; }\n' > "$ARTREPO/right.sh"
printf '#!/usr/bin/env bash\nsource leaf.sh\nmid() { echo m; }\n' > "$ARTREPO/mid.sh"
printf '#!/usr/bin/env bash\nleaf() { echo f; }\n' > "$ARTREPO/leaf.sh"
git -C "$ARTREPO" add -A && git -C "$ARTREPO" -c user.name=t -c user.email=t@e.com commit -qm init
art_out="$(python3 "$ROOT/scripts/build-graph.py" --root "$ARTREPO" --dot 2>/dev/null)"
art_json="$(python3 "$ROOT/scripts/build-graph.py" --root "$ARTREPO" 2>/dev/null)"
# Confirm the graph actually flags mid.sh as an articulation point (else the test is vacuous).
mid_is_art="$(printf '%s' "$art_json" | python3 -c 'import json,sys; print(json.load(sys.stdin)["nodes"]["mid.sh"]["is_articulation"])')"
if [ "$mid_is_art" = "True" ] \
   && printf '%s' "$art_out" | grep -qE '^  "mid.sh" \[shape=box, style=bold\];$' \
   && printf '%s' "$art_out" | grep -qE '^  "leaf.sh";$' \
   && ! printf '%s' "$art_out" | grep -qE '^  "leaf.sh" \['; then
  ok "build-graph --dot marks articulation points as bold boxes; leaf nodes stay plain"
else
  bad "build-graph --dot did not mark the articulation point: $art_out"
fi

# --- Test 11c2j: --select queries the computed per-node signals (scriptable slices) -
# --select EXPR prints the repo-relative paths of nodes matching one closed predicate over
# the signals build-graph computes, one per line, sorted — so an expert can ask "which are
# the chokepoints / the python files / the test files" without piping the full JSON through
# jq. An unknown predicate errors to stderr (exit 2); --select takes precedence over --dot.
# Fixture: x,y -> hub -> z plus test_hub -> hub, making hub the single articulation point.
SELREPO="$TMP/selrepo"; mkdir -p "$SELREPO"
git -C "$SELREPO" init -q
printf 'import hub\n' > "$SELREPO/x.py"
printf 'import hub\n' > "$SELREPO/y.py"
printf 'import z\ndef h():\n    if True:\n        return 1\n' > "$SELREPO/hub.py"
printf 'def z():\n    return 0\n' > "$SELREPO/z.py"
printf 'import hub\ndef test_h():\n    assert True\n' > "$SELREPO/test_hub.py"
git -C "$SELREPO" add -A && git -C "$SELREPO" -c user.name=t -c user.email=t@e.com commit -qm init
sel_art="$(python3 "$ROOT/scripts/build-graph.py" --root "$SELREPO" --select is_articulation 2>/dev/null)"
sel_test="$(python3 "$ROOT/scripts/build-graph.py" --root "$SELREPO" --select is_test 2>/dev/null)"
sel_py="$(python3 "$ROOT/scripts/build-graph.py" --root "$SELREPO" --select lang=python 2>/dev/null | sort | tr '\n' ' ')"
sel_notest="$(python3 "$ROOT/scripts/build-graph.py" --root "$SELREPO" --select no-is_test 2>/dev/null)"
sel_prec="$(python3 "$ROOT/scripts/build-graph.py" --root "$SELREPO" --select is_articulation --dot 2>/dev/null)"
sel_bad_rc=0; python3 "$ROOT/scripts/build-graph.py" --root "$SELREPO" --select bogus >/dev/null 2>"$TMP/sel_err" || sel_bad_rc=$?
if [ "$sel_art" = "hub.py" ] \
   && printf '%s' "$sel_test" | grep -qx "test_hub.py" \
   && [ "$sel_py" = "hub.py test_hub.py x.py y.py z.py " ] \
   && ! printf '%s' "$sel_notest" | grep -qx "test_hub.py" \
   && [ "$sel_bad_rc" = 2 ] && grep -q "unknown --select predicate" "$TMP/sel_err" \
   && printf '%s' "$sel_prec" | grep -qx "hub.py" && ! printf '%s' "$sel_prec" | grep -q "digraph"; then
  ok "build-graph --select filters nodes by predicate (bool/code/lang); bad predicate exits 2; precedes --dot"
else
  bad "build-graph --select wrong (art=[$sel_art] py=[$sel_py] badrc=$sel_bad_rc)"
fi

# --- Test 11c2j2: --select honors --scope (Context-restricted, like --dot) + lang= guard --
# (a) Under --scope, --select restricts to the Context node set (Focus + 1-hop), matching --dot
# so the two non-JSON modes agree on scope. Scope to z.py: Context = z.py + hub.py (hub imports
# z), so the python nodes are exactly hub.py + z.py — never x.py/y.py/test_hub.py.
# (b) a bare `lang=` (missing NAME) is malformed and must exit 2 like any unknown predicate,
# not silently exit 0 with empty output.
sel_scoped="$(python3 "$ROOT/scripts/build-graph.py" --root "$SELREPO" --scope z.py --select lang=python 2>/dev/null | sort | tr '\n' ' ')"
sel_le_rc=0; python3 "$ROOT/scripts/build-graph.py" --root "$SELREPO" --select 'lang=' >/dev/null 2>"$TMP/sel_le_err" || sel_le_rc=$?
if [ "$sel_scoped" = "hub.py z.py " ] && [ "$sel_le_rc" = 2 ] && grep -q "unknown --select predicate" "$TMP/sel_le_err"; then
  ok "build-graph --select honors --scope (Context-restricted) and rejects a bare lang= (exit 2)"
else
  bad "build-graph --select scope/lang= regression (scoped=[$sel_scoped] le_rc=$sel_le_rc)"
fi

# --- Test 11c2j3: --select comma-ANDs predicate conjunctions (multi-signal, no jq) --
# Each comma-separated token resolves through the same closed vocabulary and a node must
# match ALL of them. lang=python,no-is_test on SELREPO is a strict subset of lang=python
# (test_hub.py drops), proving real intersection — not first-token-wins; a disjoint pair
# (is_articulation,is_test) yields empty output with exit 0; an unknown member errors
# exactly like an unknown single predicate (exit 2, naming the offending token).
sel_conj="$(python3 "$ROOT/scripts/build-graph.py" --root "$SELREPO" --select lang=python,no-is_test 2>/dev/null | sort | tr '\n' ' ')"
sel_conj_empty_rc=0
sel_conj_empty="$(python3 "$ROOT/scripts/build-graph.py" --root "$SELREPO" --select is_articulation,is_test 2>/dev/null)" || sel_conj_empty_rc=$?
sel_conj_rc=0; python3 "$ROOT/scripts/build-graph.py" --root "$SELREPO" --select code,bogus >/dev/null 2>"$TMP/sel_conj_err" || sel_conj_rc=$?
if [ "$sel_conj" = "hub.py x.py y.py z.py " ] \
   && [ -z "$sel_conj_empty" ] && [ "$sel_conj_empty_rc" = 0 ] \
   && [ "$sel_conj_rc" = 2 ] && grep -q "unknown --select predicate 'bogus'" "$TMP/sel_conj_err"; then
  ok "build-graph --select ANDs comma conjunctions; empty intersection exits 0; unknown member exits 2"
else
  bad "build-graph --select conjunction wrong (conj=[$sel_conj] empty=[$sel_conj_empty] rc=$sel_conj_rc emptyrc=$sel_conj_empty_rc)"
fi

# --- Test 11c2j4: --select -z/--print0 NUL-delimits paths (xargs -0 interop) --------
# A target repo with spaces/newlines in tracked paths breaks newline pipelines — the
# same class the builder's own `git ls-files -z` enumeration guards. -z must yield the
# same path set as the newline form (NUL separators only), and a -z without --select
# must leave the JSON mode byte-identical.
sel_z="$(python3 "$ROOT/scripts/build-graph.py" --root "$SELREPO" --select lang=python -z 2>/dev/null | tr '\0' '\n' | sort | tr '\n' ' ')"
sel_nl="$(python3 "$ROOT/scripts/build-graph.py" --root "$SELREPO" --select lang=python 2>/dev/null | sort | tr '\n' ' ')"
json_plain="$(python3 "$ROOT/scripts/build-graph.py" --root "$SELREPO" 2>/dev/null | grep -v '"built_at"' | python3 -c 'import hashlib,sys;print(hashlib.sha256(sys.stdin.buffer.read()).hexdigest())')"
json_z="$(python3 "$ROOT/scripts/build-graph.py" --root "$SELREPO" -z 2>/dev/null | grep -v '"built_at"' | python3 -c 'import hashlib,sys;print(hashlib.sha256(sys.stdin.buffer.read()).hexdigest())')"
if [ "$sel_z" = "$sel_nl" ] && [ -n "$sel_z" ] && [ "$json_plain" = "$json_z" ]; then
  ok "build-graph --select -z NUL-delimits the same path set; -z without --select leaves JSON identical"
else
  bad "build-graph --select -z wrong (z=[$sel_z] nl=[$sel_nl] json_same=$([ "$json_plain" = "$json_z" ] && echo y || echo n))"
fi

# --- Test 11c2k: --select code (branch_count>0) and never-audited predicates --------
# Two predicate branches of to_select the cases above never reach. `code` selects nodes
# carrying real code (branch_count>0); `never-audited` selects nodes whose last_audited_sha
# is still null. Both were untested (inverting either kept the suite green).
sel_code="$(python3 "$ROOT/scripts/build-graph.py" --root "$SELREPO" --select code 2>/dev/null)"
# fresh build: nothing audited yet, so never-audited returns every node
sel_never_fresh="$(python3 "$ROOT/scripts/build-graph.py" --root "$SELREPO" --select never-audited 2>/dev/null | sort | tr '\n' ' ')"
# stamp hub.py as audited via a --prior graph (the 11b pattern); never-audited then drops it
python3 "$ROOT/scripts/build-graph.py" --root "$SELREPO" > "$TMP/sel_g.json" 2>/dev/null
python3 - "$TMP/sel_g.json" <<'PY'
import json, sys
g = json.load(open(sys.argv[1]))
g["nodes"]["hub.py"]["last_audited_sha"] = g["graph_built_at_sha"]
json.dump(g, open(sys.argv[1], "w"))
PY
sel_never_stamped="$(python3 "$ROOT/scripts/build-graph.py" --root "$SELREPO" --prior "$TMP/sel_g.json" --select never-audited 2>/dev/null)"
if printf '%s' "$sel_code" | grep -qx "hub.py" \
   && ! printf '%s' "$sel_code" | grep -qx "x.py" \
   && [ "$sel_never_fresh" = "hub.py test_hub.py x.py y.py z.py " ] \
   && ! printf '%s' "$sel_never_stamped" | grep -qx "hub.py" \
   && printf '%s' "$sel_never_stamped" | grep -qx "x.py"; then
  ok "build-graph --select code (branch>0) and never-audited (null last_audited_sha) filter correctly"
else
  bad "build-graph --select code/never-audited wrong (code=[$sel_code] fresh=[$sel_never_fresh] stamped=[$sel_never_stamped])"
fi

# --- Test 11c2k2: --select stale-audited (stamped before HEAD — the graded frontier bin) --
# Reuses 11c2k's $TMP/sel_g.json (hub.py stamped at the then-HEAD): advance SELREPO by one
# commit so that stamp lags HEAD by exactly 1, then rebuild with --prior. stale-audited must
# yield exactly hub.py (age 1, never the age-0/never-audited nodes), never-audited must
# still exclude hub.py (a reachable stamp is not "never"), the predicate must compose in a
# conjunction, and on a fresh stamp-less build it must yield empty output with exit 0.
printf 'touch\n' >> "$SELREPO/x.py"
git -C "$SELREPO" add -A && git -C "$SELREPO" -c user.name=t -c user.email=t@e.com commit -qm second
sel_stale="$(python3 "$ROOT/scripts/build-graph.py" --root "$SELREPO" --prior "$TMP/sel_g.json" --select stale-audited 2>/dev/null)"
sel_stale_conj="$(python3 "$ROOT/scripts/build-graph.py" --root "$SELREPO" --prior "$TMP/sel_g.json" --select stale-audited,lang=python 2>/dev/null)"
sel_stale_fresh_rc=0
sel_stale_fresh="$(python3 "$ROOT/scripts/build-graph.py" --root "$SELREPO" --select stale-audited 2>/dev/null)" || sel_stale_fresh_rc=$?
if printf '%s' "$sel_stale" | grep -qx "hub.py" \
   && [ "$(printf '%s\n' "$sel_stale" | grep -c .)" = 1 ] \
   && [ "$sel_stale_conj" = "hub.py" ] \
   && [ -z "$sel_stale_fresh" ] && [ "$sel_stale_fresh_rc" = 0 ]; then
  ok "build-graph --select stale-audited isolates stamped-before-HEAD nodes (composes; fresh build empty, exit 0)"
else
  bad "build-graph --select stale-audited wrong (stale=[$sel_stale] conj=[$sel_stale_conj] fresh=[$sel_stale_fresh] rc=$sel_stale_fresh_rc)"
fi

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

# --- Test 11c4: covered_by_test via change-coupling alone (test co-changes, no import)
# build-graph.py:1073-1078 also marks a source covered when a *test* node co-changes with
# it strongly (cooccur >= 3) even with NO import between them — a real scenario (a bash
# behavioural test that exercises but never `source`s its target). Every other
# covered_by_test==True assertion (11c3) reaches its subject by import, so this coupling-only
# branch was unexercised. Control: a source coupled only to a NON-test file stays uncovered,
# proving it is the test-membership of the edge that covers, not coupling per se.
CPCOV="$TMP/cpcov"; mkdir -p "$CPCOV"; git -C "$CPCOV" init -q
printf 'def helper(x):\n    return x + 1\n' > "$CPCOV/lib2.py"        # source, imports nothing
printf 'def test_x():\n    assert True\n'    > "$CPCOV/test_thing.py"  # test, imports nothing
printf 'def widget():\n    return 0\n'       > "$CPCOV/solo.py"        # source coupled to a doc
printf '# notes\n'                           > "$CPCOV/notes.md"       # non-test coupling partner
git -C "$CPCOV" add -A
git -C "$CPCOV" -c user.name=t -c user.email=t@e.com commit -qm init
# co-change lib2<->test_thing and solo<->notes in SEPARATE commits, three times each, so each
# strong pair clears cooccur>=3 while the cross pairs (e.g. solo<->test) stay at 1 (init only).
for i in 1 2 3; do
  echo "e$i" >> "$CPCOV/lib2.py"; echo "e$i" >> "$CPCOV/test_thing.py"
  git -C "$CPCOV" add -A
  git -C "$CPCOV" -c user.name=t -c user.email=t@e.com commit -qm "lib2/test co $i"
  echo "e$i" >> "$CPCOV/solo.py"; echo "e$i" >> "$CPCOV/notes.md"
  git -C "$CPCOV" add -A
  git -C "$CPCOV" -c user.name=t -c user.email=t@e.com commit -qm "solo/notes co $i"
done
cpcov_out="$TMP/cpcov_graph.json"
python3 "$ROOT/scripts/build-graph.py" --root "$CPCOV" > "$cpcov_out" 2>/dev/null
if python3 - "$cpcov_out" <<'PY' 2>/dev/null
import json, sys
g = json.load(open(sys.argv[1])); n = g["nodes"]
assert n["test_thing.py"]["is_test"] is True, n["test_thing.py"]
# the pair has a strong coupling edge AND no import edge either way -> coupling-only path
assert "lib2.py" not in n["test_thing.py"]["imports"] and "test_thing.py" not in n["lib2.py"]["imports"], "fixture must have no import edge between the pair"
edge = [e for e in g["coupling_edges"] if {e["a"], e["b"]} == {"lib2.py", "test_thing.py"}]
assert edge and edge[0]["cooccur"] >= 3, "lib2/test coupling edge missing"
# payoff: lib2.py is covered purely via change-coupling to a test
assert n["lib2.py"]["covered_by_test"] is True, "coupling to a test must mark the source covered"
# control: solo.py couples only to a non-test doc, so it stays uncovered
assert n["solo.py"]["covered_by_test"] is False, "coupling to a non-test must NOT cover"
PY
then ok "build-graph.py covers a source via change-coupling to a test alone (no import edge)"; else bad "build-graph.py coupling-only covered_by_test routing wrong"; fi

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
# C header extensions that are include targets (C_HEADER_EXTS) must also route as C, not
# "unknown" — otherwise a resolved .h++/.cuh/.tcc/.ipp/.inc node carries no defines/branch.
for ext in ("h++", "cuh", "tcc", "ipp", "inc"):
    assert ("." + ext) in bg.C_HEADER_EXTS, ext            # guard: still an include target
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

# --- Test 11c2: shebang interpreter detection is basename-exact, not substring ---------
# An extension-less script is classified by its shebang. The old `b"sh" in first` substring
# test swept any interpreter whose name merely contains "sh" (fish, wish, csh, tcsh) into
# bash; lang_of must now match the interpreter basename so only genuine sh-family shells
# (sh/bash/dash/zsh, incl. env-wrapped) map to bash, while the extension still wins when set.
if python3 -B - "$ROOT/scripts/build-graph.py" <<'PY' 2>/dev/null
import importlib.util, sys
spec = importlib.util.spec_from_file_location("bg", sys.argv[1])
bg = importlib.util.module_from_spec(spec); spec.loader.exec_module(bg)
for sb in (b"#!/bin/sh\n", b"#!/bin/bash\n", b"#!/usr/bin/env bash\n",
           b"#!/bin/dash\n", b"#!/bin/zsh\n", b"#!/usr/bin/env -S bash -e\n"):
    assert bg.lang_of("hook", sb) == "bash", sb
for sb in (b"#!/usr/bin/env fish\n", b"#!/bin/csh\n", b"#!/usr/bin/wish\n", b"#!/bin/tcsh\n"):
    assert bg.lang_of("hook", sb) != "bash", sb
for sb in (b"#!/usr/bin/python\n", b"#!/usr/bin/env python3\n", b"#!/usr/bin/python3.11\n"):
    assert bg.lang_of("hook", sb) == "python", sb
assert bg.lang_of("x.sh", b"#!/usr/bin/env fish\n") == "bash"   # extension still wins
PY
then ok "lang_of shebang detection is basename-exact (fish/csh/wish are not bash)"; else bad "lang_of shebang detection misclassifies a non-sh interpreter as bash"; fi

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

# --- Test 11d3b: a leading std/core/alloc crate root must NOT forge a false edge ------
# resolve_rust_import drops an external stdlib import (`use std::io::Read;`) rather than
# stripping the crate root and probing the rest, which would link to an unrelated local
# module of the same name (here src/io.rs). A genuine intra-crate `use crate::io::...`
# against the same fileset must still resolve. Guards the import graph that centrality /
# articulation / cycle / dirty-set routing all consume.
if python3 - "$ROOT/scripts/build-graph.py" <<'PY' 2>/dev/null
import importlib.util, sys
spec = importlib.util.spec_from_file_location("bg", sys.argv[1])
bg = importlib.util.module_from_spec(spec); spec.loader.exec_module(bg)
fs = {"src/main.rs", "src/io.rs"}
# external stdlib roots collide with a same-named local module -> must drop (no edge)
for use in ("use std::io::Read;", "use core::ptr::null;", "use alloc::vec::Vec;"):
    coll = {"src/main.rs", "src/" + use.split("::")[0].split()[1] + ".rs"}
    assert bg.imports_of("rust", use, "src/main.rs", coll) == [], (use, bg.imports_of("rust", use, "src/main.rs", coll))
# the std collision specifically must not link to src/io.rs
assert bg.imports_of("rust", "use std::io::Read;", "src/main.rs", fs) == [], "std::io forged an edge"
# a genuine intra-crate use of a local `io` module still resolves
assert bg.imports_of("rust", "use crate::io::Read;", "src/main.rs", fs) == ["src/io.rs"], "crate::io must resolve"
PY
then ok "build-graph.py drops a stdlib Rust import instead of forging a false local edge"; else bad "build-graph.py forged a false Rust edge for a stdlib crate root"; fi

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

# --- Test 11d6: nested Go sub-modules resolve against the NEAREST go.mod --------
# A Go monorepo can carry several go.mod files. Each .go file must resolve its imports
# against its own (deepest enclosing) module, and a package path is relative to THAT
# module's directory. Cross-module imports (a file in module 'a' importing module 'b')
# drop, like any non-intra-module path.
if python3 -B - "$ROOT/scripts/build-graph.py" <<'PY' 2>/dev/null
import importlib.util, sys
spec = importlib.util.spec_from_file_location("bg", sys.argv[1])
bg = importlib.util.module_from_spec(spec); spec.loader.exec_module(bg)
fs = {"go.mod", "root.go", "shared/s.go",
      "svcA/go.mod", "svcA/main.go", "svcA/util/u.go",
      "svcB/go.mod", "svcB/main.go", "svcB/util/u.go"}
mods = [("", "root"), ("svcA", "a"), ("svcB", "b")]
# nearest_go_module picks the deepest enclosing module
assert bg.nearest_go_module("svcA/util/u.go", mods) == ("svcA", "a"), "nearest = a"
assert bg.nearest_go_module("svcB/main.go", mods) == ("svcB", "b"), "nearest = b"
assert bg.nearest_go_module("root.go", mods) == ("", "root"), "nearest = root"
# each sub-module resolves its own intra-module import (path relative to its go.mod dir)
assert bg.imports_of("go", 'import "a/util"\n', "svcA/main.go", fs, mods) == ["svcA/util/u.go"], "a/util"
assert bg.imports_of("go", 'import "b/util"\n', "svcB/main.go", fs, mods) == ["svcB/util/u.go"], "b/util"
# root module resolves against the repo root
assert bg.imports_of("go", 'import "root/shared"\n', "root.go", fs, mods) == ["shared/s.go"], "root/shared"
# cross-module import drops: a file in module 'a' importing 'b/util' does not match 'a'
assert bg.imports_of("go", 'import "b/util"\n', "svcA/main.go", fs, mods) == [], "cross-module drops"
PY
then ok "build-graph.py resolves nested Go sub-modules against the nearest go.mod"; else bad "nested Go go.mod resolution wrong (module selection or relative package dir)"; fi

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
# (c) deleted SOURCE file (not build-config): a surviving importer must go dirty via the
# incremental impacted-seeding path, NOT whole_graph — exercising build()->compute_dirty
# end-to-end. The unit test pins compute_dirty directly with hand-built dicts; the shell
# tests above only cover the build-config deletion that short-circuits to whole_graph, so
# the full-pipeline source-deletion wiring was never integration-tested.
SDREPO="$TMP/srcdel"; mkdir -p "$SDREPO"
git -C "$SDREPO" init -q
sdgc() { git -C "$SDREPO" -c user.name=t -c user.email=t@e.com commit -q "$@"; }
printf '# a\n[see b](b.md)\n' > "$SDREPO/a.md"   # a.md imports b.md (markdown link edge)
printf '# b\n' > "$SDREPO/b.md"
printf '# c\n' > "$SDREPO/c.md"                  # unrelated, must stay clean
git -C "$SDREPO" add -A; sdgc -m init
sd_prior="$TMP/sd_prior.json"
python3 "$ROOT/scripts/build-graph.py" --root "$SDREPO" > "$sd_prior" 2>/dev/null
git -C "$SDREPO" rm -q b.md; sdgc -m "drop b"
sd_del="$TMP/sd_del.json"
python3 "$ROOT/scripts/build-graph.py" --root "$SDREPO" --prior "$sd_prior" > "$sd_del" 2>/dev/null
if python3 - "$sd_prior" "$sd_del" <<'PY' 2>/dev/null
import json, sys
prior = json.load(open(sys.argv[1]))
assert prior["nodes"]["a.md"]["imports"] == ["b.md"], prior["nodes"]["a.md"]  # edge must exist
d = json.load(open(sys.argv[2]))["dirty"]
assert d["whole_graph"] is False, d                 # incremental path, not whole-graph
assert d["reason"] == "incremental", d
assert d["changed"] == [], d                        # a.md/c.md bytes unchanged
assert "a.md" in d["nodes"], d                       # importer of deleted b.md re-audited
assert "c.md" not in d["nodes"], d                   # unrelated file stays clean
PY
then ok "source-file deletion marks its surviving importer dirty end-to-end (incremental, not whole-graph)"; else bad "deleted source file did not seed its importer into the incremental dirty set"; fi

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
# quoted source targets resolve identically to their unquoted form (the dominant
# idiom `. "$HERE/lib.sh"` / `source 'lib.sh'`); the surrounding quote pair must
# be stripped before the basename fallback runs.
assert bg.imports_of("bash", 'source "common.sh"\n', "scripts/main.sh", fs) == ["lib/common.sh"], "double-quoted source"
assert bg.imports_of("bash", "source 'common.sh'\n", "scripts/main.sh", fs) == ["lib/common.sh"], "single-quoted source"
assert bg.imports_of("bash", '. "$HERE/common.sh"\n', "scripts/main.sh", fs) == ["lib/common.sh"], "quoted \$DIR/lib.sh basename fallback"
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

# --- Test 11o2: JS/TS path aliases resolve against the NEAREST-ENCLOSING tsconfig, so a
# nested-package monorepo (packages/app/tsconfig.json) is not misrouted by a root-only scan.
# imports_of accepts the multi-config list form [(cfg_dir, (base_dir, patterns)), ...] and picks
# the deepest config enclosing each file (nearest_ts_config), mirroring the go.mod nearest-module
# rule. A root file still resolves the root alias; a packages/app file resolves its OWN @app alias
# (which the root config does not define) — the exact case the old first-config-wins scan dropped.
if python3 -B - "$ROOT/scripts/build-graph.py" <<'PY' 2>/dev/null
import importlib.util, sys
spec = importlib.util.spec_from_file_location("bg", sys.argv[1])
bg = importlib.util.module_from_spec(spec); spec.loader.exec_module(bg)
js = {"src/root.ts", "src/shared.ts", "packages/app/src/main.ts", "packages/app/src/util.ts"}
ts_configs = [
    ("", ("src", [("@root/*", ["./*"])])),                              # root: @root/x -> src/x
    ("packages/app", ("packages/app/src", [("@app/*", ["./*"])])),      # nested: @app/x -> packages/app/src/x
]
ji = lambda src, frm: bg.imports_of("js", src, frm, js, None, ts_configs)
# a nested-package file resolves its own (nested) @app alias — dropped by a root-only scan
assert ji('import {u} from "@app/util"\n', "packages/app/src/main.ts") == ["packages/app/src/util.ts"], \
    "nested @app alias must resolve against packages/app/tsconfig.json"
# the root alias still resolves for a root-level file
assert ji('import {s} from "@root/shared"\n', "src/root.ts") == ["src/shared.ts"], "root alias still resolves"
# a nested file does NOT see the root @root alias as its own (nearest-enclosing, not merged)
assert ji('import {s} from "@root/shared"\n', "packages/app/src/main.ts") == [], \
    "nested file resolves only its nearest config, not the root alias"
# nearest_ts_config picks the deepest enclosing config directly
assert bg.nearest_ts_config("packages/app/src/main.ts", ts_configs)[0] == "packages/app/src", "deepest config wins"
assert bg.nearest_ts_config("src/root.ts", ts_configs)[0] == "src", "root config for a root file"
PY
then ok "build-graph.py resolves JS/TS aliases against the nearest-enclosing tsconfig (monorepo-aware)"; else bad "nested tsconfig alias resolution broke (monorepo misroute or root regression)"; fi

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

# --- Test 11q: TypeScript/JS tsconfig compilerOptions.paths alias resolution ----
# A bare specifier is normally node_modules and drops, but a tsconfig `paths` alias
# (with an optional baseUrl and a `*` wildcard) maps it to a repo file. JSONC tolerance
# (comments, trailing commas) must not break the parse.
if python3 -B - "$ROOT/scripts/build-graph.py" <<'PY' 2>/dev/null
import importlib.util, os, shutil, sys, tempfile
spec = importlib.util.spec_from_file_location("bg", sys.argv[1])
bg = importlib.util.module_from_spec(spec); spec.loader.exec_module(bg)
fs = {"src/app/util.ts", "src/app/m/index.ts", "src/lib/index.ts", "src/a.ts"}
ts = ("", [("@app/*", ["src/app/*"]), ("@lib", ["src/lib/index.ts"])])
ri = lambda t, frm=("src/a.ts"): bg.resolve_js_import(t, frm, fs, ts)
assert ri("@app/util") == "src/app/util.ts", "wildcard alias -> .ts"
assert ri("@app/m") == "src/app/m/index.ts", "wildcard alias -> dir index"
assert ri("@lib") == "src/lib/index.ts", "exact (non-wildcard) alias"
assert ri("react") is None, "unaliased bare specifier still drops"
assert ri("./app/util", "src/x.ts") == "src/app/util.ts", "relative import unaffected by aliases"
# baseUrl is applied to replacements
ts2 = ("src", [("@/*", ["*"])])
assert bg.resolve_js_import("@/app/util", "src/a.ts", fs, ts2) == "src/app/util.ts", "baseUrl applied"
# parse_tsconfig tolerates JSONC (line + block comments, trailing comma)
d = tempfile.mkdtemp()
try:
    open(os.path.join(d, "tsconfig.json"), "w").write(
        '{\n  // editor hint\n  "compilerOptions": {\n'
        '    "baseUrl": "src",\n'
        '    "paths": { "@app/*": ["app/*"], } /* aliases */\n  }\n}\n')
    assert bg.parse_tsconfig(os.path.join(d, "tsconfig.json"), "") == ("src", [("@app/*", ["app/*"])]), "JSONC parse"
finally:
    shutil.rmtree(d, ignore_errors=True)
PY
then ok "build-graph.py resolves tsconfig paths aliases (wildcard, exact, baseUrl; JSONC-tolerant)"; else bad "tsconfig paths alias resolution wrong (apply_ts_aliases / parse_tsconfig)"; fi

# --- Test 11q2: aliases resolve from a NON-default tsconfig name (monorepo) ------
# build() discovers `paths` from tsconfig.base.json/app.json, not just tsconfig.json,
# and falls through a tsconfig.json that carries no paths (the `extends` monorepo
# layout). End-to-end: the alias lives only in tsconfig.base.json (commit d868d5e).
TSBREPO="$TMP/tsbase_repo"
mkdir -p "$TSBREPO/src/app"
git -C "$TSBREPO" init -q
printf 'import { x } from "@app/util";\nexport const y = x;\n' > "$TSBREPO/src/a.ts"
printf 'export const x = 1;\n' > "$TSBREPO/src/app/util.ts"
# tsconfig.json present but WITHOUT paths -> parse returns None -> fall through.
printf '{ "compilerOptions": { "strict": true } }\n' > "$TSBREPO/tsconfig.json"
# the alias is defined only in the non-default base config.
printf '{ "compilerOptions": { "paths": { "@app/*": ["src/app/*"] } } }\n' > "$TSBREPO/tsconfig.base.json"
git -C "$TSBREPO" add -A
git -C "$TSBREPO" -c user.name=t -c user.email=t@e.com commit -qm init
tsb_out="$TMP/tsbase_graph.json"
python3 "$ROOT/scripts/build-graph.py" --root "$TSBREPO" > "$tsb_out" 2>/dev/null
if python3 - "$tsb_out" <<'PY' 2>/dev/null
import json, sys
g = json.load(open(sys.argv[1]))
imports = g["nodes"]["src/a.ts"].get("imports", [])
assert "src/app/util.ts" in imports, imports
PY
then ok "build-graph.py resolves tsconfig paths aliases from a non-default name (tsconfig.base.json)"; else bad "non-default tsconfig name alias resolution wrong (build() name list)"; fi

# --- Test 11r: C/C++ angle includes resolve against -I include roots -----------
# `#include <project/foo.h>` reaches a header through an -I include root, so it resolves
# to a unique repo file ending in that sub-path. System headers must never forge an edge:
# extensionless ones (<vector>) are skipped, and a slashed system header (<sys/types.h>)
# resolves strictly (no basename fallback) so it cannot link to an unrelated repo types.h.
if python3 -B - "$ROOT/scripts/build-graph.py" <<'PY' 2>/dev/null
import importlib.util, sys
spec = importlib.util.spec_from_file_location("bg", sys.argv[1])
bg = importlib.util.module_from_spec(spec); spec.loader.exec_module(bg)
fs = {"src/main.c", "include/project/foo.h", "include/bar.h"}
ci = lambda s: bg.imports_of("c", s, "src/main.c", fs)
assert ci('#include <project/foo.h>\n') == ["include/project/foo.h"], "angle via include root"
assert ci('#include <bar.h>\n') == ["include/bar.h"], "angle header-ext basename -> include root"
assert ci('#include <vector>\n') == [], "extensionless system header skipped"
# a slashed system header that is NOT in the repo must not link to an unrelated types.h
fs2 = {"src/main.c", "src/types.h"}
assert bg.imports_of("c", '#include <sys/types.h>\n', "src/main.c", fs2) == [], "no false system-header edge"
# ambiguous angle sub-path (two include roots) drops rather than guessing
fs3 = {"src/main.c", "a/project/foo.h", "b/project/foo.h"}
assert bg.imports_of("c", '#include <project/foo.h>\n', "src/main.c", fs3) == [], "ambiguous angle drops"
# quoted includes are unaffected (basename fallback still resolves the project header)
assert bg.imports_of("c", '#include "foo.h"\n', "src/main.c", {"src/main.c", "src/foo.h"}) == ["src/foo.h"], "quoted unchanged"
# both styles in one file resolve together
two = '#include "bar.h"\n#include <project/foo.h>\n'
assert set(ci(two)) == {"include/bar.h", "include/project/foo.h"}, ci(two)
# a dotfile header <.config.h> must keep its leading dot, not strip it as a char set
# and forge an edge to an unrelated config.h (regression: lstrip("./") stripped the dot)
fs4 = {"src/main.c", "include/config.h"}
assert bg.imports_of("c", '#include <.config.h>\n', "src/main.c", fs4) == [], "dotfile angle header must not forge edge to stripped-name file"
# a genuine leading "./" is still stripped so the header resolves through its include root
assert ci('#include <./project/foo.h>\n') == ["include/project/foo.h"], "leading ./ still resolves"
PY
then ok "build-graph.py resolves C/C++ angle includes via include roots (system headers excluded)"; else bad "C angle-include resolution wrong (resolve_c_angle / system-header leak)"; fi

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

# --- Test 11s: coupling_pairs caps bulk commits (limits git-log O(F^2) blowup) ----
if python3 - "$ROOT/scripts/build-graph.py" <<'PY' 2>/dev/null
import importlib.util, sys
spec = importlib.util.spec_from_file_location("bg", sys.argv[1])
bg = importlib.util.module_from_spec(spec); spec.loader.exec_module(bg)
# a normal (under-cap) commit yields its pair; repeats accumulate
assert bg.coupling_pairs([{"a", "b"}], max_files_per_commit=10) == {("a", "b"): 1}
assert bg.coupling_pairs([{"a", "b"}, {"a", "b"}], max_files_per_commit=10) == {("a", "b"): 2}
# a bulk commit (over cap) is skipped entirely — no O(F^2) pair explosion
big = {f"f{i}" for i in range(50)}
assert bg.coupling_pairs([big], max_files_per_commit=10) == {}
# the cap is per-commit: a bulk commit is dropped while small ones still count
assert bg.coupling_pairs([big, {"a", "b"}], max_files_per_commit=10) == {("a", "b"): 1}
PY
then ok "coupling_pairs skips bulk commits over the per-commit cap (limits git-log blowup)"; else bad "coupling_pairs did not cap bulk commits"; fi

# --- Test 11t: sh() enforces a timeout so a wedged git cannot hang the build -------
if python3 - "$ROOT/scripts/build-graph.py" <<'PY' 2>/dev/null
import importlib.util, subprocess, sys
spec = importlib.util.spec_from_file_location("bg", sys.argv[1])
bg = importlib.util.module_from_spec(spec); spec.loader.exec_module(bg)
# a fast command completes within the (generous) default timeout
assert bg.sh(["true"], ".") == ""
# a slow command must hit the timeout override and raise (not hang forever)
try:
    bg.sh(["sleep", "3"], ".", timeout=1)
except subprocess.TimeoutExpired:
    pass
else:
    sys.exit(1)
PY
then ok "sh() times out a wedged subprocess instead of hanging the build"; else bad "sh() did not enforce its timeout"; fi

# --- Test 11u: build-graph.py degrades cleanly when the git binary is absent -------
# A missing git raises FileNotFoundError (OSError, not SubprocessError); main() catches
# OSError and exits non-zero with a diagnostic instead of a raw traceback (commit
# d8ace75). Run the builder with a PATH that has python3 but no git.
GITLESS="$TMP/gitless_bin"
mkdir -p "$GITLESS"
ln -sf "$(command -v python3)" "$GITLESS/python3"
ng_rc=0
ng_out="$(cd "$ROOT" && PATH="$GITLESS" "$GITLESS/python3" scripts/build-graph.py --root "$ROOT" 2>&1 >/dev/null)" || ng_rc=$?
if [ "$ng_rc" -ne 0 ] && ! printf '%s' "$ng_out" | grep -q 'Traceback (most recent call last)'; then
  ok "build-graph.py exits non-zero with a diagnostic (not a traceback) when git is absent"
else
  bad "build-graph.py did not degrade cleanly without git (rc=$ng_rc, out=$ng_out)"
fi

# --- Test 11v: a corrupted --prior graph warns on stderr and forces a full rebuild -
# build() warns and falls back to a from-scratch rebuild (prior={} -> dirty.is_first_run)
# when --prior is a non-object or unparseable JSON, instead of silently masking a
# data-integrity problem as a slow clean run (commit 4623724).
NOPRIOR="$TMP/corrupt_nonobject.json"; printf '[]' > "$NOPRIOR"
python3 "$ROOT/scripts/build-graph.py" --root "$ROOT" --prior "$NOPRIOR" 2>"$TMP/cp_no_err.txt" >"$TMP/cp_no_out.json" || true
if grep -qF 'is not a JSON object' "$TMP/cp_no_err.txt" \
   && python3 -c "import json,sys;sys.exit(0 if json.load(open('$TMP/cp_no_out.json'))['dirty']['is_first_run'] else 1)"; then
  ok "build-graph.py warns and rebuilds from a non-object prior graph"
else
  bad "build-graph.py did not warn+rebuild on a non-object prior graph"
fi
BADPRIOR="$TMP/corrupt_unparseable.json"; printf '{{{' > "$BADPRIOR"
python3 "$ROOT/scripts/build-graph.py" --root "$ROOT" --prior "$BADPRIOR" 2>"$TMP/cp_bad_err.txt" >"$TMP/cp_bad_out.json" || true
if grep -qF 'ignoring unreadable prior graph' "$TMP/cp_bad_err.txt" \
   && python3 -c "import json,sys;sys.exit(0 if json.load(open('$TMP/cp_bad_out.json'))['dirty']['is_first_run'] else 1)"; then
  ok "build-graph.py warns and rebuilds from an unparseable prior graph"
else
  bad "build-graph.py did not warn+rebuild on an unparseable prior graph"
fi


# --- Test 11i: build-graph.py does not depend on the external `date` binary --------
# built_at is now stamped via datetime, not a `date` subprocess. Shadow `date` with a
# failing stub on PATH: before the fix sh(["date",...]) aborted the whole build; now it
# is never called, so the build still succeeds with a valid ISO-8601 built_at.
SHADOW="$TMP/datebreak"; mkdir -p "$SHADOW"
printf '#!/bin/sh\nexit 1\n' > "$SHADOW/date"; chmod +x "$SHADOW/date"
db_out="$TMP/datebreak_graph.json"
db_rc=0
PATH="$SHADOW:$PATH" python3 "$ROOT/scripts/build-graph.py" --root "$ROOT" > "$db_out" 2>/dev/null || db_rc=$?
if [ "$db_rc" = 0 ] && python3 -c "
import json, sys, re
d = json.load(open('$db_out'))
sys.exit(0 if re.match(r'\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ\$', d.get('built_at','')) else 1)
" 2>/dev/null; then
  ok "build-graph.py builds with a broken/absent date binary (built_at via datetime)"
else
  bad "build-graph.py still depends on the external date binary (rc=$db_rc)"
fi


# --- Test 11l: build-graph.py rebuilds (not crashes) from a malformed prior ---
# A hand-edited/truncated graph.json whose coupling_edges is a string used to
# crash the incremental rebuild with AttributeError ('str' has no .get) once a
# tracked file was deleted. It must now type-sanitize the prior and rebuild.
MALREPO="$TMP/malprior"
mkdir -p "$MALREPO"
git -C "$MALREPO" init -q
echo "x=1" > "$MALREPO/a.py"; echo "y=2" > "$MALREPO/b.py"
git -C "$MALREPO" add -A
git -C "$MALREPO" -c user.name=t -c user.email=t@e.com commit -qm init
mal_prior="$TMP/mal_prior.json"
python3 "$ROOT/scripts/build-graph.py" --root "$MALREPO" > "$mal_prior" 2>/dev/null
python3 -c "import json;p=json.load(open('$mal_prior'));p['coupling_edges']='garbage';p['graph_built_at_sha']=123;p['nodes']['b.py']='garbage';json.dump(p,open('$mal_prior','w'))"
git -C "$MALREPO" rm -q a.py
git -C "$MALREPO" -c user.name=t -c user.email=t@e.com commit -qm "del a"
mal_rc=0
python3 "$ROOT/scripts/build-graph.py" --root "$MALREPO" --prior "$mal_prior" > "$TMP/mal_out.json" 2>/dev/null || mal_rc=$?
# The coerced-to-None graph_built_at_sha means unknown provenance: the dirty block
# must take the documented "unreachable -> whole rebuild" path, not report a clean
# zero-divergence incremental (which would keep stale incremental state alive).
if [ "$mal_rc" = 0 ] && python3 - "$TMP/mal_out.json" <<'PY'
import json, sys
g = json.load(open(sys.argv[1]))
assert g["nodes"], "no nodes"
d = g["dirty"]
assert d["whole_graph"] is True, d
assert "unreachable" in d["reason"], d["reason"]
# the string-valued prior node entry was dropped (degraded), not crashed on:
# with no usable baseline its rebuilt last_audited_sha is null
assert g["nodes"]["b.py"]["last_audited_sha"] is None, g["nodes"]["b.py"]
PY
then
  ok "build-graph.py type-sanitizes a malformed prior graph and rebuilds whole-graph (unreachable sha)"
else
  bad "build-graph.py malformed-prior rebuild wrong (rc=$mal_rc; expected whole_graph + unreachable reason)"
fi


# --- Test 11m: parse_tsconfig keeps a comma inside a string literal ----------
# The trailing-comma strip used a blanket regex `,(\s*[}\]])`, which also rewrote a
# comma inside a string value like "weird, ]/path" — silently corrupting the alias.
# A string-aware strip must drop the real trailing comma but preserve the in-string one.
TSDIR="$TMP/tsconfig_case"; mkdir -p "$TSDIR"
cat > "$TSDIR/tsconfig.json" <<'JSON'
{
  "compilerOptions": {
    "baseUrl": ".",
    "paths": {
      "@x/*": ["weird, ]/path/*"],
    }
  }
}
JSON
if python3 - "$ROOT/scripts/build-graph.py" "$TSDIR/tsconfig.json" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("bg", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
res = m.parse_tsconfig(sys.argv[2], "")
assert res is not None, "tsconfig with a trailing comma did not parse"
base, patterns = res
repls = dict(patterns)["@x/*"]
# the real trailing comma was stripped (parse succeeded) AND the in-string comma kept
assert repls == ["weird, ]/path/*"], repls
print("TSCONFIG-OK")
PY
then ok "parse_tsconfig strips the trailing comma but preserves a comma inside a string literal"; else bad "parse_tsconfig corrupted a string literal when stripping trailing commas"; fi


# --- Test 11n: defines/defines_at/branch_at share one iter_defines scan -------
# build() now runs iter_defines once per file and derives all three symbol fields
# from it, instead of three separate scans. Pin that the shared-scan helpers return
# exactly what the standalone public functions do (the refactor must be output-neutral).
if python3 - "$ROOT/scripts/build-graph.py" "$ROOT/scripts/status.py" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("bg", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
text = open(sys.argv[2], encoding="utf-8").read()
lang = "python"
defs = list(m.iter_defines(lang, text))
assert m._defines_from_defs(defs) == m.defines_of(lang, text)
assert m._defines_at_from_defs(defs, text) == m.defines_at_of(lang, text)
assert m._branch_at_from_defs(lang, defs, text) == m.branch_at_of(lang, text)
assert m.defines_of(lang, text), "fixture should define some symbols"
print("DEFINES-SHARED-OK")
PY
then ok "build-graph defines/defines_at/branch_at share one iter_defines scan (output-neutral)"; else bad "build-graph shared-defs refactor changed symbol output"; fi


# --- Test 11o: PW_GIT_TIMEOUT_SECONDS overrides the git-call timeout ----------
# The git timeout was hardcoded at 120s; a huge monorepo / slow FS needs to raise it
# without editing code. A valid override is honoured (and surfaced in params); a
# missing/invalid/non-positive value falls back to 120.
gt_ovr="$TMP/gt_override.json"; gt_bad="$TMP/gt_bad.json"; gt_def="$TMP/gt_default.json"
PW_GIT_TIMEOUT_SECONDS=7   python3 "$ROOT/scripts/build-graph.py" --root "$ROOT" > "$gt_ovr" 2>/dev/null
PW_GIT_TIMEOUT_SECONDS=abc python3 "$ROOT/scripts/build-graph.py" --root "$ROOT" > "$gt_bad" 2>/dev/null
python3 "$ROOT/scripts/build-graph.py" --root "$ROOT" > "$gt_def" 2>/dev/null
if [ "$(ver "$gt_ovr" "['params']['git_timeout_seconds']")" = 7 ] \
   && [ "$(ver "$gt_bad" "['params']['git_timeout_seconds']")" = 120 ] \
   && [ "$(ver "$gt_def" "['params']['git_timeout_seconds']")" = 120 ]; then
  ok "build-graph honours PW_GIT_TIMEOUT_SECONDS (valid override; invalid/absent -> 120)"
else
  bad "build-graph PW_GIT_TIMEOUT_SECONDS override not honoured"
fi


# --- Test 11p: pagerank stops on convergence, not a fixed 50 iterations -------
# pagerank ran a hardcoded 50 iterations; it now breaks once the rank vector settles
# (L1 delta < tol), with iters as a safety cap. The early-exit must reach the SAME
# fixpoint as a high iteration count (so ranking order is unchanged), and the default
# must equal an explicit large-iters run.
if python3 - "$ROOT/scripts/build-graph.py" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("bg", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
# an asymmetric graph whose PR is non-uniform, so convergence is non-trivial
nodes = ["a", "b", "c", "d"]
edges = {"a": ["b", "c"], "b": ["c"], "c": ["a"], "d": ["c"]}
conv = m.pagerank(nodes, edges)               # default: stops early on convergence
big = m.pagerank(nodes, edges, iters=1000)    # effectively the fixpoint
assert all(abs(conv[f] - big[f]) < 1e-9 for f in nodes), (conv, big)
assert abs(sum(conv.values()) - 1.0) < 1e-6, sum(conv.values())
# non-uniform: the converged ranks are not all equal (a real ranking signal)
assert max(conv.values()) - min(conv.values()) > 1e-3, conv
# a hard cap of 1 iteration must NOT yet equal the fixpoint (proves it iterates)
one = m.pagerank(nodes, edges, iters=1)
assert any(abs(one[f] - conv[f]) > 1e-6 for f in nodes), "converged in a single pass?"
print("PAGERANK-CONVERGE-OK")
PY
then ok "pagerank converges to the fixed-iteration fixpoint and stops early (stable ranking)"; else bad "pagerank convergence changed the result or did not converge"; fi


# --- Test 11q: a non-ASCII tracked filename builds, not aborts ----------------
# With git's default core.quotepath=true, `git ls-files` C-quotes non-ASCII paths
# ("na\303\257ve.md"); consuming that quoted name verbatim made every later stat
# on it raise FileNotFoundError, which the OSError handler converted into a
# misleading "is git installed?" abort for the WHOLE build. Enumeration now runs
# NUL-delimited with core.quotepath=off, so the node is graphed verbatim.
NAREPO="$TMP/nonascii_repo"
mkdir -p "$NAREPO"
git -C "$NAREPO" init -q
printf '# doc\n' > "$NAREPO/naïve.md"
printf 'def f():\n    return 1\n' > "$NAREPO/a.py"
git -C "$NAREPO" add -A
git -C "$NAREPO" -c user.name=t -c user.email=t@e.com commit -qm init
printf 'more\n' >> "$NAREPO/naïve.md"
git -C "$NAREPO" add -A
git -C "$NAREPO" -c user.name=t -c user.email=t@e.com commit -qm second
na_out="$TMP/nonascii_graph.json"
if python3 "$ROOT/scripts/build-graph.py" --root "$NAREPO" > "$na_out" 2>"$TMP/nonascii_err" \
   && python3 - "$na_out" <<'PY' 2>/dev/null
import json, sys
g = json.load(open(sys.argv[1]))
n = g["nodes"]["naïve.md"]
assert n["lang"] == "markdown", n["lang"]
assert n["loc"] >= 1, n["loc"]
# churn from the second commit proves git-log paths also arrive unquoted
assert n["git_churn"] >= 2, n["git_churn"]
PY
then ok "build-graph graphs a non-ASCII tracked filename (no quotepath abort)"; else bad "build-graph aborts or misgraphs a non-ASCII tracked filename: $(head -c 200 "$TMP/nonascii_err" 2>/dev/null)"; fi


# --- Test 11c2f: a leading ./ in --scope resolves like the bare spec --------------
# git ls-files paths carry no "./" prefix, so `--scope ./src/` used to be a silent
# false no-match (empty Focus for an existing directory). resolve_scope now strips
# the prefix; a genuinely missing path must still come back empty.
sc_dot="$TMP/scope_dot.json"
python3 "$ROOT/scripts/build-graph.py" --root "$SCREPO" --scope ./src/ > "$sc_dot" 2>/dev/null
if python3 - "$sc_dot" <<'PY' 2>/dev/null
import json, sys
g = json.load(open(sys.argv[1]))
assert g["focus"] == ["src/api.sh", "src/auth.sh"], g["focus"]
PY
then ok "--scope ./src/ resolves identically to --scope src/ (leading ./ normalized)"; else bad "--scope with a leading ./ still yields a false no-match"; fi


# --- Test 11c2g: --scope . is the whole-repo Focus; .//src/ equals src/ -------------
# "." and "./" (the most habitual whole-tree specs, cf. `git add .`) reduced to a
# spec that matched nothing, surfacing as a hard "matched no files" error for the
# repo root; ".//src" normalized into a leading-slash miss. normpath collapses all
# the habitual spellings; a genuinely missing path must still come back empty.
sc_dotall="$TMP/scope_dotall.json"; sc_dslash="$TMP/scope_dslash.json"
python3 "$ROOT/scripts/build-graph.py" --root "$SCREPO" --scope . > "$sc_dotall" 2>/dev/null
python3 "$ROOT/scripts/build-graph.py" --root "$SCREPO" --scope .//src/ > "$sc_dslash" 2>/dev/null
if python3 - "$sc_dotall" "$sc_dslash" <<'PY' 2>/dev/null
import json, sys
whole = json.load(open(sys.argv[1]))
assert sorted(whole["focus"]) == sorted(whole["nodes"].keys()), whole["focus"]
dslash = json.load(open(sys.argv[2]))
assert dslash["focus"] == ["src/api.sh", "src/auth.sh"], dslash["focus"]
PY
then ok "--scope . yields the whole-repo Focus and .//src/ resolves like src/"; else bad "--scope . or .//src/ still false no-matches"; fi
