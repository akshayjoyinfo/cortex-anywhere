# ADR 004 · Postgres as the only durable store

Status: accepted

## Context
- Vectors, jobs, memory and data all need tenant isolation.
- Every extra store needs its own isolation proof.
- Team is small.

## Decision
Postgres 16 holds rows, vectors (pgvector), Hangfire jobs and audit.

## Alternatives rejected
| Option | Why it lost |
|---|---|
| Qdrant or Weaviate for vectors | Second isolation model to prove |
| Separate queue (RabbitMQ) | Another store with tenant payloads |

## Consequences
- One backup, one restore drill.
- RLS covers vectors too.
- Valkey holds only ephemeral, sealed data.
