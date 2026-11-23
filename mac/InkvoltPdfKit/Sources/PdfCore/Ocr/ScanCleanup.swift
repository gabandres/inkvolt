import Foundation
import PrintCore

// Cleaning a scanned page before text recognition (roadmap 2.2, E14): the Windows app's shared
// `InkvoltPrint.Core/Imaging/ScanCleanup.cs` lives in PrintCore (`ScanCleanup`, `Deskew.measure`, `PageRotate`,
// `PaperLevel`, `Upright`, `GrayImage`), as Windows' InkvoltPdf.Core uses the shared core's, so Inkvolt Print's pages
// turned upright (its roadmap 4.3) and this recognizer read pages alike. Here: the same steps with PdfCore's `CancelToken`.

/// Runs `body` with a stop for PrintCore's cleanup parts that fires when `cancel` does (nil without a token).
private func withStop<T>(_ cancel: CancelToken?, _ body: (BatchStop?) throws -> T) throws -> T {
    guard let cancel else { return try body(nil) }
    let stop = BatchStop()
    let id = cancel.register { stop.stop() }
    defer { cancel.unregister(id) }
    return try body(stop)
}

extension ScanCleanup {
    /// `pixels` (rows of `width` × `channels` bytes, 1 = grey, 3 = RGB) at `dpi` cleaned for the recognizer
    /// (`ScanCleanup.clean(…stop:)`). `keepColor` also returns the cleaned page in colour (RGB input only).
    /// - Throws: `CancellationError` when `cancel` fires.
    public static func clean(_ pixels: [UInt8], _ width: Int, _ height: Int, _ channels: Int, _ dpi: Int, keepColor: Bool = false,
                             cancel: CancelToken? = nil) throws -> CleanedScan {
        try withStop(cancel) { stop in try clean(pixels, width, height, channels, dpi, keepColor: keepColor, stop: stop) }
    }
}

/// Removes specks: small dark spots (dust, toner, a hole's shadow) with no other ink near them, a full stop, comma, dot
/// or accent kept beside its letters. PrintCore's `CleanupDespeckle` (Inkvolt Print's scan cleanup), with a `CancelToken`.
public enum Despeckle {
    /// Turns lone specks white (in place); returns how many went.
    /// - Throws: `CancellationError` when `cancel` fires.
    public static func remove(_ gray: inout [UInt8], _ width: Int, _ height: Int, _ dpi: Int, cancel: CancelToken? = nil) throws -> Int {
        try withStop(cancel) { stop in try CleanupDespeckle.remove(&gray, width, height, dpi, stop) }
    }
}
