import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// How big each file is (Windows' `Sizes`): `full` is the benchmark, `small` a quick try.
struct Sizes: Sendable {
    let textPages, scanPages, drawingSheets, pathsPerSheet, commentPages, commentsPerPage: Int
    static let full = Sizes(textPages: 5000, scanPages: 500, drawingSheets: 400, pathsPerSheet: 72_000, commentPages: 250, commentsPerPage: 40)
    static let small = Sizes(textPages: 12, scanPages: 3, drawingSheets: 2, pathsPerSheet: 5000, commentPages: 5, commentsPerPage: 40)
}

/// One benchmark file: its name, what it is, and the word Find looks for in it.
struct CorpusFile: Sendable {
    let name: String
    let findWord: String
    func describe(_ s: Sizes) -> String {
        switch name {
        case "text.pdf": "\(n(s.textPages))-page text document: real paragraphs in Times, Helvetica, Courier and Helvetica-Bold (standard fonts, Flate content)"
        case "scan.pdf": "\(n(s.scanPages))-page scan: 300 dpi grayscale JPEG pages (2550 × 3300 px) with paper noise, text-like lines and specks"
        case "drawings.pdf": "\(n(s.drawingSheets))-sheet drawing set (ARCH D, 36 × 24 in): hatching, polylines and circles, \(n(s.pathsPerSheet)) paths per sheet, a title block"
        default: "\(n(s.commentPages))-page text document with \(n(s.commentPages * s.commentsPerPage)) comments: notes, highlights, underlines, strike-outs, boxes, circles, ink, text boxes, with popups, and replies"
        }
    }
}

func n(_ v: Int) -> String {
    let f = NumberFormatter()
    f.numberStyle = .decimal
    f.locale = Locale(identifier: "en_US")
    return f.string(from: NSNumber(value: v)) ?? "\(v)"
}

/// The four files of roadmap 3.6's benchmark, ported from Windows' `Corpus.cs`. The text, noise and paths come from the
/// same `Rng` with the same seeds, so the pages hold the same words and shapes; the files' bytes differ from Windows'
/// (Apple's deflate and ImageIO's JPEG encoder, not .NET's ZLibStream and the bench's own encoder), so their SHA-256s do too.
enum Corpus {
    static let files = [
        CorpusFile(name: "text.pdf", findWord: "lantern"),
        CorpusFile(name: "scan.pdf", findWord: "lantern"),
        CorpusFile(name: "drawings.pdf", findWord: "detail"),
        CorpusFile(name: "comments.pdf", findWord: "lantern"),
    ]

    static func make(_ dir: String, _ sizes: Sizes, force: Bool, log: (String) -> Void) throws {
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        for f in files {
            let path = (dir as NSString).appendingPathComponent(f.name)
            if FileManager.default.fileExists(atPath: path) && !force {
                log("\(f.name): exists, kept")
                continue
            }
            let started = Date()
            let tmp = path + ".tmp"
            switch f.name {
            case "text.pdf": try writeTextDocument(tmp, pages: sizes.textPages, title: "Benchmark: text", idName: "text.pdf", annotate: nil)
            case "scan.pdf": try makeScan(tmp, sizes, log)
            case "drawings.pdf": try makeDrawings(tmp, sizes, log)
            default: try makeComments(tmp, sizes)
            }
            try? FileManager.default.removeItem(atPath: path)
            try FileManager.default.moveItem(atPath: tmp, toPath: path)
            log("\(f.name): \(String(format: "%.1f", mb(path))) MB in \(Int(Date().timeIntervalSince(started))) s, SHA-256 \(sha256(path))")
        }
    }

    static func mb(_ path: String) -> Double {
        Double((try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? 0) / 1_048_576
    }

    static func sha256(_ path: String) -> String {
        guard let h = FileHandle(forReadingAtPath: path) else { return "" }
        var hasher = SHA256()
        while let chunk = try? h.read(upToCount: 8 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func fileId(_ name: String) -> String {
        Insecure.MD5.hash(data: Data("inkvolt-bench-\(name)".utf8)).map { String(format: "%02X", $0) }.joined()
    }

    private static func info(_ w: PdfFileWriter, _ title: String) -> Int {
        w.add("<< /Title \(PdfFileWriter.str(title)) /Producer (Inkvolt PDF benchmark corpus) >>")
    }

    private static let fonts =
        "/F1 << /Type /Font /Subtype /Type1 /BaseFont /Times-Roman /Encoding /WinAnsiEncoding >> " +
        "/F2 << /Type /Font /Subtype /Type1 /BaseFont /Helvetica-Bold /Encoding /WinAnsiEncoding >> " +
        "/F3 << /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >> " +
        "/F4 << /Type /Font /Subtype /Type1 /BaseFont /Courier /Encoding /WinAnsiEncoding >> " +
        "/F5 << /Type /Font /Subtype /Type1 /BaseFont /Times-Italic /Encoding /WinAnsiEncoding >>"

    // MARK: text.pdf

    struct Line {
        let font: String
        let size, x, y, width: Double
    }

    private static let left = 72.0, top = 720.0, textWidth = 468.0, body = 11.0, leading = 14.0

    private static func avgWidth(_ font: String) -> Double {
        switch font {
        case "/F1", "/F5": 0.50
        case "/F4": 0.60
        default: 0.56
        }
    }

    static func textPage(_ pageNo: Int, _ pageCount: Int, _ lines: inout [Line]) -> String {
        var rng = Rng(1_000_003 &* UInt64(pageNo) &+ 17)
        let bodyFont = ["/F1", "/F3", "/F4"][(pageNo / 7) % 3]
        var s = ""
        s.reserveCapacity(4096)
        var y = top
        if pageNo % 5 == 1 {
            let title = "Chapter \(pageNo / 5 + 1): \(Prose.title(&rng))"
            s += "BT /F2 16 Tf \(f(left)) \(f(y)) Td \(PdfFileWriter.str(title)) Tj ET\n"
            lines.append(Line(font: "/F2", size: 16, x: left, y: y, width: Double(title.count) * 16 * 0.56))
            y -= 30
        }
        var para = 0
        while y > 100 {
            let font = para % 4 == 3 ? "/F5" : bodyFont
            let maxChars = Int(textWidth / (body * avgWidth(font)))
            s += "BT \(font) \(f(body)) Tf \(f(leading)) TL \(f(left)) \(f(y)) Td\n"
            for line in Prose.wrap(Prose.paragraph(&rng), maxChars) {
                if y <= 100 { break }
                s += PdfFileWriter.str(line) + " Tj T*\n"
                lines.append(Line(font: font, size: body, x: left, y: y, width: Double(line.count) * body * avgWidth(font)))
                y -= leading
            }
            s += "ET\n"
            y -= leading / 2
            para += 1
        }
        s += "BT /F3 9 Tf \(f(left)) 50 Td (Page \(pageNo) of \(pageCount)) Tj 330 0 Td (Inkvolt PDF benchmark corpus) Tj ET\n"
        return s
    }

    private static func latin1(_ s: String) -> [UInt8] { s.unicodeScalars.map { UInt8(truncatingIfNeeded: $0.value) } }

    private static func writeTextDocument(_ path: String, pages: Int, title: String, idName: String,
                                          annotate: ((PdfFileWriter, Int, Int, [Line]) -> [Int])?) throws {
        let w = try PdfFileWriter(path: path)
        let infoId = info(w, title)
        let fontsId = w.add("<< \(fonts) >>")
        let resources = w.add("<< /Font \(fontsId) 0 R >>")
        let tree = PageTree(w, pageCount: pages)
        for p in 0..<pages {
            var lines: [Line] = []
            let content = w.addStream("", latin1(textPage(p + 1, pages, &lines)))
            let page = w.reserve()
            tree.add(page)
            let annots = annotate.map { " /Annots [\($0(w, page, p, lines).map { "\($0) 0 R" }.joined(separator: " "))]" } ?? ""
            w.put(page, "<< /Type /Page /Parent \(tree.parentOf(p)) 0 R /MediaBox [0 0 612 792] /Resources \(resources) 0 R /Contents \(content) 0 R\(annots) >>")
        }
        tree.write()
        let catalog = w.add("<< /Type /Catalog /Pages \(tree.rootId) 0 R >>")
        try w.finish(root: catalog, info: infoId, fileId: fileId(idName))
    }

    // MARK: scan.pdf

    static let scanWidth = 2550, scanHeight = 3300, scanDpi = 300

    static func scanPixels(_ pageNo: Int) -> [UInt8] {
        var rng = Rng(7919 &* UInt64(pageNo) &+ 101)
        let w = scanWidth, h = scanHeight
        var px = [UInt8](repeating: 0, count: w * h)
        for y in 0..<h {
            let row = y * w
            for x in 0..<w { px[row + x] = UInt8(236 + x * 8 / w + rng.next(13) - 6) }
        }
        func blob(_ x0: Int, _ y0: Int, _ wdt: Int, _ hgt: Int, _ gray: Int) {
            for y in max(0, y0)..<max(max(0, y0), min(h, y0 + hgt)) {
                for x in max(0, x0)..<max(max(0, x0), min(w, x0 + wdt)) {
                    let edge = y == y0 || y == y0 + hgt - 1 || x == x0 || x == x0 + wdt - 1
                    px[y * w + x] = UInt8(min(255, max(0, gray + (edge ? 60 : 0) + rng.next(21) - 10)))
                }
            }
        }
        var lineY = 300 + rng.next(40)
        for _ in 0..<55 {
            defer { lineY += 50 }
            if rng.next(100) < 8 { continue } // a blank line between paragraphs
            var x = 250 + rng.next(8)
            let end = rng.next(100) < 15 ? 900 + rng.next(1200) : 2300
            let height = 22 + rng.next(5)
            while x < end {
                let wdt = 60 + rng.next(160)
                let yy = lineY + rng.next(3)
                blob(x, yy, wdt, height, 25 + rng.next(50))
                x += wdt + 18 + rng.next(14)
            }
        }
        for _ in 0..<400 {
            let x = rng.next(w), y = rng.next(h), bw = 1 + rng.next(3), bh = 1 + rng.next(3), g = 40 + rng.next(80)
            blob(x, y, bw, bh, g)
        }
        return px
    }

    /// ImageIO's quality for the scan's pages: chosen so a page is about the size Windows' encoder makes at its 75 (0.86 MB).
    static let jpegQuality = 0.51

    /// A grayscale JPEG at 300 dpi through ImageIO (Windows uses the bench's own baseline encoder).
    static func jpeg(_ px: [UInt8], _ w: Int, _ h: Int, quality: Double = jpegQuality) -> [UInt8] {
        let data = NSMutableData()
        let provider = CGDataProvider(data: Data(px) as CFData)!
        let image = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(),
                            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue), provider: provider, decode: nil,
                            shouldInterpolate: false, intent: .defaultIntent)!
        let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: quality,
                                                 kCGImagePropertyDPIWidth: scanDpi, kCGImagePropertyDPIHeight: scanDpi] as CFDictionary)
        CGImageDestinationFinalize(dest)
        return [UInt8](data as Data)
    }

    private static func makeScan(_ path: String, _ s: Sizes, _ log: (String) -> Void) throws {
        let w = try PdfFileWriter(path: path)
        let infoId = info(w, "Benchmark: scan")
        let tree = PageTree(w, pageCount: s.scanPages)
        let chunk = 8
        var start = 0
        while start < s.scanPages {
            let count = min(chunk, s.scanPages - start)
            let jpegs = Box([[UInt8]](repeating: [], count: count))
            let first = start
            DispatchQueue.concurrentPerform(iterations: count) { i in
                let j = jpeg(scanPixels(first + i + 1), scanWidth, scanHeight)
                jpegs.set(i, j)
            }
            for i in 0..<count {
                let image = w.addStream("/Type /XObject /Subtype /Image /Width \(scanWidth) /Height \(scanHeight) /ColorSpace /DeviceGray /BitsPerComponent 8 /Filter /DCTDecode",
                                        jpegs.values[i], compress: false)
                let content = w.addStream("", latin1("q 612 0 0 792 0 0 cm /Im0 Do Q"), compress: false)
                let p = start + i
                let page = w.add("<< /Type /Page /Parent \(tree.parentOf(p)) 0 R /MediaBox [0 0 612 792] /Resources << /XObject << /Im0 \(image) 0 R >> >> /Contents \(content) 0 R >>")
                tree.add(page)
            }
            start += count
            if start % 64 == 0 || start == s.scanPages { log("scan.pdf: \(start) of \(s.scanPages) pages") }
        }
        tree.write()
        let catalog = w.add("<< /Type /Catalog /Pages \(tree.rootId) 0 R >>")
        try w.finish(root: catalog, info: infoId, fileId: fileId("scan.pdf"))
    }

    // MARK: drawings.pdf

    static let sheetWidth = 2592.0, sheetHeight = 1728.0 // ARCH D in points
    private static let sheetWords = ["PLAN", "ELEVATION", "SECTION", "DETAIL", "SCHEDULE", "LAYOUT", "FRAMING", "FOUNDATION", "ROOF", "SITE"]
    private static let sheetWhere = ["NORTH WING", "SOUTH WING", "LEVEL 1", "LEVEL 2", "LEVEL 3", "BASEMENT", "EAST STAIR", "WEST STAIR", "PLANT ROOM", "LOBBY"]

    static func sheetTitle(_ n: Int) -> String {
        "A-\(100 + n)  \(sheetWords[(n * 3) % sheetWords.count]) \(sheetWords[(n * 7 + 1) % sheetWords.count]), \(sheetWhere[n % sheetWhere.count])"
    }

    static func sheetContent(_ sheetNo: Int, _ paths: Int) -> [UInt8] {
        var rng = Rng(104_729 &* UInt64(sheetNo) &+ 7)
        var s = ""
        s.reserveCapacity(paths * 40 + 4096)
        s += "0 G 1.5 w 36 36 \(f(sheetWidth - 72)) \(f(sheetHeight - 72)) re S\n0.85 G 0.25 w\n"
        for x in stride(from: 136, to: Int(sheetWidth) - 100, by: 100) { s += "\(x) 36 m \(x) \(f(sheetHeight - 36)) l S\n" }
        for y in stride(from: 136, to: Int(sheetHeight) - 100, by: 100) { s += "36 \(y) m \(f(sheetWidth - 36)) \(y) l S\n" }
        s += "0 G 1 w \(f(sheetWidth - 636)) 36 600 120 re S\n"
        s += "BT /F2 24 Tf \(f(sheetWidth - 616)) 110 Td \(PdfFileWriter.str(sheetTitle(sheetNo))) Tj ET\n"
        s += "BT /F3 12 Tf \(f(sheetWidth - 616)) 70 Td (Inkvolt PDF benchmark corpus  Sheet \(sheetNo) of the set  Scale 1:100  Not for construction) Tj ET\n"
        let x0 = 60.0, y0 = 180.0, x1 = sheetWidth - 60, y1 = sheetHeight - 60
        for i in 0..<paths {
            if i % 400 == 0 {
                if rng.next(4) == 0 {
                    s += "\(f(Double(rng.next(60)) / 100)) G "
                } else {
                    let r = Double(rng.next(70)) / 100, g = Double(rng.next(70)) / 100, b = Double(rng.next(70)) / 100
                    s += "\(f(r)) \(f(g)) \(f(b)) RG "
                }
                s += "\(f(0.25 + Double(rng.next(5)) * 0.25)) w\n"
            }
            var x = x0 + rng.nextDouble() * (x1 - x0)
            var y = y0 + rng.nextDouble() * (y1 - y0)
            let kind = rng.next(10)
            if kind < 6 {
                let len = 2 + rng.nextDouble() * 24
                let (dx, dy): (Double, Double) = switch rng.next(4) {
                case 0: (len, len)
                case 1: (len, -len)
                case 2: (len, 0)
                default: (0, len)
                }
                s += num(x) + " " + num(y) + " m " + num(x + dx) + " " + num(y + dy) + " l S\n"
            } else if kind < 9 {
                let count = 3 + rng.next(6)
                s += num(x) + " " + num(y) + " m"
                for _ in 1..<count {
                    x = min(max(x + (rng.nextDouble() - 0.5) * 80, x0), x1)
                    y = min(max(y + (rng.nextDouble() - 0.5) * 80, y0), y1)
                    s += " " + num(x) + " " + num(y) + " l"
                }
                s += " S\n"
            } else {
                let r = 2 + rng.nextDouble() * 28
                let k = 0.5523
                s += num(x + r) + " " + num(y) + " m "
                s += curve(x + r, y + k * r, x + k * r, y + r, x, y + r)
                s += curve(x - k * r, y + r, x - r, y + k * r, x - r, y)
                s += curve(x - r, y - k * r, x - k * r, y - r, x, y - r)
                s += curve(x + k * r, y - r, x + r, y - k * r, x + r, y)
                s += "h S\n"
            }
        }
        return latin1(s)
    }

    private static func curve(_ a: Double, _ b: Double, _ c: Double, _ d: Double, _ e: Double, _ g: Double) -> String {
        num(a) + " " + num(b) + " " + num(c) + " " + num(d) + " " + num(e) + " " + num(g) + " c "
    }

    /// A coordinate with one decimal ("123.4", "7"), rounded as .NET's Math.Round (to even).
    static func num(_ v: Double) -> String {
        var tenths = Int64((v * 10).rounded(.toNearestOrEven))
        var out = ""
        if tenths < 0 {
            out = "-"
            tenths = -tenths
        }
        out += String(tenths / 10)
        if tenths % 10 != 0 { out += "." + String(tenths % 10) }
        return out
    }

    private static func makeDrawings(_ path: String, _ s: Sizes, _ log: (String) -> Void) throws {
        let w = try PdfFileWriter(path: path)
        let infoId = info(w, "Benchmark: drawing set")
        let fontsId = w.add("<< \(fonts) >>")
        let resources = w.add("<< /Font \(fontsId) 0 R >>")
        let tree = PageTree(w, pageCount: s.drawingSheets)
        let chunk = max(1, min(8, ProcessInfo.processInfo.activeProcessorCount))
        var start = 0
        while start < s.drawingSheets {
            let count = min(chunk, s.drawingSheets - start)
            let streams = Box([[UInt8]](repeating: [], count: count))
            let first = start, paths = s.pathsPerSheet
            DispatchQueue.concurrentPerform(iterations: count) { i in
                streams.set(i, PdfFileWriter.deflate(sheetContent(first + i + 1, paths)))
            }
            for i in 0..<count {
                let content = w.addStream("/Filter /FlateDecode", streams.values[i], compress: false)
                let p = start + i
                let page = w.add("<< /Type /Page /Parent \(tree.parentOf(p)) 0 R /MediaBox [0 0 \(f(sheetWidth)) \(f(sheetHeight))] /Resources \(resources) 0 R /Contents \(content) 0 R >>")
                tree.add(page)
            }
            start += count
            if start % 40 == 0 || start == s.drawingSheets { log("drawings.pdf: \(start) of \(s.drawingSheets) sheets") }
        }
        tree.write()
        let catalog = w.add("<< /Type /Catalog /Pages \(tree.rootId) 0 R >>")
        try w.finish(root: catalog, info: infoId, fileId: fileId("drawings.pdf"))
    }

    // MARK: comments.pdf

    private static let authors = ["Ana Reviewer", "Ben Reviewer", "Chloe Reviewer", "Dev Reviewer", "Eva Reviewer", "Finn Reviewer"]

    private static func date(_ n: Int) -> String {
        String(format: "(D:2026%02d%02d%02d%02d00Z)", 1 + n / 44640 % 9, 1 + n / 1440 % 28, n / 60 % 24, n % 60)
    }

    private static func makeComments(_ path: String, _ s: Sizes) throws {
        var noteIcon = -1, helv = -1, serial = 0
        try writeTextDocument(path, pages: s.commentPages, title: "Benchmark: comments", idName: "comments.pdf") { w, page, p, lines in
            var ids: [Int] = []
            if noteIcon < 0 {
                noteIcon = w.addStream("/Type /XObject /Subtype /Form /BBox [0 0 20 20]",
                                       latin1("q 0.35 G 0.8 w 1 0.85 0.1 rg 1.5 6 m 1.5 18.5 l 18.5 18.5 l 18.5 6 l 9 6 l 5 1.5 l 6 6 l h B 0.3 G 1 w 5 15 m 15 15 l 5 12 m 15 12 l 5 9 m 12 9 l S Q"),
                                       compress: false)
                helv = w.add("<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>")
            }
            var rng = Rng(65_537 &* UInt64(p) &+ 3)
            var topLevel: [(id: Int, x: Double, top: Double)] = []
            let replies = max(0, s.commentsPerPage * 3 / 10)
            let topCount = s.commentsPerPage - replies
            for i in 0..<topCount {
                let n = serial
                serial += 1
                let author = authors[n % authors.count]
                let text = Prose.sentence(&rng)
                let line = lines[rng.next(lines.count)]
                let id = w.reserve()
                let popup = w.reserve()
                let common = "/Type /Annot /P \(page) 0 R /NM (bench-\(p)-\(i)) /T \(PdfFileWriter.str(author)) /Contents \(PdfFileWriter.str(text)) /M \(date(n)) /CreationDate \(date(n)) /F 4 /CA 1 /Popup \(popup) 0 R"
                var x1 = 0.0, y1 = 0.0, x2 = 0.0, y2 = 0.0
                switch i % 28 {
                case ..<8:
                    x1 = left + rng.nextDouble() * 400
                    y2 = line.y + 10
                    x2 = x1 + 20
                    y1 = y2 - 20
                    w.put(id, "<< \(common) /Subtype /Text /Name /Comment /Open false /Rect [\(f(x1)) \(f(y1)) \(f(x2)) \(f(y2))] /C [1 0.85 0.1] /AP << /N \(noteIcon) 0 R >> >>")
                case ..<14:
                    (x1, y1, x2, y2) = (line.x, line.y - 3, line.x + max(40, line.width), line.y + line.size * 0.8)
                    let ap = w.addStream("/Type /XObject /Subtype /Form /BBox [\(f(x1)) \(f(y1)) \(f(x2)) \(f(y2))] /Resources << /ExtGState << /GS << /BM /Multiply >> >> >>",
                                         latin1("/GS gs 1 0.85 0.1 rg \(f(x1)) \(f(y1)) \(f(x2 - x1)) \(f(y2 - y1)) re f"), compress: false)
                    w.put(id, "<< \(common) /Subtype /Highlight /Rect [\(f(x1)) \(f(y1)) \(f(x2)) \(f(y2))] /QuadPoints [\(f(x1)) \(f(y2)) \(f(x2)) \(f(y2)) \(f(x1)) \(f(y1)) \(f(x2)) \(f(y1))] /C [1 0.85 0.1] /AP << /N \(ap) 0 R >> >>")
                case ..<20:
                    let strike = i % 28 >= 17
                    (x1, y1, x2, y2) = (line.x, line.y - 3, line.x + max(40, line.width), line.y + line.size * 0.8)
                    let ly = strike ? (y1 + y2) / 2 : y1 + 1
                    let color = strike ? "0.9 0.1 0.1" : "0 0 1"
                    let ap = w.addStream("/Type /XObject /Subtype /Form /BBox [\(f(x1)) \(f(y1)) \(f(x2)) \(f(y2))]",
                                         latin1("\(color) RG 1 w \(f(x1)) \(f(ly)) m \(f(x2)) \(f(ly)) l S"), compress: false)
                    w.put(id, "<< \(common) /Subtype /\(strike ? "StrikeOut" : "Underline") /Rect [\(f(x1)) \(f(y1)) \(f(x2)) \(f(y2))] /QuadPoints [\(f(x1)) \(f(y2)) \(f(x2)) \(f(y2)) \(f(x1)) \(f(y1)) \(f(x2)) \(f(y1))] /C [\(color)] /AP << /N \(ap) 0 R >> >>")
                case ..<23:
                    let circle = p % 2 == 1
                    x1 = left + rng.nextDouble() * 300
                    y1 = 120 + rng.nextDouble() * 500
                    x2 = x1 + 60 + rng.nextDouble() * 120
                    y2 = y1 + 30 + rng.nextDouble() * 60
                    let ops: String
                    if circle {
                        let cx = (x1 + x2) / 2, cy = (y1 + y2) / 2, rx = (x2 - x1) / 2 - 1, ry = (y2 - y1) / 2 - 1, k = 0.5523
                        ops = "0.9 0.1 0.1 RG 2 w \(f(cx + rx)) \(f(cy)) m \(f(cx + rx)) \(f(cy + k * ry)) \(f(cx + k * rx)) \(f(cy + ry)) \(f(cx)) \(f(cy + ry)) c "
                            + "\(f(cx - k * rx)) \(f(cy + ry)) \(f(cx - rx)) \(f(cy + k * ry)) \(f(cx - rx)) \(f(cy)) c \(f(cx - rx)) \(f(cy - k * ry)) \(f(cx - k * rx)) \(f(cy - ry)) \(f(cx)) \(f(cy - ry)) c "
                            + "\(f(cx + k * rx)) \(f(cy - ry)) \(f(cx + rx)) \(f(cy - k * ry)) \(f(cx + rx)) \(f(cy)) c h S"
                    } else {
                        ops = "0.9 0.1 0.1 RG 2 w \(f(x1 + 1)) \(f(y1 + 1)) \(f(x2 - x1 - 2)) \(f(y2 - y1 - 2)) re S"
                    }
                    let ap = w.addStream("/Type /XObject /Subtype /Form /BBox [\(f(x1)) \(f(y1)) \(f(x2)) \(f(y2))]", latin1(ops), compress: false)
                    w.put(id, "<< \(common) /Subtype /\(circle ? "Circle" : "Square") /Rect [\(f(x1)) \(f(y1)) \(f(x2)) \(f(y2))] /C [0.9 0.1 0.1] /BS << /W 2 >> /AP << /N \(ap) 0 R >> >>")
                case ..<26:
                    var pts: [Double] = []
                    var x = left + rng.nextDouble() * 300
                    var y = 120 + rng.nextDouble() * 500
                    (x1, y1, x2, y2) = (x, y, x, y)
                    for _ in 0..<12 {
                        pts.append(x)
                        pts.append(y)
                        x += 4 + rng.nextDouble() * 10
                        y += (rng.nextDouble() - 0.5) * 16
                        (x1, y1, x2, y2) = (min(x1, x), min(y1, y), max(x2, x), max(y2, y))
                    }
                    (x1, y1, x2, y2) = (x1 - 2, y1 - 2, x2 + 2, y2 + 2)
                    let list = pts.map(f).joined(separator: " ")
                    var ops = "0 0 0.8 RG 2 w 1 J 1 j "
                    for k in stride(from: 0, to: pts.count, by: 2) { ops += "\(f(pts[k])) \(f(pts[k + 1])) \(k == 0 ? "m" : "l") " }
                    ops += "S"
                    let ap = w.addStream("/Type /XObject /Subtype /Form /BBox [\(f(x1)) \(f(y1)) \(f(x2)) \(f(y2))]", latin1(ops), compress: false)
                    w.put(id, "<< \(common) /Subtype /Ink /Rect [\(f(x1)) \(f(y1)) \(f(x2)) \(f(y2))] /InkList [[\(list)]] /C [0 0 0.8] /BS << /W 2 >> /AP << /N \(ap) 0 R >> >>")
                default:
                    x1 = left + rng.nextDouble() * 250
                    y1 = 120 + rng.nextDouble() * 500
                    x2 = x1 + 180
                    y2 = y1 + 40
                    let shown = text.count > 30 ? String(text.prefix(30)) : text
                    let ap = w.addStream("/Type /XObject /Subtype /Form /BBox [\(f(x1)) \(f(y1)) \(f(x2)) \(f(y2))] /Resources << /Font << /Helv \(helv) 0 R >> >>",
                                         latin1("1 1 0.8 rg 0 G 1 w \(f(x1 + 0.5)) \(f(y1 + 0.5)) 179 39 re B BT /Helv 10 Tf 0 g \(f(x1 + 4)) \(f(y2 - 14)) Td \(PdfFileWriter.str(shown)) Tj ET"),
                                         compress: false)
                    w.put(id, "<< \(common) /Subtype /FreeText /DA (/Helv 10 Tf 0 g) /Rect [\(f(x1)) \(f(y1)) \(f(x2)) \(f(y2))] /C [1 1 0.8] /AP << /N \(ap) 0 R >> >>")
                }
                let px = min(x2 + 10, 420), py = max(y2 - 120, 40)
                w.put(popup, "<< /Type /Annot /Subtype /Popup /Parent \(id) 0 R /Open false /Rect [\(f(px)) \(f(py)) \(f(px + 180)) \(f(py + 120))] >>")
                ids.append(id)
                ids.append(popup)
                topLevel.append((id, x1, y2))
            }
            for r in 0..<replies {
                let n = serial
                serial += 1
                let parent = topLevel[r % topLevel.count]
                let author = authors[(n + 3) % authors.count]
                let text = Prose.sentence(&rng)
                let id = w.add("<< /Type /Annot /Subtype /Text /P \(page) 0 R /NM (bench-\(p)-r\(r)) /IRT \(parent.id) 0 R /RT /R /Name /Comment /T \(PdfFileWriter.str(author)) "
                               + "/Contents \(PdfFileWriter.str(text)) /M \(date(n)) /CreationDate \(date(n)) /F 28 /CA 1 /Rect [\(f(parent.x)) \(f(parent.top - 20)) \(f(parent.x + 20)) \(f(parent.top))] /C [1 0.85 0.1] /AP << /N \(noteIcon) 0 R >> >>")
                ids.append(id)
            }
            return ids
        }
    }

    /// .NET's `Math.Round(v, 2).ToString("0.##")`: two decimals at most, rounded to even, no trailing zeros.
    static func f(_ v: Double) -> String {
        let r = (v * 100).rounded(.toNearestOrEven) / 100
        var s = String(format: "%.2f", r)
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s == "-0" ? "0" : s
    }
}

/// Results written from `concurrentPerform`'s threads, each to its own slot.
final class Box<T>: @unchecked Sendable {
    private(set) var values: T
    private let lock = NSLock()
    init(_ v: T) { values = v }
}

extension Box where T == [[UInt8]] {
    func set(_ i: Int, _ v: [UInt8]) {
        lock.lock()
        values[i] = v
        lock.unlock()
    }
}

/// xorshift64*: small, fast, and the same everywhere (Windows' `Rng`).
struct Rng {
    private var s: UInt64
    init(_ seed: UInt64) { s = seed == 0 ? 0x9E37_79B9_7F4A_7C15 : seed }

    mutating func nextRaw() -> UInt64 {
        s ^= s >> 12
        s ^= s << 25
        s ^= s >> 27
        return s &* 0x2545_F491_4F6C_DD1D
    }

    mutating func next(_ n: Int) -> Int { Int(nextRaw() % UInt64(n)) }

    mutating func nextDouble() -> Double { Double(nextRaw() >> 11) * (1.0 / Double(UInt64(1) << 53)) }
}

/// Made-up English prose from a word bank ("lantern", the search target, is in it): Windows' `Prose`.
enum Prose {
    static let words = [
        "the", "a", "and", "of", "to", "in", "that", "with", "for", "on", "by", "from", "as", "at", "but", "not", "this", "which", "or", "an",
        "river", "lantern", "harbor", "window", "meadow", "ledger", "engine", "bridge", "garden", "letter", "market", "valley", "signal", "copper",
        "quarry", "orchard", "compass", "granite", "thunder", "candle", "willow", "saddle", "anchor", "barrel", "beacon", "canvas", "cellar",
        "chapel", "cobble", "cotton", "dagger", "ember", "falcon", "fossil", "furnace", "glacier", "hammer", "harvest", "hollow", "island",
        "jacket", "kettle", "lumber", "marble", "mirror", "needle", "oyster", "parcel", "pillar", "pocket", "quiver", "ribbon", "rudder",
        "shadow", "silver", "spring", "stable", "summit", "tunnel", "turret", "velvet", "wagon", "walnut", "whistle", "winter", "yonder",
        "walks", "turns", "carries", "builds", "finds", "holds", "keeps", "leaves", "meets", "opens", "reads", "sends", "stands", "takes",
        "waits", "writes", "measures", "returns", "follows", "answers", "gathers", "crosses", "remains", "settles", "remembers", "counts",
        "quiet", "early", "narrow", "steady", "bright", "distant", "hollow", "patient", "simple", "sudden", "little", "broad", "plain",
        "heavy", "gentle", "ancient", "careful", "common", "eager", "formal", "honest", "modest", "narrow", "proper", "rough", "sharp",
        "slowly", "often", "again", "almost", "rather", "nearly", "still", "already", "perhaps", "later", "before", "after", "between",
        "morning", "evening", "season", "village", "country", "station", "journey", "history", "minute", "moment", "number", "reason",
        "weather", "account", "balance", "chapter", "company", "council", "customs", "deposit", "freight", "invoice", "manager", "meeting",
        "notice", "office", "payment", "project", "record", "report", "request", "schedule", "service", "summary", "survey", "ticket",
    ]

    private static func capital(_ w: String) -> String { w.prefix(1).uppercased() + w.dropFirst() }

    static func sentence(_ rng: inout Rng) -> String {
        let n = 6 + rng.next(11)
        var s = ""
        for i in 0..<n {
            var w = words[rng.next(words.count)]
            if i == 0 { w = capital(w) }
            if i > 0 { s += i == n / 2 && rng.next(3) == 0 ? ", " : " " }
            s += w
        }
        return s + "."
    }

    static func paragraph(_ rng: inout Rng) -> String {
        let n = 3 + rng.next(5)
        var s = ""
        for i in 0..<n { s += (i > 0 ? " " : "") + sentence(&rng) }
        return s
    }

    static func title(_ rng: inout Rng) -> String {
        let n = 2 + rng.next(3)
        var parts: [String] = []
        for _ in 0..<n { parts.append(capital(words[20 + rng.next(words.count - 20)])) }
        return parts.joined(separator: " ")
    }

    /// Greedy word wrap to at most `maxChars` per line.
    static func wrap(_ text: String, _ maxChars: Int) -> [String] {
        var out: [String] = []
        var line = ""
        for word in text.split(separator: " ", omittingEmptySubsequences: false) {
            if !line.isEmpty && line.count + 1 + word.count > maxChars {
                out.append(line)
                line = ""
            }
            if !line.isEmpty { line += " " }
            line += word
        }
        if !line.isEmpty { out.append(line) }
        return out
    }
}
