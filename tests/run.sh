#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Eser KUBALI
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Smoke-test entrypoint for the helper scripts and the SKILL.md contract. Sources
# the shared harness (tests/lib.sh) and each topic case file under tests/cases/ in
# one process, then prints the aggregate summary. Exits 0 when every case passes.
# Operates entirely in temp dirs — never touches the real working tree.
#
# Usage: bash tests/run.sh
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=/dev/null
. "$HERE/lib.sh"

# Topic case files, sourced in the suite's historical order so output stays stable.
# Each is a fragment (no shebang) that relies on the harness sourced above.
for case_file in statics-scaffold skill-contract build-graph lint-plan golden-plan commands; do
  # shellcheck source=/dev/null
  . "$HERE/cases/$case_file.sh"
done

echo
echo "passed: ${PASS:-0}  failed: ${FAIL:-0}"
[ "${FAIL:-0}" -eq 0 ]
