# Workspace Architecture

The workspace layer owns the shape of a person, team, or company's operating
world. It is not a folder convention. Folders are projections of workspace state.

## Hierarchy

```text
Tenant / Organization
  -> Workspace
    -> Node graph
      -> Node
        -> sources, signals, claims, facts, memories, workflows, skills
```

Projects are Nodes inside a Workspace. They are not peers of Workspace.

```text
Workspace
  -> Project Node
  -> Person Node
  -> Product Node
  -> Operational Node
  -> Context Node
  -> Learning Node
```

## Core Objects

| Object | Meaning | Owned by |
| --- | --- | --- |
| Tenant / Organization | Governance and account boundary. | Workspace / Topology |
| Workspace | Bounded operating area with members, nodes, policies, and projections. | Workspace / Topology |
| Node | Governed unit of context, purpose, relationships, state, and activity. | Workspace / Topology |
| Node Type | Type of node such as project, person, product, operational, context, learning, entity, team, department. | Workspace / Topology |
| Node Relationship | Typed relationship between nodes. | Workspace / Topology |
| Node Member | Human, agent, service account, or team with access/role in a node. | Workspace / Topology |
| Routing Rule | Rule or hint for placing new Signals into nodes and partitions. | Workspace / Topology |

## Node Lifecycle

```text
draft
  -> active
  -> paused
  -> blocked
  -> completed
  -> archived
  -> retired
```

Every transition should record actor, reason, valid time, transaction time,
policy version, and audit event.

## Node Anatomy

Every Node has the same universal sections, even when some are empty:

```text
identity
relationships
state
focus
context
decisions
tracking
meta
```

| Section | Contains |
| --- | --- |
| Identity | name, type, purpose, owner, lifecycle state |
| Relationships | parent, children, dependencies, collaborators, people, systems |
| State | health, progress, metrics, blockers, risks |
| Focus | current priorities, active work, review items |
| Context | source packages, signals, memory objects, documents, notes |
| Decisions | pending decisions, accepted Facts, contradictions, supersessions |
| Tracking | progress logs, milestones, workflow traces, review records |
| Meta | retention policy, access policy, timestamps, custom metadata |

## Storage

Minimum topology tables:

```text
tenants / organizations
workspaces
nodes
node_types
node_relationships
node_members
routing_rules
topology_change_requests
```

The current implementation uses local SQLite as the default runtime store. The
target production store is Postgres. The layer model does not change when the
physical database changes.

## Write Rules

```text
Workspace / Topology may create or update workspace structure.
Routing may read topology to place Signals.
Memory Core may link knowledge to Nodes.
Retrieval may scope recall by Nodes.
Export may render Node folders and pages.
No layer should invent durable Nodes without the topology layer.
```

## Human And Agent Setup

Humans can create workspaces and nodes through CLI, API, app UI, or markdown
import. Agents can propose topology, but durable topology changes should flow
through review:

```text
agent proposes node or relationship
  -> topology_change_request
  -> human/policy review
  -> accepted topology version
  -> route/context/export invalidation
```

This keeps the system customizable without letting agents silently rewrite the
workspace.

