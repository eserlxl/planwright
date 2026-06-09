# SPDX-FileCopyrightText: 2026 Eser KUBALI
# SPDX-License-Identifier: GPL-3.0-or-later
# shellcheck shell=bash
#
# End-to-end golden-plan + language-routing fixtures (tests/fixtures/<lang>/).
# Sourced by tests/run.sh after tests/lib.sh — NOT standalone (uses ROOT/TMP/ok/bad).
#
# Each fixture is a small multi-file repo (C++, Rust, JS) plus a hand-authored,
# well-formed plan. For each we assert:
#   (a) build-graph.py resolves that language's imports (#include / mod-use / require)
#       and routes ranked_code to the engine file — i.e. language-specific routing works
#       on a real multi-file tree, not just the inline snippets the 11d* tests use; and
#   (b) lint-plan.py passes the golden plan (real surfaces + a runnable verification)
#       but fails a broken variant whose Surfaces point outside the fixture.
# Planning itself is the agent's job and is deliberately NOT asserted here — this pins
# the mechanizable cross-language plan SHAPE + routing contract, the testable core.

# $1=lang dir  $2=entry file  $3=import target  $4=ranked_code member  $5=expected lang
golden_check() {
  lang="$1"; entry="$2"; tgt="$3"; rcode="$4"; elang="$5"
  fx="$ROOT/tests/fixtures/$lang"
  work="$TMP/golden-$lang"
  mkdir -p "$work"
  cp -r "$fx/." "$work/"
  rm -f "$work/golden-plan.md"   # keep the built graph source-only
  git -C "$work" init -q
  git -C "$work" add -A
  git -C "$work" -c user.name=t -c user.email=t@t commit -qm init >/dev/null 2>&1
  cp "$fx/golden-plan.md" "$work/golden-plan.md"   # untracked; only lint reads it

  # set -e-safe: a build-graph failure must land in this case's own FAIL accounting
  # (the empty graph fails the python check below), not silently abort the suite.
  python3 "$ROOT/scripts/build-graph.py" --root "$work" > "$work/graph.json" 2>/dev/null || true
  if python3 - "$work/graph.json" "$entry" "$tgt" "$rcode" "$elang" <<'PY'
import json, sys
g = json.load(open(sys.argv[1], encoding="utf-8"))
entry, tgt, rcode, elang = sys.argv[2:6]
n = g["nodes"]
ok = (entry in n
      and n[entry]["lang"] == elang
      and tgt in (n[entry].get("imports") or [])
      and rcode in g["ranked_code"])
sys.exit(0 if ok else 1)
PY
  then ok "build-graph routes the $lang fixture ($elang: $entry -> $tgt, ranked_code has $rcode)"
  else bad "build-graph mis-routed the $lang fixture (lang/import/ranked_code)"; fi

  if python3 "$ROOT/scripts/lint-plan.py" --root "$work" --plan "$work/golden-plan.md" --quiet
  then ok "lint-plan passes the golden $lang plan (real surfaces + runnable verification)"
  else bad "lint-plan rejected the well-formed golden $lang plan"; fi

  broken="$work/broken-plan.md"
  sed 's#^      Surfaces: .*#      Surfaces: src/does_not_exist.zz#' \
      "$work/golden-plan.md" > "$broken"
  if python3 "$ROOT/scripts/lint-plan.py" --root "$work" --plan "$broken" --quiet
  then bad "lint-plan accepted a broken $lang plan (Surface outside the fixture)"
  else ok "lint-plan fails a broken $lang plan (nonexistent Surface)"; fi
}

# --- Golden fixtures across four import styles ------------------------------------
golden_check cpp  src/calc.cpp include/calc.h src/calc.cpp c
golden_check rust src/lib.rs   src/math.rs    src/math.rs  rust
golden_check js   src/index.js src/util.js    src/util.js  js
golden_check go   main.go      math/math.go   math/math.go go
