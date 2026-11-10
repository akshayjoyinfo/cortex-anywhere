# ADR 010 · Hetzner for the demo

Status: accepted

## Context
- Budget around €500 per month.
- Data residency in the EU.
- Design must still map to AWS.

## Decision
Hetzner Cloud (3 servers) plus one GEX44 GPU server.

## Alternatives rejected
| Option | Why it lost |
|---|---|
| AWS | Several times the cost for the same footprint |
| On premise | No founder time for hardware |

## Consequences
- We operate Postgres, Vault and Keycloak ourselves.
- Mapping kept in doc 14.
- No AWS SDK in code.
