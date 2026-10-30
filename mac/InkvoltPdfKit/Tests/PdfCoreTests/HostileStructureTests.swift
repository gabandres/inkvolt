import Foundation
import Testing
@testable import PdfCore

/// Ported from HostileStructureTests.cs, the page-edit tests (D3): DeletingAPageWalksSharedActionChainsOnce and
/// DeletingAPageSurvivesAnActionThatIsItsOwnNext, and the form one (D5): ChoiceFieldWhoseParentCyclesTakesNewItems. Files
/// built to make a walk over their objects run forever must finish in seconds (a hang fails the test instead of blocking
/// the run). The drawing ones come later.
struct HostileStructureTests {
    struct TimedOut: Error {}

    private final class Outcome<T>: @unchecked Sendable { var result: Result<T, Error>? }

    /// Runs `work` on another thread and waits at most `seconds` for it.
    private func within<T: Sendable>(_ seconds: Double = 20, _ work: @escaping @Sendable () throws -> T) throws -> T {
        let box = Outcome<T>()
        let done = DispatchSemaphore(value: 0)
        Thread {
            box.result = Result { try work() }
            done.signal()
        }.start()
        if done.wait(timeout: .now() + seconds) == .timedOut { throw TimedOut() }
        return try box.result!.get()
    }

    /// Page 1 links with action 6: a chain of `levels` actions, each with /Next [n n] to the next.
    private static func actionChain(_ levels: Int, _ last: String) -> [UInt8] {
        var objects = [
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R 4 0 R] /Count 2 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Annots [5 0 R] >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] >>",
            "<< /Type /Annot /Subtype /Widget /FT /Btn /Ff 65536 /T (go) /Rect [0 0 100 100] /A 6 0 R >>",
        ]
        for i in 0..<levels {
            objects.append(i == levels - 1 ? last : "<< /S /URI /URI (https://example.com/\(i)) /Next [\(7 + i) 0 R \(7 + i) 0 R] >>")
        }
        return Core2Pdf.build(objects)
    }

    private func buttonHasAction(_ pdf: [UInt8]) throws -> Bool {
        let doc = try Core2Pdf.open(pdf)
        return try #require(doc.page(0).array("Annots")?[0]).has("A")
    }

    @Test func choiceFieldWhoseParentCyclesTakesNewItems() throws {
        let widget = "/Type /Annot /Subtype /Widget /F 4 /P 3 0 R"
        let form = Core2Pdf.form([
            "<< \(widget) /FT /Tx /T (a) /Rect [72 700 250 720] /DA (/Helv 10 Tf 0 g) >>",
            "<< \(widget) /FT /Tx /T (b) /Rect [72 670 250 690] /DA (/Helv 10 Tf 0 g) /V (old) /AA << /C 8 0 R >> >>",
            "<< \(widget) /FT /Ch /T (c) /Rect [72 640 250 660] /DA (/Helv 10 Tf 0 g) /Parent 7 0 R >>",
        ], acroExtra: "/CO [6 0 R]", more: ["<< /S /JavaScript /JS (getField\\('c'\\).setItems\\(['x', 'y']\\); event.value = 'ran';) >>"])
        let result = try within { try FormEditor.fill(form, nil, ["a": "1"]).data }
        let doc = try Core2Pdf.open(result)
        let c = try #require((1..<doc.objectCount).map { doc.object($0) }.first { $0.isDict && $0.text("T") == "c" })
        #expect(c.array("Opt")?.count == 2)
    }

    /// From the Windows file's drawing tests (E5): a form of a 1 MB comment and one square, drawn 100,000 times.
    @Test func shapeDetectionReadsAFormDrawnManyTimesOnce() throws {
        let draws = String(repeating: "/F Do\n", count: 100_000)
        let pdf = Core2Pdf.build([
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /XObject << /F 5 0 R >> >> /Contents 4 0 R >>",
            Core2Pdf.stream("0 0 0 RG 72 72 100 100 re S\n" + draws),
            Core2Pdf.stream("% " + String(repeating: "x", count: 1 << 20) + "\n0 0 1 1 re n", "/Type /XObject /Subtype /Form /BBox [0 0 10 10]"),
        ])
        #expect(try within { try VectorShapes.read(pdf, nil, 0) }.count == 1)
    }

    @Test func deletingAPageWalksSharedActionChainsOnce() throws {
        // 2^40 paths through the chain: each action is looked at once.
        let kept = try within { try PageEditor.delete(Self.actionChain(40, "<< /S /URI /URI (https://example.com/end) >>"), nil, [1]) }
        #expect(try buttonHasAction(kept))
        // The chain still counts: a jump to the deleted page at its end takes the action away.
        let dead = try within { try PageEditor.delete(Self.actionChain(12, "<< /S /GoTo /D [4 0 R /Fit] >>"), nil, [1]) }
        #expect(try !buttonHasAction(dead))
    }

    @Test func deletingAPageSurvivesAnActionThatIsItsOwnNext() throws {
        let pdf = Core2Pdf.build([
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R 4 0 R] /Count 2 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Annots [5 0 R] >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] >>",
            "<< /Type /Annot /Subtype /Link /Rect [0 0 100 100] /A 6 0 R >>",
            "<< /S /URI /URI (https://example.com) /Next [6 0 R] >>",
        ])
        #expect(try Core2Pdf.open(try within { try PageEditor.delete(pdf, nil, [1]) }).pageCount() == 1)
        #expect(try Core2Pdf.open(try within { try PageEditor.extract(pdf, nil, [0]) }).pageCount() == 1)
    }
}
