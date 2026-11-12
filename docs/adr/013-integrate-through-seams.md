# ADR 013 · Integrate the existing Cortex through seams, not a rewrite

Status: accepted

## Context
- Cortex has a working C#/.NET codebase and paying customers.
- AI agents need strict tenant isolation the current code may do by hand.
- A rewrite would stop feature work and move all risk to one cutover.

## Decision
- Four seams: tenant (`TenantContext`), data (pinned transactions + RLS), model (`ILlmGateway`), tools (`ITenantBoundTool`).
- New AI features run in Cortex beside the existing app; the app calls them over the API.
- Strangler: move one feature at a time, retire old paths when tests and usage allow ([16](../16-integrating-existing-cortex.md)).

## Alternatives rejected
| Option | Why it lost |
|---|---|
| Big bang rewrite | Months without features; all risk at cutover |
| Bolt AI into the current app | Hand written tenant filters would guard model driven access |
| Separate AI product | Customers and identity would be managed twice |

## Consequences
- Discovery comes first: identity flow, data paths, jobs, integrations.
- Existing services become tools with business arguments only.
- Two databases may coexist during migration; AI data stays in Postgres.
