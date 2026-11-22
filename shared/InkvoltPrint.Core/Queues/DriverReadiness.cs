using InkvoltPrint.Core.Ipp;
using InkvoltPrint.Core.Printing.Direct;

namespace InkvoltPrint.Core.Queues;

/// <summary>A Windows queue's driver as the spooler reports it (<c>DRIVER_INFO_6</c>): its name, its type (3 or 4) and who provides it.</summary>
public sealed record QueueDriverInfo(string Name, int? Version, string? Provider);

/// <summary>Which kind of driver a printer's Windows queue uses.</summary>
public enum QueueDriver
{
    /// <summary>No Windows queue for it.</summary>
    None,

    /// <summary>Windows' IPP class driver: Windows Ready Print, all protected print mode allows.</summary>
    WindowsIpp,

    /// <summary>Another of Microsoft's own (the PCL6 or PostScript class driver, a generic one): inbox, but not Windows Ready Print.</summary>
    Microsoft,

    /// <summary>The maker's version 4 driver.</summary>
    MakerV4,

    /// <summary>The maker's version 3 driver (the classic kind).</summary>
    MakerV3,

    /// <summary>The maker's, of a type it doesn't say.</summary>
    Maker,
}

/// <summary>Whether a printer prints under Windows protected print mode.</summary>
public enum PrintReadiness
{
    /// <summary>Its queue already uses Windows' IPP class driver.</summary>
    Ready,

    /// <summary>It answers IPP (driverless printing) but its queue uses another driver, or it has none: Set up with Windows' driver.</summary>
    CanMove,

    /// <summary>It was asked and doesn't answer IPP: only its maker's driver prints to it, which protected print mode removes.</summary>
    NotReady,

    /// <summary>Not known: the printer can't be asked (USB, shared from another PC) or hasn't answered yet.</summary>
    NotKnown,
}

/// <summary>Whether its scanner scans under protected print mode.</summary>
public enum ScanReadiness
{
    /// <summary>No scanner here.</summary>
    None,

    /// <summary>It scans over eSCL (AirScan, Mopria Scan): Windows' own scanning keeps working.</summary>
    Ready,

    /// <summary>It's reached only through its Windows driver (WIA or TWAIN): protected print mode turns that off.</summary>
    DriverOnly,
}

/// <summary>Where one printer stands for Windows' new driver (roadmap 4.5).</summary>
public sealed record Readiness(QueueDriver Driver, bool AnswersIpp, bool AnswersEscl, bool Mopria, bool MopriaScan, PrintReadiness Print, ScanReadiness Scan)
{
    /// <summary>
    /// Set up with Windows' driver is offered: the printer answers IPP and its queue is on another driver. With no queue at all, the
    /// printer's Set up in Windows does it (it uses Windows' IPP class driver too).
    /// </summary>
    public bool OffersSetUp => Print == PrintReadiness.CanMove && Driver != QueueDriver.None;
}

/// <summary>
/// Ready for Windows' new driver (roadmap 4.5): Windows Ready Print (July 2026) installs new printers on Windows' IPP class driver,
/// and protected print mode installs printers only that way: it removes third-party drivers, and a scanner reached only through
/// its Windows driver (WIA or TWAIN) stops working; a Mopria-certified scanner (eSCL) keeps working. Sources: Microsoft's
/// "Introducing Windows Ready Print and modernized driver selection" (2026) and "Windows protected print mode" (Learn).
/// This decides, from the queue's driver and what the printer answered, whether each printer is ready, could move, or isn't.
/// </summary>
public static class DriverReadiness
{
    public const string IppClassDriver = "Microsoft IPP Class Driver";

    /// <summary>The kind of driver: Windows' IPP class driver by its name, Microsoft's others by name, else the maker's by its type.</summary>
    public static QueueDriver Kind(QueueDriverInfo? driver)
    {
        if (driver is null || string.IsNullOrWhiteSpace(driver.Name)) return QueueDriver.None;
        var name = driver.Name.Trim();
        if (name.Length > 256) name = name[..256];
        if (string.Equals(name, IppClassDriver, StringComparison.OrdinalIgnoreCase)) return QueueDriver.WindowsIpp;
        // By name only: a maker's driver Windows Update delivers says "Microsoft" as its provider, and protected print mode removes it too.
        if (name.StartsWith("Microsoft ", StringComparison.OrdinalIgnoreCase) || name.StartsWith("Generic ", StringComparison.OrdinalIgnoreCase))
            return QueueDriver.Microsoft;
        return driver.Version switch
        {
            4 => QueueDriver.MakerV4,
            3 => QueueDriver.MakerV3,
            _ => QueueDriver.Maker,
        };
    }

    /// <summary>
    /// Where the printer stands. <paramref name="ipp"/>: its Get-Printer-Attributes answer, or null when it doesn't answer IPP;
    /// <paramref name="asked"/>: it was reached over the network, so no IPP answer means it has none (USB and shared printers
    /// can't be asked). It answers IPP for Windows' driver when it takes a raster format (PWG raster, Apple raster or PCLm), as the
    /// IPP class driver needs. <paramref name="windowsScanner"/>: a WIA or TWAIN scanner belongs to the entry.
    /// </summary>
    public static Readiness Assess(QueueDriverInfo? driver, IppResponse? ipp, bool asked, bool answersEscl, bool windowsScanner)
    {
        var kind = Kind(driver);
        var answersIpp = ipp is not null && IppPrintCaps.FormatsIn(ipp.Strs("document-format-supported")).Count > 0;
        var mopria = ipp?.Strs("mopria-certified").Any(v => v.Length is > 0 and <= 16) == true;
        var mopriaScan = ipp?.Strs("mopria-certified-scan").Any(v => v.Length is > 0 and <= 16) == true;
        var print = kind == QueueDriver.WindowsIpp ? PrintReadiness.Ready
            : answersIpp ? PrintReadiness.CanMove
            : asked ? PrintReadiness.NotReady
            : PrintReadiness.NotKnown;
        var scan = answersEscl ? ScanReadiness.Ready : windowsScanner ? ScanReadiness.DriverOnly : ScanReadiness.None;
        return new Readiness(kind, answersIpp, answersEscl, mopria, mopriaScan, print, scan);
    }

    /// <summary>The name of the queue Set up with Windows' driver adds beside the old one: the printer's, marked as Windows' driver's.</summary>
    public static string NewQueueName(string printerName, string marker) => $"{printerName.Trim()} ({marker})";
}
