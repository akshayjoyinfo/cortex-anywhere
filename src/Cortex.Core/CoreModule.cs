using Microsoft.Extensions.DependencyInjection;

namespace Cortex.Core;

public static class CoreModule
{
    /// <summary>
    /// Tenant scoped services are registered Scoped and read ITenantContextAccessor.
    /// Stub: per tenant overrides (silo connection, feature flags) go here.
    /// </summary>
    public static IServiceCollection AddCortexCore(this IServiceCollection services)
    {
        services.AddSingleton<ITenantContextAccessor, TenantScope>();
        return services;
    }
}
