# SPDX-FileCopyrightText: 2026 Eser KUBALI
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Shared test harness for the planwright smoke suite. Sourced by tests/run.sh
# BEFORE any tests/cases/*.sh fragment, so every case file runs in one process
# and shares ROOT, TMP, the ok/bad counters, and the ver() helper. Operates
# entirely in a temp dir — never touches the real working tree.
#
# shellcheck shell=bash
# ROOT/TMP/PASS/FAIL are consumed by the sourced case files, not by lib.sh itself,
# so shellcheck cannot see their use when linting this file in isolation.
# shellcheck disable=SC2034
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0
FAIL=0
ok()  { echo "ok   - $1"; PASS=$((PASS + 1)); }
bad() { echo "FAIL - $1"; FAIL=$((FAIL + 1)); }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Keep fixture commits independent of the developer's global git config. In
# particular, signed-commit defaults require a writable GPG home, which CI and
# sandboxed runs often do not have.
export GIT_CONFIG_GLOBAL="$TMP/gitconfig"
printf '[commit]\n\tgpgsign = false\n' > "$GIT_CONFIG_GLOBAL"

ver() { python3 -c "import json,sys;print(json.load(open(sys.argv[1]))$2)" "$1"; }
