using Cortex.Core;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;

namespace Cortex.Agents;

public static class AgentsModule
{
    /// <summary>Gateway validates its endpoint at startup. Tools, registry and runtime are Scoped (tenant bound).</summary>
    public static IServiceCollection AddCortexAgents(this IServiceCollection services, IConfiguration configuration, CortexProfile profile)
    {
        var model = configuration.GetSection(ModelOptions.Section).Get<ModelOptions>() ?? new ModelOptions();
        OpenAiCompatibleGateway.Validate(model, profile);   // fail at startup, not on the first request

        services.AddSingleton(model);
        services.AddSingleton<ILlmGateway>(sp =>
            new OpenAiCompatibleGateway(model, profile, sp.GetRequiredService<ITenantContextAccessor>()));
        services.AddSingleton<IOutputPolicy, BasicOutputPolicy>();
        services.AddScoped<AgentRunContext>();
        services.AddScoped<ITenantBoundTool, SearchMemoryTool>();
        services.AddScoped<ToolRegistry>();
        services.AddScoped<IAgentRuntime, AgentRuntime>();
        return services;
    }
}
