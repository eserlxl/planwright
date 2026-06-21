---
description: Shorthand for the planwright skill's `pr` subcommand. Forwards to planwright; with no arguments it ingests the current branch's open PR — its unresolved review threads and failing CI — as grounded plan items. `handoff` prints the local push-back recipe. planwright stays read-only toward GitHub.
argument-hint: "handoff | <N> | [planwright args] | (empty = pr ingest of current branch PR)"
---

You are dispatching the **planwright** skill on behalf of the `/codpr` helper command.
Do **not** re-implement any planwright logic here — resolve the arguments below, then invoke
the planwright skill with the resolved argument string, and let the skill do everything else
(it owns the whole `pr` ingest/handoff procedure, the routing-only-never-Evidence trust model, and
the read-only-toward-GitHub contract). On Claude Code, that hand-off is the Skill tool invocation
`planwright:planwright`; on other hosts, load `skills/planwright/SKILL.md` or use the host's native
skill invocation with the same resolved argument string.

Raw arguments: `$ARGUMENTS`

`/codpr` is a thin alias for the planwright **`pr`** subcommand — every form simply prefixes `pr`:

1. **No arguments**: invoke planwright with `pr` — ingest the current branch's open PR. Its
   unresolved review threads (human or bot) and failing CI checks become verification-ready plan
   items for the usual `check` → `execute` path. planwright only *reads* GitHub; it writes nothing
   back, implements nothing, and never mutates the PR.
2. **`handoff`**: invoke planwright with `pr handoff` — print the **local** git/gh push-back recipe
   for already-landed PR fixes. The operator runs it by hand; planwright never writes to GitHub
   (merging the PR is the close — there is no separate close step).
3. **Anything else** (e.g. an explicit PR number `123`): invoke planwright with `pr $ARGUMENTS`, so
   `codpr 123` → `pr 123` and any future `pr` option rides along unchanged.

After resolving, invoke the planwright skill once with the resolved arguments. Print nothing of your
own — the `pr` subcommand is a quick, read-only ingest, so there is no cost banner.
