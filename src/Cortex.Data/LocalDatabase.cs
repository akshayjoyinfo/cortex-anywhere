using Cortex.Core;
using Npgsql;

namespace Cortex.Data;

/// <summary>Written by the installer. Holds no password: that lives in the secret store.</summary>
public sealed class LocalDatabaseOptions
{
    public const string Section = "Cortex:Database";

    public string Host { get; set; } = "127.0.0.1";
    public int Port { get; set; } = 5432;
    public string Database { get; set; } = "cortex";
    public string Username { get; set; } = "cortex_app";
    public string PasswordSecret { get; set; } = "pg-app";
}

public static class LocalDatabase
{
    /// <summary>
    /// Local profile connection: loopback only, as cortex_app (no BYPASSRLS), password from DPAPI.
    /// Data access itself is identical in both profiles: same interceptors, same FORCED RLS.
    /// </summary>
    public static string ConnectionString(LocalDatabaseOptions options, ISecretStore secrets)
    {
        if (options.Host is not ("127.0.0.1" or "::1" or "localhost"))
            throw new InvalidOperationException($"Local profile database host must be loopback, got '{options.Host}'.");

        return new NpgsqlConnectionStringBuilder
        {
            Host = options.Host,
            Port = options.Port,
            Database = options.Database,
            Username = options.Username,
            Password = secrets.Get(options.PasswordSecret),
            ApplicationName = "cortex",
        }.ConnectionString;
    }
}
