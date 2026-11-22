namespace InkvoltPrint.Core.Printing;

/// <summary>Why the Copy tab can't copy yet; <see cref="None"/> when it can.</summary>
public enum CopyBlocker { None, Connecting, NoScanner, NoQueue }

/// <summary>Which of the Copy tab's options are shown for a copy.</summary>
/// <param name="PcOptions">The scan source, size, pages per sheet and the preview: only the PC's page copy has them.</param>
public sealed record CopyControls(bool Copies, bool Collate, bool Color, bool TwoSided, bool PcOptions);

/// <summary>
/// Which way a copy goes: the printer's own copier (HP LEDM, <see cref="Ledm.PrinterCopier"/>: no scanner connection and no
/// Windows queue needed, the printer's own settings), or through this PC (scan, lay out, print through the queue: copies,
/// previews, 2-up and 4-up, ID cards). And what the Copy tab offers for each.
/// </summary>
public static class CopyRoute
{
    /// <summary>Copies one copy job asks for.</summary>
    public const int MaxCopies = 99;

    /// <summary>
    /// The printer copies by itself: it offers it, the user chose it, and it's a page copy (an ID card is laid out by the PC).
    /// Through this PC is the default until a recorded printer confirms the copy settings' names (<see cref="Ledm.LedmCopy"/>).
    /// </summary>
    public static bool OnPrinter(bool printerOffers, bool printerChosen, bool idCard) => printerOffers && printerChosen && !idCard;

    /// <summary>What's missing for the chosen way; the printer's own copier needs nothing more than the printer.</summary>
    /// <param name="canPrint">A Windows queue, or the demo's made-up one.</param>
    public static CopyBlocker Blocker(bool onPrinter, bool scannerChecked, bool hasScanner, bool canPrint) =>
        onPrinter ? CopyBlocker.None
        : !scannerChecked ? CopyBlocker.Connecting
        : !hasScanner ? CopyBlocker.NoScanner
        : !canPrint ? CopyBlocker.NoQueue
        : CopyBlocker.None;

    /// <summary>
    /// The options shown. On the printer none: it copies with the settings on its own control panel, which the app leaves
    /// alone. Through the PC: copies and color always; collate with more than one copy of a page copy; two-sided when the
    /// queue can and it's a page copy (an ID card copy is one sheet).
    /// </summary>
    /// <param name="byHand">The printer can't print both sides and two-sided by hand is offered instead (roadmap 4.2).</param>
    public static CopyControls Controls(bool onPrinter, bool idCard, int copies, bool queueTwoSided, bool byHand = false) =>
        onPrinter
            ? new CopyControls(Copies: false, Collate: false, Color: false, TwoSided: false, PcOptions: false)
            : new CopyControls(Copies: true, Collate: !idCard && copies > 1, Color: true, TwoSided: (queueTwoSided || byHand) && !idCard, PcOptions: !idCard);

    /// <summary>A copy count typed or stepped to: 1 to <see cref="MaxCopies"/>.</summary>
    public static int ClampCopies(int value) => Math.Clamp(value, 1, MaxCopies);
}
