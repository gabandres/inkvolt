using System.Net;
using System.Net.Sockets;
using System.Security;
using System.Text;
using InkvoltPrint.Core.Alerts;

namespace InkvoltPrint.Core.Setup;

/// <summary>A Wi-Fi network this PC can see (what Windows' list of available networks says about it).</summary>
/// <param name="Ssid">The network's name as it's sent (up to 32 bytes, not always text).</param>
/// <param name="Signal">Windows' signal quality, 0-100.</param>
/// <param name="Secured">It asks for a password (or more): only Windows' own Wi-Fi list connects to it.</param>
public sealed record WifiNetwork(byte[] Ssid, int Signal, bool Secured)
{
    /// <summary>The name as shown: one line of visible characters (a name is hostile input; bytes that aren't UTF-8 show as �).</summary>
    public string Name => SetupNetworks.Show(Ssid);

    public bool Same(WifiNetwork other) => Ssid.AsSpan().SequenceEqual(other.Ssid);
}

/// <summary>Which maker's printer a setup network seems to be, and how sure that is.</summary>
public enum SetupNetworkKind
{
    /// <summary>A printer's own setup network, open while it waits to be told the home Wi-Fi (HP-Setup, Canon_ij_, Brother's SETUP-, Epson's).</summary>
    Setup,

    /// <summary>A printer's Wi-Fi Direct network (DIRECT-xx- with a printer maker's name): also reaches its setup page.</summary>
    Direct,
}

/// <summary>A network nearby that looks like a printer's: the network, the maker it names and the kind.</summary>
public sealed record SetupCandidate(WifiNetwork Network, string Maker, SetupNetworkKind Kind);

/// <summary>
/// Spotting a new printer's setup network among the Wi-Fi networks nearby (roadmap 4.17), by the names makers give them: HP's
/// "HP-Setup&gt;xx-Model" and "HP-Print-xx-Model", Canon's "Canon_ij_XXXX", Brother's "SETUP-XXXX" and "DIRECT-xx-Brother…"/"…_BR…",
/// Epson's "EPSON…" and "DIRECT-xx-EPSON-…", Xerox's, Lexmark's, Samsung's, Kyocera's, Ricoh's and Pantum's "DIRECT-…" names.
/// A plain "DIRECT-xx-…" with no printer maker's name (a phone's or a TV's Wi-Fi Direct) isn't one. Read only: nothing here connects.
/// </summary>
public static class SetupNetworks
{
    private static readonly (string Word, string Maker)[] DirectMakers =
    [
        ("HP", "HP"), ("EPSON", "Epson"), ("Brother", "Brother"), ("Canon", "Canon"), ("Xerox", "Xerox"), ("Lexmark", "Lexmark"),
        ("Samsung", "Samsung"), ("KYOCERA", "Kyocera"), ("Ricoh", "Ricoh"), ("Pantum", "Pantum"), ("OKI", "OKI"),
    ];

    /// <summary>The printer's setup or Wi-Fi Direct network this is, or null for any other.</summary>
    public static SetupCandidate? Classify(WifiNetwork network)
    {
        var name = Show(network.Ssid);
        if (StartsWith(name, "HP-Setup")) return new(network, "HP", SetupNetworkKind.Setup);
        if (StartsWith(name, "HP-Print-")) return new(network, "HP", SetupNetworkKind.Direct);
        if (StartsWith(name, "Canon_ij_")) return new(network, "Canon", SetupNetworkKind.Setup);
        if (StartsWith(name, "SETUP-") || StartsWith(name, "Brother_")) return new(network, "Brother", SetupNetworkKind.Setup);
        if (StartsWith(name, "EPSON")) return new(network, "Epson", SetupNetworkKind.Setup);
        if (StartsWith(name, "DIRECT-") && name.Length > 10)
        {
            // Brother's: DIRECT-xxHL-L2350DW_BRa1b2 (the model, then _BR and four hex digits).
            if (System.Text.RegularExpressions.Regex.IsMatch(name, "_BR[0-9A-Fa-f]{4}$")) return new(network, "Brother", SetupNetworkKind.Direct);
            // The others: DIRECT-xx- and the maker's name right after it ("DIRECT-7A-EPSON-ET-2850", "DIRECT-4F-HP M234 LaserJet"). A
            // maker's name further on isn't one: "DIRECT-3f-[TV] Samsung 7 Series" is a television.
            if (name.Length > 10 && name[9] == '-')
            {
                var rest = name[10..].TrimStart();
                foreach (var (word, maker) in DirectMakers)
                    if (rest.StartsWith(word, StringComparison.OrdinalIgnoreCase) && (rest.Length == word.Length || !char.IsLetter(rest[word.Length])))
                        return new(network, maker, SetupNetworkKind.Direct);
            }
        }
        return null;
    }

    /// <summary>The printers' networks among <paramref name="nearby"/>, each once, setup networks first, strongest first.</summary>
    public static IReadOnlyList<SetupCandidate> Find(IEnumerable<WifiNetwork> nearby) =>
        [.. nearby.Take(512).Select(Classify).OfType<SetupCandidate>()
            .GroupBy(c => Convert.ToHexString(c.Network.Ssid)).Select(g => g.OrderByDescending(c => c.Network.Signal).First())
            .OrderBy(c => c.Kind).ThenByDescending(c => c.Network.Signal).Take(16)];

    /// <summary>A network's name as shown: UTF-8 (anything else as �), one line of visible characters.</summary>
    public static string Show(byte[] ssid)
    {
        var bytes = ssid.Length > 32 ? ssid[..32] : ssid;
        return AlertText.Clean(Encoding.UTF8.GetString(bytes), 64);
    }

    private static bool StartsWith(string name, string prefix) => name.StartsWith(prefix, StringComparison.OrdinalIgnoreCase);


    /// <summary>
    /// Windows' temporary profile for an open network (WLAN_profile schema): the network by its bytes in hex, open, no encryption,
    /// connected by hand only and never kept. Null for a network that asks for a password: those go through Windows' own list, so
    /// no password ever passes through this app.
    /// </summary>
    public static string? OpenProfile(WifiNetwork network)
    {
        if (network.Secured || network.Ssid.Length is 0 or > 32) return null;
        var name = SecurityElement.Escape(new string([.. network.Name.Where(c => c >= ' ')]));
        return $"""
            <?xml version="1.0"?>
            <WLANProfile xmlns="http://www.microsoft.com/networking/WLAN/profile/v1">
              <name>{(name.Length == 0 ? "Printer setup" : name)}</name>
              <SSIDConfig><SSID><hex>{Convert.ToHexString(network.Ssid)}</hex></SSID></SSIDConfig>
              <connectionType>ESS</connectionType>
              <connectionMode>manual</connectionMode>
              <MSM><security><authEncryption><authentication>open</authentication><encryption>none</encryption><useOneX>false</useOneX></authEncryption></security></MSM>
            </WLANProfile>
            """;
    }

    /// <summary>
    /// The printer's setup page on its own network: the Wi-Fi gateway it gave this PC (the printer is the access point), as
    /// <c>http://address/</c>. Only a private or link-local IPv4 address counts (a setup network that hands out anything else isn't
    /// a printer's); null otherwise.
    /// </summary>
    public static Uri? SetupPage(IPAddress? gateway)
    {
        if (gateway is null || gateway.AddressFamily != AddressFamily.InterNetwork) return null;
        var b = gateway.GetAddressBytes();
        var isPrivate = b[0] == 10 || (b[0] == 172 && b[1] is >= 16 and <= 31) || (b[0] == 192 && b[1] == 168) || (b[0] == 169 && b[1] == 254);
        if (!isPrivate || b[3] is 0 or 255) return null;
        return new Uri($"http://{gateway}/");
    }
}
