import Foundation

/// One scanned page as a document holds it (roadmap 4.14): its recognized words (the image's pixels from its top left, as
/// `PdfWriter` takes them), and the pictures that go in instead of text (photos found on the glass, or the page itself when no
/// text was read from it). JPEGs at `dpi`.
public struct ScanDocPage: Sendable {
    public var words: [PdfWriter.Word]?
    public var dpi: Int
    public var pictures: [[UInt8]]

    public init(_ words: [PdfWriter.Word]?, dpi: Int, pictures: [[UInt8]] = []) {
        self.words = words
        self.dpi = dpi
        self.pictures = pictures
    }

    /// The page's paragraphs, from its words (`PageText.paragraphs`).
    public func paragraphs() -> [TextParagraph] { PageText.paragraphs(PageText.lines(words)) }
}

/// A scan saved as a Word document (.docx): each page's text as paragraphs (a heading in Heading 1), its pictures inline at
/// their size (smaller to fit the page), each scanned page from a new page. Simple on purpose: no columns, tables or fonts,
/// so the text is easy to edit. The parts are written by the shared `OpenXmlParts` and `XmlOut`, as Inkvolt PDF's exports,
/// into PrintCore's `ZipArchive.Writer`. Windows' `ScanDocx`.
public enum ScanDocx {
    private static let relBase = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/"

    /// The room a picture may take (inches): a letter or A4 page inside Word's usual margins.
    public static let maxWidth = 6.3, maxHeight = 8.9

    private static let emu = 914_400.0 // per inch

    /// At most this many paragraphs and pictures go in, whatever the pages hold.
    public static let maxParagraphs = 100_000, maxPictures = 2000

    /// The document's bytes. Its parts are stored, not deflated (see `mac/docs/PLAN.md`, 4.14).
    public static func write(_ pages: [ScanDocPage], title: String?, modified: Date = Date()) throws -> [UInt8] {
        var out: [UInt8] = []
        let zip = ZipArchive.Writer(modified: modified) { out += $0 }
        var rels: [(id: String, type: String, target: String)] = [("rIdStyles", relBase + "styles", "styles.xml")]
        // The pictures first, each stored once as it is (JPEG), with its size on the page.
        var pictures: [[(id: String, cx: Int64, cy: Int64)]] = []
        var count = 0
        for page in pages {
            var placed: [(id: String, cx: Int64, cy: Int64)] = []
            for jpeg in page.pictures {
                guard count < maxPictures, let size = size(jpeg, dpi: page.dpi) else { continue }
                count += 1
                let target = "media/image\(count).jpeg"
                try zip.add("word/" + target, jpeg) // already compressed
                let id = "rIdImg\(count)"
                rels.append((id, relBase + "image", target))
                placed.append((id, size.cx, size.cy))
            }
            pictures.append(placed)
        }
        try zip.add("word/document.xml", OpenXmlParts.xml { document($0, pages, pictures) })
        try zip.add("word/styles.xml", OpenXmlParts.xml(styles))
        try zip.add("word/_rels/document.xml.rels", OpenXmlParts.xml { OpenXmlParts.relationships($0, rels) })
        try zip.add("_rels/.rels", OpenXmlParts.xml {
            OpenXmlParts.relationships($0, [
                ("rId1", relBase + "officeDocument", "word/document.xml"),
                ("rId2", "http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties", "docProps/core.xml"),
                ("rId3", relBase + "extended-properties", "docProps/app.xml"),
            ])
        })
        try zip.add("docProps/core.xml", OpenXmlParts.xml { OpenXmlParts.coreProperties($0, title) })
        try zip.add("docProps/app.xml", OpenXmlParts.xml { OpenXmlParts.appProperties($0, application: "Inkvolt Print") })
        try zip.add("[Content_Types].xml", OpenXmlParts.xml {
            OpenXmlParts.contentTypes($0, [
                ("/word/document.xml", "application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"),
                ("/word/styles.xml", "application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"),
            ])
        })
        try zip.finish()
        return out
    }

    /// A picture's size in EMU: its pixels at `dpi`, made smaller to fit the room; nil when it isn't a JPEG.
    static func size(_ jpeg: [UInt8], dpi: Int) -> (cx: Int64, cy: Int64)? {
        guard let info = try? PdfWriter.jpegInfo(jpeg), info.width >= 1, info.height >= 1 else { return nil }
        let d = Double(max(1, dpi))
        let (inW, inH) = (Double(info.width) / d, Double(info.height) / d)
        let scale = min(1, min(maxWidth / inW, maxHeight / inH))
        // bounded: a JPEG's sides are at most 65,535 pixels, so a few billion EMU at most.
        return (Int64((inW * scale * emu).rounded()), Int64((inH * scale * emu).rounded()))
    }

    private static func document(_ w: XmlOut, _ pages: [ScanDocPage], _ pictures: [[(id: String, cx: Int64, cy: Int64)]]) {
        w.start("w:document", [
            ("xmlns:w", "http://schemas.openxmlformats.org/wordprocessingml/2006/main"),
            ("xmlns:r", "http://schemas.openxmlformats.org/officeDocument/2006/relationships"),
            ("xmlns:wp", "http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing"),
            ("xmlns:a", "http://schemas.openxmlformats.org/drawingml/2006/main"),
            ("xmlns:pic", "http://schemas.openxmlformats.org/drawingml/2006/picture"),
        ])
        w.start("w:body")
        var paragraphs = 0
        var drawing = 0
        var any = false
        for (i, page) in pages.enumerated() {
            var first = true
            // A paragraph: in Heading 1 when it is a heading, and the page's first from a new page in Word (pStyle comes first in pPr).
            func start(heading: Bool) {
                w.start("w:p")
                let breaks = first && any // not before the document's first paragraph
                if heading || breaks {
                    w.start("w:pPr")
                    if heading { w.empty("w:pStyle", [("w:val", "Heading1")]) }
                    if breaks { w.empty("w:pageBreakBefore") }
                    w.end()
                }
                first = false
                any = true
            }
            for para in page.paragraphs() {
                paragraphs += 1
                if paragraphs > maxParagraphs { break }
                start(heading: para.heading)
                w.start("w:r")
                w.start("w:t", [("xml:space", "preserve")])
                w.text(OpenXmlParts.clean(para.text).replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\n", with: " "))
                w.end()
                w.end()
                w.end() // p
            }
            for picture in pictures[i] {
                start(heading: false)
                w.start("w:r")
                drawing += 1
                self.picture(w, picture.id, picture.cx, picture.cy, drawing)
                w.end()
                w.end() // p
            }
        }
        if !any { w.empty("w:p") } // Word wants a paragraph
        w.end() // body
        w.end() // document
    }

    private static func picture(_ w: XmlOut, _ id: String, _ cx: Int64, _ cy: Int64, _ n: Int) {
        let (x, y) = (String(cx), String(cy))
        w.start("w:drawing")
        w.start("wp:inline")
        w.empty("wp:extent", [("cx", x), ("cy", y)])
        w.empty("wp:docPr", [("id", String(n)), ("name", "Picture \(n)")])
        w.start("a:graphic")
        w.start("a:graphicData", [("uri", "http://schemas.openxmlformats.org/drawingml/2006/picture")])
        w.start("pic:pic")
        w.start("pic:nvPicPr")
        w.empty("pic:cNvPr", [("id", String(n)), ("name", "Picture \(n)")])
        w.empty("pic:cNvPicPr")
        w.end()
        w.start("pic:blipFill")
        w.empty("a:blip", [("r:embed", id)])
        w.start("a:stretch")
        w.empty("a:fillRect")
        w.end()
        w.end()
        w.start("pic:spPr")
        w.start("a:xfrm")
        w.empty("a:off", [("x", "0"), ("y", "0")])
        w.empty("a:ext", [("cx", x), ("cy", y)])
        w.end()
        w.start("a:prstGeom", [("prst", "rect")])
        w.empty("a:avLst")
        w.end()
        w.end() // spPr
        w.end() // pic
        w.end() // graphicData
        w.end() // graphic
        w.end() // inline
        w.end() // drawing
    }

    private static func styles(_ w: XmlOut) {
        w.start("w:styles", [("xmlns:w", "http://schemas.openxmlformats.org/wordprocessingml/2006/main")])
        func style(_ id: String, _ name: String, isDefault: Bool, _ body: () -> Void) {
            var attributes = [("w:type", "paragraph"), ("w:styleId", id)]
            if isDefault { attributes.append(("w:default", "1")) }
            w.start("w:style", attributes)
            w.empty("w:name", [("w:val", name)])
            body()
            w.end()
        }
        func val(_ element: String, _ value: String) { w.empty(element, [("w:val", value)]) }
        style("Normal", "Normal", isDefault: true) {
            w.start("w:pPr")
            w.empty("w:spacing", [("w:after", "160")])
            w.end()
            w.start("w:rPr")
            val("w:sz", "22")
            w.end()
        }
        style("Heading1", "heading 1", isDefault: false) {
            val("w:basedOn", "Normal")
            val("w:next", "Normal")
            val("w:qFormat", "1")
            w.start("w:pPr")
            w.empty("w:keepNext")
            w.empty("w:spacing", [("w:before", "240"), ("w:after", "120")])
            val("w:outlineLvl", "0")
            w.end()
            w.start("w:rPr")
            w.empty("w:b")
            val("w:sz", "32")
            w.end()
        }
        w.end()
    }
}

/// A scan saved as plain text (.txt): each page's paragraphs, a blank line between them and two between pages; UTF-8 with a
/// byte order mark and Windows line ends, so Notepad and older tools read it alike (the same file on both apps). Pages with
/// no text add nothing. Windows' `ScanText`.
public enum ScanText {
    /// The line ends .NET's ReplaceLineEndings replaces: CR, LF, CRLF, NEL, FF, LS and PS.
    static func isLineEnd(_ c: Character) -> Bool {
        ["\n", "\r\n", "\r", "\u{85}", "\u{0C}", "\u{2028}", "\u{2029}"].contains(c)
    }

    public static func text(_ pages: [ScanDocPage]) -> String {
        var s = ""
        for page in pages {
            let paragraphs = page.paragraphs()
            if paragraphs.isEmpty { continue }
            if !s.isEmpty { s += "\r\n" }
            for p in paragraphs {
                let one = p.text.split(omittingEmptySubsequences: false, whereSeparator: ScanText.isLineEnd).joined(separator: " ")
                s += one + "\r\n\r\n"
            }
        }
        let wrote = !s.isEmpty
        while let last = s.unicodeScalars.last, last == "\r" || last == "\n" { s.unicodeScalars.removeLast() }
        return s + (wrote ? "\r\n" : "")
    }

    /// The file's bytes: the byte order mark, then the text in UTF-8.
    public static func write(_ pages: [ScanDocPage]) -> [UInt8] { [0xEF, 0xBB, 0xBF] + Array(text(pages).utf8) }
}
