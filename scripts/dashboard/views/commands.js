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
//
// Front-door panel: when the server exposes /recommend.json (status.recommend — the same
// canonical decision record `planwright advise` and /codmaster consume), the view renders
// the full dispatcher overlay above the base coach hero: the exact next dispatch with its
// args, the overlay's divergence notes, mechanical blockers (dirty tree / doctor), and the
// reset follow-up. The base coach below stays browser-derived (PW_DERIVE.coach); the panel
// degrades to absent — never to an error — on an older server or a failed fetch, so the
// view keeps its zero-endpoint contract when the overlay is unavailable.
//
// The panel heading is beacon-aware: while the run-activity beacon (state.activity, the
// same contract the Console reactor renders) shows a live run, "next dispatch" would
// mislabel the panel — a command is executing right now — so the kicker flips to
// "run in progress", the running command renders on the Console's exact label, and a
// label above the pick re-frames it as the dispatch once the run settles. A stale beacon (an
// interrupted run's leftover) keeps the next-dispatch framing: a dead run must not
// re-frame the panel as live — the Console carries the stale? warning.

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

  // ---- the codmaster front-door panel (/recommend.json, optional) ----------------------

  var recData = null, recInflight = false;

  // The human-runnable spelling of a dispatcher pick. codvisor/codinventor/codcycle map
  // to their helper commands (whose bodies carry the depth-10 flagship args); codshard
  // keeps its explore escalation; execute/reset (and anything unrecognised) fall through
  // to the plain planwright invocation with the record's own args.
  var HELPERS = {
    codvisor: "/planwright:codvisor",
    codinventor: "/planwright:codinventor",
    codcycle: "/planwright:codcycle",
  };
  function dispatchInvocation(d) {
    if (d.command === "codshard") {
      return "/planwright:codshard" + (d.args === "explore" ? " explore" : "");
    }
    if (HELPERS[d.command]) return HELPERS[d.command];
    return "/planwright:planwright " + (d.args || d.command);
  }

  // A usable decision record: the endpoint exists and returned the recommend() shape
  // (an error body, a doctor payload, or an older server's 404 must all read as absent).
  function recUsable(d) {
    return !!(d && typeof d.command === "string" && d.base && Array.isArray(d.blockers));
  }

  function paintFrontDoor(slot, act) {
    slot.textContent = "";
    if (!recUsable(recData)) return;   // absent panel, never an error state
    var d = recData;
    var live = window.PW_DERIVE.activityShown(act) && !act.stale;

    var panel = elt("div", "pw-frontdoor");
    panel.appendChild(elt("span", "pw-coach-kicker",
      "codmaster front door — " + (live ? "run in progress" : "next dispatch")));
    if (live) {
      var run = elt("div", "pw-reactor-activity");
      run.appendChild(elt("span", "pw-reactor-activity-dot"));
      run.appendChild(elt("span", "pw-reactor-activity-text",
        window.PW_DERIVE.activityLabel(act)));
      panel.appendChild(run);
      panel.appendChild(elt("span", "pw-coach-alt-kicker",
        "next dispatch once this run settles"));
    }
    var pick = elt("div", "pw-frontdoor-pick");
    pick.appendChild(elt("span", "pw-coach-pick", d.command));
    if (d.args && d.args !== d.command) {
      pick.appendChild(elt("span", "pw-frontdoor-args", d.args));
    }
    panel.appendChild(pick);
    panel.appendChild(elt("p", "pw-coach-why", d.why || ""));

    var flags = elt("div", "pw-frontdoor-flags");
    flags.appendChild(elt("span", "pw-shard-chip" + (d.mutating ? " warn" : " ok"),
      d.mutating ? "mutating" : "read-only"));
    if (d.invent_class) {
      flags.appendChild(elt("span", "pw-shard-chip warn", "invent-class (`safe` stops here)"));
    }
    panel.appendChild(flags);

    var ev = elt("div", "pw-coach-evidence");
    (d.evidence || []).forEach(function (e) { ev.appendChild(elt("span", "pw-coach-ev", e)); });
    panel.appendChild(ev);

    (d.notes || []).forEach(function (n) {
      panel.appendChild(elt("p", "pw-frontdoor-note", n));
    });
    (d.blockers || []).forEach(function (b) {
      panel.appendChild(elt("p", "pw-frontdoor-blocker",
        "blocked: " + (b && b.detail ? b.detail : String(b))));
    });
    if (d.follow_up && d.follow_up.command) {
      panel.appendChild(elt("p", "pw-frontdoor-note",
        "then: " + d.follow_up.command + (d.follow_up.args ? " " + d.follow_up.args : "")));
    }
    // Enforce overlay (parity with the CLI advise notice, 791a00f): at a converged invent-dry
    // recommendation the engine routes to a non-growth move (reset/codvisor, invent_class false),
    // but a default (non-safe) codmaster drive enforces one codinventor burst there instead —
    // only `safe` relays the pick shown above. The engine pick stays the primary render (engine
    // truth); this note discloses what a real default drive would actually do next.
    if (d.signals && d.signals.converged && !d.invent_class) {
      panel.appendChild(elt("p", "pw-frontdoor-note",
        "a default codmaster drive (without safe) takes an enforced codinventor burst here, " +
        "regardless of this invent-dry routing — only safe relays the pick above"));
    }

    panel.appendChild(invoke(dispatchInvocation(d)));
    slot.appendChild(panel);
  }

  // Paint what we have, then refresh from the server. The slot belongs to the current
  // render; a response landing after a newer render paints a detached node (harmless)
  // and the refreshed recData shows on the next SSE-driven render. The beacon rides
  // along: it came from the same /state.json snapshot as this render.
  function loadFrontDoor(slot, act) {
    paintFrontDoor(slot, act);
    if (recInflight || typeof fetch !== "function") return;
    recInflight = true;
    fetch("/recommend.json")
      .then(function (r) { return r.ok ? r.json() : null; })
      .then(function (d) {
        recInflight = false;
        if (recUsable(d)) { recData = d; paintFrontDoor(slot, act); }
      })
      .catch(function () { recInflight = false; });
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

    // codmaster front-door panel (server-side dispatcher overlay; absent when the
    // endpoint is unavailable — the base coach hero below is the degraded surface)
    var fdSlot = elt("div", "pw-frontdoor-slot");
    container.appendChild(fdSlot);
    loadFrontDoor(fdSlot, state.activity);

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

    // recent contributions (honest: unattributed run track record) — shared with the
    // Console home page via PW_UI.contribCard; the Commands panel keeps the final-point line.
    container.appendChild(window.PW_UI.contribCard(state, { compact: false }));
  }

  // recUsable + dispatchInvocation are pure shape/dispatch helpers; expose them on the view
  // function (not the global) so tests can assert their branches directly without re-deriving
  // the logic. This does not change render behavior.
  render.recUsable = recUsable;
  render.dispatchInvocation = dispatchInvocation;
  window.PW_VIEWS.commands = render;
})();
