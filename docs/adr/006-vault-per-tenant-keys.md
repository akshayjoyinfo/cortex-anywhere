# ADR 006 · Vault for per tenant keys and tokens

Status: accepted

## Context
- A logical leak should return ciphertext.
- Tenant OAuth tokens need a home outside Postgres.
- Offboarding should be crypto shred.

## Decision
OpenBao (Vault API, MPL licence): Transit key and KV path per tenant; AppRole per role.

## Alternatives rejected
| Option | Why it lost |
|---|---|
| pgcrypto with app held keys | Keys live next to the data |
| One platform key | No crypto shred per tenant |
| HashiCorp Vault | BUSL licence since 2023; not open source |

## Consequences
- Deleting a key shreds a tenant.
- Vault is a hard dependency; unsealing is a runbook.
- Data keys cached briefly per tenant.
