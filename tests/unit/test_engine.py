# SPDX-FileCopyrightText: 2026 Eser KUBALI
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Direct unit tests for the build-graph engine algorithms. The smoke suite
# (tests/run.sh) exercises the scripts through their CLI, which is the real
# seam but localizes regressions poorly; these tests import the engine
# functions and pin their behavior on known inputs, including malformed ones.
#
# Run: python3 -m unittest discover -s tests/unit -p "test_*.py"

import importlib.util
import os
import subprocess
import tempfile
import unittest

_HERE = os.path.dirname(os.path.abspath(__file__))
_ROOT = os.path.dirname(os.path.dirname(_HERE))


def _load_engine():
    """Import scripts/build-graph.py by path (the filename is not a valid module name)."""
    path = os.path.join(_ROOT, "scripts", "build-graph.py")
    spec = importlib.util.spec_from_file_location("build_graph_engine", path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


bg = _load_engine()


class TestPageRank(unittest.TestCase):
    def test_in_links_raise_rank(self):
        # B and C both link to A; A should outrank the leaves that have no in-links.
        nodes = ["A", "B", "C"]
        edges = {"A": [], "B": ["A"], "C": ["A"]}
        pr = bg.pagerank(nodes, edges)
        self.assertGreater(pr["A"], pr["B"])
        self.assertGreater(pr["A"], pr["C"])

    def test_mass_is_conserved(self):
        nodes = ["A", "B", "C"]
        edges = {"A": ["B"], "B": ["C"], "C": ["A"]}
        pr = bg.pagerank(nodes, edges)
        self.assertAlmostEqual(sum(pr.values()), 1.0, places=6)
        # A symmetric 3-cycle distributes rank evenly.
        self.assertAlmostEqual(pr["A"], pr["B"], places=6)
        self.assertAlmostEqual(pr["B"], pr["C"], places=6)

    def test_empty_graph(self):
        self.assertEqual(bg.pagerank([], {}), {})


class TestArticulationPoints(unittest.TestCase):
    def test_path_graph_has_cut_vertex(self):
        # A - B - C: removing B disconnects A from C.
        nodes = ["A", "B", "C"]
        undirected = {"A": ["B"], "B": ["A", "C"], "C": ["B"]}
        self.assertEqual(bg.articulation_points(nodes, undirected), {"B"})

    def test_triangle_has_none(self):
        nodes = ["A", "B", "C"]
        undirected = {"A": ["B", "C"], "B": ["A", "C"], "C": ["A", "B"]}
        self.assertEqual(bg.articulation_points(nodes, undirected), set())


class TestImportCyclesTarjan(unittest.TestCase):
    def test_two_node_cycle(self):
        nodes = ["A", "B", "C"]
        edges = {"A": ["B"], "B": ["A"], "C": []}
        self.assertEqual(bg.import_cycles(nodes, edges, 10), [["A", "B"]])

    def test_dag_has_no_cycles(self):
        nodes = ["A", "B", "C"]
        edges = {"A": ["B"], "B": ["C"], "C": []}
        self.assertEqual(bg.import_cycles(nodes, edges, 10), [])

    def test_self_loop_is_not_a_cycle(self):
        # A self-edge is excluded (t != f in the adjacency build), so it forms no SCC>=2.
        nodes = ["A"]
        edges = {"A": ["A"]}
        self.assertEqual(bg.import_cycles(nodes, edges, 10), [])

    def test_limit_truncates_lexicographically(self):
        # Three disjoint 2-cycles: the limit caps the result to the lexicographically
        # smallest cycles (sccs are sorted before the slice), and limit 0 yields none.
        nodes = ["A", "B", "C", "D", "E", "F"]
        edges = {"A": ["B"], "B": ["A"], "C": ["D"], "D": ["C"], "E": ["F"], "F": ["E"]}
        self.assertEqual(len(bg.import_cycles(nodes, edges, 10)), 3)
        self.assertEqual(bg.import_cycles(nodes, edges, 2), [["A", "B"], ["C", "D"]])
        self.assertEqual(bg.import_cycles(nodes, edges, 0), [])


class TestResolveScope(unittest.TestCase):
    FILES = ["src/a.py", "src/b.js", "docs/x.md", "README.md"]

    def test_glob_branch(self):
        # The fnmatch glob branch — the documented `--scope <glob>` path no CLI test reaches.
        self.assertEqual(bg.resolve_scope("src/*.py", self.FILES), ["src/a.py"])

    def test_prefix_branch(self):
        # A bare directory matches everything under it by prefix (sorted).
        self.assertEqual(bg.resolve_scope("src", self.FILES), ["src/a.py", "src/b.js"])

    def test_exact_and_no_match(self):
        self.assertEqual(bg.resolve_scope("README.md", self.FILES), ["README.md"])
        self.assertEqual(bg.resolve_scope("", self.FILES), [])
        self.assertEqual(bg.resolve_scope("nope/x", self.FILES), [])


class TestImportResolvers(unittest.TestCase):
    def test_defines_of_python(self):
        text = "def foo():\n    pass\n\nclass Bar:\n    pass\n"
        self.assertEqual(bg.defines_of("python", text), ["foo", "Bar"])

    def test_defines_of_excludes_commented_and_docstring_defs(self):
        # blank_comments() blanks # comments and triple-quoted strings before symbol
        # extraction, so a def/class that exists only inside a comment or docstring is
        # not reported as a live definition (commit 8bc739a, the defines-side fix).
        py = (
            "def real():\n"
            '    """\n'
            "    def ghost():\n"
            "        pass\n"
            '    """\n'
            "    return 1\n"
            "# class Hidden: pass\n"
            "class Shown:\n"
            "    pass\n"
        )
        self.assertEqual(bg.defines_of("python", py), ["real", "Shown"])
        # C: a // line comment and a /* */ block comment hide their symbols too.
        c = (
            "int real_fn() { return 0; }\n"
            "// int hidden_fn() { return 1; }\n"
            "/* TEST(Ghost, Case) { } */\n"
        )
        self.assertEqual(bg.defines_of("c", c), ["real_fn"])

    def test_defines_of_handles_tricky_docstrings(self):
        # The single-pass triple-quote blanker must hide a def inside a cross-style
        # docstring (''' containing """) and inside an UNTERMINATED """ docstring
        # (blanked to end-of-text), not just a plain closed block.
        cross = (
            "def keep_a():\n"
            "    pass\n"
            "x = '''doc with \"\"\" inside\n"
            "def ghost_cross():\n"
            "    pass\n"
            "'''\n"
        )
        self.assertEqual(bg.defines_of("python", cross), ["keep_a"])
        unterminated = (
            "def keep_b():\n"
            "    pass\n"
            'y = """unterminated docstring\n'
            "def ghost_unterminated():\n"
            "    pass\n"
        )
        self.assertEqual(bg.defines_of("python", unterminated), ["keep_b"])

    def test_to_dot_escapes_special_chars(self):
        # A git-tracked path may legally contain a quote or backslash; to_dot must escape
        # them so --dot emits valid GraphViz instead of a malformed/truncated DOT string.
        tricky = 'src/a"b\\c.py'
        graph = {
            "nodes": {
                tricky: {"is_articulation": True, "imports": ["src/n.py"]},
                "src/n.py": {"imports": []},
            },
            "coupling_edges": [{"a": tricky, "b": "src/n.py"}],
        }
        dot = bg.to_dot(graph)
        self.assertIn('"src/a\\"b\\\\c.py"', dot)   # escaped id present
        self.assertNotIn('"a"b', dot)               # no bare unescaped quote leaked
        self.assertEqual(bg._dot_quote('a"b\\c'), '"a\\"b\\\\c"')

    def test_iter_defines_yields_in_source_order_across_categories(self):
        # iter_defines runs one regex pass per definition CATEGORY (C struct vs function);
        # their matches must be merged in source order so defines_of/defines_at_of are correct,
        # not just branch_at_of (which used to re-sort on its own). Interleave categories by line:
        c = (
            "struct First { int a; };\n"    # line 1 (type)
            "int second() { return 0; }\n"  # line 2 (function)
            "struct Third { int b; };\n"    # line 3 (type)
        )
        self.assertEqual(bg.defines_of("c", c), ["First", "second", "Third"])
        at = bg.defines_at_of("c", c)
        self.assertEqual((at["First"], at["second"], at["Third"]), (1, 2, 3))

    def test_defines_at_of_picks_first_line_on_cross_category_collision(self):
        # A name defined as both a function (earlier) and a type (later): defines_at must point
        # at the FIRST definition by line, regardless of which category regex matched it first.
        c = "int Widget(int x) { return x; }\nstruct Widget { int n; };\n"
        self.assertEqual(bg.defines_at_of("c", c)["Widget"], 1)

    def test_resolve_python_absolute(self):
        self.assertEqual(
            bg.resolve_python_import("pkg.b", "x.py", {"pkg/b.py"}), "pkg/b.py")

    def test_resolve_python_package_init(self):
        self.assertEqual(
            bg.resolve_python_import("pkg", "x.py", {"pkg/__init__.py"}),
            "pkg/__init__.py")

    def test_imports_of_python_relative(self):
        fileset = {"pkg/a.py", "pkg/b.py"}
        out = bg.imports_of("python", "from .b import x\n", "pkg/a.py", fileset)
        self.assertEqual(out, ["pkg/b.py"])

    def test_parse_tsconfig_paths(self):
        with tempfile.TemporaryDirectory() as d:
            cfg = os.path.join(d, "tsconfig.json")
            with open(cfg, "w", encoding="utf-8") as fh:
                fh.write('{"compilerOptions":{"baseUrl":".","paths":{"@app/*":["src/*"]}}}')
            parsed = bg.parse_tsconfig(cfg, "")
            self.assertIsNotNone(parsed)
            _base, patterns = parsed
            self.assertIn("@app/*", dict(patterns))



class TestCommitsSince(unittest.TestCase):
    def test_equal_shas_are_zero_divergence(self):
        self.assertEqual(bg.commits_since("abc123", "abc123", "/nonexistent"), 0)

    def test_missing_prior_sha_is_unreachable_not_zero(self):
        # The prior-graph sanitizer coerces a non-string graph_built_at_sha to None:
        # unknown provenance must read as "unreachable" (None -> whole-graph rebuild
        # in compute_dirty), never as zero divergence.
        self.assertIsNone(bg.commits_since(None, "abc123", "/nonexistent"))
        self.assertIsNone(bg.commits_since("", "abc123", "/nonexistent"))

class TestMalformedInput(unittest.TestCase):
    def test_defines_of_empty(self):
        self.assertEqual(bg.defines_of("python", ""), [])

    def test_resolve_python_unresolvable(self):
        self.assertIsNone(bg.resolve_python_import("nope.missing", "x.py", set()))

    def test_parse_tsconfig_garbage_returns_none(self):
        with tempfile.TemporaryDirectory() as d:
            cfg = os.path.join(d, "tsconfig.json")
            with open(cfg, "w", encoding="utf-8") as fh:
                fh.write("this is not json {{{")
            self.assertIsNone(bg.parse_tsconfig(cfg, ""))

    def test_parse_tsconfig_missing_file_returns_none(self):
        self.assertIsNone(bg.parse_tsconfig("/nonexistent/tsconfig.json", ""))

    def test_defines_of_non_ascii_does_not_crash(self):
        # Symbol extraction over text carrying non-ASCII must not raise.
        result = bg.defines_of("python", "def café():\n    pass\ndef ok_name():\n    pass\n")
        self.assertIn("ok_name", result)

    def test_sh_replaces_invalid_utf8_bytes(self):
        # sh() decodes subprocess output with errors="replace" so a tracked filename
        # (or any output) carrying invalid UTF-8 bytes degrades to a lossy string
        # instead of aborting the build with UnicodeDecodeError (commit d8ace75).
        out = bg.sh(
            ["python3", "-c", r"import sys; sys.stdout.buffer.write(b'a\xff\xfeb')"],
            _ROOT)
        self.assertIn("a", out)
        self.assertIn("b", out)


class TestIncrementalDirtyDeletion(unittest.TestCase):
    def test_deleted_source_marks_importers_dirty(self):
        # b.py is deleted (gone from `files`); a.py imported it and is unchanged.
        # The incremental dirty set must still mark a.py dirty so its now-broken
        # import is re-audited, instead of producing an empty dirty set.
        files = ["a.py"]
        nodes = {"a.py": {"sha256": "AH"}}
        prior = {
            "a.py": {"sha256": "AH", "imports": ["b.py"]},
            "b.py": {"sha256": "BH", "imports": []},
        }
        prior_graph = {"nodes": prior, "graph_built_at_sha": "x", "coupling_edges": []}
        undirected = {"a.py": []}
        clusters = [{"id": 0, "label": "c", "members": ["a.py"]}]
        orig = bg.commits_since
        bg.commits_since = lambda *a, **k: 0  # no divergence -> stay on the incremental path
        try:
            dirty = bg.compute_dirty(files, nodes, prior, prior_graph,
                                     "head", undirected, [], clusters, ".")
        finally:
            bg.commits_since = orig
        self.assertFalse(dirty["whole_graph"])
        self.assertEqual(dirty["changed"], [])  # a.py's content did not change
        self.assertIn("a.py", dirty["nodes"])    # importer of deleted b.py is dirty
        self.assertIn(0, dirty["clusters"])


class TestSwallowSignals(unittest.TestCase):
    """Per-arm positive/negative pins for SWALLOW_KW — the error-swallowing routing
    signal behind Stage 2b's silent-failure promotion. Precision-leaning: each arm's
    documented non-match (a legitimate handler) is pinned as firmly as its match."""

    def test_python_except_pass_and_continue_match(self):
        self.assertEqual(bg.swallow_count_of("python", "try:\n    x()\nexcept Exception:\n    pass\n"), 1)
        self.assertEqual(bg.swallow_count_of("python", "except ValueError:\n    continue\n"), 1)
        self.assertEqual(bg.swallow_count_of("python", "except:\n    pass\n"), 1)

    def test_python_real_handlers_do_not_match(self):
        self.assertEqual(bg.swallow_count_of("python", "except ValueError:\n    raise\n"), 0)
        self.assertEqual(bg.swallow_count_of("python", "except OSError as e:\n    return None\n"), 0)
        # 'passes'/'continued' as prose after the colon must not satisfy the \b-anchored verb
        self.assertEqual(bg.swallow_count_of("python", "except OSError:\n    passthrough()\n"), 0)

    def test_bash_suppression_idioms_match(self):
        self.assertEqual(bg.swallow_count_of("bash", "rm -f x || true\n"), 1)
        self.assertEqual(bg.swallow_count_of("bash", "grep -q foo f 2>/dev/null\n"), 1)
        self.assertEqual(bg.swallow_count_of("bash", "cmd 2> /dev/null || true\n"), 2)

    def test_bash_real_fallbacks_do_not_match(self):
        self.assertEqual(bg.swallow_count_of("bash", "cmd || die 'failed'\n"), 0)
        self.assertEqual(bg.swallow_count_of("bash", "cmd > /dev/null\n"), 0)  # stdout, not stderr

    def test_js_empty_catch_matches_handled_catch_does_not(self):
        self.assertEqual(bg.swallow_count_of("js", "try { f() } catch (e) {}\n"), 1)
        self.assertEqual(bg.swallow_count_of("js", "try { f() } catch {  }\n"), 1)
        self.assertEqual(bg.swallow_count_of("js", "try { f() } catch (e) { log(e) }\n"), 0)

    def test_go_discarded_error_matches_handled_error_does_not(self):
        self.assertEqual(bg.swallow_count_of("go", "v, _ := strconv.Atoi(s)\n"), 1)
        self.assertEqual(bg.swallow_count_of("go", "\t_ = os.Remove(p)\n"), 1)
        self.assertEqual(bg.swallow_count_of("go", "v, err := strconv.Atoi(s)\n"), 0)
        self.assertEqual(bg.swallow_count_of("go", "for _, x := range xs {\n"), 0)

    def test_unmatched_languages_report_zero(self):
        # rust/c deliberately have no arm (unwrap panics loudly; no C idiom at this
        # precision); markdown has no code at all
        self.assertEqual(bg.swallow_count_of("rust", "let v = f().unwrap();\n"), 0)
        self.assertEqual(bg.swallow_count_of("c", "if (!ok) return 0;\n"), 0)
        self.assertEqual(bg.swallow_count_of("markdown", "except: pass\n"), 0)

    def test_swallow_at_attributes_to_the_swallowing_function(self):
        src = ("def quiet():\n"
               "    try:\n"
               "        x()\n"
               "    except Exception:\n"
               "        pass\n"
               "\n"
               "def loud():\n"
               "    x()\n")
        self.assertEqual(bg.swallow_at_of("python", src), {"quiet": 1, "loud": 0})


class TestImportStripping(unittest.TestCase):
    FILES = {"a.py", "secrets.py"}

    def test_unterminated_triple_quote_no_import(self):
        # An import-looking line inside an UNTERMINATED triple-quoted string must not
        # become an import edge (strip_comments must blank it to EOF, like blank_comments).
        src = 'x = """\nimport secrets\n'  # the triple-quote is never closed
        imps = bg.imports_of("python", src, "a.py", self.FILES)
        self.assertNotIn("secrets.py", imps)

    def test_real_import_still_resolves(self):
        # Control: a genuine top-level import is still extracted.
        imps = bg.imports_of("python", "import secrets\n", "a.py", self.FILES)
        self.assertIn("secrets.py", imps)


def _git(work, *args):
    subprocess.run(["git", "-C", work, *args], check=True,
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


class TestBuildWorktree(unittest.TestCase):
    def test_ls_files_deleted_worktree(self):
        # A tracked file deleted from the working tree but not staged is still
        # reported by `git ls-files`; build() must treat it as a dirty deletion
        # (drop the node) rather than crash on os.path.getsize/open.
        with tempfile.TemporaryDirectory() as work:
            _git(work, "init")
            _git(work, "config", "user.name", "t")
            _git(work, "config", "user.email", "t@t")
            with open(os.path.join(work, "kept.py"), "w") as fh:
                fh.write("import os\n")
            with open(os.path.join(work, "gone.py"), "w") as fh:
                fh.write("import sys\n")
            _git(work, "add", "-A")
            _git(work, "commit", "-m", "init")
            os.remove(os.path.join(work, "gone.py"))  # deleted, not staged
            graph = bg.build(work, None)  # must not raise
            self.assertIn("kept.py", graph["nodes"])
            self.assertNotIn("gone.py", graph["nodes"])


if __name__ == "__main__":
    unittest.main()
