#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Eser KUBALI
# SPDX-License-Identifier: GPL-3.0-or-later
#
# scripts/lint-final.py — validate a recorded final point (.planwright/final.md) against
# the SKILL.md "Stage 11 / Maintain final.md" contract, so a malformed or typo'd final
# point is not silently trusted as a converged terminal state. status.py reads final.md
# leniently (sha/date/deepest_tier each default to "") and _converged() / --exit-code will
# report `converged: true` for a blank or corrupt marker whose sha happens to match HEAD;
# the escalation-reach short-circuit branches on the exact `deepest_tier` token, so a typo
# (`exapnd`) would mis-route silently. This validator catches those before they mislead.
#
# A final.md must record (one `key: value` line each, matching status.py's parser):
#   - a non-empty `sha:` (the HEAD the ladder was exhausted at);
#   - all four maturity rungs — `repair:` / `coverage:` / `opportunity:` / `vision:` — each
#     present with a non-empty one-line dry reason;
#   - when present, a `deepest_tier:` in exactly {hot-core, cold-frontier, expand, invent};
#   - paired fields co-occur: `scope:` needs `scope_focus_sha:`, `invent_seed:` needs
#     `invent_framing:` — except the whole-repo sentinel `scope: (whole-repo)`, which the
#     contract blesses with no Focus list and so needs no `scope_focus_sha:`.
# An ABSENT final.md is valid — no final point is a legitimate state (matching lint-plan's
# empty-plan posture) — and exits 0. Read-only: it never mutates anything.
#
#   python3 scripts/lint-final.py --root .
#   python3 scripts/lint-final.py --root . --json
#
# Exit 0 when final.md is absent or valid; 1 when it is present and violates the contract.

import argparse
import json
import os
import re
import sys

RUNGS = ("repair", "coverage", "opportunity", "vision")
DEEPEST_TIERS = frozenset({"hot-core", "cold-frontier", "expand", "invent"})
# A field that, when present, requires its partner to also be present and non-empty.
PAIRED = (("scope", "scope_focus_sha"), ("invent_seed", "invent_framing"))


def _field(lines, key):
    """The value of the LAST `key:`-prefixed line, as a stripped string ('' when present
    but blank), or None when the key is absent entirely. Last-wins matches
    status._parse_final (which overwrites on every match), so the validator and the
    consumer agree on which bytes a duplicated key resolves to."""
    prefix = key + ":"
    found = None
    for line in lines:
        if line.startswith(prefix):
            found = line[len(prefix):].strip()
    return found


def collect(root: str) -> dict:
    """Validate <root>/.planwright/final.md. Returns
    {present, ok, violations, path} — `present` False (and ok True) when there is no
    final point, which is a valid state."""
    path = os.path.join(root, ".planwright", "final.md")
    try:
        with open(path, encoding="utf-8") as fh:
            text = fh.read()
    except FileNotFoundError:
        # Genuinely no recorded final point — a valid open-ladder state.
        return {"present": False, "ok": True, "violations": [], "path": path}
    except (OSError, ValueError) as exc:
        # The file EXISTS but cannot be read/decoded (non-UTF-8, permissions). Degrading to
        # the absent/valid state would be a fail-open the convergence gate must not hide: a
        # present-but-unreadable marker is a corrupt environment, not a clean 'no final point'.
        # Fail closed — report present + not-ok so status --exit-code refuses — while still not
        # crashing the read-only status path.
        print("planwright lint-final: %s exists but could not be read (%s: %s); "
              "treating as a corrupt final point (gate fails closed)"
              % (path, type(exc).__name__, exc), file=sys.stderr)
        return {"present": True, "ok": False,
                "violations": ["final.md exists but could not be read (%s: %s) — corrupt environment"
                               % (type(exc).__name__, exc)],
                "path": path}

    lines = text.splitlines()
    viols = []

    # `HEAD:` is tolerated as an alias for `sha:` (status._parse_final mirrors this): SKILL.md
    # Stage 11 calls the recorded value "the HEAD sha", so a natural-variant marker that spells
    # it `HEAD:` must not read as unanchored. An explicit `sha:` wins; either, present and
    # non-empty, satisfies the contract.
    if not (_field(lines, "sha") or _field(lines, "HEAD")):
        viols.append("missing or empty `sha:` line — a final point must record its HEAD sha")

    for rung in RUNGS:
        if not _field(lines, rung):
            viols.append("rung '%s' is not recorded with a one-line dry reason "
                         "(expected a non-empty `%s:` line)" % (rung, rung))

    tier = _field(lines, "deepest_tier")
    if tier and tier not in DEEPEST_TIERS:
        viols.append("deepest_tier '%s' is not one of {%s}"
                     % (tier, ", ".join(sorted(DEEPEST_TIERS))))

    if tier == "invent":
        # The strongest convergence claim must be EARNED, not asserted: SKILL.md
        # Stage 11 makes both audits unconditional on a `deepest_tier: invent` —
        # the framing rotation that was exhausted (earned by breadth) and the
        # per-seam justification (earned by rigor).
        if not _field(lines, "invent_framings_tried"):
            viols.append("deepest_tier 'invent' requires a non-empty `invent_framings_tried:` "
                         "line (the earned-by-breadth audit: the framing rotation exhausted)")
        seams = _field(lines, "invent_seams_examined")
        if not seams:
            # An empty inline value is still valid when the per-seam audit follows as
            # an indented `- ` block (the multi-line shape SKILL.md Stage 11 records).
            # Scan only the indented continuation directly under the key — the first
            # non-indented line ends the block.
            idx = [i for i, ln in enumerate(lines)
                   if ln.startswith("invent_seams_examined:")]
            has_block = False
            if idx:
                for ln in lines[idx[-1] + 1:]:
                    if not ln.strip():
                        continue
                    if not ln.startswith((" ", "\t")):
                        break
                    if ln.strip().startswith("- "):
                        has_block = True
                        break
            if not has_block:
                viols.append("deepest_tier 'invent' requires `invent_seams_examined:` with a "
                             "per-seam reason (inline or an indented `- ` block — the "
                             "earned-by-rigor audit)")

    # Fixpoint-strength fields (additive, backward-compatible — SKILL.md Stage 11 documents both as
    # optional). Validate ONLY when present; absence is always valid — a pre-fixpoint final.md parses
    # exactly as before, so the validator must NOT require `fixpoint:`/`budget:` even alongside a
    # `deepest_tier:` (that would break the additive/backward-compatible contract and reject every
    # final.md written before these fields existed).
    fixpoint = _field(lines, "fixpoint")
    if fixpoint is not None and not fixpoint:
        viols.append("`fixpoint:` is present but empty — record a one-line reason every reachable "
                     "tier was dry, or omit the field")
    budget = _field(lines, "budget")
    if budget is not None:
        # `budget: { requested: N, used: i }` — requested/used must be integers, and a FINITE
        # (non-negative) requested budget must be >= used. An unlimited run records `requested: -1`
        # (negative), for which `used` has no upper bound.
        m_req = re.search(r"requested:\s*(-?\d+)", budget)
        m_used = re.search(r"used:\s*(-?\d+)", budget)
        if not (m_req and m_used):
            viols.append("`budget:` must read `{ requested: N, used: i }` with integer N and i")
        else:
            requested, used = int(m_req.group(1)), int(m_used.group(1))
            if requested >= 0 and used > requested:
                viols.append("`budget:` used (%d) exceeds the finite requested budget (%d)"
                             % (used, requested))

    for a, b in PAIRED:
        av, bv = _field(lines, a), _field(lines, b)
        # The contract (SKILL.md Stage 11) blesses `scope: (whole-repo)` as a whole-repo
        # sentinel — it has no Focus list, so it needs no scope_focus_sha. Treat that one
        # value as scope-absent for pairing; a real `path:`/`lib:` scope still requires its
        # focus sha, and a scope_focus_sha with no real scope still fails.
        whole_repo_scope = False
        if a == "scope" and av is not None and av.strip().lower() == "(whole-repo)":
            av = None
            whole_repo_scope = True
        # A whole-repo sentinel needs no focus sha, so a scope_focus_sha alongside it is
        # the spurious field — name IT, not `scope:` (which is present and correct), or the
        # generic branch below would misdirect the maintainer to the one good line. This
        # covers both a non-empty value AND a present-but-blank `scope_focus_sha:` (`bv == ''`),
        # which would otherwise fall through to the generic pairing check and report the
        # present, correct `scope:` sentinel as "missing or empty". An entirely absent
        # scope_focus_sha (`bv is None`) is fine — the sentinel needs none — so skip the
        # generic check unconditionally here.
        if whole_repo_scope:
            if bv:
                viols.append("`%s:` must not accompany the whole-repo sentinel "
                             "`scope: (whole-repo)`" % b)
            elif bv is not None:
                viols.append("`%s:` is present but empty alongside the whole-repo sentinel "
                             "`scope: (whole-repo)` — the sentinel needs no focus sha; remove it"
                             % b)
            continue
        # Symmetric: if either member appears at all, BOTH must be present and non-empty —
        # a half-recorded pair in EITHER direction is an unanchored/un-replayable point.
        if (av is not None or bv is not None) and not (av and bv):
            missing = a if not av else b
            viols.append("paired fields `%s:` and `%s:` must co-occur — `%s:` is missing or empty"
                         % (a, b, missing))

    return {"present": True, "ok": not viols, "violations": viols, "path": path}


def report(state, quiet):
    """Print the human-readable result. Read-only; returns None."""
    if quiet:
        return
    if not state["present"]:
        print("lint-final: no final.md recorded (the ladder is open) — ok")
        return
    if state["ok"]:
        print("lint-final: final.md OK")
        return
    print("lint-final: %d violation(s) in %s" % (len(state["violations"]), state["path"]))
    for v in state["violations"]:
        print("  - " + v)


def main():
    ap = argparse.ArgumentParser(
        description="Validate a recorded final point (.planwright/final.md). Read-only.")
    ap.add_argument("--root", default=".",
                    help="the target repo to inspect (default: the current directory)")
    ap.add_argument("--json", action="store_true",
                    help="emit the validation result as a machine-readable object")
    ap.add_argument("--quiet", action="store_true",
                    help="suppress the report (exit code only)")
    args = ap.parse_args()
    state = collect(args.root)
    if args.json:
        print(json.dumps(state, indent=2))
    else:
        report(state, args.quiet)
    return 0 if state["ok"] else 1


if __name__ == "__main__":
    sys.exit(main())
