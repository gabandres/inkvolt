import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
@testable import PdfCore

// The OCR corpus's generator and its measure (the Windows app's pdf/tools/ocr-corpus: ScanCorpus.cs, WordErrorRate.cs),
// ported for the tests: made-up prose in English and Spanish, typeset in a standard font, rendered at 300 dpi by MuPDF
// (its built-in fonts), then "scanned": turned on the glass, skewed 3-10°, softened, put on uneven paper, given noise and
// specks, and saved as a JPEG in a PDF. The same seeded generator (`Rng`, .NET's bench one) gives the same skews, turns
// and words as on Windows. Adapted: the PDFs are written by `CorpusPdf` and the JPEG by ImageIO (Windows has its own
// writer and encoder), so the files' bytes and SHA-256s differ from the ones in RESULTS.md; the pages' pixels before
// the JPEG come from the same MuPDF and the same steps.

/// A xorshift generator, .NET's `InkvoltPdf.Bench.Rng`, so the corpus draws the same numbers.
struct Rng {
    fileprivate var s: UInt64

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

/// One file of the OCR corpus: its language, how its pages were "scanned" (skew range in degrees, both signs; paper
/// noise as a standard deviation in grey levels; dark specks per page; how much darker one side of the page is), and how
/// each page lies on the glass (quarter turns clockwise; none for most files).
struct CorpusFile {
    var name: String, language: String, font: String, fontSize: Double, minSkew: Double, maxSkew: Double
    var noise: Double, specks: Int, shading: Int
    var turns: [Int]? = nil
    var pages = 2
}

/// A generated page: its words in reading order (the ground truth) and how it was put on the glass.
struct CorpusPage {
    var words: [String]
    var skew: Double
    var turns: Int
}

enum ScanCorpus {
    static let dpi = 300

    static let files: [CorpusFile] = [
        CorpusFile(name: "en-skew3-light", language: "en", font: "/Times-Roman", fontSize: 11, minSkew: 3, maxSkew: 4, noise: 8, specks: 150, shading: 10),
        CorpusFile(name: "en-skew6-noisy", language: "en", font: "/Helvetica", fontSize: 10, minSkew: 5, maxSkew: 7, noise: 26, specks: 1500, shading: 0),
        CorpusFile(name: "en-skew10-shaded", language: "en", font: "/Times-Roman", fontSize: 10, minSkew: 8.5, maxSkew: 10, noise: 14, specks: 400, shading: 60),
        CorpusFile(name: "es-skew4-noisy", language: "es", font: "/Helvetica", fontSize: 11, minSkew: 3.5, maxSkew: 5, noise: 24, specks: 1200, shading: 0),
        CorpusFile(name: "es-skew8-shaded", language: "es", font: "/Times-Roman", fontSize: 11, minSkew: 7, maxSkew: 9, noise: 14, specks: 400, shading: 50),
        CorpusFile(name: "en-turned", language: "en", font: "/Times-Roman", fontSize: 11, minSkew: 3, maxSkew: 5, noise: 12, specks: 300, shading: 20, turns: [2, 1]),
    ]

    static func file(_ name: String) -> CorpusFile { files.first { $0.name == name }! }

    /// Pages and files already made in this test run (making one takes seconds in a debug build): made once, under the
    /// lock, so tests running side by side don't make the same page twice.
    private static let lock = NSLock()
    nonisolated(unsafe) private static var madePages: [String: (pixels: [UInt8], width: Int, height: Int, truth: CorpusPage)] = [:]
    nonisolated(unsafe) private static var madeFiles: [String: (pdf: [UInt8], pages: [CorpusPage])] = [:]

    /// The scanned PDF and each page's ground truth.
    static func make(_ file: CorpusFile) throws -> (pdf: [UInt8], pages: [CorpusPage]) {
        lock.lock()
        defer { lock.unlock() }
        let key = "\(file.name)/\(file.pages)"
        if let made = madeFiles[key] { return made }
        let made = try makeFile(file)
        madeFiles[key] = made
        return made
    }

    private static func makeFile(_ file: CorpusFile) throws -> (pdf: [UInt8], pages: [CorpusPage]) {
        let (text, lines) = textPdf(file)
        let engine = try PdfEngine.open(text)
        defer { engine.close() }
        var pages: [CorpusPage] = []
        var jpegs: [(jpeg: [UInt8], width: Int, height: Int)] = []
        for p in 0..<file.pages {
            let (pixels, width, height, truth) = try scanPage(file, engine, lines, p)
            jpegs.append((try jpeg(pixels, width, height), width, height))
            pages.append(truth)
        }
        return (scanPdf(file, jpegs), pages)
    }

    /// One page as scanned (grey, before the JPEG), and its truth.
    static func makePage(_ file: CorpusFile, _ page: Int) throws -> (pixels: [UInt8], width: Int, height: Int, truth: CorpusPage) {
        lock.lock()
        defer { lock.unlock() }
        let key = "\(file.name)#\(page)"
        if let made = madePages[key] { return made }
        let (text, lines) = textPdf(file)
        let engine = try PdfEngine.open(text)
        defer { engine.close() }
        let made = try scanPage(file, engine, lines, page)
        madePages[key] = made
        return made
    }

    private static func scanPage(_ file: CorpusFile, _ engine: PdfEngine, _ lines: [[String]], _ p: Int) throws
        -> (pixels: [UInt8], width: Int, height: Int, truth: CorpusPage) {
        var rng = Rng(seed(file.name) &+ 977 &* UInt64(p + 1))
        let turns = file.turns.flatMap { p < $0.count ? $0[p] : nil } ?? 0
        let skew = ((file.minSkew + (file.maxSkew - file.minSkew) * rng.nextDouble()) * (p % 2 == 0 ? 1 : -1) * 100).rounded(.toNearestOrEven) / 100
        let gray = try grayPage(engine, p)
        let (pixels, width, height) = scan(gray.pixels, gray.width, gray.height, file, turns, skew, &rng)
        return (pixels, width, height, CorpusPage(words: lines[p].flatMap { $0.split(separator: " ").map(String.init) }, skew: skew, turns: turns))
    }

    private static func grayPage(_ engine: PdfEngine, _ p: Int) throws -> GrayImage {
        let img = try engine.render(p, scale: Double(dpi) / 72)
        return GrayImage(img.width, img.height, ScanCleanup.toGray(img.pixels, img.width, img.height))
    }

    /// A page as the scanner would see it: `turns` quarter turns clockwise, then skewed, softened, on uneven paper, noisy,
    /// specked.
    static func scan(_ gray: [UInt8], _ width: Int, _ height: Int, _ file: CorpusFile, _ turns: Int, _ skew: Double, _ rng: inout Rng)
        -> (pixels: [UInt8], width: Int, height: Int) {
        var (px, tw, th) = (gray, width, height)
        for _ in 0..<(((turns % 4) + 4) % 4) { (px, tw, th) = (turnClockwise(px, tw, th), th, tw) }
        let (w, h) = (tw, th)
        px = PageRotate.rotate(px, w, h, w, 1, skew)

        // Softened as a scanner's optics do: a 3 × 3 blur, the centre weighted (rows side by side: the debug build the
        // tests run in is slow per pixel).
        var soft = [UInt8](repeating: 0, count: px.count)
        px.withUnsafeBufferPointer { buffer in
            let input = Shared(buffer)
            soft.withUnsafeMutableBufferPointer { dst in
                let out = Shared(dst)
                DispatchQueue.concurrentPerform(iterations: h) { y in
                    for x in 0..<w {
                        if x > 0 && y > 0 && x < w - 1 && y < h - 1 {
                            let (up, here, down) = ((y - 1) * w + x, y * w + x, (y + 1) * w + x)
                            let corners = Int(input.p[up - 1]) + Int(input.p[up + 1]) + Int(input.p[down - 1]) + Int(input.p[down + 1])
                            let sides = Int(input.p[up]) + Int(input.p[down]) + Int(input.p[here - 1]) + Int(input.p[here + 1])
                            out.p[here] = UInt8((4 * Int(input.p[here]) + 2 * sides + corners) / 16)
                            continue
                        }
                        var sum = 0, weight = 0
                        for dy in -1...1 where y + dy >= 0 && y + dy < h {
                            for dx in -1...1 where x + dx >= 0 && x + dx < w {
                                let k = dx == 0 && dy == 0 ? 4 : dx == 0 || dy == 0 ? 2 : 1
                                sum += Int(input.p[(y + dy) * w + x + dx]) * k
                                weight += k
                            }
                        }
                        out.p[y * w + x] = UInt8(sum / weight)
                    }
                }
            }
        }

        // Paper: off-white, darker towards one side (a lid's shadow, grey recycled paper), ink never quite black; then noise.
        let paper = 236 - rng.next(8)
        let side = rng.next(2)
        let (wd, hd, shading, noiseLevel) = (Double(w), Double(h), Double(file.shading), file.noise)
        // Two draws a pixel, in row order: each row starts from the generator's state there, so rows can run side by side
        // and still draw the numbers they drew one after another.
        var starts = [UInt64](repeating: 0, count: h)
        var state = rng.s
        for y in 0..<h {
            starts[y] = state
            for _ in 0..<(2 * w) {
                state ^= state >> 12
                state ^= state << 25
                state ^= state >> 27
            }
        }
        rng.s = state
        let inv53 = 1.0 / Double(UInt64(1) << 53)
        soft.withUnsafeMutableBufferPointer { dst in
            let out = Shared(dst)
            starts.withUnsafeBufferPointer { buffer in
                let st = Shared(buffer)
                DispatchQueue.concurrentPerform(iterations: h) { y in
                    var s = st.p[y]
                    for x in 0..<w {
                        let along = side == 0 ? Double(x) / wd : Double(y) / hd
                        let level = Double(paper) - shading * along * along
                        s ^= s >> 12
                        s ^= s << 25
                        s ^= s >> 27
                        let u = max(1e-12, Double((s &* 0x2545_F491_4F6C_DD1D) >> 11) * inv53)
                        s ^= s >> 12
                        s ^= s << 25
                        s ^= s >> 27
                        let t = Double((s &* 0x2545_F491_4F6C_DD1D) >> 11) * inv53
                        let noise = (-2 * log(u)).squareRoot() * cos(2 * .pi * t)
                        let v = 22 + (level - 22) * Double(out.p[y * w + x]) / 255 + noise * noiseLevel
                        out.p[y * w + x] = UInt8(min(max(v.rounded(.toNearestOrEven), 0), 255))
                    }
                }
            }
        }

        // Dust and toner specks: small dark dots, a few short hairs.
        for _ in 0..<file.specks {
            let (cx, cy) = (rng.next(w), rng.next(h))
            let r = 0.8 + rng.nextDouble() * 1.8
            let tone = 20 + rng.next(90)
            let hair = rng.next(20) == 0
            var (dx, dy) = (0.0, 0.0)
            if hair {
                dx = cos(rng.nextDouble() * .pi)
                dy = sin(rng.nextDouble() * .pi)
            }
            let length = hair ? 8 + rng.next(20) : 0
            for s in 0...length {
                let (sx, sy) = (Double(cx) + dx * Double(s), Double(cy) + dy * Double(s))
                for y in Int(sy - r)...Int(sy + r) {
                    for x in Int(sx - r)...Int(sx + r)
                        where x >= 0 && y >= 0 && x < w && y < h && (Double(x) - sx) * (Double(x) - sx) + (Double(y) - sy) * (Double(y) - sy) <= r * r {
                        soft[y * w + x] = min(soft[y * w + x], UInt8(tone))
                    }
                }
            }
        }
        return (soft, w, h)
    }

    static func turnClockwise(_ px: [UInt8], _ w: Int, _ h: Int) -> [UInt8] { ScanCleanup.turn(px, w, h, 1, 1) }

    static func sha256(_ data: [UInt8]) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    private static func seed(_ name: String) -> UInt64 {
        let h = Array(SHA256.hash(data: Array("inkvolt-ocr-\(name)".utf8)))
        return (0..<8).reduce(UInt64(0)) { $0 | UInt64(h[$1]) << (8 * UInt64($1)) } // BitConverter.ToUInt64: little-endian
    }

    /// A normal distribution's sample (Box-Muller), mean 0, standard deviation 1.
    private static func gaussian(_ rng: inout Rng) -> Double {
        let u = max(1e-12, rng.nextDouble())
        return (-2 * log(u)).squareRoot() * cos(2 * .pi * rng.nextDouble())
    }

    private static func jpeg(_ gray: [UInt8], _ w: Int, _ h: Int) throws -> [UInt8] {
        let data = NSMutableData()
        guard let provider = CGDataProvider(data: Data(gray) as CFData),
              let image = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(),
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue), provider: provider, decode: nil,
                                  shouldInterpolate: false, intent: .defaultIntent),
              let dest = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil) else { throw PdfEngineError(message: "JPEG") }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.7] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw PdfEngineError(message: "JPEG") }
        return [UInt8](data as Data)
    }

    // ---- the typeset text ----

    private static let left = 72.0, top = 720.0, textWidth = 468.0

    /// The clean text pages: a heading in Helvetica-Bold, then paragraphs in the file's font, wrapped by an estimated glyph
    /// width (on the wide side, so no line runs off the page); with each page's lines.
    private static func textPdf(_ file: CorpusFile) -> (pdf: [UInt8], lines: [[String]]) {
        var rng = Rng(seed(file.name))
        var lines: [[String]] = []
        let fonts = "/F1 << /Type /Font /Subtype /Type1 /BaseFont \(file.font) /Encoding /WinAnsiEncoding >> "
            + "/F2 << /Type /Font /Subtype /Type1 /BaseFont /Helvetica-Bold /Encoding /WinAnsiEncoding >>"
        let bank = file.language == "es" ? spanish : english
        let leading = file.fontSize * 1.4
        let maxChars = Int(textWidth / (file.fontSize * (file.font == "/Helvetica" ? 0.56 : 0.50)))
        var writer = CorpusPdf()
        var kids: [Int] = []
        let parent = writer.reserve()
        for _ in 0..<file.pages {
            var pageLines: [String] = []
            var ops = ""
            let heading = title(bank, &rng)
            ops += "BT /F2 16 Tf \(n(left)) \(n(top)) Td \(str(heading)) Tj ET\n"
            pageLines.append(heading)
            var y = top - 34
            while y > 90 {
                for line in wrap(paragraph(bank, &rng), maxChars) {
                    if y <= 90 { break }
                    ops += "BT /F1 \(n(file.fontSize)) Tf \(n(left)) \(n2(y)) Td \(str(line)) Tj ET\n"
                    pageLines.append(line)
                    y -= leading
                }
                y -= leading * 0.6
            }
            lines.append(pageLines)
            let content = writer.addStream("", latin1Bytes(ops))
            kids.append(writer.add("<< /Type /Page /Parent \(parent) 0 R /MediaBox [0 0 612 792] /Resources << /Font << \(fonts) >> >> /Contents \(content) 0 R >>"))
        }
        writer.put(parent, "<< /Type /Pages /Kids [\(kids.map { "\($0) 0 R" }.joined(separator: " "))] /Count \(kids.count) >>")
        let catalog = writer.add("<< /Type /Catalog /Pages \(parent) 0 R >>")
        return (writer.finish(catalog), lines)
    }

    private static func scanPdf(_ file: CorpusFile, _ pages: [(jpeg: [UInt8], width: Int, height: Int)]) -> [UInt8] {
        var writer = CorpusPdf()
        let parent = writer.reserve()
        var kids: [Int] = []
        for (jpeg, width, height) in pages {
            let (pw, ph) = (Double(width) * 72 / Double(dpi), Double(height) * 72 / Double(dpi))
            let image = writer.addStream("/Type /XObject /Subtype /Image /Width \(width) /Height \(height) /ColorSpace /DeviceGray /BitsPerComponent 8 /Filter /DCTDecode", jpeg)
            let content = writer.addStream("", Array("q \(n2(pw)) 0 0 \(n2(ph)) 0 0 cm /Im0 Do Q".utf8))
            kids.append(writer.add("<< /Type /Page /Parent \(parent) 0 R /MediaBox [0 0 \(n2(pw)) \(n2(ph))] /Resources << /XObject << /Im0 \(image) 0 R >> >> /Contents \(content) 0 R >>"))
        }
        writer.put(parent, "<< /Type /Pages /Kids [\(kids.map { "\($0) 0 R" }.joined(separator: " "))] /Count \(kids.count) >>")
        let catalog = writer.add("<< /Type /Catalog /Pages \(parent) 0 R >>")
        return writer.finish(catalog)
    }

    /// .NET's default number text: no trailing zeros.
    private static func n(_ v: Double) -> String { v == v.rounded() ? String(Int(v)) : String(v) }

    /// .NET's "0.##".
    private static func n2(_ v: Double) -> String { PdfNum.f2(v) }

    /// A PDF literal string in WinAnsi (Latin-1 covers every letter in the word banks).
    private static func str(_ s: String) -> String {
        "(" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "(", with: "\\(").replacingOccurrences(of: ")", with: "\\)") + ")"
    }

    private static func capitalized(_ w: String) -> String { w.prefix(1).uppercased() + w.dropFirst() }

    private static func title(_ bank: [String], _ rng: inout Rng) -> String {
        var parts: [String] = []
        var i = 2 + rng.next(3)
        while i > 0 {
            parts.append(capitalized(bank[12 + rng.next(bank.count - 12)]))
            i -= 1
        }
        return parts.joined(separator: " ")
    }

    private static func paragraph(_ bank: [String], _ rng: inout Rng) -> String {
        var sb = ""
        var s = 3 + rng.next(4)
        while s > 0 {
            if !sb.isEmpty { sb += " " }
            let n = 6 + rng.next(10)
            for i in 0..<n {
                var word = rng.next(14) == 0 ? number(&rng) : bank[rng.next(bank.count)]
                if i == 0 { word = capitalized(word) }
                if i > 0 { sb += i == n / 2 && rng.next(3) == 0 ? ", " : " " }
                sb += word
            }
            sb += "."
            s -= 1
        }
        return sb
    }

    /// A number as documents have them: a count, an amount, a reference, a year.
    private static func number(_ rng: inout Rng) -> String {
        switch rng.next(4) {
        case 0: return String(2 + rng.next(98))
        case 1:
            let whole = 10 + rng.next(990)
            return "\(whole).\(String(format: "%02d", rng.next(100)))"
        case 2: return String(1000 + rng.next(9000))
        default: return String(1990 + rng.next(40))
        }
    }

    private static func wrap(_ text: String, _ maxChars: Int) -> [String] {
        var out: [String] = []
        var line = ""
        for word in text.split(separator: " ", omittingEmptySubsequences: false).map(String.init) {
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

    // The first 12 words of each bank are short function words, left out of headings.
    private static let english = [
        "the", "a", "and", "of", "to", "in", "that", "with", "for", "on", "by", "from",
        "river", "lantern", "harbor", "window", "meadow", "ledger", "engine", "bridge", "garden", "letter", "market", "valley",
        "signal", "copper", "quarry", "orchard", "compass", "granite", "thunder", "candle", "willow", "saddle", "anchor",
        "barrel", "beacon", "canvas", "cellar", "chapel", "cotton", "falcon", "fossil", "furnace", "glacier", "hammer",
        "harvest", "island", "jacket", "kettle", "lumber", "marble", "mirror", "needle", "parcel", "pillar", "pocket",
        "ribbon", "shadow", "silver", "spring", "stable", "summit", "tunnel", "velvet", "wagon", "walnut", "winter",
        "walks", "turns", "carries", "builds", "finds", "holds", "keeps", "leaves", "meets", "opens", "reads", "sends",
        "stands", "takes", "waits", "writes", "measures", "returns", "follows", "answers", "gathers", "crosses", "remains",
        "quiet", "early", "narrow", "steady", "bright", "distant", "patient", "simple", "sudden", "little", "broad", "plain",
        "heavy", "gentle", "ancient", "careful", "common", "eager", "formal", "honest", "modest", "proper", "rough", "sharp",
        "slowly", "often", "again", "almost", "rather", "nearly", "still", "already", "perhaps", "later", "before", "after",
        "morning", "evening", "season", "village", "country", "station", "journey", "history", "minute", "moment", "number",
        "weather", "account", "balance", "chapter", "company", "council", "deposit", "freight", "invoice", "manager",
        "notice", "office", "payment", "project", "record", "report", "request", "schedule", "service", "summary", "ticket",
    ]

    private static let spanish = [
        "el", "la", "de", "que", "y", "en", "un", "una", "los", "las", "por", "con",
        "año", "niño", "señal", "mañana", "montaña", "pequeño", "español", "compañía", "diseño", "otoño", "sueño", "baño",
        "canción", "información", "corazón", "nación", "estación", "reunión", "camión", "razón", "lección", "atención",
        "después", "también", "además", "jamás", "quizás", "allá", "está", "están", "será", "habrá", "tendrá", "podrá",
        "página", "público", "número", "último", "rápido", "teléfono", "música", "método", "árbol", "lápiz", "fácil", "difícil",
        "ciudad", "puerta", "ventana", "camino", "río", "mesa", "libro", "carta", "cuenta", "factura", "oficina", "informe",
        "mercado", "puente", "jardín", "invierno", "verano", "tiempo", "semana", "pueblo", "campo", "viaje", "historia",
        "guarda", "lleva", "abre", "cierra", "envía", "recibe", "escribe", "lee", "cruza", "espera", "cuenta", "vuelve",
        "sigue", "encuentra", "construye", "mide", "reúne", "queda", "trae", "busca", "piensa", "pregunta", "responde",
        "tranquilo", "temprano", "estrecho", "brillante", "lejano", "paciente", "sencillo", "repentino", "antiguo",
        "cuidadoso", "común", "honesto", "modesto", "pesado", "suave", "amplio", "claro", "oscuro", "nuevo", "viejo",
        "despacio", "siempre", "nunca", "todavía", "casi", "pronto", "tarde", "antes", "entre", "hacia", "según", "sobre",
        "acción", "artículo", "crédito", "depósito", "envío", "garantía", "período", "propósito", "próximo", "régimen",
        "pingüino", "vergüenza", "cigüeña", "acuífero", "exhibición", "electrónico", "económico", "político", "técnico",
    ]
}

/// A buffer the rows of one pass read or write side by side, each its own pixels.
private struct Shared<T>: @unchecked Sendable {
    let p: T
    init(_ p: T) { self.p = p }
}

/// A PDF written object by object (the bench's `PdfFileWriter`, the little the corpus needs).
struct CorpusPdf {
    private var objects: [Int: [UInt8]] = [:]
    private var count = 0

    mutating func reserve() -> Int {
        count += 1
        return count
    }

    mutating func put(_ n: Int, _ body: String) { objects[n] = latin1Bytes(body) }

    mutating func add(_ body: String) -> Int {
        let n = reserve()
        put(n, body)
        return n
    }

    mutating func addStream(_ dict: String, _ data: [UInt8]) -> Int {
        let n = reserve()
        objects[n] = latin1Bytes("<< \(dict) /Length \(data.count) >>\nstream\n") + data + Array("\nendstream".utf8)
        return n
    }

    func finish(_ catalog: Int) -> [UInt8] {
        var out = Array("%PDF-1.7\n%\u{e2}\u{e3}\n".utf8)
        var offsets = [Int](repeating: 0, count: count + 1)
        for n in 1...count {
            offsets[n] = out.count
            out += Array("\(n) 0 obj\n".utf8) + (objects[n] ?? Array("null".utf8)) + Array("\nendobj\n".utf8)
        }
        let xref = out.count
        var table = "xref\n0 \(count + 1)\n0000000000 65535 f \n"
        for n in 1...count { table += String(format: "%010d 00000 n \n", offsets[n]) }
        table += "trailer\n<< /Size \(count + 1) /Root \(catalog) 0 R >>\nstartxref\n\(xref)\n%%EOF\n"
        return out + Array(table.utf8)
    }
}

/// Word error rate: the fewest words to substitute, delete or insert to turn the recognized text into the true text (a
/// Levenshtein distance over words), divided by the number of true words. Words are compared exactly, accents, case and
/// punctuation included, as a search would see them. 0 is perfect; above 1 is possible (many extra words).
enum WordErrorRate {
    static func of(_ truth: [String], _ recognized: [String]) -> Double {
        truth.isEmpty ? (recognized.isEmpty ? 0 : 1) : Double(edits(truth, recognized)) / Double(truth.count)
    }

    static func edits(_ truth: [String], _ recognized: [String]) -> Int {
        var previous = Array(0...recognized.count)
        var current = [Int](repeating: 0, count: recognized.count + 1)
        for i in stride(from: 1, through: truth.count, by: 1) {
            current[0] = i
            for j in stride(from: 1, through: recognized.count, by: 1) {
                let substitute = previous[j - 1] + (truth[i - 1] == recognized[j - 1] ? 0 : 1)
                current[j] = min(substitute, min(previous[j] + 1, current[j - 1] + 1))
            }
            swap(&previous, &current)
        }
        return previous[recognized.count]
    }

    /// The words of a recognized text, split on white space.
    static func words(_ text: String) -> [String] { text.split(whereSeparator: \.isWhitespace).map(String.init) }
}
