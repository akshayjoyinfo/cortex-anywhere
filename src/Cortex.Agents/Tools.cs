using System.Diagnostics.CodeAnalysis;

namespace Cortex.Agents;

/// <summary>An agent row as the runtime sees it. Tools is the agent's allow list.</summary>
public sealed record AgentDefinition(
    Guid Id, string Name, string SystemPrompt, string Model,
    IReadOnlyList<string> Tools, int MaxSteps, int TokenBudget);

/// <summary>
/// Every tool registered in DI for the current scope. Tools are bound to the tenant
/// in code (constructor injection), so a tool cannot be pointed at another tenant by
/// an argument. Registered Scoped, like the tools it holds.
/// </summary>
public sealed class ToolRegistry
{
    private readonly Dictionary<string, ITenantBoundTool> _tools = new(StringComparer.Ordinal);

    public ToolRegistry(IEnumerable<ITenantBoundTool> tools)
    {
        foreach (var tool in tools)
        {
            if (!_tools.TryAdd(tool.Name, tool))
                throw new InvalidOperationException($"Tool name '{tool.Name}' is registered twice.");
        }
    }

    public IReadOnlyCollection<string> Registered => _tools.Keys;

    /// <summary>The intersection of the agent's allow list and the registered tools. Nothing else resolves.</summary>
    public AgentToolSet ForAgent(AgentDefinition agent)
    {
        var allowed = new Dictionary<string, ITenantBoundTool>(StringComparer.Ordinal);
        var unresolved = new List<string>();
        foreach (var name in agent.Tools.Distinct(StringComparer.Ordinal))
        {
            if (_tools.TryGetValue(name, out var tool)) allowed[name] = tool;
            else unresolved.Add(name);
        }
        return new AgentToolSet(agent.Id, allowed, unresolved);
    }
}

/// <summary>
/// What one agent may call in one run. The model only ever sees these tools, and every
/// call the model makes is checked again here by exact name before it executes.
/// </summary>
public sealed class AgentToolSet(Guid agentId, IReadOnlyDictionary<string, ITenantBoundTool> allowed, IReadOnlyList<string> unresolved)
{
    public Guid AgentId { get; } = agentId;
    public IReadOnlyList<ITenantBoundTool> Tools { get; } = [.. allowed.Values];

    /// <summary>Allow listed names with no registered tool. Reported, never resolved.</summary>
    public IReadOnlyList<string> Unresolved { get; } = unresolved;

    public bool TryResolve(string name, [NotNullWhen(true)] out ITenantBoundTool? tool)
        => allowed.TryGetValue(name, out tool);
}
