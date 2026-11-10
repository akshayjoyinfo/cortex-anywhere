namespace Cortex.Core;

/// <summary>
/// Born once at the edge (JWT) or from a signed job envelope. Immutable.
/// Nothing downstream, including the model, can construct or change it.
/// </summary>
public sealed class TenantContext
{
    public TenantContext(Guid tenantId, string tier, string subject)
    {
        if (tenantId == Guid.Empty) throw new TenantMissingException();
        TenantId = tenantId;
        Tier = tier;
        Subject = subject;
    }

    public Guid TenantId { get; }
    public string Tier { get; }
    public string Subject { get; }
}

public sealed class TenantMissingException() : InvalidOperationException("No tenant in context. Failing closed.");
