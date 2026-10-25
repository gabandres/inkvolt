using System.Net;
using System.Net.Sockets;

namespace InkvoltPdf.Core;

/// <summary>Where text sent to an AI endpoint goes.</summary>
public enum AiReach
{
    /// <summary>Loopback: the server runs on this PC (Ollama, LM Studio).</summary>
    ThisPc,
    /// <summary>A private address or a local name (.local, a single-label name): another computer on your network.</summary>
    LocalNetwork,
    /// <summary>Anything else: the text leaves this PC for that host.</summary>
    Internet,
}

/// <summary>
/// An OpenAI-compatible endpoint the user chose (bring your own AI): its base URL, ending in the API version
/// ("http://localhost:11434/v1"), and where requests to it go. Classified by its address as written, never by
/// resolving it, so the label can't change behind the user's back.
/// </summary>
public sealed record AiEndpoint
{
    // 127.0.0.1, not localhost: both servers listen on IPv4 loopback only, and Windows tries ::1 first.
    public const string OllamaUrl = "http://127.0.0.1:11434/v1";
    public const string LmStudioUrl = "http://127.0.0.1:1234/v1";

    private AiEndpoint(Uri baseUrl, AiReach reach)
    {
        BaseUrl = baseUrl;
        Reach = reach;
    }

    /// <summary>The base URL without a trailing slash.</summary>
    public Uri BaseUrl { get; }

    public AiReach Reach { get; }

    /// <summary>Host and port as shown to the user: "localhost:11434", "api.example.com".</summary>
    public string Host => BaseUrl.IsDefaultPort ? BaseUrl.Host : $"{BaseUrl.Host}:{BaseUrl.Port}";

    /// <summary>The endpoint's identity for per-endpoint choices (its API key, "don't ask again").</summary>
    public string Key => BaseUrl.AbsoluteUri.TrimEnd('/');

    public Uri ChatUrl => new(Key + "/chat/completions");

    public Uri ModelsUrl => new(Key + "/models");

    /// <summary>"Stays on this PC", "Stays on your network (nas.local:11434)", "Leaves this PC: sent to api.example.com".</summary>
    public string ReachText => Reach switch
    {
        AiReach.ThisPc => "Stays on this PC",
        AiReach.LocalNetwork => $"Stays on your network ({Host})",
        _ => $"Leaves this PC: sent to {Host}",
    };

    /// <summary>What usually serves this address, for "Is Ollama running?" hints (by its well-known port on this PC).</summary>
    public string? ServerName => Reach == AiReach.ThisPc
        ? BaseUrl.Port switch { 11434 => "Ollama", 1234 => "LM Studio", _ => null }
        : null;

    /// <summary>
    /// Reads a base URL the user typed. Adds the scheme when missing (http:// for this PC or the network, https://
    /// otherwise) and "/v1" when there is no path, and drops a pasted "/chat/completions" or "/models". Refuses user
    /// names and passwords in the address, queries, and plain http:// to a host outside the network (the text would
    /// travel unencrypted).
    /// </summary>
    public static bool TryParse(string? text, out AiEndpoint? endpoint, out string? error)
    {
        endpoint = null;
        error = null;
        text = text?.Trim() ?? "";
        if (text.Length == 0)
        {
            error = "Enter the endpoint's address, e.g. https://api.example.com/v1";
            return false;
        }
        var guessed = !text.Contains("://", StringComparison.Ordinal);
        if (guessed) text = "http://" + text;
        if (!Uri.TryCreate(text, UriKind.Absolute, out var uri) || uri.Host.Length == 0)
        {
            error = "That isn't a web address. Enter one such as https://api.example.com/v1";
            return false;
        }
        // HttpClient connects to the IDNA (punycode) form of a host, in which look-alike dots such as "。" become real
        // ones: a name classified as typed could be another host. Only plain ASCII names are taken.
        var start = text.IndexOf("://", StringComparison.Ordinal) + 3;
        var end = text.IndexOfAny(['/', '?', '#'], start);
        var authority = text.AsSpan(start, (end < 0 ? text.Length : end) - start);
        if (uri.Host.Any(c => c > 0x7E) || authority.ContainsAnyExceptInRange((char)0x21, (char)0x7E))
        {
            error = "Type the host name in plain letters and digits (an international domain name in its xn-- form).";
            return false;
        }
        if (uri.Scheme != Uri.UriSchemeHttp && uri.Scheme != Uri.UriSchemeHttps)
        {
            error = "The address must start with https:// (or http:// for this PC or your network).";
            return false;
        }
        if (uri.UserInfo.Length > 0)
        {
            error = "Leave the user name and password out of the address; put an API key in the key box instead.";
            return false;
        }
        if (uri.Query.Length > 0 || uri.Fragment.Length > 0)
        {
            error = "Leave out the part after ? or #: enter just the base address, e.g. https://api.example.com/v1";
            return false;
        }
        var reach = Classify(uri.Host);
        if (guessed && reach == AiReach.Internet)
            uri = new UriBuilder(uri) { Scheme = Uri.UriSchemeHttps, Port = uri.IsDefaultPort ? -1 : uri.Port }.Uri;
        if (uri.Scheme == Uri.UriSchemeHttp && reach == AiReach.Internet)
        {
            error = $"Use https:// for {uri.Host}: it is outside your network, and http:// would send the text unencrypted.";
            return false;
        }

        var path = uri.AbsolutePath.TrimEnd('/');
        foreach (var tail in new[] { "/chat/completions", "/models" })
            if (path.EndsWith(tail, StringComparison.OrdinalIgnoreCase)) path = path[..^tail.Length];
        if (path.Length == 0) path = "/v1";
        var b = new UriBuilder(uri) { Path = path, Query = "", Fragment = "" };
        endpoint = new AiEndpoint(b.Uri, reach);
        return true;
    }

    /// <summary>
    /// True when a connection to <paramref name="ip"/> keeps the promise of <see cref="Reach"/>: loopback for this PC;
    /// loopback or a private, link-local or unique-local address for the network; anything for the internet. Checked on
    /// every address a name resolves to, so a ".local" or ".localhost" name (or DNS rebinding) can't lead elsewhere.
    /// </summary>
    public bool Allows(IPAddress ip) => Reach switch
    {
        AiReach.ThisPc => Classify(ip) == AiReach.ThisPc,
        AiReach.LocalNetwork => Classify(ip) != AiReach.Internet,
        _ => true,
    };

    /// <summary>Where a host is, by its name or address as written.</summary>
    public static AiReach Classify(string host)
    {
        host = host.Trim().TrimEnd('.').ToLowerInvariant();
        if (host.StartsWith('[') && host.EndsWith(']')) host = host[1..^1];
        if (host.Length == 0) return AiReach.Internet;
        if (IPAddress.TryParse(host, out var ip)) return Classify(ip);
        if (host == "localhost" || host.EndsWith(".localhost", StringComparison.Ordinal)) return AiReach.ThisPc;
        // Names that only resolve inside a network: mDNS (.local), home routers (.lan, .home.arpa), private zones
        // (.internal), and single-label names (a computer's name, found by the network's own DNS or NetBIOS).
        if (!host.Contains('.')) return AiReach.LocalNetwork;
        foreach (var suffix in new[] { ".local", ".lan", ".home.arpa", ".internal" })
            if (host.EndsWith(suffix, StringComparison.Ordinal)) return AiReach.LocalNetwork;
        return AiReach.Internet;
    }

    /// <summary>Loopback is this PC; private, link-local and shared (carrier-NAT / VPN) ranges are the network.</summary>
    public static AiReach Classify(IPAddress ip)
    {
        if (ip.IsIPv4MappedToIPv6) ip = ip.MapToIPv4();
        if (IPAddress.IsLoopback(ip)) return AiReach.ThisPc;
        if (ip.AddressFamily == AddressFamily.InterNetwork)
        {
            var b = ip.GetAddressBytes();
            return b[0] == 10
                   || (b[0] == 172 && b[1] is >= 16 and <= 31)
                   || (b[0] == 192 && b[1] == 168)
                   || (b[0] == 169 && b[1] == 254)
                   || (b[0] == 100 && b[1] is >= 64 and <= 127) // 100.64.0.0/10: never routed on the internet (Tailscale and the like use it)
                ? AiReach.LocalNetwork
                : AiReach.Internet;
        }
        if (ip.AddressFamily == AddressFamily.InterNetworkV6)
        {
            var b = ip.GetAddressBytes();
            if (ip.IsIPv6LinkLocal || ip.IsIPv6SiteLocal || (b[0] & 0xFE) == 0xFC) return AiReach.LocalNetwork; // fe80::/10, fec0::/10, fc00::/7
        }
        return AiReach.Internet;
    }
}
