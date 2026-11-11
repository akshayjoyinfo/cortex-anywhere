using Microsoft.Extensions.AI;

namespace Cortex.Agents;

/// <summary>Shared stateless loop. Note: no tenant parameter anywhere; it comes from TenantContext.</summary>
public interface IAgentRuntime
{
    Task<AgentRunResult> RunAsync(AgentRunRequest request, CancellationToken cancellationToken);
}

public sealed record AgentRunRequest(Guid AgentId, Guid RunId, string Input);

public sealed record AgentRunResult(string Output, int Steps, AgentStopReason StopReason)
{
    public IReadOnlyList<ToolCallRecord> ToolCalls { get; init; } = [];
    public RunMetrics? Metrics { get; init; }
}

public enum AgentStopReason { Answered, MaxSteps, Budget, Quarantined, Refused }

/// <summary>Every tool call the model asked for, allowed or not. Arguments are kept for audit.</summary>
public sealed record ToolCallRecord(string Name, bool Allowed, string Arguments);

public sealed record RunMetrics(
    int RecalledItems, long InputTokens, long OutputTokens,
    long EmbedMs, long ModelMs, long TotalMs, double OutputTokensPerSecond);

// Per agent allow list: ToolRegistry.ForAgent returns an AgentToolSet (Tools.cs).
// Unknown or unlisted tool names never resolve.

/// <summary>
/// A tool already bound to the current tenant by DI. Its schema exposes business
/// arguments only: no tenant id, connection id, database or namespace.
/// </summary>
public interface ITenantBoundTool
{
    string Name { get; }
    AIFunction Function { get; }
}

/// <summary>Model output is untrusted input: checked before it reaches a tool, user or memory.</summary>
public interface IOutputPolicy
{
    OutputVerdict Inspect(string modelOutput);
}

public sealed record OutputVerdict(bool Allowed, string Sanitised, string? Reason);

/// <summary>
/// Only path to a model. Implementation sets vLLM cache_salt = HMAC(tenant id)
/// and picks the tenant's own model for silo tier (server profile, not yet).
/// </summary>
public interface ILlmGateway
{
    IChatClient ForCurrentTenant();
    IEmbeddingGenerator<string, Embedding<float>> EmbeddingsForCurrentTenant();
}

// ---- Ports implemented by Cortex.Data. Every call runs in a tenant pinned transaction.

public interface IAgentCatalog
{
    Task<AgentDefinition?> FindByNameAsync(string name, CancellationToken cancellationToken);
    Task<AgentDefinition?> FindByIdAsync(Guid id, CancellationToken cancellationToken);
}

/// <summary>Recalled memory is data with provenance, never instructions.</summary>
public sealed record RecalledMemory(Guid Id, string Namespace, string Content, string Source, string Trust, Guid? RunId, double Distance);

public sealed record NewMemory(string Namespace, string Content, float[] Embedding, Guid RunId, Guid AgentId, string Source, string Trust);

public interface IMemoryStore
{
    Task<IReadOnlyList<RecalledMemory>> SearchAsync(float[] embedding, IReadOnlyList<string> namespaces, int limit, CancellationToken cancellationToken);
    Task WriteItemAsync(NewMemory item, CancellationToken cancellationToken);
    Task WriteEpisodeAsync(Guid runId, Guid agentId, string content, string source, CancellationToken cancellationToken);
}

public interface IAuditLog
{
    Task WriteAsync(string kind, string actor, object detail, CancellationToken cancellationToken);
}
