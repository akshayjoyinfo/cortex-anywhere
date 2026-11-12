# cortex-lite

The foundation for Cortex: a platform where each customer runs its own AI agents, kept apart.

## The one rule
- A customer gets its own data, or no data.
- Never another customer's data.
- This holds even when someone tricks the AI into trying.

## Why it exists
- Features are easy to add later. Separation, audit and cost per customer are not.
- So this was built for those first. Product features come later, on purpose.

## What it means for customers
This is the design. Status below shows what is built.
- Data stays on our own servers at Hetzner in Falkenstein, Germany. The GPU server's location is to be confirmed.
- Each customer workspace has its own encryption key. On exit we delete the key, so leftover copies become unreadable ("crypto shred").
- Every time our staff opens customer data, it is logged.
- Large customers can get their own database.

## Cost and scale
A workspace is one separated customer space. One customer can have several.

| Workspaces | Monthly total | Per workspace |
|-|-|-|
| 10 | about 500 EUR | about 50 EUR |
| 100 | about 500 EUR (to be confirmed) | about 5 EUR (to be confirmed) |
| 500 | about 960 EUR (to be confirmed) | about 1.92 EUR (to be confirmed) |

- Net of VAT, Hetzner prices of 2026-11-09, plus a one-time GPU setup fee of 114 EUR.
- The 100 and 500 rows depend on a GPU benchmark not yet run.

## Read it in 20 minutes
1. [The whole system on one page](https://akshayjoyinfo.github.io/cortex-lite-demo/site/architecture.html): who uses it, where it runs, where each safeguard sits.
2. [Who owns which data](https://akshayjoyinfo.github.io/cortex-lite-demo/site/data-model.html): customer, workspace, and what is shared or kept apart.
3. [Overview](docs/00-overview.md): the rule, 9 principles, 4 servers.
4. [Threat model](docs/05-threat-model.md): 19 ways data could leak, and what stops each.
5. [Cost](docs/13-cost.md): every line item and its source.
6. [Decision records](docs/adr/): 14 choices, with what we rejected and why.

## Assumptions to confirm
- We sell to businesses, not consumers.
- Our team sets up each customer. There is no self signup.
- One customer can have several workspaces.
- Customers who want n8n (a workflow tool) host it themselves.
- Outside AI models (from other AI vendors) are off. A customer can opt in, but only on its own-database tier.
- Run history is kept 90 days by default. A customer can set 1 to 180 days.

## Field test: it runs on a customer's Windows machine
The same code ran on a real Windows Server with no graphics card, installed from scratch with one command. Full report: [18 · Field test](docs/18-field-test.md).
- **5 minutes** from a freshly reinstalled server to a working AI agent.
- **13 attacks** tried to make the agent reveal another customer's data. **None succeeded**, and nothing left the machine.
- After a **restart**, everything came back on its own within 15 seconds, with nobody logged in.
- The AI model runs on the server's own processor, writing about 8 to 11 word fragments per second, so a typical answer takes 15 to 35 seconds. Data never leaves the machine.
- It also found two weak spots inside one customer's own memory. Both are on the [roadmap](docs/17-roadmap.md).

How it fits together: [deployment profiles](docs/15-deployment-profiles.md) · [joining the existing Cortex code](docs/16-integrating-existing-cortex.md) · [roadmap](docs/17-roadmap.md) · [field test page](docs/site/v2/index.html).

## Status
- **Exists and proven on Windows:** one AI agent with memory, separated per customer, installed as code, running as a Windows service.
- **Exists:** automated checks on every change (CI), including a real leak test against the database.
- **Designed, not yet running:** the cloud version (central login, key vault, GPU server). See the [roadmap](docs/17-roadmap.md).
- **Does not exist:** screens and billing.

## For engineers
| Path | What |
|-|-|
| `docs/`, `docs/adr/` | 00 to 18, one screen each; fourteen decision records |
| `infra/windows/` | Windows install as code (DSC v3), verify, reboot proof, timed install |
| `db/` | Fail closed tenancy migration (FORCED RLS) and CI checks |
| `infra/` | Terraform, Ansible, compose per server |
| `src/` | `Cortex.sln`: .NET 10, web and worker roles, one image |
| `tests/` | Unit, integration, security (leak and injection), k6 perf |
| `.github/workflows/` | Unit, integration and security gates; signed image |

Deploy in 5 steps:
1. Order the GEX44, create the vSwitch, then run `terraform apply` in `infra/terraform`.
2. Bootstrap Headscale on srv-ops from the Hetzner console.
3. Run `ansible-playbook -i infra/ansible/inventory.ini infra/ansible/site.yml`.
4. Unseal OpenBao with two operators, then onboard the first tenant.
5. Push to `main`. The servers pull the signed image.
