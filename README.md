# cortex-lite

Day zero architecture for a multi tenant AI agent platform on Hetzner.
Docs, decisions, infra and an empty .NET 10 skeleton. No business logic.

## Fail closed
- Right tenant's data, or no data.
- Never another tenant's data, whatever the model does.
- Postgres FORCED RLS is the guarantee; everything else is backup.

## Repo map
| Path | What |
|---|---|
| `docs/` | 00 to 14, one screen each; start at `00-overview.md` |
| `docs/adr/` | Ten decision records |
| `db/` | Fail closed tenancy migration and CI checks |
| `infra/` | Terraform, Ansible, compose per server |
| `src/` | `Cortex.sln` at root: web and worker roles, one image |
| `tests/` | Unit, integration, security (leak + injection), k6 perf |
| `.github/workflows/` | Unit, integration, security gates; signed image |

## Deploy in 5 steps
1. Order GEX44, create vSwitch; `terraform apply` in `infra/terraform`.
2. Bootstrap Headscale on srv-ops from the Hetzner console.
3. `ansible-playbook -i infra/ansible/inventory.ini infra/ansible/site.yml`.
4. Unseal OpenBao with two operators; onboard the first tenant.
5. Push to `main`; servers pull the signed image.
