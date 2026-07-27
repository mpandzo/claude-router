# claude-router

A Claude Code plugin that classifies task complexity and facilitates running subagent work on a cost-appropriate Claude model (Haiku / Sonnet / Opus) rather than always the session default.

## What it does

- **`model-router` skill** — at the start of a self-contained task, or when a prompt fans out into multiple agents, classifies complexity and delegates the work to a subagent spawned on the matching model (Haiku / Sonnet / Opus). A subagent's `model` is set per spawn, which is where the cost is actually moved.
- **`UserPromptSubmit` hook** — surfaces an advisory suggested tier on each prompt (e.g. `🎯 model-router: standard (sonnet) — ...`).
- **`PreToolUse` hook (Agent/Task)** — fires when an agent is about to spawn. If the spawn names no model and isn't a fork, it classifies the brief and may inject a model. It is conservative: it raises to Opus on genuine high-stakes signals, but only downgrades to a cheaper model when the brief shows no complexity signals at all — otherwise it leaves the session default untouched. Explicit models and forks are never changed.

Model selection happens through the subagent `model` override (the skill and the PreToolUse hook) or `/model` (manual). The current session's own model is not changed.

## Components

```
claude-router/
├── .claude-plugin/
│   ├── plugin.json              # plugin manifest
│   └── marketplace.json         # marketplace manifest
├── skills/model-router/SKILL.md # the router skill
└── hooks/
    ├── hooks.json      # registers the UserPromptSubmit + PreToolUse hooks
    ├── classify.sh     # shared keyword classifier
    ├── suggest-tier.sh # UserPromptSubmit: advisory tier suggestion
    └── route-agent.sh  # PreToolUse: injects a model on agent spawns
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
