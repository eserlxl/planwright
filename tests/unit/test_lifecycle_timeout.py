# SPDX-FileCopyrightText: 2026 Eser KUBALI
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Unit test for lifecycle._git_commit_meta's git timeout. reconcile() resolves a commit's
# metadata inside the held _state_lock; the three git calls now carry timeout=5 and the
# handler maps subprocess.TimeoutExpired to LookupError, so a wedged git (a stuck
# filesystem, a pathological repo) fails the transaction cleanly and releases the lock
# instead of hanging every planwright process on the same .planwright/ forever.
# lifecycle.py was the last engine script without git timeouts (status.py:_repo_block /
# _dirty_paths already pass timeout=5; build-graph.py honors PW_GIT_TIMEOUT_SECONDS).
#
# Run: python3 -m unittest discover -s tests/unit -p "test_*.py"

import importlib.util
import os
import subprocess
import sys
import unittest

_HERE = os.path.dirname(os.path.abspath(__file__))
_ROOT = os.path.dirname(os.path.dirname(_HERE))
_SCRIPTS = os.path.join(_ROOT, "scripts")


def _load_lifecycle():
    if _SCRIPTS not in sys.path:
        sys.path.insert(0, _SCRIPTS)
    path = os.path.join(_SCRIPTS, "lifecycle.py")
    spec = importlib.util.spec_from_file_location("planwright_lifecycle_timeout", path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


lc = _load_lifecycle()


class GitCommitMetaTimeout(unittest.TestCase):
    def test_every_git_call_carries_a_positive_timeout(self):
        """No git call _git_commit_meta makes may wait unbounded inside the held lock."""
        timeouts = []

        def fake_run(cmd, **kw):
            timeouts.append(kw.get("timeout"))
            return subprocess.CompletedProcess(cmd, 0, stdout="deadbeefcafe\n", stderr="")

        orig = lc.subprocess.run
        lc.subprocess.run = fake_run
        try:
            lc._git_commit_meta("/repo", "HEAD")
        finally:
            lc.subprocess.run = orig
        self.assertTrue(timeouts, "no git calls were made")
        self.assertTrue(all(t is not None and t > 0 for t in timeouts),
                        "a git call had no positive timeout: %r" % timeouts)

    def test_timeout_becomes_a_clean_lookuperror(self):
        """A wedged git (TimeoutExpired) maps to LookupError, so reconcile fails 'nothing
        was modified' and releases the state lock — never a hang, never a leaked timeout."""
        def fake_run(cmd, **kw):
            raise subprocess.TimeoutExpired(cmd, kw.get("timeout", 5))

        orig = lc.subprocess.run
        lc.subprocess.run = fake_run
        try:
            with self.assertRaises(LookupError) as ctx:
                lc._git_commit_meta("/repo", "HEAD")
        finally:
            lc.subprocess.run = orig
        self.assertIn("timed out", str(ctx.exception))


class RevListTimeout(unittest.TestCase):
    """_rev_list resolves the sweep range (<since>..HEAD) and, like _git_commit_meta, must
    not wait unbounded: a wedged git maps to LookupError so the sweep fails cleanly and
    releases the lock. This pins the second, distinct git call site, so a future edit cannot
    drop _rev_list's timeout while _git_commit_meta's stays covered."""

    def test_timeout_becomes_a_clean_lookuperror(self):
        def fake_run(cmd, **kw):
            raise subprocess.TimeoutExpired(cmd, kw.get("timeout", 5))

        orig = lc.subprocess.run
        lc.subprocess.run = fake_run
        try:
            with self.assertRaises(LookupError) as ctx:
                lc._rev_list("/repo", "abc123")
        finally:
            lc.subprocess.run = orig
        self.assertIn("timed out", str(ctx.exception))

    def test_rev_list_call_carries_a_positive_timeout(self):
        timeouts = []

        def fake_run(cmd, **kw):
            timeouts.append(kw.get("timeout"))
            return subprocess.CompletedProcess(cmd, 0, stdout="", stderr="")

        orig = lc.subprocess.run
        lc.subprocess.run = fake_run
        try:
            lc._rev_list("/repo", "abc123")
        finally:
            lc.subprocess.run = orig
        self.assertTrue(timeouts and all(t is not None and t > 0 for t in timeouts),
                        "rev-list call had no positive timeout: %r" % timeouts)


if __name__ == "__main__":
    unittest.main()
