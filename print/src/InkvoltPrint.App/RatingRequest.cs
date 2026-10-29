using System.Windows;
using System.Windows.Interop;
using InkvoltPrint.Core.Suite;
using InkvoltPrint.Windows;
using InkvoltPrint.Windows.Suite;

namespace InkvoltPrint.App;

/// <summary>
/// The one Microsoft Store rating request (packaged installs, never in demo mode): each saved scan and each print sent
/// counts, and once <see cref="RatingProgress"/> says so, the Store's own "Rate and review" window opens a moment later over
/// the main window (a job done while the window is hidden in the notification area counts but doesn't ask). Never again
/// after that, whatever the person chose.
/// </summary>
internal static class RatingRequest
{
    private static readonly TimeSpan Delay = TimeSpan.FromSeconds(3);

    /// <summary>Call on the UI thread after the app did its job.</summary>
    public static void NoteSuccess(AppState state)
    {
        if (!AppPackage.IsPackaged || state.IsInMemory) return;
        var now = DateTimeOffset.Now;
        var progress = (state.Rating ?? new()).Record(now);
        // A job finished from the notification area (a preset) counts, and the ask waits for one done with the window open.
        var window = Application.Current?.MainWindow is { IsVisible: true } w ? w : null;
        var ask = window is not null && progress.ShouldAsk(now);
        state.Rating = ask ? progress.MarkAsked(now) : progress;
        state.Save();
        if (ask) _ = AskAsync(window!);
    }

    private static async Task AskAsync(Window window)
    {
        try
        {
            await Task.Delay(Delay); // after the "Saved" or "Sent" message, not over it
            Log.Write($"Store rating request: {await StoreRating.RequestAsync(new WindowInteropHelper(window).Handle)}");
        }
        catch (Exception ex)
        {
            Log.Write($"Store rating request failed: {ex.Message}"); // never a reason to bother the user
        }
    }
}
