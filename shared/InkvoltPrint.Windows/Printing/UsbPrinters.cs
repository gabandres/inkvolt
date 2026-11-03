using System.ComponentModel;
using System.Runtime.InteropServices;
using InkvoltPrint.Core.Queues;
using Microsoft.Win32;
using Windows.Devices.Enumeration;

namespace InkvoltPrint.Windows.Printing;

/// <summary>What a look at the PC's USB printers found: those that need their driver, and whether Windows protected print mode is on.</summary>
public sealed record NeedsDriverRead(IReadOnlyList<NeedsDriverPrinter> Printers, bool ProtectedPrint)
{
    public static NeedsDriverRead None { get; } = new([], false);
}

public enum UsbSetUpOutcome { Done, NeedsAdmin, Failed }

public sealed record UsbSetUpResult(UsbSetUpOutcome Outcome, string Message, string? Queue = null);

/// <summary>
/// USB printers Windows sees that nothing can print to (<see cref="NeedsDriver"/>), read only and as the signed-in user: the PnP
/// device nodes (<c>USBPRINT\…</c>, and printer-class USB devices with no driver), the spooler's drivers, and Windows protected
/// print mode's policy value. A node's instance id (it ends in the printer's serial number) is used only to read its port and is
/// never kept, logged or shown. "Set it up" (<see cref="SetUpAsync"/>) is the one thing that changes anything, and only when asked.
/// </summary>
public static class UsbPrinters
{
    private const string Present = "System.Devices.Present", Container = "System.Devices.ContainerId", HardwareIds = "System.Devices.HardwareIds",
        CompatibleIds = "System.Devices.CompatibleIds",
        DriverDescription = "{a8b865dd-2e3d-4094-ad97-e593a70c75d6} 4", DriverInf = "{a8b865dd-2e3d-4094-ad97-e593a70c75d6} 5",
        DriverSection = "{a8b865dd-2e3d-4094-ad97-e593a70c75d6} 6", ProblemCode = "{4340a6c5-93fa-4706-972c-7b648008a5a7} 3";

    private static readonly string[] Properties = [Present, Container, HardwareIds, CompatibleIds, DriverDescription, DriverInf, DriverSection, ProblemCode];

    /// <summary>The printers needing their driver now (none when Windows can't be asked), given the queues just read.</summary>
    public static async Task<NeedsDriverRead> ReadAsync(IReadOnlyList<SpoolerQueue> queues, CancellationToken ct = default)
    {
        var nodes = await NodesAsync(includeAbsent: false, ct);
        if (nodes.Count == 0) return NeedsDriverRead.None; // no USB printer plugged in: nothing more to ask
        var found = NeedsDriver.Find(nodes, queues, Drivers());
        return new NeedsDriverRead(found, found.Count > 0 && ProtectedPrintOn());
    }

    /// <summary>
    /// The USB printer device nodes (USBPRINT, and USB devices of the printer class that have a driver problem); with
    /// <paramref name="includeAbsent"/> also those Windows remembers but doesn't see now (the CLI's <c>queues --unplugged</c>).
    /// </summary>
    public static async Task<IReadOnlyList<UsbPrinterNode>> NodesAsync(bool includeAbsent, CancellationToken ct = default)
    {
        var present = includeAbsent ? "" : $" AND {Present}:=System.StructuredQueryType.Boolean#True";
        var list = new List<UsbPrinterNode>();
        try
        {
            var printNodes = await DeviceInformation.FindAllAsync($"System.Devices.DeviceInstanceId:~<\"USBPRINT\\\"{present}", Properties, DeviceInformationKind.Device).AsTask(ct);
            list.AddRange(printNodes.Select(d => Node(d, UsbNodeKind.UsbPrint)));
            // AQS can't match one entry of a list property (compatible ids): the USB devices are few, picked here.
            var usb = await DeviceInformation.FindAllAsync($"System.Devices.DeviceInstanceId:~<\"USB\\\"{present}", Properties, DeviceInformationKind.Device).AsTask(ct);
            list.AddRange(usb.Select(d => Node(d, UsbNodeKind.UsbDevice)).Where(n => NeedsDriver.IsPrinterClass(n) && (n.ProblemCode != 0 || n.DriverInf is null)));
        }
        catch (Exception ex) when (ex is not (OperationCanceledException or OutOfMemoryException))
        {
            System.Diagnostics.Trace.WriteLine($"usb printers: {ex.Message}"); // no PnP answer: nothing listed
        }
        return list;
    }

    private static UsbPrinterNode Node(DeviceInformation d, UsbNodeKind kind)
    {
        string? Text(string key) => d.Properties.TryGetValue(key, out var v) && v is string s && s.Length > 0 ? s : null;
        string[] Texts(string key) => d.Properties.TryGetValue(key, out var v) && v is string[] a ? a : [];
        // USBPRINT\<MFG+MDL>\<instance>: only the middle part is kept (the USB device's own id ends in its serial number).
        var parts = d.Id.Split('\\');
        return new UsbPrinterNode(kind, d.Properties.TryGetValue(Present, out var p) && p is true)
        {
            FriendlyName = d.Name,
            DeviceIdName = kind == UsbNodeKind.UsbPrint && parts.Length >= 2 ? parts[1] : null,
            HardwareIds = Texts(HardwareIds),
            CompatibleIds = Texts(CompatibleIds),
            DriverInf = Text(DriverInf),
            DriverSection = Text(DriverSection),
            DriverDescription = Text(DriverDescription),
            ProblemCode = d.Properties.TryGetValue(ProblemCode, out var code) && code is uint c ? (int)c : 0,
            Port = kind == UsbNodeKind.UsbPrint ? PortOf(d.Id) : null,
            ContainerId = d.Properties.TryGetValue(Container, out var g) && g is Guid guid ? guid.ToString("D") : null,
        };
    }

    /// <summary>The port usbprint gave the printer, from its device parameters (readable by every user).</summary>
    private static string? PortOf(string instanceId)
    {
        try
        {
            using var key = Registry.LocalMachine.OpenSubKey($@"SYSTEM\CurrentControlSet\Enum\{instanceId}\Device Parameters");
            return key?.GetValue("PortName") as string;
        }
        catch (Exception ex) when (ex is System.Security.SecurityException or UnauthorizedAccessException or IOException)
        {
            return null;
        }
    }

    /// <summary>Windows protected print mode (Windows 11 24H2 and later): only Microsoft's own drivers print while it's on.</summary>
    public static bool ProtectedPrintOn()
    {
        try
        {
            using var key = Registry.LocalMachine.OpenSubKey(@"SOFTWARE\Policies\Microsoft\Windows NT\Printers\WPP");
            return key?.GetValue("WindowsProtectedPrintMode") is int mode && mode == 1;
        }
        catch (Exception ex) when (ex is System.Security.SecurityException or UnauthorizedAccessException or IOException)
        {
            return false;
        }
    }

    // ---------------------------------------------------------------- the spooler's drivers, and setting a queue up

    /// <summary>The printer drivers the spooler has for this PC's Windows (<c>EnumPrinterDrivers</c>, level 6); none when it doesn't answer.</summary>
    public static IReadOnlyList<SpoolerDriver> Drivers()
    {
        try
        {
            EnumPrinterDrivers(null, null, 6, IntPtr.Zero, 0, out var needed, out _);
            if (needed == 0) return [];
            var buf = Marshal.AllocHGlobal((int)needed);
            try
            {
                if (!EnumPrinterDrivers(null, null, 6, buf, needed, out _, out var count)) throw new Win32Exception(Marshal.GetLastWin32Error());
                var size = Marshal.SizeOf<DriverInfo6>();
                var list = new List<SpoolerDriver>((int)count);
                for (var i = 0; i < count; i++)
                {
                    var d = Marshal.PtrToStructure<DriverInfo6>(buf + i * size);
                    if (d.Name is { Length: > 0 } name) list.Add(new SpoolerDriver(name, d.HardwareId, d.MfgName));
                }
                return list;
            }
            finally
            {
                Marshal.FreeHGlobal(buf);
            }
        }
        catch (Win32Exception ex)
        {
            System.Diagnostics.Trace.WriteLine($"printer drivers: {ex.Message}");
            return [];
        }
    }

    private const int AccessDenied = 5, PrinterAlreadyExists = 1802, UnknownPort = 1796, UnknownDriver = 1797;

    /// <summary>
    /// Makes the printer's queue on its USB port with its installed driver (<c>AddPrinter</c>, as the signed-in user: no prompt). Windows
    /// may want an administrator for it: then <see cref="UsbSetUpOutcome.NeedsAdmin"/>, and nothing is changed.
    /// </summary>
    public static Task<UsbSetUpResult> SetUpAsync(NeedsDriverPrinter p) => Task.Run(() =>
    {
        if (p.Port is not { Length: > 0 } port || p.Driver is not { Length: > 0 } driver)
            return new UsbSetUpResult(UsbSetUpOutcome.Failed, NeedsDriverText.SetUpFailed(NeedsDriverText.FailedNoPort));
        for (var attempt = 1; attempt <= 3; attempt++)
        {
            var name = attempt == 1 ? p.Name : $"{p.Name} ({attempt})";
            var info = new PrinterInfo2 { PrinterName = name, PortName = port, DriverName = driver, PrintProcessor = "winprint", Datatype = "RAW" };
            var h = AddPrinter(null, 2, ref info);
            if (h != IntPtr.Zero)
            {
                ClosePrinter(h);
                return new UsbSetUpResult(UsbSetUpOutcome.Done, NeedsDriverText.SetUpDone(name), name);
            }
            var error = Marshal.GetLastWin32Error();
            if (error == PrinterAlreadyExists) continue; // a queue elsewhere has its name
            return error switch
            {
                AccessDenied => new UsbSetUpResult(UsbSetUpOutcome.NeedsAdmin, NeedsDriverText.SetUpNeedsAdmin(p)),
                UnknownPort => new UsbSetUpResult(UsbSetUpOutcome.Failed, NeedsDriverText.SetUpFailed(NeedsDriverText.FailedUnknownPort(port))),
                UnknownDriver => new UsbSetUpResult(UsbSetUpOutcome.Failed, NeedsDriverText.SetUpFailed(NeedsDriverText.FailedUnknownDriver)),
                _ => new UsbSetUpResult(UsbSetUpOutcome.Failed, NeedsDriverText.SetUpFailed(new Win32Exception(error).Message)),
            };
        }
        return new UsbSetUpResult(UsbSetUpOutcome.Failed, NeedsDriverText.SetUpFailed(NeedsDriverText.FailedNameTaken));
    });

    /// <summary>Windows' own Add printer wizard (for setting it up by hand when an administrator is needed).</summary>
    public static void OpenAddPrinterWizard()
    {
        try
        {
            System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo(Path.Combine(Environment.SystemDirectory, "rundll32.exe"), "printui.dll,PrintUIEntry /il")
                { UseShellExecute = false })?.Dispose();
        }
        catch (Exception ex) when (ex is Win32Exception or InvalidOperationException)
        {
            System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo(DriverHelp.WindowsPrinters) { UseShellExecute = true })?.Dispose();
        }
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct DriverInfo6
    {
        public uint Version;
        public string? Name, Environment, DriverPath, DataFile, ConfigFile, HelpFile;
        public IntPtr DependentFiles;
        public string? MonitorName, DefaultDataType;
        public IntPtr PreviousNames;
        public long DriverDate;
        public ulong DriverVersion;
        public string? MfgName, OemUrl, HardwareId, Provider;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct PrinterInfo2
    {
        public string? ServerName, PrinterName, ShareName, PortName, DriverName, Comment, Location;
        public IntPtr DevMode;
        public string? SepFile, PrintProcessor, Datatype, Parameters;
        public IntPtr SecurityDescriptor;
        public uint Attributes, Priority, DefaultPriority, StartTime, UntilTime, Status, Jobs, AveragePpm;
    }

    [DllImport("winspool.drv", EntryPoint = "EnumPrinterDriversW", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool EnumPrinterDrivers(string? server, string? environment, uint level, IntPtr buf, uint cb, out uint needed, out uint returned);

    [DllImport("winspool.drv", EntryPoint = "AddPrinterW", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern IntPtr AddPrinter(string? server, uint level, ref PrinterInfo2 info);

    [DllImport("winspool.drv", SetLastError = true)]
    private static extern bool ClosePrinter(IntPtr handle);
}

/// <summary>
/// Says when a USB printer comes or goes (a PnP watcher on USBPRINT device nodes), so the printer list looks again at once rather
/// than at its next 30-second read. Raised from a worker thread; nothing about the device is passed on.
/// </summary>
public sealed class UsbPrinterWatcher : IDisposable
{
    private readonly DeviceWatcher _watcher;
    private bool _enumerated;

    public event Action? Changed;

    public UsbPrinterWatcher()
    {
        _watcher = DeviceInformation.CreateWatcher("System.Devices.DeviceInstanceId:~<\"USBPRINT\\\"", ["System.Devices.Present"], DeviceInformationKind.Device);
        _watcher.Added += (_, _) => Raise();
        _watcher.Updated += (_, _) => Raise();
        _watcher.Removed += (_, _) => Raise();
        _watcher.EnumerationCompleted += (_, _) => _enumerated = true;
    }

    private void Raise()
    {
        if (_enumerated) Changed?.Invoke(); // not for the nodes already there at the start
    }

    public void Start()
    {
        try { _watcher.Start(); }
        catch (Exception ex) when (ex is not OutOfMemoryException) { System.Diagnostics.Trace.WriteLine($"usb printer watcher: {ex.Message}"); }
    }

    public void Dispose()
    {
        try
        {
            if (_watcher.Status is DeviceWatcherStatus.Started or DeviceWatcherStatus.EnumerationCompleted) _watcher.Stop();
        }
        catch (Exception ex) when (ex is not OutOfMemoryException) { System.Diagnostics.Trace.WriteLine($"usb printer watcher: {ex.Message}"); }
    }
}
