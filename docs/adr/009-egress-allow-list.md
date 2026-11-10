# ADR 009 · Egress allow list at the network

Status: accepted

## Context
- A hostile model will try to call arbitrary hosts.
- Prompt rules cannot stop network calls.
- Traefik is a reverse proxy, not a forward proxy.

## Decision
Worker egress only via Smokescreen with per tenant allow lists; nftables drops the rest.

## Alternatives rejected
| Option | Why it lost |
|---|---|
| App level URL checks only | Bypassable by any new HTTP client |
| Squid | Weaker SSRF defaults than Smokescreen |

## Consequences
- New SaaS domain is a tenant admin change.
- srv-gpu has no egress at all.
- Denials feed quarantine.
