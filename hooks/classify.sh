#!/usr/bin/env bash
# Shared keyword classifier for claude-router.
#
# Usage: classify.sh [--with-overrides | --agent] < text
#   Reads raw text on stdin. Prints "<model>\t<tier>\t<reason>" when it can
#   classify, or nothing (exit 0) when inconclusive.
#
#   --with-overrides  (suggest-tier) enables user-intent overrides ("use opus",
#       "cheap", "thorough"). These express what the USER wants and are meaningful
#       only for the user's own prompt — never for a generated agent brief, where
#       words like "carefully" appear incidentally.
#   --agent  (route-agent) applies the conservative-downgrade policy: it will
#       RAISE a spawn to Opus on a genuine architectural/high-stakes signal, but
#       only downgrades to a cheaper model when the brief shows NO complexity
#       signals at all. If any complex/architectural signal is present but didn't
#       win, it stays silent so the spawn keeps the session default rather than
#       being risked onto a weaker model on brittle keyword evidence.
#
# Design notes (learned the hard way):
#   - Path/filename tokens are stripped first, so a filename like
#     cart-validation.md can't be read as intent.
#   - Every single-word signal is word-boundaried (\b), so substrings don't match.
#   - Tiers are chosen by how many signals hit, NOT by "highest tier that matched".
#     Ties resolve to the CHEAPER tier, so one stray keyword in a long brief
#     can't ratchet everything up to Opus.
#   - "audit"/"security"/"performance" alone are NOT architectural — a doc audit
#     is not a security audit. Architectural needs an explicit phrase.

set -euo pipefail

mode="base"
case "${1:-}" in
  --with-overrides) mode="overrides" ;;
  --agent)          mode="agent" ;;
esac

raw="$(tr '[:upper:]' '[:lower:]')"

# Strip path tokens (anything with a slash) and filename tokens (name.ext) so
# paths and quoted filenames don't count as intent.
text="$(printf '%s' "$raw" \
  | sed -E 's#[^[:space:]]*/[^[:space:]]*# #g; s#[[:alnum:]_-]+\.[[:alnum:]]+# #g')"

[ -n "${text//[[:space:]]/}" ] || exit 0

# Signal sets. Single words are \b-bounded; multi-word phrases are specific
# enough to match as-is.
# NOTE: "format" and "typo" are deliberately excluded. They are meta-language —
# "## Output format" headings and "check for typos" instructions are boilerplate
# in structured agent briefs, and matching them classifies the brief's wrapper
# rather than the work itself (which silently downgraded real research agents).
P_TRIVIAL='\b(rename|reformat|lint|indent|whitespace|spelling)\b'
P_STANDARD='\b(bug|bugs|validation)\b|\badd(ing)? (a |an )?tests?\b|\bunit tests?\b|refactor (this )?function|small (feature|change|refactor)'
P_COMPLEX='\b(migration|integration|endpoint)\b|\bapi\b|multi-file|multiple files|new feature'
P_ARCH='system design|\barchitecture\b|\barchitect\b|major refactor|large refactor|breaking change|security (audit|review|issue|fix|hardening)|\bvulnerabilit|threat model|\bperformance\b'
# High-stakes subset: counted a SECOND time so it wins ties (weight 2). Missing a
# genuine security/breaking-change signal is the costly error, so these beat a
# co-occurring lower-tier word. Ordinary architectural words stay weight 1 and
# still lose ties.
P_ARCH_HIGH='security (audit|review|issue|fix|hardening)|\bvulnerabilit|threat model|breaking change'

hits() { printf '%s' "$text" | { grep -Eo "$1" || true; } | wc -l | tr -d ' '; }

ct=$(hits "$P_TRIVIAL"); cs=$(hits "$P_STANDARD")
cc=$(hits "$P_COMPLEX");  ca=$(( $(hits "$P_ARCH") + $(hits "$P_ARCH_HIGH") ))

# Pick the tier with the most signal hits. Evaluate cheapest -> priciest with a
# STRICT >, so equal counts keep the cheaper tier.
tier=""; best=0
consider() { if [ "$1" -gt "$best" ]; then best="$1"; tier="$2"; fi; }
consider "$ct" trivial
consider "$cs" standard
consider "$cc" complex
consider "$ca" architectural

reason=""
case "$tier" in
  trivial)       reason="low-complexity task" ;;
  standard)      reason="routine task" ;;
  complex)       reason="broad / multi-part task" ;;
  architectural) reason="design / risk / security" ;;
esac

# User-intent overrides win outright — only when reading the user's own prompt.
if [ "$mode" = "overrides" ]; then
  om() { printf '%s' "$text" | grep -Eq "$1"; }
  if om '\buse opus\b|\bthorough(ly)?\b|\bcarefully\b|\bbe careful\b'; then
    tier=architectural; reason="explicit: thorough/opus"
  elif om '\buse haiku\b|\bcheap\b|\bquick fix\b|\bbe fast\b|minimi[sz]e cost'; then
    tier=trivial; reason="explicit: cheap/fast"
  elif om '\buse sonnet\b'; then
    tier=standard; reason="explicit: sonnet"
  fi
fi

# Conservative-downgrade policy for agent spawns: allow raising to Opus, but only
# downgrade when there is NO complexity signal at all. If a complex/architectural
# signal is present but a cheaper tier won on count, stay silent (keep default).
if [ "$mode" = "agent" ] && [ "$tier" != "architectural" ]; then
  if [ "$cc" -gt 0 ] || [ "$ca" -gt 0 ]; then exit 0; fi
fi

[ -n "$tier" ] || exit 0

case "$tier" in
  trivial)       model=haiku ;;
  standard)      model=sonnet ;;
  complex)       model=sonnet ;;
  architectural) model=opus ;;
esac

printf '%s\t%s\t%s\n' "$model" "$tier" "$reason"
