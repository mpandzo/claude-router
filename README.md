# claude-router

A Claude Code plugin that routes delegated agent work to a cost-appropriate model (Haiku / Sonnet / Opus) instead of always the session default. An LLM classifies each spawn's brief, and the verdict is applied only when it's **cheaper** than what the agent would otherwise inherit — never an upgrade.

## Install

```
/plugin marketplace add <owner>/claude-router
/plugin install claude-router@claude-router
```

For local development, point the marketplace at the checkout (`/plugin marketplace add <path>`), or skip the marketplace entirely with `claude --plugin-dir <path>`.

## How it works

- **`SessionStart` hook** — records the main conversation's model: the baseline for "cheaper".
- **`PreToolUse` hook (Agent)** — on a spawn with no `model`, no `fork`, and a non-empty brief, an LLM reads the brief and replies `haiku` / `sonnet` / `opus` / `keep`. No keyword heuristics — it judges the actual work. The pick is reported to you via `systemMessage` and back to the assistant via `additionalContext`, so it can re-spawn with an explicit model if the routing is wrong.
- **`model-router` skill** — guidance for the assistant when it spawns agents itself: leave `model` unset and let the hook route; if you do set one, only ever pass something cheaper than the session's model. It mirrors the hook's rule so the two can't disagree.

**Never an upgrade.** A modelless agent inherits the session's model, so injecting a pricier one would *raise* cost. Only a strictly cheaper verdict is applied (on an Opus session: trivial → Haiku, standard → Sonnet). An equal verdict, `keep`, unsure, and failure all change nothing; `opus` as an upgrade needs `CLAUDE_ROUTER_ALLOW_OPUS`; an unknown baseline means Haiku-only, the one model that can't cost more than anything. The session's own model is never touched — that's `/model`.

The classifier is instructed via a **system prompt**, which improves obedience and hardens against a brief trying to steer it. On the CLI backend that prompt also replaces the default agentic one and tools are disabled, so it classifies rather than acts on the brief.

## What gets routed

The matcher is the `Agent` tool, so **every** agent spawned through it is covered: built-in types (`general-purpose`, `Explore`, `Plan`, …), custom `.claude/agents` or plugin agents, skill-launched spawns, background and worktree/remote-isolated agents, and nested fan-outs (where the baseline stays the *session* model, not the spawning agent's).

Untouched: spawns that already name a `model` (an explicit choice wins), `subagent_type: "fork"` (forks ignore `model` overrides), the main session, and any environment where the plugin isn't loaded.

For custom agents, note that a per-spawn `model` overrides an agent definition's `model:` frontmatter — and so can the hook's verdict, which is judged against the session model rather than the pin. Pass the model explicitly if the pin matters.

## Configuration

The classifier runs on every modelless spawn, via one of two backends:

1. **Anthropic API** (`curl`) when `ANTHROPIC_API_KEY` is set — fast and isolated; only the key is needed (sent as `x-api-key`), there is no separate "secret".
2. **`claude -p --model haiku`** otherwise — reuses your existing Claude Code OAuth, no key needed. It runs stripped down (`--strict-mcp-config`, no tools) but still boots a nested CLI, so it's slower and **can time out under a parallel fan-out**; prefer setting a key. It's also the fallback if the API path errors, which means an *invalid* key fails both backends (routing then no-ops).

The key is resolved from the environment, then `<plugin>/.env` (git-ignored, for `--plugin-dir` dev), then `~/.claude/claude-router.env` — first hit wins. Only the `ANTHROPIC_API_KEY` line is read; the files are never executed. A marketplace install lives in a cache dir with no `.env`, so supply the key via the environment (`~/.zshrc`, or `~/.claude/settings.json` → `{ "env": { ... } }`) or the user-level file.

| Var | Effect |
|-----|--------|
| `ANTHROPIC_API_KEY` | Enables the API backend. Only the key is needed (no secret). |
| `CLAUDE_ROUTER_API_MODEL` | Model id for the API call (default `claude-haiku-4-5-20251001`). |
| `CLAUDE_ROUTER_ALLOW_OPUS` | Set to also apply an `opus` verdict when it's an upgrade. Off by default. |
| `CLAUDE_ROUTER_LLM_TIMEOUT` | Seconds to wait on either backend (default 30). On timeout the spawn keeps the session default. |
| `CLAUDE_ROUTER_LOG` | Telemetry log path (default `~/.claude/claude-router.log`; `/dev/null` to disable). |
| `CLAUDE_ROUTER_LLM_CMD` | Override the classifier command (brief on stdin, prints a word); mainly for testing. |
| `CLAUDE_ROUTER_CLASSIFYING` | Set internally around the CLI call so the nested `claude` doesn't re-trigger the hook; not for manual use. |

The CLI fallback's timeout is portable: `timeout`/`gtimeout` if present (stock macOS has neither), otherwise a built-in fallback — no dependency required.

**The baseline.** PreToolUse hooks don't receive the session model, so `SessionStart` writes it to `$CLAUDE_PLUGIN_DATA/model-<session_id>` (falling back to `~/.claude/claude-router/`) and the router reads it back by `session_id`. Two caveats: the field isn't guaranteed at SessionStart (then the baseline is unknown → Haiku-only), and it isn't refreshed by a mid-session `/model`, so it can go stale until the next session start.

**Telemetry.** Every classification appends a tab-separated `<UTC timestamp>\t<verdict>\t<brief snippet>` to the log, where `verdict` is the injected model, `keep`, or `none`. Check the distribution — which models, how often it abstains — before trusting the routing. The path is `$HOME`-anchored regardless of install method; delete it or point `CLAUDE_ROUTER_LOG` at `/dev/null` to opt out.

## Layout and tests

```
.claude-plugin/{plugin,marketplace}.json   manifests
skills/model-router/SKILL.md               the skill
hooks/hooks.json                           registers both hooks
hooks/capture-model.sh                     SessionStart: record the baseline
hooks/route-agent.sh                       PreToolUse: classify, inject a cheaper model
tests/route-agent.test.sh                  hermetic tests
```

```
bash tests/route-agent.test.sh
```

Hermetic — the classifier is stubbed via `CLAUDE_ROUTER_LLM_CMD`, so no network or real `claude` is needed. It covers the skip conditions, injection, abstention, the reentrancy guard, transparency output, and telemetry. Backend behaviour (API, `claude -p`, timeouts) is validated manually.
