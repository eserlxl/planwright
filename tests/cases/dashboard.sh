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
        proc.wait(timeout=5)
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
