# ADR 012 · PostgreSQL in every mode, including a customer's Windows machine

Status: accepted (proven on Windows Server 2022)

## Context
- Tenant isolation rests on FORCED row level security ([ADR 003](003-fail-closed-rls-policy.md)).
- Agent memory needs vector search.
- An embedded database would mean a second isolation model for local installs.

## Decision
- PostgreSQL 16 with pgvector everywhere, also locally, as its own Windows service.
- Same migrations, same `db/checks`, same leak suite in every mode.
- Binaries pinned by SHA256; pgvector built once in CI against the pinned build.

## Alternatives rejected
| Option | Why it lost |
|---|---|
| SQLite locally | No RLS; isolation would be code only |
| SQL Server locally | Different RLS model, no pgvector; two schemas to keep safe |
| Customer's existing Postgres | Not ours to configure; we never touch it (port conflict stops install) |

## Consequences
- Local install carries a database server (installed in 42 s, starts 13 s after boot).
- No C compiler on customer machines: extensions arrive prebuilt with provenance.
- Field test caught a real migration bug (schema `public` hid `vector`), fixed in 0002.
