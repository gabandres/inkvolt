using System.Text.RegularExpressions;

namespace InkvoltPrint.Core.Queues;

/// <summary>Which kind of USB device node a <see cref="UsbPrinterNode"/> is.</summary>
public enum UsbNodeKind
{
    /// <summary>The printer node <c>usbprint.sys</c> makes (<c>USBPRINT\MFGMDL\…</c>): it takes a printer driver.</summary>
    UsbPrint,

    /// <summary>A USB device of the printer class (<c>USB\Class_07</c>) Windows has no driver for at all (no USBPRINT node under it).</summary>
    UsbDevice,
}

/// <summary>
/// One USB printer device node as Windows has it, read only. Never its instance id: the USB one ends in the printer's serial
/// number, a device identifier that is never stored, logged or shown. <see cref="DeviceIdName"/> is the instance id's middle part
/// (<c>HEWLETT-PACKARDHP_LASERJET_P1006</c>, the IEEE 1284 MFG and MDL joined), which carries no serial.
/// </summary>
public sealed record UsbPrinterNode(UsbNodeKind Kind, bool Present)
{
    public string? FriendlyName { get; init; }

    /// <summary>
    /// What the device itself calls its product (<c>DEVPKEY_Device_BusReportedDeviceDesc</c>: "Epson Perfection V19"): a USB
    /// device with no driver has only this for a name.
    /// </summary>
    public string? BusReportedName { get; init; }

    public string? DeviceIdName { get; init; }
    public IReadOnlyList<string> HardwareIds { get; init; } = [];
    public IReadOnlyList<string> CompatibleIds { get; init; } = [];

    /// <summary>The bound driver's INF (<c>DEVPKEY_Device_DriverInfPath</c>), section and description; null: none.</summary>
    public string? DriverInf { get; init; }

    public string? DriverSection { get; init; }
    public string? DriverDescription { get; init; }

    /// <summary><c>DEVPKEY_Device_ProblemCode</c>: 0 none, 28 no driver installed, 1 not configured, 18 reinstall the drivers.</summary>
    public int ProblemCode { get; init; }

    /// <summary>The USB port usbprint gave it (<c>USB001</c>), from its device parameters.</summary>
    public string? Port { get; init; }

    /// <summary>The PnP container (for matching a queue only: never shown or logged).</summary>
    public string? ContainerId { get; init; }
}

/// <summary>A printer driver the Print Spooler has (<c>DRIVER_INFO_6</c>): what "Set it up" can make a queue with.</summary>
public sealed record SpoolerDriver(string Name, string? HardwareId = null, string? Maker = null);

/// <summary>Where a USB printer without a queue is.</summary>
public enum DriverStage
{
    /// <summary>Windows has no driver for it (only its "Generic printer device" placeholder, or none at all).</summary>
    NoDriver,

    /// <summary>A driver for it is installed, but Windows made no queue: "Set it up".</summary>
    NotSetUp,
}

/// <summary>
/// A USB printer that is plugged in but can't be printed to: Windows has no driver for it, or has one and made no queue. Listed on
/// the printer list with what to do (<see cref="NeedsDriverText"/>).
/// </summary>
/// <param name="Id">"usb-needs-driver:" and its port (or its name): never a UUID, a queue's id or a serial.</param>
/// <param name="Maker">The maker's short name ("HP", "Epson"…), null when not known.</param>
/// <param name="Driver">The installed driver "Set it up" uses (<see cref="DriverStage.NotSetUp"/>), null when none matched.</param>
public sealed record NeedsDriverPrinter(string Id, string Name, string? Maker, string? Port, DriverStage Stage, string? Driver = null)
{
    /// <summary>Made up (demo mode): nothing about it is real.</summary>
    public bool IsMadeUp { get; init; }

    /// <summary>A printer, or a scanner (<see cref="UsbScanners"/>): a scanner is never "set up", only given its driver.</summary>
    public NeedsDriverKind Kind { get; init; } = NeedsDriverKind.Printer;

    /// <summary>Its USB vendor and product ids ("04B8:013C"), the same for every one of the model: never its serial. Null: not known.</summary>
    public string? UsbId { get; init; }

    public bool IsScanner => Kind == NeedsDriverKind.Scanner;
}

/// <summary>What a device needing its driver is.</summary>
public enum NeedsDriverKind { Printer, Scanner }

/// <summary>What a look at the PC's USB printers found: those that need their driver, and whether Windows protected print mode is on.</summary>
public sealed record NeedsDriverRead(IReadOnlyList<NeedsDriverPrinter> Printers, bool ProtectedPrint)
{
    public static NeedsDriverRead None { get; } = new([], false);
}

/// <summary>
/// One look at the PC's USB printers, never on the caller's thread: the printer list asks from the UI thread, and the spooler can
/// hang (<see cref="TimedCalls{TKey,T}"/>). A spooler that doesn't answer in <paramref name="driversLimit"/> leaves the printers
/// listed as having no driver, with one call waiting on it however many looks follow.
/// </summary>
public sealed class NeedsDriverReader(
    Func<CancellationToken, Task<IReadOnlyList<UsbPrinterNode>>> nodes, Func<IReadOnlyList<SpoolerDriver>> drivers, Func<bool> protectedPrint, TimeSpan? driversLimit = null)
{
    private readonly TimedCalls<int, IReadOnlyList<SpoolerDriver>> _drivers = new(driversLimit ?? TimeSpan.FromSeconds(7));

    /// <summary>The printers needing their driver now (none when no USB printer is plugged in), given the queues just read.</summary>
    public Task<NeedsDriverRead> ReadAsync(IReadOnlyList<SpoolerQueue> queues, CancellationToken ct = default) => Task.Run(async () =>
    {
        var found = await nodes(ct).ConfigureAwait(false);
        if (found.Count == 0) return NeedsDriverRead.None; // no USB printer plugged in: nothing more to ask
        var (answered, known) = await _drivers.RunAsync(0, drivers, ct).ConfigureAwait(false);
        var printers = NeedsDriver.Find(found, queues, answered ? known! : []);
        return new NeedsDriverRead(printers, printers.Count > 0 && protectedPrint());
    }, ct);
}

/// <summary>
/// The rules for "Plugged in, needs its driver": which USB printers Windows sees now that nothing can print to. A printer node bound
/// only to Microsoft's placeholder ("Generic printer device", <c>prnms013.inf</c>, <c>CID_MS_GENERICPRINT</c>) or with a driver
/// problem, and no queue on its port or in its container, needs its driver; with a real driver (bound, or in the spooler and
/// matching it) and still no queue, it needs setting up. A printer with a queue is a queue printer; one unplugged is not listed.
/// Host-based printers (most older USB lasers) have no class driver in Windows: only their maker's driver prints to them.
/// </summary>
public static partial class NeedsDriver
{
    private const string IdPrefix = "usb-needs-driver:";

    public static bool IsNeedsDriverId(string? id) => id?.StartsWith(IdPrefix, StringComparison.Ordinal) == true;

    /// <summary>Problem codes that mean "no working driver": not configured (1), reinstall (18), no driver installed (28), failed install (31).</summary>
    private static readonly int[] DriverProblems = [1, 18, 28, 31];

    private const string GenericInf = "prnms013.inf", GenericSection = "MS_GENERICPRINT", GenericCompatible = "CID_MS_GENERICPRINT";

    /// <summary>Bound to Microsoft's placeholder, or to nothing: no real printer driver.</summary>
    public static bool HasOnlyPlaceholder(UsbPrinterNode n) =>
        n.DriverInf is not { Length: > 0 } inf
        || string.Equals(Path.GetFileName(inf), GenericInf, StringComparison.OrdinalIgnoreCase)
        || string.Equals(n.DriverSection, GenericSection, StringComparison.OrdinalIgnoreCase)
        || DriverProblems.Contains(n.ProblemCode);

    /// <summary>The USB printer class (07) among a device's compatible ids.</summary>
    public static bool IsPrinterClass(UsbPrinterNode n) =>
        n.CompatibleIds.Any(c => c.StartsWith(@"USB\Class_07", StringComparison.OrdinalIgnoreCase))
        || n.CompatibleIds.Any(c => string.Equals(c, GenericCompatible, StringComparison.OrdinalIgnoreCase));

    /// <summary>
    /// The USB printers plugged in now that nothing can print to, each once (the order Windows gave): from their device nodes, the
    /// spooler's queues and its drivers.
    /// </summary>
    public static IReadOnlyList<NeedsDriverPrinter> Find(IReadOnlyList<UsbPrinterNode> nodes, IReadOnlyList<SpoolerQueue> queues, IReadOnlyList<SpoolerDriver> drivers)
    {
        var found = new List<NeedsDriverPrinter>();
        var seenContainers = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        var printNodes = nodes.Where(n => n.Present && n.Kind == UsbNodeKind.UsbPrint).ToList();
        foreach (var n in printNodes)
        {
            if (HasQueue(n, queues)) continue; // a queue printer: listed as one
            if (n.ContainerId is { Length: > 0 } c && !seenContainers.Add(c)) continue;
            var name = PrinterNames.ForDevice(n.FriendlyName, n.DeviceIdName, n.HardwareIds);
            var driver = MatchDriver(n, name, drivers);
            var stage = HasOnlyPlaceholder(n) && driver is null ? DriverStage.NoDriver : DriverStage.NotSetUp;
            found.Add(new NeedsDriverPrinter(IdFor(n.Port, name), name, PrinterNames.MakerOf(n.FriendlyName, n.DeviceIdName, n.HardwareIds), n.Port, stage, driver?.Name));
        }
        // A printer-class USB device with no driver at all has no USBPRINT node: no port, so nothing to set up.
        foreach (var n in nodes.Where(n => n.Present && n.Kind == UsbNodeKind.UsbDevice && IsPrinterClass(n) && n.DriverProblem()))
        {
            if (n.ContainerId is { Length: > 0 } c && (!seenContainers.Add(c) || printNodes.Any(p => string.Equals(p.ContainerId, c, StringComparison.OrdinalIgnoreCase))))
                continue;
            if (HasQueue(n, queues)) continue;
            var name = PrinterNames.ForDevice(n.FriendlyName, n.DeviceIdName, n.HardwareIds);
            found.Add(new NeedsDriverPrinter(IdFor(null, name), name, PrinterNames.MakerOf(n.FriendlyName, n.DeviceIdName, n.HardwareIds), null, DriverStage.NoDriver)
                { UsbId = UsbScanners.UsbIdOf(n) });
        }
        // A scanner (or an all-in-one's scanner part) with no driver: listed unless its printer part already is (one entry a device).
        foreach (var n in nodes.Where(n => n.Present && n.Kind == UsbNodeKind.UsbDevice && n.DriverProblem() && !IsPrinterClass(n) && UsbScanners.IsScanner(n)))
        {
            if (n.ContainerId is { Length: > 0 } c && !seenContainers.Add(c)) continue; // its printer part is listed: one entry a device
            if (UsbScanners.UsbIdOf(n) is not { } usbId) continue;
            found.Add(new NeedsDriverPrinter(IdPrefix + "scanner-" + usbId.Replace(':', '-').ToLowerInvariant(), UsbScanners.NameOf(n), UsbScanners.MakerOf(n), null,
                DriverStage.NoDriver) { Kind = NeedsDriverKind.Scanner, UsbId = usbId });
        }
        return found.DistinctBy(p => p.Id, StringComparer.OrdinalIgnoreCase).ToList();
    }

    /// <summary>No working driver: a problem code that says so, or no driver bound at all.</summary>
    public static bool DriverProblem(this UsbPrinterNode n) => DriverProblems.Contains(n.ProblemCode) || n.DriverInf is not { Length: > 0 };

    private static string IdFor(string? port, string name) => IdPrefix + (port is { Length: > 0 } p ? p.Trim().TrimEnd(':') : name).ToLowerInvariant();

    /// <summary>A queue on its port, or in its device container (not the PC's own).</summary>
    public static bool HasQueue(UsbPrinterNode n, IReadOnlyList<SpoolerQueue> queues) =>
        queues.Any(q => !QueueKinds.IsVirtual(q)
                        && (n.Port is { Length: > 0 } port && string.Equals(q.PortName.Trim().TrimEnd(':'), port.Trim().TrimEnd(':'), StringComparison.OrdinalIgnoreCase)
                            || n.ContainerId is { Length: > 0 } c && !string.Equals(c.Trim('{', '}'), QueueKinds.ThisPcContainer, StringComparison.OrdinalIgnoreCase)
                               && string.Equals(q.ContainerId?.Trim('{', '}'), c.Trim('{', '}'), StringComparison.OrdinalIgnoreCase)));

    /// <summary>
    /// The installed spooler driver for this printer: the one whose hardware id is the node's (<c>Hewlett-PackardHP_LaBB7B</c>), else
    /// the node's own bound driver by name, else one named after the model ("HP LaserJet P1006", "HP LaserJet P1006 PCL"). Never a
    /// class driver (Microsoft's IPP, PCL6 or PS class drivers don't print to host-based printers, and USB printers pick theirs by id).
    /// </summary>
    public static SpoolerDriver? MatchDriver(UsbPrinterNode n, string name, IReadOnlyList<SpoolerDriver> drivers)
    {
        var real = drivers.Where(d => !IsClassDriver(d.Name)).ToList();
        var ids = n.HardwareIds.Select(h => h.StartsWith(@"USBPRINT\", StringComparison.OrdinalIgnoreCase) ? h[9..] : h).ToHashSet(StringComparer.OrdinalIgnoreCase);
        if (real.FirstOrDefault(d => d.HardwareId is { Length: > 0 } h && ids.Contains(h.StartsWith(@"USBPRINT\", StringComparison.OrdinalIgnoreCase) ? h[9..] : h)) is { } byId)
            return byId;
        if (!HasOnlyPlaceholder(n) && n.DriverDescription is { Length: > 0 } desc
            && real.FirstOrDefault(d => string.Equals(d.Name, desc, StringComparison.OrdinalIgnoreCase)) is { } bound)
            return bound;
        var model = Words(name);
        if (model.Length == 0 || !model.Any(char.IsDigit)) return null; // "HP Printer" would match too much
        return real.FirstOrDefault(d => Words(d.Name) is var w && (w == model || w.StartsWith(model + " ", StringComparison.Ordinal)));
    }

    private static bool IsClassDriver(string name) =>
        name.StartsWith("Microsoft ", StringComparison.OrdinalIgnoreCase) || name.StartsWith("Generic ", StringComparison.OrdinalIgnoreCase)
        || name.Contains("Class Driver", StringComparison.OrdinalIgnoreCase) || name.Contains("Universal Printing", StringComparison.OrdinalIgnoreCase);

    /// <summary>Lower case, the maker's long name as its short one, single spaces: "hewlett-packard hp laserjet p1006" → "hp laserjet p1006".</summary>
    private static string Words(string s) =>
        Spaces().Replace(PrinterNames.ForDevice(s, null, []).ToLowerInvariant(), " ").Trim();

    [GeneratedRegex(@"\s+")]
    private static partial Regex Spaces();
}

/// <summary>
/// A USB printer's name to show, from what Windows has: its friendly name ("Hewlett-Packard HP LaserJet P1006"), else the IEEE 1284
/// MFG and MDL usbprint joined into its ids (<c>USBPRINT\Hewlett-PackardHP_LaserJet_P1006</c>): "HP LaserJet P1006". The maker's
/// long name goes ("Hewlett-Packard" → "HP"), a repeated one is dropped.
/// </summary>
public static partial class PrinterNames
{
    /// <summary>Makers as their IEEE 1284 MFG names come, longest first, and the short name to show.</summary>
    private static readonly (string Mfg, string Short)[] Makers =
    [
        ("Hewlett-Packard", "HP"), ("Hewlett Packard", "HP"), ("KONICA MINOLTA", "Konica Minolta"), ("FUJI XEROX", "Fuji Xerox"),
        ("FUJIFILM", "Fujifilm"), ("OKI DATA CORP", "OKI"), ("Kyocera Mita", "Kyocera"), ("KYOCERA", "Kyocera"), ("SAMSUNG", "Samsung"),
        ("Brother", "Brother"), ("Lexmark", "Lexmark"), ("Panasonic", "Panasonic"), ("Toshiba", "Toshiba"), ("Pantum", "Pantum"),
        ("EPSON", "Epson"), ("Canon", "Canon"), ("Xerox", "Xerox"), ("Ricoh", "Ricoh"), ("Sharp", "Sharp"), ("Zebra", "Zebra"),
        ("DYMO", "Dymo"), ("Dell", "Dell"), ("OKI", "OKI"), ("HP", "HP"),
    ];

    public static string ForDevice(string? friendlyName, string? deviceIdName, IReadOnlyList<string> hardwareIds)
    {
        if (friendlyName?.Trim() is { Length: > 0 } friendly && !IsPlaceholderName(friendly)) return Clean(friendly, joined: false);
        // A hardware id usbprint shortened (20 characters and a 4-digit checksum, "Hewlett-PackardHP_LaBB7B") has only part of the model.
        // USB\VID_…&PID_… (a device with no USBPRINT node) has no name in it.
        foreach (var id in hardwareIds.Where(h => !h.StartsWith(@"USB\", StringComparison.OrdinalIgnoreCase)).Select(StripEnumerator).Where(h => h.Length > 0 && !IsShortened(h)))
            return Clean(id.Replace('_', ' '), joined: true);
        if (deviceIdName?.Trim() is { Length: > 0 } fromId) return Clean(StripEnumerator(fromId).Replace('_', ' '), joined: true);
        return "USB printer";
    }

    /// <summary>The maker's short name, from the same facts; null when not one Inkvolt Print knows.</summary>
    public static string? MakerOf(string? friendlyName, string? deviceIdName, IReadOnlyList<string> hardwareIds)
    {
        var name = ForDevice(friendlyName, deviceIdName, hardwareIds);
        return Makers.Select(m => m.Short).Distinct().FirstOrDefault(s => name.StartsWith(s + " ", StringComparison.OrdinalIgnoreCase));
    }

    private static bool IsPlaceholderName(string s) =>
        s.Equals("Generic printer device", StringComparison.OrdinalIgnoreCase) || s.Equals("USB Printing Support", StringComparison.OrdinalIgnoreCase);

    private static string StripEnumerator(string id)
    {
        var s = id.Trim();
        if (s.StartsWith(@"USBPRINT\", StringComparison.OrdinalIgnoreCase)) s = s[9..];
        var slash = s.IndexOf('\\');
        return slash >= 0 ? s[..slash] : s; // an instance id's own part, with nothing after it (no serial)
    }

    private static bool IsShortened(string id) => id.Length == 24 && ShortenedTail().IsMatch(id);

    private static string Clean(string raw, bool joined)
    {
        var s = Spaces().Replace(raw, " ").Trim();
        foreach (var (mfg, shortName) in Makers)
        {
            if (!s.StartsWith(mfg, StringComparison.OrdinalIgnoreCase)) continue;
            var rest = s[mfg.Length..];
            if (!joined && rest.Length > 0 && rest[0] != ' ') continue; // "HPE…", "Dellmore": not the maker
            rest = rest.Trim();
            if (rest.Length == 0) return shortName;
            // "Hewlett-Packard HP LaserJet", "EPSON EPSON L1110": the model names its maker again.
            foreach (var (again, _) in Makers.Where(m => m.Short == shortName))
                if (rest.StartsWith(again + " ", StringComparison.OrdinalIgnoreCase))
                {
                    rest = rest[again.Length..].Trim();
                    break;
                }
            return $"{shortName} {Model(rest)}";
        }
        return Model(s);
    }

    /// <summary>A model in capitals from an instance id ("LASERJET P1006") reads as typed; mixed case stays as the maker wrote it.</summary>
    private static string Model(string s) =>
        s.Any(char.IsLower) ? s : string.Join(' ', s.Split(' ').Select(w => w.Length > 1 && w.All(c => char.IsLetter(c)) ? w[0] + w[1..].ToLowerInvariant() : w));

    [GeneratedRegex(@"\s+")]
    private static partial Regex Spaces();

    [GeneratedRegex(@"[0-9A-F]{4}$")]
    private static partial Regex ShortenedTail();
}
