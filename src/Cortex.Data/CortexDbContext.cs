using Cortex.Core;
using Microsoft.EntityFrameworkCore;
using Pgvector;

namespace Cortex.Data;

/// <summary>
/// The global query filter is a second layer. Postgres FORCED RLS is the guarantee
/// (db/migrations/0001_tenancy.sql). Remove this filter and isolation still holds.
/// Column names are mapped explicitly to the snake_case schema in db/migrations.
/// </summary>
public sealed class CortexDbContext(DbContextOptions<CortexDbContext> options, ITenantContextAccessor tenant)
    : DbContext(options)
{
    private Guid CurrentTenantId => tenant.Current.TenantId;

    public DbSet<Agent> Agents => Set<Agent>();
    public DbSet<MemoryItem> MemoryItems => Set<MemoryItem>();
    public DbSet<MemoryEpisode> MemoryEpisodes => Set<MemoryEpisode>();
    public DbSet<AuditEvent> AuditEvents => Set<AuditEvent>();

    protected override void OnModelCreating(ModelBuilder b)
    {
        b.HasDefaultSchema("cortex");
        b.HasPostgresExtension("vector");

        b.Entity<Agent>(e =>
        {
            e.ToTable("agents");
            e.Property(a => a.Id).HasColumnName("id");
            e.Property(a => a.TenantId).HasColumnName("tenant_id");
            e.Property(a => a.Name).HasColumnName("name");
            e.Property(a => a.SystemPrompt).HasColumnName("system_prompt");
            e.Property(a => a.Model).HasColumnName("model");
            e.Property(a => a.Tools).HasColumnName("tools");
            e.Property(a => a.MemoryNamespaces).HasColumnName("memory_namespaces");
            e.Property(a => a.MaxSteps).HasColumnName("max_steps");
            e.Property(a => a.TokenBudget).HasColumnName("token_budget");
            e.Property(a => a.ExternalShare).HasColumnName("external_share");
            e.HasQueryFilter(a => a.TenantId == CurrentTenantId);
        });

        b.Entity<MemoryItem>(e =>
        {
            e.ToTable("memory_item");
            e.Property(m => m.Id).HasColumnName("id");
            e.Property(m => m.TenantId).HasColumnName("tenant_id");
            e.Property(m => m.Namespace).HasColumnName("namespace");
            e.Property(m => m.Content).HasColumnName("content");
            e.Property(m => m.Embedding).HasColumnName("embedding").HasColumnType("vector(1024)");
            e.Property(m => m.RunId).HasColumnName("run_id");
            e.Property(m => m.AgentId).HasColumnName("agent_id");
            e.Property(m => m.Source).HasColumnName("source");
            e.Property(m => m.SourceRef).HasColumnName("source_ref");
            e.Property(m => m.Trust).HasColumnName("trust");
            e.Property(m => m.CreatedAt).HasColumnName("created_at").ValueGeneratedOnAdd();
            e.HasQueryFilter(m => m.TenantId == CurrentTenantId);
        });

        b.Entity<MemoryEpisode>(e =>
        {
            e.ToTable("memory_episode");
            e.Property(m => m.Id).HasColumnName("id");
            e.Property(m => m.TenantId).HasColumnName("tenant_id");
            e.Property(m => m.RunId).HasColumnName("run_id");
            e.Property(m => m.AgentId).HasColumnName("agent_id");
            e.Property(m => m.Content).HasColumnName("content");
            e.Property(m => m.Source).HasColumnName("source");
            e.Property(m => m.SourceRef).HasColumnName("source_ref");
            e.Property(m => m.CreatedAt).HasColumnName("created_at").ValueGeneratedOnAdd();
            e.HasQueryFilter(m => m.TenantId == CurrentTenantId);
        });

        b.Entity<AuditEvent>(e =>
        {
            e.ToTable("audit_event");
            e.Property(a => a.Id).HasColumnName("id").UseIdentityAlwaysColumn();
            e.Property(a => a.TenantId).HasColumnName("tenant_id");
            e.Property(a => a.Kind).HasColumnName("kind");
            e.Property(a => a.Actor).HasColumnName("actor");
            e.Property(a => a.Detail).HasColumnName("detail").HasColumnType("jsonb");
            e.Property(a => a.CreatedAt).HasColumnName("created_at").ValueGeneratedOnAdd();
            e.HasQueryFilter(a => a.TenantId == CurrentTenantId);
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
    public string[] MemoryNamespaces { get; set; } = ["default"];
    public int MaxSteps { get; set; } = 8;
    public int TokenBudget { get; set; } = 20000;
    public bool ExternalShare { get; set; }
}

public sealed class MemoryItem
{
    public Guid Id { get; set; }
    public Guid TenantId { get; set; }
    public string Namespace { get; set; } = "default";
    public byte[] Content { get; set; } = [];          // ciphertext, bound to the tenant (IContentProtector)
    public Vector Embedding { get; set; } = new(new float[1024]);
    public Guid? RunId { get; set; }
    public Guid? AgentId { get; set; }
    public string Source { get; set; } = "run";        // run | mcp:n8n | mcp:assistant | admin
    public string? SourceRef { get; set; }
    public string Trust { get; set; } = "retrieved";   // user | retrieved
    public DateTime CreatedAt { get; set; }
}

public sealed class MemoryEpisode
{
    public Guid Id { get; set; }
    public Guid TenantId { get; set; }
    public Guid RunId { get; set; }
    public Guid AgentId { get; set; }
    public byte[] Content { get; set; } = [];          // ciphertext
    public string Source { get; set; } = "run";
    public string? SourceRef { get; set; }
    public DateTime CreatedAt { get; set; }
}

public sealed class AuditEvent
{
    public long Id { get; set; }
    public Guid TenantId { get; set; }
    public string Kind { get; set; } = "";
    public string Actor { get; set; } = "";
    public string Detail { get; set; } = "{}";
    public DateTime CreatedAt { get; set; }
}
