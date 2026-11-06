#!/usr/bin/env bash
#
# Install the process reaper as a launchd agent on macOS.
#
# WHY
#
# Every `mix phx.server` and every test run starts a process. Left alone,
# they accumulate — the last sweep found 38 Phoenix instances and 206
# SurrealDB stores running on one machine. The reaper stops the ones that
# are provably ours, on a timer, so nobody has to remember.
#
# It only ever touches a process whose working directory is inside this
# repository, or whose pid is in ops/processes.tsv. The developer's other
# BEAM projects and the store on :8010 are not ours and are never stopped.
#
# The rule itself is Elixir: `Veritas.Dev.Process.Reaper`, with the platform
# operations behind `Veritas.Dev.Process`. This script only installs the
# agent.
#
# USAGE
#
#   bash ops/install-reaper.sh
#
# REMOVE
#
#   bash ops/install-reaper.sh --remove

set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
LABEL="com.veritas.reaper"
AGENTS="$HOME/Library/LaunchAgents"
PLIST="$AGENTS/$LABEL.plist"
DOMAIN="gui/$(id -u)"

if [ "${1:-}" = "--remove" ]; then
  launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
  rm -f "$PLIST"
  echo "removed the reaper."
  exit 0
fi

MIX="$(command -v mix)" || { echo "mix must be available on PATH" >&2; exit 1; }
case "$MIX" in
  /*) [ -x "$MIX" ] || { echo "mix must be executable" >&2; exit 1; } ;;
  *) echo "mix must resolve to an absolute executable path" >&2; exit 1 ;;
esac

mkdir -p "$AGENTS" "$ROOT/var/log"
cp "$ROOT/ops/launchd/$LABEL.plist" "$PLIST"
# Use plist operations rather than text substitution so spaces and XML
# metacharacters in the checkout, HOME or toolchain paths remain valid.
plutil -remove ProgramArguments.0 "$PLIST"
plutil -insert ProgramArguments.0 -string "$MIX" "$PLIST"
plutil -replace EnvironmentVariables.PATH -string "$PATH" "$PLIST"
plutil -replace EnvironmentVariables.VERITAS_KEEP_PORTS -string "${VERITAS_KEEP_PORTS:-4000,4050,4070,8010}" "$PLIST"
plutil -replace WorkingDirectory -string "$ROOT" "$PLIST"
plutil -replace StandardOutPath -string "$ROOT/var/log/reaper.log" "$PLIST"
plutil -replace StandardErrorPath -string "$ROOT/var/log/reaper.err.log" "$PLIST"
plutil -lint "$PLIST"

launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
launchctl bootstrap "$DOMAIN" "$PLIST"
launchctl enable "$DOMAIN/$LABEL"

echo
echo "installed: the reaper runs every five minutes."
echo "  it stops only Veritas processes — see the rule in Veritas.Dev.Process.Reaper."
echo "  dry run:  mix veritas.reap"
echo "  remove:   bash ops/install-reaper.sh --remove"
