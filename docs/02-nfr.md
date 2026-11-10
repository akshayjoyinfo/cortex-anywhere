# 02 · Non functional requirements

## In one glance
- Isolation targets are zero tolerance; everything else has a budget.
- Every NFR names its mechanism and its test.
- Cost per tenant is a first class NFR, not an afterthought.

Rule: [00-overview](00-overview.md#the-rule-fail-closed).

| NFR | Target | Mechanism | How tested |
|---|---|---|---|
| Cross tenant read | 0 rows, ever | FORCED RLS, tenant keys | Leak suite in CI, canary every 5 min |
| Query with no tenant | 0 rows or error | `NULLIF` fail closed policy | Policy unit test |
| Egress off allow list | 0 connections | nftables + Smokescreen | Probe from worker and srv-gpu |
| Operator data access | 100% audited | Break glass role + pgaudit | Audit replay in quarterly drill |
| API latency (no LLM) | p95 < 300 ms | Monolith, PgBouncer, Valkey | k6 smoke per deploy |
| First token | p95 < 2 s (unverified) | vLLM batching, Qwen3-14B-AWQ | Synthetic chat probe |
| Availability | 99.5% monthly | Single region, fast restore | Uptime probe from srv-ops |
| RPO | 5 min | pgBackRest WAL archive | Weekly restore to scratch |
| RTO | 4 h | Terraform + Ansible rebuild | Quarterly rebuild drill |
| Quarantine time | < 60 s from trigger | Valkey flag checked per request | Synthetic runaway tenant |
| Crypto shred | < 1 h on offboard | Delete Vault Transit key | Offboard drill: ciphertext only |
| Onboarding | < 15 min | One Ansible play per tenant | CI runs it against dev |
| Rollback | < 10 min | Previous signed image tag | Rollback rehearsal per release |
| Cost per tenant | < €5/month at 100 tenants | Pooled tier, shared GPU | Doc 13, monthly invoice check |
| Traceability | 100% runs traced with `tenant_id` | OpenTelemetry + Tempo | Missing attribute fails test |
| Recall under RLS | recall@10 ≥ 0.9 | HNSW iterative scan | Recall test in CI |

## Decisions
| Decision | Alternative | Why it lost |
|---|---|---|
| 99.5% single region | 99.9% multi region | Breaks 3 server budget; demo scale |
| RPO 5 min via WAL | Nightly dumps | 24 h data loss unacceptable |
| Isolation targets never traded | Risk weighted targets | Fail closed rule forbids it |

## Open questions
- First token target needs a GEX44 benchmark.
- Does any tenant need EU only processing proof (DPA)?
