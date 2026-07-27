#!/usr/bin/env bash
# PreToolUse (Agent): pick a model for agent spawns that don't set one.
#
# Every modelless, non-fork spawn is classified by an LLM which reads the brief
# (the full task the subagent will act on) and replies haiku|sonnet|opus|keep.
# "keep" (and any unparseable/failed reply) means: change nothing, keep the
# session default. Two backends, in order:
#   1. Anthropic API (curl) when ANTHROPIC_API_KEY is available — fast, tool-less.
#   2. `claude -p` otherwise — reuses existing Claude Code auth, no key needed.
# If the API path yields nothing (error/timeout) it falls back to the CLI path
# when `claude` is available.
#
# Skips: an explicit model, subagent_type "fork", and empty briefs.
#
# API key resolution (first hit wins): the environment, then
# <plugin>/.env, then ~/.claude/claude-router.env. Setting it in the environment
# (shell profile or ~/.claude/settings.json "env") is the way to supply it to a
# marketplace-installed copy, where the plugin-root .env isn't present.
#
# Env:
#   ANTHROPIC_API_KEY           enables the API backend (x-api-key only; no secret).
#   CLAUDE_ROUTER_API_MODEL     model id for the API call (default claude-haiku-4-5-20251001).
#   CLAUDE_ROUTER_LLM_TIMEOUT   seconds to wait on either backend (default 30).
#   CLAUDE_ROUTER_LOG           telemetry log path (default ~/.claude/claude-router.log;
#                               set to /dev/null to disable).
#   CLAUDE_ROUTER_CLASSIFYING   set internally around the CLI call to prevent re-entry.
#   CLAUDE_ROUTER_LLM_CMD       override the classifier command (brief on stdin,
#                               prints a word); used for testing.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Reentrancy guard: never run inside our own CLI classification call.
if [ -n "${CLAUDE_ROUTER_CLASSIFYING:-}" ]; then exit 0; fi

# Resolve the API key from a file if the environment doesn't set one. Only the
# ANTHROPIC_API_KEY line is extracted (files are never executed).
if [ -z "${ANTHROPIC_API_KEY:-}" ]; then
  for __ef in "$here/../.env" "$HOME/.claude/claude-router.env"; do
    [ -f "$__ef" ] || continue
    __ln="$(grep -E '^[[:space:]]*(export[[:space:]]+)?ANTHROPIC_API_KEY[[:space:]]*=' "$__ef" | tail -n1 || true)"
    [ -n "${__ln:-}" ] || continue
    __v="${__ln#*=}"
    __v="$(printf '%s' "$__v" | tr -d '\r' | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"
    __v="${__v#\"}"; __v="${__v%\"}"; __v="${__v#\'}"; __v="${__v%\'}"
    if [ -n "$__v" ]; then export ANTHROPIC_API_KEY="$__v"; break; fi
  done
  unset __ef __ln __v 2>/dev/null || true
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
LOG="${CLAUDE_ROUTER_LOG:-$HOME/.claude/claude-router.log}"
INSTR="You are a model-complexity router for an AI coding assistant. You are given the BRIEF that will be handed to a subagent. Reply with EXACTLY ONE lowercase word: haiku, sonnet, opus, or keep. Judge only the difficulty of the underlying work; IGNORE any output-format instructions, headings, or boilerplate in the brief. haiku = trivial or mechanical; sonnet = standard implementation, refactoring, or research; opus = deep reasoning, system/architecture design, security-critical, or high-risk verification; keep = the task is ordinary enough that the session default is fine, OR you are unsure — prefer 'keep' over guessing. Output the single word and nothing else."

log() { printf '%s\t%s\t%s\n' "$(date -u +%FT%TZ)" "$1" "$(printf '%s' "$brief" | tr '\n\t' '  ' | cut -c1-120)" >> "$LOG" 2>/dev/null || true; }

parse_word() { printf '%s' "$1" | { grep -oiE 'haiku|sonnet|opus|keep' || true; } | head -n1 | tr '[:upper:]' '[:lower:]'; }

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

api_call() {   # prints raw model text; instruction is a system prompt, brief is the user turn
  local body
  body="$(jq -n --arg m "${CLAUDE_ROUTER_API_MODEL:-claude-haiku-4-5-20251001}" --arg s "$INSTR" --arg b "$brief" \
    '{model:$m, max_tokens:16, system:$s, messages:[{role:"user", content:("AGENT BRIEF:\n"+$b)}]}')"
  curl -sS --max-time "$TIMEOUT" https://api.anthropic.com/v1/messages \
    -H "x-api-key: ${ANTHROPIC_API_KEY}" \
    -H "anthropic-version: 2023-06-01" \
    -H "content-type: application/json" \
    --data "$body" 2>/dev/null \
    | jq -r '.content[0].text // ""' 2>/dev/null || true
}

cli_call() {   # prints raw model text
  # --system-prompt replaces the default agentic prompt so it classifies, not
  # acts; --allowed-tools "" is fail-safe hardening so no tools are ever available.
  run_with_timeout "$TIMEOUT" env CLAUDE_ROUTER_CLASSIFYING=1 \
    claude -p "AGENT BRIEF:\n$brief" --system-prompt "$INSTR" --model haiku --allowed-tools "" 2>/dev/null || true
}

classify() {   # prints haiku|sonnet|opus|keep, or nothing
  local word
  if [ -n "${CLAUDE_ROUTER_LLM_CMD:-}" ]; then
    parse_word "$(printf '%s' "$brief" | ${CLAUDE_ROUTER_LLM_CMD} 2>/dev/null || true)"
    return
  fi
  if [ -n "${ANTHROPIC_API_KEY:-}" ]; then
    word="$(parse_word "$(api_call)")"
    if [ -n "$word" ]; then printf '%s' "$word"; return; fi
  fi
  if command -v claude >/dev/null 2>&1; then
    parse_word "$(cli_call)"
  fi
}

verdict="$(classify)"
log "${verdict:-none}"

case "$verdict" in
  haiku|sonnet|opus) ;;   # inject below
  *) exit 0 ;;            # keep / unsure / failure -> leave the session default
esac

updated_input="$(printf '%s' "$payload" | jq --arg m "$verdict" '.tool_input + {model:$m}')"

jq -n \
  --argjson ui "$updated_input" \
  --arg msg "🎯 model-router — set this agent's model to ${verdict} (LLM-classified)." \
  --arg ac "model-router set this agent's model to ${verdict}, judged from its brief alone (not the full conversation). If that's wrong for this task, re-spawn the agent with an explicit model." \
  '{systemMessage:$msg, hookSpecificOutput:{hookEventName:"PreToolUse", updatedInput:$ui, additionalContext:$ac}}'
