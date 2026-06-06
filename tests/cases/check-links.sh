# SPDX-FileCopyrightText: 2026 Eser KUBALI
# SPDX-License-Identifier: GPL-3.0-or-later
# shellcheck shell=bash
#
# scripts/check-links.py — intra-repo Markdown link & anchor integrity.
# Sourced by tests/run.sh after tests/lib.sh — NOT standalone (uses ROOT/TMP/ok/bad).

CL="$ROOT/scripts/check-links.py"

# --- Test CL1: the repo's own docs all resolve (exit 0) --------------------------
# This is also the live guard: a future broken README/docs link fails the suite.
rc=0; out="$(python3 "$CL" --root "$ROOT")" || rc=$?
if [ "$rc" = "0" ] && printf '%s' "$out" | grep -q 'markdown file(s) OK'; then
  ok "check-links.py passes on the repo's own markdown (every intra-repo link/anchor resolves)"
else
  bad "check-links.py reported broken links in the repo (rc=$rc): $out"
fi

# --- Test CL2: a broken file link and broken anchors are caught (exit 1) ----------
# A temp git tree (check-links enumerates via git ls-files) with one valid file link,
# valid cross-file + same-page anchors, and one of each broken. Expect exit 1 naming
# exactly the broken targets and none of the good ones.
LK="$TMP/check-links"; mkdir -p "$LK/sub"
git -C "$LK" init -q
printf '# Home\n\n[ok](sub/readme.md)\n[ok-anchor](sub/readme.md#a-section)\n[same](#home)\n[bad-file](sub/missing.md)\n[bad-anchor](sub/readme.md#nope)\n[bad-same](#ghost)\n' > "$LK/index.md"
printf '# Readme\n\n## A Section\n\ntext\n' > "$LK/sub/readme.md"
git -C "$LK" add -A
rc=0; out="$(python3 "$CL" --root "$LK")" || rc=$?
if [ "$rc" = "1" ] \
   && printf '%s' "$out" | grep -q 'sub/missing.md (file does not exist)' \
   && printf '%s' "$out" | grep -q 'sub/readme.md#nope (anchor not found' \
   && printf '%s' "$out" | grep -q '#ghost (no heading/anchor' \
   && ! printf '%s' "$out" | grep -q 'a-section' \
   && ! printf '%s' "$out" | grep -qE '\(#home\)'; then
  ok "check-links.py catches a missing file and bad same-page/cross-file anchors, exit 1"
else
  bad "check-links.py mis-graded the broken-link fixture (rc=$rc): $out"
fi

# --- Test CL3: inline-code link syntax and fenced blocks are not false positives --
# A `[..](X)` written as documentation (inside backticks) or inside a ``` fence must
# NOT be flagged — precise over clever, like the other engine scripts.
CLN="$TMP/check-links-clean"; mkdir -p "$CLN"
git -C "$CLN" init -q
# The backticks are literal fixture content (inline-code link syntax), not command
# substitution — that is exactly what check-links must ignore.
# shellcheck disable=SC2016
printf '# Doc\n\nThe link syntax is `[text](target)` — here `[..](X)` is prose.\n\n```\n[fenced](nope.md)\n```\n\n[real](other.md)\n' > "$CLN/index.md"
printf '# Other\n' > "$CLN/other.md"
git -C "$CLN" add -A
rc=0; out="$(python3 "$CL" --root "$CLN")" || rc=$?
if [ "$rc" = "0" ] && printf '%s' "$out" | grep -q 'markdown file(s) OK'; then
  ok "check-links.py ignores inline-code link syntax and fenced code blocks (no false positives)"
else
  bad "check-links.py false-flagged inline-code or fenced link syntax (rc=$rc): $out"
fi

# --- Test CL4: --quiet prints nothing but preserves the exit code -----------------
# Parity with doctor/lint-plan/lifecycle: --quiet is exit-code-only. Reuse the broken
# fixture from CL2 ($LK) — quiet must emit no stdout yet still exit 1.
rc=0; qout="$(python3 "$CL" --root "$LK" --quiet)" || rc=$?
if [ "$rc" = "1" ] && [ -z "$qout" ]; then
  ok "check-links.py --quiet emits nothing and still exits 1 on a broken tree"
else
  bad "check-links.py --quiet was not silent or lost its exit code (rc=$rc out='$qout')"
fi
