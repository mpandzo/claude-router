#!/usr/bin/env bash
# PreToolUse (Agent/Task): fill in a model for agent spawns that don't set one.
#
# Fires the moment an agent is about to launch. Behavior:
#   - If the spawn already names a model  -> leave it (respect explicit choice).
#   - If subagent_type is "fork"          -> leave it (forks ignore the model
#                                             override, so injecting is a no-op).
#   - Otherwise classify the subagent's own brief and, if conclusive, inject a
#     matching model via updatedInput.
#   - If classification is inconclusive   -> change nothing; the agent inherits
#                                             the session default.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

payload="$(cat)"
get() { printf '%s' "$payload" | jq -r "$1"; }

model="$(get '.tool_input.model // ""')"
subtype="$(get '.tool_input.subagent_type // ""')"

# Respect an explicit model, and never route forks.
[ -z "$model" ] || exit 0
[ "$subtype" != "fork" ] || exit 0

# Classify from the subagent's description + prompt.
brief="$(get '[.tool_input.description, .tool_input.prompt] | map(select(. != null)) | join(" ")')"
line="$(printf '%s' "$brief" | "$here/classify.sh" --agent)" || true
[ -n "$line" ] || exit 0
IFS=$'\t' read -r picked tier reason <<<"$line"

# Inject the chosen model into the tool input; leave everything else untouched.
updated_input="$(printf '%s' "$payload" | jq --arg m "$picked" '.tool_input + {model:$m}')"

jq -n \
  --argjson ui "$updated_input" \
  --arg msg "🎯 model-router — set this agent's model to ${picked} (${tier}; ${reason})." \
  '{systemMessage:$msg, hookSpecificOutput:{hookEventName:"PreToolUse", updatedInput:$ui}}'
