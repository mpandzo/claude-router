#!/usr/bin/env bash
# PreToolUse (Agent): pick a model for agent spawns that don't set one.
#
# Every modelless, non-fork spawn is classified by an LLM which reads the brief
# and names haiku|sonnet|opus for the work. Two backends, in order:
#   1. Anthropic API (curl) when ANTHROPIC_API_KEY is set — fast, isolated.
#   2. `claude -p --model haiku` otherwise — reuses existing Claude Code auth,
#      no key needed, but heavier (spawns a full nested CLI).
# If the API path yields nothing (error/timeout) it falls back to the CLI path
# when `claude` is available. On total failure, nothing is injected and the
# spawn keeps the session default.
#
# Behaviour:
#   - explicit model on the spawn -> leave it.
#   - subagent_type "fork"        -> leave it (forks ignore the override).
#   - empty brief                 -> leave it (nothing to classify).
#
# Env:
#   ANTHROPIC_API_KEY           enables the API backend (x-api-key). The
#                               first-party API needs only this — no "secret".
#                               Also read from a .env at the plugin root if the
#                               environment doesn't already set it.
#   CLAUDE_ROUTER_API_MODEL     model id for the API call
#                               (default: claude-haiku-4-5-20251001).
#   CLAUDE_ROUTER_LLM_TIMEOUT   seconds to wait on either backend (default 30).
#   CLAUDE_ROUTER_CLASSIFYING   set internally around the CLI call so the nested
#                               `claude` doesn't re-trigger this hook.
#   CLAUDE_ROUTER_LLM_CMD       override the classifier command (reads the brief
#                               on stdin, prints a word); used for testing.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Reentrancy guard: never run inside our own CLI classification call.
if [ -n "${CLAUDE_ROUTER_CLASSIFYING:-}" ]; then exit 0; fi

# Load ANTHROPIC_API_KEY from the plugin's .env if it isn't already set. Only the
# one line is extracted (the file is never executed), and an already-set
# environment value always wins.
if [ -z "${ANTHROPIC_API_KEY:-}" ] && [ -f "$here/../.env" ]; then
  __ln="$(grep -E '^[[:space:]]*(export[[:space:]]+)?ANTHROPIC_API_KEY[[:space:]]*=' "$here/../.env" | tail -n1 || true)"
  if [ -n "${__ln:-}" ]; then
    __v="${__ln#*=}"
    __v="$(printf '%s' "$__v" | tr -d '\r' | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"
    __v="${__v#\"}"; __v="${__v%\"}"; __v="${__v#\'}"; __v="${__v%\'}"
    [ -n "$__v" ] && export ANTHROPIC_API_KEY="$__v"
    unset __ln __v
  fi
fi

payload="$(cat)"
get() { printf '%s' "$payload" | jq -r "$1"; }

model="$(get '.tool_input.model // ""')"
subtype="$(get '.tool_input.subagent_type // ""')"

[ -z "$model" ] || exit 0
[ "$subtype" != "fork" ] || exit 0

brief="$(get '[.tool_input.description, .tool_input.prompt] | map(select(. != null)) | join(" ")')"
[ -n "${brief//[[:space:]]/}" ] || exit 0

TIMEOUT="${CLAUDE_ROUTER_LLM_TIMEOUT:-30}"
INSTR="You are a model-complexity router for an AI coding assistant. Below is the BRIEF that will be handed to a subagent. Reply with EXACTLY ONE lowercase word — haiku, sonnet, or opus — naming the Claude model best suited to actually DO this task. Judge only the difficulty of the underlying work; IGNORE any output-format instructions, headings, or boilerplate. Rough guide: haiku = trivial or mechanical; sonnet = standard implementation, refactoring, or research; opus = deep reasoning, system/architecture design, security-critical, or high-risk verification. Output the single word and nothing else."

parse_word() { printf '%s' "$1" | { grep -oiE 'haiku|sonnet|opus' || true; } | head -n1 | tr '[:upper:]' '[:lower:]'; }

# Run a command with a timeout, portably (stock macOS ships no timeout/gtimeout).
# Writes to a temp file rather than a captured pipe, so lingering grandchildren
# of a killed command can't hold the pipe open and block the full duration.
run_with_timeout() {
  local secs="$1"; shift
  local tb; tb="$(command -v timeout || command -v gtimeout || true)"
  if [ -n "$tb" ]; then "$tb" "$secs" "$@"; return "$?"; fi
  local tmp; tmp="$(mktemp)"
  "$@" >"$tmp" 2>/dev/null &
  local cmd_pid=$!
  ( sleep "$secs"; kill -TERM "$cmd_pid" 2>/dev/null; sleep 1; kill -KILL "$cmd_pid" 2>/dev/null ) >/dev/null 2>&1 &
  local killer=$!
  wait "$cmd_pid" 2>/dev/null || true
  kill -TERM "$killer" 2>/dev/null || true
  wait "$killer" 2>/dev/null || true
  cat "$tmp"; rm -f "$tmp"
}

api_call() {   # $1 = prompt; prints raw model text
  local body
  body="$(jq -n --arg m "${CLAUDE_ROUTER_API_MODEL:-claude-haiku-4-5-20251001}" --arg p "$1" \
    '{model:$m, max_tokens:16, messages:[{role:"user", content:$p}]}')"
  curl -sS --max-time "$TIMEOUT" https://api.anthropic.com/v1/messages \
    -H "x-api-key: ${ANTHROPIC_API_KEY}" \
    -H "anthropic-version: 2023-06-01" \
    -H "content-type: application/json" \
    --data "$body" 2>/dev/null \
    | jq -r '.content[0].text // ""' 2>/dev/null || true
}

cli_call() {   # $1 = prompt; prints raw model text
  run_with_timeout "$TIMEOUT" env CLAUDE_ROUTER_CLASSIFYING=1 \
    claude -p "$1" --model haiku 2>/dev/null || true
}

classify() {   # prints haiku|sonnet|opus, or nothing
  local prompt word
  prompt="$(printf '%s\n\nAGENT BRIEF:\n%s' "$INSTR" "$brief")"

  if [ -n "${CLAUDE_ROUTER_LLM_CMD:-}" ]; then
    parse_word "$(printf '%s' "$brief" | ${CLAUDE_ROUTER_LLM_CMD} 2>/dev/null || true)"
    return
  fi

  if [ -n "${ANTHROPIC_API_KEY:-}" ]; then
    word="$(parse_word "$(api_call "$prompt")")"
    if [ -n "$word" ]; then printf '%s' "$word"; return; fi
  fi

  if command -v claude >/dev/null 2>&1; then
    parse_word "$(cli_call "$prompt")"
  fi
}

verdict="$(classify)"
[ -n "$verdict" ] || exit 0

updated_input="$(printf '%s' "$payload" | jq --arg m "$verdict" '.tool_input + {model:$m}')"

jq -n \
  --argjson ui "$updated_input" \
  --arg msg "🎯 model-router — set this agent's model to ${verdict} (LLM-classified)." \
  '{systemMessage:$msg, hookSpecificOutput:{hookEventName:"PreToolUse", updatedInput:$ui}}'
