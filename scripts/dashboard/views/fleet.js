// SPDX-FileCopyrightText: 2026 Eser KUBALI
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Fleet view — a portfolio glance across every project the single dashboard server tracks.
// It renders /projects.json (window.PW_PROJECTS, kept fresh by app.js) as a grid of project
// cards: name, a reactor-state dot (active / converged / stale / idle — the same liveness the
// per-project Console reactor reflects), and pending/done counts. Clicking a card switches the
// whole dashboard to that project (app.js's PW_SWITCH_PROJECT) — purely view-state, no server
// control. This is what lets one server replace one-dashboard-per-repo: watch every repo's
// convergence at once, then dive into any. Read-only and derivable-only, like every view.
//
// Cards are styled inline (the global stylesheet is not this view's to edit); the colors are
// theme-neutral translucent grays + standard status hues so they read on light or dark.

(function () {
  "use strict";
  window.PW_VIEWS = window.PW_VIEWS || {};

  function elt(tag, cls, text) {
    var e = document.createElement(tag);
    if (cls) e.className = cls;
    if (text != null) e.textContent = text;
    return e;
  }

  var STATUS_LABEL = { active: "running", converged: "converged", stale: "stale", idle: "idle" };
  var STATUS_HUE = { active: "#22c55e", converged: "#3b82f6", stale: "#ef4444", idle: "#9ca3af" };

  function card(p, currentRoot) {
    var c = elt("button", "pw-fleet-card pw-fleet-card--" + (p.status || "idle"));
    c.type = "button";
    var current = currentRoot && p.path === currentRoot;
    c.style.cssText =
      "text-align:left;min-width:190px;flex:0 1 220px;padding:12px 14px;border-radius:10px;" +
      "border:1px solid rgba(127,127,127," + (current ? ".7" : ".3") + ");" +
      "background:rgba(127,127,127,.06);cursor:pointer;color:inherit;font:inherit;";
    var head = elt("div", "pw-fleet-head");
    head.style.cssText = "display:flex;align-items:center;gap:8px;font-weight:600;";
    var dot = elt("span", "pw-fleet-dot pw-fleet-dot--" + (p.status || "idle"));
    dot.style.cssText = "display:inline-block;width:9px;height:9px;border-radius:50%;background:" +
      (STATUS_HUE[p.status] || STATUS_HUE.idle) + ";";
    head.appendChild(dot);
    head.appendChild(elt("span", "pw-fleet-name", p.name || p.path));
    c.appendChild(head);
    var st = elt("div", "pw-fleet-status", STATUS_LABEL[p.status] || p.status || "idle");
    st.style.cssText = "opacity:.8;margin-top:4px;";
    c.appendChild(st);
    var counts = p.counts || {};
    var cn = elt("div", "pw-fleet-counts",
      (counts.pending || 0) + " pending · " + (counts.done || 0) + " done");
    cn.style.cssText = "opacity:.7;font-size:.85em;margin-top:2px;";
    c.appendChild(cn);
    c.title = p.path || "";
    c.addEventListener("click", function () {
      if (window.PW_SWITCH_PROJECT) window.PW_SWITCH_PROJECT(p.id);
    });
    return c;
  }

  window.PW_VIEWS.fleet = function (container, state, ctx) {
    container.textContent = "";
    var projects = window.PW_PROJECTS || (ctx && ctx.projects) || [];
    container.appendChild(elt("h2", "pw-view-title", "Fleet"));
    if (!projects.length) {
      container.appendChild(elt("p", "pw-fleet-empty",
        "No projects registered yet. Run planwright in a repo, or add one with " +
        "dashboard.py --add <dir>."));
      return;
    }
    container.appendChild(elt("p", "pw-fleet-note",
      projects.length + " project" + (projects.length === 1 ? "" : "s") +
      " · click a card to switch"));
    // running first, then quiescent (idle/converged), then stale; ties by name
    var rank = { active: 0, idle: 1, converged: 1, stale: 2 };
    var order = projects.slice().sort(function (a, b) {
      var ra = rank[a.status] != null ? rank[a.status] : 1;
      var rb = rank[b.status] != null ? rank[b.status] : 1;
      if (ra !== rb) return ra - rb;
      return String(a.name || "").localeCompare(String(b.name || ""));
    });
    var grid = elt("div", "pw-fleet-grid");
    grid.style.cssText = "display:flex;flex-wrap:wrap;gap:12px;margin-top:12px;";
    var curRoot = state && state.root;
    order.forEach(function (p) { grid.appendChild(card(p, curRoot)); });
    container.appendChild(grid);
  };
})();
