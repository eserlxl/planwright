# SPDX-FileCopyrightText: 2026 Eser KUBALI
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Subprocess-coverage honesty. The CI coverage gate (.github/workflows/ci.yml)
# trusts that the python3 subprocesses the shell suite spawns are counted, via a
# startup hook — COVERAGE_PROCESS_START plus a coverage_subprocess .pth (see
# .coveragerc). If that hook silently breaks, those subprocesses run
# uninstrumented and `coverage combine` reports a misleadingly low number that
# could still pass the 90% floor. This case pins the property with a
# fails-on-drift assertion: with the startup hook active a SPAWNED scripts/
# entry point IS counted; with it disabled it is NOT.
#
# The parent process never imports the target, so any coverage attributed to
# scripts/status.py in the combined data can only come from the spawned child.
#
# Sourced by tests/run.sh after tests/lib.sh — NOT standalone (uses ROOT/TMP/ok/bad).
# coverage-gated (the CI smoke step installs no coverage): a clean skip when
# coverage is absent keeps the suite green everywhere, exactly the way derive.sh
# gates on node. A hermetic temp sitecustomize stands in for CI's site .pth (the
# same COVERAGE_PROCESS_START startup-hook contract) so the case never writes to
# the developer's real site-packages.
#
# shellcheck shell=bash

# --- Test COV1: a spawned scripts/ subprocess is counted iff the startup hook is on ---
if python3 -c "import coverage" >/dev/null 2>&1; then
  CWORK="$TMP/covcase"
  mkdir -p "$CWORK/site"
  # The startup hook: importable on PYTHONPATH, auto-run by Python at interpreter
  # start, a no-op unless COVERAGE_PROCESS_START points at an rcfile — the exact
  # contract CI's coverage_subprocess.pth relies on.
  printf 'import coverage; coverage.process_startup()\n' > "$CWORK/site/sitecustomize.py"
  cat > "$CWORK/cov.rc" <<RC
[run]
parallel = true
data_file = $CWORK/.coverage
source = $ROOT/scripts
RC
  # Parent: spawns scripts/status.py as a child but never imports it, so any
  # status.py coverage in the combined data can ONLY come from the subprocess.
  cat > "$CWORK/parent.py" <<'PY'
import os, subprocess, sys
subprocess.run(
    [sys.executable, os.path.join(os.environ["PW_ROOT"], "scripts", "status.py"), "--help"],
    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)
PY

  # Run the parent under coverage, combine, and report scripts/status.py's
  # covered-line count. $1 = on -> install the startup hook for the child; off ->
  # leave it out, so the child runs uninstrumented.
  cov_subproc_lines() {
    rm -f "$CWORK"/.coverage*
    if [ "$1" = on ]; then
      env PW_ROOT="$ROOT" PYTHONPATH="$CWORK/site" COVERAGE_PROCESS_START="$CWORK/cov.rc" \
        python3 -m coverage run --rcfile="$CWORK/cov.rc" "$CWORK/parent.py" >/dev/null 2>&1
    else
      env PW_ROOT="$ROOT" \
        python3 -m coverage run --rcfile="$CWORK/cov.rc" "$CWORK/parent.py" >/dev/null 2>&1
    fi
    python3 -m coverage combine --rcfile="$CWORK/cov.rc" >/dev/null 2>&1 || true
    python3 -m coverage json --rcfile="$CWORK/cov.rc" -o "$CWORK/cov.json" >/dev/null 2>&1 || true
    python3 - "$CWORK/cov.json" <<'PY'
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    print(0); sys.exit(0)
fs = d.get("files", {})
print(max([v["summary"]["covered_lines"] for v in fs.values()] or [0]))
PY
  }

  on_lines="$(cov_subproc_lines on)"
  off_lines="$(cov_subproc_lines off)"
  if [ "$on_lines" -gt 0 ] && [ "$off_lines" -eq 0 ]; then
    ok "subprocess coverage honesty: a spawned scripts/status.py is counted with the startup hook ($on_lines lines) and NOT without it ($off_lines lines)"
  else
    bad "subprocess coverage instrumentation drift: hook-on=$on_lines (want >0), hook-off=$off_lines (want 0)"
  fi
else
  ok "subprocess coverage honesty check skipped (coverage not installed)"
fi
