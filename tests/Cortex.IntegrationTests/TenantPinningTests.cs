using Xunit;

namespace Cortex.IntegrationTests;

/// <summary>
/// Runs Cortex.Data against a real Postgres 16 + pgvector container
/// (Testcontainers, image pgvector/pgvector:0.8.0-pg16) with db/migrations applied.
/// </summary>
public sealed class TenantPinningTests
{
    private const string Pending = "Skeleton: wire PostgreSqlBuilder and apply 0001_tenancy.sql.";

    [Fact(Skip = Pending)] public void Transaction_pins_tenant_with_set_config() { }
    [Fact(Skip = Pending)] public void Command_outside_transaction_is_refused() { }
    [Fact(Skip = Pending)] public void Ef_filter_removed_rls_still_isolates() { }
    [Fact(Skip = Pending)] public void Retention_above_180_days_is_rejected() { }
}
