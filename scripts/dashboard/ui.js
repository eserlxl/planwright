// SPDX-FileCopyrightText: 2026 Eser KUBALI
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Shared dashboard UI fragments rendered identically across views, so a card lives in
// exactly one place instead of drifting between two view modules. Self-contained (its own
// elt helper, mirroring each view's), with no dependency on a view's locals; the optional
// final-point line reads window.PW_DERIVE (loaded before this file). Registers window.PW_UI.
(function () {
  function elt(tag, cls, text) {
    var e = document.createElement(tag);
    if (cls) { e.className = cls; }
    if (text != null) { e.textContent = text; }
    return e;
  }

  // The "Recent contributions" card — the honest, unattributed FIFO track record of accepted
  // work (the logs do not record which command produced each item). Reads state.completed
  // ([{title, mode, commit}]) and state.rejected for the count.
  //
  // Two presentations, selected by opts.compact:
  //   - DETAILED (default, the Commands panel): a pw-panel-title heading, the accepted/rejected
  //     + FIFO-caveat sub-line, the per-item Commit: provenance stamp, the "showing N of M" foot,
  //     and the recorded final-point line.
  //   - COMPACT (opts.compact, the Console home rail): a pw-section-mini heading matching the
  //     Console's other section labels, and just the recent items (mode badge + title). It drops
  //     the sub-line, commit stamp, foot, and final-point — the Commands panel already explains
  //     the counts and the reactor already shows convergence; the home card is a glance.
  // Returns a <section> element.
  function contribCard(state, opts) {
    state = state || {};
    opts = opts || {};
    var compact = !!opts.compact;
    var completed = state.completed || [];

    var contrib = elt("section", "pw-panel pw-contrib" + (compact ? " pw-contrib--compact" : ""));
    var ch = elt("div", "pw-panel-head");
    ch.appendChild(compact
      ? elt("span", "pw-section-mini", "Recent contributions")
      : elt("h3", "pw-panel-title", "Recent contributions"));
    contrib.appendChild(ch);
    if (!compact) {
      contrib.appendChild(elt("p", "pw-panel-sub",
        completed.length + " accepted · " + (state.rejected || []).length + " rejected this run. " +
        "The logs are FIFO and don't record which command produced each item."));
    }

    if (!completed.length) {
      contrib.appendChild(elt("div", "pw-empty", "Nothing completed yet — run a sweep to start the track record."));
    } else {
      var list = elt("ul", "pw-contrib-list");
      completed.slice(-8).reverse().forEach(function (c) {
        var li = elt("li", "pw-contrib-item");
        if (c.mode) { li.appendChild(elt("span", "pw-contrib-mode mode-" + c.mode, c.mode)); }
        li.appendChild(elt("span", "pw-contrib-title", c.title || "(untitled)"));
        if (!compact && c.commit) {
          // Commit: provenance stamp (state.json completed[].commit) — the detailed panel only.
          var sha = elt("span", "pw-contrib-commit", c.commit);
          sha.title = "landing commit";
          li.appendChild(sha);
        }
        list.appendChild(li);
      });
      contrib.appendChild(list);
      if (!compact && completed.length > 8) {
        contrib.appendChild(elt("div", "pw-panel-foot", "showing the 8 most recent of " + completed.length + " accepted"));
      }
    }

    if (!compact) {
      var fp = state.final_point;
      if (window.PW_DERIVE && window.PW_DERIVE.finalPointShown(fp)) {
        var fpFlag = window.PW_DERIVE.finalFlag(fp);
        contrib.appendChild(elt("div", "pw-coach-final",
          "Final point: " + (fp.deepest_tier || "?") + (fp.date ? " · " + fp.date : "") +
          (fpFlag === "stale" ? " · stale (HEAD moved)"
            : fpFlag === "invalid" ? " · INVALID (fails lint-final's contract)"
              : fpFlag === "scoped" ? " · scoped to " + fp.scope + " (not whole-repo)" : "")));
      }
    }
    return contrib;
  }

  window.PW_UI = window.PW_UI || {};
  window.PW_UI.contribCard = contribCard;
})();
