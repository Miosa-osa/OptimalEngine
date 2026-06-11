# Packages And Exports

Optimal Engine separates packages from generic exports.

## Definitions

| Term | Meaning |
| --- | --- |
| Package | A receiver/channel bundle made from multiple files or objects, often zipped or prepared for delivery. |
| Export | A generated view or artifact, such as markdown, HTML, PDF, report, API response, app view, or loose generated file. |
| Skill Package | A governed reusable procedure. This is not the same as a delivery package. |

Packages answer:

```text
Who is this for?
Through what channel will it be sent?
What files are included?
Which Nodes and source objects support it?
Who generated it?
Who reviewed it?
```

## Placement Rule

Put a package where its ownership lives.

```text
Node-specific package
  -> nodes/<node-slug>/packages/<package-slug>/

Workspace-level package
  -> workspace-packages/<package-slug>/
  -> only when the package intentionally spans multiple Nodes
```

Do not put a project package at the workspace root. If the package is for a
project, customer, person, product, operation, or research area, it belongs
inside that Node.

## Node Package Shape

```text
nodes/project-platform-launch/packages/partner-update/
  package.yaml
  README.md
  source-links.md
  launch-brief.md
  pricing-summary.pdf
  assets/
  dist/
    partner-update.zip
```

`package.yaml` should include:

```yaml
package_id: pkg_partner_update
package_type: delivery
owner_node_id: node_project_platform_launch
receiver: partner team
channel: email
purpose: Send the current launch update and pricing context.
source_node_ids:
  - node_project_platform_launch
source_object_links:
  - type: fact
    id: fact_current_pricing
review_status: draft
generated_by: agent_or_human_id
```

## Workspace Package Shape

Use workspace-level packages only for cross-node bundles.

```text
workspace-packages/q3-board-review/
  package.yaml
  README.md
  sections/
    product.md
    sales.md
    operations.md
  dist/
    q3-board-review.zip
```

The manifest must list every source Node. If it does not, the package should
not be workspace-level.

## Export Shape

Exports are looser generated surfaces:

```text
nodes/project-platform-launch/exports/
  current-state.html
  node-summary.md
  timeline.json
```

Exports can feed an app, report, API response, or wiki page. They are
rebuildable projections unless explicitly re-ingested as source evidence.

## Agent Rule

When a user asks:

```text
make a package
send a packet
bundle this up
prep this for the team
make the client handoff
zip the launch docs
```

the agent should resolve:

```text
receiver
channel
workspace
owning Node
source objects
review requirements
output format
```

If the owning Node is ambiguous, ask before writing files.
