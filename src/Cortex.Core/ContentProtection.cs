using System.Security.Cryptography;
using System.Text;

namespace Cortex.Core;

/// <summary>
/// Memory content is stored encrypted. The tenant id is bound into every ciphertext,
/// so a row copied to another tenant (or read with the wrong tenant) does not decrypt.
/// Local profile: AES-GCM with a machine key from the secret store.
/// Server profile: OpenBao Transit with a key per tenant (not yet wired).
/// </summary>
public interface IContentProtector
{
    byte[] Protect(Guid tenantId, string plaintext);
    string Unprotect(Guid tenantId, byte[] blob);
}

public sealed class AesGcmContentProtector : IContentProtector
{
    private const byte Version = 1;
    private const int NonceSize = 12, TagSize = 16;
    private readonly byte[] _key;

    public AesGcmContentProtector(byte[] key)
    {
        if (key.Length != 32) throw new ArgumentException("Content key must be 32 bytes.", nameof(key));
        _key = key;
    }

    /// <summary>Key stored by the installer as a base64url secret.</summary>
    public static AesGcmContentProtector FromSecret(ISecretStore secrets, string name)
    {
        var s = secrets.Get(name).Replace('-', '+').Replace('_', '/');
        s = s.PadRight(s.Length + (4 - s.Length % 4) % 4, '=');
        return new AesGcmContentProtector(Convert.FromBase64String(s));
    }

    public byte[] Protect(Guid tenantId, string plaintext)
    {
        var plain = Encoding.UTF8.GetBytes(plaintext);
        var blob = new byte[1 + NonceSize + TagSize + plain.Length];
        blob[0] = Version;
        var nonce = blob.AsSpan(1, NonceSize);
        RandomNumberGenerator.Fill(nonce);
        using var aes = new AesGcm(_key, TagSize);
        aes.Encrypt(nonce, plain, blob.AsSpan(1 + NonceSize + TagSize), blob.AsSpan(1 + NonceSize, TagSize), Aad(tenantId));
        return blob;
    }

    public string Unprotect(Guid tenantId, byte[] blob)
    {
        if (blob.Length < 1 + NonceSize + TagSize || blob[0] != Version)
            throw new CryptographicException("Unknown content format.");
        var plain = new byte[blob.Length - 1 - NonceSize - TagSize];
        using var aes = new AesGcm(_key, TagSize);
        aes.Decrypt(blob.AsSpan(1, NonceSize), blob.AsSpan(1 + NonceSize + TagSize), blob.AsSpan(1 + NonceSize, TagSize), plain, Aad(tenantId));
        return Encoding.UTF8.GetString(plain);
    }

    private static byte[] Aad(Guid tenantId) => Encoding.ASCII.GetBytes($"cortex-memory-v1:{tenantId:D}");
}

/// <summary>Server profile seam: OpenBao Transit, one key per tenant. Interface only for now.</summary>
public sealed class TransitContentProtector : IContentProtector
{
    public byte[] Protect(Guid tenantId, string plaintext) => throw new NotSupportedException("OpenBao Transit is not wired yet (server profile).");
    public string Unprotect(Guid tenantId, byte[] blob) => throw new NotSupportedException("OpenBao Transit is not wired yet (server profile).");
}
