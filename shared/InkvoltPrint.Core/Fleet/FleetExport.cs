using System.Globalization;
using System.Text;
using System.Text.Json;
using InkvoltPrint.Core.Suite;

namespace InkvoltPrint.Core.Fleet;

/// <summary>
/// The Fleet page's Pro export and <c>status --all --json</c>: a CSV (a row per supply) and JSON (<c>print/schemas/fleet-status.schema.json</c>)
/// of the list as it stands. Both can leave the PC, so every text goes through <see cref="Diagnostics.Scrub"/> first: a name or a
/// status string a printer filled with its serial number, UUID, address or someone's e-mail doesn't carry them out. A firmware
/// version stays. The CSV's cells can't run as formulas (<see cref="CsvCell"/>); the JSON is plain ASCII, so no console code page
/// spoils it, whatever the names are written in.
/// </summary>
public static class FleetExport
{
    private const string Columns = "Printer,Model,Kind,State,Status,Problems,Supply,Color,Level %,Supply state,Pages printed,Firmware,Last reading";

    /// <summary>Whether the Pro check lets the list be exported (<see cref="ProFeature.FleetExport"/>).</summary>
    public static bool Allowed => Pro.Allows(ProFeature.FleetExport);

    public static string Csv(IEnumerable<FleetPrinter> printers, DateTimeOffset now, Diagnostics.Identity who)
    {
        var csv = new StringBuilder(Columns).Append("\r\n");
        foreach (var printer in FleetOrder.Sort(printers).Select(p => Scrubbed(p, who)))
        {
            var problems = string.Join("; ", printer.Problems);
            foreach (var s in printer.Supplies.DefaultIfEmpty()) // a printer with no supplies still has its row
                csv.AppendJoin(',', CsvCell.Of(printer.Name), CsvCell.Of(printer.Model ?? ""), KindWord(printer.Kind), TroubleWord(printer.Trouble), CsvCell.Of(printer.Status),
                        CsvCell.Of(problems), CsvCell.Of(s?.Name ?? ""), CsvCell.Of(s?.Color ?? ""), Number(s?.Level), CsvCell.Of(s?.State ?? ""),
                        Number(printer.Pages), CsvCell.Of(printer.Firmware ?? ""), LastReading(printer) ?? "")
                    .Append("\r\n");
        }
        return csv.ToString();
    }

    public static string Json(IEnumerable<FleetPrinter> printers, IEnumerable<string> notes, DateTimeOffset now, Diagnostics.Identity who)
    {
        using var stream = new MemoryStream();
        // The default encoder: everything past ASCII as \uXXXX, and a half surrogate can't get through.
        using (var json = new Utf8JsonWriter(stream, new JsonWriterOptions { Indented = true }))
        {
            json.WriteStartObject();
            json.WriteNumber("version", 1);
            json.WriteString("generated", Time(now));
            json.WriteStartArray("notes");
            foreach (var note in notes) json.WriteStringValue(FleetText.Clean(Diagnostics.Scrub(note, who), FleetPrinter.MaxText) ?? "");
            json.WriteEndArray();
            json.WriteStartArray("printers");
            foreach (var p in FleetOrder.Sort(printers).Select(p => Scrubbed(p, who)))
            {
                json.WriteStartObject();
                json.WriteString("name", p.Name);
                json.WriteString("model", p.Model);
                json.WriteString("kind", KindWord(p.Kind));
                json.WriteString("connection", p.Connection);
                json.WriteString("trouble", TroubleWord(p.Trouble));
                json.WriteString("status", p.Status);
                json.WriteStartArray("problems");
                foreach (var problem in p.Problems) json.WriteStringValue(problem);
                json.WriteEndArray();
                json.WriteStartArray("supplies");
                foreach (var s in p.Supplies)
                {
                    json.WriteStartObject();
                    json.WriteString("name", s.Name);
                    json.WriteString("color", s.Color);
                    if (s.Level is { } level) json.WriteNumber("level", level);
                    else json.WriteNull("level");
                    json.WriteString("state", s.State);
                    json.WriteEndObject();
                }
                json.WriteEndArray();
                if (p.Pages is { } pages) json.WriteNumber("pages", pages);
                else json.WriteNull("pages");
                json.WriteString("firmware", p.Firmware);
                json.WriteString("lastReading", LastReading(p));
                json.WriteBoolean("lastKnown", p.LastKnown);
                json.WriteEndObject();
            }
            json.WriteEndArray();
            json.WriteEndObject();
        }
        return Encoding.UTF8.GetString(stream.ToArray());
    }

    public static string KindWord(FleetKind kind) => kind switch
    {
        FleetKind.Network => "network",
        FleetKind.Queue => "queue",
        _ => "scanner",
    };

    public static string TroubleWord(FleetTrouble trouble) => trouble switch
    {
        FleetTrouble.Error => "error",
        FleetTrouble.Warning => "warning",
        FleetTrouble.Offline => "offline",
        FleetTrouble.Unknown => "unknown",
        _ => "ok",
    };

    private static string Number(int? n) => n?.ToString(CultureInfo.InvariantCulture) ?? "";

    private static string Time(DateTimeOffset t) => new DateTimeOffset(t.Ticks - t.Ticks % TimeSpan.TicksPerSecond, t.Offset).ToString("yyyy-MM-ddTHH:mm:sszzz", CultureInfo.InvariantCulture);

    private static string? LastReading(FleetPrinter p) =>
        p.LastReading is { } time ? Time(time) : p.LastReadingDay?.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture);

    /// <summary>The entry as it may leave the PC.</summary>
    internal static FleetPrinter Scrubbed(FleetPrinter p, Diagnostics.Identity who) => p with
    {
        Name = Text(p.Name, who) ?? "Printer with no name",
        Model = Text(p.Model, who),
        Connection = Text(p.Connection, who),
        Status = Text(p.Status, who) ?? "Status not available",
        Problems = p.Problems.Select(t => Text(t, who)).OfType<string>().ToList(),
        Supplies = p.Supplies.Select(s => s with
        {
            Name = Text(s.Name, who) ?? "Supply",
            Color = s.Color is null ? null : FleetText.Clean(Diagnostics.Scrub(s.Color, who), 24),
            State = FleetText.Clean(Diagnostics.Scrub(s.State, who), 24) ?? "unknown",
        }).ToList(),
        Firmware = FirmwareText(p.Firmware, who),
    };

    private static string? Text(string? text, Diagnostics.Identity who) =>
        text is null ? null : FleetText.Clean(Diagnostics.Scrub(text, who), FleetPrinter.MaxText);

    /// <summary>A firmware version looks like a serial number or an address to the scrubber, which keeps it after the words "Firmware version".</summary>
    private static string? FirmwareText(string? firmware, Diagnostics.Identity who)
    {
        const string label = "Firmware version ";
        if (firmware is null) return null;
        var scrubbed = Diagnostics.Scrub(label + firmware, who);
        return FleetText.Clean(scrubbed.StartsWith(label, StringComparison.Ordinal) ? scrubbed[label.Length..] : scrubbed, FleetPrinter.MaxText);
    }
}
