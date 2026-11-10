using Cortex.Agents;
using Cortex.Core;

namespace Cortex.Worker;

/// <summary>Signed at enqueue from TenantContext. The model never writes an envelope.</summary>
public sealed record JobEnvelope(Guid TenantId, string Tier, Guid RunId, Guid AgentId, DateTimeOffset IssuedAt, string Signature);

public interface IEnvelopeSigner
{
    JobEnvelope Sign(Guid runId, Guid agentId);   // reads TenantContext
    bool Verify(JobEnvelope envelope);
}

/// <summary>Hangfire job. Rebuilds TenantContext from the verified envelope only.</summary>
public sealed class AgentRunJob(IEnvelopeSigner signer, IAgentRuntime runtime)
{
    public async Task Execute(JobEnvelope envelope, string input, CancellationToken cancellationToken)
    {
        if (!signer.Verify(envelope))
            throw new InvalidOperationException("Envelope signature invalid. Job rejected.");

        using (TenantScope.Begin(new TenantContext(envelope.TenantId, envelope.Tier, $"job:{envelope.RunId}")))
        {
            await runtime.RunAsync(new AgentRunRequest(envelope.AgentId, envelope.RunId, input), cancellationToken);
        }
    }
}
