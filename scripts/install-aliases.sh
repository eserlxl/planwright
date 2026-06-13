#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Eser KUBALI
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Install short, unprefixed personal aliases for planwright's plugin commands.
#
# Claude Code namespaces every plugin command by the plugin name, so the
# commands ship as `/planwright:codcycle`, `/planwright:codvisor`, etc. A plugin
# cannot register an unprefixed top-level command — those only exist in the user
# (~/.claude/commands/) or project (.claude/commands/) scopes, which a plugin
# can't write into. This script drops thin delegator commands into one of those
# scopes so you can type `/codcycle`, `/codvisor`, `/codinventor`, `/codshard`, `/codmaster`.
#
# Each alias only forwards its arguments to the real `/planwright:<name>` command
# (it does NOT copy the logic), so the aliases never drift out of sync with the
# plugin.
#
# Usage:
#   scripts/install-aliases.sh [--project] [--dir <path>] [--uninstall]
#
# Scope (default: personal):
#   (no flag)        install into ~/.claude/commands/        (all your projects)
#   --project        install into ./.claude/commands/        (this repo only)
#   --dir <path>     install into an explicit commands directory
#
# Other:
#   --uninstall      remove the alias files from the target scope
#   -h, --help       show this help
set -euo pipefail

ALIASES=(codcycle codvisor codinventor codshard codmaster)

usage() {
  echo "Usage: $(basename "$0") [--project] [--dir <path>] [--uninstall]"
  echo "Scope: default ~/.claude/commands/, --project ./.claude/commands/, --dir <path>"
  echo "Other: --uninstall, -h/--help"
}

TARGET_DIR=""
UNINSTALL=0
while [ $# -gt 0 ]; do
  case "$1" in
    --project)
      TARGET_DIR=".claude/commands"
      shift
      ;;
    --dir)
      [ $# -ge 2 ] || { echo "error: --dir needs a path" >&2; exit 2; }
      # Reject an explicit empty value (e.g. `--dir "$VAR"` with VAR unset): an empty
      # TARGET_DIR is indistinguishable from "no --dir" below and would silently reroute
      # to the personal ~/.claude/commands scope — destructive under --uninstall.
      [ -n "$2" ] || { echo "error: --dir path must not be empty" >&2; exit 2; }
      TARGET_DIR="$2"
      shift 2
      ;;
    --uninstall)
      UNINSTALL=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "error: unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

# Default scope: personal commands dir, honouring CLAUDE_CONFIG_DIR if set.
if [ -z "$TARGET_DIR" ]; then
  TARGET_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/commands"
fi

if [ "$UNINSTALL" -eq 1 ]; then
  removed=0
  for name in "${ALIASES[@]}"; do
    f="$TARGET_DIR/$name.md"
    if [ -f "$f" ]; then
      rm -f "$f"
      echo "removed $f"
      removed=$((removed + 1))
    fi
  done
  echo "Uninstalled $removed alias(es) from $TARGET_DIR"
  exit 0
fi

mkdir -p "$TARGET_DIR"

# Per-alias frontmatter (description + argument-hint) mirrors the plugin commands.
# Case-statement lookups, not `declare -A`: associative arrays need bash >= 4.0, and
# stock macOS ships /bin/bash 3.2 — `declare -A` there aborts the install (set -e)
# AFTER mkdir created the target dir, leaving zero aliases written.
desc_for() {
  case "$1" in
    codcycle)   echo "Personal alias for /planwright:codcycle — runs planwright's explore→invent cycle orchestrator without the plugin prefix." ;;
    codvisor)   echo "Personal alias for /planwright:codvisor — planwright advisor shorthand (explore) without the plugin prefix." ;;
    codinventor) echo "Personal alias for /planwright:codinventor — planwright inventor shorthand (invent) without the plugin prefix." ;;
    codshard)   echo "Personal alias for /planwright:codshard — planwright's sharded maturity sweep (per-shard scoped cycles, then one closing whole-repo round) without the plugin prefix." ;;
    codmaster)  echo "Personal alias for /planwright:codmaster — the front door: senses the planning state and runs the required commands consecutively to the final point (advise = tell only; safe = no invention; loop = infinite, reset-continued; parallel = forward codshard recon) without the plugin prefix." ;;
  esac
}
arghint_for() {
  case "$1" in
    codcycle)   echo "[N] | <N> (negative = infinite) | (empty = 10 outer cycles)" ;;
    codvisor)   echo "[planwright args] | <N> [D] | (empty = cycle 10 depth 10 explore)" ;;
    codinventor) echo "[planwright args] | <N> [D] | (empty = cycle 10 depth 10 invent)" ;;
    codshard)   echo "[M] [D] | shards <a,b,c> | parallel [J] | explore | (empty = auto-shards, cycle 3 depth 10 per shard)" ;;
    codmaster)  echo "advise | safe | loop | parallel [J] | (empty = sense → dispatch → re-sense, consecutively until the final point)" ;;
  esac
}

for name in "${ALIASES[@]}"; do
  f="$TARGET_DIR/$name.md"
  cat > "$f" <<EOF
---
description: $(desc_for "$name")
argument-hint: "$(arghint_for "$name")"
---

This is a thin personal alias for the planwright plugin command **\`/planwright:$name\`**.
Do not re-implement any logic here. Dispatch to that plugin command now, forwarding the
arguments below verbatim, and let it own all of its behaviour.

ARGUMENTS: \$ARGUMENTS
EOF
  echo "wrote $f"
done

echo
echo "Installed ${#ALIASES[@]} aliases into $TARGET_DIR"
echo "Restart Claude Code (or /clear), then use: /codcycle  /codvisor  /codinventor  /codshard  /codmaster"
