import CoreGraphics
import Foundation
import Testing
@testable import PdfCore

/// Opt-in (`INKVOLT_PRINT_BENCH=file[,file…]`, the bench corpus's scan.pdf and drawings.pdf): how long a print copy takes
/// to get ready, as `PrintSheetView.prepare` makes it (`PrintCopy.make`, then Core Graphics opening the copy and reading
/// each page's box), nothing rated by a view engine yet (the slowest case: every page checked). One line a file,
/// `PRINTBENCH`, in the test's output.
struct PrintCopyBench {
    static let files = ProcessInfo.processInfo.environment["INKVOLT_PRINT_BENCH"]

    private static func seconds(since start: ContinuousClock.Instant) -> Double {
        let d = ContinuousClock.now - start
        return Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
    }

    @Test(.enabled(if: files != nil))
    func printCopyTime() throws {
        for path in (Self.files ?? "").split(separator: ",").map(String.init) {
            let data = try PdfEngine.readFile(path)
            let engine = try PdfEngine.open(data)
            let shown = (0..<engine.pageCount).map { (engine.page($0).width, engine.page($0).height) }
            engine.close()
            let start = ContinuousClock.now
            let copy = try PrintCopy.make(data, nil, shown: shown)
            let made = Self.seconds(since: start)
            var read = 0
            if copy.hasVectors, let provider = CGDataProvider(data: Data(copy.data) as CFData), let doc = CGPDFDocument(provider) {
                for i in 0..<doc.numberOfPages where doc.page(at: i + 1)?.getBoxRect(.cropBox).isEmpty == false { read += 1 }
            }
            let total = Self.seconds(since: start)
            let vectors = copy.pages.filter { if case .vector = $0 { true } else { false } }.count
            let name = URL(fileURLWithPath: path).lastPathComponent
            // Every page read by the view engine already: MuPDF's writing alone.
            let rated = Array(repeating: PageVerdict.fine, count: shown.count)
            let again = ContinuousClock.now
            _ = try PrintCopy.make(data, nil, shown: shown, rated: rated)
            let written = Self.seconds(since: again)
            let format = "PRINTBENCH %@: %d pages, make %.2f s, ready %.2f s, %d vectors, %d read by Core Graphics; all rated fine: %.2f s"
            print(String(format: format, name, shown.count, made, total, vectors, read, written))
        }
    }
}
