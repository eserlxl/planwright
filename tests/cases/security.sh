# SPDX-FileCopyrightText: 2026 Eser KUBALI
# SPDX-License-Identifier: GPL-3.0-or-later
# shellcheck shell=bash
#
# Read-only planning write-boundary invariant tests. Sourced by tests/run.sh after
# tests/lib.sh — NOT standalone (uses ROOT/TMP/ok/bad).

# --- Test SEC1: planning entry points write only under .planwright/ -----------------
# status.py / build-graph.py / lint-plan.py are the read-only planning entry points.
# SKILL.md pins "writes only the plan file, never application source." Run all three
# over a committed git fixture and assert nothing OUTSIDE .planwright/ is created or
# modified — a whole-tree snapshot the per-file --fix byte checks (lint-plan.sh) miss.
SEC="$TMP/sec_wb"; mkdir -p "$SEC/.planwright" "$SEC/src"
printf 'def a():\n    return 1\n' > "$SEC/src/a.py"
printf '# readme\n[x](src/a.py)\n' > "$SEC/README.md"
git -C "$SEC" init -q
git -C "$SEC" add -A
git -C "$SEC" -c user.name=t -c user.email=t@e.com commit -qm init
cat > "$SEC/.planwright/plan.md" <<'PLAN'
# planwright Plan — .

- [ ] Probe item with a mechanically fixable Surface
      Mode: improve
      Rationale: exercise lint-plan --fix so the write path actually runs.
      Evidence: src/a.py:1 defines a().
      Surfaces: src/a.py
      Development: no-op probe.
      Acceptance: nothing outside .planwright/ changes.
      Verification: bash tests/run.sh
PLAN
# Snapshot every tracked-and-untracked path OUTSIDE .planwright/ (name + checksum).
sec_snap() { ( cd "$SEC" && find . -type f -not -path './.git/*' -not -path './.planwright/*' \
                 | LC_ALL=C sort | while read -r f; do printf '%s ' "$f"; cksum "$f"; done ); }
sec_before="$(sec_snap)"
python3 "$ROOT/scripts/build-graph.py" --root "$SEC" >/dev/null 2>&1 || true
python3 "$ROOT/scripts/status.py" --recommend --root "$SEC" >/dev/null 2>&1 || true
python3 "$ROOT/scripts/lint-plan.py" --root "$SEC" --plan "$SEC/.planwright/plan.md" --fix --quiet >/dev/null 2>&1 || true
sec_after="$(sec_snap)"
if [ "$sec_before" = "$sec_after" ]; then
  ok "planning entry points (status/build-graph/lint-plan) write nothing outside .planwright/"
else
  bad "a planning entry point created or modified a file outside .planwright/ (before/after tree differ)"
fi

# --- Test SEC2: lifecycle.py (the MUTATING bookkeeping script) confines writes to .planwright/ ----
# SEC1 covers the READ-ONLY entry points; lifecycle.py is the one script that actually WRITES
# (housekeep drains, land flips+stamps, reconcile records), so its write-boundary matters most: every
# write must land inside .planwright/ and never touch source. Reuse the SEC fixture + snapshot, run a
# housekeep then a land, and assert the outside-.planwright tree is byte-identical (lock files,
# plan/completed/rejected drains all stay in-boundary).
sec_lc_before="$(sec_snap)"
python3 "$ROOT/scripts/lifecycle.py" housekeep --root "$SEC/.planwright" >/dev/null 2>&1 || true
python3 "$ROOT/scripts/lifecycle.py" land 1 --commit deadbee --root "$SEC/.planwright" >/dev/null 2>&1 || true
sec_lc_after="$(sec_snap)"
if [ "$sec_lc_before" = "$sec_lc_after" ]; then
  ok "lifecycle.py (housekeep/land) writes nothing outside .planwright/ (the mutating script stays in-boundary)"
else
  bad "lifecycle.py created or modified a file outside .planwright/ (write-boundary breached)"
fi

# --- Test SEC3: a planning run never READS (ingests) or stages a gitignored secret-shaped file ----
# SEC1/SEC2 pin the WRITE boundary; this pins the READ boundary. Planning scans git-tracked files
# ONLY (Stage 1), so a gitignored secret (.env) must never be ingested into graph.json nor staged.
# A regression that switched build-graph to os.walk / --no-ignore would leak the secret into the
# graph memory. Build a fixture with a tracked source file and a gitignored .env carrying a sentinel,
# run build-graph + status, then assert (a) .env stays untracked and (b) the sentinel never appears
# in the emitted graph.
SECR="$TMP/sec_secret"; mkdir -p "$SECR/src"
printf 'def a():\n    return 1\n' > "$SECR/src/a.py"
printf '.env\n' > "$SECR/.gitignore"
printf 'API_KEY=SENTINEL_DO_NOT_INGEST_8f3a\n' > "$SECR/.env"
git -C "$SECR" init -q
git -C "$SECR" add -A
git -C "$SECR" -c user.name=t -c user.email=t@e.com commit -qm init
python3 "$ROOT/scripts/build-graph.py" --root "$SECR" > "$SECR/graph.out" 2>/dev/null || true
python3 "$ROOT/scripts/status.py" --recommend --root "$SECR" >/dev/null 2>&1 || true
env_tracked="$(git -C "$SECR" ls-files .env)"            # gitignored => never staged => empty
if [ -z "$env_tracked" ] \
   && ! grep -q 'SENTINEL_DO_NOT_INGEST' "$SECR/graph.out"; then
  ok "a planning run never ingests or stages a gitignored secret (.env excluded from the graph and the index)"
else
  bad "a planning run ingested or staged a gitignored secret (.env leaked into the graph or got tracked)"
fi

# --- Test SEC4: the Stage 10 gate refuses a protected-path Surface ------------------
# SEC1-SEC3 pin the planning write/read boundary; this pins the *plan* boundary: an item
# may never name a VCS/tool-state tree (.git/, .qb/), the LICENSE, or a secret/credential
# file (.env/.env.*/*.pem/*.key) as an editable Surface (SKILL.md "Editable surfaces").
# So a generated/imported plan cannot smuggle an edit to a secret past execute. The
# fails-on-violation per-class coverage lives in lint-plan.sh Test 12g; this is the
# boundary-suite assertion that the class is gated at all (one secret + one state tree).
SECB="$TMP/sec_protboundary"; mkdir -p "$SECB/.planwright"
cat > "$SECB/.planwright/plan.md" <<'PLAN'
# planwright Plan — .

- [ ] Smuggle an edit to a dotenv secret
      Mode: improve
      Rationale: r.
      Evidence: gap.
      Surfaces: deploy/.env.production
      Development: edit it.
      Acceptance: green.
      Verification: bash tests/run.sh

- [ ] Smuggle an edit to git state
      Mode: improve
      Rationale: r.
      Evidence: gap.
      Surfaces: .git/hooks/pre-commit
      Development: edit it.
      Acceptance: green.
      Verification: bash tests/run.sh
PLAN
secb_rc=0
secb_out="$(python3 "$ROOT/scripts/lint-plan.py" --root "$SECB" --plan "$SECB/.planwright/plan.md" 2>&1)" || secb_rc=$?
if [ "$secb_rc" -ne 0 ] \
   && printf '%s' "$secb_out" | grep -qF "is a protected path (secret/credential file)" \
   && printf '%s' "$secb_out" | grep -qF "is a protected path (.git/ state tree)"; then
  ok "the Stage 10 gate refuses a secret-file and a .git/ Surface (a plan cannot smuggle a protected-path edit)"
else
  bad "the Stage 10 gate accepted a protected-path Surface (boundary breached, rc=$secb_rc)"
fi
