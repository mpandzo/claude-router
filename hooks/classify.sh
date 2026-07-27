#!/usr/bin/env bash
# Shared keyword classifier for claude-router.
#
# Reads raw prompt text on stdin. Prints a single tab-separated line
# "<model>\t<tier>\t<reason>" when a signal matches, or nothing (exit 0)
# when classification is inconclusive.

set -euo pipefail

prompt="$(tr '[:upper:]' '[:lower:]')"
[ -n "${prompt//[[:space:]]/}" ] || exit 0

match() { printf '%s' "$prompt" | grep -Eq "$1"; }

model=""; tier=""; reason=""

# Base classification. Later blocks escalate over earlier ones.
if match 'typo|rename|reformat|format |lint|indent|whitespace|spelling|copy edit'; then
  model="haiku"; tier="trivial"; reason="mechanical edit"
fi
if match 'bug|add (a )?test|validation|refactor function|small feature'; then
  model="sonnet"; tier="standard"; reason="standard code change"
fi
if match 'multi-file|multiple files|migration|integration|new feature|endpoint|\bapi\b'; then
  model="sonnet"; tier="complex"; reason="multi-file / feature work"
fi
if match 'architect|system design|security|audit|vulnerab|major refactor|breaking change|performance'; then
  model="opus"; tier="architectural"; reason="design / risk / security"
fi

# Explicit overrides win outright.
if match 'use opus|thorough|be careful|carefully'; then
  model="opus"; tier="architectural"; reason="explicit: thorough/opus"
elif match 'use haiku|cheap|quick fix|be fast|minimi[sz]e cost'; then
  model="haiku"; tier="trivial"; reason="explicit: cheap/fast"
elif match 'use sonnet'; then
  model="sonnet"; tier="standard"; reason="explicit: sonnet"
fi

[ -n "$model" ] || exit 0
printf '%s\t%s\t%s\n' "$model" "$tier" "$reason"
