using System.Globalization;
using System.Text.RegularExpressions;
using InkvoltPrint.Core.Suite;

namespace InkvoltPrint.Core.Recording;

/// <summary>
/// Takes out of a printer recording what identifies the printer, its network or a person, as Report a problem does
/// (<see cref="Diagnostics.Scrub"/>), but keeping the documents readable: every identifier gets a stand-in of the same shape,
/// the same one wherever it appears, so the identity checks still agree on replay (the UUID LEDM, eSCL and IPP report stays one
/// UUID; the serial number LEDM and SNMP report stays one serial). Serial numbers become <c>SN0…1</c> (same length), UUIDs
/// <c>00000000-0000-4000-8000-00000000000n</c>, addresses RFC 5737's (the recorded printer's is <see cref="PlaceholderHost"/>),
/// IPv6 addresses RFC 3849's <c>2001:db8::n</c>, MAC addresses RFC 7042's <c>00:00:5E:00:53:nn</c>, host names
/// <c>printer-n</c> (<c>.local</c> and <c>.example</c> kept as the shape), e-mail addresses <c>user@example.com</c>.
/// What a person typed (printer name, location, contact, user and job names, Wi-Fi names) becomes a word that says what it was.
/// Two passes: <see cref="Learn"/> every document first (identifiers from their fields: serials, UUIDs, MAC addresses, host
/// names), then <see cref="Scrub"/> each, so an identifier learnt in one document is caught in free text in another.
/// </summary>
public sealed partial class FixtureScrubber(string host, string placeholderHost = FixtureScrubber.DefaultPlaceholderHost, Diagnostics.Identity? who = null)
{
    /// <summary>Where a recording's printer is: the demo printer's address (RFC 5737), so <c>FixtureHandler</c>'s tests read it as is.</summary>
    public const string DefaultPlaceholderHost = Net.FixtureHandler.DemoHost;

    public string PlaceholderHost { get; } = placeholderHost;

    private enum Kind { Serial, Uuid, Mac, Ip, Ip6, Host, Bracket }

    private readonly Dictionary<Kind, Dictionary<string, string>> _maps = Enum.GetValues<Kind>()
        .ToDictionary(k => k, _ => new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase));
    private readonly HashSet<string> _placeholders = new(StringComparer.OrdinalIgnoreCase);

    /// <summary>What was replaced, by kind, for the recording's notes (counts only, never the values).</summary>
    public IReadOnlyDictionary<string, int> Counts => _maps.Where(kv => kv.Value.Count > 0).ToDictionary(kv => kv.Key.ToString(), kv => kv.Value.Count);

    // ---------------------------------------------------------------------------------------------------- learning

    /// <summary>Notes the identifiers in one document's fields (by <paramref name="name"/>'s kind: XML, JSON, IppText, snmpwalk).</summary>
    public void Learn(string name, string text)
    {
        switch (KindOf(name))
        {
            case DocKind.Xml:
                foreach (Match m in XmlField().Matches(text)) LearnField(m.Groups["n"].Value, m.Groups["v"].Value);
                break;
            case DocKind.Json:
                foreach (Match m in JsonField().Matches(text)) LearnField(m.Groups["n"].Value, m.Groups["v"].Value);
                break;
            case DocKind.Ipp:
                foreach (Match m in IppLine().Matches(text))
                {
                    var (attr, value) = (m.Groups["n"].Value, m.Groups["v"].Value.TrimEnd('\r'));
                    if (attr == "printer-device-id")
                        foreach (Match sn in DeviceIdSerial().Matches(value)) LearnField("SerialNumber", sn.Groups["v"].Value);
                    else LearnField(attr, value);
                }
                break;
            case DocKind.Snmp:
                foreach (Match m in SnmpString().Matches(text))
                    if (m.Groups["oid"].Value.StartsWith(PrtGeneralSerialNumber, StringComparison.Ordinal)) LearnField("SerialNumber", m.Groups["v"].Value);
                break;
        }
    }

    private void LearnField(string field, string value)
    {
        value = value.Trim();
        // "N/A", "none", "0": nothing that identifies anyone, and too common to replace wherever it appears.
        if (value.Length < 4 || !value.Any(char.IsDigit) && Category(field) is not Field.Host) return;
        switch (Category(field))
        {
            case Field.Serial: Map(Kind.Serial, value); break;
            case Field.Uuid: Map(Kind.Uuid, value.Replace("urn:uuid:", "", StringComparison.OrdinalIgnoreCase)); break;
            case Field.Mac: Map(Kind.Mac, value); break;
            case Field.Host when !value.Contains(' '): Map(Kind.Host, value); break;
        }
    }

    // ---------------------------------------------------------------------------------------------------- scrubbing

    /// <summary>One document with every identifier replaced (see the class summary). Call after <see cref="Learn"/> on all of them.</summary>
    public string Scrub(string name, string text)
    {
        // What a person typed, in its own field.
        text = KindOf(name) switch
        {
            DocKind.Xml => XmlField().Replace(text, m => Retype(m, Typed(m.Groups["n"].Value))),
            DocKind.Json => JsonField().Replace(text, m => Retype(m, Typed(m.Groups["n"].Value))),
            DocKind.Ipp => IppLine().Replace(text, m => Retype(m, TypedIpp(m.Groups["n"].Value))),
            DocKind.Snmp => SnmpString().Replace(text, m => Retype(m, TypedSnmp(m.Groups["oid"].Value))),
            _ => text,
        };

        // Versions (firmware 6.28.3.30-…, revisions) are set aside so no address pattern takes them, and put back at the end.
        var versions = new List<string>();
        string Aside(Match m) => IsVersion(m.Groups["n"].Value) && !m.Groups["v"].Value.Contains("://", StringComparison.Ordinal)
            ? Swap(m, "v", Hold(versions, m.Groups["v"].Value)) : m.Value;
        text = KindOf(name) switch
        {
            DocKind.Xml => XmlField().Replace(text, Aside),
            DocKind.Json => JsonField().Replace(text, Aside),
            DocKind.Ipp => IppLine().Replace(text, Aside),
            _ => text,
        };

        // Identifiers learnt from the fields, wherever they appear (longest first, whole tokens only).
        foreach (var kind in new[] { Kind.Uuid, Kind.Serial, Kind.Mac, Kind.Host })
            foreach (var (from, to) in _maps[kind].OrderByDescending(kv => kv.Key.Length).ToList())
            {
                if (from == to) continue;
                text = Regex.Replace(text, $@"(?<![A-Za-z0-9]){Regex.Escape(from)}(?![A-Za-z0-9])", to.Replace("$", "$$"), RegexOptions.IgnoreCase);
                if (kind == Kind.Mac && HexOnly(from) is { } hex) // a MAC address also written as bare or spaced hex (SNMP)
                    text = Regex.Replace(text, $@"(?<![0-9A-Fa-f]){string.Join(@"[\s:-]?", hex.Chunk(2).Select(c => new string(c)))}(?![0-9A-Fa-f])",
                        HexOnly(to)!, RegexOptions.IgnoreCase);
            }

        // The patterns, for whatever no field named.
        if (who?.UserName is { Length: >= 3 } user) text = Regex.Replace(text, $@"\b{Regex.Escape(user)}\b", "user", RegexOptions.IgnoreCase);
        if (who?.MachineName is { Length: >= 3 } pc) text = Regex.Replace(text, $@"\b{Regex.Escape(pc)}\b", "pc", RegexOptions.IgnoreCase);
        text = Email().Replace(text, "user@example.com");
        text = UrlHost().Replace(text, m => m.Groups["s"].Value + HostOrAddress(m.Groups["h"].Value));
        text = LocalName().Replace(text, m => Map(Kind.Host, m.Value));
        text = UuidPattern().Replace(text, m => Map(Kind.Uuid, m.Value));
        text = MacPattern().Replace(text, m => Map(Kind.Mac, m.Value));
        text = Ipv6().Replace(text, m => Map(Kind.Ip6, m.Value));
        text = Ipv4().Replace(text, m => Map(Kind.Ip, m.Value));
        text = HpHostName().Replace(text, m => Map(Kind.Host, m.Value));
        text = LabelledSerial().Replace(text, m => Swap(m, "v", Map(Kind.Serial, m.Groups["v"].Value)));
        text = BracketId().Replace(text, m => Swap(m, "v", Map(Kind.Bracket, m.Groups["v"].Value)));
        if (!IsAddress(host)) text = Regex.Replace(text, $@"(?<![\w.-]){Regex.Escape(host)}(?![\w-])", PlaceholderHost, RegexOptions.IgnoreCase);
        return Held().Replace(text, m => versions[int.Parse(m.Groups["i"].Value, CultureInfo.InvariantCulture)]);
    }

    private static bool IsVersion(string field)
    {
        var f = field.ToLowerInvariant();
        return f.Contains("version", StringComparison.Ordinal) || f.Contains("revision", StringComparison.Ordinal)
               || f.Contains("firmware", StringComparison.Ordinal) && !f.Contains("uri", StringComparison.Ordinal);
    }

    private static string Hold(List<string> held, string value)
    {
        held.Add(value);
        return $"\u0001{held.Count - 1}\u0001";
    }

    private string HostOrAddress(string h)
    {
        var bare = h.Trim('[', ']');
        if (string.Equals(bare, host, StringComparison.OrdinalIgnoreCase)) return PlaceholderHost;
        if (System.Net.IPAddress.TryParse(bare, out var ip))
            return ip.AddressFamily == System.Net.Sockets.AddressFamily.InterNetworkV6 ? $"[{Map(Kind.Ip6, bare)}]" : Map(Kind.Ip, bare);
        return Map(Kind.Host, h);
    }

    /// <summary>The stand-in for <paramref name="value"/>: the same one every time; placeholders and documentation values stay.</summary>
    private string Map(Kind kind, string value)
    {
        if (kind is Kind.Ip or Kind.Host && string.Equals(value, host, StringComparison.OrdinalIgnoreCase)) return PlaceholderHost;
        if (_placeholders.Contains(value) || Kept(kind, value)) return value;
        var map = _maps[kind];
        if (map.TryGetValue(value, out var known)) return known;
        var n = map.Count + 1;
        var stand = kind switch
        {
            Kind.Serial => "SN" + n.ToString(CultureInfo.InvariantCulture).PadLeft(Math.Max(4, value.Length - 2), '0'),
            Kind.Uuid => $"00000000-0000-4000-8000-{n:D12}",
            Kind.Mac => FakeMac(value, n),
            Kind.Ip => n < 200 ? $"192.0.2.{n + 20}" : $"198.51.100.{n % 250 + 1}",
            Kind.Ip6 => $"2001:db8::{n:x}",
            Kind.Host => value.EndsWith(".local", StringComparison.OrdinalIgnoreCase) ? $"printer-{n}.local"
                : value.Contains('.') ? $"printer-{n}.example" : $"printer-{n}",
            Kind.Bracket => n.ToString("X6", CultureInfo.InvariantCulture),
            _ => throw new ArgumentOutOfRangeException(nameof(kind)),
        };
        map[value] = stand;
        _placeholders.Add(stand);
        return stand;
    }

    /// <summary>Not an identifier: loopback, unspecified, masks, the documentation ranges, versions that look like addresses.</summary>
    private bool Kept(Kind kind, string value) => kind switch
    {
        Kind.Ip => value.StartsWith("127.", StringComparison.Ordinal) || value.StartsWith("0.", StringComparison.Ordinal)
                   || value.StartsWith("255.", StringComparison.Ordinal) || value.StartsWith("192.0.2.", StringComparison.Ordinal)
                   || value.StartsWith("198.51.100.", StringComparison.Ordinal) || value.StartsWith("203.0.113.", StringComparison.Ordinal)
                   || (value == PlaceholderHost),
        Kind.Ip6 => value is "::" or "::1" || value.StartsWith("2001:db8:", StringComparison.OrdinalIgnoreCase),
        Kind.Mac => value.StartsWith("00:00:5E:00:53", StringComparison.OrdinalIgnoreCase) || value.StartsWith("00-00-5E-00-53", StringComparison.OrdinalIgnoreCase)
                    || HexOnly(value) is "000000000000" or "FFFFFFFFFFFF",
        Kind.Uuid => value.StartsWith("00000000-0000-", StringComparison.Ordinal),
        Kind.Host => value.Equals(PlaceholderHost, StringComparison.OrdinalIgnoreCase) || value.EndsWith(".example", StringComparison.OrdinalIgnoreCase)
                     || value.Equals("localhost", StringComparison.OrdinalIgnoreCase),
        _ => false,
    };

    private static string FakeMac(string value, int n)
    {
        var sep = value.Contains(':') ? ":" : value.Contains('-') ? "-" : value.Contains(' ') ? " " : "";
        var mac = string.Join(sep, "00", "00", "5E", "00", "53", (n % 256).ToString("X2", CultureInfo.InvariantCulture));
        return value.Any(char.IsLower) ? mac.ToLowerInvariant() : mac;
    }

    private static string? HexOnly(string mac)
    {
        var hex = new string(mac.Where(Uri.IsHexDigit).ToArray()).ToUpperInvariant();
        return hex.Length == 12 ? hex : null;
    }

    private static bool IsAddress(string h) => System.Net.IPAddress.TryParse(h.Trim('[', ']'), out _);

    /// <summary>A typed value replaced by <paramref name="word"/>; an empty one stays empty.</summary>
    private static string Retype(Match m, string? word) => word is null || m.Groups["v"].Value.Trim().Length == 0 ? m.Value : Swap(m, "v", word);

    /// <summary>The match with one group's text replaced (the rest of the match kept as it was).</summary>
    private static string Swap(Match m, string group, string value)
    {
        var g = m.Groups[group];
        return m.Value[..(g.Index - m.Index)] + value + m.Value[(g.Index - m.Index + g.Length)..];
    }

    // ---------------------------------------------------------------------------------------------------- fields

    private enum DocKind { Other, Xml, Json, Ipp, Snmp }

    private static DocKind KindOf(string name) =>
        name.EndsWith(".ipp.txt", StringComparison.OrdinalIgnoreCase) ? DocKind.Ipp
        : name.EndsWith(".xml", StringComparison.OrdinalIgnoreCase) ? DocKind.Xml
        : name.EndsWith(".json", StringComparison.OrdinalIgnoreCase) ? DocKind.Json
        : name.EndsWith(".txt", StringComparison.OrdinalIgnoreCase) && name.Contains("snmp", StringComparison.OrdinalIgnoreCase) ? DocKind.Snmp
        : DocKind.Other;

    private enum Field { None, Serial, Uuid, Mac, Host, Name, Place, Person, Mail, Job, Network }

    /// <summary>What an XML element, JSON key or IPP attribute holds, from its name (any case, any prefix).</summary>
    private static Field Category(string field)
    {
        var f = field.Replace("-", "", StringComparison.Ordinal).Replace("_", "", StringComparison.Ordinal).ToLowerInvariant();
        return f switch
        {
            _ when f.EndsWith("serialnumber", StringComparison.Ordinal) || f is "serial" or "serialnum" or "printerserialnumber" => Field.Serial,
            _ when f.EndsWith("uuid", StringComparison.Ordinal) => Field.Uuid,
            _ when f.EndsWith("macaddress", StringComparison.Ordinal) || f.EndsWith("hardwareaddress", StringComparison.Ordinal) || f is "mac" => Field.Mac,
            _ when f.EndsWith("hostname", StringComparison.Ordinal) || f.EndsWith("domainname", StringComparison.Ordinal) || f is "fqdn" => Field.Host,
            _ when f.Contains("email", StringComparison.Ordinal) => Field.Mail,
            _ when f.EndsWith("username", StringComparison.Ordinal) || f is "owner" or "jobowner" or "userid" or "contact" or "contactname" or "username"
                   or "jobowneruser" or "personname" => Field.Person,
            _ when f.EndsWith("jobname", StringComparison.Ordinal) || f is "documentname" or "filename" => Field.Job,
            _ when f is "ssid" or "networkname" or "wirelessnetworkname" || f.EndsWith("ssid", StringComparison.Ordinal) => Field.Network,
            _ when f is "location" or "devicelocation" or "printerlocation" or "geolocation" or "printergeolocation" => Field.Place,
            _ when f is "friendlyname" or "devicename" or "computername" or "bonjourservicename" or "printerdnssdname" or "printername"
                   or "printerinfo" or "assetnumber" or "printerorganization" or "printerorganizationalunit" or "devicedescription" => Field.Name,
            _ => Field.None,
        };
    }

    /// <summary>The word that replaces a typed value, or null for a field that isn't typed by a person.</summary>
    private static string? Typed(string field) => Category(field) switch
    {
        Field.Name => "Printer",
        Field.Place => "Location",
        Field.Person => "user",
        Field.Mail => "user@example.com",
        Field.Job => "Job",
        Field.Network => "Network",
        _ => null,
    };

    private static string? TypedIpp(string attribute) => attribute switch
    {
        "printer-geo-location" => "geo:0,0",
        "printer-make-and-model" or "printer-device-id" => null,
        "job-originating-user-name" or "requesting-user-name" => "user",
        "job-name" or "document-name-supplied" => "Job",
        _ => Typed(attribute),
    };

    private const string SysContact = "1.3.6.1.2.1.1.4.", SysName = "1.3.6.1.2.1.1.5.", SysLocation = "1.3.6.1.2.1.1.6.";
    private const string PrtGeneralSerialNumber = "1.3.6.1.2.1.43.5.1.1.17.";
    private const string PrtGeneralCurrentOperator = "1.3.6.1.2.1.43.5.1.1.20.", PrtGeneralServicePerson = "1.3.6.1.2.1.43.5.1.1.21.";

    private static string? TypedSnmp(string oid) =>
        oid.StartsWith(SysContact, StringComparison.Ordinal) || oid.StartsWith(PrtGeneralCurrentOperator, StringComparison.Ordinal)
        || oid.StartsWith(PrtGeneralServicePerson, StringComparison.Ordinal) ? "user"
        : oid.StartsWith(SysName, StringComparison.Ordinal) ? "printer"
        : oid.StartsWith(SysLocation, StringComparison.Ordinal) ? "Location"
        : null;

    // An element with text only: <dd:SerialNumber attr="…">CN…</dd:SerialNumber>.
    [GeneratedRegex(@"<(?<p>(?:[\w.-]+:)?(?<n>[A-Za-z][\w.-]*))(?:\s[^>]*)?>(?<v>[^<]*)</\k<p>\s*>")]
    private static partial Regex XmlField();

    [GeneratedRegex(@"""(?<n>[A-Za-z][\w-]*)""\s*:\s*""(?<v>(?:[^""\\]|\\.)*)""")]
    private static partial Regex JsonField();

    [GeneratedRegex(@"^(?<n>[a-z][a-z0-9-]*) (?<s>[A-Za-z]+) (?<v>.*?)\r?$", RegexOptions.Multiline)]
    private static partial Regex IppLine();

    [GeneratedRegex(@"^\.(?<oid>[\d.]+) = STRING: ""(?<v>.*)""\r?$", RegexOptions.Multiline)]
    private static partial Regex SnmpString();

    // IEEE 1284 device ID: SN:CN123…; or SERN:…;
    [GeneratedRegex(@"(?:^|;)\s*(?:SN|SERN|SERIALNUMBER):(?<v>[^;]{3,})", RegexOptions.IgnoreCase)]
    private static partial Regex DeviceIdSerial();

    [GeneratedRegex(@"\u0001(?<i>\d+)\u0001")]
    private static partial Regex Held();

    [GeneratedRegex(@"[\w.+-]+@[\w-]+(?:\.[\w-]+)+")]
    private static partial Regex Email();

    [GeneratedRegex(@"(?<s>\b(?:https?|ipps?|wss?|socket|lpd)://(?:[^@/\s]*@)?)(?<h>\[[0-9A-Fa-f:.%\w]+\]|[^/\s:?#\[\]""'<>]+)")]
    private static partial Regex UrlHost();

    [GeneratedRegex(@"(?<![\w.-])[A-Za-z0-9][\w-]*(?:\.[\w-]+)*\.local\b")]
    private static partial Regex LocalName();

    [GeneratedRegex(@"\b[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}\b")]
    private static partial Regex UuidPattern();

    [GeneratedRegex(@"(?<![\w:-])[0-9A-Fa-f]{2}(?:([:-])[0-9A-Fa-f]{2})(?:\1[0-9A-Fa-f]{2}){4}(?![\w:-])")]
    private static partial Regex MacPattern();

    // Has "::" or at least five groups, so times (12:34:56) are left alone; the zone (%12) goes with it.
    [GeneratedRegex(@"(?<![\w:.])(?=[0-9A-Fa-f:]*::|(?:[0-9A-Fa-f]{1,4}:){5})[0-9A-Fa-f]{0,4}(?::[0-9A-Fa-f]{0,4}){2,7}(?::(?:\d{1,3}\.){3}\d{1,3})?(?:%\w+)?(?![\w:])")]
    private static partial Regex Ipv6();

    // As Report a problem: a dotted quad after "v"/"version", or all of one digit (1.0.7.0), is a version and stays; so is one
    // running on into a word or a hyphen (HP's firmware 6.28.3.30-202606…).
    [GeneratedRegex(@"(?<![\d.])(?<!\b(?i:v|ver|version)[\s=:]*)(?!\d\.\d\.\d\.\d(?!\d))(?:(?:25[0-5]|2[0-4]\d|1?\d?\d)\.){3}(?:25[0-5]|2[0-4]\d|1?\d?\d)(?![\w-]|\.\d)")]
    private static partial Regex Ipv4();

    [GeneratedRegex(@"\b(?:NPI|HP)[0-9A-F]{6}\b", RegexOptions.IgnoreCase)]
    private static partial Regex HpHostName();

    [GeneratedRegex(@"\b(?:serial(?:\s*number)?|s/n|SN|SERN)\s*[:=#]\s*(?<v>[A-Za-z0-9-]{4,})", RegexOptions.IgnoreCase)]
    private static partial Regex LabelledSerial();

    // HP's network names end in the last six hex digits of the MAC address: "HP LaserJet MFP M234dw [A1B2C3]" or "(A1B2C3)".
    [GeneratedRegex(@"[\[(](?<v>[0-9A-Fa-f]{6})[\])]")]
    private static partial Regex BracketId();
}
