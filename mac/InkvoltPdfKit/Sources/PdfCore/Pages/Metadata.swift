import Foundation

/// A document's properties (the Info dictionary) and its PDF version.
public struct PdfMetadata: Equatable, Sendable {
    public var title: String
    public var author: String
    public var subject: String
    public var keywords: String
    public var creator: String
    public var producer: String
    public var created: Date?
    public var modified: Date?
    public var version: String
}

/// PDF dates ("D:20260127153000+02'00'").
enum PdfDates {
    static func format(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMddHHmmss"
        let offset = TimeZone.current.secondsFromGMT(for: date) / 60
        let sign = offset < 0 ? "-" : "+"
        return "D:" + f.string(from: date) + String(format: "%@%02d'%02d'", sign, abs(offset) / 60, abs(offset) % 60)
    }

    /// A PDF date, with as much of it as the string has; nil when it isn't one.
    static func parse(_ text: String?) -> Date? {
        guard var s = text?.trimmingCharacters(in: .whitespaces) else { return nil }
        if s.hasPrefix("D:") { s.removeFirst(2) }
        let digits = s.prefix { $0.isASCII && $0.isNumber }
        guard digits.count >= 4 else { return nil }
        func part(_ from: Int, _ length: Int, _ fallback: Int) -> Int {
            guard digits.count >= from + length else { return fallback }
            let start = digits.index(digits.startIndex, offsetBy: from)
            return Int(digits[start..<digits.index(start, offsetBy: length)]) ?? fallback
        }
        var c = DateComponents()
        c.year = part(0, 4, 1)
        c.month = part(4, 2, 1)
        c.day = part(6, 2, 1)
        c.hour = part(8, 2, 0)
        c.minute = part(10, 2, 0)
        c.second = part(12, 2, 0)
        let rest = s.dropFirst(digits.count)
        var zone = TimeZone.current
        if let first = rest.first {
            if first == "Z" {
                zone = TimeZone(secondsFromGMT: 0)!
            } else if first == "+" || first == "-" {
                let nums = rest.dropFirst().split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
                let minutes = (nums.first ?? 0) * 60 + (nums.count > 1 ? nums[1] : 0)
                zone = TimeZone(secondsFromGMT: (first == "-" ? -1 : 1) * minutes * 60) ?? zone
            }
        }
        c.timeZone = zone
        return Calendar(identifier: .gregorian).date(from: c)
    }
}

/// The Info dictionary of a document opened for editing.
enum InfoDict {
    /// The Info dictionary; made (and linked from the trailer) when asked to.
    static func get(_ doc: MuDoc, create: Bool) -> PObj? {
        if let info = doc.trailer.dict("Info") { return info }
        guard create else { return nil }
        let made = doc.add(doc.dict())
        doc.trailer.set("Info", made)
        return made
    }

    static func text(_ doc: MuDoc, _ key: String) -> String { get(doc, create: false)?.text(key) ?? "" }

    /// Sets a text entry; an empty value removes it.
    static func set(_ doc: MuDoc, _ key: String, _ value: String) {
        guard let info = get(doc, create: !value.isEmpty) else { return }
        if value.isEmpty { info.remove(key) } else { info.set(key, doc.text(value)) }
    }

    static func setDate(_ doc: MuDoc, _ key: String, _ date: Date) {
        get(doc, create: true)?.set(key, doc.text(PdfDates.format(date)))
    }
}

/// Keeps the XMP metadata packet in step with the Info dictionary (the Windows app's `Xmp`): the document's own packet,
/// its Info-backed properties updated, else a new one. Windows splices the packet into the bytes PDFsharp saved; here
/// the Metadata stream is replaced before MuPDF writes the file.
enum Xmp {
    static let rdf = "http://www.w3.org/1999/02/22-rdf-syntax-ns#"
    static let dc = "http://purl.org/dc/elements/1.1/"
    static let pdf = "http://ns.adobe.com/pdf/1.3/"
    static let xmp = "http://ns.adobe.com/xap/1.0/"
    static let xmpMM = "http://ns.adobe.com/xap/1.0/mm/"
    static let meta = "adobe:ns:meta/"
    static let xmlNs = "http://www.w3.org/XML/1998/namespace"

    /// The document's XMP packet, or nil if it has none or it isn't usable XML.
    static func read(_ doc: MuDoc) -> XMLDocument? {
        guard let stream = doc.catalog.dict("Metadata"), stream.isStream, let data = stream.streamData,
              let xml = try? XMLDocument(data: Data(data), options: [.nodeLoadExternalEntitiesNever]) else { return nil }
        return rdfElement(xml) == nil ? nil : xml
    }

    static let pdfUaId = "http://www.aiim.org/pdfua/ns/id/"

    /// The packet says the file is PDF/UA (pdfuaid:part).
    static func saysPdfUa(_ xml: XMLDocument?) -> Bool {
        guard let xml, let r = rdfElement(xml) else { return false }
        return descriptions(r).contains { !$0.elements(forLocalName: "part", uri: pdfUaId).isEmpty || $0.attribute(forLocalName: "part", uri: pdfUaId) != nil }
    }

    /// Writes the document's XMP packet (a new one when it has none), its Info-backed properties as they are now, with
    /// pdfuaid:part 1 (Windows' `MarkPdfUa` writes the mark and its save updates the properties).
    static func markPdfUa(_ doc: MuDoc) {
        let xml = document(Values(doc), original: read(doc))
        guard let r = rdfElement(xml) else { return }
        for d in descriptions(r) {
            if let a = d.attribute(forLocalName: "part", uri: pdfUaId), let name = a.name { d.removeAttribute(forName: name) }
            for e in d.elements(forLocalName: "part", uri: pdfUaId) { e.detach() }
        }
        let d = XMLElement(name: "rdf:Description", uri: rdf)
        d.addAttribute(XMLNode.attribute(withName: "rdf:about", uri: rdf, stringValue: "") as! XMLNode)
        d.addNamespace(XMLNode.namespace(withName: "pdfuaid", stringValue: pdfUaId) as! XMLNode)
        let part = XMLElement(name: "pdfuaid:part", uri: pdfUaId)
        part.stringValue = "1"
        d.addChild(part)
        r.addChild(d)
        let bytes = packet(xml)
        let catalog = doc.catalog
        if let stream = catalog["Metadata"], stream.isStream {
            stream.setStream(bytes, deflate: false)
        } else {
            catalog.set("Metadata", doc.addStream(bytes, dict: doc.dict([("Type", doc.name("Metadata")), ("Subtype", doc.name("XML"))]), deflate: false))
        }
    }

    /// The Info values as the packet carries them.
    struct Values {
        var title = "", author = "", subject = "", keywords = "", producer = "", creator = ""
        var created: Date?
        var modified: Date?

        init(_ doc: MuDoc) {
            title = InfoDict.text(doc, "Title")
            author = InfoDict.text(doc, "Author")
            subject = InfoDict.text(doc, "Subject")
            keywords = InfoDict.text(doc, "Keywords")
            producer = InfoDict.text(doc, "Producer")
            creator = InfoDict.text(doc, "Creator")
            created = PdfDates.parse(InfoDict.get(doc, create: false)?.text("CreationDate"))
            modified = PdfDates.parse(InfoDict.get(doc, create: false)?.text("ModDate"))
        }
    }

    /// Writes the packet `build` makes into the document's Metadata stream (made when missing), uncompressed as PDFsharp
    /// writes it.
    static func write(_ doc: MuDoc, original: XMLDocument?) {
        let packet = build(Values(doc), original: original)
        let catalog = doc.catalog
        if let stream = catalog["Metadata"], stream.isStream {
            stream.setStream(packet, deflate: false)
        } else {
            catalog.set("Metadata", doc.addStream(packet, dict: doc.dict([("Type", doc.name("Metadata")), ("Subtype", doc.name("XML"))]), deflate: false))
        }
    }

    static func build(_ info: Values, original: XMLDocument?, bare: Bool = false) -> [UInt8] {
        packet(document(info, original: original, bare: bare))
    }

    /// The packet's XML: a copy of `original`, else a new one, with the Info-backed properties set (and, unless `bare`,
    /// the dates and document IDs).
    static func document(_ info: Values, original: XMLDocument?, bare: Bool = false) -> XMLDocument {
        let xml: XMLDocument
        if let original, !bare, let copy = original.copy() as? XMLDocument, rdfElement(copy) != nil {
            xml = copy
        } else {
            let root = XMLElement(name: "x:xmpmeta", uri: meta)
            root.addNamespace(XMLNode.namespace(withName: "x", stringValue: meta) as! XMLNode)
            let r = XMLElement(name: "rdf:RDF", uri: rdf)
            r.addNamespace(XMLNode.namespace(withName: "rdf", stringValue: rdf) as! XMLNode)
            root.addChild(r)
            xml = XMLDocument(rootElement: root)
        }
        let r = rdfElement(xml)!
        let created = info.created
        let modified = info.modified ?? created ?? Date()
        set(r, dc, "title", info.title) { alt($0, r) }
        set(r, dc, "creator", info.author) { seq($0, r) }
        set(r, dc, "description", info.subject) { alt($0, r) }
        set(r, pdf, "Keywords", info.keywords)
        set(r, pdf, "Producer", info.producer)
        set(r, xmp, "CreatorTool", info.creator)
        if !bare {
            if let c = created, !has(r, xmp, "CreateDate") { set(r, xmp, "CreateDate", format(c)) }
            set(r, xmp, "ModifyDate", format(modified))
            set(r, xmp, "MetadataDate", format(modified))
            if !has(r, xmpMM, "DocumentID") { set(r, xmpMM, "DocumentID", "uuid:\(UUID().uuidString.lowercased())") }
            set(r, xmpMM, "InstanceID", "uuid:\(UUID().uuidString.lowercased())")
        }
        return xml
    }

    /// The XML wrapped in an XMP packet, as UTF-8.
    static func packet(_ xml: XMLDocument) -> [UInt8] {
        let text = "<?xpacket begin=\"\u{FEFF}\" id=\"W5M0MpCehiHzreSzNTczkc9d\"?>\n" + xml.rootElement()!.xmlString + "\n<?xpacket end=\"w\"?>"
        return Array(text.utf8)
    }

    /// The rdf:RDF element.
    static func rdfElement(_ xml: XMLDocument) -> XMLElement? {
        func find(_ e: XMLElement) -> XMLElement? {
            if e.localName == "RDF" && e.uri == rdf { return e }
            for child in e.children ?? [] {
                if let c = child as? XMLElement, let hit = find(c) { return hit }
            }
            return nil
        }
        return xml.rootElement().flatMap(find)
    }

    static func descriptions(_ r: XMLElement) -> [XMLElement] { r.elements(forLocalName: "Description", uri: rdf) }

    private static func has(_ r: XMLElement, _ ns: String, _ local: String) -> Bool {
        descriptions(r).contains { !$0.elements(forLocalName: local, uri: ns).isEmpty || $0.attribute(forLocalName: local, uri: ns) != nil }
    }

    private static func prefix(_ e: XMLElement, _ ns: String) -> String {
        if let p = e.resolvePrefix(forNamespaceURI: ns), !p.isEmpty { return p }
        return ns == rdf ? "rdf" : ns == dc ? "dc" : ns == pdf ? "pdf" : ns == xmpMM ? "xmpMM" : "xmp"
    }

    private static func alt(_ value: String, _ r: XMLElement) -> XMLElement {
        let p = prefix(r, rdf)
        let a = XMLElement(name: "\(p):Alt", uri: rdf)
        let li = XMLElement(name: "\(p):li", uri: rdf)
        li.addAttribute(XMLNode.attribute(withName: "xml:lang", uri: xmlNs, stringValue: "x-default") as! XMLNode)
        li.stringValue = value
        a.addChild(li)
        return a
    }

    private static func seq(_ value: String, _ r: XMLElement) -> XMLElement {
        let p = prefix(r, rdf)
        let s = XMLElement(name: "\(p):Seq", uri: rdf)
        let li = XMLElement(name: "\(p):li", uri: rdf)
        li.stringValue = value
        s.addChild(li)
        return s
    }

    /// Sets a property where the packet keeps it (element or attribute of an rdf:Description); an empty value removes it.
    private static func set(_ r: XMLElement, _ ns: String, _ local: String, _ raw: String, _ structured: ((String) -> XMLElement)? = nil) {
        let value = clean(raw)
        let ds = descriptions(r)
        if structured == nil && !value.isEmpty, let attribute = ds.lazy.compactMap({ $0.attribute(forLocalName: local, uri: ns) }).first {
            attribute.stringValue = value
            return
        }
        for d in ds {
            if let a = d.attribute(forLocalName: local, uri: ns), let name = a.name { d.removeAttribute(forName: name) }
            for e in d.elements(forLocalName: local, uri: ns) { e.detach() }
        }
        if value.isEmpty { return }

        var host = ds.first { d in
            (d.children ?? []).contains { ($0 as? XMLElement)?.uri == ns } || (d.attributes ?? []).contains { $0.uri == ns }
        } ?? ds.first
        if host == nil {
            let made = XMLElement(name: "\(prefix(r, rdf)):Description", uri: rdf)
            made.addAttribute(XMLNode.attribute(withName: "\(prefix(r, rdf)):about", uri: rdf, stringValue: "") as! XMLNode)
            r.addChild(made)
            host = made
        }
        let h = host!
        let wanted = ns == dc ? "dc" : ns == pdf ? "pdf" : ns == xmpMM ? "xmpMM" : "xmp"
        if h.resolvePrefix(forNamespaceURI: ns) == nil {
            h.addNamespace(XMLNode.namespace(withName: wanted, stringValue: ns) as! XMLNode)
        }
        let p = h.resolvePrefix(forNamespaceURI: ns) ?? wanted
        let e = XMLElement(name: "\(p):\(local)", uri: ns)
        if let structured { e.addChild(structured(value)) } else { e.stringValue = value }
        h.addChild(e)
    }

    /// Drops characters XML can't carry (PDF strings may hold control characters), trimmed.
    static func clean(_ s: String) -> String {
        var out = String.UnicodeScalarView()
        for u in s.unicodeScalars {
            let v = u.value
            if v == 0x9 || v == 0xA || v == 0xD || (0x20...0xD7FF).contains(v) || (0xE000...0xFFFD).contains(v) || v >= 0x10000 { out.append(u) }
        }
        return String(out).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func format(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ssxxx"
        return f.string(from: d)
    }
}

extension PdfEdit {
    /// A document opened for reading (PDFsharp's Import mode): an encrypted one opens with either of its passwords.
    static func openToRead(_ data: [UInt8], _ password: String?) throws -> MuDoc {
        let doc: MuDoc
        do {
            doc = try MuDoc.open(data)
        } catch let e as PdfEngineError {
            throw PdfEditError("This PDF can't be read: \(e.message)")
        }
        if doc.needsPassword && doc.authBits(password) == 0 { throw PasswordRequired(wrongPassword: !(password ?? "").isEmpty) }
        return doc
    }
}
