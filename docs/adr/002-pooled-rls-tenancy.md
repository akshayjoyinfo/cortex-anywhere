# ADR 002 · Pooled tenancy with shared schema and RLS

Status: accepted

## Context
- Most tenants are small.
- Cost per tenant must stay under €5.
- Some tenants will want full isolation.

## Decision
Shared schema, FORCED RLS; silo is a tier column plus runbook.

## Alternatives rejected
| Option | Why it lost |
|---|---|
| Schema per tenant | Migrations multiply; RLS still needed for pooled data |
| Database per tenant | Cost and connections explode at 500 tenants |

## Consequences
- One migration path for all tiers.
- Silo is an exception, not a fork.
- RLS correctness is the single critical control.
