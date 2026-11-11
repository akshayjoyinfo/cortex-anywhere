using System.Diagnostics;
using Microsoft.AspNetCore.Http;

namespace Cortex.Core;

/// <summary>Written once by the installer (infra/windows, Cortex.Windows/LocalInstall). Never by a request.</summary>
public sealed class LocalInstallOptions
{
    public const string Section = "Cortex:Local";

    public Guid TenantId { get; set; }
    public string TenantName { get; set; } = "";
    public int Port { get; set; } = 5080;
    public string SecretsDirectory { get; set; } = @"C:\ProgramData\Cortex\secrets";
}

/// <summary>
/// Local profile: one customer per machine, so the tenant is the install's tenant.
/// The caller must still be an authenticated Windows user (Negotiate); the subject is that user.
/// Same TenantContext and TenantScope as the server profile: everything downstream is unchanged.
/// </summary>
public sealed class LocalTenantMiddleware(RequestDelegate next, LocalInstallOptions install)
{
    public async Task InvokeAsync(HttpContext http)
    {
        if (http.User.Identity?.IsAuthenticated != true)
        {
            http.Response.StatusCode = StatusCodes.Status401Unauthorized;
            return;
        }

        var subject = http.User.Identity.Name ?? "unknown";
        Activity.Current?.SetTag("tenant.id", install.TenantId);

        using (TenantScope.Begin(new TenantContext(install.TenantId, "silo", subject)))
        {
            await next(http);
        }
    }
}
