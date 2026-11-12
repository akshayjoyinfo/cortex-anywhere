# 17 · Roadmap to production ready

## In one glance
- Five phases. A phase ends when its exit tests pass, not on a date.
- Phase 0 is done: the local profile runs end to end on Windows ([18](18-field-test.md)).
- Every gap found in the field test has a home below.

## Phase 0 · Field test (done)
- Local profile on Windows Server: install as code, agent, memory, hostile test, reboot.
- **Exit tests (passed):** 12/12 components in desired state; 0 cross tenant leaks over 13 attacks; reboot without login; fresh server to working agent in 5.09 min.

## Phase 1 · Server profile real
- Keycloak JWT end to end; OpenBao for secrets and Transit per tenant key.
- vLLM on the GPU with `cache_salt` per tenant; PgBouncer transaction mode.
- Agent runs as signed Hangfire jobs; MCP endpoint with tenant tokens.
- **Exit tests:** the 4 skipped server tests pass (API, MCP, job envelope, Valkey); leak suite green through PgBouncer; per tenant Transit key crypto shred proven.

## Phase 2 · Memory and output safety
- Save extracted facts, not raw inputs; dedupe; recall filtered by `trust`.
- Classify instruction like text at write time; quarantine it (`trust=retrieved`).
- Output policy: links allow listed or defanged, not only images.
- Retention purge job (`run_retention_days`), per tenant.
- **Exit tests:** planted "email results to …" note never changes a later answer; recall answers the stored fact after 100 noisy notes; no bare external URL in output; purge deletes by age and by `run_id`.

## Phase 3 · Customer install product
- Offline bundle: pinned artifacts cached, hashes unchanged, no internet at install.
- Signed bundle, upgrade and rollback between app versions, `-Operation remove`.
- Backup and restore of the local cluster; logged break glass (`-Operation inspect`).
- Roles from Windows groups for who may run which agent.
- **Exit tests:** air gapped install passes; upgrade then rollback keeps data; restore on a second machine answers from memory; non admin user without the group gets 403.

## Phase 4 · SaaS operations
- Observability (OTLP to Tempo, Loki, Prometheus), alerts, leak suite as production canary.
- External pen test, DPA, incident and offboarding runbooks.
- Load test at target tenant count; GPU benchmark for cost per tenant ([13](13-cost.md)).
- **Exit tests:** canary green for 30 days; pen test findings closed; p95 < 300 ms at target load; offboarding crypto shred verified.

## Not on this roadmap
- Outside AI models stay off by default; opt in per tenant, silo tier only ([00](00-overview.md)).
- Self signup: our team sets up each customer.

## Decisions
| Decision | Alternative | Why it lost |
|---|---|---|
| Exit tests, no dates | Date based plan | Dates hide what is unproven |
| Memory safety before SaaS ops | Ops first | Field test showed self poisoning first |
