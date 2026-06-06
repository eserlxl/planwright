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


if __name__ == "__main__":
    unittest.main()
