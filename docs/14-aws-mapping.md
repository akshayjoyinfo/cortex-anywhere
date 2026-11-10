# 14 · AWS mapping

## In one glance
- Same design maps to AWS without changing the code.
- Isolation stays in Postgres; AWS only swaps operations.
- Main change: managed services replace Ansible roles.

| Hetzner component | AWS service | What changes | What stays |
|---|---|---|---|
| srv-app + compose | ECS Fargate | Two services from one image | Image, roles, code |
| Traefik | ALB + WAF | TLS at ALB | Rate limit by tenant claim |
| Keycloak | Cognito or Keycloak on ECS | Claim mapping config | `tenant_id` claim |
| Postgres + pgvector | Aurora PostgreSQL | Managed backups | FORCED RLS, policies, roles |
| PgBouncer | RDS Proxy | Pinning rules (unverified) | Tx local tenant setting |
| Valkey | ElastiCache Valkey | Managed | Key prefix, ACL |
| Vault | KMS + Secrets Manager | Key per tenant in KMS | Envelope encryption |
| vLLM on GEX44 | Bedrock or SageMaker | Data leaves own hardware | `IChatClient` boundary |
| Smokescreen | Network Firewall | Domain rules managed | Per tenant allow list |
| Grafana stack | CloudWatch + X-Ray | Exporters | OpenTelemetry |
| pgBackRest + Object Storage | Aurora backups + S3 | Managed | RPO target |
| Headscale | SSM Session Manager | No VPN | Audited operator access |

## Decisions
- Code never imports an AWS SDK.

## Open questions
- RDS Proxy with `set_config(..., true)`: confirm no pinning cost.
