namespace Cortex.Core;

public interface ITenantContextAccessor
{
    /// <summary>Throws when no tenant is set: fail closed, never a default.</summary>
    TenantContext Current { get; }
    bool HasTenant { get; }
}

/// <summary>AsyncLocal holder. A tenant is set once per flow and never replaced.</summary>
public sealed class TenantScope : ITenantContextAccessor
{
    private static readonly AsyncLocal<TenantContext?> Ambient = new();

    public TenantContext Current => Ambient.Value ?? throw new TenantMissingException();
    public bool HasTenant => Ambient.Value is not null;

    public static IDisposable Begin(TenantContext context)
    {
        if (Ambient.Value is not null)
            throw new InvalidOperationException("Tenant already set for this flow.");
        Ambient.Value = context;
        return new Exit();
    }

    private sealed class Exit : IDisposable
    {
        public void Dispose() => Ambient.Value = null;
    }
}
