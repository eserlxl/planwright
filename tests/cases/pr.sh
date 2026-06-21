# SPDX-FileCopyrightText: 2026 Eser KUBALI
# SPDX-License-Identifier: GPL-3.0-or-later
# shellcheck shell=bash
#
# scripts/pr.py — the `pr` subcommand's mechanical half (PR ingest + local handoff),
# plus the SKILL.md / references/pr.md wiring and the security invariants the feature
# rests on. Sourced by tests/run.sh after tests/lib.sh — NOT standalone (uses ROOT/TMP/ok/bad).
#
# planwright stays read-only toward GitHub: these tests never call the network. The gh
# orchestration is exercised only through its clean-degrade path; the pure parsers,
# handoff, and gates are covered with fixtures.

PRPY="$ROOT/scripts/pr.py"
PYBIN="$(command -v python3)"

# --- Test PR1: parse_review_threads keeps only unresolved, in-range, pathed threads ----
if python3 - "$ROOT/scripts" <<'PY'
import sys; sys.path.insert(0, sys.argv[1]); import pr
data = {"data": {"repository": {"pullRequest": {"reviewThreads": {"nodes": [
    {"id": "T1", "isResolved": False, "isOutdated": False, "path": "a/b.py", "line": 12,
     "startLine": 10, "comments": {"nodes": [{"body": "bug here", "author": {"login": "alice"}}]}},
    {"id": "T2", "isResolved": True, "isOutdated": False, "path": "a/c.py", "line": 5,
     "comments": {"nodes": [{"body": "done", "author": {"login": "bot"}}]}},   # resolved -> dropped
    {"id": "T3", "isResolved": False, "isOutdated": True, "path": "a/d.py", "line": 7,
     "comments": {"nodes": []}},                                               # outdated -> dropped
    {"id": "T4", "isResolved": False, "isOutdated": False, "path": None,        # no path -> dropped
     "line": 1, "comments": {"nodes": []}},
]}}}}}
leads = pr.parse_review_threads(data)
assert [l["id"] for l in leads] == ["T1"], leads
l = leads[0]
assert l["path"] == "a/b.py" and l["line"] == 12 and l["author"] == "alice" and l["body"] == "bug here", l
# falls back to startLine, and survives garbage input without raising
assert pr.parse_review_threads({}) == [] and pr.parse_review_threads({"data": None}) == []
PY
then ok "pr.parse_review_threads keeps only unresolved/in-range/pathed threads (author+body extracted)"; else bad "pr.parse_review_threads filtering/extraction wrong"; fi

# --- Test PR2: parse_failing_log extracts the first repo-relative file:line, skips absolute --
if python3 - "$ROOT/scripts" <<'PY'
import sys; sys.path.insert(0, sys.argv[1]); import pr
r = pr.parse_failing_log("Running tests\nsrc/app/widget.py:88: AssertionError: boom\n", "unit")
assert r["kind"] == "check" and r["name"] == "unit", r
assert r["path"] == "src/app/widget.py" and r["line"] == 88 and "AssertionError" in r["excerpt"], r
# python-traceback frame form
r2 = pr.parse_failing_log('  File "pkg/mod.py", line 42, in f', "py")
assert r2["path"] == "pkg/mod.py" and r2["line"] == 42, r2
# no anchor, and an absolute/system path is NOT a repo-relative seed
assert pr.parse_failing_log("just words, no anchor", "x")["path"] is None
assert pr.parse_failing_log("/usr/lib/py/x.py:3: nope", "x")["path"] is None
assert pr.parse_failing_log("../escape.py:9: nope", "x")["path"] is None
PY
then ok "pr.parse_failing_log extracts the first repo-relative file:line and skips absolute/traversal anchors"; else bad "pr.parse_failing_log anchor extraction wrong"; fi

# --- Test PR3: pr_provenance + eligible_handoff_items (tag AND Commit required) -----------
if python3 - "$ROOT/scripts" <<'PY'
import sys; sys.path.insert(0, sys.argv[1]); import pr
assert pr.pr_provenance("x (pr-thread TH_1)") == ("pr-thread", "TH_1")
assert pr.pr_provenance("y (pr-check unit-tests)") == ("pr-check", "unit-tests")
assert pr.pr_provenance("no tag here") is None
items = [
    {"title": "Fix (pr-thread TH_1)", "fields": {"Commit": "abc1234"}},   # eligible
    {"title": "CI (pr-check unit)",   "fields": {"Commit": "def5678"}},   # eligible
    {"title": "Untagged",             "fields": {"Commit": "999aaaa"}},   # no tag -> out
    {"title": "Tagged (pr-thread TH_9)", "fields": {}},                   # no commit -> out
]
elig = pr.eligible_handoff_items(items)
assert [e["id"] for e in elig] == ["TH_1", "unit"], elig
assert [e["commit"] for e in elig] == ["abc1234", "def5678"], elig
PY
then ok "pr.eligible_handoff_items selects only items with BOTH a PR provenance tag and a Commit stamp"; else bad "pr.eligible_handoff_items selection wrong"; fi

# --- Test PR4: positive_pr_number neutralizes a non-integer / option-smuggling --pr -------
if python3 - "$ROOT/scripts" <<'PY'
import sys, argparse; sys.path.insert(0, sys.argv[1]); import pr
assert pr.positive_pr_number("42") == 42
for bad in ["-1", "0", "abc", "--repo=x", "3; rm -rf /", "", None]:
    try:
        pr.positive_pr_number(bad)
    except argparse.ArgumentTypeError:
        continue
    raise SystemExit("accepted bad PR ref: %r" % (bad,))
PY
then ok "pr.positive_pr_number accepts a positive int and rejects non-int / option-smuggling refs"; else bad "pr.positive_pr_number guard wrong (PR-ref injection surface)"; fi

# --- Test PR5: `pr leads` degrades cleanly when gh is unavailable (no network, no writes) --
# Run with a PATH that resolves no `gh` (use the absolute python so the runtime still works,
# exactly like doctor's DR4). resolve fails -> prints `[]`, exit 0, a one-line note, and it
# writes NOTHING (no .planwright/ created) because it returns before any mkdir.
LR="$TMP/pr-degrade"; mkdir -p "$LR"
lr_rc=0
lr_out="$(PATH=/nonexistent-pr-test "$PYBIN" "$PRPY" leads --root "$LR" 2>"$TMP/pr-degrade.err")" || lr_rc=$?
if [ "$lr_rc" = 0 ] && [ "$lr_out" = "[]" ] \
   && grep -q 'skipping cleanly' "$TMP/pr-degrade.err" \
   && [ ! -e "$LR/.planwright" ]; then
  ok "pr leads degrades to [] (exit 0, clean note, no writes) when gh is unavailable"
else
  bad "pr leads did not degrade cleanly without gh (rc=$lr_rc out='$lr_out')"
fi

# --- Test PR6: `pr handoff` builds the local recipe for verified PR fixes only ------------
HR="$TMP/pr-handoff"; mkdir -p "$HR/.planwright"
cat > "$HR/.planwright/completed.md" <<'EOF'
# completed

- [x] Fix null deref (pr-thread TH_123)
      Mode: repair
      Commit: abc1234
- [x] Make CI green (pr-check unit-tests)
      Mode: repair
      Commit: def5678
- [x] Unrelated cleanup
      Mode: improve
      Commit: 999aaaa
- [x] Tagged but not yet committed (pr-thread TH_999)
      Mode: repair
EOF
ho_out="$(python3 "$PRPY" handoff --root "$HR")"
if printf '%s' "$ho_out" | grep -q '^git push' \
   && printf '%s' "$ho_out" | grep -q 'resolveReviewThread' \
   && printf '%s' "$ho_out" | grep -q 'TH_123' \
   && printf '%s' "$ho_out" | grep -q 'abc1234' \
   && printf '%s' "$ho_out" | grep -q 'def5678' \
   && printf '%s' "$ho_out" | grep -q 'gh pr merge' \
   && printf '%s' "$ho_out" | grep -qi 'merging' \
   && ! printf '%s' "$ho_out" | grep -q '999aaaa' \
   && ! printf '%s' "$ho_out" | grep -q 'TH_999'; then
  ok "pr handoff recipe pushes + resolves + merges for tagged-AND-committed items only (skips untagged/uncommitted)"
else
  bad "pr handoff recipe wrong (included an ineligible item or dropped an eligible one)"
fi

# empty / absent completed.md -> the explicit no-op message, never a half recipe
HE="$TMP/pr-handoff-empty"; mkdir -p "$HE/.planwright"; : > "$HE/.planwright/completed.md"
HN="$TMP/pr-handoff-none"; mkdir -p "$HN"
if python3 "$PRPY" handoff --root "$HE" | grep -q 'No verified' \
   && python3 "$PRPY" handoff --root "$HN" | grep -q 'No verified'; then
  ok "pr handoff prints the no-op message when no verified PR fixes are recorded (empty or absent completed.md)"
else
  bad "pr handoff did not handle an empty/absent completed.md cleanly"
fi

# checks-only (eligible pr-check fixes but NO review threads) -> push + merge recipe,
# but the optional resolve-thread section must be omitted (the `if threads:` false branch).
HC="$TMP/pr-handoff-checks-only"; mkdir -p "$HC/.planwright"
cat > "$HC/.planwright/completed.md" <<'EOF'
# completed

- [x] Make CI green (pr-check unit-tests)
      Mode: repair
      Commit: cafe123
EOF
hc_out="$(python3 "$PRPY" handoff --root "$HC")"
if printf '%s' "$hc_out" | grep -q '^git push' \
   && printf '%s' "$hc_out" | grep -q 'gh pr merge' \
   && printf '%s' "$hc_out" | grep -q 'cafe123' \
   && ! printf '%s' "$hc_out" | grep -q 'resolveReviewThread'; then
  ok "pr handoff omits the review-thread resolve section when only failing-check fixes are eligible (checks-only branch)"
else
  bad "pr handoff checks-only branch wrong (emitted a resolve-thread section without threads, or dropped push/merge)"
fi

# --- Test PR7: extract_run_id pulls a workflow run id from a check link -------------------
if python3 - "$ROOT/scripts" <<'PY'
import sys; sys.path.insert(0, sys.argv[1]); import pr
assert pr.extract_run_id("https://github.com/o/r/actions/runs/12345/job/9") == "12345"
assert pr.extract_run_id("https://example/none") is None
assert pr.extract_run_id("") is None and pr.extract_run_id(None) is None
PY
then ok "pr.extract_run_id resolves a workflow run id from a check link (None when absent)"; else bad "pr.extract_run_id wrong"; fi

# --- Test PR8: pr is wired via progressive disclosure (mirrors doctor DR6) ----------------
# Contract: pr reachable — Usage line + dispatch pointer in SKILL.md to references/pr.md,
# whose procedure wires the bundled <scripts>/pr.py; and the pr handoff sub-form is exposed.
if python3 - "$ROOT/skills/planwright/SKILL.md" "$ROOT/skills/planwright/references/pr.md" <<'PY' 2>/dev/null
import sys
skill = open(sys.argv[1], encoding="utf-8").read()
ref = open(sys.argv[2], encoding="utf-8").read()
need = []
if "/planwright pr" not in skill: need.append("usage-line")
if "pr handoff" not in skill: need.append("handoff-usage")
if "references/pr.md" not in skill: need.append("dispatch-pointer")
if "<scripts>/pr.py" not in ref: need.append("script-wire")
sys.exit(1 if need else 0)
PY
then ok "pr exposed: SKILL.md usage + dispatch pointer, references/pr.md wires <scripts>/pr.py"; else bad "pr command wiring missing across SKILL.md / references/pr.md"; fi

# --- Test PR9: references/pr.md pins the load-bearing trust invariants ---------------------
# These phrases are the contract the whole feature rests on; an edit that drops one must fail.
if python3 - "$ROOT/skills/planwright/references/pr.md" <<'PY' 2>/dev/null
import sys
t = open(sys.argv[1], encoding="utf-8").read()
need = []
if "routing only" not in t or "never Evidence" not in t: need.append("routing-only-never-evidence")
if "never writes to GitHub" not in t: need.append("never-writes-github")
if "never required" not in t: need.append("gh-optional")
if "by hand" not in t: need.append("operator-manual-pushback")
if ".github/workflows" not in t: need.append("workflows-extra-scrutiny")
if "re-ground" not in t: need.append("reground-anchors")
sys.exit(1 if need else 0)
PY
then ok "references/pr.md pins routing-only/never-Evidence, never-writes-GitHub, gh-optional, operator-manual push-back, workflows scrutiny, anchor re-grounding"; else bad "references/pr.md dropped a load-bearing trust invariant"; fi

# --- Test PR10: the routing gate rejects an item that cites a parked PR lead as Evidence ----
# The pr-leads.md backstop is the existing lint-plan .planwright/-routing rule; pin that it
# fires for the new file, and prove the check is non-vacuous (a real anchor passes).
SR="$TMP/pr-sec"; mkdir -p "$SR/.planwright"
printf 'x = 1\n' > "$SR/real.py"
write_plan() {  # $1 = Evidence value
  cat > "$SR/.planwright/plan.md" <<EOF
# planwright Plan

- [ ] PR-sourced fix
      Mode: repair
      Rationale: a reviewer flagged a real defect
      Evidence: $1
      Surfaces: real.py
      Development: fix the call site at real.py:1
      Acceptance: behavior corrected
      Verification: python3 -c "print(1)"
EOF
}
write_plan ".planwright/pr-leads.md:3"
sec_rc=0; sec_out="$(python3 "$ROOT/scripts/lint-plan.py" --root "$SR" 2>&1)" || sec_rc=$?
write_plan "real.py:1"
ctl_rc=0; python3 "$ROOT/scripts/lint-plan.py" --root "$SR" --quiet || ctl_rc=$?
if [ "$sec_rc" != 0 ] && printf '%s' "$sec_out" | grep -qi 'routing only' && [ "$ctl_rc" = 0 ]; then
  ok "lint-plan rejects an item citing .planwright/pr-leads.md as Evidence (routing only); a real anchor passes (non-vacuous)"
else
  bad "the pr-leads routing gate is wrong (sec_rc=$sec_rc ctl_rc=$ctl_rc)"
fi

# --- Test PR11: parked leads carry the routing banner + never-Evidence warning -------------
if python3 - "$ROOT/scripts" <<'PY'
import sys; sys.path.insert(0, sys.argv[1]); import pr
md = pr._render_leads_md("o/r", 7, [
    {"kind": "thread", "id": "T1", "path": "a.py", "line": 3, "author": "x", "body": "hi"},
    {"kind": "check", "name": "unit", "path": "b.py", "line": 9, "excerpt": "boom"},
])
assert pr.ROUTING_BANNER in md, md
assert "NEVER cite this file as Evidence" in md, md
assert "a.py:3" in md and "b.py:9" in md, md
PY
then ok "pr leads file carries the UNVERIFIED routing banner + never-cite-as-Evidence warning"; else bad "pr leads file is missing its routing banner/warning"; fi
