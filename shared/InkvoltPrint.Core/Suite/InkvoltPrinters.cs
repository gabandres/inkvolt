using System.Text.Json;

namespace InkvoltPrint.Core.Suite;

/// <summary>A printer Inkvolt Print remembers (its <c>state.json</c>), as other Inkvolt apps see it.</summary>
public sealed record InkvoltPrinter(string Uuid, string Name, string? Model, string Host, Uri? EsclRoot);

/// <summary>
/// Read-only view of Inkvolt Print's remembered printers and queue associations, for the other Inkvolt apps (Inkvolt PDF).
/// Inkvolt Print owns the file; this never writes it. A missing or unreadable file reads as empty.
/// </summary>
public sealed class InkvoltPrinters
{
    public static readonly string DefaultPath = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "InkvoltPrint", "state.json");

    public static readonly InkvoltPrinters Empty = new([], new Dictionary<string, string>());

    public InkvoltPrinters(IReadOnlyList<InkvoltPrinter> printers, IReadOnlyDictionary<string, string> queueNames)
    {
        Printers = printers;
        QueueNames = queueNames;
    }

    public IReadOnlyList<InkvoltPrinter> Printers { get; }

    /// <summary>Printer UUID → Windows queue name Inkvolt Print created for it (printers added by address).</summary>
    public IReadOnlyDictionary<string, string> QueueNames { get; }

    /// <summary>
    /// Reads <paramref name="path"/>, or by default Inkvolt Print's current state file wherever it is installed: unpackaged
    /// (<see cref="DefaultPath"/>) or packaged, whose writes Windows keeps in the package's folder
    /// (<see cref="InkvoltPaths.CurrentStateFile"/>).
    /// </summary>
    public static InkvoltPrinters Load(string? path = null)
    {
        try
        {
            var file = path ?? InkvoltPaths.CurrentStateFile(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData));
            return file is not null && File.Exists(file) ? Parse(File.ReadAllText(file)) : Empty;
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            return Empty;
        }
    }

    /// <summary>Parses Inkvolt Print's state JSON; skips entries without a UUID or host. Never throws on bad input.</summary>
    public static InkvoltPrinters Parse(string json)
    {
        try
        {
            using var doc = JsonDocument.Parse(json, new JsonDocumentOptions { AllowTrailingCommas = true, CommentHandling = JsonCommentHandling.Skip });
            if (doc.RootElement.ValueKind != JsonValueKind.Object) return Empty;
            var printers = new List<InkvoltPrinter>();
            if (doc.RootElement.TryGetProperty("Printers", out var list) && list.ValueKind == JsonValueKind.Array)
                foreach (var p in list.EnumerateArray())
                {
                    if (p.ValueKind != JsonValueKind.Object) continue;
                    var uuid = Str(p, "Uuid");
                    var host = Str(p, "Host");
                    if (string.IsNullOrWhiteSpace(uuid) || string.IsNullOrWhiteSpace(host)) continue;
                    var escl = Uri.TryCreate(Str(p, "EsclRoot"), UriKind.Absolute, out var u) && u.Scheme is "http" or "https" ? u : null;
                    printers.Add(new InkvoltPrinter(uuid, Str(p, "Name") is { Length: > 0 } n ? n : host, Str(p, "Model"), host, escl));
                }
            var queues = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
            if (doc.RootElement.TryGetProperty("QueueNames", out var map) && map.ValueKind == JsonValueKind.Object)
                foreach (var kv in map.EnumerateObject())
                    if (kv.Value.ValueKind == JsonValueKind.String && kv.Value.GetString() is { Length: > 0 } q)
                        queues[kv.Name] = q;
            return new InkvoltPrinters(printers, queues);
        }
        catch (JsonException)
        {
            return Empty;
        }
    }

    private static string? Str(JsonElement e, string name) =>
        e.TryGetProperty(name, out var v) && v.ValueKind == JsonValueKind.String ? v.GetString()?.Trim() : null;
}
