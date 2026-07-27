# claude-router

A Claude Code plugin that classifies task complexity and facilitates running subagent work on a cost-appropriate Claude model (Haiku / Sonnet / Opus) rather than always the session default.

## What it does

- **`model-router` skill** — at the start of a self-contained task, or when a prompt fans out into multiple agents, classifies complexity and delegates the work to a subagent spawned on the matching model (Haiku / Sonnet / Opus). A subagent's `model` is set per spawn, which is where the cost is actually moved.
- **`PreToolUse` hook (Agent)** — fires when an agent is about to spawn. If the spawn names no model, isn't a fork, and has a non-empty brief, an **LLM reads the brief and names the model** (haiku / sonnet / opus), which is injected via `updatedInput`. There's no keyword heuristic — the LLM judges the actual work. Explicit models, forks, and empty briefs are left untouched; if classification fails, the spawn keeps the session default.

Model selection happens through the subagent `model` override (the skill and the PreToolUse hook) or `/model` (manual). The current session's own model is not changed.

## Configuration (env vars)

The classifier LLM runs on **every** modelless spawn, via one of two backends:

1. **Anthropic API** (`curl`) when `ANTHROPIC_API_KEY` is set — fast and isolated. The first-party API needs only the key (sent as `x-api-key`); there is no separate "secret".
2. **`claude -p --model haiku`** otherwise — reuses your existing Claude Code auth, no key needed, but heavier (spawns a nested CLI). If the API path errors, it also falls back here when `claude` is available.

Note: when `ANTHROPIC_API_KEY` is set, the `claude -p` fallback inherits it too, so an invalid key fails both backends (routing then no-ops).

| Var | Effect |
|-----|--------|
| `ANTHROPIC_API_KEY` | Enables the API backend. Only the key is needed (no secret). |
| `CLAUDE_ROUTER_API_MODEL` | Model id for the API call (default `claude-haiku-4-5-20251001`). |
| `CLAUDE_ROUTER_LLM_TIMEOUT` | Seconds to wait on either backend (default 30). On timeout, the spawn keeps the session default. |
| `CLAUDE_ROUTER_LLM_CMD` | Override the classifier command (reads the brief on stdin, prints a word); mainly for testing. |
| `CLAUDE_ROUTER_CLASSIFYING` | Set internally around the CLI call so the nested `claude` doesn't re-trigger this hook; not for manual use. |

The CLI fallback uses a portable timeout: `timeout`/`gtimeout` if present (stock macOS has neither), otherwise a built-in fallback — no dependency required.

## Components

```
claude-router/
├── .claude-plugin/
│   ├── plugin.json              # plugin manifest
│   └── marketplace.json         # marketplace manifest
├── skills/model-router/SKILL.md # the router skill
└── hooks/
    ├── hooks.json      # registers the PreToolUse hook
    └── route-agent.sh  # PreToolUse: LLM-classifies the brief, injects a model
```

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
