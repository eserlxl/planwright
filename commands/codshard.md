---
description: Run planwright shard-by-shard. Partitions the repo into component shards (top-level directories by default, or an explicit shards list), runs an ordinary scoped planwright cycle per shard sequentially in staleness order, then closes with a single whole-repo round that covers what no shard can see — cross-shard seams, root-level files, global concerns, and the only legitimate global final point. An opt-in `parallel` flag (Claude Code only) prefetches read-only recon leads per shard via subagents; the leads are routing-only re-verification seeds, never Evidence, and every other host simply runs without recon. An opt-in `explore` flag escalates the closing round only (`cycle <M> depth <D> explore`) — the shard loop never escalates, and `invent`/`seed` stay non-composable. With no arguments it auto-enumerates shards and runs cycle 3 depth 10 per shard.
argument-hint: "[M] [D] | shards <a,b,c> | parallel [J] | explore | (empty = auto-shards, cycle 3 depth 10 per shard)"
---

You are dispatching the **planwright** skill on behalf of the `/codshard` helper command.
Like `/codcycle`, this is an **orchestration** command, not a single-invocation alias: it sequences
several ordinary planwright invocations — one scoped cycle per shard, then one closing whole-repo
round. Do **not** re-implement any planwright logic here — each round is an ordinary planwright
cycle run, and planwright owns all planning/execute/cycle behaviour, the Focus/Context scope model,
the maturity ladder, scoped and global final points, and every stop condition. On Claude Code, each
round is the Skill tool invocation `planwright:planwright` with the round's argument string; on
other hosts, load `skills/planwright/SKILL.md` (or use the host's native skill invocation) once per
round with the same argument string.

Why shard: a scoped run concentrates its entire depth budget on one component — at any given depth,
Stage 2b reads its top function bodies *per shard* instead of *per repo* — so a shard-by-shard pass
reads strictly more code at the same depth than one whole-repo round, and each shard's findings are
drained through execute before the next shard starts, keeping plan-capacity pressure low. The
closing whole-repo round then covers exactly what no scoped round can see. Depth keeps its ordinary
planwright meaning throughout (per-round analysis intensity); sharding changes where attention goes,
never what `depth` means.

Raw arguments: `$ARGUMENTS`

Resolve them in this order:

0. **Peel the scope first.** If `$ARGUMENTS` contains a `path <X>` or `lib <X>` scope (the keyword
   plus its single following token, appearing anywhere), lift that pair out and let `<rest>` be the
   remaining tokens. For `/codshard` a peeled scope is not appended to the rounds — it becomes a
   **single-entry shard list** (exactly as if `shards <X>` had been passed), since shards *are*
   scopes here. In every planwright invocation below, `cycle` stays the **first token** planwright
   dispatches on, and the shard's `path <shard>` / `lib <shard>` trails the rest — never let
   `path`/`lib` lead. Also recognise the `--`-prefixed aliases when peeling, normalising to the bare
   form first: `--path <X>` → `path <X>`, `--lib <X>` → `lib <X>`, `--scope <X>` → `path <X>`
   (both `--opt <X>` and `--opt=<X>` spellings).

1. **Peel `shards <a,b,c>`** (one comma-separated token, no spaces) from `<rest>`: an explicit shard
   list. A bare-integer entry, or one matching an option keyword (`parallel`, `shards`, `help`,
   `path`, `lib`, `seed`, `explore`, `invent`), is a malformed list — print the `Usage:` line and
   STOP (catching the `shards path` typo class upfront beats a mid-run scope no-match). An entry containing `/` or naming an
   existing directory is a `path` shard; any other entry is a `lib` shard (planwright resolves the
   logical name). If a scope was also peeled in step 0, it joins the front of this list.

2. **Peel `parallel`** (optionally followed by an integer `J >= 1`, which binds to it) from
   `<rest>`: enables the Claude-Code-only recon prefetch described below. An integer below 1 does
   **not** bind — it stays in `<rest>` and falls through to step 4, where it is an invalid `M` and
   prints the `Usage:` line. Without `J`, recon agents for all shards are launched at once and the
   host caps concurrency. Peel this *before* classifying the remaining integers, so `J` is never
   mistaken for `M` or `D`.

3. **Peel `explore`** from `<rest>`: opt-in escalation for the **closing round only**. When
   present, the closing whole-repo round runs `cycle <M> depth <D> explore` instead of the plain
   closing cycle; the shard loop is never escalated — every per-shard round stays an ordinary
   scoped cycle. `invent` and `seed <S>` remain non-composable: if `<rest>` still contains either,
   print one line —
   `codshard: invent/seed are not composable with sharding (invent grows and runs to budget; the closing round exists to converge) — ignored; use /codinventor or /codcycle for invent.`
   — drop those tokens, and continue.

4. Classify what remains of `<rest>`:
   - **empty**: the defaults — `M = 3` per-shard cycles at `D = 10` (i.e. `cycle 3 depth 10` per
     shard, and the same for the closing round).
   - **one integer `M`** (`M >= 1`): per-shard cycle count; depth defaults to 10.
   - **two integers `M D`**: per-shard cycle count and depth. First number = cycles, second = depth.
   - **`help` / `--help` / `-h` / `?`**: print
     `Usage: /codshard [M] [D] [shards <a,b,c>] [parallel [J]] [explore]   (M >= 1; defaults: auto-enumerated top-level shards, cycle 3 depth 10 per shard; parallel recon is Claude-Code-only and routing-only; explore escalates the closing round only). Runs cycle <M> depth <D> path <shard> per shard sequentially, then one closing whole-repo round.`
     and STOP — do not run anything.
   - **anything else** (including `M < 1` or a non-integer leftover): print that same `Usage:` line
     and STOP.

**Shard enumeration** (only when no explicit list was given): the shards are the repo's
top-level directories that hold at least one git-tracked file (`git ls-files`, first path
segment), excluding
dot-directories and the tool-owned `.planwright/`. Root-level loose files are not a shard — the
closing whole-repo round covers them. A directory with fewer than 3 tracked files is folded into the
closing round instead of getting its own cycle (report which, in the banner's shard list, as
`folded: <dirs>`). When no shardable directory exists, K = 0: skip the shard loop and run only the
closing whole-repo round, saying so in the banner.

**Shard order** (deterministic): when `.planwright/graph.json` exists and parses, order shards by
staleness —
descending count of the shard's never-audited graph nodes (the graph's `frontier.never_audited`
predicate: non-test nodes with `branch_count > 0` and `last_audited_sha` null, restricted to the
shard's path prefix), tiebroken lexicographically by shard name — computed with one small read-only
pass over the file (use the ctx sandbox when available). Without a graph — or with a graph file
that exists but cannot be parsed — order is lexicographic, exactly as if no graph were present.
`lib` entries have no path prefix until planwright resolves them, so they keep their user-given
order after all `path` shards. The graph steers *order only* — it is routing, never Evidence.

For runnable cases, **first print exactly one cost-banner line** so this heavy run is never silent:
`codshard: sharded maturity sweep — <K> shard(s) in <staleness|lexicographic> order (<list>), each an ordinary scoped planwright run (cycle <M> depth <D> path|lib <shard>), then one closing whole-repo round (cycle <M> depth <D>) for cross-shard seams, root-level files, and global concerns.`
— appending ` parallel recon: <J> read-only agent(s), routing-only.` when `parallel` is active
(`<J>` prints as `all` when no count was given — the host caps concurrency), and
swapping the closing round's parenthetical to `(cycle <M> depth <D> explore)` when `explore` is
active (in both banner variants). At
`K = 0` print this variant instead:
`codshard: no shardable top-level directory — running only the closing whole-repo round (cycle <M> depth <D>).`

Then stamp the run-activity beacon so the dashboard's reactor names this run: resolve `<scripts>`
per planwright's **Procedure → Bundled scripts** rule (the skill base directory's
`../../scripts/`) and run `python3 <scripts>/state.py activity start codshard --root .` in the ctx
sandbox when available. The beacon is best-effort telemetry — if the script cannot run, skip it
and proceed; never block on it.

**Parallel recon (opt-in, Claude Code only).** When `parallel` was passed and the host exposes a
subagent primitive (Claude Code's Agent tool), launch — before the shard loop — one recon subagent
per selected `path` shard (`lib` shards get no recon — their paths resolve only inside planwright),
`J` at a time. Use a **read-only** agent type when the host offers one (Claude Code: the Explore
type); regardless of type, the recon prompt MUST state verbatim that the agent is read-only — no
file edits, no writes, no state, no mutating commands — and that it replies only with at most 8
candidate leads (`file:line — one-line suspected defect or gap`). The reply text is the only
artifact — codshard writes no files of its own, and leads live only in the conversation. Leads carry
the trust level of carried dossier candidates — **routing-only re-verification seeds** — but a
weaker obligation: a lead is an optional routing hint the executor consults from the conversation
while running that shard's round; nothing is appended to the planwright argument string. A lead may
steer which code that shard's cycle reads first, but it is **never Evidence** — every lead must be
re-proven from code re-read inside the shard's own cycle, or silently dropped. planwright's pipeline
itself stays single-agent; recon is a command-layer prefetch that spends extra model calls to buy
wall-clock, never a second source of truth. When the Agent tool is unavailable (any other host, or a
restricted session), print
`codshard: parallel recon unavailable on this host — continuing sequential without recon.`
and continue — recon never changes *what* is audited, only how fast attention warms up.

Then run the **shard loop** — always sequential (recon parallelises reading, never the rounds). For
each shard `i` (from 1 to `K`, in the order above):

- Print a header line `=== codshard shard i/K: <shard> ===`, re-stamping the beacon with the
  shard as its detail first: `python3 <scripts>/state.py activity start codshard --detail "shard i/K: <shard>" --root .`
  (best-effort, never block).
- Invoke planwright with `cycle <M> depth <D> path <shard>` (or `lib <shard>` for a lib entry).
  Wait for it to finish.
- A shard that converges records its **scoped final point**; by planwright's own rule that never
  suppresses a differently-scoped or whole-repo run — continue to the next shard.
- Record `commits_i` = the number of verified (committed) items planwright reported for this shard.

Between rounds, honour planwright's own stop conditions — do not paper over them: if any round stops
on a **hard blocker** (an item needing an unresolved design decision or undeclared surfaces) or a
**failing broad final verification**, STOP the whole codshard run immediately and report — do not
start the next shard **or the closing round** on a broken tree.

After the shard loop — whether it completed all `K` shards or was interrupted (but **not** when it
stopped on a broken tree) — run the closing phase **exactly once**:

- Print a header line `=== codshard closing whole-repo round ===`, re-stamping the beacon's
  detail to `closing whole-repo round` first (same invocation shape; best-effort, never block).
- Invoke planwright with `cycle <M> depth <D>` (unscoped) — or `cycle <M> depth <D> explore`
  (unscoped) when the `explore` flag was peeled in step 3. This round sees what no shard can:
  cross-shard seams, root-level files, build/CI/docs and other global concerns, and the
  project-wide opportunity/vision survey — so it is the **only** round that may legitimately
  declare the **global final point**. Per-shard scoped final points never aggregate into one.
  Explore composes here and only here because this round is already at the altitude escalation
  needs: its cold-frontier sweep and expand tier survey the whole repo — cross-shard seams
  included — and deepen the same global final point this round owns. Inside a shard, the same
  flag would only double-spend on the attention redistribution sharding itself provides, which
  is why the shard loop never escalates.

After the closing round (or an early stop), first remove the run-activity beacon:
`python3 <scripts>/state.py activity stop --root .` (best-effort, never block — this applies to
every way the run ends, including hard stops). Then print a short cumulative summary: shards completed (out
of `K`), the per-shard verified-commit counts in order (e.g. `commits 2 → 0 → 1 across shards
scripts → docs → tests`), whether the closing round ran and what it reported, total items
implemented across all rounds, whether the closing round escalated with `explore`, and the stop
reason (`completed`, `hard blocker`, or `broad-verify failed`).

Print nothing of your own except the cost banner, the one-line notes (invent/seed-ignored,
recon-unavailable), the per-shard and closing headers, and the final summary; each planwright round
prints its own per-cycle output, which stands as-is.
