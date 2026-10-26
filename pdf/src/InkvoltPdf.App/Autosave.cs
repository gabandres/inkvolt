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
        public byte[]? Writing; // the bytes queued to be copied, until the write is done
        public bool Started; // a write was queued: there may be files to remove
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
            if (ReferenceEquals(entry.Written, data) || ReferenceEquals(entry.Writing, data)) continue;
            entry.Writing = data;
            entry.Started = true;
            var stamp = session.DiskStampWhenRead;
            var info = new RecoveryInfo(session.DisplayName, session.FilePath, stamp?.Length, stamp?.WriteTimeUtc, DateTime.UtcNow,
                tab.PageView.CurrentPage);
            // Counted as copied only once written: a failed write (disk full, folder locked) is tried again next pass.
            Enqueue(store => store.Write(entry.Id, data, info), ok =>
            {
                if (ReferenceEquals(entry.Writing, data)) entry.Writing = null;
                if (ok) entry.Written = data;
            });
        }
        if (wait) _queue.Wait(TimeSpan.FromSeconds(10));
    }

    private void Forget(DocumentTab tab)
    {
        if (!_entries.Remove(tab, out var entry) || !entry.Started) return;
        Enqueue(store => store.Remove(entry.Id));
    }

    /// <summary>Queues store work; <paramref name="done"/> (on the UI thread) learns whether it succeeded.</summary>
    private void Enqueue(Action<RecoveryStore> work, Action<bool>? done = null)
    {
        var dispatcher = Dispatcher.CurrentDispatcher;
        _queue = _queue.ContinueWith(_ =>
        {
            var ok = false;
            try
            {
                _store ??= RecoveryStore.Start(Root);
                work(_store);
                ok = true;
            }
            catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
            {
                Log.Write($"Recovery copy failed: {ex.Message}");
            }
            if (done is not null) dispatcher.BeginInvoke(() => done(ok));
        }, TaskScheduler.Default);
    }

    /// <summary>
    /// The window closed without the user settling every document (Windows ended the session): the copies stay, and the
    /// next start offers them (the run's lock goes when the process ends).
    /// </summary>
    public void Keep()
    {
        _timer.Stop();
        _queue.Wait(TimeSpan.FromSeconds(10));
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
