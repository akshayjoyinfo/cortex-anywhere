# 07 · Tenant isolation, one request

## In one glance
- Tenant is born once from the JWT and never changes.
- Postgres decides visibility; the app only carries the id.
- Rule: [00-overview](00-overview.md#the-rule-fail-closed).

```mermaid
sequenceDiagram
  participant U as User
  participant T as Traefik
  participant W as web
  participant Q as Valkey/Hangfire
  participant K as worker
  participant P as Postgres
  participant V as Vault
  participant L as vLLM
  U->>T: HTTPS + JWT
  T->>W: forward
  W->>W: validate JWT, build TenantContext
  W->>Q: enqueue run, signed envelope
  Q->>K: dequeue
  K->>K: verify signature, restore TenantContext
  K->>P: BEGIN; set_config('app.tenant_id', id, true)
  P-->>K: rows passing RLS only
  K->>V: decrypt with transit/keys/tenant-id
  K->>L: prompt, cache_salt = HMAC(id)
  L-->>K: tool call (business args)
  K->>K: allow list check, bind tenant tool
  K->>P: write result + provenance; COMMIT
```

## Steps
1. Traefik terminates TLS; rate limit by `tenant_id` claim.
2. web validates JWT against Keycloak realm keys.
3. Middleware builds immutable `TenantContext` in `AsyncLocal`.
4. Scoped DI container resolves services for that tenant.
5. Run enqueued with HMAC signed envelope `{tenant, run, agent}`.
6. Worker verifies signature; rebuilds the same `TenantContext`.
7. EF interceptor opens tx and calls `set_config(..., true)`.
8. RLS filters every read and write; no tenant means zero rows.
9. Vault Transit decrypts with this tenant's key only.
10. Tool calls checked against allow list, bound by DI, logged.

## Decisions
- `TenantContext` is a sealed record with no setters.
- Missing context throws before any I/O happens.

## Open questions
- None today.
