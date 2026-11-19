using System.Net;
using System.Net.Sockets;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using System.Text;

namespace InkvoltPrint.Core.Sharing;

/// <summary>Windows' category of a network this PC is on (Settings › Network: Public or Private; a domain network is an office's).</summary>
public enum NetworkKind { Public, Private, Domain }

/// <summary>One address of this PC on a network: the interface, the address and its prefix (the local subnet), and the network's category.</summary>
public sealed record LocalNetwork(int InterfaceIndex, IPAddress Address, int PrefixLength, NetworkKind Kind);

/// <summary>
/// Who may reach the shared scanner (roadmap 3.1: private networks only). Served: this PC's addresses on networks Windows calls
/// Private. Allowed: a device on one of those addresses' own subnets (an IPv6 link-local one on that same interface), or this PC
/// itself. Everyone else's connection is closed before TLS starts; Windows Firewall keeps public networks out as well.
/// </summary>
public static class SharePeers
{
    /// <summary>
    /// The networks a share serves: the addresses, with a real subnet (not a /0 or a host route), of interfaces on a private network that
    /// have an IPv4 subnet of their own (a LAN). A VPN's point-to-point interface (a /32, with only IPv6 link-local beside it) isn't one:
    /// its peers aren't on a subnet, and multicast DNS doesn't cross it.
    /// </summary>
    public static IReadOnlyList<LocalNetwork> Served(IEnumerable<LocalNetwork> all)
    {
        var usable = all.Where(n => n.Kind == NetworkKind.Private && !IPAddress.IsLoopback(n.Address)
            && n.PrefixLength >= (n.Address.AddressFamily == AddressFamily.InterNetwork ? 8 : 32)
            && n.PrefixLength <= (n.Address.AddressFamily == AddressFamily.InterNetwork ? 30 : 127)).ToList();
        var lans = usable.Where(n => n.Address.AddressFamily == AddressFamily.InterNetwork).Select(n => n.InterfaceIndex).ToHashSet();
        return [.. usable.Where(n => lans.Contains(n.InterfaceIndex))];
    }

    /// <summary>Whether <paramref name="peer"/> may connect: this PC, or a device on a served network's subnet.</summary>
    public static bool Allows(IPAddress peer, IReadOnlyList<LocalNetwork> served)
    {
        if (peer.IsIPv4MappedToIPv6) peer = peer.MapToIPv4();
        if (IPAddress.IsLoopback(peer)) return true;
        foreach (var n in served)
        {
            if (n.Address.AddressFamily != peer.AddressFamily) continue;
            if (!SamePrefix(peer, n.Address, n.PrefixLength)) continue;
            // fe80::/64 is on every interface: only the one the peer came in on counts.
            if (peer.IsIPv6LinkLocal && peer.ScopeId != n.InterfaceIndex) continue;
            return true;
        }
        return false;
    }

    private static bool SamePrefix(IPAddress a, IPAddress b, int bits)
    {
        Span<byte> x = stackalloc byte[16], y = stackalloc byte[16];
        if (!a.TryWriteBytes(x, out var n) || !b.TryWriteBytes(y, out var m) || n != m || bits < 0 || bits > n * 8) return false;
        var whole = bits / 8;
        if (!x[..whole].SequenceEqual(y[..whole])) return false;
        var rest = bits % 8;
        if (rest == 0) return true;
        var mask = (byte)(0xFF << (8 - rest));
        return (x[whole] & mask) == (y[whole] & mask);
    }
}

/// <summary>
/// The shared scanner's TLS certificate (roadmap 3.1): self-signed, made once per install for this PC's name, an ECDSA P-256 key
/// (whose private half Windows keeps in the user's protected key store: InkvoltPrint.Windows). A client can't check it against
/// anyone, so the person compares <see cref="Fingerprint"/> with what the client shows, where it shows one.
/// </summary>
public static class ShareCertificate
{
    /// <summary>Apple's limit for a TLS server certificate (825 days), so an Apple client never refuses it for its length.</summary>
    public static readonly TimeSpan Life = TimeSpan.FromDays(825);

    /// <summary>A certificate this close to its end is made anew (with a new fingerprint).</summary>
    public static readonly TimeSpan RenewBefore = TimeSpan.FromDays(30);

    public const string Subject = "CN=Inkvolt Print scanner sharing";

    /// <summary>A certificate for <paramref name="key"/>, for <paramref name="hostName"/> (a DNS name such as <c>pc.local</c>).</summary>
    public static X509Certificate2 Create(ECDsa key, string hostName, DateTimeOffset now)
    {
        var request = new CertificateRequest(Subject, key, HashAlgorithmName.SHA256);
        request.CertificateExtensions.Add(new X509BasicConstraintsExtension(false, false, 0, true));
        request.CertificateExtensions.Add(new X509KeyUsageExtension(X509KeyUsageFlags.DigitalSignature, true));
        request.CertificateExtensions.Add(new X509EnhancedKeyUsageExtension([new System.Security.Cryptography.Oid("1.3.6.1.5.5.7.3.1")], false));
        var names = new SubjectAlternativeNameBuilder();
        names.AddDnsName(hostName);
        request.CertificateExtensions.Add(names.Build());
        return request.CreateSelfSigned(now.AddDays(-1), now.Add(Life));
    }

    /// <summary>Still good to use at <paramref name="now"/> (not yet close to its end), and made by this app.</summary>
    public static bool Usable(X509Certificate2 cert, DateTimeOffset now) =>
        cert.Subject == Subject && cert.NotBefore <= now.LocalDateTime && now.Add(RenewBefore).LocalDateTime < cert.NotAfter && cert.GetECDsaPublicKey() is not null;

    /// <summary>SHA-256 of the certificate, as pairs of hex digits joined by colons (what Safari's and OpenSSL's views show).</summary>
    public static string Fingerprint(X509Certificate2 cert) => string.Join(':', SHA256.HashData(cert.RawData).Select(b => b.ToString("X2")));

    /// <summary>
    /// A certificate with a key kept nowhere (tests, demo mode): made, then loaded the way Windows' TLS can use it (an in-memory key
    /// can't serve TLS there). Its key is removed when it's disposed.
    /// </summary>
    public static X509Certificate2 Ephemeral(string hostName, DateTimeOffset now)
    {
        using var key = ECDsa.Create(ECCurve.NamedCurves.nistP256);
        using var made = Create(key, hostName, now);
        return X509CertificateLoader.LoadPkcs12(made.Export(X509ContentType.Pkcs12), null);
    }
}

/// <summary>What the shared scanner announces over DNS-SD (Bonjour): <c>_uscans._tcp</c>, its name, port and TXT keys.</summary>
/// <param name="Instance">The name clients list (at most 63 bytes, no dots).</param>
/// <param name="Host">This PC's <c>.local</c> name.</param>
public sealed record ShareAdvert(string Instance, string Host, int Port, IReadOnlyList<KeyValuePair<string, string>> Txt)
{
    public const string Service = "_uscans._tcp";
}

/// <summary>The DNS-SD record for a shared scanner, as Mopria's eSCL and Apple's AirScan clients read it.</summary>
public static class ShareDnssd
{
    /// <summary>The advert for <paramref name="id"/> on <paramref name="port"/>: rs=eSCL, its UUID, color modes, sources, duplex and formats.</summary>
    public static ShareAdvert For(ShareIdentity id, Escl.ScannerCapabilities caps, string computerName, int port)
    {
        var inputs = new[] { caps.Platen, caps.Adf }.OfType<Escl.InputCaps>().ToList();
        var modes = inputs.SelectMany(i => i.ColorModes).Distinct().ToList();
        var cs = new List<string>();
        if (modes.Contains("BlackAndWhite1")) cs.Add("binary");
        if (modes.Contains("Grayscale8")) cs.Add("grayscale");
        if (modes.Contains("RGB24") || modes.Count == 0) cs.Add("color");
        var sources = new List<string>();
        if (caps.Platen is not null) sources.Add("platen");
        if (caps.Adf is not null) sources.Add("adf");
        var txt = new List<KeyValuePair<string, string>>
        {
            new("txtvers", "1"),
            new("vers", ShareXml.Version),
            new("rs", "eSCL"),
            new("ty", Bytes(id.Name, 200)),
            new("UUID", id.Uuid.ToString("D")),
            new("pdl", string.Join(',', ShareXml.Formats)),
            new("cs", string.Join(',', cs)),
            new("is", string.Join(',', sources)),
            new("duplex", caps.AdfDuplex ? "T" : "F"),
        };
        return new ShareAdvert(InstanceName(id.Name, computerName), HostName(computerName), port, txt);
    }

    /// <summary>"Scanner on PC" in the app's language: no dots or control characters, cut to DNS-SD's 63 bytes.</summary>
    public static string InstanceName(string scannerName, string computerName)
    {
        var name = string.Format(CoreStrings.Share_InstanceName, scannerName.Trim(), computerName.Trim());
        var clean = string.Join(' ', new string([.. name.Select(c => char.IsControl(c) || c is '.' or '\\' ? ' ' : c)])
            .Split(' ', StringSplitOptions.RemoveEmptyEntries));
        return Bytes(clean.Length == 0 ? "Inkvolt Print scanner" : clean, 63);
    }

    /// <summary>This PC's name as a <c>.local</c> host name: letters, digits and dashes (others become dashes).</summary>
    public static string HostName(string computerName)
    {
        var label = new string([.. computerName.Trim().Select(c => char.IsAsciiLetterOrDigit(c) ? c : '-')]).Trim('-');
        if (label.Length > 63) label = label[..63].TrimEnd('-');
        return (label.Length == 0 ? "inkvolt-print" : label) + ".local";
    }

    /// <summary>The longest start of <paramref name="text"/> that is at most <paramref name="max"/> UTF-8 bytes, cut between characters.</summary>
    private static string Bytes(string text, int max)
    {
        if (Encoding.UTF8.GetByteCount(text) <= max) return text;
        var cut = text;
        while (cut.Length > 0 && Encoding.UTF8.GetByteCount(cut) > max)
            cut = cut[..^(char.IsLowSurrogate(cut[^1]) && cut.Length > 1 ? 2 : 1)];
        return cut.TrimEnd();
    }
}
