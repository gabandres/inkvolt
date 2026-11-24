import Foundation

/// An IPP request (RFC 8010 §3.1) written attribute by attribute: the header, the operation group with
/// `attributes-charset`, `attributes-natural-language` and `printer-uri` first (RFC 8011 §4.1.4 wants them in that order),
/// then whatever the operation takes, a job group when one is opened, and end-of-attributes. Collections are written as
/// RFC 8010 §3.1.6 has them (begCollection, memberAttrName and its value, endCollection). IPP/2.0, which IPP Everywhere
/// printers support. Windows' `Ipp/IppRequest`.
public struct IppRequest: Sendable {
    private var bytes: [UInt8]

    public init(_ operation: UInt16, requestId: Int32, printerUri: String) {
        bytes = [2, 0, UInt8(operation >> 8), UInt8(operation & 0xFF)] + Self.int32(Int(requestId))
        bytes.append(IppCodec.operationTag)
        value(IppCodec.charset, "attributes-charset", "utf-8")
        value(IppCodec.naturalLanguage, "attributes-natural-language", "en")
        value(IppCodec.uri, "printer-uri", printerUri)
    }

    /// Starts the job attributes group (Print-Job's job template attributes).
    public mutating func jobGroup() { bytes.append(IppCodec.jobTag) }

    public mutating func integer(_ name: String, _ v: Int) { value(IppCodec.integer, name, Self.int32(v)) }
    public mutating func enumeration(_ name: String, _ v: Int) { value(IppCodec.enumeration, name, Self.int32(v)) }
    public mutating func keyword(_ name: String, _ v: String) { value(IppCodec.keyword, name, v) }
    public mutating func name(_ name: String, _ v: String) { value(IppCodec.name, name, Self.shorten(v)) }
    public mutating func mimeMediaType(_ name: String, _ v: String) { value(IppCodec.mimeMediaType, name, v) }

    /// A 1setOf keyword (the first value carries the name, the others an empty one).
    public mutating func keywords(_ name: String, _ values: [String]) {
        for (i, v) in values.enumerated() { value(IppCodec.keyword, i == 0 ? name : "", v) }
    }

    /// A collection attribute; `members` writes its members.
    public mutating func collection(_ name: String, _ members: (inout IppCollectionWriter) -> Void) {
        value(IppCodec.begCollection, name, [UInt8]())
        var writer = IppCollectionWriter()
        members(&writer)
        bytes += writer.bytes
        value(IppCodec.endCollection, "", [UInt8]())
    }

    /// The finished request (end-of-attributes written). The document, if any, follows these bytes.
    public func finished() -> [UInt8] { bytes + [IppCodec.endTag] }

    /// A name value is at most 255 octets (RFC 8011 §5.1.3): longer file names are cut on a character boundary.
    static func shorten(_ v: String) -> String {
        if v.utf8.count <= 255 { return v }
        var cut = Substring(v)
        while cut.utf8.count > 255 { cut = cut.dropLast() }
        return String(cut)
    }

    private mutating func value(_ tag: UInt8, _ name: String, _ v: String) { value(tag, name, Array(v.utf8)) }

    private mutating func value(_ tag: UInt8, _ name: String, _ v: [UInt8]) {
        Self.write(&bytes, tag, name, v)
    }

    static func write(_ b: inout [UInt8], _ tag: UInt8, _ name: String, _ v: [UInt8]) {
        let n = Array(name.utf8.prefix(0xFFFF))
        let v = v.count > 0xFFFF ? Array(v.prefix(0xFFFF)) : v
        b.append(tag)
        b += [UInt8(n.count >> 8), UInt8(n.count & 0xFF)] + n
        b += [UInt8(v.count >> 8), UInt8(v.count & 0xFF)] + v
    }

    static func int32(_ v: Int) -> [UInt8] {
        let u = UInt32(bitPattern: Int32(truncatingIfNeeded: v))
        return [UInt8(u >> 24), UInt8(u >> 16 & 0xFF), UInt8(u >> 8 & 0xFF), UInt8(u & 0xFF)]
    }
}

/// Writes one collection's members: each is a memberAttrName, then its value with an empty name.
public struct IppCollectionWriter: Sendable {
    var bytes: [UInt8] = []

    public mutating func integer(_ member: String, _ v: Int) { self.member(member, IppCodec.integer, IppRequest.int32(v)) }
    public mutating func keyword(_ member: String, _ v: String) { self.member(member, IppCodec.keyword, Array(v.utf8)) }

    public mutating func collection(_ member: String, _ members: (inout IppCollectionWriter) -> Void) {
        self.member(member, IppCodec.begCollection, [])
        members(&self)
        IppRequest.write(&bytes, IppCodec.endCollection, "", [])
    }

    private mutating func member(_ member: String, _ tag: UInt8, _ v: [UInt8]) {
        IppRequest.write(&bytes, IppCodec.memberAttrName, "", Array(member.utf8))
        IppRequest.write(&bytes, tag, "", v)
    }
}
