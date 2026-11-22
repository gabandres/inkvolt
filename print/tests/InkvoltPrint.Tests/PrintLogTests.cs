using System.Buffers.Binary;
using InkvoltPrint.Core;
using InkvoltPrint.Core.History;
using InkvoltPrint.Core.Printing;
using InkvoltPrint.Core.Suite;

namespace InkvoltPrint.Tests;

/// <summary>
/// The print log (roadmap 4.9): the spooler's job notices into entries (<see cref="PrintLogRecorder"/>, from the sequence a real job to
/// Microsoft Print to PDF gave), the log bounded and read back as hostile input (<see cref="PrintLog"/>, <see cref="PrintLogFile"/>),
/// month totals and the CSV.
/// </summary>
public class PrintLogTests
{
    private static readonly DateTimeOffset Now = new(2026, 11, 22, 15, 0, 0, TimeSpan.Zero);
    private static readonly DateTimeOffset Submitted = new(2026, 11, 22, 7, 8, 47, TimeSpan.Zero);

    private static JobChange Job(int id = 3) => new(id);

    /// <summary>What the spooler sent for a three-page job, two copies, to Microsoft Print to PDF (field by field, as it came).</summary>
    private static IEnumerable<JobChange[]> RealJob(int id = 3, DateTimeOffset? submitted = null, bool cancelBeforePrinting = false)
    {
        yield return [Job(id) with { Printer = "Microsoft Print to PDF" }, Job(id) with { Machine = @"\\OFFICE-PC" }, Job(id) with { User = "ana" },
            Job(id) with { Settings = new JobSettings(2, true, null) }, Job(id) with { Status = JobStatus.Spooling },
            Job(id) with { Document = @"C:\Users\ana\Taxes\return.pdf" }, Job(id) with { Submitted = submitted ?? Submitted },
            Job(id) with { TotalPages = 0 }, Job(id) with { PagesPrinted = 0 }];
        yield return [Job(id) with { TotalPages = 1 }, Job(id) with { Status = JobStatus.Spooling }];
        if (cancelBeforePrinting)
        {
            yield return [Job(id) with { Status = JobStatus.Spooling | JobStatus.Deleting }];
            yield return [Job(id) with { Status = JobStatus.Deleting | JobStatus.Deleted }];
            yield break;
        }
        yield return [Job(id) with { Status = JobStatus.Spooling | JobStatus.Printing | JobStatus.Retained }];
        yield return [Job(id) with { TotalPages = 3 }, Job(id) with { PagesPrinted = 3 }, Job(id) with { PagesPrinted = 6 }];
        yield return [Job(id) with { Status = JobStatus.Printing | JobStatus.Retained }, Job(id) with { Status = JobStatus.None }];
        yield return [Job(id) with { Status = JobStatus.Deleting | JobStatus.Printed }, Job(id) with { PagesPrinted = 6 }];
        yield return [Job(id) with { Status = JobStatus.Deleting | JobStatus.Printed | JobStatus.Deleted }];
    }

    private static List<PrintLogEntry> Run(PrintLogRecorder recorder, IEnumerable<JobChange[]> notices) =>
        notices.SelectMany(n => recorder.Notice(n, Now)).ToList();

    // ---------------------------------------------------------------- the recorder

    [Fact]
    public void A_printed_job_is_logged_once_with_what_the_spooler_said()
    {
        var recorder = new PrintLogRecorder();
        var e = Assert.Single(Run(recorder, RealJob()));
        Assert.Equal(Submitted, e.At);
        Assert.Equal("Microsoft Print to PDF", e.Printer);
        Assert.Equal("return.pdf", e.Document); // the folders stay off the log
        Assert.Equal("ana", e.User);
        Assert.Equal("OFFICE-PC", e.Machine);
        Assert.Equal(3, e.Pages);
        Assert.Equal(2, e.Copies);
        Assert.Equal(6, e.Printed);
        Assert.Equal(6, e.TotalPages); // the spooler's printed count has the copies in it already
        Assert.True(e.Color);
        Assert.Null(e.TwoSided);
        Assert.Equal(PrintLogOutcome.Printed, e.Outcome);
        Assert.Equal(0, recorder.Open);
    }

    [Fact]
    public void A_job_deleted_before_it_printed_is_cancelled_and_counts_no_pages()
    {
        var e = Assert.Single(Run(new PrintLogRecorder(), RealJob(cancelBeforePrinting: true)));
        Assert.Equal(PrintLogOutcome.Cancelled, e.Outcome);
        Assert.Equal(0, e.TotalPages);
    }

    [Fact]
    public void A_job_a_queue_keeps_after_printing_is_logged_when_it_prints_and_not_again()
    {
        var recorder = new PrintLogRecorder();
        Assert.Empty(recorder.Notice([Job(9) with { Printer = "Laser", Status = JobStatus.Printing, TotalPages = 2 }], Now));
        Assert.Single(recorder.Notice([Job(9) with { Status = JobStatus.Retained | JobStatus.Printed, PagesPrinted = 2 }], Now));
        Assert.Empty(recorder.Notice([Job(9) with { Status = JobStatus.Retained | JobStatus.Printed }], Now));
        Assert.Empty(recorder.Refresh([Job(9) with { Status = JobStatus.Retained | JobStatus.Printed }], Now, first: false));
        Assert.Empty(recorder.Notice([Job(9) with { Status = JobStatus.Deleted }], Now)); // deleted later by hand: already logged
    }

    [Fact]
    public void Jobs_already_printed_when_watching_starts_were_there_before()
    {
        var recorder = new PrintLogRecorder();
        Assert.Empty(recorder.Refresh([Job(1) with { Printer = "Laser", Status = JobStatus.Retained | JobStatus.Printed, TotalPages = 4 }], Now, first: true));
        Assert.Empty(recorder.Notice([Job(1) with { Status = JobStatus.Deleted }], Now));
        // One still waiting then is followed, and logged when it prints.
        Assert.Empty(recorder.Refresh([Job(2) with { Printer = "Laser", Status = JobStatus.None, TotalPages = 1 }], Now, first: true));
        Assert.Single(recorder.Notice([Job(2) with { Status = JobStatus.Printed }], Now));
    }

    [Fact]
    public void A_job_missing_from_the_whole_list_has_left()
    {
        var recorder = new PrintLogRecorder();
        recorder.Notice([Job(4) with { Printer = "Laser", Status = JobStatus.Spooling, TotalPages = 1 }], Now);
        recorder.Notice([Job(5) with { Printer = "Laser", Status = JobStatus.Printing, TotalPages = 2 }], Now);
        var ended = recorder.Refresh([], Now, first: false);
        Assert.Equal([PrintLogOutcome.Left, PrintLogOutcome.Printed], ended.Select(e => e.Outcome));
    }

    [Fact]
    public void An_id_used_again_is_another_job()
    {
        var recorder = new PrintLogRecorder();
        recorder.Notice([Job(7) with { Printer = "A", Document = "first", Submitted = Submitted, Status = JobStatus.Printing }], Now);
        var ended = recorder.Notice([Job(7) with { Printer = "B", Document = "second", Submitted = Submitted.AddMinutes(5) }], Now);
        Assert.Equal("first", Assert.Single(ended).Document);
        Assert.Equal(1, recorder.Open);
    }

    [Fact]
    public void The_jobs_followed_are_bounded_and_forgotten_when_watching_stops()
    {
        var recorder = new PrintLogRecorder();
        recorder.Notice(Enumerable.Range(1, PrintLogRecorder.MaxOpen + 50).Select(i => Job(i) with { Status = JobStatus.Spooling }), Now);
        Assert.Equal(PrintLogRecorder.MaxOpen, recorder.Open);
        recorder.Reset();
        Assert.Equal(0, recorder.Open);
    }

    [Fact]
    public void The_keeper_logs_nothing_while_off()
    {
        var file = new PrintLogFile(null);
        var keeper = new PrintLogKeeper(file, () => Now) { On = false };
        foreach (var n in RealJob()) keeper.Notice(n, JobNoticeKind.Changes);
        Assert.Empty(file.Read(Now));
        keeper.On = true;
        var added = 0;
        keeper.Added += () => added++;
        foreach (var n in RealJob(8)) keeper.Notice(n, JobNoticeKind.Changes);
        Assert.Single(file.Read(Now));
        Assert.Equal(1, added);
    }

    // ---------------------------------------------------------------- what the spooler hands over

    private static byte[] DevMode(uint fields, short copies, short color, short duplex, ushort size = 220)
    {
        var d = new byte[size];
        BinaryPrimitives.WriteUInt16LittleEndian(d.AsSpan(68), size);
        BinaryPrimitives.WriteUInt32LittleEndian(d.AsSpan(72), fields);
        BinaryPrimitives.WriteInt16LittleEndian(d.AsSpan(86), copies);
        BinaryPrimitives.WriteInt16LittleEndian(d.AsSpan(92), color);
        BinaryPrimitives.WriteInt16LittleEndian(d.AsSpan(94), duplex);
        return d;
    }

    [Fact]
    public void A_devmode_says_only_what_its_fields_say()
    {
        Assert.Equal(new JobSettings(3, false, true), JobSettings.Read(DevMode(0x100 | 0x800 | 0x1000, 3, 1, 2)));
        Assert.Equal(new JobSettings(null, null, null), JobSettings.Read(DevMode(0, 3, 2, 3)));
        Assert.Equal(new JobSettings(null, true, null), JobSettings.Read(DevMode(0x800, -5, 2, 9)));
        Assert.Null(JobSettings.Read(new byte[40]));
        var lying = DevMode(0x100, 2, 1, 1);
        BinaryPrimitives.WriteUInt16LittleEndian(lying.AsSpan(68), 60_000); // says it's longer than what came
        Assert.Null(JobSettings.Read(lying));
        var shortOne = DevMode(0x100 | 0x800, 2, 2, 1);
        BinaryPrimitives.WriteUInt16LittleEndian(shortOne.AsSpan(68), 90); // copies fit in what it says it is, color doesn't
        Assert.Equal(new JobSettings(2, null, null), JobSettings.Read(shortOne));
    }

    [Fact]
    public void A_submission_time_that_isnt_a_date_is_none()
    {
        var t = new byte[16];
        ushort[] good = [2026, 11, 0, 22, 7, 8, 47, 120];
        for (var i = 0; i < 8; i++) BinaryPrimitives.WriteUInt16LittleEndian(t.AsSpan(i * 2), good[i]);
        Assert.Equal(new DateTimeOffset(2026, 11, 22, 7, 8, 47, 120, TimeSpan.Zero), JobChange.SystemTime(t));
        BinaryPrimitives.WriteUInt16LittleEndian(t.AsSpan(6), 31); // November 31st
        Assert.Null(JobChange.SystemTime(t));
        Assert.Null(JobChange.SystemTime(new byte[8]));
        Assert.Null(JobChange.SystemTime(new byte[16]));
    }

    // ---------------------------------------------------------------- the log

    private static PrintLogEntry Entry(DateTimeOffset at, string printer = "Laser", string user = "ana", int pages = 2, int copies = 1,
        bool? color = null, PrintLogOutcome outcome = PrintLogOutcome.Printed) =>
        new(at, printer, "doc", user, pages, copies, color, null, outcome);

    [Fact]
    public void Names_are_one_line_of_visible_characters_and_counts_are_bounded()
    {
        var e = PrintLog.Clean(new PrintLogEntry(Now, "Laser\u202E\r\nfake line", new string('x', 500), "ana\u0000", -4, 0, Printed: int.MaxValue, Machine: "\\\\PC​"))!;
        Assert.Equal("Laser fake line", e.Printer);
        Assert.Equal(PrintLog.MaxText, e.Document.Length);
        Assert.Equal("ana", e.User);
        Assert.Equal("PC", e.Machine);
        Assert.Equal(0, e.Pages);
        Assert.Equal(1, e.Copies);
        Assert.Equal(PrintLog.MaxPages, e.Printed);
        Assert.Null(PrintLog.Clean(new PrintLogEntry(default, "a", "b", "c", 1)));
        Assert.Null(PrintLog.Clean(null));
    }

    [Fact]
    public void The_log_keeps_thirteen_months_and_at_most_its_limit()
    {
        var list = new List<PrintLogEntry> { Entry(Now.AddMonths(-14)), Entry(Now.AddMonths(-12)) };
        list = PrintLog.Add(list, Entry(Now), Now);
        Assert.Equal(2, list.Count);
        var many = Enumerable.Range(0, PrintLog.MaxEntries + 10).Select(i => Entry(Now.AddMinutes(-i))).Reverse().ToList();
        var kept = PrintLog.Trim(many, Now);
        Assert.Equal(PrintLog.MaxEntries, kept.Count);
        Assert.Equal(Now, kept[^1].At); // the newest stay
    }

    [Fact]
    public void Month_totals_count_pages_times_copies_per_printer_and_per_person_without_cancelled_jobs()
    {
        var november = new DateOnly(2026, 11, 1);
        PrintLogEntry[] log =
        [
            Entry(Now, "Laser", "ana", pages: 3, copies: 2),
            Entry(Now, "laser", "ben", pages: 1, color: true),
            Entry(Now, "Inkjet", "ana", pages: 4, color: true),
            Entry(Now, "Inkjet", "ben", pages: 50, outcome: PrintLogOutcome.Cancelled),
            Entry(Now.AddMonths(-1), "Laser", "ana", pages: 100),
            Entry(Now, "", "", pages: 1),
        ];
        var byPrinter = PrintLog.ByPrinter(log, november);
        Assert.Equal(new PrintLogTotal("Laser", 2, 7, 1), byPrinter[0]);
        Assert.Equal(new PrintLogTotal("Inkjet", 1, 4, 4), byPrinter[1]);
        Assert.Equal(CoreStrings.PrintLog_Unknown, byPrinter[2].Name);
        var byUser = PrintLog.ByUser(log, november);
        Assert.Equal(new PrintLogTotal("ana", 2, 10, 4), byUser[0]);
        Assert.Equal([november, november.AddMonths(-1)], PrintLog.Months(log));
        Assert.Equal(5, PrintLog.In(log, november).Count);
    }

    [Fact]
    public void The_csv_has_a_header_and_cells_a_spreadsheet_wont_run()
    {
        var csv = PrintLog.Csv([new PrintLogEntry(Submitted, "Laser, 2nd floor", "=HYPERLINK(\"x\")", "ana", 3, 2, true, false, PrintLogOutcome.Printed, "PC", 6)]);
        var lines = csv.Split("\r\n", StringSplitOptions.RemoveEmptyEntries);
        Assert.Equal("time,printer,document,user,computer,pages,copies,total_pages,color,two_sided,outcome", lines[0]);
        Assert.Equal("2026-11-22T07:08:47+00:00,\"Laser, 2nd floor\",\"'=HYPERLINK(\"\"x\"\")\",ana,PC,3,2,6,yes,no,printed", lines[1]);
    }

    [Fact]
    public void The_file_is_read_back_as_hostile_input()
    {
        string[] lines =
        [
            PrintLogFile.Line(Entry(Now.AddDays(-1))),
            "not json",
            "{\"At\":\"2026-11-20T10:00:00+00:00\",\"Printer\":\"P\\u202Eq\",\"Document\":null,\"User\":\"u\",\"Pages\":-1,\"Outcome\":\"Sideways\"}",
            "{\"At\":\"2026-11-20T10:00:00+00:00\",\"Printer\":\"Q\",\"Document\":\"d\",\"User\":\"u\",\"Pages\":2,\"Outcome\":99}",
            "{\"At\":\"" + new string('9', 9000) + "\"}",
            PrintLogFile.Line(Entry(Now.AddMonths(-20))),
            "",
        ];
        var read = PrintLogFile.Parse(lines, Now);
        Assert.Equal(2, read.Count);
        Assert.Equal("Q", read[0].Printer);
        Assert.Equal(PrintLogOutcome.Left, read[0].Outcome);
        Assert.Equal("Laser", read[1].Printer);
    }

    [Fact]
    public void The_file_keeps_appending_and_clears()
    {
        var folder = Path.Combine(Path.GetTempPath(), "inkvolt-printlog-" + Guid.NewGuid().ToString("N"));
        try
        {
            var path = Path.Combine(folder, "print-log.jsonl");
            var file = new PrintLogFile(path);
            file.Add([Entry(Now.AddHours(-2))], Now);
            file.Add([Entry(Now.AddHours(-1), printer: "Inkjet")], Now);
            Assert.Equal(2, File.ReadAllLines(path).Length);
            var again = new PrintLogFile(path).Read(Now);
            Assert.Equal(["Laser", "Inkjet"], again.Select(e => e.Printer));
            file.Clear();
            Assert.False(File.Exists(path));
            Assert.Empty(file.Read(Now));
            Assert.Empty(new PrintLogFile(path).Read(Now));
        }
        finally
        {
            if (Directory.Exists(folder)) Directory.Delete(folder, recursive: true);
        }
    }

    [Fact]
    public void The_palette_opens_the_log_and_its_csv_is_a_pro_feature_of_its_own()
    {
        Assert.Contains(PrintPalette.Build(null, -1, [], []), e => e.Id == "app:printlog");
        Assert.Equal(CoreStrings.Pro_PrintLogExport, Pro.Title(ProFeature.PrintLogExport));
        Assert.Equal(CoreStrings.Pro_PrintLogExport_Locked, Pro.Locked(ProFeature.PrintLogExport));
    }

    [Fact]
    public void The_demo_log_is_made_up_months_of_jobs()
    {
        var demo = PrintLog.Demo(Now);
        Assert.True(demo.Count > 20);
        Assert.All(demo, e => Assert.NotNull(PrintLog.Clean(e)));
        Assert.True(PrintLog.Months(demo).Count >= 3);
    }
}
