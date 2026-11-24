using System.Text.Json;
using System.Text.Json.Serialization;
using System.Text.RegularExpressions;
using InkvoltPrint.Core.Escl;
using InkvoltPrint.Core.Imaging;
using InkvoltPrint.Core.Suite;

namespace InkvoltPrint.Core.Presets;

/// <summary>Where a preset scans from. Auto: the feeder when it holds pages, else the glass.</summary>
public enum PresetSource { Auto, Glass, Feeder }

/// <summary>What a preset saves: a PDF, a searchable PDF, JPEG pictures, or the text read from the pages as a Word document or plain text (roadmap 4.14).</summary>
public enum PresetFileType { Pdf, SearchablePdf, Jpeg, Word, Text }

/// <summary>The folder a preset saves into; sync folders (OneDrive, Dropbox) are <see cref="Custom"/> paths.</summary>
public enum PresetFolder { Documents, Pictures, Custom }

/// <summary>What happens once the file is saved.</summary>
public enum PresetAfter { None, OpenInInkvoltPdf, Print, Email }

/// <summary>
/// A named set of scan settings plus where the file goes and what it's called: one click scans and saves. Settings are
/// wishes, matched to each scanner when it runs (<see cref="PresetPlan"/>). Stored in the app's settings (numbers for enums,
/// so a value from a newer version can't make the file unreadable; <see cref="ScanPresets.Normalize"/> repairs it).
/// </summary>
public sealed record ScanPreset
{
    public string Id { get; init; } = "";
    public string Name { get; init; } = "";
    public PresetSource Source { get; init; }

    /// <summary>Both sides of each page, when the feeder is used and can.</summary>
    public bool TwoSided { get; init; }

    /// <summary>
    /// With <see cref="TwoSided"/>, on a feeder that scans one side: the fronts, then the stack turned over for the backs, put
    /// in order (<see cref="Imaging.TurnedStack"/>). Off: one side only, as before.
    /// </summary>
    public bool TurnStack { get; init; }
    public bool Color { get; init; } = true;

    /// <summary>
    /// A PDF's pages saved in black and white (1 bit, CCITT G4) for a much smaller file; scanned in grey. Not for photos on the
    /// glass, which stay in color.
    /// </summary>
    public bool SmallerFile { get; init; }

    /// <summary>A PDF saved as PDF/A-2b, for archiving (<see cref="ScanPresets.SavesPdfA"/>); never with <see cref="Password"/>.</summary>
    public bool PdfA { get; init; }

    /// <summary>
    /// A PDF that asks for a password to open (AES-256, <see cref="ScanPresets.SavesWithPassword"/>). The password itself is never
    /// in the preset: Windows' Credential Manager keeps it under the preset's id, or the save asks for it.
    /// </summary>
    public bool Password { get; init; }

    /// <summary>Pages lying sideways or upside down turned upright, when their text says so clearly (<see cref="Imaging.PageUpright"/>).</summary>
    public bool TurnUpright { get; init; } = true;

    /// <summary>Black and white (1 bit) where the scanner offers it, else grey; <see cref="Color"/> off. Inkvolt PDF's presets set it.</summary>
    public bool BlackAndWhite { get; init; }
    public int Resolution { get; init; } = 300;

    /// <summary><see cref="ScanChoices.PageSizes"/> key; null = Letter or A4 by region.</summary>
    public string? PageSize { get; init; }
    public PresetFileType FileType { get; init; } = PresetFileType.SearchablePdf;

    /// <summary>Stop on the scan review (turn, crop, reorder) before saving; off saves right away.</summary>
    public bool Review { get; init; }
    public bool SkipBlank { get; init; } = true;
    public bool Straighten { get; init; } = true;

    /// <summary>What each page is cleaned up with (crop to the paper, whiten, descreen, restore colors); none by default.</summary>
    public PageFilters Cleanup { get; init; }

    /// <summary>The color <see cref="PageFilters.DropColor"/> drops, "#RRGGBB" (<see cref="Imaging.DropColor.Hex"/>); null: red.</summary>
    public string? DropColor { get; init; }

    /// <summary>The OCR language (a BCP-47 tag) for a searchable PDF; null: Windows' first display language that has one.</summary>
    public string? OcrLanguage { get; init; }

    /// <summary>Batch scanning: one feeder run saved as several files, a new one at each separator sheet.</summary>
    public SplitAt SplitAt { get; init; }

    /// <summary>Separator sheets stay in (as the first page of the file they start) instead of being left out.</summary>
    public bool KeepSeparators { get; init; }

    /// <summary>Several photos on the glass: each found and saved by itself, cut out straight (glass scans only).</summary>
    public bool FindPhotos { get; init; }
    public PresetFolder Folder { get; init; }

    /// <summary>The folder for <see cref="PresetFolder.Custom"/>.</summary>
    public string? FolderPath { get; init; }

    /// <summary>Template for a folder inside <see cref="Folder"/> ("" = none), e.g. <c>Receipts\{date:yyyy}</c>.</summary>
    public string Subfolder { get; init; } = "";

    /// <summary>File-name template (<see cref="FileNameTemplate"/>).</summary>
    public string FileName { get; init; } = ScanPresets.DefaultFileName;
    public PresetAfter After { get; init; }

    /// <summary>The next <c>{n}</c>; goes up by one with every scan saved with this preset (<see cref="ScanPresets.Reserve"/>).</summary>
    public int NextNumber { get; init; } = 1;

    /// <summary>Fields this version doesn't know (written by a newer one), kept as they were so saving doesn't drop them.</summary>
    [JsonExtensionData]
    public Dictionary<string, JsonElement>? Unknown { get; init; }
}

/// <summary>The presets as stored: <see cref="Version"/> says which shape the list was written in.</summary>
public sealed class ScanPresetSettings
{
    public int Version { get; set; } = ScanPresets.CurrentVersion;
    public List<ScanPreset>? Items { get; set; }

    /// <summary>Fields a newer version added, kept as they were.</summary>
    [JsonExtensionData]
    public Dictionary<string, JsonElement>? Unknown { get; set; }

    /// <summary>Written by a newer Inkvolt Print: usable, but this version doesn't write over it (<see cref="ScanPresets.CurrentVersion"/>).</summary>
    [JsonIgnore]
    public bool IsNewer => Version > ScanPresets.CurrentVersion;
}

/// <summary>Built-in starters and the list operations the editor offers (create, duplicate, rename checks, reorder).</summary>
public static partial class ScanPresets
{
    /// <summary>1: the first shape. A file without presets (version 0, from before presets) gets the built-ins.</summary>
    public const int CurrentVersion = 1;

    public const string DefaultFileName = "{preset} {date} {time}";
    public const int MaxNameLength = 60;
    private const int MaxResolution = 1200, MinResolution = 75;

    public static IReadOnlyList<ScanPreset> BuiltIns() =>
    [
        new()
        {
            Id = "document", Name = CoreStrings.Preset_DocumentName, Source = PresetSource.Auto, Color = false, Resolution = 300,
            FileType = PresetFileType.SearchablePdf, Subfolder = CoreStrings.Preset_ScansFolder, FileName = CoreStrings.Preset_DocumentFileName,
        },
        new()
        {
            Id = "photo", Name = CoreStrings.Preset_PhotoName, Source = PresetSource.Glass, Color = true, Resolution = 600, PageSize = "full",
            FileType = PresetFileType.Jpeg, Review = true, SkipBlank = false, Straighten = false, Folder = PresetFolder.Pictures,
            Subfolder = CoreStrings.Preset_ScansFolder, FileName = CoreStrings.Preset_PhotoFileName,
        },
        new()
        {
            Id = "receipt", Name = CoreStrings.Preset_ReceiptName, Source = PresetSource.Glass, Color = false, Resolution = 300, PageSize = "full",
            FileType = PresetFileType.SearchablePdf, Subfolder = CoreStrings.Preset_ReceiptsFolder, FileName = CoreStrings.Preset_ReceiptFileName,
        },
    ];

    /// <summary>
    /// The stored list made safe to use: null or pre-preset settings get the built-ins (an emptied list stays empty);
    /// missing or repeated ids and names, unknown values (hand edits, newer versions) and out-of-range numbers are repaired.
    /// </summary>
    public static List<ScanPreset> Normalize(ScanPresetSettings? stored)
    {
        if (stored?.Items is not { } items || stored.Version < 1) return [.. BuiltIns()];
        var list = new List<ScanPreset>();
        var ids = new HashSet<string>(StringComparer.Ordinal);
        foreach (var raw in items)
        {
            if (raw is null) continue;
            var p = raw with
            {
                Id = !IsValidId(raw.Id) || ids.Contains(raw.Id) ? NewId() : raw.Id,
                Name = string.IsNullOrWhiteSpace(raw.Name) ? CoreStrings.Preset_DefaultName : Cut(raw.Name.Trim()),
                Source = Enum.IsDefined(raw.Source) ? raw.Source : PresetSource.Auto,
                FileType = Enum.IsDefined(raw.FileType) ? raw.FileType : PresetFileType.Pdf,
                After = Enum.IsDefined(raw.After) ? raw.After : PresetAfter.None,
                SplitAt = Enum.IsDefined(raw.SplitAt) ? raw.SplitAt : SplitAt.None,
                Cleanup = raw.Cleanup & PageFilters.All,
                DropColor = Imaging.DropColor.Parse(raw.DropColor)?.Hex,
                Folder = Enum.IsDefined(raw.Folder) && !(raw.Folder == PresetFolder.Custom && string.IsNullOrWhiteSpace(raw.FolderPath))
                    ? raw.Folder : PresetFolder.Documents,
                Resolution = Math.Clamp(raw.Resolution, MinResolution, MaxResolution),
                PageSize = ScanChoices.PageSizes.Any(s => s.Key == raw.PageSize) ? raw.PageSize : null,
                Subfolder = FileNameTemplate.PadsTooWide(raw.Subfolder) ? "" : raw.Subfolder ?? "",
                FileName = string.IsNullOrWhiteSpace(raw.FileName) || FileNameTemplate.PadsTooWide(raw.FileName) ? DefaultFileName : raw.FileName,
                NextNumber = Math.Max(1, raw.NextNumber),
            };
            p = p with { Name = UniqueName(list.Select(x => x.Name), p.Name) };
            ids.Add(p.Id);
            list.Add(p);
        }
        return list;
    }

    /// <summary>
    /// Ids go on a command line (the jump list's <c>--preset id</c>) unquoted: letters, digits and '-' only, at most 64.
    /// </summary>
    public static bool IsValidId(string? id) => id is { Length: > 0 and <= 64 } && ValidId().IsMatch(id);

    [GeneratedRegex("^[A-Za-z0-9-]+$")]
    private static partial Regex ValidId();

    /// <summary>
    /// Takes the next <c>{n}</c> of preset <paramref name="id"/> in <paramref name="list"/> and moves its counter on, in one
    /// step, so two scans saved with one preset never get the same number. Null when the preset isn't in the list.
    /// </summary>
    public static int? Reserve(IList<ScanPreset> list, string id)
    {
        for (var i = 0; i < list.Count; i++)
        {
            if (list[i].Id != id) continue;
            var n = Math.Max(1, list[i].NextNumber);
            list[i] = list[i] with { NextNumber = n < int.MaxValue ? n + 1 : 1 }; // past int: 1 again, never a negative number
            return n;
        }
        return null;
    }

    /// <summary>
    /// The editor's list with each preset's counter as it is in <paramref name="current"/> now (scans may have been saved
    /// while the editor was open); new presets keep theirs.
    /// </summary>
    public static List<ScanPreset> KeepCounters(IEnumerable<ScanPreset> edited, IEnumerable<ScanPreset> current)
    {
        var counters = current.GroupBy(p => p.Id).ToDictionary(g => g.Key, g => g.First().NextNumber);
        return edited.Select(p => counters.TryGetValue(p.Id, out var n) ? p with { NextNumber = n } : p).ToList();
    }

    /// <summary>
    /// Inkvolt PDF's Scan dialog: its current choices saved under <paramref name="name"/> (made unique), a searchable PDF when
    /// <paramref name="ocr"/>. The scanner isn't part of it: the preset is matched to whichever scanner is chosen (<see cref="PresetPlan"/>).
    /// </summary>
    public static ScanPreset FromChoices(IEnumerable<ScanPreset> existing, string name, ScanSource source, ScanColor color, int dpi,
        string? pageSize, bool ocr, bool skipBlank) => new()
    {
        Id = NewId(),
        Name = UniqueName(existing.Select(p => p.Name), Cut(name.Trim())),
        Source = source == ScanSource.Platen ? PresetSource.Glass : PresetSource.Feeder,
        TwoSided = source == ScanSource.AdfDuplex,
        Color = color == ScanColor.Color,
        BlackAndWhite = color == ScanColor.BlackAndWhite,
        Resolution = Math.Clamp(dpi, MinResolution, MaxResolution),
        PageSize = ScanChoices.PageSizes.Any(s => s.Key == pageSize) ? pageSize : null,
        FileType = ocr ? PresetFileType.SearchablePdf : PresetFileType.Pdf,
        Review = true,
        SkipBlank = skipBlank,
    };

    public static ScanPreset Create(IEnumerable<ScanPreset> existing) =>
        new() { Id = NewId(), Name = UniqueName(existing.Select(p => p.Name), CoreStrings.Preset_NewName) };

    /// <summary>A copy under a new id and name ("Receipt copy"), with its own counter.</summary>
    public static ScanPreset Duplicate(IEnumerable<ScanPreset> existing, ScanPreset preset) =>
        preset with { Id = NewId(), Name = UniqueName(existing.Select(p => p.Name), string.Format(CoreStrings.Preset_CopyName, preset.Name)), NextNumber = 1 };

    /// <summary>Why <paramref name="name"/> can't be the name of preset <paramref name="id"/>; null when it can.</summary>
    public static string? NameProblem(IEnumerable<ScanPreset> existing, string id, string? name)
    {
        var trimmed = name?.Trim() ?? "";
        if (trimmed.Length == 0) return CoreStrings.Preset_NameEmpty;
        if (trimmed.Length > MaxNameLength) return string.Format(CoreStrings.Preset_NameTooLong, MaxNameLength);
        return existing.FirstOrDefault(p => p.Id != id && string.Equals(p.Name.Trim(), trimmed, StringComparison.OrdinalIgnoreCase)) is { } other
            ? string.Format(CoreStrings.Preset_NameTaken, other.Name) : null;
    }

    /// <summary>Moves the item at <paramref name="from"/> to <paramref name="to"/>; false when either is out of range or they're equal.</summary>
    public static bool Move<T>(IList<T> list, int from, int to)
    {
        if (from < 0 || to < 0 || from >= list.Count || to >= list.Count || from == to) return false;
        var item = list[from];
        list.RemoveAt(from);
        list.Insert(to, item);
        return true;
    }

    /// <summary><paramref name="wanted"/>, else "wanted (2)", "wanted (3)"… (names compared without case).</summary>
    public static string UniqueName(IEnumerable<string> existing, string wanted)
    {
        var taken = new HashSet<string>(existing.Select(n => n.Trim()), StringComparer.OrdinalIgnoreCase);
        if (!taken.Contains(wanted)) return wanted;
        for (var i = 2; ; i++)
            if (!taken.Contains($"{wanted} ({i})")) return $"{wanted} ({i})";
    }

    /// <summary>
    /// The preset's pages go into its PDF in black and white (<see cref="ScanPreset.SmallerFile"/>): not for JPEG files, nor for
    /// photos found on the glass, which stay pictures in color. <paramref name="source"/>: where it scans from this time; null:
    /// as the preset says (glass when it says glass).
    /// </summary>
    public static bool SavesSmallerFile(ScanPreset p, ScanSource? source = null) =>
        p.SmallerFile && IsPdf(p.FileType)
        && !(p.FindPhotos && (source is { } s ? s == ScanSource.Platen : p.Source == PresetSource.Glass));

    /// <summary>The preset's PDF is PDF/A-2b: a PDF file type, and no password (PDF/A forbids encryption: the password wins).</summary>
    public static bool SavesPdfA(ScanPreset p) => p.PdfA && IsPdf(p.FileType) && !p.Password;

    /// <summary>The preset's PDF asks for a password to open: a PDF file type with the option on.</summary>
    public static bool SavesWithPassword(ScanPreset p) => p.Password && IsPdf(p.FileType);

    /// <summary>
    /// The editor's PDF/A box ticked or cleared: ticking it clears the password (they can't go together), the last one ticked winning.
    /// </summary>
    public static ScanPreset WithPdfA(ScanPreset p, bool on) => p with { PdfA = on, Password = on ? false : p.Password };

    /// <summary>The editor's password box ticked or cleared: ticking it clears PDF/A.</summary>
    public static ScanPreset WithPassword(ScanPreset p, bool on) => p with { Password = on, PdfA = on ? false : p.PdfA };

    /// <summary>The ids whose saved password goes when <paramref name="before"/> becomes <paramref name="after"/>: deleted, or the password turned off.</summary>
    public static IReadOnlyList<string> PasswordsToForget(IEnumerable<ScanPreset> before, IEnumerable<ScanPreset> after)
    {
        var kept = after.Where(p => p.Password).Select(p => p.Id).ToHashSet(StringComparer.Ordinal);
        return [.. before.Where(p => p.Password && !kept.Contains(p.Id)).Select(p => p.Id)];
    }

    /// <summary>
    /// How the preset's PDF is written (<see cref="Pdf.PdfWriter.Write"/>): PDF/A, or with <paramref name="password"/> when it
    /// asks for one; null for the plain file. A PDF/A or protected file is always written here, never the scanner's own PDF as sent.
    /// </summary>
    /// <exception cref="ArgumentException">The preset asks for a password and <paramref name="password"/> can't be one: a protected
    /// preset never saves its PDF open.</exception>
    public static Pdf.PdfWriteOptions? WriteOptions(ScanPreset p, string? password) =>
        SavesWithPassword(p)
            ? Pdf.PdfEncryption.Usable(password) ? new Pdf.PdfWriteOptions { Password = password }
                : throw new ArgumentException("The preset protects its PDF and no usable password was given.", nameof(password))
        : SavesPdfA(p) ? new Pdf.PdfWriteOptions { PdfA = true }
        : null;

    /// <summary>A PDF (searchable or not): what opens in Inkvolt PDF and can be saved in black and white.</summary>
    public static bool IsPdf(PresetFileType type) => type is PresetFileType.Pdf or PresetFileType.SearchablePdf;

    /// <summary>The saved file's extension: ".pdf", ".jpg", ".docx" or ".txt".</summary>
    public static string Extension(PresetFileType type) => type switch
    {
        PresetFileType.Jpeg => ".jpg",
        PresetFileType.Word => ".docx",
        PresetFileType.Text => ".txt",
        _ => ".pdf",
    };

    private static string Cut(string name) => name.Length > MaxNameLength ? name[..MaxNameLength] : name;

    private static string NewId() => Guid.NewGuid().ToString("N")[..12];
}

/// <summary>Words for presets in the UI (button tooltips, the Overview's scan card, the editor's lists).</summary>
public static class ScanPresetText
{
    public static string FileType(PresetFileType t) => t switch
    {
        PresetFileType.SearchablePdf => CoreStrings.Preset_SearchablePdf,
        PresetFileType.Jpeg => CoreStrings.Preset_JpegImages,
        PresetFileType.Word => CoreStrings.Preset_WordDocument,
        PresetFileType.Text => CoreStrings.Preset_TextFile,
        _ => "PDF",
    };

    public static string Source(PresetSource s, bool twoSided) => s switch
    {
        PresetSource.Glass => CoreStrings.Preset_SourceGlass,
        PresetSource.Feeder => twoSided ? CoreStrings.Preset_SourceFeederBoth : CoreStrings.Preset_SourceFeeder,
        _ => twoSided ? CoreStrings.Preset_SourceAutoBoth : CoreStrings.Preset_SourceAuto,
    };

    /// <summary>The preset's color as its summary says it: color, grey, or black and white for a smaller file.</summary>
    public static string ColorDpi(ScanPreset p) => string.Format(
        ScanPresets.SavesSmallerFile(p) ? CoreStrings.Preset_SmallerFileDpi : p.Color ? CoreStrings.Preset_ColorDpi : CoreStrings.Preset_GreyDpi,
        p.Resolution);

    public static string After(PresetAfter a) => a switch
    {
        PresetAfter.OpenInInkvoltPdf => CoreStrings.Preset_AfterOpenPdf,
        PresetAfter.Print => CoreStrings.Preset_AfterPrint,
        PresetAfter.Email => CoreStrings.Preset_AfterEmail,
        _ => CoreStrings.Preset_AfterNothing,
    };

    /// <summary>The folder as the user knows it: Documents, Pictures, or the chosen folder's name; then the subfolder template.</summary>
    public static string Folder(ScanPreset p)
    {
        var root = p.Folder switch
        {
            PresetFolder.Pictures => CoreStrings.Preset_FolderPictures,
            PresetFolder.Custom when p.FolderPath is { Length: > 0 } path => System.IO.Path.GetFileName(path.TrimEnd('\\', '/')) is { Length: > 0 } leaf ? leaf : path,
            _ => CoreStrings.Preset_FolderDocuments,
        };
        return string.IsNullOrWhiteSpace(p.Subfolder) ? root : $"{root}\\{p.Subfolder.Trim('\\', '/', ' ')}";
    }

    /// <summary>"patch code sheet", "blank page", "patch code sheet or blank page".</summary>
    public static string SplitText(SplitAt s) => s switch
    {
        SplitAt.BlankPage => CoreStrings.Preset_SplitBlank,
        SplitAt.PatchCodeOrBlankPage => CoreStrings.Preset_SplitPatchOrBlank,
        _ => CoreStrings.Preset_SplitPatch,
    };

    /// <summary>"Searchable PDF · feeder or glass · grey, 300 dpi · Documents\Scans", plus the review step and what happens after saving.</summary>
    public static string Summary(ScanPreset p)
    {
        var parts = new List<string>
        {
            FileType(p.FileType),
            Source(p.Source, p.TwoSided),
            ColorDpi(p),
            Folder(p),
        };
        if (ScanPresets.SavesPdfA(p)) parts.Add(CoreStrings.Preset_PdfAShort);
        if (ScanPresets.SavesWithPassword(p)) parts.Add(CoreStrings.Preset_PasswordShort);
        if (p.TwoSided && p.TurnStack && p.Source != PresetSource.Glass) parts.Add(CoreStrings.Preset_TurnStackShort);
        if (p.SplitAt != SplitAt.None) parts.Add(string.Format(CoreStrings.Preset_NewFileAtEach, SplitText(p.SplitAt)));
        if (p.FindPhotos) parts.Add(CoreStrings.Preset_EachPhoto);
        if (PageCleanup.Describe(p.Cleanup, Imaging.DropColor.Parse(p.DropColor)) is { Length: > 0 } cleanup) parts.Add(cleanup);
        if (p.Review) parts.Add(CoreStrings.Preset_ReviewFirst);
        if (p.After != PresetAfter.None) parts.Add(string.Format(CoreStrings.Preset_Then, After(p.After)));
        return string.Join(" · ", parts);
    }
}
