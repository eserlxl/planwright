// SPDX-FileCopyrightText: 2026 Eser KUBALI
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Load every dashboard view through the shared vm-bootstrap (tests/cases/lib/dashboard-vm.js)
// so that, under NODE_V8_COVERAGE, V8 emits coverage for scripts/dashboard/**/*.js. The loader
// passes an absolute vm filename, so the coverage is attributed to the real source paths.
// scripts/js-coverage-report.py then reduces the emitted V8 JSON to a single percentage.
//
// Shared by the DASH-JS-COV-PCT harness block (tests/cases/dashboard.sh) and the CI
// JS-coverage step (.github/workflows/ci.yml), so the local suite and CI measure coverage the
// same way. Exercises both the full and the degraded (bare ctx) render path of each view to
// reflect the behavior the suite actually covers.
//
// Usage: NODE_V8_COVERAGE=<dir> node tests/cases/lib/dashboard-coverage-load.js <scripts/dashboard dir>
"use strict";

const path = require("path");
const BASE = path.resolve(process.argv[2] || "scripts/dashboard");
const VM = require(path.resolve(BASE, "../../tests/cases/lib/dashboard-vm.js"));
const { makeDoc, makeWin, install, loadCommon, loadViews, makeFixture, El } = VM;

const doc = makeDoc();
const win = makeWin(doc);
win.fetch = function () {
  return Promise.resolve({ ok: true, json: function () { return Promise.resolve({ total: 0, checks: [] }); } });
};
install(win, doc);
loadCommon(BASE);

const VIEWS = ["console", "plan", "commands", "insights", "shards", "timeline", "graph", "fleet", "runs"];
loadViews(BASE, VIEWS);
const { state, fullCtx, bareCtx } = makeFixture();
VIEWS.forEach(function (v) {
  win.PW_VIEWS[v](new El("section"), state, fullCtx);
  win.PW_VIEWS[v](new El("section"), state, bareCtx);   // degraded path too
});
// Exercise the data-driven render paths the empty fetch stub above does not reach, so the Phase 7
// client code (runs timeline + commands motion telemetry) is MEASURED, not merely loaded: a
// populated ledger drives runs.paint()/duration() and commands.paintTelemetry()'s populated branch,
// and an empty ledger drives the degrade path.
const sampleRuns = [
  { command: "cycle", started: "2026-06-21T00:00:00Z", ended: "2026-06-21T00:00:10Z", outcome: "converged" },
  { command: "execute", started: "2026-06-21T01:00:00Z", ended: "2026-06-21T01:02:30Z", outcome: "pending" },
];
win.PW_VIEWS.runs.paint(new El("section"), sampleRuns);
win.PW_VIEWS.runs.paint(new El("section"), []);
win.PW_VIEWS.commands.paintTelemetry(new El("section"), sampleRuns);
// shards.js: makeFixture's state carries no `repo` block, so the per-view loop above only reaches the
// empty-state early return (shards.map(undefined, ...) -> null). Drive the POPULATED map path so
// shardCard()'s chips/heat/maxAge/frontier, the folded/large/residue notes, and the scoped vs
// whole-repo final-point flags are MEASURED — the DASH-VIEWS-SHARDS block (dashboard.sh) asserts this
// same DOM, so the coverage reflects behavior that is pinned, not coverage theater. Fixture mirrors
// derive.sh DRV9's gSh: a/ is a frontier shard (never-audited + aged stamp), b/ clean, c/ -> residue.
const shGraph = JSON.stringify({
  graph_built_at_sha: "shard01", dirty: { nodes: ["b/dirty.py"] },
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
const shMetrics = win.PW_DERIVE.metrics(shGraph);
win.PW_VIEWS.shards(new El("section"),
  { repo: { tracked_files: 9, shardable_dirs: ["a", "b"], folded_dirs: ["z"], large: true },
    final_point: { sha: "shard01", date: "2026-06-22", deepest_tier: "expand", valid: true, stale: false, scope: "path:a" } },
  { metrics: shMetrics });                                   // metrics + folded + large + SCOPED final point
win.PW_VIEWS.shards(new El("section"),
  { repo: { tracked_files: 9, shardable_dirs: ["a", "b"], folded_dirs: [], large: false },
    final_point: { sha: "shard01", date: "2026-06-22", deepest_tier: "expand", valid: true, stale: false, scope: null } },
  { metrics: null });                                        // no-graph fallback + WHOLE-REPO final point
// fleet.js: makeFixture carries no projects, so the per-view loop only reaches the empty early return.
// Drive the populated grid (varied status, current-project highlight) so card() + the sort are MEASURED
// (DASH-VIEWS-FLEET asserts this same DOM).
win.PW_VIEWS.fleet(new El("section"), { root: "/x" }, { projects: [
  { id: "p1", name: "alpha",   path: "/x", status: "active",    counts: { pending: 2, done: 5 } },
  { id: "p2", name: "beta",    path: "/y", status: "converged", counts: { pending: 0, done: 9 } },
  { id: "p3", name: "gamma",   path: "/z", status: "stale",     counts: { pending: 1, done: 3 } },
  { id: "p4", name: "delta",   path: "/w", status: "idle" },
  { id: "p5", name: "epsilon", path: "/v" },
] });
console.log("COV-LOAD-OK");
