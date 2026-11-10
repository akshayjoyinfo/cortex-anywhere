using Hangfire;
using Hangfire.PostgreSql;
using Microsoft.Extensions.DependencyInjection;

namespace Cortex.Worker;

public static class WorkerModule
{
    /// <summary>Worker role only. Egress leaves via Smokescreen (HTTPS_PROXY), nothing else.</summary>
    public static IServiceCollection AddCortexWorker(this IServiceCollection services, string connectionString)
    {
        services.AddHangfire(c => c.UsePostgreSqlStorage(o => o.UseNpgsqlConnection(connectionString)));
        services.AddHangfireServer();
        services.AddScoped<AgentRunJob>();
        return services;
    }
}
