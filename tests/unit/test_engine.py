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


if __name__ == "__main__":
    unittest.main()
