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

# --- Test DASH-XDG-ISO: the suite-wide registry isolation survives the prior case ----------
# This case runs right after `registry`, which overrides XDG_CONFIG_HOME for its own assertions.
# If that case tears down by *unsetting* XDG_CONFIG_HOME instead of restoring the suite default
# (lib.sh points it at $TMP/xdg), every dashboard test that stamps a beacon — state.py's
# _register_project upserts the running root — would leak a temp fixture path into the
# developer's real ~/.config/planwright/projects.json. Pin the invariant at the seam.
case "${XDG_CONFIG_HOME:-}" in
  "$TMP"/*) ok "ambient XDG_CONFIG_HOME is still under TMP after the registry case (no real-registry leak)" ;;
  *) bad "XDG_CONFIG_HOME ('${XDG_CONFIG_HOME:-}') escaped TMP before dashboard — a prior case leaked isolation" ;;
esac

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
        etag = r.headers.get("ETag")
        data = json.load(r)
    assert data["schema_version"] == 1, data
    assert data["counts"]["pending"] == 1, data["counts"]
    assert data["pending"][0]["title"] == "one", data["pending"]

    # /state.json carries a strong validator, and a follow-up GET with If-None-Match set to it
    # returns 304 Not Modified (snapshot unchanged) without a rebuilt body — so a polling client
    # stops re-parsing plan.md + completed.md on every request. (urllib raises HTTPError for 304.)
    assert etag, "ETag header missing from /state.json"
    cond = urllib.request.Request(base + "/state.json", headers={"If-None-Match": etag})
    try:
        urllib.request.urlopen(cond, timeout=5)
        not_modified = False
    except urllib.error.HTTPError as e:
        not_modified = e.code == 304
        assert e.headers.get("ETag") == etag, e.headers.get("ETag")
    assert not_modified, "conditional GET with matching If-None-Match did not return 304"

    # ETag invalidation — the load-bearing half of the conditional-GET contract. After any
    # .planwright/ input changes, the validator MUST change so a polling client still holding
    # the OLD ETag is rebuilt (200 + a NEW, different ETag), never wrongly told 304 and frozen
    # on a stale snapshot. The block above only proved match->304; a validator frozen to a
    # constant would pass that yet silently starve every client of updates. (_mtime_signature
    # keys on (name, mtime_ns, size), so appending to plan.md flips it deterministically.)
    with open(os.path.join(root, ".planwright", "plan.md"), "a") as fh:
        fh.write("\n")
    stale = urllib.request.Request(base + "/state.json", headers={"If-None-Match": etag})
    with urllib.request.urlopen(stale, timeout=5) as r:
        assert r.status == 200, "stale If-None-Match was not rebuilt (status %s)" % r.status
        new_etag = r.headers.get("ETag")
        json.load(r)                          # body must rebuild, not 304-skip
    assert new_etag and new_etag != etag, \
        "ETag did not change after .planwright/ mutation: %r -> %r" % (etag, new_etag)
    # the refreshed validator is itself stable: a conditional GET carrying it now 304s
    cond_new = urllib.request.Request(base + "/state.json", headers={"If-None-Match": new_etag})
    try:
        urllib.request.urlopen(cond_new, timeout=5); re304 = False
    except urllib.error.HTTPError as e:
        re304 = e.code == 304
    assert re304, "refreshed ETag did not 304 on a matching conditional GET"
    print("ETAG-INVALIDATE-OK")

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

    # Extended containment: each variant must be refused (404), and the in-root symlink
    # escape must be refused BY THE CONTAINMENT GUARD (realpath), not merely not-found.
    def refused(p):
        try:
            urllib.request.urlopen(base + p, timeout=5)
            return False
        except urllib.error.HTTPError as e:
            return e.code == 404
        except Exception:
            return True
    # encoded-dot traversal: the resolver must NOT unquote %2e%2e into '..'
    assert refused("/%2e%2e/%2e%2e/etc/passwd"), "encoded traversal was not refused"
    # absolute path: an absolute URL path must stay contained under the static root
    assert refused("/etc/passwd"), "absolute path was not refused"
    # in-root symlink escape — the realpath containment guard (not the not-found branch).
    # Exercised directly against _resolve_static with STATIC_ROOT pointed at a temp dir
    # holding a symlink that escapes the root, so the repo's real scripts/dashboard/ is
    # never mutated. A normpath-only guard would wrongly resolve link/passwd and serve it.
    import importlib, tempfile
    sys.path.insert(0, os.path.dirname(os.path.abspath(dash)))
    _dash_mod = importlib.import_module("dashboard")
    _saved_root = _dash_mod.STATIC_ROOT
    _td = tempfile.mkdtemp()
    _fake = os.path.join(_td, "static"); os.makedirs(_fake)
    open(os.path.join(_fake, "index.html"), "w").write("ok")
    os.symlink("/etc", os.path.join(_fake, "link"))   # in-root symlink escaping the root
    try:
        _dash_mod.STATIC_ROOT = _fake
        assert _dash_mod._resolve_static("/link/passwd") is None, \
            "in-root symlink escape was not refused by the containment guard"
        assert _dash_mod._resolve_static("/index.html") is not None, \
            "legitimate in-root file was wrongly refused"
    finally:
        _dash_mod.STATIC_ROOT = _saved_root
    print("CONTAINMENT-OK")

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

    # No mutating handler: the dashboard is read-only by construction (only do_GET is
    # defined). A POST/PUT/DELETE must be refused by the stdlib handler (501 Unsupported
    # method), never served — a future do_POST that mutated the repo would make this 2xx
    # and fail here.
    for _meth in ("POST", "PUT", "DELETE"):
        _req = urllib.request.Request(base + "/state.json", data=b"", method=_meth)
        _code = None
        try:
            _code = urllib.request.urlopen(_req, timeout=5).status
            _mutating_refused = False
        except urllib.error.HTTPError as e:
            _mutating_refused = e.code not in (200, 201, 202, 204)
        assert _mutating_refused, "%s was served (a mutating handler exists): %r" % (_meth, _code)
    print("NO-MUTATE-OK")

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

    # /style.css must serve as text/css (not the octet-stream fallback): an unstyled UI would
    # otherwise ship green, since the .js and woff2 content types are asserted but the stylesheet's
    # was not. get_content_type() drops the charset param, so compare the bare media type.
    with urllib.request.urlopen(base + "/style.css", timeout=5) as r:
        sct = r.headers.get_content_type()
        sbody = r.read()
    assert sct == "text/css", "style.css content-type: " + sct
    assert len(sbody) > 0, "style.css served empty"
    print("STYLE-CSS-OK")

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

    # /recommend.json — the dispatcher decision record the Commands front-door panel
    # consumes (status.recommend, read-only). The fixture has exactly 1 pending item,
    # so the drain-first overlay row makes the dispatch deterministic (execute,
    # mutating); blockers/doctor content varies by machine, so pin only its shape.
    with urllib.request.urlopen(base + "/recommend.json", timeout=10) as r:
        assert r.headers.get_content_type() == "application/json", r.headers.get_content_type()
        assert r.headers.get("Cache-Control") == "no-store", r.headers.get("Cache-Control")
        rec = json.load(r)
    assert rec.get("command") == "execute", rec
    assert rec.get("mutating") is True, rec
    assert isinstance(rec.get("why"), str) and rec["why"], rec
    assert isinstance(rec.get("base"), dict) and rec["base"].get("key"), rec
    assert isinstance(rec.get("blockers"), list), rec
    assert isinstance(rec.get("evidence"), list) and rec["evidence"], rec
    print("RECOMMEND-JSON-OK")

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
PW_TEST_VIEWS="console commands plan timeline graph insights shards doctor fleet" \
  python3 "$TMP/dash_client.py" "$DFX" "$DASH" >"$TMP/dash.out" 2>"$TMP/dash.err" || true
if grep -q DASH-OK "$TMP/dash.out"; then
  ok "dashboard.py serves /state.json (JSON) + /events (text/event-stream), refuses traversal + foreign Host"
else
  bad "dashboard.py endpoint check failed: $(cat "$TMP/dash.err" 2>/dev/null)"
fi
if grep -q ETAG-INVALIDATE-OK "$TMP/dash.out"; then
  ok "dashboard.py /state.json invalidates its ETag on a .planwright/ change (stale If-None-Match -> 200 + new validator)"
else
  bad "dashboard.py ETag invalidation check failed: $(cat "$TMP/dash.err" 2>/dev/null)"
fi
if grep -q NOHOST-OK "$TMP/dash.out"; then
  ok "dashboard.py allows a no-Host (HTTP/1.0) request — the deliberate DNS-rebinding pass-through"
else
  bad "dashboard.py absent-Host pass-through check failed: $(cat "$TMP/dash.err" 2>/dev/null)"
fi
if grep -q NO-MUTATE-OK "$TMP/dash.out"; then
  ok "dashboard.py serves no mutating method (POST/PUT/DELETE refused 501 — read-only by construction)"
else
  bad "dashboard.py served a non-GET method (a mutating handler exists): $(cat "$TMP/dash.err" 2>/dev/null)"
fi
# Loopback-only bind + sole-handler pin: the server binds 127.0.0.1 (never a routable
# interface) and defines exactly one do_GET handler. grep-able guards so a non-loopback bind
# or an added mutating do_* handler turns red.
if grep -qF 'ThreadingHTTPServer(("127.0.0.1", port), Handler)' "$DASH" \
   && [ "$(grep -cE '^[[:space:]]+def do_[A-Z]' "$DASH")" = "1" ] \
   && grep -qE '^[[:space:]]+def do_GET\(self\):' "$DASH"; then
  ok "dashboard.py binds 127.0.0.1 only and exposes a single do_GET handler (loopback + read-only)"
else
  bad "dashboard.py bind site changed off 127.0.0.1 or gained a non-GET do_* handler"
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
if grep -q CONTAINMENT-OK "$TMP/dash.out"; then
  ok "dashboard.py refuses encoded + absolute + in-root-symlink static-root escapes (404 / guard)"
else
  bad "dashboard.py extended containment check failed: $(cat "$TMP/dash.err" 2>/dev/null)"
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
if grep -q STYLE-CSS-OK "$TMP/dash.out"; then
  ok "dashboard.py serves /style.css as text/css (not the octet-stream fallback)"
else
  bad "dashboard.py did not serve /style.css as text/css: $(cat "$TMP/dash.err" 2>/dev/null)"
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
# The codmaster front-door card: present in the catalog (ORDER + COMMANDS entry) but never
# coach-recommended — it dispatches the coach's own picks, so the table recommending it
# would be circular. Same grep-able-guard posture as the COACH.reset pin above.
if grep -q '"codmaster", "codvisor"' "$ROOT/scripts/dashboard/views/commands.js" \
   && grep -q 'cmd: "/planwright:codmaster"' "$ROOT/scripts/dashboard/views/commands.js" \
   && grep -q 'Never coach-recommended — it dispatches the' "$ROOT/scripts/dashboard/views/commands.js"; then
  ok "Commands view carries the codmaster front-door card (first in ORDER, never coach-recommended)"
else
  bad "Commands view lost the codmaster front-door card or its never-coach-recommended note"
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
if grep -q RECOMMEND-JSON-OK "$TMP/dash.out"; then
  ok "dashboard.py /recommend.json serves the dispatcher decision record (drain-first dispatch on a pending fixture)"
else
  bad "dashboard.py /recommend.json failed: $(cat "$TMP/dash.err" 2>/dev/null)"
fi
if grep -q VIEW-shards-OK "$TMP/dash.out"; then
  ok "dashboard serves the Shards view (views/shards.js registers PW_VIEWS.shards)"
else
  bad "dashboard Shards view check failed: $(cat "$TMP/dash.err" 2>/dev/null)"
fi
if grep -q VIEW-fleet-OK "$TMP/dash.out"; then
  ok "dashboard serves the Fleet view (views/fleet.js registers PW_VIEWS.fleet, referenced by the shell)"
else
  bad "dashboard Fleet view check failed: $(cat "$TMP/dash.err" 2>/dev/null)"
fi
# The Commands view's codmaster front-door panel must consume /recommend.json and gate the
# paint on the recUsable shape guard (an error body / older server degrades to an absent
# panel, never an error state). Same grep-able-guard posture as the COACH.reset pin.
if grep -q 'fetch("/recommend.json")' "$ROOT/scripts/dashboard/views/commands.js"; then
  ok "Commands view wires the codmaster front-door panel (/recommend.json fetch)"
else
  bad "Commands view lost the front-door panel wiring (/recommend.json fetch)"
fi

# --- Test DASH-VIEW-INVENTORY: the dashboard view inventory cannot drift across its 4 lists ----
# A view is "wired" only when it exists in FOUR places at once: the on-disk views/*.js file, the
# app.js VIEWS array (the canonical nav/render inventory), an index.html <script src> tag, and the
# doctor.py BUNDLED install-completeness list. doctor.sh only guards index.html-assets ⊆ BUNDLED; it
# never reads the on-disk glob or app.js VIEWS, so a half-wired view (file present but absent from
# VIEWS = dead file; or a VIEWS entry with no file = "view not loaded" at runtime) drifts silently.
# Derive all four sets from the tree and assert they are equal, and that every app.js VIEWS key
# matches its view-<key> container id, so any added/removed/renamed view not wired in all four turns red.
if python3 - "$ROOT" >/dev/null 2>"$TMP/view_inv.err" <<'PY'
import os, re, sys
root = sys.argv[1]
d = os.path.join(root, "scripts", "dashboard")
on_disk = {f for f in os.listdir(os.path.join(d, "views")) if f.endswith(".js")}
app = open(os.path.join(d, "app.js"), encoding="utf-8").read()
pairs = re.findall(r'\{ key: "([a-z]+)", container: "view-([a-z]+)" \}', app)
app_js = {k + ".js" for k, _ in pairs}
container_bad = sorted((k, c) for k, c in pairs if k != c)
idx = open(os.path.join(d, "index.html"), encoding="utf-8").read()
idx_js = {m + ".js" for m in re.findall(r'src="/views/([a-z]+)\.js"', idx)}
doc = open(os.path.join(root, "scripts", "doctor.py"), encoding="utf-8").read()
bundled_js = {m + ".js" for m in re.findall(r'dashboard/views/([a-z]+)\.js', doc)}
assert on_disk, "no on-disk views/*.js found"
assert not container_bad, "app.js VIEWS key != container id: %s" % container_bad
assert on_disk == app_js, "on-disk views != app.js VIEWS: only-disk=%s only-app=%s" % (sorted(on_disk - app_js), sorted(app_js - on_disk))
assert on_disk == idx_js, "on-disk views != index.html <script src>: only-disk=%s only-idx=%s" % (sorted(on_disk - idx_js), sorted(idx_js - on_disk))
assert on_disk == bundled_js, "on-disk views != doctor BUNDLED: only-disk=%s only-bundled=%s" % (sorted(on_disk - bundled_js), sorted(bundled_js - on_disk))
PY
then
  ok "dashboard view inventory is consistent across on-disk views/*.js, app.js VIEWS, index.html script tags, and doctor BUNDLED (no half-wired view)"
else
  bad "dashboard view inventory drifted: $(cat "$TMP/view_inv.err" 2>/dev/null)"
fi

# --- Test DASH-CMD-UNIT: commands.js recUsable / dispatchInvocation pure-function units ----
# Replaces the `function recUsable` source grep above. The front-door render path only covers
# recUsable's all-present/all-absent extremes and dispatchInvocation's codshard branch, so the
# individual recUsable conditions (command:string, base, blockers:array) and dispatchInvocation's
# HELPERS/default branches were ungated. Exercise both pure helpers directly on valid + malformed
# payloads (exposed on the view function), so a dropped condition or dispatch branch fails CI.
if command -v node >/dev/null 2>&1; then
  cat > "$TMP/cmd_unit_test.js" <<'JS'
const assert = require("assert");
const BASE = process.argv[2];
const VM = require(BASE + "/../../tests/cases/lib/dashboard-vm.js");
const { makeDoc, makeWin, install, loadCommon, loadView } = VM;
const doc = makeDoc(); const win = makeWin(doc); install(win, doc);
loadCommon(BASE);            // derive.js (PW_DERIVE.coach) + graph.js + ui.js commands.js needs
loadView(BASE, "commands");
const cmd = win.PW_VIEWS.commands;
assert(typeof cmd.recUsable === "function" && typeof cmd.dispatchInvocation === "function",
  "commands.js did not expose recUsable/dispatchInvocation for unit testing");
// recUsable: a usable record needs command:string + base + blockers:array — each condition gates.
assert(cmd.recUsable({ command: "codshard", base: { key: "x" }, blockers: [] }) === true,
  "recUsable rejected a well-formed record");
assert(cmd.recUsable(null) === false, "recUsable accepted null");
assert(cmd.recUsable({ total: 1, checks: [] }) === false, "recUsable accepted a doctor-shaped body");
assert(cmd.recUsable({ command: 0, base: { key: "x" }, blockers: [] }) === false,
  "recUsable accepted a non-string command");
assert(cmd.recUsable({ command: "x", blockers: [] }) === false, "recUsable accepted a record with no base");
assert(cmd.recUsable({ command: "x", base: { key: "x" } }) === false, "recUsable accepted a record with no blockers");
assert(cmd.recUsable({ command: "x", base: { key: "x" }, blockers: "nope" }) === false,
  "recUsable accepted a non-array blockers");
// dispatchInvocation: codshard maps to its helper (+ explore arg only), a known helper maps to
// itself, and any other command falls back to the bare planwright invocation with its args.
assert(cmd.dispatchInvocation({ command: "codshard", args: "explore" }) === "/planwright:codshard explore",
  "dispatchInvocation lost the codshard+explore mapping");
assert(cmd.dispatchInvocation({ command: "codshard", args: "" }) === "/planwright:codshard",
  "dispatchInvocation added a stray arg to a bare codshard dispatch");
assert(cmd.dispatchInvocation({ command: "codvisor", args: "" }) === "/planwright:codvisor",
  "dispatchInvocation lost the HELPERS-table mapping for a known helper command");
assert(cmd.dispatchInvocation({ command: "execute", args: "execute" }) === "/planwright:planwright execute",
  "dispatchInvocation default branch did not map to the bare planwright invocation");
console.log("CMD-UNIT-OK");
JS
  if node "$TMP/cmd_unit_test.js" "$ROOT/scripts/dashboard" >"$TMP/cmd_unit.out" 2>"$TMP/cmd_unit.err" \
     && grep -q CMD-UNIT-OK "$TMP/cmd_unit.out"; then
    ok "commands.js recUsable/dispatchInvocation pure functions assert valid + malformed payloads"
  else
    bad "commands.js recUsable/dispatchInvocation unit assertion failed: $(cat "$TMP/cmd_unit.err" 2>/dev/null)"
  fi
else
  ok "commands.js recUsable/dispatchInvocation unit check skipped (node not installed)"
fi

# --- Test DASH-CMD-DEGRADE: the front door degrades on a failed/null /recommend.json fetch ----
# loadFrontDoor maps a non-ok response to null and swallows a rejected fetch (.catch), so a 404 /
# older server / network error must paint NO panel and never throw. The DASH-VIEWS-FN flow only
# covers a wrong-SHAPED 200 body; this covers the transport-failure path (ok:false and reject).
if command -v node >/dev/null 2>&1; then
  cat > "$TMP/cmd_degrade_test.js" <<'JS'
const assert = require("assert");
const BASE = process.argv[2];
const VM = require(BASE + "/../../tests/cases/lib/dashboard-vm.js");
const { El, makeDoc, makeWin, install, loadCommon, loadView, makeFixture, frontDoorPanels } = VM;
const doc = makeDoc(); const win = makeWin(doc);
// /recommend.json fails: first as a non-ok response (must never be json-parsed), then as a
// rejected promise. The doctor stub stays ok so unrelated views do not error.
let mode = "notok";
win.fetch = function (url) {
  if (url === "/recommend.json") {
    if (mode === "reject") return Promise.reject(new Error("network down"));
    return Promise.resolve({ ok: false, json: function () { throw new Error("must not parse a non-ok body"); } });
  }
  return Promise.resolve({ ok: true, json: function () { return Promise.resolve({ total: 0, checks: [] }); } });
};
install(win, doc);
loadCommon(BASE);
loadView(BASE, "commands");
const fx = makeFixture();
var c1 = new El("section");
win.PW_VIEWS.commands(c1, fx.state, fx.fullCtx);   // triggers a non-ok fetch
mode = "reject";
var c2 = new El("section");
win.PW_VIEWS.commands(c2, fx.state, fx.fullCtx);   // triggers a rejected fetch
setTimeout(function () {
  setTimeout(function () {
    var c3 = new El("section");
    win.PW_VIEWS.commands(c3, fx.state, fx.fullCtx);
    assert(frontDoorPanels(c1).length === 0 && frontDoorPanels(c3).length === 0,
      "a failed/null /recommend.json fetch painted a front-door panel");
    console.log("CMD-DEGRADE-OK");
  }, 0);
}, 0);
JS
  if node "$TMP/cmd_degrade_test.js" "$ROOT/scripts/dashboard" >"$TMP/cmd_degrade.out" 2>"$TMP/cmd_degrade.err" \
     && grep -q CMD-DEGRADE-OK "$TMP/cmd_degrade.out"; then
    ok "commands.js front door degrades on a failed/null /recommend.json fetch (no panel, no throw)"
  else
    bad "commands.js front-door degrade assertion failed: $(cat "$TMP/cmd_degrade.err" 2>/dev/null)"
  fi
else
  ok "commands.js front-door degrade check skipped (node not installed)"
fi

# --- Test DASH-CMD-FRONTDOOR: the front-door panel renders the args-differ and follow-up rows ----
# A successful /recommend.json paints the front door. The args-differ row (pw-frontdoor-args) shows
# ONLY when d.args !== d.command; the follow-up row ("then: <cmd>") shows ONLY when d.follow_up.command
# is set. A record lacking those fields renders neither. (Fetch is async, so flush two macrotasks.)
if command -v node >/dev/null 2>&1; then
  cat > "$TMP/cmd_frontdoor_test.js" <<'JS'
const assert = require("assert");
const BASE = process.argv[2];
const VM = require(BASE + "/../../tests/cases/lib/dashboard-vm.js");
const { El, makeDoc, makeWin, install, loadCommon, loadView, makeFixture, frontDoorPanels, findByClass, textOf } = VM;
const doc = makeDoc(); const win = makeWin(doc);
var rec = { command: "codvisor", args: "cycle 10 depth 10 explore", base: { key: "codvisor" }, mutating: true, blockers: [], evidence: [], notes: [], follow_up: { command: "codshard", args: "explore" } };
win.fetch = function (url) {
  if (url === "/recommend.json") return Promise.resolve({ ok: true, json: function () { return Promise.resolve(rec); } });
  return Promise.resolve({ ok: true, json: function () { return Promise.resolve({ total: 0, checks: [] }); } });
};
install(win, doc);
loadCommon(BASE);
loadView(BASE, "commands");
const fx = makeFixture();
function flush(cb) { setTimeout(function () { setTimeout(cb, 0); }, 0); }
// paintFrontDoor re-paints from the cached recData (sync) then the fetched record (async); the shim
// never clears children, so panels accumulate — the CURRENT record is always the LAST painted panel.
function lastFD(c) { var ps = frontDoorPanels(c); return ps[ps.length - 1]; }
var cA = new El("section");
win.PW_VIEWS.commands(cA, fx.state, fx.fullCtx);   // record WITH differing args + follow_up
flush(function () {
  var pA = lastFD(cA);
  assert(pA, "front door did not paint on a valid /recommend.json");
  assert(findByClass(pA, "pw-frontdoor-args").length === 1, "args-differ row missing when args !== command");
  assert(/then: codshard explore/.test(textOf(pA)), "follow-up row missing when follow_up.command present");
  rec = { command: "execute", args: "execute", base: { key: "execute" }, mutating: true, blockers: [], evidence: [], notes: [] };
  var cB = new El("section");
  win.PW_VIEWS.commands(cB, fx.state, fx.fullCtx);   // args === command, no follow_up
  flush(function () {
    var pB = lastFD(cB);
    assert(pB, "front door did not paint on the second record");
    assert(findByClass(pB, "pw-frontdoor-args").length === 0, "args-differ row rendered when args === command");
    assert(!/then: /.test(textOf(pB)), "follow-up row rendered when follow_up absent");
    console.log("CMD-FRONTDOOR-OK");
  });
});
JS
  if node "$TMP/cmd_frontdoor_test.js" "$ROOT/scripts/dashboard" >"$TMP/cmd_frontdoor.out" 2>"$TMP/cmd_frontdoor.err" \
     && grep -q CMD-FRONTDOOR-OK "$TMP/cmd_frontdoor.out"; then
    ok "commands.js front-door renders the args-differ row (args!==command) and follow-up row (follow_up.command), each absent otherwise"
  else
    bad "commands.js front-door args-differ/follow-up assertion failed: $(cat "$TMP/cmd_frontdoor.err" 2>/dev/null)"
  fi
else
  ok "commands.js front-door args-differ/follow-up check skipped (node not installed)"
fi

# --- Test DASH-CMD-PULSE: the live pulse chips warn-class non-zero graph signals; omit coverage at null
# render() builds the pulse chips from COACH.signals: under hasGraph the cycles/hotspots chips carry the
# warn class ONLY when non-zero, and the "% covered" chip is omitted when coveragePct is null (no graph).
# Synchronous — the pulse is built before the async front-door fetch, so no flush is needed.
if command -v node >/dev/null 2>&1; then
  cat > "$TMP/cmd_pulse_test.js" <<'JS'
const assert = require("assert");
const BASE = process.argv[2];
const VM = require(BASE + "/../../tests/cases/lib/dashboard-vm.js");
const { El, makeDoc, makeWin, install, loadCommon, loadView, makeFixture, findByClass, classOf, textOf } = VM;
const doc = makeDoc(); const win = makeWin(doc);
win.fetch = function () { return Promise.resolve({ ok: true, json: function () { return Promise.resolve({ total: 0, checks: [] }); } }); };
install(win, doc);
loadCommon(BASE);
loadView(BASE, "commands");
const fx = makeFixture();
var cycGraph = JSON.stringify({ graph_built_at_sha: "deadbeef", import_cycles: [["a.py", "b.py"]],
  nodes: {
    "a.py": { imports: ["b.py"], branch_count: 1, pagerank: 0.9, covered_by_test: false, is_test: false, lang: "python", loc: 50, git_churn: 9, is_articulation: true },
    "b.py": { imports: ["a.py"], branch_count: 1, pagerank: 0.8, covered_by_test: false, is_test: false, lang: "python", loc: 40, git_churn: 8, is_articulation: false },
  } });
var mCyc = win.PW_DERIVE.metrics(cycGraph);
var pcA = new El("section");
win.PW_VIEWS.commands(pcA, fx.state, { graphText: cycGraph, metrics: mCyc, builtSha: "deadbeef", stale: false, head: "deadbeef" });
var warnText = findByClass(pcA, "pw-coach-pulse-chip").filter(function (c) { return classOf(c).indexOf("warn") >= 0; }).map(textOf).join(" | ");
assert(/cycles/.test(warnText), "cycles pulse chip not warn-classed on cycles>0 (got: " + warnText + ")");
assert(/hotspots/.test(warnText), "untested-hotspots pulse chip not warn-classed on hotUncovered>0 (got: " + warnText + ")");
var pcB = new El("section");
win.PW_VIEWS.commands(pcB, fx.state, fx.bareCtx);   // no metrics -> hasGraph false -> no graph chips
assert(!/% covered/.test(textOf(pcB)), "coverage pulse chip rendered when coveragePct == null (no graph)");
console.log("CMD-PULSE-OK");
JS
  if node "$TMP/cmd_pulse_test.js" "$ROOT/scripts/dashboard" >"$TMP/cmd_pulse.out" 2>"$TMP/cmd_pulse.err" \
     && grep -q CMD-PULSE-OK "$TMP/cmd_pulse.out"; then
    ok "commands.js pulse chips warn-class non-zero graph signals (cycles/hotspots) and omit the coverage chip when coveragePct is null"
  else
    bad "commands.js pulse-chip assertion failed: $(cat "$TMP/cmd_pulse.err" 2>/dev/null)"
  fi
else
  ok "commands.js pulse-chip check skipped (node not installed)"
fi

# --- Test DASH-CMD-HERO: the base coach hero pick + evidence (browser coach, no /recommend.json) --
# render()'s hero is computed from the BROWSER coach (PW_DERIVE.coach.signals -> recommend ->
# evidence), independent of the optional server /recommend.json overlay. DASH-CMD-PULSE pins the
# pulse chips but never the recommendation; this asserts the pw-coach-pick equals the independently
# computed COACH.recommend(signals).key and that the pw-coach-evidence chips render, so a broken
# signals->recommend->evidence wiring (e.g. picking the wrong command) fails.
if command -v node >/dev/null 2>&1; then
  cat > "$TMP/cmd_hero_test.js" <<'JS'
const assert = require("assert");
const BASE = process.argv[2];
const VM = require(BASE + "/../../tests/cases/lib/dashboard-vm.js");
const { El, makeDoc, makeWin, install, loadCommon, loadView, makeFixture, findByClass, textOf } = VM;
const doc = makeDoc(); const win = makeWin(doc);
win.fetch = function () { return Promise.reject(new Error("no recommend endpoint")); };  // no overlay -> base hero is THE surface
install(win, doc);
loadCommon(BASE);
loadView(BASE, "commands");
const fx = makeFixture();
// A cyclic, uncovered graph -> the coach routes to debt (codvisor). Compute the expected
// recommendation independently from the same browser coach the view uses, so the assertion
// tracks the truth table rather than hardcoding a key.
var g = JSON.stringify({ graph_built_at_sha: "deadbeef", import_cycles: [["a.py", "b.py"]],
  nodes: {
    "a.py": { imports: ["b.py"], branch_count: 1, pagerank: 0.9, covered_by_test: false, is_test: false, lang: "python", loc: 50, git_churn: 9, is_articulation: true },
    "b.py": { imports: ["a.py"], branch_count: 1, pagerank: 0.8, covered_by_test: false, is_test: false, lang: "python", loc: 40, git_churn: 8, is_articulation: false },
  } });
var m = win.PW_DERIVE.metrics(g);
var COACH = win.PW_DERIVE.coach;
var rec = COACH.recommend(COACH.signals(fx.state, m));
var heroRoot = new El("section");
win.PW_VIEWS.commands(heroRoot, fx.state, { graphText: g, metrics: m, builtSha: "deadbeef", stale: false, head: "deadbeef" });
var pick = findByClass(heroRoot, "pw-coach-pick").map(textOf).join("").trim();
assert(pick.length > 0, "base coach hero rendered no pw-coach-pick");
assert(new RegExp(rec.key).test(pick),
  "pw-coach-pick '" + pick + "' does not match COACH.recommend(signals).key '" + rec.key + "'");
var evChips = findByClass(heroRoot, "pw-coach-ev").map(textOf).map(function (x) { return x.trim(); }).filter(Boolean);
assert(evChips.length >= 1, "base coach hero rendered no pw-coach-evidence chips");
// Phase 2.3: the command grid renders one card per ORDER entry; dropping an entry must fail the
// count. (The pulse chips are pinned by DASH-CMD-PULSE and not re-asserted here.)
var cardNames = findByClass(heroRoot, "pw-cmd-name").map(textOf).map(function (x) { return x.trim(); });
assert(cardNames.length === 5,
  "command grid did not render one card per ORDER entry (want 5, got " + cardNames.length + ": " + cardNames.join(", ") + ")");
["codmaster", "codvisor", "codinventor", "codcycle", "codshard"].forEach(function (k) {
  assert(cardNames.indexOf(k) >= 0, "command grid is missing the '" + k + "' card");
});
console.log("CMD-HERO-OK");
JS
  if node "$TMP/cmd_hero_test.js" "$ROOT/scripts/dashboard" >"$TMP/cmd_hero.out" 2>"$TMP/cmd_hero.err" \
     && grep -q CMD-HERO-OK "$TMP/cmd_hero.out"; then
    ok "commands.js base coach hero: pw-coach-pick matches COACH.recommend(signals).key and pw-coach-evidence chips render"
  else
    bad "commands.js base coach hero assertion failed: $(cat "$TMP/cmd_hero.err" 2>/dev/null)"
  fi
else
  ok "commands.js base coach hero check skipped (node not installed)"
fi

# --- Test DASH-CMD-COPY: the copy button writes the invocation to the clipboard (and degrades) ----
# invoke() renders a copy button whose click calls navigator.clipboard.writeText(cmd) with the exact
# rendered invocation text; with no clipboard API the click must be a silent no-op (no throw). Patches
# El.addEventListener/click locally (the same dispatch-hook technique the other view blocks use).
if command -v node >/dev/null 2>&1; then
  cat > "$TMP/cmd_copy_test.js" <<'JS'
const assert = require("assert");
const BASE = process.argv[2];
const VM = require(BASE + "/../../tests/cases/lib/dashboard-vm.js");
const { El, makeDoc, makeWin, install, loadCommon, loadView, makeFixture, findByClass, textOf } = VM;
El.prototype.addEventListener = function (type, fn) { this._ev = this._ev || {}; (this._ev[type] = this._ev[type] || []).push(fn); };
El.prototype.click = function () { var fns = (this._ev && this._ev.click) || []; for (var i = 0; i < fns.length; i++) { fns[i].call(this, { type: "click" }); } };
const doc = makeDoc(); const win = makeWin(doc);
win.fetch = function () { return Promise.resolve({ ok: true, json: function () { return Promise.resolve({ total: 0, checks: [] }); } }); };
install(win, doc);
loadCommon(BASE);
loadView(BASE, "commands");
const fx = makeFixture();
// (1) with a clipboard stub: clicking copy writes the exact rendered invocation text
var copied = [];
// Node 20 exposes a read-only global `navigator`, so a plain assignment no-ops — define it.
Object.defineProperty(globalThis, "navigator", { value: { clipboard: { writeText: function (s) { copied.push(s); return Promise.resolve(); } } }, configurable: true, writable: true });
var cC = new El("section");
win.PW_VIEWS.commands(cC, fx.state, fx.fullCtx);
var invokeWrap = findByClass(cC, "pw-cmd-invoke")[0];
assert(invokeWrap, "commands did not render a copyable invocation");
var codeText = textOf(findByClass(invokeWrap, "pw-cmd-code")[0]).trim();
var copyBtn = findByClass(invokeWrap, "pw-cmd-copy")[0];
assert(copyBtn, "invoke did not render a copy button");
copyBtn.click();
assert(copied.length === 1 && copied[0] === codeText,
  "copy click did not writeText the rendered invocation (wrote " + JSON.stringify(copied) + ", code=" + JSON.stringify(codeText) + ")");
// (2) no-clipboard fallback: a click must not throw when navigator.clipboard is absent
Object.defineProperty(globalThis, "navigator", { value: {}, configurable: true, writable: true });
var cD = new El("section");
win.PW_VIEWS.commands(cD, fx.state, fx.fullCtx);
findByClass(cD, "pw-cmd-copy")[0].click();   // must not throw
console.log("CMD-COPY-OK");
JS
  if node "$TMP/cmd_copy_test.js" "$ROOT/scripts/dashboard" >"$TMP/cmd_copy.out" 2>"$TMP/cmd_copy.err" \
     && grep -q CMD-COPY-OK "$TMP/cmd_copy.out"; then
    ok "commands.js copy button writes the rendered invocation via navigator.clipboard.writeText and no-ops without a clipboard API"
  else
    bad "commands.js copy-button assertion failed: $(cat "$TMP/cmd_copy.err" 2>/dev/null)"
  fi
else
  ok "commands.js copy-button check skipped (node not installed)"
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

# --- Test DASH-SSE-RETRY: /events advertises a server-tuned reconnect cadence ------------
# A leading SSE `retry: <ms>` directive gives a dropped stream a deliberate, bounded reconnect
# interval instead of the browser's implicit default. It must appear in the first bytes (right after
# the opening change frame, so the stream's first line stays `event: change`) and carry a positive ms.
cat > "$TMP/dash_retry.py" <<'PY'
import os, subprocess, sys, time, urllib.request
root, dash = sys.argv[1], sys.argv[2]
env = dict(os.environ, PW_DASH_POLL="0.05")
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
    saw_retry = False
    for _ in range(12):
        ln = ev.readline()
        if ln.startswith(b"retry:"):
            ms = int(ln.split(b":", 1)[1].strip())
            assert ms >= 1, "retry cadence must be a positive integer ms, got %d" % ms
            saw_retry = True; break
    ev.close()
    assert saw_retry, "no `retry:` directive in the first bytes of /events"
    print("SSE-RETRY-OK")
finally:
    proc.terminate()
    try:
        proc.wait(timeout=5)
    except Exception:
        proc.kill()
PY
DRDIR="$TMP/dash-retry"; mkdir -p "$DRDIR/.planwright"
printf -- '- [ ] one\n      Mode: improve\n' > "$DRDIR/.planwright/plan.md"
python3 "$TMP/dash_retry.py" "$DRDIR" "$DASH" >"$TMP/dretry.out" 2>"$TMP/dretry.err" || true
if grep -q SSE-RETRY-OK "$TMP/dretry.out"; then
  ok "dashboard.py /events advertises a positive retry: reconnect cadence in the first bytes"
else
  bad "dashboard.py /events retry: directive not observed: $(cat "$TMP/dretry.err" 2>/dev/null)"
fi

# --- Test DASH-SSE-ID: change events carry a strictly increasing id: --------------------
# Each change frame stamps a monotonic `id:` (the frame's second line) so a reconnecting client
# replaying Last-Event-ID can detect a gap. Two successive changes must carry strictly increasing ids.
cat > "$TMP/dash_id.py" <<'PY'
import os, subprocess, sys, time, urllib.request
root, dash = sys.argv[1], sys.argv[2]
env = dict(os.environ, PW_DASH_POLL="0.05")
proc = subprocess.Popen([sys.executable, dash, "--root", root, "--port", "0"],
                        stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, env=env)
def read_id(ev):
    saw_change = False
    for _ in range(40):
        ln = ev.readline()
        if not ln:
            return None
        if ln.startswith(b"event: change"):
            saw_change = True
        elif saw_change and ln.startswith(b"id:"):
            return int(ln.split(b":", 1)[1].strip())
    return None
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
    ev = urllib.request.urlopen("http://127.0.0.1:%d/events" % port, timeout=8)
    id1 = read_id(ev)
    assert id1 is not None, "no id on the first change event"
    time.sleep(0.1)
    with open(os.path.join(root, ".planwright", "plan.md"), "a") as fh:
        fh.write("\n- [ ] two\n      Mode: improve\n")
    id2 = read_id(ev)
    assert id2 is not None, "no id on the second change event"
    assert id2 > id1, "ids not strictly increasing (%r -> %r)" % (id1, id2)
    ev.close()
    print("SSE-ID-OK")
finally:
    proc.terminate()
    try:
        proc.wait(timeout=5)
    except Exception:
        proc.kill()
PY
DIDIR="$TMP/dash-id"; mkdir -p "$DIDIR/.planwright"
printf -- '- [ ] one\n      Mode: improve\n' > "$DIDIR/.planwright/plan.md"
python3 "$TMP/dash_id.py" "$DIDIR" "$DASH" >"$TMP/did.out" 2>"$TMP/did.err" || true
if grep -q SSE-ID-OK "$TMP/did.out"; then
  ok "dashboard.py /events stamps strictly increasing id: on successive change events"
else
  bad "dashboard.py /events monotonic id: not observed: $(cat "$TMP/did.err" 2>/dev/null)"
fi

# --- Test DASH-SSE-CAP: the concurrent /events cap returns a retriable 503 and recovers ----
# MAX_SSE_CLIENTS bounds live SSE handler threads so tab open/close churn during a long
# unattended cycle run cannot pile them up: an over-cap client gets a retriable 503 (not a new
# thread), and the slot is released on disconnect so capacity recovers. All 11 other /events
# opens in this suite are sequential, so the acquire-guard / 503 / finally-release path was
# untested. With PW_DASH_MAX_SSE_CLIENTS=1 the over-cap path is deterministic.
cat > "$TMP/dash_ssecap.py" <<'PY'
import os, subprocess, sys, time, urllib.request, urllib.error
root, dash = sys.argv[1], sys.argv[2]
env = dict(os.environ, PW_DASH_POLL="0.05", PW_DASH_HEARTBEAT="0.1", PW_DASH_MAX_SSE_CLIENTS="1")
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
    base = "http://127.0.0.1:%d" % port
    # Hold the only slot open with a first stream.
    ev1 = urllib.request.urlopen(base + "/events", timeout=5)
    assert ev1.readline().startswith(b"event: change"), "no initial change event on first stream"
    # A second concurrent /events must get a retriable 503, not a new handler thread.
    over = None
    try:
        urllib.request.urlopen(base + "/events", timeout=5)
    except urllib.error.HTTPError as e:
        over = e.code
    assert over == 503, "over-cap /events should be 503, got %r" % over
    # Release the slot by disconnecting the first stream; capacity must recover (bounded retry,
    # since the slot frees only when the handler's next write detects the broken pipe).
    ev1.close()
    recovered = False
    for _ in range(40):
        try:
            ev3 = urllib.request.urlopen(base + "/events", timeout=5)
            if ev3.readline().startswith(b"event: change"):
                recovered = True; ev3.close(); break
            ev3.close()
        except urllib.error.HTTPError:
            time.sleep(0.1)
    assert recovered, "slot not released after first stream closed (capacity did not recover)"
    print("SSE-CAP-OK")
finally:
    proc.terminate()
    try:
        proc.wait(timeout=5)
    except Exception:
        proc.kill()
PY
DSCDIR="$TMP/dash-ssecap"; mkdir -p "$DSCDIR/.planwright"
printf -- '- [ ] one\n      Mode: improve\n' > "$DSCDIR/.planwright/plan.md"
python3 "$TMP/dash_ssecap.py" "$DSCDIR" "$DASH" >"$TMP/dscap.out" 2>"$TMP/dscap.err" || true
if grep -q SSE-CAP-OK "$TMP/dscap.out"; then
  ok "dashboard.py /events caps concurrent streams with a retriable 503 and recovers on disconnect"
else
  bad "dashboard.py SSE cap not observed: $(cat "$TMP/dscap.err" 2>/dev/null)"
fi

# --- Test DASH-SSE-CAP-VALIDATION: an invalid cap falls back to 64, never floors to 0 --------
# PW_DASH_MAX_SSE_CLIENTS is an integer slot count. A fractional value in (0,1) once passed the
# float helper's >0 guard and int()-floored to 0, leaving a zero-slot BoundedSemaphore that 503s
# every live client. _env_int must reject fractional/sub-1/negative/non-numeric values and fall
# back to the default 64, while honoring a valid integer >= 1. Asserted at import — no port bound.
cat > "$TMP/dash_capval.py" <<'PY'
import os, sys, importlib
sys.path.insert(0, os.path.dirname(os.path.abspath(sys.argv[1])))
cases = {"0.5": 64, "0.9": 64, "0": 64, "-5": 64, "abc": 64, "32": 32, "1": 1}
for raw, want in cases.items():
    os.environ["PW_DASH_MAX_SSE_CLIENTS"] = raw
    sys.modules.pop("dashboard", None)
    got = importlib.import_module("dashboard").MAX_SSE_CLIENTS
    assert got == want, "PW_DASH_MAX_SSE_CLIENTS=%s -> %r, want %d" % (raw, got, want)
os.environ.pop("PW_DASH_MAX_SSE_CLIENTS", None)
sys.modules.pop("dashboard", None)
got = importlib.import_module("dashboard").MAX_SSE_CLIENTS
assert got == 64, "unset default should be 64, got %r" % got
print("CAP-VAL-OK")
PY
python3 "$TMP/dash_capval.py" "$DASH" >"$TMP/capval.out" 2>"$TMP/capval.err" || true
if grep -q CAP-VAL-OK "$TMP/capval.out"; then
  ok "dashboard.py MAX_SSE_CLIENTS rejects fractional/sub-1/non-numeric and falls back to 64"
else
  bad "dashboard.py SSE-cap validation failed: $(cat "$TMP/capval.err" 2>/dev/null)"
fi

# --- Test DASH-SSE-RETRY-VALIDATION: an invalid retry cadence falls back to 3000, never to 0 --
# PW_DASH_SSE_RETRY_MS sets the advertised reconnect cadence. It must go through the same strict
# _env_int validator as the SSE cap: a fractional/sub-1/negative/non-numeric value is rejected back
# to the default 3000 (never 0 — a `retry: 0` would tell the browser to reconnect instantly, a tight
# loop), while a valid integer >= 1 is honored. Asserted at import — no port bound.
cat > "$TMP/dash_retryval.py" <<'PY'
import os, sys, importlib
sys.path.insert(0, os.path.dirname(os.path.abspath(sys.argv[1])))
cases = {"0.5": 3000, "0": 3000, "-5": 3000, "abc": 3000, "5000": 5000, "1": 1}
for raw, want in cases.items():
    os.environ["PW_DASH_SSE_RETRY_MS"] = raw
    sys.modules.pop("dashboard", None)
    got = importlib.import_module("dashboard").SSE_RETRY_MS
    assert got == want, "PW_DASH_SSE_RETRY_MS=%s -> %r, want %d" % (raw, got, want)
os.environ.pop("PW_DASH_SSE_RETRY_MS", None)
sys.modules.pop("dashboard", None)
got = importlib.import_module("dashboard").SSE_RETRY_MS
assert got == 3000, "unset default should be 3000, got %r" % got
print("SSE-RETRY-VAL-OK")
PY
python3 "$TMP/dash_retryval.py" "$DASH" >"$TMP/retryval.out" 2>"$TMP/retryval.err" || true
if grep -q SSE-RETRY-VAL-OK "$TMP/retryval.out"; then
  ok "dashboard.py SSE_RETRY_MS rejects fractional/sub-1/non-numeric and falls back to 3000 (never 0)"
else
  bad "dashboard.py SSE-retry validation failed: $(cat "$TMP/retryval.err" 2>/dev/null)"
fi

# --- Test DASH-PORT-VALIDATION: a fractional PW_DASH_PORT is rejected, not floored ----------
# A port is a whole number, so PW_DASH_PORT goes through _env_int (the strict integer path),
# not _env_float + int() which silently floored a fractional value to a nearby port. The
# distinguishing case is "9001.5": the old float+floor path yielded 9001 (a bad value honored),
# the strict path rejects it back to the default 8765. A valid integer is still honored.
cat > "$TMP/dash_portval.py" <<'PY'
import os, sys, importlib
sys.path.insert(0, os.path.dirname(os.path.abspath(sys.argv[1])))
cases = {"9001.5": 8765, "8765.9": 8765, "0.5": 8765, "0": 8765, "-5": 8765,
         "abc": 8765, "9001": 9001, "1": 1}
for raw, want in cases.items():
    os.environ["PW_DASH_PORT"] = raw
    sys.modules.pop("dashboard", None)
    got = importlib.import_module("dashboard").DEFAULT_PORT
    assert got == want, "PW_DASH_PORT=%s -> %r, want %d" % (raw, got, want)
os.environ.pop("PW_DASH_PORT", None)
sys.modules.pop("dashboard", None)
got = importlib.import_module("dashboard").DEFAULT_PORT
assert got == 8765, "unset default should be 8765, got %r" % got
print("PORT-VAL-OK")
PY
python3 "$TMP/dash_portval.py" "$DASH" >"$TMP/portval.out" 2>"$TMP/portval.err" || true
if grep -q PORT-VAL-OK "$TMP/portval.out"; then
  ok "dashboard.py DEFAULT_PORT rejects a fractional/sub-1/non-numeric PW_DASH_PORT (no silent floor) and honors a valid integer"
else
  bad "dashboard.py PW_DASH_PORT validation failed: $(cat "$TMP/portval.err" 2>/dev/null)"
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

# --- Dashboard is read-only-by-construction: serving leaves the tree byte-unchanged ----
# scripts/dashboard.py claims to mirror, never mutate, the served repo. Boot it over a
# pristine fixture (NOT $DFX, which the main client appends to), hit every read-only endpoint
# (state/graph/doctor/recommend/projects + the UI shell), then assert no file under the root was
# created, modified, or removed (a sha256 tree snapshot). A regression where an endpoint writes a
# cache/lock/beacon (or doctor reaches its --fix git-ignore append) turns the suite red.
DFX3="$TMP/dash-nowrite"; mkdir -p "$DFX3/.planwright"
printf -- '- [ ] one\n      Mode: develop\n' > "$DFX3/.planwright/plan.md"
printf '{"nodes":{"a.py":{"pagerank":0.5,"is_articulation":true,"imports":[]}}}\n' > "$DFX3/.planwright/graph.json"
cat > "$TMP/dash_nowrite.py" <<'PY'
import hashlib, os, subprocess, sys, time, urllib.request, urllib.error
root, dash = sys.argv[1], sys.argv[2]
def snap(r):
    out = {}
    for dp, _, fs in os.walk(r):
        for f in fs:
            p = os.path.join(dp, f)
            try:
                out[os.path.relpath(p, r)] = hashlib.sha256(open(p, "rb").read()).hexdigest()
            except OSError:
                pass
    return out
before = snap(root)
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
    # Exercise every read-only endpoint (and the shell). Errors are ignored here: the
    # contract under test is no-write, not response shape (covered above).
    for ep in ("/state.json", "/graph.json", "/doctor.json", "/recommend.json",
               "/projects.json", "/"):
        try:
            urllib.request.urlopen(base + ep, timeout=10).read()
        except urllib.error.HTTPError:
            pass
    time.sleep(0.3)   # let any deferred/background write land before snapshotting
finally:
    proc.terminate()
    try:
        proc.wait(timeout=5)
    except Exception:
        proc.kill()
after = snap(root)
new = sorted(set(after) - set(before))
removed = sorted(set(before) - set(after))
modified = sorted(k for k in before if k in after and before[k] != after[k])
assert not new, "dashboard CREATED files while serving: %r" % new
assert not removed, "dashboard REMOVED files while serving: %r" % removed
assert not modified, "dashboard MODIFIED files while serving: %r" % modified
print("NOWRITE-OK")
PY
if python3 "$TMP/dash_nowrite.py" "$DFX3" "$DASH" >"$TMP/dash_nw.out" 2>"$TMP/dash_nw.err" \
   && grep -q NOWRITE-OK "$TMP/dash_nw.out"; then
  ok "dashboard.py serves read-only: every endpoint leaves the fixture tree byte-unchanged"
else
  bad "dashboard.py no-write assertion failed: $(cat "$TMP/dash_nw.err" 2>/dev/null)"
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
# Covers all nine views: the state-driven ones (shards + fleet included), timeline + graph
# (graph's full path drives PW_GRAPH.renderCoupling, its bare path the graph-less guard), and
# the fetch-based doctor view (stubbed fetch -> async paint, rendered outside the loop). Node-gated.
if command -v node >/dev/null 2>&1; then
  cat > "$TMP/views_fn_test.js" <<'JS'
const fs = require("fs");
const vm = require("vm");
const assert = require("assert");
const BASE = process.argv[2];

// El/document/window stubs, the view loader, and the fixture come from the shared
// node-gated vm-bootstrap helper (tests/cases/lib/dashboard-vm.js) so every view-
// assertion block reuses one bootstrap instead of duplicating it. BASE is .../scripts/
// dashboard, so .../../tests/cases/lib reaches the repo's helper.
const VM = require(BASE + "/../../tests/cases/lib/dashboard-vm.js");
const { El, makeDoc, makeWin, install, loadCommon, loadViews, makeFixture } = VM;
// Capture click handlers so a vital's onActivate (wired via addEventListener in vitalCard)
// is invocable here — el.click() fires the stored click listeners. Storing alone is inert;
// only an explicit .click() dispatches, so this never perturbs a plain render.
El.prototype.addEventListener = function (type, fn) {
  this._ev = this._ev || {};
  (this._ev[type] = this._ev[type] || []).push(fn);
};
El.prototype.click = function () {
  var fns = (this._ev && this._ev.click) || [];
  for (var i = 0; i < fns.length; i++) { fns[i].call(this, { type: "click" }); }
};
const doc = makeDoc();
const win = makeWin(doc);
// doctor.js fetches /doctor.json and commands.js fetches /recommend.json instead of
// rendering only from the passed state; stub fetch per-URL so both async paint paths are
// exercisable here. REC_BODY starts as a WRONG-shaped body (a doctor-ish payload), so the
// commands front-door recUsable guard is behaviorally exercised before the usable record
// is swapped in below.
let REC_BODY = { total: 1, checks: [] };
win.fetch = function (url) {
  if (url === "/recommend.json") {
    return Promise.resolve({ ok: true, json: function () { return Promise.resolve(REC_BODY); } });
  }
  return Promise.resolve({ ok: true, json: function () {
    return Promise.resolve({ total: 5, warn: 1, fail: 0, checks: [
      { name: "git", status: "ok", detail: "2.40" },
      { name: "rg", status: "warn", detail: "not found", degrades: "slower Stage 1 scan" },
    ] });
  } });
};
install(win, doc);

// Load the real derive engine + vendored coupling renderer + shared UI fragments, then
// every view (each registers window.PW_VIEWS.<name>); then build the full+bare fixture.
loadCommon(BASE);
const VIEWS = ["console", "plan", "commands", "insights", "shards", "timeline", "graph", "fleet"];
loadViews(BASE, VIEWS);
const { graphText, metrics, state, fullCtx, bareCtx } = makeFixture();
assert(metrics, "metrics built from the fixture graph");

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
// Phase 1.2: pin the rendered frontier COUNTS (not just the label) so a swapped or mis-counted
// never_audited/stale field fails CI. The fixture frontier is {never_audited:3, stale:5}; the
// vital renders the sub-line "3 never-audited · 5 stale" — assert both counts on the card.
var frVital = findByClass(fc, "pw-vital--frontier");
assert(frVital.length === 1, "Console did not render the audit-frontier vital card");
var frText = textOf(frVital[0]);
assert(/3 never-audited/.test(frText), "frontier vital did not render never_audited=3 (got: " + frText + ")");
assert(/5 stale/.test(frText), "frontier vital did not render stale=5 (got: " + frText + ")");
var graphless = JSON.stringify({ graph_built_at_sha: "deadbeef", nodes: { "a.py": { git_churn: 1, pagerank: 0.5, covered_by_test: true, is_test: false, lang: "python", loc: 5, branch_count: 1, imports: [] } } });
var mNoFr = win.PW_DERIVE.metrics(graphless);
assert(mNoFr && mNoFr.frontier === null, "fixture sanity: a frontier-less graph yields null frontier");
var nf = new El("section");
win.PW_VIEWS.console(nf, state, { graphText: graphless, metrics: mNoFr, builtSha: "deadbeef", stale: false, head: "deadbeef" });
assert(!/never-audited/.test(textOf(nf)), "Console rendered a frontier vital on a pre-frontier (null) graph");

// Phase 1.2: console must render the vitals strip on a fully degraded null-metrics/null-
// graphText context (a repo with no built graph yet) without throwing and without a frontier
// card. The VIEWS loop only proves no-throw on bareCtx; the nf check above uses real metrics
// with a null frontier — a DIFFERENT path. Pin the null-metrics branch: vitals() returns the
// "needs a built graph" note and no frontier vital.
var bareC = new El("section");
win.PW_VIEWS.console(bareC, state, bareCtx);
var bareConText = textOf(bareC);
assert(/Vitals need a built graph/.test(bareConText),
  "console did not render the no-graph vitals note on a null-metrics context");
assert(findByClass(bareC, "pw-vital--frontier").length === 0,
  "console rendered a frontier vital card on a null-metrics context");
assert(!/never-audited/.test(bareConText),
  "console rendered the frontier vital on a null-metrics context");

// Targeted: the carried satellite appears ONLY when counts.carried is non-zero; the base
// fixture (no carried field — an older snapshot) must render the satellites unchanged.
assert(!/carried/.test(textOf(fc)), "Console rendered a carried satellite without counts.carried");
var carriedState = Object.assign({}, state, {
  counts: Object.assign({}, state.counts, { carried: 2 }),
});
var cs = new El("section");
win.PW_VIEWS.console(cs, carriedState, fullCtx);
assert(/carried/.test(textOf(cs)), "Console omitted the carried satellite on counts.carried=2");

// Targeted: the Reactor's four resting states — the base fixture (2 pending) reads
// IN PROGRESS; converged reads CONVERGED; a drained plan whose recorded point went stale
// reads STALE; a drained plan with no recorded point reads IDLE.
assert(/IN PROGRESS/.test(textOf(fc)), "Reactor did not read IN PROGRESS with pending items");
var convC = new El("section");
win.PW_VIEWS.console(convC, Object.assign({}, state, { converged: true }), fullCtx);
assert(/CONVERGED/.test(textOf(convC)), "Reactor did not read CONVERGED on a converged snapshot");
var staleC = new El("section");
win.PW_VIEWS.console(staleC, Object.assign({}, state, {
  pending: [], counts: Object.assign({}, state.counts, { pending: 0 }),
  final_point: { sha: "deadbeef", date: "2026-01-01", deepest_tier: "expand", valid: true, stale: true, scope: null },
}), fullCtx);
assert(/STALE/.test(textOf(staleC)), "Reactor did not read STALE on a drained plan with a stale final point");
var idleC = new El("section");
win.PW_VIEWS.console(idleC, Object.assign({}, state, {
  pending: [], counts: Object.assign({}, state.counts, { pending: 0 }), final_point: null,
}), fullCtx);
assert(/IDLE/.test(textOf(idleC)), "Reactor did not read IDLE on a drained plan with no final point");

// Phase 5.1: deeper than the /STALE/ verdict above — a drained-but-stale point must ALSO render
// the explanatory staleness sub-line copy AND the is-stale reactor decorator (a regression that
// kept the STALE word but dropped the explanation or the visual cue would still pass /STALE/).
// Both must be ABSENT on a fresh (valid, non-stale) point.
assert(/final point is stale — HEAD moved since/.test(textOf(staleC)),
  "stale reactor omitted the explanatory staleness sub-line copy");
assert(findByClass(staleC, "is-stale").length > 0,
  "stale reactor omitted the is-stale decorator class");
// Phase 2.3: like the stale sub-line above, pin the IDLE and component-scoped reactor sub-line copy.
// Only the verdict WORD was asserted for IDLE, and the scoped branch (a whole noteText case) was
// unexercised — so a swapped guidance line would pass. idleC is the drained/no-final-point fixture.
assert(/no pending work and no final point recorded/.test(textOf(idleC)),
  "idle reactor omitted the 'no pending work and no final point' sub-line copy");
var scopedC = new El("section");
win.PW_VIEWS.console(scopedC, Object.assign({}, state, {
  pending: [], counts: Object.assign({}, state.counts, { pending: 0 }),
  final_point: { sha: "deadbeef", date: "2026-01-01", deepest_tier: "expand", valid: true, stale: false, scope: "path:scripts" },
}), fullCtx);
assert(/only a component-scoped final point is recorded/.test(textOf(scopedC)),
  "scoped reactor omitted the component-scoped final-point sub-line copy");
var freshC = new El("section");
win.PW_VIEWS.console(freshC, Object.assign({}, state, {
  pending: [], counts: Object.assign({}, state.counts, { pending: 0 }),
  final_point: { sha: fullCtx.head, date: "2026-01-01", deepest_tier: "expand", valid: true, stale: false, scope: null },
}), fullCtx);
assert(!/final point is stale — HEAD moved since/.test(textOf(freshC)),
  "fresh final point wrongly rendered the staleness sub-line");
assert(findByClass(freshC, "is-stale").length === 0,
  "fresh final point wrongly rendered the is-stale decorator");

// Phase 5.1: the reactor ring arcs — the done progress arc (pw-reactor-arc-progress, rendered only
// when doneLen>0, i.e. completed>0) and the rejected notch (pw-reactor-notch, killLen>0, i.e.
// rejected>0). The base fixture has completed:[1]+rejected:[1] so both render; a fixture with
// neither completed nor rejected renders neither arc.
assert(findByClass(fc, "pw-reactor-arc-progress").length > 0,
  "reactor did not render the done progress arc with completed items");
assert(findByClass(fc, "pw-reactor-notch").length > 0,
  "reactor did not render the rejected notch with rejected items");
var noArcs = new El("section");
win.PW_VIEWS.console(noArcs, Object.assign({}, state, {
  completed: [], rejected: [],
  counts: Object.assign({}, state.counts, { completed: 0, rejected: 0 }),
}), fullCtx);
assert(findByClass(noArcs, "pw-reactor-arc-progress").length === 0,
  "reactor rendered a done arc with zero completed items");
assert(findByClass(noArcs, "pw-reactor-notch").length === 0,
  "reactor rendered a rejected notch with zero rejected items");

// Phase 5.2: the import-cycle vital — the cycles card renders the err gauge (pw-gauge-fill err) and
// the "import cycles" copy ONLY when metrics.cycles.length>0 (derive.js: cycles = graph.import_cycles).
// The base fixture is acyclic (import_cycles:[]) so its cycles vital reads "no import cycles" with no
// err gauge; a graph carrying a cycle renders the alerting gauge.
var cyclicGraph = JSON.stringify({
  graph_built_at_sha: "deadbeef",
  nodes: {
    "a.py": { imports: ["b.py"], pagerank: 0.5, branch_count: 1, loc: 5, lang: "python", covered_by_test: true, is_test: false, git_churn: 1 },
    "b.py": { imports: ["a.py"], pagerank: 0.5, branch_count: 1, loc: 5, lang: "python", covered_by_test: true, is_test: false, git_churn: 1 },
  },
  import_cycles: [["a.py", "b.py"]],
});
var mCyc = win.PW_DERIVE.metrics(cyclicGraph);
assert(mCyc.cycles.length === 1, "fixture sanity: a cyclic graph yields 1 import cycle");
var cycC = new El("section");
win.PW_VIEWS.console(cycC, state, { graphText: cyclicGraph, metrics: mCyc, builtSha: "deadbeef", stale: false, head: "deadbeef" });
var cycVital = findByClass(cycC, "pw-vital--cycles");
assert(cycVital.length === 1, "console did not render the import-cycles vital on a cyclic graph");
assert(findByClass(cycVital[0], "pw-gauge-fill err").length > 0,
  "import-cycles vital missing the err gauge on cyc>0");
assert(/import cycles/.test(textOf(cycVital[0])) && !/no import cycles/.test(textOf(cycVital[0])),
  "import-cycles vital did not render the cycle-count copy on cyc>0");
var fcCyc = findByClass(fc, "pw-vital--cycles");
assert(fcCyc.length === 1 && findByClass(fcCyc[0], "pw-gauge-fill err").length === 0,
  "acyclic base fixture wrongly rendered the cycles err gauge");

// Phase 2.3: the coupling-tension vital (v4) was entirely unasserted (the cycles vital above
// already pins its err-gauge/acyclic branches). Drive one strong (w>=0.8) of two coupling links ->
// couplingStrongShare 0.5 -> a "50%" vital reading "1 of 2 links w≥0.8"; a broken strong-share
// computation fails.
var coupGraph = JSON.stringify({ graph_built_at_sha: "deadbeef",
  nodes: { "x.py": { pagerank: 0.5, git_churn: 1, branch_count: 1, lang: "python", loc: 10, covered_by_test: false, is_test: false, imports: [] },
           "y.py": { pagerank: 0.4, git_churn: 1, branch_count: 1, lang: "python", loc: 10, covered_by_test: false, is_test: false, imports: [] } },
  coupling_edges: [ { a: "x.py", b: "y.py", weight: 0.9, cooccur: 3 }, { a: "x.py", b: "y.py", weight: 0.5, cooccur: 2 } ],
  import_cycles: [] });
var mCoup = win.PW_DERIVE.metrics(coupGraph);
var coupC = new El("section");
win.PW_VIEWS.console(coupC, state, { graphText: coupGraph, metrics: mCoup, builtSha: "deadbeef", stale: false, head: "deadbeef" });
var coupVital = findByClass(coupC, "pw-vital--coupling");
assert(coupVital.length === 1, "console did not render the coupling-tension vital");
var coupTxt = textOf(coupVital[0]);
assert(/50%/.test(coupTxt) && /1 of 2 links/.test(coupTxt),
  "coupling vital did not render the strong-share % and 'N of M links' (got: " + coupTxt + ")");

// Phase 5.2: the audit-frontier vital's alert branch — the frontier card renders the warn gauge
// (pw-gauge-fill warn) ONLY when na (never_audited) > 0. The existing frontier test pins the COUNTS
// but not the alert branch. The base fixture has na=3>0 (warn gauge present); an na==0 frontier
// renders the card without the warn gauge.
var fcFrontier = findByClass(fc, "pw-vital--frontier");
assert(fcFrontier.length === 1, "console did not render the frontier vital on the base fixture");
assert(findByClass(fcFrontier[0], "pw-gauge-fill warn").length > 0,
  "frontier vital missing the warn gauge on na>0");
var na0Graph = JSON.stringify({
  graph_built_at_sha: "deadbeef",
  frontier: { never_audited: 0, stale: 4 },
  nodes: {
    "hot.py": { git_churn: 10, pagerank: 0.9, covered_by_test: false, is_test: false, lang: "python", loc: 100, branch_count: 5, is_articulation: true, imports: ["cold.py"] },
    "cold.py": { git_churn: 1, pagerank: 0.1, covered_by_test: true, is_test: false, lang: "python", loc: 10, branch_count: 1, is_articulation: false, imports: [] },
  },
  import_cycles: [],
});
var mNa0 = win.PW_DERIVE.metrics(na0Graph);
assert(mNa0.frontier && mNa0.frontier.never_audited === 0, "fixture sanity: na==0 frontier");
var na0C = new El("section");
win.PW_VIEWS.console(na0C, state, { graphText: na0Graph, metrics: mNa0, builtSha: "deadbeef", stale: false, head: "deadbeef" });
var na0Frontier = findByClass(na0C, "pw-vital--frontier");
assert(na0Frontier.length === 1, "console did not render the frontier vital on an na==0 graph");
assert(findByClass(na0Frontier[0], "pw-gauge-fill warn").length === 0,
  "frontier vital wrongly rendered the warn gauge on na==0");

// Phase 5.2: cadence() omits zero-count mode legs (line `if (!counts[m]) return`). The base fixture's
// completed items are all develop, so the mode legend has a develop leg but NONE for the zero-count
// modes (repair/improve/docs/reorganize). A two-mode fixture shows exactly those two legs. (Read the
// pw-legend-item elements directly — findByClass substring-matches, so "pw-legend" also hits the items.)
var legText = findByClass(fc, "pw-legend-item").map(function (l) { return textOf(l); }).join(" | ");
assert(/develop/.test(legText), "cadence legend omitted the present develop mode");
["repair", "improve", "docs", "reorganize"].forEach(function (m) {
  assert(legText.indexOf(m) < 0, "cadence legend rendered a zero-count mode leg: " + m);
});
var twoModeC = new El("section");
win.PW_VIEWS.console(twoModeC, Object.assign({}, state, {
  completed: [{ title: "a", mode: "repair", commit: "x" }, { title: "b", mode: "docs", commit: "y" }],
}), fullCtx);
var twoLegText = findByClass(twoModeC, "pw-legend-item").map(function (l) { return textOf(l); }).join(" | ");
assert(/repair/.test(twoLegText) && /docs/.test(twoLegText), "two-mode cadence legend missing a present mode");
assert(twoLegText.indexOf("develop") < 0 && twoLegText.indexOf("improve") < 0,
  "two-mode cadence legend rendered a zero-count mode");

// Phase 5.2: sessionTrend() renders the empty "Collecting session history" branch when ctx.trend has
// fewer than 2 points, and 3 polylines (done/pend/kill) + the snapshot-count footer on a populated
// trend.
var emptyTrendC = new El("section");
win.PW_VIEWS.console(emptyTrendC, state, Object.assign({}, fullCtx, { trend: [] }));
assert(/Collecting session history/.test(textOf(emptyTrendC)),
  "sessionTrend did not render the empty branch on a <2-point trend");
assert(findByClass(emptyTrendC, "pw-trend-line").length === 0,
  "sessionTrend rendered trend lines on an empty trend");
var trend = [
  { t: 1000, done: 0, pend: 5, kill: 0 },
  { t: 61000, done: 2, pend: 3, kill: 1 },
  { t: 121000, done: 4, pend: 1, kill: 1 },
];
var fullTrendC = new El("section");
win.PW_VIEWS.console(fullTrendC, state, Object.assign({}, fullCtx, { trend: trend }));
assert(!/Collecting session history/.test(textOf(fullTrendC)),
  "sessionTrend wrongly rendered the empty branch on a populated trend");
assert(findByClass(fullTrendC, "pw-trend-line").length === 3,
  "sessionTrend did not render the 3 trend polylines (done/pend/kill) on a populated trend");
assert(/3 snapshots over/.test(textOf(fullTrendC)),
  "sessionTrend did not render the snapshot-count footer on a populated trend");

// Phase 5.2: the Dirty Pulse rail — renders "graph not built yet" on a null-metrics (no-graph) ctx,
// and a "N nodes dirty" sub-line (from state.graph.dirty_node_count) otherwise.
var barePulse = new El("section");
win.PW_VIEWS.console(barePulse, state, bareCtx);
assert(/graph not built yet/.test(textOf(barePulse)),
  "pulserail did not render the no-graph empty branch on a null-metrics ctx");
var dirtyState = Object.assign({}, state, { graph: { dirty_node_count: 3 } });
var dirtyC = new El("section");
win.PW_VIEWS.console(dirtyC, dirtyState, fullCtx);
var dirtySub = findByClass(dirtyC, "pw-pulserail-sub");
assert(dirtySub.length === 1 && /3 nodes dirty/.test(textOf(dirtySub[0])),
  "pulserail did not render the dirty-node count (3) from state.graph.dirty_node_count");

// Phase 5.3: Risk Ledger row flags — a row renders the "uncovered" flag when !n.covered and the
// "articulation" flag when n.articulation, and OMITS each otherwise. The fixture has hot.py
// (uncovered + articulation) and cold.py (covered, non-articulation), so each flag appears EXACTLY
// once (on hot.py); cold.py's row omits both. (Search the full flag class to exclude the
// "pw-ledger-flags" container and the "pw-ledger-row is-uncovered" row class.)
var insC = new El("section");
win.PW_VIEWS.insights(insC, state, fullCtx);
assert(findByClass(insC, "pw-ledger-row").length >= 2, "risk ledger did not render the fixture's hotspot rows");
assert(findByClass(insC, "pw-ledger-flag is-uncovered").length === 1,
  "risk ledger uncovered flag should appear exactly once (hot.py), not on the covered cold.py row");
assert(findByClass(insC, "pw-ledger-flag is-articulation").length === 1,
  "risk ledger articulation flag should appear exactly once (hot.py), not on the non-articulation cold.py row");

// Targeted (Phase 1.2): the Reactor satellite strip reflects the accepted/pending/rejected
// counts so a renamed engine field renders a wrong count instead of failing silently. The
// verdict + carried-satellite assertions above never pin the accepted/pending NUMBERS; sat()
// renders value then label, so the strip reads "1 accepted 2 pending 1 rejected" for the base
// fixture (completed:[1], pending:[2], rejected:[1]).
var reSats = findByClass(fc, "pw-reactor-sats");
assert(reSats.length === 1, "Console reactor did not render the satellite strip");
var reSatText = textOf(reSats[0]);
assert(/1\s+accepted/.test(reSatText), "Reactor 'accepted' satellite did not reflect completed.length=1");
assert(/2\s+pending/.test(reSatText), "Reactor 'pending' satellite did not reflect pending.length=2");
assert(/1\s+rejected/.test(reSatText), "Reactor 'rejected' satellite did not reflect rejected.length=1");
// A renamed/mis-counted completed field must move the accepted satellite — add a second
// completed item and assert the count tracks it (the negative the strip exists to catch).
var moreDone = new El("section");
win.PW_VIEWS.console(moreDone, Object.assign({}, state, {
  completed: state.completed.concat([{ title: "also shipped", mode: "improve", commit: "def5678" }]),
}), fullCtx);
assert(/2\s+accepted/.test(textOf(findByClass(moreDone, "pw-reactor-sats")[0])),
  "Reactor 'accepted' satellite did not track a second completed item");

// Targeted: the run-activity beacon line (under the reactor note) appears ONLY when
// state.activity carries a well-formed beacon — the base fixture omits the field (an
// older snapshot) and must render the reactor unchanged; a stale beacon reads "stale?"
// instead of asserting a long-dead run is live; an explicit null (no beacon stamped)
// renders nothing either. "· since" is the line's unique marker in the Console text.
assert(!/· since /.test(textOf(fc)), "Console rendered an activity line without state.activity");
var actC = new El("section");
win.PW_VIEWS.console(actC, Object.assign({}, state, {
  activity: { command: "codshard", detail: "shard 3/5: scripts/", started: "2026-06-12T18:42:00Z", age_seconds: 30, stale: false },
}), fullCtx);
var actText = textOf(actC);
assert(/codshard — shard 3\/5: scripts\//.test(actText), "Console omitted the running-command line on a live beacon");
assert(/· since \d\d:\d\d/.test(actText), "activity line missed the since HH:MM stamp");
assert(!/stale\?/.test(actText), "a fresh beacon must not read stale?");
var staleActC = new El("section");
win.PW_VIEWS.console(staleActC, Object.assign({}, state, {
  activity: { command: "codmaster", detail: null, started: "2026-06-12T08:00:00Z", age_seconds: 7200, stale: true },
}), fullCtx);
assert(/codmaster/.test(textOf(staleActC)) && /stale\?/.test(textOf(staleActC)),
  "a stale beacon must render with the stale? caveat");
var nullActC = new El("section");
win.PW_VIEWS.console(nullActC, Object.assign({}, state, { activity: null }), fullCtx);
assert(!/· since /.test(textOf(nullActC)), "Console rendered an activity line on a null beacon");

// Targeted: the structural count vitals derive from the fixture graph — 2 tracked files,
// 1 articulation point (hot.py), 0 test files — and the cadence legend lists the accepted
// modes plus the rejected bucket with their counts.
var fcText = textOf(fc);
assert(/files\s+2\s+tracked files/.test(fcText), "Console files vital did not show the fixture's 2 tracked files");
assert(/articulation\s+1\s+cut vertices/.test(fcText), "Console articulation vital did not show the fixture's 1 cut vertex");
assert(/tests\s+0\s+test files/.test(fcText), "Console tests vital did not show the fixture's 0 test files");
assert(/develop 1/.test(fcText), "Cadence legend missed the develop accepted count");
assert(/rejected 1/.test(fcText), "Cadence legend missed the rejected count");

// Targeted (Phase 1.2): the coverage donut + hotspots vitals render from metrics, and their
// onActivate handlers navigate via PW_BUS.goto('insights'). The structural vitals above are
// pinned but the coverage/hotspots cards and their navigation wiring were not. Stub goto to
// record targets, find both vital buttons by modifier class, click each, assert the target.
var gotoTargets = [];
var savedGoto = win.PW_BUS.goto;
win.PW_BUS.goto = function (t) { gotoTargets.push(t); };
var vc = new El("section");
win.PW_VIEWS.console(vc, state, fullCtx);
var covVital = findByClass(vc, "pw-vital--coverage");
var hotVital = findByClass(vc, "pw-vital--hotspots");
assert(covVital.length === 1, "Console coverage vital did not render");
assert(hotVital.length === 1, "Console hotspots vital did not render");
var covText = textOf(covVital[0]);
assert(/1\/2/.test(covText) && /50% covered/.test(covText),
  "coverage vital did not render covered/total + percent from metrics (want 1/2, 50% covered)");
assert(/hot/.test(textOf(hotVital[0])), "hotspots vital did not render the hot meter from metrics");
covVital[0].click();
hotVital[0].click();
assert(gotoTargets.filter(function (t) { return t === "insights"; }).length === 2,
  "coverage/hotspots vital onActivate did not PW_BUS.goto('insights') (got " + gotoTargets.join(",") + ")");
win.PW_BUS.goto = savedGoto;

// Targeted: the Decision-timeline cumulative graph (timelineGraph) — header + accepted-rate
// text, a legend entry per mode present in completed[] with its cumulative count, and the
// no-accepted empty state (a rejected-only log plots no cumulative line).
function classOf(n) { return String(n.className || (n._attr && n._attr["class"]) || ""); }
function findByClass(node, cls, out) {
  out = out || [];
  if (classOf(node).indexOf(cls) >= 0) out.push(node);
  (node.children || []).forEach(function (c) { findByClass(c, cls, out); });
  return out;
}
var tl = new El("section");
win.PW_VIEWS.timeline(tl, state, fullCtx);
var tlText = textOf(tl);
assert(/Decision timeline/.test(tlText), "Timeline omitted the decision-timeline graph header");
assert(/50% accepted \(1\/2\)/.test(tlText), "Timeline graph accepted-rate text wrong (want 50% accepted (1/2))");
assert(/develop 1/.test(tlText), "Timeline graph legend missed the develop cumulative count");
assert(findByClass(tl, "pw-tlgraph-line").length === 1,
  "Timeline graph should draw exactly one cumulative line for a one-mode log");
var tlEmpty = new El("section");
win.PW_VIEWS.timeline(tlEmpty, Object.assign({}, state, { completed: [] }), fullCtx);
assert(/none accepted yet/.test(textOf(tlEmpty)), "Timeline graph empty state missing on a rejected-only log");
assert(findByClass(tlEmpty, "pw-tlgraph-line").length === 0,
  "Timeline graph plotted cumulative lines with no accepted entries");

// Targeted (Phase 4.3): the timeline render()'s NON-graph sections — the section-title header
// and the pw-timeline decision listing built by row() — were unasserted (only timelineGraph
// above was). The fixture log is completed:[{shipped, develop}], rejected:[{bad idea, value-gate}];
// render emits "Timeline — 1 accepted, 1 rejected" and a pw-timeline list of two rows: an accepted
// row (#1, title, mode badge) and a rejected row (#1, title, inline reason). Reuse tl from above.
assert(/Timeline — 1 accepted, 1 rejected/.test(tlText),
  "Timeline omitted the section-title header with accepted/rejected counts");
var tlList = findByClass(tl, "pw-timeline");
assert(tlList.length === 1, "Timeline did not render the pw-timeline decision listing");
var tlRows = (tlList[0].children || []);
assert(tlRows.length === 2, "Timeline listing did not render one row per completed+rejected entry (want 2, got " + tlRows.length + ")");
var tlAccepted = findByClass(tl, "pw-dot accepted");
var tlRejected = findByClass(tl, "pw-dot rejected");
assert(tlAccepted.length === 1 && tlRejected.length === 1,
  "Timeline listing did not render exactly one accepted + one rejected row dot");
// header/listing agreement: the header counts must equal the rendered row dots.
assert((/(\d+) accepted, (\d+) rejected/.exec(tlText) || [])[1] === String(tlAccepted.length) &&
       (/(\d+) accepted, (\d+) rejected/.exec(tlText) || [])[2] === String(tlRejected.length),
  "Timeline header accepted/rejected counts disagree with the rendered listing rows");
var tlAcceptedRowText = textOf(tlRows[0]);
assert(/#1/.test(tlAcceptedRowText) && /shipped/.test(tlAcceptedRowText),
  "Timeline accepted row missing its #position or title");
assert(findByClass(tlRows[0], "pw-badge").length === 1 && /develop/.test(textOf(findByClass(tlRows[0], "pw-badge")[0])),
  "Timeline accepted row missing its mode badge (want develop)");
var tlRejReason = findByClass(tl, "pw-reason-inline");
assert(tlRejReason.length === 1 && /value-gate: no consumer/.test(textOf(tlRejReason[0])),
  "Timeline rejected row missing its inline reason");
assert(/bad idea/.test(textOf(tlRows[1])), "Timeline rejected row missing its title");

// Targeted: the Plan view's per-surface graph cross-link chips (crossLinks, plan.js:40) render
// ONLY when an item's Surface matches a graph node (metrics.byPath). The base fixture's surfaces
// (a.py/b.py) are absent from the fixture graph (hot.py/cold.py), so the chips never rendered and
// the view's differentiating feature was unexercised. Point one item at a real node (hot.py) and
// assert exactly one chip + the "in graph" key; the second item (b.py, out-of-graph) is the
// negative control, and the degraded (no-metrics) context must draw none without throwing.
var xlState = Object.assign({}, state, {
  pending: [
    { title: "in graph", mode: "improve", rationale: "r", evidence: "e", surfaces: ["hot.py"], new_surfaces: [], development: "d", acceptance: "ok", verification: "bash tests/run.sh" },
    { title: "out of graph", mode: "repair", rationale: "r", evidence: "e", surfaces: ["b.py"], new_surfaces: [], development: "d", acceptance: "ok", verification: "bash tests/run.sh" },
  ],
});
var planXl = new El("section");
win.PW_VIEWS.plan(planXl, xlState, fullCtx);
var xlChips = findByClass(planXl, "pw-xlink lang-");
assert(xlChips.length === 1,
  "Plan crossLinks should render one chip (hot.py in-graph; b.py is not), got " + xlChips.length);
assert(findByClass(planXl, "pw-xlinks-k").length === 1,
  "Plan crossLinks omitted the 'in graph' key span for an in-graph surface");
assert(/hot\.py/.test(textOf(xlChips[0])),
  "Plan cross-link chip did not name the in-graph surface hot.py");
var planBareXl = new El("section");
win.PW_VIEWS.plan(planBareXl, xlState, bareCtx);
assert(findByClass(planBareXl, "pw-xlink lang-").length === 0,
  "Plan drew a cross-link chip with no metrics (crossLinks must return null)");

// Targeted: the Console home page renders the shared Recent-contributions card (PW_UI.contribCard)
// in the right rail ABOVE the dirty pulse — COMPACT: a two-tab strip ("Recent contributions" |
// "Rejected") in the mini-heading look (matching the Console's other section labels, never the
// big pw-panel-title scale), mode+title items only, and NO sub-line /
// commit stamp / "showing N of M" foot / final-point line (the Commands panel carries all of those;
// the home card is a glance).
var conC = new El("section");
win.PW_VIEWS.console(conC, state, fullCtx);
var conSide = findByClass(conC, "pw-console-side");
// findByClass matches substrings; the section's full "pw-panel pw-contrib" class is unique to it
// (sub-elements are pw-contrib-list/-item/...), and the aside matches its own class exactly.
var conContrib = findByClass(conC, "pw-panel pw-contrib");
var conPulse = findByClass(conC, "pw-pulserail").filter(function (n) { return classOf(n) === "pw-pulserail"; });
assert(conSide.length === 1 && conContrib.length === 1 && conPulse.length === 1,
  "Console right rail must hold exactly one contributions card and the dirty pulse");
function idxOfClass(arr, cls) {
  for (var i = 0; i < arr.length; i++) { if (classOf(arr[i]).indexOf(cls) >= 0) { return i; } }
  return -1;
}
var conSideKids = conSide[0].children;
assert(idxOfClass(conSideKids, "pw-contrib") >= 0 &&
       idxOfClass(conSideKids, "pw-pulserail") > idxOfClass(conSideKids, "pw-contrib"),
  "Console contributions card must sit ABOVE the dirty pulse in the right rail");
var conCardText = textOf(conContrib[0]);
assert(/Recent contributions/.test(conCardText) && /shipped/.test(conCardText),
  "Console contributions card must show the heading and the completed item's mode+title");
// The card heading is now a two-tab strip ("Recent contributions" | "Rejected"), so there is no
// standalone pw-section-mini / pw-panel-title heading element any more. The compact rail must
// avoid the big pw-panel-title scale and expose both tabs as role="tab" buttons.
var conTabs = findByClass(conContrib[0], "pw-contrib-tab").filter(function (n) { return classOf(n) === "pw-contrib-tab"; });
assert(conTabs.length === 2 && findByClass(conContrib[0], "pw-panel-title").length === 0,
  "Console (compact) contributions card must render the two-tab strip and no pw-panel-title heading");
assert(conTabs.every(function (b) { return b.getAttribute("role") === "tab"; }),
  "compact contributions tabs must carry role=\"tab\"");
assert(/Rejected/.test(conCardText), "compact contributions card must surface the Rejected tab next to Recent contributions");
assert(!/abc1234/.test(conCardText), "Console (compact) contributions card must omit the commit hash");
assert(!/rejected this run/.test(conCardText), "Console (compact) contributions card must omit the accepted/rejected sub-line");
assert(!/Final point:/.test(conCardText), "Console (compact) contributions card must omit the final-point line");
// Foot-removal needs >8 items: a 9-item log shows the "showing N of M" foot in the detailed
// Commands card but never in the compact Console card.
var manyCompleted = [];
for (var mci = 0; mci < 9; mci++) { manyCompleted.push({ title: "item " + mci, mode: "improve", commit: "c" + mci }); }
var manyState = Object.assign({}, state, { completed: manyCompleted });
var conMany = new El("section");
win.PW_VIEWS.console(conMany, manyState, fullCtx);
assert(findByClass(conMany, "pw-panel-foot").length === 0,
  "Console (compact) contributions card must omit the 'showing N of M' foot even past 8 items");
var cmdMany = new El("section");
win.PW_VIEWS.commands(cmdMany, manyState, fullCtx);
assert(findByClass(cmdMany, "pw-panel-foot").length === 1,
  "Commands (detailed) contributions card must keep the 'showing N of M' foot past 8 items");

// Targeted: the Shards view renders the shard map from state.repo (the codshard
// enumeration) — shard cards in sweep order, the folded-dirs note, and the closing
// whole-repo round — and degrades to the no-enumeration empty state when the snapshot
// carries no repo block (an older server / git unavailable), exactly the state the
// VIEWS loop above already exercised (the base fixture has no repo key).
var shState = Object.assign({}, state, {
  repo: { tracked_files: 240, shardable_dirs: ["docs", "scripts"], folded_dirs: ["misc"], large: true },
});
var shC = new El("section");
win.PW_VIEWS.shards(shC, shState, fullCtx);
var shText = textOf(shC);
assert(/docs\//.test(shText) && /scripts\//.test(shText), "Shards view did not render the shard cards from state.repo");
// Basis is asserted on the pulse CHIPS, not the whole view text — the static header copy
// contains the phrase "staleness order" verbatim, so a textOf match would be vacuous.
var shChips = findByClass(shC, "pw-coach-pulse-chip").map(textOf).join(" | ");
assert(/staleness order/.test(shChips), "Shards basis chip did not read staleness with a graph present");
assert(!/lexicographic order/.test(shChips), "Shards basis chip wrongly read lexicographic with a graph present");
assert(/misc/.test(shText), "Shards view omitted the folded-dirs note");
assert(/Closing whole-repo round/.test(shText), "Shards view omitted the closing whole-repo round card");
assert(/large repo/.test(shText), "Shards view omitted the large-repo chip on repo.large=true");
// Every shard card carries its copyable single-shard invocation (codshard's explicit
// `shards <X>` form), and the closing card keeps the bare whole-repo one. Anchored on
// the pw-cmd-code elements, not the view text — the header prose also says
// "/planwright:codshard", so a textOf count would be vacuous.
var shInv = findByClass(shC, "pw-cmd-code").map(textOf);
assert(shInv.indexOf("/planwright:codshard shards docs") >= 0
    && shInv.indexOf("/planwright:codshard shards scripts") >= 0,
  "shard cards lack their copyable single-shard codshard invocation");
assert(shInv.indexOf("/planwright:codshard") >= 0,
  "the closing card lost its bare whole-repo invocation");
assert.strictEqual(shInv.length, 3,
  "Shards view invocation count drifted (want per-shard scoped x2 + closing whole-repo x1)");
var shBare = new El("section");
win.PW_VIEWS.shards(shBare, shState, bareCtx);
var shBareChips = findByClass(shBare, "pw-coach-pulse-chip").map(textOf).join(" | ");
assert(/lexicographic order/.test(shBareChips), "Shards basis chip did not fall back to lexicographic without a graph");
assert(findByClass(shBare, "pw-cmd-code").map(textOf).indexOf("/planwright:codshard shards docs") >= 0,
  "graph-less shard cards lost the single-shard invocation");
var shNo = new El("section");
win.PW_VIEWS.shards(shNo, state, fullCtx);
assert(/No shard enumeration/.test(textOf(shNo)), "Shards view did not degrade to the no-repo empty state");

// Targeted (Phase 4.3): the Fleet view's POPULATED multi-project grid path. The VIEWS loop
// renders fleet on the base fixture, which carries no projects, so only the empty state runs —
// the grid, cards, and project-count note (fleet.js populated branch) were never executed.
// Drive it via window.PW_PROJECTS (the bridge app.js fills) and assert the grid renders one
// card per project + the plural/singular note; zero projects falls back to the no-projects note.
// (Per-card dot/count VALUES + sort order are item 87.) Restore PW_PROJECTS so no later block sees it.
var savedPWP = win.PW_PROJECTS;
win.PW_PROJECTS = [
  { id: "p1", name: "alpha", path: "/repos/alpha", status: "active", counts: { pending: 4, done: 7 } },
  { id: "p2", name: "beta", path: "/repos/beta", status: "converged", counts: { pending: 0, done: 3 } },
  { id: "p3", name: "gamma", path: "/repos/gamma", status: "stale", counts: { pending: 2, done: 1 } },
];
var fleetC = new El("section");
win.PW_VIEWS.fleet(fleetC, state, fullCtx);
assert(findByClass(fleetC, "pw-fleet-grid").length === 1, "Fleet did not render the multi-project grid");
assert(findByClass(fleetC, "pw-fleet-card").length === 3, "Fleet grid did not render one card per project");
assert(findByClass(fleetC, "pw-fleet-empty").length === 0, "Fleet rendered the empty state on a populated snapshot");
var fleetNote = textOf(findByClass(fleetC, "pw-fleet-note")[0]);
assert(/3 projects/.test(fleetNote) && /click a card to switch/.test(fleetNote), "Fleet note did not reflect the 3-project count");
win.PW_PROJECTS = [{ id: "p1", name: "alpha", path: "/repos/alpha", status: "active", counts: { pending: 1, done: 0 } }];
var fleetOne = new El("section");
win.PW_VIEWS.fleet(fleetOne, state, fullCtx);
assert(/1 project/.test(textOf(findByClass(fleetOne, "pw-fleet-note")[0])) && !/1 projects/.test(textOf(fleetOne)) && findByClass(fleetOne, "pw-fleet-card").length === 1,
  "Fleet did not singularize the note / render one card for a single project");
win.PW_PROJECTS = [];
var fleetEmpty = new El("section");
win.PW_VIEWS.fleet(fleetEmpty, state, fullCtx);
assert(/No projects registered yet/.test(textOf(fleetEmpty)) && findByClass(fleetEmpty, "pw-fleet-card").length === 0,
  "Fleet did not render the empty state for zero projects");
win.PW_PROJECTS = savedPWP;

// Targeted (Phase 4.3): the Fleet per-card VALUES + sort order. #86 pins the grid structure;
// this pins what a swapped status->dot map, a pending/done transpose, or a broken sort would
// corrupt: each card's reactor-state dot class encodes its status, the counts line carries
// pending/done, the active project shows the "running" label, and the grid sorts active before
// stale (ties by name). fleet.js sort rank: active=0, idle/converged=1, stale=2.
var savedPWP2 = win.PW_PROJECTS;
win.PW_PROJECTS = [
  { id: "z", name: "zulu", path: "/r/zulu", status: "stale", counts: { pending: 0, done: 1 } },
  { id: "b", name: "bravo", path: "/r/bravo", status: "active", counts: { pending: 2, done: 5 } },
  { id: "c", name: "charlie", path: "/r/c", status: "converged", counts: { pending: 0, done: 9 } },
];
var flV = new El("section");
win.PW_VIEWS.fleet(flV, state, fullCtx);
var flVNames = findByClass(flV, "pw-fleet-name").map(function (n) { return textOf(n).trim(); });
assert(flVNames[0] === "bravo" && flVNames[flVNames.length - 1] === "zulu",
  "Fleet did not sort active before stale (got: " + flVNames.join(",") + ")");
[["bravo", "active", /2 pending/, /5 done/, "running"],
 ["zulu", "stale", /0 pending/, /1 done/, "stale"]].forEach(function (exp) {
  var card = findByClass(flV, "pw-fleet-card").filter(function (c) { return textOf(c).indexOf(exp[0]) >= 0; });
  assert(card.length === 1, "Fleet card for " + exp[0] + " not found");
  var dot = findByClass(card[0], "pw-fleet-dot");
  assert(dot.length === 1 && classOf(dot[0]).indexOf("pw-fleet-dot--" + exp[1]) >= 0,
    "Fleet card " + exp[0] + " dot did not encode status " + exp[1] + " (got: " + (dot[0] && classOf(dot[0])) + ")");
  var ctext = textOf(card[0]);
  assert(exp[2].test(ctext) && exp[3].test(ctext),
    "Fleet card " + exp[0] + " did not render its pending/done counts (got: " + ctext + ")");
  assert(ctext.indexOf(exp[4]) >= 0, "Fleet card " + exp[0] + " did not render status label '" + exp[4] + "'");
});
win.PW_PROJECTS = savedPWP2;

// Targeted (Phase 4.3): the Shards per-card frontier-heat + aggregate pulse content. The
// block-level shState graph sits at repo root, so its docs/scripts shards show 0 code nodes
// and the heat branch renders trivially. Build a shard-scoped graph (a never-audited code node
// under docs/, a clean one under scripts/) so the per-shard frontier chips + heat label and the
// aggregate-totals pulse chips render non-trivially.
var shGraph = JSON.stringify({ graph_built_at_sha: "deadbeef", frontier: { never_audited: 1, stale: 0 }, nodes: {
  "docs/guide.py": { git_churn: 3, pagerank: 0.5, covered_by_test: false, is_test: false, lang: "python", loc: 40, branch_count: 3, is_articulation: false, imports: [], audit_age_commits: null },
  "scripts/run.py": { git_churn: 1, pagerank: 0.2, covered_by_test: true, is_test: false, lang: "python", loc: 20, branch_count: 1, is_articulation: false, imports: [], audit_age_commits: 0 }
}, clusters: [], import_cycles: [] });
var shM = win.PW_DERIVE.metrics(shGraph);
var shRepo = { tracked_files: 50, shardable_dirs: ["docs", "scripts"], folded_dirs: ["misc"], large: false };
var shScopedCtx = { graphText: shGraph, metrics: shM, builtSha: "deadbeef", stale: false, head: "deadbeef" };
var shFull = new El("section");
win.PW_VIEWS.shards(shFull, Object.assign({}, state, { repo: shRepo }), shScopedCtx);
var shCards = findByClass(shFull, "pw-shard-card");
assert(shCards.length === 2, "shard grid did not render one card per shardable dir (got " + shCards.length + ")");
var docsChips = findByClass(shCards[0], "pw-shard-chip").map(textOf).map(function (s) { return s.trim(); });
assert(docsChips.indexOf("1 never-audited") >= 0 && docsChips.indexOf("0 stale") >= 0,
  "leading shard card lost its never-audited/stale frontier chips (got: " + JSON.stringify(docsChips) + ")");
assert(/1\/1 code nodes on the audit frontier/.test(textOf(shCards[0])),
  "leading shard card lost its frontier-heat label");
assert(/frontier clear/.test(textOf(shCards[1])), "clean shard card did not render the frontier-clear heat label");
var shScopedPulse = findByClass(shFull, "pw-coach-pulse-chip").map(textOf).map(function (s) { return s.trim(); });
assert(shScopedPulse.indexOf("2 shards") >= 0, "Shards pulse omitted the shard-count chip (got: " + JSON.stringify(shScopedPulse) + ")");
assert(shScopedPulse.indexOf("50 tracked files") >= 0, "Shards pulse omitted the tracked-files chip");
assert(shScopedPulse.indexOf("1 never-audited") >= 0 && shScopedPulse.indexOf("0 stale") >= 0,
  "Shards pulse omitted the aggregate frontier-total chips");
var shNoDir = new El("section");
win.PW_VIEWS.shards(shNoDir, Object.assign({}, state, { repo: { tracked_files: 5, shardable_dirs: [], folded_dirs: [], large: false } }), shScopedCtx);
assert(/No shardable top-level directory/.test(textOf(shNoDir)),
  "Shards view did not render the no-shardable-directory empty state when shardable_dirs is empty");

// graph view: otherwise only smoke-rendered in the VIEWS loop (no output asserted). Assert
// both branches — a graph-less ctx renders the NO_GRAPH empty state, and a populated ctx
// drives the PW_GRAPH.renderCoupling web. A regressed empty-state message, or a renamed
// metrics field that silently emptied the web, would fail here. Fresh containers sidestep
// the module-level memoize-on-bytes guard.
var gphEmpty = new El("section");
win.PW_VIEWS.graph(gphEmpty, state, bareCtx);
assert(/No graph has been built yet/.test(textOf(gphEmpty)) && findByClass(gphEmpty, "pw-empty").length === 1,
  "Graph view did not render the NO_GRAPH empty state on a graph-less snapshot");
var gphFull = new El("section");
win.PW_VIEWS.graph(gphFull, state, fullCtx);
assert(findByClass(gphFull, "pw-empty").length === 0 && findByClass(gphFull, "pw-web-svg").length >= 1,
  "Graph view did not drive the coupling web on a populated snapshot (fell into the empty state)");

// doctor view: fetch-based (not state-driven), so it sits outside the VIEWS render loop —
// load its file here (registers PW_VIEWS.doctor) and cover it explicitly: render() must show
// the sync placeholder immediately, and once the stubbed /doctor.json promise flushes,
// paint() must render the preflight rows (a renamed doctor.json field would break this).
vm.runInThisContext(fs.readFileSync(BASE + "/views/doctor.js", "utf8"));
assert(typeof win.PW_VIEWS.doctor === "function", "view doctor did not register render()");
var docC = new El("section");
win.PW_VIEWS.doctor(docC, state, fullCtx);
assert(textOf(docC).length > 0, "doctor render() produced no DOM synchronously");
// doctor on a bare (no metrics/graph) snapshot must also paint the sync placeholder without
// throwing. It stays OUT of the shared VIEWS loop on purpose: its single in-flight
// /doctor.json fetch + module-level state must bind to docC so the deferred paint assertion
// below sees the resolved rows — a throwaway loop container would steal that fetch.
var docBare = new El("section");
win.PW_VIEWS.doctor(docBare, state, bareCtx);
assert(docBare.children.length > 0, "doctor render() produced no DOM on a bare snapshot");

// Targeted: the Commands codmaster front-door panel — behavioral, not just grep-pinned.
// The panel element's class is exactly "pw-frontdoor"; the always-present slot is
// "pw-frontdoor-slot", so count exact matches only.
function frontDoorPanels(node) {
  return findByClass(node, "pw-frontdoor").filter(function (n) { return classOf(n) === "pw-frontdoor"; });
}
// Synchronously (no /recommend.json resolved yet) the panel must be absent, not erroring.
var cmdC = new El("section");
win.PW_VIEWS.commands(cmdC, state, fullCtx);
assert(frontDoorPanels(cmdC).length === 0, "front-door panel painted before any /recommend.json resolved");
// The contributions track record mirrors the Plan view's Commit provenance badge:
// the fixture's completed[].commit must surface in the rendered list text.
assert(/abc1234/.test(textOf(cmdC)),
  "Commands contributions list dropped the completed item's Commit provenance stamp");
assert(/rejected this run/.test(textOf(cmdC)),
  "Commands contributions card must keep its accepted/rejected sub-line");

// Targeted: the contributions card's Rejected tab (PW_UI.contribCard). The card carries two
// role="tab" buttons; "Recent contributions" is active by default (every assertion above reads
// the accepted body), and clicking "Rejected" swaps the body to the run's cut items, each with
// its recorded reason from state.rejected ([{title, reason}]). The fixture rejected log is
// [{title:"bad idea", reason:"value-gate: no consumer"}]. Driven on the DETAILED (Commands) card;
// the compact card shares the code path. Resets to the accepted tab at the end so the module-
// level activeTab does not leak into any later contrib render in this process.
function exactClass(node, cls) {
  return findByClass(node, cls).filter(function (n) { return classOf(n) === cls; });
}
function tabByLabel(tabs, label) {
  return tabs.filter(function (b) { return textOf(b).indexOf(label) >= 0; })[0];
}
var rtC = new El("section");
win.PW_VIEWS.commands(rtC, state, fullCtx);
var rtCard = findByClass(rtC, "pw-panel pw-contrib")[0];
assert(rtCard, "commands view did not render the contributions card");
var rtTabs = exactClass(rtCard, "pw-contrib-tab");
assert(rtTabs.length === 2, "contributions card did not render exactly two tabs (accepted + rejected)");
var acceptedTab = tabByLabel(rtTabs, "Recent contributions");
var rejectedTab = tabByLabel(rtTabs, "Rejected");
assert(acceptedTab && rejectedTab, "contributions card is missing the Recent-contributions or Rejected tab");
assert(acceptedTab.getAttribute("role") === "tab" && rejectedTab.getAttribute("role") === "tab",
  "contribution tabs must carry role=\"tab\"");
// The Rejected tab reads "Rejected" with no count badge (the count lives in the body / reactor).
assert(textOf(rejectedTab).indexOf("Rejected") >= 0 && !/\d/.test(textOf(rejectedTab)),
  "Rejected tab label must read 'Rejected' with no rejected-count badge");
// Default: accepted active, body shows the completed item and NOT the rejection reason.
assert(acceptedTab.getAttribute("aria-selected") === "true" && rejectedTab.getAttribute("aria-selected") === "false",
  "contributions card did not default to the accepted tab");
var rtBody = findByClass(rtCard, "pw-contrib-body")[0];
assert(rtBody, "contributions card has no swappable body region");
assert(/shipped/.test(textOf(rtBody)) && !/value-gate/.test(textOf(rtBody)),
  "default (accepted) tab body should show completed items, not rejected reasons");
// Click "Rejected": the body swaps to the cut item + its reason; active flags follow.
rejectedTab.click();
assert(rejectedTab.getAttribute("aria-selected") === "true" && acceptedTab.getAttribute("aria-selected") === "false",
  "clicking the Rejected tab did not move aria-selected onto it");
assert(rejectedTab.classList.contains("is-active") && !acceptedTab.classList.contains("is-active"),
  "clicking the Rejected tab did not move the is-active class onto it");
var rtRejText = textOf(findByClass(rtCard, "pw-contrib-body")[0]);
assert(/bad idea/.test(rtRejText) && /value-gate: no consumer/.test(rtRejText),
  "Rejected tab body did not render the rejected item's title and recorded reason");
assert(!/shipped/.test(rtRejText), "Rejected tab body still showed the accepted item after the swap");
assert(exactClass(findByClass(rtCard, "pw-contrib-body")[0], "pw-contrib-item is-rejected").length === 1,
  "Rejected tab body did not render exactly one rejected item row");
// Persistence: app.js rebuilds the card on every SSE tick, so a fresh render must keep the user
// on the Rejected tab (the choice lives in a module var, not in throwaway DOM).
var rtC2 = new El("section");
win.PW_VIEWS.commands(rtC2, state, fullCtx);
var rtCard2 = findByClass(rtC2, "pw-panel pw-contrib")[0];
assert(tabByLabel(exactClass(rtCard2, "pw-contrib-tab"), "Rejected").getAttribute("aria-selected") === "true",
  "the Rejected tab selection did not persist across a re-render");
assert(/value-gate: no consumer/.test(textOf(findByClass(rtCard2, "pw-contrib-body")[0])),
  "the re-rendered card did not stay on the Rejected tab's body");
// Empty rejected log: the Rejected tab shows a 'nothing rejected' empty state.
var noRejState = Object.assign({}, state, { rejected: [], counts: Object.assign({}, state.counts, { rejected: 0 }) });
var rtC3 = new El("section");
win.PW_VIEWS.commands(rtC3, noRejState, fullCtx);
var rtCard3 = findByClass(rtC3, "pw-panel pw-contrib")[0];
var rejTab3 = tabByLabel(exactClass(rtCard3, "pw-contrib-tab"), "Rejected");
rejTab3.click();   // no-op if the persisted tab is already 'rejected'; either way the body is rejected
assert(/Nothing rejected/.test(textOf(findByClass(rtCard3, "pw-contrib-body")[0])),
  "an empty rejected log did not render the 'nothing rejected' empty state");
// ARIA tab/panel association: each tab points at the panel via aria-controls, the panel carries
// that id, and aria-labelledby tracks the active tab (rtCard3 is currently on the Rejected tab).
var rtPanel = findByClass(rtCard3, "pw-contrib-body")[0];
var rtTabs3b = exactClass(rtCard3, "pw-contrib-tab");
assert(!!rtPanel.getAttribute("id") &&
       rtTabs3b.every(function (b) { return b.getAttribute("aria-controls") === rtPanel.getAttribute("id"); }),
  "every tab must reference the panel via aria-controls and the panel must carry that id");
assert(rtPanel.getAttribute("aria-labelledby") === tabByLabel(rtTabs3b, "Rejected").getAttribute("id"),
  "the tabpanel's aria-labelledby must track the active (Rejected) tab");

// Arrow-key roving (ui.js keydown handler). The harness auto-dispatches click only, so fire
// keydown by hand against the tablist. ArrowRight moves accepted->rejected and wraps back;
// ArrowLeft wraps the other way.
function fireKey(el, k) {
  ((el && el._ev && el._ev.keydown) || []).forEach(function (fn) { fn.call(el, { key: k, preventDefault: function () {} }); });
}
var akC = new El("section");
win.PW_VIEWS.commands(akC, state, fullCtx);
var akCard = findByClass(akC, "pw-panel pw-contrib")[0];
var akTabs = exactClass(akCard, "pw-contrib-tab");
var akTablist = findByClass(akCard, "pw-contrib-tabs").filter(function (n) { return classOf(n) === "pw-contrib-tabs"; })[0];
tabByLabel(akTabs, "Recent contributions").click();   // a prior block may have left the module var on rejected
assert(tabByLabel(akTabs, "Recent contributions").getAttribute("aria-selected") === "true", "arrow-key fixture did not start on accepted");
fireKey(akTablist, "ArrowRight");
assert(tabByLabel(akTabs, "Rejected").getAttribute("aria-selected") === "true",
  "ArrowRight did not move the active tab accepted->rejected");
fireKey(akTablist, "ArrowRight");
assert(tabByLabel(akTabs, "Recent contributions").getAttribute("aria-selected") === "true",
  "ArrowRight did not wrap rejected->accepted");
fireKey(akTablist, "ArrowLeft");
assert(tabByLabel(akTabs, "Rejected").getAttribute("aria-selected") === "true",
  "ArrowLeft did not wrap accepted->rejected");

// Compact (Console rail) tab interaction: the same code path must swap there too and stay minimal
// (no sub-line / foot) even on the Rejected tab.
var cpC = new El("section");
win.PW_VIEWS.console(cpC, state, fullCtx);
var cpCard = findByClass(cpC, "pw-panel pw-contrib")[0];
var cpTabs = exactClass(cpCard, "pw-contrib-tab");
tabByLabel(cpTabs, "Rejected").click();
assert(/bad idea/.test(textOf(findByClass(cpCard, "pw-contrib-body")[0])), "compact Rejected tab did not render the rejected item");
assert(findByClass(cpCard, "pw-panel-sub").length === 0 && findByClass(cpCard, "pw-panel-foot").length === 0,
  "compact Rejected tab must stay minimal (no sub-line / foot)");
tabByLabel(cpTabs, "Recent contributions").click();   // restore the compact module var

// Rejected-item edge data: a missing title falls back to "(untitled)", an empty reason renders no
// reason span (and a present reason exposes its full text via the title attr), and a >8 log shows
// the "showing the 8 most recent of N rejected" foot on the detailed card.
var manyRej = [];
for (var mri = 0; mri < 9; mri++) { manyRej.push({ title: "rej " + mri, reason: "reason " + mri }); }
manyRej.push({ title: "", reason: "" });   // untitled + reasonless, last so it survives slice(-8)
var edgeState = Object.assign({}, state, { rejected: manyRej, counts: Object.assign({}, state.counts, { rejected: manyRej.length }) });
var edgeC = new El("section");
win.PW_VIEWS.commands(edgeC, edgeState, fullCtx);
var edgeCard = findByClass(edgeC, "pw-panel pw-contrib")[0];
tabByLabel(exactClass(edgeCard, "pw-contrib-tab"), "Rejected").click();
var edgeBody = findByClass(edgeCard, "pw-contrib-body")[0];
assert(/\(untitled\)/.test(textOf(edgeBody)), "a rejected item with no title did not fall back to (untitled)");
var edgeFoot = findByClass(edgeCard, "pw-panel-foot");
assert(edgeFoot.length === 1 && /8 most recent of 10 rejected/.test(textOf(edgeFoot[0])),
  "the detailed Rejected tab did not show the 'showing the 8 most recent of N rejected' foot past 8 items");
var edgeRows = exactClass(edgeBody, "pw-contrib-item is-rejected");
var untitledRow = edgeRows.filter(function (li) { return /\(untitled\)/.test(textOf(li)); })[0];
assert(untitledRow && findByClass(untitledRow, "pw-contrib-reason").length === 0,
  "a rejected item with an empty reason must render no reason span");
var reasonRow = edgeRows.filter(function (li) { return /rej 8/.test(textOf(li)); })[0];
var reasonSpan = reasonRow && findByClass(reasonRow, "pw-contrib-reason")[0];
assert(reasonSpan && reasonSpan.title === "reason 8",
  "a rejected reason span must expose the full reason via its title (tooltip) for truncated text");

// Reset the shared activeTab back to the accepted default so later contrib renders are unaffected.
tabByLabel(exactClass(rtCard3, "pw-contrib-tab"), "Recent contributions").click();
var rtReset = new El("section");
win.PW_VIEWS.commands(rtReset, state, fullCtx);
assert(tabByLabel(exactClass(findByClass(rtReset, "pw-panel pw-contrib")[0], "pw-contrib-tab"), "Recent contributions")
  .getAttribute("aria-selected") === "true",
  "failed to reset the contributions card back to the accepted tab");

// Targeted regression (load order): in the real browser ui.js (index.html loads it before the
// views) creates window.PW_UI WITHOUT planMode, so plan.js must seed the "all" default itself
// instead of assuming it is the object's creator. This harness pre-seeds win.PW_UI.planMode="all"
// (the `win` literal above), which MASKS the bug — so reset to the genuine first-load state and
// re-run the two files in index.html order, then assert the Plan view's DEFAULT render (no user
// interaction, no prior planMode) lists pending items rather than hiding them as "mode 'undefined'".
(function () {
  var savedPW_UI = win.PW_UI;
  win.PW_UI = undefined;                                                 // fresh page: nobody made PW_UI yet
  vm.runInThisContext(fs.readFileSync(BASE + "/ui.js", "utf8"));         // ui.js loads first ...
  vm.runInThisContext(fs.readFileSync(BASE + "/views/plan.js", "utf8")); // ... then plan.js seeds the default
  assert(win.PW_UI.planMode === "all",
    "plan.js must seed PW_UI.planMode='all' even when ui.js created window.PW_UI first (got " +
    String(win.PW_UI.planMode) + ")");
  var defState = Object.assign({}, state, {
    pending: [{ title: "load-order item", mode: "repair", rationale: "r", evidence: "e",
                surfaces: ["x"], new_surfaces: [], development: "d", acceptance: "a",
                verification: "bash tests/run.sh" }],
    completed: [], rejected: [],
  });
  var planDef = new El("section");
  win.PW_VIEWS.plan(planDef, defState, bareCtx);
  assert(findByClass(planDef, "pw-card").length === 1,
    "Plan default render hid the pending item (planMode left undefined by ui.js/plan.js load order)");
  assert(!/mode 'undefined'/.test(textOf(planDef)),
    "Plan default render showed \"mode 'undefined'\" — plan.js did not seed the planMode default");
  win.PW_UI = savedPW_UI;                                                // restore for the deferred tests below
})();

setTimeout(function () {
  assert(/Environment preflight/.test(textOf(docC)),
    "doctor paint() did not render the preflight after /doctor.json resolved");

  // Phase 4.4: pin the Doctor view's actual render, not just the heading, so a regression in
  // doctor.js's verdict/badge/row painting fails CI. The stubbed /doctor.json (fetch above) is
  // {total:5, warn:1, fail:0, checks:[git=ok, rg=warn]} — a warn-but-runnable preflight.
  var docText = textOf(docC);
  var docVerdict = findByClass(docC, "pw-doc-verdict");
  assert(docVerdict.length === 1 && /is-warn/.test(classOf(docVerdict[0])) &&
         /runnable/.test(textOf(docVerdict[0])) && /warnings/.test(textOf(docVerdict[0])),
    "Doctor view verdict did not render is-warn 'runnable · warnings' for a warn>0/fail==0 payload");
  assert(/5 checks/.test(docText) && /1 warn/.test(docText) && /0 fail/.test(docText),
    "Doctor view sub-line did not render the 5 checks / 1 warn / 0 fail tally (got: " + docText + ")");
  var docRows = findByClass(docC, "pw-doc-row");
  assert(docRows.length === 2,
    "Doctor view did not render one row per check (expected 2, got " + docRows.length + ")");
  var docNames = findByClass(docC, "pw-doc-name").map(textOf);
  assert(docNames.indexOf("git") >= 0 && docNames.indexOf("rg") >= 0,
    "Doctor view rows dropped a check name (got: " + JSON.stringify(docNames) + ")");
  var docBadges = findByClass(docC, "pw-doc-badge").map(textOf);
  assert(docBadges.indexOf("OK") >= 0 && docBadges.indexOf("WARN") >= 0,
    "Doctor view badges did not render OK/WARN (got: " + JSON.stringify(docBadges) + ")");
  assert(/degrades: slower Stage 1 scan/.test(docText),
    "Doctor view did not render the per-check degrades line for a non-ok check");

  // The initial WRONG-shaped /recommend.json body (REC_BODY above) has resolved by now;
  // the recUsable guard must have rejected it — still no panel on a fresh render.
  var cmdBad = new El("section");
  win.PW_VIEWS.commands(cmdBad, state, fullCtx);
  assert(frontDoorPanels(cmdBad).length === 0,
    "a wrong-shaped /recommend.json body was painted as a front-door panel");

  // Swap in a usable dispatcher record and let a render fetch + cache it.
  REC_BODY = {
    base: { key: "codvisor", why: "structural debt" },
    command: "codshard", args: "explore",
    why: "repo large — harden work routes to codshard",
    mutating: true, invent_class: false, follow_up: null,
    notes: ["coach: codvisor — routed to codshard"],
    blockers: [{ kind: "dirty-tree", detail: "uncommitted paths: x.py" }],
    evidence: ["3 import cycles"], reset_nudge: null, signals: {}, repo: {},
  };
  var cmdSeed = new El("section");
  win.PW_VIEWS.commands(cmdSeed, state, fullCtx);

  setTimeout(function () {
    var cmdOk = new El("section");
    win.PW_VIEWS.commands(cmdOk, state, fullCtx);   // paints synchronously from the cached record
    var fd = frontDoorPanels(cmdOk);
    assert(fd.length === 1, "front-door panel did not paint from a usable /recommend.json record");
    var fdText = textOf(fd[0]);
    assert(/codmaster front door/.test(fdText), "front-door panel kicker missing");
    assert(/codshard/.test(fdText) && /explore/.test(fdText), "front-door panel does not show the dispatch command + args");
    assert(/mutating/.test(fdText), "front-door panel omitted the mutating flag chip");
    assert(/blocked: uncommitted paths/.test(fdText), "front-door panel omitted the dirty-tree blocker");
    assert(/3 import cycles/.test(fdText), "front-door panel omitted the evidence chips");
    assert(/\/planwright:codshard explore/.test(fdText), "front-door invocation did not map codshard+explore to its helper command");
    // Phase 1.3: the record's notes[] render as front-door notes (the slot/blockers/evidence are
    // pinned above, the notes list was not). The usable record carries notes:["coach: codvisor …"].
    assert(/coach: codvisor/.test(fdText), "front-door panel omitted the record's notes list");

    // The kicker is beacon-aware: while state.activity carries a live (fresh) beacon
    // the heading reads "run in progress" with the Console beacon's running-command
    // line, and a label above the pick re-frames it as the dispatch once the run
    // settles; with no beacon — or a stale one (a dead run must not re-frame the
    // panel as live) — the heading stays "next dispatch" with no running line.
    function kickerOf(panel) { return textOf(findByClass(panel, "pw-coach-kicker")[0]); }
    assert(/next dispatch/.test(kickerOf(fd[0])), "beacon-less front-door kicker lost its next-dispatch heading");
    assert(!/run in progress/.test(fdText), "beacon-less front-door panel rendered the run-in-progress framing");
    var cmdLive = new El("section");
    win.PW_VIEWS.commands(cmdLive, Object.assign({}, state, {
      activity: { command: "codmaster", detail: "step 3/12: execute", started: "2026-06-12T18:42:00Z", age_seconds: 30, stale: false },
    }), fullCtx);
    var fdLive = frontDoorPanels(cmdLive);
    assert(fdLive.length === 1, "front-door panel missing on a live-beacon render");
    var liveKicker = kickerOf(fdLive[0]);
    assert(/run in progress/.test(liveKicker) && !/next dispatch/.test(liveKicker),
      "front-door kicker did not flip to run-in-progress on a live beacon");
    var liveText = textOf(fdLive[0]);
    assert(/codmaster — step 3\/12: execute/.test(liveText), "live front-door panel omitted the running-command line");
    assert(/next dispatch once this run settles/.test(liveText), "live front-door panel lost the next-dispatch label above the pick");
    var cmdStale = new El("section");
    win.PW_VIEWS.commands(cmdStale, Object.assign({}, state, {
      activity: { command: "codmaster", detail: null, started: "2026-06-12T08:00:00Z", age_seconds: 7200, stale: true },
    }), fullCtx);
    var fdStale = frontDoorPanels(cmdStale);
    assert(fdStale.length === 1, "front-door panel missing on a stale-beacon render");
    assert(/next dispatch/.test(kickerOf(fdStale[0])), "a stale beacon re-framed the front-door heading as a live run");
    assert(!/run in progress/.test(textOf(fdStale[0])), "a stale beacon rendered the run-in-progress framing");

    // Enforce overlay (791a00f parity): at a converged invent-dry recommendation the engine
    // routes to a non-growth move (reset/codvisor, invent_class false), but a default codmaster
    // drive enforces a codinventor burst there, so the panel must disclose it (mirroring the CLI
    // advise notice) WITHOUT dropping the engine pick; and it must NOT disclose it when the engine
    // already recommends growth (invent_class true) — there is no divergence then.
    REC_BODY = {
      base: { key: "codvisor", why: "converged at the invent-dry point" },
      command: "codvisor", args: "cycle 10 depth 10 explore",
      why: "converged at the invent-dry point, but the cold frontier is undrained — harden",
      mutating: true, invent_class: false, follow_up: null,
      notes: [], blockers: [], evidence: ["0 import cycles"], reset_nudge: null,
      signals: { converged: true }, repo: {},
    };
    var cmdConvSeed = new El("section");
    win.PW_VIEWS.commands(cmdConvSeed, state, fullCtx);   // trigger a fresh fetch of the new record
    setTimeout(function () {
      var cmdConv = new El("section");
      win.PW_VIEWS.commands(cmdConv, state, fullCtx);
      var fdConv = frontDoorPanels(cmdConv);
      assert(fdConv.length === 1, "front-door panel missing on a converged invent-dry record");
      var convText = textOf(fdConv[0]);
      assert(/enforced codinventor burst/.test(convText),
        "converged invent-dry front-door panel omitted the default-drive enforced-growth disclosure (791a00f parity)");
      assert(/codvisor/.test(convText),
        "enforce note must not drop the engine pick (engine truth stays the primary render)");

      REC_BODY = {
        base: { key: "codinventor", why: "converged — grow" },
        command: "codinventor", args: "cycle 10 depth 10 invent",
        why: "converged at a current final point — grow", mutating: true,
        invent_class: true, follow_up: null, notes: [], blockers: [],
        evidence: [], reset_nudge: null, signals: { converged: true }, repo: {},
      };
      var cmdGrowSeed = new El("section");
      win.PW_VIEWS.commands(cmdGrowSeed, state, fullCtx);
      setTimeout(function () {
        var cmdGrow = new El("section");
        win.PW_VIEWS.commands(cmdGrow, state, fullCtx);
        assert(!/enforced codinventor burst/.test(textOf(frontDoorPanels(cmdGrow)[0])),
          "enforce overlay wrongly shown when the engine already recommends growth (invent_class true)");
        // Phase 1.3: an invent_class:true record renders the "invent-class (`safe` stops here)"
        // safe chip (the mutating chip is pinned above, this one was not).
        assert(/invent-class/.test(textOf(frontDoorPanels(cmdGrow)[0])),
          "front-door panel omitted the invent-class safe chip on an invent_class:true record");
        console.log("VIEWS-FN-OK");
      }, 0);
    }, 0);
  }, 0);
}, 0);
JS
  if node "$TMP/views_fn_test.js" "$ROOT/scripts/dashboard" >"$TMP/views_fn.out" 2>"$TMP/views_fn.err" \
     && grep -q VIEWS-FN-OK "$TMP/views_fn.out"; then
    ok "dashboard render() runs for all nine views (incl. fleet/shards/doctor/graph/timeline) on full + graph-less snapshots (no throw, non-empty DOM)"
  else
    bad "a dashboard view render() failed: $(cat "$TMP/views_fn.err" 2>/dev/null)"
  fi
else
  ok "dashboard view render() check skipped (node not installed)"
fi

# --- Test DASH-FLEET-CLICK: clicking a Fleet card switches to that project's id --------
# fleet.js wires each card's click to window.PW_SWITCH_PROJECT(p.id) (the app.js bridge that
# switches the whole dashboard view-state). DASH-VIEWS-FN asserts the grid STRUCTURE but never
# dispatches a click, so a regression in the handler's argument (p.path instead of p.id, or the
# wrong card) would ship green. The shared El shim's addEventListener/click are no-ops, so this
# block upgrades the prototype LOCALLY to record + dispatch click handlers, then asserts the
# stub received the clicked card's exact id once (and that a missing bridge does not throw).
if command -v node >/dev/null 2>&1; then
  cat > "$TMP/fleet_click.js" <<'JS'
const BASE = process.argv[2];
const VM = require(BASE + "/../../tests/cases/lib/dashboard-vm.js");
const { El, makeDoc, makeWin, install, loadCommon, loadView, makeFixture, findByClass } = VM;
const assert = require("assert");
// Upgrade the shim El (addEventListener/click are no-ops by default) to record + dispatch.
El.prototype.addEventListener = function (type, fn) {
  this._lis = this._lis || {}; (this._lis[type] = this._lis[type] || []).push(fn);
};
El.prototype.click = function () {
  ((this._lis && this._lis.click) || []).forEach(function (fn) { fn.call(this, { type: "click" }); }, this);
};
const doc = makeDoc(); const win = makeWin(doc);
install(win, doc);
loadCommon(BASE);
loadView(BASE, "fleet");
const { state, fullCtx } = makeFixture();
win.PW_PROJECTS = [
  { id: "p1", name: "alpha", path: "/repos/alpha", status: "active", counts: { pending: 4, done: 7 } },
  { id: "p2", name: "beta", path: "/repos/beta", status: "converged", counts: { pending: 0, done: 3 } },
];
const calls = [];
win.PW_SWITCH_PROJECT = function (id) { calls.push(id); };
const c = new El("section");
win.PW_VIEWS.fleet(c, state, fullCtx);
const cards = findByClass(c, "pw-fleet-card");
assert(cards.length === 2, "expected two cards, got " + cards.length);
// Identify a specific card by its title (p.path) so the assertion is sort-order-independent.
const alpha = cards.filter(function (x) { return x.title === "/repos/alpha"; })[0];
assert(alpha, "alpha card not found");
alpha.click();
assert.deepStrictEqual(calls, ["p1"],
  "click must call PW_SWITCH_PROJECT with the card's p.id exactly once, got " + JSON.stringify(calls));
// A missing bridge must not throw (fleet.js guards `if (window.PW_SWITCH_PROJECT)`).
delete win.PW_SWITCH_PROJECT;
const c2 = new El("section");
win.PW_VIEWS.fleet(c2, state, fullCtx);
findByClass(c2, "pw-fleet-card")[0].click();
console.log("FLEET-CLICK-OK");
JS
  if node "$TMP/fleet_click.js" "$ROOT/scripts/dashboard" >"$TMP/fleet_click.out" 2>"$TMP/fleet_click.err" \
     && grep -q FLEET-CLICK-OK "$TMP/fleet_click.out"; then
    ok "dashboard fleet card click calls PW_SWITCH_PROJECT with the card's p.id (and no-ops without the bridge)"
  else
    bad "dashboard fleet card click body wrong: $(cat "$TMP/fleet_click.err" 2>/dev/null)"
  fi
else
  ok "dashboard fleet card click check skipped (node not installed)"
fi

# --- Test DASH-SHARDS-COPY: a Shards card copy button writes its single-shard invocation -
# shards.js invoke() renders a pw-cmd-copy button whose click writes the single-shard
# codshard invocation via navigator.clipboard.writeText. DASH-CMD-COPY covers the SAME
# affordance in commands.js, never the shards-rendered button — so a regression in the shards
# copy text (or the no-clipboard guard) ships green. Render the populated shard map, click the
# docs shard's copy button, assert the exact invocation was written; the no-clipboard branch
# is a silent no-op.
if command -v node >/dev/null 2>&1; then
  cat > "$TMP/shards_copy_test.js" <<'JS'
const assert = require("assert");
const BASE = process.argv[2];
const VM = require(BASE + "/../../tests/cases/lib/dashboard-vm.js");
const { El, makeDoc, makeWin, install, loadCommon, loadView, makeFixture, findByClass, textOf } = VM;
El.prototype.addEventListener = function (type, fn) { this._ev = this._ev || {}; (this._ev[type] = this._ev[type] || []).push(fn); };
El.prototype.click = function () { var fns = (this._ev && this._ev.click) || []; for (var i = 0; i < fns.length; i++) { fns[i].call(this, { type: "click" }); } };
const doc = makeDoc(); const win = makeWin(doc);
install(win, doc);
loadCommon(BASE);
loadView(BASE, "shards");
const fx = makeFixture();
const shState = Object.assign({}, fx.state, {
  repo: { tracked_files: 240, shardable_dirs: ["docs", "scripts"], folded_dirs: ["misc"], large: true },
});
// (1) clipboard stub: clicking the docs shard's copy writes its exact single-shard invocation.
var copied = [];
Object.defineProperty(globalThis, "navigator",
  { value: { clipboard: { writeText: function (s) { copied.push(s); return Promise.resolve(); } } }, configurable: true, writable: true });
var sC = new El("section");
win.PW_VIEWS.shards(sC, shState, fx.fullCtx);
var docsWrap = findByClass(sC, "pw-cmd-invoke").filter(function (w) {
  return textOf(findByClass(w, "pw-cmd-code")[0]).trim() === "/planwright:codshard shards docs";
})[0];
assert(docsWrap, "shards view did not render the docs single-shard invocation");
findByClass(docsWrap, "pw-cmd-copy")[0].click();
assert(copied.length === 1 && copied[0] === "/planwright:codshard shards docs",
  "shards copy did not writeText the single-shard invocation (wrote " + JSON.stringify(copied) + ")");
// (2) no-clipboard fallback: a click must not throw when navigator.clipboard is absent.
Object.defineProperty(globalThis, "navigator", { value: {}, configurable: true, writable: true });
var sD = new El("section");
win.PW_VIEWS.shards(sD, shState, fx.fullCtx);
findByClass(sD, "pw-cmd-copy")[0].click();   // must not throw
console.log("SHARDS-COPY-OK");
JS
  if node "$TMP/shards_copy_test.js" "$ROOT/scripts/dashboard" >"$TMP/shards_copy.out" 2>"$TMP/shards_copy.err" \
     && grep -q SHARDS-COPY-OK "$TMP/shards_copy.out"; then
    ok "dashboard shards card copy button writes its single-shard codshard invocation (and no-ops without a clipboard API)"
  else
    bad "dashboard shards copy-button assertion failed: $(cat "$TMP/shards_copy.err" 2>/dev/null)"
  fi
else
  ok "dashboard shards copy-button check skipped (node not installed)"
fi

# --- Test DASH-CONSOLE-DEGRADED: console degraded fallbacks render specific output ------
# DASH-VIEWS-FN renders console on bareCtx but only pins the vitals no-graph note (the
# pulserail "graph not built yet" + sessionTrend empty are pinned separately, so they are not
# restated here). Two console degraded fallbacks were still smoke-only: the Dirty Pulse rail's
# empty branch (metrics present, nothing changed) and the recent-contributions card's
# completed-empty fallback. Pin each to its specific text so a broken fallback fails instead
# of rendering wrong. ("Nothing rejected" is already asserted elsewhere — not restated.)
if command -v node >/dev/null 2>&1; then
  cat > "$TMP/console_degraded.js" <<'JS'
const assert = require("assert");
const BASE = process.argv[2];
const VM = require(BASE + "/../../tests/cases/lib/dashboard-vm.js");
const { El, makeDoc, makeWin, install, loadCommon, loadView, makeFixture, textOf } = VM;
const doc = makeDoc(); const win = makeWin(doc);
install(win, doc);
loadCommon(BASE);
loadView(BASE, "console");
const fx = makeFixture();
// (1) Dirty Pulse empty branch: fullCtx metrics carry an empty dirtyChanged, so the rail must
// render "nothing changed since last build" (not a file list) on an unchanged tree.
var c1 = new El("section");
win.PW_VIEWS.console(c1, fx.state, fx.fullCtx);
assert(/nothing changed since last build/.test(textOf(c1)),
  "console pulserail did not render the empty-dirty fallback on an unchanged tree");
// (2) Recent-contributions completed-empty fallback: a state with no completed items must
// render the "Nothing completed yet" empty branch of the contributions card.
var emptyState = Object.assign({}, fx.state, { completed: [] });
var c2 = new El("section");
win.PW_VIEWS.console(c2, emptyState, fx.fullCtx);
assert(/Nothing completed yet/.test(textOf(c2)),
  "console recent-contributions did not render the completed-empty fallback");
console.log("CONSOLE-DEGRADED-OK");
JS
  if node "$TMP/console_degraded.js" "$ROOT/scripts/dashboard" >"$TMP/console_degraded.out" 2>"$TMP/console_degraded.err" \
     && grep -q CONSOLE-DEGRADED-OK "$TMP/console_degraded.out"; then
    ok "dashboard console renders its empty-dirty-pulse and completed-empty contributions fallbacks with specific text"
  else
    bad "dashboard console degraded-fallback assertion failed: $(cat "$TMP/console_degraded.err" 2>/dev/null)"
  fi
else
  ok "dashboard console degraded-fallback check skipped (node not installed)"
fi

# --- Test DASH-PLAN-DEGRADED: the Plan view's empty/degraded plan-card fallbacks --------
# plan.js renders three empty-list fallbacks (No pending items. / Nothing completed yet. /
# Nothing rejected.) plus a mode-filtered empty ("No pending items in mode 'X'.") — all
# smoke-only today. The crossLinks no-metrics branch is already pinned elsewhere, so it is
# explicitly out of scope here. Render on bareCtx (null metrics) and assert each fallback's
# exact text branch-by-branch.
if command -v node >/dev/null 2>&1; then
  cat > "$TMP/plan_degraded.js" <<'JS'
const assert = require("assert");
const BASE = process.argv[2];
const VM = require(BASE + "/../../tests/cases/lib/dashboard-vm.js");
const { El, makeDoc, makeWin, install, loadCommon, loadView, makeFixture, textOf } = VM;
const doc = makeDoc(); const win = makeWin(doc);
install(win, doc);
loadCommon(BASE);
loadView(BASE, "plan");
const fx = makeFixture();
// (1) Fully drained state on bareCtx: all three empty-list fallbacks render their exact text.
win.PW_UI.planMode = "all";
var empty = Object.assign({}, fx.state, { pending: [], completed: [], rejected: [], pending_modes: {} });
var c1 = new El("section");
win.PW_VIEWS.plan(c1, empty, fx.bareCtx);
var t1 = textOf(c1);
assert(/No pending items\./.test(t1), "plan view did not render the empty-pending fallback");
assert(/Nothing completed yet\./.test(t1), "plan view did not render the empty-completed fallback");
assert(/Nothing rejected\./.test(t1), "plan view did not render the empty-rejected fallback");
// (2) Mode-filtered empty: a develop-only plan filtered to 'repair' yields the mode-scoped note.
win.PW_UI.planMode = "repair";
var devOnly = Object.assign({}, fx.state, {
  pending: [{ title: "a develop item", mode: "develop", rationale: "r", evidence: "e",
    surfaces: ["a.py"], new_surfaces: [], development: "d", acceptance: "ok", verification: "bash tests/run.sh" }],
  completed: [], rejected: [], pending_modes: { develop: 1 },
});
var c2 = new El("section");
win.PW_VIEWS.plan(c2, devOnly, fx.bareCtx);
assert(/No pending items in mode 'repair'\./.test(textOf(c2)),
  "plan view did not render the mode-filtered empty note");
console.log("PLAN-DEGRADED-OK");
JS
  if node "$TMP/plan_degraded.js" "$ROOT/scripts/dashboard" >"$TMP/plan_degraded.out" 2>"$TMP/plan_degraded.err" \
     && grep -q PLAN-DEGRADED-OK "$TMP/plan_degraded.out"; then
    ok "dashboard plan view renders its empty pending/completed/rejected and mode-filtered fallbacks with specific text"
  else
    bad "dashboard plan degraded-fallback assertion failed: $(cat "$TMP/plan_degraded.err" 2>/dev/null)"
  fi
else
  ok "dashboard plan degraded-fallback check skipped (node not installed)"
fi

# --- Test DASH-COV-MAP-MODULES: the coverage map's module set matches views/ on disk ----
# docs/dashboard-js-coverage-map.md inventories every view module, but no test references it,
# so it can silently drift from reality (a new view added, or one removed/renamed). Pin the
# set: the modules the map documents (its `### [X.js](../scripts/dashboard/views/X.js)` headers)
# must equal the set of scripts/dashboard/views/*.js files on disk. Pure stdlib — no node.
if python3 - "$ROOT/docs/dashboard-js-coverage-map.md" "$ROOT/scripts/dashboard/views" <<'PY' 2>/dev/null
import os, re, sys
mapdoc = open(sys.argv[1], encoding="utf-8").read()
viewsdir = sys.argv[2]
documented = set(re.findall(r"^### \[([A-Za-z0-9_-]+\.js)\]\(\.\./scripts/dashboard/views/\1\)", mapdoc, re.M))
on_disk = {f for f in os.listdir(viewsdir) if f.endswith(".js")}
assert documented, "no view modules parsed from the coverage map"
assert documented == on_disk, ("map<->disk drift, symmetric diff: " + repr(sorted(documented ^ on_disk)))
PY
then ok "coverage map's view-module set matches scripts/dashboard/views/*.js on disk (fails on drift)"; else bad "coverage map's documented view-module set drifted from scripts/dashboard/views/*.js"; fi

# --- Test DASH-COV-MAP-ANCHORS: the coverage map's credited harness anchors/bootstrap exist
# The coverage map credits specific harness anchors (DASH-VIEWS-FN, DASH-INSIGHTS-RENDER, the
# click/degraded blocks, DASH-FN) and the shared bootstrap (tests/cases/lib/dashboard-vm.js).
# Nothing gates them, so renaming a credited block leaves the map silently false. Pin it: every
# DASH-* anchor the map names must exist as a `Test <anchor>` block in dashboard.sh, and the
# credited bootstrap path must exist on disk. Pure stdlib — no node.
if python3 - "$ROOT/docs/dashboard-js-coverage-map.md" "$ROOT/tests/cases/dashboard.sh" "$ROOT/tests/cases/lib/dashboard-vm.js" <<'PY' 2>/dev/null
import os, re, sys
mapdoc = open(sys.argv[1], encoding="utf-8").read()
harness = open(sys.argv[2], encoding="utf-8").read()
bootstrap = sys.argv[3]
anchors = sorted(set(re.findall(r"DASH-[A-Z0-9-]+", mapdoc)))
assert anchors, "no DASH-* anchors parsed from the coverage map"
missing = [a for a in anchors if not re.search(r"Test %s[: ]" % re.escape(a), harness)]
assert not missing, "map credits anchors with no Test block in dashboard.sh: " + repr(missing)
assert "tests/cases/lib/dashboard-vm.js" in mapdoc, "map no longer credits the shared bootstrap"
assert os.path.isfile(bootstrap), "credited bootstrap path missing: " + bootstrap
PY
then ok "coverage map's credited harness anchors all resolve to Test blocks and the bootstrap path exists (fails on rename)"; else bad "coverage map credits a harness anchor or bootstrap that no longer exists"; fi

# --- Test DASH-JS-FLOOR-LOCKSTEP: the JS coverage floor is identical across CI/gate/doc -
# The JS --fail-under floor lives in three surfaces (ci.yml's "JS coverage" step, this file's
# DASH-JS-COV-PCT gate, and docs/js-coverage-floor.md) and the CI comment claims "lockstep" —
# but nothing enforces it, so a one-surface raise drifts silently. Guarded-parse each (a
# missing/unparseable pattern fails loudly, per the Test 10c precedent) and assert all agree.
if python3 - "$ROOT/.github/workflows/ci.yml" "$ROOT/tests/cases/dashboard.sh" "$ROOT/docs/js-coverage-floor.md" <<'PY' 2>/dev/null
import re, sys
ci = open(sys.argv[1], encoding="utf-8").read()
gate = open(sys.argv[2], encoding="utf-8").read()
doc = open(sys.argv[3], encoding="utf-8").read()
def grab(pat, text, label):
    m = re.search(pat, text)
    assert m, "JS floor not parseable in " + label
    return int(m.group(1))
floors = {
    "ci.yml": grab(r"js-coverage-report\.py[^\n]*--fail-under\s+(\d+)", ci, "ci.yml"),
    "gate":   grab(r"rc_floor=0;[^\n]*--fail-under\s+(\d+)", gate, "DASH-JS-COV-PCT gate"),
    "doc":    grab(r"Committed floor:\*\*\s*\*\*(\d+)%", doc, "js-coverage-floor.md"),
}
assert len(set(floors.values())) == 1, "JS floor drift: " + repr(floors)
PY
then ok "JS coverage floor (--fail-under) is identical across ci.yml, the DASH-JS-COV-PCT gate, and the doc"; else bad "JS coverage floor drifted across ci.yml / gate / doc (or a parse pattern broke)"; fi

# --- Test DASH-PY-FLOOR-LOCKSTEP: the Python coverage floor is identical across CI/cfg/doc -
# Sibling of the JS floor lockstep: the Python coverage --fail-under floor is a three-way
# literal (ci.yml's `coverage report --fail-under=90`, .coveragerc's `fail_under = 90`, and
# the doc's reference) with no cross-check, so a one-surface bump drifts silently. Guarded-parse
# each (a missing/unparseable pattern fails loudly) and assert all three agree.
if python3 - "$ROOT/.github/workflows/ci.yml" "$ROOT/.coveragerc" "$ROOT/docs/js-coverage-floor.md" <<'PY' 2>/dev/null
import re, sys
ci = open(sys.argv[1], encoding="utf-8").read()
rc = open(sys.argv[2], encoding="utf-8").read()
doc = open(sys.argv[3], encoding="utf-8").read()
def grab(pat, text, label):
    m = re.search(pat, text)
    assert m, "Python floor not parseable in " + label
    return int(m.group(1))
floors = {
    "ci.yml":     grab(r"coverage report\s+--fail-under=(\d+)", ci, "ci.yml"),
    "coveragerc": grab(r"(?m)^\s*fail_under\s*=\s*(\d+)", rc, ".coveragerc"),
    "doc":        grab(r"coverage report\s+--fail-under=(\d+)", doc, "js-coverage-floor.md"),
}
assert len(set(floors.values())) == 1, "Python floor drift: " + repr(floors)
PY
then ok "Python coverage floor (--fail-under) is identical across ci.yml, .coveragerc, and the doc"; else bad "Python coverage floor drifted across ci.yml / .coveragerc / doc (or a parse pattern broke)"; fi

# --- Test DASH-JS-COVERAGE: the node-gated view-load path emits V8 coverage --------
# Phase 1.4 prerequisite for a CI JS coverage floor (the Python --fail-under=90 analog).
# Run the shared view loader under NODE_V8_COVERAGE and assert a coverage JSON keyed to a
# real scripts/dashboard/**/*.js path lands in a temp dir. No new framework — Node built-ins
# (vm/fs) + NODE_V8_COVERAGE only (the loader passes an absolute vm filename so V8 attributes
# coverage to the real source path, not an anonymous URL). Skips cleanly when node is absent.
if command -v node >/dev/null 2>&1; then
  cat > "$TMP/js_cov_load.js" <<'JS'
const BASE = process.argv[2];
const VM = require(BASE + "/../../tests/cases/lib/dashboard-vm.js");
const { makeDoc, makeWin, install, loadCommon, loadViews, makeFixture } = VM;
const doc = makeDoc(); const win = makeWin(doc);
win.fetch = function () { return Promise.resolve({ ok: true, json: function () { return Promise.resolve({ total: 0, checks: [] }); } }); };
install(win, doc);
loadCommon(BASE);
loadViews(BASE, ["console", "plan", "commands", "insights", "shards", "timeline", "graph", "fleet"]);
const { state, fullCtx } = makeFixture();
["console", "plan", "commands", "insights", "shards", "timeline", "graph", "fleet"].forEach(function (v) {
  win.PW_VIEWS[v](new (VM.El)("section"), state, fullCtx);
});
console.log("JS-COV-LOAD-OK");
JS
  COVDIR="$TMP/js_v8_cov"
  mkdir -p "$COVDIR"
  if NODE_V8_COVERAGE="$COVDIR" node "$TMP/js_cov_load.js" "$ROOT/scripts/dashboard" >"$TMP/js_cov.out" 2>"$TMP/js_cov.err" \
     && grep -q JS-COV-LOAD-OK "$TMP/js_cov.out" \
     && node -e '
       const fs=require("fs"); const dir=process.argv[1]; let hit=false;
       for (const f of fs.readdirSync(dir)) {
         const d=JSON.parse(fs.readFileSync(dir+"/"+f,"utf8"));
         for (const s of (d.result||[])) { if (/scripts\/dashboard\/.*\.js/.test(s.url||"")) { hit=true; } }
       }
       process.exit(hit?0:1);
     ' "$COVDIR"; then
    ok "node-gated view-load path emits V8 coverage keyed to scripts/dashboard/*.js under NODE_V8_COVERAGE"
  else
    bad "NODE_V8_COVERAGE produced no scripts/dashboard coverage from the view-load path: $(cat "$TMP/js_cov.err" 2>/dev/null)"
  fi
else
  ok "dashboard JS V8-coverage emission check skipped (node not installed)"
fi

# --- Test DASH-JS-COV-PCT: js-coverage-report.py reduces V8 coverage to a deterministic % --
# Phase 1.4: run the committed coverage collector under NODE_V8_COVERAGE, then reduce it with
# the reporter. Assert a deterministic percentage line, that re-running yields the identical
# number (so a CI floor can gate it), and that --fail-under exits non-zero below / zero above.
# This pins the reporter behaviorally — its own Verification (check-links) is a false green.
# No new framework: Node built-ins + the stdlib reporter.
if command -v node >/dev/null 2>&1; then
  PCTDIR="$TMP/js_cov_pct"; mkdir -p "$PCTDIR"
  if NODE_V8_COVERAGE="$PCTDIR" node "$ROOT/tests/cases/lib/dashboard-coverage-load.js" "$ROOT/scripts/dashboard" \
       >"$TMP/js_cov_pct.out" 2>"$TMP/js_cov_pct.err" \
     && grep -q COV-LOAD-OK "$TMP/js_cov_pct.out"; then
    rep1="$(python3 "$ROOT/scripts/js-coverage-report.py" "$PCTDIR" --root "$ROOT")"
    rep2="$(python3 "$ROOT/scripts/js-coverage-report.py" "$PCTDIR" --root "$ROOT")"
    rc_hi=0; python3 "$ROOT/scripts/js-coverage-report.py" "$PCTDIR" --root "$ROOT" --fail-under 100 >/dev/null 2>&1 || rc_hi=$?
    rc_lo=0; python3 "$ROOT/scripts/js-coverage-report.py" "$PCTDIR" --root "$ROOT" --fail-under 1 >/dev/null 2>&1 || rc_lo=$?
    # Committed floor: the 71% floor (CI --fail-under 71, docs/js-coverage-floor.md) must
    # pass on the current tree, so a coverage drop below it fails the suite locally too, not only CI.
    rc_floor=0; python3 "$ROOT/scripts/js-coverage-report.py" "$PCTDIR" --root "$ROOT" --fail-under 71 >/dev/null 2>&1 || rc_floor=$?
    if printf '%s' "$rep1" | grep -qE 'JS coverage \(scripts/dashboard\): [0-9]+\.[0-9]+%' \
       && [ "$rep1" = "$rep2" ] && [ "$rc_hi" = "2" ] && [ "$rc_lo" = "0" ] && [ "$rc_floor" = "0" ]; then
      ok "js-coverage-report.py reduces V8 coverage to one deterministic % over the 71% floor (--fail-under gates correctly)"
    else
      bad "js-coverage-report.py % non-deterministic, below the 71% floor, or --fail-under mis-gated (hi=$rc_hi lo=$rc_lo floor=$rc_floor): '$rep1' vs '$rep2'"
    fi
  else
    bad "JS coverage collector failed: $(cat "$TMP/js_cov_pct.err" 2>/dev/null)"
  fi
else
  ok "JS coverage % reporter check skipped (node not installed)"
fi

# --- Test DASH-JS-COV-ERR: the reporter exits 1 (not 0/2) when no coverage files exist ---------
# Pins the documented exit-code contract (1 on a usage/IO error: no coverage-*.json files),
# distinct from the --fail-under breach (exit 2). A pure stdlib error path — no node needed, so it
# runs unconditionally; a regression collapsing it into exit 0/2 would mask a broken collector.
JSCOV_EMPTY="$TMP/js_cov_empty"; mkdir -p "$JSCOV_EMPTY"
rc_jcerr=0; jcerr="$(python3 "$ROOT/scripts/js-coverage-report.py" "$JSCOV_EMPTY" --root "$ROOT" 2>&1 >/dev/null)" || rc_jcerr=$?
if [ "$rc_jcerr" = "1" ] && printf '%s' "$jcerr" | grep -qi "no coverage"; then
  ok "js-coverage-report.py exits 1 with a clear message when the coverage dir has no coverage-*.json files"
else
  bad "js-coverage-report.py no-files exit-1 contract regressed (rc=$rc_jcerr msg='$jcerr')"
fi

# --- Test DASH-INSIGHTS-RENDER: the Insights view's render OUTPUT (not just registration) ----
# The views block above asserts only "insights rendered something" (children.length>0). This pins
# the actionable content: given an uncovered articulation hotspot (hot.py), insights.render() must
# surface that file in the Risk Ledger, render the "Coverage by language" panel, and show the
# uncovered flag. (An independent QB audit found the views were registration-smoke-tested, not
# output-asserted — console/timeline get deep output checks above, insights did not.) Node-gated
# with a clean skip, like derive.sh; no npm/network.
if command -v node >/dev/null 2>&1; then
  cat > "$TMP/insights_render_test.js" <<'JS'
const assert = require("assert");
const BASE = process.argv[2];
// Reuse the shared vm-bootstrap (El/document/window stubs + script loader) instead of a
// second copy of the DOM shim. BASE is .../scripts/dashboard.
const VM = require(BASE + "/../../tests/cases/lib/dashboard-vm.js");
const { El, makeDoc, makeWin, install, loadScript, findByClass } = VM;
// Capture event handlers so the ledger filter input is drivable from the harness:
// el.dispatch(type) fires the stored listeners (storing alone is inert; only an explicit
// dispatch runs them, so a plain render is never perturbed).
El.prototype.addEventListener = function (type, fn) { this._ev = this._ev || {}; (this._ev[type] = this._ev[type] || []).push(fn); };
El.prototype.dispatch = function (type, props) { var ev = Object.assign({ type: type, preventDefault: function () {}, stopPropagation: function () {} }, props || {}); var fns = (this._ev && this._ev[type]) || []; for (var i = 0; i < fns.length; i++) { fns[i].call(this, ev); } };
const doc = makeDoc();
const win = makeWin(doc);
install(win, doc);
loadScript(BASE, "vendor/derive.js");
loadScript(BASE, "views/insights.js");
assert(typeof win.PW_VIEWS.insights==="function","insights view did not register render()");
const graphText=JSON.stringify({ graph_built_at_sha:"deadbeef", frontier:{never_audited:1,stale:1},
  nodes:{ "hot.py":{git_churn:10,pagerank:0.9,covered_by_test:false,is_test:false,lang:"python",loc:100,branch_count:5,is_articulation:true,imports:["cold.py"]},
          "cold.py":{git_churn:1,pagerank:0.1,covered_by_test:true,is_test:false,lang:"python",loc:10,branch_count:1,is_articulation:false,imports:[]} },
  coupling_edges:[], clusters:[{label:"core",members:["hot.py","cold.py"]}], import_cycles:[] });
const metrics=win.PW_DERIVE.metrics(graphText);
assert(metrics && metrics.hotspots && metrics.hotspots.length===2, "fixture metrics built (2 hotspots)");
const ctx={ graphText:graphText, metrics:metrics, builtSha:"deadbeef", stale:false, head:"deadbeef" };
const root=new El("section");
win.PW_VIEWS.insights(root, { counts:{} }, ctx);
function textOf(n){ var t=n.textContent||""; (n.children||[]).forEach(function(c){ t+=" "+textOf(c); }); return t; }
const out=textOf(root);
assert(root.children.length>0, "insights rendered nothing on a full snapshot");
assert(/hot\.py/.test(out), "Risk Ledger did not surface the uncovered hotspot hot.py");
assert(/uncovered/.test(out), "insights did not surface the uncovered coverage flag");
assert(/Coverage by language/.test(out), "insights did not render the by-language Coverage panel");
// Phase 1.3: the Coverage-by-language rows order languages by UNCOVERED count (total - cov)
// descending — the assertion above only proves the panel renders. Build a multi-language graph
// (python uncov 2, shell uncov 1, javascript uncov 0) and assert the pw-cov-lang labels render
// in uncovered-descending order so a reversed sort predicate fails.
var multiGraph = JSON.stringify({ graph_built_at_sha: "deadbeef", nodes: {
  "a.py": { lang: "python", branch_count: 2, covered_by_test: false, is_test: false, loc: 50, imports: [] },
  "b.py": { lang: "python", branch_count: 2, covered_by_test: false, is_test: false, loc: 50, imports: [] },
  "c.py": { lang: "python", branch_count: 2, covered_by_test: true, is_test: false, loc: 50, imports: [] },
  "d.js": { lang: "javascript", branch_count: 2, covered_by_test: true, is_test: false, loc: 50, imports: [] },
  "e.js": { lang: "javascript", branch_count: 2, covered_by_test: true, is_test: false, loc: 50, imports: [] },
  "f.sh": { lang: "shell", branch_count: 2, covered_by_test: false, is_test: false, loc: 50, imports: [] }
}, clusters: [], import_cycles: [] });
var mMulti = win.PW_DERIVE.metrics(multiGraph);
var multiRoot = new El("section");
win.PW_VIEWS.insights(multiRoot, { counts: {} },
  { graphText: multiGraph, metrics: mMulti, builtSha: "deadbeef", stale: false, head: "deadbeef" });
var langOrder = findByClass(multiRoot, "pw-cov-lang").map(textOf).map(function (s) { return s.trim(); });
assert(JSON.stringify(langOrder) === JSON.stringify(["python", "shell", "javascript"]),
  "Coverage-by-language not ordered by uncovered-descending (want python, shell, javascript; got " + langOrder.join(",") + ")");
// Phase 1.3: the Risk-Ledger path filter narrows metrics.hotspots and shows a (filtered)
// affordance; an empty query shows all rows. The render assertions above never drive the input.
// The fixture has 2 hotspots (hot.py, cold.py); a "hot" query keeps only hot.py.
var ledgerRoot = new El("section");
win.PW_VIEWS.insights(ledgerRoot, { counts: {} }, ctx);
var fInput = findByClass(ledgerRoot, "pw-ledger-filter")[0];
var fCount = findByClass(ledgerRoot, "pw-ledger-count")[0];
assert(fInput && fCount, "Risk-Ledger filter input/count did not render");
// The "showing N of M" count reflects metrics.hotspots.filter(query); a "(filtered)" suffix is the
// non-empty-query affordance. (The DOM row count is unreliable here: the shim's textContent='' does
// not clear children like the real DOM, so paint() accumulates rows across re-paints — the count is
// the faithful signal of the filter predicate.)
assert(/showing 2 of 2/.test(fCount.textContent) && !/\(filtered\)/.test(fCount.textContent),
  "Risk-Ledger initial count wrong (want 'showing 2 of 2', no filtered; got '" + fCount.textContent + "')");
fInput.value = "hot";
fInput.dispatch("input");
assert(/showing 1 of 2 \(filtered\)/.test(fCount.textContent),
  "Risk-Ledger filter did not narrow metrics.hotspots to 1 of 2 with the (filtered) affordance (got '" + fCount.textContent + "')");
fInput.value = "nomatchxyz";
fInput.dispatch("input");
assert(/showing 0 of 2 \(filtered\)/.test(fCount.textContent),
  "Risk-Ledger filter did not narrow to 0 of 2 on a non-matching query (got '" + fCount.textContent + "')");
fInput.value = "";
fInput.dispatch("input");
assert(/showing 2 of 2/.test(fCount.textContent) && !/\(filtered\)/.test(fCount.textContent),
  "Risk-Ledger did not restore all rows (and drop the filtered affordance) on an empty query (got '" + fCount.textContent + "')");
// Phase 2.2: degraded snapshot (no metrics) renders the specific "No graph has been built yet"
// empty-state — not a half-built grid — upgrading the bare-ctx branch from no-throw smoke to
// behavior-asserted.
var bareRoot = new El("section");
win.PW_VIEWS.insights(bareRoot, { counts:{} }, { graphText:null, metrics:null, builtSha:"", stale:false, head:"deadbeef" });
assert(/No graph has been built yet\. Run a plan to build/.test(textOf(bareRoot)),
  "insights bare-ctx did not render the 'no graph built yet' empty-state");
assert(findByClass(bareRoot, "pw-insights-grid").length === 0,
  "insights bare-ctx wrongly rendered the insights grid on null metrics");
// Phase 5.3: the Risk-Ledger j/k/Arrow keyboard handler moves row focus; a non-navigation key
// early-returns with no change. Wire the minimal DOM the handler reads (querySelectorAll-by-class
// + focus()->document.activeElement), render a fresh ledger, focus row 0, then drive keydown. (Patches
// applied here, AFTER the render assertions above, so only this keyboard render sees them.)
El.prototype.querySelectorAll = function (sel) { return findByClass(this, sel.replace(/^\./, "")); };
El.prototype.focus = function () { global.document.activeElement = this; };
var kbRoot = new El("section");
win.PW_VIEWS.insights(kbRoot, { counts: {} }, ctx);
var kbList = findByClass(kbRoot, "pw-ledger-list")[0];
var kbRows = findByClass(kbRoot, "pw-ledger-row");
assert(kbList && kbRows.length === 2, "keyboard-nav fixture: a ledger list + 2 rows expected");
kbRows[0].focus();
assert(doc.activeElement === kbRows[0], "focus() did not set activeElement to row 0");
kbList.dispatch("keydown", { key: "j" });
assert(doc.activeElement === kbRows[1], "j did not move row focus down to row 1");
kbList.dispatch("keydown", { key: "ArrowUp" });
assert(doc.activeElement === kbRows[0], "ArrowUp did not move row focus back up to row 0");
kbList.dispatch("keydown", { key: "x" });   // non-navigation key: early return, no focus change
assert(doc.activeElement === kbRows[0], "a non-navigation key wrongly changed row focus");

// Phase 5.3: priorities() renders the empty-state when no ranked surfaces (the base fixture graph
// carries no ranked_code/ranked), and the hot/uncovered/articulation/in-cycle flags on a ranked
// fixture (hot.py is ranked, uncovered, an articulation point, and in an import cycle -> all four).
var noRankRoot = new El("section");
win.PW_VIEWS.insights(noRankRoot, { counts: {} }, ctx);
assert(/No ranked surfaces recorded yet/.test(textOf(noRankRoot)),
  "priorities did not render the empty-state on an unranked fixture");
var rankGraph = JSON.stringify({
  graph_built_at_sha: "deadbeef",
  ranked_code: ["hot.py"],
  nodes: {
    "hot.py": { git_churn: 10, pagerank: 0.9, covered_by_test: false, is_test: false, lang: "python", loc: 100, branch_count: 5, is_articulation: true, imports: ["cold.py"] },
    "cold.py": { git_churn: 1, pagerank: 0.1, covered_by_test: true, is_test: false, lang: "python", loc: 10, branch_count: 1, is_articulation: false, imports: ["hot.py"] },
  },
  import_cycles: [["hot.py", "cold.py"]],
});
var mRank = win.PW_DERIVE.metrics(rankGraph);
var rankRoot = new El("section");
win.PW_VIEWS.insights(rankRoot, { counts: {} }, { graphText: rankGraph, metrics: mRank, builtSha: "deadbeef", stale: false, head: "deadbeef" });
var prioFlagText = findByClass(rankRoot, "pw-prio-flag").map(textOf).join(" ");
assert(/hot/.test(prioFlagText), "priorities omitted the hot flag for a hot ranked node");
assert(/uncovered/.test(prioFlagText), "priorities omitted the uncovered flag");
assert(/articulation/.test(prioFlagText), "priorities omitted the articulation flag");
assert(/in cycle/.test(prioFlagText), "priorities omitted the in-cycle flag for a cyclic node");
// Phase 2.2: priorities() renders the top-N in rankedCode order (a passthrough of the planner's
// centrality ranking — no local sort). The flag/empty assertions above use a single-element
// ranked_code, so ORDER is unpinned; a multi-surface, non-alphabetical fixture pins it so a
// reorder/reverse of the rendered list fails.
var orderGraph = JSON.stringify({
  graph_built_at_sha: "deadbeef",
  ranked_code: ["z/first.py", "a/second.py", "m/third.py"],
  nodes: {
    "z/first.py":  { pagerank: 0.9, branch_count: 3, lang: "python", loc: 30, covered_by_test: false, is_test: false, git_churn: 3, imports: [] },
    "a/second.py": { pagerank: 0.5, branch_count: 2, lang: "python", loc: 20, covered_by_test: true,  is_test: false, git_churn: 2, imports: [] },
    "m/third.py":  { pagerank: 0.1, branch_count: 1, lang: "python", loc: 10, covered_by_test: true,  is_test: false, git_churn: 1, imports: [] },
  },
  import_cycles: [],
});
var mOrder = win.PW_DERIVE.metrics(orderGraph);
var orderRoot = new El("section");
win.PW_VIEWS.insights(orderRoot, { counts: {} }, { graphText: orderGraph, metrics: mOrder, builtSha: "deadbeef", stale: false, head: "deadbeef" });
var prioBasenames = findByClass(orderRoot, "pw-prio-name").map(textOf).map(function (s) { return s.trim().replace(/\s+/g, " "); });
assert(prioBasenames.length === 3 && /first\.py$/.test(prioBasenames[0]) && /second\.py$/.test(prioBasenames[1]) && /third\.py$/.test(prioBasenames[2]),
  "priorities did not render the top-N in rankedCode order (want first, second, third; got " + prioBasenames.join(" | ") + ")");

// Phase 5.3: coldFrontier() renders the Invent-framing note when metrics.exploreFraming, the
// framing/frontier-aware empty variant when no cold list, and the uncovered/test flags on cold rows.
var framingEmptyGraph = JSON.stringify({
  graph_built_at_sha: "deadbeef", explore_framing: "power-user", explore_seed: 3,
  frontier: { never_audited: 2, stale: 1 },
  nodes: { "a.py": { branch_count: 1, pagerank: 0.5, lang: "python", loc: 5, covered_by_test: true, is_test: false, git_churn: 1, imports: [] } },
  import_cycles: [],
});
var mFrEmpty = win.PW_DERIVE.metrics(framingEmptyGraph);
var frEmptyRoot = new El("section");
win.PW_VIEWS.insights(frEmptyRoot, { counts: {} }, { graphText: framingEmptyGraph, metrics: mFrEmpty, builtSha: "deadbeef", stale: false, head: "deadbeef" });
var frEmptyText = textOf(frEmptyRoot);
assert(/Invent framing: power-user/.test(frEmptyText), "cold frontier did not surface the explore-framing note");
assert(/No cold-frontier list recorded yet/.test(frEmptyText), "cold frontier did not render the empty variant");
// Phase 2.2: the framing chip carries the seed, and the frontier-backlog sub-line (the dryness
// denominator the capped 8-row list hides) renders from metrics.frontier on the empty branch too.
// (The framing note + empty text above were already pinned; these two branches were not.)
assert(/Invent framing: power-user \(seed 3\)/.test(frEmptyText), "cold frontier framing chip dropped the (seed N) qualifier");
assert(/Backlog: 2 never-audited, 1 stale/.test(frEmptyText), "cold frontier did not render the frontier-backlog sub-line from metrics.frontier");
var coldGraph = JSON.stringify({
  graph_built_at_sha: "deadbeef", ranked_cold: ["src.py", "t_spec.py"],
  nodes: {
    "src.py": { branch_count: 2, pagerank: 0.4, lang: "python", loc: 20, covered_by_test: false, is_test: false, git_churn: 2, imports: [] },
    "t_spec.py": { branch_count: 1, pagerank: 0.1, lang: "python", loc: 8, covered_by_test: false, is_test: true, git_churn: 1, imports: [] },
  },
  import_cycles: [],
});
var mCold = win.PW_DERIVE.metrics(coldGraph);
var coldRoot = new El("section");
win.PW_VIEWS.insights(coldRoot, { counts: {} }, { graphText: coldGraph, metrics: mCold, builtSha: "deadbeef", stale: false, head: "deadbeef" });
var coldFlagText = findByClass(coldRoot, "pw-prio-flag").map(textOf).join(" ");
assert(/uncovered/.test(coldFlagText), "cold frontier omitted the uncovered flag for an uncovered non-test node");
assert(/test/.test(coldFlagText), "cold frontier omitted the test flag for a test node");

// Phase 5.3: constellation() plots one dot per node (pw-scatter-dot), and the nodeCount>50 guard
// caps the scatter to the 50 highest-risk dots plus a truncation foot. The base fixture (2 nodes)
// plots 2 dots with no foot; a 60-node graph plots 50 dots + the "showing the 50 ... of 60" foot.
var bigNodes = {};
for (var bi = 0; bi < 60; bi++) {
  bigNodes["f" + bi + ".py"] = { git_churn: bi + 1, pagerank: (bi + 1) / 100, covered_by_test: bi % 2 === 0, is_test: false, lang: "python", loc: 10 + bi, branch_count: 1, is_articulation: false, imports: [] };
}
var bigGraph = JSON.stringify({ graph_built_at_sha: "deadbeef", nodes: bigNodes, import_cycles: [] });
var mBig = win.PW_DERIVE.metrics(bigGraph);
assert(mBig.nodeCount === 60, "fixture sanity: 60-node graph");
var bigRoot = new El("section");
win.PW_VIEWS.insights(bigRoot, { counts: {} }, { graphText: bigGraph, metrics: mBig, builtSha: "deadbeef", stale: false, head: "deadbeef" });
assert(findByClass(bigRoot, "pw-scatter-dot").length === 50,
  "constellation did not cap the scatter to the 50 highest-risk dots on a >50-node graph");
assert(/showing the 50 highest-risk of 60 files/.test(textOf(bigRoot)),
  "constellation did not render the >50-node truncation foot");
var smallRoot = new El("section");
win.PW_VIEWS.insights(smallRoot, { counts: {} }, ctx);
assert(findByClass(smallRoot, "pw-scatter-dot").length === 2,
  "constellation did not plot one dot per node on the 2-node fixture");
assert(!/showing the 50 highest-risk/.test(textOf(smallRoot)),
  "constellation wrongly rendered the truncation foot on a 2-node graph");

// Phase 5.3: coverage() renders the uncovered gap (pw-cov-gap hatch) on a partially-covered language
// and omits it on a fully-covered one; cycles()/cycleArc() render one cycle card per import cycle (and
// the acyclic empty-state otherwise).
var covRoot = new El("section");
win.PW_VIEWS.insights(covRoot, { counts: {} }, ctx);  // base fixture: python is 1/2 covered, acyclic
assert(findByClass(covRoot, "pw-cov-lang").length >= 1, "coverage panel did not render a by-language row");
assert(findByClass(covRoot, "pw-cov-gap").length >= 1,
  "coverage panel did not render the uncovered gap for a partially-covered language");
assert(/No import cycles/.test(textOf(covRoot)), "cycles() did not render the acyclic empty-state");
var coveredGraph = JSON.stringify({ graph_built_at_sha: "deadbeef", nodes: {
  "a.py": { lang: "python", branch_count: 1, covered_by_test: true, is_test: false, loc: 5, pagerank: 0.5, git_churn: 1, imports: [] },
}, import_cycles: [] });
var mCovered = win.PW_DERIVE.metrics(coveredGraph);
var coveredRoot = new El("section");
win.PW_VIEWS.insights(coveredRoot, { counts: {} }, { graphText: coveredGraph, metrics: mCovered, builtSha: "deadbeef", stale: false, head: "deadbeef" });
assert(findByClass(coveredRoot, "pw-cov-gap").length === 0,
  "coverage panel wrongly rendered an uncovered gap on a fully-covered graph");
var twoCycleGraph = JSON.stringify({ graph_built_at_sha: "deadbeef", nodes: {
  "a.py": { lang: "python", branch_count: 1, covered_by_test: true, is_test: false, loc: 5, pagerank: 0.5, git_churn: 1, imports: ["b.py"] },
  "b.py": { lang: "python", branch_count: 1, covered_by_test: true, is_test: false, loc: 5, pagerank: 0.5, git_churn: 1, imports: ["a.py"] },
  "c.py": { lang: "python", branch_count: 1, covered_by_test: true, is_test: false, loc: 5, pagerank: 0.5, git_churn: 1, imports: ["d.py"] },
  "d.py": { lang: "python", branch_count: 1, covered_by_test: true, is_test: false, loc: 5, pagerank: 0.5, git_churn: 1, imports: ["c.py"] },
}, import_cycles: [["a.py", "b.py"], ["c.py", "d.py"]] });
var mTwoCycle = win.PW_DERIVE.metrics(twoCycleGraph);
var cycleRoot = new El("section");
win.PW_VIEWS.insights(cycleRoot, { counts: {} }, { graphText: twoCycleGraph, metrics: mTwoCycle, builtSha: "deadbeef", stale: false, head: "deadbeef" });
assert(findByClass(cycleRoot, "pw-cycle-card").length === 2,
  "cycles() did not render one cycle card per import cycle (want 2)");
// Phase 2.2: each card lists its member files as chips (pw-cycle-chip); the card-count above never
// inspects the members. Pin the chip count (one per cycle member) and a member's path so a dropped
// or mislabeled member chip fails.
var cycChips = findByClass(cycleRoot, "pw-cycle-chip").map(textOf).map(function (s) { return s.trim(); });
assert(cycChips.length === 4,
  "cycles() did not render one chip per cycle member (want 4 across two 2-node cycles, got " + cycChips.length + ")");
assert(cycChips.some(function (s) { return /a\.py$/.test(s); }) && cycChips.some(function (s) { return /d\.py$/.test(s); }),
  "cycles() member chips did not render the cycle's file paths (got " + cycChips.join(", ") + ")");
console.log("INSIGHTS-RENDER-OK");
JS
  if node "$TMP/insights_render_test.js" "$ROOT/scripts/dashboard" >"$TMP/insights_render.out" 2>"$TMP/insights_render.err" \
     && grep -q INSIGHTS-RENDER-OK "$TMP/insights_render.out"; then
    ok "dashboard Insights view render OUTPUT asserts the hotspot Risk-Ledger row + by-language Coverage panel + uncovered flag (not just registration)"
  else
    bad "dashboard Insights render-output assertion failed: $(cat "$TMP/insights_render.err" 2>/dev/null)"
  fi
else
  ok "dashboard Insights render-output check skipped (node not installed)"
fi

# --- Test DASH-TIMELINE-ROWS: the accepted/rejected decision rows (mode badge + reason inline) ------
# timeline.render() lists one row per completed (pw-dot accepted + the mode pw-badge) and per rejected
# (pw-dot rejected + pw-reason-inline). The Decision-timeline GRAPH is pinned by DASH-VIEWS-FN above;
# the ROW list was smoke-only. Node-gated, clean skip without node.
if command -v node >/dev/null 2>&1; then
  cat > "$TMP/timeline_rows_test.js" <<'JS'
const assert = require("assert");
const BASE = process.argv[2];
const VM = require(BASE + "/../../tests/cases/lib/dashboard-vm.js");
const { El, makeDoc, makeWin, install, loadCommon, loadView, findByClass, classOf, textOf } = VM;
const doc = makeDoc(); const win = makeWin(doc);
install(win, doc);
loadCommon(BASE);
loadView(BASE, "timeline");
var longReason = "x".repeat(120);
var state = {
  completed: [{ title: "added widget", mode: "develop" }, { title: "fixed bug", mode: "repair" }],
  rejected: [{ title: "dropped idea", reason: longReason }, { title: "short one", reason: "too small" }],
  final_point: null,
};
var root = new El("section");
win.PW_VIEWS.timeline(root, state, {});
var dots = findByClass(root, "pw-dot");
var accepted = dots.filter(function (d) { return /\baccepted\b/.test(classOf(d)); });
var rejectedDots = dots.filter(function (d) { return /\brejected\b/.test(classOf(d)); });
assert(accepted.length === 2, "timeline did not render one accepted row per completed item (want 2, got " + accepted.length + ")");
assert(rejectedDots.length === 2, "timeline did not render one rejected row per rejected item (want 2, got " + rejectedDots.length + ")");
var badges = findByClass(root, "pw-badge").map(textOf).map(function (s) { return s.trim(); });
assert(badges.indexOf("develop") >= 0 && badges.indexOf("repair") >= 0,
  "accepted rows did not carry the mode pw-badge (got: " + badges.join(", ") + ")");
assert(findByClass(root, "pw-reason-inline").length === 2,
  "rejected rows did not carry the pw-reason-inline reason");
// Phase 2.4: the rejected-reason truncation predicate (reason.length > 80 -> slice(0,77)+"…").
// The 120-char reason above must render truncated to 77 chars + the ellipsis (length 78); the
// short "too small" reason must render whole. Flipping the threshold fails this.
var reasons = findByClass(root, "pw-reason-inline").map(textOf);
var truncated = reasons.filter(function (r) { return /…$/.test(r); });
assert(truncated.length === 1, "rejected-reason truncation branch not exercised (want exactly 1 …-terminated reason)");
assert(truncated[0].length === 78, "truncated reason is not 77 chars + the ellipsis (got length " + truncated[0].length + ")");
assert(reasons.indexOf("too small") >= 0, "a short rejected reason (<=80 chars) was wrongly truncated");
// Phase 2.4: the fully-empty branch — no completed AND no rejected -> "No history yet." with no
// graph and no rows. The base fixtures always carry items, so this branch was unexercised.
var emptyRoot = new El("section");
win.PW_VIEWS.timeline(emptyRoot, { completed: [], rejected: [], final_point: null }, {});
assert(/No history yet\./.test(textOf(emptyRoot)), "timeline did not render the fully-empty 'No history yet.' branch");
assert(findByClass(emptyRoot, "pw-dot").length === 0, "fully-empty timeline wrongly rendered decision rows");
console.log("TIMELINE-ROWS-OK");
JS
  if node "$TMP/timeline_rows_test.js" "$ROOT/scripts/dashboard" >"$TMP/timeline_rows.out" 2>"$TMP/timeline_rows.err" \
     && grep -q TIMELINE-ROWS-OK "$TMP/timeline_rows.out"; then
    ok "timeline.js decision rows: accepted rows carry the mode pw-badge, rejected rows carry the pw-reason-inline"
  else
    bad "timeline.js decision-rows assertion failed: $(cat "$TMP/timeline_rows.err" 2>/dev/null)"
  fi
else
  ok "timeline.js decision-rows check skipped (node not installed)"
fi

# --- Test DASH-ACT-SIG: the beacon's TTL crossing changes the /events signature ------
# The activity beacon's stale flip happens by TTL, not by a file write — an interrupted
# run leaves activity.json untouched, so without a derived bit in _mtime_signature the
# one scenario the stale flag exists for would never fire an SSE change event and an
# open dashboard would keep pulsing "live" over a dead run. Pin the bit: with the SAME
# file and SAME mtime, signatures must differ purely on the TTL verdict, and only the
# activity.json entry carries the extra element.
DAS="$TMP/dash-act-sig"; mkdir -p "$DAS/.planwright"
python3 "$ROOT/scripts/state.py" activity start codmaster --root "$DAS" >/dev/null
printf -- '- [ ] x\n      Mode: repair\n' > "$DAS/.planwright/plan.md"
if python3 - "$ROOT" "$DAS" <<'PY' 2>/dev/null
import importlib.util, os, sys
root, fixture = sys.argv[1], sys.argv[2]
scripts = os.path.join(root, "scripts")
sys.path.insert(0, scripts)
spec = importlib.util.spec_from_file_location("pw_dashboard", os.path.join(scripts, "dashboard.py"))
dash = importlib.util.module_from_spec(spec)
spec.loader.exec_module(dash)
# age the beacon 2h with an explicit utime so both signature reads see ONE mtime;
# only the env TTL differs between them — any signature difference is the derived bit
beacon = os.path.join(fixture, ".planwright", "activity.json")
st = os.stat(beacon)
os.utime(beacon, (st.st_mtime - 7200, st.st_mtime - 7200))
os.environ["PW_ACTIVITY_TTL"] = "999999"
sig_live = dash._mtime_signature(fixture)
os.environ["PW_ACTIVITY_TTL"] = "60"
sig_dead = dash._mtime_signature(fixture)
del os.environ["PW_ACTIVITY_TTL"]
assert sig_live != sig_dead, "TTL crossing did not change the signature (no SSE change would fire)"
live_entry = [e for e in sig_live if e[0] == "activity.json"][0]
dead_entry = [e for e in sig_dead if e[0] == "activity.json"][0]
assert len(live_entry) == 4 and live_entry[3] is False, live_entry
assert len(dead_entry) == 4 and dead_entry[3] is True, dead_entry
plan_entry = [e for e in sig_live if e[0] == "plan.md"][0]
assert len(plan_entry) == 3, plan_entry  # only the beacon carries the derived bit
PY
then
  ok "dashboard _mtime_signature folds the beacon's TTL verdict in (stale flip fires exactly one SSE change)"
else
  bad "dashboard _mtime_signature misses the beacon TTL bit (an open dashboard would pulse 'live' over a dead run forever)"
fi

# --- Test DCLI: registry management flags act and exit without serving --------------------
# --add/--remove/--discover/--list curate the cross-repo registry the multi-project server
# lists. They are management invocations: they perform the op and exit 0 (never bind a port,
# so the call returns immediately). The registry is redirected to a temp XDG dir.
DCREG="$TMP/dash-cli-xdg"; mkdir -p "$DCREG"
DCPRJ="$TMP/dash-cli-proj"; mkdir -p "$DCPRJ/one/.planwright" "$DCPRJ/two/.planwright"
# --add then --list compose (add, then show); the management call must exit on its own.
add_out="$(XDG_CONFIG_HOME="$DCREG" python3 "$DASH" --add "$DCPRJ/one" --list)"
if printf '%s' "$add_out" | python3 -c '
import json, os, sys
# the JSON list is the trailing object; find the line where it starts
text = sys.stdin.read()
obj = json.loads(text[text.index("{"):])
paths = [e["path"] for e in obj["projects"]]
assert os.path.abspath("'"$DCPRJ"'/one") in paths, paths
'; then
  ok "dashboard.py --add + --list registers a project and exits without serving"
else
  bad "dashboard.py --add/--list did not register/list the project (or hung)"
fi
# --discover registers every .planwright/ child; --remove drops one.
XDG_CONFIG_HOME="$DCREG" python3 "$DASH" --discover "$DCPRJ" >/dev/null
XDG_CONFIG_HOME="$DCREG" python3 "$DASH" --remove "$DCPRJ/one" >/dev/null
rem_out="$(XDG_CONFIG_HOME="$DCREG" python3 "$DASH" --list)"
if printf '%s' "$rem_out" | python3 -c '
import json, os, sys
obj = json.loads(sys.stdin.read())
names = sorted(os.path.basename(e["path"]) for e in obj["projects"])
assert names == ["two"], names   # one removed; two discovered
'; then
  ok "dashboard.py --discover registers children and --remove drops a project"
else
  bad "dashboard.py --discover/--remove did not yield the expected registry"
fi

# --- Test DMP: per-request project resolution by opaque id against the allow-list ---------
# Two projects: launch --root A, and B registered in a temp registry. The server must serve
# A by default (back-compat), serve B by its id, 404 an unknown id, and NEVER honor a raw
# path passed as ?project (the security boundary).
DMP="$TMP/dash-mp"; mkdir -p "$DMP/.planwright"
printf -- '- [ ] alpha-item\n      Mode: develop\n' > "$DMP/.planwright/plan.md"
DMPB="$TMP/dash-mp-b"; mkdir -p "$DMPB/.planwright"
printf -- '- [ ] beta-item\n      Mode: improve\n\n- [ ] beta-two\n      Mode: improve\n' > "$DMPB/.planwright/plan.md"
DMPX="$TMP/dash-mp-xdg"; mkdir -p "$DMPX"
XDG_CONFIG_HOME="$DMPX" python3 "$DASH" --add "$DMPB" >/dev/null

cat > "$TMP/dash_mp_client.py" <<'PY'
import json, os, subprocess, sys, time, urllib.request, urllib.error
dash, scripts, rootA, rootB, xdg = sys.argv[1:6]
sys.path.insert(0, scripts)
import registry
idB = registry.project_id(rootB)
env = dict(os.environ); env["XDG_CONFIG_HOME"] = xdg
proc = subprocess.Popen([sys.executable, dash, "--root", rootA, "--port", "0"],
                        stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, env=env)
try:
    port, deadline = None, time.time() + 10
    while time.time() < deadline:
        line = proc.stdout.readline()
        if not line:
            break
        if "http://127.0.0.1:" in line:
            port = int(line.split("http://127.0.0.1:")[1].split("/")[0]); break
    assert port, "no port banner"
    base = "http://127.0.0.1:%d" % port
    def get(pathq):
        try:
            with urllib.request.urlopen(base + pathq, timeout=5) as r:
                return r.status, json.loads(r.read().decode())
        except urllib.error.HTTPError as e:
            return e.code, None
    st, data = get("/state.json")
    assert st == 200 and [p["title"] for p in data["pending"]] == ["alpha-item"], ("default!=A", st, data and data["pending"])
    st, data = get("/state.json?project=" + idB)
    assert st == 200 and [p["title"] for p in data["pending"]] == ["beta-item", "beta-two"], ("id!=B", st, data and data["pending"])
    st, _ = get("/state.json?project=deadbeefdeadbeef")
    assert st == 404, ("unknown id not 404", st)
    st, _ = get("/state.json?project=/etc")
    assert st == 404, ("raw path honored as project", st)
    print("MP_OK")
finally:
    proc.terminate()
    try:
        proc.wait(timeout=5)
    except Exception:
        proc.kill()
PY
if python3 "$TMP/dash_mp_client.py" "$DASH" "$ROOT/scripts" "$DMP" "$DMPB" "$DMPX" 2>/dev/null | grep -q MP_OK; then
  ok "dashboard resolves ?project=<id> via allow-list (default serves --root; unknown id + raw path 404)"
else
  bad "dashboard multi-project id resolution failed (allow-list / 404 / back-compat)"
fi

# --- Test DETAG: /state.json ETag is keyed per project (no cross-project 304) -------------
# Two projects with BYTE-IDENTICAL .planwright/ and forced-identical mtimes, so their change
# signatures match. Without folding the project id into the ETag they would share one and
# project A's If-None-Match would 304 project B. The ETag must still 304 within one project.
DET="$TMP/dash-etag"; mkdir -p "$DET/a/.planwright" "$DET/b/.planwright"
printf -- '- [ ] same\n      Mode: develop\n' > "$DET/a/.planwright/plan.md"
printf -- '- [ ] same\n      Mode: develop\n' > "$DET/b/.planwright/plan.md"
python3 -c 'import os,sys; t=1000000000000000000; [os.utime(p, ns=(t,t)) for p in sys.argv[1:]]' \
  "$DET/a/.planwright/plan.md" "$DET/b/.planwright/plan.md"
DETX="$TMP/dash-etag-xdg"; mkdir -p "$DETX"
XDG_CONFIG_HOME="$DETX" python3 "$DASH" --add "$DET/b" >/dev/null

cat > "$TMP/dash_etag_client.py" <<'PY'
import json, os, subprocess, sys, time, urllib.request, urllib.error
dash, scripts, rootA, rootB, xdg = sys.argv[1:6]
sys.path.insert(0, scripts)
import registry
idB = registry.project_id(rootB)
env = dict(os.environ); env["XDG_CONFIG_HOME"] = xdg
proc = subprocess.Popen([sys.executable, dash, "--root", rootA, "--port", "0"],
                        stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, env=env)
try:
    port, deadline = None, time.time() + 10
    while time.time() < deadline:
        line = proc.stdout.readline()
        if not line:
            break
        if "http://127.0.0.1:" in line:
            port = int(line.split("http://127.0.0.1:")[1].split("/")[0]); break
    assert port, "no port banner"
    base = "http://127.0.0.1:%d" % port
    def get(pathq, headers=None):
        req = urllib.request.Request(base + pathq, headers=headers or {})
        try:
            with urllib.request.urlopen(req, timeout=5) as r:
                return r.status, r.headers.get("ETag")
        except urllib.error.HTTPError as e:
            return e.code, e.headers.get("ETag")
    stA, etagA = get("/state.json")                      # default -> A
    stB, etagB = get("/state.json?project=" + idB)       # -> B
    assert stA == 200 and etagA, ("A etag", stA, etagA)
    assert stB == 200 and etagB, ("B etag", stB, etagB)
    assert etagA != etagB, ("ETag collided across projects with identical signatures", etagA, etagB)
    stX, _ = get("/state.json?project=" + idB, {"If-None-Match": etagA})
    assert stX == 200, ("A's ETag wrongly 304'd B", stX)
    stY, _ = get("/state.json?project=" + idB, {"If-None-Match": etagB})
    assert stY == 304, ("same-project conditional did not 304", stY)
    print("ETAG_OK")
finally:
    proc.terminate()
    try:
        proc.wait(timeout=5)
    except Exception:
        proc.kill()
PY
if python3 "$TMP/dash_etag_client.py" "$DASH" "$ROOT/scripts" "$DET/a" "$DET/b" "$DETX" 2>/dev/null | grep -q ETAG_OK; then
  ok "dashboard /state.json ETag is project-keyed (no cross-project 304; same-project still 304s)"
else
  bad "dashboard ETag cross-pollinates across projects (or broke same-project revalidation)"
fi

# --- Test DPROJ: /projects.json lists allow-listed projects with cheap liveness -----------
# A (launch --root) is converged (final.md, no pending); B (registered) is active (fresh
# beacon) with 1 pending / 2 done. /projects.json must list both with id/name/path/status/
# counts, be no-store, and derive status without a full state.collect. C is registered but
# its .planwright/ is gone (a moved/deleted project, or a leaked test fixture): the read-only
# serving path must omit it from the switcher rather than surface a dead row forever.
DPJ="$TMP/dash-projects"; mkdir -p "$DPJ/a/.planwright" "$DPJ/b/.planwright" "$DPJ/c"
printf 'final point\n' > "$DPJ/a/.planwright/final.md"
printf -- '- [ ] todo\n      Mode: develop\n' > "$DPJ/b/.planwright/plan.md"
printf -- '- [x] did-one\n- [x] did-two\n' > "$DPJ/b/.planwright/completed.md"
python3 -c 'import json,sys; open(sys.argv[1],"w").write(json.dumps({"command":"plan","started":"t","updated":"t"}))' \
  "$DPJ/b/.planwright/activity.json"
DPJX="$TMP/dash-projects-xdg"; mkdir -p "$DPJX"
XDG_CONFIG_HOME="$DPJX" python3 "$DASH" --add "$DPJ/b" >/dev/null
XDG_CONFIG_HOME="$DPJX" python3 "$DASH" --add "$DPJ/c" >/dev/null

cat > "$TMP/dash_projects_client.py" <<'PY'
import json, os, subprocess, sys, time, urllib.request
dash, rootA, xdg = sys.argv[1:4]
env = dict(os.environ); env["XDG_CONFIG_HOME"] = xdg; env["PW_ACTIVITY_TTL"] = "99999"
proc = subprocess.Popen([sys.executable, dash, "--root", rootA, "--port", "0"],
                        stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, env=env)
try:
    port, deadline = None, time.time() + 10
    while time.time() < deadline:
        line = proc.stdout.readline()
        if not line:
            break
        if "http://127.0.0.1:" in line:
            port = int(line.split("http://127.0.0.1:")[1].split("/")[0]); break
    assert port, "no port banner"
    with urllib.request.urlopen("http://127.0.0.1:%d/projects.json" % port, timeout=5) as r:
        assert r.headers.get_content_type() == "application/json", r.headers.get_content_type()
        assert r.headers.get("Cache-Control") == "no-store", r.headers.get("Cache-Control")
        data = json.loads(r.read().decode())
    byname = {p["name"]: p for p in data["projects"]}
    assert "a" in byname and "b" in byname, list(byname)
    assert "c" not in byname, ("dead project (no .planwright/) leaked into the switcher", list(byname))
    assert byname["a"]["status"] == "converged", byname["a"]
    assert byname["b"]["status"] == "active", byname["b"]
    assert byname["b"]["counts"] == {"pending": 1, "done": 2}, byname["b"]
    for p in data["projects"]:
        assert p["id"] and p["path"], p
    print("PROJ_OK")
finally:
    proc.terminate()
    try:
        proc.wait(timeout=5)
    except Exception:
        proc.kill()
PY
if python3 "$TMP/dash_projects_client.py" "$DASH" "$DPJ/a" "$DPJX" 2>/dev/null | grep -q PROJ_OK; then
  ok "dashboard /projects.json lists allow-listed projects with status + counts (no-store, no full collect)"
else
  bad "dashboard /projects.json missing projects/status/counts (or not no-store)"
fi

# --- Test DPROJPW: a leaked .planwright state-dir entry never reaches the switcher/Fleet ---
# A `.planwright` state dir that grew a nested `.planwright/` (a tool run with the state dir as
# cwd) could be written into the registry by an older build or a stray `discover`. Its basename
# is `.planwright`, so it used to render as a phantom project in the switcher dropdown and the
# Fleet grid (both read /projects.json). The allow-list filter (registry.is_registerable) must
# drop it at serve time even though the read-only path never rewrites the registry to self-heal.
DPW="$TMP/dash-projects-pw"; mkdir -p "$DPW/real/.planwright" "$DPW/poison/.planwright/.planwright"
DPWX="$TMP/dash-projects-pw-xdg"; mkdir -p "$DPWX"
XDG_CONFIG_HOME="$DPWX" python3 "$DASH" --add "$DPW/real" >/dev/null
# Inject the poison entry directly (upsert/add now refuse it) to mimic a registry from a build
# that predates the guard — exactly the on-disk state a real user would have. $ROOT/$DPW go via
# argv so the quoted heredoc body needs no shell expansion (clean for shellcheck).
XDG_CONFIG_HOME="$DPWX" python3 - "$ROOT" "$DPW" <<'PY'
import os, sys
root, dpw = sys.argv[1], sys.argv[2]
sys.path.insert(0, os.path.join(root, "scripts"))
import registry
e = registry.load(); e["poisonid"] = os.path.join(dpw, "poison", ".planwright"); registry.save(e)
PY
cat > "$TMP/dash_projects_pw_client.py" <<'PY'
import json, os, subprocess, sys, time, urllib.request
dash, rootA, xdg = sys.argv[1:4]
env = dict(os.environ); env["XDG_CONFIG_HOME"] = xdg
proc = subprocess.Popen([sys.executable, dash, "--root", rootA, "--port", "0"],
                        stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, env=env)
try:
    port, deadline = None, time.time() + 10
    while time.time() < deadline:
        line = proc.stdout.readline()
        if not line:
            break
        if "http://127.0.0.1:" in line:
            port = int(line.split("http://127.0.0.1:")[1].split("/")[0]); break
    assert port, "no port banner"
    with urllib.request.urlopen("http://127.0.0.1:%d/projects.json" % port, timeout=5) as r:
        data = json.loads(r.read().decode())
    names = sorted(p["name"] for p in data["projects"])
    assert ".planwright" not in names, ("phantom .planwright row leaked into the switcher", names)
    assert "real" in names, names
    print("PROJPW_OK")
finally:
    proc.terminate()
    try:
        proc.wait(timeout=5)
    except Exception:
        proc.kill()
PY
if python3 "$TMP/dash_projects_pw_client.py" "$DASH" "$DPW/real" "$DPWX" 2>/dev/null | grep -q PROJPW_OK; then
  ok "dashboard /projects.json filters a leaked .planwright state-dir entry from the switcher/Fleet"
else
  bad "dashboard /projects.json surfaced a phantom .planwright project from a poisoned registry"
fi

# --- Test DSW: app.js wires the client-side project switcher ------------------------------
# The bottom-left #pw-project becomes a switcher: app.js fetches /projects.json and re-points
# its state/events fetches at ?project=<id> (purely client-side — no control endpoint). This
# is a static wiring assertion (the DOM behavior has no JS test harness in this suite).
APPJS="$ROOT/scripts/dashboard/app.js"
if grep -q '/projects.json' "$APPJS" \
   && grep -q 'withProject(' "$APPJS" \
   && grep -q '"?project=" + encodeURIComponent' "$APPJS" \
   && grep -q 'function setSelectedProject' "$APPJS" \
   && grep -q 'id="pw-project"' "$ROOT/scripts/dashboard/index.html"; then
  ok "app.js wires the project switcher (/projects.json + ?project= + setSelectedProject into #pw-project)"
else
  bad "app.js project-switcher wiring is incomplete (/projects.json, withProject, ?project=, or #pw-project missing)"
fi

# --- Test DFLEET: the Fleet view is loaded and consumes the project list ------------------
# The Fleet view renders every tracked project's reactor state from /projects.json (bridged
# by app.js into window.PW_PROJECTS). Static wiring assertion (no JS DOM harness in this suite).
IDX="$ROOT/scripts/dashboard/index.html"
FLEET="$ROOT/scripts/dashboard/views/fleet.js"
APPJS="$ROOT/scripts/dashboard/app.js"
if grep -q '/views/fleet.js' "$IDX" \
   && grep -q 'id="view-fleet"' "$IDX" \
   && grep -q 'data-view="fleet"' "$IDX" \
   && grep -q 'PW_VIEWS.fleet' "$FLEET" \
   && grep -q 'PW_PROJECTS' "$FLEET" \
   && grep -q 'window.PW_PROJECTS = projectsList' "$APPJS" \
   && grep -q '{ key: "fleet"' "$APPJS"; then
  ok "Fleet view is loaded (tab + section + script) and consumes the project list (PW_PROJECTS)"
else
  bad "Fleet view wiring incomplete (script/tab/section, PW_VIEWS.fleet, or PW_PROJECTS bridge)"
fi

# --- Test DPORT: stable default port with single-instance reuse + ephemeral fallback ------
# With no --port the server binds a stable home port (pinned via PW_DASH_PORT for the test).
# A second default launch must detect the running dashboard and exit 0 (reuse), while an
# explicit busy --port keeps the exit-2 contract.
DPORT="$TMP/dash-port"; mkdir -p "$DPORT/.planwright"
printf -- '- [ ] x\n      Mode: develop\n' > "$DPORT/.planwright/plan.md"

cat > "$TMP/dash_port_client.py" <<'PY'
import os, socket, subprocess, sys, time, urllib.request
dash, root = sys.argv[1:3]
s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
s.bind(("127.0.0.1", 0)); home = s.getsockname()[1]; s.close()
env = dict(os.environ); env["PW_DASH_PORT"] = str(home)
def banner_port(proc):
    deadline = time.time() + 10
    while time.time() < deadline:
        line = proc.stdout.readline()
        if not line:
            return None
        if "http://127.0.0.1:" in line:
            return int(line.split("http://127.0.0.1:")[1].split("/")[0])
    return None
p1 = subprocess.Popen([sys.executable, dash, "--root", root], env=env,
                      stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
try:
    bound = banner_port(p1)
    assert bound == home, ("server #1 did not bind the pinned home port", bound, home)
    with urllib.request.urlopen("http://127.0.0.1:%d/" % home, timeout=3) as r:
        assert r.status == 200
    p2 = subprocess.run([sys.executable, dash, "--root", root], env=env,
                        stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=15)
    assert p2.returncode == 0, ("reuse did not exit 0", p2.returncode, p2.stdout)
    assert "already running" in p2.stdout, ("no reuse message", p2.stdout)
    p3 = subprocess.run([sys.executable, dash, "--root", root, "--port", str(home)], env=env,
                        stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=15)
    assert p3.returncode == 2, ("explicit busy --port should exit 2", p3.returncode, p3.stdout)
    print("PORT_OK")
finally:
    p1.terminate()
    try:
        p1.wait(timeout=5)
    except Exception:
        p1.kill()
PY
if python3 "$TMP/dash_port_client.py" "$DASH" "$DPORT" 2>/dev/null | grep -q PORT_OK; then
  ok "dashboard default port is stable with single-instance reuse (exit 0); explicit busy --port still exit 2"
else
  bad "dashboard default-port reuse/fallback failed (or explicit busy --port no longer exit 2)"
fi

# --- Test DASH-SSE-RECONNECT: app.js surfaces honest live/reconnecting(n)/offline state -----
# The bare onerror was replaced by a bounded reconnect: consecutive errors count up, the status
# reads live (open) -> reconnecting (n) (under the cap) -> offline (past the cap, client stops
# retrying), and a reopen resets to live. connectEvents is DOM/EventSource-bound, so the test drives
# the exposed pure state machine (window.PW_SSE.status) the handler uses, over the open/error/reopen
# sequence. Node-gated; server-side SSE tests above run without Node.
if command -v node >/dev/null 2>&1; then
  cat > "$TMP/sse_reconnect_test.js" <<'JS'
const assert = require("assert");
const BASE = process.argv[2];
const VM = require(BASE + "/../../tests/cases/lib/dashboard-vm.js");
const { makeDoc, makeWin, install, loadCommon, loadScript } = VM;
const doc = makeDoc(); const win = makeWin(doc); install(win, doc);
win.fetch = function () { return Promise.reject(new Error("no fetch in test")); };
global.fetch = win.fetch;
loadCommon(BASE);
loadScript(BASE, "app.js");            // registers window.PW_SSE
const SSE = win.PW_SSE;
assert(SSE && typeof SSE.status === "function", "app.js did not expose PW_SSE.status");
const MAX = SSE.MAX_RECONNECT;
assert(typeof MAX === "number" && MAX >= 1, "PW_SSE.MAX_RECONNECT must be a positive int");
// open / reopen -> live (ok)
assert(SSE.status(0, MAX).text === "live" && SSE.status(0, MAX).cls === "ok", "open should be live/ok");
// error under the cap -> reconnecting (n) (warn), strictly counting up
const r1 = SSE.status(1, MAX);
assert(r1.text === "reconnecting (1)" && r1.cls === "warn", "first error: " + JSON.stringify(r1));
assert(SSE.status(MAX, MAX).text === "reconnecting (" + MAX + ")", "at the cap still reconnecting (max)");
// past the cap -> offline (err): the client gives up rather than spin forever
const off = SSE.status(MAX + 1, MAX);
assert(off.text === "offline" && off.cls === "err", "past the cap: " + JSON.stringify(off));
console.log("SSE-RECONNECT-OK");
JS
  if node "$TMP/sse_reconnect_test.js" "$ROOT/scripts/dashboard" >"$TMP/sse_reconnect.out" 2>"$TMP/sse_reconnect.err" \
     && grep -q SSE-RECONNECT-OK "$TMP/sse_reconnect.out"; then
    ok "app.js PW_SSE.status surfaces honest live/reconnecting(n)/offline state across open/error/reopen"
  else
    bad "app.js SSE reconnect state assertion failed: $(cat "$TMP/sse_reconnect.err" 2>/dev/null)"
  fi
else
  ok "app.js SSE reconnect state check skipped (node not installed)"
fi

