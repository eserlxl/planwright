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

# --- Test CL5: link titles and angle-bracket targets resolve; broken titled link caught
# clean_target() strips a trailing "title" and a <...> wrapper. Pin both branches: a
# titled link and an angle-bracket link to an existing file must pass, while a titled
# link to a missing file must still be flagged (with the title stripped from the report).
TT="$TMP/check-links-title"; mkdir -p "$TT"
git -C "$TT" init -q
printf '# Home\n\n[a](other.md "a title")\n[b](<other.md>)\n' > "$TT/good.md"
printf '# Other\n' > "$TT/other.md"
git -C "$TT" add -A
rc=0; out="$(python3 "$CL" --root "$TT")" || rc=$?
if [ "$rc" = "0" ] && printf '%s' "$out" | grep -q 'markdown file(s) OK'; then
  ok "check-links.py resolves a titled link and an angle-bracket target"
else
  bad "check-links.py mis-parsed a titled or angle-bracket link (rc=$rc): $out"
fi
printf '[c](missing.md "t")\n' >> "$TT/good.md"
git -C "$TT" add -A
rc=0; out="$(python3 "$CL" --root "$TT")" || rc=$?
if [ "$rc" = "1" ] && printf '%s' "$out" | grep -q 'missing.md (file does not exist)'; then
  ok "check-links.py flags a broken titled link with the title stripped from the report"
else
  bad "check-links.py did not flag a broken titled link (rc=$rc): $out"
fi

# --- Test CL6: bogus numeric-suffix anchors are caught; real duplicate suffixes pass
# GitHub only mints `-N` anchors for REPEATED headings. A `#heading-2` link where
# `# Heading` appears once must be flagged; where it appears 3x, `#heading-1` resolves.
NS="$TMP/cl-numsuffix"; mkdir -p "$NS"; git -C "$NS" init -q
printf '# Heading\n\n[bogus](#heading-2)\n' > "$NS/single.md"
git -C "$NS" add -A
ns_rc=0
ns_out="$(python3 "$CL" --root "$NS" 2>&1)" || ns_rc=$?
# check a real-duplicate fixture in isolation so the single.md break does not mask it
DUP="$TMP/cl-dup"; mkdir -p "$DUP"; git -C "$DUP" init -q
printf '# Dup\n\n# Dup\n\n# Dup\n\n[real](#dup-1)\n[real2](#dup-2)\n' > "$DUP/dup.md"
git -C "$DUP" add -A
dup_rc=0
python3 "$CL" --root "$DUP" >/dev/null 2>&1 || dup_rc=$?
if [ "$ns_rc" = "1" ] && printf '%s' "$ns_out" | grep -q '#heading-2' && [ "$dup_rc" = "0" ]; then
  ok "check-links.py flags a bogus -N anchor on a single heading but accepts real duplicate suffixes"
else
  bad "check-links.py numeric-suffix anchor handling wrong (single_rc=$ns_rc dup_rc=$dup_rc)"
fi

# --- Test CL7: link targets are URL-decoded and query-stripped before the disk check
# A valid link with a %20-encoded space or a ?query suffix must resolve to the real
# file, not false-fail as broken.
NM="$TMP/cl-normalize"; mkdir -p "$NM"; git -C "$NM" init -q
printf '# Concepts\n' > "$NM/core concepts.md"
printf '# Home\n\n[spaced](core%%20concepts.md)\n[queried](index.md?v=1)\n' > "$NM/index.md"
git -C "$NM" add -A
nm_rc=0
nm_out="$(python3 "$CL" --root "$NM" 2>&1)" || nm_rc=$?
if [ "$nm_rc" = "0" ]; then
  ok "check-links.py URL-decodes %20 and strips ?query before the existence check"
else
  bad "check-links.py false-failed a %20 / ?query link (rc=$nm_rc): $nm_out"
fi

# --- Test CL8: a link inside a multi-line inline code span is not a real link ------
# A single-backtick span may cross lines; a [text](target) inside it must not be parsed
# as a link. Per-line blanking missed this and false-flagged the inner target.
ML="$TMP/cl-multiline"; mkdir -p "$ML"; git -C "$ML" init -q
# shellcheck disable=SC2016
printf '# Doc\n\nHere is `a code span that opens\nand contains [fake](nope.md) inside it\nand closes` afterwards.\n' > "$ML/index.md"
git -C "$ML" add -A
ml_rc=0
ml_out="$(python3 "$CL" --root "$ML" 2>&1)" || ml_rc=$?
if [ "$ml_rc" = "0" ]; then
  ok "check-links.py does not treat a link inside a multi-line inline code span as real"
else
  bad "check-links.py false-flagged a link inside a multi-line code span (rc=$ml_rc): $ml_out"
fi

# --- Test CL9: --json emits a structured broken-link array and preserves the exit code
# Parity with status/doctor/lint-plan --json: a CI consumer parses file/line/target/reason
# instead of scraping the text format. Reuse the broken fixture from CL2 ($LK): --json must
# emit a JSON array carrying the broken targets and still exit 1; on a clean tree it emits
# `[]` and exits 0.
jrc=0; jout="$(python3 "$CL" --root "$LK" --json)" || jrc=$?
if [ "$jrc" = "1" ] \
   && printf '%s' "$jout" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert isinstance(d,list) and any(e["target"]=="sub/missing.md" and "file" in e and "line" in e and "reason" in e for e in d)' 2>/dev/null; then
  ok "check-links.py --json emits a parseable broken-link array and exits 1 on a broken tree"
else
  bad "check-links.py --json wrong on a broken tree (rc=$jrc out='$jout')"
fi
crc=0; cout="$(python3 "$CL" --root "$CLN" --json)" || crc=$?
if [ "$crc" = "0" ] && [ "$cout" = "[]" ]; then
  ok "check-links.py --json emits [] and exits 0 on a clean tree"
else
  bad "check-links.py --json wrong on a clean tree (rc=$crc out='$cout')"
fi

# --- Test CL10: a relative link that escapes the repo root is rejected -------------
# A ../outside.md link to a real file ABOVE the repo root is not an intra-repo link
# even though it exists on disk; flag it rather than silently resolving outside the tree.
ESC="$TMP/cl-escape"; mkdir -p "$ESC/repo"; git -C "$ESC/repo" init -q
printf '# outside the repo\n' > "$ESC/outside.md"
printf '# Home\n\n[escape](../outside.md)\n' > "$ESC/repo/index.md"
git -C "$ESC/repo" add -A
esc_rc=0
esc_out="$(python3 "$CL" --root "$ESC/repo" 2>&1)" || esc_rc=$?
if [ "$esc_rc" = "1" ] && printf '%s' "$esc_out" | grep -q 'escapes repo root'; then
  ok "check-links.py rejects a relative link that escapes the repo root"
else
  bad "check-links.py accepted a link escaping the repo root (rc=$esc_rc): $esc_out"
fi

# --- Test CL11: a percent-encoded anchor is decoded before the membership test -----
# A link to an explicit <a name="..."> anchor written percent-encoded (#my%20section)
# must resolve to the decoded name, not false-fail; a genuinely missing one still flags
# (so the decode does not over-match).
AE="$TMP/cl-anchor-encoded"; mkdir -p "$AE"; git -C "$AE" init -q
printf '# Home\n\n<a name="my section"></a>\n\n[enc](#my%%20section)\n[bad](#no%%20such)\n' > "$AE/index.md"
git -C "$AE" add -A
ae_rc=0
ae_out="$(python3 "$CL" --root "$AE" 2>&1)" || ae_rc=$?
if [ "$ae_rc" = "1" ] \
   && printf '%s' "$ae_out" | grep -q '#no%20such' \
   && ! printf '%s' "$ae_out" | grep -q '#my%20section'; then
  ok "check-links.py decodes a percent-encoded anchor before matching (resolves a valid one, still flags a missing one)"
else
  bad "check-links.py mis-handled a percent-encoded anchor (rc=$ae_rc): $ae_out"
fi
