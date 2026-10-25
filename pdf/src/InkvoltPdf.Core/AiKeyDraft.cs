namespace InkvoltPdf.Core;

/// <summary>
/// The API key being edited in Settings › AI assistant, tied to one endpoint. A typed key, or "remove the saved key",
/// belongs to the endpoint it was entered for: changing the endpoint (preset or address) drops both, so a key for one
/// service is never tested against, sent to, saved for or removed from another.
/// </summary>
public sealed class AiKeyDraft
{
    /// <summary>The endpoint (<see cref="AiEndpoint.Key"/>) the draft belongs to; null while the address is invalid.</summary>
    public string? EndpointKey { get; private set; }

    /// <summary>A key typed for <see cref="EndpointKey"/>, or null.</summary>
    public string? Typed { get; private set; }

    /// <summary>True when the saved key of <see cref="EndpointKey"/> is to be removed.</summary>
    public bool Remove { get; private set; }

    public AiKeyDraft(string? endpointKey) => EndpointKey = endpointKey;

    /// <summary>The address changed. Returns true when it is another endpoint, and so the typed key and removal were dropped.</summary>
    public bool EndpointChanged(string? endpointKey)
    {
        if (string.Equals(endpointKey, EndpointKey, StringComparison.OrdinalIgnoreCase)) return false;
        EndpointKey = endpointKey;
        Typed = null;
        Remove = false;
        return true;
    }

    public void Type(string? key)
    {
        Typed = string.IsNullOrWhiteSpace(key) ? null : key.Trim();
        if (Typed is not null) Remove = false;
    }

    public void RemoveSaved()
    {
        Typed = null;
        Remove = true;
    }

    /// <summary>The key a request to <see cref="EndpointKey"/> uses now: the typed one, else the saved one unless it is being removed.</summary>
    public string? KeyToUse(Func<string, string?> saved) =>
        EndpointKey is null ? null : Typed ?? (Remove ? null : saved(EndpointKey));
}
