import Foundation

/// A link annotation: where it is (page space) and where it leads (a URI, or a page of this document).
public struct LinkInfo: Equatable, Sendable {
    /// The annotation's /NM, else its position ("p<page>:<index>", valid for the bytes it was read from).
    public var id: String
    public var pageIndex: Int
    public var rect: RectD
    /// The address of a URI link; nil otherwise.
    public var uri: String?
    /// The page a link inside the document goes to (0-based); -1 for a URI or an action Inkvolt PDF doesn't edit.
    public var targetPage: Int

    /// What it leads to, for lists and tooltips.
    public func describe() -> String { uri ?? (targetPage >= 0 ? "Page \(targetPage + 1)" : "Another action") }
}

/// Link annotations made and edited with the Link tool (the Windows app's `Links`): a rectangle on a page leading to a web
/// or email address (a URI action) or to a page of this document (a destination). Links are invisible (no border);
/// viewers show a hand over them. Opening a link is the viewer's business: Inkvolt PDF asks before opening anything but
/// http, https and mailto.
public enum Links {
    /// Schemes opened without asking (the same as the page view's link safety prompt).
    private static let safeSchemes: Set<String> = ["http", "https", "mailto"]
    /// Schemes never written into a link.
    private static let blockedSchemes: Set<String> = ["javascript", "vbscript", "data"]

    public static func read(_ data: [UInt8], _ password: String?) throws -> [LinkInfo] {
        let doc = try PdfEdit.openToRead(data, password)
        var list: [LinkInfo] = []
        for p in 0..<(try doc.pageCount()) {
            let page = doc.page(p)
            for (i, a) in (page.array("Annots")?.elements ?? []).enumerated() where a.isDict && a.name("Subtype") == "Link" {
                guard let r = a.array("Rect"), r.count >= 4 else { continue }
                let (uri, target) = target(doc, a)
                list.append(LinkInfo(id: Annotations.idOf(doc, a, p, i), pageIndex: p, rect: PageBoxes.rectToPage(page, r), uri: uri, targetPage: target))
            }
        }
        return list
    }

    private static func target(_ doc: MuDoc, _ link: PObj) -> (uri: String?, page: Int) {
        var dest = link["Dest"]
        if let a = link.dict("A") {
            switch a.name("S") {
            case "URI": return (a.text("URI") ?? a["URI"]?.bytes.map { String(decoding: $0, as: UTF8.self) }, -1)
            case "GoTo": dest = a["D"]
            default: return (nil, -1)
            }
        }
        return (nil, DocumentFeatures.resolveDestination(doc, dest)?.pageIndex ?? -1)
    }

    /// Adds a link (or, with `replaceId`, moves it and changes where it leads) over `rect` (page space): to `uri` when
    /// given, else to page `targetPage`.
    public static func put(_ data: [UInt8], _ password: String?, _ pageIndex: Int, _ rect: RectD, uri: String?, targetPage: Int,
                           replaceId: String? = nil) throws -> [UInt8] {
        try put(data, password, pageIndex, rect, uri, targetPage, replaceId, nil)
    }

    /// Makes the text in `lineRects` (one box per line, page space) a link: one link over all of them whose /QuadPoints
    /// are the lines, so viewers that read them react to the text only.
    public static func putOnText(_ data: [UInt8], _ password: String?, _ pageIndex: Int, _ lineRects: [RectD], uri: String?,
                                 targetPage: Int) throws -> [UInt8] {
        let lines = lineRects.filter { !$0.isEmpty }
        if lines.isEmpty { throw PdfEditError("No text to link.") }
        let all = RectD.fromEdges(lines.map(\.x).min()!, lines.map(\.y).min()!, lines.map(\.right).max()!, lines.map(\.bottom).max()!)
        return try put(data, password, pageIndex, all, uri, targetPage, nil, lines)
    }

    private static func put(_ data: [UInt8], _ password: String?, _ pageIndex: Int, _ rect: RectD, _ uri: String?, _ targetPage: Int,
                            _ replaceId: String?, _ lines: [RectD]?) throws -> [UInt8] {
        if rect.width < 1 || rect.height < 1 { throw PdfEditError("The link needs a size.") }
        var address: String?
        if let uri {
            guard let normalized = normalize(uri) else { throw PdfEditError("That isn't a web or email address.") }
            address = normalized
        }
        return try PageEditor.edit(data, password) { doc in
            try Annotations.checkPage(doc, pageIndex)
            let count = try doc.pageCount()
            if address == nil && (targetPage < 0 || targetPage >= count) { throw PdfEditError("Choose a page from 1 to \(count).") }

            let page = doc.page(pageIndex)
            let annot: PObj
            if let replaceId {
                annot = try relocate(doc, replaceId, pageIndex)
                for key in ["A", "Dest", "QuadPoints"] { annot.remove(key) }
            } else {
                annot = doc.add(doc.dict([
                    ("Type", doc.name("Annot")), ("Subtype", doc.name("Link")), ("NM", doc.text(Annotations.newId())), ("F", doc.int(4)),
                    ("Border", doc.array([doc.int(0), doc.int(0), doc.int(0)])), ("H", doc.name("I")), ("P", page),
                ]))
                doc.annots(page).append(annot)
            }
            let r = PageBoxes.fromPageSpace(page, rect)
            annot.set("Rect", doc.realArray([r.x1, r.y1, r.x2, r.y2]))
            annot.set("M", doc.now())
            if let lines {
                // Corners in the reading orientation of the page as shown, as for text markup: upper-left, upper-right,
                // lower-left, lower-right.
                var qp: [Double] = []
                for l in lines {
                    for (px, py) in [(l.x, l.y), (l.right, l.y), (l.x, l.bottom), (l.right, l.bottom)] {
                        let q = PageBoxes.toPdf(page, px, py)
                        qp += [q.x, q.y]
                    }
                }
                annot.set("QuadPoints", doc.realArray(qp))
            }
            if let address {
                annot.set("A", doc.dict([("Type", doc.name("Action")), ("S", doc.name("URI")), ("URI", doc.string(Array(address.utf8)))]))
            } else {
                // The top of the target page as shown, keeping the zoom.
                let target = doc.page(targetPage)
                let u = PageBoxes.toPdf(target, 0, 0)
                let sideways = [90, 270].contains(PageBoxes.rotate(target))
                let ux = doc.real((u.x * 100).rounded() / 100), uy = doc.real((u.y * 100).rounded() / 100)
                annot.set("Dest", doc.array([target, doc.name("XYZ"), sideways ? ux : doc.null, sideways ? doc.null : uy, doc.null]))
            }
        }
    }

    /// Moves or resizes a link (onto another page too), keeping where it leads, whatever its action.
    public static func move(_ data: [UInt8], _ password: String?, _ id: String, _ pageIndex: Int, _ rect: RectD) throws -> [UInt8] {
        if rect.width < 1 || rect.height < 1 { throw PdfEditError("The link needs a size.") }
        return try PageEditor.edit(data, password) { doc in
            try Annotations.checkPage(doc, pageIndex)
            let annot = try relocate(doc, id, pageIndex)
            let r = PageBoxes.fromPageSpace(doc.page(pageIndex), rect)
            annot.set("Rect", doc.realArray([r.x1, r.y1, r.x2, r.y2]))
            annot.set("M", doc.now())
            // Highlighting quads (/QuadPoints) would still mark the old place.
            annot.remove("QuadPoints")
        }
    }

    /// The link `id`, moved into page `pageIndex`'s annotations if it was on another page.
    private static func relocate(_ doc: MuDoc, _ id: String, _ pageIndex: Int) throws -> PObj {
        guard let found = try Annotations.find(doc, id) else { throw PdfEditError("That link is no longer in the document.") }
        let link = found.annot
        if link.name("Subtype") != "Link" { throw PdfEditError("That isn't a link.") }
        if found.page == pageIndex { return link }
        let from = doc.annots(doc.page(found.page))
        var kept: PObj?
        for i in stride(from: from.count - 1, through: 0, by: -1) {
            if let e = from[i], e.identity == link.identity {
                kept = kept ?? e
                from.remove(at: i)
            }
        }
        let page = doc.page(pageIndex)
        doc.annots(page).append(kept ?? link)
        link.set("P", page)
        return link
    }

    /// Deletes a link.
    public static func delete(_ data: [UInt8], _ password: String?, _ id: String) throws -> [UInt8] {
        try PageEditor.edit(data, password) { doc in
            guard let found = try Annotations.find(doc, id), found.annot.name("Subtype") == "Link" else {
                throw PdfEditError("That link is no longer in the document.")
            }
            _ = try Annotations.deleteIn(doc, id)
        }
    }

    // ---------------- Addresses ----------------

    /// The address as it goes into a link, or nil when it can't be one: "example.com/x" and "www.example.com" become
    /// https, "name@example.com" becomes mailto; absolute addresses stay as typed (international domains as punycode,
    /// other non-ASCII characters percent-encoded as UTF-8), except script and data addresses, which are refused. Windows
    /// leans on .NET's `Uri`; this parses the few parts that matter (scheme, host, the rest) itself.
    public static func normalize(_ text: String) -> String? {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty || (t.contains(where: \.isWhitespace) && !t.contains(":")) { return nil }
        if !t.contains(":") && t.contains("@") && !t.contains("/"), let at = t.firstIndex(of: "@"), at > t.startIndex,
           let dot = t[t.index(after: at)...].firstIndex(of: "."), t.distance(from: at, to: dot) > 1 {
            t = "mailto:" + t
        } else if !t.contains("://") && !t.contains(":") && t.contains(".") {
            t = "https://" + t
        }
        guard let colon = t.firstIndex(of: ":") else { return nil }
        let scheme = String(t[..<colon]).lowercased()
        guard let first = scheme.unicodeScalars.first, first.isASCII, first.properties.isAlphabetic,
              scheme.unicodeScalars.allSatisfy({ $0.isASCII && ($0.properties.isAlphabetic || ("0"..."9").contains($0) || "+.-".unicodeScalars.contains($0)) })
        else { return nil }
        if blockedSchemes.contains(scheme) { return nil }
        let rest = String(t[t.index(after: colon)...])
        let ascii: String?
        if scheme == "mailto" {
            ascii = asciiMailto(rest)
        } else if rest.hasPrefix("//") {
            ascii = asciiHierarchical(scheme, String(rest.dropFirst(2)))
        } else {
            ascii = rest.isEmpty ? nil : scheme + ":" + percentEncode(rest)
        }
        guard let ascii, ascii.unicodeScalars.allSatisfy({ $0.value > 32 && $0.value < 0x7F }) else { return nil }
        return ascii
    }

    /// scheme://[user@]host[:port]/path?query#fragment: the host lowercased (international ones as punycode), an empty
    /// path as "/", everything else percent-encoded where it isn't ASCII.
    private static func asciiHierarchical(_ scheme: String, _ rest: String) -> String? {
        let end = rest.firstIndex(where: { $0 == "/" || $0 == "?" || $0 == "#" }) ?? rest.endIndex
        let authority = String(rest[..<end])
        var tail = String(rest[end...])
        var user = "", hostPort = authority
        if let at = authority.lastIndex(of: "@") {
            user = String(authority[...at])
            hostPort = String(authority[authority.index(after: at)...])
        }
        var host = hostPort, port = ""
        if !hostPort.hasPrefix("["), let c = hostPort.lastIndex(of: ":"), hostPort[hostPort.index(after: c)...].allSatisfy(\.isNumber) {
            host = String(hostPort[..<c])
            port = String(hostPort[c...])
        }
        if host.isEmpty || host.contains(where: { $0.isWhitespace || "<>\"{}|\\^`%".contains($0) }) { return nil }
        guard let asciiHost = idnHost(host) else { return nil }
        if tail.isEmpty || tail.hasPrefix("?") || tail.hasPrefix("#") { tail = "/" + tail }
        return scheme + "://" + percentEncode(user) + asciiHost + port + percentEncode(tail)
    }

    /// mailto:local@domain?query: the domain as punycode, everything else that isn't ASCII percent-encoded.
    private static func asciiMailto(_ body: String) -> String? {
        let q = body.firstIndex(of: "?") ?? body.endIndex
        let to = String(body[..<q]), query = String(body[q...])
        var addresses: [String] = []
        for a in to.split(separator: ",", omittingEmptySubsequences: false).map(String.init) {
            guard let at = a.lastIndex(of: "@") else {
                addresses.append(percentEncode(a))
                continue
            }
            let domain = String(a[a.index(after: at)...])
            if domain.unicodeScalars.allSatisfy(\.isASCII) {
                addresses.append(percentEncode(a))
            } else {
                guard let host = idnHost(domain.removingPercentEncoding ?? domain) else { return nil }
                addresses.append(percentEncode(String(a[..<at])) + "@" + host)
            }
        }
        return "mailto:" + addresses.joined(separator: ",") + percentEncode(query)
    }

    /// A host name in ASCII: each label lowercased, non-ASCII labels as "xn--" punycode (IDNA's ToASCII for the names
    /// people type; full UTS #46 mapping is reduced to compatibility normalization and lowercasing).
    static func idnHost(_ host: String) -> String? {
        var h = host
        for dot in ["\u{3002}", "\u{FF0E}", "\u{FF61}"] { h = h.replacingOccurrences(of: dot, with: ".") }
        var labels: [String] = []
        for label in h.split(separator: ".", omittingEmptySubsequences: false).map(String.init) {
            if label.unicodeScalars.allSatisfy(\.isASCII) {
                labels.append(label.lowercased())
                continue
            }
            let mapped = label.precomposedStringWithCompatibilityMapping.lowercased()
            guard let code = punycode(mapped.unicodeScalars.map(\.value)) else { return nil }
            labels.append("xn--" + code)
        }
        return labels.joined(separator: ".")
    }

    /// RFC 3492's Punycode encoding of a label's code points.
    static func punycode(_ input: [UInt32]) -> String? {
        let base = 36, tMin = 1, tMax = 26, skew = 38, damp = 700
        func digit(_ d: Int) -> Character { Character(Unicode.Scalar(UInt8(d < 26 ? 97 + d : 22 + d))) }
        func adapt(_ delta: Int, _ points: Int, _ first: Bool) -> Int {
            var d = first ? delta / damp : delta / 2
            d += d / points
            var k = 0
            while d > ((base - tMin) * tMax) / 2 {
                d /= base - tMin
                k += base
            }
            return k + (base - tMin + 1) * d / (d + skew)
        }
        var output = String(input.filter { $0 < 0x80 }.compactMap { Unicode.Scalar($0) }.map(Character.init))
        let basic = output.count
        var handled = basic
        if basic > 0 { output.append("-") }
        var n = 128, delta = 0, bias = 72
        let codes = input.map(Int.init)
        while handled < codes.count {
            guard let m = codes.filter({ $0 >= n }).min() else { return nil }
            delta += (m - n) * (handled + 1)
            n = m
            for c in codes {
                if c < n { delta += 1 }
                if c == n {
                    var q = delta
                    var k = base
                    while true {
                        let t = k <= bias ? tMin : (k >= bias + tMax ? tMax : k - bias)
                        if q < t { break }
                        output.append(digit(t + (q - t) % (base - t)))
                        q = (q - t) / (base - t)
                        k += base
                    }
                    output.append(digit(q))
                    bias = adapt(delta, handled + 1, handled == basic)
                    delta = 0
                    handled += 1
                }
            }
            delta += 1
            n += 1
        }
        return output
    }

    /// Percent-encodes (as UTF-8) every character that isn't printable ASCII, leaving the rest as it is.
    private static func percentEncode(_ s: String) -> String {
        var out = ""
        for scalar in s.unicodeScalars {
            if scalar.value > 32 && scalar.value < 0x7F {
                out.unicodeScalars.append(scalar)
                continue
            }
            for b in String(scalar).utf8 { out += String(format: "%%%02X", b) }
        }
        return out
    }

    /// True for addresses viewers open without asking (http, https, mailto).
    public static func isSafe(_ uri: String) -> Bool {
        guard let colon = uri.firstIndex(of: ":") else { return false }
        return safeSchemes.contains(String(uri[..<colon]).lowercased())
    }
}
