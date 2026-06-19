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
import shutil
import subprocess
import tempfile
import unittest
from unittest import mock

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


class TestEvidenceAnchorMultiReport(unittest.TestCase):
    """evidence_anchor_issues reports every distinct offending anchor while deduping repeats,
    so an ungrounded plan item is never silently half-validated on a multi-anchor Evidence line."""

    def test_two_distinct_missing_anchors_yield_two_issues(self):
        with tempfile.TemporaryDirectory() as root:
            issues = lp.evidence_anchor_issues("cites ghost_a.py:1 and ghost_b.py:2", root)
            missing = sorted(p for p, kind, _ in issues if kind == "missing")
            self.assertEqual(missing, ["ghost_a.py", "ghost_b.py"],
                             f"both distinct missing anchors must be reported, got {issues}")

    def test_repeated_anchor_deduped_to_one_issue(self):
        with tempfile.TemporaryDirectory() as root:
            issues = lp.evidence_anchor_issues("ghost.py:1 then ghost.py:1 again", root)
            missing = [p for p, kind, _ in issues if kind == "missing" and p == "ghost.py"]
            self.assertEqual(len(missing), 1,
                             f"a repeated anchor must dedup to a single issue, got {issues}")

    def test_mixed_escape_and_missing_each_reported(self):
        with tempfile.TemporaryDirectory() as root:
            issues = lp.evidence_anchor_issues("traces to ../outside.py:1 and ghost.py:2", root)
            kinds = {kind for _, kind, _ in issues}
            self.assertIn("escape", kinds, f"the escape anchor must be reported, got {issues}")
            self.assertIn("missing", kinds, f"the missing anchor must be reported, got {issues}")


class TestEvidenceAnchorFormParity(unittest.TestCase):
    """The two supported anchor spellings (path:N and path (line N)) must behave identically,
    so a regex change cannot let one spelling silently bypass the grounding range check."""

    def test_colon_and_paren_forms_yield_identical_issue(self):
        with tempfile.TemporaryDirectory() as root:
            with open(os.path.join(root, "small.py"), "w") as fh:
                fh.write("a = 1\nb = 2\nc = 3\n")
            colon = lp.evidence_anchor_issues("see small.py:99999", root)
            paren = lp.evidence_anchor_issues("see small.py (line 99999)", root)
            self.assertEqual(colon, paren,
                             f"the :N and (line N) anchor forms must produce identical issues, "
                             f"got colon={colon} paren={paren}")
            self.assertTrue(colon and colon[0][1] == "out-of-range",
                            f"expected an out-of-range issue, got {colon}")


class TestUnsafeSurfaceContainment(unittest.TestCase):
    """unsafe_surface() is execute mode's edit-boundary guard; its rejection branches must
    each be pinned so a containment escape can never be silently accepted."""

    def test_drive_absolute_surface_rejected(self):
        # A Windows drive-absolute path (forward- or back-slashed) is absolute, not
        # repo-relative — the np[1] == ":" branch must reject it with the absolute reason.
        with tempfile.TemporaryDirectory() as root:
            reason = "absolute path (Surfaces must be repo-relative)"
            self.assertEqual(lp.unsafe_surface("C:/Users/x", root), reason)
            self.assertEqual(lp.unsafe_surface("C:\\Users\\x", root), reason)

    def test_commonpath_valueerror_degrades_to_outside_root(self):
        # When os.path.commonpath raises (uncomparable roots / different drive), the
        # containment guard must degrade-not-crash: contained=False -> reject as outside.
        with tempfile.TemporaryDirectory() as root:
            with mock.patch("os.path.commonpath", side_effect=ValueError):
                self.assertEqual(lp.unsafe_surface("sub/file.py", root),
                                 "resolves outside the repo root")


class TestEvidenceAnchorGitignore(unittest.TestCase):
    """planwright must never scan gitignored files — the Evidence range check must not open
    a file git deliberately excludes (a generated dist/ bundle, a vendored file)."""

    @staticmethod
    def _git(root, *args):
        subprocess.run(["git", "-C", root, *args], check=True,
                       capture_output=True, text=True)

    @unittest.skipUnless(shutil.which("git"), "git required for the gitignore guard")
    def test_gitignored_citation_is_not_opened(self):
        with tempfile.TemporaryDirectory() as root:
            self._git(root, "init")
            with open(os.path.join(root, ".gitignore"), "w") as fh:
                fh.write("dist/\n")
            os.mkdir(os.path.join(root, "dist"))
            with open(os.path.join(root, "dist", "bundle.js"), "w") as fh:
                fh.write("a\nb\n")  # 2 lines, but gitignored
            os.mkdir(os.path.join(root, "src"))
            with open(os.path.join(root, "src", "app.js"), "w") as fh:
                fh.write("a\nb\n")  # 2 lines, NOT ignored
            # A citation into the gitignored tree must NOT be opened: its line count is never
            # read, so an out-of-range cited line cannot be flagged (the file is out of scope).
            ign = lp.evidence_anchor_issues("see dist/bundle.js:9999", root)
            self.assertEqual([], ign,
                             f"a gitignored citation must not be opened/range-checked, got {ign}")
            # Control: an identical citation to a non-ignored file IS range-checked, proving the
            # skip above is the gitignore guard, not a parsing miss.
            tracked = lp.evidence_anchor_issues("see src/app.js:9999", root)
            self.assertTrue(any(kind == "out-of-range" for _, kind, _ in tracked),
                            f"a non-ignored citation should still be range-checked, got {tracked}")


class TestProseVerification(unittest.TestCase):
    def test_js_test_runners_not_prose(self):
        # A bare two-word command led by a real JS/TS test runner (no path/operator
        # char) must NOT be misread as prose just because the runner is not a Python tool.
        for cmd in ("vitest tests", "jest src", "mocha test", "ava unit",
                    "playwright tests"):
            self.assertFalse(lp.is_prose_verification(cmd),
                             f"{cmd!r} should be a runnable command, not prose")

    def test_custom_underscore_runner_not_prose(self):
        # A project-specific runner whose name carries a '_' ("run_tests all") must not be
        # misread as prose. '-' and '.' already register as command signals anywhere in the
        # value; '_' did not, so the underscore form was wrongly flagged while its hyphenated
        # twin passed. The first token being program-name-shaped now suffices.
        for cmd in ("run_tests all", "build_check fast", "run-tests all", "a.out --check"):
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
