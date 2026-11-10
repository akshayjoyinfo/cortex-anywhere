# ADR 005 · Keycloak for identity

Status: accepted

## Context
- Open source only, no paid SaaS.
- Need a `tenant_id` claim and a separate operator realm.
- Data must stay on Hetzner.

## Decision
Self hosted Keycloak; tenant realm with group mapper, separate operator realm.

## Alternatives rejected
| Option | Why it lost |
|---|---|
| Auth0 | Paid SaaS, identity data leaves Hetzner |
| Zitadel | Smaller ecosystem for .NET examples |

## Consequences
- We operate an IdP ourselves.
- Claim mapping is configuration, versioned in git.
- Operator tokens can never act as tenants.
