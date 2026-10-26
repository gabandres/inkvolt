using InkvoltPrint.Core.Suite;

namespace InkvoltPrint.Tests;

/// <summary>Help in both apps: the diagnostics a user copies into a report (scrubbed), and What's New after an update.</summary>
public class HelpTests
{
    private static readonly Diagnostics.Identity Me = new("jdoe", "JDOE-LAPTOP");

    [Theory]
    [InlineData("Connected to 192.168.1.23:631", "Connected to [ip]:631")]
    [InlineData("ipps://192.0.2.10/ipp/print failed", "ipps://[host]/ipp/print failed")]
    [InlineData("GET http://HPF0A1B2.local:8080/eSCL/ScannerStatus", "GET http://[host]:8080/eSCL/ScannerStatus")]
    [InlineData("resolved NPI1A2B3C.local", "resolved [host].local")]
    [InlineData("printer 12345678-1234-4abc-8def-123456789abc added", "printer [uuid] added")]
    [InlineData("urn:uuid:12345678-1234-4ABC-8DEF-123456789ABC", "urn:uuid:[uuid]")]
    [InlineData("MAC a0:b1:c2:d3:e4:f5 seen", "MAC [mac] seen")]
    [InlineData("fe80::1c2b:3a4d:5e6f:7a8b%12 answered", "[ip] answered")]
    [InlineData("Serial number: CNB9K12345", "Serial number: [serial]")]
    [InlineData("SNMP device TH12A3B456 matched", "SNMP device [id] matched")]
    [InlineData("HP OfficeJet Pro 9010 series [A1B2C3]", "HP OfficeJet Pro 9010 series [id]")]
    [InlineData("pin 9F86D081884C7D659A2FEAA0C55AD015A3BF4F1B2B0B822CD15D6C15B0F00A08", "pin [hex]")]
    [InlineData("mail from jane.doe@example.com", "mail from [email]")]
    [InlineData(@"Saved C:\Users\jdoe\Documents\Taxes 2026\return.pdf", @"Saved [path].pdf")]
    [InlineData(@"Opened \\nas\share\scan.jpg", @"Opened [path].jpg")]
    [InlineData(@"Inkvolt Print started (C:\Program Files (x86)\Inkvolt\InkvoltPrint.exe)", "Inkvolt Print started ([path].exe)")]
    [InlineData(@"tried C:\Scans\a.pdf, C:\Scans\b.pdf; gave up", "tried [path].pdf, [path].pdf; gave up")]
    [InlineData(@"at InkvoltPdf.App.MainWindow.OnSave() in Z:\PdfDesk\pdf\src\MainWindow.xaml.cs:line 12", @"at InkvoltPdf.App.MainWindow.OnSave() in [path].cs:line 12")]
    [InlineData("Logged in as JDoe on jdoe-laptop", "Logged in as [user] on [pc]")]
    public void Scrub_masks_what_identifies_a_person_a_printer_or_a_network(string line, string expected) =>
        Assert.Equal(expected, Diagnostics.Scrub(line, Me));

    [Theory]
    [InlineData("12:34:56.789 Scan finished in 4.2 s")]
    [InlineData("HRESULT 0x8007000E (out of memory)")]
    [InlineData("HP LaserJet MFP M234dw: toner 42 %")]
    [InlineData("System.IO.IOException: The process cannot access the file")]
    [InlineData("eSCL 2.63, 300 dpi, A4")]
    public void Scrub_keeps_what_helps_find_the_problem(string line) => Assert.Equal(line, Diagnostics.Scrub(line, Me));

    [Fact]
    public void Report_has_the_app_windows_settings_and_the_scrubbed_log_tail()
    {
        var report = Diagnostics.Report(
            app: "Inkvolt Print", version: "1.0.3", windows: "Microsoft Windows 10.0.26300", architecture: "Arm64",
            packaged: true, settings: [("Theme", "Dark"), ("Scan folder", @"C:\Users\jdoe\Scans")],
            logTail: ["2026-10-25 10:00:00.000 Connected to 192.168.1.23", "2026-10-25 10:00:01.000 Ready"], who: Me);

        Assert.Contains("Inkvolt Print 1.0.3 (Store package)", report);
        Assert.Contains("Windows: Microsoft Windows 10.0.26300, Arm64", report);
        Assert.Contains("Theme: Dark", report);
        Assert.Contains("Scan folder: [path]", report);
        Assert.Contains("Connected to [ip]", report);
        Assert.Contains("Ready", report);
        Assert.DoesNotContain("jdoe", report, StringComparison.OrdinalIgnoreCase);
        Assert.DoesNotContain("192.168", report);
    }

    [Fact]
    public void Report_says_when_there_is_no_log()
    {
        var report = Diagnostics.Report("Inkvolt PDF", "1.0.3", "Windows", "X64", false, [], [], Me);

        Assert.Contains("Inkvolt PDF 1.0.3", report);
        Assert.DoesNotContain("Store package", report);
        Assert.Contains("(no log yet)", report);
    }

    [Fact]
    public void Tail_reads_the_last_lines_of_a_log_another_writer_holds_open()
    {
        var path = Path.Combine(Path.GetTempPath(), $"inkvolt-tail-{Guid.NewGuid():N}.log");
        try
        {
            File.WriteAllLines(path, Enumerable.Range(1, 500).Select(i => $"line {i}"));
            using var writer = new FileStream(path, FileMode.Open, FileAccess.ReadWrite, FileShare.ReadWrite);

            var tail = Diagnostics.Tail(path, 3);

            Assert.Equal(["line 498", "line 499", "line 500"], tail);
        }
        finally
        {
            File.Delete(path);
        }
    }

    [Fact]
    public void Tail_of_a_missing_log_is_empty() => Assert.Empty(Diagnostics.Tail(Path.Combine(Path.GetTempPath(), $"none-{Guid.NewGuid():N}.log"), 10));

    [Fact]
    public void Issue_url_prefills_a_github_issue_without_the_log()
    {
        var url = Diagnostics.IssueUrl("https://github.com/gabandres/inkvolt", "Inkvolt Print", "1.0.3", "Microsoft Windows 10.0.26300");

        Assert.StartsWith("https://github.com/gabandres/inkvolt/issues/new?title=", url);
        var body = Uri.UnescapeDataString(url[(url.IndexOf("&body=", StringComparison.Ordinal) + 6)..]);
        Assert.Contains("Inkvolt Print 1.0.3", body);
        Assert.Contains("Microsoft Windows 10.0.26300", body);
        Assert.Contains("paste", body, StringComparison.OrdinalIgnoreCase);
        Assert.True(url.Length < 2000);
    }

    private const string Notes = """
        # What's new in Inkvolt Print

        ## Next
        - Not released yet, never shown.

        ## 1.1.0
        - Settings in one place.
        - Report a problem copies the details
          a report needs.

        ## 1.0.3
        - Printers set up in Windows show up too.

        ## 1.0.2
        - Older printers over SNMP.
        """;

    [Fact]
    public void Parse_reads_versions_newest_first_with_their_items_and_skips_unreleased()
    {
        var notes = ReleaseNotes.Parse(Notes);

        Assert.Equal(["1.1.0", "1.0.3", "1.0.2"], notes.Select(n => n.Version.ToString()));
        Assert.Equal(["Settings in one place.", "Report a problem copies the details a report needs."], notes[0].Items);
    }

    [Theory]
    [InlineData("1.0.2", "1.1.0", false, "1.1.0,1.0.3")] // updated over two versions: both
    [InlineData("1.0.3", "1.1.0", false, "1.1.0")]
    [InlineData("1.1.0", "1.1.0", false, "")] // already seen
    [InlineData("1.2.0", "1.1.0", false, "")] // went back a version
    [InlineData(null, "1.1.0", true, "")] // a new install: nothing new to it
    [InlineData(null, "1.1.0", false, "1.1.0")] // updated from a version that didn't keep track: this one's notes
    [InlineData("garbage", "1.1.0", false, "1.1.0")]
    [InlineData("1.0.3.0", "1.1.0.0", false, "1.1.0")] // package versions have a fourth number
    [InlineData("1.0.3", "1.0.4", false, "")] // no notes written for it
    public void Since_shows_each_update_once(string? lastSeen, string current, bool newInstall, string expected)
    {
        var shown = ReleaseNotes.Since(ReleaseNotes.Parse(Notes), lastSeen, Version.Parse(current), newInstall);

        Assert.Equal(expected, string.Join(",", shown.Select(n => n.Version.ToString())));
    }

    [Fact]
    public void Format_lists_each_version_with_its_items()
    {
        var text = ReleaseNotes.Format(ReleaseNotes.Parse(Notes).Take(2));

        Assert.Equal("Version 1.1.0\n• Settings in one place.\n• Report a problem copies the details a report needs.\n\nVersion 1.0.3\n• Printers set up in Windows show up too.",
            text.ReplaceLineEndings("\n"));
    }
}
