import Foundation
import Synchronization
import Testing
@testable import PrintCore

/// Ported from DirectPrintTests.cs (roadmap 2.1, driverless printing; the encoders are RasterEncoderTests'): the IPP requests
/// and the collection decoding; what a printer's attributes allow and the plan made from them, hostile values included; and a
/// job through a fake printer (FixtureTransport's Print-Job, as Windows' FixtureHandler). Left out: The_apps_state_file_puts_
/// back_every_list_a_hand_edit_left_null (it reads Windows' AppState.cs) and Photo_names_map_both_ways (Print Schema names for
/// Windows' Print Photos; the Mac's Print Photos prints through a macOS queue). Mac differences: a plan's problem comes back as
/// a `DirectPrintProblem` (Windows: an out string); a job listed by Get-Jobs keeps its IPP `job-state` (`JobState`) where
/// Windows maps it to the spooler's status bits; the printer that wants a signed-in user is sent to a macOS queue.
struct DirectPrintTests {
    // ---- IPP: requests, collections, hostile replies ----

    private static func plan(_ paper: DirectPaper? = nil) -> DirectPrintPlan {
        var p = DirectPrintPlan(.pwgRaster, dpi: 300, color: .rgb8, paper: paper ?? DirectPaper("na_letter_8.5x11in", 21590, 27940, 635, 635, 635, 635))
        (p.twoSided, p.copies, p.colorMode, p.quality, p.mediaType) = (true, 2, "color", 5, "photographic-glossy")
        return p
    }

    private static func group(_ body: [UInt8], _ index: Int) throws -> IppResponse {
        let groups = try IppCodec.decodeGroups(body).groups
        return IppResponse(statusCode: 0, attributes: groups[index].attributes)
    }

    @Test func printJobHasItsOperationAndJobAttributesInOrder() throws {
        let body = DirectJob.printJobRequest("ipp://192.0.2.11:631/ipp/print", user: "ana", jobName: "report.pdf", Self.plan(), requestId: 7)
        #expect(Array(body[0..<9]) == [2, 0, 0, 2, 0, 0, 0, 7, 1]) // IPP/2.0, Print-Job, request 7, operation group
        let (status, groups, end) = try IppCodec.decodeGroups(body)
        #expect(status == 2) // the operation id sits where a reply's status does
        #expect(end == body.count)
        // The operation attributes in the order written: the names as they come on the wire.
        #expect(Self.names(body, group: 0) == ["attributes-charset", "attributes-natural-language", "printer-uri", "requesting-user-name", "job-name", "document-format"])
        #expect(IppResponse(statusCode: 0, attributes: groups[0].attributes).str("document-format") == "image/pwg-raster")
        #expect(groups[1].tag == IppCodec.jobTag)
        let job = IppResponse(statusCode: 0, attributes: groups[1].attributes)
        #expect(job.int("copies") == 2)
        #expect(job.str("sides") == "two-sided-long-edge")
        #expect(job.str("print-color-mode") == "color")
        #expect(job.int("print-quality") == 5)
        let col = try #require(job.collections("media-col").first)
        #expect(col.collection("media-size")?.int("x-dimension") == 21590)
        #expect(col.collection("media-size")?.int("y-dimension") == 27940)
        #expect(col.int("media-top-margin") == 635)
        #expect(col.str("media-type") == "photographic-glossy")
        #expect(body.last == IppCodec.endTag)
    }

    /// The named attributes of one group as they come, in order (the decoded dictionary has no order).
    private static func names(_ b: [UInt8], group: Int) -> [String] {
        var names: [String] = []
        var i = 8, g = -1
        while i < b.count {
            let tag = b[i]
            i += 1
            if tag == IppCodec.endTag { break }
            if tag < 0x10 { g += 1; continue }
            let n = Int(b[i]) << 8 | Int(b[i + 1])
            let name = String(decoding: b[i + 2..<i + 2 + n], as: UTF8.self)
            i += 2 + n
            let v = Int(b[i]) << 8 | Int(b[i + 1])
            i += 2 + v
            if g == group && !name.isEmpty { names.append(name) }
        }
        return names
    }

    @Test func aCollectionIsWrittenAsRfc8010HasIt() throws {
        var r = IppRequest(IppCodec.printJob, requestId: 1, printerUri: "ipp://x/")
        r.jobGroup()
        r.collection("media-col") { c in c.collection("media-size") { s in s.integer("x-dimension", 1) } }
        let body = r.finished()
        let at = try #require(Self.index(of: [0x34, 0, 9], in: body)) // media-col, the job group's only attribute
        #expect(body[at - 1] == IppCodec.jobTag)
        // One append per piece: Xcode 26's Swift gives up on the sum written as one expression.
        var expected: [UInt8] = [0x34, 0, 9]
        expected += Array("media-col".utf8)
        expected += [0, 0] as [UInt8]                                  // begCollection "media-col"
        expected += [0x4A, 0, 0, 0, 10] as [UInt8]
        expected += Array("media-size".utf8)                           // memberAttrName "media-size"
        expected += [0x34, 0, 0, 0, 0] as [UInt8]                      // its value: a collection
        expected += [0x4A, 0, 0, 0, 11] as [UInt8]
        expected += Array("x-dimension".utf8)
        expected += [0x21, 0, 0, 0, 4, 0, 0, 0, 1] as [UInt8]          // integer 1
        expected += [0x37, 0, 0, 0, 0] as [UInt8]                      // end of media-size
        expected += [0x37, 0, 0, 0, 0] as [UInt8]                      // end of media-col
        expected += [0x03] as [UInt8]
        #expect(Array(body[at...]) == expected)
    }

    private static func index(of needle: [UInt8], in hay: [UInt8]) -> Int? {
        guard hay.count >= needle.count else { return nil }
        for i in 0...(hay.count - needle.count) where Array(hay[i..<i + needle.count]) == needle { return i }
        return nil
    }

    @Test func longNamesAreCutTo255Bytes() throws {
        let body = DirectJob.printJobRequest("ipp://x/", user: String(repeating: "é", count: 300), jobName: String(repeating: "a", count: 400), Self.plan())
        let op = try Self.group(body, 0)
        #expect(op.str("job-name")?.count == 255)
        #expect((op.str("requesting-user-name")?.utf8.count ?? 999) <= 255)
    }

    @Test func hostileCollectionsAreRefusedOrBounded() throws {
        // Nested past the limit.
        var deep: [UInt8] = [2, 0, 0, 0, 0, 0, 0, 1, 4]
        func attr(_ tag: UInt8, _ name: String, _ v: [UInt8]) {
            deep += [tag, UInt8(name.utf8.count >> 8), UInt8(name.utf8.count & 0xFF)] + Array(name.utf8) + [UInt8(v.count >> 8), UInt8(v.count & 0xFF)] + v
        }
        attr(0x34, "media-col-database", [])
        for _ in 0..<IppCodec.maxCollectionDepth {
            attr(0x4A, "", Array("m".utf8))
            attr(0x34, "", [])
        }
        deep.append(3)
        #expect(throws: IppFormatError.self) { try IppCodec.decode(deep) }
        // Never closed.
        #expect(throws: IppFormatError.self) { try IppCodec.decode([2, 0, 0, 0, 0, 0, 0, 1, 4, 0x34, 0, 1, UInt8(ascii: "a"), 0, 0, 3]) }
        // Closed twice.
        #expect(throws: IppFormatError.self) { try IppCodec.decode([2, 0, 0, 0, 0, 0, 0, 1, 4, 0x37, 0, 0, 0, 0, 3]) }
        // Truncated anywhere: an IppFormatError, never a crash.
        let good = DirectJob.printJobRequest("ipp://x/", user: "u", jobName: "j", Self.plan())
        for cut in 9..<good.count - 1 {
            do { _ = try IppCodec.decodeGroups(Array(good[0..<cut])) } catch is IppFormatError {}
        }
    }

    @Test func resolutionRangeAndDateValuesDecode() throws {
        let r = try IppCodec.decode(Self.printer { b in
            b.raw(0x32, "pwg-raster-document-resolution-supported", [0, 0, 1, 44, 0, 0, 1, 44, 3])
            b.raw(0x32, "", [0, 0, 0, 118, 0, 0, 0, 118, 4])
            b.raw(0x33, "copies-supported", [0, 0, 0, 1, 0, 0, 0, 99])
            b.raw(0x31, "printer-current-time", [0x07, 0xEA, 11, 18, 9, 30, 0, 0, UInt8(ascii: "-"), 4, 0])
        })
        #expect(r.resolutions("pwg-raster-document-resolution-supported").compactMap(\.dpi) == [300, 300])
        #expect(r.range("copies-supported") == IppRange(lower: 1, upper: 99))
        #expect(r.attributes["printer-current-time"]?.first == .date(Self.utc(2026, 11, 18, 13, 30))) // 09:30 at UTC-4
        #expect(IppText.parseResolution("300dpi").map { [$0.x, $0.y, Int32($0.units)] } == [300, 300, 3])
        #expect(IppText.parseResolution("600x300dpi").map { [$0.x, $0.y, Int32($0.units)] } == [600, 300, 3])
        #expect(IppText.parseResolution("300") == nil)
        #expect(IppText.parseRange("1-99").map { [$0.lower, $0.upper] } == [1, 99])
        #expect(IppText.parseRange("9-1") == nil)
    }

    // ---- what a printer takes ----

    private static func mediaCol(_ w: Int, _ h: Int, _ margin: Int, _ name: String? = nil, _ source: String? = nil) -> C {
        let c = C()
        c.coll("media-size") { s in s.int("x-dimension", w).int("y-dimension", h) }
        for side in ["bottom", "left", "right", "top"] { c.int("media-\(side)-margin", margin) }
        if let name { c.kw("media-size-name", name) }
        if let source { c.kw("media-source", source) }
        return c
    }

    @Test func capsComeFromMediaColDatabaseAndTheRasterAttributes() throws {
        let r = try IppCodec.decode(Self.printer { b in
            b.mime("document-format-supported", "application/octet-stream", "image/pwg-raster", "image/urf", "application/PCLm")
            b.kw("pwg-raster-document-type-supported", "black_1", "sgray_8", "srgb_8")
            b.res("pwg-raster-document-resolution-supported", 300, 600)
            b.kw("pwg-raster-document-sheet-back", "flipped")
            b.kw("urf-supported", "V1.4", "W8", "SRGB24", "RS300-600", "DM3")
            b.res("pclm-source-resolution-supported", 600)
            b.int("pclm-strip-height-preferred", 32)
            b.kw("pclm-compression-method-preferred", "jpeg", "rle", "flate")
            b.collections("media-col-database", Self.mediaCol(21590, 27940, 423, "na_letter_8.5x11in"), Self.mediaCol(21590, 27940, 0, "na_letter_8.5x11in"),
                          Self.mediaCol(21000, 29700, 423), Self.mediaCol(9_999_999, 100, 0), Self.mediaCol(10160, 15240, 0, "na_index-4x6_4x6in", "photo"))
            b.collections("media-col-default", Self.mediaCol(21590, 27940, 423, "na_letter_8.5x11in"))
            b.kw("sides-supported", "one-sided", "two-sided-long-edge")
            b.kw("print-color-mode-supported", "monochrome", "color")
            b.kw("print-color-mode-default", "color")
            b.range("copies-supported", 1, 99)
            b.enums("print-quality-supported", 3, 4, 5, 9)
            b.kw("media-type-supported", "stationery", "photographic-glossy", "BAD KEYWORD")
        })
        let caps = IppPrintCaps.from(r)
        #expect(caps.formats == [.pwgRaster, .urf, .pclm])
        #expect(caps.pwgColors == [.gray8, .rgb8])
        #expect(caps.pwgDpis == [300, 600])
        #expect(caps.pwgBack == .flipped)
        #expect(caps.urfDpis == [300, 600])
        #expect(caps.urfBack == .rotated)
        #expect(caps.pclmStripHeight == 32)
        #expect(caps.pclmRunLength) // run-length before flate
        #expect(caps.papers.count == 4) // the 100 km wide one left out
        #expect(caps.papers[2].name == "iso_a4_210x297mm") // named from its size when the printer gives no name
        #expect(caps.papers[3].source == "photo")
        #expect(caps.papers[1].borderless)
        #expect(caps.defaultPaper == caps.papers[0])
        #expect(caps.twoSided)
        #expect(caps.color && caps.colorByDefault)
        #expect(caps.maxCopies == 99)
        #expect(caps.qualities == [3, 4, 5])
        #expect(caps.mediaTypes == ["stationery", "photographic-glossy"])
    }

    @Test func withoutMediaColDatabaseThePapersComeFromMediaSupported() throws {
        let caps = IppPrintCaps.from(try IppCodec.decode(Self.printer { b in
            b.mime("document-format-supported", "image/urf")
            b.kw("urf-supported", "W8", "RS300")
            b.kw("media-supported", "na_letter_8.5x11in", "iso_a4_210x297mm", "custom_min_10x10mm", "na_index-4x6_4x6in", "nonsense")
            b.kw("media-default", "iso_a4_210x297mm")
            b.ints("media-left-margin-supported", 0, 300)
            b.ints("media-right-margin-supported", 0, 300)
            b.ints("media-top-margin-supported", 0, 300)
            b.ints("media-bottom-margin-supported", 0, 300, -5)
        }))
        #expect(caps.papers.count == 6) // three sizes, each with margins and borderless
        #expect(caps.defaultPaper == DirectPaper("iso_a4_210x297mm", 21000, 29700, 300, 300, 300, 300))
        #expect(IppPrintCaps.size("na_index-4x6_4x6in").map { [$0.w, $0.h] } == [10160, 15240])
        #expect(IppPrintCaps.size("custom_max_1000x1000in") == nil)
        #expect(IppPrintCaps.size(String(repeating: "a", count: 500) + "_1x1in") == nil)
        #expect(!caps.twoSided)
        #expect(!caps.color)
        #expect(caps.maxCopies == 1)
    }

    @Test func aFormatCountsOnlyWithWhatItNeedsAndHostileListsAreCut() throws {
        let many = (0..<1000).map { Self.mediaCol(10000 + $0 * 10, 15000, -9) }
        let caps = IppPrintCaps.from(try IppCodec.decode(Self.printer { b in
            b.mime("document-format-supported", "image/pwg-raster", "image/urf", "application/PCLm")
            b.kw("pwg-raster-document-type-supported", "black_1") // nothing 8-bit
            b.kw("urf-supported", "RS0-99999", "W8")              // no usable resolution
            b.res("pclm-source-resolution-supported", 0)
            b.int("pclm-strip-height-preferred", 0)
            b.collections("media-col-database", many)
            b.range("copies-supported", 1, Int(Int32.max))
        }))
        #expect(caps.formats.isEmpty)
        #expect(!caps.canPrint)
        #expect(caps.papers.count == IppPrintCaps.maxPapers)
        #expect(caps.papers.allSatisfy { $0.left == 0 }) // a negative margin reads as none
        #expect(caps.pclmStripHeight == 16)
        #expect(caps.maxCopies == 999)
    }

    // ---- the plan ----

    static func caps(_ change: ((inout IppPrintCaps) -> Void)? = nil) -> IppPrintCaps {
        let letter = DirectPaper("na_letter_8.5x11in", 21590, 27940, 423, 423, 423, 423)
        var c = IppPrintCaps()
        c.formats = [.pwgRaster, .urf, .pclm]
        (c.pwgColors, c.pwgDpis, c.pwgBack) = ([.gray8, .rgb8], [300, 600], .rotated)
        (c.urfColors, c.urfDpis, c.pclmDpis) = ([.gray8], [600], [600])
        c.papers = [letter, letter.withoutMargins, DirectPaper("iso_a4_210x297mm", 21000, 29700, 423, 423, 423, 423),
                    DirectPaper("na_index-4x6_4x6in", 10160, 15240, 0, 0, 0, 0)]
        c.defaultPaper = letter
        (c.twoSided, c.color, c.maxCopies, c.collatedCopies) = (true, true, 99, true)
        (c.qualities, c.mediaTypes) = ([4, 5], ["stationery", "photographic-glossy"])
        change?(&c)
        return c
    }

    private static func request(_ copies: Int = 1, twoSided: Bool = false, _ change: ((inout DirectPrintRequest) -> Void)? = nil) -> DirectPrintRequest {
        var r = DirectPrintRequest(copies: copies, twoSided: twoSided)
        change?(&r)
        return r
    }

    private static func plan(_ caps: IppPrintCaps, _ request: DirectPrintRequest) throws -> DirectPrintPlan {
        try DirectPrintPlan.choose(caps, request).get()
    }

    private static func problem(_ caps: IppPrintCaps, _ request: DirectPrintRequest) -> DirectPrintProblem? {
        if case .failure(let p) = DirectPrintPlan.choose(caps, request) { return p }
        return nil
    }

    @Test func pwgRasterAt300DpiFirstWithWhatWasAsked() throws {
        let plan = try Self.plan(Self.caps(), Self.request(3, twoSided: true) { ($0.color, $0.quality, $0.mediaType) = (true, 5, "photographic-glossy") })
        #expect(plan.format == .pwgRaster)
        #expect([plan.dpi, plan.renderDpi, plan.enlarge] == [300, 300, 1] as [Int])
        #expect(plan.color == .rgb8)
        #expect(plan.colorMode == "color")
        #expect([plan.copies, plan.repeatCount] == [3, 1] as [Int])
        #expect(plan.twoSided)
        #expect(plan.back == .rotated)
        #expect(plan.quality == 5)
        #expect(plan.paper.name == "na_letter_8.5x11in")
        #expect(!plan.paper.borderless)
        #expect(plan.documentFormat == "image/pwg-raster")
    }

    @Test func appleRasterAt600IsDrawnAt300AndEnlargedInGrey() throws {
        let plan = try Self.plan(Self.caps { $0.formats = [.urf, .pclm] }, Self.request { $0.color = true })
        #expect(plan.format == .urf)
        #expect([plan.dpi, plan.renderDpi, plan.enlarge] == [600, 300, 2] as [Int])
        #expect(plan.color == .gray8) // its urf-supported has W8 only
        #expect(plan.colorMode == "monochrome")
        #expect(DirectPrintPlan.chooseDpi([360, 720]) == 360)
        #expect(DirectPrintPlan.chooseDpi([360]) == 360)
        #expect(DirectPrintPlan.chooseDpi([100, 150]) == 150)
        #expect(DirectPrintPlan.chooseDpi([]) == nil)
        let odd = DirectPrintPlan(.urf, dpi: 360, color: .gray8, paper: Self.caps().papers[0])
        #expect([odd.renderDpi, odd.enlarge] == [360, 1] as [Int])
    }

    @Test func onlyTheFormatAskedFor() throws {
        let plan = try Self.plan(Self.caps(), Self.request { $0.format = .pclm })
        #expect(plan.format == .pclm)
        #expect(plan.documentFormat == "application/PCLm")
    }

    @Test func copiesThePrinterDoesntMakeAreSentAgainWithABlankBackBetween() throws {
        let plan = try Self.plan(Self.caps { $0.maxCopies = 1 }, Self.request(2, twoSided: true))
        #expect([plan.copies, plan.repeatCount] == [1, 2] as [Int])
        #expect(plan.pagesPerCopy(3) == 4)
        #expect(plan.job(plan.pagesPerCopy(3)).pages == 8)
        let once = try Self.plan(Self.caps(), Self.request(2, twoSided: true))
        #expect(once.pagesPerCopy(3) == 3) // the printer makes the copies: no blank
        #expect(plan.impressions(3) == 8) // "page N of M": each copy sent again, a blank back counted
        #expect(once.impressions(3) == 6) // and the copies the printer makes
    }

    @Test func paperByNameSizeDefaultOrBorderless() throws {
        let caps = Self.caps()
        #expect(try Self.plan(caps, Self.request { $0.paperName = "iso_a4_210x297mm" }).paper.name == "iso_a4_210x297mm")
        #expect(try Self.plan(caps, Self.request { $0.paperInches = (11.69, 8.27) }).paper.name == "iso_a4_210x297mm")
        #expect(try Self.plan(caps, Self.request { ($0.paperName, $0.borderless) = ("na_letter_8.5x11in", true) }).paper.borderless)
        #expect(try Self.plan(Self.caps { $0.defaultPaper = nil }, Self.request()).paper.name == "na_letter_8.5x11in")
        #expect(Self.problem(caps, Self.request { $0.paperName = "iso_a3_297x420mm" }) == .noPaper)
        #expect(DirectPrintProblem.noPaper.message == loc("The printer doesn't offer that paper. Choose another paper size."))
        #expect(Self.problem(caps, Self.request { ($0.paperName, $0.borderless) = ("iso_a4_210x297mm", true) }) != nil)
    }

    @Test func whatThePrinterCantDoIsSaidAndNothingIsPlanned() throws {
        #expect(Self.problem(Self.caps { $0.twoSided = false }, Self.request(twoSided: true)) == .notTwoSided)
        #expect(Self.problem(Self.caps { $0.formats = [] }, Self.request()) == .noFormat)
        #expect(Self.problem(Self.caps(), Self.request(0)) == .copies)
        // A quality or paper type the printer doesn't list is said, not dropped.
        #expect(Self.problem(Self.caps(), Self.request { $0.quality = 3 }) == .noQuality)
        #expect(Self.problem(Self.caps(), Self.request { $0.mediaType = "labels" }) == .noMediaType)
        let plan = try Self.plan(Self.caps(), Self.request { ($0.quality, $0.mediaType, $0.color) = (4, "stationery", false) })
        #expect(plan.quality == 4 && plan.mediaType == "stationery")
        #expect(plan.color == .gray8)
        #expect(!plan.grey)
    }

    @Test func greyOnAFormatThatTakesOnlyColorIsMadeGreyHere() throws {
        let rgbOnly = Self.caps { $0.pwgColors = [.rgb8] }
        let grey = try Self.plan(rgbOnly, Self.request { $0.color = false })
        #expect(grey.color == .rgb8)
        #expect(grey.grey)
        #expect(grey.colorMode == "monochrome")
        let color = try Self.plan(rgbOnly, Self.request { $0.color = true })
        #expect(!color.grey)
        #expect(color.colorMode == "color")
        // The pixels: RGB with the three equal.
        #expect(try RasterPage.fromBgra(width: 1, height: 1, stride: 4, [0, 0, 255, 255], color: .rgb8, grey: true).pixels == [77, 77, 77])
    }

    @Test func thePrinterMakesCopiesOnlyWhenItCollatesThem() throws {
        let collates = try Self.plan(Self.caps(), Self.request(3))
        #expect([collates.copies, collates.repeatCount] == [3, 1] as [Int])
        let body = try Self.group(DirectJob.printJobRequest("ipp://x/", user: "u", jobName: "j", collates), 1)
        #expect(body.str("multiple-document-handling") == "separate-documents-collated-copies")
        let doesnt = try Self.plan(Self.caps { $0.collatedCopies = false }, Self.request(3))
        #expect([doesnt.copies, doesnt.repeatCount] == [1, 3] as [Int]) // the pages go three times, collated by the order they're sent in
        let one = try Self.group(DirectJob.printJobRequest("ipp://x/", user: "u", jobName: "j", doesnt), 1)
        #expect(one.int("copies") == nil)
        #expect(one.str("multiple-document-handling") == nil)
        #expect(IppPrintCaps.from(try IppCodec.decode(Self.printer { $0.kw("multiple-document-handling-supported",
            "separate-documents-uncollated-copies", "separate-documents-collated-copies") })).collatedCopies)
        #expect(!IppPrintCaps.from(try IppCodec.decode(Self.printer { $0.kw("multiple-document-handling-supported",
            "separate-documents-uncollated-copies") })).collatedCopies)
    }

    private struct Timeout: Error {}

    @Test func thePrintersAttributesAreReadOnceAWhile() async throws {
        let state = Mutex<(reads: Int, now: ContinuousClock.Instant, fail: Bool)>((0, ContinuousClock.now, false))
        let cache = IppCapsCache({
            let (reads, fail) = state.withLock { s in
                s.reads += 1
                return (s.reads, s.fail)
            }
            if fail { throw Timeout() }
            var caps = IppPrintCaps()
            caps.maxCopies = reads
            return caps
        }, keep: .seconds(120), now: { state.withLock { $0.now } })
        #expect(try await cache.get().maxCopies == 1)
        #expect(try await cache.get().maxCopies == 1) // the paper check and the print share one read
        state.withLock { $0.now = $0.now + .seconds(180) }
        #expect(try await cache.get().maxCopies == 2)
        cache.forget()
        state.withLock { $0.fail = true }
        await #expect(throws: Timeout.self) { try await cache.get() }
        state.withLock { $0.fail = false }
        #expect(try await cache.get().maxCopies == 4) // a failed read isn't kept
        #expect(state.withLock { $0.reads } == 4)
    }

    @Test func aCancelSaysWhetherThePrinterTookIt() async {
        func stop(_ answer: @escaping @Sendable ([UInt8]) -> [UInt8]) async -> any Error {
            let ipp = IppClient(DeviceHttp(host: "192.0.2.11", transport: Answering(answer)), endpoint: URL(string: "http://192.0.2.11:631/ipp/print")!)
            do { try await DirectJob.stop(ipp, user: "ana", jobId: 5) } catch { return error }
        }
        #expect(await stop { _ in IppCodec.encodeResponse(status: 0, requestId: 1, []) } is CancellationError)
        for ended: UInt16 in [0x0404, 0x0406, 0x0407] { // not possible (it ended), not found, gone
            #expect(await stop { _ in IppCodec.encodeResponse(status: ended, requestId: 1, []) } is CancellationError)
        }
        for refused: UInt16 in [0x040C, 0x0401, 0x0500] {
            let e = await stop { _ in IppCodec.encodeResponse(status: refused, requestId: 1, []) }
            let error = e as? DirectPrintError
            #expect(error?.mayHavePrinted == true)
            #expect(error?.message == loc("The printer didn't take the cancel, so the job may still print. Cancel it on the printer's control panel."))
        }
        #expect(await stop { _ in [1, 2] } is DirectPrintError) // no answer to speak of
    }

    @Test func aPrintersClockOutOfRangeIsLeftOutNotThrown() throws {
        let now = Self.utc(2026, 11, 19, 12, 0)
        // Offset 14:59 (RFC 2579 allows 13 hours), and year 9999, which an offset can push past what a date holds.
        let values: [[UInt8]] = [
            [0x07, 0xEA, 11, 18, 9, 30, 0, 0, UInt8(ascii: "+"), 14, 59],
            [0x27, 0x0F, 12, 31, 23, 59, 59, 0, UInt8(ascii: "-"), 13, 59],
            [0x27, 0x0F, 12, 31, 23, 59, 59, 0, UInt8(ascii: "+"), 0, 0],
        ]
        for value in values {
            let answer = Self.response(0) { b in
                b.group(IppCodec.jobTag)
                b.int("job-id", 3)
                b.enums("job-state", 5)
                b.raw(0x31, "date-time-at-creation", value)
            }
            let job = try #require(try PrinterJobs.parse(answer, now: now).first)
            #expect(job.submitted == now) // the time it was read instead
            #expect(IppCodec.readDateTime(value) == nil)
        }
        #expect(IppCodec.readDateTime([0x07, 0xEA, 11, 18, 9, 30, 0, 0, UInt8(ascii: "+"), 13, 0]) != nil)
    }

    @Test(arguments: [
        (true, true, false, PrintRoute.queue), (true, true, true, .direct), (false, true, false, .direct), (true, false, true, .queue),
        (false, false, true, .none),
    ] as [(Bool, Bool, Bool, PrintRoute)])
    func theWindowsQueueStaysTheDefault(_ queue: Bool, _ raster: Bool, _ chose: Bool, _ route: PrintRoute) {
        #expect(PrintRoutes.choose(hasQueue: queue, printerTakesRaster: raster, personChoseDirect: chose) == route)
    }

    // ---- jobs ----

    @Test func jobStatesInPlainWords() throws {
        #expect(DirectJob.describe(DirectJobState(9, ["job-completed-successfully"], nil, 3), pages: 3) == loc("Printed"))
        #expect(DirectJob.describe(DirectJobState(5, [], nil, 1), pages: 3) == loc("Printing page {0} of {1}", 2, 3))
        #expect(DirectJob.describe(DirectJobState(4, ["job-held-for-authorization"], nil, nil), pages: 3)
                == loc("Waiting: {0}", loc("it holds the job until it's released at the printer")))
        #expect(DirectJob.describe(DirectJobState(8, ["document-format-error"], nil, nil), pages: 3)
                == loc("The printer stopped the job: {0}", loc("it couldn't read the pages")))
        let format = loc("The printer refused the pages: it didn't take their format or settings. Nothing was printed.")
        #expect(DirectJob.refused(0x040A) == format)
        #expect(DirectJob.refused(0x0401) == loc("The printer wants a signed-in user for printing. Set it up in macOS and print through it, or allow printing without signing in on its web page."))
        // RFC 8011 §13.1: busy is service-unavailable, temporary-error, not-accepting-jobs and busy; job-canceled is a cancel at
        // the printer; uri-scheme-not-supported is no format problem.
        for busy: UInt16 in [0x0502, 0x0505, 0x0506, 0x0507] { #expect(DirectJob.refused(busy) == loc("The printer is busy and took nothing. Try again in a minute.")) }
        #expect(DirectJob.refused(0x0508) == loc("Cancelled at the printer"))
        #expect(DirectJob.refused(0x040C) == loc("The printer refused the job. Nothing was printed."))
        #expect(DirectJob.refused(0x0408) == loc("The printer can't take a job this large. Print fewer pages at a time."))
        #expect(DirectJob.refused(0x041B) == format)
        #expect(DirectJob.refused(0x0400) == loc("The printer refused the job. Nothing was printed.")) // no codes in words the user reads
        let hostile = try IppCodec.decode(Self.job { $0.int("job-state", 99) }, group: IppCodec.jobTag)
        #expect(DirectJob.stateOf(hostile) == nil)
        let long = try #require(DirectJob.stateOf(try IppCodec.decode(Self.job { b in
            b.enums("job-state", 5)
            b.text("job-state-message", String(repeating: "x", count: 5000) + "\nmore")
            b.int("job-impressions-completed", -4)
        }, group: IppCodec.jobTag)))
        #expect((long.message?.count ?? 999) <= 201)
        #expect(long.pagesDone == nil)
    }

    @Test func getJobsListsThePrintersJobsForTheQueueCard() throws {
        let answer = Self.response(0) { b in
            b.group(IppCodec.jobTag)
            b.int("job-id", 12)
            b.text("job-name", "report.pdf")
            b.enums("job-state", 5)
            b.kw("job-state-reasons", "job-printing")
            b.text("job-originating-user-name", "ana")
            b.int("job-impressions", 4)
            b.int("job-impressions-completed", 1)
            b.raw(0x31, "date-time-at-creation", [0x07, 0xEA, 11, 18, 9, 30, 0, 0, UInt8(ascii: "+"), 0, 0])
            b.group(IppCodec.jobTag)
            b.int("job-id", 13)
            b.text("job-name", "photos")
            b.enums("job-state", 6)
            b.kw("job-state-reasons", "resources-are-not-ready")
            b.group(IppCodec.jobTag)
            b.int("job-id", -1)
            b.enums("job-state", 3)
        }
        let jobs = try PrinterJobs.parse(answer, now: Self.utc(2026, 11, 18, 10, 0))
        #expect(jobs.count == 2)
        let printing = try #require(jobs.first { $0.id == 12 })
        #expect(printing.name == "report.pdf" && printing.pages == 4 && printing.pagesPrinted == 1 && printing.owner == "ana")
        #expect(printing.state == .processing)
        #expect(printing.submitted == Self.utc(2026, 11, 18, 9, 30))
        #expect(jobs.first { $0.id == 13 }?.state == .stopped) // Mac: the job's own state; Windows' status bits add PaperOut
        #expect(throws: DirectPrintError.self) { try PrinterJobs.parse(Self.response(0x0401) { _ in }, now: Date()) }
        let request = PrinterJobs.getJobsRequest("ipp://x/", user: "ana")
        #expect(Array(request[0..<4]) == [2, 0, 0, 0x0A])
    }

    @Test func aJobGoesToThePrinterAndIsFollowedToItsEnd() async throws {
        let transport = FixtureTransport(document: { name in try? Fixtures.data("inkjet-demo/\(name)") })
        let http = DeviceHttp(host: "192.0.2.11", transport: transport)
        let ipp = IppClient(http, endpoint: IppClient.defaultEndpoint(http))
        let caps = IppPrintCaps.from(try await ipp.printerAttributes(IppPrintCaps.requested))
        #expect(caps.formats == [.pwgRaster, .urf])
        #expect(caps.twoSided && caps.color)
        #expect(caps.papers.contains { $0.name == "na_index-4x6_4x6in" && $0.borderless })
        #expect(caps.defaultPaper?.name == "na_letter_8.5x11in")
        #expect(caps.defaultPaper?.left == 300)

        let plan = try Self.plan(caps, Self.request(2) { $0.color = false })
        let writer = try RasterWriter.forJob(plan.job(1))
        try writer.write(try RasterPage.blank(width: writer.job.widthPixels, height: writer.job.heightPixels, color: plan.color))
        try writer.finish()
        let document = writer.drain()
        let (id, state) = try await DirectJob.send(ipp, user: "ana", jobName: "test", plan, document: document)
        #expect(id == 1)
        #expect(state?.state == DirectJobState.pending)
        let sent = try #require(transport.printJobs.first)
        #expect(transport.printJobs.count == 1)
        let end = try #require(try IppCodec.decodeGroups(sent).end) // the request's attributes end where the document begins
        #expect(Array(sent[end...]) == document)
        let seen = Mutex<[DirectJobState]>([])
        let last = await DirectJob.watch(ipp, user: "ana", jobId: id, every: .milliseconds(10), quiet: .seconds(5), progress: { s in seen.withLock { $0.append(s) } })
        #expect(last?.state == DirectJobState.completed)
        #expect(seen.withLock { $0.count } == 1)
        #expect(await DirectJob.cancel(ipp, user: "ana", jobId: id))
    }

    @Test func aPrinterThatRefusesTheJobHasSentNothing() async throws {
        let endpoint = URL(string: "http://192.0.2.11:631/ipp/print")!
        let refusing = IppClient(DeviceHttp(host: "192.0.2.11", transport: Answering { _ in IppCodec.encodeResponse(status: 0x040A, requestId: 1, []) }), endpoint: endpoint)
        do {
            _ = try await DirectJob.send(refusing, user: "ana", jobName: "test", Self.plan(), document: [1, 2, 3])
            Issue.record("sent")
        } catch let e as DirectPrintError {
            #expect(!e.mayHavePrinted)
            #expect(e.message == loc("The printer refused the pages: it didn't take their format or settings. Nothing was printed."))
        }
        let garbage = IppClient(DeviceHttp(host: "192.0.2.11", transport: Answering { _ in [1, 2, 3] }), endpoint: endpoint)
        do {
            _ = try await DirectJob.send(garbage, user: "ana", jobName: "test", Self.plan(), document: [1, 2, 3])
            Issue.record("sent")
        } catch let e as DirectPrintError {
            #expect(e.mayHavePrinted)
        }
    }

    /// A printer that answers as `Answering` but, as URLSession does, gives up on a request sent from a cancelled task; it keeps
    /// every operation it answered.
    private final class CancelAware: HttpTransport {
        let answer: @Sendable ([UInt8]) -> [UInt8]
        private let seen = Mutex<[UInt16]>([])

        init(_ answer: @escaping @Sendable ([UInt8]) -> [UInt8]) { self.answer = answer }

        var operations: [UInt16] { seen.withLock { $0 } }

        func send(_ request: HttpRequest) async throws -> HttpResponse {
            try Task.checkCancellation()
            let body = request.bodyBytes()
            let operation: UInt16 = try IppCodec.readRequestHeader(body).operation
            seen.withLock { $0.append(operation) }
            return HttpResponse(status: 200, headers: ["Content-Type": "application/ipp"], body: answer(body))
        }
    }

    private static func ipp(_ transport: any HttpTransport) -> IppClient {
        IppClient(DeviceHttp(host: "192.0.2.11", transport: transport), endpoint: URL(string: "http://192.0.2.11:631/ipp/print")!)
    }

    // The review of P12 2.1: a cancel reaches the printer, a job being sent goes to its end, the job's size is bounded, a
    // watch ends.

    @Test func aCancelReachesThePrinterFromTheCancelledTask() async {
        let printer = CancelAware { _ in IppCodec.encodeResponse(status: 0, requestId: 1, []) }
        let ipp = Self.ipp(printer)
        let stopping = Task { () async -> any Error in
            withUnsafeCurrentTask { task in task?.cancel() } // the person's Cancel, as the window's
            do { try await DirectJob.stop(ipp, user: "ana", jobId: 5) } catch { return error }
        }
        #expect(await stopping.value is CancellationError) // the printer took it, not "didn't take the cancel"
        #expect(printer.operations == [IppCodec.cancelJob])
    }

    @Test func aJobBeingSentIsntCutByACancel() async throws {
        let printer = CancelAware { body in
            IppCodec.encodeResponse(status: 0, requestId: 1, [
                IppValue(name: "job-id", tag: IppCodec.integer, value: "7"),
                IppValue(name: "job-state", tag: IppCodec.enumeration, value: "3"),
            ], group: IppCodec.jobTag)
        }
        let ipp = Self.ipp(printer)
        let plan = Self.plan()
        let sending = Task { () async throws -> (jobId: Int, state: DirectJobState?) in
            withUnsafeCurrentTask { task in task?.cancel() }
            return try await DirectJob.send(ipp, user: "ana", jobName: "test", plan, document: [1, 2, 3])
        }
        let (id, state) = try await sending.value
        #expect(id == 7) // the job went whole: Cancel-Job is what stops it now
        #expect(state?.state == DirectJobState.pending)
        #expect(printer.operations == [IppCodec.printJob])
    }

    @Test func aJobPastItsLimitIsRefusedBeforeAnythingIsSent() throws {
        #expect(DirectJobFile.maxBytes == 1 << 30)
        let url = DirectJobFile.temporaryUrl()
        defer { try? FileManager.default.removeItem(at: url) }
        let file = try DirectJobFile(url, request: [1, 2, 3, 4], limit: 10)
        try file.append([5, 6, 7, 8, 9, 10])
        do {
            try file.append([11])
            Issue.record("written past the limit")
        } catch let e as DirectPrintError {
            #expect(!e.mayHavePrinted)
            #expect(e.message == loc("The printer can't take a job this large. Print fewer pages at a time."))
        }
        let done = try file.finish()
        #expect(done.bytes == 10)
        #expect([UInt8](try Data(contentsOf: url)) == Array(1...10))
        #expect(throws: (any Error).self) { try DirectJobFile(url, request: [1]) } // never another job's file
    }

    @Test func aWatchEndsAfterItsLongestWhenThePrinterKeepsChanging() async {
        let asked = Mutex(0)
        let printer = CancelAware { _ in
            let n = asked.withLock { n -> Int in
                n += 1
                return n
            }
            return IppCodec.encodeResponse(status: 0, requestId: 1, [
                IppValue(name: "job-state", tag: IppCodec.enumeration, value: "5"),
                IppValue(name: "job-impressions-completed", tag: IppCodec.integer, value: String(n % 2)),
            ], group: IppCodec.jobTag)
        }
        let clock = ContinuousClock()
        let started = clock.now
        let last = await DirectJob.watch(Self.ipp(printer), user: "ana", jobId: 7, every: .milliseconds(5), quiet: .seconds(3600), longest: .milliseconds(300))
        let followed = clock.now - started // the quiet limit is an hour: only the longest ends it
        #expect(last?.state == DirectJobState.processing)
        #expect(DirectJob.followedTooLong(last, after: followed, longest: .milliseconds(300))
                == loc("Inkvolt Print stopped following the job after 2 hours. The printer's control panel shows how it's going."))
        #expect(DirectJob.followedTooLong(last, after: .seconds(60)) == nil) // ended sooner: quiet, or no answer
        #expect(DirectJob.followedTooLong(DirectJobState(9, [], nil, 3), after: .seconds(3 * 60 * 60)) == nil)
        #expect(DirectJob.watchLongest == .seconds(2 * 60 * 60))
    }

    private static func utc(_ y: Int, _ m: Int, _ d: Int, _ h: Int, _ mi: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: mi))!
    }

    /// A printer that answers every request with `answer(body)`.
    struct Answering: HttpTransport {
        let answer: @Sendable ([UInt8]) -> [UInt8]

        init(_ answer: @escaping @Sendable ([UInt8]) -> [UInt8]) { self.answer = answer }

        func send(_ request: HttpRequest) async throws -> HttpResponse {
            HttpResponse(status: 200, headers: ["Content-Type": "application/ipp"], body: answer(request.bodyBytes()))
        }
    }

    // ---- building replies ----

    static func printer(_ attrs: (B) -> Void) -> [UInt8] {
        response(0) { b in
            b.group(4)
            attrs(b)
        }
    }

    static func job(_ attrs: (B) -> Void) -> [UInt8] {
        response(0) { b in
            b.group(IppCodec.jobTag)
            attrs(b)
        }
    }

    static func response(_ status: UInt16, _ attrs: (B) -> Void) -> [UInt8] {
        let b = B()
        b.bytes = [2, 0, UInt8(status >> 8), UInt8(status & 0xFF), 0, 0, 0, 1, 1]
        attrs(b)
        b.bytes.append(3)
        return b.bytes
    }

    /// A collection to write: its members as (name, tag, value) or nested collections.
    final class C {
        var members: [(name: String, tag: UInt8, value: [UInt8], nested: C?)] = []

        @discardableResult func int(_ name: String, _ v: Int) -> C {
            members.append((name, 0x21, be(v), nil))
            return self
        }

        @discardableResult func kw(_ name: String, _ v: String) -> C {
            members.append((name, 0x44, Array(v.utf8), nil))
            return self
        }

        @discardableResult func coll(_ name: String, _ fill: (C) -> Void) -> C {
            let c = C()
            fill(c)
            members.append((name, 0x34, [], c))
            return self
        }
    }

    final class B {
        var bytes: [UInt8] = []

        func group(_ tag: UInt8) { bytes.append(tag) }

        func raw(_ tag: UInt8, _ name: String, _ v: [UInt8]) {
            let n = Array(name.utf8)
            bytes += [tag, UInt8(n.count >> 8), UInt8(n.count & 0xFF)] + n + [UInt8(v.count >> 8), UInt8(v.count & 0xFF)] + v
        }

        private func many(_ tag: UInt8, _ name: String, _ values: [[UInt8]]) {
            for (i, v) in values.enumerated() { raw(tag, i == 0 ? name : "", v) }
        }

        func kw(_ name: String, _ v: String...) { many(0x44, name, v.map { Array($0.utf8) }) }
        func mime(_ name: String, _ v: String...) { many(0x49, name, v.map { Array($0.utf8) }) }
        func text(_ name: String, _ v: String) { raw(0x41, name, Array(v.utf8)) }
        func int(_ name: String, _ v: Int) { raw(0x21, name, be(v)) }
        func ints(_ name: String, _ v: Int...) { many(0x21, name, v.map(be)) }
        func enums(_ name: String, _ v: Int...) { many(0x23, name, v.map(be)) }
        func range(_ name: String, _ lo: Int, _ hi: Int) { raw(0x33, name, be(lo) + be(hi)) }
        func res(_ name: String, _ dpi: Int...) { many(0x32, name, dpi.map { be($0) + be($0) + [3] }) }

        func collections(_ name: String, _ values: C...) { collections(name, values) }

        func collections(_ name: String, _ values: [C]) {
            for (i, v) in values.enumerated() {
                raw(0x34, i == 0 ? name : "", [])
                members(v)
                raw(0x37, "", [])
            }
        }

        private func members(_ c: C) {
            for m in c.members {
                raw(0x4A, "", Array(m.name.utf8))
                raw(m.tag, "", m.value)
                if let nested = m.nested {
                    members(nested)
                    raw(0x37, "", [])
                }
            }
        }
    }
}

private func be(_ v: Int) -> [UInt8] {
    let u = UInt32(bitPattern: Int32(truncatingIfNeeded: v))
    return [UInt8(u >> 24), UInt8(u >> 16 & 0xFF), UInt8(u >> 8 & 0xFF), UInt8(u & 0xFF)]
}
