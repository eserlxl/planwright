# SPDX-FileCopyrightText: 2026 Eser KUBALI
# SPDX-License-Identifier: GPL-3.0-or-later
# shellcheck shell=bash
#
# scripts/build-graph.py engine algorithms — direct Python unit tests.
# Sourced by tests/run.sh after tests/lib.sh — NOT standalone (uses ROOT/ok/bad).
# Wraps the stdlib unittest suite under tests/unit/ as one suite check so the
# engine internals (PageRank, articulation points, Tarjan SCC, import resolvers)
# are exercised by the smoke run, not only through the CLI.

# --- Test UE1: the engine unit suite passes ------------------------------------
rc=0
out="$(cd "$ROOT" && python3 -m unittest discover -s tests/unit -p "test_*.py" 2>&1)" || rc=$?
if [ "$rc" = "0" ]; then
  ran="$(printf '%s' "$out" | grep -oE 'Ran [0-9]+ tests' | head -1)"
  ok "build-graph engine unit suite passes (${ran:-ran})"
else
  bad "build-graph engine unit suite failed (rc=$rc): $(printf '%s' "$out" | tail -1)"
fi
