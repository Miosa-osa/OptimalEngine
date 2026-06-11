# Agentic Loop Design Prompt

Use this when I want to create a repeatable agent loop for code, research,
learning, package generation, wiki refresh, connector sync, or scheduled review.

## Goal

Design a governed loop the agent can run until the task is complete, verified,
or blocked.

## What I Will Provide

I may provide:

- a feature plan
- a checklist
- a workspace or Node
- a research goal
- a package type
- a video/book/article URL
- a codebase
- a failing test or GitHub Action
- a recurring daily/weekly/monthly review goal

## Your Job

1. Identify the loop goal.
2. Identify the owning Workspace and Node.
3. Identify required context sources.
4. Identify allowed tool surfaces: CLI, MCP, API, connector, script, scheduler,
   model call, or A2A agent.
5. Create a checklist with phases.
6. Define validation gates for every phase.
7. Define stop conditions.
8. Define what outputs should become Source Packages, observations, pending
   Claims, packages, exports, workflow traces, or audit records.
9. Identify when human review is required.

## Required Output

Return:

1. Loop summary.
2. Loop YAML.
3. Phase checklist.
4. Validation gates.
5. Tool permissions needed.
6. Stop conditions.
7. Memory/audit outputs.
8. Command or scheduler recommendation.

## Rules

- Do not call the loop done unless validation passes.
- Do not let generated output become Fact directly.
- Do not use MCP when CLI is simpler.
- Do not use CLI when MCP/API/connector is needed for auth, schemas, or writes.
- Do not use A2A unless the other side is another agent.
- Ask before write actions, external sends, purchases, deployments, or
  cross-organization delegation unless policy explicitly allows it.

