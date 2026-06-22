#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Eser KUBALI
# SPDX-License-Identifier: GPL-3.0-or-later
#
# planwright dashboard — a local, read-only web view of the planning state, so you can
# *watch* the explore->invent process evolve live instead of re-running `status`. It is
# a mirror, never a remote control: it launches no agent, edits nothing, and exposes no
# action buttons. Everything it shows is derived from the gitignored .planwright/ tree.
#
# Stdlib only — no Flask, no websocket library, no build toolchain:
#   GET /            -> the static UI shell (scripts/dashboard/index.html)
#   GET /<asset>     -> static assets under scripts/dashboard/ (app.js, views/*.js, ...)
#   GET /state.json  -> the current state snapshot (built on demand via state.collect)
#   GET /graph.json  -> a passthrough of .planwright/graph.json (for the graph view)
#   GET /recommend.json -> the dispatcher decision record (status.recommend: the same
#                       read-only JSON `planwright advise` and /codmaster consume), so
#                       the Commands view can show what codmaster would dispatch next
#   GET /events      -> a Server-Sent Events stream that mtime-polls .planwright/ ~1s
#                       and pushes a `change` event whenever a file changes, so the
#                       browser re-fetches /state.json. One-directional (server->client).
#
#   python3 scripts/dashboard.py --root .            # bind 127.0.0.1 on the stable home port 8765 (reuse if running)
#   python3 scripts/dashboard.py --root . --port 0   # bind an ephemeral port instead
#   python3 scripts/dashboard.py --root . --open     # also open the URL in a browser
#
# Bound to loopback (127.0.0.1) only and read-only by construction. Dynamic responses are
# sent no-store so the live view never reads a stale snapshot from the browser cache.

import argparse
import errno
import hashlib
import json
import os
import signal
import sys
import threading
import time
import urllib.parse
import urllib.request
import webbrowser
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

# dashboard.py lives beside state.py/status.py/doctor.py in scripts/; that directory is
# sys.path[0] when run as a script, so a plain import resolves them.
import state
import status
import doctor
import registry

# Static UI lives under scripts/dashboard/ next to this file (resolved from __file__, not
# the cwd, so the server works regardless of where it is launched from).
_HERE = os.path.dirname(os.path.abspath(__file__))
STATIC_ROOT = os.path.join(_HERE, "dashboard")

# Minimal extension -> content-type map for the static assets the UI ships.
_CONTENT_TYPES = {
    ".html": "text/html; charset=utf-8",
    ".js": "text/javascript; charset=utf-8",
    ".css": "text/css; charset=utf-8",
    ".json": "application/json; charset=utf-8",
    ".svg": "image/svg+xml",
    ".woff2": "font/woff2",
    ".woff": "font/woff",
    ".txt": "text/plain; charset=utf-8",
}

def _env_float(name, default):
    """A positive float from the environment, else the default. A behavior-preserving
    tuning/test seam (the defaults are unchanged when the env var is absent or invalid)."""
    raw = os.environ.get(name)
    if raw is not None:
        try:
            v = float(raw)
            if v > 0:
                return v
        except ValueError:
            pass
    return default


def _env_int(name, default):
    """A positive int (>= 1) from the environment, else the default. Mirrors _env_float for
    count-style caps that must be a whole number of slots: a fractional ("0.5"), sub-1, or
    non-numeric value is invalid and falls back to the default, never silently flooring to 0
    (int(0.5) == 0 would leave a zero-slot semaphore that 503s every client)."""
    raw = os.environ.get(name)
    if raw is not None:
        try:
            v = int(raw)
            if v >= 1:
                return v
        except ValueError:
            pass
    return default


# How often the /events stream polls .planwright/ for changes (seconds).
POLL_INTERVAL = _env_float("PW_DASH_POLL", 1.0)

# How long the /events stream may stay silent before it sends a keep-alive `: ping`
# comment. The ping keeps the connection warm and lets a vanished client be noticed (the
# failing write tears the handler thread down) instead of leaking until the next change.
HEARTBEAT_INTERVAL = _env_float("PW_DASH_HEARTBEAT", 15.0)


# Cap on concurrent /events (SSE) streams. ThreadingHTTPServer spawns a handler thread
# per connection and an idle-closed tab is only reaped at the next heartbeat write, so
# without a bound, repeated open/close churn can pile up live threads. A BoundedSemaphore
# caps the live streams; an over-cap client gets a retriable 503 instead of a new thread.
# Overridable via PW_DASH_MAX_SSE_CLIENTS (invalid/absent -> 64).
MAX_SSE_CLIENTS = _env_int("PW_DASH_MAX_SSE_CLIENTS", 64)
_sse_slots = threading.BoundedSemaphore(MAX_SSE_CLIENTS)

# The reconnect cadence (milliseconds) advertised to the browser via a leading SSE `retry:`
# directive, so a dropped /events stream reconnects on a deliberate, server-tuned interval
# (bounded against MAX_SSE_CLIENTS open/close churn) instead of the browser's implicit ~3s default.
# Overridable via PW_DASH_SSE_RETRY_MS through the strict _env_int validator — a fractional,
# sub-1, or non-numeric value is rejected back to the default, never silently floored to 0 (a
# `retry: 0` would tell the browser to reconnect instantly, a tight reconnect loop).
SSE_RETRY_MS = _env_int("PW_DASH_SSE_RETRY_MS", 3000)


# The stable default port for the shared (multi-project) server, so a launched dashboard has a
# bookmarkable URL and a second launch can detect and attach to the first. Overridable via
# PW_DASH_PORT (mainly so a test can pin a known-free port). A port is a whole number, so it
# goes through the strict integer path (like the other count-style env vars): a fractional
# ("8765.9") or non-numeric value is rejected back to the default, never silently floored to a
# nearby int. An explicit --port (including 0 for an ephemeral port) overrides it entirely.
DEFAULT_PORT = _env_int("PW_DASH_PORT", 8765)


def _planwright_dir(root):
    return os.path.join(root, ".planwright")


def _count_lines_prefixed(path, prefix):
    """Cheap count of lines beginning with `prefix` in a file; 0 if absent/unreadable. Used
    for the /projects.json per-project counts so listing N projects never parses a full plan
    (a line tally, not state.collect)."""
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as fh:
            return sum(1 for line in fh if line.startswith(prefix))
    except OSError:
        return 0


def _mtime_signature(root):
    """A cheap change signature for .planwright/: the sorted (name, mtime, size) of its
    files. Comparing successive signatures detects any add/remove/modify without reading
    file contents. A missing directory yields an empty signature (a valid state).

    The run-activity beacon gets one derived bit on top: its stale flip happens by TTL,
    not by a file change — an interrupted run leaves activity.json untouched, so without
    this bit the one scenario the stale flag exists for would never fire a change event
    and an open dashboard would keep pulsing "live" over a dead run. The bit makes the
    signature change exactly once when the beacon crosses PW_ACTIVITY_TTL."""
    pw = _planwright_dir(root)
    sig = []
    try:
        for name in sorted(os.listdir(pw)):
            fp = os.path.join(pw, name)
            try:
                st = os.stat(fp)
            except OSError:
                continue
            entry = (name, st.st_mtime_ns, st.st_size)
            if name == "activity.json":
                entry += ((time.time() - st.st_mtime) > state._activity_ttl(),)
            sig.append(entry)
    except OSError:
        return ()
    return tuple(sig)


def _resolve_static(path):
    """Map a URL path to a real file under STATIC_ROOT, or None if it escapes the root
    or does not exist. '/' maps to index.html. Guards against path traversal by requiring
    the resolved realpath to stay within STATIC_ROOT."""
    rel = path.lstrip("/") or "index.html"
    candidate = os.path.realpath(os.path.join(STATIC_ROOT, rel))
    root_real = os.path.realpath(STATIC_ROOT)
    if candidate != root_real and not candidate.startswith(root_real + os.sep):
        return None
    if not os.path.isfile(candidate):
        return None
    return candidate


class Handler(BaseHTTPRequestHandler):
    # Quiet by default — the access log would drown the launch banner; override to no-op.
    def log_message(self, *args):
        pass

    @property
    def root(self):
        # do_GET resolves the per-request project (by id, against the allow-list) and stashes
        # it in self._root before any handler runs; fall back to the launch root defensively.
        return getattr(self, "_root", None) or self.server.planwright_root

    # Dynamic snapshots must never be served from the browser cache: the SSE stream is what
    # tells the page to refetch, so a cached /state.json would freeze the live view.
    _NO_STORE = {"Cache-Control": "no-store"}

    def _send(self, code, content_type, body, extra_headers=None):
        self.send_response(code)
        self.send_header("Content-Type", content_type)
        # Cheap defense in depth: stop the browser from MIME-sniffing a served asset into a
        # type it was not labelled as. Everything here is same-origin and loopback-only, but
        # the header costs nothing.
        self.send_header("X-Content-Type-Options", "nosniff")
        if isinstance(body, str):
            body = body.encode("utf-8")
        if body is not None:
            self.send_header("Content-Length", str(len(body)))
        for k, v in (extra_headers or {}).items():
            self.send_header(k, v)
        self.end_headers()
        if body is not None:
            self.wfile.write(body)

    # Hosts a loopback request may legitimately carry. Pinning the Host header defeats
    # DNS rebinding: a malicious page that rebinds its hostname to 127.0.0.1 would reach
    # this server with its own Host (e.g. attacker.example), and reading the planning
    # state cross-origin is exactly what we refuse. An absent Host (HTTP/1.0 / non-browser
    # clients) cannot be rebound through, so it is allowed.
    _ALLOWED_HOSTS = ("127.0.0.1", "localhost", "::1")

    def _host_allowed(self):
        host = self.headers.get("Host", "")
        if not host:
            return True
        if host.startswith("["):            # [ipv6] or [ipv6]:port
            hostname = host[1:].split("]", 1)[0]
        else:
            hostname = host.rsplit(":", 1)[0] if ":" in host else host
        # Hostnames are case-insensitive (RFC 4343), so a legitimate loopback request may
        # arrive as `Localhost`/`LOCALHOST`; fold to lowercase before matching the (already
        # lowercase) allow-list. Case-folding loopback names does not weaken the rebinding
        # defense — a rebound attacker hostname still fails the membership test.
        return hostname.lower() in self._ALLOWED_HOSTS

    def _project_allowlist(self):
        """The current {id: abspath} allow-list of selectable projects: the live registry
        plus the launch --root (always reachable by its own id). Read fresh per request so a
        project that started running after launch appears without a server restart, and with
        prune=False so a GET never writes — the serving path stays read-only even toward the
        registry. The browser may select a project ONLY by an id in this map; a
        client-supplied path is never honored, which is what keeps the dashboard from being an
        arbitrary-directory read (state/recommend/doctor each run git in the chosen root).
        A `.planwright` state dir that leaked into the registry (registry.is_registerable) is
        filtered here so it is neither listed in the switcher/Fleet view nor selectable by id,
        even though the read-only serving path never rewrites the registry to self-heal it."""
        allow = {e["id"]: e["path"] for e in registry.list_projects(prune=False)
                 if registry.is_registerable(e["path"])}
        root = self.server.planwright_root
        allow.setdefault(registry.project_id(root), root)
        return allow

    def _resolve_project_root(self):
        """Resolve this request's project root, returning (root, known). With no ?project,
        use the launch --root (single-project / back-compat). With ?project=<id>, resolve the
        id against the allow-list; an unknown id yields (None, False) so do_GET 404s. A
        ?project value is an opaque id, never a path — so ?project=/etc cannot select a
        directory; it simply fails the allow-list lookup."""
        query = urllib.parse.urlsplit(self.path).query
        pid = (urllib.parse.parse_qs(query).get("project") or [None])[0]
        if pid is None:
            return self.server.planwright_root, True
        root = self._project_allowlist().get(pid)
        if root is None:
            return None, False
        return root, True

    def do_GET(self):
        if not self._host_allowed():
            return self._send(403, "text/plain; charset=utf-8", "forbidden host")
        # Resolve which project this request targets — by opaque id against the allow-list,
        # never by a client path. An unknown id 404s before any handler reads the filesystem.
        root, known = self._resolve_project_root()
        if not known:
            return self._send(404, "application/json; charset=utf-8",
                              json.dumps({"error": "unknown project"}), self._NO_STORE)
        self._root = root
        path = self.path.split("?", 1)[0]
        if path == "/state.json":
            return self._serve_state()
        if path == "/graph.json":
            return self._serve_graph()
        if path == "/doctor.json":
            return self._serve_doctor()
        if path == "/recommend.json":
            return self._serve_recommend()
        if path == "/projects.json":
            return self._serve_projects()
        if path == "/events":
            return self._serve_events()
        return self._serve_static(path)

    def _state_etag(self):
        """A strong ETag for the current /state.json: a short hash of the cheap .planwright/
        change signature (the same one the SSE /events stream watches). It changes iff the
        snapshot would — any add/remove/modify under .planwright/, or a beacon TTL flip."""
        # Fold the resolved root into the validator so two projects never share an ETag even
        # if their .planwright/ signatures happen to match — otherwise project A's
        # If-None-Match could wrongly 304 project B on a multi-project server.
        sig = repr((self.root, _mtime_signature(self.root))).encode("utf-8")
        return '"%s"' % hashlib.sha1(sig).hexdigest()[:16]

    def _serve_state(self):
        # Derive a strong validator from the .planwright/ change signature so a polling client
        # can revalidate cheaply: when its If-None-Match matches, the snapshot is unchanged, so
        # answer 304 and skip the state.collect() re-parse of plan.md + completed.md entirely.
        # Cache-Control stays no-store (the SSE stream still drives every refetch); no-store
        # forbids stored reuse, not conditional revalidation.
        etag = self._state_etag()
        headers = dict(self._NO_STORE, ETag=etag)
        if self.headers.get("If-None-Match") == etag:
            return self._send(304, "application/json; charset=utf-8", None, headers)
        try:
            body = json.dumps(state.collect(self.root), indent=2)
        except Exception as exc:  # never let a transient read error 500 the whole UI
            return self._send(500, "application/json; charset=utf-8",
                              json.dumps({"error": str(exc)}), self._NO_STORE)
        self._send(200, "application/json; charset=utf-8", body, headers)

    def _serve_doctor(self):
        # Read-only environment preflight. doctor.collect() only probes (tool versions,
        # git config reads, check-ignore) — it never writes; the remediating --fix path is
        # not reachable from here. Same no-store discipline as the other dynamic snapshots.
        try:
            body = json.dumps(doctor.collect(self.root), indent=2)
        except Exception as exc:
            return self._send(500, "application/json; charset=utf-8",
                              json.dumps({"error": str(exc)}), self._NO_STORE)
        self._send(200, "application/json; charset=utf-8", body, self._NO_STORE)

    def _serve_recommend(self):
        # The dispatcher overlay (codmaster's decision record), served verbatim from
        # status.recommend() — the same canonical surface `planwright advise` reads, so
        # the Commands view and the command layer can never disagree on the same state.
        # Read-only throughout: recommend() only reads .planwright/ plus read-only git
        # probes (rev-parse / ls-files / no-optional-locks status) and the doctor
        # preflight — none take .git/index.lock, so a live run's commits never flake
        # on a dashboard refetch.
        try:
            body = json.dumps(status.recommend(self.root), indent=2)
        except Exception as exc:
            return self._send(500, "application/json; charset=utf-8",
                              json.dumps({"error": str(exc)}), self._NO_STORE)
        self._send(200, "application/json; charset=utf-8", body, self._NO_STORE)

    def _serve_graph(self):
        gp = os.path.join(_planwright_dir(self.root), "graph.json")
        try:
            with open(gp, "rb") as fh:
                body = fh.read()
        except OSError:
            return self._send(404, "application/json; charset=utf-8",
                              json.dumps({"error": "no graph built"}), self._NO_STORE)
        self._send(200, "application/json; charset=utf-8", body, self._NO_STORE)

    def _project_status(self, root):
        """A cheap liveness verdict for one project, from filesystem signals only: `active`
        when the run-activity beacon is fresh (within state's TTL), `stale` when it exists but
        has expired (an interrupted run), `converged` when a final-point marker is recorded,
        else `idle`. No state.collect/doctor here — listing many projects must stay cheap."""
        pw = _planwright_dir(root)
        try:
            mtime = os.stat(os.path.join(pw, "activity.json")).st_mtime
        except OSError:
            mtime = None
        if mtime is not None:
            return "active" if (time.time() - mtime) <= state._activity_ttl() else "stale"
        if os.path.isfile(os.path.join(pw, "final.md")):
            return "converged"
        return "idle"

    def _serve_projects(self):
        """The project list the switcher and Fleet view read: one cheap entry per allow-listed
        project (the live registry + the launch --root). Each carries id, basename, path, a
        liveness status, and plan/completed line counts. Deliberately cheap — it never runs
        state.collect or doctor.collect per project, so listing N projects is N small stats,
        not N full snapshots. Same no-store discipline as the other dynamic endpoints."""
        # The launch --root is always listed (even before it has a plan); every other entry is
        # shown only while its .planwright/ still exists. That is the same liveness test
        # registry.list_projects(prune=True) self-cleans on — but applied at display time, so
        # the read-only serving path (which never rewrites the registry) still won't surface a
        # project that has been deleted or moved. Without this, a stale row — e.g. a removed
        # test fixture that leaked into the registry — would linger in the switcher forever.
        root_id = registry.project_id(self.server.planwright_root)
        out = []
        for pid, path in sorted(self._project_allowlist().items(), key=lambda kv: kv[1]):
            pw = _planwright_dir(path)
            if pid != root_id and not os.path.isdir(pw):
                continue
            out.append({
                "id": pid,
                "name": os.path.basename(os.path.normpath(path)),
                "path": path,
                "status": self._project_status(path),
                "counts": {
                    "pending": _count_lines_prefixed(os.path.join(pw, "plan.md"), "- [ ]"),
                    "done": _count_lines_prefixed(os.path.join(pw, "completed.md"), "- [x]"),
                },
            })
        self._send(200, "application/json; charset=utf-8",
                   json.dumps({"projects": out}, indent=2), self._NO_STORE)

    def _serve_static(self, path):
        real = _resolve_static(path)
        if real is None:
            return self._send(404, "text/plain; charset=utf-8", "not found")
        ext = os.path.splitext(real)[1].lower()
        ctype = _CONTENT_TYPES.get(ext, "application/octet-stream")
        try:
            with open(real, "rb") as fh:
                body = fh.read()
        except OSError:
            return self._send(404, "text/plain; charset=utf-8", "not found")
        self._send(200, ctype, body)

    def _sse_write(self, chunk):
        self.wfile.write(chunk)
        self.wfile.flush()

    def _serve_events(self):
        """Server-Sent Events: emit an initial `change` then one whenever the
        .planwright/ signature changes. During idle stretches it emits a `: ping`
        keep-alive comment every HEARTBEAT_INTERVAL seconds. Runs until the client
        disconnects (a failed write ends the handler thread). Bounded by
        MAX_SSE_CLIENTS concurrent streams — an over-cap client gets a retriable 503
        instead of an unbounded new handler thread."""
        if not _sse_slots.acquire(blocking=False):
            return self._send(503, "text/plain; charset=utf-8", "too many event streams")
        try:
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Cache-Control", "no-cache")
            self.send_header("X-Content-Type-Options", "nosniff")
            self.send_header("Connection", "keep-alive")
            self.end_headers()
            last = None
            idle = 0.0
            sent_retry = False
            event_id = 0
            while True:
                sig = _mtime_signature(self.root)
                if sig != last:
                    last = sig
                    idle = 0.0
                    # Stamp each change with a strictly increasing `id:` (the frame's second line,
                    # so the opening line stays `event: change`). A reconnecting client replaying
                    # Last-Event-ID can then tell whether changes occurred during the gap.
                    event_id += 1
                    self._sse_write(b"event: change\nid: %d\ndata: 1\n\n" % event_id)
                    if not sent_retry:
                        # After the first change frame (so the stream's opening line stays
                        # `event: change`, the documented open contract), advertise our reconnect
                        # cadence so a dropped stream reconnects on the server-tuned interval.
                        sent_retry = True
                        self._sse_write(b"retry: %d\n\n" % SSE_RETRY_MS)
                else:
                    idle += POLL_INTERVAL
                    if idle >= HEARTBEAT_INTERVAL:
                        idle = 0.0
                        self._sse_write(b": ping\n\n")
                time.sleep(POLL_INTERVAL)
        except (BrokenPipeError, ConnectionResetError, OSError):
            return  # client went away — end the handler thread cleanly
        finally:
            _sse_slots.release()


def _is_dashboard(port):
    """Best-effort probe: is the listener on 127.0.0.1:<port> a planwright dashboard? GET / and
    look for the UI shell's marker. Any error (connection refused, timeout, a foreign service)
    returns False, so a second launch only *attaches* to one of our own and otherwise falls
    back to an ephemeral port. Loopback only."""
    try:
        with urllib.request.urlopen("http://127.0.0.1:%d/" % port, timeout=1.5) as r:
            head = r.read(4096).decode("utf-8", "replace")
        return "planwright dashboard" in head
    except Exception:
        return False


def serve(root, port, open_browser=False, default_port=False):
    """Start the dashboard server on 127.0.0.1:<port> (0 = ephemeral). Prints the bound
    address (so a caller/test can discover an ephemeral port) and blocks serving. With
    open_browser, best-effort opens the URL in a browser once the socket is listening.
    Returns a process exit code: 0 on a clean shutdown, 2 when the port cannot be bound."""
    # socket.bind raises OverflowError (not OSError) for a port outside 0-65535, which
    # would escape the handler below as a traceback — pre-validate so an invalid --port
    # honors the same exit-2 contract as a busy one.
    if not 0 <= port <= 65535:
        sys.stderr.write(
            "planwright dashboard: invalid port %d (must be 0-65535; 0 = ephemeral)\n" % port)
        return 2
    try:
        httpd = ThreadingHTTPServer(("127.0.0.1", port), Handler)
    except OSError as e:
        # A busy explicit --port (errno 98 = EADDRINUSE) must fail with a clear message,
        # not an uncaught traceback. An ephemeral port (0) failing is some other bind
        # error, so report it generically rather than suggesting --port.
        if port and e.errno == errno.EADDRINUSE:
            # The stable home port being busy is handled specially: attach to an existing
            # planwright dashboard (single-instance reuse, exit 0), else fall back to an
            # ephemeral port so a launch never fails just because the home port is taken. An
            # explicit --port keeps the original "pick another" exit-2 contract.
            if default_port and _is_dashboard(port):
                url = "http://127.0.0.1:%d/" % port
                print("planwright dashboard: already running at %s — opening it" % url, flush=True)
                if open_browser:
                    try:
                        webbrowser.open(url)
                    except Exception:
                        pass
                return 0
            if default_port:
                try:
                    httpd = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
                except OSError as e2:
                    sys.stderr.write(
                        "planwright dashboard: cannot bind 127.0.0.1 (%s)\n" % e2)
                    return 2
            else:
                sys.stderr.write(
                    "planwright dashboard: port %d is already in use — pick another with "
                    "--port, or use --port 0 for an automatically-chosen free port\n" % port)
                return 2
        else:
            sys.stderr.write(
                "planwright dashboard: cannot bind 127.0.0.1:%d (%s)\n" % (port, e))
            return 2
    httpd.daemon_threads = True            # don't let SSE threads block process exit
    httpd.planwright_root = os.path.abspath(root)
    bound = httpd.server_address[1]
    url = "http://127.0.0.1:%d/" % bound
    print("planwright dashboard: %s  (root: %s)" % (url, httpd.planwright_root), flush=True)
    if open_browser:
        # The socket is already listening, so a browser can connect immediately. Never let
        # a headless box (no browser available) take the server down with it.
        try:
            webbrowser.open(url)
        except Exception:
            pass
    # A SIGTERM (proc.terminate() from a supervisor or test harness) should unwind through
    # the same clean shutdown as Ctrl-C: the finally runs server_close() and any atexit
    # (e.g. the coverage flush) fires. A default SIGTERM disposition would kill the process
    # mid-serve, skipping both. Route it to the existing KeyboardInterrupt path. (serve()
    # runs on the main thread, so signal.signal is permitted here.)
    def _on_sigterm(_signum, _frame):
        raise KeyboardInterrupt
    signal.signal(signal.SIGTERM, _on_sigterm)
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        httpd.server_close()
    return 0


def main():
    ap = argparse.ArgumentParser(
        description="planwright local read-only dashboard (live, no agent coupling).")
    ap.add_argument("--root", default=".",
                    help="the target repo to mirror (default: current directory)")
    ap.add_argument("--port", type=int, default=None,
                    help="port to bind on 127.0.0.1 (default: %d, a stable home port with "
                         "single-instance reuse; --port 0 = ephemeral)" % DEFAULT_PORT)
    ap.add_argument("--open", action="store_true",
                    help="open the dashboard URL in a browser once the server is up")
    # Registry management — curate which projects the shared (multi-project) server lists.
    # These are management invocations, not a serve: when any is given, the op runs and the
    # process exits without binding a port.
    ap.add_argument("--add", metavar="DIR",
                    help="register DIR in the cross-repo project registry, then exit")
    ap.add_argument("--remove", metavar="DIR",
                    help="drop DIR from the project registry, then exit")
    ap.add_argument("--discover", metavar="PARENT",
                    help="register each child of PARENT holding a .planwright/, then exit")
    ap.add_argument("--list", action="store_true",
                    help="print the project registry as JSON, then exit")
    args = ap.parse_args()

    # A management invocation does its registry op(s) and exits 0 without serving. --add and
    # --list compose (add then show), so run the mutating ops first and list last.
    managed = False
    if args.add:
        _pid = registry.upsert(args.add)
        print("registry: added %s" % _pid if _pid
              else "registry: refused %s (a .planwright state dir is not a project)" % args.add)
        managed = True
    if args.remove:
        print("registry: removed" if registry.remove(args.remove) else "registry: not found")
        managed = True
    if args.discover:
        print("registry: discovered %d project(s)" % len(registry.discover(args.discover)))
        managed = True
    if args.list:
        print(json.dumps({"projects": registry.list_projects()}, indent=2)); managed = True
    if managed:
        return 0

    if args.port is None:
        # No --port: use the stable home port with single-instance reuse / ephemeral fallback.
        return serve(args.root, DEFAULT_PORT, open_browser=args.open, default_port=True)
    return serve(args.root, args.port, open_browser=args.open)


if __name__ == "__main__":
    sys.exit(main())
