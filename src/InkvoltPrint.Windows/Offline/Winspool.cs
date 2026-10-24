using System.ComponentModel;
using System.Runtime.InteropServices;
using InkvoltPrint.Core.Printing;
using Microsoft.Win32.SafeHandles;

namespace InkvoltPrint.Windows.Offline;

/// <summary>
/// The few spooler calls the offline fixer needs (winspool.drv), all as the signed-in user. Windows gives the person who
/// set a printer up "Manage this printer" on it (pause, resume, Use Printer Offline) and everyone "Manage documents" on
/// their own jobs; anything else fails with ERROR_ACCESS_DENIED, which callers turn into an elevation or manual steps.
/// </summary>
internal static class Winspool
{
    public const int ErrorAccessDenied = 5;

    private const uint EnumLocal = 0x2;
    private const uint PrinterAccessAdminister = 0x4, PrinterAccessUse = 0x8;
    private const uint ControlResume = 2;
    private const uint JobControlRestart = 4, JobControlDelete = 5;

    public const uint StatusPaused = 0x1, StatusError = 0x2, StatusOffline = 0x80;
    public const uint AttributeWorkOffline = 0x400;

    public sealed record PrinterInfo(string Name, string PortName, uint Status, uint Attributes, uint Jobs);

    public sealed record PortInfo(string Name, string? Monitor, string? Description);

    public static IReadOnlyList<PrinterInfo> LocalPrinters()
    {
        var list = new List<PrinterInfo>();
        foreach (var p in Enumerate<PrinterInfo2>((buf, cb, out needed, out count) => EnumPrinters(EnumLocal, null, 2, buf, cb, out needed, out count)))
            if (p.pPrinterName is { } name) list.Add(new PrinterInfo(name, p.pPortName ?? "", p.Status, p.Attributes, p.cJobs));
        return list;
    }

    public static IReadOnlyList<PortInfo> Ports() =>
        Enumerate<PortInfo2>((buf, cb, out needed, out count) => EnumPorts(null, 2, buf, cb, out needed, out count))
            .Where(p => p.pPortName is not null).Select(p => new PortInfo(p.pPortName!, p.pMonitorName, p.pDescription)).ToList();

    public static IReadOnlyList<QueueJob> Jobs(string printer)
    {
        using var h = Open(printer, PrinterAccessUse) ?? throw new Win32Exception(Marshal.GetLastWin32Error());
        return Enumerate<JobInfo1>((buf, cb, out needed, out count) => EnumJobs(h, 0, 1000, 1, buf, cb, out needed, out count))
            .Select(j => new QueueJob((int)j.JobId, j.pDocument ?? "", (int)j.TotalPages, (int)j.PagesPrinted, (JobStatus)(int)j.Status,
                j.Submitted.ToLocal(), j.pUserName ?? ""))
            .ToList();
    }

    /// <summary>Resume a paused queue. Returns the Win32 error, 0 on success.</summary>
    public static int Resume(string printer)
    {
        using var h = Open(printer, PrinterAccessAdminister | PrinterAccessUse);
        if (h is null) return Marshal.GetLastWin32Error();
        return SetPrinter(h, 0, IntPtr.Zero, ControlResume) ? 0 : Marshal.GetLastWin32Error();
    }

    /// <summary>Clears PRINTER_ATTRIBUTE_WORK_OFFLINE ("Use Printer Offline"). Returns the Win32 error, 0 on success.</summary>
    public static int ClearWorkOffline(string printer)
    {
        using var h = Open(printer, PrinterAccessAdminister | PrinterAccessUse);
        if (h is null) return Marshal.GetLastWin32Error();
        GetPrinter(h, 2, IntPtr.Zero, 0, out var needed);
        if (needed == 0) return Marshal.GetLastWin32Error();
        var buf = Marshal.AllocHGlobal((int)needed);
        try
        {
            if (!GetPrinter(h, 2, buf, needed, out _)) return Marshal.GetLastWin32Error();
            var at = Marshal.OffsetOf<PrinterInfo2>(nameof(PrinterInfo2.Attributes)).ToInt32();
            var attributes = (uint)Marshal.ReadInt32(buf, at);
            if ((attributes & AttributeWorkOffline) == 0) return 0;
            Marshal.WriteInt32(buf, at, (int)(attributes & ~AttributeWorkOffline));
            // A null security descriptor leaves the printer's permissions as they are.
            Marshal.WriteIntPtr(buf, Marshal.OffsetOf<PrinterInfo2>(nameof(PrinterInfo2.pSecurityDescriptor)).ToInt32(), IntPtr.Zero);
            return SetPrinter(h, 2, buf, 0) ? 0 : Marshal.GetLastWin32Error();
        }
        finally
        {
            Marshal.FreeHGlobal(buf);
        }
    }

    /// <summary>Cancel (<paramref name="restart"/> false) or restart jobs. Returns the first Win32 error, 0 when all succeeded.</summary>
    public static int ControlJobs(string printer, IEnumerable<int> jobIds, bool restart)
    {
        using var h = Open(printer, PrinterAccessUse);
        if (h is null) return Marshal.GetLastWin32Error();
        var error = 0;
        foreach (var id in jobIds)
            if (!SetJob(h, (uint)id, 0, IntPtr.Zero, restart ? JobControlRestart : JobControlDelete) && error == 0)
                error = Marshal.GetLastWin32Error();
        return error;
    }

    private static PrinterHandle? Open(string printer, uint access)
    {
        var defaults = new PrinterDefaults { DesiredAccess = access };
        if (OpenPrinter(printer, out var h, ref defaults)) return h;
        h.Dispose();
        return null;
    }

    private delegate bool EnumCall(IntPtr buf, uint cb, out uint needed, out uint count);

    private static List<T> Enumerate<T>(EnumCall call) where T : struct
    {
        call(IntPtr.Zero, 0, out var needed, out _);
        if (needed == 0) return [];
        for (var attempt = 0; attempt < 3; attempt++)
        {
            var buf = Marshal.AllocHGlobal((int)needed);
            try
            {
                if (call(buf, needed, out var more, out var count))
                {
                    var size = Marshal.SizeOf<T>();
                    var list = new List<T>((int)count);
                    for (var i = 0; i < count; i++) list.Add(Marshal.PtrToStructure<T>(buf + i * size));
                    return list;
                }
                const int insufficientBuffer = 122;
                if (Marshal.GetLastWin32Error() != insufficientBuffer) throw new Win32Exception();
                needed = more; // the list grew in between: try again with the new size
            }
            finally
            {
                Marshal.FreeHGlobal(buf);
            }
        }
        throw new Win32Exception(122);
    }

    internal sealed class PrinterHandle() : SafeHandleZeroOrMinusOneIsInvalid(true)
    {
        protected override bool ReleaseHandle() => ClosePrinter(handle);
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct PrinterDefaults
    {
        public IntPtr pDatatype;
        public IntPtr pDevMode;
        public uint DesiredAccess;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct PrinterInfo2
    {
        public string? pServerName, pPrinterName, pShareName, pPortName, pDriverName, pComment, pLocation;
        public IntPtr pDevMode;
        public string? pSepFile, pPrintProcessor, pDatatype, pParameters;
        public IntPtr pSecurityDescriptor;
        public uint Attributes, Priority, DefaultPriority, StartTime, UntilTime, Status, cJobs, AveragePPM;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct PortInfo2
    {
        public string? pPortName, pMonitorName, pDescription;
        public uint fPortType, Reserved;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct SystemTime
    {
        public ushort Year, Month, DayOfWeek, Day, Hour, Minute, Second, Milliseconds;

        /// <summary>The spooler reports submission times in UTC.</summary>
        public readonly DateTime ToLocal()
        {
            try { return new DateTime(Year, Month, Day, Hour, Minute, Second, Milliseconds, DateTimeKind.Utc).ToLocalTime(); }
            catch (ArgumentOutOfRangeException) { return DateTime.Now; }
        }
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct JobInfo1
    {
        public uint JobId;
        public string? pPrinterName, pMachineName, pUserName, pDocument, pDatatype, pStatus;
        public uint Status, Priority, Position, TotalPages, PagesPrinted;
        public SystemTime Submitted;
    }

    [DllImport("winspool.drv", EntryPoint = "OpenPrinterW", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool OpenPrinter(string name, out PrinterHandle handle, ref PrinterDefaults defaults);

    [DllImport("winspool.drv", SetLastError = true)]
    private static extern bool ClosePrinter(IntPtr handle);

    [DllImport("winspool.drv", EntryPoint = "EnumPrintersW", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool EnumPrinters(uint flags, string? name, uint level, IntPtr buf, uint cb, out uint needed, out uint returned);

    [DllImport("winspool.drv", EntryPoint = "EnumPortsW", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool EnumPorts(string? server, uint level, IntPtr buf, uint cb, out uint needed, out uint returned);

    [DllImport("winspool.drv", EntryPoint = "EnumJobsW", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool EnumJobs(PrinterHandle h, uint first, uint count, uint level, IntPtr buf, uint cb, out uint needed, out uint returned);

    [DllImport("winspool.drv", EntryPoint = "GetPrinterW", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool GetPrinter(PrinterHandle h, uint level, IntPtr buf, uint cb, out uint needed);

    [DllImport("winspool.drv", EntryPoint = "SetPrinterW", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool SetPrinter(PrinterHandle h, uint level, IntPtr buf, uint command);

    [DllImport("winspool.drv", EntryPoint = "SetJobW", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool SetJob(PrinterHandle h, uint jobId, uint level, IntPtr job, uint command);
}

/// <summary>The Print Spooler service's state (advapi32; querying needs no special rights, starting or stopping it does).</summary>
internal static class SpoolerService
{
    private const uint ScManagerConnect = 0x1, ServiceQueryStatus = 0x4;

    public static Core.Offline.SpoolerState Query()
    {
        var scm = OpenSCManager(null, null, ScManagerConnect);
        if (scm == IntPtr.Zero) return Core.Offline.SpoolerState.Unknown;
        try
        {
            var svc = OpenService(scm, "Spooler", ServiceQueryStatus);
            if (svc == IntPtr.Zero) return Core.Offline.SpoolerState.Unknown;
            try
            {
                if (!QueryServiceStatus(svc, out var status)) return Core.Offline.SpoolerState.Unknown;
                return status.CurrentState switch
                {
                    1 => Core.Offline.SpoolerState.Stopped,
                    4 => Core.Offline.SpoolerState.Running,
                    2 or 3 or 5 or 6 => Core.Offline.SpoolerState.Changing,
                    _ => Core.Offline.SpoolerState.Unknown, // paused (7) or unexpected
                };
            }
            finally
            {
                CloseServiceHandle(svc);
            }
        }
        finally
        {
            CloseServiceHandle(scm);
        }
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct ServiceStatus
    {
        public uint ServiceType, CurrentState, ControlsAccepted, Win32ExitCode, ServiceSpecificExitCode, CheckPoint, WaitHint;
    }

    [DllImport("advapi32.dll", EntryPoint = "OpenSCManagerW", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern IntPtr OpenSCManager(string? machine, string? database, uint access);

    [DllImport("advapi32.dll", EntryPoint = "OpenServiceW", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern IntPtr OpenService(IntPtr scm, string name, uint access);

    [DllImport("advapi32.dll", SetLastError = true)]
    private static extern bool QueryServiceStatus(IntPtr service, out ServiceStatus status);

    [DllImport("advapi32.dll", SetLastError = true)]
    private static extern bool CloseServiceHandle(IntPtr handle);
}
