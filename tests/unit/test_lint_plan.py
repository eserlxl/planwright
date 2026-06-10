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


if __name__ == "__main__":
    unittest.main()
