# SPDX-FileCopyrightText: 2026 Eser KUBALI
# SPDX-License-Identifier: GPL-3.0-or-later
# shellcheck shell=bash
#
# hybrid-ai opt-in dossier-survey delegation — SKILL.md contract drift-guards.
# Sourced by tests/run.sh after tests/lib.sh — NOT standalone (uses ROOT/TMP/ok/bad).
#
# planwright's planning path is run by the active LLM agent following SKILL.md, not by a runnable
# binary, so there is no executable "planning path" to run twice and diff. hybrid-ai touches ZERO
# scripts by design (the off-path is the baseline by construction). The off==skipped guarantee and
# the ignore-context rule are therefore pinned here as fails-on-drift CONTRACT assertions over the
# SKILL.md clauses: each fails if the load-bearing safety guarantee is removed or weakened.

# --- Test HA1: SKILL.md Stages 3-7 pins the hybrid-ai off==skipped state identity ---
# off==skipped: with the flag absent the run writes no new .planwright/ state and the dossier is
# unchanged from the baseline. Removing or weakening that clause fails this guard.
if python3 - "$ROOT/skills/planwright/SKILL.md" <<'PY' 2>/dev/null
import sys
t = " ".join(open(sys.argv[1], encoding="utf-8").read().split())
a = t.find("### Stages 3"); b = t.find("### Stage 8")
if a < 0 or b < 0 or b <= a:
    raise SystemExit(1)
para = t[a:b]
need = [tok for tok in (
    "hybrid-ai",
    "off==skipped",
    "no new",
    "from the baseline",
) if tok not in para]
sys.exit(1 if need else 0)
PY
then ok "SKILL.md Stages 3-7 pins the hybrid-ai off==skipped state identity (off writes no new .planwright/ state, dossier unchanged from the baseline)"; else bad "SKILL.md lost the hybrid-ai off==skipped state-identity clause"; fi

# --- Test HA2: SKILL.md Stages 3-7 pins the hybrid-ai ignore-context (invent/execute) ---
# The flag is recognized but a no-op under the generative tier (invent) and the mutating path
# (execute), mirroring Stage 1.6's parallel. A wrong ignore-context (e.g. "active under invent")
# removes the pinned phrase and fails this guard.
if python3 - "$ROOT/skills/planwright/SKILL.md" <<'PY' 2>/dev/null
import sys
t = " ".join(open(sys.argv[1], encoding="utf-8").read().split())
a = t.find("### Stages 3"); b = t.find("### Stage 8")
if a < 0 or b < 0 or b <= a:
    raise SystemExit(1)
para = t[a:b]
need = [tok for tok in (
    "hybrid-ai",
    "ignored under `invent` and on `execute`",
) if tok not in para]
sys.exit(1 if need else 0)
PY
then ok "SKILL.md Stages 3-7 pins the hybrid-ai ignore-context (ignored under invent and on execute)"; else bad "SKILL.md lost the hybrid-ai ignore-context clause (invent/execute)"; fi

# --- Test HA3: SKILL.md Stages 3-7 pins the hybrid-ai never-Evidence ceiling ---
# Every delegated dossier finding is routing-only: re-proven from a code re-read or dropped, and
# never an item's Evidence (the identical Stage 1.6 ceiling). Removing it fails this guard.
if python3 - "$ROOT/skills/planwright/SKILL.md" <<'PY' 2>/dev/null
import sys
t = " ".join(open(sys.argv[1], encoding="utf-8").read().split())
a = t.find("### Stages 3"); b = t.find("### Stage 8")
if a < 0 or b < 0 or b <= a:
    raise SystemExit(1)
para = t[a:b]
need = [tok for tok in (
    "delegated dossier finding",
    "re-proven from a code re-read inside the host's single-agent dossier",
    "never becomes an item's `Evidence:`",
) if tok not in para]
sys.exit(1 if need else 0)
PY
then ok "SKILL.md Stages 3-7 pins the hybrid-ai never-Evidence ceiling (delegated findings re-proven from a code re-read or dropped, never Evidence)"; else bad "SKILL.md lost the hybrid-ai never-Evidence ceiling for delegated findings"; fi

# --- Test HA4: SKILL.md Stages 3-7 bounds the hybrid-ai egress (read-only, git-tracked, Focus) ---
# Delegation is read-only, ships only git-tracked files under the smallest Focus-enclosing dir, never
# gitignored paths, public-repo egress only. Widening the target/egress removes a pinned phrase and
# fails this guard (also covers the delegation clause's --read-only + Focus-enclosing --target).
if python3 - "$ROOT/skills/planwright/SKILL.md" <<'PY' 2>/dev/null
import sys
t = " ".join(open(sys.argv[1], encoding="utf-8").read().split())
a = t.find("### Stages 3"); b = t.find("### Stage 8")
if a < 0 or b < 0 or b <= a:
    raise SystemExit(1)
para = t[a:b]
need = [tok for tok in (
    "--agent all --read-only",
    "smallest directory enclosing the run's Focus",
    "only git-tracked files",
    "never a gitignored path",
    "public-repo egress",
) if tok not in para]
sys.exit(1 if need else 0)
PY
then ok "SKILL.md Stages 3-7 bounds the hybrid-ai egress (read-only, git-tracked-only, Focus-enclosing target, public-repo egress)"; else bad "SKILL.md lost or widened the hybrid-ai egress bound (read-only/git-tracked/Focus-enclosing/public-repo)"; fi

# --- Test HA5: SKILL.md Stages 3-7 pins the hybrid-ai degrade-to-skip (no-hard-dependency) ---
# When no external CLI is available, planwright prints the skip note and runs the dossier unchanged
# on the host agent (never errors, never blocks). Removing the clause/message fails this guard.
if python3 - "$ROOT/skills/planwright/SKILL.md" <<'PY' 2>/dev/null
import sys
t = " ".join(open(sys.argv[1], encoding="utf-8").read().split())
a = t.find("### Stages 3"); b = t.find("### Stage 8")
if a < 0 or b < 0 or b <= a:
    raise SystemExit(1)
para = t[a:b]
need = [tok for tok in (
    "no-hard-dependency",
    "planwright: hybrid-ai delegation unavailable — running the dossier on the host agent.",
    "runs the dossier unchanged",
) if tok not in para]
sys.exit(1 if need else 0)
PY
then ok "SKILL.md Stages 3-7 pins the hybrid-ai degrade-to-skip (no-hard-dependency: skip note + runs the dossier unchanged on the host agent)"; else bad "SKILL.md lost the hybrid-ai degrade-to-skip clause or skip message"; fi
