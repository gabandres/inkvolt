import Foundation
import Testing
@testable import PdfCore

/// CommentFilesTests.cs: comments in and out (roadmap 1.4): XFDF, FDF and CSV round trips, merging, and hostile files.
/// Windows checks the exported XFDF with an XSD of the XFDF 3.0 rules; Foundation has no XSD validator, so the same rules
/// are checked attribute by attribute here (`xfdfRuleErrors`).
struct CommentFilesTests {
    /// Two pages with one comment of each kind Inkvolt makes, replies two deep, Unicode and line breaks.
    static func commented() throws -> [UInt8] {
        var pdf = TestPdf.make(2)
        pdf = try Annotations.addNote(pdf, nil, 0, 300, 80, "Check this,\nline two with \"quotes\"", author: "Ana Lucía", color: AnnotColor(0.2, 0.6, 0.9), id: "note-1")
        pdf = try Annotations.addReply(pdf, nil, "note-1", "Agreed ✓ — señal", author: "Bo", id: "reply-1")
        pdf = try Annotations.addReply(pdf, nil, "reply-1", "Nested reply", author: "Ana Lucía", id: "reply-2")
        pdf = try Annotations.addTextMarkup(pdf, nil, 0, .highlight, [RectD(72, 80, 200, 24), RectD(72, 110, 150, 24)], .yellow,
                                            note: "hl note", author: "Bo", id: "hl-1")
        pdf = try Annotations.addTextMarkup(pdf, nil, 1, .strikeOut, [RectD(72, 120, 180, 24)], .red, note: "", author: "Bo", id: "so-1")
        let strokes = [[PointD(100, 300), PointD(120, 320), PointD(150, 310)], [PointD(200, 300), PointD(210, 340)]]
        pdf = try Annotations.addInk(pdf, nil, 0, strokes, .pen(AnnotColor(0, 0.5, 0), width: 3), author: "Ana Lucía", id: "ink-1")
        var square = AnnotStyle(color: .red, fill: AnnotColor(1, 1, 0.8), width: 2)
        square.dash = [4, 2]
        pdf = try Annotations.addShape(pdf, nil, 0, .rectangle, RectD(300, 300, 120, 80), square, author: "Ana Lucía", id: "sq-1")
        var circle = AnnotStyle.pen(AnnotColor(0.5, 0, 0.5))
        circle.opacity = 0.5
        pdf = try Annotations.addShape(pdf, nil, 0, .ellipse, RectD(300, 420, 100, 60), circle, author: "Bo", id: "ci-1")
        pdf = try Annotations.addLine(pdf, nil, 1, PointD(100, 400), PointD(300, 500), .arrow(AnnotColor(0, 0, 1)), author: "Bo", id: "ln-1")
        pdf = try Annotations.addPolygon(pdf, nil, 1, [PointD(350, 400), PointD(450, 420), PointD(400, 500)], closed: true, .pen(.red),
                                         author: "Bo", id: "pg-1")
        var open = AnnotStyle.pen(.red)
        open.endEnding = .closedArrow
        pdf = try Annotations.addPolygon(pdf, nil, 1, [PointD(350, 600), PointD(450, 620), PointD(500, 580)], closed: false, open,
                                         author: "Bo", id: "pl-1")
        pdf = try Annotations.addFreeText(pdf, nil, 1, RectD(100, 600, 200, 60), "Callout, text",
                                          .textBox(fontSize: 11, border: .red, fill: AnnotColor(1, 1, 0.9)), author: "Ana Lucía",
                                          callout: [PointD(80, 560)], id: "ft-1")
        pdf = try RubberStamps.put(pdf, nil, 1, RectD(350, 100, 160, 50), RubberStamps.builtIn[0], author: "Ana Lucía")
        return pdf
    }

    static func byId(_ pdf: [UInt8]) throws -> [String: AnnotationInfo] {
        Dictionary(try Annotations.read(pdf, nil).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    }

    /// Every comment of `expected` is in `actual` with the same type, text, author, color (to XFDF's 1/255), replies and
    /// geometry; with `style` the drawing style too.
    static func assertSameComments(_ expected: [UInt8], _ actual: [UInt8], style: Bool = true) throws {
        let a = try byId(expected), b = try byId(actual)
        #expect(a.count == b.count)
        func near(_ p: RectD, _ q: RectD, _ id: String) {
            #expect(abs(p.x - q.x) < 0.05 && abs(p.y - q.y) < 0.05 && abs(p.width - q.width) < 0.05 && abs(p.height - q.height) < 0.05,
                    "\(id): \(p) vs \(q)")
        }
        func color(_ p: AnnotColor?, _ q: AnnotColor?, _ id: String) {
            #expect((p == nil) == (q == nil), "\(id) color")
            if let c = p, let d = q { #expect(abs(c.r - d.r) < 0.003 && abs(c.g - d.g) < 0.003 && abs(c.b - d.b) < 0.003, "\(id): \(c) vs \(d)") }
        }
        for (id, x) in a {
            guard let y = b[id] else {
                Issue.record("\(id) missing")
                continue
            }
            #expect(x.subtype == y.subtype, "\(id)")
            #expect(x.pageIndex == y.pageIndex, "\(id)")
            #expect(x.contents.replacingOccurrences(of: "\r\n", with: "\n") == y.contents.replacingOccurrences(of: "\r\n", with: "\n"), "\(id)")
            #expect(x.author == y.author, "\(id)")
            #expect(x.replyTo == y.replyTo, "\(id)")
            #expect(x.hidden == y.hidden, "\(id)")
            if let m = x.modified {
                let n = try #require(y.modified, "\(id) date")
                #expect(abs(m.timeIntervalSince(n)) < 1.01, "\(id) date")
            }
            color(x.color, y.color, id)
            near(x.rect, y.rect, id)
            #expect(x.quadRects.count == y.quadRects.count, "\(id)")
            for i in 0..<min(x.quadRects.count, y.quadRects.count) { near(x.quadRects[i], y.quadRects[i], id) }
            #expect((x.geometry == nil) == (y.geometry == nil), "\(id) geometry")
            if let g = x.geometry, let h = y.geometry {
                near(g.box, h.box, id)
                #expect(g.paths.count == h.paths.count, "\(id)")
                for (p, q) in zip(g.paths, h.paths) {
                    #expect(p.count == q.count, "\(id)")
                    for (u, v) in zip(p, q) { #expect(abs(u.x - v.x) < 0.01 && abs(u.y - v.y) < 0.01, "\(id): \(u) vs \(v)") }
                }
                #expect(g.callout.count == h.callout.count, "\(id)")
            }
            if style, let s = x.style {
                let t = try #require(y.style, "\(id) style")
                #expect(abs(s.width - t.width) < 0.01, "\(id) width")
                #expect(abs(s.opacity - t.opacity) < 0.01, "\(id) opacity")
                #expect((s.dash ?? []) == (t.dash ?? []), "\(id) dash")
                #expect(s.startEnding == t.startEnding, "\(id)")
                #expect(s.endEnding == t.endEnding, "\(id)")
                #expect(abs(s.fontSize - t.fontSize) < 0.01, "\(id)")
                #expect(s.align == t.align, "\(id)")
                color(s.fill, t.fill, id + " fill")
                color(s.textColor, t.textColor, id + " text color")
            }
        }
    }

    @Test(arguments: [CommentFileFormat.xfdf, .fdf])
    func roundTripsIntoACleanCopy(_ format: CommentFileFormat) throws {
        let source = try Self.commented()
        let export = try CommentFiles.export(source, nil, format, pdfFileName: "source.pdf")
        #expect(export.count == 13)
        let result = try CommentFiles.importComments(TestPdf.make(2), nil, export.data)
        #expect(result.added == 13)
        #expect(result.skipped.isEmpty)
        #expect(result.notes.isEmpty)
        try Self.assertSameComments(source, result.data)

        // Every imported comment has an appearance; the stamp keeps the picture it had.
        let doc = try Core2Pdf.open(result.data)
        for p in 0..<2 {
            for a in doc.page(p).array("Annots")?.elements ?? [] { #expect(a.dict("AP")?.dict("N") != nil, "\(a.name("Subtype") ?? "")") }
        }
        #expect(try Core2Pdf.allText(result.data, page: 1).contains("APPROVED"))
        #expect(try Core2Pdf.allText(result.data, page: 1).contains("Callout, text"))
    }

    @Test func csvRoundTripKeepsTextAuthorsColorsRepliesAndPlaces() throws {
        let source = try Self.commented()
        let export = try CommentFiles.export(source, nil, .csv)
        let rows = try Csv.read(Csv.decode(export.data))
        #expect(rows.count == 14)
        #expect(rows[0] == CommentFiles.csvColumns)
        let result = try CommentFiles.importComments(TestPdf.make(2), nil, export.data)
        #expect(result.added == 13)
        try Self.assertSameComments(source, result.data, style: false)
    }

    @Test func importMergesAndSkipsWhatIsAlreadyThere() throws {
        let source = try Self.commented()
        let xfdf = try CommentFiles.export(source, nil, .xfdf).data

        // Into the document it came from: nothing is added, each comment is reported.
        let again = try CommentFiles.importComments(source, nil, xfdf)
        #expect(again.added == 0)
        #expect(again.data == source)
        #expect(again.skipped.count == 13)
        #expect(again.skipped.allSatisfy { $0.hasSuffix("already in the document") })
        #expect(again.skipped.contains { $0.hasPrefix("Page 1, note by Ana Lucía") })

        // A copy with some of them: only the missing ones come in, replies attach to the comment already there.
        var partial = try Annotations.delete(source, nil, "reply-1") // takes reply-2 with it
        partial = try Annotations.delete(partial, nil, "ink-1")
        let merged = try CommentFiles.importComments(partial, nil, xfdf)
        #expect(merged.added == 3)
        #expect(merged.skipped.count == 10)
        try Self.assertSameComments(source, merged.data)

        // Comments without ids (another app's) are matched by what they are.
        let bare = try Self.withoutIds(source)
        let fdf = try CommentFiles.export(bare, nil, .fdf).data
        let twice = try CommentFiles.importComments(bare, nil, fdf)
        #expect(twice.added == 0)
    }

    static func withoutIds(_ pdf: [UInt8]) throws -> [UInt8] {
        try PageEditor.edit(pdf, nil) { doc in
            for p in 0..<(try doc.pageCount()) {
                for a in doc.page(p).array("Annots")?.elements ?? [] where a.isDict { a.remove("NM") }
            }
        }
    }

    @Test func reportsCommentsItCantPlace() throws {
        let xfdf = """
            <?xml version="1.0" encoding="UTF-8"?>
            <xfdf xmlns="http://ns.adobe.com/xfdf/" xml:space="preserve"><annots>
            <text page="7" rect="10,10,30,30" name="far" title="Kim"><contents>On page 8</contents></text>
            <link page="0" rect="10,10,30,30" name="lnk"/>
            <fileattachment page="0" rect="10,10,30,30" name="att"/>
            <square page="0" name="norect"/>
            <text page="0" rect="10,700,30,720" name="orphan" inreplyto="nobody" replyType="reply"><contents>Reply to a missing note</contents></text>
            </annots></xfdf>
            """
        let r = try CommentFiles.importComments(TestPdf.make(1), nil, Array(xfdf.utf8))
        #expect(r.added == 1)
        #expect(r.skipped.contains { $0.contains("no page 8") })
        #expect(r.skipped.contains { $0.contains("<link>") })
        #expect(r.skipped.contains { $0.contains("<fileattachment>") })
        #expect(r.skipped.contains { $0.contains("no position") })
        #expect(r.notes.count == 1)
        let read = try Annotations.read(r.data, nil)
        #expect(read.count == 1 && read[0].replyTo == nil)
    }

    // ---------------- XFDF conformance ----------------

    /// The rules of XFDF 3.0 (ISO 19444-1, Adobe's XFDF specification) for the elements and attributes Inkvolt writes (the
    /// Windows test's XSD, attribute by attribute): the root and its children, the annotation elements with their required
    /// page and rect, colors as #RRGGBB, the flag words, reply types, justification, border styles, line endings, and
    /// number lists.
    static func xfdfRuleErrors(_ data: [UInt8]) throws -> [String] {
        let doc = try XMLDocument(data: Data(data), options: [.nodeLoadExternalEntitiesNever])
        var errors: [String] = []
        func matches(_ s: String, _ pattern: String) -> Bool { s.range(of: "^(?:\(pattern))$", options: .regularExpression) != nil }
        func kids(_ e: XMLElement) -> [XMLElement] { e.children?.compactMap { $0 as? XMLElement } ?? [] }
        let number = "-?[0-9.]+", numbers = "-?[0-9.]+(,-?[0-9.]+)*", pairs = "-?[0-9.]+,-?[0-9.]+(;-?[0-9.]+,-?[0-9.]+)*"
        let flag = "invisible|hidden|print|nozoom|norotate|noview|readonly|locked|togglenoview|lockedcontents"
        let ending = "Square|Circle|Diamond|OpenArrow|ClosedArrow|None|Butt|ROpenArrow|RClosedArrow|Slash"
        let rules: [String: String] = [
            "page": "[0-9]+", "rect": "\(number),\(number),\(number),\(number)", "color": "#[0-9A-Fa-f]{6}", "interior-color": "#[0-9A-Fa-f]{6}",
            "date": "D:[0-9]{4}([0-9]{2}){0,5}(Z|[+\\-][0-9]{2}'([0-9]{2}'?)?)?", "creationdate": "D:[0-9]{4}([0-9]{2}){0,5}(Z|[+\\-][0-9]{2}'([0-9]{2}'?)?)?",
            "flags": "((\(flag))(,(\(flag)))*)?", "opacity": "0(\\.[0-9]+)?|1(\\.0+)?|\\.[0-9]+", "replyType": "reply|group",
            "width": number, "style": "solid|dash|bevelled|inset|underline|cloudy", "dashes": numbers, "intensity": number,
            "fringe": numbers, "rotation": "-?[0-9]+", "justification": "left|centered|right", "coords": numbers,
            "start": "\(number),\(number)", "end": "\(number),\(number)", "head": ending, "tail": ending, "callout": numbers,
            "leaderLength": number, "leaderExtended": number, "leader-offset": number, "caption": "yes|no",
            "name": ".*", "title": ".*", "subject": ".*", "inreplyto": ".*", "intent": ".*", "icon": ".*", "state": ".*",
            "statemodel": ".*", "symbol": ".*", "overlay-text": ".*",
        ]
        let annotations: Set<String> = [
            "text", "freetext", "line", "square", "circle", "polygon", "polyline", "highlight", "underline", "squiggly", "strikeout",
            "stamp", "caret", "ink", "redact",
        ]
        guard let root = doc.rootElement(), root.localName == "xfdf", root.uri == "http://ns.adobe.com/xfdf/" else { return ["root"] }
        var seen: Set<String> = []
        for c in kids(root) {
            let name = c.localName ?? ""
            if !["f", "ids", "annots"].contains(name) || !seen.insert(name).inserted { errors.append("xfdf child <\(name)>") }
            if name == "f" && c.attribute(forName: "href") == nil { errors.append("<f> without href") }
            guard name == "annots" else { continue }
            for a in kids(c) {
                let el = a.localName ?? ""
                if !annotations.contains(el) { errors.append("<\(el)> in annots") }
                for attr in ["page", "rect"] where a.attribute(forName: attr) == nil { errors.append("<\(el)> without \(attr)") }
                for attr in a.attributes ?? [] {
                    let key = attr.name ?? "", value = attr.stringValue ?? ""
                    guard let rule = rules[key] else {
                        errors.append("<\(el)> attribute \(key)")
                        continue
                    }
                    if !matches(value, rule) { errors.append("<\(el)> \(key)=\"\(value)\"") }
                }
                for child in kids(a) {
                    let cn = child.localName ?? "", text = child.stringValue ?? ""
                    switch cn {
                    case "contents", "defaultappearance", "defaultstyle", "popup": break
                    case "contents-richtext":
                        if kids(child).count != 1 || kids(child)[0].uri != "http://www.w3.org/1999/xhtml" { errors.append("rich text") }
                    case "vertices": if !matches(text, pairs) { errors.append("vertices \(text)") }
                    case "inklist":
                        for g in kids(child) where g.localName != "gesture" || !matches(g.stringValue ?? "", pairs) { errors.append("gesture") }
                    case "appearance": if Data(base64Encoded: text) == nil { errors.append("appearance isn't base64") }
                    default: errors.append("<\(cn)> in <\(el)>")
                    }
                }
            }
        }
        return errors
    }

    @Test func exportedXfdfFollowsTheXfdfRules() throws {
        let xfdf = try CommentFiles.export(Self.commented(), nil, .xfdf, pdfFileName: "source.pdf").data
        #expect(try Self.xfdfRuleErrors(xfdf) == [])

        // The stamp's appearance decodes to Acrobat's DICT/STREAM tree.
        let doc = try XMLDocument(data: Data(xfdf))
        func all(_ name: String) throws -> [XMLElement] { try doc.nodes(forXPath: "//*[local-name()='\(name)']").compactMap { $0 as? XMLElement } }
        let stamps = try all("stamp")
        #expect(stamps.count == 1)
        let appearance = try #require(stamps.first?.elements(forName: "appearance").first?.stringValue)
        let tree = try XMLElement(xmlString: String(decoding: try #require(Data(base64Encoded: appearance)), as: UTF8.self))
        #expect(tree.localName == "DICT")
        #expect(tree.attribute(forName: "KEY")?.stringValue == "AP")
        let n = try #require(tree.elements(forName: "STREAM").first { $0.attribute(forName: "KEY")?.stringValue == "N" })
        #expect(n.elements(forName: "ARRAY").contains { $0.attribute(forName: "KEY")?.stringValue == "BBox" })
        #expect(n.elements(forName: "DATA").first?.attribute(forName: "ENCODING")?.stringValue == "HEX")
        let texts = try all("text")
        #expect(texts.count == 3)
        #expect(texts.first { $0.attribute(forName: "name")?.stringValue == "reply-1" }?.attribute(forName: "inreplyto")?.stringValue == "note-1")
    }

    @Test func importsAdobeStyleXfdf() throws {
        // Shaped like Acrobat's output and the XFDF specification's examples: a note with rich text and a popup, a reply, a
        // highlight, ink, a square, a free text box and a custom stamp with its appearance.
        let hexOps = Array("1 0 0 rg 2 2 116 36 re f q Q   ".utf8).map { String(format: "%02X", $0) }.joined()
        let apXml = "<?xml version=\"1.0\" encoding=\"UTF-8\" ?><DICT KEY=\"AP\"><STREAM KEY=\"N\"><ARRAY KEY=\"BBox\"><FIXED VAL=\"0.0\"/>"
            + "<FIXED VAL=\"0.0\"/><FIXED VAL=\"120.0\"/><FIXED VAL=\"40.0\"/></ARRAY><INT KEY=\"Length\" VAL=\"31\"/><NAME KEY=\"Subtype\" VAL=\"Form\"/>"
            + "<NAME KEY=\"Type\" VAL=\"XObject\"/><DICT KEY=\"Resources\"/><DATA MODE=\"RAW\" ENCODING=\"HEX\">" + hexOps + "</DATA></STREAM></DICT>"
        let stampAp = Data(apXml.utf8).base64EncodedString()
        let xfdf = """
            <?xml version="1.0" encoding="UTF-8"?>
            <xfdf xmlns="http://ns.adobe.com/xfdf/" xml:space="preserve">
            <annots>
            <text color="#FFFF00" creationdate="D:20090416104010-07'00'" flags="print,nozoom,norotate" date="D:20090416104016-07'00'" name="a1b2c3d4-0001" icon="Comment" page="0" rect="300.5,700.25,320.5,720.25" subject="Sticky Note" title="jdoe">
            <contents-richtext><body xmlns="http://www.w3.org/1999/xhtml" xmlns:xfa="http://www.xfa.org/schema/xfa-data/1.0/" xfa:APIVersion="Acrobat:9.0.0" xfa:spec="2.0.2"><p>Please review this paragraph.</p><p>Second line</p></body></contents-richtext>
            <popup flags="print,nozoom,noview,norotate" open="no" page="0" rect="320,600,500,720"/>
            </text>
            <text color="#FFFF00" date="D:20090416110000-07'00'" flags="print,nozoom,norotate" name="a1b2c3d4-0002" icon="Comment" inreplyto="a1b2c3d4-0001" replyType="reply" page="0" rect="300.5,700.25,320.5,720.25" subject="Sticky Note" title="asmith"><contents>Done.</contents></text>
            <highlight color="#FFFF00" date="D:20090416104100-07'00'" flags="print" name="a1b2c3d4-0003" page="0" coords="72,650,250,650,72,630,250,630" rect="71,629,251,651" title="jdoe" opacity="0.5"><contents>Key sentence</contents></highlight>
            <ink color="#0000FF" date="D:20090416104200-07'00'" flags="print" name="a1b2c3d4-0004" page="0" rect="99,399,201,451" title="jdoe" width="2"><inklist><gesture>100,400;150,450;200,400</gesture></inklist></ink>
            <square color="#FF0000" interior-color="#FFFFCC" date="D:20090416104300-07'00'" flags="print" name="a1b2c3d4-0005" page="0" rect="300,300,400,360" title="jdoe" width="3" style="dash" dashes="3,3"/>
            <freetext date="D:20090416104400-07'00'" flags="print" name="a1b2c3d4-0006" page="0" rect="72,200,272,240" title="jdoe" justification="centered" width="1" color="#000000">
            <contents>Typed note</contents><defaultappearance>0 0 1 rg /Helv 12 Tf</defaultappearance><defaultstyle>font: Helvetica 12pt; text-align:center; color:#0000FF</defaultstyle>
            </freetext>
            <stamp date="D:20090416104500-07'00'" flags="print" name="a1b2c3d4-0007" icon="SBApproved" page="0" rect="400,100,520,140" title="jdoe" subject="Approved"><appearance>\(stampAp)</appearance></stamp>
            </annots>
            <f href="Document.pdf"/>
            <ids original="A1B2C3" modified="D4E5F6"/>
            </xfdf>
            """
        let r = try CommentFiles.importComments(TestPdf.make(1), nil, Array(xfdf.utf8))
        #expect(r.added == 7)
        let c = try Self.byId(r.data)
        #expect(c["a1b2c3d4-0001"]?.contents == "Please review this paragraph.\nSecond line")
        #expect(c["a1b2c3d4-0002"]?.replyTo == "a1b2c3d4-0001")
        #expect(c["a1b2c3d4-0002"]?.author == "asmith")
        var when = DateComponents(timeZone: TimeZone(secondsFromGMT: -7 * 3600), year: 2009, month: 4, day: 16, hour: 10, minute: 40, second: 16)
        when.calendar = Calendar(identifier: .gregorian)
        #expect(c["a1b2c3d4-0001"]?.modified == when.date)
        #expect(c["a1b2c3d4-0003"]?.quadRects.count == 1)
        #expect(abs((c["a1b2c3d4-0003"]?.opacity ?? 0) - 0.5) < 0.001)
        #expect(c["a1b2c3d4-0004"]?.geometry?.paths.first?.count == 3)
        #expect(c["a1b2c3d4-0005"]?.style?.dash == [3, 3])
        #expect(c["a1b2c3d4-0006"]?.style?.align == .center)
        #expect(c["a1b2c3d4-0006"]?.style?.textColor == AnnotColor(0, 0, 1))
        #expect(try Core2Pdf.allText(r.data).contains("Typed note"))

        // The stamp shows the picture it came with: red.
        #expect(try Core2Pdf.ink(r.data, 0, RectD(410, 792 - 135, 100, 30)) > 0.5)
    }

    // ---------------- Hostile files ----------------

    @Test func refusesXfdfWithADtd() throws {
        let xxe = """
            <?xml version="1.0"?>
            <!DOCTYPE xfdf [<!ENTITY secret SYSTEM "file:///etc/passwd">]>
            <xfdf xmlns="http://ns.adobe.com/xfdf/"><annots><text page="0" rect="0,0,20,20"><contents>&secret;</contents></text></annots></xfdf>
            """
        do {
            _ = try CommentFiles.importComments(TestPdf.make(1), nil, Array(xxe.utf8))
            Issue.record("a DTD was read")
        } catch let e as PdfEditError {
            #expect(e.message.contains("DTD"))
        }

        let laughs = "<?xml version=\"1.0\"?><!DOCTYPE lolz [<!ENTITY lol \"lol\"><!ENTITY lol2 \"&lol;&lol;&lol;&lol;&lol;&lol;&lol;&lol;\">]>"
            + "<xfdf xmlns=\"http://ns.adobe.com/xfdf/\"><annots><text page=\"0\" rect=\"0,0,20,20\"><contents>&lol2;</contents></text></annots></xfdf>"
        #expect(throws: PdfEditError.self) { try CommentFiles.importComments(TestPdf.make(1), nil, Array(laughs.utf8)) }
        let fields = xxe.replacingOccurrences(of: "<annots>", with: "<fields><field name=\"name\"><value>&secret;</value></field></fields><annots>")
        #expect(throws: PdfEditError.self) { try FormDataFiles.importData(FormDataTests.form(), nil, Array(fields.utf8)) }
    }

    @Test func bringsNoScriptsOrActionsIn() throws {
        // FDF: actions on the annotation, in its appearance's resources and as a JavaScript name tree; an attachment.
        let fdf = """
            %FDF-1.2
            1 0 obj << /FDF << /Annots [2 0 R 5 0 R] /JavaScript << /Doc [(x) 6 0 R] >> /F (evil.pdf) >> >> endobj
            2 0 obj << /Type /Annot /Subtype /Square /Page 0 /Rect [10 10 100 100] /NM (evil-1) /T (Mallory) /Contents (hi)
               /A << /S /JavaScript /JS (app.alert\\(1\\)) >> /AA << /E << /S /Launch /F (calc.exe) >> >> /OpenAction 6 0 R
               /AP << /N 3 0 R >> /Popup << /Type /Annot /Subtype /Popup >> /IC [1 0 0] >> endobj
            3 0 obj << /Type /XObject /Subtype /Form /BBox [0 0 90 90] /Resources << /XObject << /X1 4 0 R >> /Properties << /P1 << /S /URI /URI (http://x) >> >> >> /Length 13 >>
            stream
            0 0 1 rg 0 0 90 90 re f
            endstream endobj
            4 0 obj << /Type /XObject /Subtype /Form /BBox [0 0 1 1] /F (\\\\\\\\evil\\\\share\\\\x) /Length 0 >>
            stream

            endstream endobj
            5 0 obj << /Type /Annot /Subtype /FileAttachment /Page 0 /Rect [0 0 10 10] /FS << /Type /Filespec /EF << /F 7 0 R >> >> >> endobj
            6 0 obj << /S /JavaScript /JS (this.exportDataObject\\(\\)) >> endobj
            7 0 obj << /Type /EmbeddedFile /Length 3 >>
            stream
            MZ!
            endstream endobj
            trailer << /Root 1 0 R >>
            %%EOF
            """
        let r = try CommentFiles.importComments(TestPdf.make(1), nil, Array(fdf.utf8))
        #expect(r.added == 1)
        #expect(r.skipped.contains { $0.contains("file attachment") })
        try Self.assertHarmless(r.data)

        // XFDF: a link with an action, script-looking text (stays text), a stamp appearance with an action inside.
        let badAp = Data(("<DICT KEY=\"AP\"><STREAM KEY=\"N\"><ARRAY KEY=\"BBox\"><INT VAL=\"0\"/><INT VAL=\"0\"/><INT VAL=\"10\"/><INT VAL=\"10\"/></ARRAY>"
            + "<DICT KEY=\"Resources\"><DICT KEY=\"A\"><NAME KEY=\"S\" VAL=\"JavaScript\"/><STRING KEY=\"JS\" VAL=\"app.alert(2)\"/></DICT></DICT>"
            + "<DATA MODE=\"RAW\" ENCODING=\"HEX\">30</DATA></STREAM></DICT>").utf8).base64EncodedString()
        let xfdf = """
            <xfdf xmlns="http://ns.adobe.com/xfdf/"><annots>
            <link page="0" rect="0,0,50,50"><OnActivation><Action><Launch><File Name="calc.exe"/></Launch></Action></OnActivation></link>
            <text page="0" rect="0,0,20,20" name="t1"><contents>&lt;script&gt;app.alert(3)&lt;/script&gt;</contents></text>
            <stamp page="0" rect="50,50,60,60" name="s1"><appearance>\(badAp)</appearance></stamp>
            </annots></xfdf>
            """
        let x = try CommentFiles.importComments(TestPdf.make(1), nil, Array(xfdf.utf8))
        #expect(x.added == 2)
        try Self.assertHarmless(x.data)
        #expect(try Self.byId(x.data)["t1"]?.contents == "<script>app.alert(3)</script>")
    }

    /// No object of the document is an action, holds JavaScript, a file or external data.
    static func assertHarmless(_ pdf: [UInt8]) throws {
        let doc = try Core2Pdf.open(pdf)
        for n in 1..<max(doc.objectCount, 1) {
            let d = doc.object(n)
            guard d.isDict else { continue }
            for key in ["JS", "AA", "OpenAction", "EF"] { #expect(!d.has(key), "/\(key) in object \(n)") }
            #expect(!["JavaScript", "Launch", "URI"].contains(d.name("S") ?? ""), "/S in object \(n)")
            if d.name("Type") == "Annot" { #expect(!d.has("A"), "/A on an annotation") }
            if d.isStream { #expect(!d.has("F"), "external stream") }
        }
        #expect(!latin1(pdf).contains("app.alert(1)"))
        #expect(!latin1(pdf).contains("calc.exe"))
    }

    @Test func refusesHugeFiles() throws {
        var huge = [UInt8](repeating: UInt8(ascii: " "), count: CommentFiles.maxFileBytes + 1)
        huge[0] = UInt8(ascii: "<")
        do {
            _ = try CommentFiles.importComments(TestPdf.make(1), nil, huge)
            Issue.record("a huge file was read")
        } catch let e as PdfEditError {
            #expect(e.message.contains("larger than"))
        }

        var many = "<xfdf xmlns=\"http://ns.adobe.com/xfdf/\"><annots>"
        many.reserveCapacity(3_500_000)
        for _ in 0...CommentFiles.maxComments { many += "<text page=\"0\" rect=\"0,0,1,1\"/>" }
        many += "</annots></xfdf>"
        do {
            _ = try CommentFiles.importComments(TestPdf.make(1), nil, Array(many.utf8))
            Issue.record("too many comments were read")
        } catch let e as PdfEditError {
            #expect(e.message.contains("more than"))
        }

        #expect(throws: PdfEditError.self) { try FormDataFiles.readValues([UInt8](repeating: 0, count: FormDataFiles.maxFileBytes + 1)) }
        #expect(throws: PdfEditError.self) {
            try FormDataFiles.readValues(Array((String(repeating: "[", count: 10_000) + String(repeating: "]", count: 10_000)).utf8))
        }
    }

    @Test func refusesFilesThatArentComments() {
        #expect(throws: PdfEditError.self) { try CommentFiles.importComments(TestPdf.make(1), nil, Array("name,value\nx,y\n".utf8)) }
        #expect(throws: PdfEditError.self) { try CommentFiles.importComments(TestPdf.make(1), nil, Array("<html><body/></html>".utf8)) }
        #expect(throws: PdfEditError.self) { try CommentFiles.importComments(TestPdf.make(1), nil, Array("<xfdf><annots>".utf8)) }
    }

    /// Mac only: deeply nested FDF arrays, cycles of references and a damaged stream neither crash nor hang the import.
    @Test func malformedFdfDoesntCrash() throws {
        let deep = "%FDF-1.2\n1 0 obj << /FDF << /Annots [2 0 R] >> >> endobj\n2 0 obj << /Subtype /Square /Page 0 /Rect [0 0 9 9] /NM (d) /Q "
            + String(repeating: "[", count: 50_000) + String(repeating: "]", count: 50_000) + " /C 3 0 R >> endobj\n3 0 obj 4 0 R endobj\n4 0 obj [3 0 R] endobj\n"
            + "5 0 obj << /Length 999999 >> stream\nabc\ntrailer << /Root 1 0 R >>\n"
        let r = try CommentFiles.importComments(TestPdf.make(1), nil, Array(deep.utf8))
        #expect(r.added == 1)
        #expect(throws: PdfEditError.self) { try CommentFiles.importComments(TestPdf.make(1), nil, Array("%FDF-1.2\n1 0 obj << >> endobj".utf8)) }
    }
}
