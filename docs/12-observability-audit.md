# 12 · Observability and audit

## In one glance
- Every signal carries `tenant_id`; no payloads in logs.
- Canary leak hit is a page, always.
- Quarantine triggers on metrics, never on model output.

| Signal | Source | Severity | Action |
|---|---|---|---|
| Canary cross tenant hit | Canary job | P1 page | Freeze writes platform wide; incident |
| Query with no tenant set | Postgres log | P2 | Find code path, add test |
| Egress denials > 20 in 5 min | Smokescreen | P2 | Auto quarantine tenant |
| Tokens > 3x 7 day p95 per hour | Worker metrics | P3 | Auto quarantine tenant |
| Tool allow list refusals > 10 in 5 min | Worker | P3 | Auto quarantine agent |
| MCP auth failures > 30 in 5 min | web | P3 | Block client grant |
| Break glass used | Vault + pgaudit | P2 | Second operator reviews |
| Backup older than 15 min | pgBackRest | P2 | Fix WAL archive |
| GPU memory > 95% | DCGM exporter | P3 | Lower `max_num_seqs` |

## Audit events
- `tenant.onboarded`, `tenant.offboarded`, `tenant.quarantined`, `tenant.tier_changed`.
- `operator.break_glass`, `operator.login`.
- `agent.changed`, `allowlist.changed`, `mcp.grant_changed`.
- `tool.refused`, `egress.denied`, `memory.written`.

## Canary design
- Two synthetic tenants, each with seeded marker rows and vectors.
- Every 5 min: tenant A reads via API, queue, vector, tools.
- Each read checks for tenant B markers.
- Any hit pages and freezes writes.
- Hostile prompt corpus runs nightly against both.

## Decisions
- Audit log append only, in Postgres plus Loki.
- Quarantine undo needs an operator.

## Open questions
- Thresholds above are starting values; tune after a month.
