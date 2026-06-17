## Check

Reached only via `planwright check` (or the host equivalent such as `/planwright check`). A
**pre-flight audit-and-prune** of `.planwright/plan.md`: it re-applies planwright's apply-time gates
to every pending item **without implementing anything**, drops the items that fail, and reports the
rest. Its purpose is to vet a plan planwright did **not** author through its own Stage 3–10 gauntlet —
a qb export `cp`'d into `.planwright/plan.md`, a hand-written plan, or one pasted from elsewhere — so a
manual `planwright execute` starts from a plan whose items have already been challenged.

**What it is — and is not.** `check` is read-only with respect to your **source tree**: it never edits
source, never stages, never commits, and never marks an item completed. But it is **not** a pure
observer like `status`/`advise`: it **writes `.planwright/plan.md` and `.planwright/rejected.md`**
(pruning gate-failing items) and it **executes each pending item's `Verification:` command** to test
runnability. Run it only when you are content for those Verification commands to run.

### Preconditions

1. **Plan exists** — `.planwright/plan.md` has at least one pending `- [ ]` item. If none, report
   "No pending items to check" and STOP.
2. **No clean-tree / git-identity gate.** Unlike `execute`, `check` never commits or edits source, so
   it does **not** require a clean working tree or a configured git identity — this is deliberate, so
   you can `cp` an external plan in and vet it immediately. (`.planwright/` is gitignored, so its writes
   never dirty the tree.)

Honors a `path <X>` / `lib <X>` **scope** (audit only items whose Surfaces fall in the resolved Focus,
appending `--scope .planwright/graph.json` to the linter) and `check N` (audit only pending item N).

### Per-item audit

Resolve `<scripts>` per **Procedure → Bundled scripts**. First run the structural linter over the whole
plan once: `python3 <scripts>/lint-plan.py --root <target>` (add `--scope .planwright/graph.json` under
an active scope). Then, for each targeted pending item, assign a verdict from three layers:

1. **Structural** — any `lint-plan.py` violation for this item (missing/empty field, invalid Mode, ghost
   `Surfaces:`, a `repair` item whose Evidence lacks a `file:line` anchor, a `.planwright/`-owned
   Surface, `CMakeLists` without `.txt`). → **prune**.
2. **Necessity & grounding** — re-apply, read-only, the Execute **value gate** (Per-item loop step 1:
   named failure, removal test, real consumer, not self-justifying) and the **Stage 10** judgement the
   linter cannot mechanize: Evidence cites a real signal (never `.planwright/graph.json`/`digest.md`,
   never a claim inferred from filenames/comments/types), Mode matches the change it describes (across
   all five modes), and the item is not a duplicate of a `completed.md` record (unless the audit shows
   regression). → **prune** the ones that fail, naming the failing check.
3. **Verifiability (dry-run)** — run the item's `Verification:` command exactly, against the current
   tree, and classify by **whether the command could run**, never by pass/fail:
   - **Cannot run** (command not found, missing target/file, syntax error) → `unverifiable` → **prune**.
   - **Ran and failed** → **keep.** A pending item's Verification is *expected* to fail before the item
     is implemented — that is what makes it a real verification. Never prune a runnable-but-failing
     command.
   - **Ran and passed** → **keep, but flag** `already-satisfied?`. A pass before implementation *may*
     mean the item is a no-op — but it is also the normal case for any item whose `Verification:` is the
     full suite (e.g. `bash tests/run.sh`), which is green before and after. So `check` never auto-prunes
     on this; it surfaces it for you to judge.

### Prune action

For each pruned item, move it to `rejected.md` with a machine-readable reason:
`python3 <scripts>/lifecycle.py reject <N> --reason "check: <one-line reason>" --root <target>/.planwright`
(N = the item's 1-based pending number; re-resolve N as the list shrinks, or prune from the bottom up).
This appends the canonical `Status: Rejected` / `Rejection:` lines and drains the block, exactly like an
execute-time rejection — so the reason feeds the next plan's Stage 1 **PREVIOUSLY REJECTED** set and the
whole class is not re-proposed. Surviving items stay pending, untouched.

### Report

Print a per-item verdict (`keep` / `pruned: <layer>: <reason>` / `keep ⚠ already-satisfied?`) and a
summary: items kept, items pruned (with reasons), items flagged. End with the resulting pending count —
after `check`, that surviving plan is ready for `planwright execute`. STOP after reporting; `check` never
implements.

**By-hand fallback** (no `python3`): apply the `lint-plan.py` structural checks and the value gate in
plain words, run each `Verification:` yourself, and for any failing item append the Rejection-schema
lines by hand and move it to `rejected.md` (FIFO cap 100). The contract is unchanged: no source edits, no
commits.
