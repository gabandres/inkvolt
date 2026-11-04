using System.Diagnostics;
using InkvoltPrint.Core.Printing;

namespace InkvoltPrint.Tests;

/// <summary>
/// The roadmap's test for 2.4: the built app's own command line (<c>InkvoltPrint.exe print --demo</c>), real files through Windows' real PDF
/// engine and WIC, every page drawn, to the demo queue. The test project can't load the app's WPF and WinRT parts, so it runs the
/// exe, which it builds first (the project reference in its csproj).
/// </summary>
public class BatchPrintEndToEndTests
{
    private const string Printer = "Demo printer", Password = "open sesame";

    private static string Exe()
    {
        // ...\print\tests\InkvoltPrint.Tests\bin\<config>\net10.0\ to ...\print\src\InkvoltPrint.App\bin\<config>\<windows framework>\
        var output = new DirectoryInfo(AppContext.BaseDirectory.TrimEnd(Path.DirectorySeparatorChar));
        var config = output.Parent!.Name;
        var print = output.Parent!.Parent!.Parent!.Parent!.Parent!.FullName;
        // The build in the framework's folder itself: pack-msix.ps1 leaves win-x64 and win-arm64 copies under it.
        return Directory.GetDirectories(Path.Combine(print, "src", "InkvoltPrint.App", "bin", config)).Select(d => Path.Combine(d, "InkvoltPrint.exe")).Where(File.Exists).Single();
    }

    private static async Task<(int Code, string Out, string Err)> Run(string? password, params string[] args)
    {
        var start = new ProcessStartInfo(Exe())
        {
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            UseShellExecute = false,
            CreateNoWindow = true,
            StandardOutputEncoding = System.Text.Encoding.UTF8,
            StandardErrorEncoding = System.Text.Encoding.UTF8,
        };
        foreach (var a in args) start.ArgumentList.Add(a);
        start.Environment.Remove(BatchPrintCommandLine.PasswordVariable);
        if (password is not null) start.Environment[BatchPrintCommandLine.PasswordVariable] = password;
        using var process = Process.Start(start)!;
        var (output, error) = (process.StandardOutput.ReadToEndAsync(), process.StandardError.ReadToEndAsync());
        using var limit = new CancellationTokenSource(TimeSpan.FromMinutes(4));
        try
        {
            await process.WaitForExitAsync(limit.Token);
        }
        catch (OperationCanceledException)
        {
            process.Kill();
            throw;
        }
        return (process.ExitCode, await output, await error);
    }

    /// <summary>
    /// 50 real files in a list: PDFs of 1 to 7 pages, JPEGs, PNGs, two-page TIFFs, one locked PDF, with copies, ranges, sides and papers.
    /// Returns the list's path and each file's expected sheets.
    /// </summary>
    private static (string List, List<(string Name, int Sheets)> Expected) Fifty(BatchFolder f)
    {
        var entries = new List<BatchListEntry>();
        var expected = new List<(string, int)>();
        for (var i = 0; i < 50; i++)
        {
            var copies = 1 + i % 3;
            var twoSided = i % 4 == 0;
            var paper = i % 5 == 0 ? "ISOA4" : null;
            string name;
            byte[] bytes;
            int pages;
            string? range = null;
            if (i == 25)
            {
                (name, bytes, pages) = ("locked.pdf", BatchPrintSamples.Pdf(3, "Locked", Password), 3);
            }
            else
            {
                switch (i % 4)
                {
                    case 0:
                        pages = 1 + i % 7;
                        (name, bytes) = ($"{i:00} document.pdf", BatchPrintSamples.Pdf(pages, $"Document {i}"));
                        if (pages > 2)
                        {
                            range = "2-3";
                            pages = 2;
                        }
                        break;
                    case 1:
                        (name, bytes, pages) = ($"{i:00} photo.jpg", BatchPrintSamples.Jpeg(160, 200), 1);
                        break;
                    case 2:
                        (name, bytes, pages) = ($"{i:00} drawing.png", BatchPrintSamples.Png(120, 80), 1);
                        break;
                    default:
                        (name, bytes, pages) = ($"{i:00} scan.tif", BatchPrintSamples.Tiff(2, 50, 50), 2);
                        break;
                }
            }
            var path = Path.Combine(f.Root, name);
            File.WriteAllBytes(path, bytes);
            entries.Add(new BatchListEntry(path, new BatchPrintSettings(copies, range, twoSided, paper)));
            expected.Add((name, BatchPrintSettings.Sheets(pages, copies, twoSided)));
        }
        var list = Path.Combine(f.Root, "fifty" + BatchPrintList.Extension);
        BatchPrintList.Save(list, entries);
        return (list, expected);
    }

    private static List<(string Name, string Result, int Estimated, int Sent)> ReadReport(string path) =>
        File.ReadAllLines(path).Skip(1).Select(line =>
        {
            var cells = line.Split(',');
            return (cells[1], cells[3], int.Parse(cells[^3]), int.Parse(cells[^2]));
        }).ToList();

    [Fact]
    public async Task Fifty_real_files_print_to_the_demo_queue_in_order_with_the_estimated_sheet_count()
    {
        if (!OperatingSystem.IsWindows()) return;
        using var f = new BatchFolder();
        var (list, expected) = Fifty(f);
        var report = Path.Combine(f.Root, "results.csv");

        var (code, output, error) = await Run(Password, "print", "--list", list, "--printer", Printer, "--report", report, "--demo");

        Assert.True(code == BatchPrintSummary.Done, $"exit {code}\n{output}\n{error}");
        var results = ReadReport(report);
        Assert.Equal(expected.Select(e => e.Name), results.Select(r => r.Name));
        Assert.All(results, r => Assert.Equal("Sent", r.Result));
        Assert.Equal(expected.Select(e => e.Sheets), results.Select(r => r.Sent));
        Assert.Equal(expected.Select(e => e.Sheets), results.Select(r => r.Estimated));

        // Sent one by one in the list's order, not just listed in it.
        var sentLines = output.Split('\n').Where(l => l.Contains("] sent ", StringComparison.Ordinal)).ToList();
        Assert.Equal(50, sentLines.Count);
        for (var i = 0; i < 50; i++) Assert.Contains($"[{i + 1}/50] sent     {expected[i].Name}:", sentLines[i]);
        Assert.Contains($"50 sent ({expected.Sum(e => e.Sheets)} sheets).", output);
    }

    [Fact]
    public async Task Without_its_password_the_locked_pdf_is_skipped_and_exit_1_with_a_wrong_one_too()
    {
        if (!OperatingSystem.IsWindows()) return;
        using var f = new BatchFolder();
        var locked = Path.Combine(f.Root, "locked.pdf");
        File.WriteAllBytes(locked, BatchPrintSamples.Pdf(3, "Locked", Password));
        var open = Path.Combine(f.Root, "open.pdf");
        File.WriteAllBytes(open, BatchPrintSamples.Pdf(2, "Open"));

        var none = await Run(null, "print", locked, open, "--printer", Printer, "--demo");
        Assert.True(none.Code == BatchPrintSummary.SomeFailed, $"exit {none.Code}\n{none.Out}\n{none.Err}");
        Assert.Contains("needs a password", none.Err);
        Assert.Contains("1 sent (2 sheets), 1 skipped.", none.Out);

        var wrong = await Run("wrong", "print", locked, open, "--printer", Printer, "--demo");
        Assert.Equal(BatchPrintSummary.SomeFailed, wrong.Code);
        Assert.Contains("doesn't open", wrong.Err);
        Assert.DoesNotContain("wrong", wrong.Out);

        var right = await Run(Password, "print", locked, open, "--printer", Printer, "--demo");
        Assert.True(right.Code == BatchPrintSummary.Done, $"exit {right.Code}\n{right.Out}\n{right.Err}");
        Assert.Contains("2 sent (5 sheets).", right.Out);
        Assert.DoesNotContain(Password, right.Out + right.Err);
    }

    [Fact]
    public async Task Damaged_and_disguised_files_and_a_picture_claiming_a_huge_size_are_left_out_without_ending_the_batch()
    {
        if (!OperatingSystem.IsWindows()) return;
        using var f = new BatchFolder();
        void Write(string name, byte[] bytes) => File.WriteAllBytes(Path.Combine(f.Root, name), bytes);
        Write("1 not a pdf.pdf", "this is no PDF at all"u8.ToArray());
        Write("2 not a picture.jpg", "this is no JPEG at all"u8.ToArray());
        Write("3 truncated.pdf", BatchPrintSamples.Pdf(2, "Cut")[..40]);
        // A file of a few bytes whose header, with a right checksum, claims 40,000 × 40,000 pixels.
        var huge = BatchPrintSamples.Png(1, 1);
        System.Buffers.Binary.BinaryPrimitives.WriteInt32BigEndian(huge.AsSpan(16), 40_000);
        System.Buffers.Binary.BinaryPrimitives.WriteInt32BigEndian(huge.AsSpan(20), 40_000);
        System.Buffers.Binary.BinaryPrimitives.WriteUInt32BigEndian(huge.AsSpan(29), BatchPrintSamples.Crc32(huge.AsSpan(12, 17)));
        Write("4 huge.png", huge);
        Write("5 good.pdf", BatchPrintSamples.Pdf(1, "Good"));
        Write("6 really a pdf.jpg", BatchPrintSamples.Pdf(2, "Disguised")); // what it is decides, not its name

        var (code, output, error) = await Run(null, "print", f.Root, "--printer", Printer, "--demo");

        Assert.True(code == BatchPrintSummary.SomeFailed, $"exit {code}\n{output}\n{error}");
        Assert.Contains("2 sent (3 sheets), 4 skipped.", output);
        foreach (var name in new[] { "1 not a pdf.pdf", "2 not a picture.jpg", "3 truncated.pdf", "4 huge.png" }) Assert.Contains($"left out {name}", error);
        Assert.Contains("too large", error); // refused by its header's size, before any pixel
    }

    [Fact]
    public async Task A_wrong_command_line_or_printer_exits_2_and_a_print_to_pdf_queue_name_cant_reach_the_demo()
    {
        if (!OperatingSystem.IsWindows()) return;
        Assert.Equal(BatchPrintSummary.Wrong, (await Run(null, "print", "--demo")).Code);
        using var f = new BatchFolder();
        var a = f.File("a.pdf", "x");
        var nobody = await Run(null, "print", a, "--printer", "Nobody", "--demo");
        Assert.Equal(BatchPrintSummary.Wrong, nobody.Code);
        Assert.Contains("no demo printer", nobody.Err);
        Assert.Equal(BatchPrintSummary.Done, (await Run(null, "print", "--help")).Code);
    }

    [Fact]
    public async Task A_name_in_any_script_reaches_a_script_whole_and_a_formula_stays_words_in_the_report()
    {
        if (!OperatingSystem.IsWindows()) return;
        using var f = new BatchFolder();
        const string name = "=Résumé 東京 1+1.pdf";
        var path = Path.Combine(f.Root, name);
        File.WriteAllBytes(path, BatchPrintSamples.Pdf(1, "Name"));
        var report = Path.Combine(f.Root, "results.csv");
        var (code, output, error) = await Run(null, "print", path, "--printer", Printer, "--report", report, "--demo");
        Assert.True(code == BatchPrintSummary.Done, $"exit {code}\n{output}\n{error}");
        Assert.Contains(name, output);
        Assert.Contains($",'{name},", File.ReadAllText(report));
    }

    [Fact]
    public async Task A_folder_prints_as_it_fills_and_the_next_run_prints_nothing_twice()
    {
        if (!OperatingSystem.IsWindows()) return;
        using var f = new BatchFolder();
        File.WriteAllBytes(Path.Combine(f.Root, "a.pdf"), BatchPrintSamples.Pdf(2, "A"));
        File.WriteAllBytes(Path.Combine(f.Root, "b.png"), BatchPrintSamples.Png(40, 40));

        var first = await Run(null, "print", "--watch", f.Root, "--printer", Printer, "--once", "--demo");
        Assert.True(first.Code == BatchPrintSummary.Done, $"exit {first.Code}\n{first.Out}\n{first.Err}");
        Assert.Contains("2 files sent (3 sheets)", first.Out);
        Assert.Equal(2, Directory.GetFiles(Path.Combine(f.Root, "done")).Length);

        var second = await Run(null, "print", "--watch", f.Root, "--printer", Printer, "--once", "--demo");
        Assert.Equal(BatchPrintSummary.Done, second.Code);
        Assert.Contains("0 files sent (0 sheets)", second.Out);
    }

    /// <summary>A scheduled task reads the exit code: a file left behind unprinted isn't "every file sent".</summary>
    [Fact]
    public async Task A_run_that_leaves_a_cut_off_file_behind_doesnt_exit_as_if_all_were_sent()
    {
        if (!OperatingSystem.IsWindows()) return;
        using var f = new BatchFolder();
        var cutOff = Path.Combine(f.Root, "cut.pdf");
        File.WriteAllBytes(cutOff, BatchPrintSamples.Pdf(2, "A")[..64]);

        var run = await Run(null, "print", "--watch", f.Root, "--printer", Printer, "--once", "--demo");

        Assert.True(run.Code == BatchPrintSummary.SomeFailed, $"exit {run.Code}\n{run.Out}\n{run.Err}");
        Assert.Contains("1 file left in the folder", run.Err);
        Assert.True(File.Exists(cutOff));
    }

    /// <summary>
    /// Windows' PDF engine can't open AES-256 (Acrobat's usual protection) with any password, and that's neither a wrong password
    /// nor damage: found on a real queue. The engine stops at the dictionary, so this file needs no real encryption.
    /// </summary>
    [Fact]
    public async Task A_lock_windows_cant_open_says_so_and_isnt_called_damaged()
    {
        if (!OperatingSystem.IsWindows()) return;
        using var f = new BatchFolder();
        var locked = Path.Combine(f.Root, "aes256.pdf");
        File.WriteAllBytes(locked, Aes256Locked());
        var open = Path.Combine(f.Root, "open.pdf");
        File.WriteAllBytes(open, BatchPrintSamples.Pdf(2, "Open"));

        var (code, output, error) = await Run(Password, "print", locked, open, "--printer", Printer, "--demo");

        Assert.True(code == BatchPrintSummary.SomeFailed, $"exit {code}\n{output}\n{error}");
        Assert.Contains("password protection", error);
        Assert.DoesNotContain("damaged", error);
        Assert.Contains("1 sent (2 sheets), 1 skipped.", output);
    }

    private static byte[] Aes256Locked()
    {
        string Hex(int bytes) => new('A', bytes * 2);
        var objects = new[]
        {
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] >>",
            $"<< /Filter /Standard /V 5 /R 6 /Length 256 /P -44 /O <{Hex(48)}> /U <{Hex(48)}> /OE <{Hex(32)}> /UE <{Hex(32)}> /Perms <{Hex(16)}> /StmF /StdCF /StrF /StdCF /CF << /StdCF << /CFM /AESV3 /Length 32 >> >> >>",
        };
        var pdf = new System.Text.StringBuilder("%PDF-1.7\n");
        var offsets = new List<int>();
        for (var i = 0; i < objects.Length; i++)
        {
            offsets.Add(pdf.Length);
            pdf.Append($"{i + 1} 0 obj\n{objects[i]}\nendobj\n");
        }
        var xref = pdf.Length;
        pdf.Append($"xref\n0 {objects.Length + 1}\n0000000000 65535 f \n");
        foreach (var offset in offsets) pdf.Append($"{offset:D10} 00000 n \n");
        pdf.Append($"trailer\n<< /Size {objects.Length + 1} /Root 1 0 R /Encrypt 4 0 R /ID [<{Hex(16)}> <{Hex(16)}>] >>\nstartxref\n{xref}\n%%EOF\n");
        return System.Text.Encoding.ASCII.GetBytes(pdf.ToString());
    }

    /// <summary>
    /// With its output piped (<c>| Out-Default</c>, as the README says, or a script's) the app had no console, so Ctrl+C never reached it and it
    /// went on printing behind the prompt: found on a real queue. Run from a PowerShell in a hidden console of its own, so the key reaches only these two.
    /// </summary>
    [Fact]
    public async Task Ctrl_C_stops_a_run_whose_output_is_piped()
    {
        if (!OperatingSystem.IsWindows()) return;
        using var f = new BatchFolder();
        const string script = """
            Add-Type -Namespace Inkvolt -Name Keys -MemberDefinition '[DllImport("kernel32")] public static extern bool GenerateConsoleCtrlEvent(uint e, uint g); [DllImport("kernel32")] public static extern bool SetConsoleCtrlHandler(IntPtr h, bool a);'
            [void][Inkvolt.Keys]::SetConsoleCtrlHandler([IntPtr]::Zero, $false) # a shell or CI that started this may have passed down "ignore Ctrl+C", which the app would inherit
            $i = New-Object Diagnostics.ProcessStartInfo $env:TEST_EXE
            $i.Arguments = $env:TEST_ARGS
            $i.UseShellExecute = $false
            $i.RedirectStandardOutput = $true
            $p = [Diagnostics.Process]::Start($i)
            [void]$p.StandardOutput.ReadLine()
            [void][Inkvolt.Keys]::SetConsoleCtrlHandler([IntPtr]::Zero, $true)
            [void][Inkvolt.Keys]::GenerateConsoleCtrlEvent(0, 0)
            if (-not $p.WaitForExit(30000)) { $p.Kill(); exit 99 }
            exit $p.ExitCode
            """;
        var start = new ProcessStartInfo("powershell.exe") { UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true, RedirectStandardError = true };
        foreach (var a in new[] { "-NoProfile", "-NonInteractive", "-Command", script }) start.ArgumentList.Add(a);
        start.Environment["TEST_EXE"] = Exe();
        start.Environment["TEST_ARGS"] = $"print --watch \"{f.Root}\" --printer \"{Printer}\" --demo";
        using var process = Process.Start(start)!;
        var (output, error) = (process.StandardOutput.ReadToEndAsync(), process.StandardError.ReadToEndAsync());
        using var limit = new CancellationTokenSource(TimeSpan.FromMinutes(2));
        try
        {
            await process.WaitForExitAsync(limit.Token);
        }
        catch (OperationCanceledException)
        {
            process.Kill(entireProcessTree: true);
            throw;
        }
        Assert.True(process.ExitCode is BatchPrintSummary.Done or BatchPrintSummary.Stopped, $"exit {process.ExitCode} (99: Ctrl+C didn't stop it)\n{await output}\n{await error}");
    }
}
