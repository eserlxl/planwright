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

    def test_field_label_spacing(self):
        # A space before the colon (`Mode :`) must be recognised as the field, not
        # silently absorbed as a wrapped continuation.
        items = plan_parse.parse_items("- [ ] t\n      Mode : repair\n")
        self.assertEqual(items[0]["fields"].get("Mode"), "repair")

    def test_multiword_field_label_preserved(self):
        # The internal space of a multi-word label is preserved (no regression).
        items = plan_parse.parse_items("- [ ] t\n      New Surfaces : a.py\n")
        self.assertEqual(items[0]["fields"].get("New Surfaces"), "a.py")

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

    def test_post_blank_field_lines_stay_attached_to_the_item(self):
        # The load-bearing cross-parser contract (lifecycle.py aligns to it): an
        # indented KNOWN `Field:` line after an internal blank still belongs to the
        # same item — a blank line ends the active FIELD, never the ITEM. A
        # blank-ends-item mutant (cur = None on blank) must fail this test.
        items = plan_parse.parse_items(
            "- [x] t\n"
            "      Mode: improve\n"
            "      Development: none.\n"
            "\n"
            "      Acceptance: tail fields survive\n"
            "      Verification: bash tests/run.sh\n")
        self.assertEqual(len(items), 1)
        self.assertEqual(items[0]["fields"]["Acceptance"], "tail fields survive")
        self.assertEqual(items[0]["fields"]["Verification"], "bash tests/run.sh")

    def test_span_is_the_verbatim_block_boundary(self):
        # span is the boundary primitive lifecycle slices on: it covers the head,
        # fields, wrapped continuations (column-0 included), post-blank attached
        # fields, and indented orphans — but a column-0 interstitial line closes it
        # so a later indented line cannot swallow the interstitial into the item.
        lines = [
            "# header",                      # 0 (preamble)
            "- [ ] a",                       # 1
            "      Mode: docs",              # 2
            "      Verification: true",      # 3
            "wrapped tail at column zero",   # 4 (joins Verification, extends span)
            "",                              # 5
            "      Acceptance: post-blank",  # 6 (attached field, extends span)
            "",                              # 7
            "- [x] b",                       # 8
            "      Mode: improve",           # 9
            "",                              # 10 (ends the active field)
            "## interstitial",               # 11 (no active field: closes b's span)
            "      Rationale: late",         # 12 (field captured, span unchanged)
        ]
        items = plan_parse.parse_items(lines)
        self.assertEqual(items[0]["span"], (1, 6))
        self.assertEqual(items[0]["fields"]["Verification"],
                         "true wrapped tail at column zero")
        self.assertEqual(items[0]["fields"]["Acceptance"], "post-blank")
        self.assertEqual(items[1]["span"], (8, 9))
        self.assertEqual(items[1]["fields"]["Rationale"], "late")

    def test_unknown_field_shaped_line_joins_into_current_field(self):
        # A `Note:`-shaped line is not a known field, so it wraps into the prior value
        # rather than starting a new key (the KNOWN_FIELDS gate).
        items = plan_parse.parse_items(
            "- [ ] t\n      Evidence: real\n      Note: stray\n")
        self.assertNotIn("Note", items[0]["fields"])
        self.assertEqual(items[0]["fields"]["Evidence"], "real Note: stray")

    def test_commit_provenance_stamp_is_a_first_class_field(self):
        # The execute path stamps `Commit: <short-sha>` on a passing item before
        # draining it to completed.md. The label must be in KNOWN_FIELDS: were it
        # unknown, the wrap rule above would silently absorb the stamp into the
        # preceding field's value (corrupting Verification) instead of recording it.
        items = plan_parse.parse_items(
            "- [x] t\n      Verification: bash tests/run.sh\n      Commit: be77dbd\n")
        self.assertEqual(items[0]["fields"]["Commit"], "be77dbd")
        self.assertEqual(items[0]["fields"]["Verification"], "bash tests/run.sh")


if __name__ == "__main__":
    unittest.main()
