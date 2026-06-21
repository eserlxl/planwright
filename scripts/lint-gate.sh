#!/usr/bin/env bash
# Reproduce the CI static gates (.github/workflows/ci.yml) locally so you can
# prove they pass before pushing, without hand-copying the workflow YAML.
#
# Mirrors the "Shellcheck scripts" and "Lint Python engine scripts" steps:
#   1. shellcheck over scripts/*.sh tests/*.sh tests/cases/*.sh
#   2. pyflakes scripts/*.py
#   3. mypy --config-file mypy.ini scripts/   (CI pins mypy==2.1.0)
#
# Runs all three even if an earlier one fails, then exits non-zero if any did, so
# a single run surfaces every static problem at once.
set -euo pipefail

cd "$(dirname "$0")/.."

rc=0

echo "== shellcheck =="
if shellcheck scripts/*.sh tests/*.sh tests/cases/*.sh; then
	echo "shellcheck: clean"
else
	echo "shellcheck: FAILED" >&2
	rc=1
fi

echo "== pyflakes =="
if pyflakes scripts/*.py; then
	echo "pyflakes: clean"
else
	echo "pyflakes: FAILED" >&2
	rc=1
fi

echo "== mypy (--config-file mypy.ini) =="
# CI pins mypy==2.1.0; warn (don't fail) on a version skew so a local mismatch is
# visible rather than silently diverging from the gate CI actually runs.
have_ver="$(mypy --version 2>/dev/null | awk '{print $2}' || true)"
if [ "$have_ver" != "2.1.0" ]; then
	echo "warning: mypy ${have_ver:-<absent>} installed; CI pins mypy==2.1.0 — diagnostics may differ" >&2
fi
if mypy --config-file mypy.ini scripts/; then
	echo "mypy: clean"
else
	echo "mypy: FAILED" >&2
	rc=1
fi

exit "$rc"
