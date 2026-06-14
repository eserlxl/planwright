# SPDX-FileCopyrightText: 2026 Eser KUBALI
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Property-based / fuzz tests for the canonical plan-format parser (scripts/plan_parse.py).
# test_plan_parse.py pins pinned example cases; this file exercises parse_items() over
# randomized inputs to pin its load-bearing INVARIANTS — never-raises, item-count ==
# head-line-count, field values always stripped and single-line, well-formed spans, and
# the known-field / label-spacing round-trip — beyond any fixed string. lint-plan, status,
# state, and lifecycle all route through this parser, so a regression here would otherwise
# surface as a confusing downstream count mismatch.
#
# Run: python3 -m pytest tests/unit/test_plan_parse_props.py -q
#  or: python3 -m unittest discover -s tests/unit -p "test_*.py"  (hypothesis-skip-safe)

import importlib.util
import os
import sys
import unittest

_HERE = os.path.dirname(os.path.abspath(__file__))
_ROOT = os.path.dirname(os.path.dirname(_HERE))
sys.path.insert(0, os.path.join(_ROOT, "scripts"))

import plan_parse  # noqa: E402

_HAS_HYPOTHESIS = importlib.util.find_spec("hypothesis") is not None

if _HAS_HYPOTHESIS:
    from hypothesis import given, settings, strategies as st  # noqa: E402

    # No example database (keeps the repo tree clean — no .hypothesis/ dir) and no deadline
    # (the parser is fast, but CI machines vary); a focused example budget keeps the
    # unittest-discover run snappy.
    settings.register_profile("planwright_props", max_examples=150,
                              deadline=None, database=None)
    settings.load_profile("planwright_props")

    # Printable ASCII (0x20 space .. 0x7e '~'): no control characters and no Unicode
    # whitespace / line-separator code points, so regex \s, str.strip(), and
    # str.splitlines() all agree — a generated title/value can never be silently split
    # into extra lines, which keeps the item-count and round-trip properties well-defined.
    _ASCII = st.text(st.characters(min_codepoint=0x20, max_codepoint=0x7E), max_size=40)
    _MARK = st.sampled_from([" ", "x", "X"])
    _FIELDS = sorted(plan_parse.KNOWN_FIELDS)

    def _head(mark, title):
        return f"- [{mark}] {title}"

    @st.composite
    def _blocks(draw):
        """Build a sequence of plan blocks (a `- [ ]` head line + indented known-field
        lines + a blank separator). Returns (lines, head_count) so both the list-input and
        joined-string input paths can be checked against the same expected item count."""
        n = draw(st.integers(min_value=0, max_value=6))
        lines = []
        for _ in range(n):
            lines.append(_head(draw(_MARK), draw(_ASCII)))
            for k, v in draw(st.dictionaries(st.sampled_from(_FIELDS), _ASCII,
                                             max_size=5)).items():
                lines.append(f"      {k}: {v}")
            lines.append("")  # blank separator — never changes the item count
        return lines, n

    class TestParseItemsProperties(unittest.TestCase):
        @given(st.text())
        def test_never_raises_and_returns_list(self, text):
            self.assertIsInstance(plan_parse.parse_items(text), list)

        @given(st.lists(_ASCII, max_size=30))
        def test_accepts_a_list_of_lines(self, lines):
            self.assertIsInstance(plan_parse.parse_items(lines), list)

        @given(_blocks())
        def test_item_count_equals_head_line_count(self, payload):
            lines, n = payload
            self.assertEqual(len(plan_parse.parse_items(lines)), n)
            self.assertEqual(len(plan_parse.parse_items("\n".join(lines))), n)

        @given(st.text())
        def test_field_values_are_stripped_and_single_line(self, text):
            for item in plan_parse.parse_items(text):
                for value in item["fields"].values():
                    self.assertEqual(value, value.strip())
                    self.assertNotIn("\n", value)
                    self.assertNotIn("\r", value)

        @given(st.text())
        def test_span_is_wellformed(self, text):
            line_count = len(text.splitlines())
            for item in plan_parse.parse_items(text):
                lo, hi = item["span"]
                self.assertEqual(lo, item["line"] - 1)
                self.assertGreaterEqual(lo, 0)
                self.assertLessEqual(lo, hi)
                self.assertLess(hi, line_count)

        @given(_MARK, _ASCII,
               st.dictionaries(st.sampled_from(_FIELDS), _ASCII, max_size=len(_FIELDS)))
        def test_known_fields_round_trip(self, mark, title, fields):
            lines = [_head(mark, title)]
            lines += [f"      {k}: {v}" for k, v in fields.items()]
            items = plan_parse.parse_items("\n".join(lines))
            self.assertEqual(len(items), 1)
            item = items[0]
            self.assertEqual(item["title"], title.strip())
            self.assertEqual(item["checked"], mark.lower() == "x")
            for k, v in fields.items():
                self.assertEqual(item["fields"][k], v.strip())

        @given(_MARK, _ASCII, st.sampled_from(_FIELDS), _ASCII)
        def test_label_spacing_variants_recognised(self, mark, title, field, value):
            # The parser tolerates a space before the colon (`Mode :`) and none (`Mode:`):
            # each must be recognised as the field, never absorbed as a wrapped value.
            for sep in (": ", " : ", ":"):
                items = plan_parse.parse_items(
                    "\n".join([_head(mark, title), f"      {field}{sep}{value}"]))
                self.assertEqual(items[0]["fields"].get(field), value.strip())

else:  # pragma: no cover - exercised only where hypothesis is not installed
    class TestParseItemsProperties(unittest.TestCase):
        @unittest.skip("hypothesis is not installed")
        def test_property_suite_skipped(self):
            pass


if __name__ == "__main__":
    unittest.main()
