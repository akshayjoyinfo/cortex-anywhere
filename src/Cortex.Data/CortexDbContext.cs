using Cortex.Core;
using Microsoft.EntityFrameworkCore;
using Pgvector;

namespace Cortex.Data;

/// <summary>
/// The global query filter is a second layer. Postgres FORCED RLS is the guarantee
/// (db/migrations/0001_tenancy.sql). Remove this filter and isolation still holds.
/// </summary>
public sealed class CortexDbContext(DbContextOptions<CortexDbContext> options, ITenantContextAccessor tenant)
    : DbContext(options)
{
    private Guid CurrentTenantId => tenant.Current.TenantId;

    public DbSet<Agent> Agents => Set<Agent>();
    public DbSet<MemoryItem> MemoryItems => Set<MemoryItem>();

    protected override void OnModelCreating(ModelBuilder b)
    {
        b.HasDefaultSchema("cortex");
        b.HasPostgresExtension("vector");

        b.Entity<Agent>(e =>
        {
            e.ToTable("agents");
            e.HasQueryFilter(a => a.TenantId == CurrentTenantId);
        });

        b.Entity<MemoryItem>(e =>
        {
            e.ToTable("memory_item");
            e.Property(m => m.Embedding).HasColumnType("vector(1024)");
            e.HasQueryFilter(m => m.TenantId == CurrentTenantId);
        });
    }
}

public sealed class Agent
{
    public Guid Id { get; set; }
    public Guid TenantId { get; set; }
    public string Name { get; set; } = "";
    public string SystemPrompt { get; set; } = "";
    public string Model { get; set; } = "qwen3-14b";
    public string[] Tools { get; set; } = [];
    public bool ExternalShare { get; set; }
}

public sealed class MemoryItem
{
    public Guid Id { get; set; }
    public Guid TenantId { get; set; }
    public string Namespace { get; set; } = "default";
    public byte[] Content { get; set; } = [];          // ciphertext, tenant Transit key
    public Vector Embedding { get; set; } = new(new float[1024]);
    public Guid? RunId { get; set; }
    public Guid? AgentId { get; set; }
    public string Source { get; set; } = "run";        // run | mcp:n8n | mcp:assistant | admin
    public string? SourceRef { get; set; }
    public string Trust { get; set; } = "retrieved";   // user | retrieved
}
