using System.Runtime.Versioning;
using System.Security.Claims;
using System.Security.Cryptography;
using System.Text;
using Cortex.Agents;
using Cortex.Core;
using Cortex.Data;
using Microsoft.AspNetCore.Http;
using Microsoft.Extensions.AI;
using Microsoft.Extensions.Configuration;
using Xunit;

namespace Cortex.UnitTests;

public sealed class ProfileTests
{
    private static IConfiguration Config(string? value)
        => new ConfigurationBuilder().AddInMemoryCollection(new Dictionary<string, string?> { [CortexProfiles.Key] = value }).Build();

    [Theory]
    [InlineData("local", CortexProfile.Local)]
    [InlineData(" Server ", CortexProfile.Server)]
    public void Known_profiles_resolve(string value, CortexProfile expected)
        => Assert.Equal(expected, CortexProfiles.Resolve(Config(value)));

    [Theory]
    [InlineData(null)]
    [InlineData("")]
    [InlineData("cloud")]
    public void Missing_or_unknown_profile_stops_the_process(string? value)
        => Assert.Throws<InvalidOperationException>(() => CortexProfiles.Resolve(Config(value)));
}

public sealed class LocalTenantTests
{
    [Fact]
    public async Task Unauthenticated_caller_is_rejected_before_any_tenant_exists()
    {
        var called = false;
        var mw = new LocalTenantMiddleware(_ => { called = true; return Task.CompletedTask; },
            new LocalInstallOptions { TenantId = Guid.NewGuid() });
        var http = new DefaultHttpContext();

        await mw.InvokeAsync(http);

        Assert.Equal(StatusCodes.Status401Unauthorized, http.Response.StatusCode);
        Assert.False(called);
    }

    [Fact]
    public async Task Authenticated_caller_gets_the_install_tenant_and_the_scope_ends()
    {
        var tenantId = Guid.NewGuid();
        var accessor = new TenantScope();
        TenantContext? seen = null;
        var mw = new LocalTenantMiddleware(_ => { seen = accessor.Current; return Task.CompletedTask; },
            new LocalInstallOptions { TenantId = tenantId });
        var http = new DefaultHttpContext
        {
            User = new ClaimsPrincipal(new ClaimsIdentity([new Claim(ClaimTypes.Name, @"HOST\alice")], "Negotiate")),
        };

        await mw.InvokeAsync(http);

        Assert.NotNull(seen);
        Assert.Equal(tenantId, seen.TenantId);
        Assert.Equal(@"HOST\alice", seen.Subject);
        Assert.False(accessor.HasTenant);
    }

    [Fact]
    public async Task Install_without_tenant_fails_closed()
    {
        var mw = new LocalTenantMiddleware(_ => Task.CompletedTask, new LocalInstallOptions { TenantId = Guid.Empty });
        var http = new DefaultHttpContext
        {
            User = new ClaimsPrincipal(new ClaimsIdentity([new Claim(ClaimTypes.Name, "x")], "Negotiate")),
        };

        await Assert.ThrowsAsync<TenantMissingException>(() => mw.InvokeAsync(http));
    }
}

public sealed class ModelGatewayTests
{
    private static ModelOptions Options(string url) => new() { Endpoint = new Uri(url), Name = "qwen3:1.7b", EmbeddingName = "qwen3-embedding:0.6b" };

    [Theory]
    [InlineData("http://127.0.0.1:11434/v1")]
    [InlineData("http://localhost:11434/v1")]
    public void Local_profile_accepts_loopback_model(string url)
        => OpenAiCompatibleGateway.Validate(Options(url), CortexProfile.Local);

    [Theory]
    [InlineData("http://10.10.2.10:8000/v1")]
    [InlineData("https://api.example.com/v1")]
    public void Local_profile_refuses_a_model_off_the_machine(string url)
        => Assert.Throws<InvalidOperationException>(() => OpenAiCompatibleGateway.Validate(Options(url), CortexProfile.Local));

    [Fact]
    public void Server_profile_accepts_the_inference_server()
        => OpenAiCompatibleGateway.Validate(Options("http://10.10.2.10:8000/v1"), CortexProfile.Server);

    [Fact]
    public void Missing_model_name_stops_startup()
        => Assert.Throws<InvalidOperationException>(() => OpenAiCompatibleGateway.Validate(
            new ModelOptions { Endpoint = new Uri("http://127.0.0.1:11434/v1") }, CortexProfile.Local));

    [Fact]
    public void Gateway_without_tenant_fails_closed()
    {
        var gateway = new OpenAiCompatibleGateway(Options("http://127.0.0.1:11434/v1"), CortexProfile.Local, new TenantScope());
        Assert.Throws<TenantMissingException>(() => gateway.ForCurrentTenant());
    }
}

public sealed class ToolRegistryTests
{
    private sealed class FakeTool(string name) : ITenantBoundTool
    {
        public string Name => name;
        public AIFunction Function { get; } = AIFunctionFactory.Create(() => "ok", name);
    }

    private static AgentDefinition Agent(params string[] tools)
        => new(Guid.NewGuid(), "agent", "prompt", "qwen3:1.7b", tools, 4, 4000);

    [Fact]
    public void Only_allow_listed_and_registered_tools_resolve()
    {
        var registry = new ToolRegistry([new FakeTool("search_memory"), new FakeTool("send_email")]);

        var set = registry.ForAgent(Agent("search_memory", "delete_everything"));

        Assert.Equal(new[] { "search_memory" }, set.Tools.Select(t => t.Name));
        Assert.True(set.TryResolve("search_memory", out _));
        Assert.False(set.TryResolve("send_email", out _));         // registered, not allow listed
        Assert.False(set.TryResolve("delete_everything", out _));  // allow listed, not registered
        Assert.Equal(new[] { "delete_everything" }, set.Unresolved);
    }

    [Fact]
    public void Resolution_is_exact()
    {
        var set = new ToolRegistry([new FakeTool("search_memory")]).ForAgent(Agent("search_memory"));
        Assert.False(set.TryResolve("Search_Memory", out _));
        Assert.False(set.TryResolve("search_memory ", out _));
    }

    [Fact]
    public void Duplicate_tool_names_are_rejected()
        => Assert.Throws<InvalidOperationException>(() => new ToolRegistry([new FakeTool("a"), new FakeTool("a")]));
}

public sealed class LocalSecretsAndDatabaseTests
{
    private sealed class FixedSecrets : ISecretStore
    {
        public string Get(string name) => "pw";
    }

    [Theory]
    [InlineData("10.10.1.20")]
    [InlineData("db.example.com")]
    public void Local_database_must_be_loopback(string host)
        => Assert.Throws<InvalidOperationException>(() =>
            LocalDatabase.ConnectionString(new LocalDatabaseOptions { Host = host }, new FixedSecrets()));

    [Fact]
    public void Local_connection_uses_app_role_and_secret_store()
    {
        var cs = LocalDatabase.ConnectionString(new LocalDatabaseOptions(), new FixedSecrets());
        Assert.Contains("Username=cortex_app", cs);
        Assert.Contains("Host=127.0.0.1", cs);
    }

    [Fact]
    [SupportedOSPlatform("windows")]   // analyzer: guard does not reach into lambdas; skipped at runtime elsewhere
    public void Dpapi_store_reads_an_installer_written_secret_and_rejects_path_tricks()
    {
        if (OperatingSystem.IsWindows())
        {
            var dir = Directory.CreateTempSubdirectory("cortex-secrets-").FullName;
            try
            {
                File.WriteAllBytes(Path.Combine(dir, "pg-app.dpapi"),
                    ProtectedData.Protect(Encoding.UTF8.GetBytes("s3cret"), null, DataProtectionScope.LocalMachine));
                var store = new DpapiSecretStore(dir);

                Assert.Equal("s3cret", store.Get("pg-app"));
                Assert.Throws<ArgumentException>(() => store.Get(@"..\pg-app"));
                Assert.Throws<InvalidOperationException>(() => store.Get("missing"));
            }
            finally { Directory.Delete(dir, recursive: true); }
        }
        else
        {
            Assert.Skip("DPAPI is Windows only; runs on the Windows field server.");
        }
    }
}
