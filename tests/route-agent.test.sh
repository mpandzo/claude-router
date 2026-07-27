#!/usr/bin/env bash
# Hermetic tests for route-agent.sh — no network, no real `claude`.
# The classifier is stubbed via CLAUDE_ROUTER_LLM_CMD, so every branch is
# deterministic. Backend behaviour (API / claude -p / timeouts) is validated
# manually; see README.
#
# Run: bash tests/route-agent.test.sh   (exits non-zero if any test fails)

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$HERE/../hooks/route-agent.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export CLAUDE_ROUTER_LOG="$TMP/log"
# Non-empty so the real .env is never read; unused because the mock short-circuits.
export ANTHROPIC_API_KEY="test-key-unused"

pass=0; fail=0
assert_eq() { if [ "$2" = "$3" ]; then printf 'ok   - %s\n' "$1"; pass=$((pass+1));
              else printf 'FAIL - %s (want=%q got=%q)\n' "$1" "$3" "$2"; fail=$((fail+1)); fi; }

payload() { printf '{"tool_name":"Agent","tool_input":%s}' "$1"; }
model_of() { jq -r '.hookSpecificOutput.updatedInput.model // "NONE"' 2>/dev/null; }
mock() { local f="$TMP/mock.sh"; printf 'cat >/dev/null; printf "%%s" %q\n' "$1" > "$f"; chmod +x "$f"; printf '%s' "$f"; }
run() { CLAUDE_ROUTER_LLM_CMD="$(mock "$2")" bash "$HOOK" <<<"$(payload "$1")"; }

# --- skip conditions --------------------------------------------------------
out="$(run '{"model":"opus","prompt":"rename a var"}' sonnet)"
assert_eq "explicit model is left untouched" "${out:-EMPTY}" "EMPTY"

out="$(run '{"subagent_type":"fork","prompt":"rename a var"}' sonnet)"
assert_eq "fork is left untouched" "${out:-EMPTY}" "EMPTY"

out="$(run '{"subagent_type":"general-purpose"}' sonnet)"
assert_eq "empty brief is left untouched" "${out:-EMPTY}" "EMPTY"

# --- injection --------------------------------------------------------------
out="$(run '{"subagent_type":"general-purpose","prompt":"rename a var"}' sonnet)"
assert_eq "mock sonnet injects sonnet" "$(printf '%s' "$out" | model_of)" "sonnet"
assert_eq "additionalContext is emitted (transparency)" \
  "$(printf '%s' "$out" | jq -r 'if .hookSpecificOutput.additionalContext then "yes" else "no" end')" "yes"
assert_eq "systemMessage is emitted (user visibility)" \
  "$(printf '%s' "$out" | jq -r 'if .systemMessage then "yes" else "no" end')" "yes"
assert_eq "other tool_input fields are preserved" \
  "$(printf '%s' "$out" | jq -r '.hookSpecificOutput.updatedInput.prompt')" "rename a var"

# --- abstention (#1) --------------------------------------------------------
out="$(run '{"subagent_type":"general-purpose","prompt":"rename a var"}' keep)"
assert_eq "verdict 'keep' abstains (no injection)" "${out:-EMPTY}" "EMPTY"

out="$(run '{"subagent_type":"general-purpose","prompt":"rename a var"}' dunno)"
assert_eq "unparseable verdict abstains" "${out:-EMPTY}" "EMPTY"

# --- reentrancy guard -------------------------------------------------------
out="$(CLAUDE_ROUTER_CLASSIFYING=1 CLAUDE_ROUTER_LLM_CMD="$(mock sonnet)" bash "$HOOK" <<<"$(payload '{"subagent_type":"general-purpose","prompt":"rename a var"}')")"
assert_eq "reentrancy guard makes it a no-op" "${out:-EMPTY}" "EMPTY"

# --- telemetry (#5) ---------------------------------------------------------
assert_eq "telemetry logged the injected model" "$(grep -c $'\tsonnet\t' "$CLAUDE_ROUTER_LOG")" "$(grep -c $'\tsonnet\t' "$CLAUDE_ROUTER_LOG")"
grep -q $'\tsonnet\t' "$CLAUDE_ROUTER_LOG"; assert_eq "telemetry contains a sonnet entry" "$?" "0"
grep -q $'\tkeep\t' "$CLAUDE_ROUTER_LOG"; assert_eq "telemetry contains a keep entry" "$?" "0"

# --- summary ----------------------------------------------------------------
printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
