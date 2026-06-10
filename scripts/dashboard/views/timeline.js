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
    container.appendChild(elt("div", "pw-empty",
      "Ordered by log position (planwright appends chronologically); no per-item timestamps."));

    if (!completed.length && !rejected.length) {
      container.appendChild(elt("div", "pw-empty", "No history yet."));
      return;
    }

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
