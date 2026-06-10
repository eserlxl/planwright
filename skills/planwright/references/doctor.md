## Doctor

Reached only via `planwright doctor` (or the host equivalent such as `/planwright doctor`). A
read-only **preflight**: it inspects the host environment and reports, up front, which capabilities
would silently degrade during a real run — instead of letting those fallbacks surface mid-pipeline.
It never plans, and by default writes nothing; the one exception is the opt-in `--fix` flag, which
auto-remediates the single fixable warn by adding `.planwright/` to `.gitignore` (the other warns —
an unset git identity, a missing tool — need the user) and then re-checks. Mirrors `lint-plan --fix`.

**Canonical check.** Prefer the deterministic, test-covered `<scripts>/doctor.py` (resolve
`<scripts>` per **Procedure → Bundled scripts**): run
`python3 <scripts>/doctor.py --root <target>` in the sandbox and relay its report. It checks two
seams and the target:

1. **Host tools** — `python3` (the bundled-script runtime), `git` (graph file enumeration,
   change-coupling edges, Execute's per-item commits), `rg`/`fd` (fast Stage 1 scanning). Each is
   reported present/absent with its version and exactly what degrades when missing.
2. **Bundled-script resolution** — that the bundled scripts (the whole planning pipeline plus
   `dashboard.py` and the dashboard UI shell — the full set `doctor.py`'s
   `BUNDLED` list names) resolve beside `doctor.py` (the `<scripts>` seam). A miss here means a
   broken/partial install.
3. **Target** — whether `--root` is a git work tree (the graph build needs one), whether that
   tree gitignores `.planwright/` (the tool-state directory; a repo that forgets to ignore it commits
   plan/graph/digest as noise), and whether a git commit identity (`user.name`/`user.email`) is set
   (Execute/Cycle commit per item, so an unset identity fails mid-run). Both are reported `warn`,
   never `fail`.

Severity is `ok` / `warn` (degraded, run still works) / `fail` (a core capability is unavailable:
missing `git` or a missing bundled script). The script exits non-zero when any check fails; the opt-in
`--strict` flag additionally fails on any `warn`, so a CI preflight can require a pristine (not merely
runnable) environment.

**By-hand fallback** (the script's own runtime is missing — no `python3` — so it cannot run): report
that `python3` is unavailable (every bundled script will fall back to its by-hand SKILL.md spec),
then check `git`/`rg`/`fd` on `PATH`, whether `<target>` is a git repo, and whether it gitignores
`.planwright/`, and relay the same summary by hand.

STOP after reporting.

