using InkvoltPdf.Core;

namespace InkvoltPdf.Tests;

/// <summary>Two documents side by side (roadmap 4.9): which window owns which tab, moving and tearing tabs off, launches, and what is remembered.</summary>
public class DocumentWindowsTests
{
    [Fact]
    public void AFileIsFoundInWhicheverWindowHasIt()
    {
        var windows = new DocumentWindows();
        var a = windows.Open();
        var b = windows.Open();
        windows.Add(a, 1, @"C:\Docs\one.pdf");
        windows.Add(b, 2, @"C:\Docs\two.pdf");
        windows.Add(b, 3, null); // never saved

        Assert.Equal((b, 2L), windows.FindFile(@"c:\docs\TWO.pdf"));
        Assert.Equal((a, 1L), windows.FindFile(@"C:\Docs\one.pdf"));
        Assert.Null(windows.FindFile(@"C:\Docs\three.pdf"));

        windows.SetPath(3, @"C:\Docs\three.pdf"); // Save As
        Assert.Equal((b, 3L), windows.FindFile(@"C:\Docs\three.pdf"));
        windows.Remove(2);
        Assert.Null(windows.FindFile(@"C:\Docs\two.pdf"));
    }

    [Fact]
    public void OtherLaunchesGoToTheWindowUsedLast()
    {
        var windows = new DocumentWindows();
        var a = windows.Open();
        Assert.Equal(a, windows.Active);
        var b = windows.Open();
        Assert.Equal(b, windows.Active); // a new window is the one in use
        windows.Activate(a);
        Assert.Equal(a, windows.Active);
        windows.Close(a);
        Assert.Equal(b, windows.Active);
        windows.Close(b);
        Assert.Null(windows.Active);
        Assert.Equal(0, windows.Count);
    }

    [Fact]
    public void ATabMovesToAnotherWindowUnlessItsDocumentIsBusy()
    {
        var windows = new DocumentWindows();
        var a = windows.Open();
        var b = windows.Open();
        windows.Add(a, 1, "1.pdf");
        windows.Add(a, 2, "2.pdf");
        windows.Add(b, 3, "3.pdf");

        Assert.Equal(TabMoveCheck.Busy, windows.CanMove(1, b, busy: true));
        Assert.Equal(TabMoveCheck.SameWindow, windows.CanMove(1, a, busy: false));
        Assert.Equal(TabMoveCheck.Unknown, windows.CanMove(9, b, busy: false));
        Assert.Equal(TabMoveCheck.Unknown, windows.CanMove(1, 99, busy: false));
        Assert.Equal(TabMoveCheck.Moves, windows.CanMove(1, b, busy: false));

        windows.Activate(a);
        var moved = windows.Move(1, b, 0);
        Assert.Equal(new TabMoved(a, FromEmptied: false), moved);
        Assert.Equal([2L], windows.TabsOf(a));
        Assert.Equal([1L, 3L], windows.TabsOf(b));
        Assert.Equal(b, windows.WindowOf(1));
        Assert.Equal(b, windows.Active); // the window it went to is in use now
    }

    [Fact]
    public void AWindowEmptiedByAMoveCloses()
    {
        var windows = new DocumentWindows();
        var a = windows.Open();
        var b = windows.Open();
        windows.Add(a, 1, "1.pdf");
        windows.Add(b, 2, "2.pdf");
        var moved = windows.Move(1, b, 99); // past the end: last
        Assert.True(moved.FromEmptied);
        Assert.Equal([2L, 1L], windows.TabsOf(b));
    }

    [Fact]
    public void MovingWithinAWindowReordersItsTabs()
    {
        var windows = new DocumentWindows();
        var a = windows.Open();
        foreach (var t in new long[] { 1, 2, 3, 4 }) windows.Add(a, t, $"{t}.pdf");
        // Tab 1 let go between 3 and 4: index 3 counts tab 1's own place, which it leaves.
        Assert.False(windows.Move(1, a, 3).FromEmptied);
        Assert.Equal([2L, 3L, 1L, 4L], windows.TabsOf(a));
        windows.Move(4, a, 0);
        Assert.Equal([4L, 2L, 3L, 1L], windows.TabsOf(a));
    }

    [Fact]
    public void AWindowsOnlyTabDoesntTearOff()
    {
        var windows = new DocumentWindows();
        var a = windows.Open();
        windows.Add(a, 1, "1.pdf");
        Assert.Equal(TearOffCheck.OnlyTab, windows.CanTearOff(1, busy: false));
        windows.Add(a, 2, "2.pdf");
        Assert.Equal(TearOffCheck.TearsOff, windows.CanTearOff(1, busy: false));
        Assert.Equal(TearOffCheck.Busy, windows.CanTearOff(1, busy: true));
        Assert.Equal(TearOffCheck.Unknown, windows.CanTearOff(7, busy: false));
    }

    [Fact]
    public void ATabIsInOneWindowOnly()
    {
        var windows = new DocumentWindows();
        var a = windows.Open();
        var b = windows.Open();
        windows.Add(a, 1, "1.pdf");
        Assert.Throws<ArgumentException>(() => windows.Add(b, 1, "1.pdf"));
        Assert.Throws<ArgumentException>(() => windows.Add(42, 2, "2.pdf"));
    }

    [Fact]
    public void ClosingOneOfSeveralWindowsForgetsItsFiles()
    {
        var windows = new DocumentWindows();
        var a = windows.Open();
        var b = windows.Open();
        windows.Add(a, 1, "1.pdf");
        windows.Add(b, 2, "2.pdf");
        windows.Add(b, 3, null);
        Assert.Null(windows.Remember(a, everyWindow: false)); // b is still open: what was remembered stays
        windows.Close(a);
        Assert.Equal(["2.pdf"], windows.Remember(b, everyWindow: false)); // the last window: its saved files
    }

    [Fact]
    public void WhenEveryWindowClosesAtOnceAllTheirFilesAreRememberedOnce()
    {
        var windows = new DocumentWindows();
        var a = windows.Open();
        var b = windows.Open();
        windows.Add(a, 1, "1.pdf");
        windows.Add(b, 2, "2.pdf");
        windows.Add(b, 3, "1.PDF"); // can't happen, but a file is listed once
        windows.CloseAllStarting();
        Assert.Equal(["1.pdf", "2.pdf"], windows.Remember(b, everyWindow: true));
        windows.Close(b);
        Assert.Null(windows.Remember(a, everyWindow: true)); // b's files stay remembered with a's

        // An Exit the user cancelled, then another: remembered afresh.
        windows.CloseAllStarting();
        Assert.Equal(["1.pdf"], windows.Remember(a, everyWindow: true));
    }

    [Fact]
    public void ALaunchCanAskForANewWindow()
    {
        var launch = WindowLaunch.Parse(["--new-window", @"C:\a.pdf"]);
        Assert.True(launch.NewWindow);
        Assert.Equal([@"C:\a.pdf"], launch.Files);
        Assert.False(WindowLaunch.Parse([@"C:\a.pdf"]).NewWindow);
        Assert.Empty(WindowLaunch.Parse(["--NEW-WINDOW"]).Files);
    }

    // ── Dragging a tab ──

    private static readonly TabStripArea Front = new(2, new RectD(100, 0, 600, 40), [150, 250, 350]);
    private static readonly TabStripArea Back = new(1, new RectD(400, 0, 600, 40), [450, 550]);

    [Fact]
    public void APressBecomesADragOnceItMovesWindowsDragDistance()
    {
        Assert.False(TabDrag.Started(new PointD(10, 10), new PointD(13, 12), 4, 4));
        Assert.True(TabDrag.Started(new PointD(10, 10), new PointD(14, 10), 4, 4));
        Assert.True(TabDrag.Started(new PointD(10, 10), new PointD(10, 6), 4, 4));
    }

    [Fact]
    public void ATabLetGoOnAnotherWindowsStripMovesThereBetweenItsTabs()
    {
        var drop = TabDrag.Drop(source: 1, sourceTabs: 2, new PointD(300, 20), [Front, Back]);
        Assert.Equal(new TabDrop(TabDropKind.MoveToWindow, 2, 2), drop);
        // Just under the strip still counts, and the front window wins where the strips overlap.
        Assert.Equal(new TabDrop(TabDropKind.MoveToWindow, 2, 3), TabDrag.Drop(1, 2, new PointD(500, 40 + TabDrag.Catch - 1), [Front, Back]));
        // Too far below: a window of its own.
        Assert.Equal(TabDropKind.TearOff, TabDrag.Drop(1, 2, new PointD(500, 40 + TabDrag.Catch + 1), [Front, Back]).Kind);
    }

    [Fact]
    public void TheCatchGrowsWithTheScreensScale()
    {
        var y = 40 + TabDrag.Catch * 1.5 - 1;
        Assert.Equal(TabDropKind.TearOff, TabDrag.Drop(1, 2, new PointD(300, y), [Front]).Kind);
        Assert.Equal(TabDropKind.MoveToWindow, TabDrag.Drop(1, 2, new PointD(300, y), [Front], scale: 1.5).Kind);
    }

    [Fact]
    public void ATabLetGoOnItsOwnStripReorders()
    {
        Assert.Equal(new TabDrop(TabDropKind.Reorder, 2, 0), TabDrag.Drop(2, 3, new PointD(120, 10), [Front, Back]));
        Assert.Equal(new TabDrop(TabDropKind.Reorder, 2, 3), TabDrag.Drop(2, 3, new PointD(690, 10), [Front, Back]));
    }

    [Fact]
    public void AnOnlyTabLetGoAwayFromEveryStripStaysPut()
    {
        Assert.Equal(TabDropKind.None, TabDrag.Drop(1, 1, new PointD(50, 500), [Front, Back]).Kind);
        Assert.Equal(TabDropKind.TearOff, TabDrag.Drop(1, 2, new PointD(50, 500), [Front, Back]).Kind);
    }
}
