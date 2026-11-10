# ADR 001 · Modular monolith, one image, two roles

Status: accepted

## Context
- Three people at most will run this.
- Tenant isolation must be reviewed in one place.
- Web and worker differ only in what they run.

## Decision
One .NET image; `web` or `worker` chosen by start argument.

## Alternatives rejected
| Option | Why it lost |
|---|---|
| Microservices | Network hops multiply isolation surfaces |
| Separate web and worker images | Two builds for identical code |

## Consequences
- One leak suite covers everything.
- Scaling is per role, not per module.
- Module boundaries enforced by project references.
