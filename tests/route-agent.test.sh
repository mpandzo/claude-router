#!/usr/bin/env bash
# Hermetic tests for route-agent.sh — no network, no real `claude`.
# The classifier is stubbed via CLAUDE_ROUTER_LLM_CMD and the inherited model is
# faked via a CLAUDE_PLUGIN_DATA file, so every branch is deterministic.
# Backend behaviour (API / claude -p / timeouts) is validated manually.
#
# Run: bash tests/route-agent.test.sh   (exits non-zero if any test fails)

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$HERE/../hooks/route-agent.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export CLAUDE_ROUTER_LOG="$TMP/log"
export CLAUDE_PLUGIN_DATA="$TMP"          # where the inherited-model file lives
export ANTHROPIC_API_KEY="test-key-unused" # non-empty so real .env is never read
SID="test-session"

pass=0; fail=0
assert_eq() { if [ "$2" = "$3" ]; then printf 'ok   - %s\n' "$1"; pass=$((pass+1));
              else printf 'FAIL - %s (want=%q got=%q)\n' "$1" "$3" "$2"; fail=$((fail+1)); fi; }

inherited() { if [ -z "$1" ]; then rm -f "$TMP/model-$SID"; else printf '%s\n' "$1" > "$TMP/model-$SID"; fi; }
payload() { printf '{"tool_name":"Agent","session_id":"%s","tool_input":%s}' "$SID" "$1"; }
model_of() { local o; o="$(cat)"; if [ -z "$o" ]; then echo "NONE"; else printf '%s' "$o" | jq -r '.hookSpecificOutput.updatedInput.model // "NONE"' 2>/dev/null; fi; }
mock() { local f="$TMP/mock.sh"; printf 'cat >/dev/null; printf "%%s" %q\n' "$1" > "$f"; chmod +x "$f"; printf '%s' "$f"; }
# run <tool_input_json> <verdict> [extra env assignments...]
run() { local ti="$1" v="$2"; shift 2; env "$@" CLAUDE_ROUTER_LLM_CMD="$(mock "$v")" bash "$HOOK" <<<"$(payload "$ti")"; }
BRIEF='{"subagent_type":"general-purpose","prompt":"do the task"}'

# --- skip conditions --------------------------------------------------------
inherited opus
assert_eq "explicit model is left untouched" "$(run '{"model":"opus","prompt":"x"}' haiku; echo -n E)" "E"
assert_eq "fork is left untouched"           "$(run '{"subagent_type":"fork","prompt":"x"}' haiku; echo -n E)" "E"
assert_eq "empty brief is left untouched"    "$(run '{"subagent_type":"general-purpose"}' haiku; echo -n E)" "E"

# --- inherited UNKNOWN: only Haiku applies ----------------------------------
inherited ""
assert_eq "unknown inherited: haiku applies"  "$(run "$BRIEF" haiku  | model_of)" "haiku"
assert_eq "unknown inherited: sonnet no-op"   "$(run "$BRIEF" sonnet | model_of)" "NONE"
assert_eq "unknown inherited: opus no-op"     "$(run "$BRIEF" opus   | model_of)" "NONE"

# --- inherited OPUS: downgrades apply ---------------------------------------
inherited opus
assert_eq "parent opus: haiku applies (downgrade)"  "$(run "$BRIEF" haiku  | model_of)" "haiku"
assert_eq "parent opus: sonnet applies (downgrade)" "$(run "$BRIEF" sonnet | model_of)" "sonnet"
assert_eq "parent opus: opus is a no-op"            "$(run "$BRIEF" opus   | model_of)" "NONE"

# --- inherited SONNET: only Haiku is a downgrade; opus needs opt-in ----------
inherited sonnet
assert_eq "parent sonnet: haiku applies"            "$(run "$BRIEF" haiku  | model_of)" "haiku"
assert_eq "parent sonnet: sonnet is a no-op"        "$(run "$BRIEF" sonnet | model_of)" "NONE"
assert_eq "parent sonnet: opus blocked (upgrade)"   "$(run "$BRIEF" opus   | model_of)" "NONE"
assert_eq "parent sonnet: opus applies with ALLOW"  "$(run "$BRIEF" opus CLAUDE_ROUTER_ALLOW_OPUS=1 | model_of)" "opus"

# --- inherited full model id (substring match) ------------------------------
inherited "claude-opus-5-20260101"
assert_eq "full opus id: sonnet applies (downgrade)" "$(run "$BRIEF" sonnet | model_of)" "sonnet"

# --- abstention -------------------------------------------------------------
inherited opus
assert_eq "verdict 'keep' abstains"          "$(run "$BRIEF" keep  | model_of)" "NONE"
assert_eq "unparseable verdict abstains"     "$(run "$BRIEF" dunno | model_of)" "NONE"

# --- transparency + field preservation (an applied case) --------------------
inherited opus
out="$(run '{"subagent_type":"general-purpose","prompt":"rename a var"}' haiku)"
assert_eq "additionalContext emitted" "$(printf '%s' "$out" | jq -r 'if .hookSpecificOutput.additionalContext then "y" else "n" end')" "y"
assert_eq "systemMessage emitted"     "$(printf '%s' "$out" | jq -r 'if .systemMessage then "y" else "n" end')" "y"
assert_eq "other tool_input preserved" "$(printf '%s' "$out" | jq -r '.hookSpecificOutput.updatedInput.prompt')" "rename a var"

# --- reentrancy guard -------------------------------------------------------
assert_eq "reentrancy guard no-ops" \
  "$(CLAUDE_ROUTER_CLASSIFYING=1 CLAUDE_ROUTER_LLM_CMD="$(mock haiku)" bash "$HOOK" <<<"$(payload "$BRIEF")" || true; echo -n E)" "E"

# --- telemetry --------------------------------------------------------------
grep -q $'\thaiku\t' "$CLAUDE_ROUTER_LOG"; assert_eq "telemetry has a haiku entry" "$?" "0"
grep -q $'\tkeep\t'  "$CLAUDE_ROUTER_LOG"; assert_eq "telemetry has a keep entry"  "$?" "0"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
