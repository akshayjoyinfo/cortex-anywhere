# 04 · C2 Containers

## In one glance
- One image, two roles: `web` and `worker`, chosen by start argument.
- Only the worker reaches the model and the outside world.
- Every store isolates by tenant independently of app code.

```mermaid
C4Container
  title Cortex Lite · Containers
  Person(user, "Tenant user")
  System_Ext(mcp, "Tenant MCP clients")
  System_Ext(saas, "Tenant SaaS")
  Container_Boundary(app, "srv-app") {
    Container(traefik, "Traefik", "Edge", "TLS, routing, rate limit")
    Container(kc, "Keycloak", "IdP", "Tenant realm, operator realm")
    Container(web, "Cortex web", ".NET 10", "API, chat, MCP endpoint")
    Container(worker, "Cortex worker", ".NET 10", "Hangfire, agent loop")
    Container(smoke, "Smokescreen", "Egress proxy", "Per tenant allow list")
  }
  Container_Boundary(data, "srv-data") {
    ContainerDb(pg, "Postgres 16 + pgvector", "via PgBouncer", "All tenant data, RLS")
    ContainerDb(vk, "Valkey", "KV", "Sessions, signals, limits")
    Container(vault, "Vault", "Secrets", "Transit keys, OAuth tokens")
  }
  Container_Boundary(gpu, "srv-gpu") {
    Container(vllm, "vLLM", "Qwen3-14B-AWQ", "OpenAI compatible API")
  }
  Rel(user, traefik, "HTTPS")
  Rel(mcp, traefik, "MCP over HTTPS")
  Rel(traefik, web, "HTTP")
  Rel(web, pg, "SQL")
  Rel(worker, pg, "SQL")
  Rel(worker, vllm, "HTTP, private")
  Rel(worker, smoke, "CONNECT")
  Rel(smoke, saas, "HTTPS")
```

| Container | Server | Stores | Talks to | Isolation mechanism |
|---|---|---|---|---|
| Traefik | srv-app | Nothing | web, Keycloak | Only public 443; rate limit per `tenant_id` |
| Keycloak | srv-app | Realms in Postgres (own DB) | Postgres | `tenant_id` claim from group, not user input |
| web | srv-app | Nothing | Postgres, Valkey, Vault | TenantContext from JWT; no egress |
| worker | srv-app | Nothing | Postgres, Valkey, Vault, vLLM, Smokescreen | Context from signed job envelope |
| Smokescreen | srv-app | Nothing | Allow listed hosts | Role per tenant from mTLS cert |
| Postgres + PgBouncer | srv-data | All tenant rows, vectors, Hangfire | none | FORCED RLS, tx local tenant |
| Valkey | srv-data | Sessions, signals, quotas | none | Key prefix + ACL per role; values sealed |
| Vault | srv-data | Tenant keys, OAuth tokens | none | Path per tenant; AppRole per role |
| vLLM | srv-gpu | KV cache only | none | `cache_salt` per tenant; no egress |
| Grafana stack | srv-ops | Logs, traces, metrics | all (scrape) | `tenant_id` label; no payloads logged |

## Decisions
| Decision | Alternative | Why it lost |
|---|---|---|
| MCP endpoint inside web role | Separate MCP service | Second deployable for one route |
| Smokescreen identifies tenant via client cert | Single shared egress list | One tenant's domains open to all |

## Open questions
- Keycloak on srv-app or srv-data under load?
