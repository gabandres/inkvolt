using InkvoltPdf.Core;
using static InkvoltPdf.Core.ConvertCommand;

namespace InkvoltPdf.Tests;

/// <summary>
/// Explorer starts one launch per selected file: the running copy gathers the launches that come together into one
/// batch, opens a result only for a batch of one file, and stays up while conversions are left.
/// </summary>
public class ConvertLaunchTests
{
    private static readonly DateTime T0 = new(2026, 11, 10, 9, 0, 0, DateTimeKind.Utc);

    private static Request Word(params string[] files) => new(ExportFormat.Word, files);

    // ── The options before the command, the files after it (finding 7) ──

    [Fact]
    public void OptionsAreReadOnlyBeforeTheCommand()
    {
        var (options, command) = SplitOptions(["--lang", "es", "--convert-to", "word", "--lang", "--script", @"C:\a.pdf"]);
        Assert.Equal(["--lang", "es"], options);
        Assert.Equal(["--convert-to", "word", "--lang", "--script", @"C:\a.pdf"], command);
        Assert.True(TryParse(command, out var r, out _));
        Assert.Equal(3, r!.Files.Count); // "--lang" and "--script" after the format are files (relative names, made full)
    }

    [Fact]
    public void WithoutTheCommandEverythingIsOptionsAndFiles()
    {
        var (options, command) = SplitOptions(["--lang", "es", @"C:\a.pdf"]);
        Assert.Equal(["--lang", "es", @"C:\a.pdf"], options);
        Assert.Empty(command);
        (options, command) = SplitOptions(["--convert-to=word", @"C:\a.pdf"]);
        Assert.Empty(options);
        Assert.Equal(2, command.Count);
    }

    [Fact]
    public void WhatALaunchLeftOutReachesTheRunningCopy()
    {
        // Finding 6: the running copy says "left out" in its own words for each kind; the launch's counts go with it.
        var launch = new Request(ExportFormat.Word, [@"C:\a.pdf"], OverLimit: 3, Refused: 1);
        var forwarded = ToArguments(launch);
        Assert.Equal("--convert-to=word:3:1", forwarded[0]);
        Assert.True(TryParse(forwarded, out var back, out _));
        Assert.Equal((3, 1), (back!.OverLimit, back.Refused));
        Assert.Equal(ParseError.UnknownFormat, TryParse(["--convert-to=word:-1:0", @"C:\a.pdf"], out _, out var e1) ? ParseError.None : e1);
        Assert.Equal(ParseError.UnknownFormat, TryParse(["--convert-to=word:9", @"C:\a.pdf"], out _, out var e2) ? ParseError.None : e2);
        Assert.Equal(ParseError.UnknownFormat, TryParse(["--convert-to=word:99999999999:0", @"C:\a.pdf"], out _, out var e3) ? ParseError.None : e3);
    }

    // ── Launches gathered into one batch (findings 2, 3) ──

    [Fact]
    public void LaunchesThatComeTogetherAreOneBatch()
    {
        var gather = new ConvertGather();
        gather.Add(Word(@"C:\a.pdf"), T0);
        gather.Add(Word(@"C:\b.pdf"), T0.AddMilliseconds(150));
        gather.Add(Word(@"C:\c.pdf"), T0.AddMilliseconds(300));
        Assert.False(gather.IsDue(T0.AddMilliseconds(500)));
        Assert.True(gather.IsDue(T0.AddMilliseconds(300) + ConvertGather.Quiet));
        var batch = Assert.Single(gather.Take());
        Assert.Equal([@"C:\a.pdf", @"C:\b.pdf", @"C:\c.pdf"], batch.Files);
        Assert.True(gather.IsEmpty);
    }

    [Fact]
    public void AStreamOfLaunchesIsCutAtTheLongestWait()
    {
        var gather = new ConvertGather();
        var t = T0;
        for (var i = 0; i < 40; i++, t = t.AddMilliseconds(200)) gather.Add(Word($@"C:\{i}.pdf"), t);
        Assert.True(gather.IsDue(T0 + ConvertGather.Longest));
        Assert.Equal(T0 + ConvertGather.Longest, gather.DueAt);
    }

    [Fact]
    public void NothingGatheredIsNeverDue()
    {
        var gather = new ConvertGather();
        Assert.Null(gather.DueAt);
        Assert.False(gather.IsDue(T0.AddHours(1)));
        Assert.Empty(gather.Take());
    }

    [Fact]
    public void MergingKeepsOrderEachFileOnceAndTheCountsApart()
    {
        var merged = Merge([
            new Request(ExportFormat.Word, [@"C:\a.pdf", @"C:\b.pdf"], OverLimit: 1, Refused: 2),
            new Request(ExportFormat.Excel, [@"C:\x.pdf"]),
            new Request(ExportFormat.Word, [@"c:\B.pdf", @"C:\c.pdf"], Refused: 1),
        ]);
        Assert.Equal(2, merged.Count);
        Assert.Equal(ExportFormat.Word, merged[0].Format);
        Assert.Equal([@"C:\a.pdf", @"C:\b.pdf", @"C:\c.pdf"], merged[0].Files);
        Assert.Equal((1, 3), (merged[0].OverLimit, merged[0].Refused));
        Assert.Equal([@"C:\x.pdf"], merged[1].Files);
    }

    [Fact]
    public void MergedLaunchesStillStopAtTheLimit()
    {
        var launches = Enumerable.Range(0, MaxFiles + 3).Select(i => Word($@"C:\{i}.pdf")).ToList();
        var merged = Assert.Single(Merge(launches));
        Assert.Equal(MaxFiles, merged.Files.Count);
        Assert.Equal(3, merged.OverLimit);
    }

    [Fact]
    public void NineLaunchesWithTheWindowIdleShowOneList()
    {
        // Finding 3: each launch alone looked like "one file, window idle" and went to the notice.
        var gather = new ConvertGather();
        for (var i = 0; i < 9; i++) gather.Add(Word($@"C:\{i}.pdf"), T0.AddMilliseconds(20 * i));
        var batch = Assert.Single(gather.Take());
        Assert.False(ShowsNotice(windowReady: true, listOpen: false, busy: false, batch.Files.Count));
    }

    // ── Opening the result (finding 2) ──

    [Fact]
    public async Task OnlyANoticedSingleFileIsOpened()
    {
        var queue = new ConvertQueue((job, _) => Task.FromResult(ConvertOutcome.Saved(job.Pdf + ".docx", false, null)));
        var one = queue.Add(Word(@"C:\a.pdf"), open: true);
        var listed = queue.Add(Word(@"C:\b.pdf"));
        var many = queue.Add(Word(@"C:\c.pdf", @"C:\d.pdf"), open: true);
        await queue.Idle;
        Assert.True(one[0].Open);
        Assert.False(listed[0].Open);
        Assert.All(many, j => Assert.False(j.Open));
    }

    // ── Staying up for conversions (findings 1, 4) ──

    [Theory]
    [InlineData(false, false, false, 0, true)]
    [InlineData(true, false, false, 0, false)] // the main window is open
    [InlineData(false, true, false, 0, false)] // the conversions window is open
    [InlineData(false, false, true, 0, false)] // conversions left (gathering or queued): they finish, then it exits
    [InlineData(false, false, false, 1, false)] // a launch's files read but not handled yet
    public void TheAppExitsOnlyWithNothingLeft(bool mainOpen, bool listOpen, bool converting, int forwards, bool exits) =>
        Assert.Equal(exits, MayExit(mainOpen, listOpen, converting, forwards));
}
