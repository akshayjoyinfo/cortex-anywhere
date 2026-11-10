using Microsoft.Extensions.DependencyInjection;

namespace Cortex.Agents;

public static class AgentsModule
{
    /// <summary>Stub: runtime, gateway, allow list and output policy are registered Scoped here.</summary>
    public static IServiceCollection AddCortexAgents(this IServiceCollection services) => services;
}
