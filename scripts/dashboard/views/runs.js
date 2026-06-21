// SPDX-FileCopyrightText: 2026 Eser KUBALI
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Runs view — the run-history timeline. Renders /runs.json (the append-only ledger state.py writes
// on activity stop): each completed command flow as command · duration · convergence outcome · ended,
// most recent first. Read-only; it degrades to an empty state when no runs exist and tolerates a
// malformed ledger (a non-array) without throwing.
//
// Run history changes as runs complete, so unlike the Doctor view this re-fetches /runs.json on each
// render tick. The pure paint(container, runs) is exposed on the render function so the node-gated
// DASH-RUNS-RENDER assertion can drive it with a sample ledger without an async fetch.

(function () {
  "use strict";

  window.PW_VIEWS = window.PW_VIEWS || {};

  var inflight = false;

  function elt(tag, cls, text) {
    var e = document.createElement(tag);
    if (cls) { e.className = cls; }
    if (text != null) { e.textContent = text; }
    return e;
  }

  // "1h 2m" / "3m 4s" / "5s", or "?" when the timestamps are absent or unparseable. Pure.
  function duration(started, ended) {
    var a = Date.parse(started), b = Date.parse(ended);
    if (isNaN(a) || isNaN(b) || b < a) { return "?"; }
    var s = Math.round((b - a) / 1000);
    if (s < 60) { return s + "s"; }
    var m = Math.floor(s / 60), rs = s % 60;
    if (m < 60) { return m + "m " + rs + "s"; }
    var h = Math.floor(m / 60), rm = m % 60;
    return h + "h " + rm + "m";
  }

  // Pure render-from-data. A non-array (absent/malformed) or empty ledger paints the empty state —
  // never throws. Exposed (render.paint) so the node-gated render test drives it without a fetch.
  function paint(container, runs) {
    container.textContent = "";
    if (!Array.isArray(runs) || runs.length === 0) {
      container.appendChild(elt("div", "pw-empty", "No runs recorded yet."));
      return;
    }
    container.appendChild(elt("h3", "pw-panel-title", "Run history"));
    container.appendChild(elt("p", "pw-panel-sub",
      runs.length + " recorded run" + (runs.length === 1 ? "" : "s") +
      " — most recent first; each is a completed command flow (plan / execute / cycle / codmaster …)."));
    var list = elt("div", "pw-runs");
    // Newest first, without mutating the caller's array.
    runs.slice().reverse().forEach(function (r) {
      r = r || {};
      var row = elt("div", "pw-run-row");
      row.appendChild(elt("span", "pw-run-cmd", String(r.command || "?")));
      row.appendChild(elt("span", "pw-run-dur", duration(r.started, r.ended)));
      // outcome is the convergence verdict (added by the run record); absent on older ledgers.
      if (r.outcome) {
        row.appendChild(elt("span", "pw-run-outcome is-" + r.outcome, String(r.outcome)));
      }
      if (r.ended) { row.appendChild(elt("span", "pw-run-ended", String(r.ended))); }
      list.appendChild(row);
    });
    container.appendChild(list);
  }

  function render(container, state, ctx) {
    if (!container.firstChild) {
      container.appendChild(elt("div", "pw-empty", "Loading run history…"));
    }
    if (inflight) { return; }
    inflight = true;
    fetch("/runs.json")
      .then(function (r) { return r.ok ? r.json() : null; })
      .then(function (d) { inflight = false; paint(container, d); })
      .catch(function () { inflight = false; paint(container, null); });
  }

  render.paint = paint;
  render.duration = duration;
  window.PW_VIEWS.runs = render;
})();
