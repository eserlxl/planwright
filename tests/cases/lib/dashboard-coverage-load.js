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
console.log("COV-LOAD-OK");
