using Xunit;

namespace Cortex.SecurityTests;

/// <summary>
/// Leak suite. Runs in CI against Postgres 16 + pgvector with two canary tenants,
/// and as the production canary. Any hit fails the pipeline. Examples, not yet wired.
/// </summary>
public sealed class TenantLeakTests
{
    private const string Pending = "Skeleton: needs Postgres service and seeded canary tenants.";

    [Fact(Skip = Pending)] public void Query_without_tenant_returns_zero_rows() { }
    [Fact(Skip = Pending)] public void Empty_string_tenant_returns_zero_rows() { }
    [Fact(Skip = Pending)] public void Raw_sql_without_predicate_sees_only_own_rows() { }
    [Fact(Skip = Pending)] public void Pooled_connection_does_not_carry_previous_tenant() { }
    [Fact(Skip = Pending)] public void Vector_search_never_returns_other_tenant_canary() { }
    [Fact(Skip = Pending)] public void Api_with_tenant_a_token_never_sees_b_canary() { }
    [Fact(Skip = Pending)] public void Mcp_with_tenant_a_token_never_sees_b_canary() { }
    [Fact(Skip = Pending)] public void Job_envelope_with_edited_tenant_is_rejected() { }
    [Fact(Skip = Pending)] public void Valkey_cross_prefix_read_yields_ciphertext_only() { }
    [Fact(Skip = Pending)] public void Every_tenant_table_has_forced_rls() { }   // db/checks/rls_forced.sql
}
