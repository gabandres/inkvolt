using System.Windows;
using System.Windows.Interop;
using InkvoltPdf.Core;
using Windows.Services.Store;

namespace InkvoltPdf.App;

/// <summary>
/// The Microsoft Store's update calls for a packaged install (Windows.Services.Store). Talks only to Windows' own Store
/// service, which already knows the package: nothing about the user or their documents is sent. The StoreContext is tied to
/// the main window (a desktop app must give it a window before any Request* call, so the Store's install UI has an owner).
/// </summary>
internal sealed class StoreUpdates(Window owner) : IStoreUpdates
{
    private StoreContext? _context;
    private IReadOnlyList<StorePackageUpdate> _found = [];

    private StoreContext Context()
    {
        if (_context is not null) return _context;
        var context = StoreContext.GetDefault();
        var hwnd = new WindowInteropHelper(owner).Handle;
        if (hwnd != IntPtr.Zero) WinRT.Interop.InitializeWithWindow.Initialize(context, hwnd);
        return _context = context;
    }

    public async Task<StoreUpdateInfo> FindAsync(CancellationToken cancel = default)
    {
        var updates = await Context().GetAppAndOptionalStorePackageUpdatesAsync().AsTask(cancel);
        _found = updates;
        return new StoreUpdateInfo(updates.Count, updates.Any(u => u.Mandatory));
    }

    public async Task<StoreInstallOutcome> InstallAsync(CancellationToken cancel = default)
    {
        if (_found.Count == 0) await FindAsync(cancel);
        if (_found.Count == 0) return StoreInstallOutcome.Completed;
        var result = await Context().RequestDownloadAndInstallStorePackageUpdatesAsync(_found).AsTask(cancel);
        Log.Write($"Store update install: {result.OverallState}");
        return result.OverallState switch
        {
            StorePackageUpdateState.Completed => StoreInstallOutcome.Completed,
            StorePackageUpdateState.Canceled => StoreInstallOutcome.Canceled,
            _ => StoreInstallOutcome.Failed,
        };
    }
}
