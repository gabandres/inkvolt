namespace InkvoltPrint.Core.Wia;

/// <summary>
/// Windows Image Acquisition property IDs, flags and formats Inkvolt Print uses (wiadef.h: <c>WIA_DIP_FIRST</c> = 2,
/// <c>WIA_DPS_FIRST</c> = 3074, <c>WIA_IPA_FIRST</c> = 4098, <c>WIA_IPS_FIRST</c> = 6146). These are the WIA 1.0 device and
/// item properties the scripting library (wiaaut.dll) works with; Windows gives WIA 2.0 drivers the same view.
/// </summary>
public static class WiaIds
{
    // Device info (WIA_DIP_*), readable without connecting.
    public const int DeviceId = 2, Manufacturer = 3, Description = 4, DeviceType = 5, Port = 6, Name = 7;

    // Scanner device (WIA_DPS_*): sizes in thousandths of an inch.
    public const int HorizontalBedSize = 3074, VerticalBedSize = 3075, HorizontalSheetFeedSize = 3076, VerticalSheetFeedSize = 3077,
        DocumentHandlingCapabilities = 3086, DocumentHandlingStatus = 3087, DocumentHandlingSelect = 3088, Pages = 3096;

    // Item (WIA_IPA_*, WIA_IPS_*): positions and extents in pixels at the current resolution.
    public const int DataType = 4103, Depth = 4104, CurrentIntent = 6146, XResolution = 6147, YResolution = 6148,
        XPosition = 6149, YPosition = 6150, XExtent = 6151, YExtent = 6152;

    /// <summary><c>WiaDeviceType.ScannerDeviceType</c>.</summary>
    public const int ScannerType = 1;

    // WIA_DPS_DOCUMENT_HANDLING_CAPABILITIES
    public const int CapFeed = 0x01, CapFlat = 0x02, CapDuplex = 0x04, CapDetectFeedAvailable = 0x80;

    // WIA_DPS_DOCUMENT_HANDLING_STATUS
    public const int FeedReady = 0x01, FlatCoverUp = 0x08, PathCoverUp = 0x10, PaperJam = 0x20;

    // WIA_DPS_DOCUMENT_HANDLING_SELECT
    public const int SelectFeeder = 0x001, SelectFlatbed = 0x002, SelectDuplex = 0x004, SelectFrontFirst = 0x008;

    // WIA_IPA_DATATYPE (threshold: black and white, 1 bit)
    public const int DataThreshold = 0, DataGrayscale = 2, DataColor = 3;

    public const string FormatBmp = "{B96B3CAB-0728-11D3-9D7B-0000F81EF32E}", FormatJpeg = "{B96B3CAE-0728-11D3-9D7B-0000F81EF32E}",
        FormatPng = "{B96B3CAF-0728-11D3-9D7B-0000F81EF32E}";
}

/// <summary>A scanner Windows has a WIA driver for, as listed without connecting to it.</summary>
/// <param name="Port">The driver's port: <c>USB…</c>, a network path, or <c>SWD\Escl\…</c> for Windows' own eSCL driver.</param>
public sealed record WiaDeviceInfo(string Id, string Name, string? Manufacturer = null, string? Description = null, string? Port = null)
{
    /// <summary>Windows reaches it with its built-in eSCL (AirScan) driver: Inkvolt Print scans such a printer over eSCL itself when it finds it.</summary>
    public bool IsEscl => Port?.StartsWith(@"SWD\Escl", StringComparison.OrdinalIgnoreCase) == true;

    /// <summary>How the PC reaches it, from the driver's port: "USB", "Network"; null when the port doesn't tell.</summary>
    public string? ConnectionText => Port switch
    {
        null or "" => null,
        _ when Port.Contains("usb", StringComparison.OrdinalIgnoreCase) => "USB",
        _ when IsEscl || Port.Contains("WSD", StringComparison.OrdinalIgnoreCase)
               || Port.StartsWith("http", StringComparison.OrdinalIgnoreCase) || Suite.QueueMatch.HostsIn(Port).Any(h => System.Net.IPAddress.TryParse(h, out _)) => "Network",
        _ => null,
    };
}

/// <summary>A property's valid values as the driver gives them: a list, a range, or nothing said (only the current value).</summary>
public sealed record WiaValues(int Current, IReadOnlyList<int> List, int? Min = null, int? Max = null, int? Step = null)
{
    public static WiaValues Only(int value) => new(value, []);
    public static WiaValues Range(int current, int min, int max, int step) => new(current, [], min, max, step);
    public static WiaValues Of(int current, params int[] list) => new(current, list);

    public bool Allows(int value) => List.Count > 0 ? List.Contains(value)
        : Min is { } min && Max is { } max ? value >= min && value <= max && (value - min) % Math.Max(Step ?? 1, 1) == 0
        : value == Current;
}

/// <summary>What a connected WIA scanner says it can do (read once when connecting).</summary>
/// <param name="Handling">Document handling capabilities (<see cref="WiaIds.CapFeed"/>…); null when the driver has no such property (glass only).</param>
/// <param name="BedWidth">Glass size in thousandths of an inch; null when not given.</param>
/// <param name="FeederWidth">Widest and longest sheet the feeder takes, thousandths of an inch; null when not given (or 0: any length).</param>
/// <param name="DataTypes">Data types the item offers (<see cref="WiaIds.DataColor"/>, <see cref="WiaIds.DataGrayscale"/>…); empty when not said.</param>
/// <param name="Formats">Transfer formats (GUID strings) the item offers.</param>
public sealed record WiaScannerInfo(
    int? Handling,
    int? BedWidth, int? BedHeight,
    int? FeederWidth, int? FeederHeight,
    WiaValues Resolutions,
    IReadOnlyList<int> DataTypes,
    IReadOnlyList<string> Formats);

/// <summary>What one scan sets on the device and item before transferring pages.</summary>
/// <param name="Handling">Document handling select: glass, feeder, or feeder with both sides (front first); null for a glass-only driver (left alone).</param>
/// <param name="Width">Area in pixels at <paramref name="Resolution"/> (the driver's own limit applies too).</param>
/// <param name="Pages">WIA_DPS_PAGES to set: 1 for one side from the feeder (one page per transfer), 0 (all pages) for both sides,
/// since a sheet is two pages then and 1 would give the front only; null for the glass (left alone).</param>
public sealed record WiaScanSettings(int? Handling, bool Feeder, int DataType, int Depth, int Resolution, int Width, int Height, int? Pages = null)
{
    /// <summary>Both sides of each sheet: two pages per sheet, front first.</summary>
    public bool Duplex => Feeder && Handling is { } h && (h & WiaIds.SelectDuplex) != 0;
}

/// <summary>A WIA call failed with this HRESULT (<see cref="WiaErrors"/>).</summary>
public sealed class WiaException(int hresult, string message) : Exception(message)
{
    public int Code { get; } = hresult;
}

/// <summary>WIA error HRESULTs (wiadef.h, FACILITY_WIA = 33) and what to tell the user about each.</summary>
public static class WiaErrors
{
    public const int GeneralError = unchecked((int)0x80210001), PaperJam = unchecked((int)0x80210002), PaperEmpty = unchecked((int)0x80210003),
        PaperProblem = unchecked((int)0x80210004), Offline = unchecked((int)0x80210005), Busy = unchecked((int)0x80210006),
        WarmingUp = unchecked((int)0x80210007), UserIntervention = unchecked((int)0x80210008), ItemDeleted = unchecked((int)0x80210009),
        DeviceCommunication = unchecked((int)0x8021000A), InvalidCommand = unchecked((int)0x8021000B),
        IncorrectHardwareSetting = unchecked((int)0x8021000C), DeviceLocked = unchecked((int)0x8021000D),
        ExceptionInDriver = unchecked((int)0x8021000E), InvalidDriverResponse = unchecked((int)0x8021000F),
        NoDeviceAvailable = unchecked((int)0x80210015), CoverOpen = unchecked((int)0x80210016), LampOff = unchecked((int)0x80210017);

    /// <summary>
    /// Not from WIA: the scanner's thread hasn't finished an earlier call its caller stopped waiting for (a driver that hangs, or a
    /// page still coming after Cancel), so nothing more is sent to it. HRESULT_FROM_WIN32(ERROR_TIMEOUT).
    /// </summary>
    public const int NotAnswering = unchecked((int)0x800705B4);

    // COM failures that aren't WIA's: the WIA service restarted or stopped (RPC), access denied, out of memory.
    public const int RpcServerUnavailable = unchecked((int)0x800706BA), RpcCallFailed = unchecked((int)0x800706BE),
        RpcDisconnected = unchecked((int)0x80010108), AccessDenied = unchecked((int)0x80070005), OutOfMemory = unchecked((int)0x8007000E);

    /// <summary>A WIA error (facility 33), not some other COM failure.</summary>
    public static bool IsWia(int hresult) => (hresult & 0xFFFF0000) == 0x80210000;

    /// <summary>The device can't be reached now: connecting again later may work.</summary>
    public static bool IsUnreachable(int hresult) => hresult is Offline or DeviceCommunication or NoDeviceAvailable or ItemDeleted;

    /// <summary>
    /// Whether a connected scanner should be let go after this failure and connected again on the next call. Kept only for errors
    /// about the paper or the scanner's state (jam, empty feeder, busy, warming up, cover open, lock…), which the same connection
    /// reports again once fixed; any other failure, and every non-WIA one (the WIA service restarted: RPC errors), may mean the COM
    /// object is dead, and a fresh connection costs little.
    /// </summary>
    public static bool NeedsReconnect(int hresult) => hresult is not (PaperJam or PaperEmpty or PaperProblem or Busy or WarmingUp
        or UserIntervention or DeviceLocked or IncorrectHardwareSetting or CoverOpen or LampOff or NotAnswering);

    /// <summary>
    /// Any failure of a WIA call as a <see cref="WiaException"/>: COM errors keep their HRESULT, also those .NET turned into other
    /// exception types (E_ACCESSDENIED as UnauthorizedAccessException, E_OUTOFMEMORY, E_NOTIMPL, Win32 errors as IO exceptions);
    /// late-binding and other .NET failures (facility 0x13, or no failure code) are <see cref="GeneralError"/>.
    /// </summary>
    public static WiaException From(Exception ex)
    {
        if (ex is WiaException w) return w;
        var code = ex.HResult;
        var mapped = code < 0 && ((code >> 16) & 0x1FFF) != 0x13 || ex is System.Runtime.InteropServices.COMException;
        return new WiaException(mapped ? code : GeneralError, ex.Message);
    }

    /// <summary>In plain words; <paramref name="feeder"/>: the scan was from the document feeder.</summary>
    public static string Message(int hresult, bool feeder) => hresult switch
    {
        PaperJam => feeder ? "The document feeder is jammed. Clear the paper and try again." : "The scanner reports a paper jam. Clear it and try again.",
        PaperEmpty => feeder ? "Load the pages into the document feeder first." : "The scanner says there's no paper to scan.",
        PaperProblem => "The scanner has a problem with the paper. Check the document feeder and try again.",
        Offline or NoDeviceAvailable => "The scanner isn't answering. Check that it's on and connected (its cable or the network), then try again.",
        Busy => "The scanner is busy with another job. Try again in a moment.",
        WarmingUp => "The scanner is warming up. Try again in a moment.",
        UserIntervention => "The scanner needs attention: check its panel or display, then try again.",
        DeviceCommunication or ItemDeleted => "Windows lost contact with the scanner. Check its connection and try again.",
        CoverOpen => "The scanner's cover is open. Close it and try again.",
        LampOff => "The scanner's lamp is off. Turn the scanner off and on again, then try again.",
        NotAnswering => "The scanner hasn't finished its last request (its driver may have stopped answering). Wait a moment and try " +
                        "again; if it still doesn't answer, turn the scanner off and on, or close and reopen this app.",
        RpcServerUnavailable or RpcCallFailed or RpcDisconnected =>
            "Windows' scanning service stopped answering (it may have restarted). Try again: the scanner is connected again.",
        AccessDenied => "Windows didn't allow this app to use the scanner. Close other scanning apps and try again.",
        OutOfMemory => "There wasn't enough memory for this scan. Try a lower resolution or fewer pages.",
        DeviceLocked => "The scanner is locked (some have a lock switch for moving them). Unlock it and try again.",
        IncorrectHardwareSetting => "The scanner's settings or switches don't allow this scan. Check the scanner, or try other settings.",
        InvalidCommand or ExceptionInDriver or InvalidDriverResponse =>
            "The scanner's driver couldn't do this scan. Try other settings, or reinstall the scanner's driver.",
        _ => $"The scanner's driver reported an error (0x{hresult:X8}).",
    };
}
