# planwright

> **Important:** Be sure to replace `/absolute/path/to/planwright` with the actual path where you cloned this repository on your machine.

@Antigravity, please read `/absolute/path/to/planwright/skills/planwright/SKILL.md` to understand the planwright workflow. Note that when the skill instructions refer to `<scripts>`, they mean `/absolute/path/to/planwright/scripts`. I want you to act as the planwright agent when I run the command planwright.

In addition, support these shortcut commands:
- `codvisor [cycles] [depth]`: This is a helper command that forwards to `planwright cycle <cycles> depth <depth> explore` (defaults to cycles=10, depth=10 if omitted).
- `codinventor [cycles] [depth]`: This is the invent twin of codvisor. It forwards to `planwright cycle <cycles> depth <depth> invent` (defaults to cycles=10, depth=10 if omitted).
- `codcycle [N]`: The explore→invent alternator. Follow the orchestration recipe in `/absolute/path/to/planwright/commands/codcycle.md`: N outer cycles (default 10; negative = infinite), each one `cycle 3 depth 10 explore` then a framing-rotated `cycle 3 depth 10 invent`, with one closing explore; each phase is an ordinary planwright run.
- `codshard [args]`: The sharded maturity sweep. Follow the orchestration recipe in `/absolute/path/to/planwright/commands/codshard.md`: one scoped `cycle 3 depth 10` round per shard sequentially (staleness order), then one closing whole-repo round; each round is an ordinary planwright run.
- `codmaster [advise | [safe] [loop]] [path <X> | lib <X>]`: The front door. Follow the orchestration recipe in `/absolute/path/to/planwright/commands/codmaster.md`: sense via `python3 /absolute/path/to/planwright/scripts/status.py --root . --recommend`, dispatch the record's command as an ordinary planwright run, re-sense, and repeat to the final point at depth 10 (never re-derive the recommendation in prose; if the engine cannot run, stop). With a peeled `path <X>` / `lib <X>` scope, thread it into the sense engine (`... status.py --root . --recommend --scope path:<X>`) so pending/debt/convergence are Focus-restricted, and trail the bare scope after every dispatch; a scoped drive never auto-routes `codshard` or `reset` (whole-repo moves), so the harden stays a scoped `codvisor`.

For the codvisor/codinventor shortcuts, first peel any `path <X>` or `lib <X>` pair from the arguments, resolve the remaining shortcut form, then append that scope after the resolved subcommand. Also accept the `--`-prefixed aliases, normalising to the bare form first: `--path <X>` → `path <X>`, `--lib <X>` → `lib <X>`, `--scope <X>` → `path <X>` (both `--opt <X>` and `--opt=<X>` spellings). Examples: `codvisor path src/auth/` resolves to `planwright cycle 10 depth 10 explore path src/auth/`; `codinventor 5 8 lib parser` resolves to `planwright cycle 5 depth 8 invent lib parser`.

# context-mode — MANDATORY routing rules

context-mode MCP tools available. Rules protect context window from flooding. One unrouted command dumps 56 KB into context. Antigravity has NO hooks — these instructions are ONLY enforcement. Follow strictly.

## Think in Code — MANDATORY

Analyze/count/filter/compare/search/parse/transform data: **write code** via `mcp__context-mode__ctx_execute(language, code)`, `console.log()` only the answer. Do NOT read raw data into context. PROGRAM the analysis, not COMPUTE it. Pure JavaScript — Node.js built-ins only (`fs`, `path`, `child_process`). `try/catch`, handle `null`/`undefined`. One script replaces ten tool calls.

## BLOCKED — do NOT use

### curl / wget — FORBIDDEN
Do NOT use `curl`/`wget` via `run_command`. Dumps raw HTTP into context.
Use: `mcp__context-mode__ctx_fetch_and_index(url, source)` or `mcp__context-mode__ctx_execute(language: "javascript", code: "const r = await fetch(...)")`

### Inline HTTP — FORBIDDEN
No `node -e "fetch(..."`, `python -c "requests.get(..."` via `run_command`. Bypasses sandbox.
Use: `mcp__context-mode__ctx_execute(language, code)` — only stdout enters context

### Direct web fetching — FORBIDDEN
No `read_url_content` for large pages. Raw HTML can exceed 100 KB.
Use: `mcp__context-mode__ctx_fetch_and_index(url, source)` then `mcp__context-mode__ctx_search(queries)`

## REDIRECTED — use sandbox

### Shell (>20 lines output)
`run_command` ONLY for: `git`, `mkdir`, `rm`, `mv`, `cd`, `ls`, `npm install`, `pip install`.
Otherwise: `mcp__context-mode__ctx_batch_execute(commands, queries)` or `mcp__context-mode__ctx_execute(language: "shell", code: "...")`

### File reading (for analysis)
Reading to **edit** → `view_file`/`replace_file_content` correct. Reading to **analyze/explore/summarize** → `mcp__context-mode__ctx_execute_file(path, language, code)`.

### Search (large results)
Use `mcp__context-mode__ctx_execute(language: "shell", code: "grep ...")` in sandbox.

## Tool selection

1. **GATHER**: `mcp__context-mode__ctx_batch_execute(commands, queries)` — runs all commands, auto-indexes, returns search. ONE call replaces 30+. Each command: `{label: "header", command: "..."}`.
2. **FOLLOW-UP**: `mcp__context-mode__ctx_search(queries: ["q1", "q2", ...])` — all questions as array, ONE call.
3. **PROCESSING**: `mcp__context-mode__ctx_execute(language, code)` | `mcp__context-mode__ctx_execute_file(path, language, code)` — sandbox, only stdout enters context.
4. **WEB**: `mcp__context-mode__ctx_fetch_and_index(url, source)` then `mcp__context-mode__ctx_search(queries)` — raw HTML never enters context.
5. **INDEX**: `mcp__context-mode__ctx_index(content, source)` — store in FTS5 for later search.

## Parallel I/O batches

For multi-URL fetches or multi-API calls, **always** include `concurrency: N` (1-8):

- `mcp__context-mode__ctx_batch_execute(commands: [3+ network commands], concurrency: 5)` — gh, curl, dig, docker inspect, multi-region cloud queries
- `mcp__context-mode__ctx_fetch_and_index(requests: [{url, source}, ...], concurrency: 5)` — multi-URL batch fetch

**Use concurrency 4-8** for I/O-bound work (network calls, API queries). **Keep concurrency 1** for CPU-bound (npm test, build, lint) or commands sharing state (ports, lock files, same-repo writes).

GitHub API rate-limit: cap at 4 for `gh` calls.

## Output

Write artifacts to FILES — never inline. Return: file path + 1-line description.
Descriptive source labels for `search(source: "label")`.

## ctx commands

| Command | Action |
|---------|--------|
| `ctx stats` | Call `stats` MCP tool, display full output verbatim |
| `ctx doctor` | Call `doctor` MCP tool, run returned shell command, display as checklist |
| `ctx upgrade` | Call `upgrade` MCP tool, run returned shell command, display as checklist |
| `ctx purge` | Call `purge` MCP tool with confirm: true. Warns before wiping knowledge base. |

After /clear or /compact: knowledge base and session stats preserved. Use `ctx purge` to start fresh.
