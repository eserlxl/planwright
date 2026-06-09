// SPDX-FileCopyrightText: 2026 Eser KUBALI
// SPDX-License-Identifier: GPL-3.0-or-later
//
// PW_DERIVE — a pure, dependency-free metrics engine for the dashboard. It turns the
// rich (but mostly-unused) .planwright/graph.json into the derived quantities the
// Console and Insights views render: percentile-ranked risk (churn x centrality),
// coverage by language, hotspots, temporal-coupling tension, import cycles, and the
// dirty set. No DOM, no fetch — the views fetch /graph.json (app.js does it once per
// change) and hand the raw text here.
//
// Memoize-on-raw-bytes: metrics(graphText) caches its result keyed on the exact text,
// so re-deriving on an unchanged graph during an active run is a no-op. This mirrors
// the lastSig discipline the graph view already uses to avoid redundant work.
//
// PW_BUS — a tiny framework-free selection bus so a click in one view (a Plan surface
// chip, a Risk Ledger row, a cycle card) can focus a node and cross-highlight it in
// the Constellation and Coupling Web. Read-only: it carries view-state only, never
// mutates the repo.

(function () {
  "use strict";

  // ---- percentile helpers (small n; linear scans are fine even at hundreds of nodes) --

  function ascending(a, b) { return a - b; }

  // Fraction of values strictly less than v, normalised to [0,1]. Ties share a rank.
  // An empty/singleton set yields 0 (no spread to rank against).
  function pctRank(sortedAsc, v) {
    var n = sortedAsc.length;
    if (n <= 1) return 0;
    var lo = 0;
    while (lo < n && sortedAsc[lo] < v) lo++;
    return lo / (n - 1);
  }

  // The value at the given quantile (0..1) of an ascending-sorted array.
  function quantile(sortedAsc, q) {
    var n = sortedAsc.length;
    if (!n) return 0;
    return sortedAsc[Math.min(n - 1, Math.max(0, Math.floor(q * (n - 1))))];
  }

  function basename(p) {
    var i = p.lastIndexOf("/");
    return i === -1 ? p : p.slice(i + 1);
  }
  function dirname(p) {
    var i = p.lastIndexOf("/");
    return i === -1 ? "" : p.slice(0, i + 1);
  }

  var _lastText, _lastResult;

  // Build the full derived-metrics record from the raw graph.json text. Returns null
  // when the text is absent or unparseable or carries no nodes (callers degrade to a
  // "graph not built" state). The shape is documented at the top of this file.
  function metrics(graphText) {
    if (graphText == null) return null;
    if (graphText === _lastText) return _lastResult;

    var g;
    try { g = JSON.parse(graphText); } catch (e) { g = null; }
    var nodes = (g && g.nodes) || null;
    if (!g || !nodes || typeof nodes !== "object" || !Object.keys(nodes).length) {
      _lastText = graphText; _lastResult = null;
      return null;
    }

    var paths = Object.keys(nodes);
    var nodesArr = paths.map(function (p) {
      var n = nodes[p] || {};
      return {
        path: p,
        base: basename(p),
        dir: dirname(p),
        loc: +n.loc || 0,
        lang: n.lang || "unknown",
        churn: +n.git_churn || 0,
        pagerank: +n.pagerank || 0,
        covered: !!n.covered_by_test,
        isTest: !!n.is_test,
        articulation: !!n.is_articulation,
        defines: (n.defines || []).length,
        branchCount: +n.branch_count || 0,
        imports: n.imports || [],
      };
    });

    var churns = nodesArr.map(function (n) { return n.churn; }).sort(ascending);
    var prs = nodesArr.map(function (n) { return n.pagerank; }).sort(ascending);
    var maxChurn = churns[churns.length - 1] || 0;
    var maxPr = prs[prs.length - 1] || 0;
    var maxLoc = 0;
    nodesArr.forEach(function (n) { if (n.loc > maxLoc) maxLoc = n.loc; });

    // Percentile-ranked risk: composite of where a node sits in the churn and pagerank
    // distributions (NOT absolute cutoffs — those would misfire on a different repo).
    var risks = [];
    nodesArr.forEach(function (n) {
      n.churnPct = pctRank(churns, n.churn);
      n.prPct = pctRank(prs, n.pagerank);
      n.risk = n.churnPct * n.prPct;
      risks.push(n.risk);
    });
    risks.sort(ascending);

    var churn_p66 = quantile(churns, 0.66);
    var pr_p66 = quantile(prs, 0.66);
    var risk_p66 = quantile(risks, 0.66);
    // p75 axis thresholds give a tighter "danger corner" than p66 on this skewed data
    // (median churn ≈ 4), so the shaded quadrant marks a meaningful minority, not most
    // of the plot.
    var churn_p75 = quantile(churns, 0.75);
    var pr_p75 = quantile(prs, 0.75);

    // Coverage, overall and bucketed by language (the real 10-way split; clusters are
    // mostly singletons, so language is the meaningful grouping).
    var covered = 0;
    var byLang = {};
    nodesArr.forEach(function (n) {
      if (n.covered) covered++;
      var b = byLang[n.lang] || (byLang[n.lang] = { lang: n.lang, cov: 0, total: 0 });
      b.total++;
      if (n.covered) b.cov++;
    });

    var hotspots = nodesArr.slice().sort(function (a, b) { return b.risk - a.risk; });
    // "Hot" = the top tercile by risk RANK (robust to the many zero-risk ties that a
    // value threshold like risk_p66 collapses on). hotUncovered is the actionable subset:
    // top-tercile risk, no covering test, not itself a test.
    var hotCount = Math.max(1, Math.ceil(hotspots.length / 3));
    var hotSet = hotspots.slice(0, hotCount);
    var hotPathSet = {};
    hotSet.forEach(function (n) { hotPathSet[n.path] = true; });
    var hotUncovered = hotSet.filter(function (n) { return !n.covered && !n.isTest; });
    // "Central but untested": high pagerank, no covering test — the actionable gap.
    var centralUntested = nodesArr.filter(function (n) {
      return !n.covered && !n.isTest && n.prPct >= 0.66;
    }).sort(function (a, b) { return b.pagerank - a.pagerank; });

    var couplingEdges = (g.coupling_edges || []).filter(function (e) {
      return e && e.a != null && e.b != null;
    });
    var strong = couplingEdges.filter(function (e) { return (+e.weight || 0) >= 0.8; });
    var couplingStrongShare = couplingEdges.length
      ? strong.length / couplingEdges.length : 0;

    var clusters2 = (g.clusters || []).filter(function (c) {
      return c && c.members && c.members.length >= 2;
    });

    var dirty = g.dirty || {};
    var dirtySet = {};
    (dirty.nodes || []).forEach(function (p) { dirtySet[p] = true; });

    var result = {
      builtSha: g.graph_built_at_sha || "",
      target: g.target || "",
      byPath: (function () {
        var m = {}; nodesArr.forEach(function (n) { m[n.path] = n; }); return m;
      })(),
      nodesArr: nodesArr,
      nodeCount: nodesArr.length,
      maxChurn: maxChurn, maxPr: maxPr, maxLoc: maxLoc,
      churn_p66: churn_p66, pr_p66: pr_p66, risk_p66: risk_p66,
      churn_p75: churn_p75, pr_p75: pr_p75,
      coverage: { covered: covered, total: nodesArr.length, byLang: byLang },
      hotspots: hotspots,
      hotSet: hotSet,
      hotPathSet: hotPathSet,
      hotUncovered: hotUncovered,
      centralUntested: centralUntested,
      couplingEdges: couplingEdges,
      couplingStrong: strong.length,
      couplingStrongShare: couplingStrongShare,
      cycles: g.import_cycles || [],
      clusters: clusters2,
      ranked: g.ranked || [],
      rankedCode: g.ranked_code || [],
      dirty: dirty,
      dirtyChanged: dirty.changed || [],
      dirtySet: dirtySet,
      dirtyReason: dirty.reason || "",
      isFirstRun: !!dirty.is_first_run,
    };

    _lastText = graphText;
    _lastResult = result;
    return result;
  }

  // ---- coach: the Commands view's "which sweep fits right now" heuristic ----------------
  // Pure (DOM-free) decision logic, kept here next to metrics (which it reads) so it can be
  // unit-tested rather than living trapped in the view's IIFE. The Commands view renders
  // these results; the truth table itself is pinned by tests/cases/derive.sh.

  // Distil the live state + graph metrics into the signals the recommendation reads.
  function coachSignals(state, metrics) {
    var pending = state.pending || [];
    var cov = metrics ? metrics.coverage : null;
    return {
      hasGraph: !!metrics,
      pending: pending.length,
      pendRepairImprove: pending.filter(function (p) {
        return p.mode === "repair" || p.mode === "improve";
      }).length,
      completed: (state.completed || []).length,
      rejected: (state.rejected || []).length,
      converged: !!state.converged,
      cycles: metrics ? metrics.cycles.length : 0,
      hotUncovered: metrics ? metrics.hotUncovered.length : 0,
      articulation: metrics ? metrics.nodesArr.filter(function (n) { return n.articulation; }).length : 0,
      coveragePct: cov && cov.total ? Math.round((cov.covered / cov.total) * 100) : null,
    };
  }

  // The heuristic: debt → harden (codvisor); dry → grow (codinventor); else keep the rhythm.
  function coachRecommend(s) {
    var hasDebt = s.cycles > 0 || s.hotUncovered >= 3 || s.articulation > 0 || s.pendRepairImprove > 0;
    if (hasDebt) {
      return { key: "codvisor", why: "There's structural debt to harden before growing — clear it first." };
    }
    if (s.pending === 0) {
      return { key: "codinventor", why: "Nothing's queued and the tree is clean — latent capability looks complete, so grow net-new." };
    }
    return { key: "codcycle", why: "A healthy mix — planned work to finish and room to grow. Keep the harden→grow rhythm." };
  }

  // The numbers shown beneath the recommendation, per recommended command.
  function coachEvidence(key, s) {
    if (!s.hasGraph) return [s.pending + " pending", s.completed + " accepted", s.rejected + " rejected"];
    if (key === "codvisor") {
      return [s.cycles + " import cycles", s.hotUncovered + " untested hotspots",
              s.articulation + " articulation risks", s.pendRepairImprove + " repair/improve pending"];
    }
    if (key === "codinventor") {
      return [s.pending + " pending", s.cycles + " cycles", s.converged ? "converged" : "no open debt"];
    }
    return [s.pending + " pending", s.completed + " accepted so far"];
  }

  // A supplementary cold-start nudge, surfaced only when the project is CONVERGED (at a
  // current final point). The incremental audit is dry — but it only ever asserted dryness
  // relative to what changed since the last run, so a `planwright reset` (which clears
  // .planwright/ but keeps rejected.md) forces a whole-tree cold-start re-audit that can
  // re-surface work the dirty-set gating skipped. Returns null when not converged (nothing
  // to suggest yet) so the view shows it only when it is actually the useful next move.
  function coachReset(s) {
    if (!s.converged) return null;
    return {
      cmd: "/planwright reset",
      why: "Converged — but that final point is incremental (dry only against what changed). " +
           "A reset clears .planwright/ for a whole-tree cold-start re-audit that can re-surface " +
           "work the incremental pass skipped; rejected.md is kept, then follow with /codvisor.",
    };
  }

  // ---- pending: the Plan view's per-mode tally (filter pills) --------------------------
  // Pure mode-counting kept here so it can be node-tested rather than living inline in the
  // Plan view. state.pending_modes is often empty in live snapshots, so the view recomputes
  // the counts from pending[].mode; a missing mode buckets as "other".
  function pendingModes(pending) {
    var modes = {};
    (pending || []).forEach(function (p) {
      var m = (p && p.mode) || "other";
      modes[m] = (modes[m] || 0) + 1;
    });
    return modes;
  }

  // ---- graph: shape PW_DERIVE.metrics into the Coupling Web renderer's data ------------
  // The set of file paths that participate in any import cycle (for the "in cycle" badge the
  // Plan cross-link chips and the Insights Next-up list both render). Pure and DOM-free,
  // tolerating a missing/empty cycles array so a metrics object without cycles yields {}.
  function cycleMembers(metrics) {
    var s = {};
    ((metrics && metrics.cycles) || []).forEach(function (c) {
      c.forEach(function (p) { s[p] = true; });
    });
    return s;
  }

  // Pure (DOM-free) shaping kept here next to metrics (which it consumes), so the top-N
  // selection + keepSet pruning can be unit-tested rather than living trapped in the Graph
  // view's IIFE. Keeps the most-central `topNodes` nodes (default 60) and only the
  // coupling/import/cycle/cluster structure among them — dropping any cycle/cluster left
  // with fewer than 2 kept members — which enforces the renderer's no-dangling-edge
  // invariant (every edge/importEdge endpoint passed on is in the kept node set). The
  // empty-state message is injected by the caller so the string has one owner (the view).
  function graphAdapt(metrics, ctx, opts) {
    opts = opts || {};
    var topNodes = opts.topNodes || 60;
    var emptyMsg = opts.emptyMsg || "";

    var kept = metrics.nodesArr.slice().sort(function (a, b) {
      return (b.pagerank || 0) - (a.pagerank || 0);
    }).slice(0, topNodes);
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
      clusters: clustersK, total: metrics.nodeCount, emptyMsg: emptyMsg,
      stale: !!(ctx && ctx.stale), builtSha: ctx && ctx.builtSha,
    };
  }

  window.PW_DERIVE = {
    metrics: metrics, pctRank: pctRank, quantile: quantile, pendingModes: pendingModes,
    coach: { signals: coachSignals, recommend: coachRecommend, evidence: coachEvidence, reset: coachReset },
    graph: { adapt: graphAdapt, cycleMembers: cycleMembers },
  };

  // ---- PW_BUS: cross-view selection (view-state only) ----------------------------------
  // A single current-focus plus a small subscriber list. Views re-subscribe on every
  // render and store the returned unsubscribe, so listeners never accumulate across the
  // re-renders app.js fires on each SSE change.

  var _focus = null;
  var _listeners = [];
  var _navigate = null;   // wired by app.js to the tab router

  function emit() {
    for (var i = 0; i < _listeners.length; i++) {
      try { _listeners[i](_focus); } catch (e) { /* a dead view must not break the bus */ }
    }
  }

  window.PW_BUS = {
    // app.js calls this once to connect the bus to tab routing.
    setNavigator: function (fn) { _navigate = typeof fn === "function" ? fn : null; },
    // Switch view (and optionally carry a focus path). Used by the vitals shortcuts.
    goto: function (view, opts) {
      if (opts && opts.focus) _focus = opts.focus;
      if (_navigate) _navigate(view);
      if (opts && opts.focus) emit();
    },
    // Focus a file path and reveal it (defaults to the Insights view), then cross-light.
    focusNode: function (path, opts) {
      _focus = path || null;
      var view = (opts && opts.view) || "insights";
      if (_navigate) _navigate(view);
      emit();
    },
    onFocus: function (cb) {
      if (typeof cb !== "function") return function () {};
      _listeners.push(cb);
      return function () {
        var i = _listeners.indexOf(cb);
        if (i !== -1) _listeners.splice(i, 1);
      };
    },
    getFocus: function () { return _focus; },
    clearFocus: function () { _focus = null; emit(); },
  };
})();
