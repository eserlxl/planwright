# SPDX-FileCopyrightText: 2026 Eser KUBALI
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Direct unit tests for lifecycle.py --root validation. A NUL byte cannot pass
# through a subprocess argv (execve rejects it), so the CLI suite cannot cover
# this; call main() with a crafted sys.argv instead.
#
# Run: python3 -m unittest discover -s tests/unit -p "test_*.py"

import importlib.util
import os
import sys
import unittest

_HERE = os.path.dirname(os.path.abspath(__file__))
_ROOT = os.path.dirname(os.path.dirname(_HERE))
_SCRIPTS = os.path.join(_ROOT, "scripts")


def _load_lifecycle():
    if _SCRIPTS not in sys.path:
        sys.path.insert(0, _SCRIPTS)
    path = os.path.join(_SCRIPTS, "lifecycle.py")
    spec = importlib.util.spec_from_file_location("planwright_lifecycle", path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


lc = _load_lifecycle()


class TestRootValidation(unittest.TestCase):
    def _run(self, root):
        saved = sys.argv
        try:
            sys.argv = ["lifecycle.py", "reset", "--root", root, "--quiet"]
            return lc.main()
        finally:
            sys.argv = saved

    def test_lifecycle_root_null_byte_rejected(self):
        # A NUL byte in --root must be refused at the edge (rc 2), before any os.remove.
        self.assertEqual(self._run("bad\x00root"), 2)

    def test_lifecycle_root_control_char_rejected(self):
        self.assertEqual(self._run("bad\x01root"), 2)

    def test_lifecycle_root_traversal_still_rejected(self):
        self.assertEqual(self._run("../escape"), 2)


if __name__ == "__main__":
    unittest.main()
