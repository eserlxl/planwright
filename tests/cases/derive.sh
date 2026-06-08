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

console.log("DERIVE-OK");
JS
  if node "$TMP/derive_test.js" "$ROOT/scripts/dashboard/vendor/derive.js" >"$TMP/derive.out" 2>"$TMP/derive.err" && grep -q DERIVE-OK "$TMP/derive.out"; then
    ok "PW_DERIVE metrics engine: pctRank/quantile + null-degrade + risk ordering + memoize (derive.js)"
  else
    bad "PW_DERIVE metrics engine check failed: $(cat "$TMP/derive.err" 2>/dev/null)"
  fi
else
  ok "PW_DERIVE metrics engine check skipped (node not installed)"
fi
