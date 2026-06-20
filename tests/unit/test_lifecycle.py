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

    def test_reconcile_does_not_cap_completed(self):
        # The OTHER append path: reconcile (record a directly-committed fix) must also NEVER
        # truncate mid-run. land's no-cap is pinned by test_land_does_not_cap_completed; both
        # paths funnel through append_blocks, whose cap is deferred to housekeep/cap_log. A
        # reconcile during a long codshard/codmaster sweep would otherwise drop the run's
        # earliest records before the run boundary.
        blocks = "".join(f"- [x] old {i}\n      Mode: docs\n\n" for i in range(lc.FIFO_CAP))
        with open(self.completed, "w", encoding="utf-8") as fh:
            fh.write(blocks)
        repo = os.path.join(self.root, "repo")
        os.makedirs(repo)

        def _git(*args):
            subprocess.run(["git", "-C", repo, *args], check=True, capture_output=True)

        _git("init", "-q")
        _git("config", "user.email", "t@example.com")
        _git("config", "user.name", "t")
        _git("config", "commit.gpgsign", "false")
        with open(os.path.join(repo, "f.txt"), "w", encoding="utf-8") as fh:
            fh.write("hi\n")
        _git("add", "-A")
        _git("commit", "-qm", "Reconcile no-cap subject")
        full = subprocess.run(["git", "-C", repo, "rev-parse", "HEAD"],
                              check=True, capture_output=True, text=True).stdout.strip()
        short, title, recorded = lc.reconcile(self.completed, repo, full, "improve")
        self.assertTrue(recorded)
        done = self._read(self.completed)
        self.assertIn(f"- [x] {title}", done)            # the freshly reconciled fix
        self.assertIn("- [x] old 0\n", done)             # oldest RETAINED — reconcile never caps
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

    def test_cap_log_exact_boundary(self):
        # Direct cap_log boundary: the deferred FIFO bound is a no-op at EXACTLY FIFO_CAP
        # (the `<= FIFO_CAP` guard, not `<`), and drops EXACTLY the single oldest at +1.
        # The CLI tests use 5 (under) and FIFO_CAP+3 (over) — neither pins this inflection.
        # (a) exactly FIFO_CAP: no-op, returns 0, file left byte-untouched (no rewrite).
        at_cap = "".join(
            f"- [x] old {i}\n      Mode: docs\n\n" for i in range(lc.FIFO_CAP))
        with open(self.completed, "w", encoding="utf-8") as fh:
            fh.write(at_cap)
        before = self._read(self.completed)
        self.assertEqual(lc.cap_log(self.completed), 0)
        self.assertEqual(self._read(self.completed), before)  # byte-untouched
        # (b) exactly FIFO_CAP + 1: drops exactly one (the oldest), keeps the newest cap in order.
        over = "".join(
            f"- [x] old {i}\n      Mode: docs\n\n" for i in range(lc.FIFO_CAP + 1))
        with open(self.completed, "w", encoding="utf-8") as fh:
            fh.write(over)
        self.assertEqual(lc.cap_log(self.completed), 1)
        done = self._read(self.completed)
        self.assertEqual(done.count("- [x] "), lc.FIFO_CAP)
        self.assertNotIn("- [x] old 0\n", done)              # the single oldest dropped
        self.assertIn("- [x] old 1\n", done)                 # 2nd-oldest is the new floor
        self.assertIn(f"- [x] old {lc.FIFO_CAP}\n", done)    # newest kept

    def test_reconcile_sweep_and_dryrun_arg_guards(self):
        # The reconcile-sweep / stray-flag guards (lifecycle.py argument router). Two branches
        # the CLI suite's L21d does NOT cover: reconcile-sweep must keep its --since path
        # separate from reconcile's --commit path, and a stray --dry-run on a non-sweep command
        # is a mistype that must hard-fail (the args.dry_run half of the guard, distinct from
        # the args.since half L21d already pins). Both exit 2 and write nothing.
        # (a) reconcile-sweep refuses --commit (paths stay separated)
        self.assertEqual(
            self._run("reconcile-sweep", "--since", "HEAD", "--mode", "improve",
                      "--commit", "abc1234"), 2)
        # (b) a stray --dry-run on a non-sweep command is rejected
        self.assertEqual(self._run("housekeep", "--dry-run"), 2)
        # (c) sanity mirror: a stray --since is likewise rejected (also pinned by L21d)
        self.assertEqual(self._run("housekeep", "--since", "HEAD"), 2)
        # nothing was written by any refused invocation
        self.assertFalse(os.path.exists(self.completed))


class TestReconcileSweep(unittest.TestCase):
    """reconcile_sweep — the recovery safety net that re-records dropped fix commits.

    The CLI arg-guard test (test_reconcile_sweep_and_dryrun_arg_guards) pins the router;
    these exercise the recovery BEHAVIOR end to end on a real commit range."""

    def setUp(self):
        import tempfile
        self._tmp = tempfile.TemporaryDirectory()
        self.root = self._tmp.name
        self.completed = os.path.join(self.root, "completed.md")
        self.rejected = os.path.join(self.root, "rejected.md")
        self.repo = os.path.join(self.root, "repo")
        os.makedirs(self.repo)
        self._git("init", "-q")
        self._git("config", "user.email", "t@example.com")
        self._git("config", "user.name", "t")
        self._git("config", "commit.gpgsign", "false")

    def tearDown(self):
        self._tmp.cleanup()

    def _git(self, *args):
        subprocess.run(["git", "-C", self.repo, *args], check=True, capture_output=True)

    def _commit(self, subject, fname):
        with open(os.path.join(self.repo, fname), "w", encoding="utf-8") as fh:
            fh.write(subject + "\n")
        self._git("add", "-A")
        self._git("commit", "-qm", subject)
        return subprocess.run(["git", "-C", self.repo, "rev-parse", "HEAD"],
                              check=True, capture_output=True, text=True).stdout.strip()

    def _read(self, path):
        with open(path, encoding="utf-8") as fh:
            return fh.read()

    def test_reconcile_sweep_recovers_only_missing_commits_exactly_once(self):
        # A partially-reconciled ledger: the middle commit is pre-recorded; the sweep must
        # recover the rest, classify the pre-recorded one already-recorded, and record each
        # exactly once (no duplicate for the one already present).
        base = self._commit("Base groundwork", "base.txt")
        self._commit("Implement alpha path", "a.txt")
        c2 = self._commit("Implement beta path", "b.txt")
        self._commit("Implement gamma path", "c.txt")
        lc.reconcile(self.completed, self.repo, c2, "improve")
        recorded, skipped = lc.reconcile_sweep(
            self.completed, self.rejected, self.repo, base, "improve")
        already = [s for s in skipped if s[2] == "already-recorded"]
        self.assertEqual(len(already), 1)
        self.assertTrue(c2.startswith(already[0][0]))          # short is a prefix of the full sha
        fresh = [r for r in recorded if r[2] == "recorded"]
        self.assertEqual(len(fresh), 2)                        # alpha + gamma freshly recovered
        done = self._read(self.completed)
        for subj in ("Implement alpha path", "Implement beta path", "Implement gamma path"):
            self.assertEqual(done.count("- [x] " + subj), 1)   # each present EXACTLY once
        self.assertNotIn("Base groundwork", done)              # <since>..HEAD excludes the base


class TestAtomicWrite(unittest.TestCase):
    """lifecycle.write — atomic temp+os.replace; a crash mid-rename must not truncate."""

    def setUp(self):
        import tempfile
        self._tmp = tempfile.TemporaryDirectory()
        self.root = self._tmp.name

    def tearDown(self):
        self._tmp.cleanup()

    def _read(self, path):
        with open(path, encoding="utf-8") as fh:
            return fh.read()

    def test_write_crash_leaves_target_byte_intact_and_no_straggler(self):
        import glob
        target = os.path.join(self.root, "completed.md")
        prior = "# planwright Plan — .\n\n- [x] keep me\n      Mode: docs\n"
        with open(target, "w", encoding="utf-8") as fh:
            fh.write(prior)
        saved = os.replace

        def boom(src, dst):
            raise OSError("simulated crash during rename")

        new_block = {"checked": True, "rejected": False,
                     "lines": ["- [x] new", "      Mode: docs"]}
        os.replace = boom
        try:
            with self.assertRaises(OSError):
                lc.write(target, "# planwright Plan — .", [new_block])
        finally:
            os.replace = saved
        # original is byte-identical (no truncate-in-place) ...
        self.assertEqual(self._read(target), prior)
        # ... and the temp was cleaned up (no .lifecycle-*.tmp straggler).
        self.assertEqual(glob.glob(os.path.join(self.root, ".lifecycle-*.tmp")), [])


if __name__ == "__main__":
    unittest.main()
