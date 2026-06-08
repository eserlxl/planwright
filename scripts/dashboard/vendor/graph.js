// SPDX-FileCopyrightText: 2026 Eser KUBALI
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Tiny, dependency-free graph renderers for the dashboard. No external library, no CDN,
// no WebGL toolkit — works fully offline.
//
//   PW_GRAPH.render(container, {nodes:[{id,weight?,articulation?,label?}], edges:[...]}, opts)
//     A flat circular layout. Kept as the safety fallback.
//
//   PW_GRAPH.renderCoupling(container, data, opts)
//     The Coupling Web as an interactive 3D globe: files are placed on a sphere
//     (Fibonacci spiral, ordered by language so same-language files form contiguous
//     colour bands; size = centrality), wired by the temporal co-change edges, with
//     import-cycle danger edges and articulation hazard rings. It is hand-rolled
//     pseudo-3D — yaw/pitch rotation matrices + perspective projection + a painter's
//     depth sort — so it keeps native <title> tooltips, CSS theming, delegated clicks,
//     and the shared PW_BUS focus highlight. Drag to rotate, scroll/buttons to zoom,
//     and an auto-rotate toggle (paused under prefers-reduced-motion). All view-state
//     only — it never mutates the repo.

(function () {
  "use strict";

  var SVG_NS = "http://www.w3.org/2000/svg";

  function el(name, attrs) {
    var node = document.createElementNS(SVG_NS, name);
    for (var k in attrs) {
      if (Object.prototype.hasOwnProperty.call(attrs, k)) node.setAttribute(k, attrs[k]);
    }
    return node;
  }
  function title(text) {
    var t = document.createElementNS(SVG_NS, "title");
    t.textContent = text; return t;
  }
  function clamp(v, lo, hi) { return v < lo ? lo : (v > hi ? hi : v); }

  // ---- legacy circular layout (fallback) ----------------------------------------------

  function render(container, graph, opts) {
    opts = opts || {};
    container.textContent = "";
    var nodes = (graph && graph.nodes) || [];
    var edges = (graph && graph.edges) || [];

    if (!nodes.length) {
      var empty = document.createElement("div");
      empty.className = "pw-empty";
      empty.textContent = "No graph has been built yet (run a plan to build it).";
      container.appendChild(empty);
      return;
    }

    var size = opts.size || 640;
    var cx = size / 2, cy = size / 2, radius = size / 2 - 60;
    var pos = {}, maxWeight = 0;
    nodes.forEach(function (n) { maxWeight = Math.max(maxWeight, n.weight || 0); });
    nodes.forEach(function (n, i) {
      var angle = (2 * Math.PI * i) / nodes.length - Math.PI / 2;
      pos[n.id] = { x: cx + radius * Math.cos(angle), y: cy + radius * Math.sin(angle) };
    });

    var wrap = document.createElement("div");
    wrap.className = "pw-graph-wrap";
    var svg = el("svg", { width: size, height: size, viewBox: "0 0 " + size + " " + size });
    edges.forEach(function (e) {
      var a = pos[e.source], b = pos[e.target];
      if (!a || !b) return;
      svg.appendChild(el("line", { x1: a.x, y1: a.y, x2: b.x, y2: b.y, "class": "pw-edge" }));
    });
    nodes.forEach(function (n) {
      var p = pos[n.id];
      var r = 4 + (maxWeight ? 10 * ((n.weight || 0) / maxWeight) : 0);
      var circle = el("circle", { cx: p.x, cy: p.y, r: r, "class": "pw-node" + (n.articulation ? " articulation" : "") });
      circle.appendChild(title((n.id || n.label || "") + (n.weight ? " · pagerank " + n.weight.toFixed(3) : "")));
      svg.appendChild(circle);
    });
    wrap.appendChild(svg);
    container.appendChild(wrap);
  }

  // ---- 3D Coupling Web ----------------------------------------------------------------
  // Persisted across re-renders so a data refresh never resets the camera.
  var SPIN_MAX = 0.01;   // rad/frame at the top of the speed slider (~10s per turn @60fps)
  var webState = { floor: 0.5, showImports: false, yaw: -0.6, pitch: -0.28, zoom: 1,
                   autoRotate: true, speed: 0.003, hiddenLangs: {} };
  var scene = null;   // the live globe (refs + draw fn); replaced on each renderCoupling
  var reducedMotion = !!(window.matchMedia && window.matchMedia("(prefers-reduced-motion: reduce)").matches);

  // 3x rotation (yaw about Y, then pitch about X) of a point.
  function rotate(p, yaw, pitch) {
    var cy = Math.cos(yaw), sy = Math.sin(yaw);
    var x1 = p.x * cy + p.z * sy, z1 = -p.x * sy + p.z * cy, y1 = p.y;
    var cx = Math.cos(pitch), sx = Math.sin(pitch);
    return { x: x1, y: y1 * cx - z1 * sx, z: y1 * sx + z1 * cx };
  }
  // Yaw/pitch that bring a unit direction to face the camera (maps to +z).
  function faceAngles(u) {
    return { yaw: Math.atan2(-u.x, u.z), pitch: Math.atan2(u.y, Math.hypot(u.x, u.z)) };
  }

  // Fibonacci sphere, ordered by (language, pagerank desc) so languages form contiguous
  // bands and central files cluster early in each band. Writes n._u (unit-sphere coords).
  function placeSphere(nodes) {
    var ordered = nodes.slice().sort(function (a, b) {
      if (a.lang < b.lang) return -1;
      if (a.lang > b.lang) return 1;
      return (b.pagerank || 0) - (a.pagerank || 0);
    });
    var N = ordered.length, ga = Math.PI * (3 - Math.sqrt(5));
    ordered.forEach(function (n, i) {
      var y = N > 1 ? 1 - (i / (N - 1)) * 2 : 0;
      var rad = Math.sqrt(Math.max(0, 1 - y * y)), th = i * ga;
      n._u = { x: Math.cos(th) * rad, y: y, z: Math.sin(th) * rad };
    });
    return ordered;
  }

  function renderCoupling(container, data, opts) {
    opts = opts || {};
    container.textContent = "";
    if (scene && scene.raf && window.cancelAnimationFrame) window.cancelAnimationFrame(scene.raf);
    scene = null;

    var nodes = (data && data.nodes) || [];
    if (!nodes.length) {
      var empty = document.createElement("div");
      empty.className = "pw-empty";
      empty.textContent = (data && data.emptyMsg) ||
        "No graph has been built yet (run a plan to build .planwright/graph.json).";
      container.appendChild(empty);
      return;
    }

    var size = opts.size || 720;
    var cx = size / 2, cy = size / 2;
    var R = size * 0.34, CAM = 2.6 * R, FOCAL = CAM;   // perspective camera
    var maxPr = 0;
    nodes.forEach(function (n) { if ((n.pagerank || 0) > maxPr) maxPr = n.pagerank || 0; });

    var ordered = placeSphere(nodes);
    var byId = {};
    ordered.forEach(function (n) { byId[n.id] = n; });

    // cycle-member set, for node halos + the always-on cycle edges
    var cycleMembers = {};
    (data.cycles || []).forEach(function (cyc) { cyc.forEach(function (id) { cycleMembers[id] = true; }); });

    // strongest coupling partner per node (for the <title>)
    var topPartner = {};
    (data.edges || []).forEach(function (e) {
      var w = +e.weight || 0;
      if (!topPartner[e.source] || w > topPartner[e.source].w) topPartner[e.source] = { id: e.target, w: w };
      if (!topPartner[e.target] || w > topPartner[e.target].w) topPartner[e.target] = { id: e.source, w: w };
    });

    var wrap = document.createElement("div");
    wrap.className = "pw-web-wrap";

    // ---- controls (view-state only) ----
    var controls = document.createElement("div");
    controls.className = "pw-web-controls";

    var sliderLabel = document.createElement("label");
    sliderLabel.className = "pw-web-slider-label";
    var cap = document.createElement("span");
    cap.appendChild(document.createTextNode("coupling ≥ "));
    var floorV = document.createElement("b"); floorV.className = "pw-web-floor-v";
    cap.appendChild(floorV); sliderLabel.appendChild(cap);
    var slider = document.createElement("input");
    slider.type = "range"; slider.min = "0"; slider.max = "1"; slider.step = "0.05";
    slider.value = String(webState.floor); slider.className = "pw-web-slider";
    slider.setAttribute("aria-label", "coupling weight floor");
    sliderLabel.appendChild(slider);
    controls.appendChild(sliderLabel);

    var toggle = document.createElement("button");
    toggle.type = "button";
    toggle.className = "pw-web-toggle" + (webState.showImports ? " active" : "");
    toggle.textContent = "imports overlay";
    toggle.setAttribute("aria-pressed", webState.showImports ? "true" : "false");
    controls.appendChild(toggle);

    var tools = document.createElement("div");
    tools.className = "pw-web-tools";
    var btnOut = webBtn("−", "zoom out");
    var btnIn = webBtn("+", "zoom in");
    var btnReset = webBtn("⟲", "reset view");
    var btnSpin = document.createElement("button");
    btnSpin.type = "button";
    btnSpin.className = "pw-web-btn pw-web-spin" + (webState.autoRotate ? " active" : "");
    btnSpin.setAttribute("aria-pressed", webState.autoRotate ? "true" : "false");
    btnSpin.setAttribute("aria-label", "Auto-rotate");
    btnSpin.title = "Auto-rotate";
    var globe = el("svg", { viewBox: "0 0 24 24", fill: "none", stroke: "currentColor",
      "stroke-width": "2", "stroke-linecap": "round", "stroke-linejoin": "round", "aria-hidden": "true" });
    globe.appendChild(el("circle", { cx: 12, cy: 12, r: 9 }));
    globe.appendChild(el("line", { x1: 3, y1: 12, x2: 21, y2: 12 }));
    globe.appendChild(el("path", { d: "M12 3a15 15 0 0 1 4 9 15 15 0 0 1-4 9 15 15 0 0 1-4-9 15 15 0 0 1 4-9z" }));
    btnSpin.appendChild(globe);
    var speed = document.createElement("input");
    speed.type = "range"; speed.min = "0"; speed.max = "1"; speed.step = "0.01";
    speed.value = String(clamp(webState.speed / SPIN_MAX, 0, 1));
    speed.className = "pw-web-speed";
    speed.setAttribute("aria-label", "auto-rotate speed");
    speed.title = "auto-rotate speed";
    tools.appendChild(btnOut); tools.appendChild(btnIn); tools.appendChild(btnReset);
    tools.appendChild(speed); tools.appendChild(btnSpin);
    controls.appendChild(tools);
    wrap.appendChild(controls);

    var svg = el("svg", {
      "class": "pw-web-svg", viewBox: "0 0 " + size + " " + size,
      preserveAspectRatio: "xMidYMid meet", role: "img",
      "aria-label": "Rotatable 3D coupling globe of " + nodes.length + " files. Drag to rotate, scroll to zoom.",
    });
    wrap.appendChild(svg);

    var legend = document.createElement("div");
    legend.className = "pw-web-legend";
    wrap.appendChild(legend);

    // Clickable language colour key — also a per-language filter (view-state only).
    var langCounts = {};
    ordered.forEach(function (n) { langCounts[n.lang] = (langCounts[n.lang] || 0) + 1; });
    var langKey = document.createElement("div");
    langKey.className = "pw-web-langkey";
    Object.keys(langCounts).sort(function (a, b) { return langCounts[b] - langCounts[a]; })
      .forEach(function (lang) {
        var chip = document.createElement("button");
        chip.type = "button";
        chip.className = "pw-web-lang-chip lang-" + lang + (webState.hiddenLangs[lang] ? " is-off" : "");
        chip.setAttribute("aria-pressed", webState.hiddenLangs[lang] ? "false" : "true");
        chip.setAttribute("aria-label", "toggle " + lang + " files");
        var sw = document.createElement("span"); sw.className = "pw-web-lang-sw";
        chip.appendChild(sw);
        chip.appendChild(document.createTextNode(lang + " " + langCounts[lang]));
        chip.addEventListener("click", function () {
          if (webState.hiddenLangs[lang]) delete webState.hiddenLangs[lang];
          else webState.hiddenLangs[lang] = true;
          var off = !!webState.hiddenLangs[lang];
          chip.classList.toggle("is-off", off);
          chip.setAttribute("aria-pressed", off ? "false" : "true");
          if (scene) { scene.needs = true; ensureLoop(); }
        });
        langKey.appendChild(chip);
      });
    wrap.appendChild(langKey);
    container.appendChild(wrap);

    var edgeG = el("g", {}), nodeG = el("g", {}), labelG = el("g", {});
    svg.appendChild(edgeG); svg.appendChild(nodeG); svg.appendChild(labelG);

    // Node elements built once; geometry/opacity/z-order updated each frame.
    var nodeEls = ordered.map(function (n) {
      var c = el("circle", {
        "class": "pw-web-node lang-" + n.lang +
          (n.articulation ? " articulation" : "") +
          (n.covered ? "" : " is-uncovered") +
          (cycleMembers[n.id] ? " in-cycle" : ""),
      });
      c.setAttribute("data-pw-path", n.id);
      var tp = topPartner[n.id];
      c.appendChild(title(n.id +
        " · pagerank " + (n.pagerank || 0).toFixed(3) +
        " · churn " + (n.churn || 0) +
        " · " + (n.covered ? "covered" : "uncovered") +
        (n.articulation ? " · articulation" : "") +
        (tp ? " · top couple " + tp.id.split("/").pop() + " (" + tp.w.toFixed(2) + ")" : "")));
      nodeG.appendChild(c);
      return { n: n, el: c };
    });
    var elById = {};
    nodeEls.forEach(function (ne) { elById[ne.n.id] = ne; });

    var labelEls = ordered.slice().sort(function (a, b) { return (b.pagerank || 0) - (a.pagerank || 0); })
      .slice(0, opts.maxLabels || 14).map(function (n) {
        var t = el("text", { "class": "pw-web-label" });
        t.textContent = n.base;
        labelG.appendChild(t);
        return { n: n, el: t };
      });

    var edgeEls = [];   // rebuilt when the floor / overlay change
    function buildEdges() {
      edgeG.textContent = ""; edgeEls = [];
      var coup = (data.edges || []).filter(function (e) {
        return byId[e.source] && byId[e.target] && (+e.weight || 0) >= webState.floor;
      }).sort(function (a, b) { return (+b.weight || 0) - (+a.weight || 0); }).slice(0, 120);
      coup.forEach(function (e) {
        var w = +e.weight || 0;
        var ln = el("line", { "class": "pw-coupling-edge" + (w >= 0.8 ? " is-strong" : "") });
        ln.appendChild(title(byId[e.source].base + " ↔ " + byId[e.target].base +
          " · co-change " + w.toFixed(2) + (e.cooccur ? " (" + e.cooccur + "×)" : "")));
        edgeG.appendChild(ln);
        edgeEls.push({ el: ln, a: e.source, b: e.target, w: w });
      });
      if (webState.showImports) {
        (data.importEdges || []).forEach(function (e) {
          if (!byId[e.source] || !byId[e.target]) return;
          var ln = el("line", { "class": "pw-coupling-edge is-import" });
          edgeG.appendChild(ln);
          edgeEls.push({ el: ln, a: e.source, b: e.target, w: 0.2 });
        });
      }
      (data.cycles || []).forEach(function (cyc) {
        for (var i = 0; i < cyc.length; i++) {
          var s = cyc[i], t = cyc[(i + 1) % cyc.length];
          if (!byId[s] || !byId[t]) continue;
          var ln = el("line", { "class": "pw-coupling-edge is-cycle" });
          edgeG.appendChild(ln);
          edgeEls.push({ el: ln, a: s, b: t, w: 1, cycle: true });
        }
      });
    }

    var focusPath = null;
    function depthOpacity(z) { return 0.45 + 0.55 * ((z / R) + 1) / 2; }

    function draw() {
      floorV.textContent = webState.floor.toFixed(2);
      // project every node
      ordered.forEach(function (n) {
        var p = rotate({ x: n._u.x * R, y: n._u.y * R, z: n._u.z * R }, webState.yaw, webState.pitch);
        var f = FOCAL / (CAM - p.z);
        var prN = maxPr ? (n.pagerank || 0) / maxPr : 0;
        n._s = {
          x: cx + p.x * f * webState.zoom,
          y: cy - p.y * f * webState.zoom,
          z: p.z,
          r: Math.max(1.4, (3 + 9 * prN) * f * webState.zoom),
          op: depthOpacity(p.z),
        };
      });
      // nodes: update + paint far-to-near (painter's algorithm)
      var sorted = nodeEls.slice().sort(function (a, b) { return a.n._s.z - b.n._s.z; });
      sorted.forEach(function (ne) {
        if (webState.hiddenLangs[ne.n.lang]) { ne.el.style.display = "none"; return; }
        ne.el.style.display = "";
        var s = ne.n._s, focused = ne.n.id === focusPath;
        ne.el.setAttribute("cx", s.x.toFixed(1));
        ne.el.setAttribute("cy", s.y.toFixed(1));
        ne.el.setAttribute("r", (focused ? s.r + 2 : s.r).toFixed(1));
        ne.el.style.opacity = focused ? 1 : s.op.toFixed(2);
        ne.el.classList.toggle("is-focused", focused);
        nodeG.appendChild(ne.el);   // re-append => moves to front of its depth order
      });
      // edges
      edgeEls.forEach(function (e) {
        if (webState.hiddenLangs[byId[e.a].lang] || webState.hiddenLangs[byId[e.b].lang]) {
          e.el.style.display = "none"; return;
        }
        e.el.style.display = "";
        var a = byId[e.a]._s, b = byId[e.b]._s;
        e.el.setAttribute("x1", a.x.toFixed(1)); e.el.setAttribute("y1", a.y.toFixed(1));
        e.el.setAttribute("x2", b.x.toFixed(1)); e.el.setAttribute("y2", b.y.toFixed(1));
        var op = Math.min((a.op + b.op) / 2, e.cycle ? 0.95 : Math.max(0.12, e.w));
        e.el.setAttribute("stroke-opacity", op.toFixed(2));
        e.el.setAttribute("stroke-width", (1 + 2.4 * e.w).toFixed(2));
      });
      // labels: front hemisphere only, and not for a filtered-out language
      labelEls.forEach(function (le) {
        var s = le.n._s;
        if (webState.hiddenLangs[le.n.lang]) { le.el.style.opacity = "0"; return; }
        if (s.z > 0) {
          le.el.setAttribute("x", (s.x + s.r + 3).toFixed(1));
          le.el.setAttribute("y", (s.y + 3).toFixed(1));
          le.el.style.opacity = (0.3 + 0.7 * s.op).toFixed(2);
        } else {
          le.el.style.opacity = "0";
        }
      });
      legend.textContent = edgeEls.filter(function (e) { return !e.cycle; }).length +
        " links shown (≥" + webState.floor.toFixed(2) + ") · " +
        (data.cycles || []).length + " import cycle" + ((data.cycles || []).length === 1 ? "" : "s") +
        " · 3D — drag to rotate, scroll to zoom · opacity = co-change · dashed red = cycle · hollow = uncovered · colour = language";
    }

    scene = {
      container: container, svg: svg, draw: draw, byId: byId, ordered: ordered,
      elById: elById, R: R, raf: 0, tween: null, needs: true, dragging: false,
      setFocus: function (p) { focusPath = p; scene.needs = true; },
    };

    buildEdges();
    draw();   // first paint synchronously (also makes the headless/no-rAF path render)

    // ---- interaction ----
    var pointers = {}, pcount = 0, pinchDist = 0, moved = false, downX = 0, downY = 0;
    function ptDist() {
      var ks = Object.keys(pointers); if (ks.length < 2) return 0;
      var a = pointers[ks[0]], b = pointers[ks[1]];
      return Math.hypot(a.x - b.x, a.y - b.y);
    }
    svg.addEventListener("pointerdown", function (ev) {
      pointers[ev.pointerId] = { x: ev.clientX, y: ev.clientY }; pcount++;
      scene.dragging = true; moved = false; downX = ev.clientX; downY = ev.clientY;
      scene.tween = null;
      if (pcount === 2) pinchDist = ptDist();
      if (svg.setPointerCapture) { try { svg.setPointerCapture(ev.pointerId); } catch (e) {} }
    });
    svg.addEventListener("pointermove", function (ev) {
      if (!pointers[ev.pointerId]) return;
      var prev = pointers[ev.pointerId];
      pointers[ev.pointerId] = { x: ev.clientX, y: ev.clientY };
      if (pcount >= 2) {
        var d = ptDist();
        if (pinchDist && d) { webState.zoom = clamp(webState.zoom * (d / pinchDist), 0.4, 4); pinchDist = d; scene.needs = true; }
        return;
      }
      var dx = ev.clientX - prev.x, dy = ev.clientY - prev.y;
      if (Math.abs(ev.clientX - downX) + Math.abs(ev.clientY - downY) > 3) moved = true;
      webState.yaw += dx * 0.01;
      webState.pitch = clamp(webState.pitch + dy * 0.01, -1.45, 1.45);
      scene.needs = true;
    });
    function endPointer(ev) {
      if (pointers[ev.pointerId]) { delete pointers[ev.pointerId]; pcount = Math.max(0, pcount - 1); }
      if (pcount === 0) scene.dragging = false;
    }
    svg.addEventListener("pointerup", endPointer);
    svg.addEventListener("pointercancel", endPointer);
    svg.addEventListener("pointerleave", function (ev) { if (pcount && !pointers[ev.pointerId]) {} });

    svg.addEventListener("wheel", function (ev) {
      ev.preventDefault();
      webState.zoom = clamp(webState.zoom * Math.exp(-ev.deltaY * 0.0012), 0.4, 4);
      scene.needs = true;
    }, { passive: false });

    svg.addEventListener("click", function (ev) {
      if (moved) return;   // it was a drag, not a click
      var t = ev.target;
      while (t && t !== svg && !(t.getAttribute && t.getAttribute("data-pw-path"))) t = t.parentNode;
      var path = t && t.getAttribute && t.getAttribute("data-pw-path");
      if (path && typeof opts.onNodeClick === "function") opts.onNodeClick(path);
    });

    slider.addEventListener("input", function () {
      webState.floor = clamp(parseFloat(slider.value) || 0, 0, 1);
      buildEdges(); scene.needs = true;
    });
    toggle.addEventListener("click", function () {
      webState.showImports = !webState.showImports;
      toggle.classList.toggle("active", webState.showImports);
      toggle.setAttribute("aria-pressed", webState.showImports ? "true" : "false");
      buildEdges(); scene.needs = true;
    });
    btnIn.addEventListener("click", function () { webState.zoom = clamp(webState.zoom * 1.2, 0.4, 4); scene.needs = true; });
    btnOut.addEventListener("click", function () { webState.zoom = clamp(webState.zoom / 1.2, 0.4, 4); scene.needs = true; });
    btnReset.addEventListener("click", function () { resetView(); });
    btnSpin.addEventListener("click", function () {
      webState.autoRotate = !webState.autoRotate;
      btnSpin.classList.toggle("active", webState.autoRotate);
      btnSpin.setAttribute("aria-pressed", webState.autoRotate ? "true" : "false");
      ensureLoop();
    });
    speed.addEventListener("input", function () {
      webState.speed = (parseFloat(speed.value) || 0) * SPIN_MAX;
      ensureLoop();
    });

    ensureLoop();
  }

  function webBtn(label, aria) {
    var b = document.createElement("button");
    b.type = "button"; b.className = "pw-web-btn"; b.textContent = label;
    b.setAttribute("aria-label", aria); b.title = aria;
    return b;
  }

  // rAF loop: runs while the globe is mounted+visible. Draws only when something changed
  // (interaction, tween, or auto-rotate), so an idle globe costs nothing.
  function tick() {
    if (!scene) return;
    var c = scene.container, sv = scene.svg;
    if (!sv || sv.isConnected === false) { scene.raf = 0; return; }   // removed from the DOM
    if (c && c.offsetParent === null) { scene.raf = 0; return; }      // tab hidden — pause
    if (scene.tween) {
      var tw = scene.tween, now = (window.performance && performance.now) ? performance.now() : Date.now();
      var p = clamp((now - tw.t0) / tw.dur, 0, 1), e = p < 0.5 ? 2 * p * p : 1 - Math.pow(-2 * p + 2, 2) / 2;
      webState.yaw = tw.fy + tw.dyaw * e;
      webState.pitch = tw.fp + tw.dpitch * e;
      scene.needs = true;
      if (p >= 1) scene.tween = null;
    } else if (webState.autoRotate && !scene.dragging && !reducedMotion && webState.speed > 0) {
      webState.yaw += webState.speed; scene.needs = true;
    }
    if (scene.needs) { scene.draw(); scene.needs = false; }
    scene.raf = window.requestAnimationFrame ? window.requestAnimationFrame(tick) : 0;
  }
  function ensureLoop() {
    if (scene && !scene.raf && window.requestAnimationFrame) scene.raf = window.requestAnimationFrame(tick);
  }

  function resetView() {
    webState.yaw = -0.6; webState.pitch = -0.28; webState.zoom = 1;
    if (scene) { scene.tween = null; scene.needs = true; ensureLoop(); }
  }

  // Bring a focused node to the front of the globe with a short eased tween.
  function faceNode(container, path) {
    if (!scene || !path) return;
    var n = scene.byId[path]; if (!n) return;
    var target = faceAngles(n._u);
    var dyaw = target.yaw - webState.yaw;
    while (dyaw > Math.PI) dyaw -= 2 * Math.PI;
    while (dyaw < -Math.PI) dyaw += 2 * Math.PI;
    scene.tween = {
      fy: webState.yaw, fp: webState.pitch, dyaw: dyaw, dpitch: target.pitch - webState.pitch,
      t0: (window.performance && performance.now) ? performance.now() : Date.now(), dur: 520,
    };
    ensureLoop();
  }

  // Apply / clear the cross-view focus ring (and face the node).
  function highlightCoupling(container, path) {
    if (scene) { scene.setFocus(path || null); ensureLoop(); if (path) faceNode(container, path); }
    var nodes = container.querySelectorAll(".pw-web-node");
    Array.prototype.forEach.call(nodes, function (nEl) {
      nEl.classList.toggle("is-focused", nEl.getAttribute("data-pw-path") === path);
    });
  }

  // Keyboard hooks used by app.js on the Graph tab (all view-state only).
  function rotate3D(container, dyaw, dpitch) {
    webState.yaw += dyaw;
    webState.pitch = clamp(webState.pitch + dpitch, -1.45, 1.45);
    if (scene) { scene.tween = null; scene.needs = true; ensureLoop(); }
  }
  function zoom3D(container, factor) {
    webState.zoom = clamp(webState.zoom * factor, 0.4, 4);
    if (scene) { scene.needs = true; ensureLoop(); }
  }
  function nudgeCoupling(container, delta) {
    var s = container.querySelector(".pw-web-slider");
    if (!s) return false;
    s.value = String(clamp((parseFloat(s.value) || 0) + delta, 0, 1));
    s.dispatchEvent(new Event("input"));
    return true;
  }
  function toggleImports(container) {
    var t = container.querySelector(".pw-web-toggle");
    if (!t) return false;
    t.click(); return true;
  }

  window.PW_GRAPH = {
    render: render,
    renderCoupling: renderCoupling,
    highlightCoupling: highlightCoupling,
    nudgeCoupling: nudgeCoupling,
    toggleImports: toggleImports,
    rotate3D: rotate3D,
    zoom3D: zoom3D,
    resetView: resetView,
  };
})();
