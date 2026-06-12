// SPDX-FileCopyrightText: 2026 Eser KUBALI
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Shards view — codshard's shard map, rendered live. It shows the partition a
// `/planwright:codshard` sweep would walk right now: the shardable top-level
// directories (state.json's `repo` block — the same git-tracked enumeration rule
// commands/codshard.md applies), each shard's audit-frontier debt aggregated from the
// graph (never-audited / stale code nodes, build-graph.py's exact predicates), and the
// predicted sweep order (descending never-audited count, lexicographic tiebreak —
// recomputed by PW_DERIVE.shards.map, never re-derived here). The closing whole-repo
// round is rendered as its own terminal card: it is the only round that may declare
// the global final point, so the map is honest that per-shard convergence never
// aggregates into one.
//
// Read-only and evidence-first: codshard itself persists nothing (no sweep ledger
// exists to show), so this view renders only what is re-derivable from disk — where
// the audit debt lives and the order a sweep would visit it — which is exactly the
// repo-size judgment call the coach deliberately leaves to the maintainer.

(function () {
  "use strict";

  window.PW_VIEWS = window.PW_VIEWS || {};

  function elt(tag, cls, text) {
    var e = document.createElement(tag);
    if (cls) e.className = cls;
    if (text != null) e.textContent = text;
    return e;
  }

  function pulseChip(label, cls) {
    return elt("span", "pw-coach-pulse-chip" + (cls ? " " + cls : ""), label);
  }

  // A copyable invocation (read-only — copies the command text, runs nothing).
  // Same affordance as the Commands view's invoke().
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

  function shardCard(s, hasMetrics) {
    var card = elt("div", "pw-shard-card" + (s.neverAudited ? " is-frontier" : ""));

    var top = elt("div", "pw-shard-top");
    top.appendChild(elt("span", "pw-shard-order", String(s.order)));
    top.appendChild(elt("span", "pw-shard-name", s.name + "/"));
    card.appendChild(top);

    if (!hasMetrics) {
      card.appendChild(elt("p", "pw-shard-meta", "no graph — staleness unknown"));
      card.appendChild(invoke("/planwright:codshard shards " + s.name));
      return card;
    }

    card.appendChild(elt("p", "pw-shard-meta",
      s.nodes + " graph node" + (s.nodes === 1 ? "" : "s") + " · " +
      s.codeNodes + " code · " + s.loc + " loc"));

    var chips = elt("div", "pw-shard-chips");
    chips.appendChild(elt("span", "pw-shard-chip" + (s.neverAudited ? " warn" : " ok"),
      s.neverAudited + " never-audited"));
    chips.appendChild(elt("span", "pw-shard-chip" + (s.stale ? " warn" : " ok"),
      s.stale + " stale"));
    if (s.maxAge > 0) {
      chips.appendChild(elt("span", "pw-shard-chip",
        "oldest stamp " + s.maxAge + " commit" + (s.maxAge === 1 ? "" : "s") + " back"));
    }
    card.appendChild(chips);

    // Frontier heat: the share of the shard's code nodes the audit has not (currently)
    // reached. Zero code nodes renders an empty track, not a NaN-width bar.
    var debt = s.neverAudited + s.stale;
    var pct = s.codeNodes ? Math.round((debt / s.codeNodes) * 100) : 0;
    var track = elt("div", "pw-shard-heat");
    track.setAttribute("role", "img");
    track.setAttribute("aria-label", "audit frontier: " + debt + " of " + s.codeNodes + " code nodes");
    var fill = elt("span", "pw-shard-heat-fill" + (s.neverAudited ? " is-never" : ""));
    fill.style.width = pct + "%";
    track.appendChild(fill);
    card.appendChild(track);
    card.appendChild(elt("p", "pw-shard-heat-label",
      debt ? debt + "/" + s.codeNodes + " code nodes on the audit frontier"
           : "frontier clear"));

    // The single-shard sweep this card describes — codshard's explicit `shards <X>`
    // form, the same copy-only affordance as the closing card's whole-repo invocation.
    card.appendChild(invoke("/planwright:codshard shards " + s.name));

    return card;
  }

  function render(container, state, ctx) {
    container.textContent = "";
    ctx = ctx || {};
    var metrics = ctx.metrics || null;
    var sh = window.PW_DERIVE.shards.map(state.repo, metrics);

    var head = elt("div", "pw-coach-head");
    head.appendChild(elt("h2", "pw-coach-title", "Shards"));
    head.appendChild(elt("p", "pw-panel-sub",
      "The shard map a /planwright:codshard sweep would walk right now — one scoped " +
      "cycle per shard in staleness order, then one closing whole-repo round."));
    container.appendChild(head);

    if (!sh) {
      container.appendChild(elt("div", "pw-empty",
        "No shard enumeration in this snapshot (older server, or git unavailable) — " +
        "restart the dashboard from a git work tree to see the shard map."));
      return;
    }

    // live shard pulse
    var pulse = elt("div", "pw-coach-pulse");
    pulse.appendChild(pulseChip(sh.shards.length + " shard" + (sh.shards.length === 1 ? "" : "s")));
    pulse.appendChild(pulseChip(sh.trackedFiles + " tracked files"));
    if (sh.large) pulse.appendChild(pulseChip("large repo — codshard territory", "warn"));
    if (metrics) {
      pulse.appendChild(pulseChip(sh.totals.neverAudited + " never-audited",
        sh.totals.neverAudited ? "warn" : "ok"));
      pulse.appendChild(pulseChip(sh.totals.stale + " stale", sh.totals.stale ? "warn" : "ok"));
    }
    pulse.appendChild(pulseChip(sh.basis + " order"));
    container.appendChild(pulse);

    if (!metrics) {
      container.appendChild(elt("p", "pw-shard-note",
        "No graph built yet — order falls back to lexicographic and per-shard staleness " +
        "is unknown, exactly as codshard itself would order without a graph."));
    }

    if (!sh.shards.length) {
      container.appendChild(elt("div", "pw-empty",
        "No shardable top-level directory (none holds ≥3 git-tracked files) — codshard " +
        "would run only the closing whole-repo round."));
    } else {
      var grid = elt("div", "pw-shard-grid");
      sh.shards.forEach(function (s) { grid.appendChild(shardCard(s, !!metrics)); });
      container.appendChild(grid);
    }

    if (sh.folded.length) {
      container.appendChild(elt("p", "pw-shard-note",
        "folded into the closing round (fewer than 3 tracked files): " + sh.folded.join(", ")));
    }

    // The closing whole-repo round — always exactly one, and the only legitimate owner
    // of the global final point (per-shard scoped final points never aggregate).
    var closing = elt("section", "pw-panel pw-shard-closing");
    var chh = elt("div", "pw-panel-head");
    chh.appendChild(elt("h3", "pw-panel-title", "Closing whole-repo round"));
    closing.appendChild(chh);
    closing.appendChild(elt("p", "pw-panel-sub",
      "Covers what no shard can see — cross-shard seams, root-level files, build/CI/docs " +
      "and other global concerns — and is the only round that may declare the global " +
      "final point."));
    if (metrics && sh.residue && (sh.residue.neverAudited || sh.residue.stale)) {
      closing.appendChild(elt("p", "pw-shard-note",
        sh.residue.neverAudited + " never-audited · " + sh.residue.stale + " stale code " +
        "node" + (sh.residue.neverAudited + sh.residue.stale === 1 ? " sits" : "s sit") +
        " outside every shard (root-level / folded) — only this round reaches them."));
    }
    var fp = state.final_point;
    if (window.PW_DERIVE.finalPointShown(fp)) {
      var fpFlag = window.PW_DERIVE.finalFlag(fp);
      closing.appendChild(elt("div", "pw-coach-final",
        "Last final point: " + (fp.deepest_tier || "?") + (fp.date ? " · " + fp.date : "") +
        (fpFlag === "scoped" ? " · scoped to " + fp.scope + " — a shard's point, not the global one"
          : fpFlag === "stale" ? " · stale (HEAD moved)"
            : fpFlag === "invalid" ? " · INVALID (fails lint-final's contract)"
              : " · whole-repo")));
    }
    closing.appendChild(invoke("/planwright:codshard"));
    container.appendChild(closing);
  }

  window.PW_VIEWS.shards = render;
})();
