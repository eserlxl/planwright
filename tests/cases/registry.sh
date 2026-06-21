# SPDX-FileCopyrightText: 2026 Eser KUBALI
# SPDX-License-Identifier: GPL-3.0-or-later
# shellcheck shell=bash
#
# scripts/registry.py — cross-repo project registry (the list a single dashboard server
# reads to list/switch projects). Sourced by tests/run.sh after tests/lib.sh — NOT
# standalone (uses ROOT/TMP/ok/bad). The registry is redirected to a temp XDG dir so the
# test never reads or writes the developer's real ~/.config/planwright/projects.json.

REG="$ROOT/scripts/registry.py"
RGX="$TMP/registry-xdg"; mkdir -p "$RGX"
export XDG_CONFIG_HOME="$RGX"

# Two fake projects: one with a .planwright/, one without (discover must skip the latter).
RGP="$TMP/registry-proj"; mkdir -p "$RGP/alpha/.planwright" "$RGP/beta/.planwright" "$RGP/notaproj"

# --- Test RG1: add + list round-trips a project with a stable, path-derived id ----------
python3 "$REG" add "$RGP/alpha" >/dev/null
if python3 "$REG" list | python3 -c '
import json, os, sys
data = json.load(sys.stdin)
ps = data["projects"]
assert len(ps) == 1, ps
assert os.path.basename(ps[0]["path"]) == "alpha", ps
assert ps[0]["id"] and isinstance(ps[0]["id"], str), ps
'; then
  ok "registry.py add + list round-trips a project with a path-derived id"
else
  bad "registry.py add/list did not round-trip a single project"
fi

# --- Test RG2: project_id is stable per abspath and distinct across paths ----------------
if python3 -c '
import sys; sys.path.insert(0, "'"$ROOT"'/scripts")
import registry
a = registry.project_id("'"$RGP"'/alpha")
a2 = registry.project_id("'"$RGP"'/alpha/")   # trailing slash -> same canonical path
b = registry.project_id("'"$RGP"'/beta")
assert a == a2, (a, a2)
assert a != b, (a, b)
assert all(c in "0123456789abcdef" for c in a), a   # URL-safe hex (no escaping needed)
'; then
  ok "registry.project_id is stable per canonical path and distinct across paths"
else
  bad "registry.project_id is not stable/distinct/url-safe"
fi

# --- Test RG3: the registry file is atomic-shaped (version + projects list) --------------
if [ -f "$RGX/planwright/projects.json" ] \
   && python3 -c '
import json
d = json.load(open("'"$RGX"'/planwright/projects.json"))
assert d["version"] == 1, d
assert isinstance(d["projects"], list), d
'; then
  ok "registry file carries version + projects list at the XDG path"
else
  bad "registry file missing or malformed at the XDG path"
fi

# --- Test RG4: discover registers children with a .planwright/, skips those without ------
python3 "$REG" remove "$RGP/alpha" >/dev/null
python3 "$REG" discover "$RGP" >/dev/null
if python3 "$REG" list | python3 -c '
import json, os, sys
ps = json.load(sys.stdin)["projects"]
names = sorted(os.path.basename(p["path"]) for p in ps)
assert names == ["alpha", "beta"], names   # notaproj has no .planwright/ -> skipped
'; then
  ok "registry.py discover registers .planwright/ children and skips non-projects"
else
  bad "registry.py discover did not register exactly the .planwright/ children"
fi

# --- Test RG5: list_projects prunes an entry whose .planwright/ vanished -----------------
rm -rf "$RGP/beta/.planwright"
if python3 -c '
import sys; sys.path.insert(0, "'"$ROOT"'/scripts")
import registry
ps = registry.list_projects()
import os
names = sorted(os.path.basename(p["path"]) for p in ps)
assert names == ["alpha"], names   # beta pruned (its .planwright/ is gone)
'; then
  ok "registry.list_projects prunes entries whose .planwright/ no longer exists"
else
  bad "registry.list_projects did not prune a vanished project"
fi

# --- Test RG6: remove drops a project ---------------------------------------------------
python3 "$REG" remove "$RGP/alpha" >/dev/null
if python3 "$REG" list | python3 -c '
import json, sys
assert json.load(sys.stdin)["projects"] == [], "registry not empty after remove"
'; then
  ok "registry.py remove drops a project"
else
  bad "registry.py remove did not drop the project"
fi

# --- Test RG7: an unsupported schema version fails closed to the empty registry ---------
# load() must vouch for the schema before returning entries: a projects.json whose version
# is not the supported 1 (a future format this build cannot read) reads empty, exactly like
# the corrupt-file degrade — never returning entries from a format it cannot interpret.
mkdir -p "$RGX/planwright"
printf '{"version": 2, "projects": [{"id": "ghost", "path": "%s/alpha"}]}\n' "$RGP" > "$RGX/planwright/projects.json"
if python3 "$REG" list | python3 -c '
import json, sys
assert json.load(sys.stdin)["projects"] == [], "unsupported version not failed closed"
' 2>/dev/null; then
  ok "registry.load fails closed on an unsupported schema version (reads empty, not the v2 entries)"
else
  bad "registry.load returned entries from an unsupported-version projects.json"
fi

# --- Test RG8: a corrupt projects.json degrades to the empty registry (no 500) ----------
# load()'s `except (OSError, ValueError): return {}` is the degrade the docstring promises —
# the dashboard must never 500 because the registry is corrupt or half-written. This
# fails-on-drift test exercises that branch directly: a syntactically-broken file reads empty
# with a clean exit and no traceback. Narrowing the except clause (e.g. to OSError only,
# dropping the JSON ValueError) makes this go red.
printf '{ this is not valid json,,,\n' > "$RGX/planwright/projects.json"
reg_corrupt_rc=0
reg_corrupt_out="$(python3 "$REG" list 2>"$TMP/reg_corrupt_err")" || reg_corrupt_rc=$?
if [ "$reg_corrupt_rc" = 0 ] \
   && printf '%s' "$reg_corrupt_out" | python3 -c 'import json,sys; sys.exit(0 if json.load(sys.stdin)["projects"]==[] else 1)' \
   && ! grep -q "Traceback" "$TMP/reg_corrupt_err"; then
  ok "registry.load degrades a corrupt projects.json to the empty registry (clean exit, no traceback)"
else
  bad "registry.load did not cleanly degrade a corrupt projects.json (rc=$reg_corrupt_rc out=[$reg_corrupt_out])"
fi

unset XDG_CONFIG_HOME
