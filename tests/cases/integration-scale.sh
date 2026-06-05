# SPDX-FileCopyrightText: 2026 Eser KUBALI
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Large multi-language integration test for build-graph.py routing at scale.
# Sourced by tests/run.sh after tests/lib.sh — NOT standalone (uses ROOT/TMP/ok/bad).
#
# The per-language golden fixtures are tiny (2-3 files). This generates a >100-file repo
# with real import "stars" across Python / JS / C / Rust / Go (each language has a `core`
# imported by ~24 modules), builds the graph once, and asserts routing holds at scale:
# schema-conforming, real import edges resolved per language, a non-degenerate
# (centrality) ranking signal, and sane cluster + articulation structure — within a time
# bound. Planning itself is the agent's job and is not exercised here.

BIG="$TMP/bigrepo"
mkdir -p "$BIG"
python3 - "$BIG" <<'PY'
import os, sys
root = sys.argv[1]
N = 24  # modules per language -> ~129 files total (> 100)

def w(rel, body):
    p = os.path.join(root, rel)
    os.makedirs(os.path.dirname(p), exist_ok=True)
    with open(p, "w", encoding="utf-8") as f:
        f.write(body)

# Python: a package whose modules all import pkg.core (star centred on core.py)
w("pkg/__init__.py", "")
w("pkg/core.py", "def f():\n    return 1\n")
for i in range(N):
    w(f"pkg/mod{i:02d}.py",
      f"from pkg.core import f\n\ndef g(x):\n    if x > 0:\n        return {i}\n    return f()\n")

# JS: modules all require ./core (star centred on core.js)
w("js/core.js", "module.exports = { f: () => 1 };\n")
for i in range(N):
    w(f"js/m{i:02d}.js",
      f'const core = require("./core");\nfunction g(x) {{ return x > 0 ? {i} : core.f(); }}\n'
      "module.exports = { g };\n")

# C: translation units all #include \"core.h\" (star centred on core.h)
w("c/core.h", "int f(void);\n")
w("c/core.c", '#include "core.h"\nint f(void) { return 1; }\n')
for i in range(N):
    w(f"c/u{i:02d}.c",
      f'#include "core.h"\nint g{i}(int x) {{ if (x > 0) return {i}; return f(); }}\n')

# Rust: lib.rs declares every module (star centred on lib.rs). The hub is named `base`,
# not `core`: `core` is a Rust built-in crate name that resolve_rust_import deliberately
# skips, so a `mod core;` would (correctly) resolve to nothing.
mods = "\n".join(f"mod m{i:02d};" for i in range(N))
w("rust/src/lib.rs", f"mod base;\n{mods}\n")
w("rust/src/base.rs", "pub fn f() -> i32 { 1 }\n")
for i in range(N):
    w(f"rust/src/m{i:02d}.rs",
      f"pub fn g(x: i32) -> i32 {{ if x > 0 {{ {i} }} else {{ 0 }} }}\n")

# Go: a root module whose packages all import bigmod/gocore (star centred on gocore)
w("go.mod", "module bigmod\n\ngo 1.22\n")
w("gocore/core.go", "package gocore\n\nfunc F() int { return 1 }\n")
for i in range(N):
    w(f"gom{i:02d}/m{i:02d}.go",
      f'package gom{i:02d}\n\nimport "bigmod/gocore"\n\n'
      f"func G(x int) int {{ if x > 0 {{ return {i} }}; return gocore.F() }}\n")
print("generated")
PY

git -C "$BIG" init -q
git -C "$BIG" add -A
git -C "$BIG" -c user.name=t -c user.email=t@e.com commit -qm init >/dev/null 2>&1
nfiles="$(git -C "$BIG" ls-files | wc -l | tr -d ' ')"

# Bounded runtime: build-graph must finish well within the budget (it is ~sub-second on
# ~130 files). timeout returns 124 on expiry; treat that as a failure.
TO=""
command -v timeout >/dev/null 2>&1 && TO="timeout 120"
BG="$TMP/biggraph.json"
$TO python3 "$ROOT/scripts/build-graph.py" --root "$BIG" > "$BG" 2>/dev/null
build_rc=$?

if [ "$build_rc" -ne 0 ]; then
  bad "build-graph.py did not finish within the time budget on the $nfiles-file repo (rc=$build_rc)"
else
  if python3 - "$BG" "$nfiles" <<'PY' 2>/dev/null
import json, sys
g = json.load(open(sys.argv[1], encoding="utf-8"))
nfiles = int(sys.argv[2])
n = g["nodes"]
errs = []

if g.get("version") != 1: errs.append("schema version != 1")
if nfiles <= 100: errs.append(f"fixture only {nfiles} files (need > 100)")
if len(n) != nfiles: errs.append(f"nodes {len(n)} != tracked files {nfiles}")

# Import edges resolve for EVERY language family (the point of the test).
def imps(p): return n.get(p, {}).get("imports") or []
for lang, src, tgt in [
    ("python", "pkg/mod05.py",      "pkg/core.py"),
    ("js",     "js/m05.js",         "js/core.js"),
    ("c",      "c/u05.c",           "c/core.h"),
    ("rust",   "rust/src/lib.rs",   "rust/src/base.rs"),
    ("go",     "gom05/m05.go",      "gocore/core.go"),
]:
    if tgt not in imps(src): errs.append(f"{lang}: {src} !-> {tgt} ({imps(src)})")

# A real import graph must rank by centrality, not fall back to coupling.
if g.get("ranking_signal") != "centrality":
    errs.append(f"ranking_signal={g.get('ranking_signal')} (expected centrality)")

# Structure: the 5 language families are disjoint -> many components; the star centres
# are cut vertices -> articulation points; ranked_code is non-empty engine code.
if len(g["clusters"]) < 5: errs.append(f"clusters {len(g['clusters'])} < 5")
arts = sum(1 for nd in n.values() if nd.get("is_articulation"))
if arts < 1: errs.append("no articulation points found at scale")
if not g.get("ranked_code"): errs.append("empty ranked_code")

if errs:
    sys.stderr.write("integration-scale ERRORS: " + "; ".join(errs) + "\n")
sys.exit(0 if not errs else 1)
PY
  then ok "build-graph.py routes a >100-file 5-language repo (schema, per-language edges, centrality, clusters+articulation)"
  else bad "build-graph.py routing wrong at scale (see ERRORS above)"; fi
fi
