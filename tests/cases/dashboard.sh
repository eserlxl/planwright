# SPDX-FileCopyrightText: 2026 Eser KUBALI
# SPDX-License-Identifier: GPL-3.0-or-later
# shellcheck shell=bash
#
# scripts/dashboard.py — local read-only dashboard server (stdlib http.server + SSE).
# Sourced by tests/run.sh after tests/lib.sh — NOT standalone (uses ROOT/TMP/ok/bad).
#
# The interaction (start server on an ephemeral port, discover the port from its banner,
# hit the endpoints, tear it down) is driven from a single python client so all timing
# stays inside python (no shell `sleep`) and there is no curl dependency.

DASH="$ROOT/scripts/dashboard.py"
DFX="$TMP/dash-fix"; mkdir -p "$DFX/.planwright"
printf -- '- [ ] one\n      Mode: develop\n' > "$DFX/.planwright/plan.md"
printf '{"nodes":{"a.py":{"pagerank":0.5,"is_articulation":true,"imports":["b.py"]},"b.py":{"pagerank":0.2,"is_articulation":false,"imports":[]}}}\n' \
  > "$DFX/.planwright/graph.json"

cat > "$TMP/dash_client.py" <<'PY'
import json, os, subprocess, sys, time, urllib.request, urllib.error, urllib.parse

root, dash = sys.argv[1], sys.argv[2]
proc = subprocess.Popen(
    [sys.executable, dash, "--root", root, "--port", "0"],
    stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
)
try:
    port = None
    deadline = time.time() + 10
    while time.time() < deadline:
        line = proc.stdout.readline()
        if not line:
            if proc.poll() is not None:
                print("server exited early", file=sys.stderr); sys.exit(1)
            continue
        if "http://127.0.0.1:" in line:
            port = int(line.split("http://127.0.0.1:")[1].split("/")[0])
            break
    if not port:
        print("no port banner", file=sys.stderr); sys.exit(1)
    base = "http://127.0.0.1:%d" % port

    # /state.json: JSON content-type, no-store (a live view must never cache), nosniff,
    # and the expected snapshot
    with urllib.request.urlopen(base + "/state.json", timeout=5) as r:
        assert r.headers.get_content_type() == "application/json", r.headers.get_content_type()
        assert r.headers.get("Cache-Control") == "no-store", r.headers.get("Cache-Control")
        assert r.headers.get("X-Content-Type-Options") == "nosniff", r.headers.get("X-Content-Type-Options")
        data = json.load(r)
    assert data["schema_version"] == 1, data
    assert data["counts"]["pending"] == 1, data["counts"]
    assert data["pending"][0]["title"] == "one", data["pending"]

    # /events: a Server-Sent Events stream that opens with a `change` event
    ev = urllib.request.urlopen(base + "/events", timeout=5)
    assert ev.headers.get_content_type() == "text/event-stream", ev.headers.get_content_type()
    first = ev.readline()
    assert first.startswith(b"event: change"), first
    ev.close()

    # path traversal is refused (404, not a file outside the static root)
    try:
        urllib.request.urlopen(base + "/../../etc/passwd", timeout=5)
        traversal_blocked = False
    except urllib.error.HTTPError as e:
        traversal_blocked = e.code == 404
    except Exception:
        traversal_blocked = True
    assert traversal_blocked, "path traversal was not refused"

    # DNS-rebinding guard: a request carrying a foreign Host is refused (403) before any
    # endpoint dispatch, so a rebound malicious origin cannot read the planning state.
    req = urllib.request.Request(base + "/state.json", headers={"Host": "attacker.example"})
    try:
        urllib.request.urlopen(req, timeout=5)
        host_blocked = False
    except urllib.error.HTTPError as e:
        host_blocked = e.code == 403
    assert host_blocked, "foreign Host header was not refused"

    # Host is case-insensitive (RFC 4343): a legitimate mixed-case loopback name must be
    # allowed, not 403'd. The allow-list is lowercase, so a `Localhost` Host must be folded
    # before matching (regression guard for the rebinding check rejecting real loopback).
    _port = urllib.parse.urlparse(base).port
    req_mc = urllib.request.Request(base + "/state.json", headers={"Host": "Localhost:%d" % _port})
    try:
        mc_ok = urllib.request.urlopen(req_mc, timeout=5).status == 200
    except urllib.error.HTTPError:
        mc_ok = False
    assert mc_ok, "mixed-case loopback Host (Localhost) was wrongly refused"

    # Absent Host: HTTP/1.0 / non-browser clients send no Host header and cannot be rebound
    # through, so the guard deliberately ALLOWS them (dashboard.py _host_allowed returns True
    # on an empty Host). urllib always injects a Host, so exercise this branch via a raw
    # socket sending a minimal HTTP/1.0 request line with no Host.
    import socket
    raw = socket.create_connection(("127.0.0.1", _port), timeout=5)
    raw.sendall(b"GET /state.json HTTP/1.0\r\n\r\n")
    buf = b""
    while b"\r\n" not in buf:
        chunk = raw.recv(256)
        if not chunk:
            break
        buf += chunk
    raw.close()
    nohost_status = buf.split(b"\r\n", 1)[0]
    assert b" 200 " in nohost_status, "absent-Host request not allowed: %r" % nohost_status
    print("NOHOST-OK")

    print("DASH-OK")

    # SSE live-update path: after subscribing to /events, mutating a .planwright/ file
    # must push a fresh `change` event — the dashboard's whole reason to exist. (The
    # block above only checked the initial event + content-type, never a real change.)
    ev2 = urllib.request.urlopen(base + "/events", timeout=8)
    assert ev2.readline().startswith(b"event: change"), "no initial change event"
    with open(os.path.join(root, ".planwright", "plan.md"), "a") as fh:
        fh.write("\n      Rationale: live-touch\n")
    saw_push = False
    for _ in range(64):                      # bounded; socket timeout (8s) is the backstop
        line = ev2.readline()
        if not line:
            break
        if line.startswith(b"event: change"):
            saw_push = True
            break
    ev2.close()
    assert saw_push, "no change event after mutating .planwright/"
    print("SSE-CHANGE-OK")

    # GET / serves the static UI shell (from scripts/dashboard/, resolved off the
    # script location, not the fixture root): 200 text/html that references app.js
    # and contains the three view-container ids.
    with urllib.request.urlopen(base + "/", timeout=5) as r:
        assert r.headers.get_content_type() == "text/html", r.headers.get_content_type()
        html = r.read().decode("utf-8")
    assert "/app.js" in html, "index.html does not reference app.js"
    for cid in ("view-plan", "view-timeline", "view-graph"):
        assert ('id="' + cid + '"') in html, "index.html missing container " + cid
    assert 'id="pw-overview"' in html, "index.html missing the overview strip"
    assert 'role="tab"' in html, "index.html tabs missing ARIA roles"
    print("SHELL-OK")

    # Nested /vendor/*.js: index.html loads the graph view's libraries from /vendor/,
    # served via dashboard.py's nested-subdirectory static path. Fetch every /vendor/*.js
    # the shell references and assert 200 + javascript content-type + non-empty body, so a
    # missing asset or a broken nested-path resolution turns the suite red (statics-scaffold
    # only checks they exist on disk; nothing fetched them over HTTP).
    import re as _re
    vendors = sorted(set(_re.findall(r'src="(/vendor/[^"]+\.js)"', html)))
    assert vendors, "index.html references no /vendor/*.js assets"
    for vpath in vendors:
        with urllib.request.urlopen(base + vpath, timeout=5) as r:
            vct = r.headers.get_content_type()
            vbody = r.read()
        assert vct == "text/javascript", vpath + " content-type: " + vct
        assert len(vbody) > 0, vpath + " served empty"
    # The vendored Inter font must serve with the correct font MIME (not octet-stream),
    # so the @font-face in style.css loads it cleanly offline.
    with urllib.request.urlopen(base + "/vendor/inter-variable.woff2", timeout=5) as r:
        fct = r.headers.get_content_type()
        fbody = r.read()
    assert fct == "font/woff2", "woff2 content-type: " + fct
    assert len(fbody) > 0, "woff2 served empty"
    print("VENDOR-OK")

    # /graph.json passthrough (the data path the graph view consumes)
    with urllib.request.urlopen(base + "/graph.json", timeout=5) as r:
        assert r.headers.get_content_type() == "application/json", r.headers.get_content_type()
        g = json.load(r)
    assert "nodes" in g and "a.py" in g["nodes"], g
    print("GRAPH-JSON-OK")

    # /doctor.json — the read-only environment preflight the Doctor view consumes
    with urllib.request.urlopen(base + "/doctor.json", timeout=10) as r:
        assert r.headers.get_content_type() == "application/json", r.headers.get_content_type()
        assert r.headers.get("Cache-Control") == "no-store", r.headers.get("Cache-Control")
        doc = json.load(r)
    assert "checks" in doc and isinstance(doc["checks"], list) and doc["checks"], doc
    assert set(doc) >= {"ok", "fail", "warn", "total", "checks"}, doc
    assert "fixed" not in doc, "the dashboard endpoint must never trigger doctor --fix"
    print("DOCTOR-JSON-OK")

    # Each view module: served with 200, registers into PW_VIEWS, referenced by the shell.
    def check_view(name):
        with urllib.request.urlopen(base + "/views/" + name + ".js", timeout=5) as r:
            body = r.read().decode("utf-8")
            assert r.status == 200, r.status
        assert "PW_VIEWS." + name in body, name + ".js does not register PW_VIEWS." + name
        assert ("/views/" + name + ".js") in html, name + ".js not referenced by the shell"
        print("VIEW-" + name + "-OK")

    for v in os.environ.get("PW_TEST_VIEWS", "").split():
        try:
            check_view(v)
        except urllib.error.HTTPError as e:
            if e.code == 404:
                continue   # view not landed yet; its own test gates it once it is
            raise
finally:
    proc.terminate()
    try:
        rc = proc.wait(timeout=5)
        # serve()'s SIGTERM handler routes to its KeyboardInterrupt/finally clean shutdown,
        # so a terminated server exits 0 (not killed by the default SIGTERM disposition),
        # which lets the coverage atexit flush run for the server subprocess.
        if rc == 0:
            print("SIGTERM-CLEAN-EXIT")
    except subprocess.TimeoutExpired:
        proc.kill()
PY

# --- Tests DSH1/DSH2/DSH3: endpoints + the static UI shell + the view modules -------
# PW_TEST_VIEWS lists the view modules to assert are served+registered (grows as each
# view lands), so every view ships with a runnable served+referenced check.
PW_TEST_VIEWS="console commands plan timeline graph insights doctor" \
  python3 "$TMP/dash_client.py" "$DFX" "$DASH" >"$TMP/dash.out" 2>"$TMP/dash.err" || true
if grep -q DASH-OK "$TMP/dash.out"; then
  ok "dashboard.py serves /state.json (JSON) + /events (text/event-stream), refuses traversal + foreign Host"
else
  bad "dashboard.py endpoint check failed: $(cat "$TMP/dash.err" 2>/dev/null)"
fi
if grep -q NOHOST-OK "$TMP/dash.out"; then
  ok "dashboard.py allows a no-Host (HTTP/1.0) request — the deliberate DNS-rebinding pass-through"
else
  bad "dashboard.py absent-Host pass-through check failed: $(cat "$TMP/dash.err" 2>/dev/null)"
fi
if grep -q SIGTERM-CLEAN-EXIT "$TMP/dash.out"; then
  ok "dashboard.py shuts down cleanly on SIGTERM (proc.terminate() -> exit 0, atexit can flush)"
else
  bad "dashboard.py did not exit 0 on SIGTERM (no clean-shutdown handler): $(cat "$TMP/dash.err" 2>/dev/null)"
fi
if grep -q SSE-CHANGE-OK "$TMP/dash.out"; then
  ok "dashboard.py /events pushes a change event when .planwright/ mutates (live update)"
else
  bad "dashboard.py SSE change-event check failed: $(cat "$TMP/dash.err" 2>/dev/null)"
fi
if grep -q SHELL-OK "$TMP/dash.out"; then
  ok "dashboard.py serves the UI shell (GET / 200, references app.js, three view containers)"
else
  bad "dashboard.py UI shell check failed: $(cat "$TMP/dash.err" 2>/dev/null)"
fi
if grep -q VENDOR-OK "$TMP/dash.out"; then
  ok "dashboard.py serves every nested /vendor/*.js the shell references (200, javascript, non-empty)"
else
  bad "dashboard.py nested /vendor asset serving check failed: $(cat "$TMP/dash.err" 2>/dev/null)"
fi
if grep -q VIEW-plan-OK "$TMP/dash.out"; then
  ok "dashboard serves the Plan view (views/plan.js registers PW_VIEWS.plan, referenced by shell)"
else
  bad "dashboard Plan view check failed: $(cat "$TMP/dash.err" 2>/dev/null)"
fi
if grep -q VIEW-timeline-OK "$TMP/dash.out"; then
  ok "dashboard serves the Cycle-timeline view (views/timeline.js registers PW_VIEWS.timeline)"
else
  bad "dashboard Cycle-timeline view check failed: $(cat "$TMP/dash.err" 2>/dev/null)"
fi
if grep -q VIEW-graph-OK "$TMP/dash.out"; then
  ok "dashboard serves the Dependency-graph view (views/graph.js registers PW_VIEWS.graph)"
else
  bad "dashboard Dependency-graph view check failed: $(cat "$TMP/dash.err" 2>/dev/null)"
fi
if grep -q VIEW-console-OK "$TMP/dash.out"; then
  ok "dashboard serves the Console view (views/console.js registers PW_VIEWS.console)"
else
  bad "dashboard Console view check failed: $(cat "$TMP/dash.err" 2>/dev/null)"
fi
if grep -q VIEW-commands-OK "$TMP/dash.out"; then
  ok "dashboard serves the Commands view (views/commands.js registers PW_VIEWS.commands)"
else
  bad "dashboard Commands view check failed: $(cat "$TMP/dash.err" 2>/dev/null)"
fi
# The Commands view must wire the cold-start reset nudge from the coach engine. The
# rendering is jsdom-bound (untestable here), but the COACH.reset(...) call is a grep-able
# guard so the suggestion cannot be silently dropped from the view (its logic is pinned in
# derive.sh; this pins that the view actually consumes it).
if grep -q 'COACH\.reset(' "$ROOT/scripts/dashboard/views/commands.js"; then
  ok "Commands view wires the coach reset suggestion (COACH.reset)"
else
  bad "Commands view dropped the coach reset suggestion wiring (COACH.reset)"
fi
if grep -q VIEW-insights-OK "$TMP/dash.out"; then
  ok "dashboard serves the Insights view (views/insights.js registers PW_VIEWS.insights)"
else
  bad "dashboard Insights view check failed: $(cat "$TMP/dash.err" 2>/dev/null)"
fi
if grep -q GRAPH-JSON-OK "$TMP/dash.out"; then
  ok "dashboard.py /graph.json passthrough serves .planwright/graph.json"
else
  bad "dashboard.py /graph.json passthrough failed: $(cat "$TMP/dash.err" 2>/dev/null)"
fi
if grep -q DOCTOR-JSON-OK "$TMP/dash.out"; then
  ok "dashboard.py /doctor.json serves the read-only preflight payload (no --fix)"
else
  bad "dashboard.py /doctor.json failed: $(cat "$TMP/dash.err" 2>/dev/null)"
fi
if grep -q VIEW-doctor-OK "$TMP/dash.out"; then
  ok "dashboard serves the Doctor view (views/doctor.js registers PW_VIEWS.doctor)"
else
  bad "dashboard Doctor view check failed: $(cat "$TMP/dash.err" 2>/dev/null)"
fi

# --- Test DASH-SSE-PING: an idle /events stream emits the keep-alive `: ping` ----------
# The heartbeat (HEARTBEAT_INTERVAL) is the only mechanism that reaps a vanished SSE client
# (the failing write tears the handler thread down) during the long unattended cycle runs
# the dashboard is built to watch. With sub-second POLL/HEARTBEAT env overrides, an idle
# stream (no .planwright/ mutation) must emit a `: ping` comment line.
cat > "$TMP/dash_ping.py" <<'PY'
import os, subprocess, sys, time, urllib.request
root, dash = sys.argv[1], sys.argv[2]
env = dict(os.environ, PW_DASH_POLL="0.05", PW_DASH_HEARTBEAT="0.1")
proc = subprocess.Popen([sys.executable, dash, "--root", root, "--port", "0"],
                        stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, env=env)
try:
    port, deadline = None, time.time() + 10
    while time.time() < deadline:
        line = proc.stdout.readline()
        if not line:
            if proc.poll() is not None:
                print("server exited early", file=sys.stderr); sys.exit(1)
            continue
        if "http://127.0.0.1:" in line:
            port = int(line.split("http://127.0.0.1:")[1].split("/")[0]); break
    if not port:
        print("no port banner", file=sys.stderr); sys.exit(1)
    ev = urllib.request.urlopen("http://127.0.0.1:%d/events" % port, timeout=5)
    assert ev.readline().startswith(b"event: change"), "no initial change event"
    # Stay idle (do NOT touch .planwright/); a heartbeat ping must arrive within a bounded read.
    saw_ping = False
    for _ in range(50):
        if ev.readline().startswith(b": ping"):
            saw_ping = True; break
    ev.close()
    assert saw_ping, "no `: ping` heartbeat on an idle /events stream"
    print("SSE-PING-OK")
finally:
    proc.terminate()
    try:
        proc.wait(timeout=5)
    except Exception:
        proc.kill()
PY
DPDIR="$TMP/dash-ping"; mkdir -p "$DPDIR/.planwright"
printf -- '- [ ] one\n      Mode: improve\n' > "$DPDIR/.planwright/plan.md"
python3 "$TMP/dash_ping.py" "$DPDIR" "$DASH" >"$TMP/dping.out" 2>"$TMP/dping.err" || true
if grep -q SSE-PING-OK "$TMP/dping.out"; then
  ok "dashboard.py /events emits the : ping heartbeat on an idle stream (vanished-client reaper)"
else
  bad "dashboard.py heartbeat ping not observed: $(cat "$TMP/dping.err" 2>/dev/null)"
fi

# --- /graph.json on a graphless root returns 404 {"error":"no graph built"} -----------
# The passthrough success is covered above; the no-graph guard (dashboard.py:189) was not.
# A second short-lived server on a root with a plan but NO graph.json exercises it.
DFX2="$TMP/dash-nograph"; mkdir -p "$DFX2/.planwright"
printf -- '- [ ] x\n      Mode: develop\n' > "$DFX2/.planwright/plan.md"   # plan but NO graph.json
cat > "$TMP/dash_nograph.py" <<'PY'
import json, subprocess, sys, time, urllib.request, urllib.error
root, dash = sys.argv[1], sys.argv[2]
proc = subprocess.Popen([sys.executable, dash, "--root", root, "--port", "0"],
                        stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
try:
    port = None
    deadline = time.time() + 10
    while time.time() < deadline:
        line = proc.stdout.readline()
        if not line:
            if proc.poll() is not None:
                print("server exited early", file=sys.stderr); sys.exit(1)
            continue
        if "http://127.0.0.1:" in line:
            port = int(line.split("http://127.0.0.1:")[1].split("/")[0]); break
    if not port:
        print("no port banner", file=sys.stderr); sys.exit(1)
    base = "http://127.0.0.1:%d" % port
    try:
        urllib.request.urlopen(base + "/graph.json", timeout=5)
        print("expected 404, got 200", file=sys.stderr); sys.exit(1)
    except urllib.error.HTTPError as e:
        assert e.code == 404, e.code
        body = json.load(e)
        assert "no graph built" in body.get("error", ""), body
    print("NOGRAPH-OK")
finally:
    proc.terminate()
    try:
        proc.wait(timeout=5)
    except Exception:
        proc.kill()
PY
if python3 "$TMP/dash_nograph.py" "$DFX2" "$DASH" >"$TMP/dash_ng.out" 2>"$TMP/dash_ng.err" \
   && grep -q NOGRAPH-OK "$TMP/dash_ng.out"; then
  ok "dashboard.py /graph.json returns 404 {error: no graph built} on a graphless root"
else
  bad "dashboard.py /graph.json no-graph 404 failed: $(cat "$TMP/dash_ng.err" 2>/dev/null)"
fi


# --- Test DASH-FN: app.js is functionally exercised, not just node --check ----
# statics-scaffold.sh only parse-checks app.js; this boots the real IIFE against a
# hand-rolled DOM/fetch/EventSource shim (no jsdom — the dashboard is zero-npm) and
# drives the documented contract: a view registered in window.PW_VIEWS must receive
# the fetched /state.json, and an SSE 'change' must re-fetch and re-render the new
# state. Node-gated with a clean skip, exactly like derive.sh.
if command -v node >/dev/null 2>&1; then
  cat > "$TMP/app_fn_test.js" <<'JS'
const fs = require("fs");
const vm = require("vm");
const assert = require("assert");
const APP = process.argv[2];

// ---- minimal universal DOM element (only what app.js touches at boot/render) ----
function El(tag) {
  this.tagName = (tag || "div").toUpperCase();
  this.children = [];
  this.style = { setProperty() {}, removeProperty() {}, getPropertyValue() { return ""; } };
  this._attr = {};
  this.dataset = {};
  this.classList = {
    _s: {},
    add(c) { this._s[c] = true; },
    remove(c) { delete this._s[c]; },
    toggle(c, on) { if (on === undefined) { on = !this._s[c]; } if (on) { this._s[c] = true; } else { delete this._s[c]; } return !!on; },
    contains(c) { return !!this._s[c]; },
  };
  this.textContent = ""; this.innerHTML = ""; this.hidden = false;
  this.className = ""; this.tabIndex = 0; this.value = "";
}
El.prototype.appendChild = function (c) { this.children.push(c); return c; };
El.prototype.removeChild = function (c) { this.children = this.children.filter(function (x) { return x !== c; }); return c; };
El.prototype.insertBefore = function (c) { this.children.unshift(c); return c; };
El.prototype.append = function (c) { this.children.push(c); };
El.prototype.replaceChildren = function () { this.children = []; };
El.prototype.remove = function () {};
El.prototype.addEventListener = function () {};
El.prototype.removeEventListener = function () {};
El.prototype.setAttribute = function (k, v) { this._attr[k] = String(v); };
El.prototype.getAttribute = function (k) { return (k in this._attr) ? this._attr[k] : null; };
El.prototype.hasAttribute = function (k) { return k in this._attr; };
El.prototype.removeAttribute = function (k) { delete this._attr[k]; };
El.prototype.querySelector = function () { return null; };
El.prototype.querySelectorAll = function () { return []; };
El.prototype.getContext = function () { return null; };
El.prototype.toDataURL = function () { return ""; };
El.prototype.focus = function () {}; El.prototype.click = function () {};
El.prototype.contains = function () { return false; };

const _byId = {};
const doc = {
  readyState: "complete", hidden: false, visibilityState: "visible", title: "",
  getElementById(id) { return _byId[id] || (_byId[id] = new El()); },
  querySelector() { return null; },
  querySelectorAll() { return []; },
  createElement(t) { return new El(t); },
  createElementNS(ns, t) { return new El(t); },
  addEventListener() {}, removeEventListener() {},
};
doc.body = new El("body"); doc.documentElement = new El("html"); doc.head = new El("head");

let _changeHandler = null;
function FakeEventSource() {}
FakeEventSource.prototype.addEventListener = function (type, fn) { if (type === "change") { _changeHandler = fn; } };
Object.defineProperty(FakeEventSource.prototype, "onopen", { set() {} });
Object.defineProperty(FakeEventSource.prototype, "onerror", { set() {} });
FakeEventSource.prototype.close = function () {};

let SERVED = null;
let STATE_OK = true;  // flip to simulate the server returning HTTP 500 for /state.json
function fakeFetch(url) {
  if (url === "/state.json") {
    if (!STATE_OK) { return Promise.resolve({ ok: false, status: 500, json() { return Promise.resolve({ error: "boom" }); } }); }
    return Promise.resolve({ ok: true, json() { return Promise.resolve(SERVED); } });
  }
  return Promise.resolve({ ok: false, text() { return Promise.resolve(null); } });  // no graph
}

const seen = [];
const win = {
  PW_VIEWS: { console(container, state, ctx) { seen.push({ state: state, ctx: ctx }); } },
  PW_UI: {},
  PW_BUS: { setNavigator() {}, focusNode() {}, clearFocus() {} },
  addEventListener() {}, removeEventListener() {},
  matchMedia() { return { matches: false, addEventListener() {}, addListener() {} }; },
  requestAnimationFrame() { return 0; },
  location: { hash: "", href: "http://x/", reload() {} },
  localStorage: { _d: {}, getItem(k) { return (k in this._d) ? this._d[k] : null; }, setItem(k, v) { this._d[k] = String(v); }, removeItem(k) { delete this._d[k]; } },
  console: console,
};

global.window = win;
global.document = doc;
global.location = win.location;
global.localStorage = win.localStorage;
global.fetch = fakeFetch;
global.EventSource = FakeEventSource;
global.requestAnimationFrame = win.requestAnimationFrame;
global.matchMedia = win.matchMedia;

SERVED = {
  schema_version: 1, root: "/x", head: "abc1234def0000", converged: false,
  counts: { pending: 2, completed: 1, rejected: 0 }, pending_modes: {},
  pending: [], completed: [], rejected: [], final_point: null, graph: null,
};

vm.runInThisContext(fs.readFileSync(APP, "utf8"), { filename: "app.js" });

(async function () {
  await new Promise(function (r) { setTimeout(r, 50); });
  assert(seen.length >= 1, "registered console view never rendered after fetchState()");
  const last = seen[seen.length - 1];
  assert(last.state && last.state.counts.pending === 2, "view did not receive the served /state.json (pending=2)");

  assert(typeof _changeHandler === "function", "app.js never registered an SSE 'change' listener");
  SERVED = Object.assign({}, SERVED, { converged: true, counts: { pending: 0, completed: 3, rejected: 0 } });
  _changeHandler();
  await new Promise(function (r) { setTimeout(r, 50); });
  const last2 = seen[seen.length - 1];
  assert(last2.state && last2.state.converged === true && last2.state.counts.pending === 0,
    "SSE 'change' did not re-fetch + re-render the new state");

  // A /state.json HTTP 500 (error body) must NOT be rendered as a snapshot: the r.ok guard
  // routes it to fetchState's .catch, so no view ever receives the {error:...} body
  // (regression: app.js used to json()-parse a 500 body straight into the view).
  STATE_OK = false;
  _changeHandler();
  await new Promise(function (r) { setTimeout(r, 50); });
  assert(seen.every(function (s) { return s.state && s.state.counts && s.state.error === undefined; }),
    "a /state.json 500 error body was handed to a view as a state snapshot (missing r.ok guard)");

  console.log("APP-FN-OK");
})().catch(function (e) { console.error("APP-FN-FAIL", e && e.message); process.exit(1); });
JS
  if node "$TMP/app_fn_test.js" "$ROOT/scripts/dashboard/app.js" >"$TMP/app_fn.out" 2>"$TMP/app_fn.err" && grep -q APP-FN-OK "$TMP/app_fn.out"; then
    ok "dashboard app.js boots + drives state/SSE render via PW_VIEWS contract (functional, not just node --check)"
  else
    bad "dashboard app.js functional check failed: $(cat "$TMP/app_fn.err" 2>/dev/null)"
  fi
else
  ok "dashboard app.js functional check skipped (node not installed)"
fi


# --- Test DASH-PORT: a busy --port fails cleanly (errno 98), not a traceback ---
# serve() bound ThreadingHTTPServer with no guard, so a busy explicit --port raised
# an uncaught OSError. It must now exit 2 with a clear "already in use" message.
cat > "$TMP/dash_portbusy.py" <<'PY'
import socket, subprocess, sys
dash = sys.argv[1]
s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", 0)); s.listen()
port = s.getsockname()[1]
p = subprocess.run([sys.executable, dash, "--root", ".", "--port", str(port)],
                   capture_output=True, text=True, timeout=15)
assert p.returncode == 2, "expected exit 2, got %r (stderr=%r)" % (p.returncode, p.stderr)
assert "already in use" in p.stderr, p.stderr
assert "Traceback" not in p.stderr, "leaked a traceback: " + p.stderr
print("PORTBUSY-OK")
PY
if python3 "$TMP/dash_portbusy.py" "$DASH" >"$TMP/dash_pb.out" 2>"$TMP/dash_pb.err" && grep -q PORTBUSY-OK "$TMP/dash_pb.out"; then
  ok "dashboard.py exits 2 with a clear message on a busy --port (no traceback)"
else
  bad "dashboard.py mishandled a busy --port: $(cat "$TMP/dash_pb.err" 2>/dev/null)"
fi


# --- Test DASH-PORTRANGE: an out-of-range --port exits 2 cleanly, not OverflowError ---
# socket.bind raises OverflowError (not OSError) for a port outside 0-65535, which
# escaped serve()'s bind guard as a traceback with exit 1 — off the documented
# exit-2 contract the DASH-PORT case pins for the busy-port sibling. serve() now
# pre-validates the range.
cat > "$TMP/dash_portrange.py" <<'PY'
import subprocess, sys
dash = sys.argv[1]
for bad_port in ("70000", "-1"):
    p = subprocess.run([sys.executable, dash, "--root", ".", "--port", bad_port],
                       capture_output=True, text=True, timeout=15)
    assert p.returncode == 2, "port %s: expected exit 2, got %r (stderr=%r)" % (bad_port, p.returncode, p.stderr)
    assert "invalid port" in p.stderr, p.stderr
    assert "Traceback" not in p.stderr, "leaked a traceback: " + p.stderr
print("PORTRANGE-OK")
PY
if python3 "$TMP/dash_portrange.py" "$DASH" >"$TMP/dash_pr.out" 2>"$TMP/dash_pr.err" && grep -q PORTRANGE-OK "$TMP/dash_pr.out"; then
  ok "dashboard.py exits 2 with a clear message on an out-of-range --port (no traceback)"
else
  bad "dashboard.py mishandled an out-of-range --port: $(cat "$TMP/dash_pr.err" 2>/dev/null)"
fi

# --- Test DASH-VIEWS-FN: every registered view's render() actually runs ----------------
# DASH-FN boots app.js with a PW_VIEWS *stub*, and DSH checks only served+registered, so a
# view's render() is never executed — a logic regression (a renamed state.py field, a null
# deref on a graph-less snapshot, an unshimmed DOM call) ships green. Load the real derive
# engine + the vendored coupling renderer + each view against the El/doc shim and call
# render() for a full state+graph snapshot AND a degraded graph-less (metrics=null) snapshot.
# Covers all seven views: the four state-driven ones, timeline + graph (graph's full path
# drives PW_GRAPH.renderCoupling, its bare path the graph-less guard), and the fetch-based
# doctor view (stubbed fetch -> async paint). Node-gated.
if command -v node >/dev/null 2>&1; then
  cat > "$TMP/views_fn_test.js" <<'JS'
const fs = require("fs");
const vm = require("vm");
const assert = require("assert");
const BASE = process.argv[2];

function El(tag) {
  this.tagName = (tag || "div").toUpperCase();
  this.children = [];
  this.style = { setProperty() {}, removeProperty() {}, getPropertyValue() { return ""; } };
  this._attr = {}; this.dataset = {};
  this.classList = { _s: {}, add(c) { this._s[c] = true; }, remove(c) { delete this._s[c]; },
    toggle(c, on) { if (on === undefined) { on = !this._s[c]; } if (on) { this._s[c] = true; } else { delete this._s[c]; } return !!on; },
    contains(c) { return !!this._s[c]; } };
  this.textContent = ""; this.innerHTML = ""; this.hidden = false;
  this.className = ""; this.tabIndex = 0; this.value = "";
}
El.prototype.appendChild = function (c) { this.children.push(c); return c; };
El.prototype.removeChild = function (c) { this.children = this.children.filter(function (x) { return x !== c; }); return c; };
El.prototype.insertBefore = function (c) { this.children.unshift(c); return c; };
El.prototype.append = function () { for (var i = 0; i < arguments.length; i++) { this.children.push(arguments[i]); } };
El.prototype.replaceChildren = function () { this.children = []; };
El.prototype.remove = function () {};
El.prototype.addEventListener = function () {};
El.prototype.removeEventListener = function () {};
El.prototype.setAttribute = function (k, v) { this._attr[k] = String(v); };
El.prototype.getAttribute = function (k) { return (k in this._attr) ? this._attr[k] : null; };
El.prototype.hasAttribute = function (k) { return k in this._attr; };
El.prototype.removeAttribute = function (k) { delete this._attr[k]; };
El.prototype.querySelector = function () { return null; };
El.prototype.querySelectorAll = function () { return []; };
El.prototype.getContext = function () { return null; };
El.prototype.focus = function () {}; El.prototype.click = function () {};
El.prototype.contains = function () { return false; };

const doc = {
  readyState: "complete", hidden: false, visibilityState: "visible", title: "", activeElement: null,
  getElementById() { return new El(); },
  querySelector() { return null; }, querySelectorAll() { return []; },
  createElement(t) { return new El(t); },
  createElementNS(ns, t) { return new El(t); },
  createTextNode(t) { var n = new El("#text"); n.textContent = String(t); return n; },
  addEventListener() {}, removeEventListener() {},
};
doc.body = new El("body"); doc.documentElement = new El("html"); doc.head = new El("head");

const win = {
  PW_VIEWS: {}, PW_UI: { planMode: "all" },
  PW_BUS: { setNavigator() {}, focusNode() {}, clearFocus() {}, getFocus() { return null; },
    onFocus() { return function () {}; }, goto() {} },
  addEventListener() {}, removeEventListener() {},
  matchMedia() { return { matches: false, addEventListener() {}, addListener() {} }; },
  requestAnimationFrame() { return 0; },
  location: { hash: "", href: "http://x/", reload() {} },
  localStorage: { _d: {}, getItem(k) { return (k in this._d) ? this._d[k] : null; },
    setItem(k, v) { this._d[k] = String(v); }, removeItem(k) { delete this._d[k]; } },
  console: console,
};
// doctor.js is the one view that fetches its own data (/doctor.json) instead of rendering
// from the passed state; stub fetch so its render()+paint() path is exercisable here.
win.fetch = function () {
  return Promise.resolve({ ok: true, json: function () {
    return Promise.resolve({ total: 5, warn: 1, fail: 0, checks: [
      { name: "git", status: "ok", detail: "2.40" },
      { name: "rg", status: "warn", detail: "not found", degrades: "slower Stage 1 scan" },
    ] });
  } });
};
global.window = win; global.document = doc; global.location = win.location; global.fetch = win.fetch;

// Load the real derive engine + the vendored coupling renderer (PW_GRAPH, which the graph
// view drives on a full snapshot), then each view (each registers window.PW_VIEWS.<name>).
vm.runInThisContext(fs.readFileSync(BASE + "/vendor/derive.js", "utf8"));
vm.runInThisContext(fs.readFileSync(BASE + "/vendor/graph.js", "utf8"));
const VIEWS = ["console", "plan", "commands", "insights", "timeline", "graph"];
VIEWS.forEach(function (v) {
  vm.runInThisContext(fs.readFileSync(BASE + "/views/" + v + ".js", "utf8"));
  assert(typeof win.PW_VIEWS[v] === "function", "view " + v + " did not register render()");
});

const graphText = JSON.stringify({
  graph_built_at_sha: "deadbeef",
  frontier: { never_audited: 3, stale: 5 },
  nodes: {
    "hot.py": { git_churn: 10, pagerank: 0.9, covered_by_test: false, is_test: false, lang: "python", loc: 100, branch_count: 5, is_articulation: true, imports: ["cold.py"] },
    "cold.py": { git_churn: 1, pagerank: 0.1, covered_by_test: true, is_test: false, lang: "python", loc: 10, branch_count: 1, is_articulation: false, imports: [] },
  },
  coupling_edges: [{ a: "hot.py", b: "cold.py", weight: 2, cooccur: 2 }],
  clusters: [{ label: "core", members: ["hot.py", "cold.py"] }],
  import_cycles: [],
});
const metrics = win.PW_DERIVE.metrics(graphText);
assert(metrics, "metrics built from the fixture graph");

const state = {
  schema_version: 1, root: "/x", head: "deadbeef", converged: false,
  counts: { pending: 2, completed: 1, rejected: 1 },
  pending_modes: { develop: 1, repair: 1 },
  pending: [
    { title: "do a thing", mode: "develop", rationale: "r", evidence: "e", surfaces: ["a.py"], new_surfaces: [], development: "d", acceptance: "ok", verification: "bash tests/run.sh" },
    { title: "fix a bug", mode: "repair", rationale: "r", evidence: "e", surfaces: ["b.py"], new_surfaces: [], development: "d", acceptance: "ok", verification: "bash tests/run.sh" },
  ],
  completed: [{ title: "shipped", mode: "develop" }],
  rejected: [{ title: "bad idea", reason: "value-gate: no consumer" }],
  final_point: { sha: "deadbeef", date: "", deepest_tier: "", valid: true, stale: false, scope: null },
  graph: { built_sha: "deadbeef", node_count: 2, dirty: 0, stale: false },
};
const fullCtx = { graphText: graphText, metrics: metrics, builtSha: "deadbeef", stale: false, head: "deadbeef" };
const bareCtx = { graphText: null, metrics: null, builtSha: "", stale: false, head: "deadbeef" };

VIEWS.forEach(function (v) {
  var c1 = new El("section");
  win.PW_VIEWS[v](c1, state, fullCtx);
  assert(c1.children.length > 0, "view " + v + " rendered nothing on a full snapshot");
  var c2 = new El("section");
  win.PW_VIEWS[v](c2, state, bareCtx);   // degraded: no graph/metrics must not throw
});

// Targeted: the Console audit-frontier vital appears ONLY when the snapshot carries a
// frontier (the fullCtx fixture has frontier:{never_audited:3,stale:5}); a pre-frontier
// (null) graph must render the vitals strip unchanged (no frontier card).
function textOf(node) {
  var t = node.textContent || "";
  (node.children || []).forEach(function (c) { t += " " + textOf(c); });
  return t;
}
var fc = new El("section");
win.PW_VIEWS.console(fc, state, fullCtx);
assert(/never-audited/.test(textOf(fc)), "Console omitted the audit-frontier vital on a frontier-bearing snapshot");
var graphless = JSON.stringify({ graph_built_at_sha: "deadbeef", nodes: { "a.py": { git_churn: 1, pagerank: 0.5, covered_by_test: true, is_test: false, lang: "python", loc: 5, branch_count: 1, imports: [] } } });
var mNoFr = win.PW_DERIVE.metrics(graphless);
assert(mNoFr && mNoFr.frontier === null, "fixture sanity: a frontier-less graph yields null frontier");
var nf = new El("section");
win.PW_VIEWS.console(nf, state, { graphText: graphless, metrics: mNoFr, builtSha: "deadbeef", stale: false, head: "deadbeef" });
assert(!/never-audited/.test(textOf(nf)), "Console rendered a frontier vital on a pre-frontier (null) graph");

// Targeted: the carried satellite appears ONLY when counts.carried is non-zero; the base
// fixture (no carried field — an older snapshot) must render the satellites unchanged.
assert(!/carried/.test(textOf(fc)), "Console rendered a carried satellite without counts.carried");
var carriedState = Object.assign({}, state, {
  counts: Object.assign({}, state.counts, { carried: 2 }),
});
var cs = new El("section");
win.PW_VIEWS.console(cs, carriedState, fullCtx);
assert(/carried/.test(textOf(cs)), "Console omitted the carried satellite on counts.carried=2");

// doctor view: fetch-based (not state-driven), so it sits outside the VIEWS render loop —
// load its file here (registers PW_VIEWS.doctor) and cover it explicitly: render() must show
// the sync placeholder immediately, and once the stubbed /doctor.json promise flushes,
// paint() must render the preflight rows (a renamed doctor.json field would break this).
vm.runInThisContext(fs.readFileSync(BASE + "/views/doctor.js", "utf8"));
assert(typeof win.PW_VIEWS.doctor === "function", "view doctor did not register render()");
var docC = new El("section");
win.PW_VIEWS.doctor(docC, state, fullCtx);
assert(textOf(docC).length > 0, "doctor render() produced no DOM synchronously");
setTimeout(function () {
  assert(/Environment preflight/.test(textOf(docC)),
    "doctor paint() did not render the preflight after /doctor.json resolved");
  console.log("VIEWS-FN-OK");
}, 0);
JS
  if node "$TMP/views_fn_test.js" "$ROOT/scripts/dashboard" >"$TMP/views_fn.out" 2>"$TMP/views_fn.err" \
     && grep -q VIEWS-FN-OK "$TMP/views_fn.out"; then
    ok "dashboard render() runs for all seven views (incl. doctor/graph/timeline) on full + graph-less snapshots (no throw, non-empty DOM)"
  else
    bad "a dashboard view render() failed: $(cat "$TMP/views_fn.err" 2>/dev/null)"
  fi
else
  ok "dashboard view render() check skipped (node not installed)"
fi
