# 13 · Cost

## In one glance
- About €500/month runs the demo, GPU included.
- GPU is half the bill; tenants share it.
- Prices net of VAT, checked 2026-11-09.

## Per component (monthly, EUR net)
| Component | Type | Cost | Source |
|---|---|---|---|
| srv-app | CCX23 | 85.99 | Hetzner API |
| srv-data | CCX33 | 138.49 | Hetzner API |
| srv-ops | CPX32 | 35.49 | Hetzner API |
| srv-gpu | GEX44 | 232.30 + 114 setup | Hetzner price page |
| Object Storage | 1 TB | ~6 (unverified) | Hetzner |
| IPv4 x3 | Primary IP | ~2 (unverified) | Hetzner |
| **Total** | | **~500** | |

## Per tenant
| Tenants | Change | Monthly total | Per tenant |
|---|---|---|---|
| 10 | None | ~€500 | ~€50 |
| 100 | None (light use, unverified) | ~€500 | ~€5 |
| 500 | srv-data CCX43, srv-ops CPX42, 2nd GEX44 | ~€960 | ~€1.92 |

## Assumptions
- Light use: ~50 agent runs per tenant per day.
- One GEX44 serves ~100 such tenants (unverified, needs benchmark).
- 500 tenants needs a 5th server: second GPU.

## Decisions
- Scale up servers before adding servers.
- Silo tenants pay for own DB and worker.

## Open questions
- GEX44 throughput benchmark decides the 100 tenant row.
