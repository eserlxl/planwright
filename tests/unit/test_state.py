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


if __name__ == "__main__":
    unittest.main()
