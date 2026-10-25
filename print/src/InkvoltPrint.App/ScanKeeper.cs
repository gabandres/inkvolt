using System.IO;
using System.Runtime.CompilerServices;
using System.Windows.Threading;
using InkvoltPrint.App.ViewModels;
using InkvoltPrint.Core.Imaging;

namespace InkvoltPrint.App;

/// <summary>
/// Unsaved scans survive a crash, a killed process or Windows signing out: every few seconds each printer's unsaved pages
/// are copied to disk in the background (<see cref="ScanRecoveryStore"/>; a page once, its review edits in the list), a
/// scan saved or cleared is forgotten, and a clean exit removes them all. Pages a run left are put back, as they were, in
/// the Scan tab of the printer they were scanned on once its scanner is there (another printer's after a minute when
/// that printer is no longer listed), with the printer shown.
/// </summary>
internal sealed class ScanKeeper : IDisposable
{
    private static readonly TimeSpan Interval = TimeSpan.FromSeconds(3), WaitForPrinter = TimeSpan.FromMinutes(1);

    private readonly MainViewModel _vm;
    private readonly string _root;
    private readonly DispatcherTimer _timer;
    private readonly DateTime _started = DateTime.UtcNow;
    private readonly ConditionalWeakTable<ScanPageViewModel, string> _files = [];
    private readonly Dictionary<string, string> _kept = []; // printer id → what its list says, to write only changes
    private readonly List<LeftOverScan> _pending;
    private ScanRecoveryStore? _store;
    private Task _queue = Task.CompletedTask; // store work in order, off the UI thread
    private bool _ended;

    public ScanKeeper(MainViewModel vm, string root)
    {
        _vm = vm;
        _root = root;
        try
        {
            ScanRecoveryStore.DiscardEmpty(root);
            _pending = [.. ScanRecoveryStore.FindLeftOver(root)];
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            Log.Write($"Looking for unsaved scans failed: {ex.Message}");
            _pending = [];
        }
        if (_pending.Count > 0) Log.Write($"Unsaved scans left by an earlier run: {_pending.Count}");
        _timer = new DispatcherTimer(DispatcherPriority.Background) { Interval = Interval };
        _timer.Tick += (_, _) =>
        {
            RestorePending();
            Keep();
        };
        _timer.Start();
    }

    /// <summary>Copies what changed since the last pass. <paramref name="wait"/>: finish before returning.</summary>
    public void Keep(bool wait = false)
    {
        if (_ended) return;
        var listed = new HashSet<string>();
        foreach (var printer in _vm.Printers)
        {
            listed.Add(printer.Uuid);
            if (printer.Scan is not { HasUnsavedPages: true } scan)
            {
                if (_kept.Remove(printer.Uuid)) Forget(printer.Uuid);
                continue;
            }
            var fresh = new List<(string Name, byte[] Jpeg)>();
            var pages = scan.Pages.Select(p =>
            {
                if (!_files.TryGetValue(p, out var name))
                {
                    name = ScanRecoveryStore.NewPageName();
                    _files.Add(p, name);
                    fresh.Add((name, p.Original));
                }
                return new KeptPage(name, p.Dpi, p.Ocr, p.Edits.QuarterTurns, p.Edits.Deskew, p.Edits.Crop, p.IsSkipped, p.StartsFile);
            }).ToList();
            var says = string.Join("|", pages);
            if (_kept.TryGetValue(printer.Uuid, out var before) && before == says) continue;
            _kept[printer.Uuid] = says;
            var kept = new KeptScan(printer.Uuid, printer.Name, DateTime.UtcNow, pages);
            Enqueue(store =>
            {
                foreach (var (name, jpeg) in fresh) store.KeepPage(name, jpeg);
                store.Keep(kept);
            });
        }
        foreach (var gone in _kept.Keys.Where(id => !listed.Contains(id)).ToList())
        {
            _kept.Remove(gone);
            Forget(gone);
        }
        if (wait) _queue.Wait(TimeSpan.FromSeconds(10));
    }

    private void Forget(string printerId) => Enqueue(store => store.Forget(printerId));

    /// <summary>Left-over scans go back into a Scan tab once one can take them (its scanner connected, not busy).</summary>
    private void RestorePending()
    {
        foreach (var left in _pending.ToList())
        {
            var own = _vm.Printers.FirstOrDefault(p => p.Uuid == left.Scan.PrinterId);
            var target = own ?? (DateTime.UtcNow - _started > WaitForPrinter ? _vm.Printers.FirstOrDefault(p => p.Scan is not null) : null);
            if (target?.Scan is not { IsBusy: false } scan) continue;
            List<(byte[], KeptPage)> pages;
            try
            {
                pages = [.. left.Scan.Pages.Select(p => (File.ReadAllBytes(left.PagePath(p)), p))];
            }
            catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
            {
                Log.Write($"Unsaved scan couldn't be read back: {ex.Message}");
                _pending.Remove(left);
                continue;
            }
            _pending.Remove(left);
            scan.Restore(pages);
            _vm.Selected = target;
            target.SelectedSection = PrinterViewModel.ScanSection;
            Log.Write($"Restored {pages.Count} unsaved scanned pages");
            // This run keeps its own copy first, so a crash right now still finds the pages.
            Keep();
            var done = left;
            Enqueue(_ => ScanRecoveryStore.Remove(done));
        }
    }

    private void Enqueue(Action<ScanRecoveryStore> work)
    {
        _queue = _queue.ContinueWith(_ =>
        {
            try
            {
                _store ??= ScanRecoveryStore.Start(_root);
                work(_store);
            }
            catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
            {
                Log.Write($"Keeping unsaved scans on disk failed: {ex.Message}");
            }
        }, TaskScheduler.Default);
    }

    /// <summary>Windows is signing out: the scans are written now and stay for the next start, unasked.</summary>
    public void KeepForNextStart()
    {
        if (_ended) return;
        Keep(wait: true);
        _ended = true;
        _timer.Stop();
        _queue.Wait(TimeSpan.FromSeconds(10));
        _store?.KeepForNextStart();
    }

    /// <summary>A clean exit: scans were saved, or the user chose to close without them.</summary>
    public void Dispose()
    {
        if (_ended) return;
        _ended = true;
        _timer.Stop();
        _queue.Wait(TimeSpan.FromSeconds(10));
        _store?.Dispose();
    }
}
