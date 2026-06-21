---
description: Run planwright shard-by-shard. Partitions the repo into component shards (top-level directories by default, or an explicit shards list), runs an ordinary scoped planwright cycle per shard sequentially in staleness order, then closes with a single whole-repo round that covers what no shard can see — cross-shard seams, root-level files, global concerns, and the only legitimate global final point. An opt-in `parallel` flag is forwarded to each per-shard planwright run, whose Stage 1.6 runs the read-only recon prefetch over that shard's Focus (native subagent by default, or the entirely optional external-agent CLI backend on `parallel external`); the leads are routing-only re-verification seeds, never Evidence. An opt-in `explore` flag escalates the closing round only (`cycle <M> depth <D> explore`) — the shard loop never escalates, and `invent`/`seed` stay non-composable. With no arguments it auto-enumerates shards and runs cycle 3 depth 10 per shard.
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
   logical name). If a scope was also peeled in step 0, it joins the front of this list **keeping the
   explicit type its keyword named** — `path <X>` is a path shard, `lib <X>` is a lib shard — so the
   filesystem-presence reclassification above applies only to keyword-less `shards` entries and never
   overrides an explicit `lib <X>` whose directory happens to exist on disk.

2. **Peel `parallel`** (optionally a backend qualifier `agent` or `external`, then an integer
   `J >= 1`, which binds to it) from `<rest>`: it is **forwarded to each per-shard planwright run**,
   whose **Stage 1.6** runs the recon (recon lives in the base skill now — see the forwarding note
   below). Bare `parallel` and `parallel agent` select planwright's **native subagent** backend (no
   external egress); `parallel external` selects the external-agents CLI backend (it runs wherever the
   agy/codex/claude CLIs are installed, and is how recon is *delegated to external agents*). That external backend is **entirely optional**: planwright never requires the
   external-agents plugin or any paid CLI (no OpenAI/Google subscription is needed to use
   planwright), and it is never auto-engaged — only `parallel external` reaches a third-party
   provider. The qualifier, when present, is `agent` or `external` immediately after
   `parallel`, and `J` follows it; any other token after `parallel` is not a qualifier — it stays in
   `<rest>` (so `parallel 3` leaves `3` as the cycle count `M`). An integer below 1 does **not** bind — it stays in `<rest>` and falls through to
   step 4, where it is an invalid `M` and prints the `Usage:` line. Without `J`, recon agents for
   all shards are launched at once and the host caps concurrency. Peel `parallel`, any qualifier,
   and `J` *before* classifying the remaining integers, so neither the qualifier nor `J` is ever
   mistaken for `M` or `D`.

2b. **Peel `hybrid-ai`** from `<rest>`: an opt-in **dossier-survey delegation**, **forwarded to each
   per-shard planwright run and the closing whole-repo round**, whose base-skill Stages 3–7 survey is
   then delegated to the optional external-agent CLI backend (never-Evidence, off==skipped). Delegation
   lives in the base skill — codshard only forwards `<hybrid-ai>`, never re-implements it. Peel it
   before classifying the remaining integers.

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
     `Usage: /codshard [M] [D] [shards <a,b,c>] [path <X> | lib <X>] [parallel [J]] [explore]   (M >= 1; defaults: auto-enumerated top-level shards, cycle 3 depth 10 per shard; a path/lib scope becomes a single-entry shard list; parallel recon is host-neutral (native subagents or external-agent CLIs) and routing-only; explore escalates the closing round only). Runs cycle <M> depth <D> path <shard> per shard sequentially, then one closing whole-repo round.`
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
— appending ` parallel recon: <J> read-only agent(s) via the <backend> backend, routing-only.` when
`parallel` is active (the `<backend>` is `native subagents` for bare `parallel`/`parallel agent`, or
the optional `external-agent CLIs` — which ship each shard tree to external providers, agy read-only
best-effort — only for an explicit `parallel external`; `<J>` prints as `all` when no count was given
— the host caps concurrency), and
swapping the closing round's parenthetical to `(cycle <M> depth <D> explore)` when `explore` is
active (in both banner variants). At
`K = 0` print this variant instead:
`codshard: no shardable top-level directory — running only the closing whole-repo round (cycle <M> depth <D>).`

Then stamp the run-activity beacon so the dashboard's reactor names this run: resolve `<scripts>`
the same way `/dashboard` does — prefer the host-exported `${CLAUDE_PLUGIN_ROOT}/scripts`, else
this command file's sibling `../scripts/` (never a bare `scripts/`, which resolves against the
target repo) — and run `python3 <scripts>/state.py activity start codshard --root .` in the ctx
sandbox when available. The beacon is best-effort telemetry — if the script cannot run, skip it
and proceed; never block on it.

Also record the **run-start ref** here — `git rev-parse HEAD` (best-effort) — the HEAD the sweep
opens at; it is the `--since` anchor for the run-close reconciliation below.

**Parallel recon (opt-in, forwarded to planwright).** Recon now lives in the base skill — when
`parallel` was peeled (step 2), **append it to each per-shard planwright run** (e.g.
`cycle <M> depth <D> path <shard> parallel external`), and planwright's **Stage 1.6** runs the
read-only recon prefetch over that shard's Focus before its audit (the full backend ladder, the
read-only contract, the external-agents discovery, and the degrade-to-no-recon fallback all live in
`skills/planwright/SKILL.md`). codshard does **not** run recon itself: the leads stay **routing-only**
re-verification seeds, **never Evidence**, re-proven inside each shard's own single-agent run. The
shard rounds stay strictly sequential — recon parallelises only the reading inside each run, never the
rounds. `parallel external` is the explicit, **entirely optional** external-agent CLI backend
(planwright never requires it, and it is never auto-engaged); bare `parallel`/`parallel agent` use the
native subagent backend. Both `path` and `lib` shards get the prefetch — planwright resolves each
shard's Focus.

Then run the **shard loop** — always sequential (recon parallelises reading, never the rounds). For
each shard `i` (from 1 to `K`, in the order above):

- Print a header line `=== codshard shard i/K: <shard> ===`, re-stamping the beacon with the
  shard as its detail first: `python3 <scripts>/state.py activity start codshard --detail "shard i/K: <shard>" --root .`
  (best-effort, never block).
- Invoke planwright with `cycle <M> depth <D> path <shard>` (or `lib <shard>` for a lib entry) —
  **appending `parallel [agent|external]` when it was peeled in step 2**, so planwright's Stage 1.6
  runs the recon prefetch over this shard's Focus. Wait for it to finish.
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

After the closing round (or an early stop), first **reconcile the run's commits** — the mechanical
safety net behind SKILL.md's completion-accounting invariant: a shard or closing round that
committed a fix inline without landing it would otherwise silently miss `completed.md`, the only
file the dashboard reads. Run
`python3 <scripts>/lifecycle.py reconcile-sweep --since <run-start ref> --mode repair --root .planwright`
(same `<scripts>` as the beacon) — it records every non-merge, non-release commit since the
run-start ref that `completed.md` does not already carry, idempotently and git-verified; best-effort,
never block (per-item `land` stays the primary path, the sweep only catches drift). Then remove the run-activity beacon:
`python3 <scripts>/state.py activity stop --root .` (best-effort, never block — this applies to
every way the run ends, including hard stops). Then print a short cumulative summary: shards completed (out
of `K`), the per-shard verified-commit counts in order (e.g. `commits 2 → 0 → 1 across shards
scripts → docs → tests`), whether the closing round ran and what it reported, total items
implemented across all rounds, whether the closing round escalated with `explore`, and the stop
reason (`completed`, `hard blocker`, or `broad-verify failed`).

Print nothing of your own except the cost banner, the one-line notes (invent/seed-ignored,
recon-unavailable), the per-shard and closing headers, and the final summary; each planwright round
prints its own per-cycle output, which stands as-is.
