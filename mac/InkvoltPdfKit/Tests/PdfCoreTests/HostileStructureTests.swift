import Foundation
import Testing
@testable import PdfCore

/// Ported from HostileStructureTests.cs, the page-edit tests (D3): DeletingAPageWalksSharedActionChainsOnce and
/// DeletingAPageSurvivesAnActionThatIsItsOwnNext, and the form one (D5): ChoiceFieldWhoseParentCyclesTakesNewItems. Files
/// built to make a walk over their objects run forever must finish in seconds (a hang fails the test instead of blocking
/// the run). The drawing ones come later. The accessibility check's first ones, after them, have no Windows twin; those
/// under "From Windows" do, with the same names. Adapted there: Swift has no count of bytes allocated, so a test that
/// measures it on Windows looks at what was read (`xfaBytes`) or at the note.
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

    // MARK: The accessibility check

    private static let shell = [
        "<< /Type /Catalog /Pages 2 0 R /StructTreeRoot 4 0 R >>",
        "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
        "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] >>",
        "<< /Type /StructTreeRoot /K 5 0 R >>",
    ]

    /// Windows' RedactingWalksASharedStructureTreeOnce and ExportReadsASharedStructureTreeOnce, for the check: /K arrays two
    /// of the next one each, 40 deep (2^40 paths), and tags that hold themselves.
    @Test func TheAccessibilityCheckWalksASharedStructureTreeOnce() throws {
        var objects = Self.shell + ["[5 0 R 6 0 R 6 0 R]"]
        for i in 0..<40 { objects.append(i == 39 ? "[<< /S /Figure /Pg 3 0 R /Alt (A cat) >>]" : "[\(7 + i) 0 R \(7 + i) 0 R]") }
        let sharedFile = Core2Pdf.build(objects)
        let shared = try within { try AccessibilityCheck.run(sharedFile, nil) }
        #expect(shared.tagged)

        // Elements whose /K leads back to themselves and to each other: each is one tag.
        var loop = Self.shell
        loop[3] = "<< /Type /StructTreeRoot /K [5 0 R 5 0 R] >>"
        for i in 0..<40 { loop.append("<< /S /Sect /P 4 0 R /K [\(5 + (i + 1) % 40) 0 R \(5 + (i + 1) % 40) 0 R 5 0 R] >>") }
        let loopFile = Core2Pdf.build(loop)
        let looped = try within { try AccessibilityCheck.run(loopFile, nil) }
        #expect(looped.tagged)
    }

    @Test func TheAccessibilityCheckSurvivesNestingToItsDepthLimit() throws {
        // Tags nested 400 deep (the limit is 256), one per level: no stack runs out on a thread with a small one.
        var objects = Self.shell
        for i in 0..<400 { objects.append(i == 399 ? "<< /S /Sect /P 4 0 R >>" : "<< /S /Sect /P 4 0 R /K \(6 + i) 0 R >>") }
        let file = Core2Pdf.build(objects)
        let report = try within { try AccessibilityCheck.run(file, nil) }
        #expect(report.tagged)
    }

    /// Twelve forms, each drawing the next one six times (6^11 draws of the last), as Windows' FormChain.
    private static func formChain(_ leaf: String) -> [UInt8] {
        var objects = [
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /XObject << /F 4 0 R >> >> /Contents 16 0 R >>",
        ]
        for i in 0..<12 {
            let body = i == 11 ? leaf : String(repeating: "/F Do\n", count: 6)
            let res = i == 11 ? "" : "/Resources << /XObject << /F \(5 + i) 0 R >> >>"
            objects.append(Core2Pdf.stream(body, "/Type /XObject /Subtype /Form /BBox [0 0 10 10] \(res)"))
        }
        objects.append(Core2Pdf.stream("/F Do"))
        return Core2Pdf.build(objects)
    }

    @Test func TheAccessibilityCheckStopsAFormDrawnManyTimes() throws {
        let file = Self.formChain("0 0 1 1 re f")
        let report = try within { try AccessibilityCheck.run(file, nil) }
        #expect(report.failedConditions.contains("01-005"))
        #expect(report.notes.contains { $0.contains("very long") })
    }

    @Test func TheAccessibilityCheckReadsAFormDrawnManyTimesOnce() throws {
        // A form of a 1 MB comment and one square, drawn 100,000 times (Windows' ShapeDetection… file).
        let pdf = Core2Pdf.build([
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /XObject << /F 5 0 R >> >> /Contents 4 0 R >>",
            Core2Pdf.stream("0 0 0 RG 72 72 100 100 re S\n" + String(repeating: "/F Do\n", count: 100_000)),
            Core2Pdf.stream("% " + String(repeating: "x", count: 1 << 20) + "\n0 0 1 1 re f", "/Type /XObject /Subtype /Form /BBox [0 0 10 10]"),
        ])
        let report = try within { try AccessibilityCheck.run(pdf, nil) }
        #expect(report.failures.first { $0.condition == "01-005" }?.count == 100_001)
    }

    @Test func TheAccessibilityCheckSurvivesAFormThatDrawsItself() throws {
        let pdf = Core2Pdf.build([
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /XObject << /F 5 0 R >> >> /Contents 4 0 R >>",
            Core2Pdf.stream("/F Do"),
            Core2Pdf.stream("/F Do /F Do 0 0 1 1 re f", "/Type /XObject /Subtype /Form /BBox [0 0 10 10] /Resources << /XObject << /F 5 0 R >> >>"),
        ])
        let report = try within { try AccessibilityCheck.run(pdf, nil) }
        #expect(report.failures.first { $0.condition == "01-005" }?.count == 1)
    }

    @Test func TheAccessibilityCheckWalksSharedRenditionsOnce() throws {
        // A rendition selector listing itself a hundred times (100^8 walks at its depth limit), then one clip without a type.
        let list = String(repeating: "6 0 R ", count: 100)
        let pdf = Core2Pdf.build([
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Annots [4 0 R] >>",
            "<< /Type /Annot /Subtype /Screen /Rect [0 0 10 10] /A 5 0 R >>",
            "<< /S /Rendition /R 6 0 R >>",
            "<< /S /SR /R [\(list) 7 0 R] >>",
            "<< /S /MR /C << /S /MCD /Alt [(en) (A video)] >> >>",
        ])
        let report = try within { try AccessibilityCheck.run(pdf, nil) }
        #expect(report.failures.filter { $0.condition == "28-014" }.count == 1)
    }

    @Test func TheAccessibilityCheckRefusesToLayOutATableOfHugeSpans() throws {
        // 500 rows of 1,000 cells spanning 1,000 by 1,000: gigabytes of places if each were filled.
        var objects = Self.shell
        let span = "<< /O /Table /RowSpan 1000 /ColSpan 1000 >>"
        let cells = String(repeating: "<< /S /TD /P 6 0 R /A \(span) >> ", count: 1000)
        let rows = (0..<500).map { "\(6 + $0) 0 R" }.joined(separator: " ")
        objects.append("<< /S /Table /P 4 0 R /K [\(rows)] >>")
        for _ in 0..<500 { objects.append("<< /S /TR /P 5 0 R /K [\(cells)] >>") }
        let file = Core2Pdf.build(objects)
        let report = try within(60) { try AccessibilityCheck.run(file, nil) }
        #expect(report.notes.contains { $0.contains("too many to lay out") })
    }

    @Test func AnOverlongContentStreamIsCutOffNotReadInFull() throws {
        // Four million operators on a page: the first two million are checked, and the rest aren't kept in memory.
        let pdf = Core2Pdf.build([
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R >>",
            Core2Pdf.stream(String(repeating: "q Q\n", count: 2_000_000)),
        ])
        let report = try within(60) { try AccessibilityCheck.run(pdf, nil) }
        #expect(report.notes.contains { $0.contains("very long") })
    }

    @Test func DynamicXfaScanIsLinearOnAFormOfOpeningTags() throws {
        let junk = [UInt8](String(repeating: "<dynamicRender", count: 200_000).utf8)
        #expect(try !within { AccessibilityChecker.requiresDynamicRender(junk) })
        #expect(AccessibilityChecker.requiresDynamicRender(Array("<DYNAMICRENDER a='b'> required </dynamicRender >".utf8)))
    }

    @Test func DynamicXfaScanIsLinearOnOpeningTagsSharingARunOfSpaces() throws {
        // 200,000 openings look past the same '>' at the same two million spaces, unless they share the answer.
        let junk = [UInt8]((String(repeating: "<dynamicRender", count: 200_000) + ">" + String(repeating: " ", count: 2_000_000) + "x").utf8)
        #expect(try !within { AccessibilityChecker.requiresDynamicRender(junk) })
    }

    // MARK: From Windows

    @Test func AccessibilityCheckWalksARenditionSelectorListingItselfOnce() throws {
        // 100 entries to itself, 8 levels deep: 100^8 walks unless each selector is walked once.
        var doc = A11yDoc()
        doc.annots = "11 0 R"
        doc.more = [
            "<< /Type /Annot /Subtype /Screen /Rect [100 100 200 200] /Contents (A video) /A << /S /Rendition /R 12 0 R >> >>",
            "<< /S /SR /R [\(String(repeating: "12 0 R ", count: 100)) 13 0 R] >>",
            "<< /S /MR /C << /S /MCD /Alt [(en) (A video)] >> >>",
        ]
        let file = doc.build()
        let report = try within { try AccessibilityCheck.run(file, nil) }
        #expect(report.failedConditions.contains("28-014")) // the clip behind the selector is still found
    }

    @Test func AccessibilityCheckWalksSelectorsSharedByEveryAnnotationOnce() throws {
        // 20,000 annotations share a selector with 200,000 entries: 4 billion steps if each annotation walks it.
        var doc = A11yDoc()
        doc.annots = String(repeating: "11 0 R ", count: 20_000)
        doc.more = [
            "<< /Type /Annot /Subtype /Screen /Rect [100 100 200 200] /Contents (A video) /A << /S /Rendition /R 12 0 R >> >>",
            "<< /S /SR /R [\(String(repeating: "13 0 R ", count: 200_000))] >>",
            "<< /S /MR /C << /S /MCD /CT (video/mp4) /Alt [(en) (A video)] >> >>",
        ]
        let file = doc.build()
        _ = try within { try AccessibilityCheck.run(file, nil) }
    }

    @Test func AccessibilityCheckWalksAdditionalActionsSharedByManyAnnotationsOnce() throws {
        // A Mac addition: 5,000 annotations share /AA of 200,000 entries, a billion looked at.
        var doc = A11yDoc()
        doc.annots = String(repeating: "11 0 R ", count: 5000)
        let triggers = (0..<200_000).map { "/T\($0) 13 0 R " }.joined()
        doc.more = [
            "<< /Type /Annot /Subtype /Screen /Rect [100 100 200 200] /Contents (A video) /AA 12 0 R >>",
            "<< \(triggers) >>",
            "<< /S /URI /URI (https://example.com) >>",
        ]
        let file = doc.build()
        _ = try within { try AccessibilityCheck.run(file, nil) }
    }

    /// A table of `rows` rows, built by each row's cells.
    private static func tableOf(_ rows: Int, _ cells: (Int) -> String) -> [UInt8] {
        var doc = A11yDoc()
        doc.docKids = "10 0 R"
        doc.parentTree = ""
        doc.content = "BT ET"
        let body = (0..<rows).map { "<< /Type /StructElem /S /TR /K [\(cells($0))] >> " }.joined()
        doc.elems = ["<< /Type /StructElem /S /Table /P 6 0 R /K [\(body)] >>"]
        return doc.build()
    }

    private static func cell(_ rowSpan: Int, _ colSpan: Int) -> String {
        "<< /Type /StructElem /S /TD /A << /O /Table /RowSpan \(rowSpan) /ColSpan \(colSpan) >> >> "
    }

    @Test func AccessibilityCheckWontTakeGigabytesForATablesSpans() throws {
        // One cell in each row, each 1000 by 1000, each starting right of the one above: the grid's rows grow to 600,000 places.
        let file = Self.tableOf(600) { _ in Self.cell(1000, 1000) }
        let report = try within(120) { try AccessibilityCheck.run(file, nil) }
        #expect(report.notes.contains { $0.lowercased().contains("table") })
    }

    @Test func AccessibilityCheckCountsTheEmptyPlacesASpanLeavesToo() throws {
        // The first row's last cell starts 999,000 places in and goes down 100 rows, whose places left of it hold nothing.
        let first = String(repeating: Self.cell(1, 1000), count: 999) + Self.cell(100, 1000)
        let file = Self.tableOf(100) { $0 == 0 ? first : "" }
        let report = try within(120) { try AccessibilityCheck.run(file, nil) }
        #expect(report.notes.contains { $0.lowercased().contains("table") })
    }

    @Test func AccessibilityCheckStillComparesAnOrdinaryLargeTable() throws {
        let file = Self.tableOf(2000) { String(repeating: Self.cell(1, $0 == 0 ? 2 : 1), count: $0 == 0 ? 10 : 20) }
        let report = try AccessibilityCheck.run(file, nil)
        #expect(report.notes.isEmpty)
        #expect(!report.failedConditions.contains("09-004"))
    }

    private static func xfaOf(_ array: String, _ more: [String]) -> A11yDoc {
        var doc = A11yDoc()
        doc.catalog += " /AcroForm << /Fields [] /XFA \(array) >>"
        doc.more = more
        return doc
    }

    @Test func AccessibilityCheckSaysSoWhenItCantFinishLookingAtAnXfaForm() throws {
        // No '>' anywhere. The Mac's scan is one pass with no time limit to run out of, so it finishes, with no note to give.
        let file = Self.xfaOf("11 0 R", [A11yDoc.stream(String(repeating: "<dynamicRender ", count: 1_000_000))]).build()
        let report = try within(60) { try AccessibilityCheck.run(file, nil) }
        #expect(!report.failedConditions.contains("25-001"))
    }

    @Test func AccessibilityCheckReadsAnXfaStreamListedManyTimesOnce() throws {
        // 500 entries to one stream of a megabyte: 500 MB of bytes if each entry is read.
        let list = String(repeating: "(part) 11 0 R ", count: 500)
        let file = Self.xfaOf("[\(list)]", [A11yDoc.stream(String(repeating: "x", count: 1 << 20))]).build()
        let doc = try Core2Pdf.open(file)
        let xfa = try #require(doc.catalog.dict("AcroForm")?["XFA"])
        #expect(AccessibilityChecker.xfaBytes(xfa).count == 1 << 20)
    }

    @Test func AccessibilityCheckStillFindsADynamicXfaForm() throws {
        let report = try Self.xfaOf("[(a) 11 0 R (b) 11 0 R]", [A11yDoc.stream("<config><dynamicRender>required</dynamicRender></config>")]).check()
        #expect(report.failedConditions.contains("25-001"))
        #expect(report.notes.isEmpty)
    }

    @Test func AccessibilityCheckWalksAnAppearanceSharedByManyAnnotationsOnce() throws {
        // 20,000 annotations with one appearance of a megabyte of nothing: 20 GB read, in a page of very few drawing steps.
        var doc = A11yDoc()
        doc.annots = String(repeating: "11 0 R ", count: 20_000)
        doc.more = [
            "<< /Type /Annot /Subtype /Stamp /Rect [100 100 200 200] /Contents (A stamp) /AP << /N 12 0 R >> >>",
            A11yDoc.stream(String(repeating: " ", count: 1 << 20), "/Type /XObject /Subtype /Form /BBox [0 0 100 100]"),
        ]
        let file = doc.build()
        _ = try within { try AccessibilityCheck.run(file, nil) }
    }

    @Test func AccessibilityCheckCountsWhatAFormDrawnManyTimesTakesToRead() throws {
        // 200,000 draws of a form of a megabyte of nothing: the Mac keeps what it parsed, so it reads it once (no note);
        // AccessibilityCheckCountsAFormItCantKeepEachTimeItIsRead has it read every time.
        var doc = A11yDoc()
        doc.resources = "/XObject << /X 11 0 R >>"
        doc.content = "/Artifact BMC " + String(repeating: "/X Do ", count: 200_000) + "EMC"
        doc.more = [A11yDoc.stream(String(repeating: " ", count: 1 << 20), "/Type /XObject /Subtype /Form /BBox [0 0 100 100]")]
        let file = doc.build()
        _ = try within { try AccessibilityCheck.run(file, nil) }
    }

    @Test func AccessibilityCheckCountsAFormItCantKeepEachTimeItIsRead() throws {
        // A Mac addition: two forms fill what is kept parsed, so a third of a megabyte of nothing and one step is read at each of 200,000 draws.
        let form = "/Type /XObject /Subtype /Form /BBox [0 0 100 100]"
        let file = Core2Pdf.build([
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R 4 0 R] /Count 2 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 5 0 R /Resources 9 0 R >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 6 0 R /Resources 9 0 R >>",
            Core2Pdf.stream("/A Do"),
            Core2Pdf.stream("/B Do " + String(repeating: "/C Do ", count: 200_000)),
            Core2Pdf.stream(String(repeating: "q Q ", count: 950_000), form),
            Core2Pdf.stream(String(repeating: "q Q ", count: 300_000), form),
            "<< /XObject << /A 7 0 R /B 8 0 R /C 10 0 R >> >>",
            Core2Pdf.stream("q Q" + String(repeating: " ", count: 1 << 20), form),
        ])
        let report = try within(60) { try AccessibilityCheck.run(file, nil) }
        #expect(report.notes.contains { $0.contains("very long") })
    }

    /// Pages sharing one content stream: object 3 is the content, then the pages.
    private static func sharedPages(_ pages: Int, _ content: String) -> [UInt8] {
        let kids = (0..<pages).map { "\(4 + $0) 0 R " }.joined()
        var objects = ["<< /Type /Catalog /Pages 2 0 R >>", "<< /Type /Pages /Kids [\(kids)] /Count \(pages) >>", Core2Pdf.stream(content)]
        for _ in 0..<pages { objects.append("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 3 0 R /Resources << >> >>") }
        return Core2Pdf.build(objects)
    }

    @Test func AccessibilityCheckStopsOnAFileWhosePagesAllDrawTheSameLongContent() throws {
        // 5,000 pages sharing a content stream at the limit of drawing steps for a page: 10 billion steps. (The document's
        // limit lowered here: the real one takes minutes to reach.)
        let file = Self.sharedPages(5000, String(repeating: "q Q ", count: 1_000_000))
        let report = try within(60) { try AccessibilityCheck.run(file, nil, maxDocumentOperators: 5_000_000) }
        #expect(report.notes.contains { $0.contains("very long") })
    }

    @Test func AccessibilityCheckCountsWhatAPageTakesToRead() throws {
        // A Mac addition: pages of a megabyte of nothing have no drawing steps to count.
        let file = Self.sharedPages(5000, String(repeating: " ", count: 1 << 20))
        let report = try within(60) { try AccessibilityCheck.run(file, nil, maxDocumentOperators: 5_000_000) }
        #expect(report.notes.contains { $0.contains("very long") })
    }

    @Test func AccessibilityCheckStopsOnAFileWhosePagesAllListTheSameAnnotations() throws {
        // 20,000 pages share an array of 20,000 annotations: 400 million looked at.
        let pages = 20_000
        var objects = [
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [\((0..<pages).map { "\(5 + $0) 0 R " }.joined())] /Count \(pages) >>",
            "[\(String(repeating: "4 0 R ", count: 20_000))]",
            "<< /Type /Annot /Subtype /Link /Rect [100 100 200 200] /Contents (A link) >>",
        ]
        for _ in 0..<pages { objects.append("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Annots 3 0 R >>") }
        let file = Core2Pdf.build(objects)
        let report = try within(60) { try AccessibilityCheck.run(file, nil, maxDocumentOperators: 5_000_000) }
        #expect(report.notes.contains { $0.contains("very long") })
    }

    @Test func ExportReadsASharedStructureTreeOnce() throws {
        // An array in itself (5: [5 0 R 6 0 R 6 0 R]), then arrays two of the next one each, 40 deep, down to a figure.
        var objects = Self.shell + ["[5 0 R 6 0 R 6 0 R]"]
        for i in 0..<40 { objects.append(i == 39 ? "[<< /S /Figure /Pg 3 0 R /Alt (A cat) >>]" : "[\(7 + i) 0 R \(7 + i) 0 R]") }
        let file = Core2Pdf.build(objects)
        let alts = try within { try AutoTag.figureAlts(Core2Pdf.open(file)).map(\.alt) }
        #expect(alts == ["A cat"])
    }

    @Test func ExportTagsDoesntLookForEachTagsPageThroughEveryPage() throws {
        // 100,000 tags on the last of 20,000 pages: 2 billion looks.
        let pages = 20_000
        let tags = String(repeating: "<< /S /P /Pg \(3 + pages) 0 R >> ", count: 100_000)
        var objects = [
            "<< /Type /Catalog /Pages 2 0 R /StructTreeRoot 3 0 R >>",
            "<< /Type /Pages /Kids [\((0..<pages).map { "\(4 + $0) 0 R " }.joined())] /Count \(pages) >>",
            "<< /Type /StructTreeRoot /K [\(tags)] >>",
        ]
        for _ in 0..<pages { objects.append("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] >>") }
        let file = Core2Pdf.build(objects)
        _ = try within { try AutoTag.figureAlts(Core2Pdf.open(file)).count }
    }
}
