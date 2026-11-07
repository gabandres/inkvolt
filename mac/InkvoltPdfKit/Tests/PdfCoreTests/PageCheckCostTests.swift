import Foundation
import MuPDFShim
import PrintCore
import Testing
@testable import PdfCore

/// The page checks' second review: what they cost a document read page after page (each object's streams checked once,
/// the clock read once per quarter kilobyte), a budget per reading thread, degenerate patterns, Cancel's handlers
/// calling back, inline pictures.
extension PageCheckTests {
    /// `count` pages sharing a font and a form (with a font of its own), each with content of its own.
    static func sharing(_ count: Int) -> [UInt8] {
        let first = 6
        var objects = [
            obj("<< /Type /Catalog /Pages 2 0 R >>"),
            obj("<< /Type /Pages /Kids [\((0..<count).map { "\(first + 2 * $0) 0 R" }.joined(separator: " "))] /Count \(count) >>"),
            obj("<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>"),
            stream("BT /F2 9 Tf 40 40 Td (Sheet footer) Tj ET", "/Type /XObject /Subtype /Form /BBox [0 0 612 100] /Resources << /Font << /F2 5 0 R >> >>"),
            obj("<< /Type /Font /Subtype /Type1 /BaseFont /Courier >>"),
        ]
        for p in 0..<count {
            let page = "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents \(first + 2 * p + 1) 0 R "
                + "/Resources << /Font << /F1 3 0 R >> /XObject << /Fm 4 0 R >> >> >>"
            objects.append(obj(page))
            objects.append(stream("BT /F1 14 Tf 72 700 Td (Page \(p + 1)) Tj ET q /Fm Do Q"))
        }
        return build(objects)
    }

    @Test func EachObjectsStreamsAreCheckedOnceADocument() throws {
        // Find, a drawing, a list read the same page again, and every page reaches the same fonts and forms: before, each
        // call resolved all of them again just to read their filters (the review's likely cause of Find's slowdown).
        let engine = try Self.open(Self.sharing(20))
        defer { engine.close() }
        _ = try engine.render(0, scale: 0.2, annotations: false) // its own list each time: the walk runs each time
        let first = engine.countsForTests().walked
        #expect(first == 5, "\(first)") // the page, its content, the font, the form, the form's font
        _ = try engine.render(0, scale: 0.3, annotations: false)
        #expect(engine.countsForTests().walked == first, "the same page again")
        _ = try engine.render(1, scale: 0.2, annotations: false)
        #expect(engine.countsForTests().walked == first + 2, "another page: its own object and content only")
        for p in 2..<20 { _ = try engine.render(p, scale: 0.1) }
        #expect(engine.countsForTests().walked == first + 2 * 19)
        #expect(try engine.text(19).text.contains("Page 20"))
    }

    @Test func AStreamFoundFineIsCheckedAgainOnceTheDocumentIsEdited() throws {
        // A document whose objects change in place (an edit makes MuPDF start an incremental section) keeps no verdicts:
        // a stream found fine and then given four Flates is refused. Driven through the shim, as no engine edits its own
        // document.
        let file = Self.sharing(2)
        guard let ctx = inkv_new_context(0) else { Issue.record("no context"); return }
        defer { inkv_drop_context(ctx) }
        var err = [CChar](repeating: 0, count: Int(INKV_ERR_SIZE))
        guard let doc = file.withUnsafeBufferPointer({ inkv_open_pdf(ctx, $0.baseAddress, $0.count, 8, &err) }) else {
            Issue.record("not opened"); return
        }
        defer { inkv_drop_doc(ctx, doc) }
        func draw() -> (Int32, Int32) {
            guard let cookie = inkv_new_cookie() else { return (-1, -1) }
            defer { inkv_drop_cookie(cookie) }
            inkv_cookie_limit(cookie, 30, PdfEngine.maxPicturePixels)
            var pixels: UnsafeMutablePointer<UInt8>?
            var w: Int32 = 0, h: Int32 = 0
            let result = inkv_render_rgb_contents(ctx, doc, 0, 0.2, 0, 0, 612, 792, 1, cookie, &pixels, &w, &h, &err)
            inkv_free(pixels)
            return (result, inkv_cookie_stopped(cookie))
        }
        #expect(draw() == (1, 0))
        #expect(draw() == (1, 0)) // its verdicts kept: nothing walked again
        // The shared form (object 4) is given four Flates in place, through a call that doesn't name the document.
        guard let form = inkv_obj_ref(ctx, doc, 4, &err), let filters = inkv_obj_new(ctx, doc, 6, 0, nil, nil, 0, &err) else {
            Issue.record("no form"); return
        }
        defer {
            inkv_obj_drop(ctx, form)
            inkv_obj_drop(ctx, filters)
        }
        for i in 0..<4 {
            guard let flate = inkv_obj_new(ctx, doc, 4, 0, "FlateDecode", nil, 0, &err) else { Issue.record("no name"); return }
            #expect(inkv_obj_array_insert(ctx, filters, Int32(i), flate, &err) == 1)
            inkv_obj_drop(ctx, flate)
        }
        #expect(inkv_obj_put(ctx, form, "Filter", filters, &err) == 1)
        #expect(draw() == (2, 4)) // refused for its filters: the walk ran again
    }

    @Test func TheDocumentsStreamReadsTheClockOncePerQuarterKilobyte() throws {
        // A page of 1,000 small forms, each its own object: every one is read in chunks that start at 16 bytes. The CPU
        // clock (a kernel call) was read three times a chunk; now once per 256 bytes handed over, or per larger chunk.
        let forms = 1_000
        var objects = [
            Self.obj("<< /Type /Catalog /Pages 2 0 R >>"),
            Self.obj("<< /Type /Pages /Kids [3 0 R] /Count 1 >>"),
            Self.obj("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R /Resources << /XObject << "
                + (0..<forms).map { "/F\($0) \(5 + $0) 0 R" }.joined(separator: " ") + " >> >> >>"),
            Self.stream((0..<forms).map { "q 1 0 0 1 \($0 % 40 * 15) \($0 / 40 * 30) cm /F\($0) Do Q" }.joined(separator: "\n")),
        ]
        for i in 0..<forms {
            objects.append(Self.stream("0 0 \(5 + i % 7) \(5 + i % 11) re f", "/Type /XObject /Subtype /Form /BBox [0 0 20 20]"))
        }
        let file = Self.build(objects)
        let engine = try Self.open(file)
        defer { engine.close() }
        _ = try engine.render(0, scale: 0.5)
        let reads = engine.countsForTests().clockReads
        #expect(reads > 0)
        #expect(reads <= file.count / 256 + 50, "\(reads) reads for \(file.count) bytes")
        #expect(engine.verdictOf(0) == .fine)
    }

    @Test func FindsThreadsEachHaveTheBudgetOfTheirOwnPages() throws {
        // A cookie is made for one call, begun and used on the thread that makes the call (MuPDF starts no threads), and
        // its deadline is that thread's CPU time: Find's threads, each with its own engine instance, each give each
        // page the budget. 64 pages of some 20 ms each, a budget of 0.25 s: together they take seconds of CPU time,
        // and none is refused.
        var objects = [
            Self.obj("<< /Type /Catalog /Pages 2 0 R >>"),
            Self.obj("<< /Type /Pages /Kids [\((0..<64).map { "\(4 + 2 * $0) 0 R" }.joined(separator: " "))] /Count 64 >>"),
            Self.obj("<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>"),
        ]
        let words = (0..<6_000).map { "1 0 0 1 \($0 % 60 * 10) \($0 / 60 * 7) Tm (w\($0)) Tj" }.joined(separator: "\n")
        for p in 0..<64 {
            objects.append(Self.obj("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents \(5 + 2 * p) 0 R /Resources << /Font << /F1 3 0 R >> >> >>"))
            objects.append(Self.stream("BT /F1 6 Tf \(words) ET BT /F1 12 Tf 72 760 Td (lantern \(p)) Tj ET"))
        }
        let engine = try Self.open(Self.build(objects), budget: 0.25)
        defer { engine.close() }
        let started = ProcessInfo.processInfo.systemUptime
        var cpu = rusage()
        getrusage(RUSAGE_SELF, &cpu)
        let before = Double(cpu.ru_utime.tv_sec) + Double(cpu.ru_utime.tv_usec) / 1e6
        let found = try engine.findAll("lantern", matchCase: false, wholeWord: false)
        getrusage(RUSAGE_SELF, &cpu)
        let used = Double(cpu.ru_utime.tv_sec) + Double(cpu.ru_utime.tv_usec) / 1e6 - before
        #expect(found.filter { !$0.hits.isEmpty }.count == 64)
        #expect(found.allSatisfy { $0.refused == nil }, "\(found.compactMap(\.refused).map(\.page))")
        #expect(used > 0.25, "\(used) s of CPU in \(ProcessInfo.processInfo.systemUptime - started) s")
    }

    static let degenerate = [
        "/Matrix [0 0 0 0 0 0]", "/Matrix [0 0 0 1 0 0]", "/Matrix [1 0 0 0 0 0]", "/Matrix [0.000001 0 0 0.000001 0 0]",
        "/Matrix [0 0 0 0 300 400]", "/XStep 0", "/YStep 0",
    ]

    /// A page filled with a pattern whose dictionary has `odd` (its matrix, or a step), with "Visit notes" over it.
    static func oddPattern(_ odd: String) -> [UInt8] {
        let step = odd.contains("XStep") || odd.contains("YStep")
        let steps = (odd.contains("XStep") ? "" : " /XStep 6") + (odd.contains("YStep") ? "" : " /YStep 6")
        let dict = "/Type /Pattern /PatternType 1 /PaintType 1 /TilingType 1 /BBox [0 0 6 6] "
            + (step ? odd + steps : "/XStep 6 /YStep 6 " + odd) + " /Resources << >>"
        return build([
            obj("<< /Type /Catalog /Pages 2 0 R >>"),
            obj("<< /Type /Pages /Kids [3 0 R] /Count 1 >>"),
            obj("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R /Resources << /Pattern << /P1 5 0 R >> /Font << /F1 6 0 R >> >> >>"),
            stream("q /Pattern cs /P1 scn 0 0 612 792 re f Q 0 g BT /F1 48 Tf 72 600 Td (Visit notes) Tj ET"),
            stream("0 0 m 6 6 l S 0 0 3 3 re f", dict),
            obj("<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>"),
        ])
    }

    @Test(arguments: degenerate)
    func ADegeneratePatternDrawsNothingAndTheRestOfThePageDraws(_ odd: String) throws {
        // A pattern of no area or with a step of 0 (found in harmless real files): its tiles can't be counted, and the
        // draw device's own count runs to billions (a step of 0) or comes from a matrix it can't invert. It shows
        // nothing; the page isn't refused, the rest of it draws. Red: a step of 0 refused the page (its count wasn't a
        // number); the matrices of no area already drew nothing (MuPDF hands back a matrix it can't invert unchanged,
        // so the area shown came out empty) and stay here for the guard's new check.
        let engine = try Self.open(Self.oddPattern(odd))
        defer { engine.close() }
        for scale in [72 / 72.0, 600 / 72.0] {
            var pixels: [UInt8] = []
            let took = try Self.time { pixels = try engine.render(0, scale: scale).pixels }
            #expect(took < Self.slack, "\(odd) at \(scale): \(took) s")
            if scale == 1 { #expect(pixels.contains { $0 < 128 }, "\(odd): the text wasn't drawn") }
        }
        #expect(engine.verdictOf(0) == .fine, "\(odd)")
        #expect(try engine.text(0).text.contains("Visit notes"))
    }

    @Test func APatternWithNoStepAtAllIsRefusedWithinTheLimit() throws {
        // Both steps 0: MuPDF's interpreter draws the tiles itself, 2^62 of them (its count of them isn't a number),
        // and swallowed the stream's "not yet" once the time was up, a tile at a time: the page read for ever (red: 11
        // minutes, then stopped by hand). Reads after a stop now stop MuPDF, so the page is refused at the limit.
        let engine = try Self.open(Self.oddPattern("/XStep 0 /YStep 0"))
        defer { engine.close() }
        var refusal: PageRefused?
        let took = Self.time { refusal = Self.refused { _ = try engine.render(0, scale: 1) } }
        #expect(took < Self.limit + Self.slack, "\(took) s")
        #expect(refusal?.tooSlow == true)
        #expect(Self.refused { _ = try engine.text(0) }?.tooSlow == true) // at once from then on
    }

    @Test func AHandlerCallingBackIntoItsTokenDoesntWaitForItself() {
        // cancel() runs the handlers on its own thread; one that unregisters itself or another, registers, looks at or
        // cancels its token doesn't wait for itself (the deadlock the review asked about), and one unregistered before
        // its turn doesn't run.
        for _ in 0..<200 {
            let token = CancelToken()
            let lock = NSLock()
            var ran: [String] = []
            var ids: [String: Int] = [:]
            func note(_ s: String) { lock.withLock { ran.append(s) } }
            func id(_ s: String) -> Int? { lock.withLock { ids[s] } }
            for (me, other) in [("a", "b"), ("b", "a")] {
                let registered = token.register {
                    note(me)
                    token.unregister(id(me))
                    token.unregister(id(other))
                    _ = token.register { note("late") } // already cancelled: runs at once, here
                    _ = token.isCancelled
                    token.cancel()
                }
                lock.withLock { ids[me] = registered }
            }
            let done = DispatchSemaphore(value: 0)
            DispatchQueue.global().async {
                token.cancel()
                done.signal()
            }
            #expect(done.wait(timeout: .now() + 5) == .success, "cancel() is stuck")
            let order = lock.withLock { ran }
            #expect(order.count == 2 && order.last == "late", "\(order)") // one of a and b, then its late handler
        }
    }

    @Test func UnregisteringFromALinkedTokensHandlerDoesntDeadlock() {
        // The AI's deadline: the parent's handler cancels a child token, whose handler unregisters from the parent (on
        // the thread running the parent's handlers), while the call's own thread unregisters from the child and the
        // parent. Hammered, each round within a time.
        var stuck = 0
        for i in 0..<500 {
            let parent = CancelToken(), child = CancelToken()
            let box = NSLock()
            var parentId: Int?
            let childId = child.register { box.withLock { parent.unregister(parentId) } }
            box.withLock { parentId = parent.register { child.cancel() } }
            let done = DispatchSemaphore(value: 0)
            DispatchQueue.global().async {
                parent.cancel()
                done.signal()
            }
            if i % 2 == 0 { child.unregister(childId) }
            parent.unregister(box.withLock { parentId })
            if done.wait(timeout: .now() + 5) != .success { stuck += 1 }
        }
        #expect(stuck == 0, "\(stuck) of 500 rounds deadlocked")
    }

    @Test func AnInlinePictureLargerThanTheLimitIsRefusedBeforeItDecodes() throws {
        // MuPDF decodes an inline picture (BI … ID … EI) whole while it parses the content, before the guard sees it:
        // 50,000 x 50,000 gray is 2.5 GB of pixels written from a megabyte of Flate. Refused at the allocation, at once;
        // a small inline picture still draws.
        let huge = Self.zlib([], zeros: 50_000 * 50_000)
        let inline = Array("q 400 0 0 400 100 200 cm BI /W 50000 /H 50000 /BPC 8 /CS /G /F /Fl ID ".utf8) + huge
            + Array(" EI Q BT /F1 12 Tf 72 100 Td (Second) Tj ET".utf8)
        let small = Array("q 100 0 0 100 100 300 cm BI /W 2 /H 2 /BPC 8 /CS /G ID ".utf8) + [0, 0, 0, 0]
            + Array(" EI Q BT /F1 12 Tf 72 100 Td (Third) Tj ET".utf8)
        let file = Self.build([
            Self.obj("<< /Type /Catalog /Pages 2 0 R >>"),
            Self.obj("<< /Type /Pages /Kids [3 0 R 4 0 R] /Count 2 >>"),
            Self.obj("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 5 0 R /Resources << /Font << /F1 7 0 R >> >> >>"),
            Self.obj("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 6 0 R /Resources << /Font << /F1 7 0 R >> >> >>"),
            Self.stream(inline),
            Self.stream(small),
            Self.obj("<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>"),
        ])
        let engine = try Self.open(file, budget: 120)
        defer { engine.close() }
        for read in ["text", "render"] {
            var refusal: PageRefused?
            let took = Self.time {
                refusal = Self.refused {
                    if read == "text" { _ = try engine.text(0, cache: false) } else { _ = try engine.render(0, scale: 0.5) }
                }
            }
            #expect(took < 1, "\(read): \(took) s")
            #expect(refusal?.tooSlow == false, "\(read)")
        }
        #expect(engine.verdictOf(0) == .failed)
        #expect(try engine.render(1, scale: 0.5).pixels.contains { $0 < 64 })
        #expect(try engine.text(1).text.contains("Third"))
    }
}
