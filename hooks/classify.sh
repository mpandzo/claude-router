#!/usr/bin/env bash
# Shared keyword classifier for claude-router.
#
# Usage: classify.sh [--with-overrides] < text
#   Reads raw text on stdin. Prints "<model>\t<tier>\t<reason>" when it can
#   classify, or nothing (exit 0) when inconclusive.
#
#   --with-overrides enables user-intent overrides ("use opus", "cheap",
#   "thorough"). These express what the USER wants and are meaningful only for
#   the user's own prompt — never for a generated agent brief, where words like
#   "carefully" appear incidentally. route-agent therefore omits the flag.
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

overrides=0
if [ "${1:-}" = "--with-overrides" ]; then overrides=1; fi

raw="$(tr '[:upper:]' '[:lower:]')"

# Strip path tokens (anything with a slash) and filename tokens (name.ext) so
# paths and quoted filenames don't count as intent.
text="$(printf '%s' "$raw" \
  | sed -E 's#[^[:space:]]*/[^[:space:]]*# #g; s#[[:alnum:]_-]+\.[[:alnum:]]+# #g')"

[ -n "${text//[[:space:]]/}" ] || exit 0

# Signal sets. Single words are \b-bounded; multi-word phrases are specific
# enough to match as-is.
P_TRIVIAL='\b(typo|typos|rename|reformat|lint|indent|whitespace|spelling)\b|\bformat\b'
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
  trivial)       reason="mechanical edit" ;;
  standard)      reason="standard code change" ;;
  complex)       reason="multi-file / feature work" ;;
  architectural) reason="design / risk / security" ;;
esac

# User-intent overrides win outright — only when reading the user's own prompt.
if [ "$overrides" -eq 1 ]; then
  om() { printf '%s' "$text" | grep -Eq "$1"; }
  if om '\buse opus\b|\bthorough(ly)?\b|\bcarefully\b|\bbe careful\b'; then
    tier=architectural; reason="explicit: thorough/opus"
  elif om '\buse haiku\b|\bcheap\b|\bquick fix\b|\bbe fast\b|minimi[sz]e cost'; then
    tier=trivial; reason="explicit: cheap/fast"
  elif om '\buse sonnet\b'; then
    tier=standard; reason="explicit: sonnet"
  fi
fi

[ -n "$tier" ] || exit 0

case "$tier" in
  trivial)       model=haiku ;;
  standard)      model=sonnet ;;
  complex)       model=sonnet ;;
  architectural) model=opus ;;
esac

printf '%s\t%s\t%s\n' "$model" "$tier" "$reason"
