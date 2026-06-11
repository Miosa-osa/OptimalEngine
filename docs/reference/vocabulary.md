# Vocabulary

Use product terms consistently.

| Term | Meaning |
| --- | --- |
| Tenant / Organization | Governance boundary for one person, team, or company. |
| Workspace | Bounded operating area inside an organization. |
| Node | Governed unit of context, purpose, relationships, state, and activity. |
| Source Package | Preserved raw input with metadata, hash, scope, and policy. |
| Signal | Classified interpretation of source material. |
| Claim | Unaccepted assertion extracted from a source or observation. |
| Fact | Reviewed/policy-accepted assertion. |
| Memory Object | Source-backed meaning around Facts, Claims, sources, and relationships. |
| Context Package | Authorized bundle of context for a query or task. |
| Active Memory Pool | Task-scoped working memory shared by humans and agents. |
| Workflow Trace | Evidence-linked trace of repeated or meaningful work. |
| Skill Package | Governed reusable procedure with policy, tools, checks, and audit. |
| Projection | Rebuildable surface such as markdown, wiki, HTML, app view, API response, or agent prompt. |

## Domain Translation

Different users may prefer different surface words:

| Engine term | Business-facing wording | Personal-facing wording | Technical wording |
| --- | --- | --- | --- |
| Node | team, project, account, function | life area, project, person | namespace, module, scope |
| Signal | update, note, event | thought, note, observation | event, payload |
| Memory Object | company memory | remembered context | durable context object |
| Context Package | briefing packet | prep packet | authorized context bundle |
| Skill Package | SOP/playbook | routine | executable procedure |

The engine can render friendly language, but internal architecture should use
the canonical terms above.

