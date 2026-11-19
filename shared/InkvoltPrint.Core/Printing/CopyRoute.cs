namespace InkvoltPrint.Core.Printing;

/// <summary>Why the Copy tab can't copy yet; <see cref="None"/> when it can.</summary>
public enum CopyBlocker { None, Connecting, NoScanner, NoQueue }

/// <summary>
/// Which way a copy goes: the printer's own copier (HP LEDM, <see cref="Ledm.PrinterCopier"/>: no scanner connection and no
/// Windows queue needed), or through this PC (scan, lay out, print through the queue: previews, 2-up and 4-up, ID cards).
/// </summary>
public static class CopyRoute
{
    /// <summary>The printer copies by itself: it offers it, the user left it chosen, and it's a page copy (an ID card is laid out by the PC).</summary>
    public static bool OnPrinter(bool printerOffers, bool printerChosen, bool idCard) => printerOffers && printerChosen && !idCard;

    /// <summary>What's missing for the chosen way; the printer's own copier needs nothing more than the printer.</summary>
    /// <param name="canPrint">A Windows queue, or the demo's made-up one.</param>
    public static CopyBlocker Blocker(bool onPrinter, bool scannerChecked, bool hasScanner, bool canPrint) =>
        onPrinter ? CopyBlocker.None
        : !scannerChecked ? CopyBlocker.Connecting
        : !hasScanner ? CopyBlocker.NoScanner
        : !canPrint ? CopyBlocker.NoQueue
        : CopyBlocker.None;
}
