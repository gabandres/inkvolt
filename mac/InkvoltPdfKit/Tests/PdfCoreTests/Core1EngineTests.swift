import Foundation
import Testing
@testable import PdfCore

/// Ported from Core1EngineTests.cs (its Core1SessionTests come with D2's document session, and the page-range test of
/// Core1TextTests with D3). The timing tests run one at a time, so the rest of the suite doesn't skew them.
@Suite(.serialized)
struct Core1EngineTests {
    @Test func cancelledRenderThrows() throws {
        let engine = try PdfEngine.open(TestPdf.make(1))
        defer { engine.close() }
        let cancel = CancelToken()
        cancel.cancel()
        #expect(throws: CancellationError.self) { try engine.render(0, scale: 1, cancel: cancel) }
        let never = FileManager.default.temporaryDirectory.appendingPathComponent("never.png").path
        #expect(throws: CancellationError.self) { try engine.saveImage(0, dpi: 72, path: never, jpeg: false, cancel: cancel) }
        #expect(!FileManager.default.fileExists(atPath: never))
    }

    @Test(arguments: [
        (0.5, 0.0, 0.0, 612.0, 792.0),
        (1.37, 13.3, 7.9, 201.7, 99.1),
        (2.91, 300.25, 500.5, 311.75, 291.5),
        (0.13, 1.0, 1.0, 600.0, 700.0),
    ])
    func cancellableRenderMatchesPlainRender(scale: Double, x: Double, y: Double, w: Double, h: Double) throws {
        let engine = try PdfEngine.open(TestPdf.make(1))
        defer { engine.close() }
        let region = RectD(x, y, w, h)
        let plain = try engine.render(0, scale: scale, region: region)
        let cancellable = try engine.render(0, scale: scale, region: region, cancel: CancelToken())
        #expect(plain == cancellable)
    }

    @Test func renderStopsMidwayWhenCancelled() throws {
        let engine = try PdfEngine.open(Core1TestPdf.heavy())
        defer { engine.close() }
        let start = Date()
        _ = try engine.render(0, scale: 1)
        let full = Date().timeIntervalSince(start)
        if full < 0.05 { return } // too fast here to cancel midway

        // Cancel a fifth of the way in, from a thread of its own.
        let cancel = CancelToken()
        let canceller = Thread {
            Thread.sleep(forTimeInterval: full / 5)
            cancel.cancel()
        }
        let cutStart = Date()
        canceller.start()
        #expect(throws: CancellationError.self) { try engine.render(0, scale: 1, cancel: cancel) }
        let cut = Date().timeIntervalSince(cutStart)
        if full > 0.4 { #expect(cut < full * 0.6, "cancelled after \(cut) s; full render \(full) s") }

        // The engine is fine afterwards.
        #expect(abs(Double(try engine.render(0, scale: 0.1).width * 10) - 612) <= 10)
    }

    @Test func textDoesNotWaitForARender() throws {
        let engine = try PdfEngine.open(Core1TestPdf.heavy())
        defer { engine.close() }
        let start = Date()
        _ = try engine.render(0, scale: 1)
        let full = Date().timeIntervalSince(start)
        if full < 0.3 { return } // too fast here to tell

        let started = DispatchSemaphore(value: 0)
        let done = DispatchSemaphore(value: 0)
        Thread {
            started.signal()
            _ = try? engine.render(0, scale: 1)
            done.signal()
        }.start()
        started.wait()
        Thread.sleep(forTimeInterval: 0.02)
        let textStart = Date()
        _ = try engine.text(0)
        _ = try engine.links(0)
        _ = try engine.outline()
        let text = Date().timeIntervalSince(textStart)
        let renderDone = done.wait(timeout: .now()) == .success
        #expect(!(renderDone && text > full / 2), "text took \(text) s during a \(full) s render")
        if !renderDone { done.wait() }
    }

    @Test func refusesHugeImages() throws {
        let engine = try PdfEngine.open(TestPdf.make(1))
        defer { engine.close() }
        let render = #expect(throws: PdfEngineError.self) { try engine.render(0, scale: 100) }
        #expect(render?.message.contains("too large") == true)
        let never = FileManager.default.temporaryDirectory.appendingPathComponent("never.png").path
        let save = #expect(throws: PdfEngineError.self) { try engine.saveImage(0, dpi: 8000, path: never, jpeg: false) }
        #expect(save?.message.contains("too large") == true)
        #expect(abs(try engine.render(0, scale: 2).width - 1224) <= 1)
    }

    @Test func encryptedDocumentTextUsesThePassword() throws {
        let engine = try PdfEngine.open(TestPdf.encrypted(2, "pw"), password: "pw")
        defer { engine.close() }
        #expect(engine.isEncrypted)
        #expect(try engine.text(1).text.contains("Page 2"))
        #expect(try engine.outline().isEmpty)
    }

    @Test func previewEngineReadsTextFromTheFile() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("inkvoltpdf-\(UUID().uuidString).pdf")
        try Data(TestPdf.make(2)).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let engine = try #require(try PdfEngine.openPreview(path: url.path))
        defer { engine.close() }
        #expect(try engine.text(1).text.contains("Page 2"))
        let encrypted = url.deletingLastPathComponent().appendingPathComponent("inkvoltpdf-\(UUID().uuidString).pdf")
        try Data(TestPdf.encrypted(1, "pw")).write(to: encrypted)
        defer { try? FileManager.default.removeItem(at: encrypted) }
        #expect(try PdfEngine.openPreview(path: encrypted.path) == nil)
    }

    @Test func closeWhileTextIsInUseIsSafe() throws {
        for _ in 0..<5 {
            let engine = try PdfEngine.open(TestPdf.make(3))
            let done = DispatchSemaphore(value: 0)
            Thread {
                do {
                    for p in 0..<3 { _ = try engine.text(p, cache: false) }
                } catch {
                    // PdfEngineClosed, once the engine is closed
                }
                done.signal()
            }.start()
            _ = try engine.render(0, scale: 0.2)
            engine.close()
            done.wait()
            #expect(throws: PdfEngineClosed.self) { try engine.text(0) }
        }
    }
}

/// Ported from Core1EngineTests.cs's Core1TextTests (but PageRangesAcceptTypographicDashes, which comes with D3).
struct Core1TextTests {
    private func lines(_ lines: String...) -> PageText {
        PageText(lines.enumerated().map { y, line in
            Array(line).enumerated().map { x, c in (String(c), RectD(Double(x * 10), Double(y * 20), 10, 16)) }
        })
    }

    @Test func findsWordsHyphenatedAcrossLines() {
        let text = lines("an exam-", "ple here")
        let hits = text.find("example", matchCase: false, wholeWord: true)
        #expect(hits.count == 1)
        #expect(text.string(hits[0].start, hits[0].end) == "exam-\nple")
        #expect(text.rects(hits[0].start, hits[0].end).count == 2)

        let soft = lines("an exam\u{AD}", "ple here")
        let s = soft.find("example", matchCase: false, wholeWord: false)[0]
        #expect(soft.string(s.start, s.end) == "exam\u{AD}\nple")

        // Numbers and dashes at line ends stay as they are; queries spanning other line breaks still work.
        #expect(lines("1990-", "2000").find("19902000", matchCase: false, wholeWord: false).isEmpty)
        #expect(lines("1990-", "2000").find("1990- 2000", matchCase: false, wholeWord: false).count == 1)
        let both = lines("an exam-", "ple here").find("example here", matchCase: false, wholeWord: false)[0]
        #expect(both.start == 3 && both.end == 17)
    }

    @Test func ignoresAccentsOnRequest() throws {
        let text = lines("Un café crème")
        #expect(text.find("cafe", matchCase: false, wholeWord: false).isEmpty)
        let hits = text.find("cafe creme", matchCase: false, wholeWord: false, ignoreAccents: true)
        try #require(hits.count == 1)
        #expect(text.string(hits[0].start, hits[0].end) == "café crème")
        #expect(text.find("CAFÉ", matchCase: false, wholeWord: true).count == 1)
        #expect(text.find("CAFÉ", matchCase: true, wholeWord: true).isEmpty)
    }

    @Test func matchLengthComesFromTheComparer() throws {
        // A decomposed "é" (e + combining acute) is one letter to the comparer but two UTF-16 units in the text.
        let text = lines("cafe\u{301} au lait")
        let hits = text.find("café au", matchCase: false, wholeWord: false)
        try #require(hits.count == 1)
        #expect(text.string(hits[0].start, hits[0].end) == "cafe\u{301} au")
        #expect(text.find("café", matchCase: false, wholeWord: true).count == 1)
    }

    @Test func ignorableOnlyQueryFindsNothing() {
        #expect(lines("abc").find("\u{AD}", matchCase: false, wholeWord: false).isEmpty)
    }
}
