# ADR 007 · Hangfire for workflows

Status: accepted

## Context
- Workflows are short, deterministic sequences.
- Postgres is already the store.
- No extra cluster allowed.

## Decision
Hangfire on Postgres; agent runs are steps.

## Alternatives rejected
| Option | Why it lost |
|---|---|
| Temporal | Needs its own cluster and store |
| n8n | Sustainable Use licence; not multi tenant |

## Consequences
- Workflow state is tenant rows under RLS.
- Long sagas are out of scope.
- Jobs carry a signed tenant envelope.
