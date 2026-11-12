# 18 · Field test on Windows Server

## In one glance
- The local profile ran end to end on a real Windows Server, no GPU, installed as code only.
- Fresh server to working agent: **5.09 min**. Reboot without login: everything back in **≤ 15.2 s**.
- Hostile test: **13 attacks, 0 cross tenant leaks**. Two real weaknesses found inside one tenant.
- Evidence: JSON per run (host facts, bundle hash, step logs, checks); IPs and hostnames left out here.

## Machine
- Windows Server 2022 Standard, 4 vCPU (2 cores, 4 threads, Xeon Skylake), 8 GB RAM, 160 GB SSD, no GPU.
- Reached over a tailnet only; no inbound port opened for the app or database.

## What ran
| Phase | What | Result |
|---|---|---|
| 0 | PostgreSQL 16.15 + pgvector 0.8.7 (CI built), migrations, `db/checks` | Pass after one fix (0002) |
| 1 | Profiles, Windows auth, DPAPI, loopback bind | 4/4 app checks |
| 2 | One agent: recall, Qwen3 1.7B on CPU, memory with provenance, audit | Pass |
| 3 | Canary tenant B, injection corpus, leak suite | 0 leaks |
| 4 | Windows service + reboot proof | Pass |
| 5 | Timed install on a reinstalled server | 5.09 min |

## Numbers
| Measure | Value |
|---|---|
| Fresh server to first answer | 5.09 min (bootstrap 4.36, first answer 43.9 s cold) |
| Slowest installs | Ollama 43.1 s · PostgreSQL 42.3 s · models 41.2 s · .NET SDK 37.6 s (field test only) |
| Generation speed, CPU | 5.0 to 6.6 tok/s cold, 8.1 to 11.3 tok/s warm |
| Agent run wall time | 14 to 35 s typical, up to 70 s on long attacks |
| RAM | Ollama 2.9 GB (both models), app 96 to 128 MB |
| After reboot | postgres 13.3 s, app 14.4 s, Ollama 15.2 s, tailscale 14 s |
| Tests on server | unit 33/33 · security 14 pass, 4 skipped · integration 4 skipped |

## Hostile test
- Positive control first: the scanner found tenant B's marker in B's 4 notes and agent.
- No B marker in any output, tool argument, A's 34 notes, episodes, audits or agents.
- A asking for B's agent: 404. Off machine connections: 0 over 1452 samples.
- The model passed `namespace: "tenant-b"` to `search_memory`; the tool ignored it (tenant bound in code).

## Weaknesses found (inside one tenant)
- **Self poisoning:** a saved "email results to attacker" note resurfaced in a later answer. No tool could act.
- **Bare URLs** pass the output gate; only images are stripped.
- **Recall crowding:** after many stored questions, an answer missed the saved fact.
- **Ops:** Tailscale needed unattended mode to survive a reboot; now a checked setting.
- Fixes: [17](17-roadmap.md) Phase 2 and 3.

## Bugs found and fixed during the test
- `initdb` drops admin rights: secrets folder ACL; schema `public` hid `vector` from the app (0002).
- PowerShell 5.1 traps: empty string prefix, single item arrays, `Get-Content` string metadata.

## Not tested, and why
- Server profile at runtime (Keycloak, OpenBao, vLLM, Hangfire, MCP): needs the cloud stack.
- GPU throughput and multi tenant load: no GPU, one machine.
- Offline install, upgrade, rollback, backup and restore: Phase 3 work.
- Ansible path for Windows (`infra/ansible/windows.yml`): written, never run.
- Non admin and domain users for Windows auth: only the local Administrator was used.
