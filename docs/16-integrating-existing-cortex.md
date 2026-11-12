# 16 · Integrating the existing Cortex codebase

## In one glance
- Integrate through seams, not a rewrite ([ADR 013](adr/013-integrate-through-seams.md)).
- Four seams carry everything: tenant, data, model, tools. Each is one interface.
- New AI features grow beside the current app (strangler); old paths retire one at a time.

## Discovery (first two weeks, read only)
1. Map where customer identity enters and how it flows (session, header, job payload).
2. List every data access path: EF, raw SQL, stored procedures, reports, exports.
3. Find tenant filters done by hand (`WHERE customer_id = …`): each one is a leak risk.
4. Inventory background jobs and what tenant context they run with.
5. List integrations: outbound calls, webhooks, file drops, email.
6. Record runtime facts: .NET version, Windows or Linux, SQL Server or Postgres, deployment.
- Output: one table per item, owner named, risk scored. No code changes yet.

## The four seams
| Seam | Interface | What the existing app does | What changes |
|---|---|---|---|
| Tenant | `TenantContext`, `ITenantContextAccessor` | Passes customer id around | Born once at the edge, read everywhere |
| Data | `CortexDbContext` + interceptors | Filters by hand | Transaction pins tenant; FORCED RLS guarantees it |
| Model | `ILlmGateway` (`IChatClient`) | None yet | Only path to a model; endpoint per profile |
| Tools | `ITenantBoundTool`, `ToolRegistry` | Existing services | Wrapped as tools bound to the tenant by DI |
- Secrets (`ISecretStore`) and encryption (`IContentProtector`) ride along as plumbing.

## How existing code meets the seams
- **Tenant:** add one middleware at the edge; old code reads the accessor instead of parameters.
- **Data:** keep the current database for current features; new AI tables live in Postgres with RLS.
- **Tools:** expose existing business services as tools with business arguments only, never ids.
- **UI:** the existing app calls Cortex agents over its API; no shared database writes.

## Strangler steps
1. Stand up Cortex beside the app, same customers, read only tools first.
2. Route one AI feature through Cortex end to end; keep the old path as fallback.
3. Move tenant identity to `TenantContext` module by module; delete hand filters behind RLS.
4. Retire the old path when the leak suite and usage both say so.

## Proof it fits .NET on Windows
- The field test ran the full stack on Windows Server 2022 with .NET 10 ([18](18-field-test.md)).
- Windows auth, Windows service, DPAPI, DSC v3: native Windows mechanisms, no Linux shims.

## Decisions
| Decision | Alternative | Why it lost |
|---|---|---|
| Seams + strangler | Big bang rewrite | Freezes features for months; risk lands at once |
| New AI data in Postgres | Same database as today | RLS and pgvector are the guarantees ([ADR 012](adr/012-postgres-in-every-mode.md)) |
| Agents called over API | Shared library in the old app | Keeps isolation logic in one place |

## Open questions
- Is today's database SQL Server? If so, which AI data must join with it?
- Which existing services become the first read only tools?
