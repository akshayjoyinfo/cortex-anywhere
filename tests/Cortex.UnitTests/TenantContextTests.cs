using Cortex.Core;
using Xunit;

namespace Cortex.UnitTests;

public sealed class TenantContextTests
{
    [Fact]
    public void Empty_tenant_is_rejected()
        => Assert.Throws<TenantMissingException>(() => new TenantContext(Guid.Empty, "pooled", "t"));

    [Fact]
    public void No_tenant_fails_closed()
        => Assert.Throws<TenantMissingException>(() => new TenantScope().Current);

    [Fact]
    public void Tenant_cannot_be_replaced_inside_a_flow()
    {
        using var _ = TenantScope.Begin(new TenantContext(Guid.NewGuid(), "pooled", "a"));
        Assert.Throws<InvalidOperationException>(
            () => TenantScope.Begin(new TenantContext(Guid.NewGuid(), "pooled", "b")));
    }
}
