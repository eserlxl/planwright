---
description: Launch the planwright dashboard — a local, read-only live web view of the planning state — and open it in your browser. Binds 127.0.0.1 on a stable default port (reusing an already-running instance) or `--port N`, and serves until you stop it. Read-only: it mirrors `.planwright/`, launches no agent, and never mutates the repo.
argument-hint: "[--port N] [--root DIR] | (empty = stable port, current repo, open browser)"
---

You are running the **`/dashboard`** command: start planwright's bundled **read-only**
dashboard server and open it in a browser. The dashboard is a *mirror* of the gitignored
`.planwright/` planning state — it launches no agent, edits nothing, and exposes no action
buttons. Everything below is read-only; nothing here may write to the repo.

Raw arguments: `$ARGUMENTS`

## 1 — Resolve the bundled script

`dashboard.py` ships **inside the planwright distribution**, not in the repo you are viewing.
Resolve `<scripts>` to the **absolute** path of that bundled `scripts/` directory once (the
same rule the other commands use), and call `<scripts>/dashboard.py`:

- Prefer the env var the host exports for plugin commands: `<scripts>` = `${CLAUDE_PLUGIN_ROOT}/scripts`.
- If it is unset, this command file lives at `<plugin>/commands/dashboard.md`, so the script is
  its sibling `../scripts/dashboard.py` — resolve that to an absolute path.

**Never invoke it as a bare `scripts/dashboard.py`** — the current working directory is the
*target* repo being mirrored, which has no planwright `scripts/` directory.

**By-hand fallback (no `python3`):** there is no server — tell the user to run
`/planwright status` (or read `.planwright/` directly) for a one-shot summary, and stop.

## 2 — Read arguments

From `$ARGUMENTS` (all optional; echo the canonical form you resolved):

- `--port <N>` (or bare `port <N>`) → bind that fixed port. With no `--port` the server binds a
  stable home port (`8765`) so the URL is bookmarkable, and a second launch attaches to the
  already-running instance instead of failing; `--port 0` picks an ephemeral port. The bound URL is
  printed in the banner.
- `--root <DIR>` (or a bare directory path) → the repo to mirror; default `.` (the current
  directory). `<DIR>` selects which repo's `.planwright/` the server reads — it is not a
  subtree view. With no registry this is a single-project view, exactly as before.
- `--add <DIR>` / `--remove <DIR>` / `--discover <PARENT>` / `--list` → **registry management**,
  not a serve: register/forget projects (or scan `<PARENT>` for children holding a `.planwright/`),
  print the registry, and exit without binding a port.

**Multiple projects from one server.** One dashboard can mirror many repos: the viewable set is a
user-level registry (`$XDG_CONFIG_HOME/planwright/projects.json`, outside any repo) that every
planwright run auto-populates, plus the `--add`/`--discover` flags above. The bottom-left name
becomes a **switcher**; selecting a project re-points the browser via `?project=<id>` (client-side,
so separate tabs can watch separate projects), and `/projects.json` feeds the switcher with each
project's live status. Selection is by **allow-listed id only, never a raw path** — the security
boundary that keeps the read-only mirror from reading arbitrary directories.

**Sandbox note.** The registry at `$XDG_CONFIG_HOME/planwright/projects.json` lives **outside the
workspace**, so under the default sandbox (which forbids writes outside the workspace) the
auto-populate and `--add`/`--discover` registry writes are **blocked** — the switcher then shows only
the current repo. To register projects in the global switcher, run the registering command
(`planwright dashboard --add <DIR>`, or a planwright run that auto-populates) **outside the sandbox**
(e.g. a `!`-prefixed shell command, or a normal terminal). The read-only serve itself needs no such
write and works sandboxed.

## 3 — Launch (do not block the turn)

Start the server **in the background** so this turn does not hang, and ask it to open the
browser:

```
python3 <scripts>/dashboard.py --root <root> [--port <N>] --open
```

Run it backgrounded (the harness background mode, or
`nohup … >.planwright/dashboard.log 2>&1 &` — a **workspace-relative** log path, since the default
sandbox forbids writes outside the workspace such as `/tmp`). Wait ~1 second, then read the banner
line **from that log file** (`.planwright/dashboard.log`) — not from command stdout, which the
redirect captured into the file —
`planwright dashboard: http://127.0.0.1:<port>/  (root: …)` — to learn the bound URL. The
`--open` flag best-effort opens that URL in the user's default browser (a harmless no-op on a
headless box). The server binds **loopback only** (`127.0.0.1`) and is read-only by
construction.

## 4 — Report and stop

Report the exact bound URL, that the view is **read-only and live** (it re-fetches whenever
`.planwright/` changes via a Server-Sent-Events stream), and how to stop it (Ctrl-C in its
terminal, or kill the backgrounded process / end the session). Then **STOP** — do not tail the
server log or block waiting on it. The dashboard keeps running on its own; its nine views —
**Console / Commands / Plan / Timeline / Graph / Insights / Shards / Fleet / Doctor** — update live as the plan evolves.
