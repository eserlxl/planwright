#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Eser KUBALI
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Smoke-test entrypoint for the helper scripts and the SKILL.md contract. Sources
# the shared harness (tests/lib.sh) and each topic case file under tests/cases/ in
# one process, then prints the aggregate summary. Exits 0 when every case passes.
# Operates entirely in temp dirs — never touches the real working tree.
#
# Usage: bash tests/run.sh [case ...]   (no arguments = the full suite; case names
#        filter to just those topic files, e.g. `bash tests/run.sh lint-plan lifecycle`)
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=/dev/null
. "$HERE/lib.sh"

# Topic case files, sourced in the suite's historical order so output stays stable.
# Each is a fragment (no shebang) that relies on the harness sourced above.
CASES="statics-scaffold skill-contract skill-guards skill-graph-contract build-graph unit-engine lint-plan lint-final lifecycle doctor status state dashboard derive check-links golden-plan integration-scale commands install-aliases make-plugin"

# Optional case-name filter: arguments select just those topic files for a focused
# iteration loop. Every name is validated against the registered list FIRST — an
# unknown name is a usage error (exit 2), never a silent zero-check green run.
# No arguments = the full suite, byte-identical behavior to before.
FILTERED=0
if [ $# -gt 0 ]; then
  FILTERED=1
  for want in "$@"; do
    case " $CASES " in
      *" $want "*) ;;
      *)
        echo "Usage: bash tests/run.sh [case ...] — unknown case '$want'" >&2
        echo "valid cases: $CASES" >&2
        exit 2
        ;;
    esac
  done
  CASES="$*"
fi

for case_file in $CASES; do
  # shellcheck source=/dev/null
  . "$HERE/cases/$case_file.sh"
done

# Completeness guard: an unregistered tests/cases/*.sh would otherwise pass the suite
# with zero of its checks executed — silent non-execution, the worst failure mode for
# a gate. Any drift between the list above and the directory fails loudly. A filtered
# run deliberately executes a subset, so the guard only holds in full-suite mode.
if [ "$FILTERED" -eq 0 ]; then
  drift=""
  for f in "$HERE"/cases/*.sh; do
    name="$(basename "$f" .sh)"
    case " $CASES " in
      *" $name "*) ;;
      *) drift="$drift $name" ;;
    esac
  done
  if [ -z "$drift" ]; then
    ok "every tests/cases/*.sh is registered in the suite's case list"
  else
    bad "unregistered case file(s) never run:$drift — add them to CASES in tests/run.sh"
  fi
else
  echo "(filtered run: $CASES — completeness guard skipped)"
fi

echo
echo "passed: ${PASS:-0}  failed: ${FAIL:-0}"
[ "${FAIL:-0}" -eq 0 ]
