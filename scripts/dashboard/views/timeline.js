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

  // The timeline graph: a full-width ribbon of every decision in log order — accepted
  // bars rise above the midline (colored by mode), rejected bars drop below it (red) —
  // with a mode legend. Honest about the data: entries carry no per-item timestamps, so
  // the x-axis is log position, not wall-clock.
  function timelineGraph(completed, rejected) {
    var wrap = elt("div", "pw-tlgraph");
    var done = completed.length, kill = rejected.length, tot = done + kill;
    var rate = tot ? Math.round(100 * done / tot) : 0;

    var head = elt("div", "pw-tlgraph-head");
    head.appendChild(elt("span", "pw-section-mini", "Decision timeline"));
    head.appendChild(elt("span", "pw-tlgraph-rate", rate + "% accepted (" + done + "/" + tot + ")"));
    wrap.appendChild(head);

    var n = Math.max(done, kill, 1);
    var step = 4, W = n * step + 2, H = 56, mid = 28;
    var s = svgEl("svg", {
      "class": "pw-tlgraph-svg", viewBox: "0 0 " + W + " " + H,
      preserveAspectRatio: "none", role: "img",
      "aria-label": "Decision timeline: " + done + " accepted, " + kill + " rejected, in log order",
    });
    s.appendChild(svgEl("line", { x1: 0, y1: mid, x2: W, y2: mid, "class": "pw-tlgraph-mid" }));
    completed.forEach(function (it, i) {
      var bar = svgEl("rect", {
        x: 1 + i * step, y: mid - 22, width: step - 1.5, height: 22, rx: 0.6,
        "class": "pw-tlgraph-bar up mode-" + (it.mode || "other"),
      });
      bar.appendChild(svgTitle("#" + (i + 1) + " accepted · " + (it.title || "(untitled)") +
        (it.mode ? " · " + it.mode : "")));
      s.appendChild(bar);
    });
    rejected.forEach(function (it, i) {
      var bar = svgEl("rect", {
        x: 1 + i * step, y: mid, width: step - 1.5, height: 18, rx: 0.6, "class": "pw-tlgraph-bar down",
      });
      bar.appendChild(svgTitle("#" + (i + 1) + " rejected · " + (it.title || "(untitled)")));
      s.appendChild(bar);
    });
    wrap.appendChild(s);

    var counts = {};
    completed.forEach(function (it) { var m = it.mode || "other"; counts[m] = (counts[m] || 0) + 1; });
    var legend = elt("div", "pw-tlgraph-legend");
    MODES.forEach(function (m) {
      if (!counts[m]) return;
      var leg = elt("span", "pw-tlgraph-leg mode-" + m);
      leg.appendChild(elt("span", "pw-tlgraph-sw"));
      leg.appendChild(elt("span", null, m + " " + counts[m]));
      legend.appendChild(leg);
    });
    if (kill) {
      var rj = elt("span", "pw-tlgraph-leg is-rej");
      rj.appendChild(elt("span", "pw-tlgraph-sw"));
      rj.appendChild(elt("span", null, "rejected " + kill));
      legend.appendChild(rj);
    }
    wrap.appendChild(legend);
    wrap.appendChild(elt("div", "pw-tlgraph-foot",
      "log order, not wall-clock — entries carry no per-item timestamps"));
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
