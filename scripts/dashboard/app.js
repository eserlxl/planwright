// SPDX-FileCopyrightText: 2026 Eser KUBALI
// SPDX-License-Identifier: GPL-3.0-or-later
//
// planwright dashboard shell. Read-only: it fetches /state.json + /graph.json, derives
// the metrics cache (PW_DERIVE), renders the at-a-glance overview strip, routes between
// the tab views, and re-fetches whenever the /events SSE stream reports a change. It
// never mutates anything — there are no action controls, by design.
//
// Beyond routing it owns the chrome that makes the page feel live: the reactive aurora
// tokens (hue = convergence, drift speed = workload), a one-shot ripple on every change,
// a "since you looked away" catch-up banner, a command palette, light/dark theme, glance
// mode, a shortcuts sheet, and full keyboard navigation. All of it is view-state only.
//
// View modules (views/*.js) register a render(container, state, ctx) function into the
// global window.PW_VIEWS registry; ctx = { graphText, metrics, builtSha, stale, head }.

(function () {
  "use strict";

  window.PW_VIEWS = window.PW_VIEWS || {};
  window.PW_UI = window.PW_UI || { planMode: "all" };
  // Exposed for the Fleet view (views/fleet.js): the live project list + the switch action.
  window.PW_PROJECTS = window.PW_PROJECTS || [];
  window.PW_SWITCH_PROJECT = function (id) { setSelectedProject(id); };

  // SSE connection-state logic, kept pure and exposed so the node-gated dashboard tests
  // (DASH-SSE-RECONNECT / DASH-SSE-GAP) can drive it without a DOM or a live stream.
  var SSE_MAX_RECONNECT = 6;
  window.PW_SSE = window.PW_SSE || {
    MAX_RECONNECT: SSE_MAX_RECONNECT,
    // The connection-state label for a given consecutive-error count: `live` while connected
    // (attempts 0), `reconnecting (n)` while the browser retries on the server's retry: cadence,
    // and `offline` once attempts pass the cap (the client then stops retrying).
    status: function (attempts, max) {
      if (typeof max !== "number") { max = SSE_MAX_RECONNECT; }
      if (attempts <= 0) { return { text: "live", cls: "ok" }; }
      if (attempts > max) { return { text: "offline", cls: "err" }; }
      return { text: "reconnecting (" + attempts + ")", cls: "warn" };
    },
  };

  var VIEWS = [
    { key: "console", container: "view-console" },
    { key: "commands", container: "view-commands" },
    { key: "plan", container: "view-plan" },
    { key: "timeline", container: "view-timeline" },
    { key: "graph", container: "view-graph" },
    { key: "insights", container: "view-insights" },
    { key: "shards", container: "view-shards" },
    { key: "fleet", container: "view-fleet" },
    { key: "runs", container: "view-runs" },
    { key: "doctor", container: "view-doctor" },
  ];
  var KEYS = VIEWS.map(function (v) { return v.key; });
  var TITLE_BASE = "planwright dashboard";

  var state = null;
  var ctx = { graphText: null, metrics: null, builtSha: "", stale: false, head: "" };
  var active = "console";
  var fetching = false;   // a fetch is in flight
  var refetch = false;    // a change arrived mid-fetch — coalesce into one trailing fetch
  var trend = [];         // client-timestamped count history for the session sparkline
  var selectedProject = currentProjectId();  // the ?project=<id> in view, or null = launch root
  var projectsList = [];  // last /projects.json projects[] (feeds the bottom-left switcher)
  var es = null;          // the live EventSource, so a project switch can reconnect it
  var titleProject = "";  // current project name, mixed into the browser-tab title

  function elt(tag, cls, text) {
    var e = document.createElement(tag);
    if (cls) e.className = cls;
    if (text != null) e.textContent = text;
    return e;
  }
  function byId(id) { return document.getElementById(id); }

  function setStatus(text, cls) {
    var el = byId("pw-status");
    if (!el) return;
    el.textContent = text;
    el.className = "pw-status" + (cls ? " " + cls : "");
  }

  function pad2(n) { return (n < 10 ? "0" : "") + n; }
  function clockNow() {
    var d = new Date();
    return pad2(d.getHours()) + ":" + pad2(d.getMinutes()) + ":" + pad2(d.getSeconds());
  }

  function chip(label, value, cls) {
    var c = elt("span", "pw-chip" + (cls ? " " + cls : ""));
    c.appendChild(elt("span", "pw-chip-k", label));
    c.appendChild(elt("span", "pw-chip-v", value));
    return c;
  }

  // ---- derived context -----------------------------------------------------------------

  function buildCtx(s, graphText) {
    var metrics = (graphText != null && window.PW_DERIVE)
      ? window.PW_DERIVE.metrics(graphText) : null;
    var builtSha = metrics ? metrics.builtSha
      : ((s && s.graph && s.graph.built_at_sha) || "");
    var head = (s && s.head) || "";
    // Prefer the canonical state.json verdict (status.py's predicate: an
    // unverifiable HEAD reads STALE, sha matching tolerates prefix forms) —
    // mirroring how final_point.stale is consumed straight from state.json. The
    // local compare is only a fallback for a degraded snapshot without the key.
    var stale = (s && s.graph && typeof s.graph.stale === "boolean")
      ? s.graph.stale
      : !!(builtSha && head && builtSha !== head);
    return { graphText: graphText, metrics: metrics, builtSha: builtSha, stale: stale, head: head };
  }

  // ---- reactive aurora + stale cast ----------------------------------------------------

  function lengthsOf(s) {
    return {
      done: (s.completed || []).length,
      pend: (s.pending || []).length,
      kill: (s.rejected || []).length,
    };
  }

  function writeAura(s) {
    var L = lengthsOf(s), total = L.done + L.pend + L.kill;
    var ratio = total ? L.done / total : 0;
    var root = document.documentElement;
    root.style.setProperty("--pw-converge-hue", String(Math.round(40 + 100 * ratio)));
    var workload = Math.max(8, Math.min(60, 60 - L.pend * 4));
    root.style.setProperty("--pw-workload", workload + "s");
    // Stale strictly means "sha lags HEAD" — import cycles are structural debt the
    // Insights view renders as such, never grounds for the stale cast (PW_DERIVE
    // owns the predicate so the suite can pin it under node).
    var stale = window.PW_DERIVE
      ? window.PW_DERIVE.staleCast(ctx, s.final_point)
      : (ctx.stale || (s.final_point && s.final_point.stale));
    document.body.classList.toggle("pw-stale", !!stale);
  }

  function pulse() {
    var el = byId("pw-pulse-ripple");
    if (!el) return;
    el.classList.remove("is-active");
    void el.offsetWidth;   // restart the one-shot keyframe
    el.classList.add("is-active");
  }

  // The dashboard has no per-item timestamps (the logs are FIFO-only), so we stamp the
  // client clock as snapshots arrive to build a real time-series of the counts for the
  // session. Consecutive identical snapshots extend the last segment instead of bloating
  // the series, so flat stretches stay cheap.
  function captureTrend(s) {
    var L = lengthsOf(s), last = trend[trend.length - 1];
    if (last && last.pend === L.pend && last.done === L.done && last.kill === L.kill) {
      last.t = Date.now();
      return;
    }
    trend.push({ t: Date.now(), pend: L.pend, done: L.done, kill: L.kill });
    if (trend.length > 240) trend.shift();
  }

  // A canvas-drawn favicon that tracks convergence (amber→green) and, when the tab is
  // backgrounded with unread changes, shows the count — so a parked tab is glanceable.
  // Pure client-side (data URL); no network, works offline.
  function updateFavicon(s) {
    if (!s) return;
    var canvas = document.createElement("canvas");
    canvas.width = canvas.height = 32;
    var g = canvas.getContext && canvas.getContext("2d");
    if (!g) return;
    var L = lengthsOf(s), total = L.done + L.pend + L.kill;
    var ratio = total ? L.done / total : 0, hue = Math.round(40 + 100 * ratio);
    g.clearRect(0, 0, 32, 32);
    g.beginPath(); g.arc(16, 16, 15, 0, 2 * Math.PI);
    g.fillStyle = "hsl(" + hue + ",70%,48%)"; g.fill();
    var n = unreadTotal();
    if (n > 0 && document.hidden) {
      g.beginPath(); g.arc(16, 16, 11, 0, 2 * Math.PI); g.fillStyle = "rgba(0,0,0,0.82)"; g.fill();
      g.fillStyle = "#fff"; g.font = "bold 17px system-ui, sans-serif";
      g.textAlign = "center"; g.textBaseline = "middle";
      g.fillText(n > 9 ? "9+" : String(n), 16, 17);
    }
    var link = byId("pw-favicon");
    if (!link) {
      link = document.createElement("link"); link.id = "pw-favicon"; link.rel = "icon";
      if (document.head) document.head.appendChild(link);
    }
    link.type = "image/png";
    try { link.href = canvas.toDataURL("image/png"); } catch (e) {}
  }

  // ---- overview strip ------------------------------------------------------------------

  function shaChip(c) {
    var s = elt("span", "pw-sha" + (c.stale ? " pw-sha--stale" : ""));
    s.textContent = "graph " + (c.builtSha ? c.builtSha.slice(0, 7) : "—") + (c.stale ? " · stale" : "");
    return s;
  }

  function baseOf(path) {
    var parts = String(path || "").replace(/[\/\\]+$/, "").split(/[\/\\]/);
    return parts[parts.length - 1] || "";
  }
  function parentOf(path) {
    var parts = String(path || "").replace(/[\/\\]+$/, "").split(/[\/\\]/);
    return parts.length >= 2 ? parts[parts.length - 2] : "";
  }
  function projectName(s) { return baseOf((s && s.root) || ""); }

  // A project's display name: its basename, disambiguated with the parent dir when another
  // registered project shares the same basename (two different "web" repos stay distinct).
  function displayName(p, all) {
    var base = baseOf(p.path);
    var clash = all.some(function (o) { return o.id !== p.id && baseOf(o.path) === base; });
    var parent = parentOf(p.path);
    return clash && parent ? parent + "/" + base : base;
  }

  // Which allow-listed project this view currently shows: the selected id, else the one whose
  // path matches the served state.root.
  function currentProject(s) {
    var all = projectsList || [];
    var cur = null;
    if (selectedProject) cur = all.filter(function (p) { return p.id === selectedProject; })[0] || null;
    if (!cur && s && s.root) cur = all.filter(function (p) { return p.path === s.root; })[0] || null;
    return cur;
  }

  function renderBrand(s) {
    var el = byId("pw-project");
    if (!el) return;
    var all = projectsList || [];
    var cur = currentProject(s);
    var label = cur ? displayName(cur, all) : projectName(s);
    if (!label) { el.hidden = true; el.textContent = ""; titleProject = ""; return; }
    el.hidden = false;
    titleProject = label;
    if (unreadTotal() === 0) restoreTitle();   // reflect the project in the tab title
    if (all.length > 1) {
      renderSwitcher(el, all, cur, s);          // multiple projects -> a switcher dropdown
    } else if (s && s.branch) {
      // single project with a known branch -> the plain name plus the same Branch subtitle the
      // switcher carries (no dropdown, since there is nothing to switch between).
      el.className = "pw-project pw-project--solo";
      el.textContent = "";
      el.title = (s && s.root) || label;
      el.appendChild(elt("span", "pw-project-name", label));
      appendBranch(el, s);
    } else {
      el.className = "pw-project";               // single project, no branch -> plain-name look
      el.textContent = label;
      el.title = (s && s.root) || label;
    }
  }

  // Appends the "Branch" subtitle + the active branch value (s.branch) to a project header,
  // shared by the switcher and the single-project header. No-op when branch is "" (detached
  // HEAD / non-git tree), so the line is hidden rather than labelled "HEAD"; the overview's
  // HEAD chip still carries the sha there.
  function appendBranch(el, s) {
    if (!(s && s.branch)) return;
    el.appendChild(elt("span", "pw-section-mini pw-project-label pw-branch-label", "Branch"));
    el.appendChild(elt("span", "pw-project-branch", s.branch));
  }

  // The bottom-left switcher: a native <select> (accessible + themeable, type-to-search built
  // in) listing every allow-listed project, running ones first. Selecting one re-points the
  // client at that project — purely client-side, no server restart and no control endpoint.
  function renderSwitcher(el, all, cur, s) {
    el.className = "pw-project pw-project--switch";
    el.textContent = "";
    el.title = (s && s.root) || "";
    // A "Project" mini-heading above the dropdown, styled like the "Recent contributions"
    // label (.pw-section-mini) so the sidebar reads consistently.
    el.appendChild(elt("span", "pw-section-mini pw-project-label", "Project"));
    var sel = elt("select", "pw-project-select");
    sel.setAttribute("aria-label", "Switch project");
    var order = all.slice().sort(function (a, b) {
      var ra = a.status === "active" ? 0 : 1, rb = b.status === "active" ? 0 : 1;
      if (ra !== rb) return ra - rb;
      return baseOf(a.path).localeCompare(baseOf(b.path));
    });
    order.forEach(function (p) {
      var opt = elt("option");
      opt.value = p.id;
      var pend = p.counts ? p.counts.pending : 0;
      opt.textContent = displayName(p, all) + " · " + p.status + (pend ? " (" + pend + "▸)" : "");
      if (cur && p.id === cur.id) opt.selected = true;
      sel.appendChild(opt);
    });
    sel.addEventListener("change", function () { setSelectedProject(sel.value); });
    // Wrap the native control so a CSS-drawn chevron can sit over it (a <select> can't carry
    // its own ::after); the wrapper owns width, the select fills it.
    var wrap = elt("div", "pw-select-wrap");
    wrap.appendChild(sel);
    el.appendChild(wrap);
    appendBranch(el, s);                          // the selected project's active branch line
  }

  function renderOverview(s) {
    var bar = byId("pw-overview");
    if (!bar) return;
    bar.textContent = "";
    if (!s) { bar.hidden = true; return; }
    bar.hidden = false;

    var L = lengthsOf(s);
    bar.appendChild(s.converged ? chip("status", "converged", "ok") : chip("status", "in progress", "warn"));
    bar.appendChild(chip("pending", String(L.pend)));
    bar.appendChild(chip("accepted", String(L.done)));
    bar.appendChild(chip("rejected", String(L.kill)));
    if (s.head) bar.appendChild(chip("HEAD", String(s.head).slice(0, 7)));

    var fp = s.final_point;
    if (fp) {
      bar.appendChild(chip("final point",
        (fp.deepest_tier || "?") + (fp.date ? " · " + fp.date : ""), fp.stale ? "warn" : null));
    }
    var g = s.graph;
    if (g) {
      bar.appendChild(chip("graph",
        g.node_count + " nodes" + (g.dirty_node_count ? " · " + g.dirty_node_count + " dirty" : ""),
        g.dirty_node_count ? "warn" : null));
    }
    if (ctx.builtSha) bar.appendChild(shaChip(ctx));
    bar.appendChild(elt("span", "pw-updated", "updated " + clockNow()));
  }

  // ---- since-you-looked-away catch-up banner -------------------------------------------

  var prev = null;             // { done:Set, kill:Set, pend:int, dirty:[] }
  var unread = { accepted: 0, killed: 0, dirty: 0, pendFrom: null, pendTo: null };
  var lastPing = 0;

  function titleSet(arr) {
    var s = {};
    (arr || []).forEach(function (it) { if (it && it.title) s[it.title] = true; });
    return s;
  }
  function notIn(arr, set) {
    return (arr || []).filter(function (it) { return it && it.title && !set[it.title]; });
  }

  function catchUp(s) {
    var doneSet = titleSet(s.completed), killSet = titleSet(s.rejected);
    var L = lengthsOf(s);
    var changed = (ctx.metrics && ctx.metrics.dirtyChanged) || [];

    if (!prev) {
      prev = { done: doneSet, kill: killSet, pend: L.pend, dirty: changed.slice() };
      return;
    }
    var newAccepted = notIn(s.completed, prev.done).length;
    var newKilled = notIn(s.rejected, prev.kill).length;
    var prevDirty = {}; prev.dirty.forEach(function (p) { prevDirty[p] = true; });
    var newlyDirty = changed.filter(function (p) { return !prevDirty[p]; }).length;
    var pendDelta = L.pend - prev.pend;

    if (newAccepted || newKilled || newlyDirty || pendDelta !== 0) {
      unread.accepted += newAccepted;
      unread.killed += newKilled;
      unread.dirty += newlyDirty;
      if (unread.pendFrom == null) unread.pendFrom = prev.pend;
      unread.pendTo = L.pend;
      showBanner();
      if (document.hidden) pingTitle();
    }
    prev = { done: doneSet, kill: killSet, pend: L.pend, dirty: changed.slice() };
  }

  function unreadTotal() { return unread.accepted + unread.killed + unread.dirty; }

  function showBanner() {
    var b = byId("pw-banner");
    if (!b) return;
    var parts = [];
    if (unread.accepted) parts.push("+" + unread.accepted + " accepted");
    if (unread.killed) parts.push("+" + unread.killed + " rejected");
    if (unread.pendFrom != null && unread.pendFrom !== unread.pendTo) {
      parts.push("pending " + unread.pendFrom + "→" + unread.pendTo);
    }
    if (unread.dirty) parts.push(unread.dirty + " newly dirty");
    if (!parts.length) { hideBanner(); return; }
    var msg = b.querySelector(".pw-banner-msg");
    if (msg) msg.textContent = parts.join(" · ") + " since you looked away";
    b.hidden = false;
    var badge = byId("pw-console-unread");
    if (badge) {
      var n = unreadTotal();
      badge.textContent = n > 99 ? "99+" : String(n);
      badge.hidden = n === 0;
    }
  }

  function hideBanner() {
    var b = byId("pw-banner");
    if (b) b.hidden = true;
  }

  function clearUnread() {
    unread = { accepted: 0, killed: 0, dirty: 0, pendFrom: null, pendTo: null };
    hideBanner();
    var badge = byId("pw-console-unread");
    if (badge) badge.hidden = true;
    restoreTitle();
    updateFavicon(state);
  }

  // The browser-tab title is project-qualified on a multi-project server: "<project> ·
  // planwright dashboard". titleProject is set by renderBrand; both the unread badge and the
  // restored title route through baseTitle() so the project prefix survives either state.
  function baseTitle() { return titleProject ? titleProject + " · " + TITLE_BASE : TITLE_BASE; }
  function pingTitle() {
    var now = Date.now();
    if (now - lastPing < 2000) return;   // throttle to ≤ 1 / 2s
    lastPing = now;
    document.title = "● " + baseTitle() + " (" + unreadTotal() + ")";
  }
  function restoreTitle() { document.title = baseTitle(); }

  // ---- routing -------------------------------------------------------------------------

  function renderActive() {
    VIEWS.forEach(function (v) {
      var section = byId(v.container);
      if (!section) return;
      var on = v.key === active;
      section.hidden = !on;
      if (!on) return;
      var render = window.PW_VIEWS[v.key];
      if (typeof render === "function" && state) {
        try { render(section, state, ctx); }
        catch (e) { section.textContent = "view error: " + e.message; }
      } else if (!render) {
        section.textContent = "(" + v.key + " view not loaded)";
      }
    });
  }

  function selectTab(key, fromHash) {
    if (KEYS.indexOf(key) === -1) key = KEYS[0];
    active = key;
    document.body.setAttribute("data-active", key);
    var buttons = document.querySelectorAll(".pw-tab");
    Array.prototype.forEach.call(buttons, function (b) {
      var on = b.getAttribute("data-view") === key;
      b.classList.toggle("active", on);
      b.setAttribute("aria-selected", on ? "true" : "false");
      b.tabIndex = on ? 0 : -1;   // roving tabindex
    });
    if (!fromHash && location.hash !== "#" + key) location.hash = key;
    renderActive();
  }

  // ---- fetch ---------------------------------------------------------------------------

  function currentProjectId() {
    try {
      var q = new URLSearchParams(location.search).get("project");
      if (q) return q;
    } catch (e) {}
    return lsGet("pw-project") || null;
  }

  // Append the selected project id (if any) as ?project=<id>; the server resolves it against
  // its allow-list (absent = the launch --root; an unknown id 404s). The browser never sends a
  // path — only an opaque id — which is what keeps selection inside the allow-list.
  function withProject(path) {
    return selectedProject ? path + "?project=" + encodeURIComponent(selectedProject) : path;
  }

  // Switch the whole client to another project: persist the id (localStorage + the URL search
  // param, leaving the hash for tab routing), reconnect the SSE stream to that project, and
  // refetch. View-state only — there is no server-side "current project".
  function setSelectedProject(id) {
    selectedProject = id || null;
    if (selectedProject) lsSet("pw-project", selectedProject);
    else { try { localStorage.removeItem("pw-project"); } catch (e) {} }
    try {
      var u = new URL(location.href);
      if (selectedProject) u.searchParams.set("project", selectedProject);
      else u.searchParams.delete("project");
      history.replaceState(null, "", u.toString());
    } catch (e) {}
    reconnectEvents();
    fetchState();
    fetchProjects();
  }

  // The cross-repo project list that feeds the switcher (and the Fleet view). Cheap; refetched
  // on every change so liveness stays current without a dedicated socket.
  function fetchProjects() {
    return fetch("/projects.json").then(function (r) {
      return r.ok ? r.json() : null;
    }).then(function (data) {
      projectsList = (data && data.projects) || [];
      window.PW_PROJECTS = projectsList;
      renderBrand(state);
      if (active === "fleet") renderActive();   // keep the Fleet grid live
    }).catch(function () {});
  }

  function fetchState() {
    if (fetching) { refetch = true; return Promise.resolve(); }
    fetching = true;
    return Promise.all([
      fetch(withProject("/state.json")).then(function (r) { if (!r.ok) { throw new Error("state " + r.status); } return r.json(); }),
      fetch(withProject("/graph.json")).then(function (r) { return r.ok ? r.text() : null; })
        .catch(function () { return null; }),
    ]).then(function (res) {
      state = res[0];
      captureTrend(state);
      ctx = buildCtx(state, res[1]);
      ctx.trend = trend;
      ctx.projects = projectsList;
      writeAura(state);
      catchUp(state);
      updateFavicon(state);
      renderBrand(state);
      renderOverview(state);
      renderActive();
    }).catch(function (e) {
      setStatus("state error", "err");
      if (window.console && console.error) console.error("state fetch failed", e);
    }).then(function () {
      fetching = false;
      if (refetch) { refetch = false; fetchState(); }
    });
  }

  var sseAttempts = 0;
  function connectEvents() {
    if (typeof EventSource === "undefined") { setStatus("no live updates", "warn"); return; }
    es = new EventSource(withProject("/events"));
    es.addEventListener("change", function () {
      sseAttempts = 0;
      setStatus("live", "ok"); pulse(); fetchState(); fetchProjects();
    });
    es.onopen = function () { sseAttempts = 0; setStatus("live", "ok"); };
    es.onerror = function () {
      // Bounded reconnect with an honest connection state: count consecutive errors, surface
      // live / reconnecting (n) / offline, and once attempts pass the cap stop the browser's
      // implicit retry loop (close the stream) rather than spin "reconnecting" forever.
      sseAttempts += 1;
      var st = window.PW_SSE.status(sseAttempts, SSE_MAX_RECONNECT);
      setStatus(st.text, st.cls);
      if (sseAttempts > SSE_MAX_RECONNECT && es) {
        try { es.close(); } catch (e) {}
        es = null;
      }
    };
  }

  // A project switch re-points the SSE stream at the newly-selected project's .planwright/.
  function reconnectEvents() {
    if (es) { try { es.close(); } catch (e) {} es = null; }
    sseAttempts = 0;
    connectEvents();
  }

  function hashKey() {
    var h = (location.hash || "").replace(/^#/, "");
    return KEYS.indexOf(h) !== -1 ? h : null;
  }

  // ---- theme + glance ------------------------------------------------------------------

  function lsGet(k) { try { return localStorage.getItem(k); } catch (e) { return null; } }
  function lsSet(k, v) { try { localStorage.setItem(k, v); } catch (e) {} }

  function initTheme() {
    var saved = lsGet("pw-theme");
    var prefersLight = window.matchMedia && window.matchMedia("(prefers-color-scheme: light)").matches;
    document.documentElement.setAttribute("data-theme", saved || (prefersLight ? "light" : "dark"));
    updateThemeBtn();
  }
  function toggleTheme() {
    var cur = document.documentElement.getAttribute("data-theme") === "light" ? "light" : "dark";
    var next = cur === "light" ? "dark" : "light";
    document.documentElement.setAttribute("data-theme", next);
    lsSet("pw-theme", next);
    updateThemeBtn();
  }
  function updateThemeBtn() {
    var btn = byId("pw-theme-toggle");
    if (!btn) return;
    var light = document.documentElement.getAttribute("data-theme") === "light";
    btn.setAttribute("aria-label", light ? "Switch to dark theme" : "Switch to light theme");
    btn.title = light ? "Dark theme (d)" : "Light theme (d)";
  }

  function initGlance() { if (lsGet("pw-glance") === "1") document.body.classList.add("pw-glance"); }
  function toggleGlance() {
    var on = document.body.classList.toggle("pw-glance");
    lsSet("pw-glance", on ? "1" : "0");
  }

  // ---- shortcuts sheet -----------------------------------------------------------------

  function toggleShortcuts(force) {
    var s = byId("pw-shortcuts");
    if (!s) return;
    var show = force != null ? force : s.hidden;
    s.hidden = !show;
  }

  // ---- command palette -----------------------------------------------------------------

  var paletteOpen = false, paletteItems = [], paletteIdx = 0, paletteReturn = null;

  function buildCandidates() {
    var c = [];
    VIEWS.forEach(function (v) {
      c.push({ label: v.key, kind: "view", hint: "view", run: function () { selectTab(v.key); } });
    });
    ["repair", "improve", "develop", "docs", "reorganize"].forEach(function (m) {
      c.push({ label: "mode: " + m, kind: "mode", hint: "filter plan",
        run: function () { window.PW_UI.planMode = m; selectTab("plan"); } });
    });
    if (state) {
      [].concat(state.pending || [], state.completed || [], state.rejected || []).forEach(function (it) {
        if (it && it.title) c.push({ label: it.title, kind: "item", hint: "plan item",
          run: function () { selectTab("plan"); } });
      });
    }
    if (ctx.metrics) {
      ctx.metrics.nodesArr.forEach(function (n) {
        c.push({ label: n.path, kind: "file", hint: n.lang,
          run: function () { window.PW_BUS.focusNode(n.path, { view: "insights" }); } });
      });
    }
    return c;
  }

  // Lightweight subsequence fuzzy score; lower is better, null = no match.
  function fuzzy(q, s) {
    if (!q) return 0;
    s = s.toLowerCase();
    var idx = s.indexOf(q);
    if (idx !== -1) return idx;                 // contiguous beats scattered
    var qi = 0, score = 0, last = -1;
    for (var i = 0; i < s.length && qi < q.length; i++) {
      if (s[i] === q[qi]) { score += (last === -1 ? i : i - last); last = i; qi++; }
    }
    return qi === q.length ? 1000 + score : null;
  }

  function openPalette() {
    var p = byId("pw-palette");
    var input = byId("pw-palette-input");
    if (!p || !input) return;
    paletteReturn = document.activeElement;
    paletteOpen = true;
    p.hidden = false;
    input.value = "";
    paintPalette();
    input.focus();
  }
  function closePalette() {
    var p = byId("pw-palette");
    if (!p) return;
    paletteOpen = false;
    p.hidden = true;
    if (paletteReturn && paletteReturn.focus) { try { paletteReturn.focus(); } catch (e) {} }
  }
  function paintPalette() {
    var input = byId("pw-palette-input");
    var list = byId("pw-palette-list");
    if (!input || !list) return;
    var q = input.value.trim().toLowerCase();
    var all = buildCandidates();
    var scored = [];
    all.forEach(function (cand) {
      var sc = fuzzy(q, cand.label);
      if (sc !== null) scored.push({ cand: cand, sc: sc });
    });
    scored.sort(function (a, b) { return a.sc - b.sc; });
    paletteItems = scored.slice(0, 40).map(function (x) { return x.cand; });
    paletteIdx = 0;
    list.textContent = "";
    paletteItems.forEach(function (cand, i) {
      var li = elt("li", "pw-palette-item" + (i === 0 ? " active" : ""));
      li.setAttribute("role", "option");
      var ic = elt("span", "pw-palette-kind is-" + cand.kind, cand.kind);
      li.appendChild(ic);
      li.appendChild(elt("span", "pw-palette-label", cand.label));
      li.appendChild(elt("span", "pw-palette-hint", cand.hint));
      li.addEventListener("click", function () { runPalette(i); });
      li.addEventListener("mousemove", function () { setPaletteIdx(i); });
      list.appendChild(li);
    });
  }
  function setPaletteIdx(i) {
    var list = byId("pw-palette-list");
    if (!list) return;
    var items = list.children;
    if (i < 0) i = 0; if (i >= items.length) i = items.length - 1;
    paletteIdx = i;
    Array.prototype.forEach.call(items, function (el, j) { el.classList.toggle("active", j === i); });
    if (items[i] && items[i].scrollIntoView) items[i].scrollIntoView({ block: "nearest" });
  }
  function runPalette(i) {
    var cand = paletteItems[i != null ? i : paletteIdx];
    closePalette();
    if (cand && cand.run) cand.run();
  }

  // ---- keyboard ------------------------------------------------------------------------

  var gPending = 0;   // timestamp of a pending 'g' chord

  function isTyping(t) {
    return t && (/^(input|textarea|select)$/i.test(t.tagName) || t.isContentEditable);
  }

  function onKeydown(ev) {
    if (ev.defaultPrevented) return;
    var k = ev.key;

    if (paletteOpen) {
      if (k === "Escape") { closePalette(); ev.preventDefault(); }
      else if (k === "ArrowDown") { setPaletteIdx(paletteIdx + 1); ev.preventDefault(); }
      else if (k === "ArrowUp") { setPaletteIdx(paletteIdx - 1); ev.preventDefault(); }
      else if (k === "Enter") { runPalette(); ev.preventDefault(); }
      return;
    }

    // Cmd/Ctrl-K opens the palette from anywhere (even while typing).
    if ((ev.metaKey || ev.ctrlKey) && (k === "k" || k === "K")) { openPalette(); ev.preventDefault(); return; }

    if (k === "Escape") {
      toggleShortcuts(false);
      window.PW_BUS.clearFocus();
      clearUnread();
      return;
    }
    if (isTyping(ev.target)) return;       // let inputs type freely
    if (ev.metaKey || ev.ctrlKey || ev.altKey) return;

    // g-chord (g then a letter within 600ms)
    if (gPending && Date.now() - gPending < 600) {
      gPending = 0;
      var map = { c: "console", m: "commands", p: "plan", i: "insights", w: "graph", t: "timeline", s: "shards", f: "fleet", d: "doctor" };
      if (map[k]) { selectTab(map[k]); ev.preventDefault(); return; }
    }
    if (k === "g") { gPending = Date.now(); return; }

    if (k === "/") { openPalette(); ev.preventDefault(); return; }
    if (k === "?") { toggleShortcuts(); ev.preventDefault(); return; }
    if (k === ".") { toggleGlance(); ev.preventDefault(); return; }
    if (k === "d") { toggleTheme(); ev.preventDefault(); return; }
    if (k === "u") { var b = byId("pw-banner"); if (b && !b.hidden && b.focus) b.focus(); return; }

    if (k >= "1" && k <= "9") {
      var idx = (+k) - 1;
      if (KEYS[idx]) { selectTab(KEYS[idx]); ev.preventDefault(); }
      return;
    }

    // 3D Coupling Web controls (only meaningful on the graph tab; all view-state only)
    if (active === "graph") {
      var gc = byId("view-graph"), step = 0.18;
      if (k === "ArrowLeft") { window.PW_GRAPH.rotate3D(gc, -step, 0); ev.preventDefault(); return; }
      if (k === "ArrowRight") { window.PW_GRAPH.rotate3D(gc, step, 0); ev.preventDefault(); return; }
      if (k === "ArrowUp") { window.PW_GRAPH.rotate3D(gc, 0, -step); ev.preventDefault(); return; }
      if (k === "ArrowDown") { window.PW_GRAPH.rotate3D(gc, 0, step); ev.preventDefault(); return; }
      if (k === "+" || k === "=") { window.PW_GRAPH.zoom3D(gc, 1.2); ev.preventDefault(); return; }
      if (k === "-" || k === "_") { window.PW_GRAPH.zoom3D(gc, 1 / 1.2); ev.preventDefault(); return; }
      if (k === "r") { window.PW_GRAPH.resetView(); ev.preventDefault(); return; }
      if (k === "[" || k === "]") { window.PW_GRAPH.nudgeCoupling(gc, k === "]" ? 0.05 : -0.05); ev.preventDefault(); return; }
      if (k === "i") { window.PW_GRAPH.toggleImports(gc); ev.preventDefault(); return; }
    }
  }

  // Roving-tabindex arrow nav scoped to the tablist.
  function onTabsKeydown(ev) {
    var k = ev.key;
    if (["ArrowLeft", "ArrowRight", "ArrowUp", "ArrowDown", "Home", "End"].indexOf(k) === -1) return;
    var i = KEYS.indexOf(active);
    if (k === "Home") i = 0;
    else if (k === "End") i = KEYS.length - 1;
    else if (k === "ArrowRight" || k === "ArrowDown") i = (i + 1) % KEYS.length;
    else i = (i - 1 + KEYS.length) % KEYS.length;
    selectTab(KEYS[i]);
    var btn = document.querySelector('.pw-tab[data-view="' + KEYS[i] + '"]');
    if (btn) btn.focus();
    ev.preventDefault();
  }

  // ---- init ----------------------------------------------------------------------------

  function init() {
    initTheme();
    initGlance();
    window.PW_BUS.setNavigator(function (view) { selectTab(view); });

    var tabs = byId("pw-tabs");
    if (tabs) {
      tabs.addEventListener("click", function (ev) {
        var btn = ev.target && ev.target.closest && ev.target.closest(".pw-tab");
        var key = btn && btn.getAttribute("data-view");
        if (key) selectTab(key);
      });
      tabs.addEventListener("keydown", onTabsKeydown);
    }
    window.addEventListener("hashchange", function () {
      var key = hashKey();
      if (key && key !== active) selectTab(key, true);
    });

    var themeBtn = byId("pw-theme-toggle");
    if (themeBtn) themeBtn.addEventListener("click", toggleTheme);
    var palBtn = byId("pw-palette-open");
    if (palBtn) palBtn.addEventListener("click", openPalette);
    var palInput = byId("pw-palette-input");
    if (palInput) palInput.addEventListener("input", paintPalette);
    var palBack = byId("pw-palette-backdrop");
    if (palBack) palBack.addEventListener("click", closePalette);
    var bdismiss = document.querySelector(".pw-banner-dismiss");
    if (bdismiss) bdismiss.addEventListener("click", clearUnread);
    var sclose = document.querySelector(".pw-shortcuts-close");
    if (sclose) sclose.addEventListener("click", function () { toggleShortcuts(false); });
    var sback = document.querySelector(".pw-shortcuts-backdrop");
    if (sback) sback.addEventListener("click", function () { toggleShortcuts(false); });

    document.addEventListener("keydown", onKeydown);
    window.addEventListener("focus", function () { restoreTitle(); updateFavicon(state); });
    document.addEventListener("visibilitychange", function () { updateFavicon(state); });

    selectTab(hashKey() || active, true);
    // Resolve the project list first so a stale saved id that no longer registers is dropped
    // before the first /state.json fetch (otherwise that fetch would 404).
    fetchProjects().then(function () {
      if (selectedProject && !projectsList.some(function (p) { return p.id === selectedProject; })) {
        selectedProject = null;
        try { localStorage.removeItem("pw-project"); } catch (e) {}
      }
      fetchState();
      connectEvents();
    });
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", init);
  } else {
    init();
  }
})();
