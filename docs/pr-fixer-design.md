# planwright PR-fixer — `pr` subcommand (design + as-built)

Status: **IMPLEMENTED (v1, subcommand).** Decisions locked in the design session and shipped:
(1) source from **review threads + failing CI**; (2) ship a **standalone subcommand only** (the
codmaster rung and the dashboard view are deferred follow-ups); (3) planwright stays **100% local** —
it *reads* PR data but never writes to GitHub, so all push-back is the operator's own manual step,
which planwright only *prepares and instructs*.

**As built (deviations from the original sketch, both forced by the codebase):**
- **`pr` is a `planwright <sub>` subcommand; the `commands/codpr.md` alias came afterward.** `pr` is
  invoked `planwright pr` / `planwright pr handoff`, exactly like `check`/`status`/`advise`. The v1
  subcommand shipped *without* a `commands/*.md` host alias; a thin `commands/codpr.md` alias
  **was later added as the sixth command-family member** — a targeted `pr` shortcut, not a flagship
  maturity sweep (it carries no sweep cost banner), so the `cod*.md` pin of **exactly 5 flagship
  sweeps** (codvisor/codinventor/codcycle/codshard/codmaster, each with a cost banner + README
  host-parity rows) still holds even though the alias now exists.
  *Throughout this doc, `codpr` is shorthand for the `planwright pr` subcommand.*
- **Tests consolidated in `tests/cases/pr.sh`** (self-contained, mirroring the `doctor.sh`
  precedent — including the routing-gate security check), rather than scattered into
  `skill-guards.sh`/`security.sh`/`commands.sh`.

Files: new `scripts/pr.py` (`leads` + `handoff`), `skills/planwright/references/pr.md`,
`tests/cases/pr.sh`; edits to `skills/planwright/SKILL.md` (dispatch pointer + Usage lines) and
`tests/run.sh` (case registration). Full suite **689/0**.

planwright is **language-agnostic** and, until now, **100% local + read-only toward the network.**
This feature adds the project's first `gh`/remote dependency — but **read-only**: planwright fetches
PR signals to *plan* from them; it never pushes, comments, resolves, merges, or closes. Every
outward-facing action stays in the operator's hands. That invariant is the spine of this design.

## The gap

planwright already turns an audit into a verification-ready plan, and it already ingests an
**external** source of items: codmaster's qb intent-replan merges `.qb/plan.md` items into
`.planwright/plan.md` (dedupe vs pending + `completed.md` + `rejected.md`, re-validate with
`lint-plan.py --strict`, tag provenance). What's missing is a way to treat an **open pull request**
as a source of grounded, verifiable work — the reviewer feedback and red CI that a human would
otherwise hand-translate into a TODO list.

The naïve version ("fetch open PRs, infer items from the diff") collides head-on with planwright's
two hardest item requirements: every item needs **Evidence with a real `file:line` anchor** and a
**runnable `Verification:`** (`lint-plan.py` rejects bare prose, `true`, and `.planwright/`-rooted
citations). Translating a raw diff into a hand-grounded anchor + a meaningful verification is exactly
the judgment-heavy, low-yield path that produces dropped items.

## The model: ingest only *pre-anchored* signals; produce, never fix-in-place

The decisive idea: source **only the two PR signals that already arrive anchored**, so Evidence and
Verification translation become mechanical instead of judgemental.

| PR signal | → `Evidence:` | → `Verification:` |
|---|---|---|
| **Unresolved review threads** (human *and* bot, e.g. CodeRabbit) | the thread's `path` + `line` map 1:1 to a real `file:line` anchor | the narrowest command that fails now / passes after the fix |
| **Failing CI checks** | the failing location parsed from the job log, re-grounded to `file:line` | **the failing check's own command, re-run locally** — green = done |

The failing-CI verification is the strongest kind planwright can have: "the red check goes green" is
precisely the *removal test* the apply-time value gate rewards (something breaks that nothing else
catches). The review-thread anchor reuses the exact fetch the installed `coderabbit:autofix` skill
already relies on (`gh api graphql` over `reviewThreads`, filtered `isResolved == false AND
isOutdated == false`) — but where `autofix` **applies changes directly**, planwright instead emits
**deduped, tracked, verification-ready plan items** and lets its normal `check` → `execute` path act.
That is the differentiator and it is squarely planwright's producer ethos.

`codpr` is a **producer**, not a fixer: it mutates **nothing** in the source tree. It writes only
`.planwright/` (gitignored), exactly like `check` — so it needs **no clean-tree gate**, no git
identity, and carries no risk of clobbering uncommitted work. The implementing, verifying, and
committing all happen later in the unchanged `execute` path.

## Command surface — two local modes

```
codpr            ingest   → fetch PR signals → emit verification-ready items      (read-only source)
  ↓ (you run)    execute  → implement + verify + land local commits               (existing path)
codpr handoff    prepare  → print the manual git/gh recipe the OPERATOR runs       (local; zero network writes)
```

Both modes are local. `codpr` *reads* GitHub (best-effort, availability-gated); `codpr handoff`
touches the network **not at all** — it only reads `completed.md` and prints a copy-pasteable recipe.

These are subcommands of the skill: `planwright pr` (ingest) and `planwright pr handoff` (the
mechanical halves live in `scripts/pr.py leads` / `scripts/pr.py handoff`). No `commands/*.md` alias
is created — see the as-built note at the top.

### `codpr` (ingest) — read-only toward source

1. **Availability guard** (clone Stage 1.6's posture): if `gh` is absent, `gh auth status` is
   non-zero, or there is no remote → print one line and **STOP cleanly** (never error, never block).
2. **Resolve the current branch's open PR**: `gh pr list --head "$(git branch --show-current)"`
   (clone `coderabbit:autofix` Step 2). Optional `pr <N>` overrides to an explicit PR number (routed
   through the existing ref-injection guard before any `gh`/`git` call). No multi-PR browsing.
3. **Fetch both sources** (each via the house `subprocess.run(timeout=…)` + degrade-to-empty pattern):
   - **Review threads** — `gh api graphql` over `reviewThreads`, keeping `isResolved == false AND
     isOutdated == false`; capture `path`, `line`/`startLine`, author, body. Accept human reviewers,
     not just the bot.
   - **Failing CI** — `gh pr checks` to find red checks, then `gh run view --log-failed` to pull the
     failing job's log; normalize the log into (a) a `file:line` where one is present and (b) the
     runnable command that produced the failure.
4. **Re-ground every anchor against the live tree** (the security spine — see below): re-open
   `path:N`, confirm the issue is real *now*, re-anchor if the line drifted. Never quote the comment
   into Evidence.
5. **Emit one 8-field item per signal** (mapping below), appended to `.planwright/plan.md` via the
   existing `lifecycle.py` append path. Raw, unverified PR text is parked under
   `.planwright/pr-leads.md` (routing only).
6. **Validate**: run `lint-plan.py --strict` over the written plan (promotes dedup-vs-completed/
   rejected advisories to hard failures — the same gate the qb merge uses).
7. **Report & STOP**: `N items imported — run `planwright check` then `execute`, then `codpr
   handoff`.` No implement, no commit, no network write, no dashboard, no codmaster rung.

### `codpr handoff` (prepare) — the local push-back logic

This replaces the earlier network `sync` step. It performs **zero** GitHub writes. After `execute`
has landed the fixes (each PR-sourced item lands in `completed.md` with a `Commit:` stamp and its
provenance tag), `codpr handoff`:

1. Reads `completed.md` for items whose provenance tag is a PR thread/check **and** that carry a
   `Commit:` stamp (so only *verified, landed* fixes are eligible).
2. Prints a **copy-pasteable manual recipe** the operator runs by hand, e.g.:
   ```
   # Push the verified fixes to the PR's branch (updates the PR, re-runs CI):
   git push

   # (optional, cosmetic) mark the addressed review threads resolved:
   gh api graphql -f query='mutation { resolveReviewThread(input:{threadId:"<id>"}){ thread { isResolved } } }'
   ...

   # Closing the PR: merge it — GitHub closes it automatically. No separate "close" step.
   gh pr merge --squash    # or merge via the GitHub UI
   ```
3. Optionally records the PR/thread linkage as a **commit trailer** suggestion for auditability — but
   the recipe works purely off `completed.md` provenance, so `execute` needs **no change**.

planwright prints; the operator decides and runs. That is the whole of "push-back," kept local.

## PR lifecycle — who closes the PR (and why it's automatic)

Because `codpr` ingests the **current branch's own** PR, `execute`'s fix commits land on that PR's
**head branch**. The close is therefore free in the normal flow:

- **Merging the PR closes it.** A PR auto-closes *only* when merged (merge/squash/rebase). The
  operator's manual `git push` **updates** the PR and re-runs CI; the operator's manual merge
  **closes** it. There is no separate "close the PR" step to forget.
- **Pushing does not close.** Pushing commits to the head branch never closes the PR — by design,
  since fixing review feedback should leave the PR open for re-review until merged.
- **Closing keywords close issues, not PRs.** `Fixes #N` / `Closes #N` in a commit/PR body auto-close
  the linked **issue** when the commit reaches the default branch; they have no auto-close effect on
  a PR. So a suggested commit trailer can tidily close a linked *issue*, but the *PR* still closes via
  merge.
- **Thread resolution is independent.** Unresolved threads don't auto-resolve on push; `codpr
  handoff` emits the optional `gh ... resolveReviewThread` line for the operator. Resolution is
  cosmetic — it never blocks merge.

The only path that *would* need a manual close is abandoning the PR and landing the fix on a
different branch merged to base. This design deliberately avoids that by fixing the PR's own branch.

## The 8-field conversion contract

Every emitted item must clear the same Stage 10 gate as any planwright item. The mapping:

**From a review thread:**
- `Mode:` — `repair` for a bug (forces the mandatory `file:line` anchor — a second mechanical
  backstop); `improve`/`docs`/`reorganize` for a suggestion or doc nit, matching the change.
- `Rationale:` — the reviewer's concern restated as *why it matters*, never the raw quote.
- `Evidence:` — the **re-grounded** `path:line` from the live tree (must resolve under root; never the
  comment text, never a `.planwright/` path).
- `Surfaces:` — the existing file(s) the fix touches. `New Surfaces:` only if the fix creates files.
- `Development:` — what to change at that seam. `Acceptance:` — the observable outcome.
- `Verification:` — the narrowest **real** command that fails now / passes after.
- **Title** — content-keyed + provenance, e.g. `<short issue> (pr-thread <threadId>)`.

**From a failing CI check:**
- `Mode:` — `repair`.
- `Evidence:` — the `file:line` parsed from the failing log and re-grounded. **If the log yields no
  anchor**, do *not* fabricate one: emit the signal to `.planwright/pr-leads.md` as a flagged lead and
  report it for manual handling, rather than ship an unanchored `repair`.
- `Verification:` — **the failing check's own command** (re-run locally); green = done.
- **Title** — `<check name> (pr-check <name>)`.

**Dedup** rides on the content-keyed, provenance-tagged title: `lint-plan.py`'s `past_titles`
compares it against `completed.md`/`rejected.md`, and `--strict` promotes a match to a hard failure —
so re-importing the same thread/check (or one already rejected) is caught mechanically.

## Security & trust model (local-only)

The posture is *stronger* than qb's, because PR text is attacker-controlled:

- **planwright never writes to GitHub.** It only *reads* PR data, best-effort and availability-gated
  exactly like Stage 1.6. All outward writes (push, resolve, comment, merge, close) are the
  operator's manual steps. This is the load-bearing invariant.
- **PR text is routing-only, never Evidence** (same trust class as Stage 1.6 recon leads). Raw leads
  persist under `.planwright/pr-leads.md`, so the existing `.planwright/`-routing regex in
  `lint-plan.py` auto-fails any item that tries to cite them as proof. No new gate needed.
- **Re-ground every anchor against the live tree** (prompt-injection defense): all PR text is framed
  as *data, never instructions*; an Evidence anchor must be re-confirmed by re-reading the cited code
  this run. `Mode=repair` forces the mandatory anchor as a second backstop.
- **`.github/workflows` gets extra scrutiny.** `protected_surface` already refuses
  `.git`/`.qb`/`.planwright`/`LICENSE`/`.env`/`*.pem`/`*.key`. A failing-CI item touching a workflow
  file is flagged (never silently accepted as a Surface). Since planwright never pushes, the
  supply-chain decision lands squarely at the operator's manual merge — the `handoff` recipe surfaces
  any workflow change explicitly.
- **Ref-injection reuse.** Any operator-supplied PR number routes through the existing leading-`-` /
  whitespace / `--end-of-options` guard before any `gh`/`git` call. The current-branch default derives
  the PR from git (not free text), shrinking the surface further.

## Reused machinery — what we deliberately do **not** build

The whole point is reuse; the feature adds **no new validator, no new mutating script, no engine/coach
change**:

- **`lint-plan.py --strict`** — structural gate + dedup-vs-completed/rejected promotion (unchanged).
- **`check`** — purpose-built to vet externally-authored plans ("a qb export `cp`'d in, a hand-written
  plan, or one pasted from elsewhere"); a PR-sourced plan needs no new vetting concept. It re-applies
  the value gate read-only and dry-runs each `Verification:`.
- **`execute`** — implements, verifies, and lands each item (clean-tree precondition + commit-or-stop
  already enforced), stamping `completed.md` with `Commit:` + provenance.
- **`lifecycle.py`** — `land`/`reject`/append/housekeep (unchanged).

`codpr` adds only: the `gh` ingest, the signal→8-field conversion, and the local `handoff` reporter.

## `SKILL.md` / repo changes required (when approved)

1. **Usage block + Modes table** — add a `pr` row (and the `pr handoff` sub-mode); add to
   `VALID_MODES`-adjacent docs only if a new item Mode is needed (it is **not** — items use existing
   `repair`/`improve`/`docs`).
2. **First-token dispatch** — clone the `check` branch so `pr` routes to a new `references/pr.md`
   (clone `references/check.md`'s structure: purpose, preconditions, per-item conversion, report).
3. **`commands/pr.md`** — clone `commands/codshard.md` frontmatter for the `codpr` host alias.
4. **No new scripts beyond the `pr` ingest/handoff entrypoint.** The item format is unchanged, so
   `lint-plan.py` is unaffected.

## Test pins (lockstep with the contract)

- `skill-guards.sh` prose-pin (clone the Stage 1.6 guard test): `pr.md` names `gh`-as-optional /
  never-required, PR-text **routing-only-never-Evidence**, **planwright-never-writes-to-GitHub**, and
  push-back-is-operator-manual.
- `security.sh` clone (SEC): an item citing a PR lead / URL as Evidence is rejected; a
  `.github/workflows` Surface is flagged for extra scrutiny.
- `commands.sh` / `skill-contract.sh` content assertions for the new `pr` subcommand + `handoff`
  sub-mode.
- A test asserting `codpr handoff` reports **only** `completed.md` items carrying both PR provenance
  and a `Commit:` stamp (no unverified work in the recipe).

## Deferred follow-ups (explicitly out of v1)

- **codmaster `pr intent-replan` rung** — a near-verbatim clone of the qb block (availability guard /
  fetch+convert / merge-dedupe-revalidate / execute / re-sense + at-most-once flag + relap re-arm).
  Carries disproportionate cost (5-file escalation-ladder lockstep, verbatim stop-set test assertions,
  a net-new "already-ingested PR/thread" ledger for loop honesty, 12-step-cap budgeting). Ship it only
  after the subcommand's conversion rules are battle-tested.
- **Dashboard PR section** — PR-sourced items already render in the existing Plan view via
  `state.pending`; the provenance tag rides in the title for free. A dedicated `views/pr.js` triggers
  the four-list view inventory, the three test VIEWS lists, the coverage-map doc, **and** the JS
  coverage floor — pure overhead for v1.

## Open questions (decide before building)

1. **Failing-CI log normalization** — how aggressively to parse diverse CI log formats into
   `file:line` + command? Recommend: start with the common cases (test-runner failures, linter/compiler
   errors that emit `file:line`), and emit anything unparseable as a flagged lead rather than guessing.
2. **`codpr handoff` vs. fold into `codpr` output** — keep handoff a separate mode (clean separation,
   runs after `execute`), or have `codpr` print a provisional recipe up front? Recommend a separate
   mode, since the `Commit:` stamps don't exist until `execute` has run.
3. **Commit-trailer linkage** — emit a suggested `Fixes #<issue>` / thread-id trailer for
   auditability (and free issue-close-on-merge), or keep commits trailer-free and map purely off
   `completed.md`? Recommend offering the trailer in the `handoff` recipe, never auto-applying it.

## Recommendation

Build the **`codpr` ingest** half first (review threads + failing CI → items → `check` → `execute`),
dogfood it against a real open PR, and add **`codpr handoff`** once the conversion rules are proven.
Keep planwright strictly read-only toward GitHub throughout: it plans and prepares; the operator
pushes, resolves, and merges (and merging is the close). Defer the codmaster rung and the dashboard
view until the subcommand has earned them.
