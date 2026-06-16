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

    def test_reject_appends_canonical_lines_and_drains(self):
        # Same pending numbering as land: index 2 skips the checked interloper.
        # The appended Status/Rejection spelling must be the exact machine-readable
        # form drain_rejected and the PREVIOUSLY REJECTED reader key on.
        rejected = os.path.join(self.root, "rejected.md")
        self.assertEqual(self._run("reject", "2", "--reason",
                                   "verification failed: flaky target"), 0)
        out = self._read(rejected)
        self.assertIn("- [ ] second thing", out)
        self.assertIn("      Status: Rejected", out)
        self.assertIn("      Rejection: verification failed: flaky target", out)
        plan = self._read(self.plan)
        self.assertIn("- [ ] first thing", plan)
        self.assertNotIn("second thing", plan)

    def test_reject_out_of_range_modifies_nothing(self):
        before = self._read(self.plan)
        self.assertEqual(self._run("reject", "9", "--reason", "nope"), 2)
        self.assertEqual(self._read(self.plan), before)
        self.assertFalse(os.path.exists(os.path.join(self.root, "rejected.md")))

    def test_reject_reason_validation(self):
        self.assertEqual(self._run("reject", "1"), 2)                          # no --reason
        self.assertEqual(self._run("reject", "1", "--reason", "   "), 2)       # blank
        self.assertEqual(self._run("reject", "1", "--reason", "two\nlines"), 2)  # newline
        # Spaces are prose, not corruption — a normal one-line reason is accepted.
        self.assertEqual(self._run("reject", "1", "--reason", "a real reason"), 0)

    def test_land_and_reject_options_do_not_cross(self):
        self.assertEqual(self._run("land", "1", "--reason", "x"), 2)
        self.assertEqual(self._run("reject", "1", "--commit", "abc1234"), 2)

    def test_land_does_not_cap_completed(self):
        # Execute (land) must NEVER truncate: a run that lands past FIFO_CAP items keeps its
        # full record so the dashboard's accepted count reflects the whole current plan rather
        # than a mid-run-truncated 100. The cap is deferred to the next run's Stage 0 housekeep
        # (see test_housekeep_caps_completed_log).
        blocks = "".join(f"- [x] old {i}\n      Mode: docs\n\n" for i in range(lc.FIFO_CAP))
        with open(self.completed, "w", encoding="utf-8") as fh:
            fh.write(blocks)
        self.assertEqual(self._run("land", "1", "--commit", "abc1234"), 0)
        done = self._read(self.completed)
        self.assertIn("- [x] first thing", done)        # the freshly landed item
        self.assertIn("- [x] old 0\n", done)            # oldest RETAINED — execute never caps
        self.assertEqual(done.count("- [x] "), lc.FIFO_CAP + 1)

    def test_housekeep_caps_completed_log(self):
        # The deferred FIFO bound: housekeep (Stage 0 of the *next* run) trims the accumulated
        # log back to FIFO_CAP, dropping the oldest from the top. plan.md is removed first so
        # the drain moves nothing and this isolates the cap step.
        over = lc.FIFO_CAP + 3
        blocks = "".join(f"- [x] old {i}\n      Mode: docs\n\n" for i in range(over))
        with open(self.completed, "w", encoding="utf-8") as fh:
            fh.write(blocks)
        os.remove(self.plan)
        self.assertEqual(self._run("housekeep"), 0)
        done = self._read(self.completed)
        self.assertEqual(done.count("- [x] "), lc.FIFO_CAP)
        self.assertNotIn("- [x] old 0\n", done)         # oldest 3 (0,1,2) dropped to hold the cap
        self.assertNotIn("- [x] old 2\n", done)
        self.assertIn("- [x] old 3\n", done)            # 4th-oldest is the new floor
        self.assertIn(f"- [x] old {over - 1}\n", done)  # newest kept

    def test_housekeep_below_cap_leaves_completed_untouched(self):
        # Under the cap, housekeep must not rewrite completed.md (cap_log returns 0).
        blocks = "".join(f"- [x] old {i}\n      Mode: docs\n\n" for i in range(5))
        with open(self.completed, "w", encoding="utf-8") as fh:
            fh.write(blocks)
        before = self._read(self.completed)
        os.remove(self.plan)
        self.assertEqual(self._run("housekeep"), 0)
        self.assertEqual(self._read(self.completed), before)


if __name__ == "__main__":
    unittest.main()
