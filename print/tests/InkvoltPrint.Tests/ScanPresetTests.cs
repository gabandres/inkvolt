using System.Globalization;
using System.Text.Json;
using InkvoltPrint.Core.Escl;
using InkvoltPrint.Core.Presets;

namespace InkvoltPrint.Tests;

public class FileNameTemplateTests
{
    private static readonly NameContext Ctx = new(new DateTime(2026, 10, 24, 9, 5, 7), "Receipt", "Demo printer", 7, 3, CultureInfo.InvariantCulture);

    [Theory]
    [InlineData("{preset} {date}", "Receipt 2026-10-24")]
    [InlineData("{date:yyyyMMdd}-{time}", "20261024-0905")]
    [InlineData("{time:HH.mm.ss}", "09.05.07")]
    [InlineData("Scan {n}", "Scan 7")]
    [InlineData("Scan {n:000}", "Scan 007")]
    [InlineData("{printer} ({pages} pages)", "Demo printer (3 pages)")]
    [InlineData("{PRESET} {Date}", "Receipt 2026-10-24")] // token names aren't case-sensitive
    [InlineData("{{literal}} {preset}", "{literal} Receipt")]
    [InlineData("plain", "plain")]
    public void Expands(string template, string expected) => Assert.Equal(expected, FileNameTemplate.FileName(template, Ctx));

    [Theory]
    [InlineData("{date:yyyy/MM/dd}", "2026-10-24")] // a separator in a date format can't become a folder
    [InlineData("a<b>c:d\"e|f?g*h", "a-b-c-d-e-f-g-h")]
    [InlineData("  name.  ", "name")] // Windows drops trailing dots and spaces itself: never rely on it
    [InlineData("", "Scan")]
    [InlineData("   ", "Scan")]
    [InlineData("...", "Scan")]
    [InlineData("CON", "CON_")]
    [InlineData("lpt1", "lpt1_")]
    [InlineData("nul.backup", "nul_.backup")]
    [InlineData("COM¹", "COM¹_")]
    [InlineData("lpt³.txt", "lpt³_.txt")]
    [InlineData("conin$", "conin$_")]
    [InlineData("CONOUT$.log", "CONOUT$_.log")]
    [InlineData("COM10", "COM10")] // not a device
    [InlineData("tab\there", "tab-here")]
    public void Sanitizes(string template, string expected) => Assert.Equal(expected, FileNameTemplate.FileName(template, Ctx));

    [Fact]
    public void ValuesWithSlashesStayInOneName()
    {
        var ctx = Ctx with { Printer = @"HP\LaserJet/M234" };
        Assert.Equal("HP-LaserJet-M234", FileNameTemplate.FileName("{printer}", ctx));
    }

    [Fact]
    public void LongNamesAreCut()
    {
        var name = FileNameTemplate.FileName(new string('x', 400), Ctx);
        Assert.Equal(FileNameTemplate.MaxNameLength, name.Length);
    }

    [Theory]
    [InlineData("{preset} {date}", null)]
    [InlineData("{n:000} {date:yyyy-MM}", null)]
    [InlineData("{pagez}", "Unknown token {pagez}. Use {date}, {time}, {preset}, {printer}, {n} or {pages}.")]
    [InlineData("{date", "A { has no closing }. Type {{ for a brace.")]
    [InlineData("a } b", "A } has no opening {. Type }} for a brace.")]
    [InlineData("{preset:x}", "{preset} takes no format.")]
    [InlineData("{}", "Unknown token {}. Use {date}, {time}, {preset}, {printer}, {n} or {pages}.")]
    public void Validates(string template, string? problem) => Assert.Equal(problem, FileNameTemplate.Problem(template));

    [Fact]
    public void UnknownTokensStayAsTyped() => Assert.Equal("{pagez} Receipt", FileNameTemplate.FileName("{pagez} {preset}", Ctx));

    [Theory]
    [InlineData("", "")]
    [InlineData("Scans", "Scans")]
    [InlineData(@"Receipts\{date:yyyy}", @"Receipts\2026")]
    [InlineData("Receipts/{date:yyyy}/{date:MM}", @"Receipts\2026\10")]
    [InlineData(@"..\..\Windows", "Windows")] // never climbs out of the chosen folder
    [InlineData(@"C:\Temp", @"C-\Temp")]
    [InlineData(@"\\server\share", @"server\share")]
    [InlineData(@"a\\\b\", @"a\b")]
    [InlineData("{date:yyyy/MM}", "2026-10")] // separators inside a token stay in its one folder name
    [InlineData("{printer}", "Demo printer")]
    public void Subfolders(string template, string expected) => Assert.Equal(expected, FileNameTemplate.Subfolder(template, Ctx));

    [Fact]
    public void NeverOverwrites()
    {
        var existing = new HashSet<string>(StringComparer.OrdinalIgnoreCase) { @"C:\s\Scan.pdf", @"C:\s\Scan-2.pdf" };
        Assert.Equal(@"C:\s\Scan-3.pdf", FileNameTemplate.UniquePath(@"C:\s", "Scan", ".pdf", existing.Contains));
        Assert.Equal(@"C:\s\Other.pdf", FileNameTemplate.UniquePath(@"C:\s", "Other", ".pdf", existing.Contains));
        Assert.Equal(@"C:\s\scan-3.pdf", FileNameTemplate.UniquePath(@"C:\s", "scan", ".pdf", existing.Contains)); // Windows names ignore case
    }

    [Fact]
    public void ImageSetsAreNumberedAndNeverOverwrite()
    {
        Assert.Equal([@"C:\s\Photo.jpg"], FileNameTemplate.UniquePaths(@"C:\s", "Photo", ".jpg", 1, _ => false));
        Assert.Equal([@"C:\s\Photo (1).jpg", @"C:\s\Photo (2).jpg"], FileNameTemplate.UniquePaths(@"C:\s", "Photo", ".jpg", 2, _ => false));
        // One of the set exists: the whole set moves to the next free name, so pages stay together.
        var existing = new HashSet<string>(StringComparer.OrdinalIgnoreCase) { @"C:\s\Photo (2).jpg" };
        Assert.Equal([@"C:\s\Photo-2 (1).jpg", @"C:\s\Photo-2 (2).jpg"], FileNameTemplate.UniquePaths(@"C:\s", "Photo", ".jpg", 2, existing.Contains));
    }
}

public class FileSetTests
{
    /// <summary>A folder where <paramref name="late"/> files appear only when something tries to move onto them.</summary>
    private sealed class FakeFolder(params string[] late)
    {
        public readonly HashSet<string> Files = new(StringComparer.OrdinalIgnoreCase);
        private readonly HashSet<string> _late = new(late, StringComparer.OrdinalIgnoreCase);

        public bool TryMove(string from, string to)
        {
            if (_late.Remove(to)) Files.Add(to); // another program saved there just now
            if (Files.Contains(to) || !Files.Remove(from)) return false;
            Files.Add(to);
            return true;
        }
    }

    [Fact]
    public void ANameTakenMidwayMovesTheWholeSetOn()
    {
        var fs = new FakeFolder(@"C:\s\Photo (2).jpg");
        fs.Files.UnionWith([@"C:\s\t1", @"C:\s\t2", @"C:\s\t3"]);
        var placed = FileNameTemplate.PlaceSet([@"C:\s\t1", @"C:\s\t2", @"C:\s\t3"], @"C:\s", "Photo", ".jpg", fs.Files.Contains, fs.TryMove);
        Assert.Equal([@"C:\s\Photo-2 (1).jpg", @"C:\s\Photo-2 (2).jpg", @"C:\s\Photo-2 (3).jpg"], placed);
        // Nothing of ours left under the first name or as a temporary file; the other program's file untouched.
        Assert.Equal(
            new HashSet<string>([@"C:\s\Photo (2).jpg", .. placed], StringComparer.OrdinalIgnoreCase),
            fs.Files);
    }

    [Fact]
    public void ASingleFileTakesTheNextName()
    {
        var fs = new FakeFolder(@"C:\s\Scan.pdf");
        fs.Files.Add(@"C:\s\tmp");
        Assert.Equal([@"C:\s\Scan-2.pdf"], FileNameTemplate.PlaceSet([@"C:\s\tmp"], @"C:\s", "Scan", ".pdf", fs.Files.Contains, fs.TryMove));
    }
}

public class ScanPresetListTests
{
    [Fact]
    public void StartsWithTheBuiltIns()
    {
        var list = ScanPresets.Normalize(null);
        Assert.Equal(["Document to PDF", "Photo", "Receipt"], list.Select(p => p.Name));
        Assert.All(list, p => Assert.Null(FileNameTemplate.Problem(p.FileName)));
        Assert.All(list, p => Assert.Null(FileNameTemplate.Problem(p.Subfolder)));
        Assert.Equal(list.Count, list.Select(p => p.Id).Distinct().Count());
        var photo = list[1];
        Assert.Equal(PresetFileType.Jpeg, photo.FileType);
        Assert.True(photo.Color);
        Assert.False(photo.SkipBlank);
    }

    [Fact]
    public void BuiltInsAreFreshCopies() => Assert.NotSame(ScanPresets.BuiltIns()[0], ScanPresets.BuiltIns()[0]);

    [Fact]
    public void EmptySavedListStaysEmpty() =>
        // The user deleted every preset: don't bring the starters back behind their back.
        Assert.Empty(ScanPresets.Normalize(new ScanPresetSettings { Version = ScanPresets.CurrentVersion, Items = [] }));

    [Fact]
    public void RepairsHandEditedOrNewerFiles()
    {
        var stored = new ScanPresetSettings
        {
            Version = 99,
            Items =
            [
                null!,
                new ScanPreset { Id = "a", Name = "  ", Resolution = 5000, NextNumber = -4, FileName = null!, Subfolder = null!, PageSize = "tabloid" },
                new ScanPreset { Id = "a", Name = "Second", Source = (PresetSource)42, FileType = (PresetFileType)9, After = (PresetAfter)7, Folder = (PresetFolder)8 },
                new ScanPreset { Id = null!, Name = "Second" },
                new ScanPreset { Id = "c", Name = "Custom", Folder = PresetFolder.Custom, FolderPath = null },
            ],
        };
        var list = ScanPresets.Normalize(stored);
        Assert.Equal(4, list.Count);
        Assert.Equal(list.Count, list.Select(p => p.Id).Distinct().Count());
        Assert.Equal("Scan preset", list[0].Name);
        Assert.Equal(1200, list[0].Resolution);
        Assert.Equal(1, list[0].NextNumber);
        Assert.Equal(ScanPresets.DefaultFileName, list[0].FileName);
        Assert.Equal("", list[0].Subfolder);
        Assert.Null(list[0].PageSize);
        Assert.Equal(PresetSource.Auto, list[1].Source);
        Assert.Equal(PresetFileType.Pdf, list[1].FileType);
        Assert.Equal(PresetAfter.None, list[1].After);
        Assert.Equal(PresetFolder.Documents, list[1].Folder);
        Assert.Equal("Second (2)", list[2].Name);
        Assert.Equal(PresetFolder.Documents, list[3].Folder); // a custom folder with no path
    }

    [Theory]
    [InlineData("receipt", true)]
    [InlineData("a1b2-C3", true)]
    [InlineData("x --autoprint out.txt", false)]
    [InlineData("a\"b", false)]
    [InlineData("tab\there", false)]
    [InlineData("", false)]
    public void IdsAreSafeOnACommandLine(string id, bool valid)
    {
        Assert.Equal(valid, ScanPresets.IsValidId(id));
        var list = ScanPresets.Normalize(new ScanPresetSettings { Items = [new ScanPreset { Id = id, Name = "P" }] });
        Assert.True(ScanPresets.IsValidId(list[0].Id));
        Assert.Equal(valid, list[0].Id == id);
    }

    [Fact]
    public void NewIdsAreValid()
    {
        var list = ScanPresets.BuiltIns().ToList();
        Assert.All(list, p => Assert.True(ScanPresets.IsValidId(p.Id)));
        Assert.True(ScanPresets.IsValidId(ScanPresets.Create(list).Id));
        Assert.True(ScanPresets.IsValidId(ScanPresets.Duplicate(list, list[0]).Id));
    }

    [Fact]
    public void ReservesEachNumberOnce()
    {
        var list = ScanPresets.BuiltIns().ToList();
        Assert.Equal(1, ScanPresets.Reserve(list, "receipt"));
        Assert.Equal(2, ScanPresets.Reserve(list, "receipt"));
        Assert.Equal(3, list[2].NextNumber);
        Assert.Equal(1, list[0].NextNumber);
        Assert.Null(ScanPresets.Reserve(list, "gone"));
    }

    [Fact]
    public void EditorSaveKeepsCountersThatMovedMeanwhile()
    {
        var current = ScanPresets.BuiltIns().Select(p => p with { NextNumber = p.Id == "receipt" ? 9 : p.NextNumber }).ToList();
        var edited = ScanPresets.BuiltIns().Select(p => p with { Name = p.Name + "!" }).ToList(); // opened when receipt was at 1
        var added = ScanPresets.Create(edited) with { NextNumber = 1 };
        edited.Add(added);
        var saved = ScanPresets.KeepCounters(edited, current);
        Assert.Equal(9, saved[2].NextNumber);
        Assert.Equal("Receipt!", saved[2].Name);
        Assert.Equal(1, saved[3].NextNumber);
    }

    [Fact]
    public void NewerFilesKeepWhatThisVersionDoesntKnow()
    {
        const string json = """{"Version":2,"Items":[{"Id":"receipt","Name":"Receipt","Cloud":{"x":1}}],"Sort":"name"}""";
        var stored = JsonSerializer.Deserialize<ScanPresetSettings>(json)!;
        Assert.True(stored.IsNewer);
        var back = JsonSerializer.Serialize(stored);
        Assert.Contains("\"Cloud\":{\"x\":1}", back);
        Assert.Contains("\"Sort\":\"name\"", back);
        Assert.Contains("\"Version\":2", back);
        // Repaired copies keep them too.
        Assert.NotNull(ScanPresets.Normalize(stored)[0].Unknown);
    }

    [Fact]
    public void RoundTripsThroughJson()
    {
        var settings = new ScanPresetSettings { Items = [.. ScanPresets.BuiltIns()] };
        var json = JsonSerializer.Serialize(settings);
        var back = JsonSerializer.Deserialize<ScanPresetSettings>(json)!;
        Assert.Equal(ScanPresets.CurrentVersion, back.Version);
        Assert.Equal(settings.Items, back.Items);
    }

    [Fact]
    public void OlderFilesWithoutPresetsGetTheBuiltIns()
    {
        var back = JsonSerializer.Deserialize<ScanPresetSettings>("""{"Version":0}""")!;
        Assert.Equal(3, ScanPresets.Normalize(back).Count);
    }

    [Fact]
    public void CreatesWithUniqueNames()
    {
        var list = ScanPresets.BuiltIns().ToList();
        var a = ScanPresets.Create(list);
        list.Add(a);
        var b = ScanPresets.Create(list);
        Assert.Equal("New preset", a.Name);
        Assert.Equal("New preset (2)", b.Name);
        Assert.NotEqual(a.Id, b.Id);
    }

    [Fact]
    public void DuplicatesUnderANewNameAndId()
    {
        var list = ScanPresets.BuiltIns().ToList();
        list[2] = list[2] with { NextNumber = 40 };
        var copy = ScanPresets.Duplicate(list, list[2]);
        Assert.Equal("Receipt copy", copy.Name);
        Assert.NotEqual(list[2].Id, copy.Id);
        Assert.Equal(1, copy.NextNumber); // its own counter
        Assert.Equal(list[2] with { Id = copy.Id, Name = copy.Name, NextNumber = 1 }, copy);
        list.Add(copy);
        Assert.Equal("Receipt copy (2)", ScanPresets.Duplicate(list, list[2]).Name);
    }

    [Theory]
    [InlineData("Invoices", null)]
    [InlineData("  ", "Give the preset a name.")]
    [InlineData("photo", "Another preset is already called \"Photo\".")]
    [InlineData(" Photo ", "Another preset is already called \"Photo\".")]
    public void ChecksNames(string name, string? problem)
    {
        var list = ScanPresets.BuiltIns();
        Assert.Equal(problem, ScanPresets.NameProblem(list, list[0].Id, name));
    }

    [Fact]
    public void RenamingToItsOwnNameIsFine()
    {
        var list = ScanPresets.BuiltIns();
        Assert.Null(ScanPresets.NameProblem(list, list[1].Id, "PHOTO"));
        Assert.Equal("Names can be up to 60 characters.", ScanPresets.NameProblem(list, list[1].Id, new string('a', 61)));
    }

    [Fact]
    public void Moves()
    {
        var list = ScanPresets.BuiltIns().ToList();
        Assert.True(ScanPresets.Move(list, 2, 0));
        Assert.Equal(["Receipt", "Document to PDF", "Photo"], list.Select(p => p.Name));
        Assert.False(ScanPresets.Move(list, 0, -1));
        Assert.False(ScanPresets.Move(list, 2, 3));
        Assert.False(ScanPresets.Move(list, 1, 1));
    }
}

public class PresetPlanTests
{
    private static InputCaps Input(params int[] dpi) =>
        new(0, 2550, 0, 3508, ["RGB24", "Grayscale8"], ["image/jpeg"], dpi, ["Document", "Photo"]);

    private static ScannerCapabilities Caps(bool glass = true, bool feeder = true, bool duplex = true, int[]? dpi = null) =>
        new("2.6", "Test", null, glass ? Input(dpi ?? [75, 150, 300, 600]) : null, feeder ? Input(dpi ?? [75, 150, 300]) with { MaxHeight = 4200 } : null, duplex);

    private static readonly ScanPreset Doc = ScanPresets.BuiltIns()[0];

    [Fact]
    public void AutoUsesTheFeederWhenItHasPages()
    {
        Assert.Equal(ScanSource.Adf, PresetPlan.For(Doc, Caps(), feederLoaded: true, ocrAvailable: true, metric: false).Request.Source);
        Assert.Equal(ScanSource.Platen, PresetPlan.For(Doc, Caps(), feederLoaded: false, ocrAvailable: true, metric: false).Request.Source);
        Assert.Equal(ScanSource.Platen, PresetPlan.For(Doc, Caps(), feederLoaded: null, ocrAvailable: true, metric: false).Request.Source);
        Assert.Equal(ScanSource.Adf, PresetPlan.For(Doc, Caps(glass: false), feederLoaded: null, ocrAvailable: true, metric: false).Request.Source);
    }

    [Fact]
    public void TwoSidedWhenTheFeederCan()
    {
        var p = Doc with { TwoSided = true, Source = PresetSource.Feeder };
        Assert.Equal(ScanSource.AdfDuplex, PresetPlan.For(p, Caps(), null, true, false).Request.Source);
        var simplex = PresetPlan.For(p, Caps(duplex: false), null, true, false);
        Assert.Equal(ScanSource.Adf, simplex.Request.Source);
        Assert.Contains("This scanner's feeder scans one side only.", simplex.Notes);
    }

    [Fact]
    public void FallsBackWhenTheSourceIsMissing()
    {
        var glassOnly = PresetPlan.For(Doc with { Source = PresetSource.Feeder }, Caps(feeder: false), null, true, false);
        Assert.Equal(ScanSource.Platen, glassOnly.Request.Source);
        Assert.Contains("This scanner has no document feeder: scanning from the glass.", glassOnly.Notes);
        var feederOnly = PresetPlan.For(Doc with { Source = PresetSource.Glass }, Caps(glass: false), null, true, false);
        Assert.Equal(ScanSource.Adf, feederOnly.Request.Source);
        Assert.Contains("This scanner has no glass: scanning from the document feeder.", feederOnly.Notes);
    }

    [Fact]
    public void PicksTheClosestResolutionAndSize()
    {
        var plan = PresetPlan.For(Doc with { Resolution = 200, Source = PresetSource.Glass, PageSize = null }, Caps(dpi: [100, 300]), null, true, metric: true);
        Assert.Equal(300, plan.Request.Resolution);
        Assert.Equal(2480, plan.Request.Width); // A4 by region
        var legal = PresetPlan.For(Doc with { Source = PresetSource.Glass, PageSize = "legal" }, Caps(), null, true, false);
        Assert.Equal(2550, legal.Request.Width); // glass is A4-long only: falls back to Letter
        Assert.Contains("Legal (8.5 × 14 in) doesn't fit this source: scanning Letter (8.5 × 11 in).", legal.Notes);
        var whole = PresetPlan.For(Doc with { PageSize = "full" }, Caps(), null, true, false);
        Assert.Null(whole.Request.Width);
    }

    [Fact]
    public void GreyWhenColorIsOff()
    {
        Assert.Equal(ScanColor.Grayscale, PresetPlan.For(Doc with { Color = false }, Caps(), null, true, false).Request.Color);
        Assert.Equal(ScanColor.Color, PresetPlan.For(Doc with { Color = true }, Caps(), null, true, false).Request.Color);
    }

    [Fact]
    public void SearchableOnlyWithOcr()
    {
        var p = Doc with { FileType = PresetFileType.SearchablePdf };
        Assert.True(PresetPlan.For(p, Caps(), null, ocrAvailable: true, false).Ocr);
        var none = PresetPlan.For(p, Caps(), null, ocrAvailable: false, false);
        Assert.False(none.Ocr);
        Assert.Contains("Text recognition isn't available on this PC: the PDF won't be searchable.", none.Notes);
        Assert.False(PresetPlan.For(Doc with { FileType = PresetFileType.Pdf }, Caps(), null, true, false).Ocr);
        Assert.False(PresetPlan.For(Doc with { FileType = PresetFileType.Jpeg }, Caps(), null, true, false).Ocr);
    }
}

public class SyncFolderTests
{
    [Fact]
    public void FindsOneDriveAndDropbox()
    {
        var dirs = new HashSet<string>(StringComparer.OrdinalIgnoreCase) { @"C:\Users\ana\OneDrive", @"C:\Users\ana\OneDrive - Contoso", @"C:\Users\ana\Dropbox" };
        const string info = """{"personal": {"path": "C:\\Users\\ana\\Dropbox", "host": 123, "is_team": false, "subscription_type": "Basic"}}""";
        var found = SyncFolders.Find(
            oneDrive: [@"C:\Users\ana\OneDrive", @"C:\Users\ana\OneDrive\", @"C:\Users\ana\OneDrive - Contoso", null, "", @"C:\Users\ana\Gone"],
            dropboxInfo: [info, null],
            dirs.Contains);
        Assert.Equal(
            [new SyncFolder("OneDrive", @"C:\Users\ana\OneDrive"), new SyncFolder("OneDrive - Contoso", @"C:\Users\ana\OneDrive - Contoso"), new SyncFolder("Dropbox", @"C:\Users\ana\Dropbox")],
            found);
    }

    [Fact]
    public void ReadsBothDropboxAccounts()
    {
        const string info = """{"personal": {"path": "D:\\Dropbox (Personal)"}, "business": {"path": "D:\\Dropbox (Contoso)"}}""";
        var found = SyncFolders.Find([], [info], _ => true);
        Assert.Equal(["Dropbox (Personal)", "Dropbox (Contoso)"], found.Select(f => f.Name));
    }

    [Theory]
    [InlineData("not json")]
    [InlineData("[]")]
    [InlineData("""{"personal": "x"}""")]
    [InlineData("""{"personal": {"path": 5}}""")]
    [InlineData("""{"personal": {"path": "relative\\Dropbox"}}""")]
    public void IgnoresBrokenDropboxInfo(string info) => Assert.Empty(SyncFolders.Find([], [info], _ => true));
}

public class ScanPresetTextTests
{
    [Fact]
    public void Summaries()
    {
        var list = ScanPresets.BuiltIns();
        Assert.Equal(@"Searchable PDF · feeder or glass · grey, 300 dpi · Documents\Scans", ScanPresetText.Summary(list[0]));
        Assert.Equal(@"JPEG images · glass · color, 600 dpi · Pictures\Scans · review first", ScanPresetText.Summary(list[1]));
        var mail = list[2] with { Folder = PresetFolder.Custom, FolderPath = @"C:\Users\ana\OneDrive\", Subfolder = "", After = PresetAfter.Email };
        Assert.Equal("Searchable PDF · glass · grey, 300 dpi · OneDrive · then email it", ScanPresetText.Summary(mail));
    }
}
