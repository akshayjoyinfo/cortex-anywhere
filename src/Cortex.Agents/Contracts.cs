using Microsoft.Extensions.AI;

namespace Cortex.Agents;

/// <summary>Shared stateless loop. Note: no tenant parameter anywhere; it comes from TenantContext.</summary>
public interface IAgentRuntime
{
    Task<AgentRunResult> RunAsync(AgentRunRequest request, CancellationToken cancellationToken);
}

public sealed record AgentRunRequest(Guid AgentId, Guid RunId, string Input);

public sealed record AgentRunResult(string Output, int Steps, AgentStopReason StopReason);

public enum AgentStopReason { Answered, MaxSteps, Budget, Quarantined, Refused }

/// <summary>Per agent allow list. Unknown tool names never resolve.</summary>
public interface IToolAllowList
{
    bool IsAllowed(Guid agentId, string toolName);
}

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
/// and picks the tenant's own model for silo tier.
/// </summary>
public interface ILlmGateway
{
    IChatClient ForCurrentTenant();
}
