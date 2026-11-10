using Cortex.Agents;
using Cortex.Core;
using Cortex.Data;
using Cortex.Worker;

var role = args.FirstOrDefault() ?? "web";
if (role is not ("web" or "worker"))
    throw new ArgumentException($"Unknown role '{role}'. Use web or worker.");

var builder = WebApplication.CreateBuilder(args.Skip(1).ToArray());
var connectionString = builder.Configuration.GetConnectionString("Cortex") ?? "";

builder.AddServiceDefaults();
builder.Services.AddCortexCore();
builder.Services.AddCortexData(connectionString);
builder.Services.AddCortexAgents();

if (role == "worker")
{
    builder.Services.AddCortexWorker(connectionString);
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
        b => b.UseMiddleware<TenantMiddleware>());

    app.MapGet("/api/whoami", (ITenantContextAccessor t) => Results.Ok(new { tenant = t.Current.TenantId }))
       .RequireAuthorization();

    // MCP endpoint for n8n and AI assistants: tenant from the OAuth token only. Stub.
    app.MapPost("/mcp", () => Results.StatusCode(StatusCodes.Status501NotImplemented))
       .RequireAuthorization();
}

app.Run();
