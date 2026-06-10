# SPDX-FileCopyrightText: 2026 Eser KUBALI
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Direct unit tests for the lint-plan engine. The smoke suite (tests/run.sh)
# exercises the CLI; these import the module functions and pin behavior on
# known inputs.
#
# Run: python3 -m unittest discover -s tests/unit -p "test_*.py"

import importlib.util
import os
import tempfile
import unittest

_HERE = os.path.dirname(os.path.abspath(__file__))
_ROOT = os.path.dirname(os.path.dirname(_HERE))


def _load_lint_plan():
    """Import scripts/lint-plan.py by path (the filename is not a valid module name)."""
    path = os.path.join(_ROOT, "scripts", "lint-plan.py")
    spec = importlib.util.spec_from_file_location("lint_plan_engine", path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


lp = _load_lint_plan()


class TestEvidenceAnchorEscape(unittest.TestCase):
    def test_evidence_anchor_escape_flagged(self):
        # An Evidence anchor that resolves outside the repo root via ../ must be
        # reported as an escape, not existence/range-checked against an outside file.
        with tempfile.TemporaryDirectory() as root:
            issues = lp.evidence_anchor_issues("traces to ../outside.py:1", root)
            self.assertTrue(any(kind == "escape" for _, kind, _ in issues),
                            f"expected an escape issue, got {issues}")

    def test_in_root_anchor_not_escape(self):
        # A normal in-root anchor to an existing file yields no escape issue.
        with tempfile.TemporaryDirectory() as root:
            with open(os.path.join(root, "x.py"), "w") as fh:
                fh.write("a = 1\n")
            issues = lp.evidence_anchor_issues("see x.py:1", root)
            self.assertFalse(any(kind == "escape" for _, kind, _ in issues),
                             f"unexpected escape issue, got {issues}")


class TestProseVerification(unittest.TestCase):
    def test_js_test_runners_not_prose(self):
        # A bare two-word command led by a real JS/TS test runner (no path/operator
        # char) must NOT be misread as prose just because the runner is not a Python tool.
        for cmd in ("vitest tests", "jest src", "mocha test", "ava unit",
                    "playwright tests"):
            self.assertFalse(lp.is_prose_verification(cmd),
                             f"{cmd!r} should be a runnable command, not prose")

    def test_genuine_prose_still_flagged(self):
        # The heuristic must still catch real prose (two+ words, no command-signal
        # char, first token not a known runner).
        for phrase in ("verify manually", "checks pending approval", "inspect the output"):
            self.assertTrue(lp.is_prose_verification(phrase),
                            f"{phrase!r} should be flagged as prose")


if __name__ == "__main__":
    unittest.main()
