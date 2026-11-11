using System.Text.Json;
using Cortex.Agents;
using Cortex.Core;
using Microsoft.EntityFrameworkCore;
using Pgvector;
using Pgvector.EntityFrameworkCore;

namespace Cortex.Data;

internal static class TenantTx
{
    /// <summary>Every database call runs in its own short transaction, which pins the tenant (interceptor).</summary>
    public static async Task<T> RunAsync<T>(CortexDbContext db, Func<Task<T>> work, CancellationToken ct)
    {
        await using var tx = await db.Database.BeginTransactionAsync(ct);
        var result = await work();
        await tx.CommitAsync(ct);
        return result;
    }
}

public sealed class EfAgentCatalog(CortexDbContext db) : IAgentCatalog
{
    public Task<AgentDefinition?> FindByNameAsync(string name, CancellationToken ct)
        => TenantTx.RunAsync(db, async () => Map(await db.Agents.AsNoTracking().FirstOrDefaultAsync(a => a.Name == name, ct)), ct);

    public Task<AgentDefinition?> FindByIdAsync(Guid id, CancellationToken ct)
        => TenantTx.RunAsync(db, async () => Map(await db.Agents.AsNoTracking().FirstOrDefaultAsync(a => a.Id == id, ct)), ct);

    private static AgentDefinition? Map(Agent? a) => a is null ? null
        : new AgentDefinition(a.Id, a.Name, a.SystemPrompt, a.Model, a.Tools, a.MaxSteps, a.TokenBudget)
        { MemoryNamespaces = a.MemoryNamespaces };
}

public sealed class EfMemoryStore(CortexDbContext db, IContentProtector protector, ITenantContextAccessor tenant) : IMemoryStore
{
    public Task<IReadOnlyList<RecalledMemory>> SearchAsync(float[] embedding, IReadOnlyList<string> namespaces, int limit, CancellationToken ct)
        => TenantTx.RunAsync(db, async () =>
        {
            var query = new Vector(embedding);
            var ns = namespaces.ToArray();
            var rows = await db.MemoryItems.AsNoTracking()
                .Where(m => ns.Contains(m.Namespace))
                .OrderBy(m => m.Embedding.CosineDistance(query))
                .Take(limit)
                .Select(m => new { m.Id, m.Namespace, m.Content, m.Source, m.Trust, m.RunId, Distance = m.Embedding.CosineDistance(query) })
                .ToListAsync(ct);
            var tenantId = tenant.Current.TenantId;
            return (IReadOnlyList<RecalledMemory>)rows
                .Select(r => new RecalledMemory(r.Id, r.Namespace, protector.Unprotect(tenantId, r.Content), r.Source, r.Trust, r.RunId, r.Distance))
                .ToList();
        }, ct);

    public Task WriteItemAsync(NewMemory item, CancellationToken ct)
        => TenantTx.RunAsync(db, async () =>
        {
            if (item.Embedding.Length != 1024)
                throw new InvalidOperationException($"Embedding has {item.Embedding.Length} dimensions, schema expects 1024.");
            var tenantId = tenant.Current.TenantId;
            db.MemoryItems.Add(new MemoryItem
            {
                Id = Guid.NewGuid(), TenantId = tenantId, Namespace = item.Namespace,
                Content = protector.Protect(tenantId, item.Content), Embedding = new Vector(item.Embedding),
                RunId = item.RunId, AgentId = item.AgentId, Source = item.Source, Trust = item.Trust,
            });
            return await db.SaveChangesAsync(ct);
        }, ct);

    public Task WriteEpisodeAsync(Guid runId, Guid agentId, string content, string source, CancellationToken ct)
        => TenantTx.RunAsync(db, async () =>
        {
            var tenantId = tenant.Current.TenantId;
            db.MemoryEpisodes.Add(new MemoryEpisode
            {
                Id = Guid.NewGuid(), TenantId = tenantId, RunId = runId, AgentId = agentId,
                Content = protector.Protect(tenantId, content), Source = source,
            });
            return await db.SaveChangesAsync(ct);
        }, ct);
}

public sealed class EfAuditLog(CortexDbContext db, ITenantContextAccessor tenant) : IAuditLog
{
    public Task WriteAsync(string kind, string actor, object detail, CancellationToken ct)
        => TenantTx.RunAsync(db, async () =>
        {
            db.AuditEvents.Add(new AuditEvent
            {
                TenantId = tenant.Current.TenantId, Kind = kind, Actor = actor, Detail = JsonSerializer.Serialize(detail),
            });
            return await db.SaveChangesAsync(ct);
        }, ct);
}
