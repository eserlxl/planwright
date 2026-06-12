# SPDX-FileCopyrightText: 2026 Eser KUBALI
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Direct unit tests for status.py's convergence gate and the mechanized coach
# (the codmaster / `planwright advise` decision surface). The smoke suite
# (tests/run.sh) exercises the CLI; these pin the broken-validator contract, the
# shared coach truth table (cross-pinned against derive.js via
# tests/fixtures/coach-table.json + coach-graph.json), and the repo-size
# constants' boundaries.
#
# Run: python3 -m unittest discover -s tests/unit -p "test_*.py"

import importlib.util
import json
import os
import sys
import tempfile
import unittest

_HERE = os.path.dirname(os.path.abspath(__file__))
_ROOT = os.path.dirname(os.path.dirname(_HERE))
_SCRIPTS = os.path.join(_ROOT, "scripts")


def _load_status():
    """Import scripts/status.py by path (it does `import plan_parse`, so scripts/ must be
    importable)."""
    if _SCRIPTS not in sys.path:
        sys.path.insert(0, _SCRIPTS)
    path = os.path.join(_SCRIPTS, "status.py")
    spec = importlib.util.spec_from_file_location("planwright_status", path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


st = _load_status()


class TestConvergenceValidator(unittest.TestCase):
    def test_lint_final_unloadable_fails_gate(self):
        # A present-but-broken validator must NOT certify convergence — _final_valid
        # returns False so --exit-code refuses rather than passing a CI gate blind.
        with tempfile.TemporaryDirectory() as root:
            saved = (st._LINT_FINAL, st._LINT_FINAL_STATUS)
            try:
                st._LINT_FINAL, st._LINT_FINAL_STATUS = None, "broken"
                self.assertFalse(st._final_valid(root))
                # A genuinely absent validator still degrades permissively.
                st._LINT_FINAL, st._LINT_FINAL_STATUS = None, "absent"
                self.assertTrue(st._final_valid(root))
            finally:
                st._LINT_FINAL, st._LINT_FINAL_STATUS = saved


_FIXTURES = os.path.join(_ROOT, "tests", "fixtures")


def _snake_signals(sig):
    """Map the fixture's camelCase (JS-native) signal keys to the Python port's names,
    defaulting absent keys the way coach_signals would."""
    key_map = {"cycles": "cycles", "hotUncovered": "hot_uncovered",
               "articulation": "articulation", "pendRepairImprove": "pend_repair_improve",
               "pending": "pending", "fpFlag": "fp_flag"}
    out = {"cycles": 0, "hot_uncovered": 0, "articulation": 0,
           "pend_repair_improve": 0, "pending": 0, "fp_flag": ""}
    for k, v in sig.items():
        out[key_map[k]] = v
    return out


class TestCoachTable(unittest.TestCase):
    def test_shared_truth_table_parity(self):
        # The same rows tests/cases/derive.sh asserts against derive.js coachRecommend —
        # the cross-pin that keeps the CLI brain and the dashboard brain identical.
        with open(os.path.join(_FIXTURES, "coach-table.json"), encoding="utf-8") as fh:
            tbl = json.load(fh)
        for row in tbl["rows"]:
            got = st.coach_recommend(_snake_signals(row["signals"]))["key"]
            self.assertEqual(got, row["expect"], "coach-table row: %s" % row["name"])

    def test_shared_graph_fixture_derivation(self):
        # The debt-signal derivation (hot-tercile tie semantics included), pinned to the
        # same expected numbers derive.sh asserts from derive.js metrics().
        with open(os.path.join(_FIXTURES, "coach-graph.json"), encoding="utf-8") as fh:
            fx = json.load(fh)
        with tempfile.TemporaryDirectory() as root:
            os.makedirs(os.path.join(root, ".planwright"))
            with open(os.path.join(root, ".planwright", "graph.json"), "w",
                      encoding="utf-8") as fh:
                json.dump(fx["graph"], fh)
            got = st._graph_signals(root)
        self.assertEqual(got, {
            "import_cycles": fx["expected"]["import_cycles"],
            "articulation": fx["expected"]["articulation"],
            "hot_uncovered": fx["expected"]["hot_uncovered"],
            "coverage_pct": fx["expected"]["coverage_pct"],
        })


class TestResetNecessity(unittest.TestCase):
    # The reset decision must be SHOWN necessary, never assumed: a seeded invent-dry point
    # is seed-scoped (re-survey), an undrained or unknown frontier still has non-destructive
    # moves (harden), and only unseeded + drained leaves reset as the one remaining move.
    def test_seeded_point_resurveys(self):
        self.assertEqual(st._reset_necessity({"invent_seed": 3}, {"never_audited": 0}),
                         "reinvent")

    def test_undrained_or_unknown_frontier_hardens(self):
        self.assertEqual(st._reset_necessity({"invent_seed": None}, {"never_audited": 2}),
                         "harden")
        self.assertEqual(st._reset_necessity({"invent_seed": None}, None), "harden")
        self.assertEqual(st._reset_necessity({"invent_seed": None}, {}), "harden")

    def test_unseeded_drained_is_really_necessary(self):
        self.assertEqual(st._reset_necessity({"invent_seed": None}, {"never_audited": 0}),
                         "reset")


class TestRepoSizeCall(unittest.TestCase):
    def test_large_boundaries(self):
        # The mechanical size call — pinned at both boundaries so the constants cannot
        # drift silently (LARGE_REPO_TRACKED_FILES = 120, SHARD_MIN_DIRS = 2).
        self.assertTrue(st._is_large(120, 2))
        self.assertFalse(st._is_large(119, 2))
        self.assertFalse(st._is_large(120, 1))

    def test_pct_rank_ties_and_edges(self):
        # derive.js pctRank parity: singleton/empty -> 0; strictly-less rank; ties share.
        self.assertEqual(st._pct_rank([5], 5), 0.0)
        self.assertEqual(st._pct_rank([], 0), 0.0)
        self.assertAlmostEqual(st._pct_rank([1, 2, 3, 4], 3), 2 / 3)
        self.assertAlmostEqual(st._pct_rank([1, 2, 2, 4], 2), 1 / 3)


if __name__ == "__main__":
    unittest.main()
