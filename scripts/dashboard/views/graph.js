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

  // The pure metrics->coupling-web shaping (top-N selection + keepSet pruning) lives in
  // PW_DERIVE.graph.adapt so it can be unit-tested under node; this view just injects its
  // empty-state message and renders the result.

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

    var data = window.PW_DERIVE.graph.adapt(metrics, ctx, { emptyMsg: NO_GRAPH });
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
