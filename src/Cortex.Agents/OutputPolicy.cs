using System.Text.RegularExpressions;

namespace Cortex.Agents;

/// <summary>
/// First output gate. Removes reasoning blocks and anything a client would fetch on render
/// (markdown or HTML images), the classic exfiltration channel. More rules land in Phase 3.
/// </summary>
public sealed partial class BasicOutputPolicy : IOutputPolicy
{
    public OutputVerdict Inspect(string modelOutput)
    {
        var text = ThinkBlock().Replace(modelOutput ?? "", "");
        var stripped = MarkdownImage().Replace(text, "[image removed]");
        stripped = HtmlImage().Replace(stripped, "[image removed]");
        var reason = stripped != text ? "image or remote reference removed" : null;
        return new OutputVerdict(true, stripped.Trim(), reason);
    }

    [GeneratedRegex(@"<think>.*?</think>", RegexOptions.Singleline | RegexOptions.IgnoreCase)]
    private static partial Regex ThinkBlock();

    [GeneratedRegex(@"!\[[^\]]*\]\([^)]*\)")]
    private static partial Regex MarkdownImage();

    [GeneratedRegex(@"<img\b[^>]*>", RegexOptions.IgnoreCase)]
    private static partial Regex HtmlImage();
}
