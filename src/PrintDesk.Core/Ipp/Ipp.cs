using System.Buffers.Binary;
using System.Net.Http.Headers;
using System.Text;
using PrintDesk.Core.Model;
using PrintDesk.Core.Net;

namespace PrintDesk.Core.Ipp;

/// <summary>Minimal IPP/1.1 encoding (RFC 8010): enough for Get-Printer-Attributes.</summary>
public static class IppCodec
{
    public const ushort GetPrinterAttributes = 0x000B;

    private const byte OperationTag = 0x01, PrinterTag = 0x04, EndTag = 0x03;
    private const byte Integer = 0x21, Boolean = 0x22, Enum = 0x23;
    private const byte Charset = 0x47, NaturalLanguage = 0x48, Uri = 0x45, Keyword = 0x44;

    public static byte[] EncodeGetPrinterAttributes(string printerUri, IEnumerable<string> requested, int requestId = 1)
    {
        using var ms = new MemoryStream();
        Span<byte> head = stackalloc byte[8];
        head[0] = 1; head[1] = 1;
        BinaryPrimitives.WriteUInt16BigEndian(head[2..], GetPrinterAttributes);
        BinaryPrimitives.WriteInt32BigEndian(head[4..], requestId);
        ms.Write(head);
        ms.WriteByte(OperationTag);
        WriteAttr(ms, Charset, "attributes-charset", "utf-8");
        WriteAttr(ms, NaturalLanguage, "attributes-natural-language", "en");
        WriteAttr(ms, Uri, "printer-uri", printerUri);
        var first = true;
        foreach (var r in requested)
        {
            WriteAttr(ms, Keyword, first ? "requested-attributes" : "", r);
            first = false;
        }
        ms.WriteByte(EndTag);
        return ms.ToArray();
    }

    /// <summary>Decodes the printer-attributes group. Values: string, int, bool, or byte[] for unknown types.</summary>
    public static IppResponse Decode(ReadOnlySpan<byte> b)
    {
        if (b.Length < 9) throw new FormatException("IPP response too short");
        var status = BinaryPrimitives.ReadUInt16BigEndian(b[2..]);
        var attrs = new Dictionary<string, List<object>>(StringComparer.Ordinal);
        var i = 8;
        string? last = null;
        byte group = 0;
        while (i < b.Length)
        {
            var tag = b[i++];
            if (tag == EndTag) break;
            if (tag < 0x10) { group = tag; last = null; continue; }
            // A truncated or corrupt reply must surface as FormatException, never IndexOutOfRange.
            if (i + 2 > b.Length) throw new FormatException("IPP response truncated");
            var nameLen = BinaryPrimitives.ReadUInt16BigEndian(b[i..]); i += 2;
            if (i + nameLen + 2 > b.Length) throw new FormatException("IPP response truncated");
            var name = Encoding.UTF8.GetString(b.Slice(i, nameLen)); i += nameLen;
            var valLen = BinaryPrimitives.ReadUInt16BigEndian(b[i..]); i += 2;
            if (i + valLen > b.Length) throw new FormatException("IPP response truncated");
            var val = b.Slice(i, valLen); i += valLen;
            if (nameLen > 0) last = name;
            if (last is null || group != PrinterTag) continue;
            object value = tag switch
            {
                Integer or Enum when valLen == 4 => BinaryPrimitives.ReadInt32BigEndian(val),
                Boolean when valLen == 1 => val[0] != 0,
                >= 0x40 and <= 0x4F => Encoding.UTF8.GetString(val),
                _ => val.ToArray(),
            };
            if (!attrs.TryGetValue(last, out var list)) attrs[last] = list = [];
            list.Add(value);
        }
        return new IppResponse(status, attrs);
    }

    private static void WriteAttr(Stream s, byte tag, string name, string value)
    {
        var n = Encoding.UTF8.GetBytes(name);
        var v = Encoding.UTF8.GetBytes(value);
        Span<byte> len = stackalloc byte[2];
        s.WriteByte(tag);
        BinaryPrimitives.WriteUInt16BigEndian(len, (ushort)n.Length); s.Write(len); s.Write(n);
        BinaryPrimitives.WriteUInt16BigEndian(len, (ushort)v.Length); s.Write(len); s.Write(v);
    }
}

public sealed record IppResponse(ushort StatusCode, IReadOnlyDictionary<string, List<object>> Attributes)
{
    public bool Ok => StatusCode < 0x0100;
    public string? Str(string name) => Attributes.TryGetValue(name, out var v) ? v.FirstOrDefault() as string : null;
    public int? Int(string name) => Attributes.TryGetValue(name, out var v) && v.FirstOrDefault() is int i ? i : null;
    public IEnumerable<string> Strs(string name) => Attributes.TryGetValue(name, out var v) ? v.OfType<string>() : [];
    public IEnumerable<int> Ints(string name) => Attributes.TryGetValue(name, out var v) ? v.OfType<int>() : [];
}

public sealed class IppClient(DeviceHttp http, string resourcePath = "ipp/print", int port = 631)
{
    public static readonly string[] StatusAttributes =
    [
        "printer-state", "printer-state-reasons", "printer-state-message", "printer-make-and-model", "printer-uuid",
        "printer-info", "marker-names", "marker-levels", "marker-low-levels", "marker-types", "marker-colors",
        "document-format-supported",
    ];

    public Uri Endpoint { get; } = new UriBuilder(Uri.UriSchemeHttp, http.Host, port, resourcePath).Uri;

    public async Task<IppResponse> GetPrinterAttributesAsync(IEnumerable<string>? requested = null, CancellationToken ct = default)
    {
        var printerUri = new UriBuilder("ipp", http.Host, port, resourcePath).Uri.AbsoluteUri;
        var body = IppCodec.EncodeGetPrinterAttributes(printerUri, requested ?? StatusAttributes);
        using var req = new HttpRequestMessage(HttpMethod.Post, Endpoint)
        {
            Content = new ByteArrayContent(body) { Headers = { ContentType = new MediaTypeHeaderValue("application/ipp") } },
        };
        using var resp = await http.SendAsync(req, TimeSpan.FromSeconds(5), ct).ConfigureAwait(false);
        await DeviceHttp.EnsureSuccessAsync(resp).ConfigureAwait(false);
        return IppCodec.Decode(await resp.Content.ReadAsByteArrayAsync(ct).ConfigureAwait(false));
    }

    public static PrinterStatus ToStatus(IppResponse r)
    {
        var reasons = r.Strs("printer-state-reasons").Where(x => x != "none").ToList();
        var alerts = reasons.Select(x =>
        {
            var sev = x.EndsWith("-error", StringComparison.Ordinal) ? Severity.Error
                : x.EndsWith("-warning", StringComparison.Ordinal) ? Severity.Warning
                : x.EndsWith("-report", StringComparison.Ordinal) ? Severity.Info
                : Severity.Error; // RFC 8011 §5.4.12: a reason with no suffix is an error
            var id = x.EndsWith("-error") || x.EndsWith("-warning") || x.EndsWith("-report") ? x[..x.LastIndexOf('-')] : x;
            return new PrinterAlert(id, sev, Ledm.StatusText.Humanize(id));
        }).ToList();
        var (code, text) = r.Int("printer-state") switch
        {
            3 => ("ready", "Ready"),
            4 => ("processing", "Printing"),
            5 => ("stopped", "Stopped"),
            _ => ("unknown", "Unknown"),
        };
        var sev = alerts.Count > 0 ? alerts.Max(a => a.Severity) : code == "stopped" ? Severity.Error : Severity.Info;
        return new PrinterStatus(code, r.Str("printer-state-message") is { Length: > 0 } m ? m : text, sev, alerts);
    }

    public static IReadOnlyList<Consumable> ToConsumables(IppResponse r)
    {
        var names = r.Strs("marker-names").ToList();
        var levels = r.Ints("marker-levels").ToList();
        var lows = r.Ints("marker-low-levels").ToList();
        var types = r.Strs("marker-types").ToList();
        return names.Select((n, i) =>
        {
            int? level = i < levels.Count && levels[i] >= 0 ? levels[i] : null;
            int? low = i < lows.Count ? lows[i] : null;
            var state = level is null ? "unknown" : level == 0 ? "out" : low is { } l && level <= l ? "low" : "ok";
            return new Consumable(n, i < types.Count ? types[i] : "supply", null, level, state, null, null, low, null, null);
        }).ToList();
    }
}
