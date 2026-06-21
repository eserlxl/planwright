# SPDX-FileCopyrightText: 2026 Eser KUBALI
# SPDX-License-Identifier: GPL-3.0-or-later
#
# scripts/dashboard/vendor/derive.js — the PW_DERIVE pure-metrics engine.
# Sourced by tests/run.sh after tests/lib.sh — NOT standalone (uses ROOT/TMP/ok/bad).
#
# The dashboard's risk/coverage/coupling numbers are all computed in derive.js, but the
# dashboard.sh case only fetches each view over HTTP and string-matches its registration
# — nothing executes the engine. This case does. It is JS-only, so it is gated on `node`
# exactly the way statics-scaffold.sh gates its shellcheck checks: a clean skip when node
# is absent (CI runs Python + shellcheck only) keeps the suite green everywhere, while a
# local run really exercises pctRank/quantile/metrics.
#
# shellcheck shell=bash

# --- Test DRV1: PW_DERIVE pctRank/quantile/metrics behave as documented ----
if command -v node >/dev/null 2>&1; then
  cat > "$TMP/derive_test.js" <<'JS'
const fs = require("fs");
const vm = require("vm");
const assert = require("assert");

// derive.js is a browser IIFE that publishes window.PW_DERIVE; shim window and run it
// in this global context so the publish lands on global.window (no DOM is touched).
global.window = {};
vm.runInThisContext(fs.readFileSync(process.argv[2], "utf8"));
const D = global.window.PW_DERIVE;
assert(D && typeof D.metrics === "function", "PW_DERIVE.metrics missing");

// percentile helpers
assert.strictEqual(D.pctRank([5], 5), 0, "pctRank singleton -> 0");
assert.strictEqual(D.pctRank([], 0), 0, "pctRank empty -> 0");
assert(Math.abs(D.pctRank([1, 2, 3, 4], 3) - 2 / 3) < 1e-9, "pctRank rank");
assert.strictEqual(D.quantile([10, 20, 30, 40], 0.5), 20, "quantile median");
assert.strictEqual(D.quantile([], 0.5), 0, "quantile empty -> 0");

// degenerate inputs degrade to null (callers show a "graph not built" state)
assert.strictEqual(D.metrics(null), null, "metrics(null) -> null");
assert.strictEqual(D.metrics("@@ not json"), null, "metrics(bad json) -> null");
assert.strictEqual(D.metrics('{"nodes":{}}'), null, "metrics(no nodes) -> null");

// a real two-node graph: hot.py dominates both churn and pagerank, cold.py is covered
const g = JSON.stringify({
  graph_built_at_sha: "deadbeef",
  nodes: {
    "hot.py":  { git_churn: 10, pagerank: 0.9, covered_by_test: false, is_test: false, lang: "python", loc: 100, branch_count: 5 },
    "cold.py": { git_churn: 1,  pagerank: 0.1, covered_by_test: true,  is_test: false, lang: "python", loc: 10,  branch_count: 1 },
  },
});
const m = D.metrics(g);
assert(m, "metrics returns a record for a real graph");
assert.strictEqual(m.nodeCount, 2, "nodeCount");
assert.strictEqual(m.coverage.covered, 1, "coverage.covered");
assert.strictEqual(m.coverage.total, 2, "coverage.total");
assert.strictEqual(m.builtSha, "deadbeef", "builtSha");
assert.strictEqual(m.hotspots[0].path, "hot.py", "hottest node ranks first");
assert(m.byPath["hot.py"].risk > m.byPath["cold.py"].risk, "risk orders hot above cold");

// memoize-on-raw-bytes: same text returns the identical cached record
assert.strictEqual(D.metrics(g), m, "metrics memoizes on identical text");

// frontier: absent on a pre-frontier graph -> null (views can tell "absent" from "zero");
// present -> passed through verbatim (after the memoize check: metrics caches one entry,
// so calling it on a second graph here must not sit between the m/identity pair above)
assert.strictEqual(m.frontier, null, "frontier defaults to null when the graph lacks it");
const gFr = JSON.stringify(Object.assign(JSON.parse(g), { frontier: { never_audited: 7, stale: 43 } }));
assert.deepStrictEqual(D.metrics(gFr).frontier, { never_audited: 7, stale: 43 }, "frontier passes through");

// coach: the Commands-view recommendation truth table (pure decision logic)
const C = D.coach;
assert(C && typeof C.recommend === "function" && typeof C.signals === "function", "PW_DERIVE.coach missing");
assert.strictEqual(C.recommend({ cycles: 1, hotUncovered: 0, articulation: 0, pendRepairImprove: 0, pending: 5 }).key, "codvisor", "debt via cycles -> codvisor");
assert.strictEqual(C.recommend({ cycles: 0, hotUncovered: 3, articulation: 0, pendRepairImprove: 0, pending: 5 }).key, "codvisor", "debt via hotUncovered>=3 -> codvisor");
assert.strictEqual(C.recommend({ cycles: 0, hotUncovered: 0, articulation: 1, pendRepairImprove: 0, pending: 5 }).key, "codvisor", "debt via articulation -> codvisor");
assert.strictEqual(C.recommend({ cycles: 0, hotUncovered: 0, articulation: 0, pendRepairImprove: 2, pending: 5 }).key, "codvisor", "debt via pending repair/improve -> codvisor");
assert.strictEqual(C.recommend({ cycles: 0, hotUncovered: 0, articulation: 0, pendRepairImprove: 0, pending: 0 }).key, "codinventor", "no debt + nothing pending -> codinventor");
assert.strictEqual(C.recommend({ cycles: 0, hotUncovered: 2, articulation: 0, pendRepairImprove: 0, pending: 4 }).key, "codcycle", "no debt + pending -> codcycle");

// signals: a null graph degrades cleanly (no crash, zeroed graph fields)
const sNoGraph = C.signals({ pending: [{ mode: "repair" }], completed: [1, 2], rejected: [] }, null);
assert.strictEqual(sNoGraph.hasGraph, false, "signals(state,null).hasGraph");
assert.strictEqual(sNoGraph.pending, 1, "signals pending");
assert.strictEqual(sNoGraph.cycles, 0, "signals cycles (no graph)");
assert.strictEqual(sNoGraph.hotUncovered, 0, "signals hotUncovered (no graph)");
assert.strictEqual(sNoGraph.coveragePct, null, "signals coveragePct (no graph)");

// signals over a real metrics-like object
const fakeMetrics = {
  coverage: { covered: 1, total: 2 },
  cycles: [["a", "b"]],
  hotUncovered: [{}, {}],
  nodesArr: [{ articulation: true }, { articulation: false }],
};
const sG = C.signals({ pending: [{ mode: "repair" }, { mode: "develop" }], completed: [1], rejected: [2] }, fakeMetrics);
assert.strictEqual(sG.hasGraph, true, "signals hasGraph");
assert.strictEqual(sG.pending, 2, "signals pending count");
assert.strictEqual(sG.pendRepairImprove, 1, "signals pendRepairImprove");
assert.strictEqual(sG.cycles, 1, "signals cycles");
assert.strictEqual(sG.hotUncovered, 2, "signals hotUncovered");
assert.strictEqual(sG.articulation, 1, "signals articulation");
assert.strictEqual(sG.coveragePct, 50, "signals coveragePct");

// signals.converged passthrough — the one signal that drives a coach.evidence branch
assert.strictEqual(C.signals({ pending: [], completed: [], rejected: [], converged: true }, null).converged, true, "signals converged true");
assert.strictEqual(C.signals({ pending: [], completed: [], rejected: [] }, null).converged, false, "signals converged default false");

// coach.evidence: the numbers rendered beneath each recommendation (pure per-key truth table)
assert(typeof C.evidence === "function", "PW_DERIVE.coach.evidence missing");
// no-graph short-circuit: ANY key falls back to [pending, accepted, rejected]
assert.deepStrictEqual(
  C.evidence("codvisor", { hasGraph: false, pending: 5, completed: 3, rejected: 1 }),
  ["5 pending", "3 accepted", "1 rejected"], "evidence no-graph fallback");
// codvisor branch: cycles / hotspots / articulation / repair-improve
assert.deepStrictEqual(
  C.evidence("codvisor", { hasGraph: true, cycles: 2, hotUncovered: 4, articulation: 1, pendRepairImprove: 2 }),
  ["2 import cycles", "4 untested hotspots", "1 articulation risks", "2 repair/improve pending"], "evidence codvisor");
// codinventor branch: converged toggles the third chip
assert.deepStrictEqual(
  C.evidence("codinventor", { hasGraph: true, pending: 0, cycles: 0, converged: true }),
  ["0 pending", "0 cycles", "converged"], "evidence codinventor converged");
assert.deepStrictEqual(
  C.evidence("codinventor", { hasGraph: true, pending: 5, cycles: 2, converged: false }),
  ["5 pending", "2 cycles", "no open debt"], "evidence codinventor not converged");
// codcycle default branch
assert.deepStrictEqual(
  C.evidence("codcycle", { hasGraph: true, pending: 4, completed: 7 }),
  ["4 pending", "7 accepted so far"], "evidence codcycle default");

// coach.reset: a supplementary cold-start nudge, present ONLY when converged
assert(typeof C.reset === "function", "PW_DERIVE.coach.reset missing");
assert.strictEqual(C.reset({ converged: false }), null, "reset suggestion is absent when not converged");
const rsug = C.reset({ converged: true });
assert(rsug && rsug.cmd === "/planwright reset", "reset suggestion names `/planwright reset` (Claude Code slash form) when converged");
assert(/reset/i.test(rsug.why) && /rejected\.md/i.test(rsug.why) && /codvisor/i.test(rsug.why), "reset suggestion explains the cold-start, that rejected.md is kept, and points to the /codvisor follow-up");

// shared truth-table fixture — the SAME rows tests/unit/test_status.py pins against the
// Python port (scripts/status.py coach_recommend), so the two brains cannot drift: a
// one-sided behavior change fails one of the two suites.
const TBL = JSON.parse(fs.readFileSync(process.argv[3], "utf8"));
TBL.rows.forEach(function (r) {
  assert.strictEqual(C.recommend(r.signals).key, r.expect, "coach-table row: " + r.name);
});

// shared graph fixture — the debt-signal DERIVATION (hot-tercile tie semantics included)
// pinned to the same ground truth the Python port (_graph_signals) asserts.
const GFX = JSON.parse(fs.readFileSync(process.argv[4], "utf8"));
const gfxM = D.metrics(JSON.stringify(GFX.graph));
assert.strictEqual(gfxM.cycles.length, GFX.expected.import_cycles, "coach-graph: import cycles");
assert.strictEqual(gfxM.hotUncovered.length, GFX.expected.hot_uncovered, "coach-graph: hot uncovered");
const gfxS = C.signals({ pending: [], completed: [], rejected: [] }, gfxM);
assert.strictEqual(gfxS.articulation, GFX.expected.articulation, "coach-graph: articulation");
assert.strictEqual(gfxS.coveragePct, GFX.expected.coverage_pct, "coach-graph: coverage pct");

// branchless exclusion: a branch_count==0 node (config/license/declaration-only header) that
// lands in the hot tercile must NOT count as hot-uncovered — it has nothing for a test to
// cover. cfg is the single hottest node yet branchless; only the real code node `py` counts.
// (Mirrors test_status.py test_branchless_nodes_are_not_hot_uncovered; dropping the
// branchCount>0 guard makes this read 2.)
const gBL = JSON.stringify({ graph_built_at_sha: "bl01", nodes: {
  "cfg":    { git_churn: 99, pagerank: 0.99, covered_by_test: false, is_test: false, branch_count: 0, lang: "ini" },
  "py":     { git_churn: 50, pagerank: 0.9,  covered_by_test: false, is_test: false, branch_count: 7, lang: "python" },
  "lo1.py": { git_churn: 1,  pagerank: 0.1,  covered_by_test: true,  is_test: false, branch_count: 2, lang: "python" },
  "lo2.py": { git_churn: 0,  pagerank: 0.05, covered_by_test: true,  is_test: false, branch_count: 1, lang: "python" },
} });
const mBL = D.metrics(gBL);
assert.strictEqual(mBL.hotUncovered.length, 1, "coach-graph: branchless hot node excluded, real code counts");
assert.strictEqual(mBL.hotUncovered[0].path, "py", "coach-graph: the counted hot-uncovered node is the real code node");

// graph.adapt: the Coupling Web's data contract — top-N selection + keepSet pruning
assert(D.graph && typeof D.graph.adapt === "function", "PW_DERIVE.graph.adapt missing");
const N = 62;
const nodesArr = [];
for (let i = 0; i < N; i++) {
  nodesArr.push({ path: "n" + i, base: "n" + i, lang: "python", pagerank: N - i, churn: 0, covered: false, articulation: false, imports: [] });
}
const keptX = "n0", keptY = "n1", dropA = "n60", dropB = "n61";  // n60/n61 have the lowest pagerank
nodesArr[0].imports = [keptY, dropA];                            // one kept->kept, one kept->dropped
const gm = {
  nodeCount: N,
  nodesArr: nodesArr,
  dirtySet: { [keptX]: true },
  couplingEdges: [
    { a: keptX, b: keptY, weight: 2, cooccur: 5 },   // both kept -> survives
    { a: keptX, b: dropA, weight: 1, cooccur: 4 },   // one dropped -> pruned
  ],
  cycles: [[keptX, keptY], [keptX, dropA]],          // 2nd has <2 kept after prune -> dropped
  clusters: [
    { label: "core", members: [keptX, keptY, dropA] },  // 2 kept -> survives, dropA pruned out
    { label: "edge", members: [dropA, dropB] },         // 0 kept -> dropped
  ],
};
const ad = D.graph.adapt(gm, { stale: true, builtSha: "abc123" }, { emptyMsg: "NONE" });
const ids = ad.nodes.map(function (n) { return n.id; });
assert.strictEqual(ad.nodes.length, 60, "adapt keeps the top 60 nodes by pagerank");
assert(!ids.includes(dropA) && !ids.includes(dropB), "lowest-pagerank nodes are dropped");
assert(ids.includes(keptX) && ids.includes(keptY), "top nodes are kept");
assert.strictEqual(ad.nodes.find(function (n) { return n.id === keptX; }).dirty, true, "dirtySet flows through");
assert.strictEqual(ad.edges.length, 1, "a coupling edge to a dropped node is pruned");
assert.deepStrictEqual([ad.edges[0].source, ad.edges[0].target], [keptX, keptY], "surviving edge is kept->kept");
assert.deepStrictEqual(ad.importEdges, [{ source: keptX, target: keptY }], "an import edge to a dropped node is pruned");
assert.strictEqual(ad.cycles.length, 1, "a cycle left with <2 kept members is dropped");
assert(ad.cycles[0].every(function (p) { return ids.includes(p); }), "surviving cycle has only kept members");
assert.strictEqual(ad.clusters.length, 1, "a cluster left with <2 kept members is dropped");
assert.deepStrictEqual(ad.clusters[0].members, [keptX, keptY], "cluster pruned to its kept members");
assert.strictEqual(ad.total, N, "total = nodeCount");
assert.strictEqual(ad.emptyMsg, "NONE", "emptyMsg is injected by the caller");
assert.strictEqual(ad.stale, true, "ctx.stale passthrough");
assert.strictEqual(ad.builtSha, "abc123", "ctx.builtSha passthrough");

// graph.adapt defensive guards: with no ctx and no opts the fallbacks are taken (opts||{},
// emptyMsg default "", and the `ctx &&` guards) — it must not throw and must degrade cleanly.
const adBare = D.graph.adapt(gm);
assert.strictEqual(adBare.emptyMsg, "", "adapt with no opts -> emptyMsg defaults to ''");
assert.strictEqual(adBare.stale, false, "adapt with no ctx -> stale false");
assert.strictEqual(adBare.builtSha, undefined, "adapt with no ctx -> builtSha undefined");
assert.strictEqual(adBare.nodes.length, 60, "adapt with no opts -> default top-60 cap applies");

// graph.cycleMembers: the pure {path:true} set of every file in any import cycle (shared by
// the Plan cross-link chips and the Insights Next-up "in cycle" badge).
assert(typeof D.graph.cycleMembers === "function", "PW_DERIVE.graph.cycleMembers missing");
assert.deepStrictEqual(
  D.graph.cycleMembers({ cycles: [["a", "b"], ["c"]] }), { a: true, b: true, c: true },
  "cycleMembers maps every path in any cycle");
assert.deepStrictEqual(
  D.graph.cycleMembers({ cycles: [["a", "b"], ["b", "a"]] }), { a: true, b: true },
  "cycleMembers dedupes a node appearing in two cycles");
assert.deepStrictEqual(D.graph.cycleMembers({}), {}, "cycleMembers over missing cycles -> {}");
assert.deepStrictEqual(D.graph.cycleMembers({ cycles: [] }), {}, "cycleMembers over empty cycles -> {}");

// pendingModes: the Plan view's per-mode tally for the filter pills; a missing mode -> "other".
assert(typeof D.pendingModes === "function", "PW_DERIVE.pendingModes missing");
assert.deepStrictEqual(
  D.pendingModes([{ mode: "repair" }, { mode: "repair" }, {}]), { repair: 2, other: 1 },
  "pendingModes tallies modes and buckets a missing mode as 'other'");
assert.deepStrictEqual(D.pendingModes([]), {}, "pendingModes over [] -> {}");

// metrics().coverage.byLang: the per-language coverage split (cov/total per bucket), plus the
// `lang || "unknown"` default. A {python:2 (1 covered), ts:1 covered, <no lang>:1} graph.
const gLang = JSON.stringify({
  graph_built_at_sha: "lang01",
  nodes: {
    "a.py":   { lang: "python", covered_by_test: true,  pagerank: 0.5, git_churn: 1 },
    "b.py":   { lang: "python", covered_by_test: false, pagerank: 0.4, git_churn: 1 },
    "c.ts":   { lang: "ts",     covered_by_test: true,  pagerank: 0.3, git_churn: 1 },
    "d.bin":  {                 covered_by_test: false, pagerank: 0.2, git_churn: 1 },
  },
});
const mLang = D.metrics(gLang);
assert.deepStrictEqual(mLang.coverage.byLang.python, { lang: "python", cov: 1, total: 2 }, "byLang python cov/total");
assert.deepStrictEqual(mLang.coverage.byLang.ts, { lang: "ts", cov: 1, total: 1 }, "byLang ts cov/total");
assert.deepStrictEqual(mLang.coverage.byLang.unknown, { lang: "unknown", cov: 0, total: 1 }, "byLang 'unknown' default bucket");

// metrics().centralUntested: !covered && !isTest && prPct>=0.66, ordered by descending pagerank.
// Four nodes share the top pagerank band (>=0.90) and eight low nodes seed the percentile base, so
// with 12 nodes prPct(v) = (#strictly-below)/11 puts every top-band node above the 0.66 cutoff
// (the lowest, 0.90, has 8 below -> 8/11 ≈ 0.727). All four would qualify on pagerank alone, which
// gives the !covered/!isTest exclusions teeth: hi1/hi2 are uncovered & non-test (kept, hi1 first);
// cov is in-band but covered (excluded); tst is in-band but a test (excluded). The lo* nodes are
// below the cutoff (excluded), so dropping the prPct>=0.66 cutoff would surface them.
const gCU = JSON.stringify({
  graph_built_at_sha: "cu01",
  nodes: {
    "hi1": { pagerank: 0.99, covered_by_test: false, is_test: false, lang: "python" },
    "cov": { pagerank: 0.96, covered_by_test: true,  is_test: false, lang: "python" },
    "tst": { pagerank: 0.93, covered_by_test: false, is_test: true,  lang: "python" },
    "hi2": { pagerank: 0.90, covered_by_test: false, is_test: false, lang: "python" },
    "lo1": { pagerank: 0.10, covered_by_test: false, is_test: false, lang: "python" },
    "lo2": { pagerank: 0.09, covered_by_test: false, is_test: false, lang: "python" },
    "lo3": { pagerank: 0.08, covered_by_test: false, is_test: false, lang: "python" },
    "lo4": { pagerank: 0.07, covered_by_test: false, is_test: false, lang: "python" },
    "lo5": { pagerank: 0.06, covered_by_test: false, is_test: false, lang: "python" },
    "lo6": { pagerank: 0.05, covered_by_test: false, is_test: false, lang: "python" },
    "lo7": { pagerank: 0.04, covered_by_test: false, is_test: false, lang: "python" },
    "lo8": { pagerank: 0.03, covered_by_test: false, is_test: false, lang: "python" },
  },
});
const mCU = D.metrics(gCU);
assert.deepStrictEqual(
  mCU.centralUntested.map(function (n) { return n.path; }), ["hi1", "hi2"],
  "centralUntested keeps only prPct>=0.66 uncovered non-test nodes, ordered by descending pagerank");

// metrics() coupling derivations: the a/b!=null filter, the weight>=0.8 strong count, and the
// couplingStrongShare ratio. Edges: [w0.9 strong, w0.5 weak, {b:null} malformed, null] -> kept 2.
const gCoup = JSON.stringify({
  graph_built_at_sha: "coup01",
  nodes: { "x": { pagerank: 0.5, git_churn: 1 }, "y": { pagerank: 0.4, git_churn: 1 } },
  coupling_edges: [
    { a: "x", b: "y", weight: 0.9, cooccur: 3 },
    { a: "x", b: "y", weight: 0.5, cooccur: 2 },
    { a: "x", b: null, weight: 0.9 },
    null,
  ],
});
const mCoup = D.metrics(gCoup);
assert.strictEqual(mCoup.couplingEdges.length, 2, "coupling: malformed (null endpoint / null entry) edges dropped");
assert.strictEqual(mCoup.couplingStrong, 1, "coupling: weight>=0.8 strong count");
assert(Math.abs(mCoup.couplingStrongShare - 0.5) < 1e-9, "coupling: strong share = strong/kept");
// zero-edge case: the empty-denominator guard yields share 0 (no NaN division).
const mNoCoup = D.metrics(JSON.stringify({ nodes: { "z": { pagerank: 0.5 } } }));
assert.strictEqual(mNoCoup.couplingStrongShare, 0, "coupling: zero edges -> share 0 (denominator guard)");

// metrics() dirty/cluster passthroughs: dirtyReason, isFirstRun (!! coercion), dirtyChanged,
// dirtySet (built from dirty.nodes), and the clusters members.length>=2 filter.
const gDC = JSON.stringify({
  graph_built_at_sha: "dc01",
  nodes: { "p": { pagerank: 0.5 }, "q": { pagerank: 0.4 } },
  dirty: { reason: "changed since last run", is_first_run: 1, changed: ["p"], nodes: ["p", "q"] },
  clusters: [
    { label: "two", members: ["p", "q"] },
    { label: "one", members: ["p"] },
    { label: "none", members: [] },
  ],
});
const mDC = D.metrics(gDC);
assert.strictEqual(mDC.dirtyReason, "changed since last run", "dirtyReason passthrough");
assert.strictEqual(mDC.isFirstRun, true, "isFirstRun is the !! coercion of dirty.is_first_run");
assert.deepStrictEqual(mDC.dirtyChanged, ["p"], "dirtyChanged passthrough");
assert.deepStrictEqual(mDC.dirtySet, { p: true, q: true }, "dirtySet built from dirty.nodes");
assert.strictEqual(mDC.clusters.length, 1, "clusters filtered to members.length>=2");
assert.strictEqual(mDC.clusters[0].label, "two", "the surviving cluster is the >=2-member one");

console.log("DERIVE-OK");
JS
  if node "$TMP/derive_test.js" "$ROOT/scripts/dashboard/vendor/derive.js" "$ROOT/tests/fixtures/coach-table.json" "$ROOT/tests/fixtures/coach-graph.json" >"$TMP/derive.out" 2>"$TMP/derive.err" && grep -q DERIVE-OK "$TMP/derive.out"; then
    ok "PW_DERIVE metrics engine: pctRank/quantile + null-degrade + risk ordering + memoize (derive.js)"
  else
    bad "PW_DERIVE metrics engine check failed: $(cat "$TMP/derive.err" 2>/dev/null)"
  fi
else
  ok "PW_DERIVE metrics engine check skipped (node not installed)"
fi


# --- Test DRV2: staleCast fires only on sha-lag, never on mere import cycles ----
# writeAura applied the body-level "stale data" cast whenever the graph had ANY
# import cycle, so a repo with benign doc link cycles looked permanently stale even
# with graph and final point both current. The predicate is now PW_DERIVE.staleCast:
# stale strictly means "sha lags HEAD" (a stale ctx or a stale final point).
if command -v node >/dev/null 2>&1; then
  cat > "$TMP/derive_stale_test.js" <<'JS'
const fs = require("fs");
const vm = require("vm");
const assert = require("assert");
global.window = {};
vm.runInThisContext(fs.readFileSync(process.argv[2], "utf8"));
const D = global.window.PW_DERIVE;
assert(typeof D.staleCast === "function", "PW_DERIVE.staleCast missing");
// cycles alone (current graph, current final point) -> NOT stale
assert.strictEqual(D.staleCast({ stale: false, metrics: { cycles: [["a", "b"]] } },
                               { stale: false }), false, "cycles alone must not cast stale");
// a stale graph ctx -> stale, with or without cycles
assert.strictEqual(D.staleCast({ stale: true, metrics: { cycles: [] } }, null), true);
// a stale final point -> stale even with a current graph
assert.strictEqual(D.staleCast({ stale: false, metrics: null }, { stale: true }), true);
// degraded inputs never throw
assert.strictEqual(D.staleCast(null, null), false);
console.log("STALECAST-OK");
JS
  if node "$TMP/derive_stale_test.js" "$ROOT/scripts/dashboard/vendor/derive.js" >"$TMP/derive_sc.out" 2>"$TMP/derive_sc.err" && grep -q STALECAST-OK "$TMP/derive_sc.out"; then
    ok "PW_DERIVE.staleCast: sha-lag only — import cycles never apply the stale cast"
  else
    bad "PW_DERIVE.staleCast wrong: $(cat "$TMP/derive_sc.err" 2>/dev/null)"
  fi
  # app.js must route writeAura through the shared predicate, not a local cycles check
  if grep -q 'PW_DERIVE.staleCast(ctx, s.final_point)' "$ROOT/scripts/dashboard/app.js" \
     && ! grep -q 'ctx.metrics.cycles.length > 0' "$ROOT/scripts/dashboard/app.js"; then
    ok "app.js writeAura uses PW_DERIVE.staleCast (no cycles disjunct)"
  else
    bad "app.js writeAura does not route the stale cast through PW_DERIVE.staleCast"
  fi
else
  ok "PW_DERIVE.staleCast check skipped (node not installed)"
fi


# --- Test DRV3: finalFlag — an invalid final point is never rendered as trusted ----
# state.json's final_point.valid (lint-final's verdict) was read nowhere in the view
# layer, so a rung-less final.md at HEAD displayed as a trusted "set" point. The trust
# flag now lives in PW_DERIVE.finalFlag (stale wins, matching status.py's precedence).
if command -v node >/dev/null 2>&1; then
  cat > "$TMP/derive_final_test.js" <<'JS'
const fs = require("fs");
const vm = require("vm");
const assert = require("assert");
global.window = {};
vm.runInThisContext(fs.readFileSync(process.argv[2], "utf8"));
const D = global.window.PW_DERIVE;
assert(typeof D.finalFlag === "function", "PW_DERIVE.finalFlag missing");
assert.strictEqual(D.finalFlag({ stale: true, valid: false }), "stale", "stale wins");
assert.strictEqual(D.finalFlag({ stale: false, valid: false }), "invalid");
assert.strictEqual(D.finalFlag({ stale: false, valid: true }), "");
assert.strictEqual(D.finalFlag({ stale: false }), "", "absent valid defaults to trusted");
assert.strictEqual(D.finalFlag(null), "");
// a component-scoped point is never a whole-repo "set"; stale/invalid still win
assert.strictEqual(D.finalFlag({ stale: false, valid: true, scope: "path:src/auth" }), "scoped");
assert.strictEqual(D.finalFlag({ stale: true, valid: true, scope: "path:x" }), "stale", "stale wins over scoped");
assert.strictEqual(D.finalFlag({ stale: false, valid: false, scope: "path:x" }), "invalid", "invalid wins over scoped");
assert.strictEqual(D.finalFlag({ stale: false, valid: true, scope: null }), "", "null scope is whole-repo");
// finalPointShown: a point renders as soon as it carries a sha; date/deepest_tier are
// optional, so a sha-only point (especially a STALE/INVALID one) must NOT be hidden.
assert(typeof D.finalPointShown === "function", "PW_DERIVE.finalPointShown missing");
assert.strictEqual(D.finalPointShown({ sha: "abc", date: "", deepest_tier: "", stale: true }), true, "sha-only stale point shows");
assert.strictEqual(D.finalPointShown({ date: "2026-06-10" }), true, "date-only shows");
assert.strictEqual(D.finalPointShown({ deepest_tier: "expand" }), true, "tier-only shows");
assert.strictEqual(D.finalPointShown(null), false, "null hidden");
assert.strictEqual(D.finalPointShown({}), false, "empty point hidden");
console.log("FINALFLAG-OK");
JS
  if node "$TMP/derive_final_test.js" "$ROOT/scripts/dashboard/vendor/derive.js" >"$TMP/derive_ff.out" 2>"$TMP/derive_ff.err" && grep -q FINALFLAG-OK "$TMP/derive_ff.out"; then
    ok "PW_DERIVE.finalFlag: stale wins, invalid surfaces, trusted is empty"
  else
    bad "PW_DERIVE.finalFlag wrong: $(cat "$TMP/derive_ff.err" 2>/dev/null)"
  fi
  # The contributions card's final-point line moved to the shared ui.js (PW_UI.contribCard);
  # commands.js now delegates to it, so the trust-rendering surfaces are console.js (reactor),
  # ui.js (the shared card), and timeline.js.
  if grep -q 'PW_DERIVE.finalFlag(fp)' "$ROOT/scripts/dashboard/views/console.js" \
     && grep -q 'finalFlag' "$ROOT/scripts/dashboard/ui.js" \
     && grep -q 'finalFlag' "$ROOT/scripts/dashboard/views/timeline.js"; then
    ok "console/ui/timeline route final-point trust through PW_DERIVE.finalFlag"
  else
    bad "a view still renders final-point trust without PW_DERIVE.finalFlag"
  fi
  if grep -q 'finalPointShown(fp)' "$ROOT/scripts/dashboard/views/console.js" \
     && grep -q 'finalPointShown(fp)' "$ROOT/scripts/dashboard/ui.js" \
     && grep -q 'finalPointShown(fp)' "$ROOT/scripts/dashboard/views/timeline.js"; then
    ok "console/ui/timeline gate the final-point indicator on finalPointShown (a sha-only point shows)"
  else
    bad "a view still gates the final-point indicator on date||tier (hides a valid sha-only point)"
  fi
else
  ok "PW_DERIVE.finalFlag check skipped (node not installed)"
fi


# --- Test DRV4: the coach never recommends invention over a stale/invalid final point
# With nothing pending and no debt, coachRecommend said "grow net-new" even when the
# recorded final point was stale or invalid — states whose response is a re-audit.
# A merely scoped point is not a trust failure and must not trigger the gate.
if command -v node >/dev/null 2>&1; then
  cat > "$TMP/derive_coachfp_test.js" <<'JS'
const fs = require("fs");
const vm = require("vm");
const assert = require("assert");
global.window = {};
vm.runInThisContext(fs.readFileSync(process.argv[2], "utf8"));
const D = global.window.PW_DERIVE;
function rec(fp) {
  const s = D.coach.signals({ pending: [], completed: [], rejected: [], converged: false,
                              final_point: fp }, null);
  return D.coach.recommend(s);
}
assert.strictEqual(rec({ stale: true, valid: true }).key, "codvisor", "stale -> re-audit");
assert(/no longer holds \(stale\)/.test(rec({ stale: true, valid: true }).why));
assert.strictEqual(rec({ stale: false, valid: false }).key, "codvisor", "invalid -> re-audit");
assert.strictEqual(rec({ stale: false, valid: true, scope: "path:x" }).key, "codinventor",
  "a scoped point is not a trust failure");
assert.strictEqual(rec(null).key, "codinventor", "no final point: clean-tree advice unchanged");
console.log("COACHFP-OK");
JS
  if node "$TMP/derive_coachfp_test.js" "$ROOT/scripts/dashboard/vendor/derive.js" >"$TMP/derive_cfp.out" 2>"$TMP/derive_cfp.err" && grep -q COACHFP-OK "$TMP/derive_cfp.out"; then
    ok "coachRecommend gates invention on final-point trust (stale/invalid -> codvisor)"
  else
    bad "coachRecommend final-point trust gate wrong: $(cat "$TMP/derive_cfp.err" 2>/dev/null)"
  fi
else
  ok "coach final-point trust check skipped (node not installed)"
fi


# --- Test DRV5: metrics passes ranked_cold through (the cold-frontier card's input) --
# ranked_cold drives the explore escalation's first tier, yet it was the only
# escalation input PW_DERIVE dropped — the dashboard could not show what a dry hot
# core sweeps next. It must pass through verbatim and default to [] when absent.
if command -v node >/dev/null 2>&1; then
  cat > "$TMP/derive_cold_test.js" <<'JS'
const fs = require("fs");
const vm = require("vm");
const assert = require("assert");
global.window = {};
vm.runInThisContext(fs.readFileSync(process.argv[2], "utf8"));
const D = global.window.PW_DERIVE;
const base = {
  graph_built_at_sha: "deadbeef",
  nodes: { "a.py": { git_churn: 1, pagerank: 0.5, covered_by_test: false, is_test: false, lang: "python", loc: 5, branch_count: 1 } },
};
const withCold = D.metrics(JSON.stringify(Object.assign({ ranked_cold: ["a.py"] }, base)));
assert.deepStrictEqual(withCold.rankedCold, ["a.py"], "ranked_cold passthrough");
const without = D.metrics(JSON.stringify(base));
assert.deepStrictEqual(without.rankedCold, [], "absent ranked_cold defaults to []");
console.log("RANKEDCOLD-OK");
JS
  if node "$TMP/derive_cold_test.js" "$ROOT/scripts/dashboard/vendor/derive.js" >"$TMP/derive_rc.out" 2>"$TMP/derive_rc.err" && grep -q RANKEDCOLD-OK "$TMP/derive_rc.out"; then
    ok "PW_DERIVE.metrics exposes rankedCold (verbatim passthrough; [] when absent)"
  else
    bad "PW_DERIVE.metrics rankedCold wrong: $(cat "$TMP/derive_rc.err" 2>/dev/null)"
  fi
  if grep -q 'coldFrontier(metrics, ctx)' "$ROOT/scripts/dashboard/views/insights.js" \
     && grep -q 'rankedCold' "$ROOT/scripts/dashboard/views/insights.js"; then
    ok "insights view renders the Cold frontier card from metrics.rankedCold"
  else
    bad "insights view does not render the cold-frontier card"
  fi
else
  ok "PW_DERIVE rankedCold check skipped (node not installed)"
fi


# --- Test DRV6: metrics passes the seeded-invent framing through ---------------------
# Every codcycle invent phase runs under a rotating seeded framing, but the dashboard
# had no surface for which framing is active. exploreSeed/exploreFraming now pass
# through (null/"" on an unseeded graph).
if command -v node >/dev/null 2>&1; then
  cat > "$TMP/derive_framing_test.js" <<'JS'
const fs = require("fs");
const vm = require("vm");
const assert = require("assert");
global.window = {};
vm.runInThisContext(fs.readFileSync(process.argv[2], "utf8"));
const D = global.window.PW_DERIVE;
const base = {
  graph_built_at_sha: "deadbeef",
  nodes: { "a.py": { git_churn: 1, pagerank: 0.5, covered_by_test: false, is_test: false, lang: "python", loc: 5, branch_count: 1 } },
};
const seeded = D.metrics(JSON.stringify(Object.assign({ explore_seed: 7, explore_framing: "integration" }, base)));
assert.strictEqual(seeded.exploreSeed, 7, "explore_seed passthrough");
assert.strictEqual(seeded.exploreFraming, "integration", "explore_framing passthrough");
const unseeded = D.metrics(JSON.stringify(base));
assert.strictEqual(unseeded.exploreSeed, null, "absent seed -> null");
assert.strictEqual(unseeded.exploreFraming, "", "absent framing -> empty string");
// seed 0 is reachable (build-graph --seed 0) and is THE edge the == null
// construction protects: a truthiness rewrite (g.explore_seed || null) nulls it.
const zero = D.metrics(JSON.stringify(Object.assign({ explore_seed: 0, explore_framing: "automation" }, base)));
assert.strictEqual(zero.exploreSeed, 0, "seed 0 passthrough (== null, not truthiness)");
assert.strictEqual(zero.exploreFraming, "automation", "seed 0 framing passthrough");
console.log("FRAMING-OK");
JS
  if node "$TMP/derive_framing_test.js" "$ROOT/scripts/dashboard/vendor/derive.js" >"$TMP/derive_fr.out" 2>"$TMP/derive_fr.err" && grep -q FRAMING-OK "$TMP/derive_fr.out"; then
    ok "PW_DERIVE.metrics exposes exploreSeed/exploreFraming (null/empty when unseeded)"
  else
    bad "PW_DERIVE.metrics framing passthrough wrong: $(cat "$TMP/derive_fr.err" 2>/dev/null)"
  fi
  if grep -q 'metrics.exploreFraming' "$ROOT/scripts/dashboard/views/insights.js"; then
    ok "insights cold-frontier card renders the invent framing chip when seeded"
  else
    bad "insights view does not consume the framing fields"
  fi
else
  ok "PW_DERIVE framing check skipped (node not installed)"
fi


# --- Test DRV7: buildCtx consumes the canonical graph.stale from state.json ----------
# status.py's graph.stale (unverifiable HEAD reads stale, prefix-tolerant match) is
# the canonical verdict; the dashboard used to re-derive a DIVERGENT predicate (empty
# head read fresh, strict equality), so the CLI and the rendered view could disagree
# on the same bytes. buildCtx must prefer the state key, falling back only when a
# degraded snapshot lacks it.
if grep -q 'typeof s.graph.stale === "boolean"' "$ROOT/scripts/dashboard/app.js" \
   && grep -q 's.graph.stale' "$ROOT/scripts/dashboard/app.js"; then
  ok "app.js buildCtx prefers the canonical state.json graph.stale verdict"
else
  bad "app.js buildCtx still re-derives graph staleness instead of consuming graph.stale"
fi

# --- Test DRV8: vendor/graph.js camera math (rotate/faceAngles/placeSphere/clamp) -----
# graph.js is the one untested vendor file; its pure camera math carries the invariant
# click-to-focus relies on — a faced node must project to the front (+z). Exposed on
# PW_GRAPH._math; the pure fns touch no DOM, so vm-run graph.js with a minimal shim.
if command -v node >/dev/null 2>&1; then
  cat > "$TMP/graph_math_test.js" <<'JS'
const fs = require("fs");
const vm = require("vm");
const assert = require("assert");
global.window = { matchMedia: function () { return { matches: false, addEventListener() {}, addListener() {} }; } };
global.document = { createElement() { return {}; }, createElementNS() { return {}; } };
vm.runInThisContext(fs.readFileSync(process.argv[2], "utf8"));
const M = global.window.PW_GRAPH._math;
assert(M && typeof M.rotate === "function", "PW_GRAPH._math missing");

// (a) face invariant: rotating a unit vector by its own faceAngles brings it to +z.
function unit(x, y, z) { var n = Math.hypot(x, y, z); return { x: x / n, y: y / n, z: z / n }; }
[unit(1, 0, 0), unit(0, 1, 0), unit(0, 0, 1), unit(1, 2, 3), unit(-2, 1, -0.5), unit(0.3, -0.7, 0.2)].forEach(function (u) {
  var a = M.faceAngles(u);
  var r = M.rotate(u, a.yaw, a.pitch);
  assert(Math.abs(r.x) < 1e-9 && Math.abs(r.y) < 1e-9 && Math.abs(r.z - 1) < 1e-9,
    "faced vector must map to +z: " + JSON.stringify(r));
});

// (b) placeSphere: every point lands on the unit sphere; a single node maps to y=0.
M.placeSphere([{ lang: "python", pagerank: 0.9 }, { lang: "python", pagerank: 0.1 },
  { lang: "js", pagerank: 0.5 }, { lang: "go", pagerank: 0.2 }]).forEach(function (n) {
  assert(Math.abs(Math.hypot(n._u.x, n._u.y, n._u.z) - 1) < 1e-9, "placeSphere point off the unit sphere");
});
assert.strictEqual(M.placeSphere([{ lang: "python", pagerank: 1 }])[0]._u.y, 0, "single node maps to y=0");

// (c) clamp boundaries.
assert.strictEqual(M.clamp(5, 0, 10), 5, "clamp in-range");
assert.strictEqual(M.clamp(-1, 0, 10), 0, "clamp below");
assert.strictEqual(M.clamp(11, 0, 10), 10, "clamp above");
console.log("GRAPHMATH-OK");
JS
  if node "$TMP/graph_math_test.js" "$ROOT/scripts/dashboard/vendor/graph.js" >"$TMP/graph_math.out" 2>"$TMP/graph_math.err" \
     && grep -q GRAPHMATH-OK "$TMP/graph_math.out"; then
    ok "PW_GRAPH._math: faceAngles/rotate round-trip faces +z, placeSphere lands on the unit sphere, clamp bounds"
  else
    bad "vendor/graph.js camera math wrong: $(cat "$TMP/graph_math.err" 2>/dev/null)"
  fi
else
  ok "PW_GRAPH._math check skipped (node not installed)"
fi


# --- Test DRV9: shards.map — codshard's shard map (enumeration + frontier + order) ----
# The Shards view's data is pure derivation: enumeration from state.json's repo block
# (git-tracked truth, never graph node paths), per-shard staleness via build-graph.py's
# exact frontier predicates (never-audited: code node with a null audit stamp; stale:
# stamped, aged, and NOT in the dirty set), and codshard.md's sweep order (descending
# never-audited, lexicographic tiebreak; plain lexicographic without a graph).
if command -v node >/dev/null 2>&1; then
  cat > "$TMP/derive_shards_test.js" <<'JS'
const fs = require("fs");
const vm = require("vm");
const assert = require("assert");
global.window = {};
vm.runInThisContext(fs.readFileSync(process.argv[2], "utf8"));
const D = global.window.PW_DERIVE;
assert(D.shards && typeof D.shards.map === "function", "PW_DERIVE.shards.map missing");

// metrics.auditAge: null is meaningful (never audited) and 0 must survive (audited at
// HEAD) — the `== null` construction a truthiness rewrite (|| 0) would break.
const gSh = JSON.stringify({
  graph_built_at_sha: "shard01",
  dirty: { nodes: ["b/dirty.py"] },
  nodes: {
    "a/x.py":      { branch_count: 2, is_test: false, loc: 10, pagerank: 0.1, git_churn: 1 },
    "a/y.py":      { branch_count: 1, is_test: false, loc: 5,  pagerank: 0.1, git_churn: 1, audit_age_commits: 4, last_audited_sha: "s1" },
    "a/t_test.py": { branch_count: 3, is_test: true,  loc: 5,  pagerank: 0.1, git_churn: 1 },
    "a/data.md":   { branch_count: 0, is_test: false, loc: 50, pagerank: 0.1, git_churn: 1 },
    "b/z.py":      { branch_count: 2, is_test: false, loc: 8,  pagerank: 0.1, git_churn: 1, audit_age_commits: 0, last_audited_sha: "s2" },
    "b/dirty.py":  { branch_count: 2, is_test: false, loc: 8,  pagerank: 0.1, git_churn: 1, audit_age_commits: 9, last_audited_sha: "s3" },
    "c/q.py":      { branch_count: 2, is_test: false, loc: 4,  pagerank: 0.1, git_churn: 1 },
  },
});
const mSh = D.metrics(gSh);
assert.strictEqual(mSh.byPath["a/x.py"].auditAge, null, "no stamp -> auditAge null");
assert.strictEqual(mSh.byPath["a/y.py"].auditAge, 4, "audit_age_commits passthrough");
assert.strictEqual(mSh.byPath["b/z.py"].auditAge, 0, "age 0 survives (== null, not truthiness)");

const repo = { tracked_files: 9, shardable_dirs: ["a", "b"], folded_dirs: ["z"], large: false };
const SH = D.shards.map(repo, mSh);
assert(SH, "shards.map returns a record for a repo block + metrics");
assert.strictEqual(SH.basis, "staleness", "basis is staleness with a usable graph");
assert.strictEqual(SH.trackedFiles, 9, "tracked_files passthrough");
assert.deepStrictEqual(SH.folded, ["z"], "folded_dirs passthrough");
// order: shard a has 1 never-audited (a/x.py), b has 0 -> a sweeps first
assert.deepStrictEqual(SH.shards.map(function (s) { return s.name; }), ["a", "b"], "descending never-audited order");
assert.deepStrictEqual(SH.shards.map(function (s) { return s.order; }), [1, 2], "order numbers assigned");
const a = SH.shards[0], b = SH.shards[1];
// shard a: 4 graph nodes, 2 code nodes (the test file and the branchless doc are excluded)
assert.strictEqual(a.nodes, 4, "shard a node count");
assert.strictEqual(a.codeNodes, 2, "shard a code nodes exclude tests and branchless nodes");
assert.strictEqual(a.neverAudited, 1, "shard a never-audited (null stamp)");
assert.strictEqual(a.stale, 1, "shard a stale (aged stamp)");
assert.strictEqual(a.maxAge, 4, "shard a oldest stamp age");
// shard b: the age-0 node is clean and the aged node is in the dirty set -> stale 0
assert.strictEqual(b.neverAudited, 0, "shard b never-audited");
assert.strictEqual(b.stale, 0, "shard b stale excludes dirty-set and age-0 nodes");
assert.strictEqual(b.maxAge, 9, "shard b oldest stamp age still reported");
// c/q.py is under no listed shard -> the residue bucket (the closing round's territory),
// so totals = shards + residue reconcile EXACTLY with the builder's path-agnostic
// whole-repo frontier over the same nodes ({never_audited: 2, stale: 1} here).
assert.strictEqual(SH.residue.nodes, 1, "residue holds the out-of-shard node");
assert.strictEqual(SH.residue.neverAudited, 1, "residue never-audited (c/q.py, null stamp)");
assert.strictEqual(SH.residue.stale, 0, "residue stale");
assert.deepStrictEqual(SH.totals, { neverAudited: 2, stale: 1 },
  "totals (shards + residue) reconcile with the whole-repo frontier");

// no graph: lexicographic order, zeroed stats — exactly codshard's no-graph fallback
const SHL = D.shards.map({ tracked_files: 9, shardable_dirs: ["b", "a"], folded_dirs: [], large: false }, null);
assert.strictEqual(SHL.basis, "lexicographic", "basis falls back without a graph");
assert.deepStrictEqual(SHL.shards.map(function (s) { return s.name; }), ["a", "b"], "lexicographic fallback order");
assert.strictEqual(SHL.shards[0].neverAudited, 0, "no graph -> zeroed staleness");
assert.strictEqual(SHL.residue.neverAudited, 0, "no graph -> zeroed residue");

// staleness ties break lexicographically: shards b and z both have 0 never-audited
// nodes (z has no graph nodes at all), so the input order ["z", "b"] must not survive
const SHT = D.shards.map({ tracked_files: 9, shardable_dirs: ["z", "b"], folded_dirs: [], large: false }, mSh);
assert.deepStrictEqual(SHT.shards.map(function (s) { return s.name; }), ["b", "z"],
  "a never-audited tie breaks lexicographically by shard name");

// degraded inputs: no repo block (older snapshot / git unavailable) -> null, never a throw
assert.strictEqual(D.shards.map(null, mSh), null, "no repo block -> null");
assert.strictEqual(D.shards.map({}, mSh), null, "repo without shardable_dirs -> null");
console.log("SHARDS-OK");
JS
  if node "$TMP/derive_shards_test.js" "$ROOT/scripts/dashboard/vendor/derive.js" >"$TMP/derive_sh.out" 2>"$TMP/derive_sh.err" && grep -q SHARDS-OK "$TMP/derive_sh.out"; then
    ok "PW_DERIVE.shards.map: repo-block enumeration, frontier predicates (dirty-set excluded), staleness order + lexicographic fallback"
  else
    bad "PW_DERIVE.shards.map wrong: $(cat "$TMP/derive_sh.err" 2>/dev/null)"
  fi
  if grep -q 'PW_DERIVE.shards.map(state.repo, metrics)' "$ROOT/scripts/dashboard/views/shards.js"; then
    ok "Shards view derives the shard map through PW_DERIVE.shards.map (state.repo, never graph paths)"
  else
    bad "Shards view does not route the shard map through PW_DERIVE.shards.map"
  fi
else
  ok "PW_DERIVE.shards.map check skipped (node not installed)"
fi

# --- Test DRV10: shards.map totals reconcile with a REAL build-graph.py frontier ------
# DRV9 pins the JS predicates on a synthetic graph; this feeds the actual builder's
# emitted graph.json into shards.map so the two brains (build-graph.py's frontier block
# and derive.js's shardMap) cannot drift apart silently: totals (shards + residue) must
# equal the builder's path-agnostic frontier counts EXACTLY, on a fixture that exercises
# never-audited, stale, and dirty-excluded nodes at once.
if command -v node >/dev/null 2>&1; then
  XREPO="$TMP/xpinrepo"
  mkdir -p "$XREPO/alpha" "$XREPO/beta"
  printf '#!/usr/bin/env bash\none() { if true; then echo a1; fi; }\n' > "$XREPO/alpha/one.sh"
  printf '#!/usr/bin/env bash\ntwo() { if true; then echo a2; fi; }\n' > "$XREPO/alpha/two.sh"
  printf '#!/usr/bin/env bash\nthree() { if true; then echo b1; fi; }\n' > "$XREPO/beta/three.sh"
  printf '#!/usr/bin/env bash\nfour() { if true; then echo b2; fi; }\n' > "$XREPO/beta/four.sh"
  printf 'plain notes, no branches\n' > "$XREPO/notes.md"
  git -C "$XREPO" init -q
  git -C "$XREPO" add -A
  git -C "$XREPO" -c user.name=t -c user.email=t@e.com commit -qm init
  xg1="$TMP/xpin_graph1.json"
  python3 "$ROOT/scripts/build-graph.py" --root "$XREPO" > "$xg1" 2>/dev/null
  # Stamp two nodes as audited at HEAD1, then land a second commit touching alpha/one.sh,
  # so the --prior rebuild ages the stamps: alpha/one.sh turns dirty (stale-excluded on
  # both sides), beta/three.sh turns genuinely stale, and the two unstamped code nodes
  # stay never-audited — the builder's frontier must read {never_audited: 2, stale: 1}.
  python3 - "$xg1" <<'PY'
import json, sys
g = json.load(open(sys.argv[1]))
for f in ("alpha/one.sh", "beta/three.sh"):
    g["nodes"][f]["last_audited_sha"] = g["graph_built_at_sha"]
json.dump(g, open(sys.argv[1], "w"))
PY
  printf '#!/usr/bin/env bash\none() { if true; then echo a1 edited; fi; }\n' > "$XREPO/alpha/one.sh"
  git -C "$XREPO" add -A
  git -C "$XREPO" -c user.name=t -c user.email=t@e.com commit -qm edit
  xg2="$TMP/xpin_graph2.json"
  python3 "$ROOT/scripts/build-graph.py" --root "$XREPO" --prior "$xg1" > "$xg2" 2>/dev/null
  cat > "$TMP/derive_xpin_test.js" <<'JS'
const fs = require("fs");
const vm = require("vm");
const assert = require("assert");
global.window = {};
vm.runInThisContext(fs.readFileSync(process.argv[2], "utf8"));
const D = global.window.PW_DERIVE;
const raw = fs.readFileSync(process.argv[3], "utf8");
const g = JSON.parse(raw);
// the fixture must really exercise the frontier mix on the builder's side first
assert(g.frontier && g.frontier.never_audited > 0 && g.frontier.stale > 0,
  "fixture lost its frontier mix: " + JSON.stringify(g.frontier));
const m = D.metrics(raw);
assert(m, "metrics rejected the real builder output");
const SH = D.shards.map(
  { tracked_files: 5, shardable_dirs: ["alpha", "beta"], folded_dirs: [], large: false }, m);
assert(SH, "shards.map rejected the real builder output");
// THE cross-pin: the JS totals must equal the Python builder's frontier verbatim
assert.strictEqual(SH.totals.neverAudited, g.frontier.never_audited,
  "never-audited drift: js " + SH.totals.neverAudited + " vs builder " + g.frontier.never_audited);
assert.strictEqual(SH.totals.stale, g.frontier.stale,
  "stale drift: js " + SH.totals.stale + " vs builder " + g.frontier.stale);
console.log("XPIN-OK");
JS
  if node "$TMP/derive_xpin_test.js" "$ROOT/scripts/dashboard/vendor/derive.js" "$xg2" >"$TMP/derive_xpin.out" 2>"$TMP/derive_xpin.err" \
     && grep -q XPIN-OK "$TMP/derive_xpin.out"; then
    ok "shards.map totals reconcile exactly with a real build-graph.py frontier (cross-brain pin)"
  else
    bad "shards.map drifted from build-graph.py's frontier: $(cat "$TMP/derive_xpin.err" 2>/dev/null)"
  fi
else
  ok "shards.map real-builder cross-pin skipped (node not installed)"
fi

# --- Test DRV6: activityShown/activityLabel — the run-activity beacon line is pure logic ---
# The Console's "which command is running" line derives entirely from state.activity;
# the shown-guard and the label format live in PW_DERIVE so this suite can pin them:
# a malformed/absent beacon renders nothing (older snapshots stay unchanged), the label
# carries command — detail · since HH:MM, and a stale beacon appends "stale?" instead of
# asserting a long-dead run is live.
if command -v node >/dev/null 2>&1; then
  cat > "$TMP/derive_activity_test.js" <<'JS'
const fs = require("fs");
const vm = require("vm");
const assert = require("assert");
global.window = {};
vm.runInThisContext(fs.readFileSync(process.argv[2], "utf8"));
const D = global.window.PW_DERIVE;
assert(typeof D.activityShown === "function", "PW_DERIVE.activityShown missing");
assert(typeof D.activityLabel === "function", "PW_DERIVE.activityLabel missing");
// shown: presence check on a well-formed beacon only
assert.strictEqual(D.activityShown(null), false, "null beacon hidden");
assert.strictEqual(D.activityShown(undefined), false, "absent field (older snapshot) hidden");
assert.strictEqual(D.activityShown({}), false, "commandless beacon hidden");
assert.strictEqual(D.activityShown({ command: "" }), false, "empty command hidden");
assert.strictEqual(D.activityShown({ command: 42 }), false, "non-string command hidden");
assert.strictEqual(D.activityShown({ command: "codshard" }), true, "well-formed beacon shows");
// label: command — detail · since HH:MM (· stale? only past the TTL)
const live = D.activityLabel({ command: "codshard", detail: "shard 3/5: scripts/", started: "2026-06-12T18:42:00Z", stale: false });
assert(/^codshard — shard 3\/5: scripts\/ · since \d\d:\d\d$/.test(live), "live label format: " + live);
const bare = D.activityLabel({ command: "plan", detail: null, started: null, stale: false });
assert.strictEqual(bare, "plan", "detail-less, started-less label is just the command");
const stale = D.activityLabel({ command: "codmaster", detail: null, started: "2026-06-12T08:00:00Z", stale: true });
assert(/ · stale\?$/.test(stale), "stale beacon appends the stale? caveat: " + stale);
const badDate = D.activityLabel({ command: "cycle", detail: "cycle 2/3", started: "not-a-date", stale: false });
assert.strictEqual(badDate, "cycle — cycle 2/3", "an unparseable started drops the since stamp, not the line");
console.log("ACTIVITY-OK");
JS
  if node "$TMP/derive_activity_test.js" "$ROOT/scripts/dashboard/vendor/derive.js" >"$TMP/derive_act.out" 2>"$TMP/derive_act.err" && grep -q ACTIVITY-OK "$TMP/derive_act.out"; then
    ok "PW_DERIVE.activityShown/activityLabel: guard hides malformed beacons, label formats live/stale runs"
  else
    bad "PW_DERIVE activity helpers wrong: $(cat "$TMP/derive_act.err" 2>/dev/null)"
  fi
  if grep -q 'PW_DERIVE.activityShown(act)' "$ROOT/scripts/dashboard/views/console.js" \
     && grep -q 'PW_DERIVE.activityLabel(act)' "$ROOT/scripts/dashboard/views/console.js"; then
    ok "console routes the activity line through PW_DERIVE.activityShown/activityLabel"
  else
    bad "console renders the activity line without the PW_DERIVE activity helpers"
  fi
else
  ok "PW_DERIVE activity helpers check skipped (node not installed)"
fi

# --- Test DASH-MOTION-AGG: PW_DERIVE.aggregateMotions summarizes the run ledger per motion ---
# Aggregate the run-history ledger into per-motion run count, duration (total/avg seconds), and the
# convergence-outcome distribution. Pin the aggregates against a known sample so a counts/outcome
# drift fails; a non-array degrades to {} without throwing.
if command -v node >/dev/null 2>&1; then
  cat > "$TMP/motion_agg_test.js" <<'JS'
const fs = require("fs");
const vm = require("vm");
const assert = require("assert");
global.window = {};
vm.runInThisContext(fs.readFileSync(process.argv[2], "utf8"));
const D = global.window.PW_DERIVE;
assert(D && typeof D.aggregateMotions === "function", "PW_DERIVE.aggregateMotions missing");
// Non-array / empty degrade to {} without throwing.
assert.deepStrictEqual(D.aggregateMotions(null), {}, "non-array ledger should aggregate to {}");
assert.deepStrictEqual(D.aggregateMotions([]), {}, "empty ledger should aggregate to {}");
const ledger = [
  { command: "cycle", started: "2026-06-21T00:00:00Z", ended: "2026-06-21T00:00:10Z", outcome: "converged" },
  { command: "cycle", started: "2026-06-21T01:00:00Z", ended: "2026-06-21T01:00:30Z", outcome: "pending" },
  { command: "execute", started: "2026-06-21T02:00:00Z", ended: "2026-06-21T02:00:20Z", outcome: "converged" },
  { command: "execute", started: "bad", ended: "also-bad" },   // untimed + unknown outcome
];
const agg = D.aggregateMotions(ledger);
assert.strictEqual(agg.cycle.count, 2, "cycle count");
assert.strictEqual(agg.cycle.totalSeconds, 40, "cycle total seconds (10+30)");
assert.strictEqual(agg.cycle.avgSeconds, 20, "cycle avg seconds");
assert.strictEqual(agg.cycle.outcomes.converged, 1, "cycle converged count");
assert.strictEqual(agg.cycle.outcomes.pending, 1, "cycle pending count");
assert.strictEqual(agg.execute.count, 2, "execute count");
assert.strictEqual(agg.execute.timedRuns, 1, "execute timed runs (one has bad timestamps)");
assert.strictEqual(agg.execute.avgSeconds, 20, "execute avg over the single timed run");
assert.strictEqual(agg.execute.outcomes.converged, 1, "execute converged count");
assert.strictEqual(agg.execute.outcomes.unknown, 1, "execute unknown-outcome count");
console.log("MOTION-AGG-OK");
JS
  if node "$TMP/motion_agg_test.js" "$ROOT/scripts/dashboard/vendor/derive.js" >"$TMP/motion_agg.out" 2>"$TMP/motion_agg.err" \
     && grep -q MOTION-AGG-OK "$TMP/motion_agg.out"; then
    ok "PW_DERIVE.aggregateMotions summarizes the ledger per motion (count/duration/outcomes; non-array -> {})"
  else
    bad "PW_DERIVE.aggregateMotions aggregation drifted from the sample ledger: $(cat "$TMP/motion_agg.err" 2>/dev/null)"
  fi
else
  ok "PW_DERIVE.aggregateMotions check skipped (node not installed)"
fi
