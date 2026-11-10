using System.Data.Common;
using Cortex.Core;
using Microsoft.EntityFrameworkCore.Diagnostics;

namespace Cortex.Data;

/// <summary>
/// Pins the tenant on every transaction: set_config('app.tenant_id', id, true).
/// Transaction local, so PgBouncer (transaction mode) never carries it to another tenant.
/// </summary>
public sealed class TenantTransactionInterceptor(ITenantContextAccessor tenant) : DbTransactionInterceptor
{
    private const string Sql = "SELECT set_config('app.tenant_id', @tenant, true)";

    public override DbTransaction TransactionStarted(
        DbConnection connection, TransactionEndEventData eventData, DbTransaction result)
    {
        using var cmd = Build(connection, result);
        cmd.ExecuteNonQuery();
        return result;
    }

    public override async ValueTask<DbTransaction> TransactionStartedAsync(
        DbConnection connection, TransactionEndEventData eventData, DbTransaction result,
        CancellationToken cancellationToken = default)
    {
        await using var cmd = Build(connection, result);
        await cmd.ExecuteNonQueryAsync(cancellationToken);
        return result;
    }

    private DbCommand Build(DbConnection connection, DbTransaction transaction)
    {
        var cmd = connection.CreateCommand();
        cmd.Transaction = transaction;
        cmd.CommandText = Sql;
        var p = cmd.CreateParameter();
        p.ParameterName = "tenant";
        p.Value = tenant.Current.TenantId.ToString();   // throws when no tenant: fail closed
        cmd.Parameters.Add(p);
        return cmd;
    }
}

/// <summary>
/// A command outside a transaction has no tenant pinned. Refuse it instead of
/// relying on RLS returning zero rows. Callers open a unit of work first.
/// </summary>
public sealed class RequireTransactionInterceptor : DbCommandInterceptor
{
    public override InterceptionResult<DbDataReader> ReaderExecuting(
        DbCommand command, CommandEventData eventData, InterceptionResult<DbDataReader> result)
        => Guard(command, result);

    public override ValueTask<InterceptionResult<DbDataReader>> ReaderExecutingAsync(
        DbCommand command, CommandEventData eventData, InterceptionResult<DbDataReader> result,
        CancellationToken cancellationToken = default)
        => ValueTask.FromResult(Guard(command, result));

    public override InterceptionResult<int> NonQueryExecuting(
        DbCommand command, CommandEventData eventData, InterceptionResult<int> result)
        => Guard(command, result);

    public override ValueTask<InterceptionResult<int>> NonQueryExecutingAsync(
        DbCommand command, CommandEventData eventData, InterceptionResult<int> result,
        CancellationToken cancellationToken = default)
        => ValueTask.FromResult(Guard(command, result));

    public override InterceptionResult<object> ScalarExecuting(
        DbCommand command, CommandEventData eventData, InterceptionResult<object> result)
        => Guard(command, result);

    public override ValueTask<InterceptionResult<object>> ScalarExecutingAsync(
        DbCommand command, CommandEventData eventData, InterceptionResult<object> result,
        CancellationToken cancellationToken = default)
        => ValueTask.FromResult(Guard(command, result));

    private static T Guard<T>(DbCommand command, T result)
        => command.Transaction is null
            ? throw new InvalidOperationException("Command outside a tenant transaction. Failing closed.")
            : result;
}
