# claude-router

A Claude Code plugin that classifies task complexity and facilitates running subagent work on a cost-appropriate Claude model (Haiku / Sonnet / Opus) rather than always the session default.

## What it does

- **`model-router` skill** — at the start of a self-contained task, or when a prompt fans out into multiple agents, classifies complexity and delegates the work to a subagent spawned on the matching model (Haiku / Sonnet / Opus). A subagent's `model` is set per spawn, which is where the cost is actually moved.
- **`PreToolUse` hook (Agent)** — fires when an agent is about to spawn. If the spawn names no model, isn't a fork, and has a non-empty brief, an **LLM reads the brief** (the full task the subagent will act on) and replies `haiku` / `sonnet` / `opus` / `keep`. A named model is injected via `updatedInput`; **`keep` (or any unsure/failed reply) abstains** and leaves the session default. There's no keyword heuristic — the LLM judges the actual work. The decision is also surfaced back to the assistant via `additionalContext` (so it can re-spawn with an explicit model if the routing is wrong) and to you via `systemMessage`.

Model selection happens through the subagent `model` override (the skill and the PreToolUse hook) or `/model` (manual). The current session's own model is not changed.

The classifier is instructed via a **system prompt** (not the user turn), which both improves obedience and hardens against a brief trying to steer it. On the CLI backend the system prompt also replaces the default agentic prompt and tools are disabled, so it classifies rather than acts on the brief.

## Configuration (env vars)

The classifier LLM runs on **every** modelless spawn, via one of two backends:

1. **Anthropic API** (`curl`) when `ANTHROPIC_API_KEY` is set — fast and isolated. The first-party API needs only the key (sent as `x-api-key`); there is no separate "secret".
2. **`claude -p --model haiku`** otherwise — reuses your existing Claude Code auth, no key needed, but heavier (spawns a nested CLI). If the API path errors, it also falls back here when `claude` is available.

Note: when `ANTHROPIC_API_KEY` is set, the `claude -p` fallback inherits it too, so an invalid key fails both backends (routing then no-ops).

### Where the API key comes from

The key is resolved in this order (first hit wins):

1. The **environment** — `ANTHROPIC_API_KEY`.
2. `<plugin>/.env` — convenient for local `--plugin-dir` development (git-ignored).
3. `~/.claude/claude-router.env` — a stable user-level file.

Only the `ANTHROPIC_API_KEY` line is read; the files are never executed.

**From a marketplace install** the plugin lives in a cache dir, so `<plugin>/.env` isn't present. Supply the key via the environment or the user-level file instead:
- `export ANTHROPIC_API_KEY=...` in `~/.zshrc`, or
- `~/.claude/settings.json` → `{ "env": { "ANTHROPIC_API_KEY": "..." } }` (user-level, not committed), or
- `~/.claude/claude-router.env` containing `ANTHROPIC_API_KEY=...`.

### Variables

| Var | Effect |
|-----|--------|
| `ANTHROPIC_API_KEY` | Enables the API backend. Only the key is needed (no secret). |
| `CLAUDE_ROUTER_API_MODEL` | Model id for the API call (default `claude-haiku-4-5-20251001`). |
| `CLAUDE_ROUTER_LLM_TIMEOUT` | Seconds to wait on either backend (default 30). On timeout, the spawn keeps the session default. |
| `CLAUDE_ROUTER_LOG` | Telemetry log path (default `~/.claude/claude-router.log`; set to `/dev/null` to disable). |
| `CLAUDE_ROUTER_LLM_CMD` | Override the classifier command (reads the brief on stdin, prints a word); mainly for testing. |
| `CLAUDE_ROUTER_CLASSIFYING` | Set internally around the CLI call so the nested `claude` doesn't re-trigger this hook; not for manual use. |

The CLI fallback uses a portable timeout: `timeout`/`gtimeout` if present (stock macOS has neither), otherwise a built-in fallback — no dependency required.

### Telemetry

Every classification appends a tab-separated line to the log — `<UTC timestamp>\t<verdict>\t<brief snippet>` — where `verdict` is the injected model, `keep`, or `none`. Use it to see whether routing is actually helping (distribution of models, how often it abstains) before trusting it. Delete or `/dev/null` the log to opt out.

## Components

```
claude-router/
├── .claude-plugin/
│   ├── plugin.json              # plugin manifest
│   └── marketplace.json         # marketplace manifest
├── skills/model-router/SKILL.md # the router skill
├── hooks/
│   ├── hooks.json      # registers the PreToolUse hook
│   └── route-agent.sh  # PreToolUse: LLM-classifies the brief, injects a model
└── tests/
    └── route-agent.test.sh  # hermetic tests (mocked classifier, no network)
```

## Testing

```
bash tests/route-agent.test.sh
```

Hermetic — the classifier is stubbed via `CLAUDE_ROUTER_LLM_CMD`, so no network or real `claude` is needed. It covers the skip conditions, injection, abstention, the reentrancy guard, transparency output, and telemetry. Backend behaviour (API, `claude -p`, timeouts) is validated manually.

## Install

Add a marketplace pointing at this repo, then install the plugin:

```
/plugin marketplace add <owner>/claude-router
/plugin install claude-router@claude-router
```

For local development, point the marketplace at the checkout directory instead:

```
/plugin marketplace add <path-to-this-repo>
/plugin install claude-router@claude-router
```

Or load the checkout directly at launch, without registering a marketplace:

```
claude --plugin-dir <path-to-this-repo>
```

## Classification tiers

See `skills/model-router/SKILL.md` for the full tiers, overrides, context nudges, and the delegation and fan-out steps.
