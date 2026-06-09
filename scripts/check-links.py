#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Eser KUBALI
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Deterministic intra-repo Markdown link checker. planwright's mission is grounded,
# verification-ready output; its own docs are a cross-linked product surface (the
# README's onboarding flow points at docs/*.md), so a link that 404s is a real defect
# that nothing else catches — a broken README -> docs/concepts.md link shipped exactly
# that way. This is the verification command that closes that gap.
#
# For every tracked *.md file it parses inline `[text](target)` links and checks each
# *intra-repo* target:
#   * a relative file target must exist (resolved against the linking file's directory);
#   * a `#anchor` (same-file or `path#anchor` into another .md) must match a heading on
#     the target page (GitHub heading-slug rules) or an explicit <a name/id> anchor.
# External links (http(s)://, mailto:, tel:, protocol-relative //) are left alone, and
# fenced code blocks are skipped so a ```...``` sample is never mistaken for a link.
#
# Precise over clever — like lint-plan.py / build-graph.py, it never raises a false
# failure: anything it cannot resolve confidently (a non-.md anchor target, a multi-line
# link, an unparseable heading) is skipped rather than flagged. It only reads the tree.
#
#   python3 scripts/check-links.py [--root DIR] [--quiet]
#
# Exit status: 0 when every intra-repo link/anchor resolves, 1 when any is broken (each
# printed as `file:line: broken link -> target (reason)`), 2 on a usage/enumeration error.
# --quiet suppresses all output and sets only the exit code (parity with the siblings).
import argparse
import json
import os
import re
import subprocess
import sys
import urllib.parse

LINK_RE = re.compile(r"\[[^\]]*\]\(([^)]+)\)")
HEADING_RE = re.compile(r"^\s{0,3}#{1,6}\s+(.*?)\s*#*\s*$")
# A setext heading is a line of text followed by a line of only `=` (H1) or `-` (H2),
# indented 0-3 spaces. We match the underline; the heading text is the preceding line.
SETEXT_RE = re.compile(r"^\s{0,3}(?:=+|-+)\s*$")
HTML_ANCHOR_RE = re.compile(r"""<a\s+[^>]*?(?:name|id)\s*=\s*["']([^"']+)["']""", re.IGNORECASE)
EXTERNAL_RE = re.compile(r"^(?:[a-zA-Z][a-zA-Z0-9+.-]*:|//)")


def list_markdown(root):
    """Tracked *.md files, repo-relative. Uses git so untracked scratch and ignored
    trees (.planwright/, node_modules) are never walked."""
    out = subprocess.check_output(["git", "-C", root, "ls-files", "*.md", "**/*.md"],
                                  text=True)
    seen, files = set(), []
    for line in out.splitlines():
        f = line.strip()
        if f and f not in seen:
            seen.add(f)
            files.append(f)
    return files


def slugify(heading):
    """GitHub-style heading slug: drop inline code/emphasis markers, lowercase, keep
    [a-z0-9 -], turn spaces into hyphens, collapse repeats, trim. Conservative — used
    only to CONFIRM an anchor resolves, so an over-strip can at worst skip a flag."""
    text = heading.replace("`", "")
    text = re.sub(r"[*_~]", "", text)
    # strip any leftover markdown link syntax in the heading, keeping the visible text
    text = re.sub(r"\[([^\]]*)\]\([^)]*\)", r"\1", text)
    text = text.lower()
    text = re.sub(r"[^a-z0-9 \-]", "", text)
    # GitHub replaces each space with a hyphen and does NOT collapse the runs that
    # punctuation removal leaves behind, so "Invocation & help" -> "invocation--help".
    # Do the same — collapsing would mismatch every such double-hyphen anchor.
    return text.strip().replace(" ", "-")


def anchors_of(path):
    """The set of valid in-page anchors for a markdown file: every heading slug plus any
    explicit <a name=/id=> anchor. Returns None if the file cannot be read."""
    try:
        with open(path, encoding="utf-8") as fh:
            lines = fh.read().splitlines()
    except OSError:
        return None
    slugs, counts, in_fence = set(), {}, False
    prev = None  # previous non-fenced line's text — a candidate setext heading

    def register(text):
        slug = slugify(text)
        if slug:
            # GitHub disambiguates a REPEATED heading by appending -1, -2, … in order
            # of occurrence: the 1st `slug`, the 2nd `slug-1`, the 3rd `slug-2`. Emit
            # exactly those anchors so a bogus `slug-999` on a single heading does not
            # resolve (the old `-\d+$` strip accepted any numeric suffix).
            n = counts.get(slug, 0)
            slugs.add(slug if n == 0 else "%s-%d" % (slug, n))
            counts[slug] = n + 1

    for raw in lines:
        s = raw.lstrip()
        if s.startswith("```") or s.startswith("~~~"):
            in_fence = not in_fence
            prev = None
            continue
        if in_fence:
            prev = None
            continue
        m = HEADING_RE.match(raw)
        if m:
            register(m.group(1))
            prev = None
            continue
        # A setext underline (a line of only `=` or `-`) turns the PRECEDING non-blank
        # line into a heading. This is purely additive — it only ever adds an anchor — so
        # it can never introduce a false "broken link"; it removes the false-fail on links
        # to setext headings, honouring this module's never-false-fail contract.
        if prev is not None and SETEXT_RE.match(raw):
            register(prev.strip())
            prev = None
            continue
        for am in HTML_ANCHOR_RE.finditer(raw):
            slugs.add(am.group(1).lower())
        prev = raw if raw.strip() else None
    return slugs


def anchor_ok(anchor, slugs):
    """True when `anchor` resolves against a page's anchor set. anchors_of already emits
    GitHub's real `-1/-2` disambiguation anchors, so this is a plain membership test."""
    return anchor.lower() in slugs


def clean_target(raw):
    """Normalize a raw link target: drop a <...> wrapper and a trailing "title"."""
    t = raw.strip()
    if t.startswith("<") and ">" in t:
        t = t[1:t.index(">")]
    else:
        t = t.split()[0] if t.split() else t
    return t.strip()


def check_file(root, relpath, anchor_cache):
    """Return a list of (lineno, target, reason) broken links in one markdown file."""
    full = os.path.join(root, relpath)
    base_dir = os.path.dirname(relpath)
    try:
        with open(full, encoding="utf-8") as fh:
            lines = fh.read().splitlines()
    except OSError as exc:
        return [(0, relpath, "unreadable (%s)" % exc)]

    def resolve_anchors(target_rel):
        if target_rel not in anchor_cache:
            anchor_cache[target_rel] = anchors_of(os.path.join(root, target_rel))
        return anchor_cache[target_rel]

    broken, in_fence, code_open = [], False, False
    for lineno, raw in enumerate(lines, 1):
        s = raw.lstrip()
        if s.startswith("```") or s.startswith("~~~"):
            in_fence = not in_fence
            continue
        if in_fence:
            continue
        # Blank inline-code spans before scanning so a `[..](X)` written as documentation
        # of the link syntax (not a real link) is never parsed as one. Line numbers are
        # unaffected (same-line substitution). A single-backtick span may cross line
        # boundaries (CommonMark), so carry the open state across lines: continue blanking
        # an open span up to its closing backtick, then detect a span this line opens but
        # does not close (an odd trailing backtick) and carry it to the next line.
        line = raw
        if code_open:
            idx = line.find("`")
            if idx == -1:
                continue  # the whole line is still inside the open code span
            line = " " * (idx + 1) + line[idx + 1:]
            code_open = False
        scan = re.sub(r"`[^`]*`", "", line)
        if scan.count("`") % 2 == 1:
            scan = scan[:scan.rfind("`")]
            code_open = True
        for m in LINK_RE.finditer(scan):
            target = clean_target(m.group(1))
            if not target or EXTERNAL_RE.match(target):
                continue
            path, _, anchor = target.partition("#")
            # Decode the anchor symmetrically with the path below: a percent-encoded
            # anchor (e.g. #my%20section linking an <a name="my section"> anchor) must
            # match the decoded name, not the literal '%20', or a valid link false-fails.
            anchor = urllib.parse.unquote(anchor)
            # A real file target may carry a `?query` (drop it) and percent-encoding
            # like `%20` (decode it) before it is matched against disk, or a valid link
            # such as `docs/core%20concepts.md` / `usage.md?v=1` false-fails as broken.
            path = urllib.parse.unquote(path.split("?", 1)[0])
            if path == "":
                # same-file anchor
                slugs = resolve_anchors(relpath)
                if slugs is not None and not anchor_ok(anchor, slugs):
                    broken.append((lineno, target, "no heading/anchor on this page"))
                continue
            # normalize the file target relative to the linking file's directory
            dest = os.path.normpath(os.path.join(base_dir, path)) if base_dir else os.path.normpath(path)
            # Containment: a relative target that escapes the repo root (e.g. ../outside.md)
            # is not an intra-repo link even if such a file exists on disk — flag it rather
            # than silently resolving against whatever lies outside the tree.
            full = os.path.realpath(os.path.join(root, dest))
            rootn = os.path.realpath(root)
            try:
                contained = full == rootn or os.path.commonpath([full, rootn]) == rootn
            except ValueError:
                contained = False  # different drive / uncomparable -> treat as escaping
            if not contained:
                broken.append((lineno, target, "escapes repo root"))
                continue
            if not os.path.exists(os.path.join(root, dest)):
                broken.append((lineno, target, "file does not exist"))
                continue
            if anchor and dest.lower().endswith(".md"):
                slugs = resolve_anchors(dest)
                if slugs is not None and not anchor_ok(anchor, slugs):
                    broken.append((lineno, target, "anchor not found in %s" % dest))
    return broken


def main():
    ap = argparse.ArgumentParser(description="Check intra-repo Markdown links and anchors.")
    ap.add_argument("--root", default=".", help="repo root to check (default: cwd)")
    ap.add_argument("--quiet", action="store_true",
                    help="print nothing; only set the exit code (parity with the sibling scripts)")
    ap.add_argument("--json", action="store_true",
                    help="emit the broken links as a JSON array of {file,line,target,reason} for CI "
                         "(parity with the sibling scripts); --quiet still suppresses all output")
    args = ap.parse_args()
    root = os.path.abspath(args.root)

    def emit(text):
        """Human report line — suppressed by --quiet and by --json (which prints once)."""
        if not args.quiet and not args.json:
            print(text)

    try:
        files = list_markdown(root)
    except (OSError, subprocess.SubprocessError) as exc:
        if not args.quiet:
            sys.stderr.write("check-links: could not enumerate markdown files (%s)\n" % exc)
        return 2

    anchor_cache, broken = {}, []
    for relpath in files:
        for lineno, target, reason in check_file(root, relpath, anchor_cache):
            broken.append({"file": relpath, "line": lineno, "target": target, "reason": reason})
            emit("%s:%d: broken link -> %s (%s)" % (relpath, lineno, target, reason))
    if not args.quiet and args.json:
        print(json.dumps(broken))
    if broken:
        emit("check-links: %d broken link(s) across %d file(s)" % (len(broken), len(files)))
        return 1
    emit("check-links: %d markdown file(s) OK" % len(files))
    return 0


if __name__ == "__main__":
    sys.exit(main())
