using System.ComponentModel;
using System.Runtime.InteropServices;
using InkvoltPrint.Core.Queues;
using Microsoft.Win32.SafeHandles;

namespace InkvoltPrint.Windows.Printing;

/// <summary>
/// Watches the spooler for queues added, deleted or renamed (or moved to another port or driver) and says so through
/// <c>changed</c>, a burst once (<see cref="QueueChangeNotices"/>): <c>FindFirstPrinterChangeNotification</c> on the local
/// print server's handle, opened as the user (read only), asked for add and delete and for the name, port and driver fields, so a
/// queue's status changing while it prints isn't a notice (<see cref="QueueChanges"/>). One thread of its own waits on the
/// notice and a stop event. When the spooler isn't running, or restarts, it tries again every 30 s; the app's own 30 s listing
/// goes on either way.
/// </summary>
public sealed class SpoolerChanges : IDisposable
{
    private static readonly TimeSpan Quiet = TimeSpan.FromMilliseconds(750), Longest = TimeSpan.FromSeconds(3), Retry = TimeSpan.FromSeconds(30);

    private readonly QueueChangeNotices _notices;
    private readonly Action<string> _log;
    private readonly ManualResetEvent _stop = new(false);
    private readonly Thread _thread;

    public SpoolerChanges(Action changed, Action<string> log)
    {
        _notices = new QueueChangeNotices(changed, Quiet, Longest);
        _log = log;
        _thread = new Thread(Run) { IsBackground = true, Name = "Spooler change notices" };
        _thread.Start();
    }

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
                    _log($"Spooler change notices stopped ({ex.Message}); trying again in {Retry.TotalSeconds:0} s");
                }
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
            var fields = GCHandle.Alloc(QueueChanges.Fields, GCHandleType.Pinned);
            var type = new NotifyOptionsType { Type = PrinterNotifyType, Count = (uint)QueueChanges.Fields.Length, Fields = fields.AddrOfPinnedObject() };
            var types = GCHandle.Alloc(new[] { type }, GCHandleType.Pinned);
            try
            {
                var options = new NotifyOptions { Version = 2, Count = 1, Types = types.AddrOfPinnedObject() };
                var change = FindFirstPrinterChangeNotification(server, QueueChanges.AddPrinter | QueueChanges.DeletePrinter, 0, ref options);
                if (change == IntPtr.Zero || change == new IntPtr(-1)) throw new Win32Exception(Marshal.GetLastWin32Error());
                try
                {
                    using var signal = new ChangeHandle(change);
                    while (WaitHandle.WaitAny([_stop, signal]) == 1)
                    {
                        if (!FindNextPrinterChangeNotification(change, out var what, IntPtr.Zero, out var info))
                            throw new Win32Exception(Marshal.GetLastWin32Error());
                        uint flags = 0, count = 0;
                        if (info != IntPtr.Zero)
                        {
                            // PRINTER_NOTIFY_INFO: Version, Flags, Count, then the data (only whether there is any matters here).
                            flags = (uint)Marshal.ReadInt32(info, 4);
                            count = (uint)Marshal.ReadInt32(info, 8);
                            FreePrinterNotifyInfo(info);
                        }
                        if (QueueChanges.NeedsRelist(what, flags, count)) _notices.Notice();
                        if (QueueChanges.NeedsRefresh(flags))
                        {
                            // The spooler dropped notices: until asked for everything again (PRINTER_NOTIFY_OPTIONS_REFRESH) it
                            // sends no more field changes. What it sends back isn't needed: the queues are read again anyway.
                            var refresh = options with { Flags = QueueChanges.OptionsRefresh };
                            if (!FindNextPrinterChangeNotification(change, out _, ref refresh, out var all)) throw new Win32Exception(Marshal.GetLastWin32Error());
                            if (all != IntPtr.Zero) FreePrinterNotifyInfo(all);
                        }
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

    public void Dispose()
    {
        _stop.Set();
        _notices.Dispose(); // no more calls, whatever the thread is doing
        // The stop event is the thread's: closed only once it has ended (a thread still in winspool sees it set later and ends).
        if (_thread.Join(TimeSpan.FromSeconds(2))) _stop.Dispose();
        else _log("Spooler change notices: the watcher didn't stop in time");
    }

    /// <summary>PRINTER_NOTIFY_TYPE (the queue's own fields, not its jobs').</summary>
    private const ushort PrinterNotifyType = 0;

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
