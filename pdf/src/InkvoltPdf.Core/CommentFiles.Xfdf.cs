using System.Globalization;
using System.Text;
using System.Xml;
using System.Xml.Linq;

namespace InkvoltPdf.Core;

public static partial class CommentFiles
{
    private static readonly XNamespace XfdfNs = "http://ns.adobe.com/xfdf/";
    private static readonly XNamespace XhtmlNs = "http://www.w3.org/1999/xhtml";

    /// <summary>The XFDF element of each annotation subtype that has one.</summary>
    private static readonly Dictionary<string, string> XfdfElements = new(StringComparer.Ordinal)
    {
        ["Text"] = "text", ["FreeText"] = "freetext", ["Line"] = "line", ["Square"] = "square", ["Circle"] = "circle",
        ["Polygon"] = "polygon", ["PolyLine"] = "polyline", ["Highlight"] = "highlight", ["Underline"] = "underline",
        ["Squiggly"] = "squiggly", ["StrikeOut"] = "strikeout", ["Stamp"] = "stamp", ["Caret"] = "caret", ["Ink"] = "ink",
        ["Redact"] = "redact",
    };

    private static readonly Dictionary<string, string> SubtypeOfElement = XfdfElements.ToDictionary(kv => kv.Value, kv => kv.Key, StringComparer.Ordinal);

    /// <summary>Annotation flags (/F bits 1-10) by their XFDF names.</summary>
    private static readonly string[] FlagNames = ["invisible", "hidden", "print", "nozoom", "norotate", "noview", "readonly", "locked", "togglenoview", "lockedcontents"];

    /// <summary>Border styles (/BS /S) and their XFDF names.</summary>
    private static readonly (string Pdf, string Xfdf)[] Styles = [("S", "solid"), ("D", "dash"), ("B", "bevelled"), ("I", "inset"), ("U", "underline")];

    // ---------------- Writing ----------------

    private static byte[] WriteXfdf(List<Record> records, string? pdfFileName, List<string> left)
    {
        var annots = new XElement(XfdfNs + "annots");
        var notInXfdf = new SortedDictionary<string, int>(StringComparer.Ordinal);
        foreach (var r in records)
        {
            if (XfdfElements.TryGetValue(r.Subtype, out var name)) annots.Add(Element(r, name));
            else notInXfdf[r.Subtype] = notInXfdf.GetValueOrDefault(r.Subtype) + 1;
        }
        foreach (var (subtype, n) in notInXfdf) left.Add($"{Plural(n, KindName(subtype))}: XFDF has no element for them (FDF keeps them)");
        var root = new XElement(XfdfNs + "xfdf", new XAttribute(XNamespace.Xml + "space", "preserve"), annots);
        if (pdfFileName is not null) root.Add(new XElement(XfdfNs + "f", new XAttribute("href", pdfFileName)));
        using var ms = new MemoryStream();
        var settings = new XmlWriterSettings { Encoding = new UTF8Encoding(false), NewLineHandling = NewLineHandling.Entitize };
        using (var w = XmlWriter.Create(ms, settings)) new XDocument(new XDeclaration("1.0", "UTF-8", null), root).Save(w);
        return ms.ToArray();
    }

    private static XElement Element(Record r, string name)
    {
        var d = r.Dict;
        var e = new XElement(XfdfNs + name);
        void Attr(string attr, string? value)
        {
            if (!string.IsNullOrEmpty(value)) e.SetAttributeValue(attr, value);
        }

        Attr("page", r.Page.ToString(CultureInfo.InvariantCulture));
        Attr("rect", List(Numbers(d.GetValueOrDefault("Rect"))));
        Attr("name", r.Key);
        Attr("title", d.GetValueOrDefault("T") as string);
        Attr("subject", d.GetValueOrDefault("Subj") as string);
        Attr("date", d.GetValueOrDefault("M") as string);
        Attr("creationdate", d.GetValueOrDefault("CreationDate") as string);
        Attr("color", Hex(Numbers(d.GetValueOrDefault("C"))));
        Attr("interior-color", Hex(Numbers(d.GetValueOrDefault("IC"))));
        if (d.GetValueOrDefault("F") is double flags)
            Attr("flags", string.Join(',', FlagNames.Where((_, i) => ((int)flags & (1 << i)) != 0)));
        if (d.GetValueOrDefault("CA") is double ca && ca < 1) Attr("opacity", Fdf.Number(ca));
        if (r.ReplyTo is { } to)
        {
            Attr("inreplyto", to);
            Attr("replyType", d.GetValueOrDefault("RT") is Fdf.Name { Value: "Group" } ? "group" : "reply");
        }
        Attr("intent", (d.GetValueOrDefault("IT") as Fdf.Name)?.Value);

        // Border: /BS (width, style, dashes), else /Border [h v width [dash]]; clouds from /BE.
        if (d.GetValueOrDefault("BS") is Dictionary<string, object?> bs)
        {
            if (bs.GetValueOrDefault("W") is double w) Attr("width", Fdf.Number(w));
            if (bs.GetValueOrDefault("S") is Fdf.Name s && Styles.FirstOrDefault(x => x.Pdf == s.Value).Xfdf is { } style) Attr("style", style);
            if (Numbers(bs.GetValueOrDefault("D")) is { Count: > 0 } dash) Attr("dashes", List(dash));
        }
        else if (Numbers(d.GetValueOrDefault("Border")) is { Count: >= 3 } border) Attr("width", Fdf.Number(border[2]));
        if (d.GetValueOrDefault("BE") is Dictionary<string, object?> be && be.GetValueOrDefault("S") is Fdf.Name { Value: "C" })
        {
            Attr("style", "cloudy");
            if (be.GetValueOrDefault("I") is double intensity) Attr("intensity", Fdf.Number(intensity));
        }
        Attr("fringe", List(Numbers(d.GetValueOrDefault("RD"))));
        Attr("rotation", d.GetValueOrDefault("Rotate") is double rot ? Fdf.Number(rot) : null);
        Attr("icon", (d.GetValueOrDefault("Name") as Fdf.Name)?.Value);
        Attr("state", d.GetValueOrDefault("State") as string);
        Attr("statemodel", d.GetValueOrDefault("StateModel") as string);
        Attr("justification", d.GetValueOrDefault("Q") is double q ? q switch { 1 => "centered", 2 => "right", _ => "left" } : null);

        switch (r.Subtype)
        {
            case "Line":
                if (Numbers(d.GetValueOrDefault("L")) is { Count: 4 } l)
                {
                    Attr("start", List(l.Take(2)));
                    Attr("end", List(l.Skip(2)));
                }
                Ends();
                if (d.GetValueOrDefault("LL") is double ll) Attr("leaderLength", Fdf.Number(ll));
                if (d.GetValueOrDefault("LLE") is double lle) Attr("leaderExtended", Fdf.Number(lle));
                if (d.GetValueOrDefault("LLO") is double llo) Attr("leader-offset", Fdf.Number(llo));
                if (d.GetValueOrDefault("Cap") is bool cap) Attr("caption", cap ? "yes" : "no");
                break;
            case "PolyLine":
                Ends();
                break;
            case "FreeText":
                Attr("callout", List(Numbers(d.GetValueOrDefault("CL"))));
                if (d.GetValueOrDefault("LE") is Fdf.Name head) Attr("head", head.Value);
                break;
            case "Caret":
                Attr("symbol", d.GetValueOrDefault("Sy") is Fdf.Name { Value: "P" } ? "paragraph" : null);
                break;
            case "Redact":
                Attr("overlay-text", d.GetValueOrDefault("OverlayText") as string);
                break;
        }
        if (r.Subtype is "Highlight" or "Underline" or "Squiggly" or "StrikeOut" or "Redact")
            Attr("coords", List(Numbers(d.GetValueOrDefault("QuadPoints"))));

        if (d.GetValueOrDefault("Contents") is string { Length: > 0 } contents) e.Add(new XElement(XfdfNs + "contents", contents));
        if (d.GetValueOrDefault("RC") is string rc && RichText(rc) is { } body) e.Add(new XElement(XfdfNs + "contents-richtext", body));
        if (d.GetValueOrDefault("DA") is string da) e.Add(new XElement(XfdfNs + "defaultappearance", da));
        if (d.GetValueOrDefault("DS") is string ds) e.Add(new XElement(XfdfNs + "defaultstyle", ds));
        switch (r.Subtype)
        {
            case "Polygon" or "PolyLine" when Numbers(d.GetValueOrDefault("Vertices")) is { Count: >= 2 } v:
                e.Add(new XElement(XfdfNs + "vertices", Pairs(v)));
                break;
            case "Ink" when d.GetValueOrDefault("InkList") is List<object?> strokes:
                e.Add(new XElement(XfdfNs + "inklist", strokes.Select(Numbers).OfType<List<double>>().Select(s => new XElement(XfdfNs + "gesture", Pairs(s)))));
                break;
            case "Stamp" when d.GetValueOrDefault("AP") is Dictionary<string, object?> ap && AppearanceXml(ap) is { } xml:
                e.Add(new XElement(XfdfNs + "appearance", Convert.ToBase64String(xml)));
                break;
        }
        return e;

        void Ends()
        {
            if (d.GetValueOrDefault("LE") is List<object?> { Count: 2 } le)
            {
                Attr("head", (le[0] as Fdf.Name)?.Value);
                Attr("tail", (le[1] as Fdf.Name)?.Value);
            }
        }
    }

    private static string? List(IEnumerable<double>? values) => values is null ? null : string.Join(',', values.Select(Fdf.Number));

    /// <summary>"x,y;x,y;…", the way XFDF writes vertices and ink gestures.</summary>
    private static string Pairs(List<double> v) =>
        string.Join(';', Enumerable.Range(0, v.Count / 2).Select(i => Fdf.Number(v[2 * i]) + "," + Fdf.Number(v[2 * i + 1])));

    private static string? Hex(List<double>? c)
    {
        double r, g, b;
        switch (c?.Count)
        {
            case 1: r = g = b = c[0]; break;
            case 3: (r, g, b) = (c[0], c[1], c[2]); break;
            case 4: (r, g, b) = ((1 - c[0]) * (1 - c[3]), (1 - c[1]) * (1 - c[3]), (1 - c[2]) * (1 - c[3])); break;
            default: return null;
        }
        return string.Create(CultureInfo.InvariantCulture, $"#{Byte(r):X2}{Byte(g):X2}{Byte(b):X2}");

        static int Byte(double v) => (int)Math.Round(Math.Clamp(v, 0, 1) * 255);
    }

    /// <summary>/RC rich text as its XHTML body element (null when it isn't well-formed XML).</summary>
    private static XElement? RichText(string rc)
    {
        try
        {
            var root = XElement.Load(XmlReader.Create(new StringReader(rc), SafeXml(rc.Length * 2L + 1024)));
            return root.Name.LocalName == "body" ? root : null;
        }
        catch (XmlException)
        {
            return null;
        }
    }

    private static XmlReaderSettings SafeXml(long maxChars) => new()
    {
        DtdProcessing = DtdProcessing.Prohibit,
        XmlResolver = null,
        MaxCharactersInDocument = Math.Min(maxChars, MaxFileBytes * 2L),
        MaxCharactersFromEntities = 1024,
    };

    /// <summary>
    /// An appearance dictionary the way Acrobat puts it in XFDF (base64 of an XML tree: DICT, STREAM, ARRAY, NAME, INT,
    /// FIXED, BOOL, STRING, and each stream's bytes in DATA as stored, hex, its /Filter kept).
    /// </summary>
    private static byte[]? AppearanceXml(Dictionary<string, object?> ap)
    {
        var nodes = 0;
        XElement? Node(string tag, string? key, object? v, int depth)
        {
            if (++nodes > 200_000 || depth > 32) return null;
            var e = new XElement(tag);
            if (key is not null) e.SetAttributeValue("KEY", key);
            switch (v)
            {
                case Fdf.Stream s:
                    e.Name = "STREAM";
                    foreach (var (k, x) in s.Dict) e.Add(Of(k, x, depth));
                    e.Add(new XElement("DATA", new XAttribute("MODE", "FILTERED"), new XAttribute("ENCODING", "HEX"), Convert.ToHexString(s.Data)));
                    return e;
                case Dictionary<string, object?> dict:
                    e.Name = "DICT";
                    foreach (var (k, x) in dict) e.Add(Of(k, x, depth));
                    return e;
                case List<object?> list:
                    e.Name = "ARRAY";
                    foreach (var x in list) e.Add(Of(null, x, depth));
                    return e;
                case Fdf.Name n:
                    e.Name = "NAME";
                    e.SetAttributeValue("VAL", n.Value);
                    return e;
                case double d:
                    e.Name = Math.Abs(d - Math.Round(d)) < 1e-9 && Math.Abs(d) < int.MaxValue ? "INT" : "FIXED";
                    e.SetAttributeValue("VAL", Fdf.Number(d));
                    return e;
                case bool b:
                    e.Name = "BOOL";
                    e.SetAttributeValue("VAL", b ? "true" : "false");
                    return e;
                case string str when str.All(XmlConvert.IsXmlChar):
                    e.Name = "STRING";
                    e.SetAttributeValue("VAL", str);
                    return e;
                default:
                    return null;
            }
        }
        XElement? Of(string? key, object? v, int depth) => Node("X", key, v, depth + 1);

        var root = Node("DICT", "AP", ap, 0);
        if (root is null || nodes > 200_000) return null;
        using var ms = new MemoryStream();
        using (var w = XmlWriter.Create(ms, new XmlWriterSettings { Encoding = new UTF8Encoding(false) })) new XDocument(new XDeclaration("1.0", "UTF-8", null), root).Save(w);
        return ms.ToArray();
    }

    // ---------------- Reading ----------------

    private static List<Record> ReadXfdf(byte[] file, List<string> skipped)
    {
        // A DTD could pull in other files or blow up as it expands: refused outright, before any parsing.
        var head = Encoding.UTF8.GetString(file, 0, Math.Min(file.Length, 4096));
        if (head.Contains("<!DOCTYPE", StringComparison.OrdinalIgnoreCase) || head.Contains("<!ENTITY", StringComparison.OrdinalIgnoreCase))
            throw new InvalidDataException("The XFDF file has a DTD (<!DOCTYPE>), which Inkvolt PDF doesn't read: it could make the file read other files or grow without end.");
        XDocument doc;
        try
        {
            using var reader = XmlReader.Create(new MemoryStream(file), SafeXml(MaxFileBytes * 2L));
            doc = XDocument.Load(reader);
        }
        catch (XmlException ex)
        {
            throw new InvalidDataException(ex.Message.Contains("DTD", StringComparison.OrdinalIgnoreCase)
                ? "The XFDF file has a DTD, which Inkvolt PDF doesn't read."
                : $"The file isn't valid XFDF: {ex.Message}", ex);
        }
        if (doc.Root is not { } root || root.Name.LocalName != "xfdf") throw new InvalidDataException("The file isn't XFDF (its root element isn't <xfdf>).");

        var elements = root.Elements().Where(x => x.Name.LocalName == "annots").SelectMany(a => a.Elements()).ToList();
        if (elements.Count > MaxComments) throw new InvalidDataException($"The file has more than {MaxComments:N0} comments, the most Inkvolt PDF imports.");
        var cleaner = new Cleaner(v => v);
        var records = new List<Record>();
        for (var i = 0; i < elements.Count; i++)
        {
            var x = elements[i];
            var page = int.TryParse((string?)x.Attribute("page"), NumberStyles.None, CultureInfo.InvariantCulture, out var pg) ? pg : -1;
            if (!SubtypeOfElement.TryGetValue(x.Name.LocalName, out var subtype))
            {
                if (x.Name.LocalName != "popup") skipped.Add($"Page {page + 1}, <{x.Name.LocalName}>: not a kind of comment Inkvolt PDF imports");
                continue;
            }
            var dict = FromXfdf(x, subtype);
            if (cleaner.Annotation(dict) is not { } clean) continue;
            var key = (string?)x.Attribute("name") is { Length: > 0 } nm ? nm : HashKey("xfdf", i, null, clean);
            records.Add(new Record { Key = key, Page = page, Dict = clean, ReplyTo = (string?)x.Attribute("inreplyto") is { Length: > 0 } to ? to : null });
        }
        return records;
    }

    private static Dictionary<string, object?> FromXfdf(XElement x, string subtype)
    {
        var d = new Dictionary<string, object?>(StringComparer.Ordinal) { ["Subtype"] = new Fdf.Name(subtype) };
        string? A(string name) => (string?)x.Attribute(name);
        XElement? Child(string name) => x.Elements().FirstOrDefault(c => c.Name.LocalName == name);
        void Put(string key, object? value)
        {
            if (value is not null) d[key] = value;
        }

        Put("Rect", Nums(A("rect")) is { Count: 4 } rect ? Box(rect) : null);
        Put("T", A("title"));
        Put("Subj", A("subject"));
        Put("M", A("date"));
        Put("CreationDate", A("creationdate"));
        Put("C", Color(A("color")));
        Put("IC", Color(A("interior-color")));
        if (A("flags") is { } flags)
        {
            var f = 0;
            foreach (var part in flags.Split(',', StringSplitOptions.TrimEntries | StringSplitOptions.RemoveEmptyEntries))
                if (Array.IndexOf(FlagNames, part.ToLowerInvariant()) is var bit and >= 0) f |= 1 << bit;
            d["F"] = (double)f;
        }
        Put("CA", Num(A("opacity")) is { } ca ? Math.Clamp(ca, 0, 1) : null);
        if (A("inreplyto") is { Length: > 0 }) d["RT"] = new Fdf.Name(A("replyType")?.Equals("group", StringComparison.OrdinalIgnoreCase) == true ? "Group" : "R");
        Put("IT", A("intent") is { Length: > 0 } it ? new Fdf.Name(it) : null);

        var style = A("style")?.ToLowerInvariant();
        var bs = new Dictionary<string, object?>(StringComparer.Ordinal) { ["Type"] = new Fdf.Name("Border") };
        if (Num(A("width")) is { } width) bs["W"] = Math.Clamp(width, 0, 1000);
        if (Styles.FirstOrDefault(s => s.Xfdf == style).Pdf is { } pdfStyle) bs["S"] = new Fdf.Name(pdfStyle);
        if (Nums(A("dashes")) is { Count: > 0 } dashes)
        {
            bs["D"] = dashes.Take(16).Cast<object?>().ToList();
            bs.TryAdd("S", new Fdf.Name("D"));
        }
        if (bs.Count > 1) d["BS"] = bs;
        if (style == "cloudy")
            d["BE"] = new Dictionary<string, object?>(StringComparer.Ordinal) { ["S"] = new Fdf.Name("C"), ["I"] = Math.Clamp(Num(A("intensity")) ?? 1, 0, 2) };
        Put("RD", Nums(A("fringe")) is { Count: 4 } fringe ? fringe.Cast<object?>().ToList() : null);
        Put("Rotate", Num(A("rotation")));
        Put("Name", A("icon") is { Length: > 0 } icon ? new Fdf.Name(icon) : null);
        Put("State", A("state"));
        Put("StateModel", A("statemodel"));
        if (A("justification") is { } j) d["Q"] = j.ToLowerInvariant() switch { "centered" or "center" => 1.0, "right" => 2.0, _ => 0.0 };

        switch (subtype)
        {
            case "Line":
                if (Nums(A("start")) is { Count: 2 } s && Nums(A("end")) is { Count: 2 } e) d["L"] = new List<object?> { s[0], s[1], e[0], e[1] };
                Ends();
                Put("LL", Num(A("leaderLength")));
                Put("LLE", Num(A("leaderExtended")));
                Put("LLO", Num(A("leader-offset")));
                if (A("caption") is { } cap) d["Cap"] = cap.Equals("yes", StringComparison.OrdinalIgnoreCase);
                break;
            case "PolyLine":
                Ends();
                break;
            case "FreeText":
                Put("CL", Nums(A("callout")) is { Count: 4 or 6 } cl ? cl.Cast<object?>().ToList() : null);
                Put("LE", A("head") is { Length: > 0 } head ? new Fdf.Name(head) : null);
                break;
            case "Caret":
                d["Sy"] = new Fdf.Name(A("symbol")?.Equals("paragraph", StringComparison.OrdinalIgnoreCase) == true ? "P" : "None");
                break;
            case "Redact":
                Put("OverlayText", A("overlay-text"));
                break;
        }
        if (subtype is "Highlight" or "Underline" or "Squiggly" or "StrikeOut" or "Redact" && Nums(A("coords")) is { Count: > 0 } coords && coords.Count % 8 == 0)
            d["QuadPoints"] = coords.Cast<object?>().ToList();

        var rich = Child("contents-richtext")?.Elements().FirstOrDefault(c => c.Name.LocalName == "body");
        if (Child("contents") is { } contents) d["Contents"] = contents.Value;
        else if (rich is not null) d["Contents"] = PlainText(rich);
        if (rich is not null) d["RC"] = rich.ToString(SaveOptions.DisableFormatting);
        Put("DA", Child("defaultappearance")?.Value);
        Put("DS", Child("defaultstyle")?.Value);
        switch (subtype)
        {
            case "Polygon" or "PolyLine" when Nums(Child("vertices")?.Value) is { Count: >= 4 } v && v.Count % 2 == 0:
                d["Vertices"] = v.Cast<object?>().ToList();
                break;
            case "Ink" when Child("inklist") is { } ink:
                var strokes = ink.Elements().Where(g => g.Name.LocalName == "gesture").Select(g => Nums(g.Value)).OfType<List<double>>()
                    .Where(p => p.Count >= 2 && p.Count % 2 == 0).Select(p => (object?)p.Cast<object?>().ToList()).ToList();
                if (strokes.Count > 0) d["InkList"] = strokes;
                break;
            case "Stamp" when Child("appearance")?.Value is { Length: > 0 } b64 && ParseAppearance(b64) is { } ap:
                d["AP"] = ap;
                break;
        }
        return d;

        void Ends()
        {
            var head = A("head");
            var tail = A("tail");
            if (head is not null || tail is not null) d["LE"] = new List<object?> { new Fdf.Name(head ?? "None"), new Fdf.Name(tail ?? "None") };
        }
    }

    private static List<object?> Box(List<double> r) =>
        [Math.Min(r[0], r[2]), Math.Min(r[1], r[3]), Math.Max(r[0], r[2]), Math.Max(r[1], r[3])];

    /// <summary>Numbers separated by commas, semicolons or spaces; null when any isn't a finite number.</summary>
    private static List<double>? Nums(string? text)
    {
        if (string.IsNullOrWhiteSpace(text)) return null;
        var list = new List<double>();
        foreach (var part in text.Split([',', ';', ' ', '\t', '\r', '\n'], StringSplitOptions.RemoveEmptyEntries))
        {
            if (!double.TryParse(part, NumberStyles.Float, CultureInfo.InvariantCulture, out var v) || !double.IsFinite(v)) return null;
            list.Add(v);
        }
        return list;
    }

    private static double? Num(string? text) => Nums(text) is { Count: 1 } one ? one[0] : null;

    /// <summary>"#RRGGBB" as a /C array (null when it isn't one).</summary>
    private static List<object?>? Color(string? hex)
    {
        if (hex is not { Length: 7 } || hex[0] != '#' || !int.TryParse(hex.AsSpan(1), NumberStyles.HexNumber, CultureInfo.InvariantCulture, out var v)) return null;
        return [Math.Round(((v >> 16) & 255) / 255.0, 4), Math.Round(((v >> 8) & 255) / 255.0, 4), Math.Round((v & 255) / 255.0, 4)];
    }

    /// <summary>The text of an XHTML body: paragraphs and line breaks become new lines.</summary>
    private static string PlainText(XElement body)
    {
        var sb = new StringBuilder();
        void Walk(XElement e)
        {
            foreach (var n in e.Nodes())
            {
                if (n is XText t) sb.Append(t.Value);
                else if (n is XElement c)
                {
                    if (c.Name.LocalName == "br") sb.Append('\n');
                    else Walk(c);
                    if (c.Name.LocalName is "p" or "div") sb.Append('\n');
                }
            }
        }
        Walk(body);
        return sb.ToString().TrimEnd('\n');
    }

    /// <summary>An XFDF stamp's <c>appearance</c>: base64 of an XML tree of DICT, STREAM, ARRAY and values (see
    /// <see cref="AppearanceXml"/>). Null when it can't be read.</summary>
    private static Dictionary<string, object?>? ParseAppearance(string base64)
    {
        byte[] bytes;
        try
        {
            bytes = Convert.FromBase64String(base64.Trim());
        }
        catch (FormatException)
        {
            return null;
        }
        if (Encoding.UTF8.GetString(bytes, 0, Math.Min(bytes.Length, 4096)).Contains("<!DOCTYPE", StringComparison.OrdinalIgnoreCase)) return null;
        XElement root;
        try
        {
            root = XElement.Load(XmlReader.Create(new MemoryStream(bytes), SafeXml(bytes.Length * 2L + 1024)));
        }
        catch (XmlException)
        {
            return null;
        }
        var nodes = 0;
        object? Value(XElement e, int depth)
        {
            if (++nodes > 200_000 || depth > 32) return null;
            var val = (string?)e.Attribute("VAL");
            switch (e.Name.LocalName.ToUpperInvariant())
            {
                case "DICT":
                    return Entries(e, depth);
                case "STREAM":
                {
                    var dict = Entries(e, depth);
                    var data = e.Elements().FirstOrDefault(c => c.Name.LocalName.Equals("DATA", StringComparison.OrdinalIgnoreCase));
                    var raw = Data(data);
                    if (raw is null) return null;
                    // Unfiltered data ("RAW"): its /Filter no longer applies, unless the bytes still look Flate-encoded.
                    if (((string?)data!.Attribute("MODE"))?.Equals("RAW", StringComparison.OrdinalIgnoreCase) == true
                        && !(dict.GetValueOrDefault("Filter") is Fdf.Name { Value: "FlateDecode" } && raw.Length > 1 && raw[0] == 0x78))
                    {
                        dict.Remove("Filter");
                        dict.Remove("DecodeParms");
                    }
                    return new Fdf.Stream(dict, raw);
                }
                case "ARRAY":
                    return e.Elements().Select(c => Value(c, depth + 1)).ToList();
                case "NAME":
                    return val is null ? null : new Fdf.Name(val);
                case "INT" or "FIXED":
                    return double.TryParse(val, NumberStyles.Float, CultureInfo.InvariantCulture, out var n) && double.IsFinite(n) ? n : null;
                case "BOOL":
                    return val?.Equals("true", StringComparison.OrdinalIgnoreCase) == true;
                case "STRING":
                    return val ?? e.Value;
                default:
                    return null;
            }
        }
        Dictionary<string, object?> Entries(XElement e, int depth)
        {
            var dict = new Dictionary<string, object?>(StringComparer.Ordinal);
            foreach (var c in e.Elements())
                if ((string?)c.Attribute("KEY") is { Length: > 0 } key && key != "Length" && Value(c, depth + 1) is { } v) dict[key] = v;
            return dict;
        }
        static byte[]? Data(XElement? data)
        {
            if (data is null) return null;
            var text = data.Value;
            try
            {
                return ((string?)data.Attribute("ENCODING"))?.ToUpperInvariant() switch
                {
                    "HEX" => Convert.FromHexString(string.Concat(text.Where(Uri.IsHexDigit))),
                    "BASE64" => Convert.FromBase64String(text.Trim()),
                    _ => Encoding.Latin1.GetBytes(text),
                };
            }
            catch (FormatException)
            {
                return null;
            }
        }

        if (!root.Name.LocalName.Equals("DICT", StringComparison.OrdinalIgnoreCase)) return null;
        var ap = Entries(root, 0);
        return ap.GetValueOrDefault("N") is not null ? ap : null;
    }
}
