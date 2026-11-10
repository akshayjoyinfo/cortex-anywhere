using System.Diagnostics;
using Microsoft.AspNetCore.Http;

namespace Cortex.Core;

/// <summary>Reads tenant_id from the validated JWT only. Never from body, query or header.</summary>
public sealed class TenantMiddleware(RequestDelegate next)
{
    public async Task InvokeAsync(HttpContext http)
    {
        var claim = http.User.FindFirst("tenant_id")?.Value;
        if (!Guid.TryParse(claim, out var tenantId) || tenantId == Guid.Empty)
        {
            http.Response.StatusCode = StatusCodes.Status401Unauthorized;
            return;
        }

        var tier = http.User.FindFirst("tenant_tier")?.Value ?? "pooled";
        var subject = http.User.FindFirst("sub")?.Value ?? "unknown";
        Activity.Current?.SetTag("tenant.id", tenantId);

        using (TenantScope.Begin(new TenantContext(tenantId, tier, subject)))
        {
            await next(http);
        }
    }
}
