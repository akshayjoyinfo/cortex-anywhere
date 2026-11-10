# 06 · Security guardrails

## In one glance
- Each guardrail: what the model sees, asks for, gets when wrong.
- Failure is always no data, an error, or an alert.
- Rule: [00-overview](00-overview.md#the-rule-fail-closed). Threats: [05](05-threat-model.md).

| Guardrail | Threats | Model sees | Model can ask | Asks wrongly → | Why wrong data is impossible |
|---|---|---|---|---|---|
| FORCED RLS, fail closed policy | T8 T9 T10 T11 | Nothing | Nothing | No data | Postgres filters every row by tx setting |
| Tenant from JWT only | T7 T18 | Nothing | Nothing | Error 401 | No code path reads tenant from input |
| Tools bound by DI | T7 | Business args schema | Business args | Error: unknown arg | Binding resolved before the model runs |
| Tool allow list per agent | T1 T2 | Allowed tool names | Any tool name | Error + audit | Unknown tool never resolves |
| Egress allow list | T2 T3 T17 | Nothing | Any URL | Error 403 + alert | Network drops it below the app |
| Recipient allow list | T5 | Nothing | Any recipient | Error + audit | Checked in code after model output |
| No remote render in UI | T4 | Nothing | Markdown images | Not fetched | CSP `img-src 'self'` |
| Data labelling | T1 T6 | Retrieved text as data | Nothing | Ignored | Recall never enters system role |
| Memory provenance | T6 T18 | Nothing | Memory write | Tagged, reviewable | Writes keyed to run and source |
| Tenant keys (Transit) | T15 | Nothing | Nothing | Ciphertext | Other tenant's key never loaded |
| Signed job envelope | T14 | Nothing | Nothing | Job rejected | Worker trusts signature, not args |
| `cache_salt` per tenant | T16 | Nothing | Nothing | Cache miss | Salt set by gateway |
| Quarantine | T19 | Nothing | Nothing | Tenant paused | Trigger is metrics |

## Decisions
- No guardrail lives in the prompt.
- Every refusal is logged with `tenant_id` and run id.

## Open questions
- None today.
