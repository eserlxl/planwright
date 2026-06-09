# SPDX-FileCopyrightText: 2026 Eser KUBALI
# SPDX-License-Identifier: GPL-3.0-or-later
#
# scripts/install-aliases.sh — installs the unprefixed delegator commands
# (/codcycle, /codvisor, /codinventor) into a Claude commands dir.
# Sourced by tests/run.sh after tests/lib.sh — NOT standalone (uses ROOT/TMP/ok/bad).
#
# Every install here targets an explicit --dir under TMP, so the real ~/.claude commands
# dir is never written or deleted. The script's uninstall path runs rm, so IA3 also pins
# that it removes only the three aliases and leaves unrelated files alone.
#
# shellcheck shell=bash

IA="$ROOT/scripts/install-aliases.sh"
IADIR="$TMP/ia-cmds"

# --- Test IA1: --dir installs the three delegator aliases ------------------
if bash "$IA" --dir "$IADIR" >"$TMP/ia.out" 2>"$TMP/ia.err"; then
  ia_missing=""
  for n in codcycle codvisor codinventor; do
    [ -f "$IADIR/$n.md" ] || ia_missing="$ia_missing $n"
  done
  if [ -z "$ia_missing" ]; then
    ok "install-aliases --dir writes the three delegator alias files"
  else
    bad "install-aliases --dir missing:$ia_missing"
  fi
else
  bad "install-aliases --dir exited nonzero: $(cat "$TMP/ia.err" 2>/dev/null)"
fi

# --- Test IA2: each alias carries frontmatter and forwards to the plugin cmd -
ia_content=1
for n in codcycle codvisor codinventor; do
  f="$IADIR/$n.md"
  grep -q '^description: ' "$f" 2>/dev/null || ia_content=0
  grep -q '^argument-hint: ' "$f" 2>/dev/null || ia_content=0
  grep -q "/planwright:$n" "$f" 2>/dev/null || ia_content=0
  # the alias body forwards the literal token "$ARGUMENTS" — match it verbatim, no expansion
  # shellcheck disable=SC2016
  grep -qF 'ARGUMENTS: $ARGUMENTS' "$f" 2>/dev/null || ia_content=0
done
if [ "$ia_content" -eq 1 ]; then
  ok "install-aliases delegators carry description/argument-hint and forward to /planwright:<name>"
else
  bad "install-aliases delegator content is malformed"
fi

# --- Test IA3: --uninstall removes only the three aliases, leaving other files -
printf 'keep me\n' > "$IADIR/other.md"
if bash "$IA" --dir "$IADIR" --uninstall >"$TMP/ia.un" 2>&1; then
  ia_gone=1
  for n in codcycle codvisor codinventor; do
    [ -e "$IADIR/$n.md" ] && ia_gone=0
  done
  if [ "$ia_gone" -eq 1 ] && [ -f "$IADIR/other.md" ]; then
    ok "install-aliases --uninstall removes the three aliases and leaves unrelated files"
  else
    bad "install-aliases --uninstall left an alias or deleted an unrelated file"
  fi
else
  bad "install-aliases --uninstall exited nonzero: $(cat "$TMP/ia.un" 2>/dev/null)"
fi

# --- Test IA4: --help exits 0 with usage; an unknown flag exits 2 ----------
if bash "$IA" --help 2>/dev/null | grep -q "Usage:"; then
  ok "install-aliases --help prints usage (exit 0)"
else
  bad "install-aliases --help did not print usage"
fi
if bash "$IA" --bogus >/dev/null 2>&1; then
  bad "install-aliases accepted an unknown flag"
else
  ia_rc=$?
  if [ "$ia_rc" -eq 2 ]; then
    ok "install-aliases rejects an unknown flag (exit 2)"
  else
    bad "install-aliases unknown flag exit was $ia_rc, not 2"
  fi
fi

# --- Test IA5: an explicit empty --dir is rejected, not rerouted to the personal scope
# `--dir ""` (e.g. `--dir "$VAR"` with VAR unset) must exit 2 and write nothing — never
# silently fall through to ~/.claude/commands, which --uninstall would then delete from.
# Run under an isolated HOME/CLAUDE_CONFIG_DIR so even a regression cannot touch the real
# personal scope.
IAHOME="$TMP/ia-emptyguard"; mkdir -p "$IAHOME"
ia5_rc=0
HOME="$IAHOME" CLAUDE_CONFIG_DIR="$IAHOME/.claude" bash "$IA" --dir "" \
  >"$TMP/ia5.out" 2>"$TMP/ia5.err" || ia5_rc=$?
if [ "$ia5_rc" -eq 2 ] \
   && grep -q 'must not be empty' "$TMP/ia5.err" \
   && [ ! -e "$IAHOME/.claude/commands/codvisor.md" ]; then
  ok "install-aliases rejects an empty --dir (exit 2) and writes nothing to the personal scope"
else
  bad "install-aliases mis-handled an empty --dir (rc=$ia5_rc err='$(cat "$TMP/ia5.err" 2>/dev/null)')"
fi
# The destructive variant must also exit 2 at parse, before the uninstall rm loop runs.
ia5u_rc=0
HOME="$IAHOME" CLAUDE_CONFIG_DIR="$IAHOME/.claude" bash "$IA" --dir "" --uninstall \
  >/dev/null 2>&1 || ia5u_rc=$?
if [ "$ia5u_rc" -eq 2 ]; then
  ok "install-aliases --dir '' --uninstall exits 2 before removing anything"
else
  bad "install-aliases --dir '' --uninstall did not exit 2 (rc=$ia5u_rc)"
fi
