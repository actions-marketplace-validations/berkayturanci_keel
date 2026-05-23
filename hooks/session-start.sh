#!/usr/bin/env bash
#
# session-start.sh — bootstrap the compound-engineering plugin in Claude Code
# on the Web sandbox sessions.
#
# The project enables the plugin at .claude/settings.json via
# `"enabledPlugins": {"compound-engineering@compound-engineering-plugin": true}`
# but enabling alone does not install the plugin in the ephemeral sandbox
# container — the marketplace must be added and the plugin installed on every
# fresh session. Local sessions already have the plugin (operator installed
# it once), so this hook is a no-op there.
#
# Idempotent: skips marketplace add / plugin install when already present.
# Non-interactive: never prompts.
# Non-blocking: install failures are logged but never abort session startup.
# Exits 0 in every path so the SessionStart hook never marks the session
# as failed for plugin-only problems.

set -uo pipefail

# Only run in Claude Code on the Web; local sessions already have the plugin.
# Accept common truthy spellings so a future env-var change does not silently
# disable the bootstrap.
case "${CLAUDE_CODE_REMOTE:-}" in
  true|TRUE|True|1|yes|YES) ;;
  *) exit 0 ;;
esac

MARKETPLACE_NAME="compound-engineering-plugin"
MARKETPLACE_SOURCE="EveryInc/compound-engineering-plugin"
PLUGIN="compound-engineering@compound-engineering-plugin"

# Fail-soft helper: log to stderr and continue. Plugin unavailability should
# not block the entire session.
warn() { echo "session-start: WARN $*" >&2; }

# `claude` itself missing means we cannot bootstrap; degrade with a warning.
if ! command -v claude >/dev/null 2>&1; then
  warn "claude CLI not on PATH; skipping plugin bootstrap"
  exit 0
fi

# Idempotency checks use grep -qF (fixed-string) so the marketplace short name
# cannot false-positive against a substring inside an unrelated plugin id, and
# vice versa.
if ! claude plugin marketplace list 2>/dev/null | grep -qF -- "$MARKETPLACE_NAME"; then
  echo "session-start: adding marketplace $MARKETPLACE_SOURCE"
  if ! claude plugin marketplace add "$MARKETPLACE_SOURCE"; then
    warn "claude plugin marketplace add failed; aborting plugin bootstrap (session continues)"
    exit 0
  fi
fi

if ! claude plugin list 2>/dev/null | grep -qF -- "$PLUGIN"; then
  echo "session-start: installing $PLUGIN"
  if ! claude plugin install "$PLUGIN"; then
    warn "claude plugin install failed; session continues without compound-engineering plugin"
    exit 0
  fi
fi

# Version probe is best-effort. Wrap in `|| true` so a pipeline failure (e.g.,
# `claude plugin list` exiting non-zero on a transient auth hiccup) cannot
# abort the script after a successful install.
VERSION="$(claude plugin list 2>/dev/null \
  | awk -v p="$PLUGIN" 'index($0, p) > 0 {found=1; next} found && /Version:/ {print $2; exit}' \
  || true)"
echo "session-start: compound-engineering plugin ready (v${VERSION:-unknown})"
