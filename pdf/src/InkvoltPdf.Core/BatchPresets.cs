using System.Globalization;
using System.Text;
using System.Text.Encodings.Web;
using System.Text.Json;

namespace InkvoltPdf.Core;

/// <summary>A saved batch: its actions, in order, and how the results are saved.</summary>
public sealed record BatchPreset
{
    public required string Name { get; init; }
    public required IReadOnlyList<BatchStep> Steps { get; init; }

    /// <summary>Where the results go; null: chosen when it runs (the Batch window's folder, <c>--out</c>, a watched folder's "results").</summary>
    public string? OutputFolder { get; init; }

    public string NameTemplate { get; init; } = BatchNames.DefaultTemplate;
    public bool NeverOverwrite { get; init; } = true;
    public bool KeepSubfolders { get; init; } = true;
    public SignedFilePolicy SignedFiles { get; init; }
    public PasswordPolicy Passwords { get; init; }
    public PageSizeOption ImagePageSize { get; init; }

    /// <summary>The preset of a plan (its output folder kept or not).</summary>
    public static BatchPreset From(string name, BatchPlan plan, bool keepFolder) => new()
    {
        Name = name,
        Steps = plan.Steps,
        OutputFolder = keepFolder && !string.IsNullOrWhiteSpace(plan.OutputFolder) && Path.IsPathFullyQualified(plan.OutputFolder) ? plan.OutputFolder : null,
        NameTemplate = plan.NameTemplate,
        NeverOverwrite = plan.NeverOverwrite,
        KeepSubfolders = plan.KeepSubfolders,
        SignedFiles = plan.SignedFiles,
        Passwords = plan.Passwords,
        ImagePageSize = plan.ImagePageSize,
    };

    /// <summary>A plan that runs the preset now, its results in <paramref name="outputFolder"/>.</summary>
    public BatchPlan ToPlan(string outputFolder) => new()
    {
        Steps = Steps,
        OutputFolder = outputFolder,
        NameTemplate = NameTemplate,
        NeverOverwrite = NeverOverwrite,
        KeepSubfolders = KeepSubfolders,
        SignedFiles = SignedFiles,
        Passwords = Passwords,
        ImagePageSize = ImagePageSize,
        Date = DateTime.Now,
    };
}

/// <summary>A preset can't be read; the message says why in words (and where: the action, the setting).</summary>
public sealed class BatchPresetException(string message, Exception? inner = null) : Exception(message, inner);

/// <summary>
/// Batch presets as plain JSON files, readable and diffable: a format marker, a version, the name, the output settings,
/// then the actions in order, each with every setting written out (fields always in the same order, enum values as
/// camelCase words, colors as #RRGGBB (8 bits a channel, as the color pickers give them), a watermark picture as base64 PNG). Passwords are never written: a Protect action
/// keeps only which passwords it sets, and they are given when it runs. Reading is strict, so a mistake made by hand is
/// named rather than silently ignored (an unknown action or setting, a wrong type, a value out of range), but settings
/// left out take their defaults. A preset from a newer version is refused with a clear message rather than half-read.
/// Version history: 1 (Inkvolt PDF 1.1, roadmap 1.2).
/// </summary>
public static class BatchPresets
{
    public const int Version = 1;
    public const string Format = "Inkvolt PDF batch preset";
    public const string Extension = ".json";

    /// <summary>Largest preset file read (a watermark picture makes the biggest ones).</summary>
    public const int MaxBytes = 32 << 20;

    private static readonly JsonWriterOptions WriterOptions = new()
    {
        Indented = true,
        NewLine = "\n",
        // "<<name>>" and accented names stay as written, not \u003C escapes.
        Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping,
    };

    private static readonly JsonDocumentOptions ReaderOptions = new() { AllowTrailingCommas = true, CommentHandling = JsonCommentHandling.Skip };

    // ───────────────────────────── files ─────────────────────────────

    /// <summary>Reads a preset file; its name (without extension) names a preset that has none.</summary>
    /// <exception cref="BatchPresetException">The file can't be read or isn't a preset this version knows.</exception>
    public static BatchPreset Load(string path)
    {
        string json;
        try
        {
            var info = new FileInfo(path);
            if (!info.Exists) throw new BatchPresetException($"There is no preset file at {path}.");
            if (info.Length > MaxBytes) throw new BatchPresetException($"{info.Name} is too large to be a batch preset.");
            json = File.ReadAllText(path, Encoding.UTF8);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or ArgumentException or NotSupportedException)
        {
            throw new BatchPresetException($"The preset {Path.GetFileName(path)} can't be read: {ex.Message}", ex);
        }
        return Read(json, Path.GetFileNameWithoutExtension(path));
    }

    /// <summary>Writes a preset file whole (through a temporary file, so a reader never sees half of it).</summary>
    public static void Save(BatchPreset preset, string path)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(Path.GetFullPath(path))!);
        var temp = path + $".{Guid.NewGuid():N}.tmp";
        try
        {
            File.WriteAllText(temp, Write(preset), new UTF8Encoding(false));
            File.Move(temp, path, overwrite: true);
        }
        finally
        {
            BatchRunner.TryDelete(temp);
        }
    }

    /// <summary>A file name for a preset called <paramref name="name"/> ("Scans to archive.json").</summary>
    public static string FileName(string name) => BatchNames.Expand(name.Replace("<<", "").Replace(">>", ""), "preset", 1, DateTime.Now) + Extension;

    /// <summary>
    /// The steps with the Protect action's wanted passwords given (<paramref name="open"/>, <paramref name="permissions"/>);
    /// a wanted password that is null or empty stays wanted, and then <see cref="BatchPlan.Validate"/> says so.
    /// </summary>
    public static IReadOnlyList<BatchStep> WithPasswords(IReadOnlyList<BatchStep> steps, string? open, string? permissions) =>
    [
        .. steps.Select(s => s is ProtectStep p
            ? p with
            {
                UserPassword = p.UserPassword is "" && !string.IsNullOrEmpty(open) ? open : p.UserPassword,
                OwnerPassword = p.OwnerPassword is "" && !string.IsNullOrEmpty(permissions) ? permissions : p.OwnerPassword,
            }
            : s),
    ];

    // ───────────────────────────── writing ─────────────────────────────

    /// <summary>The preset as JSON (UTF-8 text, two-space indents, "\n" line ends, no passwords).</summary>
    public static string Write(BatchPreset preset)
    {
        using var ms = new MemoryStream();
        using (var w = new Utf8JsonWriter(ms, WriterOptions))
        {
            w.WriteStartObject();
            w.WriteString("format", Format);
            w.WriteNumber("version", Version);
            w.WriteString("name", preset.Name);
            w.WriteStartObject("output");
            w.WriteString("folder", preset.OutputFolder);
            w.WriteString("names", preset.NameTemplate);
            w.WriteBoolean("neverOverwrite", preset.NeverOverwrite);
            w.WriteBoolean("keepSubfolders", preset.KeepSubfolders);
            w.WriteString("signedFiles", Word(preset.SignedFiles));
            w.WriteString("filesWithPasswords", Word(preset.Passwords));
            w.WriteString("imagePages", Word(preset.ImagePageSize));
            w.WriteEndObject();
            w.WriteStartArray("actions");
            foreach (var step in preset.Steps) WriteStep(w, step);
            w.WriteEndArray();
            w.WriteEndObject();
        }
        return Encoding.UTF8.GetString(ms.ToArray()) + "\n";
    }

    private static void WriteStep(Utf8JsonWriter w, BatchStep step)
    {
        w.WriteStartObject();
        w.WriteString("action", ActionName(step));
        switch (step)
        {
            case OptimizeStep { Options: var o }:
                if (o.MaxImageDpi is { } dpi) w.WriteNumber("maxImageDpi", dpi);
                else w.WriteNull("maxImageDpi");
                w.WriteNumber("jpegQuality", o.JpegQuality);
                w.WriteBoolean("compressStreams", o.CompressStreams);
                w.WriteBoolean("deduplicateStreams", o.DeduplicateStreams);
                w.WriteBoolean("removeMetadata", o.RemoveMetadata);
                w.WriteBoolean("removeThumbnails", o.RemoveThumbnails);
                w.WriteBoolean("removePieceInfo", o.RemovePieceInfo);
                break;
            case ProtectStep p:
                // Which passwords are set, never the passwords.
                w.WriteBoolean("openPassword", p.UserPassword is not null);
                w.WriteBoolean("permissionsPassword", p.OwnerPassword is not null);
                w.WriteString("encryption", Word(p.Method));
                w.WriteString("print", Word(p.Permissions.Print));
                w.WriteBoolean("copy", p.Permissions.Copy);
                w.WriteBoolean("modify", p.Permissions.Modify);
                w.WriteBoolean("annotate", p.Permissions.Annotate);
                w.WriteBoolean("fillForms", p.Permissions.FillForms);
                w.WriteBoolean("assemble", p.Permissions.Assemble);
                break;
            case SanitizeStep s:
                w.WriteStartArray("remove");
                foreach (var item in Enum.GetValues<SanitizeItem>().Where(s.Items.Contains)) w.WriteStringValue(Word(item));
                w.WriteEndArray();
                break;
            case RedactPatternsStep { Options: var r }:
                w.WriteStartArray("patterns");
                foreach (var kind in RedactionPatterns.BuiltIn.Where(r.Patterns.Contains)) w.WriteStringValue(Word(kind));
                w.WriteEndArray();
                w.WriteStartArray("phrases");
                foreach (var phrase in r.Phrases) w.WriteStringValue(phrase);
                w.WriteEndArray();
                w.WriteBoolean("wholeWord", r.WholeWord);
                w.WriteBoolean("matchCase", r.MatchCase);
                w.WriteString("expression", string.IsNullOrEmpty(r.Expression) ? null : r.Expression);
                if (r.Pages is null) w.WriteNull("pages");
                else
                {
                    w.WriteStartArray("pages");
                    foreach (var page in r.Pages) w.WriteNumberValue(page + 1);
                    w.WriteEndArray();
                }
                break;
            case WatermarkStep { Options: var m }:
                w.WriteString("text", m.Image is null ? m.Text : null);
                w.WriteString("imagePng", m.Image is { } image ? Convert.ToBase64String(Png(image)) : null);
                w.WriteNumber("fontSize", m.FontSize);
                w.WriteString("color", Hex(m.Color));
                w.WriteNumber("opacity", m.Opacity);
                w.WriteNumber("rotation", m.Rotation);
                w.WriteString("layout", Word(m.Layout));
                w.WriteNumber("imageScale", m.ImageScale);
                w.WriteBoolean("behind", m.Behind);
                break;
            case HeaderFooterStep { Options: var h } hf:
                foreach (var slot in Enum.GetValues<HeaderFooterSlot>()) w.WriteString(Word(slot), h.Text(slot));
                w.WriteNumber("fontSize", h.FontSize);
                w.WriteString("color", Hex(h.Color));
                w.WriteNumber("marginTop", h.MarginTop);
                w.WriteNumber("marginBottom", h.MarginBottom);
                w.WriteNumber("marginLeft", h.MarginLeft);
                w.WriteNumber("marginRight", h.MarginRight);
                if (h.Bates is { } b)
                {
                    w.WriteStartObject("bates");
                    w.WriteString("prefix", b.Prefix);
                    w.WriteNumber("start", b.Start);
                    w.WriteNumber("digits", b.Digits);
                    w.WriteString("suffix", b.Suffix);
                    w.WriteEndObject();
                }
                else w.WriteNull("bates");
                w.WriteBoolean("continueBates", hf.ContinueBates);
                break;
            case RotateStep r:
                w.WriteNumber("degrees", r.Degrees);
                break;
            case SaveAsPdfAStep { Conformance: PdfAConformance.A }:
                w.WriteString("conformance", Word(PdfAConformance.A));
                break;
            case MakeAccessibleStep { Language: { } language }:
                w.WriteString("language", language);
                break;
            case FlattenStep { Options: var f }:
                w.WriteBoolean("annotations", f.Annotations);
                w.WriteBoolean("formFields", f.FormFields);
                w.WriteBoolean("links", f.Links);
                w.WriteBoolean("printableOnly", f.PrintableOnly);
                break;
            case ExportStep x:
                w.WriteString("format", Word(x.Format));
                w.WriteNumber("dpi", x.Dpi);
                break;
        }
        w.WriteEndObject();
    }

    /// <summary>Each action's name in a preset, in the order the Batch window offers them.</summary>
    public static IReadOnlyList<string> ActionNames { get; } =
        ["optimize", "protect", "unprotect", "sanitize", "redactPatterns", "checkRedaction", "checkAccessibility", "reportContents", "watermark", "headerFooter", "rotate", "flatten", "ocr", "makeAccessible", "saveAsPdfA", "export"];

    private static string ActionName(BatchStep step) => step switch
    {
        OptimizeStep => "optimize",
        ProtectStep => "protect",
        UnprotectStep => "unprotect",
        SanitizeStep => "sanitize",
        RedactPatternsStep => "redactPatterns",
        CheckRedactionStep => "checkRedaction",
        CheckAccessibilityStep => "checkAccessibility",
        ReportContentsStep => "reportContents",
        WatermarkStep => "watermark",
        HeaderFooterStep => "headerFooter",
        RotateStep => "rotate",
        FlattenStep => "flatten",
        OcrStep => "ocr",
        SaveAsPdfAStep => "saveAsPdfA",
        MakeAccessibleStep => "makeAccessible",
        ExportStep => "export",
        _ => throw new NotSupportedException(step.Title),
    };

    /// <summary>An enum value as a camelCase word ("highResolution").</summary>
    private static string Word<T>(T value) where T : struct, Enum
    {
        var name = value.ToString();
        return char.ToLowerInvariant(name[0]) + name[1..];
    }

    private static string Hex(AnnotColor c) =>
        string.Create(CultureInfo.InvariantCulture, $"#{Byte(c.R):X2}{Byte(c.G):X2}{Byte(c.B):X2}");

    private static int Byte(double v) => (int)Math.Round(Math.Clamp(v, 0, 1) * 255);

    private static byte[] Png(StampImage image)
    {
        var n = image.Width * image.Height;
        if (image.Alpha is null) return PngEncoder.Encode(image.Width, image.Height, image.Rgb, alpha: false);
        var rgba = new byte[n * 4];
        for (var i = 0; i < n; i++)
        {
            rgba[i * 4] = image.Rgb[i * 3];
            rgba[i * 4 + 1] = image.Rgb[i * 3 + 1];
            rgba[i * 4 + 2] = image.Rgb[i * 3 + 2];
            rgba[i * 4 + 3] = image.Alpha[i];
        }
        return PngEncoder.Encode(image.Width, image.Height, rgba, alpha: true);
    }

    // ───────────────────────────── reading ─────────────────────────────

    /// <summary>Reads a preset (see the class remarks); <paramref name="fallbackName"/> names one that has no name.</summary>
    /// <exception cref="BatchPresetException">It isn't JSON, isn't a preset, comes from a newer version, or a setting is wrong.</exception>
    public static BatchPreset Read(string json, string? fallbackName = null)
    {
        JsonDocument doc;
        try
        {
            doc = JsonDocument.Parse(json, ReaderOptions);
        }
        catch (JsonException ex)
        {
            var where = ex.LineNumber is { } line ? $" (line {line + 1}, character {(ex.BytePositionInLine ?? 0) + 1})" : "";
            throw new BatchPresetException($"This isn't a batch preset: it isn't valid JSON{where}.", ex);
        }
        using (doc)
        {
            var root = doc.RootElement;
            if (root.ValueKind != JsonValueKind.Object) throw new BatchPresetException("This isn't a batch preset: it should be a JSON object { … }.");
            if (root.TryGetProperty("format", out var format) && (format.ValueKind != JsonValueKind.String || format.GetString() != Format))
                throw new BatchPresetException($"This JSON file isn't an Inkvolt PDF batch preset (its \"format\" should be \"{Format}\").");
            if (!root.TryGetProperty("version", out var version))
                throw new BatchPresetException("This JSON file isn't an Inkvolt PDF batch preset: it has no \"version\".");
            if (version.ValueKind != JsonValueKind.Number || !version.TryGetInt32(out var v) || v < 1)
                throw new BatchPresetException($"The preset's \"version\" ({version.GetRawText()}) isn't one Inkvolt PDF knows: it should be {Version}.");
            if (v > Version)
                throw new BatchPresetException($"This preset was saved by a newer Inkvolt PDF (preset version {v}; this one reads version {Version} and earlier). Update Inkvolt PDF to use it.");

            var top = new Fields(root, "The preset");
            top.Text("format", Format);
            top.Int("version", Version, 1, Version);
            var name = top.Text("name", null);
            if (string.IsNullOrWhiteSpace(name)) name = string.IsNullOrWhiteSpace(fallbackName) ? "Preset" : fallbackName;
            var preset = new BatchPreset { Name = name.Trim(), Steps = [] };
            if (top.Object("output") is { } output)
            {
                var folder = output.Text("folder", null);
                if (folder is { Length: > 0 } && !Path.IsPathFullyQualified(folder))
                    throw new BatchPresetException($"The preset's output \"folder\" should be a full path, such as D:\\\\Results (it is \"{folder}\").");
                var names = output.Text("names", BatchNames.DefaultTemplate)!;
                if (BatchNames.Validate(names) is { } nameError) throw new BatchPresetException($"The preset's output \"names\": {nameError}");
                preset = preset with
                {
                    OutputFolder = string.IsNullOrWhiteSpace(folder) ? null : folder,
                    NameTemplate = names,
                    NeverOverwrite = output.Bool("neverOverwrite", true),
                    KeepSubfolders = output.Bool("keepSubfolders", true),
                    SignedFiles = output.Choice("signedFiles", SignedFilePolicy.Skip),
                    Passwords = output.Choice("filesWithPasswords", PasswordPolicy.Ask),
                    ImagePageSize = output.Choice("imagePages", PageSizeOption.FitImage),
                };
                output.Done();
            }
            var actions = top.Array("actions") ?? throw new BatchPresetException("The preset has no \"actions\": add at least one, such as { \"action\": \"optimize\" }.");
            var steps = new List<BatchStep>();
            var n = 0;
            foreach (var item in actions.EnumerateArray())
            {
                n++;
                steps.Add(ReadStep(item, n));
            }
            if (steps.Count == 0) throw new BatchPresetException("The preset's \"actions\" list is empty: add at least one.");
            top.Done();
            return preset with { Steps = steps };
        }
    }

    private static BatchStep ReadStep(JsonElement item, int n)
    {
        if (item.ValueKind != JsonValueKind.Object) throw new BatchPresetException($"Action {n} should be an object such as {{ \"action\": \"ocr\" }}.");
        if (!item.TryGetProperty("action", out var nameElement) || nameElement.ValueKind != JsonValueKind.String)
            throw new BatchPresetException($"Action {n} has no \"action\" saying what it does (one of {string.Join(", ", ActionNames)}).");
        var name = nameElement.GetString()!;
        if (!ActionNames.Contains(name))
            throw new BatchPresetException($"Action {n}: \"{name}\" isn't an action Inkvolt PDF knows (it knows {string.Join(", ", ActionNames)}).");
        var f = new Fields(item, $"Action {n} ({name})");
        f.Text("action", null);
        BatchStep step = name switch
        {
            "optimize" => new OptimizeStep(new OptimizeOptions
            {
                MaxImageDpi = f.NullableNumber("maxImageDpi", new OptimizeOptions().MaxImageDpi, 36, 2400),
                JpegQuality = f.Int("jpegQuality", 75, 1, 100),
                CompressStreams = f.Bool("compressStreams", true),
                DeduplicateStreams = f.Bool("deduplicateStreams", true),
                RemoveMetadata = f.Bool("removeMetadata", false),
                RemoveThumbnails = f.Bool("removeThumbnails", true),
                RemovePieceInfo = f.Bool("removePieceInfo", true),
            }),
            "protect" => ReadProtect(f),
            "unprotect" => new UnprotectStep(),
            "sanitize" => new SanitizeStep(f.Words("remove", Enum.GetValues<SanitizeItem>().Where(i => i != SanitizeItem.Signatures)).ToHashSet()),
            "redactPatterns" => new RedactPatternsStep(new RedactionPatternOptions
            {
                Patterns = f.Words("patterns", RedactionPatterns.Defaults, RedactionPatterns.BuiltIn).ToHashSet(),
                Phrases = f.Texts("phrases"),
                WholeWord = f.Bool("wholeWord", true),
                MatchCase = f.Bool("matchCase", false),
                Expression = f.Text("expression", null) is { Length: > 0 } x ? x : null,
                Pages = f.Pages("pages"),
            }),
            "checkRedaction" => new CheckRedactionStep(),
            "checkAccessibility" => new CheckAccessibilityStep(),
            "reportContents" => new ReportContentsStep(),
            "watermark" => ReadWatermark(f),
            "headerFooter" => ReadHeaderFooter(f),
            "rotate" => new RotateStep(f.Int("degrees", 90, -270, 270) is var d && d % 90 == 0 && d != 0
                ? d
                : throw new BatchPresetException($"Action {n} (rotate): \"degrees\" should be 90, -90 or 180.")),
            "flatten" => new FlattenStep(new FlattenOptions
            {
                Annotations = f.Bool("annotations", true),
                FormFields = f.Bool("formFields", true),
                Links = f.Bool("links", false),
                PrintableOnly = f.Bool("printableOnly", false),
            }),
            "ocr" => new OcrStep(),
            "saveAsPdfA" => new SaveAsPdfAStep { Conformance = f.Choice("conformance", PdfAConformance.B) },
            "makeAccessible" => new MakeAccessibleStep { Language = f.Text("language", null) is { Length: > 0 } l ? l : null },
            _ => new ExportStep(f.Choice("format", BatchExportFormat.Text), f.Int("dpi", 150, 36, 1200)),
        };
        f.Done();
        return step;
    }

    private static ProtectStep ReadProtect(Fields f)
    {
        var open = f.Bool("openPassword", false, passwordHint: true);
        var permissions = f.Bool("permissionsPassword", false, passwordHint: true);
        if (!open && !permissions)
            throw new BatchPresetException($"{f.Where}: set \"openPassword\", \"permissionsPassword\" or both to true (the passwords themselves are given when it runs).");
        var method = f.Choice("encryption", EncryptionMethod.Aes256, EncryptionMethod.Aes256, EncryptionMethod.Aes128);
        var perms = new PdfPermissions(
            f.Choice("print", PrintPermission.HighResolution),
            f.Bool("copy", true), f.Bool("modify", true), f.Bool("annotate", true), f.Bool("fillForms", true), f.Bool("assemble", true));
        // "" = wanted, given when the batch runs (BatchPresets.WithPasswords, the Batch window's Change…).
        return new ProtectStep(open ? "" : null, permissions ? "" : null, permissions ? perms : PdfPermissions.All, method);
    }

    private static WatermarkStep ReadWatermark(Fields f)
    {
        var text = f.Text("text", null);
        var png = f.Text("imagePng", null);
        StampImage? image = null;
        if (png is { Length: > 0 })
        {
            try
            {
                image = PngDecoder.Decode(Convert.FromBase64String(png));
            }
            catch (Exception ex) when (ex is FormatException or InvalidDataException)
            {
                throw new BatchPresetException($"{f.Where}: \"imagePng\" isn't a PNG picture in base64 ({ex.Message})", ex);
            }
        }
        if (image is null && string.IsNullOrWhiteSpace(text))
            throw new BatchPresetException($"{f.Where}: give a \"text\" (or an \"imagePng\" picture).");
        var step = new WatermarkStep(new WatermarkOptions
        {
            Text = image is null ? text : null,
            Image = image,
            FontSize = f.Number("fontSize", 72, 1, 1000),
            Color = f.Color("color", new AnnotColor(0.5, 0.5, 0.5)),
            Opacity = f.Number("opacity", 0.3, 0, 1),
            Rotation = f.Number("rotation", 45, -360, 360),
            Layout = f.Choice("layout", WatermarkLayout.Center),
            ImageScale = f.Number("imageScale", 0.5, 0.01, 1),
            Behind = f.Bool("behind", false),
        });
        return step;
    }

    private static HeaderFooterStep ReadHeaderFooter(Fields f)
    {
        var texts = Enum.GetValues<HeaderFooterSlot>().ToDictionary(s => s, s => f.Text(Word(s), "") ?? "");
        BatesFormat? bates = null;
        if (f.Object("bates") is { } b)
        {
            bates = new BatesFormat(b.Text("prefix", "") ?? "", b.Long("start", 1, 0, 999_999_999_999), b.Int("digits", 6, 1, 18), b.Text("suffix", "") ?? "");
            b.Done();
        }
        var options = new HeaderFooterOptions
        {
            HeaderLeft = texts[HeaderFooterSlot.HeaderLeft],
            HeaderCenter = texts[HeaderFooterSlot.HeaderCenter],
            HeaderRight = texts[HeaderFooterSlot.HeaderRight],
            FooterLeft = texts[HeaderFooterSlot.FooterLeft],
            FooterCenter = texts[HeaderFooterSlot.FooterCenter],
            FooterRight = texts[HeaderFooterSlot.FooterRight],
            FontSize = f.Number("fontSize", 10, 1, 200),
            Color = f.Color("color", new AnnotColor(0, 0, 0)),
            MarginTop = f.Number("marginTop", 36, 0, 1000),
            MarginBottom = f.Number("marginBottom", 36, 0, 1000),
            MarginLeft = f.Number("marginLeft", 72, 0, 1000),
            MarginRight = f.Number("marginRight", 72, 0, 1000),
            Bates = bates,
        };
        if (options.IsEmpty) throw new BatchPresetException($"{f.Where}: every text is empty; give at least one, such as \"footerCenter\": \"Page <<page>> of <<pages>>\".");
        return new HeaderFooterStep(options, f.Bool("continueBates", false));
    }

    /// <summary>An object's settings, read one by one; <see cref="Done"/> refuses any it didn't ask for (a typo, a setting of another version).</summary>
    private sealed class Fields
    {
        private readonly JsonElement _e;
        private readonly HashSet<string> _asked = [];

        public string Where { get; }

        public Fields(JsonElement e, string where)
        {
            if (e.ValueKind != JsonValueKind.Object) throw new BatchPresetException($"{where} should be an object {{ … }}.");
            _e = e;
            Where = where;
        }

        private JsonElement? Get(string name)
        {
            _asked.Add(name);
            return _e.TryGetProperty(name, out var v) && v.ValueKind != JsonValueKind.Null ? v : null;
        }

        private BatchPresetException Wrong(string name, string should) => new($"{Where}: \"{name}\" should be {should}.");

        public bool Bool(string name, bool fallback, bool passwordHint = false)
        {
            if (Get(name) is not { } v) return fallback;
            if (v.ValueKind is JsonValueKind.True or JsonValueKind.False) return v.GetBoolean();
            if (passwordHint && v.ValueKind == JsonValueKind.String)
                throw new BatchPresetException($"{Where}: passwords aren't kept in presets; \"{name}\" is true or false, and the password is given when the batch runs.");
            throw Wrong(name, "true or false");
        }

        public double Number(string name, double fallback, double min, double max)
        {
            if (Get(name) is not { } v) return fallback;
            if (v.ValueKind != JsonValueKind.Number || !v.TryGetDouble(out var d) || !double.IsFinite(d)) throw Wrong(name, "a number");
            return d >= min && d <= max ? d : throw Wrong(name, $"between {min.ToString(CultureInfo.InvariantCulture)} and {max.ToString(CultureInfo.InvariantCulture)}");
        }

        public double? NullableNumber(string name, double? fallback, double min, double max)
        {
            if (!_e.TryGetProperty(name, out var v)) return fallback;
            return v.ValueKind == JsonValueKind.Null ? Ask(name, null) : Number(name, 0, min, max);
        }

        private double? Ask(string name, double? value)
        {
            _asked.Add(name);
            return value;
        }

        public int Int(string name, int fallback, int min, int max) => (int)Long(name, fallback, min, max);

        public long Long(string name, long fallback, long min, long max)
        {
            if (Get(name) is not { } v) return fallback;
            if (v.ValueKind != JsonValueKind.Number || !v.TryGetInt64(out var i)) throw Wrong(name, "a whole number");
            return i >= min && i <= max ? i : throw Wrong(name, $"between {min} and {max}");
        }

        public string? Text(string name, string? fallback)
        {
            if (Get(name) is not { } v) return fallback;
            return v.ValueKind == JsonValueKind.String ? v.GetString() : throw Wrong(name, "a text in quotes");
        }

        public IReadOnlyList<string> Texts(string name)
        {
            if (Get(name) is not { } v) return [];
            if (v.ValueKind != JsonValueKind.Array) throw Wrong(name, "a list of texts [\"…\", \"…\"]");
            return [.. v.EnumerateArray().Select(e => e.ValueKind == JsonValueKind.String ? e.GetString()! : throw Wrong(name, "a list of texts [\"…\", \"…\"]"))];
        }

        /// <summary>An enum value from its camelCase word; <paramref name="allowed"/> limits the choice (default: every value).</summary>
        public T Choice<T>(string name, T fallback, params T[] allowed) where T : struct, Enum
        {
            if (Get(name) is not { } v) return fallback;
            var choices = allowed.Length > 0 ? allowed : Enum.GetValues<T>();
            var words = string.Join(", ", choices.Select(c => $"\"{Word(c)}\""));
            if (v.ValueKind != JsonValueKind.String) throw Wrong(name, $"one of {words}");
            var given = v.GetString();
            foreach (var c in choices)
                if (Word(c) == given) return c;
            throw Wrong(name, $"one of {words} (it is \"{given}\")");
        }

        /// <summary>A list of enum words; missing: <paramref name="fallback"/>.</summary>
        public IEnumerable<T> Words<T>(string name, IEnumerable<T> fallback, IEnumerable<T>? allowed = null) where T : struct, Enum
        {
            if (Get(name) is not { } v) return fallback;
            var choices = (allowed ?? Enum.GetValues<T>()).ToList();
            var words = string.Join(", ", choices.Select(c => $"\"{Word(c)}\""));
            if (v.ValueKind != JsonValueKind.Array) throw Wrong(name, $"a list of {words}");
            var result = new List<T>();
            foreach (var e in v.EnumerateArray())
            {
                var given = e.ValueKind == JsonValueKind.String ? e.GetString() : null;
                var match = choices.FirstOrDefault(c => Word(c) == given);
                if (given is null || Word(match) != given) throw Wrong(name, $"a list of {words} (\"{given ?? e.GetRawText()}\" isn't one)");
                result.Add(match);
            }
            return result;
        }

        /// <summary>Page numbers from 1 (stored from 0); null or missing: every page.</summary>
        public IReadOnlyList<int>? Pages(string name)
        {
            if (Get(name) is not { } v) return null;
            if (v.ValueKind != JsonValueKind.Array) throw Wrong(name, "null (every page) or a list of page numbers [1, 2]");
            return [.. v.EnumerateArray().Select(e => e.ValueKind == JsonValueKind.Number && e.TryGetInt32(out var p) && p >= 1
                ? p - 1
                : throw Wrong(name, "null (every page) or a list of page numbers from 1"))];
        }

        public AnnotColor Color(string name, AnnotColor fallback)
        {
            var text = Text(name, null);
            if (text is null) return fallback;
            if (text.Length != 7 || text[0] != '#' || !int.TryParse(text.AsSpan(1), NumberStyles.HexNumber, CultureInfo.InvariantCulture, out var rgb))
                throw Wrong(name, "a color such as \"#808080\"");
            return new AnnotColor((rgb >> 16 & 0xFF) / 255.0, (rgb >> 8 & 0xFF) / 255.0, (rgb & 0xFF) / 255.0);
        }

        public Fields? Object(string name) => Get(name) is { } v ? new Fields(v, $"{Where}'s \"{name}\"") : null;

        public JsonElement? Array(string name) =>
            Get(name) is { } v ? v.ValueKind == JsonValueKind.Array ? v : throw Wrong(name, "a list [ … ]") : null;

        public void Done()
        {
            foreach (var p in _e.EnumerateObject())
                if (!_asked.Contains(p.Name))
                    throw new BatchPresetException(p.Name.Contains("password", StringComparison.OrdinalIgnoreCase)
                        ? $"{Where}: \"{p.Name}\" isn't a setting, and passwords are never kept in presets."
                        : $"{Where}: \"{p.Name}\" isn't a setting Inkvolt PDF knows here.");
        }
    }
}
