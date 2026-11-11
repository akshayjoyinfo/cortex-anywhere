using System.ClientModel;
using Cortex.Core;
using Microsoft.Extensions.AI;
using OpenAI;

namespace Cortex.Agents;

public sealed class ModelOptions
{
    public const string Section = "Cortex:Model";

    /// <summary>OpenAI compatible base URL. Local: Ollama http://127.0.0.1:11434/v1. Server: vLLM.</summary>
    public Uri? Endpoint { get; set; }

    /// <summary>Model name as the endpoint knows it, for example qwen3:1.7b (Ollama) or qwen3-14b (vLLM).</summary>
    public string Name { get; set; } = "";

    /// <summary>Embedding model on the same endpoint. Must produce 1024 dimensions (memory_item.embedding).</summary>
    public string EmbeddingName { get; set; } = "";
}

/// <summary>
/// The only path to a model. Ollama and vLLM both speak the OpenAI chat API, so one
/// client serves both profiles; only the endpoint differs.
/// Local profile refuses any non loopback endpoint: customer data never leaves the machine.
/// Server profile (not yet): vLLM cache_salt = HMAC(tenant id) and a silo tenant's own model.
/// </summary>
public sealed class OpenAiCompatibleGateway : ILlmGateway
{
    private readonly IChatClient _client;
    private readonly IEmbeddingGenerator<string, Embedding<float>> _embeddings;
    private readonly ITenantContextAccessor _tenant;

    public OpenAiCompatibleGateway(ModelOptions options, CortexProfile profile, ITenantContextAccessor tenant)
    {
        Validate(options, profile);
        _tenant = tenant;
        var openAi = new OpenAIClient(new ApiKeyCredential("not-used"), new OpenAIClientOptions
        {
            Endpoint = options.Endpoint,
            NetworkTimeout = TimeSpan.FromMinutes(10),   // CPU inference is slow; the run has its own budget
        });
        _client = openAi.GetChatClient(options.Name).AsIChatClient();
        _embeddings = openAi.GetEmbeddingClient(options.EmbeddingName).AsIEmbeddingGenerator();
    }

    /// <summary>Fails closed without a tenant, like every other tenant scoped service.</summary>
    public IChatClient ForCurrentTenant()
    {
        _ = _tenant.Current;
        return _client;
    }

    public IEmbeddingGenerator<string, Embedding<float>> EmbeddingsForCurrentTenant()
    {
        _ = _tenant.Current;
        return _embeddings;
    }

    public static void Validate(ModelOptions options, CortexProfile profile)
    {
        if (options.Endpoint is null || !options.Endpoint.IsAbsoluteUri)
            throw new InvalidOperationException($"{ModelOptions.Section}:Endpoint is not set.");
        if (options.Endpoint.Scheme is not ("http" or "https"))
            throw new InvalidOperationException($"Model endpoint scheme '{options.Endpoint.Scheme}' is not allowed.");
        if (string.IsNullOrWhiteSpace(options.Name))
            throw new InvalidOperationException($"{ModelOptions.Section}:Name is not set.");
        if (string.IsNullOrWhiteSpace(options.EmbeddingName))
            throw new InvalidOperationException($"{ModelOptions.Section}:EmbeddingName is not set.");
        if (profile == CortexProfile.Local && !options.Endpoint.IsLoopback)
            throw new InvalidOperationException($"Local profile model endpoint must be loopback, got '{options.Endpoint.Host}'.");
    }
}
