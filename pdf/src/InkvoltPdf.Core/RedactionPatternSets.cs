using System.Text;
using System.Text.Encodings.Web;
using System.Text.Json;

namespace InkvoltPdf.Core;

/// <summary>A named set of what to look for, saved on this PC.</summary>
public sealed record RedactionPatternSet(string Name, RedactionPatternOptions Options);

/// <summary>A saved pattern set can't be read; the message says why in plain words.</summary>
public sealed class RedactionPatternSetException(string message, Exception? inner = null) : Exception(message, inner);

/// <summary>
/// Saved pattern sets: one small JSON file per set in a folder on this PC. Nothing but the app reads them, but anything can
/// write them, so reading is strict and all or nothing: a set with a kind this version doesn't know, a wrong type, too many
/// or too long phrases or a pattern that doesn't compile is refused with a reason, never half used (half a set would look
/// like a search that found nothing). The words in a set are the person's own and stay as plain text on this PC.
/// </summary>
public static class RedactionPatternSets
{
    public const int Version = 1;
    public const string Format = "Inkvolt PDF redaction patterns";
    public const string Extension = ".json";

    /// <summary>Largest set file read, and the longest name kept.</summary>
    public const int MaxBytes = 2 << 20, MaxNameLength = 80;

    /// <summary>Most sets listed: a folder filled by something else mustn't stall the dialog.</summary>
    private const int MaxListed = 500;

    private static readonly JsonWriterOptions WriterOptions = new()
    {
        Indented = true,
        NewLine = "\n",
        Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping,
    };

    private static readonly JsonDocumentOptions ReaderOptions = new() { MaxDepth = 8 };

    private static readonly string[] Words = ["socialSecurity", "phone", "email", "paymentCard", "date", "iban", "ipAddress", "zipCode"];

    private static readonly RedactionPattern[] Kinds =
    [
        RedactionPattern.SocialSecurity, RedactionPattern.Phone, RedactionPattern.Email, RedactionPattern.PaymentCard,
        RedactionPattern.Date, RedactionPattern.Iban, RedactionPattern.IpAddress, RedactionPattern.ZipCode,
    ];

    /// <summary>A set's name as shown: no control or invisible characters, not over-long.</summary>
    public static string CleanName(string name) => RedactionPatterns.Displayable(name, MaxNameLength).Trim();

    /// <summary>
    /// A file name for a set: letters, digits, spaces, dashes and underscores from its name, never a device name or a
    /// path; a hash of the name is added when anything had to go, so two names don't land on one file.
    /// </summary>
    public static string FileName(string name)
    {
        var clean = CleanName(name);
        var sb = new StringBuilder();
        foreach (var c in clean) sb.Append(char.IsLetterOrDigit(c) || c is ' ' or '-' or '_' ? c : '_');
        var safe = sb.ToString().Trim(' ', '.');
        if (safe.Length > 60) safe = safe[..60].TrimEnd(' ', '.');
        var device = safe.ToUpperInvariant() is "CON" or "PRN" or "AUX" or "NUL" || (safe.Length == 4 && (safe.StartsWith("COM", StringComparison.OrdinalIgnoreCase) || safe.StartsWith("LPT", StringComparison.OrdinalIgnoreCase)));
        if (safe != clean || safe.Length == 0 || device)
            safe = $"{(safe.Length == 0 || device ? "set" : safe)} {Convert.ToHexStringLower(System.Security.Cryptography.SHA256.HashData(Encoding.UTF8.GetBytes(name)))[..8]}";
        return safe + Extension;
    }

    /// <summary>The sets in <paramref name="folder"/> by name, and the files that couldn't be read with the reason for each.</summary>
    public static (List<RedactionPatternSet> Sets, List<string> Problems) List(string folder)
    {
        var sets = new List<RedactionPatternSet>();
        var problems = new List<string>();
        string[] files;
        try
        {
            files = Directory.Exists(folder) ? Directory.GetFiles(folder, "*" + Extension) : [];
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            problems.Add($"The saved sets can't be read: {ex.Message}");
            return (sets, problems);
        }
        foreach (var path in files.Order(StringComparer.OrdinalIgnoreCase).Take(MaxListed))
        {
            try
            {
                sets.Add(Load(path));
            }
            catch (RedactionPatternSetException ex)
            {
                problems.Add(ex.Message);
            }
        }
        sets.Sort((a, b) => string.Compare(a.Name, b.Name, StringComparison.CurrentCultureIgnoreCase));
        return (sets, problems);
    }

    /// <exception cref="RedactionPatternSetException">The file can't be read, or isn't a set this version can use whole.</exception>
    public static RedactionPatternSet Load(string path)
    {
        var name = Path.GetFileName(path);
        string json;
        try
        {
            var info = new FileInfo(path);
            if (!info.Exists) throw new RedactionPatternSetException($"The saved set {name} isn't there any more.");
            if (info.Length > MaxBytes) throw new RedactionPatternSetException($"{name} is too large to be a saved set.");
            json = File.ReadAllText(path, Encoding.UTF8);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or ArgumentException or NotSupportedException)
        {
            throw new RedactionPatternSetException($"The saved set {name} can't be read: {ex.Message}", ex);
        }
        return Read(json, name);
    }

    /// <summary>Saves a set whole (through a temporary file), in place of one with the same name.</summary>
    /// <returns>The file written.</returns>
    /// <exception cref="RedactionPatternSetException">The set isn't valid, or its name is empty.</exception>
    public static string Save(RedactionPatternSet set, string folder)
    {
        var name = CleanName(set.Name);
        if (name.Length == 0) throw new RedactionPatternSetException("Name the set.");
        if (RedactionPatterns.Validate(set.Options) is { } problem) throw new RedactionPatternSetException(problem);
        if (set.Options.IsEmpty) throw new RedactionPatternSetException("Choose something to look for first.");
        Directory.CreateDirectory(folder);
        var path = Path.Combine(folder, FileName(name));
        var temp = path + $".{Guid.NewGuid():N}.tmp";
        try
        {
            File.WriteAllText(temp, Write(set with { Name = name }), new UTF8Encoding(false));
            File.Move(temp, path, overwrite: true);
        }
        finally
        {
            BatchRunner.TryDelete(temp);
        }
        return path;
    }

    public static void Delete(string name, string folder) => BatchRunner.TryDelete(Path.Combine(folder, FileName(name)));

    public static string Write(RedactionPatternSet set)
    {
        using var stream = new MemoryStream();
        using (var w = new Utf8JsonWriter(stream, WriterOptions))
        {
            var o = set.Options;
            w.WriteStartObject();
            w.WriteString("format", Format);
            w.WriteNumber("version", Version);
            w.WriteString("name", set.Name);
            w.WriteStartArray("kinds");
            for (var i = 0; i < Kinds.Length; i++)
                if (o.Patterns.Contains(Kinds[i])) w.WriteStringValue(Words[i]);
            w.WriteEndArray();
            w.WriteStartArray("phrases");
            foreach (var phrase in o.Phrases) w.WriteStringValue(phrase);
            w.WriteEndArray();
            w.WriteBoolean("wholeWord", o.WholeWord);
            w.WriteBoolean("matchCase", o.MatchCase);
            w.WriteString("expression", string.IsNullOrEmpty(o.Expression) ? null : o.Expression);
            w.WriteEndObject();
        }
        return Encoding.UTF8.GetString(stream.ToArray()) + "\n";
    }

    /// <exception cref="RedactionPatternSetException">It isn't a set this version can use whole.</exception>
    public static RedactionPatternSet Read(string json, string fileName)
    {
        RedactionPatternSetException Bad(string why) => new($"The saved set {fileName} can't be used: {why}");
        JsonDocument doc;
        try
        {
            doc = JsonDocument.Parse(json, ReaderOptions);
        }
        catch (JsonException ex)
        {
            throw new RedactionPatternSetException($"The saved set {fileName} can't be used: it isn't valid JSON.", ex);
        }
        using (doc)
        {
            var root = doc.RootElement;
            if (root.ValueKind != JsonValueKind.Object) throw Bad("it isn't a set.");
            string Text(string key, bool required)
            {
                if (!root.TryGetProperty(key, out var e) || e.ValueKind == JsonValueKind.Null)
                    return required ? throw Bad($"\"{key}\" is missing.") : "";
                return e.ValueKind == JsonValueKind.String ? e.GetString()! : throw Bad($"\"{key}\" should be text.");
            }
            bool Flag(string key, bool otherwise)
            {
                if (!root.TryGetProperty(key, out var e)) return otherwise;
                return e.ValueKind switch { JsonValueKind.True => true, JsonValueKind.False => false, _ => throw Bad($"\"{key}\" should be true or false.") };
            }
            List<string> List(string key)
            {
                if (!root.TryGetProperty(key, out var e)) return [];
                if (e.ValueKind != JsonValueKind.Array) throw Bad($"\"{key}\" should be a list.");
                if (e.GetArrayLength() > RedactionPatterns.MaxPhrases) throw Bad($"\"{key}\" has too many items.");
                return [.. e.EnumerateArray().Select(i => i.ValueKind == JsonValueKind.String ? i.GetString()! : throw Bad($"\"{key}\" should list text."))];
            }

            if (Text("format", true) != Format) throw Bad("it isn't a set of redaction patterns.");
            if (!root.TryGetProperty("version", out var version) || !version.TryGetInt32(out var v) || v < 1) throw Bad("its version is missing.");
            if (v > Version) throw Bad("it comes from a newer version of Inkvolt PDF.");

            var name = CleanName(Text("name", true));
            if (name.Length == 0) throw Bad("it has no name.");
            var kinds = new HashSet<RedactionPattern>();
            foreach (var word in List("kinds"))
            {
                var i = Array.IndexOf(Words, word);
                if (i < 0) throw Bad($"it asks for a kind this version doesn't know ({RedactionPatterns.Displayable(word, 40)}).");
                kinds.Add(Kinds[i]);
            }
            var options = new RedactionPatternOptions
            {
                Patterns = kinds,
                Phrases = List("phrases"),
                WholeWord = Flag("wholeWord", true),
                MatchCase = Flag("matchCase", false),
                Expression = Text("expression", false) is { Length: > 0 } x ? x : null,
                SetName = name,
            };
            if (RedactionPatterns.Validate(options) is { } problem) throw Bad(problem);
            if (options.IsEmpty) throw Bad("it has nothing to look for.");
            return new RedactionPatternSet(name, options);
        }
    }
}
