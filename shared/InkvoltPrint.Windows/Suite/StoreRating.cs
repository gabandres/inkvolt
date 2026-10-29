using Windows.Services.Store;

namespace InkvoltPrint.Windows.Suite;

/// <summary>
/// Shows the Microsoft Store's own "Rate and review" window for the running app (packaged installs only). Windows' Store
/// service already knows the package: nothing about the user or their documents is sent. When to ask:
/// <see cref="Core.Suite.RatingProgress"/>.
/// </summary>
public static class StoreRating
{
    /// <summary>
    /// Opens the rating window over <paramref name="owner"/> (a desktop app must give the Store a window first). Returns
    /// what the Store reported, for the log.
    /// </summary>
    public static async Task<string> RequestAsync(IntPtr owner)
    {
        if (!AppPackage.IsPackaged) return "not packaged";
        var context = StoreContext.GetDefault();
        if (owner != IntPtr.Zero) WinRT.Interop.InitializeWithWindow.Initialize(context, owner);
        var result = await context.RequestRateAndReviewAppAsync();
        return result.ExtendedError is { } error ? $"{result.Status} ({error.Message})" : result.Status.ToString();
    }
}
