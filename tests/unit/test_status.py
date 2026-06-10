# SPDX-FileCopyrightText: 2026 Eser KUBALI
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Direct unit tests for status.py's convergence gate. The smoke suite
# (tests/run.sh) exercises the CLI; these pin the broken-validator contract.
#
# Run: python3 -m unittest discover -s tests/unit -p "test_*.py"

import importlib.util
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


if __name__ == "__main__":
    unittest.main()
