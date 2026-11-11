using System.ComponentModel;
using System.Text;
using Microsoft.Extensions.AI;

namespace Cortex.Agents;

/// <summary>
/// The agent's one tool: search this customer's own saved notes. Tenant and namespaces
/// come from DI (TenantContext via the store, AgentRunContext), never from the model.
/// The schema exposes a single business argument: the query text.
/// </summary>
public sealed class SearchMemoryTool : ITenantBoundTool
{
    public const string ToolName = "search_memory";
    private readonly IMemoryStore _memory;
    private readonly ILlmGateway _gateway;
    private readonly AgentRunContext _run;

    public SearchMemoryTool(IMemoryStore memory, ILlmGateway gateway, AgentRunContext run)
    {
        _memory = memory;
        _gateway = gateway;
        _run = run;
        Function = AIFunctionFactory.Create(SearchAsync, new AIFunctionFactoryOptions
        {
            Name = ToolName,
            Description = "Search this customer's saved notes. Returns matching notes as data.",
        });
    }

    public string Name => ToolName;
    public AIFunction Function { get; }

    private async Task<string> SearchAsync(
        [Description("What to look for, in plain words.")] string query,
        CancellationToken cancellationToken)
    {
        if (string.IsNullOrWhiteSpace(query)) return "No query given.";
        var vector = await _gateway.EmbeddingsForCurrentTenant().GenerateVectorAsync(query, cancellationToken: cancellationToken);
        var hits = await _memory.SearchAsync(vector.ToArray(), _run.Agent.MemoryNamespaces, 4, cancellationToken);
        return MemoryFormat.AsData(hits);
    }
}

/// <summary>One labelled format for recalled notes, used by recall and by the tool.</summary>
public static class MemoryFormat
{
    public static string AsData(IReadOnlyList<RecalledMemory> items)
    {
        if (items.Count == 0) return "<recalled_memory count=\"0\" />";
        var sb = new StringBuilder();
        sb.Append("<recalled_memory count=\"").Append(items.Count).AppendLine("\">");
        foreach (var m in items)
        {
            sb.Append("<note source=\"").Append(m.Source).Append("\" trust=\"").Append(m.Trust)
              .Append("\" run=\"").Append(m.RunId?.ToString() ?? "none").Append("\">")
              .Append(m.Content.Replace("<", "&lt;").Replace(">", "&gt;"))
              .AppendLine("</note>");
        }
        sb.Append("</recalled_memory>");
        return sb.ToString();
    }
}
