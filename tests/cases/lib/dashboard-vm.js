// SPDX-FileCopyrightText: 2026 Eser KUBALI
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Shared node-gated vm-bootstrap for the dashboard view-render assertions in
// tests/cases/dashboard.sh. The DASH-VIEWS-FN and DASH-INSIGHTS-RENDER blocks each
// used to carry their own ~copy of the El/document DOM shim, the window stub, the
// view loader, and the fixture state/graph/metrics. This module extracts that
// boilerplate once so every view-assertion block sources one helper instead of
// duplicating it — a new behavioral assertion for any views/*.js render just
// requires() this and reuses makeDoc()/makeWin()/loadViews()/makeFixture().
//
// Pure CommonJS, no dependencies beyond Node built-ins (fs/vm/assert), so the
// callers stay node-gated and skip cleanly when node is absent. The view files are
// loaded with vm.runInThisContext, which runs in the caller's realm — so they see
// the globals install() sets (global.window/document). Helper and caller share one
// Node process, so a fixture built here registers on the same window the caller uses.

"use strict";

const fs = require("fs");
const vm = require("vm");
const assert = require("assert");

// --- El: the DOM element shim the views render into ----------------------------------
function El(tag) {
  this.tagName = (tag || "div").toUpperCase();
  this.children = [];
  this.style = { setProperty() {}, removeProperty() {}, getPropertyValue() { return ""; } };
  this._attr = {}; this.dataset = {};
  this.classList = { _s: {}, add(c) { this._s[c] = true; }, remove(c) { delete this._s[c]; },
    toggle(c, on) { if (on === undefined) { on = !this._s[c]; } if (on) { this._s[c] = true; } else { delete this._s[c]; } return !!on; },
    contains(c) { return !!this._s[c]; } };
  this.textContent = ""; this.innerHTML = ""; this.hidden = false;
  this.className = ""; this.tabIndex = 0; this.value = "";
}
El.prototype.appendChild = function (c) { this.children.push(c); return c; };
El.prototype.removeChild = function (c) { this.children = this.children.filter(function (x) { return x !== c; }); return c; };
El.prototype.insertBefore = function (c) { this.children.unshift(c); return c; };
El.prototype.append = function () { for (var i = 0; i < arguments.length; i++) { this.children.push(arguments[i]); } };
El.prototype.prepend = function (c) { this.children.unshift(c); return c; };
El.prototype.replaceChildren = function () { this.children = []; };
El.prototype.remove = function () {};
El.prototype.addEventListener = function () {};
El.prototype.removeEventListener = function () {};
El.prototype.setAttribute = function (k, v) { this._attr[k] = String(v); };
El.prototype.setAttributeNS = function (ns, k, v) { this._attr[k] = String(v); };
El.prototype.getAttribute = function (k) { return (k in this._attr) ? this._attr[k] : null; };
El.prototype.hasAttribute = function (k) { return k in this._attr; };
El.prototype.removeAttribute = function (k) { delete this._attr[k]; };
El.prototype.querySelector = function () { return null; };
El.prototype.querySelectorAll = function () { return []; };
El.prototype.getContext = function () { return null; };
El.prototype.focus = function () {}; El.prototype.click = function () {};
El.prototype.contains = function () { return false; };

// --- makeDoc: a fresh document stub backed by El -------------------------------------
function makeDoc() {
  const doc = {
    readyState: "complete", hidden: false, visibilityState: "visible", title: "", activeElement: null,
    getElementById() { return new El(); },
    querySelector() { return null; }, querySelectorAll() { return []; },
    createElement(t) { return new El(t); },
    createElementNS(ns, t) { return new El(t); },
    createTextNode(t) { var n = new El("#text"); n.textContent = String(t); return n; },
    addEventListener() {}, removeEventListener() {},
  };
  doc.body = new El("body"); doc.documentElement = new El("html"); doc.head = new El("head");
  return doc;
}

// --- makeWin: a fresh window stub (no fetch — the caller installs its own per-URL stub
// when a view fetches, e.g. console/commands hit /recommend.json and doctor /doctor.json) -
function makeWin(doc) {
  return {
    PW_VIEWS: {}, PW_UI: { planMode: "all" },
    PW_BUS: { setNavigator() {}, focusNode() {}, clearFocus() {}, getFocus() { return null; },
      onFocus() { return function () {}; }, goto() {} },
    addEventListener() {}, removeEventListener() {},
    matchMedia() { return { matches: false, addEventListener() {}, addListener() {} }; },
    requestAnimationFrame() { return 0; },
    location: { hash: "", href: "http://x/", reload() {} },
    localStorage: { _d: {}, getItem(k) { return (k in this._d) ? this._d[k] : null; },
      setItem(k, v) { this._d[k] = String(v); }, removeItem(k) { delete this._d[k]; } },
    console: console,
  };
}

// --- install: wire the stubs into the realm globals the view files read --------------
function install(win, doc) {
  global.window = win; global.document = doc; global.location = win.location;
  if (win.fetch) { global.fetch = win.fetch; }
}

// --- loadScript / loadCommon / loadView / loadViews: the view loader ------------------
function loadScript(base, rel) {
  // Pass an absolute filename so NODE_V8_COVERAGE attributes coverage to the real source
  // path (file:///.../scripts/dashboard/...). Without it, V8 records the script under an
  // anonymous URL and the dashboard JS gets zero measured coverage. runInThisContext still
  // runs in the caller realm — only the script's reported URL changes.
  const abs = require("path").resolve(base, rel);
  vm.runInThisContext(fs.readFileSync(abs, "utf8"), { filename: abs });
}
// The real derive engine + the vendored coupling renderer (PW_GRAPH, which the graph
// view drives) + the shared UI fragments (window.PW_UI) the Console/Commands views call.
function loadCommon(base) {
  loadScript(base, "vendor/derive.js");
  loadScript(base, "vendor/graph.js");
  loadScript(base, "ui.js");
}
function loadView(base, name) {
  loadScript(base, "views/" + name + ".js");
  assert(typeof global.window.PW_VIEWS[name] === "function", "view " + name + " did not register render()");
}
function loadViews(base, names) {
  names.forEach(function (v) { loadView(base, v); });
}

// --- makeFixture: the full state + graph + derived-metrics snapshot ------------------
// Requires loadCommon() to have run first (uses window.PW_DERIVE). Returns the same
// named pieces the assertions consume: graphText, metrics, state, fullCtx, bareCtx.
function makeFixture() {
  const win = global.window;
  const graphText = JSON.stringify({
    graph_built_at_sha: "deadbeef",
    frontier: { never_audited: 3, stale: 5 },
    nodes: {
      "hot.py": { git_churn: 10, pagerank: 0.9, covered_by_test: false, is_test: false, lang: "python", loc: 100, branch_count: 5, is_articulation: true, imports: ["cold.py"] },
      "cold.py": { git_churn: 1, pagerank: 0.1, covered_by_test: true, is_test: false, lang: "python", loc: 10, branch_count: 1, is_articulation: false, imports: [] },
    },
    coupling_edges: [{ a: "hot.py", b: "cold.py", weight: 2, cooccur: 2 }],
    clusters: [{ label: "core", members: ["hot.py", "cold.py"] }],
    import_cycles: [],
  });
  const metrics = win.PW_DERIVE.metrics(graphText);
  const state = {
    schema_version: 1, root: "/x", head: "deadbeef", converged: false,
    counts: { pending: 2, completed: 1, rejected: 1 },
    pending_modes: { develop: 1, repair: 1 },
    pending: [
      { title: "do a thing", mode: "develop", rationale: "r", evidence: "e", surfaces: ["a.py"], new_surfaces: [], development: "d", acceptance: "ok", verification: "bash tests/run.sh" },
      { title: "fix a bug", mode: "repair", rationale: "r", evidence: "e", surfaces: ["b.py"], new_surfaces: [], development: "d", acceptance: "ok", verification: "bash tests/run.sh" },
    ],
    completed: [{ title: "shipped", mode: "develop", commit: "abc1234" }],
    rejected: [{ title: "bad idea", reason: "value-gate: no consumer" }],
    final_point: { sha: "deadbeef", date: "", deepest_tier: "", valid: true, stale: false, scope: null },
    graph: { built_sha: "deadbeef", node_count: 2, dirty: 0, stale: false },
  };
  const fullCtx = { graphText: graphText, metrics: metrics, builtSha: "deadbeef", stale: false, head: "deadbeef" };
  const bareCtx = { graphText: null, metrics: null, builtSha: "", stale: false, head: "deadbeef" };
  return { graphText: graphText, metrics: metrics, state: state, fullCtx: fullCtx, bareCtx: bareCtx };
}

// --- DOM-walk helpers the assertions share -------------------------------------------
function textOf(node) {
  var t = node.textContent || "";
  (node.children || []).forEach(function (c) { t += " " + textOf(c); });
  return t;
}
function classOf(n) { return String(n.className || (n._attr && n._attr["class"]) || ""); }
function findByClass(node, cls, out) {
  out = out || [];
  if (classOf(node).indexOf(cls) >= 0) out.push(node);
  (node.children || []).forEach(function (c) { findByClass(c, cls, out); });
  return out;
}
function idxOfClass(arr, cls) {
  for (var i = 0; i < arr.length; i++) { if (classOf(arr[i]).indexOf(cls) >= 0) { return i; } }
  return -1;
}
function frontDoorPanels(node) {
  return findByClass(node, "pw-frontdoor").filter(function (n) { return classOf(n) === "pw-frontdoor"; });
}

module.exports = {
  El, makeDoc, makeWin, install,
  loadScript, loadCommon, loadView, loadViews,
  makeFixture,
  textOf, classOf, findByClass, idxOfClass, frontDoorPanels,
};
