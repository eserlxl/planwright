// SPDX-FileCopyrightText: 2026 Eser KUBALI
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Cycle-timeline view: the progression of items accepted (completed) and rejected
// (rejected) over the run, derived purely from /state.json's completed[]/rejected[]
// logs — which planwright appends in chronological (FIFO) order — plus the recorded
// final-point date. No new instrumentation: it shows only what the logs already record.
// Because the logs carry no per-item timestamps, entries are ordered by log position.

(function () {
  "use strict";

  window.PW_VIEWS = window.PW_VIEWS || {};

  function elt(tag, cls, text) {
    var e = document.createElement(tag);
    if (cls) e.className = cls;
    if (text != null) e.textContent = text;
    return e;
  }

  var SVG_NS = "http://www.w3.org/2000/svg";
  var MODES = ["repair", "improve", "develop", "docs", "reorganize", "other"];

  function svgEl(tag, attrs) {
    var e = document.createElementNS(SVG_NS, tag);
    for (var k in attrs) { if (Object.prototype.hasOwnProperty.call(attrs, k)) e.setAttribute(k, String(attrs[k])); }
    return e;
  }

  function svgTitle(text) {
    var t = document.createElementNS(SVG_NS, "title");
    t.textContent = text;
    return t;
  }

  // The timeline graph: a cumulative burn-up of accepted decisions by mode. Each line is
  // one mode climbing to its total across the accepted log (chronological FIFO), so the
  // slopes show when each kind of work landed in the run. Honest about the data: the
  // x-axis is log position, not wall-clock, since entries carry no per-item timestamps.
  // Rejected decisions have no aligned position in the accepted log, so they are summarized
  // in the header, never plotted (avoids implying accepted[i] and rejected[i] are paired).
  function timelineGraph(completed, rejected) {
    var wrap = elt("div", "pw-tlgraph");
    var done = completed.length, kill = rejected.length, tot = done + kill;
    var rate = tot ? Math.round(100 * done / tot) : 0;

    var head = elt("div", "pw-tlgraph-head");
    head.appendChild(elt("span", "pw-section-mini", "Decision timeline"));
    head.appendChild(elt("span", "pw-tlgraph-rate",
      rate + "% accepted (" + done + "/" + tot + ")" + (kill ? " · " + kill + " rejected" : "")));
    wrap.appendChild(head);

    if (!done) {
      wrap.appendChild(elt("div", "pw-empty", kill + " rejected, none accepted yet."));
      return wrap;
    }

    // running cumulative per mode after each accepted step
    var run = {}; MODES.forEach(function (m) { run[m] = 0; });
    var snaps = [];
    completed.forEach(function (it) {
      var m = MODES.indexOf(it.mode) >= 0 ? it.mode : "other";
      run[m] += 1;
      var snap = {}; MODES.forEach(function (mm) { snap[mm] = run[mm]; });
      snaps.push(snap);
    });
    var maxY = 1; MODES.forEach(function (m) { if (run[m] > maxY) maxY = run[m]; });

    var W = 600, H = 120, padT = 8, padB = 10, padX = 4;
    var plotW = W - padX * 2, plotH = H - padT - padB, y0 = H - padB;
    function xAt(i) { return padX + (done <= 1 ? plotW : (i + 1) / done * plotW); }
    function yAt(v) { return padT + plotH - (v / maxY) * plotH; }

    var s = svgEl("svg", {
      "class": "pw-tlgraph-svg", viewBox: "0 0 " + W + " " + H,
      preserveAspectRatio: "none", role: "img",
      "aria-label": "Cumulative accepted decisions by mode over " + done + " accepted (log order); " +
        kill + " rejected",
    });
    s.appendChild(svgEl("line", { x1: padX, y1: y0, x2: W - padX, y2: y0, "class": "pw-tlgraph-axis" }));
    MODES.forEach(function (m) {
      if (!run[m]) return;
      var pts = [padX + "," + y0.toFixed(1)];
      snaps.forEach(function (snap, i) { pts.push(xAt(i).toFixed(1) + "," + yAt(snap[m]).toFixed(1)); });
      var pl = svgEl("polyline", { points: pts.join(" "), "class": "pw-tlgraph-line mode-" + m });
      pl.appendChild(svgTitle(m + " — " + run[m] + " accepted"));
      s.appendChild(pl);
    });
    wrap.appendChild(s);

    var legend = elt("div", "pw-legend");
    MODES.forEach(function (m) {
      if (!run[m]) return;
      var leg = elt("span", "pw-legend-item mode-" + m);
      leg.appendChild(elt("span", "pw-legend-sw"));
      leg.appendChild(elt("span", null, m + " " + run[m]));
      legend.appendChild(leg);
    });
    wrap.appendChild(legend);
    wrap.appendChild(elt("div", "pw-tlgraph-foot",
      "cumulative accepted by mode · log order, not wall-clock (no per-item timestamps)"));
    return wrap;
  }

  function row(kind, position, title, badge, reason, hoverTitle) {
    var li = document.createElement("li");
    if (hoverTitle) li.title = hoverTitle;
    li.appendChild(elt("span", "pw-when", "#" + position));
    li.appendChild(elt("span", "pw-dot " + kind));
    li.appendChild(elt("span", null, title || "(untitled)"));
    if (badge) li.appendChild(elt("span", "pw-badge", badge));
    if (reason) li.appendChild(elt("span", "pw-reason-inline", reason));
    return li;
  }

  function render(container, state) {
    container.textContent = "";
    var completed = state.completed || [];
    var rejected = state.rejected || [];

    container.appendChild(elt("div", "pw-section-title",
      "Timeline — " + completed.length + " accepted, " + rejected.length + " rejected"));

    if (!completed.length && !rejected.length) {
      container.appendChild(elt("div", "pw-empty", "No history yet."));
      return;
    }

    container.appendChild(timelineGraph(completed, rejected));

    var list = elt("ul", "pw-timeline");
    completed.forEach(function (c, i) {
      list.appendChild(row("accepted", i + 1, c.title, c.mode || null, null, null));
    });
    rejected.forEach(function (r, i) {
      var reason = r.reason || "";
      var short = reason.length > 80 ? reason.slice(0, 77) + "…" : reason;
      list.appendChild(row("rejected", i + 1, r.title, short ? null : "rejected", short, reason || null));
    });
    container.appendChild(list);

    var fp = state.final_point;
    if (window.PW_DERIVE.finalPointShown(fp)) {
      var fpFlag = window.PW_DERIVE.finalFlag(fp);
      var note = "Final point" +
        (fp.date ? " " + fp.date : "") +
        (fp.deepest_tier ? " (deepest tier: " + fp.deepest_tier + ")" : "") +
        (!fp.date && !fp.deepest_tier && fp.sha ? " " + String(fp.sha).slice(0, 7) : "") +
        (fpFlag === "stale" ? " — STALE, HEAD has moved"
          : fpFlag === "invalid" ? " — INVALID, fails lint-final's contract"
            : fpFlag === "scoped" ? " — scoped to " + fp.scope + ", not whole-repo" : "");
      container.appendChild(elt("div", "pw-section-title", note));
    }
  }

  window.PW_VIEWS.timeline = render;
})();
