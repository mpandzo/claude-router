#!/usr/bin/env bash
# UserPromptSubmit: advisory model-tier suggestion, surfaced on each prompt.
#
# Classifies the prompt and surfaces a one-line suggested tier. ADVISORY ONLY:
# a hook cannot change the current session's model. To act on the suggestion,
# delegate the work to a subagent spawned on that model (the /model-router
# skill does this) or switch with /model.
#
# Stays silent unless a signal matches, so trivial follow-ups don't spam.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

line="$(jq -r '.prompt // ""' | "$here/classify.sh" --with-overrides)" || true
[ -n "$line" ] || exit 0
IFS=$'\t' read -r model tier reason <<<"$line"

short="🎯 model-router — based on the prompt, this looks like ${tier}-tier work; suggested model: ${model} (${reason})."
full="model-router suggestion → ${tier} (${model}, ${reason}). Advisory only: this does NOT change the current session's model. To act on it, delegate the task to a subagent spawned with that model (the /model-router skill does this) or tell the user to /model. Ignore mid-multi-turn or when the user already named a model."

jq -n --arg s "$short" --arg f "$full" \
  '{systemMessage:$s, hookSpecificOutput:{hookEventName:"UserPromptSubmit", additionalContext:$f}}'
