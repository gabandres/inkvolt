using System.Buffers.Binary;
using System.Diagnostics;
using System.Text.RegularExpressions;
using InkvoltPrint.Core.Suite;

namespace InkvoltPrint.Tests;

/// <summary>
/// Windows 10 and small screens (the Store packages allow Windows 10 2004 and later): the build decisions, keeping a window
/// on its screen, every icon glyph in Segoe MDL2 Assets (Windows 10 has no Segoe Fluent Icons), and Print in sight at the
/// window's smallest size.
/// </summary>
public class WindowsLookTests
{
    [Theory]
    [InlineData(19041, false, false, true)] // Windows 10 2004, the Store minimum
    [InlineData(19045, false, false, true)] // Windows 10 22H2
    [InlineData(22000, true, false, true)]  // Windows 11 21H2: no Mica yet
    [InlineData(22621, true, true, true)]   // Windows 11 22H2
    [InlineData(26100, true, true, true)]
    [InlineData(18363, false, false, false)] // 1909: no dark title bar attribute
    public void DecidesFromTheBuild(int build, bool windows11, bool mica, bool darkTitle)
    {
        Assert.Equal(windows11, WindowsLook.IsWindows11(build));
        Assert.Equal(mica, WindowsLook.HasMica(build));
        Assert.Equal(darkTitle, WindowsLook.HasDarkTitleBar(build));
        Assert.Equal(windows11 ? "Segoe Fluent Icons, Segoe MDL2 Assets" : "Segoe MDL2 Assets", WindowsLook.IconFont(build));
    }

    [Theory]
    [InlineData(26300, null, 26300)]
    [InlineData(26300, "", 26300)]
    [InlineData(26300, "0", 26300)]
    [InlineData(26300, "1", 19045)]
    [InlineData(26300, " TRUE ", 19045)]
    [InlineData(26300, "yes", 19045)]
    [InlineData(19041, "1", 19041)] // already older: stays
    public void FakesWindows10OnlyWhenAsked(int real, string? fake, int expected) => Assert.Equal(expected, WindowsLook.Effective(real, fake));

    private static readonly ScreenRect Laptop125 = new(0, 0, 1092, 582); // 1366 × 768 at 125 %, without the taskbar

    [Fact]
    public void ABigWindowCentredOnASmallScreenGetsItsTitleBarBack()
    {
        // What WPF's CenterScreen did with 1180 × 800 there: title bar 109 DIPs above the top, 44 DIPs off each side.
        var centred = new ScreenRect((1092 - 1180) / 2.0, (582 - 800) / 2.0, 1180, 800);
        Assert.False(Laptop125.Contains(centred));
        var fit = ScreenFit.Fit(centred, Laptop125);
        Assert.Equal(new ScreenRect(0, 0, 1092, 582), fit);
        Assert.True(Laptop125.Contains(fit));
    }

    [Fact]
    public void AWindowThatFitsStaysPut()
    {
        var window = new ScreenRect(100, 50, 800, 500);
        Assert.Equal(window, ScreenFit.Fit(window, Laptop125));
        Assert.True(Laptop125.Contains(window));
    }

    [Fact]
    public void AWindowPartlyOffMovesTheLeastItTakes()
    {
        Assert.Equal(new ScreenRect(292, 82, 800, 500), ScreenFit.Fit(new ScreenRect(600, 300, 800, 500), Laptop125));
        Assert.Equal(new ScreenRect(0, 0, 800, 500), ScreenFit.Fit(new ScreenRect(-300, -40, 800, 500), Laptop125));
        // A second monitor to the left (negative coordinates) keeps its own origin.
        var left = new ScreenRect(-1920, 0, 1920, 1040);
        Assert.Equal(new ScreenRect(-1920, 0, 1180, 800), ScreenFit.Fit(new ScreenRect(-2000, -20, 1180, 800), left));
    }

    [Fact]
    public void CentresAndShrinksAndCapsTheMinimum()
    {
        Assert.Equal(new ScreenRect(0, 0, 1092, 582), ScreenFit.Centre(1180, 800, Laptop125));
        Assert.Equal(new ScreenRect(146, 41, 800, 500), ScreenFit.Centre(800, 500, Laptop125));
        Assert.Equal(560, ScreenFit.Minimum(560, 582));
        Assert.Equal(544, ScreenFit.Minimum(560, 544)); // 1280 × 720 at 125 %: the minimum height no taller than the screen
        Assert.Equal(0, ScreenFit.Minimum(560, -5));
    }

    [Fact]
    public void PicksTheMonitorItMostlyLiesOn()
    {
        var main = new ScreenRect(0, 0, 1920, 1040);
        var right = new ScreenRect(1920, 0, 1092, 582);
        Assert.Equal(right, ScreenFit.Best(new ScreenRect(1800, 100, 1000, 400), [main, right]));
        Assert.Equal(main, ScreenFit.Best(new ScreenRect(1000, 100, 1000, 400), [main, right]));
        Assert.Equal(right, ScreenFit.Best(new ScreenRect(4000, 100, 300, 300), [main, right])); // on none: the nearest
        Assert.Null(ScreenFit.Best(new ScreenRect(0, 0, 10, 10), []));
    }

    [Theory]
    [InlineData("1092x582", 1092.0, 582.0)]
    [InlineData("1024 X 576", 1024.0, 576.0)]
    [InlineData("1280×720", 1280.0, 720.0)]
    public void ReadsAFakeWorkArea(string text, double width, double height) => Assert.Equal((width, height), ScreenFit.ParseSize(text));

    [Theory]
    [InlineData(null)]
    [InlineData("")]
    [InlineData("1092")]
    [InlineData("0x582")]
    [InlineData("ax582")]
    [InlineData("1x2x3")]
    public void RefusesAnythingElse(string? text) => Assert.Null(ScreenFit.ParseSize(text));

    // ── Icons ──

    private static string Root()
    {
        var dir = new DirectoryInfo(AppContext.BaseDirectory);
        while (dir is not null && !File.Exists(Path.Combine(dir.FullName, "Inkvolt.slnx"))) dir = dir.Parent;
        return dir!.FullName;
    }

    /// <summary>Every private-use code point in the apps' XAML and C# (&amp;#xE749; in XAML,  or the character itself in C#).</summary>
    private static SortedDictionary<int, string> GlyphsUsed()
    {
        var used = new SortedDictionary<int, string>();
        var root = Root();
        foreach (var folder in new[] { "print/src/InkvoltPrint.App", "pdf/src/InkvoltPdf.App", "shared/InkvoltPrint.Core/Suite" })
        foreach (var file in Directory.EnumerateFiles(Path.Combine(root, folder), "*.*", SearchOption.AllDirectories))
        {
            if (!(file.EndsWith(".xaml") || file.EndsWith(".cs")) || file.Contains($"{Path.DirectorySeparatorChar}obj{Path.DirectorySeparatorChar}")
                || file.Contains($"{Path.DirectorySeparatorChar}bin{Path.DirectorySeparatorChar}") || file.EndsWith("UiAudit.cs")) continue;
            var text = File.ReadAllText(file);
            var codes = Regex.Matches(text, "&#x([0-9A-Fa-f]{4});").Select(m => Convert.ToInt32(m.Groups[1].Value, 16))
                .Concat(Regex.Matches(text, @"\\u([0-9A-Fa-f]{4})").Select(m => Convert.ToInt32(m.Groups[1].Value, 16)))
                .Concat(text.Where(c => c is >= '' and <= '').Select(c => (int)c));
            foreach (var code in codes.Where(c => c is >= 0xE000 and <= 0xF8FF)) used.TryAdd(code, Path.GetRelativePath(root, file));
        }
        return used;
    }

    [Fact]
    public void EveryIconGlyphIsInSegoeMdl2Assets()
    {
        var used = GlyphsUsed();
        Assert.True(used.Count > 50, $"only {used.Count} glyphs found: the scan is broken");
        var font = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Fonts), "segmdl2.ttf");
        if (!File.Exists(font)) return; // not on this machine (CI images without the font): nothing to check against
        var mdl2 = CmapCodePoints(File.ReadAllBytes(font));
        var missing = used.Where(u => !mdl2.Contains(u.Key)).Select(u => $"U+{u.Key:X4} ({u.Value})").ToList();
        Assert.True(missing.Count == 0, "Not in Segoe MDL2 Assets, so blank on Windows 10: " + string.Join(", ", missing));
    }

    /// <summary>The code points a TrueType font maps (its Windows Unicode BMP cmap, format 4).</summary>
    private static HashSet<int> CmapCodePoints(byte[] ttf)
    {
        ushort U16(int at) => BinaryPrimitives.ReadUInt16BigEndian(ttf.AsSpan(at));
        uint U32(int at) => BinaryPrimitives.ReadUInt32BigEndian(ttf.AsSpan(at));
        var tables = U16(4);
        var cmap = Enumerable.Range(0, tables).Select(i => 12 + 16 * i).Where(r => System.Text.Encoding.ASCII.GetString(ttf, r, 4) == "cmap")
            .Select(r => (int)U32(r + 8)).Single();
        var sub = Enumerable.Range(0, U16(cmap + 2)).Select(i => cmap + 4 + 8 * i)
            .Where(r => U16(r) == 3 && U16(r + 2) == 1).Select(r => cmap + (int)U32(r + 4)).First();
        Assert.Equal(4, U16(sub));
        var segs = U16(sub + 6) / 2;
        var (ends, starts, deltas, offsets) = (sub + 14, sub + 16 + 2 * segs, sub + 16 + 4 * segs, sub + 16 + 6 * segs);
        var codes = new HashSet<int>();
        for (var s = 0; s < segs; s++)
        {
            int start = U16(starts + 2 * s), end = U16(ends + 2 * s), delta = (short)U16(deltas + 2 * s), offset = U16(offsets + 2 * s);
            for (var c = start; c <= end && c != 0xFFFF; c++)
            {
                var glyph = offset == 0 ? (c + delta) & 0xFFFF : U16(offsets + 2 * s + offset + 2 * (c - start)) is var g and > 0 ? (g + delta) & 0xFFFF : 0;
                if (glyph != 0) codes.Add(c);
            }
        }
        return codes;
    }

    // ── Print in sight ──

    private static string Exe()
    {
        // ...\print\tests\InkvoltPrint.Tests\bin\<config>\net10.0\ to ...\print\src\InkvoltPrint.App\bin\<config>\<windows framework>\
        var output = new DirectoryInfo(AppContext.BaseDirectory.TrimEnd(Path.DirectorySeparatorChar));
        var print = output.Parent!.Parent!.Parent!.Parent!.Parent!.FullName;
        // The build in the framework's folder itself: pack-msix.ps1 leaves win-x64 and win-arm64 copies under it.
        return Directory.GetDirectories(Path.Combine(print, "src", "InkvoltPrint.App", "bin", output.Parent!.Name)).Select(d => Path.Combine(d, "InkvoltPrint.exe")).Where(File.Exists).Single();
    }

    /// <summary>
    /// The real app (demo printers): a PDF opened in Print (as Choose a PDF… does) at the window's smallest size and at a
    /// small laptop's, as on Windows 11 and as on Windows 10 with a larger Text size; the Print button must be whole, in sight
    /// and pressable. On the older PC it sat below the options, cut off, with no way to scroll to it.
    /// </summary>
    [Theory]
    [InlineData(860, 560, false, null)]
    [InlineData(1024, 576, true, null)]
    [InlineData(860, 560, true, "1.25")]
    public async Task PrintIsInSightAtSmallSizes(int width, int height, bool windows10, string? textScale)
    {
        var report = Path.Combine(Path.GetTempPath(), $"inkvolt-press-print-{Guid.NewGuid():N}.txt");
        var start = new ProcessStartInfo(Exe()) { UseShellExecute = false };
        foreach (var a in new[] { "--demo", "--sample-pdf", "--printer", "2", "--size", $"{width}", $"{height}", "--press-print", report })
            start.ArgumentList.Add(a);
        start.Environment[WindowsLook.FakeWindows10Variable] = windows10 ? "1" : "";
        start.Environment["INKVOLT_TEXTSCALE"] = textScale ?? "";
        using var process = Process.Start(start)!;
        using var limit = new CancellationTokenSource(TimeSpan.FromMinutes(2));
        try
        {
            await process.WaitForExitAsync(limit.Token);
        }
        catch (OperationCanceledException)
        {
            process.Kill();
            throw;
        }
        try
        {
            var lines = File.ReadAllText(report);
            Assert.Contains("print button: in sight", lines);
            Assert.Contains("pressed: ", lines); // the press reached the command (the demo printer has no Windows queue to print to)
        }
        finally
        {
            File.Delete(report);
        }
    }
}
