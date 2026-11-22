using System.ComponentModel;
using System.Runtime.InteropServices;
using InkvoltPrint.Core.Queues;
using Microsoft.Win32.SafeHandles;

namespace InkvoltPrint.Windows.Printing;

/// <summary>
/// The spooler's change notices on the local print server's handle (<c>FindFirstPrinterChangeNotification</c>, opened as the user,
/// read only), on one thread of its own that waits on the notice and a stop event: <see cref="SpoolerChanges"/> (queues added, deleted
/// or renamed) and <see cref="SpoolerJobs"/> (every job, for the print log) ask for different changes and fields and read the notices
/// their own way. When the spooler isn't running, or restarts, it tries again every 30 s. After notices were dropped the spooler sends
/// no more field changes until it's asked for everything again (<see cref="QueueChanges.OptionsRefresh"/>), which is done here and
/// handed over as <see cref="OnRefresh"/>.
/// </summary>
public abstract class SpoolerWatcher : IDisposable
{
    private static readonly TimeSpan Retry = TimeSpan.FromSeconds(30);

    private readonly Action<string> _log;
    private readonly ManualResetEvent _stop = new(false);
    private readonly string _name;
    private Thread? _thread;

    /// <param name="filter">PRINTER_CHANGE_* asked for.</param>
    /// <param name="type">PRINTER_NOTIFY_TYPE (0) or JOB_NOTIFY_TYPE (1).</param>
    /// <param name="fields">The fields asked for.</param>
    protected SpoolerWatcher(string name, uint filter, ushort type, ushort[] fields, Action<string> log)
    {
        _name = name;
        Filter = filter;
        Type = type;
        Fields = fields;
        _log = log;
    }

    private uint Filter { get; }
    private ushort Type { get; }
    private ushort[] Fields { get; }

    /// <summary>Starts the thread (from the subclass's constructor, once it's ready for notices).</summary>
    protected void Start()
    {
        _thread = new Thread(Run) { IsBackground = true, Name = _name };
        _thread.Start();
    }

    protected Action<string> Log => _log;

    /// <summary>Watching began (again): the spooler's whole list follows as <see cref="OnRefresh"/> with first true.</summary>
    protected virtual bool AsksForEverythingFirst => false;

    /// <summary>One notice: <paramref name="what"/> (PRINTER_CHANGE_*) and its PRINTER_NOTIFY_INFO (may be zero), freed after.</summary>
    protected abstract void OnNotice(uint what, IntPtr info);

    /// <summary>Everything again, after notices were dropped or (<paramref name="first"/>) as watching begins; the info is freed after.</summary>
    protected virtual void OnRefresh(IntPtr info, bool first) { }

    /// <summary>The watching stopped (the spooler went away, or the app closes).</summary>
    protected virtual void OnStopped() { }

    private void Run()
    {
        try
        {
            while (!_stop.WaitOne(0))
            {
                try
                {
                    Watch();
                }
                catch (Exception ex) when (ex is Win32Exception or ExternalException or InvalidOperationException)
                {
                    _log($"{_name} stopped ({ex.Message}); trying again in {Retry.TotalSeconds:0} s");
                }
                OnStopped();
                if (_stop.WaitOne(Retry)) return;
            }
        }
        catch (ObjectDisposedException)
        {
            // stopped: nothing more to watch
        }
    }

    /// <summary>Until stopped, or the spooler stops answering (it restarted: the handle is no use).</summary>
    private void Watch()
    {
        if (!OpenPrinter(null, out var server, IntPtr.Zero)) throw new Win32Exception(Marshal.GetLastWin32Error());
        using (server)
        {
            var fields = GCHandle.Alloc(Fields, GCHandleType.Pinned);
            var type = new NotifyOptionsType { Type = Type, Count = (uint)Fields.Length, Fields = fields.AddrOfPinnedObject() };
            var types = GCHandle.Alloc(new[] { type }, GCHandleType.Pinned);
            try
            {
                var options = new NotifyOptions { Version = 2, Count = 1, Types = types.AddrOfPinnedObject() };
                var change = FindFirstPrinterChangeNotification(server, Filter, 0, ref options);
                if (change == IntPtr.Zero || change == new IntPtr(-1)) throw new Win32Exception(Marshal.GetLastWin32Error());
                try
                {
                    if (AsksForEverythingFirst) Refresh(change, options, first: true);
                    using var signal = new ChangeHandle(change);
                    while (WaitHandle.WaitAny([_stop, signal]) == 1)
                    {
                        if (!FindNextPrinterChangeNotification(change, out var what, IntPtr.Zero, out var info))
                            throw new Win32Exception(Marshal.GetLastWin32Error());
                        uint flags = 0;
                        try
                        {
                            // PRINTER_NOTIFY_INFO: Version, Flags, Count, then the data.
                            if (info != IntPtr.Zero) flags = (uint)Marshal.ReadInt32(info, 4);
                            OnNotice(what, info);
                        }
                        finally
                        {
                            if (info != IntPtr.Zero) FreePrinterNotifyInfo(info);
                        }
                        if (QueueChanges.NeedsRefresh(flags)) Refresh(change, options, first: false);
                    }
                }
                finally
                {
                    FindClosePrinterChangeNotification(change);
                }
            }
            finally
            {
                types.Free();
                fields.Free();
            }
        }
    }

    private void Refresh(IntPtr change, NotifyOptions options, bool first)
    {
        var refresh = options with { Flags = QueueChanges.OptionsRefresh };
        if (!FindNextPrinterChangeNotification(change, out _, ref refresh, out var all)) throw new Win32Exception(Marshal.GetLastWin32Error());
        if (all == IntPtr.Zero) return;
        try
        {
            OnRefresh(all, first);
        }
        finally
        {
            FreePrinterNotifyInfo(all);
        }
    }

    public void Dispose()
    {
        _stop.Set();
        Stopping();
        // The stop event is the thread's: closed only once it has ended (a thread still in winspool sees it set later and ends).
        if (_thread is null || _thread.Join(TimeSpan.FromSeconds(2))) _stop.Dispose();
        else _log($"{_name}: the watcher didn't stop in time");
        GC.SuppressFinalize(this);
    }

    /// <summary>Dispose began: no more calls out, whatever the thread is doing.</summary>
    protected virtual void Stopping() { }

    // ---------------------------------------------------------------- reading PRINTER_NOTIFY_INFO

    /// <summary>
    /// The items of a PRINTER_NOTIFY_INFO (winspool.h): Version, Flags, Count, then PRINTER_NOTIFY_INFO_DATA items (Type, Field,
    /// Reserved, Id, then a union of two DWORDs or a size and a pointer), laid out as this process's pointer size has them.
    /// </summary>
    protected static IEnumerable<NotifyItem> Items(IntPtr info)
    {
        if (info == IntPtr.Zero) yield break;
        var count = Math.Min((uint)Marshal.ReadInt32(info, 8), 100_000u);
        var wide = IntPtr.Size == 8;
        var first = wide ? 16 : 12;
        var size = wide ? 32 : 20;
        var union = wide ? 16 : 12;
        var pointer = wide ? 8 : 4;
        for (var i = 0; i < count; i++)
        {
            var item = info + first + i * size;
            yield return new NotifyItem(
                (ushort)Marshal.ReadInt16(item, 0),
                (ushort)Marshal.ReadInt16(item, 2),
                Marshal.ReadInt32(item, 8),
                (uint)Marshal.ReadInt32(item, union),
                (uint)Marshal.ReadInt32(item, union),
                Marshal.ReadIntPtr(item, union + pointer));
        }
    }

    /// <summary>One PRINTER_NOTIFY_INFO_DATA: its type and field, the job's (or queue's) id, its number (adwData[0]) or its buffer.</summary>
    protected readonly record struct NotifyItem(ushort Type, ushort Field, int Id, uint Number, uint BufferSize, IntPtr Buffer)
    {
        /// <summary>A string field (a NUL-terminated UTF-16 string in the buffer, at most its size).</summary>
        public string? Text()
        {
            if (Buffer == IntPtr.Zero || BufferSize < 2) return null;
            var chars = (int)Math.Min(BufferSize / 2, 32_768);
            var text = Marshal.PtrToStringUni(Buffer, chars);
            var nul = text.IndexOf('\0');
            return nul >= 0 ? text[..nul] : text;
        }

        /// <summary>The buffer's bytes, at most <paramref name="max"/>.</summary>
        public byte[] Bytes(int max)
        {
            if (Buffer == IntPtr.Zero || BufferSize == 0) return [];
            var bytes = new byte[(int)Math.Min(BufferSize, (uint)max)];
            Marshal.Copy(Buffer, bytes, 0, bytes.Length);
            return bytes;
        }
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct NotifyOptionsType
    {
        public ushort Type, Reserved0;
        public uint Reserved1, Reserved2, Count;
        public IntPtr Fields;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct NotifyOptions
    {
        public uint Version, Flags, Count;
        public IntPtr Types;
    }

    /// <summary>The change notification's handle to wait on (closed by FindClosePrinterChangeNotification, not by this).</summary>
    private sealed class ChangeHandle : WaitHandle
    {
        public ChangeHandle(IntPtr handle) => SafeWaitHandle = new SafeWaitHandle(handle, ownsHandle: false);
    }

    private sealed class ServerHandle() : SafeHandleZeroOrMinusOneIsInvalid(true)
    {
        protected override bool ReleaseHandle() => ClosePrinter(handle);
    }

    [DllImport("winspool.drv", EntryPoint = "OpenPrinterW", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool OpenPrinter(string? name, out ServerHandle handle, IntPtr defaults);

    [DllImport("winspool.drv", SetLastError = true)]
    private static extern bool ClosePrinter(IntPtr handle);

    [DllImport("winspool.drv", SetLastError = true)]
    private static extern IntPtr FindFirstPrinterChangeNotification(ServerHandle printer, uint filter, uint options, ref NotifyOptions notifyOptions);

    [DllImport("winspool.drv", SetLastError = true)]
    private static extern bool FindNextPrinterChangeNotification(IntPtr change, out uint what, IntPtr options, out IntPtr info);

    [DllImport("winspool.drv", SetLastError = true)]
    private static extern bool FindNextPrinterChangeNotification(IntPtr change, out uint what, ref NotifyOptions options, out IntPtr info);

    [DllImport("winspool.drv", SetLastError = true)]
    private static extern bool FindClosePrinterChangeNotification(IntPtr change);

    [DllImport("winspool.drv", SetLastError = true)]
    private static extern bool FreePrinterNotifyInfo(IntPtr info);
}
