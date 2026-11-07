import Foundation
import Testing
@testable import PdfCore

/// Ported from CompareContractTests.cs: roadmap 3.3's test, a contract and its edited .docx with 30 planted changes
/// (wording, moves, formatting). Word made the two PDFs, read here in place from the Windows tests' Data folder; the
/// planted list is built as the Windows test builds it. `MakeThePdfsWithWord` (Word on Windows, `INKVOLTPDF_WORD`) isn't
/// ported: the PDFs are made there.
struct CompareContractTests {
    private struct Plant: CustomStringConvertible {
        var kind: ChangeKind
        var clause: Int
        var old: String
        var new: String
        var look: LookParts = []
        var description: String { "\(kind) \(clause): “\(old)” → “\(new)”" }
    }

    private static let clauses = 48
    private static let insertion = " promptly and in writing"
    private static let removal = " unless waived by the board"
    private static let replaced = [2, 7, 11, 16, 21, 27, 33, 40]
    private static let inserted = [4, 13, 24, 30, 44]
    private static let removed = [6, 18, 26, 36, 46]
    private static let moved: [(clause: Int, after: Int)] = [(9, 14), (20, 38), (31, 3), (42, 47)]

    private static func amount(_ clause: Int) -> String { String(1000 + clause * 37) }

    private static func title(_ i: Int) -> String {
        let names = ["Term", "Payment", "Warranty", "Indemnity", "Notices", "Assignment", "Audit", "Insurance", "Confidentiality", "Termination", "Liability"]
        return "Article \(i) \(names[i % 11])"
    }

    /// What the version plants in a clause (the Windows test's `Clause`, its runs not needed here).
    private static func plantsOf(_ i: Int, _ plants: inout [Plant]) {
        if replaced.contains(i) { plants.append(Plant(kind: .changed, clause: i, old: amount(i), new: String(1000 + i * 37 + 5000))) }
        if inserted.contains(i) { plants.append(Plant(kind: .inserted, clause: i, old: "", new: insertion.trimmingCharacters(in: .whitespaces))) }
        if removed.contains(i) { plants.append(Plant(kind: .deleted, clause: i, old: removal.trimmingCharacters(in: .whitespaces), new: "")) }
        // Formatting: the words stay, how they are set changes.
        let bare = title(i) + "."
        let looks: [Int: (String, LookParts)] = [1: (bare, .bold), 8: (amount(i), .bold), 15: (bare, .size), 23: (amount(i), .size),
                                                 28: (bare, .italic), 34: (amount(i), .color), 38: (bare, .font), 45: (bare, .bold)]
        if let (text, parts) = looks[i] { plants.append(Plant(kind: .formatted, clause: i, old: text, new: text, look: parts)) }
    }

    private static func plants() -> [Plant] {
        var plants: [Plant] = []
        for i in 1...clauses { plantsOf(i, &plants) }
        for m in moved { plants.append(Plant(kind: .moved, clause: m.clause, old: title(m.clause), new: title(m.clause))) }
        return plants
    }

    /// pdf/tests/InkvoltPdf.Tests/Data/`name`, found from this file up to the repository's root.
    private static func data(_ name: String) throws -> [UInt8] {
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while !FileManager.default.fileExists(atPath: dir.appendingPathComponent("pdf/tests/InkvoltPdf.Tests/Data").path) {
            let up = dir.deletingLastPathComponent()
            if up.path == dir.path { throw PdfEditError("The repository's root wasn't found above \(#filePath).") }
            dir = up
        }
        return Array(try Data(contentsOf: dir.appendingPathComponent("pdf/tests/InkvoltPdf.Tests/Data/\(name)")))
    }

    private static func read(_ pdf: [UInt8], formatting: Bool = true) throws -> CompareSource {
        let engine = try PdfEngine.open(pdf)
        defer { engine.close() }
        return CompareSource.of(try (0..<engine.pageCount).map { try engine.comparePage($0) }, formatting: formatting)
    }

    private static func show(_ c: CompareChange) -> String {
        let page = c.new.first?.page ?? c.old.first?.page ?? -1
        return "\(c.kind) p\(page): “\(c.oldText)” → “\(c.newText)” \(c.look?.describe() ?? "")"
    }

    private static func matches(_ c: CompareChange, _ p: Plant) -> Bool {
        switch p.kind {
        case .moved: c.kind == .moved && c.newText.hasPrefix(p.new)
        case .formatted: c.kind == .formatted && c.newText == p.new && c.look?.parts == p.look
        default: c.kind == p.kind && c.oldText == p.old && c.newText == p.new
        }
    }

    @Test func wordMadeContractListsItsThirtyPlantedChangesAndNoOthers() throws {
        let plants = Self.plants()
        #expect(plants.count == 30)
        let r = try DocumentCompare.run(try Self.read(try Self.data("compare-contract-old.pdf")), try Self.read(try Self.data("compare-contract-new.pdf")))

        var unmatched = r.changes
        var missing: [Plant] = []
        for plant in plants {
            if let found = unmatched.firstIndex(where: { Self.matches($0, plant) }) {
                unmatched.remove(at: found)
            } else {
                missing.append(plant)
            }
        }
        #expect(missing.isEmpty && unmatched.isEmpty,
                "Not found: \(missing.map(\.description).joined(separator: "; "))\nNot planted:\n\(unmatched.map(Self.show).joined(separator: "\n"))")
        #expect([r.changed, r.inserted, r.deleted, r.moved, r.formatted] as [Int] == [8, 5, 5, 4, 8])
    }

    @Test func aWordMadePageIsNoScanAndAPictureOfOneIs() throws {
        let made = try PdfEngine.open(try Self.data("compare-contract-old.pdf"))
        defer { made.close() }
        let page = try made.comparePage(0)
        #expect(!page.isPicture)
        #expect(!page.text.isEmpty)
        let article = (page.text.text as NSString).range(of: "Article").location
        #expect(page.looks.at(article).map { $0.size.rounded() } == 11)

        let picture = try ImageImport.imagesToPdf([(TestImages.png(400, 500) { _, _ in (250, 250, 250, 255) }, "scan.png")])
        let scan = try PdfEngine.open(picture)
        defer { scan.close() }
        let read = try scan.comparePage(0)
        #expect(read.isPicture)
        #expect(read.text.isEmpty)
        #expect(CompareSource.of([read]).looksOf(0) == nil)
        #expect(CompareSource.of([read]).isScanned(0))
    }

    @Test func withoutFormattingOnlyTheWordingAndMovesAreListed() throws {
        let r = try DocumentCompare.run(try Self.read(try Self.data("compare-contract-old.pdf"), formatting: false),
                                        try Self.read(try Self.data("compare-contract-new.pdf"), formatting: false))
        #expect([r.changed, r.inserted, r.deleted, r.moved, r.formatted] as [Int] == [8, 5, 5, 4, 0])
    }

    @Test func theLooksLineUpWithThePageTextOnEveryPage() throws {
        let engine = try PdfEngine.open(try Self.data("compare-contract-new.pdf"))
        defer { engine.close() }
        for p in 0..<engine.pageCount {
            let read = try engine.comparePage(p)
            #expect(try engine.text(p, cache: false).text == read.text.text)
            // A word planted in another look has it exactly there, and the word beside it doesn't.
            let text = read.text.text as NSString
            let at = text.range(of: "Article 8 ").location
            if at == NSNotFound { continue }
            let amount = text.range(of: Self.amount(8), range: NSRange(location: at, length: text.length - at)).location
            #expect(read.looks.at(amount)?.bold == true)
            #expect(read.looks.at(amount - 2)?.bold == false)
        }
    }
}
