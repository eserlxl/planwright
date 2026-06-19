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

  // The selected sub-tab, persisted across re-renders: app.js's renderActive() rebuilds this
  // card on every SSE tick, so a DOM-local toggle would snap back to "accepted" on each live
  // update. Keyed by presentation so the compact Console rail and the detailed Commands panel
  // remember independently (only one is ever visible, but they should not fight over the key).
  var activeTab = { compact: "accepted", detailed: "accepted" };

  // Per-card id seed: each rendered card needs unique tab/panel ids for the aria-controls /
  // aria-labelledby wiring, since the compact (Console) and detailed (Commands) cards can both
  // sit in the DOM at once (one hidden) and duplicate ids would break the associations.
  var cardSeq = 0;

  // The contributions card — the honest, unattributed FIFO track record of a run, now with two
  // sibling tabs so the cut items are visible, not just counted:
  //   - "Recent contributions" — accepted work (state.completed, [{title, mode, commit}]).
  //   - "Rejected"             — items the run cut (state.rejected, [{title, reason}]), each with
  //                              its recorded rejection reason.
  // The logs are FIFO and do not record which command produced each item.
  //
  // Two presentations, selected by opts.compact:
  //   - DETAILED (default, the Commands panel): the per-tab sub-line, the per-item Commit:
  //     provenance stamp (accepted tab only), the "showing N of M" foot, and the recorded
  //     final-point line below the body.
  //   - COMPACT (opts.compact, the Console home rail): the tab strip (mini-heading look matching
  //     the rail's other section labels) and just the items. It drops the sub-line, commit stamp,
  //     foot, and final-point — the Commands panel already explains the counts and the reactor
  //     already shows convergence; the home card is a glance.
  // Returns a <section> element.
  function contribCard(state, opts) {
    state = state || {};
    opts = opts || {};
    var compact = !!opts.compact;
    var key = compact ? "compact" : "detailed";
    var completed = state.completed || [];
    var rejected = state.rejected || [];
    var uid = "pw-contrib-" + (++cardSeq);
    var panelId = uid + "-panel";

    var contrib = elt("section", "pw-panel pw-contrib" + (compact ? " pw-contrib--compact" : ""));

    // --- header: a two-tab strip replacing the old single heading. A tab click swaps only the
    //     card body (renderBody); the choice lives in activeTab so a live re-render keeps it.
    var head = elt("div", "pw-panel-head pw-contrib-head");
    var tabs = elt("div", "pw-contrib-tabs");
    tabs.setAttribute("role", "tablist");
    var buttons = [];

    function selectTab(id) {
      activeTab[key] = id;
      var activeBtn = null;
      buttons.forEach(function (b) {
        var on = b._tabId === id;
        b.classList.toggle("is-active", on);
        b.setAttribute("aria-selected", on ? "true" : "false");
        b.tabIndex = on ? 0 : -1;   // roving tabindex, mirroring the main nav
        if (on) { activeBtn = b; }
      });
      // keep the panel labelled by whichever tab is active (ARIA tab/tabpanel association)
      if (activeBtn) { body.setAttribute("aria-labelledby", activeBtn.getAttribute("id")); }
      renderBody();
    }

    function mkTab(id, label) {
      var b = elt("button", "pw-contrib-tab", label);
      b.type = "button";
      b._tabId = id;
      b.setAttribute("id", uid + "-tab-" + id);
      b.setAttribute("role", "tab");
      b.setAttribute("aria-controls", panelId);
      b.addEventListener("click", function () { if (activeTab[key] !== id) { selectTab(id); } });
      buttons.push(b);
      tabs.appendChild(b);
      return b;
    }

    mkTab("accepted", "Recent contributions");
    mkTab("rejected", "Rejected");

    // Arrow-key roving across the tablist (standard ARIA tab behaviour); Enter/Space already
    // activate the focused <button> natively.
    tabs.addEventListener("keydown", function (ev) {
      var dir = ev.key === "ArrowRight" ? 1 : ev.key === "ArrowLeft" ? -1 : 0;
      if (!dir) { return; }
      ev.preventDefault();
      var cur = activeTab[key] === "rejected" ? 1 : 0;
      var nextBtn = buttons[(cur + dir + buttons.length) % buttons.length];
      selectTab(nextBtn._tabId);
      if (nextBtn.focus) { nextBtn.focus(); }
    });

    head.appendChild(tabs);
    contrib.appendChild(head);

    var body = elt("div", "pw-contrib-body");
    body.setAttribute("id", panelId);
    body.setAttribute("role", "tabpanel");
    contrib.appendChild(body);

    function renderAccepted() {
      if (!compact) {
        body.appendChild(elt("p", "pw-panel-sub",
          completed.length + " accepted · " + rejected.length + " rejected this run. " +
          "The logs are FIFO and don't record which command produced each item."));
      }
      if (!completed.length) {
        body.appendChild(elt("div", "pw-empty", "Nothing completed yet — run a sweep to start the track record."));
        return;
      }
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
      body.appendChild(list);
      if (!compact && completed.length > 8) {
        body.appendChild(elt("div", "pw-panel-foot", "showing the 8 most recent of " + completed.length + " accepted"));
      }
    }

    function renderRejected() {
      if (!compact) {
        body.appendChild(elt("p", "pw-panel-sub",
          rejected.length + " rejected this run. Each shows the reason recorded when it was cut."));
      }
      if (!rejected.length) {
        body.appendChild(elt("div", "pw-empty", "Nothing rejected — every proposed item was accepted."));
        return;
      }
      var list = elt("ul", "pw-contrib-list pw-contrib-list--rejected");
      rejected.slice(-8).reverse().forEach(function (r) {
        var li = elt("li", "pw-contrib-item is-rejected");
        li.appendChild(elt("span", "pw-contrib-mode is-rejected", "rejected"));
        // title + reason stack vertically so a long reason wraps under the title instead of
        // crowding the row (works the same in the narrow compact rail and the wide panel).
        var textWrap = elt("span", "pw-contrib-text");
        textWrap.appendChild(elt("span", "pw-contrib-title", r.title || "(untitled)"));
        var reason = (r.reason || "").trim();
        if (reason) {
          var rsn = elt("span", "pw-contrib-reason", reason);
          rsn.title = reason;
          textWrap.appendChild(rsn);
        }
        li.appendChild(textWrap);
        list.appendChild(li);
      });
      body.appendChild(list);
      if (!compact && rejected.length > 8) {
        body.appendChild(elt("div", "pw-panel-foot", "showing the 8 most recent of " + rejected.length + " rejected"));
      }
    }

    function renderBody() {
      body.replaceChildren();   // clears children in the browser AND the test DOM shim
      if (activeTab[key] === "rejected") { renderRejected(); } else { renderAccepted(); }
    }

    // Apply the persisted tab (default "accepted"), syncing the buttons' active flags + body.
    selectTab(activeTab[key]);

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
