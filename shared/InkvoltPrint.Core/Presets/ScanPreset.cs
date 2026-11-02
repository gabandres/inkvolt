using System.Text.Json;
using System.Text.Json.Serialization;
using System.Text.RegularExpressions;
using InkvoltPrint.Core.Escl;
using InkvoltPrint.Core.Imaging;
using InkvoltPrint.Core.Suite;

namespace InkvoltPrint.Core.Presets;

/// <summary>Where a preset scans from. Auto: the feeder when it holds pages, else the glass.</summary>
public enum PresetSource { Auto, Glass, Feeder }

public enum PresetFileType { Pdf, SearchablePdf, Jpeg }

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
    public bool Color { get; init; } = true;

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
            Id = "document", Name = "Document to PDF", Source = PresetSource.Auto, Color = false, Resolution = 300,
            FileType = PresetFileType.SearchablePdf, Subfolder = "Scans", FileName = "Document {date} {time}",
        },
        new()
        {
            Id = "photo", Name = "Photo", Source = PresetSource.Glass, Color = true, Resolution = 600, PageSize = "full",
            FileType = PresetFileType.Jpeg, Review = true, SkipBlank = false, Straighten = false, Folder = PresetFolder.Pictures,
            Subfolder = "Scans", FileName = "Photo {date} {time}",
        },
        new()
        {
            Id = "receipt", Name = "Receipt", Source = PresetSource.Glass, Color = false, Resolution = 300, PageSize = "full",
            FileType = PresetFileType.SearchablePdf, Subfolder = @"Scans\Receipts\{date:yyyy}", FileName = "Receipt {date} {n:000}",
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
                Name = string.IsNullOrWhiteSpace(raw.Name) ? "Scan preset" : Cut(raw.Name.Trim()),
                Source = Enum.IsDefined(raw.Source) ? raw.Source : PresetSource.Auto,
                FileType = Enum.IsDefined(raw.FileType) ? raw.FileType : PresetFileType.Pdf,
                After = Enum.IsDefined(raw.After) ? raw.After : PresetAfter.None,
                SplitAt = Enum.IsDefined(raw.SplitAt) ? raw.SplitAt : SplitAt.None,
                Cleanup = raw.Cleanup & PageFilters.All,
                Folder = Enum.IsDefined(raw.Folder) && !(raw.Folder == PresetFolder.Custom && string.IsNullOrWhiteSpace(raw.FolderPath))
                    ? raw.Folder : PresetFolder.Documents,
                Resolution = Math.Clamp(raw.Resolution, MinResolution, MaxResolution),
                PageSize = ScanChoices.PageSizes.Any(s => s.Key == raw.PageSize) ? raw.PageSize : null,
                Subfolder = raw.Subfolder ?? "",
                FileName = string.IsNullOrWhiteSpace(raw.FileName) ? DefaultFileName : raw.FileName,
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
            var n = list[i].NextNumber;
            list[i] = list[i] with { NextNumber = n + 1 };
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
        new() { Id = NewId(), Name = UniqueName(existing.Select(p => p.Name), "New preset") };

    /// <summary>A copy under a new id and name ("Receipt copy"), with its own counter.</summary>
    public static ScanPreset Duplicate(IEnumerable<ScanPreset> existing, ScanPreset preset) =>
        preset with { Id = NewId(), Name = UniqueName(existing.Select(p => p.Name), $"{preset.Name} copy"), NextNumber = 1 };

    /// <summary>Why <paramref name="name"/> can't be the name of preset <paramref name="id"/>; null when it can.</summary>
    public static string? NameProblem(IEnumerable<ScanPreset> existing, string id, string? name)
    {
        var trimmed = name?.Trim() ?? "";
        if (trimmed.Length == 0) return "Give the preset a name.";
        if (trimmed.Length > MaxNameLength) return $"Names can be up to {MaxNameLength} characters.";
        return existing.FirstOrDefault(p => p.Id != id && string.Equals(p.Name.Trim(), trimmed, StringComparison.OrdinalIgnoreCase)) is { } other
            ? $"Another preset is already called \"{other.Name}\"." : null;
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

    private static string Cut(string name) => name.Length > MaxNameLength ? name[..MaxNameLength] : name;

    private static string NewId() => Guid.NewGuid().ToString("N")[..12];
}

/// <summary>Words for presets in the UI (button tooltips, the Overview's scan card, the editor's lists).</summary>
public static class ScanPresetText
{
    public static string FileType(PresetFileType t) => t switch
    {
        PresetFileType.SearchablePdf => "Searchable PDF",
        PresetFileType.Jpeg => "JPEG images",
        _ => "PDF",
    };

    public static string Source(PresetSource s, bool twoSided) => s switch
    {
        PresetSource.Glass => "glass",
        PresetSource.Feeder => twoSided ? "feeder, both sides" : "feeder",
        _ => twoSided ? "feeder (both sides) or glass" : "feeder or glass",
    };

    public static string After(PresetAfter a) => a switch
    {
        PresetAfter.OpenInInkvoltPdf => "open in Inkvolt PDF",
        PresetAfter.Print => "print a copy",
        PresetAfter.Email => "email it",
        _ => "nothing else",
    };

    /// <summary>The folder as the user knows it: Documents, Pictures, or the chosen folder's name; then the subfolder template.</summary>
    public static string Folder(ScanPreset p)
    {
        var root = p.Folder switch
        {
            PresetFolder.Pictures => "Pictures",
            PresetFolder.Custom when p.FolderPath is { Length: > 0 } path => System.IO.Path.GetFileName(path.TrimEnd('\\', '/')) is { Length: > 0 } leaf ? leaf : path,
            _ => "Documents",
        };
        return string.IsNullOrWhiteSpace(p.Subfolder) ? root : $"{root}\\{p.Subfolder.Trim('\\', '/', ' ')}";
    }

    /// <summary>"patch code sheet", "blank page", "patch code sheet or blank page".</summary>
    public static string SplitText(SplitAt s) => s switch
    {
        SplitAt.BlankPage => "blank page",
        SplitAt.PatchCodeOrBlankPage => "patch code sheet or blank page",
        _ => "patch code sheet",
    };

    /// <summary>"Searchable PDF · feeder or glass · grey, 300 dpi · Documents\Scans", plus the review step and what happens after saving.</summary>
    public static string Summary(ScanPreset p)
    {
        var parts = new List<string>
        {
            FileType(p.FileType),
            Source(p.Source, p.TwoSided),
            $"{(p.Color ? "color" : "grey")}, {p.Resolution} dpi",
            Folder(p),
        };
        if (p.SplitAt != SplitAt.None) parts.Add($"a new file at each {SplitText(p.SplitAt)}");
        if (p.FindPhotos) parts.Add("each photo on the glass by itself");
        if (PageCleanup.Describe(p.Cleanup) is { Length: > 0 } cleanup) parts.Add(cleanup);
        if (p.Review) parts.Add("review first");
        if (p.After != PresetAfter.None) parts.Add($"then {After(p.After)}");
        return string.Join(" · ", parts);
    }
}
