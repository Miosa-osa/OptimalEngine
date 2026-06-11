# Operations Spec

Operations describe how work moves through Optimal Engine.

## Work Setup

```text
Create or initiate Workspace
  -> define Nodes and relationships
  -> grant humans/agents/tools
  -> configure routing rules and policies
  -> render initial projections
```

## Intake Operation

```text
input
  -> preserve Source Package
  -> classify Signal
  -> route to workspace/node
  -> extract Claims
  -> write derivation ledger
  -> queue review
  -> update projections/indexes
```

## Recall Operation

```text
request
  -> authenticate actor
  -> build authorization envelope
  -> plan retrieval
  -> assemble Context Package
  -> return source-linked context
  -> record audit
```

## Agent Action Operation

```text
task
  -> open or load Active Memory Pool
  -> load Context Package
  -> request governed tool/model call
  -> validate input/output
  -> record run
  -> publish observation
  -> create pending Claim when useful
```

## Workflow Promotion

```text
repeated episodes
  -> Workflow Traces
  -> Generalized Workflow
  -> Procedural Memory Object
  -> Skill Package
  -> execution and validation records
```

## Review Gates

| Gate | Required before |
| --- | --- |
| Topology review | Agent-proposed Nodes/relationships become durable topology. |
| Claim review | Extracted assertions become Facts. |
| Tool grant review | Agents call external tools with write capability. |
| Workflow review | Repeated traces become reusable procedures. |
| Skill enablement review | Skill Packages become executable guidance. |

