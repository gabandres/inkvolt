using System.Text;
using InkvoltPdf.Core;

namespace InkvoltPdf.Tests;

/// <summary>A conversion launch that gives up on the running copy (<see cref="LaunchHandoff.Way.Dropped"/>) leaves its files for the copy that converts.</summary>
public sealed class LaunchDropBoxTests : IDisposable
{
    private readonly string _dir = Directory.CreateTempSubdirectory("inkvolt-dropbox-").FullName;

    public void Dispose()
    {
        try { Directory.Delete(_dir, true); }
        catch (IOException) { }
    }

    private static string[] Launch(params string[] files) => [ConvertCommand.Switch, "word", .. files];

    [Fact]
    public void ADroppedLaunchIsTakenOnceInTheOrderLeft()
    {
        Assert.True(LaunchDropBox.Leave(_dir, Launch(@"C:\a\one.pdf")));
        Assert.True(LaunchDropBox.Leave(_dir, Launch(@"C:\a\two.pdf", @"C:\a\three.pdf")));
        var taken = LaunchDropBox.Take(_dir);
        Assert.Equal(2, taken.Count);
        Assert.Equal(Launch(@"C:\a\one.pdf"), taken[0]);
        Assert.Equal(Launch(@"C:\a\two.pdf", @"C:\a\three.pdf"), taken[1]);
        Assert.True(ConvertCommand.TryParse(taken[1], out var request, out _)); // read as a forwarded launch is
        Assert.Equal(2, request!.Files.Count);
        Assert.Empty(LaunchDropBox.Take(_dir));
        Assert.Empty(Directory.GetFiles(_dir));
    }

    [Fact]
    public void TwoCopiesTakingAtOnceGetEachLaunchOnce()
    {
        for (var i = 0; i < 200; i++) Assert.True(LaunchDropBox.Leave(_dir, Launch($@"C:\a\{i}.pdf")));
        var all = new List<string[]>[4];
        Parallel.For(0, all.Length, k =>
        {
            all[k] = [];
            for (var round = 0; round < 5; round++) all[k].AddRange(LaunchDropBox.Take(_dir));
        });
        var files = all.SelectMany(t => t).Select(a => a[^1]).ToList();
        Assert.Equal(200, files.Count);
        Assert.Equal(200, files.Distinct().Count());
    }

    [Fact]
    public void ALaunchStillBeingWrittenIsNotTaken()
    {
        File.WriteAllText(Path.Combine(_dir, "0638000000000000000-x.part"), string.Join('\n', Launch(@"C:\a\half")));
        Assert.Empty(LaunchDropBox.Take(_dir));
        Assert.Single(Directory.GetFiles(_dir)); // a fresh part is left to its writer
        Assert.Empty(LaunchDropBox.Take(_dir, DateTime.UtcNow + LaunchDropBox.MaxAge + TimeSpan.FromHours(1)));
        Assert.Empty(Directory.GetFiles(_dir)); // an old one is a launch that ended mid-write
    }

    [Fact]
    public void AnOldLaunchIsLetGoOfUnread()
    {
        Assert.True(LaunchDropBox.Leave(_dir, Launch(@"C:\a\one.pdf")));
        Assert.Empty(LaunchDropBox.Take(_dir, DateTime.UtcNow + LaunchDropBox.MaxAge + TimeSpan.FromHours(1)));
        Assert.Empty(Directory.GetFiles(_dir));
    }

    [Fact]
    public void TheFolderIsBoundedInLaunchesAndSize()
    {
        Assert.False(LaunchDropBox.Leave(_dir, [new string('x', LaunchDropBox.MaxChars + 1)]));
        Assert.False(LaunchDropBox.Leave(_dir, Launch("C:\\a\nC:\\b"))); // a line break would make two arguments
        // Full: the next launch isn't left (its own log says so).
        for (var i = 0; i < LaunchDropBox.MaxLaunches; i++) File.WriteAllText(Path.Combine(_dir, $"{i:D19}-f.launch"), "x");
        Assert.False(LaunchDropBox.Leave(_dir, Launch(@"C:\a\one.pdf")));
        Assert.Equal(LaunchDropBox.TakeAtOnce, LaunchDropBox.Take(_dir).Count); // the rest at the next look
    }

    [Fact]
    public void AnOverlongFileLeftThereIsRemovedUnread()
    {
        File.WriteAllText(Path.Combine(_dir, "0000000000000000001-big.launch"), new string('x', LaunchDropBox.MaxChars + 1), new UTF8Encoding(false));
        Assert.True(LaunchDropBox.Leave(_dir, Launch(@"C:\a\one.pdf")));
        var taken = Assert.Single(LaunchDropBox.Take(_dir));
        Assert.Equal(Launch(@"C:\a\one.pdf"), taken);
        Assert.Empty(Directory.GetFiles(_dir));
    }
}
