using System.Runtime.Versioning;
using System.Security.Cryptography;
using System.Text;

namespace Cortex.Core;

/// <summary>
/// The only way code reads a secret. Local profile: DPAPI files written by the installer.
/// Server profile: OpenBao. Secrets never come from appsettings or environment variables.
/// </summary>
public interface ISecretStore
{
    string Get(string name);
}

/// <summary>
/// Reads &lt;dir&gt;\&lt;name&gt;.dpapi, protected with DPAPI LocalMachine scope by the installer.
/// The file ACL (SYSTEM, Administrators, service account) is the access control; DPAPI binds it to this machine.
/// </summary>
[SupportedOSPlatform("windows")]
public sealed class DpapiSecretStore(string directory) : ISecretStore
{
    public string Get(string name)
    {
        if (string.IsNullOrWhiteSpace(name) || name.IndexOfAny(Path.GetInvalidFileNameChars()) >= 0 || name.Contains(".."))
            throw new ArgumentException($"Invalid secret name '{name}'.", nameof(name));

        var path = Path.Combine(directory, name + ".dpapi");
        if (!File.Exists(path))
            throw new InvalidOperationException($"Secret '{name}' not found. Run the installer (infra/windows/bootstrap.ps1).");

        var plain = ProtectedData.Unprotect(File.ReadAllBytes(path), null, DataProtectionScope.LocalMachine);
        try { return Encoding.UTF8.GetString(plain); }
        finally { CryptographicOperations.ZeroMemory(plain); }
    }
}

/// <summary>Server profile. Interface only for now: wired to OpenBao (AppRole, per tenant Transit) later.</summary>
public sealed class OpenBaoSecretStore : ISecretStore
{
    public string Get(string name)
        => throw new NotSupportedException("OpenBao secret store is not implemented yet (server profile, roadmap phase 2).");
}
