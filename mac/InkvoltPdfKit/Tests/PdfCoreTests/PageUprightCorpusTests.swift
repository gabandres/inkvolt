import Foundation
import PrintCore
import Testing
@testable import PdfCore

/// Ported from PageUprightCorpusTests.cs: Inkvolt Print's pages turned upright on their own (its roadmap 4.3, in PrintCore):
/// real text typeset by MuPDF and "scanned" by the OCR corpus's generator (`ScanCorpus`, the same seeds), fed each way
/// round and a little crooked, read on the small copy the scan review's checks use (about 100 dpi). Every page must come
/// out upright and sure: a scan that is turned wrongly is worse than one left as it came, so this is what makes it reliable
/// enough to be on by default.
struct PageUprightCorpusTests {
    @Test(.enabled(if: ScanCorpus.runs), arguments: [
        ("en-upright-times", "/Times-Roman", 11.0, 0), ("en-upright-helvetica", "/Helvetica", 10.0, 1), ("es-upright-times", "/Times-Roman", 12.0, 2),
    ] as [(String, String, Double, Int)])
    func pagesFedEachWayRoundAreTurnedUpright(_ name: String, _ font: String, _ size: Double, _ shift: Int) throws {
        let turns = (0..<4).map { ($0 + shift) % 4 }
        let file = CorpusFile(name: name, language: String(name.prefix(2)), font: font, fontSize: size, minSkew: 0.5, maxSkew: 3.5,
                              noise: 14, specks: 300, shading: 30, turns: turns, pages: 4)
        for p in 0..<4 {
            let (pixels, w, h, truth) = try ScanCorpus.makePage(file, p)
            let small = ScanCleanup.downscale(GrayImage(w, h, pixels), 3)
            let found = PageUpright.find(small, Double(ScanCorpus.dpi) / 3)
            #expect(found.sure, "\(name) page \(p + 1), fed \(truth.turns) turns: not sure")
            #expect(found.quarterTurns == (4 - truth.turns) % 4, "\(name) page \(p + 1)")
            // Lying sideways, it is straightened by its lines' own skew (the scan was skewed after it was turned).
            if truth.turns % 2 == 1 { #expect(abs(found.skew - truth.skew) <= 0.5, "\(found.skew) for \(truth.skew)") }
        }
    }

    @Test func aPageWithAFewWordsIsLeftAsItCame() {
        // A heading and nothing else: too little text to say which way up, so no turn.
        var px = [UInt8](repeating: 240, count: 850 * 1100)
        for y in 100..<112 {
            for x in 100..<300 { px[y * 850 + x] = 30 }
        }
        #expect(PageUpright.find(GrayImage(850, 1100, px), 100).turns == 0)
    }
}
