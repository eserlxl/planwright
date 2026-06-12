// SPDX-FileCopyrightText: 2026 Eser KUBALI
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Console view — the mission-control landing (default tab). A glance-once screen for
// watching the explore->invent run converge: a hand-rolled SVG Convergence Reactor, four
// Health Vitals gauges that finally cash in the graph.json goldmine (coverage, hotspots,
// import cycles, coupling tension), a Cadence Ribbon of decision rhythm, and a Dirty Pulse
// rail of the files the last graph build touched. Read-only: everything is derived from
// /state.json and the metrics PW_DERIVE computes from /graph.json. The third render
// argument (ctx) carries { graphText, metrics, stale, builtSha, head } from app.js.

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

  // Source-of-truth provenance chip: which graph sha these numbers came from, flagged
  // when it lags HEAD (honesty about stale graph data).
  function shaChip(ctx) {
    var s = elt("span", "pw-sha" + (ctx && ctx.stale ? " pw-sha--stale" : ""));
    var sha = (ctx && ctx.builtSha) ? ctx.builtSha.slice(0, 7) : "—";
    s.textContent = "graph " + sha + (ctx && ctx.stale ? " · stale" : "");
    s.title = ctx && ctx.stale
      ? "graph.json was built at " + sha + ", behind HEAD — figures may lag the plan"
      : "graph.json built at " + sha;
    return s;
  }

  // ---- Convergence Reactor -------------------------------------------------------------

  function reactor(state) {
    var done = (state.completed || []).length;
    var pend = (state.pending || []).length;
    var kill = (state.rejected || []).length;
    var total = done + pend + kill;
    var ratio = total ? done / total : 0;
    var converged = !!state.converged;

    // Reactor state — three resting points, not two, so a drained plan (0 pending) that is
    // not a certified final point no longer mislabels as "IN PROGRESS":
    //   CONVERGED    — status certified a current, valid, whole-repo final point.
    //   IN PROGRESS  — there is pending work to implement (the only genuinely active state).
    //   STALE / IDLE — the plan is drained but not converged; the recorded final point (if
    //                  any) is stale/invalid/scoped, so HEAD moved on and a fresh plan would
    //                  re-open the ladder.
    var fp = state.final_point;
    var fpShown = window.PW_DERIVE.finalPointShown(fp);
    var fpFlag = fpShown ? window.PW_DERIVE.finalFlag(fp) : null;
    var inProgress = pend > 0;
    var verdictText = converged ? "CONVERGED" : inProgress ? "IN PROGRESS" : fpShown ? "STALE" : "IDLE";
    var noteText = converged
      ? "final point recorded; HEAD has not moved since"
      : inProgress
        ? (pend + " item" + (pend === 1 ? "" : "s") + " pending — run execute to implement")
        : fpFlag === "stale"
          ? ("plan drained, but the " + (fp.deepest_tier || "?") + " final point is stale — HEAD moved since " +
             (fp.date || "?") + "; run a plan to re-open the ladder")
          : fpFlag === "invalid"
            ? "plan drained, but the recorded final point failed validation — run a plan to re-establish convergence"
            : fpFlag === "scoped"
              ? "plan drained, but only a component-scoped final point is recorded — run a whole-repo plan"
              : fpShown
                ? "plan drained; HEAD moved since the final point — run a plan to confirm convergence"
                : "no pending work and no final point recorded — run a plan to assess the tree";

    var panel = elt("div", "pw-reactor");
    var size = 240, c = 120, R = 96, C = 2 * Math.PI * R;
    var s = svg("svg", {
      "class": "pw-reactor-svg", viewBox: "0 0 " + size + " " + size,
      role: "img",
      "aria-label": "Convergence: " + done + " accepted, " + pend + " pending, " +
        kill + " rejected of " + total,
    });

    // rotate the whole ring so 0% starts at the top
    var ring = svg("g", { transform: "rotate(-90 " + c + " " + c + ")" });
    ring.appendChild(svg("circle", {
      cx: c, cy: c, r: R, fill: "none", "class": "pw-reactor-track", "stroke-width": 16,
    }));
    var doneLen = ratio * C;
    var killLen = total ? (kill / total) * C : 0;
    if (doneLen > 0) {
      ring.appendChild(svg("circle", {
        cx: c, cy: c, r: R, fill: "none", "class": "pw-reactor-arc-progress",
        "stroke-width": 16, "stroke-linecap": "round",
        "stroke-dasharray": doneLen.toFixed(2) + " " + (C - doneLen).toFixed(2),
      }));
    }
    if (killLen > 0) {
      ring.appendChild(svg("circle", {
        cx: c, cy: c, r: R, fill: "none", "class": "pw-reactor-notch",
        "stroke-width": 16,
        "stroke-dasharray": killLen.toFixed(2) + " " + (C - killLen).toFixed(2),
        "stroke-dashoffset": (-doneLen).toFixed(2),
      }));
    }
    s.appendChild(ring);

    // core + spinning indicator (or breathing glow when converged)
    s.appendChild(svg("circle", {
      cx: c, cy: c, r: 70, "class": "pw-reactor-core" + (converged ? " is-converged" : ""),
    }));
    if (inProgress) {
      // spin only while work is genuinely pending — a drained/stale plan is at rest
      s.appendChild(svg("circle", {
        cx: c, cy: c, r: 80, fill: "none", "class": "pw-reactor-spin",
        "stroke-width": 2, "stroke-dasharray": "4 10",
      }));
    }

    var verdict = svg("text", {
      x: c, y: c - 4, "class": "pw-reactor-verdict " + (converged ? "is-ok" : "is-warn"),
      "text-anchor": "middle",
    });
    verdict.textContent = verdictText;
    s.appendChild(verdict);
    var sub = svg("text", { x: c, y: c + 20, "class": "pw-reactor-sub", "text-anchor": "middle" });
    sub.textContent = done + " / " + total + " · " + Math.round(ratio * 100) + "%";
    s.appendChild(sub);

    panel.appendChild(s);

    // satellite counters
    var sats = elt("div", "pw-reactor-sats");
    sats.appendChild(sat("accepted", done, "is-ok"));
    sats.appendChild(sat("pending", pend, "is-muted"));
    sats.appendChild(sat("rejected", kill, "is-err"));
    // Verified-but-cut dossier findings carried in the planning digest. Rendered only
    // when non-zero (mirroring status.report's zero-silence), so a snapshot without
    // the field — an older state.json — renders the satellites unchanged.
    var carried = (state.counts && state.counts.carried) || 0;
    if (carried > 0) {
      var carriedSat = sat("carried", carried, "is-muted");
      carriedSat.title = "cut/deferred dossier candidates — routing only, see digest.md";
      sats.appendChild(carriedSat);
    }
    if (fpShown) {
      var label = "final · " + (fp.deepest_tier || "?") + (fp.date ? " · " + fp.date : "");
      // PW_DERIVE.finalFlag: an invalid (fails lint-final) or component-scoped
      // final point must never render as a trusted whole-repo "set" — status
      // refuses to certify it, so do we.
      var flag = fpFlag;
      var fsat = elt("div", "pw-sat" +
        (flag === "stale" ? " is-stale"
          : flag === "invalid" ? " is-err"
            : flag === "scoped" ? " is-muted" : ""));
      fsat.appendChild(elt("span", "pw-sat-v", flag || "set"));
      fsat.appendChild(elt("span", "pw-sat-k", label));
      sats.appendChild(fsat);
    }
    panel.appendChild(sats);
    panel.appendChild(elt("div", "pw-reactor-note", noteText));
    // Run-activity beacon: WHICH command is executing right now (state.activity,
    // stamped by the command flows via `state.py activity`). Rendered only for a
    // well-formed beacon — an older snapshot without the field leaves the reactor
    // unchanged — and never reuses the IN PROGRESS vocabulary: that verdict means
    // pending items exist, this line means a run is live this second.
    var act = state.activity;
    if (window.PW_DERIVE.activityShown(act)) {
      var live = elt("div", "pw-reactor-activity" + (act.stale ? " is-stale" : ""));
      live.appendChild(elt("span", "pw-reactor-activity-dot"));
      live.appendChild(elt("span", "pw-reactor-activity-text",
        window.PW_DERIVE.activityLabel(act)));
      live.title = act.stale
        ? "beacon last stamped " + (act.started || "?") +
          " and not refreshed within its TTL — the run may have been interrupted " +
          "(state.py activity stop clears a leftover)"
        : "a command flow stamped this run at " + (act.started || "?");
      panel.appendChild(live);
    }
    return panel;
  }

  function sat(label, value, cls) {
    var d = elt("div", "pw-sat " + (cls || ""));
    d.appendChild(elt("span", "pw-sat-v", String(value)));
    d.appendChild(elt("span", "pw-sat-k", label));
    return d;
  }

  // ---- Health Vitals -------------------------------------------------------------------

  function vitalCard(modifier, ariaLabel, onActivate) {
    var b = elt("button", "pw-vital " + modifier);
    b.type = "button";
    b.setAttribute("aria-label", ariaLabel);
    b.addEventListener("click", onActivate);
    return b;
  }

  function vitals(metrics, ctx) {
    var row = elt("div", "pw-vitals");
    if (!metrics) {
      var note = elt("div", "pw-empty", "Vitals need a built graph (run a plan to build .planwright/graph.json).");
      row.appendChild(note);
      return row;
    }

    // 1) coverage donut
    var cov = metrics.coverage;
    var covRatio = cov.total ? cov.covered / cov.total : 0;
    // Plain goto: a sentinel focus payload had no consumer and would clobber the
    // user's real cross-view focus (the one thing the bus exists to carry).
    var v1 = vitalCard("pw-vital--coverage", "Test coverage " + cov.covered + " of " + cov.total +
      " files. Open Insights.", function () { window.PW_BUS.goto("insights"); });
    var donut = svg("svg", { "class": "pw-vital-svg", viewBox: "0 0 64 64", "aria-hidden": "true" });
    var DC = 2 * Math.PI * 26;
    donut.appendChild(svg("circle", { cx: 32, cy: 32, r: 26, fill: "none", "class": "pw-gauge-track", "stroke-width": 8 }));
    donut.appendChild(svg("circle", {
      cx: 32, cy: 32, r: 26, fill: "none", "class": "pw-gauge-fill ok", "stroke-width": 8,
      "stroke-linecap": "round", transform: "rotate(-90 32 32)",
      "stroke-dasharray": (covRatio * DC).toFixed(2) + " " + DC.toFixed(2),
    }));
    var covTitle = "Coverage by language:\n" + Object.keys(cov.byLang).sort(function (a, b) {
      return cov.byLang[b].total - cov.byLang[a].total;
    }).map(function (l) {
      var x = cov.byLang[l]; return "  " + l + ": " + x.cov + "/" + x.total;
    }).join("\n");
    svgTitle(donut, covTitle);
    v1.appendChild(donut);
    v1.appendChild(vitalText("coverage", cov.covered + "/" + cov.total, Math.round(covRatio * 100) + "% covered"));
    v1.appendChild(shaChip(ctx));
    row.appendChild(v1);

    // 2) hotspots mini bar meter
    var hot = metrics.hotUncovered.length;
    var v2 = vitalCard("pw-vital--hotspots", hot + " untested hotspots (churn × centrality). Open Insights.",
      function () { window.PW_BUS.goto("insights"); });
    var bars = svg("svg", { "class": "pw-vital-svg", viewBox: "0 0 64 64", "aria-hidden": "true" });
    var top = metrics.hotspots.slice(0, 7);
    var maxRisk = top.length ? top[0].risk || 0.0001 : 1;
    top.forEach(function (n, i) {
      var h = 6 + 44 * (maxRisk ? (n.risk || 0) / maxRisk : 0);
      bars.appendChild(svg("rect", {
        x: 6 + i * 8, y: 58 - h, width: 5, height: h, rx: 1.5,
        "class": "pw-gauge-bar" + (n.covered ? "" : " uncovered"),
      }));
    });
    v2.appendChild(bars);
    v2.appendChild(vitalText("hotspots", hot + " hot", "churn × centrality, untested"));
    v2.appendChild(shaChip(ctx));
    row.appendChild(v2);

    // import cycles count badge — a secondary structural-debt signal (usually empty on a
    // healthy, acyclic graph), so it is appended LAST (after the frontier card below),
    // after the actionable vitals.
    var cyc = metrics.cycles.length;
    var v3 = vitalCard("pw-vital--cycles" + (cyc > 0 ? " is-alert" : ""),
      cyc + " import cycles. Open Insights.",
      function () { window.PW_BUS.goto("insights"); });
    var badge = svg("svg", { "class": "pw-vital-svg", viewBox: "0 0 64 64", "aria-hidden": "true" });
    badge.appendChild(svg("circle", { cx: 32, cy: 32, r: 26, fill: "none", "class": "pw-gauge-track", "stroke-width": 6 }));
    if (cyc > 0) badge.appendChild(svg("circle", { cx: 32, cy: 32, r: 26, fill: "none", "class": "pw-gauge-fill err", "stroke-width": 6 }));
    var bn = svg("text", { x: 32, y: 40, "text-anchor": "middle", "class": "pw-gauge-num" });
    bn.textContent = String(cyc);
    badge.appendChild(bn);
    v3.appendChild(badge);
    v3.appendChild(vitalText("cycles", cyc === 0 ? "none" : String(cyc), cyc === 0 ? "no import cycles" : "import cycles"));
    v3.appendChild(shaChip(ctx));
    // v3 (import cycles) is appended LAST — see after the frontier card below.

    // 4) coupling tension horizontal fill
    var share = metrics.couplingStrongShare;
    var v4 = vitalCard("pw-vital--coupling", Math.round(share * 100) +
      " percent tight coupling. Open the Coupling Web.",
      function () { window.PW_BUS.goto("graph"); });
    var fill = svg("svg", { "class": "pw-vital-svg pw-vital-svg--wide", viewBox: "0 0 64 64", "aria-hidden": "true" });
    fill.appendChild(svg("rect", { x: 6, y: 28, width: 52, height: 8, rx: 4, "class": "pw-gauge-track-h" }));
    fill.appendChild(svg("rect", { x: 6, y: 28, width: (52 * share).toFixed(1), height: 8, rx: 4, "class": "pw-gauge-fill-h" }));
    v4.appendChild(fill);
    v4.appendChild(vitalText("coupling", Math.round(share * 100) + "%",
      metrics.couplingStrong + " of " + metrics.couplingEdges.length + " links w≥0.8"));
    v4.appendChild(shaChip(ctx));
    row.appendChild(v4);

    // 5) audit-frontier backlog — the cold work explore/cycle escalate into. Shown only
    // when the graph carries a frontier (older pre-frontier graphs render the strip
    // unchanged), so the glance screen can tell "truly dry" from "cold work remains".
    if (metrics.frontier) {
      var na = metrics.frontier.never_audited || 0;
      var fst = metrics.frontier.stale || 0;
      var v5 = vitalCard("pw-vital--frontier" + (na > 0 ? " is-alert" : ""),
        na + " never-audited, " + fst + " stale — the audit backlog explore/cycle escalate into. Open Insights.",
        function () { window.PW_BUS.goto("insights"); });
      var fbadge = svg("svg", { "class": "pw-vital-svg", viewBox: "0 0 64 64", "aria-hidden": "true" });
      fbadge.appendChild(svg("circle", { cx: 32, cy: 32, r: 26, fill: "none", "class": "pw-gauge-track", "stroke-width": 6 }));
      if (na > 0) fbadge.appendChild(svg("circle", { cx: 32, cy: 32, r: 26, fill: "none", "class": "pw-gauge-fill warn", "stroke-width": 6 }));
      var fbn = svg("text", { x: 32, y: 40, "text-anchor": "middle", "class": "pw-gauge-num" });
      fbn.textContent = String(na + fst);
      fbadge.appendChild(fbn);
      v5.appendChild(fbadge);
      v5.appendChild(vitalText("frontier", (na + fst) === 0 ? "clear" : String(na + fst),
        na + " never-audited · " + fst + " stale"));
      v5.appendChild(shaChip(ctx));
      row.appendChild(v5);
    }

    // Structural context cards (counts), filling the row before the cycles card.
    function countVital(modifier, count, key, sub, aria, dest) {
      var card = vitalCard(modifier, aria, function () { window.PW_BUS.goto(dest); });
      var g = svg("svg", { "class": "pw-vital-svg", viewBox: "0 0 64 64", "aria-hidden": "true" });
      g.appendChild(svg("circle", { cx: 32, cy: 32, r: 26, fill: "none", "class": "pw-gauge-track", "stroke-width": 6 }));
      var t = svg("text", { x: 32, y: 40, "text-anchor": "middle", "class": "pw-gauge-num" });
      t.textContent = String(count);
      g.appendChild(t);
      card.appendChild(g);
      card.appendChild(vitalText(key, String(count), sub));
      card.appendChild(shaChip(ctx));
      return card;
    }

    // 6) total tracked files in the graph
    row.appendChild(countVital("pw-vital--files", metrics.nodeCount, "files", "tracked files",
      metrics.nodeCount + " tracked files in the graph. Open the Coupling Web.", "graph"));

    // 7) articulation points — cut vertices whose failure has wide blast radius
    var arts = metrics.nodesArr.filter(function (n) { return n.articulation; }).length;
    row.appendChild(countVital("pw-vital--articulation", arts, "articulation", "cut vertices",
      arts + " articulation points (cut vertices, wide blast radius). Open Insights.", "insights"));

    // 8) test files in the tree (a rough test-surface count alongside line coverage)
    var tcount = metrics.nodesArr.filter(function (n) { return n.isTest; }).length;
    row.appendChild(countVital("pw-vital--tests", tcount, "tests", "test files",
      tcount + " test files in the tree. Open the Coupling Web.", "graph"));

    // Import cycles last: a secondary structural-debt signal, shown after the actionable
    // vitals (coverage, hotspots, coupling, frontier) and the context cards.
    row.appendChild(v3);

    return row;
  }

  function vitalText(k, v, sub) {
    var wrap = elt("div", "pw-vital-text");
    wrap.appendChild(elt("span", "pw-vital-k", k));
    wrap.appendChild(elt("span", "pw-vital-v", v));
    wrap.appendChild(elt("span", "pw-vital-sub", sub));
    return wrap;
  }

  // ---- Cadence Ribbon ------------------------------------------------------------------

  function cadence(state) {
    var completed = state.completed || [];
    var rejected = state.rejected || [];
    var panel = elt("div", "pw-cadence");
    var head = elt("div", "pw-cadence-head");
    head.appendChild(elt("span", "pw-section-mini", "Decision cadence"));
    var done = completed.length, kill = rejected.length;
    var rate = (done + kill) ? Math.round(100 * done / (done + kill)) : 0;
    head.appendChild(elt("span", "pw-cadence-rate", rate + "% accepted"));
    panel.appendChild(head);

    var cap = 60;
    var cShow = completed.slice(-cap), rShow = rejected.slice(-cap);
    var n = Math.max(cShow.length, rShow.length, 1);
    var W = n * 3 + 2, H = 40, mid = 20;
    var s = svg("svg", {
      "class": "pw-cadence-svg", viewBox: "0 0 " + W + " " + H,
      preserveAspectRatio: "none", "aria-hidden": "true",
    });
    s.appendChild(svg("line", { x1: 0, y1: mid, x2: W, y2: mid, "class": "pw-cadence-mid" }));
    cShow.forEach(function (it, i) {
      s.appendChild(svg("rect", {
        x: 1 + i * 3, y: mid - 14, width: 2, height: 14, rx: 0.6,
        "class": "pw-cadence-tick up mode-" + (it.mode || "other"),
      }));
    });
    rShow.forEach(function (it, i) {
      s.appendChild(svg("rect", {
        x: 1 + i * 3, y: mid, width: 2, height: 12, rx: 0.6, "class": "pw-cadence-tick down",
      }));
    });
    panel.appendChild(s);

    // mode legend (accepted ticks are colored by mode; rejected ticks are red, below the line)
    var counts = {};
    completed.forEach(function (it) { var m = it.mode || "other"; counts[m] = (counts[m] || 0) + 1; });
    var legend = elt("div", "pw-legend");
    ["repair", "improve", "develop", "docs", "reorganize", "other"].forEach(function (m) {
      if (!counts[m]) return;
      var leg = elt("span", "pw-legend-item mode-" + m);
      leg.appendChild(elt("span", "pw-legend-sw"));
      leg.appendChild(elt("span", null, m + " " + counts[m]));
      legend.appendChild(leg);
    });
    if (rejected.length) {
      var rj = elt("span", "pw-legend-item is-rej");
      rj.appendChild(elt("span", "pw-legend-sw"));
      rj.appendChild(elt("span", null, "rejected " + rejected.length));
      legend.appendChild(rj);
    }
    panel.appendChild(legend);

    var foot = elt("div", "pw-cadence-foot");
    var truncated = completed.length > cap || rejected.length > cap;
    foot.textContent = (truncated ? "last " + cap + " of " + completed.length + " accepted / " +
      rejected.length + " rejected · " : "") + "log order, not wall-clock";
    panel.appendChild(foot);
    return panel;
  }

  // ---- Session trend -------------------------------------------------------------------
  // A live, wall-clock sparkline of accepted / pending / rejected across the session, from the
  // client-timestamped snapshots app.js captures (the logs carry no per-item timestamps,
  // so this is the only true time axis the dashboard has).

  function legItem(key, label) {
    var w = elt("span", "pw-trend-leg-item");
    w.appendChild(elt("span", "pw-trend-swatch is-" + key));
    w.appendChild(elt("span", null, label));
    return w;
  }

  function sessionTrend(ctx) {
    var data = (ctx && ctx.trend) || [];
    var panel = elt("div", "pw-trend");
    var head = elt("div", "pw-cadence-head");
    head.appendChild(elt("span", "pw-section-mini", "Session trend"));
    var leg = elt("span", "pw-trend-legend");
    leg.appendChild(legItem("done", "accepted"));
    leg.appendChild(legItem("pend", "pending"));
    leg.appendChild(legItem("kill", "rejected"));
    head.appendChild(leg);
    panel.appendChild(head);

    if (data.length < 2) {
      panel.appendChild(elt("div", "pw-empty",
        "Collecting session history — the lines grow as the plan changes."));
      return panel;
    }

    var W = 600, H = 92, padL = 6, padR = 10, padT = 10, padB = 16;
    var t0 = data[0].t, t1 = data[data.length - 1].t, span = (t1 - t0) || 1;
    var maxV = 1;
    data.forEach(function (p) { maxV = Math.max(maxV, p.done, p.pend, p.kill); });
    function X(p) { return padL + ((p.t - t0) / span) * (W - padL - padR); }
    function Y(v) { return H - padB - (v / maxV) * (H - padT - padB); }

    var s = svg("svg", { "class": "pw-trend-svg", viewBox: "0 0 " + W + " " + H,
      preserveAspectRatio: "none", "aria-hidden": "true" });
    s.appendChild(svg("line", { x1: padL, y1: H - padB, x2: W - padR, y2: H - padB, "class": "pw-trend-axis" }));
    ["done", "pend", "kill"].forEach(function (key) {
      var pts = data.map(function (p) { return X(p).toFixed(1) + "," + Y(p[key]).toFixed(1); }).join(" ");
      s.appendChild(svg("polyline", { points: pts, "class": "pw-trend-line is-" + key }));
      var last = data[data.length - 1];
      s.appendChild(svg("circle", { cx: X(last).toFixed(1), cy: Y(last[key]).toFixed(1), r: 2.6, "class": "pw-trend-dot is-" + key }));
    });
    panel.appendChild(s);

    var last = data[data.length - 1];
    var mins = Math.max(0, Math.round((t1 - t0) / 60000));
    panel.appendChild(elt("div", "pw-cadence-foot",
      "accepted " + last.done + " · pending " + last.pend + " · rejected " + last.kill +
      " · " + data.length + " snapshots over ~" + mins + " min (this session)"));
    return panel;
  }

  // ---- Dirty Pulse rail ----------------------------------------------------------------

  var prevChanged = null;   // for blooming only newly-changed files across renders

  function pulserail(state, metrics, ctx) {
    var rail = elt("aside", "pw-pulserail");
    var head = elt("div", "pw-pulserail-head");
    head.appendChild(elt("span", "pw-section-mini", "Dirty pulse"));
    head.appendChild(shaChip(ctx));
    rail.appendChild(head);

    if (!metrics) {
      rail.appendChild(elt("div", "pw-empty", "graph not built yet"));
      prevChanged = null;
      return rail;
    }

    var reason = metrics.dirtyReason || "—";
    var dirtyCount = (state.graph && state.graph.dirty_node_count != null)
      ? state.graph.dirty_node_count : metrics.dirty && (metrics.dirty.nodes || []).length;
    rail.appendChild(elt("div", "pw-pulserail-sub",
      reason + (metrics.isFirstRun ? " · first run" : "") + " · " + (dirtyCount || 0) + " nodes dirty"));

    var changed = metrics.dirtyChanged || [];
    if (!changed.length) {
      rail.appendChild(elt("div", "pw-empty", "nothing changed since last build"));
    } else {
      var list = elt("ul", "pw-pulse-list");
      var cap = 12;
      changed.slice(0, cap).forEach(function (p) {
        var li = elt("li", "pw-pulse-item");
        if (prevChanged && prevChanged.indexOf(p) === -1) li.classList.add("pw-bloom");
        var node = metrics.byPath[p];
        li.appendChild(elt("span", "pw-pulse-lang " + langClass(node && node.lang)));
        var name = p.split("/").pop();
        var label = elt("span", "pw-pulse-name", name);
        label.title = p;
        li.appendChild(label);
        list.appendChild(li);
      });
      rail.appendChild(list);
      if (changed.length > cap) {
        rail.appendChild(elt("div", "pw-pulse-more", "+" + (changed.length - cap) + " more"));
      }
    }
    prevChanged = changed.slice();
    return rail;
  }

  // ---- compose -------------------------------------------------------------------------

  function render(container, state, ctx) {
    container.textContent = "";
    ctx = ctx || {};
    var metrics = ctx.metrics || null;

    var grid = elt("div", "pw-console-grid");
    var main = elt("div", "pw-console-main");
    main.appendChild(reactor(state));
    main.appendChild(vitals(metrics, ctx));
    main.appendChild(cadence(state));
    main.appendChild(sessionTrend(ctx));
    grid.appendChild(main);
    grid.appendChild(pulserail(state, metrics, ctx));
    container.appendChild(grid);
  }

  window.PW_VIEWS.console = render;
})();
