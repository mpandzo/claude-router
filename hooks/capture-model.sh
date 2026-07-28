#!/usr/bin/env bash
# SessionStart: record the main conversation's model so route-agent can tell a
# downgrade (safe) from an upgrade (costs more). A modelless subagent inherits
# the main conversation's model, so this is the correct baseline even for nested
# fan-outs.
#
# The `model` field is not guaranteed present (per Claude Code docs). If it's
# absent we write nothing and route-agent falls back to Haiku-only. The value
# may go stale if the model is changed mid-session (no hook fires for that).

set -euo pipefail

payload="$(cat)"
sid="$(printf '%s' "$payload" | jq -r '.session_id // ""')"
model="$(printf '%s' "$payload" | jq -r '.model // ""')"
[ -n "$sid" ] && [ -n "$model" ] || exit 0

dir="${CLAUDE_PLUGIN_DATA:-$HOME/.claude/claude-router}"
mkdir -p "$dir" 2>/dev/null || exit 0
printf '%s\n' "$model" > "$dir/model-$sid" 2>/dev/null || true
