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


class TestLand(unittest.TestCase):
    """lifecycle.py land — the execute path's On PASS bookkeeping in one step."""

    PLAN = ("# planwright Plan — .\n\n"
            "- [ ] first thing\n      Mode: docs\n      Verification: true\n\n"
            "- [x] already done\n      Mode: improve\n\n"
            "- [ ] second thing\n      Mode: develop\n      Verification: true\n")

    def setUp(self):
        import tempfile
        self._tmp = tempfile.TemporaryDirectory()
        self.root = self._tmp.name
        self.plan = os.path.join(self.root, "plan.md")
        self.completed = os.path.join(self.root, "completed.md")
        with open(self.plan, "w", encoding="utf-8") as fh:
            fh.write(self.PLAN)

    def tearDown(self):
        self._tmp.cleanup()

    def _run(self, *argv):
        saved = sys.argv
        try:
            sys.argv = ["lifecycle.py", *argv, "--root", self.root, "--quiet"]
            return lc.main()
        finally:
            sys.argv = saved

    def _read(self, path):
        with open(path, encoding="utf-8") as fh:
            return fh.read()

    def test_land_flips_stamps_and_drains_one_item(self):
        # Index 2 counts PENDING blocks only, so the checked interloper is skipped
        # and 'second thing' lands — flipped, stamped, and drained in one step.
        self.assertEqual(self._run("land", "2", "--commit", "abc1234"), 0)
        done = self._read(self.completed)
        self.assertIn("- [x] second thing", done)
        self.assertIn("      Commit: abc1234", done)
        plan = self._read(self.plan)
        self.assertIn("- [ ] first thing", plan)       # untouched sibling stays pending
        self.assertIn("- [x] already done", plan)      # non-target checked block stays
        self.assertNotIn("second thing", plan)

    def test_land_out_of_range_modifies_nothing(self):
        before = self._read(self.plan)
        self.assertEqual(self._run("land", "3", "--commit", "abc1234"), 2)
        self.assertEqual(self._read(self.plan), before)
        self.assertFalse(os.path.exists(self.completed))

    def test_land_requires_commit_and_index(self):
        self.assertEqual(self._run("land", "1"), 2)                       # no --commit
        self.assertEqual(self._run("land", "--commit", "abc1234"), 2)     # no index
        self.assertEqual(self._run("land", "1", "--commit", "bad sha"), 2)  # whitespace

    def test_land_args_rejected_on_other_subcommands(self):
        self.assertEqual(self._run("housekeep", "1"), 2)
        self.assertEqual(self._run("housekeep", "--commit", "abc1234"), 2)

    def test_land_keeps_completed_fifo_cap(self):
        blocks = "".join(f"- [x] old {i}\n      Mode: docs\n\n" for i in range(lc.FIFO_CAP))
        with open(self.completed, "w", encoding="utf-8") as fh:
            fh.write(blocks)
        self.assertEqual(self._run("land", "1", "--commit", "abc1234"), 0)
        done = self._read(self.completed)
        self.assertIn("- [x] first thing", done)
        self.assertNotIn("- [x] old 0\n", done)        # oldest dropped to hold the cap
        self.assertEqual(done.count("- [x] "), lc.FIFO_CAP)


if __name__ == "__main__":
    unittest.main()
