import Foundation

/// Why a copy can't go yet; `.none` when it can (Windows' `CopyBlocker`).
public enum CopyBlocker: Sendable {
    case none, connecting, noScanner, noQueue
}

/// Which of the copy's options are shown (Windows' `CopyControls`).
/// - `pcOptions`: the scan source, size, pages per sheet and the preview: only the computer's page copy has them.
public struct CopyControls: Equatable, Sendable {
    public var copies: Bool, collate: Bool, color: Bool, twoSided: Bool, pcOptions: Bool

    public init(_ copies: Bool, _ collate: Bool, _ color: Bool, _ twoSided: Bool, _ pcOptions: Bool) {
        self.copies = copies
        self.collate = collate
        self.color = color
        self.twoSided = twoSided
        self.pcOptions = pcOptions
    }
}

/// Which way a copy goes (Windows' `CopyRoute`): the printer's own copier (HP LEDM, `PrinterCopier`: no scanner connection and
/// no queue needed, the printer's own settings), or through this computer (scan, lay out, print through the queue). The Mac
/// has the printer's own copier (Copy on the Printer…) and the ID card copy; Windows' page copy through the PC (2-up, 4-up,
/// the preview) isn't on the Mac yet, so `controls` and `blocker` are kept as Windows' rules for when it comes.
public enum CopyRoute {
    /// Copies one copy job asks for.
    public static let maxCopies = 99

    /// The printer copies by itself: it offers it, the user chose it, and it's a page copy (an ID card is laid out by the
    /// computer). Through the computer is Windows' default until a recorded printer confirms the copy settings' names.
    public static func onPrinter(_ printerOffers: Bool, _ printerChosen: Bool, idCard: Bool) -> Bool { printerOffers && printerChosen && !idCard }

    /// What's missing for the chosen way; the printer's own copier needs nothing more than the printer.
    /// - Parameter canPrint: a queue, or the demo's made-up one.
    public static func blocker(onPrinter: Bool, scannerChecked: Bool, hasScanner: Bool, canPrint: Bool) -> CopyBlocker {
        if onPrinter { return .none }
        if !scannerChecked { return .connecting }
        if !hasScanner { return .noScanner }
        return canPrint ? .none : .noQueue
    }

    /// The options shown. On the printer none: it copies with the settings on its own control panel, which the app leaves
    /// alone. Through the computer: copies and color always; collate with more than one copy of a page copy; two-sided when
    /// the queue can (or by hand) and it's a page copy (an ID card copy is one sheet).
    public static func controls(onPrinter: Bool, idCard: Bool, copies: Int, queueTwoSided: Bool, byHand: Bool = false) -> CopyControls {
        onPrinter ? CopyControls(false, false, false, false, false)
            : CopyControls(true, !idCard && copies > 1, true, (queueTwoSided || byHand) && !idCard, !idCard)
    }

    /// A copy count typed or stepped to: 1 to `maxCopies`.
    public static func clampCopies(_ value: Int) -> Int { min(max(value, 1), maxCopies) }
}
