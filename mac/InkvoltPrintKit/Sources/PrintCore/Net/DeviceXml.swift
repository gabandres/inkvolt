import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

/// XML a device sent that can't be read: malformed, with a DTD, or nested too deep.
public struct XmlFormatError: Error, CustomStringConvertible {
    public let description: String

    public init(_ description: String) { self.description = description }
}

/// An element of a device's XML document, by local name (LEDM namespaces drift across firmware, local names don't).
public struct XmlElement: Equatable, Sendable {
    public let name: String
    public let attributes: [String: String]
    public fileprivate(set) var children: [XmlElement]
    fileprivate(set) var text: String
    /// The namespace URI ("" for none) and the prefix the device wrote ("" for none): a write reuses the device's own names.
    public fileprivate(set) var namespace: String = ""
    public fileprivate(set) var prefix: String = ""

    /// The element's text with its descendants' (as LINQ to XML's `Value`; mixed content isn't kept in order).
    public var value: String { children.isEmpty ? text : text + children.map(\.value).joined() }

    /// Descendants named `localName`, in document order (not the element itself).
    public func all(_ localName: String) -> [XmlElement] {
        var found: [XmlElement] = []
        var stack: [XmlElement] = children.reversed()
        while let e = stack.popLast() {
            if e.name == localName { found.append(e) }
            stack.append(contentsOf: e.children.reversed())
        }
        return found
    }

    public func kids(_ localName: String) -> [XmlElement] { children.filter { $0.name == localName } }

    public func kid(_ localName: String) -> XmlElement? { children.first { $0.name == localName } }

    /// A child's trimmed text; nil when missing or empty.
    public func kidValue(_ localName: String) -> String? { nonEmpty(kid(localName)?.value) }

    /// The first descendant's trimmed text; nil when missing or empty.
    public func firstValue(_ localName: String) -> String? { nonEmpty(all(localName).first?.value) }

    private func nonEmpty(_ s: String?) -> String? {
        guard let t = s?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        return t
    }
}

extension String {
    /// As .NET's int.TryParse: surrounding white space allowed.
    var asInt: Int? { Int(trimmingCharacters(in: .whitespacesAndNewlines)) }
}

extension Optional where Wrapped == String {
    var asInt: Int? { self?.asInt }
}

/// Reads XML a device sent (LEDM, eSCL): no DTD (no entities to expand, nothing fetched) and no deeper than `maxDepth`.
/// Malformed or refused XML is an `XmlFormatError`.
public enum DeviceXml {
    /// The printers' own documents nest a dozen levels at most.
    public static let maxDepth = 64

    public static func load(_ bytes: [UInt8]) throws -> XmlElement {
        if bytes.firstRange(of: Array("<!DOCTYPE".utf8)) != nil { throw XmlFormatError("A document with a DTD is refused.") }
        let parser = XMLParser(data: Data(bytes))
        parser.shouldProcessNamespaces = true
        parser.shouldResolveExternalEntities = false
        let builder = Builder()
        parser.delegate = builder
        let parsed = parser.parse()
        if let error = builder.error { throw error }
        guard parsed, let root = builder.root else {
            throw XmlFormatError("Not well-formed XML: \(parser.parserError.map { "\($0)" } ?? "no root element").")
        }
        return root
    }

    public static func load(_ text: String) throws -> XmlElement { try load(Array(text.utf8)) }

    private final class Builder: NSObject, XMLParserDelegate {
        var stack: [XmlElement] = []
        var root: XmlElement?
        var error: XmlFormatError?

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName: String?,
                    attributes: [String: String] = [:]) {
            if stack.count >= DeviceXml.maxDepth {
                error = XmlFormatError("The document nests deeper than \(DeviceXml.maxDepth) levels.")
                parser.abortParsing()
                return
            }
            let prefix = qualifiedName.flatMap { q in q.firstIndex(of: ":").map { String(q[..<$0]) } } ?? ""
            stack.append(XmlElement(name: elementName, attributes: attributes, children: [], text: "", namespace: namespaceURI ?? "", prefix: prefix))
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) {
            guard let done = stack.popLast() else { return }
            if stack.isEmpty { root = done } else { stack[stack.count - 1].children.append(done) }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if !stack.isEmpty { stack[stack.count - 1].text += string }
        }

        func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
            if !stack.isEmpty { stack[stack.count - 1].text += String(decoding: CDATABlock, as: UTF8.self) }
        }

        func parser(_ parser: XMLParser, foundInternalEntityDeclarationWithName name: String, value: String?) { refuseDtd(parser) }

        func parser(_ parser: XMLParser, foundExternalEntityDeclarationWithName name: String, publicID: String?, systemID: String?) {
            refuseDtd(parser)
        }

        private func refuseDtd(_ parser: XMLParser) {
            error = XmlFormatError("A document with a DTD is refused.")
            parser.abortParsing()
        }
    }
}
