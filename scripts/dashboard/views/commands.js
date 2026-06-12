// SPDX-FileCopyrightText: 2026 Eser KUBALI
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Commands view — a coach for planwright's sweeps. It reads the live planning state
// and recommends which command fits the project *right now*, with the actual numbers behind
// the suggestion:
//   • codmaster  (front door)       — card only, never coach-recommended: it dispatches the
//     coach's own picks consecutively, so recommending it from this table would be circular.
//   • codvisor   (explore / harden) — when there is structural debt or queued work to fix.
//   • codinventor (invent / grow)   — when the tree is clean and nothing is queued (dry/stuck).
//   • codcycle   (explore→invent)   — the steady harden-then-grow rhythm for a healthy mix.
//   • codshard   (shard-by-shard)   — card only, never coach-recommended: sharding is a repo-size
//     call, not a planning-state call, so the heuristic has no signal for it.
// Read-only: it *shows* the command to run (copyable) — it never runs anything. Derived
// purely from /state.json + the graph metrics; the logs record no per-command attribution,
// so "recent contributions" is honestly the run's completed-item track record, unattributed.

(function () {
  "use strict";

  window.PW_VIEWS = window.PW_VIEWS || {};

  var ORDER = ["codmaster", "codvisor", "codinventor", "codcycle", "codshard"];
  var COMMANDS = {
    codmaster: {
      name: "codmaster", tag: "front door · auto-drive", cmd: "/planwright:codmaster",
      what: "Senses the planning state with this same coach and runs the required commands " +
            "consecutively to the final point, at depth 10 (advise = tell only; safe = no " +
            "invention; loop = infinite).",
      when: "Not sure which to run? Start here. (Never coach-recommended — it dispatches the " +
            "coach's own picks, so this table recommending it would be circular.)",
    },
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
    codshard: {
      name: "codshard", tag: "shard-by-shard sweep", cmd: "/planwright:codshard",
      what: "Matures the repo shard by shard — one scoped cycle per top-level directory in " +
            "staleness order (cycle 3 depth 10 each), then one closing whole-repo round.",
      when: "For large codebases: every shard gets the full depth budget instead of sharing one " +
            "whole-repo pass. (Never coach-recommended — size is your call, not the state's.)",
    },
  };

  function elt(tag, cls, text) {
    var e = document.createElement(tag);
    if (cls) e.className = cls;
    if (text != null) e.textContent = text;
    return e;
  }

  // The coach heuristic (signals / recommend / evidence) is pure, DOM-free logic that lives
  // in PW_DERIVE so it can be unit-tested; this view only renders its results.
  var COACH = window.PW_DERIVE.coach;

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
    var s = COACH.signals(state, metrics);
    var rec = COACH.recommend(s);
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
    COACH.evidence(rec.key, s).forEach(function (e) { ev.appendChild(elt("span", "pw-coach-ev", e)); });
    hero.appendChild(ev);
    hero.appendChild(invoke(picked.cmd));
    // Supplementary cold-start nudge: only when converged, suggest a reset to re-audit the
    // whole tree from scratch (the incremental final point may be masking work).
    var resetSug = COACH.reset(s);
    if (resetSug) {
      var alt = elt("div", "pw-coach-alt");
      alt.appendChild(elt("span", "pw-coach-alt-kicker", "Or cold-start re-audit"));
      alt.appendChild(elt("p", "pw-coach-alt-why", resetSug.why));
      alt.appendChild(invoke(resetSug.cmd));
      hero.appendChild(alt);
    }
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
    if (window.PW_DERIVE.finalPointShown(fp)) {
      var fpFlag = window.PW_DERIVE.finalFlag(fp);
      contrib.appendChild(elt("div", "pw-coach-final",
        "Final point: " + (fp.deepest_tier || "?") + (fp.date ? " · " + fp.date : "") +
        (fpFlag === "stale" ? " · stale (HEAD moved)"
          : fpFlag === "invalid" ? " · INVALID (fails lint-final's contract)"
            : fpFlag === "scoped" ? " · scoped to " + fp.scope + " (not whole-repo)" : "")));
    }
    container.appendChild(contrib);
  }

  window.PW_VIEWS.commands = render;
})();
