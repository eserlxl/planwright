// SPDX-FileCopyrightText: 2026 Eser KUBALI
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Doctor view — the environment preflight. Renders /doctor.json (the read-only output of
// `planwright doctor`): tool availability (git, rg, fd, python), bundled-script presence,
// whether the target is a git work tree, whether .planwright/ is gitignored, and whether a
// git commit identity is set — each with an ok/warn/fail badge and, when not ok, exactly
// what degrades. Read-only: it never runs `--fix`; it only shows what doctor reports.
//
// Environment health is stable across a session, so this view fetches /doctor.json once
// (not on every SSE tick) and keeps the result. Re-running the preflight means reloading
// the page — by design there is no action control here.

(function () {
  "use strict";

  window.PW_VIEWS = window.PW_VIEWS || {};

  var data = null, errored = false, inflight = false;

  function elt(tag, cls, text) {
    var e = document.createElement(tag);
    if (cls) e.className = cls;
    if (text != null) e.textContent = text;
    return e;
  }

  function badge(status) {
    var b = elt("span", "pw-doc-badge is-" + (status || "warn"));
    b.textContent = status === "ok" ? "OK" : String(status || "?").toUpperCase();
    return b;
  }

  function paint(container) {
    container.textContent = "";
    if (errored || !data) {
      container.appendChild(elt("div", "pw-empty", "Could not load the environment preflight."));
      return;
    }

    var head = elt("div", "pw-doc-head");
    head.appendChild(elt("h3", "pw-panel-title", "Environment preflight"));
    var verdict = data.fail ? "fail" : (data.warn ? "warn" : "ok");
    head.appendChild(elt("span", "pw-doc-verdict is-" + verdict,
      data.fail ? "needs attention" : (data.warn ? "runnable · warnings" : "all clear")));
    container.appendChild(head);

    container.appendChild(elt("p", "pw-panel-sub",
      data.total + " checks · " + data.warn + " warn · " + data.fail + " fail — " +
      "doctor preflights the toolchain so a run's degradations surface up front, not mid-run."));

    var list = elt("div", "pw-doctor");
    (data.checks || []).forEach(function (c) {
      var row = elt("div", "pw-doc-row is-" + c.status);
      row.appendChild(badge(c.status));
      var main = elt("div", "pw-doc-main");
      main.appendChild(elt("div", "pw-doc-name", c.name));
      if (c.detail) main.appendChild(elt("div", "pw-doc-detail", c.detail));
      if (c.status !== "ok" && c.degrades) {
        main.appendChild(elt("div", "pw-doc-degrade", "degrades: " + c.degrades));
      }
      row.appendChild(main);
      list.appendChild(row);
    });
    container.appendChild(list);
  }

  function render(container, state, ctx) {
    if (data && container.firstChild) return;     // already loaded — keep it
    if (!container.firstChild) {
      container.appendChild(elt("div", "pw-empty", "Running environment preflight…"));
    }
    if (inflight) return;
    inflight = true;
    fetch("/doctor.json")
      .then(function (r) { return r.ok ? r.json() : null; })
      .then(function (d) { inflight = false; data = d; errored = !d; paint(container); })
      .catch(function () { inflight = false; errored = true; paint(container); });
  }

  window.PW_VIEWS.doctor = render;
})();
