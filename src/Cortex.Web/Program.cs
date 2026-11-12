using System.Net;
using Cortex.Agents;
using Cortex.Core;
using Cortex.Data;
using Cortex.Worker;
using Microsoft.AspNetCore.Authentication.Negotiate;
using Microsoft.EntityFrameworkCore;

var role = args.FirstOrDefault() ?? "web";
if (role is not ("web" or "worker" or "canary"))
    throw new ArgumentException($"Unknown role '{role}'. Use web or worker.");

// The canary role takes positional arguments; keep them away from configuration.
var builder = WebApplication.CreateBuilder(role == "canary" ? [] : args.Skip(1).ToArray());

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
    builder.Services.AddSingleton<IContentProtector>(AesGcmContentProtector.FromSecret(secrets, install.MemoryKeySecret));

    // Everything binds to loopback. ASPNETCORE_URLS and appsettings cannot widen it.
    builder.WebHost.ConfigureKestrel(k => k.Listen(IPAddress.Loopback, install.Port));
}
else
{
    connectionString = builder.Configuration.GetConnectionString("Cortex")
        ?? throw new InvalidOperationException("ConnectionStrings:Cortex is not set.");
    builder.Services.AddSingleton<ISecretStore, OpenBaoSecretStore>();
    builder.Services.AddSingleton<IContentProtector, TransitContentProtector>();
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

if (role == "canary")
{
    if (profile != CortexProfile.Local)
        throw new InvalidOperationException("The canary role is a field test tool and runs in the local profile only.");
    Environment.ExitCode = await CanaryCommand.RunAsync(app.Services, [.. args.Skip(1)]);
    return;
}

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

    // One agent run, synchronous (local profile). Server profile will enqueue a signed job instead.
    app.MapPost("/api/agents/{name}/runs", async (string name, RunInput body, IAgentCatalog catalog, IAgentRuntime runtime, CancellationToken ct) =>
    {
        if (string.IsNullOrWhiteSpace(body.Input) || body.Input.Length > 4000)
            return Results.BadRequest(new { error = "input must be 1 to 4000 characters" });
        var agent = await catalog.FindByNameAsync(name, ct);
        if (agent is null) return Results.NotFound();
        var runId = Guid.NewGuid();
        var result = await runtime.RunAsync(new AgentRunRequest(agent.Id, runId, body.Input), ct);
        return Results.Ok(new
        {
            runId, output = result.Output, steps = result.Steps, stop = result.StopReason.ToString(),
            toolCalls = result.ToolCalls, metrics = result.Metrics,
        });
    }).RequireAuthorization();

    // Provenance only, never content: what was written, by which run, from which source, at which trust.
    app.MapGet("/api/memory/recent", async (CortexDbContext db, CancellationToken ct) =>
    {
        await using var tx = await db.Database.BeginTransactionAsync(ct);
        var items = await db.MemoryItems.AsNoTracking().OrderByDescending(m => m.CreatedAt).Take(20)
            .Select(m => new { m.Id, m.Namespace, m.Source, m.Trust, m.RunId, m.AgentId, m.CreatedAt, contentBytes = m.Content.Length })
            .ToListAsync(ct);
        var episodes = await db.MemoryEpisodes.AsNoTracking().CountAsync(ct);
        var audits = await db.AuditEvents.AsNoTracking().CountAsync(a => a.Kind == "agent.run", ct);
        await tx.CommitAsync(ct);
        return Results.Ok(new { items, episodes, agentRunAudits = audits });
    }).RequireAuthorization();

    // MCP endpoint for n8n and AI assistants: tenant from the OAuth token only. Stub.
    app.MapPost("/mcp", () => Results.StatusCode(StatusCodes.Status501NotImplemented))
       .RequireAuthorization();
}

app.Run();

internal sealed record RunInput(string Input);
