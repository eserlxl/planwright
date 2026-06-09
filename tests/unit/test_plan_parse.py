# SPDX-FileCopyrightText: 2026 Eser KUBALI
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Direct unit tests for the canonical plan-format parser (scripts/plan_parse.py).
# lint-plan.py, status.py, and state.py all route through parse_items(), so its
# load-bearing contracts are pinned here directly — a regression fails at the parser
# rather than surfacing as a confusing downstream count mismatch.
#
# Run: python3 -m unittest discover -s tests/unit -p "test_*.py"

import os
import sys
import unittest

_HERE = os.path.dirname(os.path.abspath(__file__))
_ROOT = os.path.dirname(os.path.dirname(_HERE))
sys.path.insert(0, os.path.join(_ROOT, "scripts"))

import plan_parse  # noqa: E402


class TestParseItems(unittest.TestCase):
    def test_colon_bearing_value_round_trips(self):
        # The first colon splits label from value; every later colon (a file:line:col
        # Evidence anchor, the heart of the repair contract) is preserved verbatim.
        items = plan_parse.parse_items(
            "- [ ] t\n      Evidence: scripts/x.py:42: got 5, want 6\n")
        self.assertEqual(items[0]["fields"]["Evidence"], "scripts/x.py:42: got 5, want 6")

    def test_title_trailing_space_stripped(self):
        items = plan_parse.parse_items("- [ ] My Title   \n")
        self.assertEqual(items[0]["title"], "My Title")

    def test_field_value_whitespace_stripped(self):
        items = plan_parse.parse_items("- [ ] t\n      Mode:    repair   \n")
        self.assertEqual(items[0]["fields"]["Mode"], "repair")

    def test_checkbox_marker_is_case_insensitive(self):
        items = plan_parse.parse_items("- [ ] a\n- [x] b\n- [X] c\n")
        self.assertEqual([it["checked"] for it in items], [False, True, True])

    def test_wrapped_continuation_joins_with_single_space(self):
        items = plan_parse.parse_items(
            "- [ ] t\n      Rationale: first\n        second line\n")
        self.assertEqual(items[0]["fields"]["Rationale"], "first second line")

    def test_blank_line_ends_field_block(self):
        # A blank line resets the active field, so a later indented line is NOT appended.
        items = plan_parse.parse_items(
            "- [ ] t\n      Rationale: kept\n\n      orphan trailing\n")
        self.assertEqual(items[0]["fields"]["Rationale"], "kept")

    def test_unknown_field_shaped_line_joins_into_current_field(self):
        # A `Note:`-shaped line is not a known field, so it wraps into the prior value
        # rather than starting a new key (the KNOWN_FIELDS gate).
        items = plan_parse.parse_items(
            "- [ ] t\n      Evidence: real\n      Note: stray\n")
        self.assertNotIn("Note", items[0]["fields"])
        self.assertEqual(items[0]["fields"]["Evidence"], "real Note: stray")


if __name__ == "__main__":
    unittest.main()
