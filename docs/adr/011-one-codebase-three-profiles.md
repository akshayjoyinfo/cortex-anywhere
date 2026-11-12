# ADR 011 · One codebase, three deployment profiles

Status: accepted (local profile proven in the field test, server profile designed)

## Context
- Some customers need Cortex on their own Windows machine; others want our SaaS.
- A second product for on premises would fork fixes and security work.
- Isolation must hold the same way everywhere.

## Decision
- One binary; `CORTEX_PROFILE=local|server` picks sources, never behaviour.
- Three shapes: local (customer host), dedicated (server, silo tier), SaaS (server, pooled).
- Profiles switch only seams: tenant source, secrets, encryption, model endpoint, bind.

## Alternatives rejected
| Option | Why it lost |
|---|---|
| Separate on premises product | Two codebases drift; every fix lands twice |
| Feature flags per customer | Isolation logic would branch inside the code |
| Containers on customer Windows | Docker on Windows Server adds a runtime to support |

## Consequences
- A missing profile stops the process: no silent default.
- Local enforces loopback for model, database and HTTP bind.
- Server profile pieces (Keycloak, OpenBao, vLLM) stay stubs until roadmap Phase 1.
