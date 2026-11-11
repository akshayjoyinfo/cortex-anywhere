# ADR 014 · Provisioning as code, never by hand

Status: accepted (principle) · proposed (tool, pending field test)

## Context
- Two install targets: a clean server we own, or a machine the customer already runs.
- Hand-typed setup cannot be repeated, audited or supported.
- AI systems are audited on data lineage; setup is part of that lineage.
- Customers rarely allow inbound remote management into their network.

## Decision
- Every install step lives in git as a declarative, idempotent config (test, then set).
- Every dependency is pinned by version and SHA256; nothing resolves "latest".
- Every run emits structured step logs (JSON), kept as install evidence.
- Binaries we compile (pgvector DLL) are built in CI, never on the target.
- Tool: one Microsoft DSC v3 config document, version pinned.
- Customer machine: applied locally by `dsc`, offline bundle, no controller.
- Our servers: Ansible `ansible.windows.dsc3` applies the same document.

## Alternatives rejected
| Option | Why it lost |
|---|---|
| Manual PowerShell over RDP | Not repeatable, no evidence |
| Ansible only | Needs controller and inbound WinRM/SSH into customer LAN |
| winget configure only | Not installed on every Windows Server; separate YAML dialect |
| Build pgvector on target | Puts a C++ toolchain on customer machines |

## Consequences
- The only imperative code is a short bootstrap that fetches and verifies `dsc`.
- Same document serves fresh install, re-run and drift check.
- Install time and step logs feed docs/18-field-test.md.
- Unverified: DSC v3 behaviour on the Vultr Windows Server image.
