import Foundation

/// What became of a page a scanner sent: kept, left out as blank (on request), or unreadable (no JPEG size: left out).
public enum ScanPageFate: Equatable, Sendable { case kept, blank, unreadable }

public struct ScanRunPage: Sendable {
    public let jpeg: [UInt8]
    public let fate: ScanPageFate
}

/// One scan job as Inkvolt PDF's Scan dialog runs it (the Windows suite's `ScanRun`), on any `ScanDevice` (eSCL,
/// ImageCaptureCore): each page the scanner sends, checked for blankness when asked (`BlankPage` on a small greyscale copy,
/// off the caller's actor), with its fate. Stopping early (cancelling the iteration or the caller's task) stops the device's
/// job. Shared so the dialog's page handling is tested with a fake scanner.
public enum ScanRun {
    /// Decodes a page into the greyscale copy the check reads (PrintMac's `ScanImaging.analysis` in the app).
    public typealias Analysis = @Sendable ([UInt8]) throws -> GrayImage

    /// - Parameter analysis: nil keeps every page that can be read.
    public static func pages(_ device: any ScanDevice, _ request: ScanRequest, analysis: Analysis?) -> AsyncThrowingStream<ScanRunPage, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await jpeg in device.scan(request) {
                        let fate = await fate(jpeg, analysis)
                        try Task.checkCancellation()
                        continuation.yield(ScanRunPage(jpeg: jpeg, fate: fate))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// A page without a JPEG frame header is unreadable; one the check can't judge is kept: never lose a page to the check.
    /// Stopped while the check runs (off the caller's actor), it answers at once (kept, then dropped by the caller's
    /// cancellation check) and the check's verdict is dropped, so Stop doesn't wait for a slow check to stop the device.
    static func fate(_ jpeg: [UInt8], _ analysis: Analysis?) async -> ScanPageFate {
        guard (try? PdfWriter.jpegInfo(jpeg)) != nil else { return .unreadable }
        guard let analysis else { return .kept }
        let once = OnceResult<Bool>()
        let check = Task.detached(priority: .userInitiated) {
            if Task.isCancelled { return }
            once.finish((try? BlankPage.isBlank(analysis(jpeg))) ?? false)
        }
        let blank = await withTaskCancellationHandler {
            await withCheckedContinuation { once.start($0) }
        } onCancel: {
            check.cancel()
            once.finish(false)
        }
        return blank ? .blank : .kept
    }

    /// The dialog's line once a job ends: pages added, blank pages left out, what to do next.
    /// - Parameters:
    ///   - glass: the job was from the glass (one page per job).
    ///   - finish: the finish button's words ("Create PDF", "Insert Pages").
    public static func doneText(kept: Int, blank: Int, unreadable: Int, glass: Bool, finish: String) -> String {
        var left: [String] = []
        if blank > 0 { left.append(blank == 1 ? loc("{0} blank page left out", blank) : loc("{0} blank pages left out", blank)) }
        if unreadable > 0 {
            left.append(unreadable == 1 ? loc("{0} page that couldn't be read left out", unreadable)
                : loc("{0} pages that couldn't be read left out", unreadable))
        }
        let also = left.isEmpty ? "" : " (\(left.joined(separator: ", ")))"
        if kept == 0 {
            return blank > 0 && unreadable == 0
                ? loc("Every page scanned looked blank, so none were added{0}. Clear \"Leave out blank pages\" to keep them.", also)
                : loc("The scanner returned no pages{0}.", also)
        }
        return glass
            ? loc("Done{0}. For another page, put it on the glass and press Scan Another Page; or press {1}.", also, finish)
            : loc("Done: {0} from the feeder{1}.", pages(kept), also)
    }

    /// "Scanned page 3. Scanning…", with the blank pages left out so far.
    public static func progressText(_ count: Int, blank: Int) -> String {
        blank > 0 ? loc("Scanned page {0} ({1} blank left out). Scanning…", count, blank) : loc("Scanned page {0}. Scanning…", count)
    }

    public static func pages(_ n: Int) -> String { n == 1 ? loc("{0} page", n) : loc("{0} pages", n) }
}
