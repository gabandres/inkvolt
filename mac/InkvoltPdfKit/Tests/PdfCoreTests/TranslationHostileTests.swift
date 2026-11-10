import Foundation
import Testing
@testable import PdfCore

/// Windows' crafted-file tests of `TranslationCopyTests`, the roadmap's 100-page test through a real socket on this Mac,
/// and `TranslationLinkTimingTests` (roadmap 3.1).
@Suite(.serialized) struct TranslationHostileTests {
    typealias T = TranslationCopyTests
    static let letters = T.letters
    static let marked = T.marked

    final class Outcome<V>: @unchecked Sendable { var value: Result<V, Error>? }

    /// `work` on a thread of its own, failing when it takes longer than `seconds` (a hang fails the test, not the run).
    static func within<V>(_ seconds: Double, _ work: @escaping () throws -> V) throws -> V {
        let box = Outcome<V>()
        let done = DispatchSemaphore(value: 0)
        let thread = Thread {
            box.value = Result { try work() }
            done.signal()
        }
        thread.stackSize = 16 << 20
        thread.start()
        if done.wait(timeout: .now() + seconds) == .timedOut { throw AiHostileTests.TimedOut() }
        return try box.value!.get()
    }

    @Test func formsThatMultiplyAreCutShortAndThePageIsNamed() throws {
        let base = T.page("/Fm1 Do", "BT ET", fontText: Self.letters)
        let doc = try PdfEdit.open(base, nil)
        // Eight levels of forms, each drawing the next 60 times: 60^8 drawings of the text at the bottom.
        let fonts = try #require(doc.page(0).dict("Resources")?.dict("Font"))
        func form(_ content: String, _ resources: PObj) -> PObj {
            doc.addStream(latin1Bytes(content), dict: doc.dict([("Type", doc.name("XObject")), ("Subtype", doc.name("Form")), ("BBox", doc.reals(0, 0, 612, 792)),
                                                                ("Resources", resources)]), deflate: false)
        }
        var f = form(T.lines(72, 700, 12, 14, "Hello World"), doc.dict([("Font", fonts)]))
        for _ in 0..<8 { f = form(String(repeating: "/N Do ", count: 60), doc.dict([("XObject", doc.dict([("N", f)]))])) }
        doc.page(0).dict("Resources")!.dict("XObject")!.set("Fm1", f)
        try doc.checkFailure()
        let pdf = try doc.write("")
        let start = Date()
        let plan = try Self.within(240) { try Translation.makePlan(pdf, nil, [0]) }
        #expect(plan.unreadablePages == [0])
        #expect(plan.texts.isEmpty)
        #expect(Date().timeIntervalSince(start) < 240)
        let cancel = CancelToken()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) { cancel.cancel() }
        let cancelled = Date()
        #expect(throws: CancellationError.self) { _ = try Self.within(60) { try Translation.makePlan(pdf, nil, [0], cancel: cancel) } }
        #expect(Date().timeIntervalSince(cancelled) < 30) // Windows' Timing.Limit(5 s): under a minute beside the other suites
    }

    @Test func numbersACraftedPageCantLayOutEndInAFlagNotAHang() throws {
        // A matrix and size so large the arithmetic overflows into infinity.
        let pdf = T.page("BT /FA 1e300 Tf 1e300 0 0 1e300 1e300 1e300 Tm (Hello World) Tj ET " + T.lines(72, 700, 12, 14, "2024 draft!"), fontText: Self.letters)
        let (_, r) = try Self.within(30) { try T.translate(pdf) { _ in "THE DOG" } }
        _ = r
    }

    @Test func aFontSizeOfZeroOrNonsenseDoesntStopThePage() throws {
        let pdf = T.page("BT /FA 0 Tf 1 0 0 1 72 600 Tm (Hello World) Tj /FA -12 Tf 1 0 0 1 72 500 Tm (Hello draft) Tj ET " + T.lines(72, 700, 12, 14, "2024 draft!"),
                         fontText: Self.letters)
        let (_, r) = try T.translate(pdf) { _ in "THE DOG" }
        #expect(r.report.failedPages.isEmpty)
        #expect(ContentEditPdf.text(r.data!).contains("THE DOG"))
    }

    @Test func aPageWithMoreTextPiecesThanCanBeWorkedOutIsNamedAndLeftAlone() throws {
        var sb = "BT /FA 3 Tf "
        for i in 0..<30_000 { sb += "1 0 0 1 \(10 + i % 590) \(10 + i % 770) Tm (a) Tj " }
        sb += "ET "
        let pdf = T.page(sb + T.lines(72, 700, 12, 14, "Hello World"), fontText: Self.letters)
        let (plan, r) = try Self.within(240) { try T.translate(pdf) { _ in "THE DOG" } }
        #expect(plan.crowdedPages == [0])
        #expect(r.data == nil)
    }

    @Test func aPageOfAsManyParagraphsAsAreAllowedFinishesAndCanBeCancelled() throws {
        var sb = "BT /FA 3 Tf "
        for i in 0..<19_000 { sb += "1 0 0 1 \(10 + i * 37 % 580) \(10 + (i * 13 % 770)) Tm (ab) Tj " }
        let pdf = T.page(sb + "ET", fontText: Self.letters)
        let plan = try Self.within(240) { try Translation.makePlan(pdf, nil, [0]) }
        let cancel = CancelToken()
        cancel.cancel()
        #expect(throws: CancellationError.self) { _ = try Translation.makePlan(pdf, nil, [0], cancel: cancel) }
        #expect(plan.paragraphCount > 0)
    }

    @Test func aSingleStretchOfAMillionCharactersIsntSent() throws {
        let pdf = T.page("BT /FA 3 Tf 1 0 0 1 10 700 Tm (\(String(repeating: "a", count: 1_000_000))) Tj ET", fontText: Self.letters)
        let plan = try Self.within(240) { try Translation.makePlan(pdf, nil, [0]) }
        #expect(plan.texts.isEmpty)
        #expect(plan.blocked.contains { $0.why.contains("too long") })
    }

    @Test func aPageThatCantBeReadIsNamedAndTheOthersAreTranslated() throws {
        let doc = try PdfEdit.open(TranslationPdf.report(2), nil)
        // Content that claims Flate but holds noise.
        let bad = doc.addStream([0x78, 0x9C, 0xFF, 0xFE, 0x01, 0x02, 0x03], dict: doc.dict([("Filter", doc.name("FlateDecode"))]), deflate: false)
        doc.page(0).set("Contents", bad)
        try doc.checkFailure()
        let (plan, r) = try T.translate(try doc.write("")) { "\(Self.marked) \($0)" }
        #expect(!plan.texts.contains { $0.page == 0 })
        #expect(ContentEditPdf.text(r.data!, page: 1).contains("\(Self.marked) Chapter"))
    }

    @Test func aHostileFontDoesntStopTheRun() throws {
        // /FA's encoding and widths thrown away: text it can't read back must not take the page down.
        let base = T.page(T.lines(72, 700, 12, 14, "Hello World") + "BT /Nope 12 Tf 1 0 0 1 72 600 Tm (Missing font) Tj ET", fontText: Self.letters)
        let doc = try PdfEdit.open(base, nil)
        let fa = try #require(doc.page(0).dict("Resources")?.dict("Font")?.dict("FA"))
        fa.set("Widths", doc.array([doc.int(-999_999), doc.real(Double.greatestFiniteMagnitude)]))
        fa.set("FirstChar", doc.int(Int(Int32.max)))
        fa.set("LastChar", doc.int(-1))
        fa.set("ToUnicode", doc.int(7))
        try doc.checkFailure()
        let (plan, r) = try T.translate(try doc.write("")) { _ in "Un ñandú" }
        // Whatever it makes of the font: a copy that opens, or nothing translated, and no error out of here.
        if let data = r.data {
            let engine = try PdfEngine.open(data)
            #expect(engine.pageCount == 1)
            engine.close()
        }
        #expect(plan.unreadablePages.filter { $0 != 0 }.isEmpty)
    }

    // ---- The roadmap's test ----

    static func userText(_ body: String) -> String {
        let json = try? JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any]
        return ((json?["messages"] as? [[String: Any]])?.last?["content"] as? String) ?? ""
    }

    /// The roadmap's test, with a local stand-in for the model (no model is run here: see ROADMAP.md): a 100-page report
    /// through a real socket on this Mac keeps its page count and its figures where they were, every paragraph comes out
    /// translated, and nothing is sent anywhere but this Mac (the stand-in binds 127.0.0.1 only).
    @Test func a100PageReportKeepsItsPagesAndFiguresAndEveryParagraphIsTranslated() async throws {
        let pages = 100
        let pdf = TranslationPdf.report(pages)
        let original = pdf
        let sent = AiRecorder<String>()
        let server = try #require(AiLoopbackServer { received in
            let text = Self.userText(received.body)
            sent.add(text)
            return .sse(["\(Self.marked) ", text])
        })
        defer { server.stop() }
        let endpoint = try #require(AiEndpoint.tryParse("http://127.0.0.1:\(server.port)/v1").endpoint)
        #expect(endpoint.reach == .thisMac)

        let plan = try Translation.makePlan(pdf, nil, Array(0..<pages))
        #expect(plan.unreadablePages.isEmpty)
        #expect(plan.blocked.isEmpty)
        let jobs = Translation.jobs(plan, Translation.pieceTokens(AiText.defaultContextTokens))

        // Connects through the app's handler, recording every name it would look up.
        let resolved = AiRecorder<String>()
        let handler = AiClient.createHandler(endpoint, resolve: { host in
            resolved.add(host)
            return try await AiSocketTransport.systemResolve(host)
        })
        let client = AiClient(endpoint, "local-model", apiKey: nil, handler: handler)
        let seen = AiRecorder<Int>()
        let answers = await Translation.translate(jobs, "Spanish", { m, t, c in try await client.chat(m, onText: t, cancel: c) },
                                                  progress: { seen.add($0.done) })
        #expect(answers.failed.isEmpty, "\(answers.failed.first.map { "\($0.key): \($0.value)" } ?? "")")
        #expect(answers.done.count == jobs.count)
        #expect(seen.all.max() == jobs.count) // progress came to the end

        let start = Date()
        let result = try Translation.apply(plan, answers, "es")
        let writing = Date().timeIntervalSince(start)
        let copy = try #require(result.data)

        // The original stays; nothing beyond this Mac was contacted.
        #expect(original == pdf)
        #expect(server.received.count == jobs.reduce(0) { $0 + $1.pieces.count })
        #expect(resolved.all.isEmpty) // the address is a literal 127.0.0.1: no name was even looked up
        #expect(sent.all.allSatisfy { !($0.split(separator: " ").first ?? "").contains("report") })

        // Page count and figure positions.
        let engine = try PdfEngine.open(copy)
        defer { engine.close() }
        #expect(engine.pageCount == pages)
        for p in 0..<pages {
            let figures = TranslationPdf.images(copy, p)
            #expect(figures.count == 1)
            if let f = figures.first {
                let fig = TranslationPdf.figure
                #expect(abs(f.x - fig.x) < 0.01 && abs(f.y - fig.y) < 0.01 && abs(f.width - fig.width) < 0.01 && abs(f.height - fig.height) < 0.01, "page \(p + 1): \(f)")
            }
        }

        // Every paragraph translated: every text on every page begins with the marker, and no source sentence is left.
        #expect(result.report.translated == plan.paragraphCount)
        #expect(result.report.notTranslated == 0)
        #expect(result.report.flags.isEmpty, "\(result.report.flags.prefix(3))")
        #expect(result.report.doNotFit == 0)
        #expect(result.report.failedPages.isEmpty)
        var total = 0
        for p in 0..<pages {
            let text = try engine.text(p, cache: false).text
            #expect(T.plain(text).contains(T.plain(Self.marked + " Section")))
            total += text.components(separatedBy: Self.marked).count - 1
            // Not only there for extraction: every line shows, at a real height (each line of the fixture sits on a white band).
            let problems = TranslationInk.problems(engine, p)
            #expect(problems.isEmpty, "page \(p + 1): \(problems.prefix(3))")
            #expect(!text.replacingOccurrences(of: Self.marked + " Chapter", with: "").contains("Chapter \(p + 1):"))
            // No paragraph over another: the copy's paragraphs on this page, in their boxes, don't overlap the figure.
            let fig = TranslationPdf.figure
            for q in try ContentEditor.read(copy, nil, p).paragraphs {
                let over = q.box.y < fig.bottom - 1 && q.box.bottom > fig.y + 1 && q.box.x < fig.right && q.box.right > fig.x
                #expect(!over, "page \(p + 1): \"\(q.text)\" over the figure")
            }
        }
        #expect(total == plan.paragraphCount)
        #expect(writing < 300, "writing took \(writing) s") // 2 minutes on Windows, alone
    }

    @Test func anEndpointThatRedirectsElsewhereGetsNothingFollowed() async throws {
        let elsewhere = try #require(AiLoopbackServer { _ in .sse(["Hola."]) })
        defer { elsewhere.stop() }
        let redirecting = try #require(AiLoopbackServer { _ in
            .raw("HTTP/1.1 307 Temporary Redirect\r\nLocation: http://127.0.0.1:\(elsewhere.port)/v1/chat/completions\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
        })
        defer { redirecting.stop() }
        let endpoint = try #require(AiEndpoint.tryParse("http://127.0.0.1:\(redirecting.port)/v1").endpoint)
        let client = AiClient(endpoint, "m", apiKey: "the-key")
        let answers = await Translation.translate([TranslationJob("A paragraph.", 0, ["A paragraph."]), TranslationJob("Another.", 0, ["Another."])], "Spanish",
                                                  { m, t, c in try await client.chat(m, onText: t, cancel: c) })
        #expect(answers.stoppedBecause?.contains("redirects") == true, "\(answers.stoppedBecause ?? "")")
        #expect(redirecting.received.count == 1) // and it stopped at the first
        #expect(elsewhere.received.isEmpty)
        #expect(answers.done.isEmpty)
    }

    @Test func aNameThatResolvesOffThisMacGetsNothingSent() async throws {
        let endpoint = try #require(AiEndpoint.tryParse("http://model.localhost:11434/v1").endpoint)
        let handler = AiClient.createHandler(endpoint, resolve: { _ in [AiAddress("93.184.216.34")!] })
        let client = AiClient(endpoint, "m", apiKey: nil, handler: handler)
        var settings = TranslationSettings()
        settings.retryWaits = []
        let answers = await Translation.translate([TranslationJob("A paragraph.", 0, ["A paragraph."])], "Spanish",
                                                  { m, t, c in try await client.chat(m, onText: t, cancel: c) }, settings: settings)
        #expect(answers.failed["A paragraph."]?.contains("the endpoint") == true, "\(answers.failed)")
        #expect(answers.done.isEmpty)
    }

    // ---- Windows' TranslationLinkTimingTests ----

    @Test func aLinksWordsAreLookedForQuicklyInALongParagraph() {
        // The most words a link and a paragraph give, every new word beginning the link's first: milliseconds, not seconds.
        let link = (0..<64).map { "w\($0)" }
        let text = Array(repeating: "w0", count: 4_000)
        _ = ContentEditor.follow(["w0"], ["w0"], [])
        let start = threadSeconds()
        #expect(ContentEditor.follow(link, text, []).count == 4_000)
        // 1 s on Windows' release build; swift test builds for debug, and beside the other suites it takes longer.
        #expect(threadSeconds() - start < 6, "\(threadSeconds() - start) s")
    }

    @Test func aLinkOverOneVeryLongWordIsGivenUpOnQuickly() {
        // A crafted page: a link over 100,000 letters without a space, which the translation kept, beside a word as long.
        let word = String(repeating: "a", count: 99_999) + "1"
        _ = ContentEditor.follow(["w0"], ["w0"], [])
        let start = threadSeconds()
        let found = ContentEditor.follow([word, "b" + word], ["x" + word, "y" + word], [])
        #expect(threadSeconds() - start < 3, "\(threadSeconds() - start) s") // 1 s on Windows' release build
        #expect(found.isEmpty)
        #expect(ContentEditor.follow([word], [word], []).isEmpty)
        // A word of a link's usual length is still followed.
        #expect(ContentEditor.follow(["SP", "800-63A"], ["la", "SP", "800-63A,", "dice"], []).map { [$0.start, $0.count] } == [[1, 2]])
    }
}
