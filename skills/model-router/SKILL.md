---
name: model-router
description: Use at the START of a self-contained coding/analysis task to route the actual work to the most cost-effective model. Classifies task complexity, then DELEGATES the work to a subagent spawned on Haiku (trivial), Sonnet (standard), or Opus (architectural/security). ALSO use when a prompt fans out into multiple agents — classify and route each spawned agent's model independently. Skip when the user named a model, mid-multi-turn task, or when the task is a tiny one-liner not worth a subagent hop.
---

# Model Router

Route a task's real work onto the cheapest model that will do it well. This works because the `Agent` tool honors a per-spawn `model` override — the subagent does the bulk token work (reading, editing, testing) on the chosen model, and this session only classifies and relays the result.

This does NOT change the model of the current session. It cannot. The only real lever is delegating work to a subagent with an explicit `model`.

## When to route (and when not to)

Route only when ALL of these hold:
- The task is **self-contained** and can be handed off in one prompt (a subagent starts cold — no shared context).
- The work is **substantial enough** that offloading beats the spawn overhead. A literal one-line edit you already understand: just do it inline, don't route.
- The user did **not** name a model.

Skip routing entirely when:
- The user specified a model ("use opus", "cheap model") → honor that instead (see Overrides).
- You are mid multi-turn task → keep whatever you're already on for consistency.
- The task is genuinely ambiguous → clarify first, then route.

## Step 1 — Classify complexity

Judge the task holistically (this is a heuristic, not arithmetic). Match to the highest tier whose description fits:

| Tier | Model | Fits |
|------|-------|------|
| trivial | `haiku` | typo, rename, format, lint fix, comment/copy edit, single obvious line |
| standard | `sonnet` | bug fix, add a test, small-to-medium feature, single-file refactor, add validation, wire an endpoint |
| complex | `sonnet` | multi-file feature, migration, non-trivial integration — Sonnet handles these well; reserve Opus for genuine design/risk |
| architectural | `opus` | system/API design, major cross-cutting refactor, security audit, anything where a wrong call is expensive to unwind |

## Step 2 — Overrides (win over classification)

- User says "use opus" / "use sonnet" / "use haiku" → that model.
- User says "cheap" / "fast" / "quick" → `haiku`.
- User says "thorough" / "careful" / "audit" → `opus`.
- Security / vulnerability / auth-critical work → `opus`.
- Production deployment / breaking change → `opus`.

## Step 3 — Context nudges (shift one tier)

- Unfamiliar or poorly-documented codebase → bump up one tier (more exploration headroom).
- Critical-path / hard-to-reverse code → bump up one tier.
- Isolated test/mock/fixture code → drop one tier.

## Step 4 — Delegate

Spawn the work with the `Agent` tool, passing the chosen model:

- `model`: the family alias for the tier you picked in Step 1 — `haiku`, `sonnet`, or `opus`. These are exactly the values the `Agent` tool's `model` field accepts, and each resolves to the current version of that family.
- `subagent_type`: pick by the *kind* of work — there is no single "best" type, match it to the task:
  - **Read-only investigation / search / codebase questions** → `Explore` (no write tools, so it can't misfire on files).
  - **Design / architecture / planning, no edits** → `Plan`.
  - **Implementation, edits, multi-step execution** → `general-purpose` (full tools). `claude` is an equivalent all-tools catch-all if `general-purpose` doesn't fit.
  - Prefer a more specialized project/plugin agent when one clearly matches — a named agent's own `model:` frontmatter is overridden by the `model` you pass here.
- `prompt`: a complete, self-contained brief — the subagent has none of this conversation's context.
- Do NOT use `subagent_type: "fork"` for routing — forks always inherit THIS session's model and ignore the override.

## Step 5 — Report

Before spawning, tell the user the routing decision in one line, so it's auditable and honest (the subagent, not this session, runs on that model):

`Routing → <model> (<tier>): <one-clause reason>`

Then relay what the subagent returns (its report is not shown to the user directly).

## Fan-out: multiple agents in one prompt

When a prompt requires launching several agents, there is NO automatic per-agent routing — nothing tags each spawn with a model for you. You must route each one deliberately:

- **Classify each subtask on its own** (Steps 1–3), against what *that* agent will actually do — not against the overall prompt. A "build the feature and audit its security" prompt splits into a `sonnet` implementation agent and an `opus` audit agent; don't pick one tier for the whole thing.
- **Pass the matching `model` on every `Agent` call.** A model omitted on any spawn means that agent inherits THIS session's model — usually the expensive default — silently defeating the routing.
- **Match `subagent_type` per agent too** (Step 4's mapping): the explorer that gathers context → `Explore`, the implementer → `general-purpose`, the planner → `Plan`.
- **Never route a `fork`.** Forks always inherit this session's model regardless of the `model` you pass, so a fan-out built on forks is entirely unrouted. Use real subagent types when you want per-agent models.
- **Report one line per agent** before spawning, e.g.:
  - `Routing → sonnet (standard, general-purpose): implement the endpoint`
  - `Routing → opus (architectural, general-purpose): security-audit the endpoint`

If the agents run in parallel, spawn them in a single batch with each carrying its own `model` — the override is per-call, so parallel spawns are routed independently.
