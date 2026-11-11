using Cortex.Agents;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.DependencyInjection;
using Pgvector.EntityFrameworkCore;

namespace Cortex.Data;

public static class DataModule
{
    /// <summary>Connects as cortex_app (no table ownership, no BYPASSRLS). Server: through PgBouncer.</summary>
    public static IServiceCollection AddCortexData(this IServiceCollection services, string connectionString)
    {
        services.AddSingleton<TenantTransactionInterceptor>();
        services.AddSingleton<RequireTransactionInterceptor>();
        services.AddDbContext<CortexDbContext>((sp, o) => o
            .UseNpgsql(connectionString, npgsql => npgsql.UseVector())
            .AddInterceptors(
                sp.GetRequiredService<TenantTransactionInterceptor>(),
                sp.GetRequiredService<RequireTransactionInterceptor>()));
        services.AddScoped<IAgentCatalog, EfAgentCatalog>();
        services.AddScoped<IMemoryStore, EfMemoryStore>();
        services.AddScoped<IAuditLog, EfAuditLog>();
        return services;
    }
}
