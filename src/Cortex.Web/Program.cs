using System.Net;
using Cortex.Agents;
using Cortex.Core;
using Cortex.Data;
using Cortex.Worker;
using Microsoft.AspNetCore.Authentication.Negotiate;
using Microsoft.EntityFrameworkCore;

var role = args.FirstOrDefault() ?? "web";
if (role is not ("web" or "worker"))
    throw new ArgumentException($"Unknown role '{role}'. Use web or worker.");

var builder = WebApplication.CreateBuilder(args.Skip(1).ToArray());

// One codebase, two profiles (ADR 011). The profile only decides where things come from.
var profile = CortexProfiles.Resolve(builder.Configuration);
string connectionString;

if (profile == CortexProfile.Local)
{
    // Install config written by Cortex.Windows/LocalInstall. Holds no secrets.
    builder.Configuration.AddJsonFile(
        builder.Configuration["CORTEX_CONFIG"] ?? @"C:\ProgramData\Cortex\config\cortex.json", optional: false);

    var install = builder.Configuration.GetSection(LocalInstallOptions.Section).Get<LocalInstallOptions>()
        ?? throw new InvalidOperationException($"{LocalInstallOptions.Section} missing from install config.");
    if (install.TenantId == Guid.Empty)
        throw new InvalidOperationException("Install config has no tenant. Failing closed.");
    if (!OperatingSystem.IsWindows())
        throw new PlatformNotSupportedException("The local profile runs on Windows (DPAPI, Windows authentication).");

    var secrets = new DpapiSecretStore(install.SecretsDirectory);
    var database = builder.Configuration.GetSection(LocalDatabaseOptions.Section).Get<LocalDatabaseOptions>() ?? new LocalDatabaseOptions();
    connectionString = LocalDatabase.ConnectionString(database, secrets);

    builder.Services.AddSingleton(install);
    builder.Services.AddSingleton<ISecretStore>(secrets);

    // Everything binds to loopback. ASPNETCORE_URLS and appsettings cannot widen it.
    builder.WebHost.ConfigureKestrel(k => k.Listen(IPAddress.Loopback, install.Port));
}
else
{
    connectionString = builder.Configuration.GetConnectionString("Cortex")
        ?? throw new InvalidOperationException("ConnectionStrings:Cortex is not set.");
    builder.Services.AddSingleton<ISecretStore, OpenBaoSecretStore>();
}

builder.AddServiceDefaults();
builder.Services.AddCortexCore();
builder.Services.AddCortexData(connectionString);
builder.Services.AddCortexAgents(builder.Configuration, profile);

if (role == "worker")
{
    builder.Services.AddCortexWorker(connectionString);
}
else if (profile == CortexProfile.Local)
{
    // The machine's own Windows accounts (Kerberos or NTLM). No identity provider to install.
    builder.Services.AddAuthentication(NegotiateDefaults.AuthenticationScheme).AddNegotiate();
    builder.Services.AddAuthorization();
}
else
{
    builder.Services.AddAuthentication().AddJwtBearer();   // Authority: Keycloak tenant realm (config)
    builder.Services.AddAuthorization();
}

var app = builder.Build();
app.MapDefaultEndpoints();

if (role == "web")
{
    app.UseAuthentication();
    app.UseAuthorization();
    app.UseWhen(
        c => c.Request.Path.StartsWithSegments("/api") || c.Request.Path.StartsWithSegments("/mcp"),
        b =>
        {
            if (profile == CortexProfile.Local) b.UseMiddleware<LocalTenantMiddleware>();
            else b.UseMiddleware<TenantMiddleware>();
        });

    app.MapGet("/api/whoami", (ITenantContextAccessor t) => Results.Ok(new
    {
        profile = profile.ToString().ToLowerInvariant(),
        tenant = t.Current.TenantId,
        tier = t.Current.Tier,
        subject = t.Current.Subject,
    })).RequireAuthorization();

    // Proves the data path: cortex_app, tenant pinned per transaction, FORCED RLS.
    // cortex.tenants has a self only policy, so exactly one row must be visible.
    app.MapGet("/api/tenant", async (CortexDbContext db, CancellationToken ct) =>
    {
        await using var tx = await db.Database.BeginTransactionAsync(ct);
        var names = await db.Database
            .SqlQuery<string>($"SELECT name AS \"Value\" FROM cortex.tenants")
            .ToListAsync(ct);
        await tx.CommitAsync(ct);
        return Results.Ok(new { visibleTenants = names.Count, name = names.FirstOrDefault() });
    }).RequireAuthorization();

    // MCP endpoint for n8n and AI assistants: tenant from the OAuth token only. Stub.
    app.MapPost("/mcp", () => Results.StatusCode(StatusCodes.Status501NotImplemented))
       .RequireAuthorization();
}

app.Run();
