using Microsoft.Extensions.Configuration;

namespace Cortex.Core;

/// <summary>
/// One codebase, two deployment shapes. The profile changes where things come from
/// (tenant, secrets, model, bind address), never what the code does with them.
/// </summary>
public enum CortexProfile
{
    /// <summary>Single customer on their own Windows machine. Fixed tenant, DPAPI, Ollama, loopback only.</summary>
    Local,

    /// <summary>Our servers. Tenant from the JWT, OpenBao, vLLM.</summary>
    Server,
}

public static class CortexProfiles
{
    public const string Key = "CORTEX_PROFILE";

    /// <summary>No default: a missing or unknown profile stops the process.</summary>
    public static CortexProfile Resolve(IConfiguration configuration)
    {
        var value = configuration[Key];
        return value?.Trim().ToLowerInvariant() switch
        {
            "local" => CortexProfile.Local,
            "server" => CortexProfile.Server,
            null or "" => throw new InvalidOperationException($"{Key} is not set. Use local or server."),
            _ => throw new InvalidOperationException($"{Key} '{value}' is unknown. Use local or server."),
        };
    }
}
