using System.Security.Cryptography;
using Cortex.Agents;
using Cortex.Core;
using Cortex.Data;
using Microsoft.EntityFrameworkCore;
using Npgsql;
using Pgvector.EntityFrameworkCore;
using Xunit;

namespace Cortex.SecurityTests;

/// <summary>
/// Leak suite against a real Postgres 16 + pgvector with two canary tenants, connected as
/// cortex_app. Runs in CI (security job) and on the Windows field server (verify-app.ps1).
/// Each test seeds its own tenants, so tests never depend on each other.
/// </summary>
public sealed class TenantLeakTests
{
    [Fact]
    public async Task Query_without_tenant_returns_zero_rows()
    {
        Pg.Require();
        await Pg.SeedAsync();
        await using var c = new NpgsqlConnection(Pg.AsApp());
        await c.OpenAsync();
        Assert.Equal(0L, await Pg.Scalar<long>(c, null, "SELECT count(*) FROM cortex.memory_item"));
        Assert.Equal(0L, await Pg.Scalar<long>(c, null, "SELECT count(*) FROM cortex.agents"));
    }

    [Fact]
    public async Task Empty_string_tenant_returns_zero_rows()
    {
        Pg.Require();
        await Pg.SeedAsync();
        await using var c = new NpgsqlConnection(Pg.AsApp());
        await c.OpenAsync();
        await using var tx = await c.BeginTransactionAsync();
        await using (var cmd = new NpgsqlCommand("SELECT set_config('app.tenant_id', '', true)", c, tx)) await cmd.ExecuteNonQueryAsync();
        Assert.Equal(0L, await Pg.Scalar<long>(c, tx, "SELECT count(*) FROM cortex.memory_item"));
    }

    [Fact]
    public async Task Raw_sql_without_predicate_sees_only_own_rows()
    {
        Pg.Require();
        var s = await Pg.SeedAsync();
        await using var c = new NpgsqlConnection(Pg.AsApp());
        await c.OpenAsync();
        await using var tx = await Pg.PinAsync(c, s.A);
        await using var cmd = new NpgsqlCommand("SELECT DISTINCT tenant_id FROM cortex.memory_item", c, tx);
        var tenants = new List<Guid>();
        await using (var r = await cmd.ExecuteReaderAsync()) while (await r.ReadAsync()) tenants.Add(r.GetGuid(0));
        Assert.Equal(new[] { s.A }, tenants);
    }

    [Fact]
    public async Task Pooled_connection_does_not_carry_previous_tenant()
    {
        Pg.Require();
        var s = await Pg.SeedAsync();
        var cs = Pg.AsApp(maxPool: 1);   // one physical connection: the second open must reuse it
        int pid1, pid2;
        await using (var c1 = new NpgsqlConnection(cs))
        {
            await c1.OpenAsync();
            await using var tx = await Pg.PinAsync(c1, s.A);
            pid1 = await Pg.Scalar<int>(c1, tx, "SELECT pg_backend_pid()");
            Assert.True(await Pg.Scalar<long>(c1, tx, "SELECT count(*) FROM cortex.memory_item") > 0);
            await tx.CommitAsync();
        }
        await using var c2 = new NpgsqlConnection(cs);
        await c2.OpenAsync();
        pid2 = await Pg.Scalar<int>(c2, null, "SELECT pg_backend_pid()");
        Assert.Equal(pid1, pid2);
        Assert.Equal(0L, await Pg.Scalar<long>(c2, null, "SELECT count(*) FROM cortex.memory_item"));
    }

    [Fact]
    public async Task Vector_search_never_returns_other_tenant_canary()
    {
        Pg.Require();
        var s = await Pg.SeedAsync();
        await using var c = new NpgsqlConnection(Pg.AsApp());
        await c.OpenAsync();
        await using var tx = await Pg.PinAsync(c, s.A);
        // Query with B's exact embedding: if isolation failed, B's canary would rank first.
        await using var cmd = new NpgsqlCommand(
            $"SELECT tenant_id, convert_from(content, 'UTF8') FROM cortex.memory_item ORDER BY embedding <=> '{Pg.Literal(Pg.Axis(1))}'::vector LIMIT 10", c, tx);
        await using var r = await cmd.ExecuteReaderAsync();
        var rows = 0;
        while (await r.ReadAsync())
        {
            rows++;
            Assert.Equal(s.A, r.GetGuid(0));
            Assert.DoesNotContain(s.Marker, r.GetString(1));
        }
        Assert.True(rows > 0);
    }

    [Fact]
    public async Task Tenant_a_cannot_write_into_tenant_b()
    {
        Pg.Require();
        var s = await Pg.SeedAsync();
        await using var c = new NpgsqlConnection(Pg.AsApp());
        await c.OpenAsync();
        await using var tx = await Pg.PinAsync(c, s.A);
        var ex = await Assert.ThrowsAsync<PostgresException>(() => Pg.Exec(c,
            "INSERT INTO cortex.agents (tenant_id, name, system_prompt) VALUES (@b, 'x', 'x')", ("b", s.B)));
        Assert.Equal(PostgresErrorCodes.InsufficientPrivilege, ex.SqlState);   // RLS WITH CHECK
    }

    [Fact]
    public async Task Ef_memory_store_as_tenant_a_never_returns_tenant_b_canary()
    {
        Pg.Require();
        var s = await Pg.SeedAsync();
        var protector = new AesGcmContentProtector(RandomNumberGenerator.GetBytes(32));
        var accessor = new TenantScope();

        // B writes through the real store (encrypted, tenant pinned, RLS WITH CHECK).
        using (TenantScope.Begin(new TenantContext(s.B, "silo", "test")))
        {
            await using var dbB = Db(accessor);
            await new EfMemoryStore(dbB, protector, accessor).WriteItemAsync(
                new NewMemory("default", s.Marker + " support opens 07:00", Pg.Axis(1), Guid.NewGuid(), Guid.Empty, "admin", "user"), default);
        }

        // A has its own note, then searches with B's exact embedding.
        using (TenantScope.Begin(new TenantContext(s.A, "silo", "test")))
        {
            await using var dbA = Db(accessor);
            var store = new EfMemoryStore(dbA, protector, accessor);
            await store.WriteItemAsync(new NewMemory("default", "A support opens 09:00", Pg.Axis(0), Guid.NewGuid(), Guid.Empty, "admin", "user"), default);
            var hits = await store.SearchAsync(Pg.Axis(1), ["default"], 10, default);
            Assert.Contains(hits, h => h.Content == "A support opens 09:00");   // the search works
            Assert.DoesNotContain(hits, h => h.Content.Contains(s.Marker));    // and never crosses tenants
        }
    }

    [Fact]
    public async Task Every_tenant_table_has_forced_rls()   // same rule as db/checks/rls_forced.sql
    {
        Pg.Require();
        await using var c = new NpgsqlConnection(Pg.Admin);
        await c.OpenAsync();
        Assert.Equal(0L, await Pg.Scalar<long>(c, null,
            "SELECT count(*) FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace " +
            "WHERE n.nspname = 'cortex' AND c.relkind = 'r' AND NOT (c.relrowsecurity AND c.relforcerowsecurity)"));
    }

    internal static CortexDbContext Db(ITenantContextAccessor tenant)
    {
        var options = new DbContextOptionsBuilder<CortexDbContext>()
            .UseNpgsql(Pg.AsApp(), n => n.UseVector())
            .AddInterceptors(new TenantTransactionInterceptor(tenant), new RequireTransactionInterceptor())
            .Options;
        return new CortexDbContext(options, tenant);
    }

    private const string ServerProfile = "Server profile path (Keycloak JWT, MCP, Hangfire, Valkey) is not deployed in the field test.";

    [Fact(Skip = ServerProfile)] public void Api_with_tenant_a_token_never_sees_b_canary() { }
    [Fact(Skip = ServerProfile)] public void Mcp_with_tenant_a_token_never_sees_b_canary() { }
    [Fact(Skip = ServerProfile)] public void Job_envelope_with_edited_tenant_is_rejected() { }
    [Fact(Skip = ServerProfile)] public void Valkey_cross_prefix_read_yields_ciphertext_only() { }
}
