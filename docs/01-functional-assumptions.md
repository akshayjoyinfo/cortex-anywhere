# 01 · Functional assumptions

## In one glance
- Operators onboard tenants; tenant admins configure; tenant users run.
- Agents and workflows are tenant owned rows, not code.
- External MCP clients act as the tenant, never as the platform.

Rule: [00-overview](00-overview.md#the-rule-fail-closed).

## Actors
| Actor | Can do | Cannot do |
|---|---|---|
| Tenant user | Chat with agents, start workflows, read own runs | Change agents, tools or connections |
| Tenant admin | Define agents, tools, workflows, connections, allow lists | Read another tenant; change own tier |
| Platform operator | Onboard, quarantine, offboard, change tier | Read tenant data without audited break glass |
| Agent run | Call allow listed tools with business arguments | Choose tenant, connection, database or namespace |
| Workflow step | Start agent runs, wait, branch on results | Run without a signed tenant envelope |
| MCP client (n8n, AI assistant) | Read and write opted in memory | Reach agents or memory not granted to its token |

## Objects
| Object | Owned by | Cardinality |
|---|---|---|
| Customer | Platform | 1..n tenants; contract and DPA |
| Tenant | Customer | Isolation unit: 1 tier, 1 realm group, 1 key |
| Agent | Tenant | 0..n per tenant |
| Tool binding | Agent | 0..n per agent, from tenant allow list |
| Connection | Tenant | 0..n per tenant; OAuth token in Vault |
| Workflow | Tenant | 0..n per tenant; steps reference agents |
| Run | Agent | 0..n per agent; 1 tenant, immutable |
| Memory item | Tenant | 0..n; tagged with run and source |
| MCP client grant | Tenant | 0..n; scoped to memory namespaces |

## Out of scope (day zero)
- Self service signup and billing.
- Cross tenant sharing of agents or memory.
- Hosting n8n for tenants (licence: see 03).

## Decisions
| Decision | Alternative | Why it lost |
|---|---|---|
| Agents as configuration rows | Agents as code plugins | Code per tenant breaks one image |
| Sub teams later via memory namespaces + `app.team_ids` | `team_id` column now | Unused today; adding it later is one expand migration |
| Run retention 90 days, tenant may set 1 to 180 | Unlimited, tenant chooses | More data held means more leak and GDPR exposure |

## Sub team seam (not built)
- Keycloak subgroups emit a `team_ids` claim.
- Team policy is AND-ed onto the tenant policy: it can only narrow.

## Open questions
- None today.
