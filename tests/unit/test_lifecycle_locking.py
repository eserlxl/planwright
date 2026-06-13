# SPDX-FileCopyrightText: 2026 Eser KUBALI
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Unit tests for lifecycle.py's inter-process state lock (_state_lock). write() is atomic
# per single file, but a transaction (drain/land/reject/reset_if_empty) spans multiple
# read/append/write steps across plan.md/completed.md/rejected.md; the lock serializes the
# whole transaction so two concurrent sessions on the same .planwright/ cannot interleave
# and lose or duplicate an item.
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


def _load_lifecycle():
    if _SCRIPTS not in sys.path:
        sys.path.insert(0, _SCRIPTS)
    path = os.path.join(_SCRIPTS, "lifecycle.py")
    spec = importlib.util.spec_from_file_location("planwright_lifecycle_lock", path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


lc = _load_lifecycle()

_PENDING_PLAN = (
    "# planwright Plan\n\n"
    "- [ ] Lockable item\n"
    "      Mode: docs\n"
    "      Rationale: exercise the state lock.\n"
    "      Evidence: README.md exists.\n"
    "      Surfaces: README.md\n"
    "      Development: no-op probe.\n"
    "      Acceptance: lands.\n"
    "      Verification: true\n"
)


def _seed(root):
    os.makedirs(root, exist_ok=True)
    with open(os.path.join(root, "plan.md"), "w", encoding="utf-8") as fh:
        fh.write(_PENDING_PLAN)


@unittest.skipIf(lc.fcntl is None,
                 "fcntl unavailable (non-POSIX): the state lock is a documented no-op")
class TestStateLock(unittest.TestCase):
    def test_guard_is_exposed(self):
        # The module exposes the lock context manager and its lock-file name.
        self.assertTrue(hasattr(lc, "_state_lock"))
        self.assertEqual(lc.LOCK_NAME, ".lifecycle.lock")

    def test_land_acquires_and_releases_exclusive_lock(self):
        # A land transaction (driven through main) takes an exclusive LOCK_EX before
        # mutating and releases it (LOCK_UN) after — and the transaction still completes.
        import fcntl
        with tempfile.TemporaryDirectory() as root:
            _seed(root)
            ops = []
            real = fcntl.flock

            def rec(fd, op):
                ops.append(op)
                return real(fd, op)

            saved_argv, fcntl.flock = sys.argv, rec
            try:
                sys.argv = ["lifecycle.py", "land", "1", "--commit", "abc1234",
                            "--root", root, "--quiet"]
                rc = lc.main()
            finally:
                sys.argv, fcntl.flock = saved_argv, real
            self.assertEqual(rc, 0)
            self.assertIn(fcntl.LOCK_EX, ops)   # exclusive lock taken before the mutation
            self.assertIn(fcntl.LOCK_UN, ops)   # and released after
            with open(os.path.join(root, "completed.md"), encoding="utf-8") as fh:
                self.assertIn("Commit: abc1234", fh.read())

    def test_lock_is_mutually_exclusive(self):
        # Externally-observable serialization: while _state_lock holds the lock, a second
        # non-blocking acquisition on the same lock file fails; once released, it succeeds.
        import fcntl
        with tempfile.TemporaryDirectory() as root:
            with lc._state_lock(root):
                other = open(os.path.join(root, lc.LOCK_NAME), "a+")
                try:
                    with self.assertRaises((BlockingIOError, OSError)):
                        fcntl.flock(other.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
                finally:
                    other.close()
            again = open(os.path.join(root, lc.LOCK_NAME), "a+")
            try:
                fcntl.flock(again.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)  # must not raise now
                fcntl.flock(again.fileno(), fcntl.LOCK_UN)
            finally:
                again.close()


class TestStateLockDegrades(unittest.TestCase):
    def test_no_op_when_fcntl_absent(self):
        # On a non-POSIX platform fcntl is None; _state_lock must still run the guarded
        # block (and create no lock file) rather than crash a single-process run.
        saved = lc.fcntl
        lc.fcntl = None
        try:
            with tempfile.TemporaryDirectory() as root:
                ran = []
                with lc._state_lock(root):
                    ran.append(True)
                self.assertEqual(ran, [True])
                self.assertFalse(os.path.exists(os.path.join(root, lc.LOCK_NAME)))
        finally:
            lc.fcntl = saved

    def test_no_op_when_root_missing(self):
        # A not-yet-created root has nothing to serialize against: the lock degrades to a
        # no-op (the lock-file open fails -> proceed) rather than raising.
        with tempfile.TemporaryDirectory() as base:
            missing = os.path.join(base, "nope")  # base exists, this subdir does not
            ran = []
            with lc._state_lock(missing):
                ran.append(True)
            self.assertEqual(ran, [True])


if __name__ == "__main__":
    unittest.main()
