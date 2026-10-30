using InkvoltPdf.Core;

namespace InkvoltPdf.Tests;

public class SettingsSessionTests
{
    private static SettingsSession Open() => new(new Dictionary<string, object?>
    {
        ["Theme"] = "System", ["DarkPages"] = false, ["KeepRecoveryCopies"] = true, ["AuthorName"] = "",
    });

    [Fact]
    public void NothingChangedAtFirst()
    {
        var session = Open();
        Assert.False(session.HasChanges);
        Assert.Null(session.Summary);
        Assert.Empty(session.Revert());
    }

    [Fact]
    public void ChangesAreListedLatestLast()
    {
        var session = Open();
        session.Set("DarkPages", true);
        session.Set("Theme", "Dark");
        session.Set("DarkPages", true); // changed again: now the latest
        Assert.Equal(["Theme", "DarkPages"], session.Changed);
        Assert.Equal("2 settings changed since Settings opened", session.Summary);
    }

    [Fact]
    public void ChangedBackCountsAsUnchanged()
    {
        var session = Open();
        session.Set("KeepRecoveryCopies", false);
        Assert.Equal("1 setting changed since Settings opened", session.Summary);
        session.Set("KeepRecoveryCopies", true);
        Assert.False(session.HasChanges);
    }

    [Fact]
    public void RevertGivesTheValuesAtOpenForWhatChanged()
    {
        var session = Open();
        session.Set("Theme", "Light");
        session.Set("Theme", "Dark");
        session.Set("AuthorName", "Ana");
        var back = session.Revert();
        Assert.Equal([new("Theme", "System"), new("AuthorName", "")], back);
        Assert.False(session.HasChanges);
        // After undoing, a new change is measured against the same starting values.
        session.Set("Theme", "System");
        Assert.False(session.HasChanges);
    }

    [Fact]
    public void UnknownSettingsAreRefused() =>
        Assert.Throws<ArgumentException>(() => Open().Set("Nope", 1));
}
