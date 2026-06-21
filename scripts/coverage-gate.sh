#!/usr/bin/env bash
# Reproduce the CI "Coverage gate" step (.github/workflows/ci.yml) locally.
#
# Mirrors the gate ordering and the 90% floor exactly:
#   coverage erase -> unit coverage -> smoke suite -> coverage combine -> report --fail-under=90
#
# The smoke suite (tests/run.sh) drives scripts/*.py as subprocesses, so the
# subprocess-coverage hook must be installed or `coverage combine` reports a
# misleadingly low number (see .coveragerc). CI writes the .pth into the
# interpreter's purelib; on a normal dev box that directory is root-owned, so
# this runner falls back to the writable user-site dir and removes the hook on
# exit, never leaving it behind in the developer's environment.
set -euo pipefail

cd "$(dirname "$0")/.."

export COVERAGE_PROCESS_START="$PWD/.coveragerc"

# Pick the first writable site dir (purelib in CI, user-site on a dev box).
pth_dir="$(python3 - <<'PY'
import os, site, sysconfig
candidates = [sysconfig.get_paths()["purelib"], site.getusersitepackages()]
for p in candidates:
    if os.path.isdir(p) and os.access(p, os.W_OK):
        print(p)
        break
else:
    print(site.getusersitepackages())
PY
)"
mkdir -p "$pth_dir"
pth_file="$pth_dir/coverage_subprocess.pth"
printf 'import coverage; coverage.process_startup()\n' >"$pth_file"
trap 'rm -f "$pth_file"' EXIT

# Fail fast if the subprocess coverage hook did not install: without the .pth the
# python3 subprocesses the shell suite spawns run uninstrumented, so the report
# would be a silently-degraded number that could still pass the gate.
if [ ! -f "$pth_file" ]; then
	echo "subprocess coverage hook missing: $pth_file was not installed;" \
		"subprocess coverage would be silently under-instrumented" >&2
	exit 1
fi

coverage erase
coverage run -m unittest discover -s tests/unit -p "test_*.py"
bash tests/run.sh
coverage combine
coverage report --fail-under=90
