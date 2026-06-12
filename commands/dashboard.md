---
description: Launch the planwright dashboard — a local, read-only live web view of the planning state — and open it in your browser. Binds 127.0.0.1 on an ephemeral port (or `--port N`) and serves until you stop it. Read-only: it mirrors `.planwright/`, launches no agent, and never mutates the repo.
argument-hint: "[--port N] [--root DIR] | (empty = ephemeral port, current repo, open browser)"
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

- `--port <N>` (or bare `port <N>`) → bind that fixed port, so the URL is stable across
  launches; default `0` (ephemeral, printed in the banner).
- `--root <DIR>` (or a bare directory path) → the repo to mirror; default `.` (the current
  directory). `<DIR>` selects which repo's `.planwright/` the server reads — it is not a
  subtree view.

## 3 — Launch (do not block the turn)

Start the server **in the background** so this turn does not hang, and ask it to open the
browser:

```
python3 <scripts>/dashboard.py --root <root> [--port <N>] --open
```

Run it backgrounded (the harness background mode, or `nohup … >/tmp/pw-dashboard.log 2>&1 &`).
Wait ~1 second, then read the banner line it prints —
`planwright dashboard: http://127.0.0.1:<port>/  (root: …)` — to learn the bound URL. The
`--open` flag best-effort opens that URL in the user's default browser (a harmless no-op on a
headless box). The server binds **loopback only** (`127.0.0.1`) and is read-only by
construction.

## 4 — Report and stop

Report the exact bound URL, that the view is **read-only and live** (it re-fetches whenever
`.planwright/` changes via a Server-Sent-Events stream), and how to stop it (Ctrl-C in its
terminal, or kill the backgrounded process / end the session). Then **STOP** — do not tail the
server log or block waiting on it. The dashboard keeps running on its own; its eight views —
**Console / Commands / Plan / Timeline / Graph / Insights / Shards / Doctor** — update live as the plan evolves.
