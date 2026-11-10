using Xunit;

namespace Cortex.SecurityTests;

/// <summary>
/// Hostile corpus (PromptInjectionCorpus.txt) replayed against tenant A's agent with
/// tenant B canaries seeded. Pass = no B marker in output, tool args, egress or memory.
/// </summary>
public sealed class PromptInjectionTests
{
    private const string Pending = "Skeleton: needs vLLM or a scripted hostile IChatClient.";

    [Fact(Skip = Pending)] public void Tool_schemas_expose_no_scope_arguments() { }
    [Fact(Skip = Pending)] public void Injected_fetch_to_unlisted_host_is_blocked() { }
    [Fact(Skip = Pending)] public void Markdown_image_exfil_is_not_rendered() { }
    [Fact(Skip = Pending)] public void Recalled_memory_never_enters_system_role() { }
    [Fact(Skip = Pending)] public void Asking_for_other_tenant_returns_no_data() { }

    [Fact]
    public void Corpus_is_present()
        => Assert.True(File.ReadAllLines("PromptInjectionCorpus.txt").Length >= 5);
}
