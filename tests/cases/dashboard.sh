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
PW_TEST_VIEWS="console commands plan timeline graph insights shards doctor" \
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
# The Commands view's codmaster front-door panel must consume /recommend.json and gate the
# paint on the recUsable shape guard (an error body / older server degrades to an absent
# panel, never an error state). Same grep-able-guard posture as the COACH.reset pin.
if grep -q 'fetch("/recommend.json")' "$ROOT/scripts/dashboard/views/commands.js" \
   && grep -q 'function recUsable' "$ROOT/scripts/dashboard/views/commands.js"; then
  ok "Commands view wires the codmaster front-door panel (/recommend.json + recUsable shape guard)"
else
  bad "Commands view lost the front-door panel wiring (/recommend.json fetch or its shape guard)"
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
// in the right rail ABOVE the dirty pulse — COMPACT: a pw-section-mini heading (matching the
// Console's other section labels, not pw-panel-title), mode+title items only, and NO sub-line /
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
assert(findByClass(conContrib[0], "pw-section-mini").length === 1 &&
       findByClass(conContrib[0], "pw-panel-title").length === 0,
  "Console (compact) contributions heading must use pw-section-mini, not pw-panel-title");
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
const { El, makeDoc, makeWin, install, loadScript } = VM;
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
// degraded snapshot (no metrics) must not throw
win.PW_VIEWS.insights(new El("section"), { counts:{} }, { graphText:null, metrics:null, builtSha:"", stale:false, head:"deadbeef" });
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
