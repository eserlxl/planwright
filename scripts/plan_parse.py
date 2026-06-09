#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Eser KUBALI
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Canonical parser for the planwright plan-format markdown (plan.md / completed.md /
# rejected.md): a `- [ ]`/`- [x]` checkbox line followed by indented `Field: value`
# continuation lines, where a value may wrap onto following indented non-field lines.
#
# lint-plan.py (Stage 10 gate), state.py (dashboard JSON), and status.py (summary)
# all read this format. Each historically carried its own parser, so the project's
# core contract had to be changed in lockstep across three sites and could silently
# diverge. They now all route through parse_items() here — the format is recognised
# in exactly one place.

import re

# Every continuation field the OUTPUT FORMAT defines (the eight plan fields) plus the
# lifecycle fields the execute/reject path appends (Status / Rejection). This is the
# default recognised-field set; lint-plan passes its own (identical) set so the Stage
# 10 gate keeps ownership of REQUIRED_FIELDS.
KNOWN_FIELDS = frozenset({
    "Mode", "Rationale", "Evidence", "Surfaces", "New Surfaces",
    "Development", "Acceptance", "Verification", "Status", "Rejection",
})

_HEAD_RE = re.compile(r"^- \[([ xX])\]\s*(.*)$")
_FIELD_RE = re.compile(r"^\s+([A-Z][A-Za-z ]*?):\s*(.*)$")


def parse_items(text, known_fields=KNOWN_FIELDS):
    """Parse plan-format markdown into a list of item dicts:
    {checked: bool, title: str, line: int (1-based), fields: {name: value}}.

    A field's value joins any wrapped continuation lines (a following indented line
    that is not itself a recognised `Field:`). Only labels in `known_fields` are
    captured; a later occurrence of a field overwrites the earlier one. `text` may be
    a string or an already-split list of lines."""
    lines = text if isinstance(text, list) else text.splitlines()
    items = []
    cur = None
    field = None
    for i, raw in enumerate(lines, 1):
        raw = raw.rstrip("\n")
        head = _HEAD_RE.match(raw)
        if head:
            cur = {"checked": head.group(1).lower() == "x",
                   "title": head.group(2).strip(), "line": i, "fields": {}}
            items.append(cur)
            field = None
            continue
        if cur is None:
            continue
        m = _FIELD_RE.match(raw)
        if m and m.group(1) in known_fields:
            field = m.group(1)
            cur["fields"][field] = m.group(2).strip()
        elif field is not None and raw.strip():
            # wrapped continuation of the current field's value
            cur["fields"][field] = (cur["fields"][field] + " " + raw.strip()).strip()
        elif not raw.strip():
            field = None  # blank line ends a field block
    return items
