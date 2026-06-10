// SPDX-FileCopyrightText: 2026 Eser KUBALI
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Insights view — the graph.json goldmine, made legible. Four panels, all derived by
// PW_DERIVE from /graph.json (passed in as ctx.metrics):
//   1. Risk Ledger        — an accessible, phone-legible ranked LIST of files by
//                           percentile churn × centrality (the primary hotspot surface).
//   2. Hotspot Constellation — a hand-rolled SVG scatter (churn × pagerank), the visual.
//   3. Coverage Ledger    — stacked covered/uncovered bars BY LANGUAGE + a central-but-
//                           untested callout (the actionable gap).
//   4. Import-cycle cards — one hand-rolled loop diagram per dependency cycle.
// Read-only. Clicking a file anywhere focuses it via PW_BUS and cross-highlights it in the
// Constellation here and the Coupling Web on the Graph tab.

(function () {
  "use strict";

  window.PW_VIEWS = window.PW_VIEWS || {};
  var SVG_NS = "http://www.w3.org/2000/svg";

  function elt(tag, cls, text) {
    var e = document.createElement(tag);
    if (cls) e.className = cls;
    if (text != null) e.textContent = text;
    return e;
  }
  function svg(name, attrs) {
    var n = document.createElementNS(SVG_NS, name);
    for (var k in attrs) {
      if (Object.prototype.hasOwnProperty.call(attrs, k)) n.setAttribute(k, attrs[k]);
    }
    return n;
  }
  function svgTitle(parent, text) {
    var t = document.createElementNS(SVG_NS, "title");
    t.textContent = text; parent.appendChild(t); return parent;
  }
  function langClass(lang) { return "lang-" + (lang || "unknown"); }

  function shaChip(ctx) {
    var s = elt("span", "pw-sha" + (ctx && ctx.stale ? " pw-sha--stale" : ""));
    var sha = (ctx && ctx.builtSha) ? ctx.builtSha.slice(0, 7) : "—";
    s.textContent = "graph " + sha + (ctx && ctx.stale ? " · stale" : "");
    return s;
  }
  function panelHead(title, ctx) {
    var h = elt("div", "pw-panel-head");
    h.appendChild(elt("h3", "pw-panel-title", title));
    h.appendChild(shaChip(ctx));
    return h;
  }

  // Module-scoped focus plumbing: refs map current-render path -> {row, dot}; unsub clears
  // the previous subscription so listeners never pile up across re-renders.
  var unsub = null;
  var refs = {};

  function applyFocus(path) {
    Object.keys(refs).forEach(function (p) {
      var on = p === path;
      var r = refs[p];
      if (r.row) r.row.classList.toggle("is-focused", on);
      if (r.dot) r.dot.classList.toggle("is-focused", on);
      if (on && r.row && r.row.scrollIntoView) {
        try { r.row.scrollIntoView({ block: "nearest" }); } catch (e) {}
      }
    });
  }

  // ---- Risk Ledger ---------------------------------------------------------------------

  function ledger(metrics, ctx) {
    var panel = elt("section", "pw-ledger pw-panel");
    panel.appendChild(panelHead("Risk ledger", ctx));
    panel.appendChild(elt("p", "pw-panel-sub",
      "Files ranked by churn × centrality (percentile). Higher = changes often AND many things lean on it."));

    var controls = elt("div", "pw-ledger-controls");
    var input = elt("input", "pw-filter-input pw-ledger-filter");
    input.type = "text";
    input.placeholder = "filter by path…";
    input.setAttribute("aria-label", "filter risk ledger by path");
    controls.appendChild(input);
    var count = elt("span", "pw-ledger-count");
    controls.appendChild(count);
    panel.appendChild(controls);

    var list = elt("div", "pw-ledger-list");
    list.setAttribute("role", "list");
    panel.appendChild(list);

    var LIMIT = 15;
    function paint() {
      list.textContent = "";
      var q = input.value.trim().toLowerCase();
      var matches = metrics.hotspots.filter(function (n) {
        return !q || n.path.toLowerCase().indexOf(q) !== -1;
      });
      var shown = matches.slice(0, LIMIT);
      count.textContent = "showing " + shown.length + " of " + metrics.hotspots.length +
        (q ? " (filtered)" : "");
      var maxRisk = metrics.hotspots.length ? (metrics.hotspots[0].risk || 0.0001) : 1;
      shown.forEach(function (n, i) {
        var row = elt("button", "pw-ledger-row" + (n.covered ? "" : " is-uncovered"));
        row.type = "button";
        row.setAttribute("role", "listitem");
        row.appendChild(elt("span", "pw-ledger-rank", String(i + 1)));

        var name = elt("span", "pw-ledger-name");
        if (n.dir) name.appendChild(elt("span", "pw-ledger-dir", n.dir));
        name.appendChild(elt("span", "pw-ledger-base", n.base));
        row.appendChild(name);

        var bar = elt("span", "pw-ledger-bar");
        var fillW = Math.max(3, Math.round(100 * (n.risk || 0) / (maxRisk || 1)));
        var fill = elt("span", "pw-ledger-bar-fill");
        fill.style.width = fillW + "%";
        bar.appendChild(fill);
        row.appendChild(bar);

        var meta = elt("span", "pw-ledger-meta");
        meta.appendChild(elt("span", "pw-ledger-lang " + langClass(n.lang)));
        meta.appendChild(elt("span", null, n.loc + " loc · " + n.churn + " churn"));
        row.appendChild(meta);

        var flags = elt("span", "pw-ledger-flags");
        if (!n.covered) flags.appendChild(elt("span", "pw-ledger-flag is-uncovered", "uncovered"));
        if (n.articulation) flags.appendChild(elt("span", "pw-ledger-flag is-articulation", "articulation"));
        row.appendChild(flags);

        row.title = n.path + " · risk " + (n.risk || 0).toFixed(3) +
          " (churn p" + Math.round(n.churnPct * 100) + " × central p" + Math.round(n.prPct * 100) + ")";
        row.addEventListener("click", function () { window.PW_BUS.focusNode(n.path, { view: "insights" }); });
        refs[n.path] = refs[n.path] || {};
        refs[n.path].row = row;
        list.appendChild(row);
      });
    }
    paint();
    input.addEventListener("input", paint);

    // j/k (and arrows) move row focus while a row is focused.
    list.addEventListener("keydown", function (ev) {
      var k = ev.key;
      if (k !== "j" && k !== "k" && k !== "ArrowDown" && k !== "ArrowUp") return;
      var rows = list.querySelectorAll(".pw-ledger-row");
      if (!rows.length) return;
      var idx = Array.prototype.indexOf.call(rows, document.activeElement);
      var next = (k === "j" || k === "ArrowDown") ? idx + 1 : idx - 1;
      if (next < 0) next = 0;
      if (next >= rows.length) next = rows.length - 1;
      rows[next].focus();
      ev.preventDefault();
    });
    return panel;
  }

  // ---- Next up (priorities) ------------------------------------------------------------
  // The planner's own centrality-ranked surfaces (graph.json ranked_code / ranked), each
  // cross-marked with the risk flags — the most actionable "where to look next" list.

  function prioFlag(kind, label) { return elt("span", "pw-prio-flag is-" + kind, label); }

  function priorities(metrics, ctx) {
    var panel = elt("section", "pw-priorities pw-panel");
    panel.appendChild(panelHead("Next up", ctx));
    var ranked = (metrics.rankedCode && metrics.rankedCode.length) ? metrics.rankedCode
      : (metrics.ranked || []);
    if (!ranked.length) {
      panel.appendChild(elt("div", "pw-empty", "No ranked surfaces recorded yet."));
      return panel;
    }
    panel.appendChild(elt("p", "pw-panel-sub",
      "The planner's centrality-ranked surfaces — where a change ripples furthest."));

    var inCycle = window.PW_DERIVE.graph.cycleMembers(metrics);

    var list = elt("ol", "pw-prio-list");
    ranked.slice(0, 12).forEach(function (p, i) {
      var n = metrics.byPath[p];
      var row = elt("li", "pw-prio-row");
      var btn = elt("button", "pw-prio-btn");
      btn.type = "button";
      btn.appendChild(elt("span", "pw-prio-rank", String(i + 1)));
      if (n) btn.appendChild(elt("span", "pw-prio-dot " + langClass(n.lang)));
      var nm = elt("span", "pw-prio-name");
      var dir = p.lastIndexOf("/") === -1 ? "" : p.slice(0, p.lastIndexOf("/") + 1);
      if (dir) nm.appendChild(elt("span", "pw-prio-dir", dir));
      nm.appendChild(elt("span", null, p.split("/").pop()));
      btn.appendChild(nm);
      var flags = elt("span", "pw-prio-flags");
      if (metrics.hotPathSet[p]) flags.appendChild(prioFlag("hot", "hot"));
      if (n && !n.covered) flags.appendChild(prioFlag("uncovered", "uncovered"));
      if (n && n.articulation) flags.appendChild(prioFlag("articulation", "articulation"));
      if (inCycle[p]) flags.appendChild(prioFlag("cycle", "in cycle"));
      btn.appendChild(flags);
      btn.title = p;
      btn.addEventListener("click", function () { window.PW_BUS.focusNode(p, { view: "insights" }); });
      refs[p] = refs[p] || {};
      row.appendChild(btn);
      list.appendChild(row);
    });
    panel.appendChild(list);
    return panel;
  }

  // ---- Cold frontier ---------------------------------------------------------------------
  // The explore escalation's tier-① sweep list (graph.json ranked_cold: never-audited,
  // then stalest-audited (audit_age_commits), then uncovered, then least-central). When
  // the hot core runs dry, these are exactly
  // the files the escalation reads next — the live view of "what a dry round does".

  function coldFrontier(metrics, ctx) {
    var panel = elt("section", "pw-priorities pw-panel");
    panel.appendChild(panelHead("Cold frontier", ctx));
    var cold = metrics.rankedCold || [];
    // The framing chip must render on BOTH branches — a seeded graph whose cold
    // list happens to be empty otherwise has no surface naming its active framing.
    var framingBit = "";
    if (metrics.exploreFraming) {
      // a seeded build: show which generative vantage the invent lens surveys through
      framingBit = " Invent framing: " + metrics.exploreFraming +
        (metrics.exploreSeed == null ? "" : " (seed " + metrics.exploreSeed + ")") + ".";
    }
    // The builder's frontier counts quantify the backlog the capped list hides —
    // the dryness verdict's denominator, not just the next 8 reads.
    var frontierBit = metrics.frontier
      ? " Backlog: " + (metrics.frontier.never_audited || 0) + " never-audited, " +
        (metrics.frontier.stale || 0) + " stale." : "";
    if (!cold.length) {
      if (framingBit || frontierBit) {
        panel.appendChild(elt("p", "pw-panel-sub", (framingBit + frontierBit).trim()));
      }
      panel.appendChild(elt("div", "pw-empty", "No cold-frontier list recorded yet."));
      return panel;
    }
    panel.appendChild(elt("p", "pw-panel-sub",
      "The explore escalation sweeps these when the hot core runs dry — least-audited first." +
      framingBit + frontierBit));
    var list = elt("ol", "pw-prio-list");
    cold.slice(0, 8).forEach(function (p, i) {
      var n = metrics.byPath[p];
      var row = elt("li", "pw-prio-row");
      var btn = elt("button", "pw-prio-btn");
      btn.type = "button";
      btn.appendChild(elt("span", "pw-prio-rank", String(i + 1)));
      if (n) btn.appendChild(elt("span", "pw-prio-dot " + langClass(n.lang)));
      var nm = elt("span", "pw-prio-name");
      var dir = p.lastIndexOf("/") === -1 ? "" : p.slice(0, p.lastIndexOf("/") + 1);
      if (dir) nm.appendChild(elt("span", "pw-prio-dir", dir));
      nm.appendChild(elt("span", null, p.split("/").pop()));
      btn.appendChild(nm);
      var flags = elt("span", "pw-prio-flags");
      if (n && !n.covered && !n.isTest) flags.appendChild(prioFlag("uncovered", "uncovered"));
      if (n && n.isTest) flags.appendChild(prioFlag("cycle", "test"));
      btn.appendChild(flags);
      btn.title = p;
      btn.addEventListener("click", function () { window.PW_BUS.focusNode(p, { view: "insights" }); });
      refs[p] = refs[p] || {};
      row.appendChild(btn);
      list.appendChild(row);
    });
    panel.appendChild(list);
    return panel;
  }

  // ---- Hotspot Constellation -----------------------------------------------------------

  function constellation(metrics, ctx) {
    var panel = elt("section", "pw-constellation pw-panel");
    panel.appendChild(panelHead("Hotspot constellation", ctx));
    panel.appendChild(elt("p", "pw-panel-sub",
      "Each dot a file. Right = churns more. Up = more central. Top-right = load-bearing & volatile."));

    var W = 720, Hh = 420, L = 56, R = 24, T = 24, B = 48;
    var plotL = L, plotR = W - R, plotT = T, plotB = Hh - B;
    var s = svg("svg", {
      "class": "pw-scatter-svg", viewBox: "0 0 " + W + " " + Hh,
      preserveAspectRatio: "xMidYMid meet", role: "img",
      "aria-label": "Scatter of " + metrics.nodeCount + " files by churn and centrality",
    });

    var maxChurn = metrics.maxChurn || 1, maxPr = metrics.maxPr || 1, maxLoc = metrics.maxLoc || 1;
    function xOf(c) { return plotL + (c / maxChurn) * (plotR - plotL); }
    function yOf(p) { return plotB - (p / maxPr) * (plotB - plotT); }

    // danger quadrant (high churn AND high centrality — the p75 corner)
    var qx = xOf(metrics.churn_p75), qy = yOf(metrics.pr_p75);
    s.appendChild(svg("rect", {
      x: qx.toFixed(1), y: plotT, width: (plotR - qx).toFixed(1), height: (qy - plotT).toFixed(1),
      "class": "pw-scatter-quad",
    }));
    var qlabel = svg("text", { x: (plotR - 6), y: (plotT + 14), "text-anchor": "end", "class": "pw-scatter-quad-label" });
    qlabel.textContent = "load-bearing & volatile";
    s.appendChild(qlabel);

    // axes
    s.appendChild(svg("line", { x1: plotL, y1: plotB, x2: plotR, y2: plotB, "class": "pw-scatter-axis" }));
    s.appendChild(svg("line", { x1: plotL, y1: plotT, x2: plotL, y2: plotB, "class": "pw-scatter-axis" }));
    var xl = svg("text", { x: (plotL + plotR) / 2, y: Hh - 12, "text-anchor": "middle", "class": "pw-scatter-axis-label" });
    xl.textContent = "git churn →";
    s.appendChild(xl);
    var yl = svg("text", { x: 14, y: (plotT + plotB) / 2, "text-anchor": "middle", "class": "pw-scatter-axis-label",
      transform: "rotate(-90 14 " + ((plotT + plotB) / 2) + ")" });
    yl.textContent = "centrality (pagerank) →";
    s.appendChild(yl);

    var pts = metrics.hotspots.slice(0, 50);
    pts.forEach(function (n) {
      var r = Math.max(3, Math.min(9, 3 + 6 * (n.loc / maxLoc)));
      var cls = "pw-scatter-dot " + langClass(n.lang) +
        (n.covered ? "" : " is-uncovered") + (n.articulation ? " is-articulation" : "");
      var dot = svg("circle", { cx: xOf(n.churn).toFixed(1), cy: yOf(n.pagerank).toFixed(1), r: r.toFixed(1), "class": cls });
      dot.setAttribute("data-pw-path", n.path);
      svgTitle(dot, n.path + "\nchurn " + n.churn + " · pagerank " + n.pagerank.toFixed(3) +
        " · " + n.loc + " loc · " + (n.covered ? "covered" : "uncovered") +
        " · " + n.defines + " defs" + (n.articulation ? " · articulation" : ""));
      s.appendChild(dot);
      refs[n.path] = refs[n.path] || {};
      refs[n.path].dot = dot;
    });

    // one delegated listener
    s.addEventListener("click", function (ev) {
      var t = ev.target;
      var p = t && t.getAttribute && t.getAttribute("data-pw-path");
      if (p) window.PW_BUS.focusNode(p, { view: "insights" });
    });

    var wrap = elt("div", "pw-scatter-wrap");
    wrap.appendChild(s);
    panel.appendChild(wrap);
    if (metrics.nodeCount > 50) {
      panel.appendChild(elt("div", "pw-panel-foot", "showing the 50 highest-risk of " + metrics.nodeCount + " files"));
    }
    return panel;
  }

  // ---- Coverage Ledger -----------------------------------------------------------------

  function coverage(metrics, ctx) {
    var panel = elt("section", "pw-covledger pw-panel");
    panel.appendChild(panelHead("Coverage by language", ctx));
    var cov = metrics.coverage;
    panel.appendChild(elt("p", "pw-panel-sub",
      cov.covered + " of " + cov.total + " files are reached by a test."));

    var langs = Object.keys(cov.byLang).sort(function (a, b) {
      return (cov.byLang[b].total - cov.byLang[b].cov) - (cov.byLang[a].total - cov.byLang[a].cov);
    });
    var maxTotal = 0;
    langs.forEach(function (l) { if (cov.byLang[l].total > maxTotal) maxTotal = cov.byLang[l].total; });

    langs.forEach(function (l) {
      var x = cov.byLang[l];
      var rowEl = elt("div", "pw-cov-row");
      var label = elt("div", "pw-cov-label");
      label.appendChild(elt("span", "pw-cov-dot " + langClass(l)));
      label.appendChild(elt("span", "pw-cov-lang", l));
      rowEl.appendChild(label);

      var barWrap = elt("div", "pw-cov-barwrap");
      var bar = elt("div", "pw-cov-bar");
      bar.style.width = Math.round(100 * x.total / (maxTotal || 1)) + "%";
      if (x.cov > 0) {
        var fill = elt("div", "pw-cov-fill " + langClass(l));
        fill.style.flex = String(x.cov);
        bar.appendChild(fill);
      }
      if (x.total - x.cov > 0) {
        var gap = elt("div", "pw-cov-gap pw-hatch");
        gap.style.flex = String(x.total - x.cov);
        bar.appendChild(gap);
      }
      barWrap.appendChild(bar);
      rowEl.appendChild(barWrap);
      rowEl.appendChild(elt("span", "pw-cov-count", x.cov + "/" + x.total));
      rowEl.title = l + ": " + x.cov + " covered, " + (x.total - x.cov) + " uncovered";
      panel.appendChild(rowEl);
    });

    var untested = metrics.centralUntested.slice(0, 8);
    if (untested.length) {
      panel.appendChild(elt("div", "pw-section-mini pw-untested-head", "Central, yet untested"));
      var ul = elt("ul", "pw-untested");
      untested.forEach(function (n) {
        var li = elt("li", "pw-untested-item");
        var btn = elt("button", "pw-untested-btn");
        btn.type = "button";
        btn.appendChild(elt("span", "pw-cov-dot " + langClass(n.lang)));
        btn.appendChild(elt("span", "pw-untested-name", n.base));
        btn.appendChild(elt("span", "pw-untested-meta", "p" + Math.round(n.prPct * 100) + " central"));
        btn.title = n.path;
        btn.addEventListener("click", function () { window.PW_BUS.focusNode(n.path, { view: "insights" }); });
        li.appendChild(btn);
        ul.appendChild(li);
      });
      panel.appendChild(ul);
    }
    return panel;
  }

  // ---- Import-cycle cards --------------------------------------------------------------

  function cycles(metrics, ctx) {
    var panel = elt("section", "pw-cycles pw-panel");
    panel.appendChild(panelHead("Import cycles", ctx));
    if (!metrics.cycles.length) {
      panel.appendChild(elt("div", "pw-empty", "No import cycles — the dependency graph is acyclic. ✓"));
      return panel;
    }
    panel.appendChild(elt("p", "pw-panel-sub",
      metrics.cycles.length + " cycle" + (metrics.cycles.length === 1 ? "" : "s") +
      " — mutually-importing files that can only be understood (and tested) together."));

    var grid = elt("div", "pw-cycles-grid");
    metrics.cycles.forEach(function (cyc) {
      var card = elt("div", "pw-cycle-card");
      card.appendChild(cycleArc(cyc));
      var members = elt("div", "pw-cycle-members");
      cyc.forEach(function (p) {
        var chip = elt("button", "pw-cycle-chip");
        chip.type = "button";
        var node = metrics.byPath[p];
        chip.appendChild(elt("span", "pw-cov-dot " + langClass(node && node.lang)));
        chip.appendChild(elt("span", null, p.split("/").pop()));
        chip.title = p;
        chip.addEventListener("click", function () { window.PW_BUS.focusNode(p, { view: "insights" }); });
        members.appendChild(chip);
      });
      card.appendChild(members);
      card.appendChild(elt("span", "pw-cycle-tag", "structural smell"));
      grid.appendChild(card);
    });
    panel.appendChild(grid);
    return panel;
  }

  // A small two-arc loop between the first two members (cycles in this graph are 2-node).
  function cycleArc(cyc) {
    var s = svg("svg", { "class": "pw-cycle-arc", viewBox: "0 0 180 64", "aria-hidden": "true" });
    var defs = svg("defs", {});
    var marker = svg("marker", {
      id: "pw-arrow", viewBox: "0 0 10 10", refX: 8, refY: 5,
      markerWidth: 6, markerHeight: 6, orient: "auto-start-reverse",
    });
    marker.appendChild(svg("path", { d: "M0,0 L10,5 L0,10 z", "class": "pw-cycle-arrowhead" }));
    defs.appendChild(marker);
    s.appendChild(defs);
    s.appendChild(svg("path", { d: "M48,26 C78,6 102,6 132,26", "class": "pw-cycle-loop", "marker-end": "url(#pw-arrow)" }));
    s.appendChild(svg("path", { d: "M132,38 C102,58 78,58 48,38", "class": "pw-cycle-loop", "marker-end": "url(#pw-arrow)" }));
    s.appendChild(svg("circle", { cx: 40, cy: 32, r: 9, "class": "pw-cycle-node" }));
    s.appendChild(svg("circle", { cx: 140, cy: 32, r: 9, "class": "pw-cycle-node" }));
    return s;
  }

  // ---- compose -------------------------------------------------------------------------

  function render(container, state, ctx) {
    container.textContent = "";
    ctx = ctx || {};
    var metrics = ctx.metrics || null;
    refs = {};
    if (unsub) { unsub(); unsub = null; }

    if (!metrics) {
      container.appendChild(elt("div", "pw-empty",
        "No graph has been built yet. Run a plan to build .planwright/graph.json and the insights light up."));
      return;
    }

    var grid = elt("div", "pw-insights-grid");
    grid.appendChild(priorities(metrics, ctx));
    grid.appendChild(coldFrontier(metrics, ctx));
    grid.appendChild(ledger(metrics, ctx));
    grid.appendChild(constellation(metrics, ctx));
    grid.appendChild(coverage(metrics, ctx));
    grid.appendChild(cycles(metrics, ctx));
    container.appendChild(grid);

    // re-subscribe (leak-safe) and reflect any current cross-view focus immediately
    unsub = window.PW_BUS.onFocus(applyFocus);
    applyFocus(window.PW_BUS.getFocus());
  }

  window.PW_VIEWS.insights = render;
})();
