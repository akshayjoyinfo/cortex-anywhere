# ADR 008 · Tools bound to tenant by DI, not by argument

Status: accepted

## Context
- The model controls every tool argument.
- Scope arguments let the model change tenant.
- Tool schemas are model visible.

## Decision
Tools are resolved from the tenant scoped container; schemas expose business arguments only.

## Alternatives rejected
| Option | Why it lost |
|---|---|
| Tenant id as tool argument | Model can set it |
| Validate tenant argument | One missed check leaks |

## Consequences
- Scope changes are impossible, not forbidden.
- Schema snapshot test guards it.
- Tools cannot be shared singletons.
