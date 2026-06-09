// SPDX-FileCopyrightText: 2026 Eser KUBALI
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Plan-progress view: pending / completed / rejected items from /state.json. Pending
// items show all eight plan fields and can be filtered by Mode; rejected items show
// their Rejection reason. Read-only — it renders state, never mutates it.
//
// Two upgrades over the original: (1) the mode-filter pills are derived from the actual
// pending[].mode values (state.pending_modes is often empty in live snapshots), and
// (2) when a graph has been built (ctx.metrics), each pending item's Surfaces that match
// a graph node get a clickable cross-link chip carrying inline risk badges (hot /
// uncovered / articulation / in-cycle) — clicking jumps to that file in Insights.

(function () {
  "use strict";

  window.PW_VIEWS = window.PW_VIEWS || {};
  // Shared, view-state-only UI state so the command palette can drive the mode filter.
  var PW_UI = window.PW_UI || (window.PW_UI = { planMode: "all" });

  var FIELDS = [
    ["mode", "Mode"], ["rationale", "Rationale"], ["evidence", "Evidence"],
    ["surfaces", "Surfaces"], ["new_surfaces", "New Surfaces"],
    ["development", "Development"], ["acceptance", "Acceptance"],
    ["verification", "Verification"],
  ];

  function elt(tag, cls, text) {
    var e = document.createElement(tag);
    if (cls) e.className = cls;
    if (text != null) e.textContent = text;
    return e;
  }

  function fieldValue(item, key) {
    var v = item[key];
    return Array.isArray(v) ? v.join(", ") : (v || "");
  }

  function crossLinks(item, metrics, inCycle) {
    if (!metrics) return null;
    var seen = {}, paths = [];
    ["surfaces", "new_surfaces"].forEach(function (k) {
      (item[k] || []).forEach(function (p) {
        if (!seen[p] && metrics.byPath[p]) { seen[p] = true; paths.push(p); }
      });
    });
    if (!paths.length) return null;

    var wrap = elt("div", "pw-xlinks");
    wrap.appendChild(elt("span", "pw-xlinks-k", "in graph"));
    paths.forEach(function (p) {
      var n = metrics.byPath[p];
      var chip = elt("button", "pw-xlink lang-" + (n.lang || "unknown"));
      chip.type = "button";
      chip.appendChild(elt("span", "pw-xlink-name", n.base));
      var badges = elt("span", "pw-xlink-badges");
      if (metrics.hotPathSet[p]) badges.appendChild(dot("hot", "hot — top-tercile churn × centrality"));
      if (!n.covered) badges.appendChild(dot("uncovered", "no covering test"));
      if (n.articulation) badges.appendChild(dot("articulation", "articulation point"));
      if (inCycle[p]) badges.appendChild(dot("cycle", "in an import cycle"));
      chip.appendChild(badges);
      chip.title = p;
      chip.addEventListener("click", function () { window.PW_BUS.focusNode(p, { view: "insights" }); });
      wrap.appendChild(chip);
    });
    return wrap;
  }
  function dot(kind, tip) {
    var d = elt("span", "pw-xlink-badge is-" + kind);
    d.title = tip;
    return d;
  }

  function pendingCard(item, metrics, inCycle) {
    var card = elt("div", "pw-card mode-" + (item.mode || "other"));
    var h = elt("h4", null, item.title || "(untitled)");
    if (item.mode) h.appendChild(elt("span", "pw-badge", item.mode));
    card.appendChild(h);
    var dl = elt("dl", "pw-fields");
    FIELDS.forEach(function (f) {
      var val = fieldValue(item, f[0]);
      if (!val) return;
      dl.appendChild(elt("dt", null, f[1]));
      dl.appendChild(elt("dd", null, val));
    });
    card.appendChild(dl);
    var xl = crossLinks(item, metrics, inCycle);
    if (xl) card.appendChild(xl);
    return card;
  }

  function simpleCard(title, mode, reason) {
    var card = elt("div", "pw-card" + (mode ? " mode-" + mode : ""));
    var h = elt("h4", null, title || "(untitled)");
    if (mode) h.appendChild(elt("span", "pw-badge", mode));
    card.appendChild(h);
    if (reason) card.appendChild(elt("div", "pw-reason", reason));
    return card;
  }

  function section(container, title, count) {
    container.appendChild(elt("div", "pw-section-title", title + " (" + count + ")"));
  }

  function modeFilters(container, modes, onPick) {
    var bar = elt("div", "pw-filters");
    var keys = ["all"].concat(Object.keys(modes || {}));
    keys.forEach(function (k) {
      var label = k === "all" ? "all" : k + " " + modes[k];
      var b = elt("button", k === PW_UI.planMode ? "active" : null, label);
      b.addEventListener("click", function () { PW_UI.planMode = k; onPick(); });
      bar.appendChild(b);
    });
    container.appendChild(bar);
  }

  function render(container, state, ctx) {
    ctx = ctx || {};
    var metrics = ctx.metrics || null;
    var inCycle = metrics ? window.PW_DERIVE.graph.cycleMembers(metrics) : {};
    container.textContent = "";
    var pending = state.pending || [];
    var completed = state.completed || [];
    var rejected = state.rejected || [];

    // Pending
    section(container, "Pending", pending.length);
    var modes = pending.length ? window.PW_DERIVE.pendingModes(pending) : (state.pending_modes || {});
    modeFilters(container, modes, function () { render(container, state, ctx); });
    var shown = pending.filter(function (p) {
      return PW_UI.planMode === "all" || (p.mode || "other") === PW_UI.planMode;
    });
    if (!shown.length) {
      container.appendChild(elt("div", "pw-empty", "No pending items" +
        (PW_UI.planMode === "all" ? "." : " in mode '" + PW_UI.planMode + "'.")));
    } else {
      shown.forEach(function (p) { container.appendChild(pendingCard(p, metrics, inCycle)); });
    }

    // Completed
    section(container, "Completed", completed.length);
    if (!completed.length) {
      container.appendChild(elt("div", "pw-empty", "Nothing completed yet."));
    } else {
      completed.forEach(function (c) {
        container.appendChild(simpleCard(c.title, c.mode, null));
      });
    }

    // Rejected
    section(container, "Rejected", rejected.length);
    if (!rejected.length) {
      container.appendChild(elt("div", "pw-empty", "Nothing rejected."));
    } else {
      rejected.forEach(function (r) {
        container.appendChild(simpleCard(r.title, null, r.reason));
      });
    }
  }

  window.PW_VIEWS.plan = render;
})();
