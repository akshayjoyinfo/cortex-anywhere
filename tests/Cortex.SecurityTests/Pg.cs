using System.Globalization;
using Npgsql;
using Xunit;

namespace Cortex.SecurityTests;

/// <summary>
/// Database under test. CORTEX_TEST_PG is a superuser connection to a database with
/// db/migrations applied (CI: the security job's Postgres; field server: a throwaway
/// database made by verify-app.ps1). The app path connects as cortex_app via the
/// startup option role=cortex_app, so RLS applies exactly as in production.
/// </summary>
internal static class Pg
{
    public static string? Admin => Environment.GetEnvironmentVariable("CORTEX_TEST_PG");

    /// <summary>The running test's token (xUnit1051): cancelled runs stop database work promptly.</summary>
    public static CancellationToken Ct => TestContext.Current.CancellationToken;

    public static void Require()
    {
        if (string.IsNullOrWhiteSpace(Admin))
            Assert.Skip("CORTEX_TEST_PG not set (CI security job and verify-app.ps1 set it).");
    }

    public static string AsApp(int maxPool = 10) => new NpgsqlConnectionStringBuilder(Admin)
    {
        Options = "-c role=cortex_app",
        MaxPoolSize = maxPool,
        ApplicationName = "cortex-security-tests",
    }.ConnectionString;

    /// <summary>A 1024 dim unit vector along one axis: tenants get orthogonal embeddings.</summary>
    public static float[] Axis(int i)
    {
        var v = new float[1024];
        v[i] = 1f;
        return v;
    }

    public static string Literal(float[] v) => "[" + string.Join(",", v.Select(x => x.ToString(CultureInfo.InvariantCulture))) + "]";

    /// <summary>
    /// Two fresh tenants under one customer (same customer must still not leak), one plaintext row
    /// each in namespace 'plain' for SQL level tests. Store level tests use 'default' (encrypted).
    /// </summary>
    public static async Task<Seed> SeedAsync()
    {
        var seed = new Seed(Guid.NewGuid(), Guid.NewGuid(), Guid.NewGuid(), "BCANARY" + Guid.NewGuid().ToString("N")[..12]);
        await using var c = new NpgsqlConnection(Admin);
        await c.OpenAsync(Ct);
        await Exec(c, "INSERT INTO cortex.customers (id, legal_name) VALUES (@c, 'security-test')", ("c", seed.Customer));
        await Exec(c, "INSERT INTO cortex.tenants (id, customer_id, name) VALUES (@a, @c, 'sec-a'), (@b, @c, 'sec-b')",
            ("a", seed.A), ("b", seed.B), ("c", seed.Customer));
        foreach (var (tenant, axis, text) in new[] { (seed.A, 0, "A note"), (seed.B, 1, seed.Marker + " B secret") })
        {
            await Exec(c,
                "INSERT INTO cortex.memory_item (tenant_id, namespace, content, embedding, source, trust) " +
                $"VALUES (@t, 'plain', convert_to(@x, 'UTF8'), '{Literal(Axis(axis))}'::vector, 'admin', 'user')",
                ("t", tenant), ("x", text));
        }
        return seed;
    }

    public static async Task Exec(NpgsqlConnection c, string sql, params (string name, object value)[] ps)
    {
        await using var cmd = new NpgsqlCommand(sql, c);
        foreach (var (n, v) in ps) cmd.Parameters.AddWithValue(n, v);
        await cmd.ExecuteNonQueryAsync(Ct);
    }

    public static async Task<T?> Scalar<T>(NpgsqlConnection c, NpgsqlTransaction? tx, string sql)
    {
        await using var cmd = new NpgsqlCommand(sql, c, tx);
        var r = await cmd.ExecuteScalarAsync(Ct);
        return r is null or DBNull ? default : (T)Convert.ChangeType(r, typeof(T), CultureInfo.InvariantCulture);
    }

    public static async Task<NpgsqlTransaction> PinAsync(NpgsqlConnection c, Guid tenant)
    {
        var tx = await c.BeginTransactionAsync(Ct);
        await using var cmd = new NpgsqlCommand("SELECT set_config('app.tenant_id', @t, true)", c, tx);
        cmd.Parameters.AddWithValue("t", tenant.ToString());
        await cmd.ExecuteNonQueryAsync(Ct);
        return tx;
    }
}

internal sealed record Seed(Guid Customer, Guid A, Guid B, string Marker);
