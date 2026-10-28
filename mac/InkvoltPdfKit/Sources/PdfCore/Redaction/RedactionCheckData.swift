import Foundation

/// The redaction check's search of the file's data: the values in every object of the document (strings, decoded
/// streams, the text content streams show in their own fonts, attached files), named by what holds them; in each earlier
/// version kept by incremental saves; and in the file's raw bytes with every stream decompressed.
extension RedactionCheck {
    /// Largest decompressed stream or attached file part looked into (bytes).
    static let maxStreamBytes = 64 << 20

    /// Finds the values in text: case and spacing ignored (any run of spaces or line breaks matches a space, soft hyphens
    /// are skipped), whole words only. A value made of digits and separators (a Social Security, phone or card number)
    /// also matches its digits written with other separators or none.
    struct ValueMatcher {
        private let regex: NSRegularExpression?
        private var digits: [Bool] = []
        private var wordStart: [Bool] = [], wordEnd: [Bool] = []
        let values: [String]
        var isEmpty: Bool { regex == nil }

        init(_ values: [String]) {
            self.values = values
            var parts: [String] = []
            for v in values {
                let scalars = Array(v.unicodeScalars)
                guard let first = scalars.first, let last = scalars.last else {
                    parts.append("(?!)")
                    digits.append(false)
                    wordStart.append(false)
                    wordEnd.append(false)
                    continue
                }
                let isDigits = scalars.filter(Self.isDigit).count >= 5 && !scalars.contains(where: { $0.properties.isAlphabetic })
                digits.append(isDigits)
                wordStart.append(Self.isLetterOrDigit(first))
                wordEnd.append(Self.isLetterOrDigit(last))
                let pattern: String
                if isDigits {
                    pattern = scalars.filter(Self.isDigit).map { String($0) }.joined(separator: #"[\s\-./()]{0,3}"#)
                } else {
                    pattern = v.split(separator: " ", omittingEmptySubsequences: false).map { w in
                        w.map { NSRegularExpression.escapedPattern(for: String($0)) }.joined(separator: "\u{AD}?")
                    }.joined(separator: "[\\s\u{AD}]+")
                }
                parts.append("(\(pattern))")
            }
            regex = values.isEmpty ? nil : try? NSRegularExpression(pattern: parts.joined(separator: "|"), options: [.caseInsensitive])
        }

        static func isDigit(_ s: Unicode.Scalar) -> Bool { s.properties.numericType == .decimal }

        static func isLetterOrDigit(_ s: Unicode.Scalar) -> Bool { s.properties.isAlphabetic || isDigit(s) }

        private static func unitIs(_ u: UInt16, _ test: (Unicode.Scalar) -> Bool) -> Bool {
            guard let s = Unicode.Scalar(u) else { return true } // half of a surrogate pair: a letter of another script
            return test(s)
        }

        /// Every match: which value, where (UTF-16 units).
        func matches(_ text: String) -> [(value: Int, start: Int, length: Int)] {
            guard let regex, !text.isEmpty else { return [] }
            let ns = text as NSString
            guard let found = try? TimedRegex.matches(regex, in: ns, seconds: 10) else { return [] }
            var out: [(Int, Int, Int)] = []
            for m in found {
                var v = -1
                for g in 1..<m.numberOfRanges where m.range(at: g).location != NSNotFound {
                    v = g - 1
                    break
                }
                if v < 0 { continue }
                let s = m.range.location, e = s + m.range.length
                let before: UInt16 = s > 0 ? ns.character(at: s - 1) : 32
                let after: UInt16 = e < ns.length ? ns.character(at: e) : 32
                if digits[v] {
                    if Self.unitIs(before, Self.isDigit) || Self.unitIs(after, Self.isDigit) { continue }
                } else if (wordStart[v] && Self.unitIs(before, Self.isLetterOrDigit)) || (wordEnd[v] && Self.unitIs(after, Self.isLetterOrDigit)) {
                    continue
                }
                out.append((v, s, m.range.length))
            }
            return out
        }

        /// The first match of each value.
        func firstOfEach(_ text: String) -> [(value: Int, start: Int, length: Int)] {
            var seen = Set<Int>()
            return matches(text).filter { seen.insert($0.value).inserted }
        }
    }

    /// What holds an object: a page (its dictionary, its content), a comment or field, the outline, ...
    enum Part { case page, content, annotation, field, xfa, bookmark, info, attachment, structure }

    /// `resources`: for content streams (page content, forms, appearances), their resources, to read their text.
    struct Owner {
        var part: Part
        var page: Int
        var place: String
        var fix: SanitizeItem?
        var resources: PObj?

        func with(resources: PObj?) -> Owner {
            var o = self
            o.resources = resources
            return o
        }
    }

    /// Where the earlier versions of the file end (after each %%EOF that closes a version), oldest first, the current
    /// version left out; a linearized file's first-page section isn't a version.
    static func revisions(_ data: [UInt8]) -> [Int] {
        var ends: [Int] = []
        let eof = Array("%%EOF".utf8), startxref = Array("startxref".utf8)
        var from = data.startIndex
        while let r = data[from...].firstRange(of: eof) {
            let pos = r.lowerBound
            var end = pos + 5
            while end < data.count && (data[end] == 13 || data[end] == 10) { end += 1 }
            if data[max(0, pos - 64)..<pos].firstRange(of: startxref) != nil { ends.append(end) }
            from = pos + 5
        }
        // The last one closes the current version (whatever junk follows it).
        if !ends.isEmpty { ends.removeLast() }
        if !ends.isEmpty && data.prefix(2048).firstRange(of: Array("/Linearized".utf8)) != nil { ends.removeFirst() }
        return ends
    }

    /// What holds each object (by identity, with the object), found by walking from the catalog: pages (their content,
    /// the forms it draws), comments and fields (their appearances), the form's XFA, the outline, the properties,
    /// attached files, the structure tree.
    static func owners(_ doc: MuDoc, _ cancel: CancelToken?) throws -> [UInt: (obj: PObj, owner: Owner)] {
        var map: [UInt: (obj: PObj, owner: Owner)] = [:]
        @discardableResult
        func tryAdd(_ o: PObj, _ owner: Owner) -> Bool {
            if map[o.identity] != nil { return false }
            map[o.identity] = (o, owner)
            return true
        }
        func set(_ item: PObj?, _ owner: Owner) {
            if let item, item.isDict || item.isArray || item.kind == .string { tryAdd(item, owner) }
        }
        func forms(_ resources: PObj?, _ owner: Owner, _ depth: Int) {
            guard depth <= 8, let xobjects = resources?.dict("XObject") else { return }
            for key in xobjects.keys {
                guard let form = xobjects.dict(key), form.isStream, form.name("Subtype") == "Form" else { continue }
                let res = form.dict("Resources") ?? resources
                if tryAdd(form, owner.with(resources: res)) { forms(res, owner, depth + 1) }
            }
        }
        func content(_ item: PObj?, _ owner: Owner) {
            guard let item else { return }
            if item.isStream {
                tryAdd(item, owner)
                forms(owner.resources, owner, 0)
            } else if item.isArray {
                for e in item.elements { content(e, owner) }
            }
        }

        // Attached files first: a file-attachment comment's file is named by its file specification.
        for o in doc.allObjects() where o.isDict && (o.name("Type") == "Filespec" || o.has("EF")) {
            let name = o.text("UF") ?? o.text("F") ?? ""
            let owner = Owner(part: .attachment, page: -1, place: name.isEmpty ? "An attached file" : "Attached file '\(name)'", fix: .embeddedFiles)
            tryAdd(o, owner)
            if let ef = o.dict("EF") { for key in ef.keys { set(ef[key], owner) } }
        }

        for p in 0..<(try doc.pageCount()) {
            try cancel.check()
            let page = doc.page(p)
            tryAdd(page, Owner(part: .page, page: p, place: "Page \(p + 1)'s own data", fix: .metadata))
            content(page["Contents"], Owner(part: .content, page: p, place: "Page \(p + 1)", fix: nil,
                                            resources: PageBoxes.inherited(page, "Resources")))
            for a in page.array("Annots")?.elements ?? [] where a.isDict {
                let owner = annotOwner(a, p)
                tryAdd(a, owner)
                if let ap = a.dict("AP") {
                    for key in ["N", "R", "D"] {
                        guard let states = ap.dict(key) else { continue }
                        let streams = states.isStream ? [states] : states.keys.compactMap { states.dict($0) }.filter(\.isStream)
                        for s in streams {
                            let res = s.dict("Resources")
                            if tryAdd(s, owner.with(resources: res)) { forms(res, owner, 0) }
                        }
                    }
                }
                set(a.dict("Popup"), owner)
            }
        }

        let catalog = doc.catalog
        var seen = Set<UInt>()
        if let acro = catalog.dict("AcroForm") {
            func field(_ f: PObj, _ depth: Int) {
                guard depth <= 32, seen.insert(f.identity).inserted else { return }
                tryAdd(f, Owner(part: .field, page: -1, place: "Form field '\(fieldName(f))'", fix: .formValues))
                for k in f.array("Kids")?.elements ?? [] where k.isDict { field(k, depth + 1) }
            }
            for f in acro.array("Fields")?.elements ?? [] where f.isDict { field(f, 0) }
            let xfa = Owner(part: .xfa, page: -1, place: "The form's XFA data", fix: .formValues)
            if let x = acro["XFA"] {
                if x.isStream {
                    tryAdd(x, xfa)
                } else if x.isArray {
                    for e in x.elements where e.isStream { tryAdd(e, xfa) }
                }
            }
        }

        // The outline: siblings by /Next, children by /First, each item once.
        let bookmark = Owner(part: .bookmark, page: -1, place: "Bookmark", fix: .bookmarks)
        var stack: [PObj] = []
        if let top = catalog.dict("Outlines")?.dict("First") { stack.append(top) }
        var guardCount = 0
        while let item = stack.popLast(), guardCount < 200_000 {
            guardCount += 1
            if !seen.insert(item.identity).inserted { continue }
            tryAdd(item, bookmark)
            if let next = item.dict("Next") { stack.append(next) }
            if let child = item.dict("First") { stack.append(child) }
        }

        if let info = doc.info { tryAdd(info, Owner(part: .info, page: -1, place: "Document properties", fix: .metadata)) }

        let structure = Owner(part: .structure, page: -1, place: "Tags (structure tree)", fix: nil)
        var elems: [(PObj?, Int)] = [(catalog.dict("StructTreeRoot")?["K"], 0)]
        guardCount = 0
        while let (item, depth) = elems.popLast(), guardCount < 500_000 {
            guardCount += 1
            guard let item, depth <= 256 else { continue }
            if item.isArray {
                for e in item.elements { elems.append((e, depth + 1)) }
            } else if item.isDict, item.name("Type") != "MCR", item.name("Type") != "OBJR", seen.insert(item.identity).inserted {
                tryAdd(item, structure)
                elems.append((item["K"], depth + 1))
            }
        }
        return map
    }

    static func annotOwner(_ a: PObj, _ p: Int) -> Owner {
        let subtype = a.name("Subtype") ?? ""
        let flags = a.int("F") ?? 0
        if subtype == "Widget" || a.has("FT") {
            return Owner(part: .annotation, page: p, place: "Form field '\(fieldName(a))' on page \(p + 1)",
                         fix: flags & (2 | 32) != 0 ? .hiddenAnnotations : .formValues)
        }
        let what: String
        switch subtype {
        case "Text": what = "Note"
        case "FreeText": what = "Text box"
        case "Square": what = "Rectangle"
        case "Circle": what = "Ellipse"
        case "Ink": what = "Drawing"
        case "Popup": what = "Pop-up note"
        case "FileAttachment": what = "Attached file (comment)"
        case "": what = "Comment"
        default: what = subtype
        }
        if flags & (2 | 32) != 0 {
            return Owner(part: .annotation, page: p, place: "Hidden \(what.lowercased()) on page \(p + 1)", fix: .hiddenAnnotations)
        }
        switch subtype {
        case "Link": return Owner(part: .annotation, page: p, place: "Link on page \(p + 1)", fix: .externalLinks)
        case "FileAttachment": return Owner(part: .annotation, page: p, place: "\(what) on page \(p + 1)", fix: .embeddedFiles)
        default: return Owner(part: .annotation, page: p, place: "\(what) on page \(p + 1)", fix: .comments)
        }
    }

    /// A field's full name (its own name and its parents', joined by dots).
    static func fieldName(_ f: PObj) -> String {
        var parts: [String] = []
        var d: PObj? = f
        var guardCount = 0
        while let cur = d, guardCount < 32 {
            if let t = cur.text("T"), !t.isEmpty { parts.insert(t, at: 0) }
            d = cur.dict("Parent")
            guardCount += 1
        }
        return parts.isEmpty ? "(unnamed)" : parts.joined(separator: ".")
    }

    /// The text an object holds: its strings (in nested dictionaries and arrays too, references not followed), and its
    /// stream decoded: content streams as the text they show (in their own fonts) and as bytes; attached files by their
    /// kind (zipped Office files and PDFs looked inside); XML and text as they are. Pictures and font programs are skipped.
    static func objectText(_ o: PObj, _ owner: Owner?) -> String {
        var sb = ""
        let signature = o.isDict && o.has("ByteRange")
        strings(o, &sb, signature, 0)
        guard o.isStream else { return sb }
        let type = o.name("Type") ?? "", subtype = o.name("Subtype") ?? ""
        if subtype == "Image" || type == "XRef" || type == "ObjStm" || o.has("Length1") || o.has("Length2")
            || ["Type1C", "CIDFontType0C", "OpenType"].contains(subtype) || (o.has("N") && o.has("Alternate")) { return sb }
        guard var bytes = o.streamData else { return sb } // a filter that fails on its data
        if bytes.count > maxStreamBytes { bytes = Array(bytes.prefix(maxStreamBytes)) }
        sb += "\n"
        if let owner, [.content, .annotation, .field].contains(owner.part), subtype.isEmpty || subtype == "Form" {
            sb += contentText(bytes, owner.resources) + "\n"
        }
        if type == "EmbeddedFile" || owner?.part == .attachment {
            sb += fileText(bytes)
        } else {
            sb += plainText(bytes)
        }
        return sb
    }

    private static func strings(_ item: PObj, _ sb: inout String, _ signature: Bool, _ depth: Int) {
        if depth > 16 { return }
        switch item.kind {
        case .string:
            sb += (item.text ?? "") + "\n"
        case .dict:
            for key in item.keys {
                guard !(signature && key == "Contents"), let v = item[key], !v.isRef else { continue }
                strings(v, &sb, signature, depth + 1)
            }
        case .array:
            for e in item.elements where !e.isRef { strings(e, &sb, signature, depth + 1) }
        default:
            break
        }
    }

    /// The text a content stream shows, each string decoded in its font: twice, with a space wherever the text moves and
    /// with none (a word placed letter by letter reads whole in the second).
    static func contentText(_ content: [UInt8], _ resources: PObj?) -> String {
        let (spaced, joined) = contentTexts(content, resources)
        return spaced + "\n" + joined
    }

    static func contentTexts(_ content: [UInt8], _ resources: PObj?) -> (spaced: String, joined: String) {
        var spaced = "", joined = ""
        var font: TextFont?
        var fonts: [UInt: TextFont] = [:]
        func show(_ s: CObj) {
            guard s.kind == .string else { return }
            guard let font else {
                let latin = latin1String(s.bytes)
                spaced += latin
                joined += latin
                return
            }
            for g in font.decode(s.bytes) {
                spaced += g.text
                joined += g.text
            }
        }
        for op in ContentLexer.parse(content) {
            switch op.name {
            case "Tf" where !op.operands.isEmpty:
                if let fd = resources?.dict("Font")?.dict(op.operands[0].name) {
                    if let known = fonts[fd.identity] {
                        font = known
                    } else {
                        let made = TextFont(fd)
                        fonts[fd.identity] = made
                        font = made
                    }
                } else {
                    font = nil
                }
            case "Td", "TD", "Tm", "T*", "BT", "ET":
                spaced += " "
            case "Tj", "'", "\"":
                guard let last = op.operands.last else { break }
                if op.name != "Tj" { spaced += " " }
                show(last)
            case "TJ":
                guard let last = op.operands.last, last.kind == .array else { break }
                for e in last.items {
                    if e.kind == .number && e.num < -200 {
                        spaced += " "
                    } else {
                        show(e)
                    }
                }
            default:
                break
            }
        }
        return (spaced, joined)
    }

    /// Bytes as text: by their byte-order mark, else as Latin-1 and (when it is valid) UTF-8.
    static func plainText(_ bytes: [UInt8]) -> String {
        if bytes.count >= 2 && bytes[0] == 0xFE && bytes[1] == 0xFF { return String(bytes: bytes[2...], encoding: .utf16BigEndian) ?? "" }
        if bytes.count >= 2 && bytes[0] == 0xFF && bytes[1] == 0xFE { return String(bytes: bytes[2...], encoding: .utf16LittleEndian) ?? "" }
        let latin = latin1(bytes)
        if !bytes.contains(where: { $0 >= 0x80 }) { return latin }
        if let utf8 = String(validating: bytes, as: UTF8.self) { return latin + "\n" + utf8 }
        return latin
    }

    static func latin1<C: Collection>(_ bytes: C) -> String where C.Element == UInt8 {
        String(bytes: bytes, encoding: .isoLatin1) ?? latin1String(bytes)
    }

    /// An attached file's text: a PDF's raw bytes with its streams decompressed, a zip's (Office) parts with their markup
    /// taken out, else the bytes as text (UTF-16 too when it looks like it).
    static func fileText(_ bytes: [UInt8]) -> String {
        if bytes.prefix(1024).firstRange(of: Array("%PDF-".utf8)) != nil { return rawText(bytes, nil) }
        if bytes.count > 4 && bytes[0] == 0x50 && bytes[1] == 0x4B && bytes[2] == 3 && bytes[3] == 4,
           let entries = ZipReader.entries(bytes, limit: maxStreamBytes) {
            var sb = ""
            for e in entries {
                let text = plainText(e.data)
                sb += text + "\n" + text.replacingOccurrences(of: "<[^>]*>", with: "", options: .regularExpression) + "\n"
            }
            return sb
        }
        let plain = plainText(bytes)
        let head = bytes.prefix(4096)
        let zeros = head.filter { $0 == 0 }.count
        if zeros > min(bytes.count, 4096) / 4 {
            let even = bytes.count & ~1
            return plain + "\n" + (String(bytes: bytes[..<even], encoding: .utf16LittleEndian) ?? "") + "\n"
                + (String(bytes: bytes[..<even], encoding: .utf16BigEndian) ?? "")
        }
        return plain
    }

    /// A PDF's raw bytes as Latin-1, followed by every stream in them that inflates (zlib), decompressed.
    static func rawText(_ data: [UInt8], _ cancel: CancelToken?) -> String {
        var sb = latin1(data)
        let streamKey = Array("stream".utf8), endKey = Array("endstream".utf8), end3 = Array("end".utf8)
        var total = 0
        var at = data.startIndex
        while let r = data[at...].firstRange(of: streamKey) {
            if cancel?.isCancelled == true { break }
            var start = r.upperBound
            at = start
            if start >= 9 && Array(data[(start - 9)..<(start - 6)]) == end3 { continue } // "endstream"
            if start < data.count && data[start] == 13 { start += 1 }
            if start < data.count && data[start] == 10 { start += 1 }
            guard let e = data[start...].firstRange(of: endKey), e.lowerBound > start else { continue }
            if let inflated = Inflate.zlib(data[start..<e.lowerBound], limit: maxStreamBytes) {
                total += inflated.count
                if total > 512 << 20 { break }
                sb += "\n" + latin1(inflated)
            }
            at = e.lowerBound
        }
        return sb
    }

    private static let wordPattern = try! NSRegularExpression(pattern: #"[\p{L}\p{N}][\p{L}\p{N}@._'\-]*[\p{L}\p{N}]"#)

    static func words(_ text: String) -> [String] {
        let ns = text as NSString
        return wordPattern.matches(in: text, range: NSRange(location: 0, length: ns.length)).filter { $0.range.length >= 3 }
            .map { ns.substring(with: $0.range).lowercased() }
    }

    /// What matched, with up to 20 characters around it from the same line (string), 80 at most.
    static func excerpt(_ text: String, _ start: Int, _ length: Int) -> String {
        let ns = text as NSString
        let before = ns.range(of: "\n", options: .backwards, range: NSRange(location: 0, length: min(ns.length, max(0, start - 1) + 1)))
        let lineStart = before.location == NSNotFound ? 0 : before.location + 1
        let after = start + length <= ns.length ? ns.range(of: "\n", options: [], range: NSRange(location: start + length, length: ns.length - start - length))
            : NSRange(location: NSNotFound, length: 0)
        let lineEnd = after.location == NSNotFound ? ns.length : after.location
        var s = max(lineStart, start - 20)
        var e = min(lineEnd, start + length + 20)
        if length >= 60 {
            s = start
            e = min(lineEnd, start + 80)
        }
        let part = ns.substring(with: NSRange(location: s, length: max(0, e - s))).split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        return (s > lineStart ? "…" : "") + part + (e < lineEnd ? "…" : "")
    }
}

extension RedactionCheck.Check {
    /// Every object of the document, searched for the values; a hit is reported as what holds it (page content that shows
    /// it is the page text's finding already). Returns the values found in the document's objects.
    func objects(_ doc: MuDoc, _ matcher: RedactionCheck.ValueMatcher) throws -> Set<Int> {
        var inFile = Set<Int>()
        let owners = try RedactionCheck.owners(doc, cancel)
        let used = Self.used(doc)
        for (n, o) in doc.allObjects().enumerated() {
            if n & 255 == 255 { try cancel.check() }
            let owner = owners[o.identity]?.owner
            let text = RedactionCheck.objectText(o, owner)
            if text.isEmpty { continue }
            for (v, start, length) in matcher.firstOfEach(text) {
                inFile.insert(v)
                hits.insert(v)
                let found = RedactionCheck.excerpt(text, start, length)
                if owner?.part == .content { continue } // compared with what the page shows below
                add(owner.map { Self.finding($0, found) } ?? Self.unowned(o, found, used.contains(o.num)))
            }
        }
        try hiddenInContent(matcher, owners)
        return inFile
    }

    /// A value that a page's content draws more often than the page's text holds it is in the content where it doesn't
    /// show: a hidden layer, clipped away (text outside the page and covered text are in the page text, and were reported
    /// already).
    private func hiddenInContent(_ matcher: RedactionCheck.ValueMatcher, _ owners: [UInt: (obj: PObj, owner: RedactionCheck.Owner)]) throws {
        var byPage: [Int: [(PObj, RedactionCheck.Owner)]] = [:]
        for (o, owner) in owners.values where owner.part == .content && o.isStream { byPage[owner.page, default: []].append((o, owner)) }
        for (p, group) in byPage.sorted(by: { $0.key < $1.key }) {
            if p < 0 || p >= texts.count { continue }
            try cancel.check()
            var drawn: [Int: Int] = [:]
            for (o, owner) in group {
                guard let bytes = o.streamData else { continue }
                let (spaced, joined) = RedactionCheck.contentTexts(bytes, owner.resources)
                var a: [Int: Int] = [:], b: [Int: Int] = [:]
                for m in matcher.matches(spaced) { a[m.value, default: 0] += 1 }
                for m in matcher.matches(joined) { b[m.value, default: 0] += 1 }
                for v in Set(a.keys).union(b.keys) { drawn[v, default: 0] += max(a[v] ?? 0, b[v] ?? 0) }
            }
            var shown: [Int: Int] = [:]
            for m in matcher.matches(texts[p].text) { shown[m.value, default: 0] += 1 }
            for (v, count) in drawn.sorted(by: { $0.key < $1.key }) where count > (shown[v] ?? 0) {
                hits.insert(v)
                add(RedactionFinding(.hiddenText, "Page \(p + 1), in its content but not shown", matcher.values[v], page: p,
                                     box: RedactionCheck.offPage, sanitize: hiddenLayers > 0 ? .hiddenLayers : nil))
            }
        }
    }

    private static func finding(_ o: RedactionCheck.Owner, _ text: String) -> RedactionFinding {
        var kind: RedactionLeak
        switch o.part {
        case .annotation: kind = .annotation
        case .field, .xfa: kind = .formField
        case .bookmark: kind = .bookmark
        case .info, .page: kind = .metadata
        case .attachment: kind = .attachment
        case .structure: kind = .structureTree
        case .content: kind = .fileData
        }
        if o.fix == .formValues && o.part == .annotation { kind = .formField }
        return RedactionFinding(kind, o.place, text, page: o.page, sanitize: o.fix)
    }

    /// An object no walk from the catalog named: classified by its own type.
    private static func unowned(_ o: PObj, _ text: String, _ used: Bool) -> RedactionFinding {
        let type = o.isDict ? o.name("Type") ?? "" : ""
        let number = o.num
        if type == "Metadata" { return RedactionFinding(.metadata, "XMP metadata", text, sanitize: .metadata) }
        if o.isDict && (o.has("JS") || o.name("S") == "JavaScript") {
            return RedactionFinding(.fileData, "A script (JavaScript)", text, sanitize: .activeContent)
        }
        if type == "Filespec" || type == "EmbeddedFile" { return RedactionFinding(.attachment, "An attached file", text, sanitize: .embeddedFiles) }
        if type == "Annot" { return RedactionFinding(.annotation, "A comment", text, sanitize: .comments) }
        if type == "StructElem" { return RedactionFinding(.structureTree, "Tags (structure tree)", text) }
        if !used { return RedactionFinding(.fileData, "Object \(number), which nothing in the document uses", text, rewrite: true) }
        return RedactionFinding(.fileData, "Object \(number) of the file", text)
    }

    /// The object numbers the document reaches from its catalog and its properties.
    private static func used(_ doc: MuDoc) -> Set<Int> {
        let trailer = doc.trailer
        return Set(doc.closure([trailer["Root"], trailer["Info"]]).map(\.num))
    }

    /// The earlier versions of the file (kept by incremental saves), each opened on its own: the values in their objects
    /// that the current version no longer holds, and text their pages showed that the current pages don't.
    func earlierVersions(_ engine: PdfEngine, _ matcher: RedactionCheck.ValueMatcher?, _ inFile: Set<Int>, _ ends: [Int]) throws {
        if ends.isEmpty { return }
        let maxRevisions = RedactionCheck.maxRevisions
        if ends.count > maxRevisions { notes.append("Only the last \(maxRevisions) of the file's \(ends.count) earlier versions were checked.") }
        let current = Set(texts.flatMap { RedactionCheck.words($0.text) })
        var reportedValues = Set<Int>()
        for k in max(0, ends.count - maxRevisions)..<ends.count {
            try cancel.check()
            let prefix = Array(data[0..<ends[k]])
            let place = "Earlier version \(k + 1) of the file"
            do {
                if let matcher {
                    let old = try PdfEdit.openToRead(prefix, password)
                    let owners = try RedactionCheck.owners(old, cancel)
                    for o in old.allObjects() {
                        let text = RedactionCheck.objectText(o, owners[o.identity]?.owner)
                        for (v, start, length) in matcher.firstOfEach(text) {
                            if inFile.contains(v) || !reportedValues.insert(v).inserted { continue }
                            hits.insert(v)
                            add(RedactionFinding(.earlierRevision, place, RedactionCheck.excerpt(text, start, length), rewrite: true))
                        }
                    }
                }
                let pages = try PdfEngine.open(prefix, password: password)
                defer { pages.close() }
                for p in 0..<pages.pageCount {
                    var gone: [String] = []
                    for w in RedactionCheck.words(try pages.text(p, cache: false, cancel: cancel).text) where !current.contains(w) && !gone.contains(w) {
                        gone.append(w)
                    }
                    if gone.isEmpty { continue }
                    add(RedactionFinding(.earlierRevision, "\(place), page \(p + 1)",
                                         "Text no longer on the pages: " + gone.prefix(12).joined(separator: " ") + (gone.count > 12 ? " …" : ""), rewrite: true))
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                notes.append("\(place) couldn't be read on its own.")
            }
            step()
        }
    }

    /// The file's raw bytes, every stream in them decompressed, for values found nowhere else: bytes outside the objects
    /// the document reads (an unencrypted file only; an encrypted one's bytes are ciphertext).
    func rawBytes(_ doc: MuDoc, _ matcher: RedactionCheck.ValueMatcher, _ inFile: Set<Int>) throws {
        if doc.hasEncrypt { return }
        if (0..<matcher.values.count).allSatisfy(hits.contains) { return }
        let text = RedactionCheck.rawText(data, cancel)
        try cancel.check()
        for (v, start, length) in matcher.firstOfEach(text) {
            if !hits.insert(v).inserted || inFile.contains(v) { continue }
            add(RedactionFinding(.fileData, "The file's bytes, outside the objects the document reads", RedactionCheck.excerpt(text, start, length), rewrite: true))
        }
    }
}
