// SPDX-FileCopyrightText: 2026 Eser KUBALI
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Graph view — the Coupling Web. Renders the *temporal* coupling network (files that
// change together) from /graph.json with the vendored, offline PW_GRAPH.renderCoupling
// layout: nodes in language wedges, ringed by centrality; edges weighted by co-change;
// import cycles drawn as dashed danger edges; articulation points haloed; the files the
// last build touched blooming. View-state weight-floor + imports-overlay controls only —
// read-only, no mutation.
//
// app.js fetches /graph.json centrally and hands the raw text + derived metrics in ctx, so
// this view does not fetch. It keeps the memoize-on-bytes guard (an unchanged graph is a
// no-op redraw, so the SVG never flickers during an active run) and re-applies the shared
// PW_BUS focus highlight without a rebuild.

(function () {
  "use strict";

  window.PW_VIEWS = window.PW_VIEWS || {};

  var TOP_NODES = 60;
  var lastSig;      // the graph.json text behind the current drawing (memoize-on-bytes)
  var unsub = null; // current PW_BUS focus subscription (leak-safe across re-renders)

  function elt(tag, cls, text) {
    var e = document.createElement(tag);
    if (cls) e.className = cls;
    if (text != null) e.textContent = text;
    return e;
  }
  function showEmpty(container, msg) {
    container.textContent = "";
    container.appendChild(elt("div", "pw-empty", msg));
    if (unsub) { unsub(); unsub = null; }
  }

  var NO_GRAPH = "No graph has been built yet (run a plan to build .planwright/graph.json).";

  // Shape PW_DERIVE metrics into the renderer's coupling-web data, keeping the most-central
  // TOP_NODES and only the coupling/import/cycle/cluster structure among them.
  function adapt(metrics, ctx) {
    var kept = metrics.nodesArr.slice().sort(function (a, b) {
      return (b.pagerank || 0) - (a.pagerank || 0);
    }).slice(0, TOP_NODES);
    var keepSet = {};
    kept.forEach(function (n) { keepSet[n.path] = true; });

    var nodes = kept.map(function (n) {
      return {
        id: n.path, base: n.base, lang: n.lang, pagerank: n.pagerank, churn: n.churn,
        covered: n.covered, articulation: n.articulation, dirty: !!metrics.dirtySet[n.path],
      };
    });

    var edges = metrics.couplingEdges.filter(function (e) {
      return keepSet[e.a] && keepSet[e.b];
    }).map(function (e) {
      return { source: e.a, target: e.b, weight: +e.weight || 0, cooccur: e.cooccur };
    });

    var importEdges = [];
    kept.forEach(function (n) {
      (n.imports || []).forEach(function (t) {
        if (keepSet[t]) importEdges.push({ source: n.path, target: t });
      });
    });

    var cyclesK = (metrics.cycles || []).map(function (c) {
      return c.filter(function (p) { return keepSet[p]; });
    }).filter(function (c) { return c.length >= 2; });

    var clustersK = (metrics.clusters || []).map(function (c) {
      return { label: c.label, members: (c.members || []).filter(function (p) { return keepSet[p]; }) };
    }).filter(function (c) { return c.members.length >= 2; });

    return {
      nodes: nodes, edges: edges, importEdges: importEdges, cycles: cyclesK,
      clusters: clustersK, total: metrics.nodeCount, emptyMsg: NO_GRAPH,
      stale: !!(ctx && ctx.stale), builtSha: ctx && ctx.builtSha,
    };
  }

  function render(container, state, ctx) {
    ctx = ctx || {};
    var text = (ctx.graphText !== undefined) ? ctx.graphText : null;

    // Unchanged + already drawn: skip the rebuild, just re-reflect the cross-view focus.
    if (text === lastSig && container.querySelector(".pw-web-svg")) {
      window.PW_GRAPH.highlightCoupling(container, window.PW_BUS.getFocus());
      return;
    }
    if (lastSig === undefined && !container.firstChild) showEmpty(container, "Loading graph…");
    lastSig = text;

    var metrics = ctx.metrics || null;
    if (text == null || metrics == null) { showEmpty(container, NO_GRAPH); return; }

    var data = adapt(metrics, ctx);
    if (!data.nodes.length) { showEmpty(container, NO_GRAPH); return; }

    window.PW_GRAPH.renderCoupling(container, data, {
      size: 720, maxLabels: 14,
      onNodeClick: function (path) { window.PW_BUS.focusNode(path, { view: "graph" }); },
    });

    if (unsub) { unsub(); }
    unsub = window.PW_BUS.onFocus(function (path) {
      window.PW_GRAPH.highlightCoupling(container, path);
    });
    window.PW_GRAPH.highlightCoupling(container, window.PW_BUS.getFocus());
  }

  window.PW_VIEWS.graph = render;
})();
