#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Eser KUBALI
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Canonical, deterministic builder for planwright's Stage 1.5 graph memory
# (.planwright/graph.json). Conforms to docs/graph-memory-schema.md (version 1).
#
# It only reads the repo (git + file bytes) and prints the graph JSON to stdout;
# it never writes — Stage 1.5 captures stdout and writes the file with the native
# Write tool (the sandbox FS is discarded). Run from inside the target git repo:
#
#   python3 scripts/build-graph.py [--root DIR] [--prior .planwright/graph.json]
#
# --prior, when given, preserves each surviving node's last_audited_sha.
import argparse
import fnmatch
import hashlib
import json
import os
import re
import subprocess
import sys

COUPLING_WINDOW_COMMITS = 200
COUPLING_MIN_COOCCURRENCE = 3
RANKED_SURFACE_LIMIT = 20
# A commit touching more tracked files than this is a bulk op (vendoring, mass
# reformat, generated-file dump): its pairwise co-occurrence is O(F^2) noise that
# both distorts the coupling signal and can blow up memory/time on a large `git log`.
# Such commits are excluded from coupling pairing (their per-file churn still counts).
COUPLING_MAX_FILES_PER_COMMIT = 100
# Upper bound (seconds) on any git/subprocess call, so a wedged git (hung credential
# prompt, lock contention) degrades instead of hanging the whole build. Generous: the
# heaviest call (`git log -n 200`) is bounded, so no legitimate call approaches this.
GIT_TIMEOUT_SECONDS = 120

# Rotating generative framings (docs/invent-exploration-design.md, lever 2) — a
# fixed catalog of vantage *keys* the invent generative lens can reason under. The
# builder only makes the seeded *selection* (deterministic + tested); SKILL.md owns
# the semantics (key -> vantage question). Ordered + append-only so a given seed keeps
# selecting the same key across versions. Unlike lever 1's ordering (which the survey's
# exhaustiveness makes inert), a framing is a prior over *which candidates get generated
# at all*, so it changes pool membership, not just order.
EXPLORE_FRAMINGS = [
    "power-user",   # what would an expert/power user want that the design makes hard?
    "integration",  # what external integration or interoperability is missing?
    "onboarding",   # what would make first-run / onboarding trivial for a new user?
    "reliability",  # what failure mode or recovery path is unhandled?
    "automation",   # what manual workflow could be automated end-to-end?
]

# Basenames whose change forces a whole-graph re-audit: build/lockfile edits can
# alter how every other file compiles, links, or resolves, so a localized dirty
# set would under-audit. Matched case-insensitively (SKILL.md Stage 1.5 step 7,
# "Whole-graph invalidation").
BUILD_CONFIG_BASENAMES = {
    "cmakelists.txt", "makefile", "package.json", "package-lock.json",
    "yarn.lock", "pnpm-lock.yaml", "cargo.toml", "cargo.lock", "go.mod",
    "go.sum", "pyproject.toml", "poetry.lock", "pipfile", "pipfile.lock",
    "requirements.txt", "gemfile", "gemfile.lock", "composer.json",
    "composer.lock", "build.gradle", "pom.xml", "meson.build",
}

EXT_LANG = {
    "sh": "bash", "bash": "bash", "py": "python", "md": "markdown",
    "json": "json", "yml": "yaml", "yaml": "yaml",
    # js/ts family — the extra extensions also appear in JS_EXTS as resolvable
    # import targets, so they must be recognized as source languages too.
    "js": "js", "ts": "js", "jsx": "js", "tsx": "js", "mjs": "js", "cjs": "js",
    # c/c++ family (planwright's primary target) — common alternate extensions.
    "c": "c", "h": "c", "cpp": "c", "hpp": "c",
    "cc": "c", "cxx": "c", "c++": "c", "hh": "c", "hxx": "c", "tpp": "c",
    # rust — so a Rust repo gets centrality routing + Stage 2b function hints
    # instead of degrading to the coupling-only fallback (lang "unknown").
    "rs": "rust",
    # go — defines/branch give Stage 2b per-function hints; intra-module imports resolve
    # to repo files via each .go file's nearest enclosing go.mod (root or nested
    # sub-module — see resolve_go_import / nearest_go_module). External/stdlib and
    # cross-module imports drop.
    "go": "go",
}


def sh(args, root, timeout=GIT_TIMEOUT_SECONDS):
    # timeout bounds a wedged git so the build degrades instead of hanging forever;
    # callers handle the resulting SubprocessError (TimeoutExpired/CalledProcessError).
    return subprocess.check_output(args, cwd=root, text=True, timeout=timeout)


def coupling_pairs(commits, max_files_per_commit=COUPLING_MAX_FILES_PER_COMMIT):
    """Pairwise change-coupling counts over the commit file-sets, skipping bulk
    commits (more than max_files_per_commit tracked files). Those are O(F^2) noise
    that distorts coupling and can explode on a large `git log`; per-file churn is
    counted by the caller and is unaffected by this cap."""
    pair_co = {}
    for cset in commits:
        if len(cset) > max_files_per_commit:
            continue
        fs = sorted(cset)
        for i in range(len(fs)):
            for j in range(i + 1, len(fs)):
                k = (fs[i], fs[j])
                pair_co[k] = pair_co.get(k, 0) + 1
    return pair_co


def lang_of(path, blob):
    ext = path.rsplit(".", 1)[-1].lower() if "." in os.path.basename(path) else ""
    if ext in EXT_LANG:
        return EXT_LANG[ext]
    if blob[:2] == b"#!":
        first = blob.split(b"\n", 1)[0]
        if b"bash" in first or b"sh" in first:
            return "bash"
        if b"python" in first:
            return "python"
    return "unknown"


def loc_of(blob):
    if not blob:
        return 0
    return blob.count(b"\n") + (0 if blob.endswith(b"\n") else 1)


# Per-language branch-token patterns for a best-effort complexity proxy. Stage 2b
# tiebreaks function selection "by complexity (line count or branching)"; loc gives
# the line count, branch_count gives the branching. Comment/string hits are tolerated
# (consistent with the rest of this best-effort extractor).
BRANCH_KW = {
    "bash": r"\b(?:if|elif|for|while|case|until)\b|&&|\|\|",
    "python": r"\b(?:if|elif|for|while|except)\b|\band\b|\bor\b",
    "js": r"\b(?:if|for|while|case|catch)\b|&&|\|\||\?",
    "c": r"\b(?:if|for|while|case|catch)\b|&&|\|\||\?",
    "rust": r"\b(?:if|for|while|match|loop)\b|&&|\|\||\?",
    "go": r"\b(?:if|for|switch|select|case)\b|&&|\|\|",
}


def branch_count_of(lang, text):
    """Best-effort count of branch points — the 'branching' half of Stage 2b's
    complexity tiebreak. 0 for data/markup languages with no control flow."""
    pat = BRANCH_KW.get(lang)
    return len(re.findall(pat, text)) if pat else 0


def iter_defines(lang, text):
    """Yield (symbol_name, start_offset) for every definition match, in source
    order. Shared by defines_of (names) and defines_at_of (name -> line)."""
    if lang == "bash":
        for m in re.finditer(r"(?m)^\s*(?:function\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*\(\)\s*\{?", text):
            yield m.group(1), m.start()
    elif lang == "python":
        for m in re.finditer(r"(?m)^\s*(?:def|class)\s+([A-Za-z_][A-Za-z0-9_]*)", text):
            yield m.group(1), m.start()
    elif lang == "js":
        for m in re.finditer(r"(?m)^\s*(?:export\s+)?(?:default\s+)?(?:async\s+)?function\s*\*?\s+([A-Za-z_$][\w$]*)", text):
            yield m.group(1), m.start()
        for m in re.finditer(r"(?m)^\s*(?:export\s+)?(?:default\s+)?class\s+([A-Za-z_$][\w$]*)", text):
            yield m.group(1), m.start()
        # arrow/function expressions bound to a name: `export const f = (x) => ...`
        for m in re.finditer(r"(?m)^\s*(?:export\s+)?(?:const|let|var)\s+([A-Za-z_$][\w$]*)\s*=\s*(?:async\s+)?(?:\([^)]*\)|[A-Za-z_$][\w$]*)\s*=>", text):
            yield m.group(1), m.start()
    elif lang == "c":
        # gtest group/fixture names — SKILL.md routing tracks TEST/TEST_F groups.
        for m in re.finditer(r"(?m)\b(?:TEST|TEST_F|TEST_P|TYPED_TEST)\s*\(\s*([A-Za-z_]\w*)", text):
            yield m.group(1), m.start()
        # class / struct / enum type names.
        for m in re.finditer(r"(?m)\b(?:class|struct|enum)\s+([A-Za-z_]\w*)", text):
            yield m.group(1), m.start()
        # function / method definitions: the `(...)` is followed by a `{` body, not
        # a `;` prototype; params hold no `;`/`{` so a match stays on one definition,
        # and control-flow keywords (which also read as `name (...) {`) are filtered.
        kw = {"if", "for", "while", "switch", "return", "else", "do", "catch", "sizeof"}
        for m in re.finditer(r"(?m)^\s*[A-Za-z_][\w\s:\*&<>,~]*?\b([A-Za-z_]\w*)\s*\([^;{}]*\)\s*(?:const\s*)?(?:noexcept\s*)?\{", text):
            if m.group(1) not in kw:
                yield m.group(1), m.start()
    elif lang == "rust":
        # functions (incl. methods inside impl blocks, which are indented).
        for m in re.finditer(r"(?m)^\s*(?:pub(?:\([^)]*\))?\s+)?(?:async\s+)?(?:unsafe\s+)?(?:const\s+)?fn\s+([A-Za-z_]\w*)", text):
            yield m.group(1), m.start()
        # nominal types: struct / enum / trait / union.
        for m in re.finditer(r"(?m)^\s*(?:pub(?:\([^)]*\))?\s+)?(?:struct|enum|trait|union)\s+([A-Za-z_]\w*)", text):
            yield m.group(1), m.start()
        # impl blocks — capture the implementing type (the ident before the `{`),
        # covering both `impl Foo {` and `impl Trait for Foo {`.
        for m in re.finditer(r"(?m)^\s*impl\b[^\n{]*?\b([A-Za-z_]\w*)\s*(?:<[^>\n]*>)?\s*\{", text):
            yield m.group(1), m.start()
    elif lang == "go":
        # top-level funcs and methods: `func Name(` and `func (r Recv) Name(`.
        for m in re.finditer(r"(?m)^\s*func\s+(?:\([^)]*\)\s*)?([A-Za-z_]\w*)\s*[\(\[]", text):
            yield m.group(1), m.start()
        # nominal types: `type Name struct|interface` (grouped `type (...)` blocks
        # are best-effort skipped — recall over precision, like the other arms).
        for m in re.finditer(r"(?m)^\s*type\s+([A-Za-z_]\w*)\s+(?:struct|interface)\b", text):
            yield m.group(1), m.start()


def defines_of(lang, text):
    # de-dup, preserve source order
    seen, uniq = set(), []
    for name, _ in iter_defines(lang, text):
        if name not in seen:
            seen.add(name)
            uniq.append(name)
    return uniq


def defines_at_of(lang, text):
    """Map each defined symbol to the 1-based line of its first definition, so
    Stage 2b can jump straight to a function body instead of re-scanning the file."""
    at = {}
    for name, pos in iter_defines(lang, text):
        if name not in at:
            at[name] = text.count("\n", 0, pos) + 1
    return at


def branch_at_of(lang, text):
    """Attribute branching to each symbol by its DEFINITION SPAN — the region from
    a symbol's definition to the next symbol's definition (or EOF). A best-effort,
    parser-free proxy for per-function complexity that lets Stage 2b rank functions
    *within* a centrality-ranked file (see docs/architecture.md design note). First
    definition of a repeated name wins, mirroring defines_of/defines_at_of."""
    pat = BRANCH_KW.get(lang)
    if not pat:
        return {}
    defs = sorted(iter_defines(lang, text), key=lambda np: np[1])
    out = {}
    for i, (name, start) in enumerate(defs):
        end = defs[i + 1][1] if i + 1 < len(defs) else len(text)
        if name not in out:
            out[name] = len(re.findall(pat, text[start:end]))
    return out


_TEST_DIR_SEGMENTS = {"test", "tests", "spec", "specs", "__tests__"}


def is_test_node(path):
    """Classify a node as a test file by its conventional path/name. Deliberately
    path-based and precision-leaning: mislabeling a *source* file as a test would
    hide a real coverage gap, whereas a missed test only yields a candidate finding
    to investigate (never a false "this file is tested"). Covers test dirs, the
    `_test`/`test_`/`.test.`/`.spec.`/`_unittest` stems (so gtest `foo_test.cc` and
    pytest `test_foo.py` are caught), and camelCase `FooTest`/`FooSpec`. See the
    docs/architecture.md "test→source coverage routing" design note."""
    p = path.replace("\\", "/").lower()
    if any(seg in _TEST_DIR_SEGMENTS for seg in p.split("/")):
        return True
    name = os.path.basename(p)
    if re.search(r"(?:^|[._-])(?:test|tests|spec|specs|unittest)(?:[._-]|$)", name):
        return True
    stem = os.path.basename(path)
    stem = stem.rsplit(".", 1)[0] if "." in stem else stem
    return bool(re.search(r"[a-z0-9](?:Test|Tests|Spec)$", stem))


def resolve(target, from_path, fileset, allow_basename=False):
    """Resolve a raw import target to a repo-relative path, or None.

    With allow_basename (bash `source`, C `#include`), fall back to a *unique*
    basename match when relative resolution misses: bash sources a lib by bare name
    or via an unresolved `$DIR/lib.sh`, and C reaches a header through an -I include
    root rather than a path relative to the file. The single-match guard avoids
    ambiguous edges."""
    if not target or target.startswith(("http://", "https://", "#", "mailto:")):
        return None
    target = target.split("#", 1)[0].split("?", 1)[0].strip()
    if not target:
        return None
    base = os.path.dirname(from_path)
    cand = os.path.normpath(os.path.join(base, target)) if not target.startswith("/") else target.lstrip("/")
    cand = cand.replace("\\", "/")
    if cand in fileset:
        return cand
    if allow_basename:
        bn = os.path.basename(target)
        matches = [f for f in fileset if os.path.basename(f) == bn] if bn else []
        if len(matches) == 1:
            return matches[0]
    return None


# Header suffixes that mark an angle `#include <...>` as a project header rather than a
# bare extensionless system header (<vector>, <map>). Used to gate angle-include routing.
C_HEADER_EXTS = (".h", ".hpp", ".hh", ".hxx", ".h++", ".cuh", ".tpp", ".tcc", ".ipp", ".inc")


def resolve_c_angle(target, fileset):
    """Resolve an angle `#include <path>` against the repo's include roots: the unique
    tracked file whose path equals `target` or ends with `/target` (i.e. reached through
    some -I include root). Deliberately NO bare-basename fallback — a system header like
    <sys/types.h> must not link to an unrelated repo `types.h`; only a genuine
    include-root hit (the full sub-path matches) creates the edge. Ambiguous -> None."""
    t = target.replace("\\", "/").strip().lstrip("./")
    if not t:
        return None
    matches = [f for f in fileset if f == t or f.endswith("/" + t)]
    return matches[0] if len(matches) == 1 else None


def resolve_python_import(target, from_path, fileset):
    """Resolve a python import target (a dotted module, possibly relative) to a repo
    file. Dotted names are not paths, so the generic resolver always misses them and
    every python import edge is dropped. Absolute `pkg.mod` tries `pkg/mod.py` and
    `pkg/mod/__init__.py` from the repo root; a leading-dot relative import resolves
    against the importer's package, one level up per extra dot."""
    dots = len(target) - len(target.lstrip("."))
    parts = [p for p in target[dots:].split(".") if p]
    if dots:
        base = os.path.dirname(from_path).split("/") if os.path.dirname(from_path) else []
        up = dots - 1
        if up > len(base):
            return None
        segs = base[:len(base) - up] + parts
    else:
        segs = parts
    if not segs:
        return None
    stem = "/".join(segs)
    for cand in (stem + ".py", stem + "/__init__.py"):
        if cand in fileset:
            return cand
    return None


JS_EXTS = (".js", ".ts", ".jsx", ".tsx", ".mjs", ".cjs")


def _probe_js(stem, fileset):
    """Resolve a repo-relative JS stem to a file, probing `<stem>`, `<stem>.<ext>`, then
    `<stem>/index.<ext>` — JS/TS specifiers routinely omit the extension and use directory
    `index` files."""
    stem = stem.replace("\\", "/")
    if stem in fileset:
        return stem
    for ext in JS_EXTS:
        if stem + ext in fileset:
            return stem + ext
    for ext in JS_EXTS:
        if stem + "/index" + ext in fileset:
            return stem + "/index" + ext
    return None


def apply_ts_aliases(target, ts_aliases):
    """Map a bare specifier through tsconfig `compilerOptions.paths` aliases. ts_aliases is
    (base_dir, [(pattern, [replacements])]); a `*` in the pattern captures a tail that is
    substituted into each replacement. Returns candidate repo-relative stems (un-probed)."""
    base_dir, patterns = ts_aliases
    out = []
    for pat, repls in patterns:
        if pat.endswith("/*"):
            prefix = pat[:-1]  # "@app/*" -> "@app/"
            if target.startswith(prefix):
                tail = target[len(prefix):]
                out += [os.path.normpath(os.path.join(base_dir, r.replace("*", tail))) for r in repls]
        elif pat == target:
            out += [os.path.normpath(os.path.join(base_dir, r)) for r in repls]
    return out


def _strip_jsonc(s):
    """Remove // and /* */ comments from JSONC, skipping string literals (so an alias
    pattern like `"@app/*"`, which contains `/*`, is not mistaken for a comment start).
    Regex cannot do this safely, hence the small char walker."""
    out, i, n, in_str = [], 0, len(s), False
    while i < n:
        c = s[i]
        if in_str:
            out.append(c)
            if c == "\\" and i + 1 < n:
                out.append(s[i + 1])
                i += 2
                continue
            if c == '"':
                in_str = False
            i += 1
        elif c == '"':
            in_str = True
            out.append(c)
            i += 1
        elif c == "/" and i + 1 < n and s[i + 1] == "/":
            while i < n and s[i] != "\n":
                i += 1
        elif c == "/" and i + 1 < n and s[i + 1] == "*":
            i += 2
            while i + 1 < n and not (s[i] == "*" and s[i + 1] == "/"):
                i += 1
            i += 2
        else:
            out.append(c)
            i += 1
    return "".join(out)


def parse_tsconfig(path, cfg_dir):
    """Best-effort parse of a tsconfig/jsconfig `compilerOptions.paths` map into
    (base_dir, [(pattern, [repls])]), or None. base_dir = the config's dir + baseUrl,
    repo-relative. Tolerates JSONC (// and /* */ comments, trailing commas); on any parse
    failure it returns None and alias resolution is simply skipped (recall over precision)."""
    try:
        with open(path, encoding="utf-8") as fh:
            raw = fh.read()
    except OSError:
        return None
    raw = _strip_jsonc(raw)
    raw = re.sub(r",(\s*[}\]])", r"\1", raw)  # trailing commas
    try:
        cfg = json.loads(raw)
    except ValueError:
        return None
    co = (cfg.get("compilerOptions") or {}) if isinstance(cfg, dict) else {}
    paths = co.get("paths") or {}
    if not isinstance(paths, dict) or not paths:
        return None
    base = os.path.normpath(os.path.join(cfg_dir, co.get("baseUrl") or "."))
    base = "" if base == "." else base
    patterns = [(pat, repls) for pat, repls in paths.items() if isinstance(repls, list)]
    return (base, patterns) if patterns else None


def resolve_js_import(target, from_path, fileset, ts_aliases=None):
    """Resolve a js/ts import target to a repo file. A relative/absolute specifier probes
    `<stem>(.ext)(/index.ext)`. A bare specifier (`react`) is normally node_modules and
    drops — but a tsconfig/jsconfig `compilerOptions.paths` alias (when present) is applied
    first, so an aliased import like `@app/util` resolves to its mapped path."""
    if target.startswith((".", "/")):
        base = os.path.dirname(from_path)
        stem = os.path.normpath(os.path.join(base, target)) if not target.startswith("/") else target.lstrip("/")
        return _probe_js(stem, fileset)
    if ts_aliases:
        for mapped in apply_ts_aliases(target, ts_aliases):
            r = _probe_js(mapped, fileset)
            if r:
                return r
    return None


def resolve_rust_import(target, from_path, fileset):
    """Resolve a Rust `mod name;` or `use path::...;` target to a repo file.
    `mod foo;` is a sibling `foo.rs` or `foo/mod.rs`; a `use` path is probed
    best-effort against progressively shorter `::`-prefixes (a trailing item name
    is not a file, so drop it and retry the module path). Crate-root markers are
    skipped. Recall over precision, like the other language resolvers."""
    parts = [p for p in target.split("::")
             if p and p not in ("crate", "self", "super", "std", "core", "alloc")]
    base = os.path.dirname(from_path)
    while parts:
        rel = "/".join(parts)
        for stem_base in (base, ""):
            stem = os.path.normpath(os.path.join(stem_base, rel)) if stem_base else rel
            stem = stem.replace("\\", "/")
            for cand in (stem + ".rs", stem + "/mod.rs"):
                if cand in fileset:
                    return cand
        parts = parts[:-1]  # drop the trailing item; retry as a shorter module path
    return None


def resolve_go_import(target, module_path, fileset, module_dir=""):
    """Resolve a Go import path to the repo `.go` files of the imported package.

    Go imports a package by its full module path (e.g. `import "mymod/pkg/util"` when
    go.mod declares `module mymod`), so only **intra-module** imports map to repo files;
    external and stdlib packages are not in the tree and drop. Strip the module prefix to
    get the package's path *relative to that module's go.mod directory* (`module_dir`,
    empty for a root module), then return every `.go` file directly in that directory — a
    Go package is a directory of files, so the import couples to all of them. `module_dir`
    makes this nested-module aware: a sub-directory go.mod resolves against its own root.
    Returns a list (possibly empty). Recall over precision, like the other resolvers."""
    if not module_path:
        return []
    if target == module_path:
        rel = ""
    else:
        prefix = module_path.rstrip("/") + "/"
        if not target.startswith(prefix):
            return []
        rel = target[len(prefix):].strip("/")
    pkg_dir = os.path.normpath(os.path.join(module_dir, rel)) if (module_dir or rel) else ""
    pkg_dir = "" if pkg_dir == "." else pkg_dir.replace("\\", "/")
    return sorted(f for f in fileset
                  if f.endswith(".go") and os.path.dirname(f) == pkg_dir)


def nearest_go_module(from_path, go_modules):
    """Pick the deepest go.mod whose directory encloses from_path, so each .go file
    resolves against its own (possibly nested) module. go_modules is a list of
    (module_dir, module_path) pairs; module_dir '' is the repo root. Returns the pair or
    None."""
    d = os.path.dirname(from_path)
    best = None
    for mod_dir, mod_path in go_modules:
        if mod_dir == "" or d == mod_dir or d.startswith(mod_dir + "/"):
            if best is None or len(mod_dir) > len(best[0]):
                best = (mod_dir, mod_path)
    return best


def strip_comments(lang, text):
    """Best-effort removal of comments and Python docstrings before import extraction,
    so an import-looking line inside a comment or a multi-line string does not produce a
    false import edge (e.g. `#include "x"` inside a C `/* ... */`, or `import x` inside a
    Python `\"\"\"docstring\"\"\"`). Deliberately conservative: it strips block/line
    comments and Python triple-quoted strings, not every string literal — recall still
    beats precision, and a missed strip only re-admits a false edge, which merely
    mis-routes and never produces a finding. Used only for import extraction; the original
    text still feeds branch_count and the metrics."""
    if lang in ("c", "js", "rust", "go"):
        # C/C++ `#include` uses `#` for the preprocessor, not a comment, so only `/* */`
        # and `//` are stripped here (never `#`).
        text = re.sub(r"/\*.*?\*/", "", text, flags=re.S)
        text = re.sub(r"(?m)//.*$", "", text)
    elif lang == "python":
        text = re.sub(r'"""(?:.|\n)*?"""', "", text)
        text = re.sub(r"'''(?:.|\n)*?'''", "", text)
        text = re.sub(r"(?m)#.*$", "", text)
    elif lang == "bash":
        text = re.sub(r"(?m)#.*$", "", text)
    return text


def imports_of(lang, text, from_path, fileset, go_module=None, ts_aliases=None):
    text = strip_comments(lang, text)
    # Resolve which Go module from_path belongs to (nested-module aware). go_module may be
    # a single module path string (legacy/root), a list of (module_dir, module_path) pairs,
    # or None.
    go_pick = None
    if lang == "go":
        mods = [("", go_module)] if isinstance(go_module, str) else (go_module or [])
        go_pick = nearest_go_module(from_path, mods)
    raw = []
    c_angles = []
    if lang == "bash":
        raw += re.findall(r"(?m)^\s*(?:source|\.)\s+([^\s;]+)", text)
    elif lang == "python":
        raw += re.findall(r"(?m)^\s*(?:from|import)\s+([.\w/]+)", text)
    elif lang == "js":
        raw += re.findall(r"""import\s+.*?from\s+['"]([^'"]+)['"]""", text)
        raw += re.findall(r"""require\(\s*['"]([^'"]+)['"]\s*\)""", text)
    elif lang == "c":
        raw += re.findall(r'(?m)^\s*#\s*include\s+"([^"]+)"', text)
        # Angle includes (`#include <project/foo.h>`) reach a header through an -I include
        # root; route them too, but only when they look like a project header — carrying a
        # path separator or a header extension. Bare extensionless system headers (<vector>,
        # <map>) match neither and are skipped, and angle paths resolve strictly against
        # include roots (resolve_c_angle, no basename fallback) so <sys/types.h> cannot
        # forge an edge to an unrelated repo types.h.
        c_angles += [a for a in re.findall(r'(?m)^\s*#\s*include\s+<([^>]+)>', text)
                     if "/" in a or a.lower().endswith(C_HEADER_EXTS)]
    elif lang == "rust":
        raw += re.findall(r"(?m)^\s*(?:pub(?:\([^)]*\))?\s+)?mod\s+([A-Za-z_]\w*)\s*;", text)
        raw += re.findall(r"(?m)^\s*(?:pub(?:\([^)]*\))?\s+)?use\s+([A-Za-z_][\w:]*)", text)
    elif lang == "go":
        # single-line `import "pkg"` (optionally aliased) ...
        raw += re.findall(r'(?m)^\s*import\s+(?:[\w.]+\s+)?"([^"]+)"', text)
        # ... and grouped `import ( "p1"\n alias "p2" )` blocks.
        for block in re.findall(r"(?ms)^\s*import\s*\((.*?)\)", text):
            raw += re.findall(r'"([^"]+)"', block)
    elif lang == "markdown":
        raw += re.findall(r"\[[^\]]*\]\(([^)]+)\)", text)
    out = []
    # bash sources and C includes both reach files by bare name (a sourced lib, an
    # -I include root), so both fall back to a unique basename match.
    allow_basename = lang in ("bash", "c")
    for t in raw:
        if lang == "go":
            # a Go import resolves to a *package* (a directory of .go files), so the
            # resolver returns a list; couple to each file in the imported package.
            if go_pick:
                for r in resolve_go_import(t, go_pick[1], fileset, go_pick[0]):
                    if r and r != from_path and r not in out:
                        out.append(r)
            continue
        if lang == "python":
            r = resolve_python_import(t, from_path, fileset)
        elif lang == "js":
            r = resolve_js_import(t, from_path, fileset, ts_aliases)
        elif lang == "rust":
            r = resolve_rust_import(t, from_path, fileset)
        else:
            r = resolve(t, from_path, fileset, allow_basename)
        if r and r != from_path and r not in out:
            out.append(r)
    for a in c_angles:
        r = resolve_c_angle(a, fileset)
        if r and r != from_path and r not in out:
            out.append(r)
    return out


def pagerank(nodes, edges, damping=0.85, iters=50):
    n = len(nodes)
    if n == 0:
        return {}
    idx = {f: i for i, f in enumerate(nodes)}
    out_links = {f: [t for t in edges.get(f, []) if t in idx] for f in nodes}
    pr = {f: 1.0 / n for f in nodes}
    for _ in range(iters):
        nxt = {f: (1.0 - damping) / n for f in nodes}
        dangling = sum(pr[f] for f in nodes if not out_links[f])
        for f in nodes:
            nxt[f] += damping * dangling / n
        for f in nodes:
            outs = out_links[f]
            if outs:
                share = damping * pr[f] / len(outs)
                for t in outs:
                    nxt[t] += share
        pr = nxt
    return pr


def articulation_points(nodes, undirected):
    """Standard DFS lowlink articulation-point detection."""
    visited, disc, low, parent, aps = set(), {}, {}, {}, set()
    timer = [0]

    def dfs(u):
        stack = [(u, iter(undirected.get(u, [])))]
        visited.add(u)
        disc[u] = low[u] = timer[0]
        timer[0] += 1
        children = {u: 0}
        while stack:
            node, it = stack[-1]
            advanced = False
            for w in it:
                if w not in visited:
                    parent[w] = node
                    children[node] = children.get(node, 0) + 1
                    visited.add(w)
                    disc[w] = low[w] = timer[0]
                    timer[0] += 1
                    children[w] = 0
                    stack.append((w, iter(undirected.get(w, []))))
                    advanced = True
                    break
                elif parent.get(node) != w:
                    low[node] = min(low[node], disc[w])
            if not advanced:
                stack.pop()
                if stack:
                    p = stack[-1][0]
                    low[p] = min(low[p], low[node])
                    if parent.get(p) is not None and low[node] >= disc[p]:
                        aps.add(p)
        if children.get(u, 0) > 1:
            aps.add(u)

    for s in nodes:
        if s not in visited:
            parent[s] = None
            dfs(s)
    return aps


def connected_components(nodes, undirected):
    seen, comps = set(), []
    for s in nodes:
        if s in seen:
            continue
        stack, comp = [s], []
        seen.add(s)
        while stack:
            u = stack.pop()
            comp.append(u)
            for w in undirected.get(u, []):
                if w not in seen:
                    seen.add(w)
                    stack.append(w)
        comps.append(sorted(comp))
    return comps


def import_cycles(nodes, edges, limit):
    """Strongly-connected components of size >= 2 in the *directed* import graph —
    i.e. circular-import groups (a->b->a, python circular imports, C include cycles).
    A concrete signal for the Stage 3 architecture lens, which otherwise has to spot
    "dependency direction" defects by eye. Iterative Tarjan (no recursion-depth risk
    on large repos, mirroring articulation_points). Returns up to `limit` cycles,
    each a sorted member list, the list itself sorted for determinism."""
    nodeset = set(nodes)
    adj = {f: [t for t in edges.get(f, []) if t in nodeset and t != f] for f in nodes}
    index, low, on_stack, stack, idx, sccs = {}, {}, {}, [], [0], []
    for root in nodes:
        if root in index:
            continue
        work = [(root, 0)]
        while work:
            v, pi = work[-1]
            if pi == 0:
                index[v] = low[v] = idx[0]
                idx[0] += 1
                stack.append(v)
                on_stack[v] = True
            neighbors = adj[v]
            if pi < len(neighbors):
                work[-1] = (v, pi + 1)
                w = neighbors[pi]
                if w not in index:
                    work.append((w, 0))
                elif on_stack.get(w):
                    low[v] = min(low[v], index[w])
            else:
                if low[v] == index[v]:
                    comp = []
                    while True:
                        w = stack.pop()
                        on_stack[w] = False
                        comp.append(w)
                        if w == v:
                            break
                    if len(comp) > 1:
                        sccs.append(sorted(comp))
                work.pop()
                if work:
                    p = work[-1][0]
                    low[p] = min(low[p], low[v])
    sccs.sort()
    return sccs[:limit]


def cluster_label(members):
    dirs = {os.path.dirname(m) or "(root)" for m in members}
    if len(dirs) == 1:
        return next(iter(dirs))
    # most common top-level dir
    tops = {}
    for m in members:
        top = m.split("/", 1)[0] if "/" in m else "(root)"
        tops[top] = tops.get(top, 0) + 1
    return max(sorted(tops), key=lambda k: tops[k])


def commits_since(prior_sha, head, root):
    """Number of commits on HEAD not reachable from prior_sha, or None if it
    cannot be computed (rewritten history, unknown sha)."""
    if not prior_sha or prior_sha == head:
        return 0
    try:
        out = sh(["git", "rev-list", "--count", f"{prior_sha}..HEAD"], root).strip()
    except subprocess.SubprocessError:
        return None
    return int(out) if out.isdigit() else None


def blast_adjacency(files, undirected, coupling_edges):
    """Combined 1-hop adjacency map: undirected import edges plus change-coupling
    edges. Shared by the dirty-set blast radius (compute_dirty) and component
    scoping (Context = Focus + its 1-hop neighbours), so both walk identical edges."""
    adj = {f: set(undirected.get(f, [])) for f in files}
    for e in coupling_edges:
        a, b = e["a"], e["b"]
        if a in adj and b in adj:
            adj[a].add(b)
            adj[b].add(a)
    return adj


def one_hop_closure(seed, adj, files):
    """The seed set plus its 1-hop neighbours along adj, restricted to files and
    returned sorted. The blast-radius primitive behind both the dirty set and
    Context scoping."""
    out = set(seed)
    for f in seed:
        out.update(adj.get(f, ()))
    return sorted(out & set(files))


def resolve_scope(spec, files):
    """Resolve a --scope pathspec to a Focus set of repo-relative files: a file is
    in Focus when it equals the spec, lives under it (directory prefix), or matches
    it as a glob (docs/scope-design.md, `path <X>`). Best-effort and precision-leaning
    like the rest of the builder; an empty result is a real no-match the SKILL.md
    Stage 1 layer turns into a user-facing error."""
    spec = spec.replace("\\", "/").strip().rstrip("/")
    if not spec:
        return []
    pref = spec + "/"
    focus = {f for f in files
             if f == spec or f.startswith(pref) or fnmatch.fnmatch(f, spec)}
    return sorted(focus)


def compute_dirty(files, nodes, prior, prior_graph, head, undirected, coupling_edges, clusters, root):
    """Deterministic Stage 1.5 step 7 dirty set. Returns the `dirty` block:
    which nodes changed since the prior graph, their 1-hop blast radius along
    import + coupling edges, the clusters they touch, and whether a whole-graph
    re-audit is forced. Leaving this to hand-computation each run is the most
    error-prone part of incremental skipping, so the canonical builder owns it."""
    all_files = sorted(files)
    all_clusters = sorted(c["id"] for c in clusters)

    # First run: no baseline to diff against — every node is dirty.
    if not prior:
        return {
            "is_first_run": True, "whole_graph": True, "reason": "first-run",
            "changed": [], "nodes": all_files, "clusters": all_clusters,
        }

    changed = sorted(
        f for f in files if prior.get(f, {}).get("sha256") != nodes[f]["sha256"]
    )
    # A build-config edit (or deletion) can change how everything builds.
    def is_build_config(p):
        return os.path.basename(p).lower() in BUILD_CONFIG_BASENAMES
    config_hits = [f for f in changed if is_build_config(f)]
    config_hits += [f for f in (set(prior) - set(files)) if is_build_config(f)]

    diverged = commits_since(prior_graph.get("graph_built_at_sha"), head, root)

    whole_graph, reason = False, "incremental"
    if config_hits:
        whole_graph, reason = True, f"build-config changed: {sorted(config_hits)[0]}"
    elif diverged is not None and diverged > COUPLING_WINDOW_COMMITS:
        whole_graph = True
        reason = f"HEAD diverged {diverged} commits (> {COUPLING_WINDOW_COMMITS})"
    elif diverged is None:
        whole_graph, reason = True, "prior graph_built_at_sha unreachable"

    if whole_graph:
        dirty_nodes = all_files
    else:
        # 1-hop blast radius along import + coupling adjacency (shared with scoping).
        adj = blast_adjacency(files, undirected, coupling_edges)
        dirty_nodes = one_hop_closure(changed, adj, files)

    touched = sorted({c["id"] for c in clusters if set(c["members"]) & set(dirty_nodes)})
    return {
        "is_first_run": False, "whole_graph": whole_graph, "reason": reason,
        "changed": changed, "nodes": dirty_nodes, "clusters": touched,
    }


def build(root, prior_path, scope=None, seed=None):
    head = sh(["git", "rev-parse", "HEAD"], root).strip()
    files = [f for f in sh(["git", "ls-files"], root).split("\n") if f]
    fileset = set(files)

    prior_graph = {}
    if prior_path and os.path.exists(prior_path):
        try:
            with open(prior_path, encoding="utf-8") as fh:
                loaded = json.load(fh)
            if isinstance(loaded, dict):
                prior_graph = loaded
            else:
                # Warn before masking a data-integrity problem as a slow clean run.
                sys.stderr.write(
                    f"build-graph: prior graph '{prior_path}' is not a JSON object; "
                    "rebuilding from scratch\n")
        except (ValueError, OSError) as e:
            sys.stderr.write(
                f"build-graph: ignoring unreadable prior graph '{prior_path}' ({e}); "
                "rebuilding from scratch\n")
    prior = prior_graph.get("nodes", {})
    if not isinstance(prior, dict):
        prior = {}

    # churn + change-coupling
    # Prefix the commit hash so a commit boundary is detected by an unambiguous
    # delimiter, not by "line is exactly 40 hex chars" — a tracked file whose path
    # is itself 40 hex chars (asset hashes, compiled artifacts) would otherwise be
    # misread as a commit boundary, corrupting churn and change-coupling counts.
    log = sh(["git", "log", "--name-only", "--format=commit:%H", "-n", str(COUPLING_WINDOW_COMMITS)], root)
    churn, commits, cur = {}, [], None
    for ln in log.split("\n"):
        ln = ln.strip()
        if not ln:
            continue
        if ln.startswith("commit:") and len(ln) == 47 and all(c in "0123456789abcdef" for c in ln[7:]):
            cur = set()
            commits.append(cur)
        elif cur is not None and ln in fileset:
            cur.add(ln)
            churn[ln] = churn.get(ln, 0) + 1

    pair_co = coupling_pairs(commits)

    # tsconfig/jsconfig compilerOptions.paths aliases, so `@app/x` style imports resolve.
    ts_aliases = None
    for cfg in ("tsconfig.json", "jsconfig.json"):
        if cfg in fileset:
            ts_aliases = parse_tsconfig(os.path.join(root, cfg), os.path.dirname(cfg))
            if ts_aliases:
                break

    # Every go.mod's (dir, module path), so Go intra-module imports resolve to repo files,
    # nested sub-modules included (each .go file uses its nearest enclosing module).
    go_modules = []
    for gm in sorted(f for f in fileset if os.path.basename(f) == "go.mod"):
        try:
            with open(os.path.join(root, gm), encoding="utf-8") as fh:
                txt = fh.read()
            mm = re.search(r"(?m)^\s*module\s+(\S+)", txt)
            if mm:
                go_modules.append((os.path.dirname(gm), mm.group(1)))
        except OSError:
            pass

    nodes, import_edges = {}, {}
    for f in files:
        with open(os.path.join(root, f), "rb") as fh:
            blob = fh.read()
        lang = lang_of(f, blob)
        text = blob.decode("utf-8", "replace")
        imps = imports_of(lang, text, f, fileset, go_modules, ts_aliases)
        import_edges[f] = imps
        nodes[f] = {
            "sha256": hashlib.sha256(blob).hexdigest(),
            "loc": loc_of(blob),
            "branch_count": branch_count_of(lang, text),
            "branch_at": branch_at_of(lang, text),
            "lang": lang,
            "git_churn": churn.get(f, 0),
            "defines": defines_of(lang, text),
            "defines_at": defines_at_of(lang, text),
            "imports": imps,
            "is_test": is_test_node(f),
            "covered_by_test": False,
            "pagerank": 0.0,
            "is_articulation": False,
            "last_audited_sha": prior.get(f, {}).get("last_audited_sha"),
        }

    undirected = {f: set() for f in files}
    for f, outs in import_edges.items():
        for t in outs:
            undirected[f].add(t)
            undirected[t].add(f)
    undirected = {f: sorted(s) for f, s in undirected.items()}

    pr = pagerank(files, import_edges)
    aps = articulation_points(files, undirected)
    for f in files:
        nodes[f]["pagerank"] = round(pr.get(f, 0.0), 6)
        nodes[f]["is_articulation"] = f in aps

    coupling_edges = []
    # Weighted coupling degree: sum of incident edge weights, where
    # weight = cooccur / min(churn) normalizes away raw volume so a high-churn
    # ledger file (CHANGELOG, manifests) does not dominate purely by appearing in
    # many commits. SKILL.md Stage 1.5 step 6 specifies this "sum of coupling_edges
    # weights" as the degenerate-fallback ranking signal.
    coupling_deg = {f: 0.0 for f in files}
    for (a, b), co in sorted(pair_co.items()):
        if co >= COUPLING_MIN_COOCCURRENCE:
            denom = min(churn.get(a, 1), churn.get(b, 1)) or 1
            w = round(co / denom, 4)
            coupling_edges.append({"a": a, "b": b, "cooccur": co, "weight": w})
            coupling_deg[a] += w
            coupling_deg[b] += w

    # test->source coverage routing (additive, routing-only): a node is reached
    # when some test-classified node imports it or co-changes with it (coupling
    # edges are already filtered to cooccur >= COUPLING_MIN_COOCCURRENCE, i.e.
    # "strong"). A `covered_by_test == False` on a non-test code node is a
    # *candidate* missing-test finding for Stage 2a to investigate, never proof.
    # See the docs/architecture.md "test->source coverage routing" design note.
    test_nodes = {f for f in files if nodes[f]["is_test"]}
    reached = set()
    for t in test_nodes:
        reached.update(s for s in import_edges.get(t, []) if s not in test_nodes)
    for e in coupling_edges:
        a, b = e["a"], e["b"]
        if a in test_nodes and b not in test_nodes:
            reached.add(b)
        if b in test_nodes and a not in test_nodes:
            reached.add(a)
    for f in files:
        nodes[f]["covered_by_test"] = f in reached

    comps = connected_components(files, undirected)
    clusters = []
    for i, members in enumerate(sorted(comps, key=lambda m: (-len(m), m[0]))):
        clusters.append({"id": i, "label": cluster_label(members), "members": members})

    cycles = import_cycles(files, import_edges, RANKED_SURFACE_LIMIT)

    # ranking: pagerank-driven, but fall back to change-coupling when the import
    # graph is degenerate (too few edges, or pagerank barely discriminates).
    pr_values = [pr.get(f, 0.0) for f in files]
    pr_spread = (max(pr_values) - min(pr_values)) if pr_values else 0.0
    n_import_edges = sum(len(v) for v in import_edges.values())
    degenerate = n_import_edges < max(3, len(files) // 4) or pr_spread < 1e-4
    signal = "coupling" if degenerate else "centrality"

    def sort_key(f):
        primary = coupling_deg[f] if degenerate else pr.get(f, 0.0)
        return (primary, 1 if nodes[f]["is_articulation"] else 0, churn.get(f, 0), )

    by_priority = sorted(files, key=sort_key, reverse=True)
    ranked = by_priority[:RANKED_SURFACE_LIMIT]
    # ranked_code: the same priority order restricted to nodes that actually carry
    # code (branch_count > 0), so Stage 2b's function-selection walk is not led by
    # zero-function doc/data nodes that link-centrality can float to the top of
    # `ranked` (docs/architecture.md "lang-aware Stage 2b ranking" design note).
    ranked_code = [f for f in by_priority
                   if nodes[f]["branch_count"] > 0][:RANKED_SURFACE_LIMIT]

    # ranked_cold: the audit/coverage FRONTIER — the inverse of ranked_code, surfaced
    # for the opt-in `explore` escalation (SKILL.md "Explore escalation"). Where
    # ranked_code leads with the hot, high-blast-radius core, ranked_cold leads with
    # the code the default routing neglects: never-audited nodes first
    # (last_audited_sha is None), then uncovered (covered_by_test False), then the
    # least-central (ascending pagerank), tiebroken by least churn then path. It is
    # fully deterministic (no RNG), so explore stays reproducible across runs.
    def cold_key(f):
        n = nodes[f]
        return (
            0 if n["last_audited_sha"] is None else 1,  # never-audited frontier first
            0 if not n["covered_by_test"] else 1,       # then uncovered code
            n["pagerank"],                              # then peripheral (low centrality)
            churn.get(f, 0),                            # then least-churned
            f,                                          # path -> total, stable order
        )
    ranked_cold = [f for f in sorted(files, key=cold_key)
                   if nodes[f]["branch_count"] > 0][:RANKED_SURFACE_LIMIT]

    dirty = compute_dirty(files, nodes, prior, prior_graph, head, undirected,
                          coupling_edges, clusters, root)

    graph = {
        "version": 1,
        "graph_built_at_sha": head,
        "built_at": sh(["date", "-u", "+%Y-%m-%dT%H:%M:%SZ"], root).strip(),
        "target": ".",
        "ranking_signal": signal,
        "params": {
            "coupling_window_commits": COUPLING_WINDOW_COMMITS,
            "coupling_min_cooccurrence": COUPLING_MIN_COOCCURRENCE,
            "ranked_surface_limit": RANKED_SURFACE_LIMIT,
        },
        "nodes": nodes,
        "coupling_edges": coupling_edges,
        "clusters": clusters,
        "ranked": ranked,
        "ranked_code": ranked_code,
        "ranked_cold": ranked_cold,
        "import_cycles": cycles,
        "dirty": dirty,
    }

    # Component scoping (docs/scope-design.md) — emitted ONLY under --scope, so a
    # default whole-repo build stays byte-for-byte identical to before. Focus = the
    # scoped files; Context = Focus + its 1-hop import+coupling blast radius (the same
    # walk compute_dirty uses), so a scoped run keeps root cause and impact visible
    # instead of walling them off.
    if scope is not None:
        focus = resolve_scope(scope, files)
        adj = blast_adjacency(files, undirected, coupling_edges)
        graph["focus"] = focus
        graph["context"] = one_hop_closure(focus, adj, files)

    # Seeded exploration ordering (docs/invent-exploration-design.md, lever 1) —
    # emitted ONLY under --seed, so a default build stays byte-for-byte identical.
    # A seeded permutation of the branch_count>0 code nodes, ordered by the digest
    # of "<seed>:<path>": deterministic per seed and stable across Python versions
    # (no random-module stream dependence), and reordered by a different seed. The
    # invent generative survey walks it so repeated runs explore different regions
    # while each stays reproducible from its recorded seed. Routing only, like every
    # ranked list — never Evidence.
    if seed is not None:
        graph["explore_seed"] = seed
        graph["ranked_explore"] = sorted(
            (f for f in files if nodes[f]["branch_count"] > 0),
            key=lambda f: hashlib.sha256(f"{seed}:{f}".encode()).hexdigest(),
        )
        # Rotating generative framing (lever 2): a seeded pick from the fixed catalog,
        # deterministic per seed and stable across Python versions (digest, not RNG).
        # Routing only — never Evidence. SKILL.md maps the key to a vantage question.
        graph["explore_framing"] = EXPLORE_FRAMINGS[
            int(hashlib.sha256(f"{seed}:framing".encode()).hexdigest(), 16)
            % len(EXPLORE_FRAMINGS)
        ]

    return graph


def debug_digest(graph, out):
    """Write a human-readable routing digest to `out` (stderr) so a reader can see WHY
    the graph ranked nodes as it did — the intermediate PageRank/coupling weights,
    articulation flags, the centrality-vs-coupling signal, the dirty-set decision, and
    import cycles — without hand-parsing the JSON. stdout stays a clean JSON document, so
    `--debug` composes with the normal `> graph.json` redirect. Routing diagnostics only;
    none of this is Evidence."""
    nodes = graph["nodes"]
    p = out.write
    p(f"# build-graph debug — {len(nodes)} nodes, "
      f"ranking_signal={graph['ranking_signal']} "
      f"(centrality=PageRank over imports; coupling=git co-change, used when the import "
      f"graph barely discriminates)\n")
    d = graph["dirty"]
    scope_n = d["nodes"]
    p(f"# dirty: first_run={d['is_first_run']} whole_graph={d['whole_graph']} "
      f"reason={d['reason']!r} changed={len(d['changed'])} in_scope_nodes={len(scope_n)} "
      f"clusters={len(d['clusters'])}\n")
    p(f"# import_cycles={len(graph['import_cycles'])}  "
      f"coupling_edges={len(graph['coupling_edges'])}  "
      f"articulation_points={sum(1 for n in nodes.values() if n['is_articulation'])}\n")

    def row(rank, f):
        n = nodes[f]
        art = "*art" if n["is_articulation"] else "    "
        cov = "cov" if n["covered_by_test"] else "UNC"
        return (f"  {rank:>2}. pr={n['pagerank']:.5f} {art} "
                f"br={n['branch_count']:>3} churn={n['git_churn']:>3} {cov} {f}")

    p("# ranked (top 10, all node types — link-centrality can float docs up):\n")
    for i, f in enumerate(graph["ranked"][:10], 1):
        p(row(i, f) + "\n")
    p("# ranked_code (top 10, branch_count>0 — Stage 2b correctness routing):\n")
    for i, f in enumerate(graph["ranked_code"][:10], 1):
        p(row(i, f) + "\n")
    p("# ranked_cold (top 10 — explore cold-frontier: never-audited, then uncovered):\n")
    for i, f in enumerate(graph["ranked_cold"][:10], 1):
        p(row(i, f) + "\n")
    out.flush()


def main():
    ap = argparse.ArgumentParser(description="Build planwright Stage 1.5 graph.json (prints to stdout).")
    ap.add_argument("--root", default=".", help="repo root (default: cwd)")
    ap.add_argument("--prior", default=None, help="prior graph.json to preserve last_audited_sha from")
    ap.add_argument("--scope", default=None,
                    help="restrict to a path/dir/glob; emits focus + context (Focus + 1-hop blast radius) node lists")
    ap.add_argument("--seed", type=int, default=None,
                    help="emit a seeded ranked_explore ordering + explore_framing for invent exploration; recorded as explore_seed")
    ap.add_argument("--debug", action="store_true",
                    help="write a human-readable routing digest (ranking signal, top ranked/code/cold "
                         "nodes with pagerank/churn/articulation, dirty-set + cycles) to stderr; "
                         "stdout stays clean JSON")
    args = ap.parse_args()
    root = os.path.abspath(args.root)
    try:
        graph = build(root, args.prior, args.scope, args.seed)
    except subprocess.SubprocessError as e:
        sys.stderr.write(f"build-graph: git command failed or timed out ({e})\n")
        return 2
    if args.debug:
        debug_digest(graph, sys.stderr)
    json.dump(graph, sys.stdout, indent=2)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
