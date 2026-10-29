using System.Windows.Interop;
using InkvoltPrint.Core.Suite;
using InkvoltPrint.Windows.Suite;

namespace InkvoltPdf.App;

/// <summary>
/// The one Microsoft Store rating request (packaged installs): each saved document counts, and once
/// <see cref="RatingProgress"/> says so, the Store's own "Rate and review" window opens a moment after the save. Never again
/// after that, whatever the person chose.
/// </summary>
public partial class MainWindow
{
    private static readonly TimeSpan RatingDelay = TimeSpan.FromSeconds(3);

    private void NoteSavedForRating()
    {
        if (!AppEnvironment.IsPackaged || AppSettings.ReadOnly) return;
        var settings = AppSettings.Current;
        var now = DateTimeOffset.Now;
        var progress = (settings.Rating ?? new()).Record(now);
        var ask = progress.ShouldAsk(now);
        settings.Rating = ask ? progress.MarkAsked(now) : progress;
        settings.Save();
        if (ask) _ = AskForRatingAsync();
    }

    private async Task AskForRatingAsync()
    {
        try
        {
            await Task.Delay(RatingDelay); // after the "Saved" toast, not over it
            if (_closed) return;
            Log.Write($"Store rating request: {await StoreRating.RequestAsync(new WindowInteropHelper(this).Handle)}");
        }
        catch (Exception ex)
        {
            Log.Write($"Store rating request failed: {ex.Message}"); // never a reason to bother the user
        }
    }
}
