# Architecture

`planwright` is a Claude Code plugin designed with two distinct paths: **Plan** and **Execute**. The core idea is to physically separate the auditing and generation of work from the actual implementation and editing of the source code. Claude runs every stage directly; there are no external binaries and no separate model calls required.

## The Planning Pipeline

When invoked via `/planwright`, the plugin executes a multi-stage pipeline. The entire planning phase is **read-only**: it never edits your application source. It only writes the generated plan items to `<repo>/.planwright/plan.md`.

The pipeline consists of 11 stages:

### Stage 0: Lifecycle Housekeeping
Maintains the `.planwright/` directory.
- Drains completed items (`- [x]`) into `completed.md`.
- Drains rejected items into `rejected.md`.
- Both lists are capped at a FIFO limit of 100 items.
- If all remaining items are completed, the active plan is archived into `plans/` and a fresh run starts.

### Stage 1: Scan
Collects ground-truth data from the project to ensure plan items are actionable and exact:
- **Project File Paths**: Real source, header, and configuration files.
- **Implementation Signals**: Actual non-comment symbols (functions, types, test names).
- **Test Targets**: Exact test targets (e.g., from `ctest` or your project's test runner).
- Loads previously rejected/completed items to avoid re-proposing them.

### Stage 2: Audit
Derives audit findings such as oversized modules, missing tests, risky refactors, and correctness gaps. Each finding must point to concrete file paths or implementation signals.

### Stages 3–7: Cumulative Planning Dossier
Five reasoning passes build a cumulative dossier of candidates, risks, and verification targets:
- **Architecture**: Evaluates module boundaries, API surfaces, and dependency directions.
- **Quality & Tests**: Looks for weak or missing focused tests and exact test anchors.
- **Behavior & Features**: Identifies missing runtime behavior, workflows, or integrations.
- **Operations & Reliability**: Checks configuration, sensitive data handling, and observability.
- **Prioritization Review**: Drops low-value candidates and resolves dependencies between items (e.g., forcing a design item before an implementation item).

### Stage 8: Draft
Converts the refined dossier into draft checkbox items following the exact output format, selecting the highest-value items up to the requested capacity.

### Stage 9: Finalize
Validates the draft against the real project context. It corrects vague titles, verifies test targets, and removes items that hallucinate symbols or assume files exist when they don't.

### Stage 10: Strict Quality Gate
A final check that acts as a hard gate. Items must be proven by non-comment signals. It blocks unsafe extraction (e.g., `constexpr` into `.cpp`), destructive file operations, and missing test anchors. Items failing this gate are replaced or dropped.

### Stage 11: Write
Appends the surviving items into `.planwright/plan.md`. (If `--dry-run` is active, it only prints the plan to chat).

## The Execution Path

When invoked via `/planwright execute`, the plugin enters the **Execute** path. This is the only path that modifies the source code.

1. **Preconditions**: It ensures a clean git working tree so that per-item commits don't entangle with uncommitted work.
2. **Implement**: Implements the item by editing the surfaces declared in the plan item.
3. **Verify**: Runs the exact `Verification:` command for the item.
4. **Commit / Reject**:
   - On pass: Commits the change, marks the item complete, and moves it to `completed.md`.
   - On fail: Makes up to 2 repair attempts. If it still fails, the item's edits are reverted, a rejection reason is appended, and it moves to `rejected.md`.
5. **Broad Final Verification**: After running through items, a final project-wide build/test ensures that nothing broke on a macro level.
