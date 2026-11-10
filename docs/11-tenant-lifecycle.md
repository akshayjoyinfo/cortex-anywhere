# 11 · Tenant lifecycle

## In one glance
- Every step is a script; operators never type SQL.
- Tier is a column; moving tier is a runbook.
- Offboarding ends in crypto shred.

## Onboard
1. Operator runs `onboard.sh <name> <tier>`.
2. Insert `tenants` row; Keycloak group with `tenant_id` attribute.
3. Create Vault Transit key `tenant-<id>` and KV path.
4. Seed canary rows for the leak canary.
5. Invite tenant admin; audit event `tenant.onboarded`.

## Offboard
1. Quarantine tenant; export data on request.
2. Disable Keycloak group; revoke MCP grants.
3. Delete rows; delete Vault key (crypto shred).
4. Backups older than key deletion become unreadable.
5. Audit `tenant.offboarded`, two operator approvals.

## Move to silo
1. Create database `cortex_t_<id>` with same migrations.
2. Copy rows by `tenant_id` with logical replication.
3. Flip `tenants.tier = 'silo'`; router picks connection.
4. Verify canary; delete pooled rows.

## Canary a feature to one tenant
1. Add flag row in `tenant_features`.
2. Code reads flag from `TenantContext`.
3. Watch error and leak alerts for 24 h.
4. Widen or remove the row.

| Tier | What differs | What is identical |
|---|---|---|
| Pooled | Shared DB, shared worker | Image, code, RLS, keys per tenant |
| Silo | Own DB, own worker, own egress list | Image, code, RLS, keys per tenant |

## Decisions
- Bring your own model forces silo.
- Silo keeps RLS on, as a second fence.

## Open questions
- Silo DB on srv-data or new server?
