using System.Globalization;
using System.Text.RegularExpressions;
using System.Xml;
using InkvoltPrint.Core.Ipp;
using InkvoltPrint.Core.Model;

namespace InkvoltPrint.Core.Queues;

/// <summary>
/// Route 2: a queue on a maker's driver asked over Windows' bidirectional printing (<c>IBidiSpl2.SendRecvXMLString</c>), for what
/// Microsoft's bidi schema calls <c>\Printer.Consumables</c> and <c>\Printer.Status.Summary</c>. Get only, never a Set, and nothing
/// that identifies the printer (<c>\Printer.DeviceInfo</c> holds the IEEE 1284 id). The reply comes from a third-party driver, so it's
/// read strictly: no DTD, a size limit, only the schemas asked for with the types the schema gives them; a value that isn't one
/// is left out, a reply that isn't well formed counts for nothing. A problem's words are always the app's, never the driver's.
/// </summary>
public static partial class BidiQueueReading
{
    private const string Namespace = "http://schemas.microsoft.com/windows/2005/03/printing/bidi";

    /// <summary>Asked one at a time: a driver that has one but not the other may fail a request naming both.</summary>
    public static readonly string[] Requests =
    [
        $"""<bidi:Get xmlns:bidi="{Namespace}"><Query schema="\Printer.Consumables"/></bidi:Get>""",
        $"""<bidi:Get xmlns:bidi="{Namespace}"><Query schema="\Printer.Status.Summary"/></bidi:Get>""",
    ];

    /// <summary>Longest reply read, in characters (a real one is a few kilobytes).</summary>
    public const int MaxChars = 256 * 1024;

    /// <summary>Most supplies taken from one reply (a printer has a handful); the rest are ignored.</summary>
    public const int MaxSupplies = 32;

    /// <summary>The level at or under which a supply reads low: the schema gives a level but no low mark, and 8% shouldn't read OK.</summary>
    private const int LowLevel = 10;

    /// <summary>Most values read from one reply.</summary>
    private const int MaxValues = 1024;

    /// <summary>
    /// Whether a queue's driver is worth asking: not a virtual printer, and not on Windows' IPP class driver, whose printer route 1
    /// already asks directly (and which would only hold up the status for as long as a printer that's off takes to time out).
    /// </summary>
    public static bool WorthAsking(SpoolerQueue queue) =>
        !QueueKinds.IsVirtual(queue) && queue.DriverName?.Contains("IPP Class Driver", StringComparison.OrdinalIgnoreCase) != true;

    /// <summary>The reading from the driver's replies, null ones for requests that failed; null when they say nothing usable.</summary>
    public static QueueDeviceReading? From(IEnumerable<string?> replies)
    {
        var values = replies.SelectMany(Values).ToList();
        var supplies = Supplies(values);
        var alerts = Alerts(values);
        return supplies.Count == 0 && alerts.Count == 0 ? null : new QueueDeviceReading(QueueReadingFrom.Driver, null, alerts, supplies);
    }

    private readonly record struct BidiValue(string Schema, string Type, string Text);

    /// <summary>The <c>Get/Query/Schema</c> values in a reply; none at all if any of it is ill formed, too long or not a Get.</summary>
    private static List<BidiValue> Values(string? xml)
    {
        var values = new List<BidiValue>();
        if (string.IsNullOrWhiteSpace(xml) || xml.Length > MaxChars) return values;
        var settings = new XmlReaderSettings
        {
            DtdProcessing = DtdProcessing.Prohibit,
            XmlResolver = null,
            MaxCharactersInDocument = MaxChars,
            IgnoreComments = true,
            IgnoreProcessingInstructions = true,
            IgnoreWhitespace = true,
        };
        try
        {
            using var r = XmlReader.Create(new StringReader(xml), settings);
            if (r.MoveToContent() != XmlNodeType.Element || r.LocalName != "Get") return values;
            while (r.Read())
            {
                if (r.NodeType != XmlNodeType.Element || r.Depth != 2 || r.LocalName != "Schema" || r.IsEmptyElement) continue;
                var schema = r.GetAttribute("name");
                if (!r.Read() || r.NodeType != XmlNodeType.Element || r.Depth != 3 || string.IsNullOrEmpty(schema)) continue;
                if (values.Count >= MaxValues) continue; // the rest of the document is still checked
                var type = r.LocalName;
                values.Add(new BidiValue(schema, type, r.ReadElementContentAsString().Trim()));
            }
            return values;
        }
        catch (Exception ex) when (ex is XmlException or InvalidOperationException)
        {
            System.Diagnostics.Trace.WriteLine($"queue bidi reading: {ex.GetType().Name}");
            return [];
        }
    }

    [GeneratedRegex(@"^\\Printer\.Consumables\.([A-Za-z0-9_-]{1,64})[:.](Installed|Type|Color|Level|Model)$", RegexOptions.CultureInvariant)]
    private static partial Regex ConsumableSchema();

    [GeneratedRegex(@"^[A-Za-z][A-Za-z0-9 -]{0,31}$", RegexOptions.CultureInvariant)]
    private static partial Regex SafeWord();

    [GeneratedRegex(@"^[A-Za-z0-9][A-Za-z0-9 ._-]{0,31}$", RegexOptions.CultureInvariant)]
    private static partial Regex SafeModel();

    private sealed class Found
    {
        public bool? Installed;
        public string? Type, Color, Model;
        public int? Level;
        public bool Any;
    }

    private static List<Consumable> Supplies(List<BidiValue> values)
    {
        var order = new List<string>();
        var found = new Dictionary<string, Found>(StringComparer.Ordinal);
        foreach (var v in values)
        {
            if (ConsumableSchema().Match(v.Schema) is not { Success: true } m) continue;
            var name = m.Groups[1].Value;
            if (!found.TryGetValue(name, out var f))
            {
                if (found.Count >= MaxSupplies) continue;
                found[name] = f = new Found();
                order.Add(name);
            }
            switch (m.Groups[2].Value)
            {
                case "Installed" when v.Type == "BIDI_BOOL" && bool.TryParse(v.Text, out var b): f.Installed = b; break;
                case "Type" when IsText(v.Type): f.Type = v.Text; f.Any = true; break;
                case "Color" when IsText(v.Type) && SafeWord().IsMatch(v.Text): f.Color = v.Text; f.Any = true; break;
                case "Level":
                    f.Any = true;
                    if (v.Type == "BIDI_INT" && int.TryParse(v.Text, NumberStyles.AllowLeadingSign, CultureInfo.InvariantCulture, out var n) && n is >= 0 and <= 100) f.Level = n;
                    break;
                case "Model" when IsText(v.Type) && SafeModel().IsMatch(v.Text): f.Model = v.Text; break;
            }
        }
        var taken = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        var supplies = new List<Consumable>();
        foreach (var name in order)
        {
            var f = found[name];
            if (f.Installed == false || !f.Any) continue;
            supplies.Add(Supply(name, f, taken));
        }
        return supplies;
    }

    private static bool IsText(string type) => type is "BIDI_STRING" or "BIDI_ENUM" or "BIDI_TEXT";

    private static Consumable Supply(string vendorName, Found f, HashSet<string> taken)
    {
        var kind = KindOf(f.Type);
        var color = ColorOf(f.Color);
        string display, key;
        if (f.Type is null && color is null)
            display = key = vendorName; // nothing but the driver's own name for it
        else
        {
            var word = color?.Word(SupplyNames.Feminine(kind.Keyword)) ?? "";
            display = SupplyNames.Name(word, color is { Known: true }, kind.Keyword);
            key = $"{color?.English} {kind.English}".Trim();
            key = key.Length == 0 ? display : char.ToUpperInvariant(key[0]) + key[1..];
            if (color is null && display.Length > 0) display = char.ToUpperInvariant(display[0]) + display[1..];
        }
        if (!taken.Add(key)) // the schema allows several of one type and color: its id tells them apart
        {
            display = $"{display} ({vendorName})";
            key = $"{key} ({vendorName})";
            taken.Add(key);
        }
        var waste = Consumable.IsWasteKind(kind.Keyword);
        int? level = waste ? null : f.Level;
        var state = waste ? "ok" : level is null ? "unknown" : level == 0 ? "out" : level <= LowLevel ? "low" : "ok";
        return new Consumable(display, kind.Keyword, color?.Code, level, state, f.Model, null, null, null, null) { Key = key };
    }

    private readonly record struct KindWords(string Keyword, string English);

    private static KindWords KindOf(string? type) => type switch
    {
        "Toner" or "TonerCartridge" => new("toner", "toner"),
        "Ink" => new("ink", "ink"),
        "InkCartridge" => new("ink cartridge", "ink cartridge"),
        "InkTank" => new("ink tank", "ink tank"),
        "Printhead" => new("printhead", "printhead"),
        "Drum" or "OPC" => new("drum", "drum"),
        "Developer" => new("developer", "developer"),
        "FuserOil" => new("fuser oil", "fuser oil"),
        "Wax" => new("wax", "wax"),
        "WasteToner" => new("waste-toner", "waste toner"),
        "WasteInk" => new("waste-ink", "waste ink"),
        "WasteWax" => new("waste-wax", "waste wax"),
        _ => new("supply", "supply"),
    };

    private sealed record ColorWords(string? Code, string English, bool Known, Func<bool, string> Word);

    /// <summary>The schema's predefined colors (its other ones and a vendor's own: as sent, already checked to be plain words).</summary>
    private static ColorWords? ColorOf(string? color) => color switch
    {
        null => null,
        "Black" => new("K", "Black", true, f => f ? CoreStrings.Supply_Black_Feminine : CoreStrings.Supply_Black),
        "Cyan" => new("C", "Cyan", true, _ => CoreStrings.Supply_Cyan),
        "Magenta" => new("M", "Magenta", true, _ => CoreStrings.Supply_Magenta),
        "Yellow" => new("Y", "Yellow", true, f => f ? CoreStrings.Supply_Yellow_Feminine : CoreStrings.Supply_Yellow),
        "Color" => new("CMY", "Tri-color", true, _ => CoreStrings.Supply_TriColor),
        "PhotoBlack" => new("pK", "Photo black", true, _ => CoreStrings.Supply_PhotoBlack),
        "Gray" => new("G", "Gray", true, _ => CoreStrings.Supply_Gray),
        _ => new(null, color, false, _ => color),
    };

    /// <summary>The schema's state reasons as the IPP keywords (or Windows' own id) the app has words for; a vendor's own are ignored.</summary>
    private static string? ReasonId(string reason) => reason switch
    {
        "AttentionRequired" => "user-intervention",
        "DoorOpen" => "door-open",
        "MarkerSupplyEmpty" => "marker-supply-empty",
        "MarkerSupplyLow" => "marker-supply-low",
        "MediaEmpty" => "media-empty",
        "MediaJam" => "media-jam",
        "MediaLow" => "media-low",
        "MediaNeeded" => "media-needed",
        "OutputAreaAlmostFull" => "output-area-almost-full",
        "OutputAreaFull" => "output-area-full",
        "Paused" => "paused",
        _ => null,
    };

    private static List<PrinterAlert> Alerts(List<BidiValue> values)
    {
        var alerts = new List<PrinterAlert>();
        foreach (var v in values)
        {
            if (v.Schema != @"\Printer.Status.Summary:StateReason" || !IsText(v.Type)) continue;
            foreach (var reason in v.Text.Split(' ', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries))
            {
                if (ReasonId(reason) is not { } id || alerts.Any(a => a.Id == id)) continue;
                alerts.Add(id == "user-intervention"
                    ? new PrinterAlert(id, Severity.Error, CoreStrings.Queue_UserIntervention)
                    : new PrinterAlert(id, id == "paused" ? Severity.Warning : IppStatusText.DefaultSeverity(id), IppStatusText.Describe(id)));
            }
        }
        return alerts;
    }
}
