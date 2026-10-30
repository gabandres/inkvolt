import Foundation

/// What `Optimizer.optimize` does besides rewriting the file.
public struct OptimizeOptions: Equatable, Sendable {
    /// Flate-compress streams stored uncompressed (or only ASCII/LZW-encoded).
    public var compressStreams = true
    /// Keep one copy of byte-identical streams (fonts, images, ...) and point every use at it.
    public var deduplicateStreams = true
    /// Remove XMP metadata packets (the document's properties, the title, author and so on, stay).
    public var removeMetadata = false
    /// Remove embedded page thumbnails (viewers draw their own).
    public var removeThumbnails = true
    /// Remove application private data (/PieceInfo, e.g. Illustrator's editing copy of the page).
    public var removePieceInfo = true
    /// Images shown at more than this resolution are downsampled to it (and stored as JPEG); nil = keep.
    public var maxImageDpi: Double? = 150
    /// JPEG quality (1-100) of downsampled images.
    public var jpegQuality = 75

    public init(compressStreams: Bool = true, deduplicateStreams: Bool = true, removeMetadata: Bool = false, removeThumbnails: Bool = true,
                removePieceInfo: Bool = true, maxImageDpi: Double? = 150, jpegQuality: Int = 75) {
        self.compressStreams = compressStreams
        self.deduplicateStreams = deduplicateStreams
        self.removeMetadata = removeMetadata
        self.removeThumbnails = removeThumbnails
        self.removePieceInfo = removePieceInfo
        self.maxImageDpi = maxImageDpi
        self.jpegQuality = jpegQuality
    }
}

/// What `Optimizer.optimize` produced. The output can come out larger (a file already compact): compare the sizes before
/// replacing the original.
public struct OptimizeResult: Sendable {
    public var data: [UInt8]
    public var sizeBefore: Int
    public var sizeAfter: Int
    public var streamsCompressed: Int
    public var duplicatesRemoved: Int
    public var imagesDownsampled: Int

    public var saved: Int { sizeBefore - sizeAfter }

    /// At least 1% (and 1 KB) smaller: savings under that (or a bigger file) aren't worth a rewrite.
    public var isWorthIt: Bool { saved >= max(1024, sizeBefore / 100) }
}

/// Reduces file size (the Windows app's `Optimizer`). Always a full rewrite, which by itself drops unreferenced objects
/// and earlier incremental revisions; then, as `OptimizeOptions` asks: identical streams merged, uncompressed streams
/// Flate-compressed, thumbnails / private data / XMP removed, and images shown above a resolution downsampled to it as
/// JPEG. Images are decoded and resampled by MuPDF (a one-image page rendered at the target size, so every filter it
/// reads works), limited to 8-bit DeviceGray/RGB/CMYK (or ICC-based) images without a color-key /Mask; their soft mask
/// is resampled too (kept lossless). An image's resolution is judged from where page content and form XObjects draw it
/// (largest use wins); images drawn only elsewhere (patterns, annotations, Type 3 glyphs) are left alone. Signed
/// documents need the caller's consent (`SignedEdits.run` with the rewrite allowed), as the rewrite invalidates their
/// signatures. An encrypted document (opened with its owner password) keeps its protection.
public enum Optimizer {
    /// - Throws: `SignaturesWouldBreak` when the document is signed and the rewrite wasn't allowed; `OwnerPasswordRequired`.
    public static func optimize(_ data: [UInt8], _ password: String?, _ options: OptimizeOptions = OptimizeOptions()) throws -> OptimizeResult {
        let doc = try PdfEdit.open(data, password)
        try SignedEdits.requireRewrite(data, reason: "optimizing rewrites the whole file")

        removeExtras(doc, options)
        let duplicates = options.deduplicateStreams ? deduplicate(doc) : 0
        var downsampled = 0
        if let dpi = options.maxImageDpi, dpi > 0 { downsampled = try downsample(doc, dpi, min(max(options.jpegQuality, 1), 100)) }
        let compressed = options.compressStreams ? compress(doc) : 0
        try doc.checkFailure()
        let saved = try PdfEdit.writeWhole(doc, password: password)
        return OptimizeResult(data: saved, sizeBefore: data.count, sizeAfter: saved.count, streamsCompressed: compressed,
                              duplicatesRemoved: duplicates, imagesDownsampled: downsampled)
    }

    /// The indirect dictionaries (and streams) the document still uses: what a rewrite keeps.
    private static func objects(_ doc: MuDoc) -> [PObj] {
        doc.closure([doc.catalog, doc.trailer["Info"]]).filter(\.isDict)
    }

    private static func removeExtras(_ doc: MuDoc, _ options: OptimizeOptions) {
        if options.removeThumbnails {
            for page in (try? doc.pages()) ?? [] { page.remove("Thumb") }
        }
        if !options.removePieceInfo && !options.removeMetadata { return }
        for d in objects(doc) {
            if options.removePieceInfo { d.remove("PieceInfo") }
            if options.removeMetadata, let m = d.dict("Metadata"), m.isStream { d.remove("Metadata") }
        }
    }

    // ---- Identical streams ----

    /// Points every use of a byte-identical stream (same dictionary too) at one copy; returns how many copies went.
    private static func deduplicate(_ doc: MuDoc) -> Int {
        var total = 0
        // Streams referring to merged ones (an image to its mask, a font to its file) only match on the next round.
        for _ in 0..<4 {
            var keep: [String: (ref: PObj, raw: [UInt8])] = [:]
            var map: [Int: PObj] = [:]
            for d in objects(doc) where d.isStream && d.isRef {
                if let type = d.name("Type"), ["Metadata", "XRef", "ObjStm"].contains(type) { continue }
                guard let raw = d.rawStreamData else { continue }
                let key = fnv(raw) + canonical(d, 0)
                if let first = keep[key], first.raw == raw { map[d.num] = first.ref } else { keep[key] = (d, raw) }
            }
            if map.isEmpty { break }
            total += map.count
            var seen = Set<UInt>()
            for d in objects(doc) { redirect(d, map, &seen, 0) }
            redirect(doc.catalog, map, &seen, 0)
        }
        return total
    }

    /// A 64-bit FNV-1a of the bytes, as hex (with the length).
    private static func fnv(_ bytes: [UInt8]) -> String {
        var h: UInt64 = 0xCBF2_9CE4_8422_2325
        for b in bytes {
            h ^= UInt64(b)
            h = h &* 0x100_0000_01B3
        }
        return String(h, radix: 16) + ":" + String(bytes.count) + ":"
    }

    /// A dictionary's entries (not /Length) as text, references by object number (the stream's own reference, at depth
    /// 0, is read through).
    private static func canonical(_ item: PObj?, _ depth: Int) -> String {
        guard let item, depth <= 16 else { return depth > 16 ? "?" : "null" }
        if item.isRef && depth > 0 { return "R\(item.num)" }
        switch item.kind {
        case .dict:
            return "<<" + item.keys.filter { $0 != "Length" }.sorted().map { k in "/\(k) " + canonical(item[k], depth + 1) + " " }.joined() + ">>"
        case .array:
            return "[" + item.elements.map { canonical($0, depth + 1) }.joined(separator: " ") + "]"
        case .string:
            return "(" + (item.bytes ?? []).map { String(format: "%02X", $0) }.joined() + ")"
        case .name:
            return "/" + (item.name ?? "")
        case .null:
            return "null"
        case .bool:
            return item.bool ? "true" : "false"
        default:
            return item.number.map { PdfNum.f($0) } ?? ""
        }
    }

    private static func redirect(_ item: PObj, _ map: [Int: PObj], _ seen: inout Set<UInt>, _ depth: Int) {
        if depth > 64 || !seen.insert(item.identity).inserted { return }
        if item.isDict {
            for key in item.keys {
                guard let v = item[key] else { continue }
                if v.isRef {
                    if let to = map[v.num] { item.set(key, to) }
                } else if v.isDict || v.isArray {
                    redirect(v, map, &seen, depth + 1)
                }
            }
        } else if item.isArray {
            for i in 0..<item.count {
                guard let v = item[i] else { continue }
                if v.isRef {
                    if let to = map[v.num] { item.replace(at: i, with: to) }
                } else if v.isDict || v.isArray {
                    redirect(v, map, &seen, depth + 1)
                }
            }
        }
    }

    // ---- Compression ----

    private static let recodable: Set<String> = ["ASCIIHexDecode", "ASCII85Decode", "LZWDecode", "FlateDecode"]

    /// Flate-compresses unfiltered streams, and re-encodes ASCII/LZW-encoded ones; returns how many changed.
    private static func compress(_ doc: MuDoc) -> Int {
        var count = 0
        for d in objects(doc) where d.isStream {
            if let type = d.name("Type"), ["Metadata", "XRef", "ObjStm"].contains(type) { continue }
            guard let raw = d.rawStreamData, raw.count >= 64, let filters = filters(d) else { continue }
            var plain = raw
            if !filters.isEmpty {
                // Only chains holding an ASCII or LZW filter gain anything; parameters (predictors) are left alone.
                if !filters.allSatisfy(recodable.contains) || filters.allSatisfy({ $0 == "FlateDecode" }) || d.has("DecodeParms") { continue }
                guard let decoded = d.streamData else { continue }
                plain = decoded
            }
            if deflatedSize(plain) >= raw.count { continue }
            d.setStream(plain, deflate: true)
            count += 1
        }
        return count
    }

    /// How long `data` is once deflated (what the file would store).
    static func deflatedSize(_ data: [UInt8]) -> Int {
        ((try? (Data(data) as NSData).compressed(using: .zlib) as Data)?.count ?? data.count) + 6
    }

    /// The stream's filter names (empty = none), or nil when they can't be read.
    private static func filters(_ d: PObj) -> [String]? {
        guard let f = d["Filter"] else { return [] }
        if let name = f.name { return [name] }
        if f.isArray {
            let names = f.elements.compactMap(\.name)
            return names.count == f.count ? names : nil
        }
        return nil
    }

    // ---- Image downsampling ----

    private static func downsample(_ doc: MuDoc, _ targetDpi: Double, _ quality: Int) throws -> Int {
        // Smallest resolution each image is shown at (pixels per inch along its width and height).
        var shown: [UInt: (image: PObj, x: Double, y: Double)] = [:]
        for page in try doc.pages() {
            let complete = ContentImages.scan(page) { image, ctm in
                let w = Double(image.int("Width") ?? 0)
                let h = Double(image.int("Height") ?? 0)
                let lx = (ctm[0] * ctm[0] + ctm[1] * ctm[1]).squareRoot() / 72
                let ly = (ctm[2] * ctm[2] + ctm[3] * ctm[3]).squareRoot() / 72
                let dpi = (x: lx > 1e-6 ? w / lx : Double.greatestFiniteMagnitude, y: ly > 1e-6 ? h / ly : Double.greatestFiniteMagnitude)
                if let was = shown[image.identity] {
                    shown[image.identity] = (was.image, min(was.x, dpi.x), min(was.y, dpi.y))
                } else {
                    shown[image.identity] = (image, dpi.x, dpi.y)
                }
            }
            // A page drawing more than can be followed may show an image larger than found: leave them all as they are.
            if !complete { return 0 }
        }

        var count = 0
        for (_, entry) in shown {
            let (image, dpiX, dpiY) = entry
            if dpiX <= targetDpi * 1.1 && dpiY <= targetDpi * 1.1 { continue }
            let w = image.int("Width") ?? 0
            let h = image.int("Height") ?? 0
            let nw = max(1, Int((Double(w) * min(1, targetDpi / dpiX)).rounded(.up)))
            let nh = max(1, Int((Double(h) * min(1, targetDpi / dpiY)).rounded(.up)))
            if Double(nw) * Double(nh) > 0.8 * Double(w) * Double(h) { continue }
            if try resample(image, nw, nh, quality) { count += 1 }
        }
        return count
    }

    /// Replaces the image (and its soft mask) by a w x h version, if that is smaller.
    private static func resample(_ image: PObj, _ w: Int, _ h: Int, _ quality: Int) throws -> Bool {
        guard let source = imageSource(image, maskOnly: false), let raw = image.rawStreamData else { return false }
        let smask = image.dict("SMask")
        var maskSource: String?
        var maskRaw: [UInt8] = []
        if let smask {
            guard let s = imageSource(smask, maskOnly: true), !smask.has("Matte"), let r = smask.rawStreamData else { return false }
            maskSource = s
            maskRaw = r
        }

        guard let jpeg = try render(source, raw, w, h, quality) else { return false }
        var mask: [UInt8]?
        if let maskSource {
            guard let rgb = try render(maskSource, maskRaw, w, h, nil), rgb.count == w * h * 3 else { return false }
            var gray = [UInt8](repeating: 0, count: w * h)
            for i in 0..<gray.count { gray[i] = rgb[3 * i] }
            mask = gray
        }
        if jpeg.count + (mask.map(deflatedSize) ?? 0) >= raw.count + maskRaw.count { return false }

        replace(image, jpeg, w, h, "DeviceRGB", jpeg: true)
        if let smask, let mask { replace(smask, mask, w, h, "DeviceGray", jpeg: false) }
        return true
    }

    private static func replace(_ image: PObj, _ bytes: [UInt8], _ w: Int, _ h: Int, _ colorSpace: String, jpeg: Bool) {
        let doc = image.doc
        image.setStream(bytes, deflate: !jpeg)
        if jpeg { image.set("Filter", doc.name("DCTDecode")) }
        image.set("Width", doc.int(w))
        image.set("Height", doc.int(h))
        image.set("BitsPerComponent", doc.int(8))
        image.set("ColorSpace", doc.name(colorSpace))
        image.remove("DecodeParms")
        image.remove("Decode")
    }

    /// The image dictionary to draw it on its own (filters, color space as a device space), or nil when it isn't one
    /// this resamples.
    private static func imageSource(_ image: PObj, maskOnly: Bool) -> String? {
        guard image.isStream else { return nil }
        if let m = image["ImageMask"], m.kind == .bool, m.bool { return nil }
        if image.has("Mask") || image.int("BitsPerComponent") != 8 { return nil }
        let w = image.int("Width") ?? 0, h = image.int("Height") ?? 0
        if w <= 0 || h <= 0 { return nil }
        guard let filters = filters(image), !filters.contains(where: { ["JBIG2Decode", "JPXDecode", "CCITTFaxDecode", "Crypt"].contains($0) }) else { return nil }
        guard let cs = colorSpace(image["ColorSpace"]), !maskOnly || cs == "/DeviceGray" else { return nil }

        var sb = "/Type /XObject /Subtype /Image /Width \(w) /Height \(h) /BitsPerComponent 8 /ColorSpace \(cs)"
        for key in ["Filter", "DecodeParms", "Decode"] {
            guard let v = image[key] else { continue }
            guard let text = plain(v, 0) else { return nil }
            sb += " /\(key) \(text)"
        }
        return sb
    }

    /// A device color space name for the image's color space, or nil when it isn't one this handles.
    private static func colorSpace(_ item: PObj?) -> String? {
        guard let item else { return nil }
        if let n = item.name { return ["DeviceRGB", "DeviceGray", "DeviceCMYK"].contains(n) ? "/" + n : nil }
        if item.isArray, item.count == 2, item[0]?.name == "ICCBased", let icc = item[1], icc.isDict {
            switch icc.int("N") {
            case 1: return "/DeviceGray"
            case 3: return "/DeviceRGB"
            case 4: return "/DeviceCMYK"
            default: return nil
            }
        }
        return nil
    }

    /// A direct PDF value written out (names, numbers, booleans, arrays, dictionaries); nil for anything else.
    private static func plain(_ item: PObj, _ depth: Int) -> String? {
        if depth > 8 { return nil }
        switch item.kind {
        case .name: return "/" + (item.name ?? "")
        case .int: return String(item.int ?? 0)
        case .real: return PdfNum.f(item.number ?? 0)
        case .bool: return item.bool ? "true" : "false"
        case .null: return "null"
        case .array:
            var parts: [String] = []
            for e in item.elements {
                guard let s = plain(e, depth + 1) else { return nil }
                parts.append(s)
            }
            return "[" + parts.joined(separator: " ") + "]"
        case .dict:
            if item.isStream { return nil }
            var sb = "<<"
            for key in item.keys {
                guard let v = item[key], let s = plain(v, depth + 1) else { return nil }
                sb += " /\(key) \(s)"
            }
            return sb + " >>"
        default: return nil
        }
    }

    /// The image drawn by MuPDF onto a w x h pixel page: JPEG bytes at `quality`, or raw RGB without one. Nil when MuPDF
    /// can't draw it.
    private static func render(_ imageDict: String, _ stream: [UInt8], _ w: Int, _ h: Int, _ quality: Int?) throws -> [UInt8]? {
        let pdf = oneImagePage(imageDict, stream, w, h)
        let engine: PdfEngine
        do {
            engine = try PdfEngine.open(pdf)
        } catch {
            return nil
        }
        defer { engine.close() }
        do {
            if quality == nil { return try engine.render(0, scale: 1).pixels }
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("inkvolt-opt-\(UUID().uuidString).jpg")
            defer { try? FileManager.default.removeItem(at: url) }
            try engine.saveImage(0, dpi: 72, path: url.path, jpeg: true)
            return Array(try Data(contentsOf: url))
        } catch is PdfEngineError {
            return nil
        }
    }

    /// A PDF whose single w x h point page is filled by the image.
    private static func oneImagePage(_ imageDict: String, _ stream: [UInt8], _ w: Int, _ h: Int) -> [UInt8] {
        var out: [UInt8] = []
        var offsets: [Int] = []
        func write(_ s: String) { out += Array(s.utf8) }
        func obj(_ body: String, _ data: [UInt8]? = nil) {
            offsets.append(out.count)
            write("\(offsets.count) 0 obj\n\(body)")
            if let data {
                write("\nstream\n")
                out += data
                write("\nendstream")
            }
            write("\nendobj\n")
        }
        write("%PDF-1.7\n")
        obj("<< /Type /Catalog /Pages 2 0 R >>")
        obj("<< /Type /Pages /Kids [3 0 R] /Count 1 >>")
        obj("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 \(w) \(h)] /Resources << /XObject << /Im 5 0 R >> >> /Contents 4 0 R >>")
        let content = Array("q \(w) 0 0 \(h) 0 0 cm /Im Do Q".utf8)
        obj("<< /Length \(content.count) >>", content)
        obj("<< \(imageDict) /Length \(stream.count) >>", stream)
        let xref = out.count
        write("xref\n0 \(offsets.count + 1)\n0000000000 65535 f \n")
        for o in offsets { write(String(format: "%010d 00000 n \n", o)) }
        write("trailer\n<< /Size \(offsets.count + 1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n")
        return out
    }
}

/// Finds the image XObjects a page's content draws and the transformation each is drawn with (through form XObjects),
/// by following q/Q/cm and Do in the content streams (the Windows app's `ContentImages`). Each form is read once: what
/// it draws is kept and placed again wherever it is drawn (an image a form draws twice with the same transformation is
/// reported once per drawing).
enum ContentImages {
    private static let maxDepth = 12
    /// Form reads (one more per 4 KB of content) plus images reported, per page: past it the page is left unread.
    private static let maxWork = 200_000
    private static let identity: [Double] = [1, 0, 0, 1, 0, 0]

    /// The images one form draws, with their transformations in its space (each once).
    private struct FormImages {
        var resources: UInt?
        var depth: Int
        var images: [(image: PObj, ctm: [Double])]
    }

    /// One page's scan: the forms being drawn, those already read, and the work done.
    private final class Walk {
        var visiting = Set<UInt>()
        var forms: [UInt: [FormImages]] = [:]
        var work = 0, cuts = 0
        var over: Bool { work > maxWork }
    }

    /// Reports each image drawn; false when the page draws more than `maxWork` allows (some not reported).
    static func scan(_ page: PObj, _ onImage: (PObj, [Double]) -> Void) -> Bool {
        var content: [UInt8] = []
        if let item = page["Contents"] {
            for part in item.isArray ? item.elements : [item] where part.isStream {
                content += part.streamData ?? []
                content.append(10)
            }
        }
        let walk = Walk()
        run(content, PageBoxes.inherited(page, "Resources"), identity, onImage, walk, 0)
        return !walk.over
    }

    private static func run(_ ops: [UInt8], _ resources: PObj?, _ start: [Double], _ onImage: (PObj, [Double]) -> Void, _ walk: Walk, _ depth: Int) {
        var ctm = start
        var stack: [[Double]] = []
        var operands: [Any] = []
        let xobjects = resources?.dict("XObject")
        var i = 0
        while i < ops.count {
            let c = ops[i]
            if isWhite(c) {
                i += 1
                continue
            }
            switch c {
            case 37: // %
                while i < ops.count && ops[i] != 10 && ops[i] != 13 { i += 1 }
                continue
            case 40: // (
                i = skipString(ops, i)
                operands.append("")
                continue
            case 60 where i + 1 < ops.count && ops[i + 1] == 60: // <<
                i = skipDict(ops, i)
                operands.append("")
                continue
            case 60: // < hex string
                while i < ops.count && ops[i] != 62 { i += 1 }
                i += 1
                operands.append("")
                continue
            case 91, 93, 123, 125: // [ ] { }
                i += 1
                continue
            case 47: // / a name
                i += 1
                let s = i
                while i < ops.count && !isWhite(ops[i]) && !isDelimiter(ops[i]) { i += 1 }
                operands.append("/" + String(decoding: ops[s..<i], as: UTF8.self))
                continue
            default:
                break
            }
            let start2 = i
            while i < ops.count && !isWhite(ops[i]) && !isDelimiter(ops[i]) { i += 1 }
            if i == start2 {
                i += 1
                continue
            }
            let word = String(decoding: ops[start2..<i], as: UTF8.self)
            if let first = word.utf8.first, (first >= 48 && first <= 57) || first == 45 || first == 43 || first == 46 {
                operands.append(Double(word) ?? 0.0)
                continue
            }
            switch word {
            case "q":
                stack.append(ctm)
            case "Q":
                if let top = stack.popLast() { ctm = top }
            case "cm" where operands.count >= 6 && operands.suffix(6).allSatisfy({ $0 is Double }):
                let m = operands.suffix(6).map { $0 as! Double }
                ctm = multiply(m, ctm)
            case "Do" where operands.count >= 1 && (operands.last as? String)?.hasPrefix("/") == true:
                let name = String((operands.last as! String).dropFirst())
                guard let x = xobjects?.dict(name) else { break }
                let subtype = x.name("Subtype")
                if subtype == "Image" {
                    walk.work += 1
                    if walk.work > maxWork { return }
                    onImage(x, ctm)
                } else if subtype == "Form" && depth < maxDepth && x.isStream,
                          let images = imagesOf(x, x.dict("Resources") ?? resources, walk, depth + 1) {
                    if walk.over { return }
                    let fm: [Double]
                    if let a = x.array("Matrix"), a.count >= 6 { fm = (0..<6).map { a.num($0) } } else { fm = identity }
                    let at = multiply(fm, ctm)
                    for (image, m) in images {
                        walk.work += 1
                        if walk.work > maxWork { return }
                        onImage(image, multiply(m, at))
                    }
                }
            case "BI":
                i = skipInlineImage(ops, i)
            default:
                break
            }
            operands.removeAll()
        }
    }

    /// The images a form draws, read once per resources and depth; nil when the form is already being drawn (a form
    /// drawing itself). A read that met such a loop depends on where the form was drawn from, so it isn't kept.
    private static func imagesOf(_ form: PObj, _ resources: PObj?, _ walk: Walk, _ depth: Int) -> [(image: PObj, ctm: [Double])]? {
        let known = walk.forms[form.identity]
        if let done = known?.first(where: { $0.resources == resources?.identity && $0.depth == depth }) { return done.images }
        guard walk.visiting.insert(form.identity).inserted else {
            walk.cuts += 1
            return nil
        }
        let ops = form.streamData ?? []
        walk.work += 1 + ops.count / 4096
        let cuts = walk.cuts
        var images: [(image: PObj, ctm: [Double])] = []
        var distinct = Set<String>()
        run(ops, resources, identity, { image, m in
            let key = "\(image.identity):" + m.map { String($0) }.joined(separator: ",")
            if distinct.insert(key).inserted { images.append((image, m)) }
        }, walk, depth)
        walk.visiting.remove(form.identity)
        if walk.cuts == cuts {
            walk.forms[form.identity, default: []].append(FormImages(resources: resources?.identity, depth: depth, images: images))
        }
        return images
    }

    /// m × n for PDF matrices [a b c d e f].
    private static func multiply(_ m: [Double], _ n: [Double]) -> [Double] {
        [m[0] * n[0] + m[1] * n[2], m[0] * n[1] + m[1] * n[3],
         m[2] * n[0] + m[3] * n[2], m[2] * n[1] + m[3] * n[3],
         m[4] * n[0] + m[5] * n[2] + n[4], m[4] * n[1] + m[5] * n[3] + n[5]]
    }

    private static func isWhite(_ c: UInt8) -> Bool { c == 32 || c == 10 || c == 13 || c == 9 || c == 12 || c == 0 }

    private static func isDelimiter(_ c: UInt8) -> Bool {
        c == 40 || c == 41 || c == 60 || c == 62 || c == 91 || c == 93 || c == 123 || c == 125 || c == 47 || c == 37
    }

    private static func skipString(_ b: [UInt8], _ from: Int) -> Int {
        var depth = 0
        var i = from
        while i < b.count {
            if b[i] == 92 {
                i += 2
                continue
            }
            if b[i] == 40 { depth += 1 } else if b[i] == 41 {
                depth -= 1
                if depth == 0 { return i + 1 }
            }
            i += 1
        }
        return i
    }

    private static func skipDict(_ b: [UInt8], _ from: Int) -> Int {
        var depth = 0
        var i = from
        while i < b.count {
            if b[i] == 40 {
                i = skipString(b, i)
                continue
            }
            if i + 1 < b.count && b[i] == 60 && b[i + 1] == 60 {
                depth += 1
                i += 2
                continue
            }
            if i + 1 < b.count && b[i] == 62 && b[i + 1] == 62 {
                i += 2
                depth -= 1
                if depth == 0 { return i }
                continue
            }
            i += 1
        }
        return i
    }

    /// Skips an inline image's dictionary and data, to just past its EI.
    private static func skipInlineImage(_ b: [UInt8], _ from: Int) -> Int {
        // "ID" followed by one white-space byte starts the data; it ends at white space, "EI", then white space or the end.
        var i = max(from, 1)
        while i + 2 < b.count {
            if b[i] == 73 && b[i + 1] == 68 && isWhite(b[i - 1]) && isWhite(b[i + 2]) { break }
            i += 1
        }
        i += 3
        while i + 1 < b.count {
            if isWhite(b[i - 1]) && b[i] == 69 && b[i + 1] == 73 && (i + 2 >= b.count || isWhite(b[i + 2])) { return i + 2 }
            i += 1
        }
        return b.count
    }
}
