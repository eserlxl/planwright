#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Eser KUBALI
# SPDX-License-Identifier: GPL-3.0-or-later
"""Reduce NODE_V8_COVERAGE output to one deterministic JS coverage percentage over
scripts/dashboard/ (excluding vendor/).

Node's built-in V8 coverage (set NODE_V8_COVERAGE=<dir> when invoking `node`) writes one
or more coverage-*.json files, each holding `result[]` entries keyed by a script `url`
(file:///… when the script was given an absolute vm filename — see
tests/cases/lib/dashboard-vm.js loadScript). Each script carries `functions[].ranges[]`
of {startOffset, endOffset, count}; ranges nest (outer function range, inner block ranges),
and the innermost range covering a byte gives its hit count. This script reduces that to a
single byte-coverage percentage so CI can gate it like the Python `coverage --fail-under`.

No third-party / paid service: Python standard library only. Deterministic — the same V8
output always yields the same number.

Usage:
  python3 scripts/js-coverage-report.py <NODE_V8_COVERAGE_dir> [--root <repo>]
                                        [--include <substr>] [--fail-under <pct>] [--json]
Exit codes: 0 normally; 2 when --fail-under is given and the coverage is below it; 1 on a
usage/IO error (no coverage files, unreadable dir).
"""
import argparse
import glob
import json
import os
import sys
from urllib.parse import unquote, urlparse


def _script_path(url):
    """Map a V8 script url (file:///… or a bare path) to an absolute filesystem path, or None."""
    if not url:
        return None
    if url.startswith("file://"):
        return unquote(urlparse(url).path)
    if url.startswith("/"):
        return url
    return None


def compute(cov_dir, root, include):
    """Return (covered, total, per_file) aggregated across every coverage file for the
    scripts matching `include` under `root`. A byte is covered if covered in ANY run."""
    files = sorted(glob.glob(os.path.join(cov_dir, "*.json")))
    if not files:
        raise FileNotFoundError("no coverage-*.json files in %s" % cov_dir)
    root_abs = os.path.realpath(root)
    # path -> {"len": int, "covered": set(byte offsets)}
    acc = {}
    for fpath in files:
        try:
            with open(fpath, encoding="utf-8") as fh:
                data = json.load(fh)
        except (OSError, ValueError):
            continue
        for script in data.get("result", []):
            path = _script_path(script.get("url"))
            if not path:
                continue
            path = os.path.realpath(path)
            # Restrict to scripts/dashboard/ under the repo root, excluding vendor/.
            try:
                rel = os.path.relpath(path, root_abs)
            except ValueError:
                continue
            rel = rel.replace(os.sep, "/")
            if include not in rel or "/vendor/" in rel or not os.path.exists(path):
                continue
            try:
                with open(path, "rb") as fh:
                    length = len(fh.read())
            except OSError:
                continue
            ranges = []
            for fn in script.get("functions", []):
                for r in fn.get("ranges", []):
                    ranges.append((r.get("startOffset", 0), r.get("endOffset", 0), r.get("count", 0)))
            # V8 ranges form a forest (proper nesting, no partial overlap). Paint outer ranges
            # first (start asc, then widest end first) so nested inner ranges overwrite them;
            # the innermost range covering a byte gives its hit count.
            counts = [0] * length
            for start, end, count in sorted(ranges, key=lambda r: (r[0], -r[1])):
                for i in range(max(0, start), min(length, end)):
                    counts[i] = count
            covered = {i for i, c in enumerate(counts) if c > 0}
            entry = acc.setdefault(rel, {"len": length, "covered": set()})
            entry["len"] = max(entry["len"], length)
            entry["covered"] |= covered
    total = sum(e["len"] for e in acc.values())
    covered = sum(len(e["covered"]) for e in acc.values())
    per_file = {k: (len(v["covered"]), v["len"]) for k, v in sorted(acc.items())}
    return covered, total, per_file


def main(argv=None):
    ap = argparse.ArgumentParser(description="Reduce NODE_V8_COVERAGE output to one JS coverage %.")
    ap.add_argument("cov_dir", help="directory of NODE_V8_COVERAGE coverage-*.json files")
    ap.add_argument("--root", default=".", help="repo root (default: .)")
    ap.add_argument("--include", default="scripts/dashboard/", help="path substring to measure")
    ap.add_argument("--fail-under", type=float, default=None,
                    help="exit non-zero (2) when the coverage percentage is below this")
    ap.add_argument("--json", action="store_true", help="emit a JSON object instead of a line")
    args = ap.parse_args(argv)
    try:
        covered, total, per_file = compute(args.cov_dir, args.root, args.include)
    except FileNotFoundError as exc:
        print("js-coverage-report: %s" % exc, file=sys.stderr)
        return 1
    pct = (100.0 * covered / total) if total else 0.0
    pct_r = round(pct, 1)
    if args.json:
        print(json.dumps({"include": args.include, "covered": covered, "total": total,
                          "pct": pct_r, "files": per_file}, sort_keys=True))
    else:
        print("JS coverage (%s): %.1f%% (%d/%d bytes, %d files)"
              % (args.include.rstrip("/"), pct_r, covered, total, len(per_file)))
    if args.fail_under is not None and pct_r < args.fail_under:
        print("js-coverage-report: %.1f%% is below the floor of %.1f%%" % (pct_r, args.fail_under),
              file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
