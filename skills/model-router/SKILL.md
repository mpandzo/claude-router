---
name: model-router
description: How to choose a subagent's model and subagent_type when spawning agents. A modelless subagent inherits the session's model, and a PreToolUse hook auto-routes trivial spawns to a cheaper model — never a pricier one. The rule when you set a model yourself is the same: only ever DOWNGRADE (never cost more than the session is on). Consult when spawning an agent, picking a subagent_type, or fanning out into multiple agents.
---

# Model Router

A subagent spawned without a `model` **inherits the main conversation's model**. So the only cost-relevant lever is passing a *cheaper* model than the session is on — and passing a *pricier* one is a cost increase that this plugin deliberately avoids.

This plugin's `PreToolUse` hook already routes automatically: for any spawn you make without a `model`, it reads the brief, and if the task is clearly simpler than the session's model warrants, it injects a cheaper model — never an upgrade. So the default, correct behaviour is usually to **leave `model` unset and let the hook decide.**

## The one rule

**Never pass a `model` more expensive than the current session's model.** Ranking: `haiku` < `sonnet` < `opus`. Set a model explicitly only to force a *downgrade*; otherwise leave it unset.

- Session on **Opus**: a trivial subtask → `haiku`; a routine/standard subtask → `sonnet`; a genuinely hard subtask → leave unset (stays Opus).
- Session on **Sonnet**: a trivial subtask → `haiku`; anything else → leave unset (stays Sonnet). Do **not** pass `opus`.
- Session on **Haiku**: leave unset (already the cheapest).

When in doubt, leave `model` unset — the hook is conservative and abstains rather than guess, and it can't upgrade.

There are no "escalate to Opus for audits/security" overrides: raising the model above the session's is exactly the cost increase we're avoiding. If a task genuinely needs a stronger model than the session is on, that's a decision for the *session* model (`/model`), not a per-spawn upgrade.

## Choosing `subagent_type`

Independent of the model, match the type to the kind of work:

- **Read-only investigation / search / codebase questions** → `Explore` (no write tools, so it can't misfire on files).
- **Design / architecture / planning, no edits** → `Plan`.
- **Implementation, edits, multi-step execution** → `general-purpose` (full tools). `claude` is an equivalent all-tools catch-all.
- Prefer a specialized project/plugin agent when one clearly matches.

**Never use `subagent_type: "fork"` for routing** — forks always inherit the session's model and ignore any `model` override, so a fork can't be downgraded.

## Fan-out: multiple agents in one prompt

Each spawn is handled independently by the hook. If you set models yourself, apply the one rule to *each* spawn against the session model — a "build the feature and review it" split might send a trivial sub-check to `haiku` while the rest stays at the session default. Never pass a pricier model to any of them.

## Report

If you set a model explicitly, say so in one line so it's auditable — e.g. `Routing → haiku (trivial sub-check)`. If you leave it to the hook, it announces its own pick.
