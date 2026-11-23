import Foundation
import PrintCore

/// A web or email address printed on a page: the text, the address its link leads to, and its box on each line.
public struct FoundAddress: Sendable, Equatable {
    public var page: Int
    public var text: String
    public var uri: String
    public var boxes: [RectD]

    public init(_ page: Int, _ text: String, _ uri: String, _ boxes: [RectD]) {
        self.page = page
        self.text = text
        self.uri = uri
        self.boxes = boxes
    }
}

/// Links from Addresses (roadmap 4.15; the Windows app's `AddressLinks`): every web address (http, https, or starting
/// www.) and email address printed in the text becomes a link, as the Link tool makes one over selected text
/// (`Links.putOnTexts`; the same address rules: https for www., mailto for email, international domains as punycode,
/// scripts refused). An address already covered by a link is left alone; one broken over two lines is not found.
public enum AddressLinks {
    /// The most addresses one run lists (a directory of thousands is linked in parts).
    public static let maxFound = 5000

    /// The longest address taken (longer is a run of characters, not an address).
    private static let maxLength = 2000

    // A web address: http(s):// or www. and what follows up to a space or a character addresses don't hold. An email
    // address: a local part, @, then a domain of labels ending in letters (international ones too). Neither may follow a
    // letter, digit or address character (no match inside a longer word). Windows' pattern, as ICU reads it.
    private static let address = try! NSRegularExpression(
        pattern: #"(?<![\p{L}\p{N}@._%+/-])(?:(?:https?://|www\.)[^\s<>"{}|\\^`]+|[\p{L}\p{N}._%+-]+@(?:[\p{L}\p{N}](?:[\p{L}\p{N}-]{0,61}[\p{L}\p{N}])?\.)+\p{L}{2,}(?![\p{L}\p{N}_@-]))"#,
        options: [.caseInsensitive])

    /// The addresses in a page's text, as (start, length) in UTF-16 units: a web address loses the punctuation a sentence
    /// puts after it (a full stop, a comma, quotes, a closing bracket it didn't open).
    public static func matches(_ text: String) -> [(start: Int, length: Int)] {
        let ns = text as NSString
        var result: [(start: Int, length: Int)] = []
        for m in address.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let value = ns.substring(with: m.range)
            if value.contains("@") && !value.contains("://") && !value.lowercased().hasPrefix("www.") {
                let local = value[..<value.firstIndex(of: "@")!]
                if local.hasPrefix(".") || local.hasSuffix(".") || local.contains("..") { continue }
                result.append((m.range.location, m.range.length))
                continue
            }
            let length = trimmed(value)
            let host = (value as NSString).substring(to: length) as String
            // "www." or "https://" with nothing worth a link after it.
            let rest: String
            if host.lowercased().hasPrefix("www.") {
                rest = String(host.dropFirst(4))
            } else if let r = host.range(of: "://") {
                rest = String(host[r.upperBound...])
            } else {
                continue
            }
            if (rest as NSString).length < 3 || !rest.contains(".") && !rest.lowercased().hasPrefix("localhost") || length > maxLength { continue }
            result.append((m.range.location, length))
        }
        return result
    }

    /// A web address's length (UTF-16 units) without what a sentence put after it.
    private static func trimmed(_ value: String) -> Int {
        let u = Array(value.utf16)
        let sentence = Set(".,;:!?'\"*»”’›".utf16)
        let opener: [UInt16: UInt16] = [41: 40, 93: 91, 125: 123] // ) ( ] [ } {
        var end = u.count
        while end > 0 {
            let c = u[end - 1]
            if sentence.contains(c) {
                end -= 1
            } else if let open = opener[c], u[..<end].filter({ $0 == c }).count > u[..<end].filter({ $0 == open }).count {
                end -= 1 // a closing bracket the address didn't open
            } else {
                break
            }
        }
        return end
    }

    /// The addresses on the pages not already behind a link (a link over half or more of the address), in page order;
    /// at most `maxFound`. A page that can't be read is passed over. `progress`: (pages done, pages), before each page.
    /// - Throws: `CancellationError` when `cancel` fired; `PdfEngineClosed` when the engine is closed.
    public static func find(_ engine: PdfEngine, progress: ((_ done: Int, _ total: Int) -> Void)? = nil,
                            cancel: CancelToken? = nil) throws -> [FoundAddress] {
        var found: [FoundAddress] = []
        let count = engine.pageCount
        var p = 0
        while p < count && found.count < maxFound {
            defer { p += 1 }
            try cancel.check()
            progress?(p, count)
            let text: PageText
            let links: [PageLink]
            do {
                text = try engine.text(p, cache: false, cancel: cancel)
                links = try engine.links(p, cancel: cancel)
            } catch is PdfEngineError {
                continue
            } catch is PageRefused {
                continue
            }
            let ns = text.text as NSString
            for (start, length) in matches(text.text) {
                let value = ns.substring(with: NSRange(location: start, length: length))
                guard let uri = Links.normalize(value) else { continue }
                let boxes = text.rects(start, start + length)
                if boxes.isEmpty || boxes.contains(where: { b in links.contains { covered(b, $0.area) } }) { continue }
                found.append(FoundAddress(p, value, uri, boxes))
                if found.count >= maxFound { break }
            }
        }
        return found
    }

    /// The chosen addresses made links, as one change of the document (the same bytes when none could be).
    public static func apply(_ data: [UInt8], _ password: String?, _ chosen: [FoundAddress]) throws -> [UInt8] {
        try Links.putOnTexts(data, password, chosen.map { ($0.page, $0.boxes, $0.uri) })
    }

    /// Half or more of `box` lies under `link`.
    private static func covered(_ box: RectD, _ link: RectD) -> Bool {
        let w = min(box.right, link.right) - max(box.x, link.x)
        let h = min(box.bottom, link.bottom) - max(box.y, link.y)
        return w > 0 && h > 0 && w * h >= 0.5 * box.width * box.height
    }
}
