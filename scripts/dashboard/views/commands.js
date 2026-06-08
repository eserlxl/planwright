// SPDX-FileCopyrightText: 2026 Eser KUBALI
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Commands view — a coach for planwright's three sweeps. It reads the live planning state
// and recommends which command fits the project *right now*, with the actual numbers behind
// the suggestion:
//   • codvisor   (explore / harden) — when there is structural debt or queued work to fix.
//   • codinventor (invent / grow)   — when the tree is clean and nothing is queued (dry/stuck).
//   • codcycle   (explore→invent)   — the steady harden-then-grow rhythm for a healthy mix.
// Read-only: it *shows* the command to run (copyable) — it never runs anything. Derived
// purely from /state.json + the graph metrics; the logs record no per-command attribution,
// so "recent contributions" is honestly the run's completed-item track record, unattributed.

(function () {
  "use strict";

  window.PW_VIEWS = window.PW_VIEWS || {};

  var ORDER = ["codvisor", "codinventor", "codcycle"];
  var COMMANDS = {
    codvisor: {
      name: "codvisor", tag: "explore · harden", cmd: "/planwright:codvisor",
      what: "Scans and audits the repo, then completes latent capability — the advisor sweep " +
            "(cycle 10 depth 10 explore). It hardens what already exists.",
      when: "When there are problems to fix or planned work to finish: import cycles, untested " +
            "hotspots, articulation risks, or pending repair/improve items.",
    },
    codinventor: {
      name: "codinventor", tag: "invent · grow", cmd: "/planwright:codinventor",
      what: "Proposes net-new, seam-bound features once the expand tier is dry " +
            "(cycle 10 depth 10 invent). It grows the tree beyond what's latent.",
      when: "When the project is stuck or complete: nothing pending and the tree is clean / converged.",
    },
    codcycle: {
      name: "codcycle", tag: "explore → invent rhythm", cmd: "/planwright:codcycle",
      what: "Alternates explore→invent across 10 outer cycles — harden, then grow, repeated — " +
            "with a closing explore to settle whatever the last invent landed.",
      when: "For continuous progress: a healthy mix of work to harden and room to grow.",
    },
  };

  function elt(tag, cls, text) {
    var e = document.createElement(tag);
    if (cls) e.className = cls;
    if (text != null) e.textContent = text;
    return e;
  }

  // Distil the live state into the signals the recommendation reads.
  function signals(state, metrics) {
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
  function recommend(s) {
    var hasDebt = s.cycles > 0 || s.hotUncovered >= 3 || s.articulation > 0 || s.pendRepairImprove > 0;
    if (hasDebt) {
      return { key: "codvisor", why: "There's structural debt to harden before growing — clear it first." };
    }
    if (s.pending === 0) {
      return { key: "codinventor", why: "Nothing's queued and the tree is clean — latent capability looks complete, so grow net-new." };
    }
    return { key: "codcycle", why: "A healthy mix — planned work to finish and room to grow. Keep the harden→grow rhythm." };
  }

  function evidenceFor(key, s) {
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

  function pulseChip(label, cls) {
    return elt("span", "pw-coach-pulse-chip" + (cls ? " " + cls : ""), label);
  }

  // A copyable invocation (read-only — copies the command text, runs nothing).
  function invoke(cmd) {
    var wrap = elt("div", "pw-cmd-invoke");
    wrap.appendChild(elt("code", "pw-cmd-code", cmd));
    var btn = elt("button", "pw-cmd-copy", "copy");
    btn.type = "button";
    btn.setAttribute("aria-label", "copy " + cmd + " to the clipboard");
    btn.addEventListener("click", function () {
      if (navigator.clipboard && navigator.clipboard.writeText) {
        navigator.clipboard.writeText(cmd).then(function () {
          btn.textContent = "copied";
          setTimeout(function () { btn.textContent = "copy"; }, 1200);
        }, function () {});
      }
    });
    wrap.appendChild(btn);
    return wrap;
  }

  function render(container, state, ctx) {
    container.textContent = "";
    ctx = ctx || {};
    var metrics = ctx.metrics || null;
    var s = signals(state, metrics);
    var rec = recommend(s);
    var picked = COMMANDS[rec.key];

    var head = elt("div", "pw-coach-head");
    head.appendChild(elt("h2", "pw-coach-title", "Commands"));
    head.appendChild(elt("p", "pw-panel-sub",
      "planwright's three sweeps — and which one fits the project right now."));
    container.appendChild(head);

    // live project pulse
    var pulse = elt("div", "pw-coach-pulse");
    pulse.appendChild(pulseChip(s.pending + " pending"));
    if (s.hasGraph) {
      pulse.appendChild(pulseChip(s.cycles + " cycles", s.cycles ? "warn" : null));
      pulse.appendChild(pulseChip(s.hotUncovered + " untested hotspots", s.hotUncovered ? "warn" : null));
      if (s.coveragePct != null) pulse.appendChild(pulseChip(s.coveragePct + "% covered"));
    }
    pulse.appendChild(pulseChip(s.completed + " accepted", "ok"));
    pulse.appendChild(pulseChip(s.rejected + " rejected"));
    container.appendChild(pulse);

    // hero recommendation
    var hero = elt("div", "pw-coach-hero");
    hero.appendChild(elt("span", "pw-coach-kicker", "Suggested next"));
    hero.appendChild(elt("span", "pw-coach-pick", picked.name));
    hero.appendChild(elt("p", "pw-coach-why", rec.why));
    var ev = elt("div", "pw-coach-evidence");
    evidenceFor(rec.key, s).forEach(function (e) { ev.appendChild(elt("span", "pw-coach-ev", e)); });
    hero.appendChild(ev);
    hero.appendChild(invoke(picked.cmd));
    container.appendChild(hero);

    // the three command cards
    var grid = elt("div", "pw-cmd-grid");
    ORDER.forEach(function (key) {
      var c = COMMANDS[key];
      var card = elt("div", "pw-cmd-card" + (key === rec.key ? " is-recommended" : ""));
      var top = elt("div", "pw-cmd-top");
      top.appendChild(elt("span", "pw-cmd-name", c.name));
      top.appendChild(elt("span", "pw-cmd-tag", c.tag));
      if (key === rec.key) top.appendChild(elt("span", "pw-cmd-fit", "recommended"));
      card.appendChild(top);
      card.appendChild(elt("p", "pw-cmd-what", c.what));
      var when = elt("p", "pw-cmd-when");
      when.appendChild(elt("span", "pw-cmd-when-k", "Use it when "));
      when.appendChild(document.createTextNode(c.when));
      card.appendChild(when);
      card.appendChild(invoke(c.cmd));
      grid.appendChild(card);
    });
    container.appendChild(grid);

    // recent contributions (honest: unattributed run track record)
    var contrib = elt("section", "pw-panel pw-contrib");
    var ch = elt("div", "pw-panel-head");
    ch.appendChild(elt("h3", "pw-panel-title", "Recent contributions"));
    contrib.appendChild(ch);
    contrib.appendChild(elt("p", "pw-panel-sub",
      s.completed + " accepted · " + s.rejected + " rejected this run. " +
      "The logs are FIFO and don't record which command produced each item."));

    var completed = state.completed || [];
    if (!completed.length) {
      contrib.appendChild(elt("div", "pw-empty", "Nothing completed yet — run a sweep to start the track record."));
    } else {
      var list = elt("ul", "pw-contrib-list");
      completed.slice(-8).reverse().forEach(function (c) {
        var li = elt("li", "pw-contrib-item");
        if (c.mode) li.appendChild(elt("span", "pw-contrib-mode mode-" + c.mode, c.mode));
        li.appendChild(elt("span", "pw-contrib-title", c.title || "(untitled)"));
        list.appendChild(li);
      });
      contrib.appendChild(list);
      if (completed.length > 8) {
        contrib.appendChild(elt("div", "pw-panel-foot", "showing the 8 most recent of " + completed.length + " accepted"));
      }
    }

    var fp = state.final_point;
    if (fp && (fp.date || fp.deepest_tier)) {
      contrib.appendChild(elt("div", "pw-coach-final",
        "Final point: " + (fp.deepest_tier || "?") + (fp.date ? " · " + fp.date : "") +
        (fp.stale ? " · stale (HEAD moved)" : "")));
    }
    container.appendChild(contrib);
  }

  window.PW_VIEWS.commands = render;
})();
