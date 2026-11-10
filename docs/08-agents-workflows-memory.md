# 08 · Agents, workflows, memory

## In one glance
- Agent = tenant row; runtime = shared stateless loop.
- Workflows are Hangfire jobs; agents do not know about them.
- Memory always carries provenance; recall is data, never instruction.

## Agent definition
| Field | Meaning |
|---|---|
| `id`, `tenant_id` | Identity; tenant set by DB default from setting |
| `system_prompt` | Tenant authored, versioned |
| `model` | `qwen3-14b` or tenant own model (silo only) |
| `tools[]` | Subset of tenant tool allow list |
| `memory_namespaces[]` | Which memory it reads and writes |
| `max_steps`, `token_budget` | Hard caps per run |
| `external_share` | External assistant (MCP) opt in, default false |

## Run loop
| Step | Does |
|---|---|
| 1 Load | Definition + working memory for this run |
| 2 Recall | Top k semantic memory, wrapped as labelled data |
| 3 Call | `IChatClient` with business only tool schemas |
| 4 Check | Tool name allow listed; args schema valid |
| 5 Execute | Tenant bound tool; egress via Smokescreen |
| 6 Record | Step, tokens, tool result to Postgres |
| 7 Stop | Answer, `max_steps`, budget or quarantine flag |

## Memory types
| Type | Store | Lifetime |
|---|---|---|
| Working | Valkey, sealed with tenant key | Run, TTL 24 h |
| Episodic | Postgres `memory_episode` | Retention policy |
| Semantic | Postgres + pgvector `memory_item` | Until deleted |

## Cardinality
- Tenant 1..n agents, 1..n workflows, 1..n namespaces.
- Workflow 1..n steps; step 0..1 agent.
- Run 1 tenant, 1 agent, 0..1 workflow.

## Provenance fields
- `run_id`, `agent_id`, `source` (`run`, `mcp:n8n`, `mcp:assistant`, `admin`).
- `source_ref` (document or URL), `created_at`, `trust` (`user`, `retrieved`).

## Decisions
| Decision | Alternative | Why it lost |
|---|---|---|
| Hangfire for workflows | Temporal | Extra cluster; see ADR 007 |
| Semantic Kernel loop behind `IChatClient` | LangChain (Python) | Second language, second image |

## Open questions
- Admin review queue for `retrieved` memory writes?
