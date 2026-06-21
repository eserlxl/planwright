# SPDX-FileCopyrightText: 2026 Eser KUBALI
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Contract test coupling state.py (the JSON producer) to the dashboard UI
# (scripts/dashboard/app.js, the consumer). state.py and app.js are otherwise
# only validated by manually loading the dashboard, so a field rename in
# state.collect() would silently break the UI at runtime. This pins the set of
# top-level keys the dashboard depends on: state.py must emit each, and app.js
# must reference each.
#
# Run: python3 -m unittest discover -s tests/unit -p "test_*.py"

import importlib.util
import os
import subprocess
import sys
import tempfile
import unittest

_HERE = os.path.dirname(os.path.abspath(__file__))
_ROOT = os.path.dirname(os.path.dirname(_HERE))
_SCRIPTS = os.path.join(_ROOT, "scripts")
_APP_JS = os.path.join(_SCRIPTS, "dashboard", "app.js")

# The top-level state.json keys the dashboard reads (s.<key> in app.js). Keys
# state.py emits for other consumers or that the UI derives itself (schema_version,
# counts, pending_modes) are intentionally not in this contract.
CONSUMED_KEYS = {
    "root", "head", "branch", "pending", "completed", "rejected",
    "final_point", "graph", "converged",
}

# Keys consumed by a specific view module rather than the app.js shell (views receive
# the state record directly, so a rename breaks them just as silently). Maps the key to
# the consumer file (relative to scripts/dashboard/) and the reference it must contain.
VIEW_CONSUMED_KEYS = {
    "repo": ("views/shards.js", "state.repo"),
    "activity": ("views/console.js", "state.activity"),
}


def _load_state():
    if _SCRIPTS not in sys.path:
        sys.path.insert(0, _SCRIPTS)
    path = os.path.join(_SCRIPTS, "state.py")
    spec = importlib.util.spec_from_file_location("planwright_state", path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


state = _load_state()


class TestDashboardStateContract(unittest.TestCase):
    def test_dashboard_state_contract(self):
        with tempfile.TemporaryDirectory() as root:
            os.makedirs(os.path.join(root, ".planwright"))
            with open(os.path.join(root, ".planwright", "plan.md"), "w") as fh:
                fh.write("# planwright Plan — .\n\n- [ ] t\n      Mode: repair\n")
            snapshot = state.collect(root)
        with open(_APP_JS, encoding="utf-8") as fh:
            app_js = fh.read()
        for key in CONSUMED_KEYS:
            self.assertIn(key, snapshot,
                          f"state.collect() no longer emits '{key}' the dashboard reads")
            self.assertIn("." + key, app_js,
                          f"app.js no longer references state.{key}")
        for key, (view_rel, ref) in VIEW_CONSUMED_KEYS.items():
            self.assertIn(key, snapshot,
                          f"state.collect() no longer emits '{key}' the {view_rel} view reads")
            view_path = os.path.join(_SCRIPTS, "dashboard", *view_rel.split("/"))
            with open(view_path, encoding="utf-8") as fh:
                self.assertIn(ref, fh.read(),
                              f"{view_rel} no longer references {ref}")


class TestRunHistoryLedger(unittest.TestCase):
    """Phase 7.2: activity_stop appends a bounded, length-capped run-history ledger
    (.planwright/runs.json) the dashboard renders as a run timeline. Beacons are set up via
    _write_activity (not activity_start) so the unit test never touches the real cross-repo registry."""

    def _beacon(self, root, command):
        state._write_activity(state._activity_path(root),
                              {"command": command, "started": "2026-06-21T00:00:00Z",
                               "updated": "2026-06-21T00:00:00Z"})

    def test_run_appended_and_survives_restart(self):
        with tempfile.TemporaryDirectory() as root:
            self._beacon(root, "plan")
            state.activity_stop(root, "plan")
            path = state._run_history_path(root)
            self.assertTrue(os.path.exists(path), "activity_stop did not write the run-history ledger")
            # "Simulated restart": re-read the ledger fresh from disk via the reader.
            runs = state._read_run_history(path)
            self.assertEqual(len(runs), 1, "expected exactly one run record")
            rec = runs[0]
            self.assertEqual(rec["command"], "plan")
            self.assertEqual(rec.get("started"), "2026-06-21T00:00:00Z")
            self.assertTrue(rec.get("ended"), "run record missing ended timestamp")

    def test_kept_beacon_records_no_run(self):
        # An inner flow stopping a beacon it does not own keeps it and records no run.
        with tempfile.TemporaryDirectory() as root:
            self._beacon(root, "codmaster")
            state.activity_stop(root, "execute")   # not the owner -> kept, no run recorded
            self.assertEqual(state._read_run_history(state._run_history_path(root)), [])

    def test_ledger_length_capped(self):
        with tempfile.TemporaryDirectory() as root:
            os.makedirs(os.path.join(root, ".planwright"), exist_ok=True)
            for i in range(5):
                state._append_run_record(
                    root, {"command": "c%d" % i, "started": "s", "ended": "e"}, cap=3)
            runs = state._read_run_history(state._run_history_path(root))
            self.assertEqual(len(runs), 3, "ledger not capped to the most recent 3")
            self.assertEqual([r["command"] for r in runs], ["c2", "c3", "c4"],
                             "the cap kept the wrong (not most-recent) records")

    def _git_init(self, root):
        subprocess.run(["git", "init", "-q", root], check=True, capture_output=True)
        subprocess.run(["git", "-C", root, "config", "user.email", "t@e.com"], check=True, capture_output=True)
        subprocess.run(["git", "-C", root, "config", "user.name", "t"], check=True, capture_output=True)
        subprocess.run(["git", "-C", root, "-c", "commit.gpgsign=false", "commit", "-q",
                        "--allow-empty", "-m", "init"], check=True, capture_output=True)
        return subprocess.run(["git", "-C", root, "rev-parse", "HEAD"],
                              capture_output=True, text=True).stdout.strip()

    def test_outcome_pending(self):
        # Pending work at stop -> the run record's outcome is 'pending'.
        with tempfile.TemporaryDirectory() as root:
            pw = os.path.join(root, ".planwright"); os.makedirs(pw)
            with open(os.path.join(pw, "plan.md"), "w", encoding="utf-8") as fh:
                fh.write("# plan\n\n- [ ] do a thing\n      Mode: improve\n")
            self._beacon(root, "execute")
            state.activity_stop(root, "execute")
            rec = state._read_run_history(state._run_history_path(root))[-1]
            self.assertEqual(rec.get("outcome"), "pending")

    def test_outcome_converged(self):
        # A certified whole-repo final point matching HEAD with nothing pending -> 'converged'.
        with tempfile.TemporaryDirectory() as root:
            head = self._git_init(root)
            pw = os.path.join(root, ".planwright"); os.makedirs(pw)
            with open(os.path.join(pw, "final.md"), "w", encoding="utf-8") as fh:
                fh.write("sha: %s\ndate: 2026-06-21\nrepair: dry\ncoverage: dry\n"
                         "opportunity: dry\nvision: dry\n" % head)
            self._beacon(root, "cycle")
            state.activity_stop(root, "cycle")
            rec = state._read_run_history(state._run_history_path(root))[-1]
            self.assertEqual(rec.get("outcome"), "converged")

    def test_outcome_stale(self):
        # A recorded final point whose sha no longer matches HEAD (nothing pending) -> 'stale'.
        with tempfile.TemporaryDirectory() as root:
            self._git_init(root)
            pw = os.path.join(root, ".planwright"); os.makedirs(pw)
            with open(os.path.join(pw, "final.md"), "w", encoding="utf-8") as fh:
                fh.write("sha: 0000000\ndate: 2026-06-21\nrepair: dry\ncoverage: dry\n"
                         "opportunity: dry\nvision: dry\n")   # sha != HEAD -> stale final point
            self._beacon(root, "cycle")
            state.activity_stop(root, "cycle")
            rec = state._read_run_history(state._run_history_path(root))[-1]
            self.assertEqual(rec.get("outcome"), "stale")


if __name__ == "__main__":
    unittest.main()
