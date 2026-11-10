# ADR 003 · RLS policy fails closed

Status: accepted

## Context
- PgBouncer transaction mode reuses connections.
- `current_setting` can return NULL or empty string.
- A missing tenant must never mean all tenants.

## Decision
Policy compares `tenant_id = NULLIF(current_setting('app.tenant_id', true), '')::uuid`.

## Alternatives rejected
| Option | Why it lost |
|---|---|
| `current_setting` without missing_ok | Errors are safe but noisy for health checks |
| App side `WHERE` only | One forgotten predicate leaks everything |

## Consequences
- No tenant means zero rows.
- App role owns no tables, has no BYPASSRLS.
- Policy changes are security reviews.
