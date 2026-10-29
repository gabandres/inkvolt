using System.Text.Json;
using InkvoltPrint.Core.Suite;

namespace InkvoltPrint.Tests;

/// <summary>When both apps ask for a Microsoft Store rating: once, after the app has done its job a few times on different days.</summary>
public class RatingPromptTests
{
    private static readonly DateTimeOffset Day0 = new(2026, 11, 2, 9, 0, 0, TimeSpan.FromHours(-4));

    private static RatingProgress Done(int times, DateTimeOffset first)
    {
        var progress = new RatingProgress();
        for (var i = 0; i < times; i++) progress = progress.Record(first.AddMinutes(i));
        return progress;
    }

    [Fact]
    public void NewInstallNeverAsks()
    {
        Assert.False(new RatingProgress().ShouldAsk(Day0));
        Assert.False(new RatingProgress().ShouldAsk(Day0.AddYears(1)));
    }

    [Fact]
    public void AsksAfterEnoughSuccessesOnceTheFirstIsOldEnough()
    {
        var progress = Done(RatingProgress.SuccessesNeeded, Day0);
        Assert.False(progress.ShouldAsk(Day0.AddHours(3))); // same session: too soon
        Assert.False(progress.ShouldAsk(Day0 + RatingProgress.Wait - TimeSpan.FromMinutes(1)));
        Assert.True(progress.ShouldAsk(Day0 + RatingProgress.Wait));
    }

    [Fact]
    public void FewerSuccessesNeverAsk()
    {
        var progress = Done(RatingProgress.SuccessesNeeded - 1, Day0);
        Assert.False(progress.ShouldAsk(Day0.AddDays(30)));
    }

    [Fact]
    public void AsksOnlyOnceEvenIfDismissed()
    {
        var progress = Done(RatingProgress.SuccessesNeeded, Day0);
        var later = Day0.AddDays(5);
        Assert.True(progress.ShouldAsk(later));
        var asked = progress.MarkAsked(later);
        Assert.False(asked.ShouldAsk(later));
        Assert.False(asked.Record(later.AddDays(1)).ShouldAsk(later.AddDays(60)));
        Assert.Equal(later, asked.MarkAsked(later.AddDays(9)).Asked); // the first ask is kept
    }

    [Fact]
    public void FirstSuccessIsKeptAndCountsGrow()
    {
        var progress = new RatingProgress().Record(Day0).Record(Day0.AddDays(3));
        Assert.Equal(2, progress.Successes);
        Assert.Equal(Day0, progress.FirstSuccess);
    }

    [Fact]
    public void ClockSetBackDoesNotAsk()
    {
        var progress = Done(RatingProgress.SuccessesNeeded, Day0);
        Assert.False(progress.ShouldAsk(Day0.AddDays(-3)));
    }

    [Fact]
    public void MergingTwoWindowsKeepsTheAskAndTheHigherCount()
    {
        var asked = Done(RatingProgress.SuccessesNeeded, Day0).MarkAsked(Day0.AddDays(3));
        var other = Done(RatingProgress.SuccessesNeeded + 2, Day0.AddDays(1));
        var merged = RatingProgress.Merge(other, asked)!;
        Assert.Equal(RatingProgress.SuccessesNeeded + 2, merged.Successes);
        Assert.Equal(Day0, merged.FirstSuccess);
        Assert.Equal(Day0.AddDays(3), merged.Asked);
        Assert.False(merged.ShouldAsk(Day0.AddDays(10)));
        Assert.Same(asked, RatingProgress.Merge(null, asked));
        Assert.Same(asked, RatingProgress.Merge(asked, null));
        Assert.Null(RatingProgress.Merge(null, null));
    }

    [Fact]
    public void RoundTripsThroughSettingsJson()
    {
        var progress = Done(RatingProgress.SuccessesNeeded, Day0).MarkAsked(Day0.AddDays(4));
        var back = JsonSerializer.Deserialize<RatingProgress>(JsonSerializer.Serialize(progress));
        Assert.Equal(progress, back);
        Assert.Equal(new RatingProgress(), JsonSerializer.Deserialize<RatingProgress>("{}"));
    }
}
