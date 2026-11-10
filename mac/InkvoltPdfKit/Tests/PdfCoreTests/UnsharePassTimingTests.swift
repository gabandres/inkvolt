import Foundation
import Testing
@testable import PdfCore

/// Opt-in (`INKVOLT_UNSHARE_BENCH=<the bench corpus folder>`, `mac/tools/bench`'s `make`): what the pass before a
/// compacting save costs on the corpus's files. Prints, for each, the pass alone and a whole compacting save (which runs
/// it again: the save without it is the difference).
struct UnsharePassTimingTests {
    @Test func thePassOnTheBenchCorpus() throws {
        guard let folder = ProcessInfo.processInfo.environment["INKVOLT_UNSHARE_BENCH"] else { return }
        for name in ["text.pdf", "comments.pdf", "scan.pdf", "drawings.pdf"] {
            guard let data = FileManager.default.contents(atPath: folder + "/" + name) else { continue }
            let doc = try PdfEdit.open(Array(data), nil)
            try doc.loadAllObjects()
            var start = Date()
            let pass = doc.unshareDirectObjects()
            let passTime = Date().timeIntervalSince(start)
            start = Date()
            let saved = try doc.write("garbage=compact,encrypt=keep")
            let saveTime = Date().timeIntervalSince(start)
            print(String(format: "UNSHARE %@ %.0f MB: pass %.2f s (%d copies, complete %@), compacting save with the pass %.2f s, without it about %.2f s",
                         name, Double(data.count) / 1e6, passTime, pass.copies, pass.complete ? "yes" : "no", saveTime, saveTime - passTime) + " (\(saved.count / 1_000_000) MB out)")
        }
    }
}
