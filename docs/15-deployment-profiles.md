# 15 · Deployment profiles

## In one glance
- One codebase, one binary, three ways to deploy it ([ADR 011](adr/011-one-codebase-three-profiles.md)).
- `CORTEX_PROFILE=local|server` decides where things come from, never what the code does.
- Isolation is the same in every shape: tenant pinned per transaction, FORCED RLS ([ADR 012](adr/012-postgres-in-every-mode.md)).
- Local is proven on Windows Server 2022 ([18](18-field-test.md)); server profile is designed, not yet run.

## The three shapes
| | Local (customer machine) | Dedicated (one customer, our ops) | SaaS (pooled) |
|---|---|---|---|
| Profile | `local` | `server`, tier `silo` | `server`, tier `pooled` |
| Runs on | Customer Windows host | Our server, one customer | Our servers, many tenants |
| Tenants | One, fixed at install | One | Many, one schema |
| Tenant from | Install config + Windows login | JWT claim (Keycloak) | JWT claim (Keycloak) |
| Users | Windows accounts (Negotiate) | Keycloak realm | Keycloak realm per tenant |
| Secrets | DPAPI files, admin only ACL | OpenBao | OpenBao |
| Memory encryption | AES-GCM, tenant id bound | OpenBao Transit, key per tenant | Same |
| Model | Ollama on loopback, CPU | vLLM, own GPU possible | vLLM, `cache_salt` per tenant |
| Bind | 127.0.0.1 only, enforced | Behind Traefik | Behind Traefik |
| Install | DSC v3 bootstrap ([ADR 014](adr/014-provisioning-as-code.md)) | Ansible + same DSC doc | Ansible + compose |
| Status | Proven (field test) | Designed | Designed |

## What never changes between profiles
- `TenantContext` is born once at the edge and is immutable downstream.
- Data access: `cortex_app` role, `set_config('app.tenant_id', …, true)` per transaction, FORCED RLS.
- Agent loop, tool allow list, output policy, memory with provenance and audit.
- Migrations, `db/checks`, leak suite and hostile corpus.

## What the profile switches (code seams)
| Seam | Local | Server |
|---|---|---|
| Tenant middleware | `LocalTenantMiddleware` | `TenantMiddleware` (JWT) |
| `ISecretStore` | `DpapiSecretStore` | `OpenBaoSecretStore` (stub) |
| `IContentProtector` | `AesGcmContentProtector` | `TransitContentProtector` (stub) |
| `ILlmGateway` endpoint | Ollama, loopback guard | vLLM |
| Connection | Built from install config + secret | Config via PgBouncer |

## Rules
- No profile default: a missing or unknown `CORTEX_PROFILE` stops the process.
- Local refuses a model or database endpoint that is not loopback.
- A customer machine never compiles code: app and pgvector are CI built, pinned by SHA256.

## Decisions
| Decision | Alternative | Why it lost |
|---|---|---|
| One binary, profile switch | Separate on prem product | Two codebases drift; fixes land twice |
| Windows auth locally | Ship Keycloak on prem | Another server to run per customer |
| Dedicated = server profile, silo tier | Third profile | Same ops path as SaaS, fewer variants |

## Open questions
- Does a dedicated customer want its own Keycloak, or a realm in ours?
- Local profile roles: map Windows groups to agent permissions?
