using System.IO;
using System.Windows.Threading;
using InkvoltPdf.Core;

namespace InkvoltPdf.App;

/// <summary>
/// Keeps a recovery copy of every PDF with unsaved changes (<see cref="RecoveryStore"/>, under the data folder's
/// <c>recovery</c>), so a crash, a killed process or a power cut doesn't lose them: copies are written in the background
/// at most every <see cref="Interval"/> after a change, removed when the document is saved, back at its saved state or
/// closed, and the whole folder goes on a clean exit. Settings › "Keep recovery copies" turns it off.
/// </summary>
internal sealed class Autosave : IDisposable
{
    public static readonly TimeSpan Interval = TimeSpan.FromSeconds(20);
    public static string Root => Path.Combine(AppPaths.DataDirectory, "recovery");

    private sealed class Entry(string id)
    {
        public string Id { get; } = id;
        public byte[]? Written; // the bytes last copied (documents swap in new arrays on every change)
    }

    private readonly Func<IReadOnlyList<DocumentTab>> _tabs;
    private readonly Dictionary<DocumentTab, Entry> _entries = [];
    private readonly DispatcherTimer _timer;
    private RecoveryStore? _store;
    private Task _queue = Task.CompletedTask; // store work, one after the other, off the UI thread

    public Autosave(Func<IReadOnlyList<DocumentTab>> tabs)
    {
        _tabs = tabs;
        _timer = new DispatcherTimer(DispatcherPriority.Background) { Interval = Interval };
        _timer.Tick += (_, _) => Copy(wait: false);
        _timer.Start();
    }

    private static bool Enabled => AppSettings.Current.KeepRecoveryCopies;

    /// <summary>Copies what changed since the last pass and removes what's saved or closed. <paramref name="wait"/>: finish before returning (Windows signing out).</summary>
    public void Copy(bool wait)
    {
        var open = _tabs();
        foreach (var gone in _entries.Keys.Where(t => !open.Contains(t)).ToList()) Forget(gone);
        if (!Enabled)
        {
            foreach (var t in _entries.Keys.ToList()) Forget(t);
            return;
        }
        foreach (var tab in open)
        {
            var session = tab.Session;
            if (!session.IsPdf) continue;
            if (!session.IsDirty)
            {
                Forget(tab);
                continue;
            }
            if (!_entries.TryGetValue(tab, out var entry)) _entries[tab] = entry = new Entry(Guid.NewGuid().ToString("N"));
            var data = session.Data;
            if (ReferenceEquals(entry.Written, data)) continue;
            entry.Written = data;
            var stamp = session.DiskStampWhenRead;
            var info = new RecoveryInfo(session.DisplayName, session.FilePath, stamp?.Length, stamp?.WriteTimeUtc, DateTime.UtcNow,
                tab.PageView.CurrentPage);
            Enqueue(store => store.Write(entry.Id, data, info));
        }
        if (wait) _queue.Wait(TimeSpan.FromSeconds(10));
    }

    private void Forget(DocumentTab tab)
    {
        if (!_entries.Remove(tab, out var entry) || entry.Written is null) return;
        Enqueue(store => store.Remove(entry.Id));
    }

    private void Enqueue(Action<RecoveryStore> work)
    {
        _queue = _queue.ContinueWith(_ =>
        {
            try
            {
                _store ??= RecoveryStore.Start(Root);
                work(_store);
            }
            catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
            {
                Log.Write($"Recovery copy failed: {ex.Message}");
            }
        }, TaskScheduler.Default);
    }

    /// <summary>A clean exit: every copy goes (the documents were saved, or the user chose not to).</summary>
    public void Dispose()
    {
        _timer.Stop();
        _queue.Wait(TimeSpan.FromSeconds(10));
        _store?.Dispose();
        _store = null;
    }
}
