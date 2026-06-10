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
#   GET /events      -> a Server-Sent Events stream that mtime-polls .planwright/ ~1s
#                       and pushes a `change` event whenever a file changes, so the
#                       browser re-fetches /state.json. One-directional (server->client).
#
#   python3 scripts/dashboard.py --root .            # bind 127.0.0.1 on an ephemeral port
#   python3 scripts/dashboard.py --root . --port 8765
#   python3 scripts/dashboard.py --root . --open     # also open the URL in a browser
#
# Bound to loopback (127.0.0.1) only and read-only by construction. Dynamic responses are
# sent no-store so the live view never reads a stale snapshot from the browser cache.

import argparse
import errno
import json
import os
import signal
import sys
import threading
import time
import webbrowser
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

# dashboard.py lives beside state.py/status.py/doctor.py in scripts/; that directory is
# sys.path[0] when run as a script, so a plain import resolves them.
import state
import doctor

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
MAX_SSE_CLIENTS = int(_env_float("PW_DASH_MAX_SSE_CLIENTS", 64))
_sse_slots = threading.BoundedSemaphore(MAX_SSE_CLIENTS)


def _planwright_dir(root):
    return os.path.join(root, ".planwright")


def _mtime_signature(root):
    """A cheap change signature for .planwright/: the sorted (name, mtime, size) of its
    files. Comparing successive signatures detects any add/remove/modify without reading
    file contents. A missing directory yields an empty signature (a valid state)."""
    pw = _planwright_dir(root)
    sig = []
    try:
        for name in sorted(os.listdir(pw)):
            fp = os.path.join(pw, name)
            try:
                st = os.stat(fp)
            except OSError:
                continue
            sig.append((name, st.st_mtime_ns, st.st_size))
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
        return self.server.planwright_root

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

    def do_GET(self):
        if not self._host_allowed():
            return self._send(403, "text/plain; charset=utf-8", "forbidden host")
        path = self.path.split("?", 1)[0]
        if path == "/state.json":
            return self._serve_state()
        if path == "/graph.json":
            return self._serve_graph()
        if path == "/doctor.json":
            return self._serve_doctor()
        if path == "/events":
            return self._serve_events()
        return self._serve_static(path)

    def _serve_state(self):
        try:
            body = json.dumps(state.collect(self.root), indent=2)
        except Exception as exc:  # never let a transient read error 500 the whole UI
            return self._send(500, "application/json; charset=utf-8",
                              json.dumps({"error": str(exc)}), self._NO_STORE)
        self._send(200, "application/json; charset=utf-8", body, self._NO_STORE)

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

    def _serve_graph(self):
        gp = os.path.join(_planwright_dir(self.root), "graph.json")
        try:
            with open(gp, "rb") as fh:
                body = fh.read()
        except OSError:
            return self._send(404, "application/json; charset=utf-8",
                              json.dumps({"error": "no graph built"}), self._NO_STORE)
        self._send(200, "application/json; charset=utf-8", body, self._NO_STORE)

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
            while True:
                sig = _mtime_signature(self.root)
                if sig != last:
                    last = sig
                    idle = 0.0
                    self._sse_write(b"event: change\ndata: 1\n\n")
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


def serve(root, port, open_browser=False):
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
            sys.stderr.write(
                "planwright dashboard: port %d is already in use — pick another with "
                "--port, or use --port 0 for an automatically-chosen free port\n" % port)
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
    ap.add_argument("--port", type=int, default=0,
                    help="port to bind on 127.0.0.1 (default: 0 = ephemeral, printed)")
    ap.add_argument("--open", action="store_true",
                    help="open the dashboard URL in a browser once the server is up")
    args = ap.parse_args()
    return serve(args.root, args.port, open_browser=args.open)


if __name__ == "__main__":
    sys.exit(main())
